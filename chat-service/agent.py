from __future__ import annotations

"""The PhenoMAP chat agent, as a staged pipeline:

  1. _classify_relevance -- is this even a PhenoMAP-related message? Sorts
     it into "product" (about PhenoMAP Chat/PhenoMAP itself),
     "off_topic" (declined right here, no tools), or "phenomap_question"
     (PhenoMAP's graph data). No tools called here -- and unlike
     "off_topic", "product" is no longer answered in this stage either; it
     is handed to stage 3 below just like "phenomap_question" is.
  2. _classify_intent     -- for phenomap_question only: what kind of graph
     workflow does it need, and which entities are named? Still no tools --
     this is planning, not execution.
  3. _run_execution_native -- the only stage that
     calls tools. Generalized to run over either of two disjoint tool sets:
     PhenoMAP's graph tools (search_entities and friends, for
     phenomap_question) or the single get_product_info tool (for product).
     Receives a system prompt built for whichever one applies and does the
     actual retrieval + writes the final answer.

This replaces an earlier design where one long, do-everything system prompt
asked a single completion to simultaneously classify intent, remember
citation formatting, remember truncation caveats, and remember entity-
resolution fallback rules all at once. That measurably degrades follow-
through for weaker/quantized models, since rules further down a long prompt
are easier to silently skip. Each stage here only has to hold ONE job in
mind -- the same principle already validated by pulling the alias-
confirmation phrasing out into its own dedicated call (see
_generate_alias_confirmation below, which predates this split and works the
same way), and now extended to product questions: rather than a paragraph of
"product facts" glued onto the relevance classifier and answered from
memory, a product-classified turn gets its own tool call (get_product_info)
and its own short execution prompt (PRODUCT_EXECUTION_PROMPT), so PhenoMAP's
product information is retrieved on demand in the turns that actually need
it instead of being carried in every single prompt regardless of category.

This is deliberately not a text-RAG pipeline (no vector store of documents
here). PhenoMAP's "knowledge" is already structured (graph nodes/edges,
enrichment statistics, and now product info too), and the Go backend/
product_facts.json already expose exactly the operations or data a user
would look up by hand -- so stage 3's job is composing those same calls,
not retrieving passages of text.

run_chat_stream() is the entry point main.py uses: an async generator that
yields {"type": "status", "text": ...} progress events while working (one
per pipeline stage and one per tool call), and exactly one terminal event,
either {"type": "final", ...} or {"type": "error", "message": ...}. This is
what lets the frontend show short "thinking" hints (searching..., checking
the connection..., ...) instead of a static spinner, matching the request
that motivated this whole restructuring.
"""

import asyncio
import hashlib
import json
import re
import threading

import httpx
from openai import APIConnectionError, AuthenticationError, BadRequestError, NotFoundError, OpenAI

from config import (
    MAX_TOOL_TURNS,
    OPENAI_BASE_URL,
    OPENAI_MODEL,
    SILICONFLOW_BASE_URL,
    SILICONFLOW_MODEL,
)
from prompts import EXECUTION_PROMPT_TEMPLATE, INTENT_PROMPT, PRODUCT_EXECUTION_PROMPT, RELEVANCE_PROMPT
from tools import PRODUCT_TOOL_FUNCS, PRODUCT_TOOL_SCHEMAS, TOOL_FUNCS, TOOL_SCHEMAS, BackendError

class LLMConfigError(Exception):
    """Raised when a requested LLM provider is missing credentials."""


def _resolve_llm(llm_config: dict) -> dict:
    provider = (llm_config or {}).get("provider") or "siliconflow"
    provider = provider.strip().lower()

    if provider == "openai":
        api_key = (llm_config or {}).get("api_key", "").strip()
        base_url = OPENAI_BASE_URL
        model = (llm_config or {}).get("model", "").strip() or OPENAI_MODEL
        label = "OpenAI"
        if not api_key:
            raise LLMConfigError("OpenAI mode requires an API key.")
    elif provider == "siliconflow":
        api_key = (llm_config or {}).get("api_key", "").strip()
        base_url = SILICONFLOW_BASE_URL
        model = (llm_config or {}).get("model", "").strip() or SILICONFLOW_MODEL
        label = "SiliconFlow"
        if not api_key:
            raise LLMConfigError("SiliconFlow mode requires an API key.")
    else:
        raise LLMConfigError("provider must be one of openai, siliconflow.")

    return {
        "provider": provider,
        "provider_label": label,
        "api_key": api_key,
        "base_url": base_url.rstrip("/"),
        "model": model,
    }


# SiliconFlow runs two separate sites with separate accounts:
# api.siliconflow.cn (mainland China) and api.siliconflow.com (global). A key
# issued by one is rejected (401) by the other, so a user who signed up on
# siliconflow.com could never use the chat while only the .cn site was tried.
# The first chat turn for a key probes /models on each site (configured one
# first) and remembers which one accepted it -- per key, not per process, so
# one user's site never gets pinned for everybody else (same fix as the
# FeatureMAP Shiny app).
_SILICONFLOW_SITES = ("https://api.siliconflow.cn/v1", "https://api.siliconflow.com/v1")
_siliconflow_site_by_key: dict[str, str] = {}


async def _siliconflow_base_url(api_key: str, configured: str) -> str:
    fingerprint = hashlib.sha256(api_key.encode("utf-8")).hexdigest()
    cached = _siliconflow_site_by_key.get(fingerprint)
    if cached:
        return cached

    candidates: list[str] = []
    for url in (configured, *_SILICONFLOW_SITES):
        url = (url or "").strip().rstrip("/")
        if url and url not in candidates:
            candidates.append(url)

    async with httpx.AsyncClient(timeout=10.0) as client:
        for base in candidates:
            try:
                resp = await client.get(f"{base}/models", headers={"Authorization": f"Bearer {api_key}"})
            except httpx.HTTPError:
                continue
            if resp.status_code == 200:
                if len(_siliconflow_site_by_key) > 5000:
                    _siliconflow_site_by_key.clear()
                _siliconflow_site_by_key[fingerprint] = base
                return base
    # Neither site accepted the key (or neither was reachable): use the first
    # one and let the real call report the error.
    return candidates[0]


def _friendly_llm_error(e: Exception, resolved_llm: dict) -> str | None:
    """Plain-language message for the provider errors users actually hit
    (bad key, unknown model), instead of the raw SDK error dump."""
    label = resolved_llm.get("provider_label", "The model provider")
    model = resolved_llm.get("model", "")
    if isinstance(e, AuthenticationError):
        if resolved_llm.get("provider") == "siliconflow":
            return (
                "SiliconFlow rejected this API key (checked both api.siliconflow.cn and api.siliconflow.com). "
                "Please check the key in Model settings."
            )
        return f"{label} rejected this API key. Please check the key in Model settings."
    if isinstance(e, (NotFoundError, BadRequestError)):
        text = str(e).lower()
        if "model" in text and ("not exist" in text or "not found" in text or "does not exist" in text or "invalid" in text):
            return (
                f'{label} does not offer the model "{model}" for this key. '
                "Pick another model name from the provider's model list in Model settings."
            )
    return None


# Models (per provider) that rejected the enable_thinking switch; they are
# called without it from then on.
_no_thinking_switch: set[tuple[str, str]] = set()


