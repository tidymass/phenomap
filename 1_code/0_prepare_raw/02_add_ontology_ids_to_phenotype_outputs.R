# Add per-ontology candidate IDs to existing phenotype-normalization outputs.
#
# (Originally 03_add_ontology_ids_to_workbench_phenotype_outputs.R -- renamed
# for the same reason as 01_normalize_study_phenotype.R: this post-processes
# output from either database, not just Workbench. Renumbered to this file's
# current 02_ once 0_prepare_raw/'s numbering was cleaned up to run 01-04
# with no gaps.)
#
# This post-processes files produced by:
#   1_code/0_prepare_raw/01_normalize_study_phenotype.R
#
# It does not call GPT or OLS. It reads phenotype_ols_candidates.csv and
# merges per-study MONDO/EFO/MeSH/HPO/... candidate IDs into the final/
# review/all tables, using the exact same summarizer
# (phenomap_summarize_ontology_candidates_by_study(), in
# 1_code/00_phenomap_helpers.R) that 01 itself uses -- so this
# script's output can never drift out of sync with what 01 already wrote.
# The main CSV files are kept compact for manual review.
#
# Usage:
#   Rscript 1_code/0_prepare_raw/02_add_ontology_ids_to_phenotype_outputs.R \
#     --output_dir=2_data/raw/delivery_20260819/phenotype_normalization_mw
#   Rscript 1_code/0_prepare_raw/02_add_ontology_ids_to_phenotype_outputs.R \
#     --output_dir=2_data/raw/delivery_20260819/phenotype_normalization_ml --overwrite=FALSE

source(file.path("1_code", "00_phenomap_helpers.R"))

parse_add_ontology_ids_args <- function() {
  raw <- commandArgs(trailingOnly = TRUE)
  args <- list(
    output_dir = NA_character_,
    max_per_ontology = 10L,
    overwrite = TRUE
  )

  for (arg in raw) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% names(args)) args[[key]] <- value
  }

  # No default output_dir -- see 01_normalize_study_phenotype.R's arg parser
  # for why a dated delivery folder should never be a hardcoded default.
  if (is.na(args$output_dir) || !nzchar(args$output_dir)) {
    stop("--output_dir is required, e.g. --output_dir=2_data/raw/<delivery>/phenotype_normalization_mw")
  }

  args$max_per_ontology <- suppressWarnings(as.integer(args$max_per_ontology))
  if (is.na(args$max_per_ontology) || args$max_per_ontology < 1L) args$max_per_ontology <- 10L
  args$overwrite <- as.logical(args$overwrite)
  if (is.na(args$overwrite)) args$overwrite <- TRUE
  args
}

drop_existing_summary_cols <- function(df) {
  # NOTE: this whitelist must stay complete -- it must cover every source
  # phenomap_ontology_scope_by_type (in 01_normalize_study_phenotype.R)
  # actually searches, or a re-run will fail to drop the OLD *_ids/_labels/
  # ... summary columns for a source before merging in the new summary,
  # producing duplicate ".x"/".y" columns.
  prefixes <- c(
    "mondo", "efo", "mesh", "hpo", "ncit", "bto", "chebi", "cl", "clo", "ecto",
    "eo", "gene", "go", "hancestro", "hsapdv", "maxo", "mpath",
    "ncbitaxon", "oba", "orphanet", "po", "pr", "uberon"
  )
  summary_cols <- unlist(lapply(prefixes, function(prefix) {
    paste0(prefix, c("_ids", "_labels", "_queries", "_match_types", "_rule_scores"))
  }), use.names = FALSE)
  df[, setdiff(colnames(df), summary_cols), drop = FALSE]
}

drop_debug_cols <- function(df) {
  debug_cols <- c(
    "selection_prompt", "selection_raw_response", "selection_error",
    "extraction_prompt", "extraction_raw_response", "extraction_error",
    "final_ontology_definition"
  )
  df[, setdiff(colnames(df), debug_cols), drop = FALSE]
}

keep_review_cols <- function(df) {
  preferred_cols <- c(
    "study_id", "study_title", "current_phenotype", "principal_phenotype",
    "phenotype_type", "decision", "selected", "final_label",
    "final_phenotype_type", "final_ontology", "final_ontology_id",
    "selection_confidence", "manual_review", "normalization_status",
    "review_reason",
    "mondo_ids", "mondo_labels",
    "efo_ids", "efo_labels",
    "mesh_ids", "mesh_labels",
    "hpo_ids", "hpo_labels",
    "go_ids", "go_labels",
    "chebi_ids", "chebi_labels",
    "cl_ids", "cl_labels",
    "pr_ids", "pr_labels",
    "orphanet_ids", "orphanet_labels",
    "case_label", "control_label", "study_summary",
    "aliases", "query_terms", "extraction_confidence", "extraction_rationale"
  )
  keep <- preferred_cols[preferred_cols %in% colnames(df)]
  id_label_cols <- grep("^[a-z0-9_]+_(ids|labels)$", colnames(df), value = TRUE)
  keep <- unique(c(keep, setdiff(id_label_cols, keep)))
  df[, keep, drop = FALSE]
}

augment_one_table <- function(path, ontology_summary, overwrite = TRUE, clean_main = TRUE) {
  if (!file.exists(path)) {
    warning("Skipping missing file: ", path)
    return(invisible(NULL))
  }

  df <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  df <- drop_existing_summary_cols(df)
  out <- merge(df, ontology_summary, by = "study_id", all.x = TRUE, sort = FALSE)
  clean <- keep_review_cols(drop_debug_cols(out))

  out_path <- if (isTRUE(overwrite)) path else sub("\\.csv$", "_with_ontology_ids.csv", path)
  phenomap_write_csv(if (isTRUE(clean_main)) clean else out, out_path)
  message("Wrote ", out_path)
  invisible(out_path)
}

add_ontology_ids_to_phenotype_outputs <- function(output_dir,
                                                  max_per_ontology = 10L,
                                                  overwrite = TRUE,
                                                  clean_main = TRUE) {
  ols_path <- file.path(output_dir, "phenotype_ols_candidates.csv")
  if (!file.exists(ols_path)) stop("Missing OLS candidates file: ", ols_path)

  ontology_candidates <- utils::read.csv(ols_path, stringsAsFactors = FALSE, check.names = FALSE)
  ontology_summary <- phenomap_summarize_ontology_candidates_by_study(
    ontology_candidates = ontology_candidates,
    max_per_ontology = max_per_ontology
  )

  phenomap_write_csv(ontology_summary, file.path(output_dir, "phenotype_ontology_summary.csv"))

  targets <- file.path(output_dir, c(
    "phenotype_final_selection.csv",
    "phenotype_manual_review.csv",
    "phenotype_normalization_all.csv"
  ))

  invisible(lapply(
    targets,
    augment_one_table,
    ontology_summary = ontology_summary,
    overwrite = overwrite,
    clean_main = clean_main
  ))
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- parse_add_ontology_ids_args()
  add_ontology_ids_to_phenotype_outputs(
    output_dir = args$output_dir,
    max_per_ontology = args$max_per_ontology,
    overwrite = args$overwrite
  )
}
