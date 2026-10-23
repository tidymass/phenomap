# Help page screenshots

Drop the four PNGs below into this folder, using these exact filenames --
one screenshot per tool. `frontend/public/` is served at the site root, so
`/help/<name>.png` is the URL; nothing else needs to change.

Until a file exists, that tutorial step shows a grey placeholder box, so the
page never shows a broken image.

| File | Help page | What it should show |
|---|---|---|
| `entity-search-results.png` | Entity Search | The results table, with the entity-type selector and search box visible |
| `path-query-graph.png`      | Path Query | The network view of a result, with "Shortest connection: N hops" visible |
| `enrichment-results.png`    | Module Enrichment | The bubble plot (dashed cutoff line visible) and the top of the significant-module table |
| `chat-answer.png`           | PhenoMAP Chat | One answer with citations and the Evidence panel opened |

## Current set

The four shots follow one worked example (purine metabolism; gout to anemia
of chronic renal failure) and carry red numbered callouts 1-10. HelpView.vue
refers to them through each section's `markers` field, so if a screenshot is
retaken, keep the same numbering or update the matching `markers` and text:

- 1-3 `entity-search-results.png`: type + query, result row, module detail page
- 4-5 `path-query-graph.png`: From/To pickers, shortest-connection graph
- 6-8 `enrichment-results.png`: ID box, settings panel, enrichment overview
- 9-10 `chat-answer.png`: question, answer with cited records

## Format

- PNG. The page shows them about 760 px wide, so 1240 px wide (retina) is
  plenty.
- Crop to the relevant panel rather than the whole browser window.
- Use the same browser width for all four so they look like one set.
