#!/usr/bin/env Rscript

# Complete the module_prelim output without rerunning the extraction.
#
# The first server run of 02_extract_retained_modules.R produced the important
# multi-group natural keys and module rows, but it missed a few fields that the
# old module pipeline had:
#   - module_id
#   - contextual_metabolites
#   - contextual_metabolite_ids
#   - hmdb_pathway_ids
#   - kegg_pathway_ids
#
# By default this script writes a completed copy into a new directory. If
# --in_place=1 is passed, it updates nodes_module_prelim.csv in the original
# module_prelim directory and leaves the large edge/index files untouched.
# It does not assign final KG Lab_IDs.

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

parse_args <- function() {
  args <- list(
    data_dir = "/mnt/hdd1/home/yuting/module_lists_20260911",
    module_prelim_dir = "",
    output_dir = "",
    mw_zip = "",
    ml_zip = "",
    limit_results = NA_integer_,
    in_place = "0"
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% names(args)) args[[key]] <- value
  }

  if (!nzchar(args$module_prelim_dir)) {
    args$module_prelim_dir <- file.path(args$data_dir, "module_prelim")
  }
  args$in_place <- parse_bool(args$in_place)

  if (isTRUE(args$in_place)) {
    args$output_dir <- args$module_prelim_dir
  } else if (!nzchar(args$output_dir)) {
    args$output_dir <- file.path(args$data_dir, "module_prelim_completed")
  }
  if (!nzchar(args$mw_zip)) {
    args$mw_zip <- file.path(args$data_dir, "out_qwen_eval_mw_anno_20260911.zip")
  }
  if (!nzchar(args$ml_zip)) {
    args$ml_zip <- file.path(args$data_dir, "out_qwen_eval_ml_anno_20260911.zip")
  }

  args$limit_results <- suppressWarnings(as.integer(args$limit_results))
  if (is.na(args$limit_results) || args$limit_results < 1L) {
    args$limit_results <- NA_integer_
  }

  args
}

parse_bool <- function(x) {
  x <- tolower(trimws(as.character(x[[1]])))
  x %in% c("1", "true", "t", "yes", "y")
}

clean_scalar <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0) return(default)
  x <- as.character(x[[1]])
  x <- trimws(x)
  if (!nzchar(x) || toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")) return(default)
  x
}

drop_empty <- function(x) {
  if (is.null(x) || length(x) == 0) return(character(0))
  x <- trimws(as.character(x))
  x[!is.na(x) & nzchar(x) & !toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")]
}

collapse_values <- function(x, sep = "; ") {
  x <- drop_empty(unlist(x, recursive = TRUE, use.names = FALSE))
  if (length(x) == 0) return(NA_character_)
  paste(unique(x), collapse = sep)
}

split_semicolon <- function(x) {
  x <- clean_scalar(x)
  if (is.na(x)) return(character(0))
  unique(drop_empty(unlist(strsplit(x, ";", fixed = TRUE), use.names = FALSE)))
}

split_ids <- function(x) {
  unique(drop_empty(unlist(strsplit(as.character(x), ";", fixed = TRUE), use.names = FALSE)))
}

names_for_ids <- function(ids, module_table) {
  ids <- drop_empty(ids)
  if (length(ids) == 0 || !"Compound_name" %in% names(module_table) || !"INCHI_ID" %in% names(module_table)) {
    return(NA_character_)
  }
  hit <- module_table[module_table$INCHI_ID %in% ids, c("INCHI_ID", "Compound_name"), drop = FALSE]
  hit <- hit[match(ids, hit$INCHI_ID), , drop = FALSE]
  collapse_values(hit$Compound_name)
}

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(path, ".tmp.", Sys.getpid())
  utils::write.csv(df, tmp, row.names = FALSE, na = "")
  if (file.exists(path)) {
    ok <- file.rename(tmp, path)
    if (!ok) {
      file.copy(tmp, path, overwrite = TRUE)
      unlink(tmp)
    }
  } else {
    file.rename(tmp, path)
  }
  invisible(path)
}