def _thinking_extra(resolved_llm: dict | None, model: str | None = None) -> dict:
    """Extra request fields that switch a model's "thinking" off.

    Hybrid models on SiliconFlow (Qwen3 / Qwen3.5 and similar) think before
    every reply by default. A PhenoMAP Chat turn makes several model calls
    (two classification steps, tool calling, the final answer), so with
    thinking on a single turn often ran past the time limit. With it off,
    these models answer directly, like an ordinary instruct model of the
    same size. Models without the switch reject it with a 400 and are then
    called normally (and remembered in _no_thinking_switch)."""
    if not resolved_llm or resolved_llm.get("provider") != "siliconflow":
        return {}
    model = model or resolved_llm.get("model", "")
    if ("siliconflow", model) in _no_thinking_switch:
        return {}
    return {"extra_body": {"enable_thinking": False}}


async def _stream_chunks(llm_client, resolved_llm: dict, kwargs: dict):
    """Streaming counterpart of _completion's thinking switch: try with
    thinking off, and if the model rejects the switch before sending
    anything, remember that and stream again without it."""
    extra = _thinking_extra(resolved_llm, kwargs.get("model"))
    if extra:
        got_any = False
        try:
            async for chunk in _iterate_in_thread(lambda: llm_client.chat.completions.create(**kwargs, **extra)):
                got_any = True
                yield chunk
            return
        except BadRequestError:
            if got_any:
                raise
            _no_thinking_switch.add(("siliconflow", kwargs.get("model", "")))
    async for chunk in _iterate_in_thread(lambda: llm_client.chat.completions.create(**kwargs)):
        yield chunk


def _completion(
    client,
    model,
    messages,
    use_tools=True,
    temperature=0.2,
    resolved_llm: dict | None = None,
    tool_schemas: list | None = None,
    no_thinking: bool = True,
):
    # temperature=0 for every strict-JSON-emitting call (native mode's own
    # tool_calls step, and both classification stages) -- format reliability matters more than lexical variety when
    # the output has to parse cleanly, and a lower temperature measurably
    # cuts down how often _extract_json_object's fallback parsers have to
    # kick in. The final natural-language reply (no tools left to call) is
    # the one place a little warmth is worth keeping, so callers can still
    # pass 0.2 there.
    #
    # tool_schemas lets a caller pick which tool set this particular call can
    # choose from (PhenoMAP's graph tools vs. the single get_product_info
    # tool -- see _run_execution_native) instead of always defaulting to the
    # graph tools; only native tool-calling call sites pass this.
    kwargs = {"model": model, "messages": messages, "temperature": temperature}
    if use_tools:
        kwargs["tools"] = tool_schemas if tool_schemas is not None else TOOL_SCHEMAS
        kwargs["tool_choice"] = "auto"
    # Thinking is switched off for every SiliconFlow call (see _thinking_extra).
    extra = _thinking_extra(resolved_llm, model) if no_thinking else {}
    if extra:
        try:
            return client.chat.completions.create(**kwargs, **extra)
        except BadRequestError:
            _no_thinking_switch.add((resolved_llm["provider"], model))
        except APIConnectionError:
            pass  # handled by the normal call below
    try:
        return client.chat.completions.create(**kwargs)
    except APIConnectionError as e:
        # The openai SDK collapses every network-level failure (refused,
        # unreachable, DNS, TLS handshake, ...) into the same generic
        # "Connection error." with no indication of *what* it tried to
        # reach. Re-raise with the resolved provider/base_url attached so
        # the surfaced error is self-diagnosing instead.
        if resolved_llm:
            where = f"{resolved_llm.get('provider_label')} at {resolved_llm.get('base_url')}"
        else:
            where = "the configured LLM endpoint"
        raise RuntimeError(
            f"could not reach {where} -- is that server running and reachable from chat-service? ({e})"
        ) from e


def _provider_payload(resolved_llm: dict) -> dict:
    return {
        "provider": resolved_llm["provider"],
        "label": resolved_llm["provider_label"],
        "model": resolved_llm["model"],
    }


def _history_messages(history: list[dict]) -> list[dict]:
    messages = []
    for turn in history or []:
        role = turn.get("role")
        content = turn.get("content", "")
        if role in ("user", "assistant") and content:
            messages.append({"role": role, "content": content})
    return messages


def _ensure_primary_citations(reply: str, tool_trace: list, citations: dict) -> str:
    """Code-level backstop for a failure mode prompt instructions alone
    haven't reliably prevented: the model answers "where does entity X
    appear" using the real, retrieved neighbor data, but never actually
    wraps X's own Lab_ID in a {{...}} token anywhere in the reply -- so the
    frontend has nothing to turn into a link, even though `citations` (and
    the Evidence panel) show dozens of entries.

    This only ever appends a citation for the *exact* entity a get_node_detail
    call in this turn was about -- never a guess at which entity a plain-text
    mention refers to. That's deliberate: run_enrichment's top rows can share
    an identical title with different module_id values, so there is no safe
    way to infer intent from name matching alone; get_node_detail's own
    queried lab_id has no such ambiguity.

    Requires the entity's own NAME to already appear somewhere in the reply
    text, not just "this turn called get_node_detail on it and didn't cite
    it" -- those are very different situations. A question like "which of
    AML's 57 modules are high-confidence" legitimately calls get_node_detail
    on dozens of candidate modules just to read each one's confidence_label,
    then correctly leaves most of them out of the final answer once they
    don't qualify -- their names never appear in the reply at all, because
    they were checked and filtered out, not mentioned-and-forgotten. Without
    this check, every one of those correctly-excluded candidates used to get
    backstop-appended as a "PhenoMAP profile" line anyway, silently
    contradicting the answer's own stated list with a wall of modules it had
    just said were NOT part of it. Checking the name is present narrows this
    back down to the original, real failure mode: the model wrote about an
    entity in prose but dropped the {{...}} wrapper around it.
    """
    seen: set[str] = set()
    missing: list[tuple[str, str]] = []
    reply_lower = (reply or "").lower()
    for step in tool_trace:
        if step.get("tool") != "get_node_detail":
            continue
        lab_id = (step.get("args") or {}).get("lab_id")
        if not lab_id or lab_id in seen:
            continue
        seen.add(lab_id)
        if lab_id not in citations:
            continue
        if ("{{" + lab_id + "}}") in reply:
            continue
        name = citations[lab_id].get("name") or lab_id
        if name.lower() not in reply_lower:
            continue
        missing.append((lab_id, name))

    if not missing:
        return reply
    lines = "\n".join(f"PhenoMAP profile: {name} {{{{{lab_id}}}}}" for lab_id, name in missing)
    return (reply or "").rstrip() + "\n\n" + lines


def _annotate_search_trace(trace_entry: dict, tool_name: str, result: dict) -> None:
    """Attaches a small results summary to search_entities trace entries only
    (results_count, and up to 5 {lab_id, title, label} entries) so
    _detect_unconfirmed_alias_resolution below can tell, after the fact,
    which searches in this turn came up empty and which later search (if
    any) actually resolved the entity -- without having to re-run or
    re-fetch anything. Also makes the Evidence panel a bit more informative
    than name/args alone."""
    if tool_name != "search_entities" or not isinstance(result, dict):
        return
    results = result.get("results") or []
    trace_entry["results_count"] = len(results)
    trace_entry["result_names"] = [
        {"lab_id": r.get("lab_id"), "title": r.get("title"), "label": r.get("label")}
        for r in results[:5]
        if r.get("lab_id")
    ]


def _query_appears_in_user_message(query: str, user_message: str) -> bool:
    query = (query or "").strip().lower()
    user_message = (user_message or "").lower()
    return bool(query and query in user_message)


