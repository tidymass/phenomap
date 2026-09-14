from __future__ import annotations

"""Loads PhenoMAP's own product information from the single JSON file also used
by the frontend's About pages (see ../frontend/src/data/product_facts.json's
_comment).

This module used to also render that JSON into a big prose PRODUCT_FACTS
string that got stuffed into RELEVANCE_PROMPT on *every* chat turn, whether
or not the question was actually about PhenoMAP's product info. That's gone
now: `load_facts()` is called on demand by the get_product_info tool (see
tools.py) only in the turns where the relevance-classification stage (see
agent.py's _classify_relevance) actually decides this question needs it --
the same "look it up only when needed" pattern already used for PhenoMAP's
graph data (search_entities, get_node_detail, ...), instead of a second,
inconsistent pattern just for product questions. `identity_blurb()` is the
only piece still eagerly embedded in a prompt, and it's two sentences, not
the whole JSON.
"""

import json
from pathlib import Path

_FACTS_PATH = (
    Path(__file__).resolve().parent.parent / "frontend" / "src" / "data" / "product_facts.json"
)


def load_facts() -> dict:
    """The full product-facts JSON, as a plain dict. Called fresh each time
    (no caching) -- this file is small and rarely read, and re-reading it
    means an edit to product_facts.json takes effect on the next request
    with no chat-service restart needed."""
    with open(_FACTS_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def identity_blurb() -> str:
    """Two-line bot identity for RELEVANCE_PROMPT (prompts.py) -- just enough
    for stage 1 to recognize a product-type question and phrase an
    off-topic decline naturally. Deliberately NOT PhenoMAP's full product
    information: that's retrieved on demand by the get_product_info tool
    (tools.py) only once a question is actually classified as "product",
    not carried in every single turn's prompt regardless of category."""
    identity = load_facts()["identity"]
    return (
        f"You are {identity['chatbot_name']}. You can hold a conversation in "
        f"whatever language the user writes in. Your main job is to {identity['main_job']}."
    )
