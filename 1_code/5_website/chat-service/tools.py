from __future__ import annotations

"""Tools the chat agent can call, as thin wrappers over the Go backend's own
public API (search / node / path / enrichment) -- see ../backend/handlers.go.

Design note: this service intentionally never talks to Neo4j or the R
plumber enrichment service directly. Every fact the LLM can surface goes
through the exact same endpoints the frontend itself calls, so "what
PhenoMAP knows" has one single source of truth and this service can't drift
from what a user browsing the site directly would see.

Each tool function takes a shared `citations` dict (mutated in place) and
records every Lab_ID it surfaces there as {lab_id: {"label", "name"}}. That
dict is how agent.py enforces the "never mention an ID you didn't just
retrieve" rule from prompts.py: only tokens present in `citations` get
rendered as links by the frontend, so an ID the model hallucinates instead
of retrieving simply won't resolve to anything.

get_product_info (below, in its own PRODUCT_TOOL_FUNCS/PRODUCT_TOOL_SCHEMAS,
kept separate from TOOL_FUNCS/TOOL_SCHEMAS) is the exception to "wraps the Go
backend": it answers questions about PhenoMAP Chat/PhenoMAP itself, not
PhenoMAP's graph data, so it reads product_facts.json instead. It exists so
that information is retrieved on demand -- only in the turns agent.py's
relevance stage actually classifies as a product question -- the same
"look it up only when needed" pattern as the graph tools below, instead of
being stuffed into every turn's prompt regardless of whether it's needed.
"""

import copy
import json
import time

import httpx

from config import BACKEND_URL, REQUEST_TIMEOUT, TOOL_CACHE_MAX_ENTRIES, TOOL_CACHE_TTL_SECONDS
from product_facts import load_facts as _load_product_facts

ALLOWED_LABELS = {"Study", "Phenotype", "Module", "Metabolite"}
_LABEL_HINT = "label must be one of Study, Phenotype, Module, Metabolite"


class BackendError(Exception):
    """Raised when the Go backend returns an error or is unreachable."""


# In-process cache for repeated identical backend calls -- see config.py's
# TOOL_CACHE_TTL_SECONDS for why this exists and why it's safe to key purely
# on the call itself (no session/conversation id involved). Keyed on
# (method, path, a stable JSON dump of params/body); values are
# (expires_at, response) so a stale entry is just skipped and overwritten
# rather than needing a separate cleanup pass. Deliberately process-global
# (module-level dict, not per-request) since the whole point is to make a
# repeat of the exact same call cheap regardless of which conversation or
# request asks for it.
_cache: dict[str, tuple[float, dict]] = {}


def _cache_key(method: str, path: str, payload: dict | None) -> str:
    # sort_keys makes the dump stable regardless of dict insertion order, so
    # semantically-identical params always produce the same key.
    return f"{method} {path} {json.dumps(payload or {}, sort_keys=True, default=str)}"


def _cache_get(key: str) -> dict | None:
    entry = _cache.get(key)
    if entry is None:
        return None
    expires_at, value = entry
    if time.monotonic() > expires_at:
        _cache.pop(key, None)
        return None
    # Deep-copy out: callers read tool results but this guards against any
    # caller ever mutating the dict in place, which would otherwise silently
    # corrupt the cached entry for every other caller that hits it later.
    return copy.deepcopy(value)


def _cache_set(key: str, value: dict) -> None:
    if len(_cache) >= TOOL_CACHE_MAX_ENTRIES:
        # Not a real LRU -- just bounds memory growth. This cache is about
        # avoiding a handful of duplicate calls within a short TTL, not
        # about serving as a real data store, so evicting an arbitrary
        # (insertion-order-oldest, in CPython) entry when full is fine.
        _cache.pop(next(iter(_cache)), None)
    # Deep-copy in too, not just out (_cache_get): the very first caller (the
    # one whose request was the actual cache miss) gets back this same
    # `value` object from _get/_post's `return data` below. Without copying
    # here, that caller mutating its own "fresh" result in place would
    # silently corrupt the cached entry for every later cache hit -- storing
    # an independent copy means the cache's own state can never be affected
    # by what any caller, past or future, does with the dict it was handed.
    _cache[key] = (time.monotonic() + TOOL_CACHE_TTL_SECONDS, copy.deepcopy(value))


