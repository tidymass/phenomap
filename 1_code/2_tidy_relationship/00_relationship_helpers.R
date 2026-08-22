# Shared helpers for PhenoMAP relationship table export.

source(file.path("1_code", "00_phenomap_helpers.R"))

phenomap_relationship_parse_args <- function(default_output_dir = file.path("2_data", "tidy_relationship")) {
  args <- phenomap_parse_args(default_output_dir = default_output_dir)
  raw <- commandArgs(trailingOnly = TRUE)

  args$entity_dir <- file.path("2_data", "tidy_entity")
  args$relationship_dir <- args$output_dir
  args$include_annotation_table <- FALSE
  args$embedding_model <- "text-embedding-3-small"
  args$embedding_batch_size <- 64L
  args$cross_study_only <- TRUE
  args$min_similarity_score <- 0

  for (arg in raw) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% names(args)) args[[key]] <- value
  }

  if (identical(args$relationship_dir, default_output_dir)) {
    args$relationship_dir <- args$output_dir
  }
  args$include_annotation_table <- as.logical(args$include_annotation_table)
  if (is.na(args$include_annotation_table)) args$include_annotation_table <- FALSE
  args$cross_study_only <- as.logical(args$cross_study_only)
  if (is.na(args$cross_study_only)) args$cross_study_only <- TRUE
  args$embedding_batch_size <- suppressWarnings(as.integer(args$embedding_batch_size))
  if (is.na(args$embedding_batch_size) || args$embedding_batch_size < 1L) {
    args$embedding_batch_size <- 64L
  }
  args$min_similarity_score <- suppressWarnings(as.numeric(args$min_similarity_score))
  if (is.na(args$min_similarity_score)) args$min_similarity_score <- 0
  args
}

phenomap_read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

phenomap_split_semicolon <- function(x) {
  x <- phenomap_clean_scalar(x)
  if (is.na(x)) return(character(0))
  phenomap_drop_empty(unlist(strsplit(x, ";", fixed = TRUE), use.names = FALSE))
}

phenomap_normalize_minmax <- function(x) {
  x <- suppressWarnings(as.numeric(x))
  out <- rep(NA_real_, length(x))
  ok <- !is.na(x)
  if (!any(ok)) return(out)

  xmin <- min(x[ok])
  xmax <- max(x[ok])
  if (identical(xmin, xmax)) {
    out[ok] <- 1
  } else {
    out[ok] <- (x[ok] - xmin) / (xmax - xmin)
  }
  out
}

phenomap_module_node_lookup <- function(entity_dir = file.path("2_data", "tidy_entity")) {
  modules <- phenomap_read_csv_required(file.path(entity_dir, "nodes_module.csv"))
  needed <- c(
    "Lab_ID", "Study_ID", "module_id", "anchor_metabolite_ids", "supporting_metabolite_ids",
    "contextual_metabolite_ids",
    "Module_size", "Annotated_nodes", "Module_score", "p", "fdr"
  )
  for (nm in needed) if (!nm %in% colnames(modules)) modules[[nm]] <- NA
  modules[, needed, drop = FALSE]
}

phenomap_extract_mrn_edges <- function(mrn = NULL) {
  if (is.null(mrn)) mrn <- phenomap_try_load_featuremap_resource("mrn")
  if (is.null(mrn)) stop("Could not load featuremap MRN resource 'mrn'.")

  edges <- NULL
  if (requireNamespace("igraph", quietly = TRUE) && inherits(mrn, "igraph")) {
    edges <- igraph::as_data_frame(mrn, what = "edges")
  } else if (requireNamespace("tidygraph", quietly = TRUE) && inherits(mrn, "tbl_graph")) {
    edges <- as.data.frame(tidygraph::activate(mrn, edges))
  }

  if (is.null(edges) || !is.data.frame(edges) || nrow(edges) == 0) {
    stop("Could not extract edge table from MRN resource.")
  }
  edges
}

phenomap_first_numeric_col <- function(df, candidates) {
  hit <- candidates[candidates %in% colnames(df)]
  if (length(hit) == 0) return(rep(NA_real_, nrow(df)))
  suppressWarnings(as.numeric(df[[hit[[1]]]]))
}

phenomap_first_text_col <- function(df, candidates) {
  hit <- candidates[candidates %in% colnames(df)]
  if (length(hit) == 0) return(rep(NA_character_, nrow(df)))
  as.character(df[[hit[[1]]]])
}

phenomap_clean_inchi <- function(x) {
  x <- phenomap_drop_empty(x)
  x
}

phenomap_jaccard <- function(x, y) {
  x <- unique(phenomap_drop_empty(x))
  y <- unique(phenomap_drop_empty(y))
  union_n <- length(union(x, y))
  overlap_n <- length(intersect(x, y))
  list(
    overlap_n = overlap_n,
    union_n = union_n,
    jaccard = if (union_n == 0) 0 else overlap_n / union_n
  )
}

phenomap_normalize_token <- function(x) {
  x <- tolower(phenomap_clean_scalar(x, ""))
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(gsub("[[:space:]]+", " ", x))
}

phenomap_tokenize_text <- function(x) {
  x <- phenomap_normalize_token(x)
  if (!nzchar(x)) return(character(0))
  phenomap_drop_empty(unlist(strsplit(x, "[[:space:]]+"), use.names = FALSE))
}
