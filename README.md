# PhenoMAP

PhenoMAP is a lightweight atlas of phenotype-associated metabolite modules.
It converts study-level exports from `featuremap_case` into a SQLite database
and provides metabolite-ID based over-representation queries.

## Project Layout

- `1_code/01_build_database.R`: build `2_data/phenomap_v0.1.db` from study exports.
- `1_code/02_query.R`: query modules using HMDB, KEGG, or INCHI IDs.
- `1_code/03_validate_query.R`: sanity-check queries with T2D and gout metabolite panels.
- `1_code/04_build_signature.R`: derive `signature` from LLM anchor names and module members.
- `1_code/05_build_atlas_modules.R`: merge study-specific modules into cross-study atlas modules.
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
- `signature`: query-ready anchor/top metabolite signatures
- `anchor_unmatched`: LLM anchor names that could not be resolved to member IDs
- `atlas_module`: cross-study functional modules merged by normalized title and hypothesis type
- `atlas_module_instance`: links atlas modules to original study-specific modules
- `atlas_signature`: merged anchor/top signatures for atlas-level enrichment
- `atlas_anchor_unmatched`: unmatched anchor names mapped to atlas modules

If exported `signature.csv` files are absent, `01_build_database.R` derives
`signature` automatically from `module.anchor_metabolites` and `member`.
It then derives atlas tables from `module` and `signature`.

## Build Signature Only

To refresh only the `signature` and `anchor_unmatched` tables:

```bash
Rscript 1_code/04_build_signature.R
```

The derived signature uses:

- `anchor`: LLM-selected `anchor_metabolites`, matched back to module members by name.
- `top`: `core_drivers` from `module_function`, matched back to module members
  by name.

## Build Atlas Only

To refresh only cross-study atlas tables:

```bash
Rscript 1_code/05_build_atlas_modules.R
```

The current first-pass atlas merge is conservative:

- Merge key: normalized `title + hypothesis_type`
- Example: all `Purine metabolism | Host-Endogenous` instances become one atlas module.
- Ambiguous semantic variants are not merged automatically yet.

## Query Example

```r
setwd("/Users/yuting/Documents/AtNTUlife/ShenLab/1_MyProject/featureFMA/phenomap")
source("1_code/02_query.R")

res <- query_phenomap(
  ids = c("HMDB0000289", "HMDB0000157", "HMDB0000296", "HMDB0000262"),
  id_type = "HMDB",
  min_hits = 2,
  fdr_cutoff = 0.2,
  level = "atlas"
)

print_query_result(res)
```

## Current Query Behavior

`query_phenomap()` prefers the `signature` table when available:

- `anchor`: compact module identity signature
- `top`: broader discriminating module signature

Anchor signatures are primary evidence. Core-driver signatures are also tested,
but only modules not already recovered by anchor enrichment are displayed as
supplemental results.

If a database does not include `signature`, the query script falls back to the
existing `member` table:

- `anchor`: rows with `is_core_driver = 1`
- `top`: rows with `use_for_annotation = 1`

This fallback keeps the atlas queryable while signature export is still under
development.

By default, `query_phenomap()` runs at `level = "atlas"` when atlas tables are
available. Use `level = "instance"` to query the original study-specific modules.