flatten_df <- function(df) {
  if (!is.data.frame(df) || nrow(df) == 0) return(df)
  for (nm in names(df)) {
    if (is.list(df[[nm]])) {
      df[[nm]] <- vapply(df[[nm]], collapse_values, character(1))
    }
  }
  df
}

normalize_pathway_name <- function(x) {
  x <- sub("\\s*\\([^)]*\\)\\s*$", "", as.character(x))
  x <- tolower(trimws(x))
  gsub("[[:space:]]+", " ", x)
}

pathway_ids_for_module <- function(pathway_coverage, source, module_id, pathway_names) {
  df <- pathway_coverage[[source]]
  if (is.null(df) || !is.data.frame(df)) return(NA_character_)
  if (!all(c("module_id", "pathway_id", "pathway_name") %in% names(df))) return(NA_character_)

  df <- df[as.character(df$module_id) == as.character(module_id), , drop = FALSE]
  if (nrow(df) == 0) return(NA_character_)

  names <- drop_empty(unlist(strsplit(clean_scalar(pathway_names, ""), ";", fixed = TRUE), use.names = FALSE))
  if (length(names) == 0) return(NA_character_)

  matched_ids <- character(0)
  keys <- normalize_pathway_name(df$pathway_name)
  for (name in names) {
    idx <- match(normalize_pathway_name(name), keys)
    if (!is.na(idx)) matched_ids <- c(matched_ids, df$pathway_id[[idx]])
  }

  collapse_values(matched_ids)
}

pick_res_object <- function(env, object_names) {
  if ("res_sig" %in% object_names) return(env$res_sig)
  for (nm in object_names) {
    obj <- env[[nm]]
    object_type <- tryCatch(obj$object_type, error = function(e) NULL)
    if (!is.null(object_type) && identical(object_type, "featuremap_result")) return(obj)
  }
  env[[object_names[[1]]]]
}

load_res_zip <- function(zip_path, inner_path) {
  con <- unz(zip_path, inner_path, open = "rb")
  on.exit(close(con), add = TRUE)
  env <- new.env(parent = emptyenv())
  object_names <- load(con, envir = env)
  pick_res_object(env, object_names)
}

zip_for_database <- function(database_key, mw_zip, ml_zip) {
  if (identical(database_key, "mw")) return(mw_zip)
  if (identical(database_key, "ml")) return(ml_zip)
  stop("Unknown database_key: ", database_key)
}

module_key_for <- function(database_key, study_accession, comparison_id, local_module_id) {
  paste(database_key, study_accession, comparison_id, local_module_id, sep = "::")
}

