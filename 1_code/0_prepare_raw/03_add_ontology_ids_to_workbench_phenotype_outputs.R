# Add per-ontology candidate IDs to existing Workbench phenotype outputs.
#
# This post-processes files produced by:
#   1_code/0_prepare_raw/02_normalize_workbench_phenotype.R
#
# It does not call GPT or OLS. It reads phenotype_ols_candidates.csv and merges
# per-study MONDO/EFO/MeSH/HPO candidate IDs into final/review/all tables.
# The main CSV files are kept compact for manual review.
#
# Usage:
#   Rscript 1_code/0_prepare_raw/03_add_ontology_ids_to_workbench_phenotype_outputs.R
#   Rscript 1_code/0_prepare_raw/03_add_ontology_ids_to_workbench_phenotype_outputs.R --overwrite=FALSE

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

parse_add_ontology_ids_args <- function() {
  raw <- commandArgs(trailingOnly = TRUE)
  args <- list(
    output_dir = file.path("2_data", "raw", "workbench_20260629", "phenotype_normalization"),
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

  args$max_per_ontology <- suppressWarnings(as.integer(args$max_per_ontology))
  if (is.na(args$max_per_ontology) || args$max_per_ontology < 1L) args$max_per_ontology <- 10L
  args$overwrite <- as.logical(args$overwrite)
  if (is.na(args$overwrite)) args$overwrite <- TRUE
  args
}

summarize_ontology_candidates_by_study <- function(ontology_candidates, max_per_ontology = 10L) {
  if (!is.data.frame(ontology_candidates) || nrow(ontology_candidates) == 0) {
    return(data.frame(study_id = character(0), stringsAsFactors = FALSE))
  }

  ontology_candidates$id_source <- tolower(sub(":.*$", "", ontology_candidates$ontology_id))
  ontology_candidates$id_source <- gsub("[^a-z0-9]+", "_", ontology_candidates$id_source)
  source_order <- c("mondo", "efo", "mesh", "hp", sort(setdiff(unique(ontology_candidates$id_source), c("mondo", "efo", "mesh", "hp"))))
  output_prefix <- ifelse(source_order == "hp", "hpo", source_order)

  ontology_candidates <- ontology_candidates[
    order(ontology_candidates$study_id, ontology_candidates$id_source, -ontology_candidates$rule_score, ontology_candidates$rank),
    ,
    drop = FALSE
  ]

  rows <- lapply(sort(unique(ontology_candidates$study_id)), function(study_id) {
    study_hits <- ontology_candidates[ontology_candidates$study_id == study_id, , drop = FALSE]
    row <- data.frame(study_id = study_id, stringsAsFactors = FALSE)

    for (i in seq_along(source_order)) {
      source <- source_order[[i]]
      prefix <- output_prefix[[i]]
      hits <- study_hits[study_hits$id_source == source, , drop = FALSE]
      if (nrow(hits) > 0) {
        hits <- hits[!duplicated(hits$ontology_id), , drop = FALSE]
        hits <- head(hits, max_per_ontology)
      }

      row[[paste0(prefix, "_ids")]] <- phenomap_collapse(hits$ontology_id)
      row[[paste0(prefix, "_labels")]] <- phenomap_collapse(hits$ontology_label)
      row[[paste0(prefix, "_queries")]] <- phenomap_collapse(hits$query)
      row[[paste0(prefix, "_match_types")]] <- phenomap_collapse(hits$rule_match_type)
      row[[paste0(prefix, "_rule_scores")]] <- phenomap_collapse(hits$rule_score)
    }

    row
  })

  do.call(rbind, rows)
}

drop_existing_summary_cols <- function(df) {
  prefixes <- c(
    "mondo", "efo", "mesh", "hpo", "bto", "chebi", "cl", "clo", "ecto",
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

add_ontology_ids_to_workbench_phenotype_outputs <- function(output_dir = file.path("2_data", "raw", "workbench_20260629", "phenotype_normalization"),
                                                            max_per_ontology = 10L,
                                                            overwrite = TRUE,
                                                            clean_main = TRUE) {
  ols_path <- file.path(output_dir, "phenotype_ols_candidates.csv")
  if (!file.exists(ols_path)) stop("Missing OLS candidates file: ", ols_path)

  ontology_candidates <- utils::read.csv(ols_path, stringsAsFactors = FALSE, check.names = FALSE)
  ontology_summary <- summarize_ontology_candidates_by_study(
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
  add_ontology_ids_to_workbench_phenotype_outputs(
    output_dir = args$output_dir,
    max_per_ontology = args$max_per_ontology,
    overwrite = args$overwrite
  )
}
