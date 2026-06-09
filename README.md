# PhenoMAP

PhenoMAP is a lightweight atlas of phenotype-associated metabolite modules.
It converts study-level exports from `featuremap_case` into a SQLite database
and provides metabolite-ID based over-representation queries.

## Project Layout

- `1_code/01_build_database.R`: build `2_data/phenomap_v0.1.db` from study exports.
- `1_code/02_query.R`: query modules using HMDB, KEGG, or INCHI IDs.
- `1_code/03_validate_query.R`: sanity-check queries with T2D and gout metabolite panels.
- `2_data/phenomap_v0.1.db`: current SQLite atlas.
- `5_summary/demo_summary.pptx`: demo summary deck.

## Data Source

The build script expects study exports under:

```text
../featuremap_case/3_data_analysis/phenomap/study_exports/
```

Each study directory should contain:

- `study_meta.csv`
- `annotation.csv`
- `scores.csv`
- `members.csv`
- optional `signature.csv`

## Rebuild Database

From this project directory:

```bash
Rscript 1_code/01_build_database.R
```

The resulting database contains:

- `study`: one row per study
- `module`: one row per significant module
- `member`: one row per module member metabolite
- `signature`: optional, only when `signature.csv` files are present

## Query Example

```r
setwd("/Users/yuting/Documents/AtNTUlife/ShenLab/1_MyProject/featureFMA/phenomap")
source("1_code/02_query.R")

res <- query_phenomap(
  ids = c("HMDB0000289", "HMDB0000157", "HMDB0000296", "HMDB0000262"),
  id_type = "HMDB",
  min_hits = 2,
  fdr_cutoff = 0.2
)

print_query_result(res)
```

## Current Query Behavior

`query_phenomap()` prefers the `signature` table when available:

- `anchor`: compact module identity signature
- `top`: broader discriminating module signature

The current `phenomap_v0.1.db` does not include `signature`, so the query script
falls back to the existing `member` table:

- `anchor`: rows with `is_core_driver = 1`
- `top`: rows with `use_for_annotation = 1`

This fallback keeps the atlas queryable while signature export is still under
development.