def _detect_unconfirmed_alias_resolution(tool_trace: list, user_message: str = "") -> dict | None:
    """Finds the exact failure pattern observed twice in testing: the model
    searches the user's own wording, gets zero results, then -- in the same
    turn, without ever telling the user the original term wasn't found --
    quietly retries with a different spelling/name for the same entity type,
    gets real results, and proceeds straight to analyzing them. Checks for
    the pattern in code instead of trusting the model noticed it should
    pause, since prompt instructions alone haven't reliably produced that
    behavior.

    Returns {"original_query", "resolved_query", "label", "candidates"} for
    the first label where this pattern is found, or None if no turn-level
    search_entities calls show it.
    """
    steps_by_label: dict[str, list[dict]] = {}
    for step in tool_trace:
        if step.get("tool") != "search_entities" or step.get("results_count") is None:
            continue
        label = (step.get("args") or {}).get("label") or "_any"
        steps_by_label.setdefault(label, []).append(step)

    for steps in steps_by_label.values():
        failed_query = None
        for step in steps:
            query = ((step.get("args") or {}).get("query") or "").strip()
            count = step["results_count"]
            if count == 0:
                if failed_query is None:
                    failed_query = query
                continue
            if failed_query is not None and query.lower() != failed_query.lower():
                # Avoid false positives for questions that contain two
                # distinct same-label entities, where entity A fails and
                # entity B succeeds. If the successful query was already
                # present in the user's wording, it is probably a separate
                # target entity rather than a correction/alias for the failed
                # one, so do not force an alias-confirmation turn.
                if _query_appears_in_user_message(query, user_message):
                    continue
                return {
                    "original_query": failed_query,
                    "resolved_query": query,
                    "label": (step.get("args") or {}).get("label") or "",
                    "candidates": step.get("result_names") or [],
                }
    return None


def _template_alias_confirmation(original: str, candidates: list[dict]) -> str:
    """Deterministic fallback wording, used only if the dedicated LLM call in
    _generate_alias_confirmation errors out -- the confirmation gate itself
    must never silently fail open just because the phrasing call failed."""
    lines = "\n".join(f"- {c.get('title') or c.get('lab_id')} {{{{{c.get('lab_id')}}}}}" for c in candidates)
    return (
        f'I could not find "{original}" exactly in PhenoMAP. Did you mean one of these?\n\n'
        f"{lines}\n\nLet me know which one you meant (or confirm if there's just one) and I'll "
        "continue with the analysis."
    )


def _generate_alias_confirmation(llm_client, resolved_llm: dict, user_message: str, pattern: dict) -> str:
    """Asks the model itself to phrase the confirmation question, instead of
    inserting a canned English template. The *gate* (whether a confirmation
    happens at all, and that it happens before any further analysis) is still
    guaranteed by code -- _enforce_alias_confirmation only calls this once
    the tool_trace pattern is already detected -- but the actual wording is
    generated fresh so it reads naturally, matches the user's language, and
    can reference the specific term/candidates instead of a rigid template.

    This is a separate, narrow-purpose completion (no tools, one small job)
    rather than trusting the same in-flow completion that just skipped the
    confirmation -- a dedicated call with nothing else to do is far more
    reliable at doing that one thing than a rule buried among many others in
    a long multi-step system prompt.
    """
    original = pattern["original_query"]
    candidates = pattern["candidates"]
    candidate_lines = "\n".join(
        f'- name: "{c.get("title") or c.get("lab_id")}", cite exactly as {{{{{c.get("lab_id")}}}}}'
        for c in candidates
    )
    prompt = (
        "You are drafting one short message for a PhenoMAP Chat user. Their message (below) used "
        f'the term "{original}", but a PhenoMAP database search for that exact term found nothing. '
        "A follow-up search using a different spelling, abbreviation, or synonym found these possible "
        f"matches instead:\n{candidate_lines}\n\n"
        "Write a short reply, in the same language as the user's message, that: tells them "
        f'"{original}" was not found in PhenoMAP exactly; names the candidate(s) found and cites each '
        "one using its exact {{LAB_ID}} token as given above (do not invent a different citation "
        "format); asks them to confirm which one (if any) they meant. Do not include any further "
        "biological analysis, PhenoMAP data, or explanation beyond identifying the candidates -- that "
        "will come after they confirm. Output only the message itself, nothing else.\n\n"
        f'User\'s message: "{user_message}"\n\n{_language_directive(user_message)}'
    )
    try:
        response = _completion(
            llm_client,
            resolved_llm["model"],
            [{"role": "user", "content": prompt}],
            use_tools=False,
            temperature=0.3,
            resolved_llm=resolved_llm,
        )
        text = (response.choices[0].message.content or "").strip()
        if text:
            return text
    except Exception:
        pass
    return _template_alias_confirmation(original, candidates)


def _build_pending_resolution(pattern: dict, user_message: str) -> dict:
    return {
        "type": "alias_confirmation",
        "original_user_message": user_message,
        "original_query": pattern.get("original_query") or "",
        "resolved_query": pattern.get("resolved_query") or "",
        "label": pattern.get("label") or "",
        "candidates": pattern.get("candidates") or [],
    }


def _enforce_alias_confirmation(
    reply: str, tool_trace: list, llm_client, resolved_llm: dict, user_message: str
) -> tuple[str, dict | None]:
    """Code-level override, not just a nudge: if _detect_unconfirmed_alias_
    resolution finds the silent-substitution pattern, replace the reply with
    a freshly-generated confirmation question instead of letting an
    unconfirmed guess's analysis reach the user. This is deliberately stricter
    than checking whether the model mentioned the original term: a reply can
    acknowledge the swap and still continue into downstream analysis without
    user consent, which is exactly the behavior this gate is meant to prevent."""
    pattern = _detect_unconfirmed_alias_resolution(tool_trace, user_message)
    if not pattern:
        return reply, None
    original = pattern["original_query"]
    candidates = pattern["candidates"]
    if not original or not candidates:
        return reply, None
    return _generate_alias_confirmation(llm_client, resolved_llm, user_message, pattern), _build_pending_resolution(
        pattern, user_message
    )


def _latest_pending_resolution(history: list[dict]) -> dict | None:
    for turn in reversed(history or []):
        pending = turn.get("pending_resolution")
        if isinstance(pending, dict) and pending.get("type") == "alias_confirmation":
            return pending
    return None


_CONFIRM_RE = re.compile(r"^\s*(yes|yeah|yep|correct|right|confirm|confirmed|是|是的|对|对的|正确|没错|确认)\s*[.!。！]*\s*$", re.I)
_REJECT_RE = re.compile(r"^\s*(no|nope|not really|不是|不对|否|不是的)\s*[.!。！]*\s*$", re.I)


def _looks_cjk(text: str) -> bool:
    return bool(re.search(r"[㐀-鿿]", text or ""))


