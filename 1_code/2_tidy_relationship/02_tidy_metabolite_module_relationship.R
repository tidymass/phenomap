# Generate PhenoMAP metabolite-module membership relationship table.
#
# Output:
#   edges_metabolite_module.csv

source(file.path("1_code", "2_tidy_relationship", "00_relationship_helpers.R"))

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

split_ids <- function(x) {
  ids <- phenomap_drop_empty(x)
  if (length(ids) == 0) return(character(0))
  ids <- phenomap_drop_empty(unlist(strsplit(ids, ";", fixed = TRUE), use.names = FALSE))
  unique(ids[nzchar(ids)])
}

read_study_id_map <- function(entity_dir) {
  study <- phenomap_read_csv_required(file.path(entity_dir, "nodes_study.csv"))
  if (!all(c("Lab_ID", "Accession") %in% colnames(study))) {
    stop("nodes_study.csv must contain Lab_ID and Accession.")
  }
  setNames(study$Lab_ID, study$Accession)
}

read_module_id_map <- function(entity_dir) {
  modules <- phenomap_read_csv_required(file.path(entity_dir, "nodes_module.csv"))
  if (!all(c("Lab_ID", "Study_ID", "module_id") %in% colnames(modules))) {
    stop("nodes_module.csv must contain Lab_ID, Study_ID and module_id.")
  }
  setNames(modules$Lab_ID, paste(modules$Study_ID, modules$module_id, sep = "||"))
}

read_metabolite_id_map <- function(entity_dir) {
  metabolites <- phenomap_read_csv_required(file.path(entity_dir, "nodes_metabolite.csv"))
  if (!all(c("Lab_ID", "INCHI_ID") %in% colnames(metabolites))) {
    stop("nodes_metabolite.csv must contain Lab_ID and INCHI_ID.")
  }
  metabolites <- metabolites[!is.na(metabolites$INCHI_ID) & nzchar(metabolites$INCHI_ID), , drop = FALSE]
  setNames(metabolites$Lab_ID, metabolites$INCHI_ID)
}

build_metabolite_module_relationship_one_case <- function(case_dir,
                                                          study_id_map,
                                                          module_id_map,
                                                          metabolite_id_map) {
  accession <- basename(case_dir)
  study_lab_id <- unname(study_id_map[accession])
  if (length(study_lab_id) == 0 || is.na(study_lab_id) || !nzchar(study_lab_id)) {
    return(data.frame())
  }

  res <- load_res_sig(case_dir)
  module_function <- phenomap_safe_df(res$module_function)
  module_table <- phenomap_safe_df(res$module_table)
  if (nrow(module_function) == 0 || nrow(module_table) == 0) return(data.frame())
  if (!all(c("module_id", "anchor_metabolite_ids", "top_metabolite_ids") %in% colnames(module_function))) {
    return(data.frame())
  }
  if (!all(c("Module", "INCHI_ID") %in% colnames(module_table))) return(data.frame())

  rows <- list()
  row_i <- 0L

  for (i in seq_len(nrow(module_function))) {
    local_module_id <- as.character(module_function$module_id[[i]])
    module_lab_id <- unname(module_id_map[paste(study_lab_id, local_module_id, sep = "||")])
    if (length(module_lab_id) == 0 || is.na(module_lab_id) || !nzchar(module_lab_id)) next

    all_ids <- split_ids(module_table$INCHI_ID[module_table$Module == local_module_id])
    anchor_ids <- intersect(split_ids(module_function$anchor_metabolite_ids[[i]]), all_ids)
    top_ids <- setdiff(intersect(split_ids(module_function$top_metabolite_ids[[i]]), all_ids), anchor_ids)
    contextual_ids <- setdiff(all_ids, union(anchor_ids, top_ids))

    typed_ids <- list(
      core = anchor_ids,
      supporting = top_ids,
      contextual = contextual_ids
    )

    for (type in names(typed_ids)) {
      for (inchi_id in typed_ids[[type]]) {
        metabolite_lab_id <- unname(metabolite_id_map[inchi_id])
        if (length(metabolite_lab_id) == 0 || is.na(metabolite_lab_id) || !nzchar(metabolite_lab_id)) next

        row_i <- row_i + 1L
        rows[[row_i]] <- data.frame(
          Metabolite_ID = metabolite_lab_id,
          Relationship = "member of",
          Module_ID = module_lab_id,
          Type = type,
          stringsAsFactors = FALSE
        )
      }
    }
  }

  if (length(rows) == 0) data.frame() else do.call(rbind, rows)
}

build_metabolite_module_relationship <- function(
  case_root = file.path("2_data", "raw", "workbench_20260629", "update_res_only_260705"),
  entity_dir = file.path("2_data", "tidy_entity"),
  output_dir = file.path("2_data", "tidy_relationship")
) {
  study_id_map <- read_study_id_map(entity_dir)
  module_id_map <- read_module_id_map(entity_dir)
  metabolite_id_map <- read_metabolite_id_map(entity_dir)

  case_dirs <- list.dirs(case_root, recursive = FALSE, full.names = TRUE)
  case_dirs <- case_dirs[file.exists(file.path(case_dirs, "anno_result", "res_sig.rda"))]

  rows <- lapply(
    case_dirs,
    build_metabolite_module_relationship_one_case,
    study_id_map = study_id_map,
    module_id_map = module_id_map,
    metabolite_id_map = metabolite_id_map
  )
  rows <- rows[vapply(rows, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))]

  if (length(rows) == 0) {
    out <- data.frame()
  } else {
    out <- do.call(rbind, rows)
    out <- out[!duplicated(out[, c("Metabolite_ID", "Module_ID")]), , drop = FALSE]
    type_order <- match(out$Type, c("core", "supporting", "contextual"))
    out <- out[order(out$Module_ID, type_order, out$Metabolite_ID), , drop = FALSE]
    out <- data.frame(
      Lab_ID = sprintf("MET_MOD_%06d", seq_len(nrow(out))),
      out,
      stringsAsFactors = FALSE
    )
  }

  phenomap_write_csv(out, file.path(output_dir, "edges_metabolite_module.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_relationship_parse_args()
  if (identical(args$case_root, file.path("..", "featuremap_case", "2_data", "case_metabolights"))) {
    args$case_root <- file.path("2_data", "raw", "workbench_20260629", "update_res_only_260705")
  }
  build_metabolite_module_relationship(
    case_root = args$case_root,
    entity_dir = args$entity_dir,
    output_dir = args$relationship_dir
  )
}
