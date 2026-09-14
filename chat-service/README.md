# PhenoMAP Chat service (Python / FastAPI)

An LLM tool-calling chat experience over PhenoMAP's own API -- not a text-RAG service.
It never touches Neo4j or the R plumber enrichment service directly; every
fact it can surface comes from calling the same `/api/search`, `/api/node`,
`/api/path`, `/api/enrichment` endpoints the frontend itself uses (see
`tools.py`). That keeps "what PhenoMAP knows" in one place and means this
service can't drift from what a user browsing the site directly would see.

## Why tool-calling instead of RAG-over-text

PhenoMAP's knowledge is already structured (graph nodes/edges, enrichment
statistics), not prose. The Go backend already exposes exactly the
operations a user performs by hand through the four Analysis pages
(search, node detail, path query, module enrichment). So the agent's real
job is intent understanding and entity resolution (turning a name the user
typed into an exact Lab_ID via `search_entities`), not passage retrieval.

## The one hard rule

The system prompt (`prompts.py`) forbids the model from stating any
PhenoMAP-specific fact -- a Lab_ID, a module title, an enrichment result --
unless a tool call in the current conversation actually returned it. This
isn't a style preference: PhenoMAP's IDs and content were never in any LLM's
training data, so anything not just retrieved is almost certainly
hallucinated. Every entity the model is allowed to cite gets tracked in a
`citations` dict as tools run (see `tools.py`'s `_remember()`); the model is
told to wrap references as `{{LAB_ID}}`, and the frontend only renders a
token as a clickable link if that ID is actually present in `citations` --
so even if the model slips and cites an ID it didn't retrieve, the frontend
won't hydrate it into a link pointing at a real (or worse, wrong) page.

## LLM modes

PhenoMAP Chat supports three OpenAI-compatible model modes:

- `official_qwen`: free model endpoint deployed by PhenoMAP. Configure
  `OFFICIAL_QWEN_API_KEY`, `OFFICIAL_QWEN_BASE_URL`, and
  `OFFICIAL_QWEN_MODEL` in this service's `.env`. The browser never sees the
  official key.
- `openai`: user supplies their own ChatGPT/OpenAI API key in the UI. Default
  base URL/model come from `OPENAI_BASE_URL` and `OPENAI_MODEL`.
- `siliconflow`: user supplies their own SiliconFlow API key in the UI.
  Default base URL/model come from `SILICONFLOW_BASE_URL` and
  `SILICONFLOW_MODEL`.

All three modes use the exact same PhenoMAP tools and citation rules.

## Setup

```bash
pip install -r requirements.txt
cp .env.example .env   # fill in official Qwen settings for free mode
```

## Run

From this directory, with the Go backend already running (see
`../backend/README.md`) on `BACKEND_URL`:

```bash
uvicorn main:app --port 8788
```

Or `python main.py`. You should see `Uvicorn running on http://0.0.0.0:8788`.

The Go backend calls this service at `CHAT_SERVICE_URL` (default
`http://127.0.0.1:8788`) -- see `../backend/.env.example`.

## Endpoints

- `GET /health`
- `POST /chat` with a JSON body like:
  ```json
  {
    "message": "Which modules are associated with gout?",
    "llm": { "provider": "official_qwen" },
    "history": [
      { "role": "user", "content": "..." },
      { "role": "assistant", "content": "..." }
    ]
  }
  ```
  Returns:
  ```json
  {
    "reply": "The {{PMAP_MOD_001a2}} module is linked to ...",
    "citations": { "PMAP_MOD_001a2": { "label": "Module", "name": "..." } },
    "tool_calls": [ { "tool": "search_entities", "args": { "query": "..." } } ]
  }
  ```
  `history` is not persisted server-side in this first version -- the caller
  (the frontend, in this case) is responsible for resending prior turns it
  wants the model to remember.

## Tools available to the model

See `tools.py` for the implementation and `TOOL_SCHEMAS` for the exact
function-calling schema sent to the LLM:

- `search_entities` -- name/synonym/ID search across Study, Phenotype,
  Module, Metabolite. Also the entity-resolution step: the model is
  instructed to call this before any other tool to turn a name the user
  typed into an exact Lab_ID.
- `get_node_detail` -- one entity's full properties plus a capped,
  grouped-by-relationship-type sample of its neighbors.
- `find_path` -- whether/how two entities are connected, within a hop
  limit.
- `run_enrichment` -- module enrichment test over a metabolite ID list
  (wraps `POST /api/enrichment`, i.e. `01_module_enrichment.R`). Read-only,
  same statistical logic as the Module Enrichment page -- no different risk
  profile than the other three tools.

## Known limitations (first version)

- No persisted chat history -- each browser tab holds its own turn history
  client-side and resends it every request.
- No streaming -- `POST /chat` returns the full reply once the tool-calling
  loop finishes. Multi-tool-call turns can take several seconds.
- Single evidence-grounded mode only (no separate fast/lite mode yet).