async def _get(client: httpx.AsyncClient, path: str, params: dict | None = None) -> dict:
    key = _cache_key("GET", path, params)
    cached = _cache_get(key)
    if cached is not None:
        return cached
    try:
        resp = await client.get(f"{BACKEND_URL}{path}", params=params, timeout=REQUEST_TIMEOUT)
    except httpx.HTTPError as e:
        raise BackendError(f"could not reach backend at {BACKEND_URL} ({e})") from e
    if resp.status_code >= 400:
        raise BackendError(f"{path} returned {resp.status_code}: {resp.text[:500]}")
    data = resp.json()
    _cache_set(key, data)
    return data


async def _post(client: httpx.AsyncClient, path: str, json_body: dict) -> dict:
    key = _cache_key("POST", path, json_body)
    cached = _cache_get(key)
    if cached is not None:
        return cached
    try:
        resp = await client.post(f"{BACKEND_URL}{path}", json=json_body, timeout=REQUEST_TIMEOUT)
    except httpx.HTTPError as e:
        raise BackendError(f"could not reach backend at {BACKEND_URL} ({e})") from e
    if resp.status_code >= 400:
        raise BackendError(f"{path} returned {resp.status_code}: {resp.text[:500]}")
    data = resp.json()
    _cache_set(key, data)
    return data


def _remember(citations: dict, label: str | None, lab_id: str | None, name: str | None) -> None:
    if not lab_id:
        return
    citations[lab_id] = {"label": label or "", "name": name or lab_id}


async def search_entities(client, citations, query: str, label: str | None = None, limit: int = 10) -> dict:
    """Full-text / ID search across Study, Phenotype, Module, Metabolite.

    This is also the entity-resolution step: call this first to turn a name
    or phrase the user typed into a Lab_ID before using the other tools.
    """
    if label and label not in ALLOWED_LABELS:
        return {"error": f"unknown label '{label}'. {_LABEL_HINT}"}
    params = {"q": query, "page_size": min(max(int(limit), 1), 20)}
    if label:
        params["label"] = label
    data = await _get(client, "/api/search", params=params)
    results = data.get("results", []) or []
    for r in results:
        _remember(citations, r.get("label"), r.get("lab_id"), r.get("title"))
    payload = {
        "total_matches": data.get("total", 0),
        "results": [
            {
                "label": r.get("label"),
                "lab_id": r.get("lab_id"),
                "title": r.get("title"),
                "subtitle": r.get("subtitle"),
                "extra": r.get("extra"),
            }
            for r in results
        ],
    }
    if not results:
        # Code-level nudge attached to the failed call itself, not just a
        # rule sitting in the system prompt several thousand tokens back.
        # Observed failure: query "AML" for label=Phenotype returned nothing,
        # and the model gave up and told the user it wasn't found -- even
        # though the model's own reply separately spelled out "acute myeloid
        # leukemia," it never actually issued a second search_entities call
        # with that expansion. Prompt rule 2 already asks for a retry, but a
        # hint delivered right here, in the same tool result the model is
        # about to read, is much harder to skip than a rule from far earlier
        # in context -- same reasoning as run_enrichment's zero-match warning.
        payload["hint"] = (
            f"No PhenoMAP entities matched '{query}' exactly. Before telling the user "
            "this term is not in PhenoMAP, consider: could it be an abbreviation (e.g. "
            "a shortened disease name), a misspelling, or a synonym/alternate name "
            "PhenoMAP might store under a different, full name? If you can think of a "
            "plausible expansion or alternative spelling, call search_entities again "
            "with it now, in this same turn, before answering the user. Only tell the "
            "user the term could not be found after you've tried at least one plausible "
            "alternative and it also failed."
        )
    return payload


