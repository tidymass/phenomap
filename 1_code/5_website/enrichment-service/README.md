# PhenoMAP enrichment service (R / plumber)

Thin HTTP wrapper around `1_code/4_analysis/01_module_enrichment.R`. It does
not reimplement any statistics -- it just calls the existing
`run_module_enrichment()` function and returns the result as JSON.

## Setup

```r
install.packages("plumber")   # one-time, if you don't have it
```

## Run

From the **project root** (this matters -- the analysis script's default
paths are relative to it):

```bash
cd /Users/yuting/Documents/AtNTUlife/ShenLab/1_MyProject/featureFMA/phenomap
Rscript -e "pr <- plumber::plumb('1_code/5_website/enrichment-service/plumber.R'); pr\$run(port = 8787)"
```

You should see plumber print the routes it registered and then sit there
serving requests (same idea as the Go backend -- leave this terminal open).

## Endpoints

- `GET /health`
- `POST /enrichment` with a JSON body like:
  ```json
  {
    "ids": ["HMDB0000289", "HMDB0000157"],
    "id_type": "hmdb",
    "method": "fisher",
    "fdr_cutoff": 0.05,
    "min_overlap": 2
  }
  ```

The Go backend calls this service at `ENRICHMENT_SERVICE_URL`
(default `http://127.0.0.1:8787`) -- see `../backend/.env.example`.
