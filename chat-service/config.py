"""Environment configuration for the PhenoMAP chat service.

Mirrors the .env pattern used by ../backend (.env / .env.example): load once
at import time, expose plain module-level constants, no framework-specific
settings object.
"""

import os

from dotenv import load_dotenv

load_dotenv()

# Go backend base URL. The chat service never talks to Neo4j or the R
# plumber enrichment service directly -- every fact it can surface comes
# through the same /api/search, /api/node, /api/path, /api/enrichment
# endpoints the frontend itself uses, kept as the single source of truth for
# what "PhenoMAP knowledge" means.
BACKEND_URL = os.getenv("BACKEND_URL", "http://127.0.0.1:8080").rstrip("/")

# Defaults for the user-supplied providers. Every chat turn uses the user's own
# API key (there is no server-side model any more); these defaults just save
# them from typing the base URL/model. SiliconFlow is the default provider.
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-5.4")
# Tried first; agent.py falls back to the other SiliconFlow site
# (api.siliconflow.com) automatically when a key belongs to that one.
SILICONFLOW_BASE_URL = os.getenv("SILICONFLOW_BASE_URL", "https://api.siliconflow.cn/v1")
SILICONFLOW_MODEL = os.getenv("SILICONFLOW_MODEL", "Qwen/Qwen2.5-72B-Instruct")

PORT = int(os.getenv("PORT", "8788"))

# Safety valve on the tool-calling loop: how many rounds of
# "model asks for tools -> we run them -> feed results back" are allowed
# before we force a final answer instead of letting a confused model loop
# forever.
MAX_TOOL_TURNS = int(os.getenv("MAX_TOOL_TURNS", "6"))

# Per-request timeout (seconds) for each call this service makes back to the
# Go backend (search / node / path / enrichment). Enrichment is the heaviest
# of the four, but it already has its own generous timeout on the backend
# side (30s) -- this just needs to not cut that off early.
REQUEST_TIMEOUT = float(os.getenv("REQUEST_TIMEOUT", "35"))

# How long (seconds) an identical backend call (same endpoint + same params)
# is served from an in-process cache instead of hitting the Go backend/Neo4j
# again. This service is stateless across HTTP requests -- there is no
# per-conversation session object anywhere -- so this cache is deliberately
# keyed on the call itself (endpoint + params), not on a conversation or
# session id. That works because PhenoMAP's graph data only changes via
# infrequent batch re-imports, not live edits, so serving a few-minutes-old
# answer for the exact same query is safe. This exists specifically for the
# "user asks a follow-up about an entity already looked up a turn or two
# ago" case: prompts.py's execution stages still call a tool every turn
# (the "never state a fact without a tool call this turn" rule is about
# grounding, not about avoiding a network round-trip), but if that call is
# an exact repeat, this makes it effectively free instead of a fresh
# backend + Neo4j round-trip.
TOOL_CACHE_TTL_SECONDS = float(os.getenv("TOOL_CACHE_TTL_SECONDS", "300"))
TOOL_CACHE_MAX_ENTRIES = int(os.getenv("TOOL_CACHE_MAX_ENTRIES", "500"))