def _trim_text(v, max_len=1200):
    # max_len was 600 for a while, which sounded generous until actually
    # measured against real data: nodes_module.csv's functional_summary is
    # over 600 chars for every single module (median 888, max 1199) and
    # phenotype_relationship is over 600 for ~75% of modules -- so the old
    # cap wasn't a rare-case safety valve, it was silently cutting off the
    # main descriptive field on essentially every module lookup. 1200 covers
    # the true max of both fields (and the p99 of nodes_phenotype.csv's
    # OLS_Definition and nodes_study.csv's Study_Summary is still above this
    # -- a genuinely long study abstract can still get cut -- but that's a
    # real outlier now, not the default case).
    if isinstance(v, str) and len(v) > max_len:
        return v[:max_len] + " …[truncated]"
    return v


# Module nodes carry these as raw semicolon-joined ID/name-list properties
# (see 02_tidy_metabolite_module_relationship.R) -- the exact same
# core/supporting/contextual membership that get_node_detail already exposes
# properly, per-metabolite, with a `tier` field, via neighbors_sample's
# MEMBER_OF entries (see the tier comment below). Sending both is pure
# duplication, and the raw string version is much worse: contextual_
# metabolite_ids alone runs up to ~7500 characters and is truncated on over
# 90% of modules, whereas neighbors_sample already gives the same
# information complete (up to neighbor_limit) and per-entity-citable. These
# are dropped from `properties` entirely rather than trimmed, since trimming
# a duplicate of already-better-structured data doesn't recover any real
# information -- it would just be a smaller, still-broken copy of it.
_REDUNDANT_MODULE_LIST_PROPS = {
    "anchor_metabolites",
    "anchor_metabolite_ids",
    "supporting_metabolites",
    "supporting_metabolite_ids",
    "contextual_metabolites",
    "contextual_metabolite_ids",
}



# Module<->Phenotype has no direct graph edge -- see backend/node.go's
# comments on PhenotypeModules/StudyPhenotypes. The Go backend resolves it as
# a two-hop walk through each module's Study and returns it under a separate
# top-level key (phenotype_modules / study_phenotypes) rather than in the
# regular "neighbors" list. get_node_detail used to only read "neighbors",
# so a Phenotype lookup silently dropped every module linked to it -- the
# model would call get_node_detail on a Phenotype, see only its Studies, and
# wrongly report "no module associations found" even though the frontend's
# own node page shows them. Folding these into neighbors_sample under a
# distinctly-named key (so it's never confused with a true 1-hop edge) fixes
# that without changing the tool's shape for callers.
_TWO_HOP_FIELD_BY_LABEL = {
    "Phenotype": ("phenotype_modules", "REPORTED_IN_VIA_STUDY"),
    "Module": ("study_phenotypes", "INVESTIGATED_VIA_STUDY"),
}
_TWO_HOP_DISPLAY_CAP = 200