complete_pathway_fields <- function(modules, result_index, mw_zip, ml_zip, limit_results = NA_integer_) {
  if (!"module_id" %in% names(modules)) modules$module_id <- modules$Local_Module_ID
  if (!"contextual_metabolites" %in% names(modules)) modules$contextual_metabolites <- NA_character_
  if (!"contextual_metabolite_ids" %in% names(modules)) modules$contextual_metabolite_ids <- NA_character_
  modules$hmdb_pathway_ids <- NA_character_
  modules$kegg_pathway_ids <- NA_character_

  if (!is.na(limit_results)) {
    result_index <- head(result_index, limit_results)
  }

  module_row_by_key <- setNames(seq_len(nrow(modules)), modules$Module_Key)
  n_results <- nrow(result_index)
  report <- result_index
  report$n_modules_with_contextual_ids <- 0L
  report$n_modules_with_pathway_ids <- 0L
  report$pathway_status <- "not_started"
  report$pathway_error <- NA_character_

  for (i in seq_len(n_results)) {
    rr <- result_index[i, , drop = FALSE]
    message("[", i, "/", n_results, "] pathway IDs for ", rr$database_key, " ", rr$study_accession, " ", rr$comparison_id)

    status <- "ok"
    err <- NA_character_
    n_contextual <- 0L
    n_filled <- 0L

    tryCatch({
      res <- load_res_zip(zip_for_database(rr$database_key, mw_zip, ml_zip), rr$res_sig_path)
      module_function <- flatten_df(as.data.frame(res$module_function, stringsAsFactors = FALSE, check.names = FALSE))
      module_table <- flatten_df(as.data.frame(res$module_table, stringsAsFactors = FALSE, check.names = FALSE))
      pathway_coverage <- tryCatch(res$module_evidence$pathway_coverage, error = function(e) NULL)

      if (nrow(module_function) == 0) {
        status <<- "no_module_function"
      } else {
        if (nrow(module_table) > 0 && all(c("Module", "INCHI_ID") %in% names(module_table))) {
          module_table$Module <- as.character(module_table$Module)
          module_table$INCHI_ID <- as.character(module_table$INCHI_ID)
        }

        for (j in seq_len(nrow(module_function))) {
          local_module_id <- as.character(module_function$module_id[[j]])
          key <- module_key_for(rr$database_key, rr$study_accession, rr$comparison_id, local_module_id)
          row <- unname(module_row_by_key[key])
          if (length(row) == 0 || is.na(row)) next

          if (nrow(module_table) > 0 && all(c("Module", "INCHI_ID") %in% names(module_table))) {
            local_table <- module_table[module_table$Module == local_module_id, , drop = FALSE]
            all_ids <- split_ids(local_table$INCHI_ID)
            anchor_ids <- if ("anchor_metabolite_ids" %in% names(module_function)) {
              intersect(split_ids(module_function$anchor_metabolite_ids[[j]]), all_ids)
            } else {
              character(0)
            }
            supporting_source <- if ("top_metabolite_ids" %in% names(module_function)) {
              module_function$top_metabolite_ids[[j]]
            } else if ("supporting_metabolite_ids" %in% names(module_function)) {
              module_function$supporting_metabolite_ids[[j]]
            } else {
              NA_character_
            }
            top_ids <- setdiff(intersect(split_ids(supporting_source), all_ids), anchor_ids)
            contextual_ids <- setdiff(all_ids, union(anchor_ids, top_ids))

            modules$contextual_metabolite_ids[[row]] <- collapse_values(contextual_ids)
            modules$contextual_metabolites[[row]] <- names_for_ids(contextual_ids, local_table)
            if (length(contextual_ids) > 0) n_contextual <- n_contextual + 1L
          }

          hmdb_names <- if ("top_hmdb_pathways" %in% names(module_function)) {
            module_function$top_hmdb_pathways[[j]]
          } else if ("top_hmdb_pathways" %in% names(modules)) {
            modules$top_hmdb_pathways[[row]]
          } else {
            NA_character_
          }
          kegg_names <- if ("top_kegg_pathways" %in% names(module_function)) {
            module_function$top_kegg_pathways[[j]]
          } else if ("top_kegg_pathways" %in% names(modules)) {
            modules$top_kegg_pathways[[row]]
          } else {
            NA_character_
          }
          modules$hmdb_pathway_ids[[row]] <- pathway_ids_for_module(pathway_coverage, "hmdb", local_module_id, hmdb_names)
          modules$kegg_pathway_ids[[row]] <- pathway_ids_for_module(pathway_coverage, "kegg", local_module_id, kegg_names)

          if (!is.na(modules$hmdb_pathway_ids[[row]]) || !is.na(modules$kegg_pathway_ids[[row]])) {
            n_filled <- n_filled + 1L
          }
        }
        if (is.null(pathway_coverage)) status <<- "no_pathway_coverage"
      }
    }, error = function(e) {
      status <<- "error"
      err <<- conditionMessage(e)
    })

    report$n_modules_with_contextual_ids[[i]] <- n_contextual
    report$n_modules_with_pathway_ids[[i]] <- n_filled
    report$pathway_status[[i]] <- status
    report$pathway_error[[i]] <- clean_scalar(err)
  }

  list(modules = modules, report = report)
}

