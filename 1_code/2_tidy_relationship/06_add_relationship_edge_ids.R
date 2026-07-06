# Add sequential edge IDs to PhenoMAP relationship tables.
#
# This script overwrites existing relationship CSV files in place.
#
# Output ID format:
#   MET_MET_000001
#   MET_MOD_000001
#   MOD_STU_000001
#   STU_PHE_000001
#   MOD_MOD_000001
#
# Usage:
#   Rscript 1_code/2_tidy_relationship/06_add_relationship_edge_ids.R

source(file.path("1_code", "2_tidy_relationship", "00_relationship_helpers.R"))

sort_by_existing_cols <- function(df, cols) {
  cols <- cols[cols %in% colnames(df)]
  if (length(cols) == 0 || nrow(df) == 0) return(df)

  key_df <- df[, cols, drop = FALSE]
  key_df[] <- lapply(key_df, function(x) {
    x <- as.character(x)
    x[is.na(x)] <- ""
    x
  })
  df[do.call(order, key_df), , drop = FALSE]
}

add_edge_id <- function(path, prefix, sort_cols) {
  if (!file.exists(path)) {
    warning("Skipping missing relationship table: ", path)
    return(invisible(NULL))
  }

  df <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  if ("edge_id" %in% colnames(df)) {
    df$edge_id <- NULL
  }

  df <- sort_by_existing_cols(df, sort_cols)
  df$edge_id <- sprintf("%s_%06d", prefix, seq_len(nrow(df)))
  df <- df[, c("edge_id", setdiff(colnames(df), "edge_id")), drop = FALSE]

  phenomap_write_csv(df, path)
  message("Wrote ", nrow(df), " edge IDs to ", path)
  invisible(df)
}

add_relationship_edge_ids <- function(relationship_dir = file.path("2_data", "tidy_relationship")) {
  add_edge_id(
    path = file.path(relationship_dir, "edges_metabolite_metabolite.csv"),
    prefix = "MET_MET",
    sort_cols = c("metabolite_id_from", "metabolite_id_to", "reaction_id")
  )

  add_edge_id(
    path = file.path(relationship_dir, "edges_metabolite_module.csv"),
    prefix = "MET_MOD",
    sort_cols = c("metabolite_id", "module_id")
  )

  add_edge_id(
    path = file.path(relationship_dir, "edges_module_study.csv"),
    prefix = "MOD_STU",
    sort_cols = c("module_id", "study_id")
  )

  add_edge_id(
    path = file.path(relationship_dir, "edges_study_phenotype.csv"),
    prefix = "STU_PHE",
    sort_cols = c("study_id", "phenotype_id")
  )

  add_edge_id(
    path = file.path(relationship_dir, "edges_module_module.csv"),
    prefix = "MOD_MOD",
    sort_cols = c("module_id_1", "module_id_2")
  )

  invisible(TRUE)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_relationship_parse_args()
  add_relationship_edge_ids(relationship_dir = args$relationship_dir)
}