async def get_node_detail(client, citations, label: str, lab_id: str, neighbor_limit: int = 8) -> dict:
    """Full properties of one entity, plus a capped sample of its neighbors
    grouped by relationship type (with the true per-type count, so you know
    if more exist than what's shown). Raise neighbor_limit (max 50) for
    questions that need a complete list rather than a preview -- e.g. "which
    modules are associated with phenotype X" wants every match, not just the
    first 8."""
    if label not in ALLOWED_LABELS:
        return {"error": f"unknown label '{label}'. {_LABEL_HINT}"}
    neighbor_limit = max(1, min(int(neighbor_limit), 50))
    try:
        data = await _get(client, f"/api/node/{label}/{lab_id}")
    except BackendError as e:
        if "404" in str(e):
            return {"error": f"no {label} with Lab_ID '{lab_id}' was found"}
        raise

    props = data.get("properties", {}) or {}
    actual_label = data.get("label", label)
    name = (
        props.get("title")
        or props.get("Phenotype")
        or props.get("Accession")
        or props.get("Metabolite_Name")
        or props.get("module_id")
        or lab_id
    )
    _remember(citations, actual_label, lab_id, name)

    neighbors_by_type: dict[str, list] = {}
    for n in data.get("neighbors", []) or []:
        rel = n.get("rel_type", "RELATED")
        bucket = neighbors_by_type.setdefault(rel, [])
        if len(bucket) < neighbor_limit:
            entry = {
                "label": n.get("neighbor_label"),
                "lab_id": n.get("neighbor_id"),
                "name": n.get("neighbor_name"),
            }
            # Metabolite<->Module MEMBER_OF edges carry a Type property --
            # core/supporting/contextual -- from the module membership
            # tiering (see 02_tidy_metabolite_module_relationship.R). The
            # backend's neighborsQuery now orders core before supporting
            # before contextual within this relationship type before
            # applying its cap, so a capped list already favors core/
            # supporting; surfacing the tier here too lets the model name
            # it explicitly instead of just silently benefiting from the
            # ordering.
            tier = (n.get("rel_props") or {}).get("Type")
            if tier:
                entry["tier"] = tier
            bucket.append(entry)
            # Only remember neighbors that actually made it into the capped
            # bucket above -- the model's tool result never contains rows
            # beyond neighbor_limit, so it has no way to legitimately cite
            # them anyway. Remembering every raw neighbor row regardless of
            # the cap (the previous behavior) meant a handful of
            # get_node_detail calls on well-connected Modules could dump
            # thousands of never-shown Metabolite entries into `citations`,
            # flooding the Evidence panel with entries the model never saw.
            _remember(citations, n.get("neighbor_label"), n.get("neighbor_id"), n.get("neighbor_name"))

    relationship_counts = list(data.get("relationship_counts", []) or [])
    two_hop = _TWO_HOP_FIELD_BY_LABEL.get(actual_label)
    if two_hop:
        field, rel_key = two_hop
        two_hop_rows = data.get(field, []) or []
        if two_hop_rows:
            # Deliberately not capped by neighbor_limit like the 1-hop
            # buckets above. neighbor_limit's default of 8 exists for hub
            # nodes that can legitimately have hundreds of direct edges (a
            # common metabolite, say); this two-hop field is different -- at
            # PhenoMAP's current scale the worst real case (the
            # most-studied phenotype, 7 studies) is ~66 modules, nowhere
            # near large enough to need trimming, and this field usually
            # *is* the entire answer to "which modules are associated with
            # this phenotype". Applying the same 8-item cap here is what
            # produced the "why only 8 when there are clearly more" bug --
            # relying on the model to notice and re-call with a bigger
            # neighbor_limit was fixing the symptom, not the cause. Capped
            # generously (not literally unbounded) purely as a future
            # safety backstop against unbounded context growth, not because
            # 200 is an expected real-world number.
            bucket = neighbors_by_type.setdefault(rel_key, [])
            for n in two_hop_rows:
                if len(bucket) < _TWO_HOP_DISPLAY_CAP:
                    bucket.append(
                        {
                            "label": n.get("neighbor_label"),
                            "lab_id": n.get("neighbor_id"),
                            "name": n.get("neighbor_name"),
                        }
                    )
                    # Same reasoning as the 1-hop loop above: only remember
                    # rows that actually made it into the shown bucket.
                    _remember(citations, n.get("neighbor_label"), n.get("neighbor_id"), n.get("neighbor_name"))
            relationship_counts.append({"rel_type": rel_key, "count": len(two_hop_rows)})

    trimmed_props = {
        k: _trim_text(v) for k, v in props.items() if k not in _REDUNDANT_MODULE_LIST_PROPS
    }

    # Spell out truncation explicitly rather than leaving the model to
    # notice it by cross-referencing neighbors_sample's list lengths against
    # relationship_counts itself -- that comparison is easy to skip, and a
    # skipped comparison is exactly how "only 8 of 23 modules" quietly turns
    # into an answer that reads as a complete list.
    counts_by_type = {c["rel_type"]: c["count"] for c in relationship_counts}
    truncated = [
        {"rel_type": rel_type, "shown": len(bucket), "total": counts_by_type[rel_type]}
        for rel_type, bucket in neighbors_by_type.items()
        if rel_type in counts_by_type and counts_by_type[rel_type] > len(bucket)
    ]

    return {
        "label": actual_label,
        "lab_id": lab_id,
        "name": name,
        "properties": trimmed_props,
        "relationship_counts": relationship_counts,
        "neighbors_sample": neighbors_by_type,
        # Empty list means nothing shown here was cut short. Non-empty means
        # some relationship type has more real results than are listed above
        # (call again with a higher neighbor_limit, up to 50, for a complete
        # list rather than a preview).
        "truncated": truncated,
    }


