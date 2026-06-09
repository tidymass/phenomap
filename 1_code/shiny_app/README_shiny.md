# PhenoMAP Shiny App

## Required R packages

```r
install.packages(c(
  "shiny", "bslib", "DT", "DBI", "RSQLite",
  "dplyr", "tidyr", "stringr", "plotly", "shinycssloaders"
))
```

## Run the app

From the **project root** (`phenomap/`):

```r
shiny::runApp("1_code/shiny_app")
```

Or open `1_code/shiny_app/app.R` in RStudio and click **Run App**.

## Notes

- The app auto-detects `2_data/phenomap_v0.1.db` relative to the app or project root.
- Default query level is **Atlas** (cross-study merged modules).
- Click any row in the Results table to jump to the **Module Detail** tab.
