# Help page screenshots

Drop the seven PNGs below into this folder, using these exact filenames.
`frontend/public/` is served at the site root, so `/help/<name>.png` is the
URL and no import or rebuild step is needed beyond the usual `npm run build`.

Until a file exists, that tutorial step falls back to the grey placeholder
box automatically, so the page never shows a broken image.

| File | Page | What it should show |
|---|---|---|
| `entity-search-results.png` | Entity Search | The results list, with the entity-type filter visible |
| `entity-search-detail.png`  | Entity detail | One entity page, scrolled so a relationship section is visible |
| `path-query-form.png`       | Path Query | The two node pickers filled in + the Find connections button (note: no hop selector any more) |
| `path-query-graph.png`      | Path Query | The network view of a result, with "Shortest connection: N hops" visible |
| `enrichment-form.png`       | Module Enrichment | The ID box with IDs pasted, ID type, **Module confidence / Module type dropdowns**, and the Run button |
| `enrichment-results.png`    | Module Enrichment | The bubble plot and the significant-module table below it |
| `chat-answer.png`           | PhenoMAP Chat | One answer showing citations / the evidence panel |

## Suggested shots

For `enrichment-form.png`, example #2 (the bile acid KEGG list) gives a clean
result, and opening the **Module type** dropdown in the same shot shows the
new filter -- that is the single biggest change in this release.

For `path-query-graph.png`, example #2 (Chronic kidney disease to Coronary
Artery Disease) renders about 19 nodes, which is legible at screenshot size.
Example #1 (Colorectal adenoma to Colorectal cancer) is denser at ~52 nodes.

## Format

- PNG, retina if convenient. The page renders them at 620 px wide, so
  1240 px wide is plenty; anything wider is just a bigger download.
- Crop to the relevant panel rather than shooting the whole browser window --
  the surrounding chrome adds nothing at this size.
- Keep a consistent browser width across shots so they look like one set.
