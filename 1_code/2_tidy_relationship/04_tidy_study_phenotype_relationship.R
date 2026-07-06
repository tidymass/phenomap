# Build Study-Phenotype relationship table.
#
# Output:
#   2_data/tidy_relationship/edges_study_phenotype.csv

source(file.path("1_code", "2_tidy_relationship", "00_relationship_helpers.R"))

build_study_phenotype_relationship <- function(entity_dir = file.path("2_data", "tidy_entity"),
                                               output_dir = file.path("2_data", "tidy_relationship")) {
  studies <- phenomap_read_csv_required(file.path(entity_dir, "nodes_study.csv"))
  out <- data.frame(
    Lab_ID = sprintf("STU_PHE_%06d", seq_len(nrow(studies))),
    Study_ID = studies$Lab_ID,
    Relationship = "investigated",
    Phenotype_ID = studies$Phenotype_ID,
    stringsAsFactors = FALSE
  )
  out <- out[!is.na(out$Study_ID) & out$Study_ID != "" &
               !is.na(out$Phenotype_ID) & out$Phenotype_ID != "", , drop = FALSE]
  phenomap_write_csv(out, file.path(output_dir, "edges_study_phenotype.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_relationship_parse_args()
  build_study_phenotype_relationship(args$entity_dir, args$relationship_dir)
}
