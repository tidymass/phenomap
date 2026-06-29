# Generate PhenoMAP Metabolite entity table.
#
# Output:
#   nodes_metabolite.csv
#
# Current source priority:
#   1. featuremap MRN resource nodes
#   2. featuremap functional/pathway references, when cached/available
#
# Note:
#   FeatureMAP modules are detected on MRN nodes, so the metabolite master table
#   should come directly from the MRN. Case-level results will be used later for
#   Metabolite-Module relationships, not for defining the metabolite universe.
#   metabolite_id follows the MRN node convention and equals INCHI_ID when
#   available.

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

standardize_metabolite_rows <- function(df) {
  if (!is.data.frame(df) || nrow(df) == 0) return(data.frame())

  hmdb <- phenomap_col(df, "HMDB_ID", phenomap_col(df, "HMDB.ID"))
  kegg <- phenomap_col(df, "KEGG_ID", phenomap_col(df, "KEGG.ID"))
  inchi <- phenomap_col(df, "INCHI_ID")
  name <- phenomap_col(df, "Compound_name", phenomap_col(df, "Compound.name"))

  inchikey <- phenomap_col(df, "InChIKey", phenomap_col(df, "INCHIKEY"))

  out <- data.frame(
    metabolite_id = mapply(
      phenomap_make_metabolite_id,
      hmdb_id = hmdb,
      kegg_id = kegg,
      inchikey = inchikey,
      inchi_id = inchi,
      name = name,
      USE.NAMES = FALSE
    ),
    hmdb_id = as.character(hmdb),
    kegg_id = as.character(kegg),
    inchi_id = as.character(inchi),
    metabolite_name = as.character(name),
    stringsAsFactors = FALSE
  )

  out$hmdb_id[!nzchar(out$hmdb_id) | out$hmdb_id %in% c("NA", "<NA>")] <- NA
  out$kegg_id[!nzchar(out$kegg_id) | out$kegg_id %in% c("NA", "<NA>")] <- NA
  out$inchi_id[!nzchar(out$inchi_id) | out$inchi_id %in% c("NA", "<NA>")] <- NA
  out$metabolite_name[!nzchar(out$metabolite_name) | out$metabolite_name %in% c("NA", "<NA>")] <- NA

  out$hmdb_url <- vapply(out$hmdb_id, phenomap_hmdb_url, character(1))
  out$kegg_url <- vapply(out$kegg_id, phenomap_kegg_url, character(1))

  out
}

build_metabolite_entity_one_case <- function(case_dir,
                                             include_annotation_table = FALSE) {
  res <- phenomap_load_res(case_dir)
  if (is.null(res)) return(data.frame())

  module_table <- phenomap_safe_df(res$module_table)

  rows <- list(standardize_metabolite_rows(module_table))
  if (isTRUE(include_annotation_table)) {
    anno_table <- phenomap_safe_df(res$anno_feature_table2)
    rows <- c(rows, list(standardize_metabolite_rows(anno_table)))
  }

  rows <- rows[vapply(rows, nrow, integer(1)) > 0]
  if (length(rows) == 0) return(data.frame())
  out <- do.call(rbind, rows)
  out <- out[!is.na(out$metabolite_id) & nzchar(out$metabolite_id), , drop = FALSE]
  out <- out[!duplicated(out$metabolite_id), , drop = FALSE]
  out
}

build_metabolite_entity_from_mrn <- function() {
  mrn <- phenomap_try_load_featuremap_resource("mrn")
  if (is.null(mrn)) {
    stop("Could not load featuremap MRN resource 'mrn'.")
  }

  nodes <- NULL
  if (requireNamespace("igraph", quietly = TRUE) && inherits(mrn, "igraph")) {
    nodes <- igraph::as_data_frame(mrn, what = "vertices")
  } else if (requireNamespace("tidygraph", quietly = TRUE) && inherits(mrn, "tbl_graph")) {
    nodes <- as.data.frame(tidygraph::activate(mrn, nodes))
  }

  if (is.null(nodes) || !is.data.frame(nodes) || nrow(nodes) == 0) {
    stop("Could not extract node table from MRN resource.")
  }

  out <- standardize_metabolite_rows(nodes)
  out <- out[!is.na(out$metabolite_id) & nzchar(out$metabolite_id), , drop = FALSE]
  out <- out[!duplicated(out$metabolite_id), , drop = FALSE]
  out
}

build_metabolite_entity <- function(case_root,
                                    output_dir = file.path("2_data", "tidy_entity"),
                                    enrich_from_featuremap_resources = TRUE,
                                    include_annotation_table = FALSE,
                                    source = c("mrn", "case_modules")) {
  source <- match.arg(source)

  if (identical(source, "mrn")) {
    message("Reading metabolites from featuremap MRN resource.")
    out <- build_metabolite_entity_from_mrn()
  } else {
    case_dirs <- phenomap_case_dirs(case_root, require_meta = TRUE, require_res = TRUE)

    seen <- new.env(parent = emptyenv())
    chunks <- list()
    chunk_i <- 0L

    for (case_dir in case_dirs) {
      message("Reading metabolites from ", basename(case_dir))
      one <- build_metabolite_entity_one_case(
        case_dir = case_dir,
        include_annotation_table = include_annotation_table
      )

      if (nrow(one) > 0) {
        keep <- !vapply(one$metabolite_id, exists, logical(1), envir = seen, inherits = FALSE)
        if (any(keep)) {
          new_ids <- one$metabolite_id[keep]
          for (id in new_ids) assign(id, TRUE, envir = seen)
          chunk_i <- chunk_i + 1L
          chunks[[chunk_i]] <- one[keep, , drop = FALSE]
        }
      }

      rm(one)
      gc(verbose = FALSE)
    }

    if (length(chunks) == 0) {
      out <- data.frame(
        metabolite_id = character(),
        hmdb_id = character(),
        kegg_id = character(),
        inchi_id = character(),
        metabolite_name = character(),
        stringsAsFactors = FALSE
      )
    } else {
      out <- do.call(rbind, chunks)
      rm(chunks)
      gc(verbose = FALSE)
    }
  }

  if (isTRUE(enrich_from_featuremap_resources)) {
    message("Adding metabolite reference fields when featuremap resources are available.")
    out <- phenomap_add_reference_fields(out)
  } else {
    out$hmdb_chemical_class <- NA_character_
    out$kegg_chemical_class <- NA_character_
    out$hmdb_pathway <- NA_character_
    out$kegg_pathway <- NA_character_
    out$origin <- NA_character_
    out <- out[, c(
      "metabolite_id", "hmdb_id", "kegg_id", "inchi_id",
      "metabolite_name", "hmdb_chemical_class", "kegg_chemical_class",
      "hmdb_pathway", "kegg_pathway",
      "origin", "hmdb_url", "kegg_url"
    ), drop = FALSE]
  }

  out <- out[order(out$metabolite_id), , drop = FALSE]

  phenomap_write_csv(out, file.path(output_dir, "nodes_metabolite.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_parse_args()
  build_metabolite_entity(
    case_root = args$case_root,
    output_dir = args$output_dir
  )
}
