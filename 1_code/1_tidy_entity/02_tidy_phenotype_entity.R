# Build the Phenotype node table for PhenoMAP.
#
# Phenotype source:
#   - manual review studies: phenotype_manual_short.xlsx
#   - all other studies: phenotype_final_selection.csv
# Studies with missing phenotype final label are excluded.
#
# Output:
#   2_data/tidy_entity/nodes_phenotype.csv

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

parse_args <- function() {
  args <- list(
    phenotype_dir = file.path("2_data", "raw", "workbench_20260629", "phenotype_normalization"),
    output_dir = file.path("2_data", "tidy_entity")
  )
  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) == 2 && kv[[1]] %in% names(args)) args[[kv[[1]]]] <- kv[[2]]
  }
  args
}

clean <- function(x) {
  x <- as.character(x)
  x <- trimws(x)
  x[!nzchar(x) | toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")] <- NA_character_
  x
}

ols_link <- function(ols_id) {
  ols_id <- clean(ols_id)
  out <- rep(NA_character_, length(ols_id))
  keep <- !is.na(ols_id)
  out[keep] <- paste0("https://www.ebi.ac.uk/ols4/search?q=", utils::URLencode(ols_id[keep], reserved = TRUE))
  out
}

read_phenotype_rows <- function(phenotype_dir) {
  final <- utils::read.csv(
    file.path(phenotype_dir, "phenotype_final_selection.csv"),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  manual <- as.data.frame(readxl::read_excel(file.path(phenotype_dir, "phenotype_manual_short.xlsx")))

  keep <- c("study_id", "final_label", "final_phenotype_type", "final_ontology_id", "final_ontology_definition")
  for (col in setdiff(keep, names(final))) final[[col]] <- NA_character_
  for (col in setdiff(keep, names(manual))) manual[[col]] <- NA_character_

  final <- final[, keep, drop = FALSE]
  manual <- manual[, keep, drop = FALSE]
  rows <- rbind(final[!final$study_id %in% manual$study_id, ], manual)

  rows$name <- clean(rows$final_label)
  rows$type <- clean(rows$final_phenotype_type)
  rows$ols_id <- clean(rows$final_ontology_id)
  rows$ols_definition <- clean(rows$final_ontology_definition)
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

build_phenotype_entity <- function(phenotype_dir, output_dir) {
  if (!requireNamespace("readxl", quietly = TRUE)) stop("Package 'readxl' is required.")

  rows <- add_missing_definitions(read_phenotype_rows(phenotype_dir), phenotype_dir)
  rows$dedup_key <- ifelse(is.na(rows$ols_id), paste0("name:", tolower(rows$name)), paste0("id:", rows$ols_id))

  grouped <- split(rows, rows$dedup_key)
  out <- do.call(rbind, lapply(grouped, function(x) {
    data.frame(
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
  out$Lab_ID <- sprintf("PMAP_PHENO_%06d", seq_len(nrow(out)))
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
  build_phenotype_entity(args$phenotype_dir, args$output_dir)
}
