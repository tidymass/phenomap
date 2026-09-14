# PhenoMAP Module Enrichment service.
#
# Wraps run_module_enrichment() from 1_code/4_analysis/01_module_enrichment.R
# as an HTTP API, so the Go backend (and anything else) can reuse the exact
# same Fisher/hypergeometric logic without reimplementing it.
#
# Run from anywhere (project root not required -- see note below):
#   Rscript -e "pr <- plumber::plumb('1_code/5_website/enrichment-service/plumber.R'); pr$run(port = 8787)"

library(plumber)

# NOTE: plumber changes the working directory to the directory containing
# this file (setwd(dirname(file))) while it parses AND while it serves
# requests, no matter where Rscript was launched from. So instead of
# relying on the caller's working directory, we compute the project root
# from *this file's own location* -- this file lives at
# 1_code/5_website/enrichment-service/plumber.R, three levels below the
# project root.
project_root <- normalizePath(file.path(getwd(), "..", "..", ".."))
entity_dir <- file.path(project_root, "2_data", "tidy_entity")
relationship_dir <- file.path(project_root, "2_data", "tidy_relationship")
analysis_script <- file.path(project_root, "1_code", "4_analysis", "01_module_enrichment.R")

if (!file.exists(file.path(entity_dir, "nodes_module.csv"))) {
  stop(
    "Could not find nodes_module.csv under: ", entity_dir, "\n",
    "(resolved project root: ", project_root, ")\n",
    "If your project folder isn't named 'phenomap' or isn't three levels ",
    "above this file, edit the project_root line in plumber.R directly."
  )
}

source(analysis_script)

#* @apiTitle PhenoMAP Module Enrichment
#* @apiDescription Wraps run_module_enrichment() as an HTTP API.

#* Health check
#* @get /health
function() {
  list(status = "ok", project_root = project_root)
}

#* Run module enrichment for a list of metabolite IDs
#* @param ids A list of metabolite IDs (HMDB, KEGG, or InChI)
#* @param id_type One of lab_id, hmdb, kegg, inchi
#* @param method One of fisher, hypergeometric
#* @param fdr_cutoff FDR cutoff, default 0.05
#* @param min_overlap Minimum overlap count, default 2
#* @post /enrichment
function(res, ids = list(), id_type = "lab_id", method = "fisher", fdr_cutoff = 0.05, min_overlap = 2) {
  ids <- unlist(ids)
  if (length(ids) == 0) {
    res$status <- 400
    return(list(error = "ids must be a non-empty list of metabolite IDs"))
  }

  result <- tryCatch(
    run_module_enrichment(
      input_ids = ids,
      id_type = id_type,
      method = method,
      entity_dir = entity_dir,
      relationship_dir = relationship_dir,
      fdr_cutoff = as.numeric(fdr_cutoff),
      min_overlap = as.numeric(min_overlap)
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