def _language_directive(user_message: str) -> str:
    """Explicit, code-computed reply-language instruction, appended (not
    baked into the static prompt text) to every system prompt that produces
    user-facing text: relevance classification's own off_topic reply,
    product/phenomap_question execution's final answer, and the alias-
    confirmation phrasing calls.

    Added after observing an English question ("who is the 1st author") get
    answered in Chinese despite RELEVANCE_PROMPT already saying "reply in
    the same language the user used". The likely cause: RELEVANCE_PROMPT
    itself contains literal Chinese tokens (是/对/确认/... , used so the
    classifier can recognize confirmation replies in either language) sitting
    right next to that instruction -- for a weaker/quantized model, seeing
    Chinese characters in its own context window can bias its output
    language even though those characters were meant as pattern examples,
    not a cue about what language to answer in. Computing the target
    language deterministically in code (via _looks_cjk, already used
    elsewhere for the same purpose) and stating it as a plain fact right
    before generation, instead of trusting a single instruction buried
    earlier in a long prompt to be followed reliably, mirrors the same
    "don't make the model infer what code can just tell it" principle as
    _status_for_tool_call and the citations dict.

    Deliberately binary (Chinese vs. "not Chinese") rather than a full
    language identifier: CJK detection is the one case this codebase has
    concrete evidence of a language-mixing failure for, and a wrong
    "detected language" fed to the model as a stated fact would be worse
    than not stating one -- for any other language the model is left to its
    own (already-instructed) judgment."""
    if _looks_cjk(user_message):
        return (
            "Reply-language instruction (this overrides anything else in this prompt): the "
            "user's latest message is in Chinese. Write your ENTIRE reply in Chinese, no matter "
            "what language the rest of this prompt, its instructions, or its examples are "
            "written in."
        )
    return (
        "Reply-language instruction (this overrides anything else in this prompt): the user's "
        "latest message is NOT in Chinese. Write your ENTIRE reply in that same language. Do "
        "not switch to Chinese just because other parts of this prompt contain Chinese text "
        "(e.g. confirmation-word examples like 是/对/确认) -- those are pattern examples only, "
        "never a cue for your own output language."
    )


def _select_pending_candidate(user_message: str, pending: dict) -> dict | None:
    candidates = pending.get("candidates") or []
    if not candidates:
        return None
    text = (user_message or "").strip().lower()
    for candidate in candidates:
        lab_id = (candidate.get("lab_id") or "").lower()
        title = (candidate.get("title") or "").lower()
        if lab_id and lab_id in text:
            return candidate
        if title and title in text:
            return candidate
    ordinal_map = {
        "first": 0,
        "1": 0,
        "one": 0,
        "第一个": 0,
        "第一": 0,
        "second": 1,
        "2": 1,
        "two": 1,
        "第二个": 1,
        "第二": 1,
        "third": 2,
        "3": 2,
        "three": 2,
        "第三个": 2,
        "第三": 2,
    }
    for marker, idx in ordinal_map.items():
        if marker in text and idx < len(candidates):
            return candidates[idx]
    if len(candidates) == 1 and _CONFIRM_RE.match(user_message or ""):
        return candidates[0]
    return None


def _pending_citations(pending: dict) -> dict:
    citations = {}
    for c in pending.get("candidates") or []:
        lab_id = c.get("lab_id")
        if lab_id:
            citations[lab_id] = {"label": c.get("label") or pending.get("label") or "", "name": c.get("title") or lab_id}
    return citations


def _direct_pending_reply(user_message: str, pending: dict, resolved_llm: dict) -> dict | None:
    candidates = pending.get("candidates") or []
    if not candidates:
        return None
    if _REJECT_RE.match(user_message or ""):
        reply = (
            "没关系。请发送更正后的名称、同义词，或 PhenoMAP/HMDB/KEGG ID，我会重新检索。"
            if _looks_cjk(user_message)
            else "No problem. Please send the corrected name, synonym, or PhenoMAP/HMDB/KEGG ID, and I will search again."
        )
        return {
            "reply": reply,
            "citations": {},
            "tool_calls": [],
            "provider": _provider_payload(resolved_llm),
            "tool_mode": "pending_resolution",
        }
    if len(candidates) > 1 and _CONFIRM_RE.match(user_message or ""):
        lines = "\n".join(f"- {c.get('title') or c.get('lab_id')} {{{{{c.get('lab_id')}}}}}" for c in candidates)
        reply = (
            f"我找到了多个可能的匹配项。请先选择其中一个，我再继续分析：\n\n{lines}"
            if _looks_cjk(user_message)
            else f"I found multiple possible matches. Please choose one of these so I can continue:\n\n{lines}"
        )
        return {
            "reply": reply,
            "citations": _pending_citations(pending),
            "tool_calls": [],
            "provider": _provider_payload(resolved_llm),
            "tool_mode": "pending_resolution",
            "pending_resolution": pending,
        }
    return None


def _rewrite_confirmed_resolution_message(user_message: str, history: list[dict]) -> tuple[str, dict | None]:
    pending = _latest_pending_resolution(history)
    if not pending:
        return user_message, None
    candidate = _select_pending_candidate(user_message, pending)
    if not candidate:
        return user_message, pending
    label = candidate.get("label") or pending.get("label") or ""
    title = candidate.get("title") or candidate.get("lab_id")
    lab_id = candidate.get("lab_id")
    rewritten = (
        "The user has confirmed a pending PhenoMAP entity resolution from the previous assistant turn.\n"
        f'Original user request: "{pending.get("original_user_message") or ""}"\n'
        f'Original searched term that was not found exactly: "{pending.get("original_query") or ""}"\n'
        f'Confirmed PhenoMAP entity: "{title}" with label "{label}" and Lab_ID "{lab_id}".\n'
        "Continue answering the original user request using this confirmed entity. Do not ask the same "
        "confirmation again. Retrieve any needed PhenoMAP facts with tools using the confirmed label and Lab_ID."
    )
    return rewritten, None


def _finalize(
    reply: str,
    citations: dict,
    tool_trace: list,
    resolved_llm: dict,
    tool_mode: str,
    llm_client=None,
    user_message: str = "",
) -> dict:
    reply, pending_resolution = _enforce_alias_confirmation(reply, tool_trace, llm_client, resolved_llm, user_message)
    return {
        "reply": _ensure_primary_citations(reply, tool_trace, citations),
        "citations": citations,
        "tool_calls": tool_trace,
        "provider": _provider_payload(resolved_llm),
        "tool_mode": tool_mode,
        **({"pending_resolution": pending_resolution} if pending_resolution else {}),
    }


def _extract_json_object(text: str) -> dict:
    text = (text or "").strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    fenced = re.search(r"```(?:json)?\s*(\{[\s\S]*?\})\s*```", text)
    if fenced:
        try:
            return json.loads(fenced.group(1))
        except json.JSONDecodeError:
            pass

    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and end > start:
        try:
            return json.loads(text[start : end + 1])
        except json.JSONDecodeError:
            pass
    return {"final": text}


async def _run_manual_tool(http_client, citations, name: str, args: dict, tool_funcs: dict):
    func = tool_funcs.get(name)
    if func is None:
        return {"error": f"unknown tool: {name}"}, args
    try:
        result = await func(http_client, citations, **(args or {}))
    except BackendError as e:
        result = {"error": str(e)}
    except TypeError as e:
        result = {"error": f"invalid arguments for {name}: {e}"}
    return result, args or {}


def _status_for_tool_call(name: str, args: dict) -> str:
    """Human-readable one-liner shown in the UI while a tool call runs, in
    place of the previous static 3-dot spinner. Falls back to a generic
    "Calling X..." for any tool this doesn't have specific phrasing for, so a
    new tool added later never ends up with no status text at all."""
    args = args or {}
    if name == "search_entities":
        query = args.get("query") or ""
        label = args.get("label")
        suffix = f" ({label})" if label else ""
        return f'Searching PhenoMAP for "{query}"{suffix}...'
    if name == "get_node_detail":
        label = args.get("label") or "entity"
        lab_id = args.get("lab_id") or "?"
        return f"Looking up {label} details ({lab_id})..."
    if name == "find_path":
        return (
            f"Checking the connection between {args.get('from_label', '?')} {args.get('from_id', '?')} "
            f"and {args.get('to_label', '?')} {args.get('to_id', '?')}..."
        )
    if name == "run_enrichment":
        return "Running module enrichment analysis..."
    if name == "get_product_info":
        return "Looking up PhenoMAP's product information..."
    return f"Calling {name}..."


