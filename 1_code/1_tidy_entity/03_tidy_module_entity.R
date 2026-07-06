# Generate PhenoMAP module entity table.
#
# Output:
#   nodes_module.csv

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

load_res_sig <- function(case_dir) {
  path <- file.path(case_dir, "anno_result", "res_sig.rda")
  if (!file.exists(path)) return(NULL)

  env <- new.env(parent = emptyenv())
  object_names <- load(path, envir = env)
  if ("res_sig" %in% object_names) return(env$res_sig)

  for (nm in object_names) {
    obj <- env[[nm]]
    if (!is.null(obj$object_type) && identical(obj$object_type, "featuremap_result")) {
      return(obj)
    }
  }
  env[[object_names[[1]]]]
}

read_study_id_map <- function(path) {
  study <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  if (!all(c("Lab_ID", "Accession") %in% colnames(study))) {
    stop("nodes_study.csv must contain Lab_ID and Accession.")
  }
  setNames(study$Lab_ID, study$Accession)
}

drop_empty <- function(x) {
  x <- trimws(as.character(x))
  x[!is.na(x) & nzchar(x) & !toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")]
}

split_ids <- function(x) {
  if (is.null(x) || length(x) == 0) return(character(0))
  x <- drop_empty(x)
  if (length(x) == 0) return(character(0))
  ids <- drop_empty(unlist(strsplit(x, ";", fixed = TRUE), use.names = FALSE))
  unique(ids)
}

collapse_ids <- function(x) {
  x <- unique(drop_empty(x))
  if (length(x) == 0) return(NA_character_)
  paste(x, collapse = "; ")
}

names_for_ids <- function(ids, module_table) {
  if (length(ids) == 0 || !"Compound_name" %in% colnames(module_table)) return(NA_character_)
  hit <- module_table[module_table$INCHI_ID %in% ids, c("INCHI_ID", "Compound_name"), drop = FALSE]
  hit <- hit[match(ids, hit$INCHI_ID), , drop = FALSE]
  collapse_ids(hit$Compound_name)
}

normalize_pathway_name <- function(x) {
  x <- sub("\\s*\\([^)]*\\)\\s*$", "", as.character(x))
  x <- tolower(trimws(x))
  gsub("[[:space:]]+", " ", x)
}

pathway_ids_for_module <- function(pathway_coverage, source, module_id, pathway_names) {
  df <- pathway_coverage[[source]]
  if (is.null(df) || !is.data.frame(df) || !"module_id" %in% colnames(df) || !"pathway_id" %in% colnames(df)) {
    return(NA_character_)
  }
  df <- df[df$module_id == module_id, , drop = FALSE]
  if (nrow(df) == 0) return(NA_character_)
  if (!"pathway_name" %in% colnames(df)) return(NA_character_)

  names <- drop_empty(unlist(strsplit(phenomap_clean_scalar(pathway_names, ""), ";", fixed = TRUE), use.names = FALSE))
  if (length(names) == 0) return(NA_character_)

  matched_ids <- character(0)
  keys <- normalize_pathway_name(df$pathway_name)
  for (name in names) {
    idx <- match(normalize_pathway_name(name), keys)
    if (!is.na(idx)) matched_ids <- c(matched_ids, df$pathway_id[[idx]])
  }
  collapse_ids(matched_ids)
}

build_module_entity_one_case <- function(case_dir, study_id_map) {
  accession <- basename(case_dir)
  study_lab_id <- unname(study_id_map[accession])
  if (length(study_lab_id) == 0 || is.na(study_lab_id) || !nzchar(study_lab_id)) {
    return(data.frame())
  }

  res <- load_res_sig(case_dir)
  module_function <- phenomap_safe_df(res$module_function)
  if (nrow(module_function) == 0) return(data.frame())
  module_table <- phenomap_safe_df(res$module_table)
  pathway_coverage <- res$module_evidence$pathway_coverage

  if (all(c("Module", "INCHI_ID") %in% colnames(module_table))) {
    module_table$Module <- as.character(module_table$Module)
    module_table$INCHI_ID <- as.character(module_table$INCHI_ID)
    module_function$contextual_metabolite_ids <- NA_character_
    module_function$contextual_metabolites <- NA_character_
    module_function$hmdb_pathway_ids <- NA_character_
    module_function$kegg_pathway_ids <- NA_character_

    for (i in seq_len(nrow(module_function))) {
      local_module_id <- as.character(module_function$module_id[[i]])
      local_table <- module_table[module_table$Module == local_module_id, , drop = FALSE]

      all_ids <- split_ids(local_table$INCHI_ID)
      anchor_ids <- intersect(split_ids(module_function$anchor_metabolite_ids[[i]]), all_ids)
      top_ids <- setdiff(intersect(split_ids(module_function$top_metabolite_ids[[i]]), all_ids), anchor_ids)
      contextual_ids <- setdiff(all_ids, union(anchor_ids, top_ids))

      module_function$top_metabolite_ids[[i]] <- collapse_ids(top_ids)
      module_function$top_metabolites[[i]] <- names_for_ids(top_ids, local_table)
      module_function$contextual_metabolite_ids[[i]] <- collapse_ids(contextual_ids)
      module_function$contextual_metabolites[[i]] <- names_for_ids(contextual_ids, local_table)
      module_function$hmdb_pathway_ids[[i]] <- pathway_ids_for_module(
        pathway_coverage,
        "hmdb",
        local_module_id,
        module_function$top_hmdb_pathways[[i]]
      )
      module_function$kegg_pathway_ids[[i]] <- pathway_ids_for_module(
        pathway_coverage,
        "kegg",
        local_module_id,
        module_function$top_kegg_pathways[[i]]
      )
    }
  }

  data.frame(
    Study_ID = rep(study_lab_id, nrow(module_function)),
    module_function,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

build_module_entity <- function(
  case_root = file.path("2_data", "raw", "workbench_20260629", "update_res_only_260705"),
  output_dir = file.path("2_data", "tidy_entity")
) {
  study_id_map <- read_study_id_map(file.path(output_dir, "nodes_study.csv"))
  case_dirs <- list.dirs(case_root, recursive = FALSE, full.names = TRUE)
  case_dirs <- case_dirs[file.exists(file.path(case_dirs, "anno_result", "res_sig.rda"))]

  rows <- lapply(case_dirs, build_module_entity_one_case, study_id_map = study_id_map)
  rows <- rows[vapply(rows, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))]

  if (length(rows) == 0) {
    out <- data.frame()
  } else {
    out <- do.call(rbind, rows)
    module_order <- suppressWarnings(as.integer(sub("^M", "", as.character(out$module_id))))
    module_order[is.na(module_order)] <- seq_along(module_order)[is.na(module_order)]
    out <- out[order(out$Study_ID, module_order), , drop = FALSE]
    out <- data.frame(
      Lab_ID = sprintf("PMAP_MOUDLE_%06d", seq_len(nrow(out))),
      out,
      stringsAsFactors = FALSE,
      check.names = FALSE
    )
  }

  phenomap_write_csv(out, file.path(output_dir, "nodes_module.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_parse_args()
  if (identical(args$case_root, file.path("..", "featuremap_case", "2_data", "case_metabolights"))) {
    args$case_root <- file.path("2_data", "raw", "workbench_20260629", "update_res_only_260705")
  }
  build_module_entity(
    case_root = args$case_root,
    output_dir = args$output_dir
  )
}