async def find_path(
    client,
    citations,
    from_label: str,
    from_id: str,
    to_label: str,
    to_id: str,
    max_hops: int = 5,
) -> dict:
    """Whether/how two entities are connected in the graph, within max_hops.
    Resolve both endpoints with search_entities first if you only have
    names."""
    for lbl in (from_label, to_label):
        if lbl not in ALLOWED_LABELS:
            return {"error": f"unknown label '{lbl}'. {_LABEL_HINT}"}
    params = {
        "from_label": from_label,
        "from_id": from_id,
        "to_label": to_label,
        "to_id": to_id,
        "max_hops": max(1, min(int(max_hops), 10)),
    }
    data = await _get(client, "/api/path", params=params)
    nodes = data.get("nodes", []) or []
    edges = data.get("edges", []) or []
    # The backend's induced subgraph can hold up to maxBFSVisited (4000)
    # nodes for a well-connected pair, but only the first 40 ever go into
    # nodes_sample below -- remembering all of `nodes` here (the old
    # behavior) put every one of those un-shown nodes into `citations`
    # anyway, the same "cited but never actually shown to the model" bug as
    # get_node_detail's neighbor loops. Only remember the slice that's
    # actually returned to the model.
    nodes_sample = nodes[:40]
    for node in nodes_sample:
        _remember(citations, node.get("label"), node.get("id"), node.get("name"))

    edge_type_counts: dict[str, int] = {}
    for e in edges:
        t = e.get("type", "?")
        edge_type_counts[t] = edge_type_counts.get(t, 0) + 1

    return {
        "connected": data.get("hops") is not None,
        "hops": data.get("hops"),
        "truncated": data.get("truncated", False),
        "node_count": len(nodes),
        "edge_count": len(edges),
        "edge_type_counts": edge_type_counts,
        # Capped so a very well-connected pair doesn't blow out the context
        # window -- the model has hops/edge_type_counts for the summary
        # shape and this sample for naming a few of the intermediate nodes.
        "nodes_sample": [{"label": n.get("label"), "lab_id": n.get("id"), "name": n.get("name")} for n in nodes_sample],
    }


# Lab_ID prefixes belonging to non-Metabolite entities (see
# 1_tidy_entity/*.R's sprintf() calls: Study -> PMAP_STUDY_, Phenotype ->
# PMAP_PHENO_, Module -> PMAP_MOD_/PMAP_MOUDLE_ depending on data vintage).
# run_enrichment only ever makes sense over Metabolite IDs -- catching an
# obviously-wrong entity type here, before the request even reaches the
# backend, turns a silent garbage-in/garbage-out "0 matched, no significant
# modules" (which reads exactly like a real negative enrichment result) into
# an explicit, actionable error instead.
_NON_METABOLITE_LAB_ID_PREFIXES = ("PMAP_STUDY_", "PMAP_PHENO_", "PMAP_MOD_", "PMAP_MOUDLE_")