_HMDB_ID_RE = re.compile(r"\bHMDB\d+\b", re.I)
_KEGG_ID_RE = re.compile(r"(?<![A-Z0-9])C\d{5}(?![A-Z0-9])", re.I)
_PME_ID_RE = re.compile(r"\bPME\d+\b", re.I)
_INCHI_ID_RE = re.compile(r"\bInChI=[^\s,;]+", re.I)


def _unique_preserve_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        key = value.upper()
        if key in seen:
            continue
        seen.add(key)
        out.append(value)
    return out


def _explicit_enrichment_args(user_message: str, classification: dict) -> dict | None:
    """Direct-ID enrichment fast path.

    The normal tool-calling prompt is still responsible for name resolution
    and nuanced follow-ups. This deliberately narrow path only catches the
    common website-chat command shape: "Run enrichment for HMDB...". Exact
    IDs need no entity search or pre-run confirmation, and accepting a model
    final answer without a run_enrichment call is worse than being a little
    procedural here.
    """
    message = user_message or ""
    intent = classification.get("intent")
    if intent != "enrichment" and not re.search(r"\benrich(?:ment|ed|ing)?\b", message, re.I):
        return None

    candidates = [
        ("hmdb", [m.group(0).upper() for m in _HMDB_ID_RE.finditer(message)]),
        ("kegg", [m.group(0).upper() for m in _KEGG_ID_RE.finditer(message)]),
        ("lab_id", [m.group(0).upper() for m in _PME_ID_RE.finditer(message)]),
        ("inchi", [m.group(0) for m in _INCHI_ID_RE.finditer(message)]),
    ]
    present = [(id_type, _unique_preserve_order(ids)) for id_type, ids in candidates if ids]
    if len(present) != 1:
        return None

    id_type, ids = present[0]
    args: dict = {"ids": ids, "id_type": id_type, "fdr_cutoff": 0.05, "min_overlap": 2}

    fdr = re.search(r"\bfdr\b[^0-9]{0,12}([0-9]*\.?[0-9]+)", message, re.I)
    if fdr:
        try:
            args["fdr_cutoff"] = float(fdr.group(1))
        except ValueError:
            pass

    min_overlap = re.search(r"\bmin(?:imum)?[_\s-]*overlap\b[^0-9]{0,12}(\d+)", message, re.I)
    if min_overlap:
        try:
            args["min_overlap"] = int(min_overlap.group(1))
        except ValueError:
            pass

    return args


def _wants_chinese_reply(user_message: str) -> bool:
    return bool(re.search(r"[\u4e00-\u9fff]", user_message or ""))


def _format_direct_enrichment_reply(result: dict, args: dict, user_message: str) -> str:
    ids = args.get("ids") or []
    id_type = args.get("id_type") or "hmdb"
    fdr_cutoff = args.get("fdr_cutoff", 0.05)
    min_overlap = args.get("min_overlap", 2)
    matched = result.get("matched_input_n")
    sig_count = result.get("significant_module_count")
    top_rows = result.get("top_significant_modules") or []

    if result.get("error"):
        if _wants_chinese_reply(user_message):
            return f"我尝试运行 module enrichment，但工具返回错误：{result['error']}"
        return f"I tried to run module enrichment, but the tool returned an error: {result['error']}"

    if result.get("warning"):
        if _wants_chinese_reply(user_message):
            return f"我运行了 module enrichment，但输入 ID 没有匹配到 PhenoMAP metabolite：{result['warning']}"
        return f"I ran module enrichment, but the input IDs did not match PhenoMAP metabolites: {result['warning']}"

    def row_line(row: dict, idx: int) -> str:
        title = row.get("title") or row.get("module_id") or "Untitled module"
        module_id = row.get("module_id")
        cited_title = f"{title} {{{{{module_id}}}}}" if module_id else title
        return (
            f"{idx}. {cited_title}: overlap={row.get('overlap_n')}, "
            f"enrichment_ratio={row.get('enrichment_ratio')}, FDR={row.get('fdr')}"
        )

    if _wants_chinese_reply(user_message):
        header = (
            f"已运行 module enrichment：输入 {len(ids)} 个 {id_type.upper()} ID，"
            f"匹配到 {matched} 个 metabolite；参数为 FDR cutoff={fdr_cutoff}, "
            f"min_overlap={min_overlap}。"
        )
        if not top_rows:
            return f"{header}\n\n在这些参数下没有找到显著富集的 module。"
        lines = "\n".join(row_line(row, i + 1) for i, row in enumerate(top_rows[:10]))
        return f"{header}\n\n找到 {sig_count} 个显著富集 module。Top results:\n{lines}"

    header = (
        f"I ran module enrichment for {len(ids)} {id_type.upper()} IDs; "
        f"{matched} matched PhenoMAP metabolites. Parameters: "
        f"fdr_cutoff={fdr_cutoff}, min_overlap={min_overlap}."
    )
    if not top_rows:
        return f"{header}\n\nNo significantly enriched modules were found with these settings."
    lines = "\n".join(row_line(row, i + 1) for i, row in enumerate(top_rows[:10]))
    return f"{header}\n\nFound {sig_count} significantly enriched modules. Top results:\n{lines}"


async def _run_direct_enrichment(
    resolved_llm: dict,
    user_message: str,
    tool_funcs: dict,
    args: dict,
):
    citations: dict = {}
    tool_trace: list = []
    async with httpx.AsyncClient() as http_client:
        yield {"type": "status", "text": _status_for_tool_call("run_enrichment", args)}
        result, clean_args = await _run_manual_tool(http_client, citations, "run_enrichment", args, tool_funcs)
    tool_trace.append({"tool": "run_enrichment", "args": clean_args})
    reply = _format_direct_enrichment_reply(result, clean_args, user_message)
    yield {
        "type": "final",
        "reply": reply,
        "citations": citations,
        "tool_calls": tool_trace,
        "provider": _provider_payload(resolved_llm),
        "tool_mode": "direct_enrichment",
    }


# ---------------------------------------------------------------------------
# Stage 1: relevance classification (product/greeting/off-topic vs a real
# PhenoMAP content question). No tools called here -- "product" is now
# handed to stage 3 (its own tool + execution prompt) exactly like
# "phenomap_question" is; only "off_topic" is still answered right here.
# ---------------------------------------------------------------------------

_VALID_RELEVANCE_CATEGORIES = {"product", "off_topic", "phenomap_question"}


def _classify_relevance(llm_client, resolved_llm: dict, user_message: str, history: list[dict]) -> dict:
    system_content = RELEVANCE_PROMPT + "\n\n" + _language_directive(user_message)
    messages = [{"role": "system", "content": system_content}]
    messages.extend(_history_messages(history))
    messages.append({"role": "user", "content": user_message})
    response = _completion(
        llm_client,
        resolved_llm["model"],
        messages,
        use_tools=False,
        temperature=0,
        resolved_llm=resolved_llm,
        no_thinking=True,
    )
    parsed = _extract_json_object(response.choices[0].message.content or "")
    category = parsed.get("category") or "phenomap_question"
    if category not in _VALID_RELEVANCE_CATEGORIES:
        # Fail open toward treating it as a real question rather than
        # silently declining something that might be legitimate -- an
        # unparseable classification is a formatting failure, not evidence
        # the question is off-topic.
        category = "phenomap_question"
    return {"category": category, "reply": parsed.get("reply") or ""}


