# PhenoMAP Web — Phase 1

This is the first working slice of the PhenoMAP web tool: Graph Query
single-node search. Given a phenotype, study accession, metabolite ID, or
module name, you can search for it, open its detail page (all properties +
grouped neighbors), and click through neighbors to keep exploring the graph.

Two pieces, run side by side during development:

```
5_website/
  backend/   Go API that talks to your local Neo4j instance
  frontend/  Vue 3 + Vite single-page app that calls the API
```

## Quick start

Terminal 1 — backend:
```bash
cd 1_code/5_website/backend
cp .env.example .env        # fill in your Neo4j password
go mod tidy
set -a; source .env; set +a
go run .
```
Should print `phenomap-web backend listening on :8080 ...`.

Terminal 2 — frontend:
```bash
cd 1_code/5_website/frontend
cp .env.example .env
npm install
npm run dev
```
Open http://localhost:5173, search for something (e.g. part of a study
accession, a phenotype name, or an HMDB ID).

## What's in Phase 1

- `GET /api/search?q=...&label=Module&limit=20` — search across Study /
  Phenotype / Module / Metabolite, or restrict to one label.
- `GET /api/node/{label}/{id}` — a node's full properties plus its
  neighbors grouped by relationship type (capped at 300 per node, with the
  true total count shown so you know if more exist).
- A search page and a node detail page, with every neighbor clickable —
  clicking navigates to `/node/{label}/{id}` for that neighbor and reloads
  the detail view.

## Not in Phase 1 (later phases)

- Two-node path query (Phase 2)
- Module Enrichment via the R plumber service (Phase 3)
- Sign in / Download / Help / About (Phase 4)
- AI Q&A agent (Phase 5)

## Note on verification

I could not compile the Go backend in this environment (no Go toolchain
or internet access to install one here), so `go build`/`go run` haven't
actually been run against this code. I did verify the frontend builds
cleanly with `npm run build`. If `go run .` errors out on your machine,
it's most likely a small Neo4j driver API mismatch — paste the error back
and I'll fix it directly.
