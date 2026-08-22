# Generate PhenoMAP module-study relationship table.
#
# Output:
#   edges_module_study.csv

source(file.path("1_code", "2_tidy_relationship", "00_relationship_helpers.R"))

build_module_study_relationship <- function(entity_dir = file.path("2_data", "tidy_entity"),
                                            output_dir = file.path("2_data", "tidy_relationship")) {
  modules <- phenomap_read_csv_required(file.path(entity_dir, "nodes_module.csv"))
  if (!all(c("Lab_ID", "Study_ID") %in% colnames(modules))) {
    stop("nodes_module.csv must contain Lab_ID and Study_ID.")
  }

  out <- data.frame(
    Module_ID = modules$Lab_ID,
    Relationship = "reported in",
    Study_ID = modules$Study_ID,
    stringsAsFactors = FALSE
  )

  keep <- !is.na(out$Module_ID) & nzchar(out$Module_ID) &
    !is.na(out$Study_ID) & nzchar(out$Study_ID)
  out <- out[keep, , drop = FALSE]
  out <- out[!duplicated(out[, c("Module_ID", "Study_ID")]), , drop = FALSE]
  out <- out[order(out$Study_ID, out$Module_ID), , drop = FALSE]
  # Module_ID + Study_ID are already permanent, stable Lab_IDs.
  edge_key <- paste(out$Module_ID, out$Study_ID)
  out <- data.frame(
    Lab_ID = phenomap_assign_stable_ids(
      edge_key, "MOD_STU_", file.path(output_dir, "module_study_edge_id_registry.csv")
    ),
    out,
    stringsAsFactors = FALSE
  )

  phenomap_write_csv(out, file.path(output_dir, "edges_module_study.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_relationship_parse_args()
  build_module_study_relationship(
    entity_dir = args$entity_dir,
    output_dir = args$relationship_dir
  )
}