# ---------------------------------------------------------------------------
# Stage 2: intent classification + entity extraction. Still no tools -- this
# is planning, handed to stage 3 as a hint.
# ---------------------------------------------------------------------------

_VALID_INTENTS = {"lookup", "profile", "association", "connection", "enrichment", "mixed_anchored"}

# Shown in the UI right after stage 2 resolves, so the user sees a status
# line that already reflects what kind of question this turned out to be
# instead of a generic "thinking".
_STATUS_BY_INTENT = {
    "lookup": "Looking this up in PhenoMAP...",
    "profile": "Pulling up this entity's PhenoMAP profile...",
    "association": "Checking PhenoMAP's recorded associations...",
    "connection": "Checking how these are connected in PhenoMAP...",
    "enrichment": "Running a PhenoMAP module enrichment analysis...",
    "mixed_anchored": "Resolving the right module for this phenotype...",
}


def _classify_intent(llm_client, resolved_llm: dict, user_message: str, history: list[dict]) -> dict:
    messages = [{"role": "system", "content": INTENT_PROMPT}]
    messages.extend(_history_messages(history))
    messages.append({"role": "user", "content": user_message})
    response = _completion(
        llm_client,
        resolved_llm["model"],
        messages,
        use_tools=False,
        temperature=0,
        resolved_llm=resolved_llm,
        no_thinking=True,
    )
    parsed = _extract_json_object(response.choices[0].message.content or "")
    intent = parsed.get("intent") or "profile"
    if intent not in _VALID_INTENTS:
        intent = "profile"
    entities = parsed.get("entities")
    if not isinstance(entities, list):
        entities = []
    return {
        "intent": intent,
        "entities": entities,
        "resumed_confirmation": bool(parsed.get("resumed_confirmation")),
        "notes": parsed.get("notes") or "",
    }


def _format_execution_prompt(classification: dict) -> str:
    entities = classification.get("entities") or []
    entity_bits = []
    for e in entities:
        if not isinstance(e, dict):
            continue
        text = e.get("text") or "?"
        hint = e.get("hint_label")
        entity_bits.append(f"{text} ({hint})" if hint else text)
    entities_text = ", ".join(entity_bits) or "none explicitly listed"
    resumed_note = (
        " (this continues a confirmed entity resolution from a previous turn)"
        if classification.get("resumed_confirmation")
        else ""
    )
    return EXECUTION_PROMPT_TEMPLATE.format(
        intent=classification.get("intent", "profile"),
        entities=entities_text,
        resumed_note=resumed_note,
        notes=classification.get("notes") or "",
    )


# ---------------------------------------------------------------------------
# Stage 3: execution. The only stage that calls PhenoMAP tools. Each is an
# async generator yielding progress events and ending with exactly one
# {"type": "final", ...} event.
# ---------------------------------------------------------------------------


_STREAM_DONE = object()


async def _iterate_in_thread(make_stream):
    """Async-iterates a *synchronous* OpenAI stream without blocking the
    event loop. chat-service runs as a single uvicorn process, and the
    OpenAI client used here is the blocking one: calling it directly inside
    an async function froze the whole service for the length of that LLM
    call, so a second user's chat (or even the health check) had to wait
    for the first one to finish. make_stream() (which opens the stream) and
    the iteration over it both run in a worker thread; chunks are handed
    back to the event loop through a queue. Exceptions raised in the thread
    (e.g. APIConnectionError) are re-raised here, at the await site."""
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()
    stop = threading.Event()

    def worker():
        try:
            stream = make_stream()
            for chunk in stream:
                if stop.is_set():
                    break
                loop.call_soon_threadsafe(queue.put_nowait, chunk)
        except BaseException as e:  # noqa: BLE001 -- forwarded to the consumer
            loop.call_soon_threadsafe(queue.put_nowait, e)
        finally:
            loop.call_soon_threadsafe(queue.put_nowait, _STREAM_DONE)

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    try:
        while True:
            item = await queue.get()
            if item is _STREAM_DONE:
                return
            if isinstance(item, BaseException):
                raise item
            yield item
    finally:
        # Consumer stopped early (client disconnected, error downstream):
        # tell the worker to stop pulling more chunks.
        stop.set()


async def _stream_completion(llm_client, resolved_llm: dict, messages: list[dict], *, use_tools: bool):
    """Runs one streaming chat completion. Yields {"type": "content", "text": ...} for
    each piece of natural-language text as it arrives, which is what lets
    the frontend show it typing out in real time instead of waiting for the
    whole answer, then exactly one {"type": "done", "content": ..., \
    "tool_calls": [...]} once the stream ends.

    Tool calls, if any, arrive across multiple chunks too (a call's
    arguments are streamed as small string fragments rather than delivered
    whole), keyed by an `index` identifying which tool call in this round
    each fragment belongs to -- this reconstructs them into whole {"id",
    "function": {"name", "arguments"}} dicts by index before yielding the
    terminal "done" event. use_tools=False (the exhausted-turns fallback)
    will always yield an empty tool_calls list back, since no tools param is
    sent in that case.
    """
    kwargs = {"model": resolved_llm["model"], "messages": messages, "temperature": 0, "stream": True}
    if use_tools:
        kwargs["tools"] = TOOL_SCHEMAS
        kwargs["tool_choice"] = "auto"

    def _connection_error(e):
        where = f"{resolved_llm.get('provider_label')} at {resolved_llm.get('base_url')}"
        return RuntimeError(
            f"could not reach {where} -- is that server running and reachable from chat-service? ({e})"
        )

    content_parts: list[str] = []
    tool_calls_acc: dict[int, dict] = {}
    try:
        async for chunk in _stream_chunks(llm_client, resolved_llm, kwargs):
            if not chunk.choices:
                continue
            delta = chunk.choices[0].delta
            if delta is None:
                continue
            if delta.content:
                content_parts.append(delta.content)
                yield {"type": "content", "text": delta.content}
            if delta.tool_calls:
                for tc_delta in delta.tool_calls:
                    entry = tool_calls_acc.setdefault(
                        tc_delta.index, {"id": "", "function": {"name": "", "arguments": ""}}
                    )
                    if tc_delta.id:
                        entry["id"] = tc_delta.id
                    if tc_delta.function:
                        if tc_delta.function.name:
                            entry["function"]["name"] += tc_delta.function.name
                        if tc_delta.function.arguments:
                            entry["function"]["arguments"] += tc_delta.function.arguments
    except APIConnectionError as e:
        raise _connection_error(e) from e

    ordered_tool_calls = [tool_calls_acc[i] for i in sorted(tool_calls_acc)]
    yield {"type": "done", "content": "".join(content_parts), "tool_calls": ordered_tool_calls}


