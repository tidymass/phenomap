# Generate PhenoMAP Metabolite entity table.
#
# Unlike the other three 1_tidy_entity scripts, this one does not depend on
# which studies are in the current delivery -- its only input is the
# featuremap MRN reference resource (the shared compound library), not any
# per-study output. So it only needs re-running when that MRN resource
# itself is updated, not every time new studies are merged in; 04's
# metabolite_id_map lookup just needs nodes_metabolite.csv to already exist
# on disk from a prior run.
#
# Runs SECOND among the 1_tidy_entity scripts (order: 01_tidy_phenotype_entity.R
# -> 02 (this) -> 03_tidy_study_entity.R -> 04_tidy_module_entity.R), but has
# no ordering dependency on 01/03 -- it's placed here only because 04 needs
# its output.
#
# Output:
#   nodes_metabolite.csv
#
# Source: featuremap MRN resource nodes (igraph or tbl_graph).
# ID: PMAP_META_xxxx assigned by compound name alphabetical order.

source(file.path("1_code", "00_phenomap_helpers.R"))

build_metabolite_entity <- function(output_dir = file.path("2_data", "tidy_entity")) {
  mrn <- phenomap_try_load_featuremap_resource("mrn")
  if (is.null(mrn)) stop("Could not load featuremap MRN resource 'mrn'.")

  if (requireNamespace("igraph", quietly = TRUE) && inherits(mrn, "igraph")) {
    nodes <- igraph::as_data_frame(mrn, what = "vertices")
  } else {
    nodes <- as.data.frame(tidygraph::activate(mrn, nodes))
  }

  hmdb  <- phenomap_col(nodes, "HMDB_ID",       phenomap_col(nodes, "HMDB.ID"))
  kegg  <- phenomap_col(nodes, "KEGG_ID",       phenomap_col(nodes, "KEGG.ID"))
  inchi <- phenomap_col(nodes, "INCHI_ID")
  name  <- phenomap_col(nodes, "Compound_name", phenomap_col(nodes, "Compound.name"))

  out <- data.frame(
    inchi_id       = phenomap_clean_vec(inchi),
    hmdb_id        = phenomap_clean_vec(hmdb),
    kegg_id        = phenomap_clean_vec(kegg),
    metabolite_name = phenomap_clean_vec(name),
    hmdb_chemical_class = phenomap_col(nodes, "hmdb_chemical_class", NA_character_),
    kegg_chemical_class = phenomap_col(nodes, "kegg_chemical_class", NA_character_),
    origin         = phenomap_col(nodes, "origin", NA_character_),
    stringsAsFactors = FALSE
  )

  out <- out[!is.na(out$inchi_id), , drop = FALSE]
  out <- out[!duplicated(out$inchi_id), , drop = FALSE]

  join_ref <- function(df, resource_name, id_col) {
    ref <- phenomap_try_load_featuremap_resource(resource_name)
    if (is.null(ref) || !is.data.frame(ref) || !id_col %in% colnames(df)) return(df)
    ref <- as.data.frame(ref, stringsAsFactors = FALSE)
    if (!"id" %in% colnames(ref)) return(df)
    class_col <- phenomap_first_existing_col(ref, c("class", "chemical_class", "super_class", "direct_parent"))
    origin_col <- phenomap_first_existing_col(ref, c("origin", "biological_origin", "source"))
    keep_cols <- unique(c("id", class_col, origin_col))
    keep_cols <- keep_cols[!is.na(keep_cols) & keep_cols %in% colnames(ref)]
    ref <- ref[!duplicated(ref$id), keep_cols, drop = FALSE]
    names(ref)[names(ref) == "id"] <- id_col
    suffix <- sub("_id$", "", id_col)
    for (nm in setdiff(names(ref), id_col)) names(ref)[names(ref) == nm] <- paste0(nm, ".", suffix)
    merge(df, ref, by = id_col, all.x = TRUE, sort = FALSE)
  }

  out <- join_ref(out, "functional_reference_hmdb", "hmdb_id")
  out <- join_ref(out, "functional_reference_kegg", "kegg_id")

  coalesce_cols <- function(df, out_col, candidates) {
    vals <- rep(NA_character_, nrow(df))
    for (nm in candidates[candidates %in% colnames(df)]) {
      cur <- as.character(df[[nm]])
      vals[is.na(vals)] <- cur[is.na(vals)]
    }
    df[[out_col]] <- vals
    df
  }

  out <- coalesce_cols(out, "hmdb_chemical_class",
    c("class.hmdb", "chemical_class.hmdb", "super_class.hmdb", "direct_parent.hmdb"))
  out <- coalesce_cols(out, "kegg_chemical_class",
    c("class.kegg", "chemical_class.kegg", "super_class.kegg", "direct_parent.kegg"))
  out <- coalesce_cols(out, "origin",
    c("origin.hmdb", "biological_origin.hmdb", "origin.kegg", "biological_origin.kegg"))

  out <- out[order(tolower(out$metabolite_name)), , drop = FALSE]

  out$id <- sprintf("PMAP_META_%04d", seq_len(nrow(out)))
  out$hmdb_url <- vapply(out$hmdb_id, phenomap_hmdb_url, character(1))
  out$kegg_url <- vapply(out$kegg_id, phenomap_kegg_url, character(1))

  out <- out[, c(
    "id", "metabolite_name", "inchi_id", "hmdb_id", "kegg_id",
    "hmdb_chemical_class", "kegg_chemical_class", "origin",
    "hmdb_url", "kegg_url"
  )]

  phenomap_write_csv(out, file.path(output_dir, "nodes_metabolite.csv"))
  invisible(out)
}

format_metabolite_entity <- function(output_dir = file.path("2_data", "tidy_entity")) {
  path <- file.path(output_dir, "nodes_metabolite.csv")
  out <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  # inchi_id is a globally unique, permanent natural key for a metabolite --
  # unlike the intermediate `id` (PMAP_META_####, assigned purely by
  # alphabetical row position within this run and discarded below), it
  # doubles directly as the stable-ID registry key.
  out$Lab_ID <- phenomap_assign_stable_ids(
    out$inchi_id, "PME", file.path(output_dir, "metabolite_id_registry.csv")
  )
  out$id <- NULL
  names(out) <- c(
    metabolite_name = "Metabolite_Name",
    inchi_id = "INCHI_ID",
    hmdb_id = "HMDB_ID",
    kegg_id = "KEGG_ID",
    hmdb_chemical_class = "HMDB_Chemical_Class",
    kegg_chemical_class = "KEGG_Chemical_Class",
    origin = "Origin",
    hmdb_url = "HMDB_URL",
    kegg_url = "KEGG_URL",
    Lab_ID = "Lab_ID"
  )[names(out)]
  out <- out[, c("Lab_ID", setdiff(names(out), "Lab_ID")), drop = FALSE]
  phenomap_write_csv(out, path)
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_parse_args()
  build_metabolite_entity(output_dir = args$output_dir)
  format_metabolite_entity(output_dir = args$output_dir)
}
