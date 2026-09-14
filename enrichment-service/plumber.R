# PhenoMAP Module Enrichment service.
#
# Wraps run_module_enrichment() from code/module_enrichment.R
# as an HTTP API, so the Go backend (and anything else) can reuse the exact
# same over-representation logic without reimplementing it.
#
# Run from anywhere (project root not required -- see note below):
#   Rscript -e "pr <- plumber::plumb('enrichment-service/plumber.R'); pr$run(port = 8787)"

library(plumber)

# NOTE: plumber changes the working directory to the directory containing
# this file (setwd(dirname(file))) while it parses AND while it serves
# requests, no matter where Rscript was launched from. So instead of
# relying on the caller's working directory, we compute the project root
# from *this file's own location* -- this file lives at
# enrichment-service/plumber.R, one level below the project root.
project_root <- normalizePath(file.path(getwd(), ".."))
import_dir <- Sys.getenv(
  "PHENOMAP_NEO4J_IMPORT_DIR",
  file.path(project_root, "neo4j", "import")
)
analysis_script <- file.path(project_root, "code", "module_enrichment.R")

if (!file.exists(file.path(import_dir, "nodes_module.csv"))) {
  stop(
    "Could not find nodes_module.csv under: ", import_dir, "\n",
    "(resolved project root: ", project_root, ")\n",
    "If your project folder isn't named 'phenomap' or isn't three levels ",
    "above this file, edit the project_root line in plumber.R directly."
  )
}

source(analysis_script)

# Parse the ~165 MB of CSV ONCE, at startup, instead of on every request.
# This was the single biggest cost per call. The cached object is ~30 MB.
message("Loading enrichment data into memory ...")
.enrich_load_t0 <- Sys.time()
ENRICH_DATA <- load_enrichment_data(import_dir = import_dir)
message(sprintf(
  "Loaded %d modules, %d core/supporting memberships in %.1fs.",
  nrow(ENRICH_DATA$modules), nrow(ENRICH_DATA$edges),
  as.numeric(difftime(Sys.time(), .enrich_load_t0, units = "secs"))
))

# Empty JSON arrays arrive as list(); treat those (and "") as "no filter".
as_filter <- function(x) {
  if (is.null(x)) return(NULL)
  x <- trimws(as.character(unlist(x, use.names = FALSE)))
  x <- x[!is.na(x) & nzchar(x)]
  if (length(x) == 0) NULL else x
}

#* @apiTitle PhenoMAP Module Enrichment
#* @apiDescription Wraps run_module_enrichment() as an HTTP API.

#* Health check
#* @get /health
function() {
  list(
    status = "ok",
    project_root = project_root,
    modules_loaded = nrow(ENRICH_DATA$modules),
    memberships_loaded = nrow(ENRICH_DATA$edges)
  )
}

#* Filter vocabulary: the confidence labels and module types the UI can offer,
#* with the number of modules behind each, straight from the loaded data.
#* @get /meta
function() {
  m <- ENRICH_DATA$modules
  tab <- function(col) {
    if (!col %in% colnames(m)) return(list())
    counts <- sort(table(trimws(m[[col]])), decreasing = TRUE)
    lapply(names(counts), function(v) list(value = v, n = unname(counts[[v]])))
  }
  list(
    module_n = nrow(m),
    confidence_labels = tab("confidence_label"),
    hypothesis_types = tab("hypothesis_type")
  )
}

#* Run module enrichment for a list of metabolite IDs
#* @param ids A list of metabolite IDs (HMDB, KEGG, InChI, or PhenoMAP Lab IDs)
#* @param id_type One of lab_id, hmdb, kegg, inchi
#* @param fdr_cutoff FDR cutoff, default 0.05
#* @param min_overlap Minimum overlap count, default 2
#* @param confidence_labels Optional module confidence filter, e.g. ["high","medium"]
#* @param hypothesis_types Optional module type filter, e.g. ["Host-Endogenous"]
#* @post /enrichment
function(res,
         ids = list(),
         id_type = "lab_id",
         fdr_cutoff = 0.05,
         min_overlap = 2,
         confidence_labels = NULL,
         hypothesis_types = NULL,
         method = NULL,
         ...) {
  # `method` is accepted and ignored: "fisher" and "hypergeometric" were the
  # same one-sided test, so there is only one method now. `...` swallows any
  # other stray field an older client might still post (e.g. fdr_scope), so
  # a rolling deploy can't 500 on an argument that no longer exists.
  ids <- unlist(ids)
  if (length(ids) == 0) {
    res$status <- 400
    return(list(error = "ids must be a non-empty list of metabolite IDs"))
  }

  result <- tryCatch(
    run_module_enrichment(
      input_ids = ids,
      id_type = id_type,
      data = ENRICH_DATA,
      fdr_cutoff = as.numeric(fdr_cutoff),
      min_overlap = as.numeric(min_overlap),
      confidence_labels = as_filter(confidence_labels),
      hypothesis_types = as_filter(hypothesis_types)
    ),
    error = function(e) {
      list(error = conditionMessage(e))
    }
  )

  if (!is.null(result$error)) {
    res$status <- 400
    return(result)
  }

  list(
    enrichment = result$enrichment,
    matched_input = result$matched_input,
    unmatched_input = result$unmatched_input,
    parameters = result$parameters
  )
}