async def _stream_alias_confirmation(llm_client, resolved_llm: dict, user_message: str, pattern: dict):
    """Streaming counterpart to _generate_alias_confirmation, used by the
    native-tool-calling execution path so a forced confirmation message
    types out the same way a normal streamed answer would, instead of
    appearing all at once after the fact. Yields {"type": "token", ...}
    chunks only; the caller accumulates them into the full message (see
    _stream_and_finalize_alias_confirmation). Falls back to the
    deterministic template -- yielded as a single chunk -- if the streaming
    call errors, mirroring _generate_alias_confirmation's own fallback: the
    confirmation gate must never silently fail open just because the
    phrasing call failed."""
    original = pattern["original_query"]
    candidates = pattern["candidates"]
    candidate_lines = "\n".join(
        f'- name: "{c.get("title") or c.get("lab_id")}", cite exactly as {{{{{c.get("lab_id")}}}}}'
        for c in candidates
    )
    prompt = (
        "You are drafting one short message for a PhenoMAP Chat user. Their message (below) used "
        f'the term "{original}", but a PhenoMAP database search for that exact term found nothing. '
        "A follow-up search using a different spelling, abbreviation, or synonym found these possible "
        f"matches instead:\n{candidate_lines}\n\n"
        "Write a short reply, in the same language as the user's message, that: tells them "
        f'"{original}" was not found in PhenoMAP exactly; names the candidate(s) found and cites each '
        "one using its exact {{LAB_ID}} token as given above (do not invent a different citation "
        "format); asks them to confirm which one (if any) they meant. Do not include any further "
        "biological analysis, PhenoMAP data, or explanation beyond identifying the candidates -- that "
        "will come after they confirm. Output only the message itself, nothing else.\n\n"
        f'User\'s message: "{user_message}"\n\n{_language_directive(user_message)}'
    )
    got_any = False
    try:
        stream = _stream_chunks(
            llm_client,
            resolved_llm,
            {
                "model": resolved_llm["model"],
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.3,
                "stream": True,
            },
        )
        async for chunk in stream:
            if not chunk.choices:
                continue
            delta = chunk.choices[0].delta
            if delta and delta.content:
                got_any = True
                yield {"type": "token", "text": delta.content}
    except Exception:
        got_any = False
    if not got_any:
        yield {"type": "token", "text": _template_alias_confirmation(original, candidates)}


async def _stream_and_finalize_alias_confirmation(
    llm_client, resolved_llm: dict, user_message: str, pattern: dict, tool_trace: list, citations: dict
):
    """Streams the confirmation message (see _stream_alias_confirmation),
    forwarding each token event as-is, then yields the terminal {"type":
    "final", ...} event once the message is complete. Factored out so both
    call sites in _run_execution_native (top of the tool loop, and the
    exhausted-turns fallback) share one implementation instead of repeating
    this assembly twice."""
    parts: list[str] = []
    async for event in _stream_alias_confirmation(llm_client, resolved_llm, user_message, pattern):
        parts.append(event["text"])
        yield event
    yield {
        "type": "final",
        "reply": "".join(parts),
        "citations": citations,
        "tool_calls": tool_trace,
        "provider": _provider_payload(resolved_llm),
        "tool_mode": "native_tool_calling",
        "pending_resolution": _build_pending_resolution(pattern, user_message),
    }


async def _stream_final_answer(
    llm_client, resolved_llm: dict, messages: list[dict], tool_trace: list, citations: dict
) -> str:
    """Streams the final natural-language answer with tools disabled.

    This is intentionally separate from the tool-selection completion. Some
    OpenAI-compatible servers technically accept stream=True together with
    tools/tool_choice, but still buffer the final natural-language content
    until the end. Once the model has stopped asking for tools, a plain
    no-tools writer call is the most reliable way to get real token streaming
    in the browser.
    """
    writer_messages = list(messages)
    writer_messages.append(
        {
            "role": "user",
            "content": (
                "Write the final answer now using only the PhenoMAP tool results already provided. "
                "Follow the evidence, citation, uncertainty, and language rules from the system prompt. "
                "Do not call tools and do not output JSON."
            ),
        }
    )
    done = None
    async for event in _stream_completion(llm_client, resolved_llm, writer_messages, use_tools=False):
        if event["type"] == "content":
            yield {"type": "token", "text": event["text"]}
        else:
            done = event
    raw_text = (done or {}).get("content") or ""
    final_text = _ensure_primary_citations(raw_text, tool_trace, citations)
    appended = final_text[len(raw_text) :]
    if appended:
        yield {"type": "token", "text": appended}
    return


async def _run_execution_native(
    llm_client,
    resolved_llm: dict,
    user_message: str,
    history: list[dict],
    system_prompt: str,
    tool_schemas: list,
    tool_funcs: dict,
):
    """Native tool-calling execution (openai/siliconflow).

    Generalized over `system_prompt`/`tool_schemas`/`tool_funcs` rather than
    hardcoded to PhenoMAP's graph tools: run_chat_stream calls this with
    EXECUTION_PROMPT_TEMPLATE + TOOL_SCHEMAS/TOOL_FUNCS for phenomap_question
    turns, or PRODUCT_EXECUTION_PROMPT + PRODUCT_TOOL_SCHEMAS/
    PRODUCT_TOOL_FUNCS for product turns, based on the relevance
    classification -- this function itself has no idea which one it's
    running and doesn't need to.

    Tool-selection calls use native OpenAI-compatible tools, but the final
    answer is streamed through a separate no-tools writer call. This matters
    in practice: several OpenAI-compatible providers buffer content when
    stream=True is combined with tools/tool_choice, so "streaming" still
    looks like a whole paragraph appearing at once. The writer split gives
    the frontend actual natural-language token events.

    The alias-confirmation gate (_detect_unconfirmed_alias_resolution) is
    checked at the *top* of each round, before that round's completion is
    requested at all. It only ever depends on tool_trace from rounds already
    completed, so checking it first means a round that would get overridden
    never reaches the final writer. It is a no-op for product runs: it only
    ever fires on a search_entities trace entry, which get_product_info
    (this stage's only possible tool here) never produces.
    """
    system_prompt = system_prompt + "\n\n" + _language_directive(user_message)
    messages = [{"role": "system", "content": system_prompt}]
    messages.extend(_history_messages(history))
    messages.append({"role": "user", "content": user_message})

    citations: dict = {}
    tool_trace: list = []

    async with httpx.AsyncClient() as http_client:
        for _ in range(MAX_TOOL_TURNS):
            pattern = _detect_unconfirmed_alias_resolution(tool_trace, user_message)
            if pattern:
                async for event in _stream_and_finalize_alias_confirmation(
                    llm_client, resolved_llm, user_message, pattern, tool_trace, citations
                ):
                    yield event
                return

            # Blocking OpenAI call -> worker thread, so other users' chats
            # keep running meanwhile (see _iterate_in_thread).
            response = await asyncio.to_thread(
                _completion,
                llm_client,
                resolved_llm["model"],
                messages,
                temperature=0,
                resolved_llm=resolved_llm,
                tool_schemas=tool_schemas,
            )
            msg = response.choices[0].message

            if not msg.tool_calls:
                parts: list[str] = []
                async for event in _stream_final_answer(llm_client, resolved_llm, messages, tool_trace, citations):
                    parts.append(event["text"])
                    yield event
                final_text = "".join(parts)
                yield {
                    "type": "final",
                    "reply": final_text,
                    "citations": citations,
                    "tool_calls": tool_trace,
                    "provider": _provider_payload(resolved_llm),
                    "tool_mode": "native_tool_calling",
                }
                return

            messages.append(
                {
                    "role": "assistant",
                    "content": msg.content or None,
                    "tool_calls": [
                        {
                            "id": tc.id,
                            "type": "function",
                            "function": {"name": tc.function.name, "arguments": tc.function.arguments},
                        }
                        for tc in msg.tool_calls
                    ],
                }
            )

            for tc in msg.tool_calls:
                try:
                    args_preview = json.loads(tc.function.arguments or "{}")
                except json.JSONDecodeError:
                    args_preview = {}
                yield {"type": "status", "text": _status_for_tool_call(tc.function.name, args_preview)}
                result, args = await _run_manual_tool(http_client, citations, tc.function.name, args_preview, tool_funcs)
                trace_entry = {"tool": tc.function.name, "args": args}
                _annotate_search_trace(trace_entry, tc.function.name, result)
                tool_trace.append(trace_entry)
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        # Cap tool output size fed back into context -- the
                        # individual tools already trim their own results
                        # (neighbor_limit, top_n, ...), this is just a hard
                        # backstop. Raised from 6000: measured against real
                        # PhenoMAP data, a single get_node_detail call on a
                        # well-connected Module with neighbor_limit=50 (its
                        # own properties plus a full neighbor list) already
                        # runs to roughly 10-11k characters even after
                        # tools.py's own field-level trimming -- 6000 wasn't
                        # a rare-case backstop, it was silently slicing
                        # through the middle of an ordinary result's raw JSON
                        # string, which can hand the model invalid/garbled
                        # JSON instead of a clean truncation. 12000 clears
                        # that measured worst case with headroom; this is
                        # still a real cap, not a removal of one.
                        "content": json.dumps(result, ensure_ascii=False)[:12000],
                    }
                )

    # Exhausted MAX_TOOL_TURNS without the model settling on a final answer
    # (e.g. it kept calling tools). Same gate check as above, then force one
    # last streamed completion with tools disabled so the user gets
    # *something* back instead of a dead end.
    pattern = _detect_unconfirmed_alias_resolution(tool_trace, user_message)
    if pattern:
        async for event in _stream_and_finalize_alias_confirmation(
            llm_client, resolved_llm, user_message, pattern, tool_trace, citations
        ):
            yield event
        return

    messages.append(
        {
            "role": "user",
            "content": (
                "Please give your best answer now based on what you've already found above, "
                "or say plainly that you couldn't find enough information in PhenoMAP."
            ),
        }
    )
    parts: list[str] = []
    async for event in _stream_final_answer(llm_client, resolved_llm, messages, tool_trace, citations):
        parts.append(event["text"])
        yield event
    final_text = "".join(parts)
    yield {
        "type": "final",
        "reply": final_text,
        "citations": citations,
        "tool_calls": tool_trace,
        "provider": _provider_payload(resolved_llm),
        "tool_mode": "native_tool_calling",
    }


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