async def run_enrichment(
    client,
    citations,
    ids: list,
    id_type: str = "hmdb",
    method: str = "fisher",
    fdr_cutoff: float = 0.05,
    min_overlap: float = 2,
    top_n: int = 15,
) -> dict:
    """Module enrichment test: given a list of metabolite IDs, which
    PhenoMAP modules are they statistically enriched in. id_type is one of
    lab_id, hmdb, kegg, inchi."""
    if not ids:
        return {"error": "ids must be a non-empty list of metabolite IDs"}
    if id_type not in {"lab_id", "hmdb", "kegg", "inchi"}:
        return {"error": "id_type must be one of lab_id, hmdb, kegg, inchi"}
    if id_type == "lab_id":
        bad = [i for i in ids if str(i).startswith(_NON_METABOLITE_LAB_ID_PREFIXES)]
        if bad:
            return {
                "error": (
                    f"these are not Metabolite Lab_IDs, so run_enrichment cannot use them: {bad}. "
                    "run_enrichment only accepts Metabolite identifiers (Metabolite Lab_IDs, or "
                    "HMDB/KEGG/InChI IDs) -- it is not the right tool for 'which modules are linked "
                    "to this phenotype/study'; use get_node_detail on that phenotype/study instead "
                    "and read its neighbors_sample."
                )
            }
    body = {
        "ids": ids,
        "id_type": id_type,
        "method": method if method in {"fisher", "hypergeometric"} else "fisher",
        "fdr_cutoff": fdr_cutoff,
        "min_overlap": min_overlap,
    }
    data = await _post(client, "/api/enrichment", body)
    rows = data.get("enrichment", []) or []
    sig_rows = [r for r in rows if r.get("Significant")]
    sig_rows.sort(key=lambda r: (r.get("FDR") is None, r.get("FDR", 1)))
    top_rows = sig_rows[: max(1, min(int(top_n), 30))]
    for r in top_rows:
        _remember(citations, "Module", r.get("Module_ID"), r.get("title"))

    matched_input_n = len(data.get("matched_input", []) or [])
    result = {
        "matched_input_n": matched_input_n,
        "unmatched_input_ids": [u.get("Input_ID") for u in (data.get("unmatched_input", []) or [])],
        "significant_module_count": len(sig_rows),
        "top_significant_modules": [
            {
                "module_id": r.get("Module_ID"),
                "title": r.get("title"),
                "hypothesis_type": r.get("hypothesis_type"),
                "overlap_n": r.get("Overlap_N"),
                "module_size": r.get("Module_Set_Size"),
                "enrichment_ratio": r.get("Enrichment_Ratio"),
                "fdr": r.get("FDR"),
                "overlap_metabolite_names": r.get("Overlap_Metabolite_Names"),
            }
            for r in top_rows
        ],
    }
    if matched_input_n == 0 and ids:
        # None of the supplied IDs resolved to any PhenoMAP metabolite at
        # all -- "0 significant modules" here means the input never actually
        # ran a real test, not that a real test came back negative. Flag it
        # explicitly rather than letting it read like an ordinary null
        # result (see _NON_METABOLITE_LAB_ID_PREFIXES above for the most
        # common way this happens).
        result["warning"] = (
            "none of the provided ids matched any PhenoMAP metabolite -- this is not a valid "
            "enrichment result. Do not report this as 'no significant modules found'; report that "
            "the metabolite lookup itself failed, and check the ids and id_type."
        )
    return result


async def get_product_info(client, citations, **kwargs) -> dict:
    """Returns PhenoMAP's own product information: what PhenoMAP is and how
    its graph is built, the project team, citation/manuscript details,
    current version and graph scope, and contact info -- the same content
    the site's About pages render from (see
    ../frontend/src/data/product_facts.json). Takes no arguments and always
    returns everything; PhenoMAP's product information is small enough that
    a narrower per-topic lookup would add complexity without saving
    anything meaningful.

    This is a *local* lookup, unlike the four tools above -- it never calls
    the Go backend. `client` and `citations` are accepted only so this has
    the same call signature as every other tool (see agent.py's
    _run_manual_tool, which dispatches every tool identically regardless of
    what it actually does); citations is left untouched since product
    information has no Lab_IDs to cite."""
    return _load_product_facts()


TOOL_FUNCS = {
    "search_entities": search_entities,
    "get_node_detail": get_node_detail,
    "find_path": find_path,
    "run_enrichment": run_enrichment,
}

# Kept separate from TOOL_FUNCS/TOOL_SCHEMAS on purpose: agent.py gives a
# product-classified turn ONLY this one tool, never the four PhenoMAP graph
# tools above (and vice versa for a phenomap_question turn) -- see
# agent.py's run_chat_stream. That separation is what makes "PhenoMAP graph
# data" and "PhenoMAP's own product info" two distinct, non-overlapping
# retrieval surfaces instead of one bag of tools the model has to pick the
# right one out of.
PRODUCT_TOOL_FUNCS = {
    "get_product_info": get_product_info,
}

