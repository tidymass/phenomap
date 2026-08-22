# Build Metabolite-Metabolite relationship table from MRN edges.
#
# Output:
#   2_data/tidy_relationship/edges_metabolite_metabolite.csv

source(file.path("1_code", "2_tidy_relationship", "00_relationship_helpers.R"))

build_metabolite_metabolite_relationship <- function(entity_dir = file.path("2_data", "tidy_entity"),
                                                     output_dir = file.path("2_data", "tidy_relationship")) {
  metabolites <- phenomap_read_csv_required(file.path(entity_dir, "nodes_metabolite.csv"))
  mrn_edges <- phenomap_extract_mrn_edges()

  from_inchi <- phenomap_first_text_col(mrn_edges, c("INCHI_From", "from_inchi", "source_inchi", "from"))
  to_inchi <- phenomap_first_text_col(mrn_edges, c("INCHI_To", "to_inchi", "target_inchi", "to"))

  from_id <- metabolites$Lab_ID[match(from_inchi, metabolites$INCHI_ID)]
  to_id <- metabolites$Lab_ID[match(to_inchi, metabolites$INCHI_ID)]
  out <- data.frame(
    Metabolite_ID_1 = pmin(from_id, to_id),
    Metabolite_ID_2 = pmax(from_id, to_id),
    stringsAsFactors = FALSE
  )
  out <- out[!is.na(out$Metabolite_ID_1) & out$Metabolite_ID_1 != "" &
               !is.na(out$Metabolite_ID_2) & out$Metabolite_ID_2 != "" &
               out$Metabolite_ID_1 != out$Metabolite_ID_2, , drop = FALSE]
  out <- out[!duplicated(out), , drop = FALSE]
  out <- out[order(out$Metabolite_ID_1, out$Metabolite_ID_2), , drop = FALSE]
  # Metabolite_ID_1/2 are already pmin/pmax-normalized, permanent Metabolite
  # Lab_IDs, so the pair itself is a stable natural key across reruns -- see
  # phenomap_assign_stable_ids()'s header comment in 00_phenomap_helpers.R.
  edge_key <- paste(out$Metabolite_ID_1, out$Metabolite_ID_2)
  out <- data.frame(
    Lab_ID = phenomap_assign_stable_ids(
      edge_key, "MET_MET_", file.path(output_dir, "metabolite_metabolite_edge_id_registry.csv")
    ),
    Metabolite_ID_1 = out$Metabolite_ID_1,
    Relationship = "connected with",
    Metabolite_ID_2 = out$Metabolite_ID_2,
    stringsAsFactors = FALSE
  )

  phenomap_write_csv(out, file.path(output_dir, "edges_metabolite_metabolite.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_relationship_parse_args()
  build_metabolite_metabolite_relationship(args$entity_dir, args$relationship_dir)
}