# Used when a pending alias confirmation from the previous turn was just
# resolved by the user's reply (see _rewrite_confirmed_resolution_message):
# we already know this continues a real PhenoMAP question about a specific,
# now-confirmed entity, so stages 1 and 2 are skipped entirely rather than
# re-classifying something that's already been decided -- both for latency
# (2 fewer LLM calls on every confirmation turn) and because the rewritten
# message already states the confirmed entity and label explicitly, which a
# fresh classification pass has no way to improve on.
_RESUMED_CLASSIFICATION = {
    "intent": "profile",
    "entities": [],
    "resumed_confirmation": True,
    "notes": "Continuing after the user confirmed a previously ambiguous entity resolution.",
}

_STATUS_RELEVANCE = "Checking if this is a PhenoMAP question..."
_STATUS_INTENT = "Figuring out what this question needs..."
_STATUS_PRODUCT = "Looking up PhenoMAP's product information..."


async def run_chat_stream(user_message: str, history: list[dict], llm_config: dict | None = None):
    """The chat endpoint's entry point. An async generator yielding
    {"type": "status", "text": ...} progress events while working, and
    exactly one terminal event: {"type": "final", ...} (the same shape the
    old single-call run_chat used to return outright) or
    {"type": "error", "message": ...}. main.py streams each yielded event to
    the frontend as one NDJSON line, which is what lets the UI show short
    "thinking" hints instead of a static spinner."""
    try:
        resolved_llm = _resolve_llm(llm_config or {})
    except LLMConfigError as e:
        yield {"type": "error", "message": str(e)}
        return

    if resolved_llm["provider"] == "siliconflow":
        resolved_llm["base_url"] = await _siliconflow_base_url(resolved_llm["api_key"], resolved_llm["base_url"])
    llm_client = OpenAI(api_key=resolved_llm["api_key"], base_url=resolved_llm["base_url"])

    try:
        effective_user_message, pending_resolution = _rewrite_confirmed_resolution_message(user_message, history)
        if pending_resolution:
            direct = _direct_pending_reply(user_message, pending_resolution, resolved_llm)
            if direct:
                yield {"type": "final", **direct}
                return

        # system_prompt/tool_schemas/tool_funcs are what actually get handed
        # to stage 3 (_run_execution_native) below --
        # decided per branch here rather than passing a "classification"
        # dict through and having stage 3 re-derive which tool set applies.
        if effective_user_message != user_message:
            # Resumed alias confirmation only ever concerns PhenoMAP graph
            # entities (see _RESUMED_CLASSIFICATION's comment) -- always the
            # graph tools, never get_product_info.
            system_prompt = _format_execution_prompt(_RESUMED_CLASSIFICATION)
            tool_schemas, tool_funcs = TOOL_SCHEMAS, TOOL_FUNCS
        else:
            yield {"type": "status", "text": _STATUS_RELEVANCE}
            relevance = await asyncio.to_thread(
                _classify_relevance, llm_client, resolved_llm, effective_user_message, history
            )

            if relevance["category"] == "off_topic":
                # The only category still answered directly by stage 1 --
                # it needs no lookup of any kind, PhenoMAP or product, so
                # there is nothing for stage 3 to retrieve.
                yield {
                    "type": "final",
                    "reply": relevance["reply"] or "",
                    "citations": {},
                    "tool_calls": [],
                    "provider": _provider_payload(resolved_llm),
                    "tool_mode": "classified_off_topic",
                }
                return

            if relevance["category"] == "product":
                # No stage-2 equivalent: there's exactly one tool
                # (get_product_info) and one job, so there's nothing to plan
                # first the way PhenoMAP graph questions need an intent +
                # entities hint before execution.
                yield {"type": "status", "text": _STATUS_PRODUCT}
                system_prompt = PRODUCT_EXECUTION_PROMPT
                tool_schemas, tool_funcs = PRODUCT_TOOL_SCHEMAS, PRODUCT_TOOL_FUNCS
            else:
                yield {"type": "status", "text": _STATUS_INTENT}
                classification = await asyncio.to_thread(
                    _classify_intent, llm_client, resolved_llm, effective_user_message, history
                )
                yield {
                    "type": "status",
                    "text": _STATUS_BY_INTENT.get(classification["intent"], "Working on your PhenoMAP question..."),
                }
                direct_enrichment_args = _explicit_enrichment_args(effective_user_message, classification)
                if direct_enrichment_args:
                    async for event in _run_direct_enrichment(
                        resolved_llm, effective_user_message, TOOL_FUNCS, direct_enrichment_args
                    ):
                        yield event
                    return
                system_prompt = _format_execution_prompt(classification)
                tool_schemas, tool_funcs = TOOL_SCHEMAS, TOOL_FUNCS

        executor = _run_execution_native(
            llm_client, resolved_llm, effective_user_message, history, system_prompt, tool_schemas, tool_funcs
        )
        async for event in executor:
            yield event
    except RuntimeError as e:
        # _completion's re-raised connection errors surface here.
        yield {"type": "error", "message": str(e)}
    except Exception as e:  # noqa: BLE001 -- surface any unexpected failure as a terminal
        # stream event instead of an unhandled exception, since by the time
        # we're mid-stream the HTTP response has already started with a 200.
        friendly = _friendly_llm_error(e, resolved_llm)
        yield {"type": "error", "message": friendly or f"chat agent failed: {e}"}
