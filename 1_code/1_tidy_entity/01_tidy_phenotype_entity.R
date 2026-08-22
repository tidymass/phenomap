# Build the Phenotype node table for PhenoMAP.
#
# Runs FIRST among the 1_tidy_entity scripts -- 03_tidy_study_entity.R reads
# this script's output (nodes_phenotype.csv) to compute each Study's
# Phenotype_ID. Order: 01 (this) -> 02_tidy_metabolite_entity.R ->
# 03_tidy_study_entity.R -> 04_tidy_module_entity.R.
#
# PhenoMAP now integrates two source databases (mw = Metabolomics Workbench,
# ml = MetaboLights) in one run. This script takes a separate phenotype_dir
# per database (each one, per 03_tidy_study_entity.R, has its own
# phenotype_manual_short.xlsx -- mw and ml manual reviews are kept as two
# separate files, not merged) and dedups phenotypes across BOTH at once, so
# the same real-world phenotype normalized in an mw study and an ml study
# still collapses to one node.
#
# Phenotype source (per database):
#   - manual review studies: <phenotype_dir>/phenotype_manual_short.xlsx
#   - all other studies: <phenotype_dir>/phenotype_final_selection.csv
# Studies with missing phenotype final label are excluded.
#
# Output:
#   2_data/tidy_entity/nodes_phenotype.csv

source(file.path("1_code", "00_phenomap_helpers.R"))

parse_args <- function() {
  args <- list(
    phenotype_dir_mw = "",
    phenotype_dir_ml = "",
    output_dir = file.path("2_data", "tidy_entity")
  )
  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) == 2 && kv[[1]] %in% names(args)) args[[kv[[1]]]] <- kv[[2]]
  }
  args
}

# Capitalize just the first character of the display label (sentence case,
# not title case) -- e.g. OLS/MONDO labels and GPT canonical_label commonly
# come back all-lowercase ("acute myeloid leukemia"), but the Phenotype node
# name shown in the KG should read "Acute myeloid leukemia". Only the first
# character changes; everything else (including any other capitals already
# present, e.g. gene symbols or acronyms) is left untouched.
capitalize_first <- function(x) {
  out <- x
  keep <- !is.na(x) & nzchar(x)
  out[keep] <- paste0(toupper(substr(x[keep], 1, 1)), substr(x[keep], 2, nchar(x[keep])))
  out
}

ols_link <- function(ols_id) {
  ols_id <- phenomap_clean_vec(ols_id)
  out <- rep(NA_character_, length(ols_id))
  keep <- !is.na(ols_id)
  out[keep] <- paste0("https://www.ebi.ac.uk/ols4/search?q=", utils::URLencode(ols_id[keep], reserved = TRUE))
  out
}

read_phenotype_rows <- function(phenotype_dir) {
  keep <- c("study_id", "final_label", "final_phenotype_type", "final_ontology_id", "final_ontology_definition")
  rows <- phenomap_read_phenotype_overrides(phenotype_dir, keep)

  rows$name <- capitalize_first(phenomap_clean_vec(rows$final_label))
  rows$type <- phenomap_clean_vec(rows$final_phenotype_type)
  rows$ols_id <- phenomap_clean_vec(rows$final_ontology_id)
  rows$ols_definition <- phenomap_clean_vec(rows$final_ontology_definition)
  rows <- rows[!is.na(rows$name), c("study_id", "name", "type", "ols_id", "ols_definition"), drop = FALSE]
  rows
}

add_missing_definitions <- function(rows, phenotype_dir) {
  ols <- utils::read.csv(
    file.path(phenotype_dir, "phenotype_ols_candidates.csv"),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  defs <- ols[!is.na(ols$ontology_id) & ols$ontology_id != "" & !is.na(ols$definition) & ols$definition != "",
              c("ontology_id", "definition"), drop = FALSE]
  defs <- defs[!duplicated(defs$ontology_id), , drop = FALSE]

  idx <- match(rows$ols_id, defs$ontology_id)
  missing_definition <- is.na(rows$ols_definition) & !is.na(idx)
  rows$ols_definition[missing_definition] <- defs$definition[idx[missing_definition]]
  rows
}

build_phenotype_entity <- function(phenotype_dir_mw, phenotype_dir_ml, output_dir) {
  if (!requireNamespace("readxl", quietly = TRUE)) stop("Package 'readxl' is required.")
  if (!nzchar(phenotype_dir_mw) || !nzchar(phenotype_dir_ml)) {
    stop("Both --phenotype_dir_mw and --phenotype_dir_ml must be provided.")
  }

  rows <- rbind(
    add_missing_definitions(read_phenotype_rows(phenotype_dir_mw), phenotype_dir_mw),
    add_missing_definitions(read_phenotype_rows(phenotype_dir_ml), phenotype_dir_ml)
  )
  rows$dedup_key <- ifelse(is.na(rows$ols_id), paste0("name:", tolower(rows$name)), paste0("id:", rows$ols_id))

  grouped <- split(rows, rows$dedup_key)
  out <- do.call(rbind, lapply(grouped, function(x) {
    data.frame(
      dedup_key = x$dedup_key[[1]],
      name = x$name[[1]],
      type = x$type[[1]],
      ols_id = x$ols_id[[1]],
      ols_link = ols_link(x$ols_id[[1]]),
      ols_definition = x$ols_definition[[1]],
      study_id = paste(sort(unique(x$study_id)), collapse = ";"),
      stringsAsFactors = FALSE
    )
  }))
  out <- out[order(tolower(out$name), out$ols_id), , drop = FALSE]
  # dedup_key (either "id:<OLS_ID>" or "name:<lowercase name>") is exactly
  # the natural key that identifies "the same phenotype" across reruns, so
  # it doubles as the stable-ID registry key -- see
  # phenomap_assign_stable_ids()'s header comment in 00_phenomap_helpers.R.
  out$Lab_ID <- phenomap_assign_stable_ids(
    out$dedup_key, "PPH", file.path(output_dir, "phenotype_id_registry.csv")
  )
  out$dedup_key <- NULL
  names(out) <- c(
    name = "Phenotype",
    type = "Type",
    ols_id = "OLS_ID",
    ols_link = "OLS_Link",
    ols_definition = "OLS_Definition",
    study_id = "Study_ID",
    Lab_ID = "Lab_ID"
  )[names(out)]
  out <- out[, c("Lab_ID", "Phenotype", "Type", "OLS_ID", "OLS_Link", "OLS_Definition", "Study_ID")]

  phenomap_write_csv(out, file.path(output_dir, "nodes_phenotype.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- parse_args()
  build_phenotype_entity(args$phenotype_dir_mw, args$phenotype_dir_ml, args$output_dir)
}