PRODUCT_TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "get_product_info",
            "description": (
                "Get PhenoMAP's own product information: what PhenoMAP is and how its "
                "graph is built (Introduction page), the project team (Authors page), "
                "how to cite it and its manuscript details (Citation page), current "
                "version and graph scope (Version page), how to contact the team "
                "(Contact page), and a short note on how PhenoMAP Chat itself works. Use "
                "this for any question about PhenoMAP Chat or the PhenoMAP project "
                "itself -- not for PhenoMAP's graph data (search_entities and friends "
                "are for that). Takes no arguments."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    }
]

# OpenAI-compatible function-calling schemas. Kept next to TOOL_FUNCS so the
# two can't drift apart silently.
TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "search_entities",
            "description": (
                "Search PhenoMAP for Study/Phenotype/Module/Metabolite entities by name, "
                "synonym, or ID (accession, HMDB/KEGG/InChI ID, or PhenoMAP Lab_ID). Use "
                "this first to resolve a name the user typed into a Lab_ID before calling "
                "any other tool. For English user-written entity names, first search the exact "
                "phrase the user wrote before trying spelling corrections, synonyms, or variants. "
                "Searchable entity names are stored in English; if the user asks in Chinese or "
                "another non-English language, translate only the entity phrase into a standard "
                "English biomedical term before calling this tool."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": (
                            "Entity name/synonym or exact ID to search for. For English user text, "
                            "the first entity-resolution search should use the exact phrase the user "
                            "wrote; only later searches should try corrected spellings or synonyms. "
                            "Do not pass a whole non-English question; translate the target entity "
                            "phrase first."
                        ),
                    },
                    "label": {
                        "type": "string",
                        "enum": ["Study", "Phenotype", "Module", "Metabolite"],
                        "description": "Restrict to one entity type. Omit to search all four.",
                    },
                    "limit": {"type": "integer", "description": "Max results, default 10, max 20."},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_node_detail",
            "description": (
                "Get full details for one entity by its exact Lab_ID: its properties plus "
                "a sample of its neighbors grouped by relationship type. Use search_entities "
                "first if you don't already have the exact Lab_ID. The result's `truncated` "
                "field says which relationship types have more results than shown -- call "
                "again with a higher neighbor_limit if the question needs the complete list "
                "(e.g. 'which modules are associated with this phenotype'), not just a preview."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "label": {"type": "string", "enum": ["Study", "Phenotype", "Module", "Metabolite"]},
                    "lab_id": {"type": "string", "description": "Exact PhenoMAP Lab_ID."},
                    "neighbor_limit": {
                        "type": "integer",
                        "description": (
                            "Max neighbors to return per relationship type. Default 8, max 50. "
                            "Raise this when the question needs a complete list rather than a preview."
                        ),
                    },
                },
                "required": ["label", "lab_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "find_path",
            "description": (
                "Check whether/how two entities are connected in the PhenoMAP graph, and "
                "summarize the connecting subgraph within max_hops. Resolve both endpoints "
                "to exact Lab_IDs with search_entities first."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "from_label": {"type": "string", "enum": ["Study", "Phenotype", "Module", "Metabolite"]},
                    "from_id": {"type": "string"},
                    "to_label": {"type": "string", "enum": ["Study", "Phenotype", "Module", "Metabolite"]},
                    "to_id": {"type": "string"},
                    "max_hops": {"type": "integer", "description": "1-10, default 5."},
                },
                "required": ["from_label", "from_id", "to_label", "to_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_enrichment",
            "description": (
                "Module enrichment test: given a list of metabolite IDs, find which "
                "PhenoMAP modules they are statistically enriched in (Fisher's exact or "
                "hypergeometric test, BH-adjusted FDR). Use this for 'which modules are "
                "associated with metabolites X, Y, Z' style questions."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Metabolite IDs, all of the same id_type.",
                    },
                    "id_type": {
                        "type": "string",
                        "enum": ["lab_id", "hmdb", "kegg", "inchi"],
                        "description": "Default hmdb.",
                    },
                    "method": {"type": "string", "enum": ["fisher", "hypergeometric"], "description": "Default fisher."},
                    "fdr_cutoff": {"type": "number", "description": "Default 0.05."},
                    "min_overlap": {"type": "number", "description": "Minimum overlap count, default 2."},
                },
                "required": ["ids"],
            },
        },
    },
]