copy_if_exists <- function(from_dir, to_dir, filename) {
  src <- file.path(from_dir, filename)
  if (!file.exists(src)) return(FALSE)
  dir.create(to_dir, recursive = TRUE, showWarnings = FALSE)
  file.copy(src, file.path(to_dir, filename), overwrite = TRUE)
}

main <- function() {
  args <- parse_args()
  dir.create(args$output_dir, recursive = TRUE, showWarnings = FALSE)
  if (isTRUE(args$in_place) && !is.na(args$limit_results)) {
    stop("--in_place=1 cannot be combined with --limit_results, because that would partially update the original table.")
  }

  modules <- read_csv_required(file.path(args$module_prelim_dir, "nodes_module_prelim.csv"))
  result_index <- read_csv_required(file.path(args$module_prelim_dir, "retained_result_index.csv"))

  completed <- complete_pathway_fields(modules, result_index, args$mw_zip, args$ml_zip, args$limit_results)
  modules <- completed$modules

  module_front <- c(
    "Module_Key", "Database_Key", "Database", "Study_Accession", "Result_Scope",
    "Comparison_ID", "Comparison_Kind", "Comparison_Design_Type", "Comparison_Label",
    "Case_Value", "Control_Value", "N_Case", "N_Control", "Phenotype",
    "Phenotype_Term", "Species", "Biospecimen", "module_id", "Local_Module_ID",
    "annotation_mode", "hypothesis_type", "title", "functional_summary",
    "anchor_metabolites", "anchor_metabolite_ids", "supporting_metabolites",
    "supporting_metabolite_ids", "contextual_metabolites",
    "contextual_metabolite_ids", "class_names", "phenotype_relationship",
    "confidence_label", "rationale", "global_direction",
    "origin_endogenous_frac", "origin_exogenous_frac", "top_kegg_pathways",
    "top_hmdb_pathways", "pubmed_pmids", "hmdb_pathway_ids", "kegg_pathway_ids",
    "Module_size", "Annotated_nodes", "Module_score", "p", "fdr"
  )
  modules <- modules[, c(intersect(module_front, names(modules)), setdiff(names(modules), module_front)), drop = FALSE]

  write_csv(modules, file.path(args$output_dir, "nodes_module_prelim.csv"))
  write_csv(completed$report, file.path(args$output_dir, "module_pathway_completion_report.csv"))
  if (!isTRUE(args$in_place)) {
    file.copy(
      file.path(args$module_prelim_dir, "edges_metabolite_module_prelim.csv"),
      file.path(args$output_dir, "edges_metabolite_module_prelim.csv"),
      overwrite = TRUE
    )
    write_csv(result_index, file.path(args$output_dir, "retained_result_index.csv"))
    copy_if_exists(args$module_prelim_dir, args$output_dir, "module_extract_report.csv")
  }

  message("Done.")
  message("Input modules: ", nrow(modules))
  message(if (isTRUE(args$in_place)) "Updated in place: " else "Output dir: ", args$output_dir)
  message("Missing old module columns after completion:")
  old <- c(
    "module_id", "annotation_mode", "hypothesis_type", "title", "functional_summary",
    "anchor_metabolites", "anchor_metabolite_ids", "supporting_metabolites",
    "supporting_metabolite_ids", "contextual_metabolites", "contextual_metabolite_ids",
    "class_names", "phenotype_relationship", "confidence_label", "rationale",
    "global_direction", "origin_endogenous_frac", "origin_exogenous_frac",
    "top_kegg_pathways", "top_hmdb_pathways", "pubmed_pmids",
    "hmdb_pathway_ids", "kegg_pathway_ids"
  )
  print(setdiff(old, names(modules)))
  message("Pathway completion status:")
  print(table(completed$report$pathway_status, useNA = "ifany"))
}

if (sys.nframe() == 0L && !interactive()) {
  main()
}
