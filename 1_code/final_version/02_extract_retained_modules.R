#!/usr/bin/env Rscript

# Extract retained PhenoMAP module results from the 2026-09-11 delivery.
#
# This is a preliminary, audit-friendly extractor for the final-version build.
# It keeps:
#   - study-level res_sig.rda results for retained case-control studies
#   - contrast-level res_sig.rda results where contrast_meta.kind == "vs_baseline"
#
# It drops:
#   - contrast_meta.kind == "pairwise"
#   - time_series, dose_response and other contrast designs
#
# Outputs are raw/preliminary tables. They intentionally use natural keys
# rather than final Lab_IDs, because the final KG schema still needs one more
# design decision around Study -> Comparison -> Module display.

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

parse_args <- function() {
  args <- list(
    data_dir = "/mnt/hdd1/home/yuting/module_lists_20260911",
    accession_csv = file.path("2_data", "finalversion_0913", "phenomap_retained_study_accessions.csv"),
    contrast_index_csv = "",
    output_dir = file.path("2_data", "finalversion_0913", "module_prelim"),
    mw_zip = "",
    ml_zip = "",
    mw_root = "",
    ml_root = "",
    source = "all",
    limit_results = NA_integer_
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% names(args)) args[[key]] <- value
  }

  args$source <- tolower(clean_scalar(args$source, "all"))
  if (!args$source %in% c("all", "mw", "ml")) args$source <- "all"

  args$limit_results <- suppressWarnings(as.integer(args$limit_results))
  if (is.na(args$limit_results) || args$limit_results < 1L) {
    args$limit_results <- NA_integer_
  }

  if (!nzchar(args$mw_zip)) {
    args$mw_zip <- file.path(args$data_dir, "out_qwen_eval_mw_anno_20260911.zip")
  }
  if (!nzchar(args$ml_zip)) {
    args$ml_zip <- file.path(args$data_dir, "out_qwen_eval_ml_anno_20260911.zip")
  }
  if (!nzchar(args$contrast_index_csv)) {
    args$contrast_index_csv <- file.path(args$data_dir, "contrast_index_20260911.csv")
  }

  args
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

split_ids <- function(x) {
  ids <- drop_empty(x)
  if (length(ids) == 0) return(character(0))
  unique(drop_empty(unlist(strsplit(ids, ";", fixed = TRUE), use.names = FALSE)))
}

collapse_values <- function(x, sep = "; ") {
  x <- drop_empty(unlist(x, recursive = TRUE, use.names = FALSE))
  if (length(x) == 0) return(NA_character_)
  paste(unique(x), collapse = sep)
}

safe_df <- function(x) {
  if (is.null(x) || !is.data.frame(x)) return(data.frame())
  as.data.frame(x, stringsAsFactors = FALSE, check.names = FALSE)
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

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required CSV does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(df, path, row.names = FALSE, na = "")
  invisible(path)
}

normalize_database_key <- function(database, accession = "") {
  db <- tolower(clean_scalar(database, ""))
  if (grepl("workbench|^mw$", db)) return("mw")
  if (grepl("metabolights|^ml$", db)) return("ml")
  if (grepl("^ST[0-9]+$", accession)) return("mw")
  if (grepl("^MTBLS[0-9]+$", accession)) return("ml")
  NA_character_
}

database_label <- function(database_key) {
  if (identical(database_key, "mw")) return("Metabolomics Workbench")
  if (identical(database_key, "ml")) return("MetaboLights")
  NA_character_
}

parse_json_text <- function(txt) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("Package 'jsonlite' is required.")
  }
  jsonlite::fromJSON(txt, simplifyVector = FALSE)
}

read_json_file <- function(path) {
  parse_json_text(paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n"))
}

read_json_zip <- function(zip_path, inner_path) {
  con <- unz(zip_path, inner_path, open = "rt")
  on.exit(close(con), add = TRUE)
  parse_json_text(paste(readLines(con, warn = FALSE, encoding = "UTF-8"), collapse = "\n"))
}

load_res_file <- function(path) {
  env <- new.env(parent = emptyenv())
  object_names <- load(path, envir = env)
  pick_res_object(env, object_names)
}

load_res_zip <- function(zip_path, inner_path) {
  con <- unz(zip_path, inner_path, open = "rb")
  on.exit(close(con), add = TRUE)
  env <- new.env(parent = emptyenv())
  object_names <- load(con, envir = env)
  pick_res_object(env, object_names)
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

list_zip_names <- function(zip_path) {
  if (!file.exists(zip_path)) stop("ZIP does not exist: ", zip_path)
  utils::unzip(zip_path, list = TRUE)$Name
}

result_source_zip <- function(database_key, zip_path) {
  names <- list_zip_names(zip_path)
  list(type = "zip", database_key = database_key, zip_path = zip_path, names = names)
}

result_source_dir <- function(database_key, root) {
  if (!dir.exists(root)) stop("Root directory does not exist: ", root)
  files <- list.files(root, recursive = TRUE, full.names = FALSE, all.files = FALSE, no.. = TRUE)
  list(type = "dir", database_key = database_key, root = root, names = files)
}

source_has <- function(src, inner_path) {
  inner_path %in% src$names
}

source_read_json <- function(src, inner_path) {
  if (identical(src$type, "zip")) return(read_json_zip(src$zip_path, inner_path))
  read_json_file(file.path(src$root, inner_path))
}

source_load_res <- function(src, inner_path) {
  if (identical(src$type, "zip")) return(load_res_zip(src$zip_path, inner_path))
  load_res_file(file.path(src$root, inner_path))
}

make_comparison_label <- function(kind, case_value, control_value, fallback = NA_character_) {
  case_value <- clean_scalar(case_value)
  control_value <- clean_scalar(control_value)
  if (!is.na(case_value) || !is.na(control_value)) {
    return(paste0(
      ifelse(is.na(case_value), "case", case_value),
      " vs ",
      ifelse(is.na(control_value), "baseline", control_value)
    ))
  }
  if (!is.na(clean_scalar(fallback))) return(clean_scalar(fallback))
  clean_scalar(kind, "study_level")
}

study_context_value <- function(res, name) {
  value <- tryCatch(res$study_context[[name]], error = function(e) NULL)
  clean_scalar(value)
}

module_metric_table <- function(res) {
  score <- safe_df(tryCatch(res$module_score, error = function(e) NULL))
  if (nrow(score) == 0) return(data.frame())
  score <- flatten_df(score)
  if ("Module" %in% names(score) && !"module_id" %in% names(score)) {
    names(score)[names(score) == "Module"] <- "module_id"
  }
  score
}

normalize_pathway_name <- function(x) {
  x <- sub("\\s*\\([^)]*\\)\\s*$", "", as.character(x))
  x <- tolower(trimws(x))
  gsub("[[:space:]]+", " ", x)
}

pathway_ids_for_module <- function(pathway_coverage, source, module_id, pathway_names) {
  df <- pathway_coverage[[source]]
  if (is.null(df) || !is.data.frame(df) || !"module_id" %in% names(df) || !"pathway_id" %in% names(df)) {
    return(NA_character_)
  }
  if (!"pathway_name" %in% names(df)) return(NA_character_)
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

merge_missing_metrics <- function(module_function, module_score) {
  if (nrow(module_function) == 0 || nrow(module_score) == 0 || !"module_id" %in% names(module_function)) {
    return(module_function)
  }
  if (!"module_id" %in% names(module_score)) return(module_function)
  metric_cols <- setdiff(names(module_score), names(module_function))
  if (length(metric_cols) == 0) return(module_function)
  module_score <- module_score[, c("module_id", metric_cols), drop = FALSE]
  merge(module_function, module_score, by = "module_id", all.x = TRUE, sort = FALSE)
}

build_sources <- function(args) {
  sources <- list()
  if (args$source %in% c("all", "mw")) {
    sources$mw <- if (nzchar(args$mw_root)) {
      result_source_dir("mw", args$mw_root)
    } else {
      result_source_zip("mw", args$mw_zip)
    }
  }
  if (args$source %in% c("all", "ml")) {
    sources$ml <- if (nzchar(args$ml_root)) {
      result_source_dir("ml", args$ml_root)
    } else {
      result_source_zip("ml", args$ml_zip)
    }
  }
  sources
}

read_contrast_index <- function(path) {
  if (!file.exists(path)) return(data.frame())
  index <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  needed <- c("source", "study_id", "contrast_id")
  if (!all(needed %in% names(index))) return(data.frame())
  index$database_key <- tolower(index$source)
  index$key <- paste(index$database_key, index$study_id, index$contrast_id, sep = "\r")
  index
}

contrast_index_row <- function(index, database_key, study_id, comparison_id) {
  if (!is.data.frame(index) || nrow(index) == 0) return(NULL)
  key <- paste(database_key, study_id, comparison_id, sep = "\r")
  hit <- index[index$key == key, , drop = FALSE]
  if (nrow(hit) == 0) return(NULL)
  hit[1, , drop = FALSE]
}

index_value <- function(index_row, name, default = NA_character_) {
  if (is.null(index_row) || !name %in% names(index_row)) return(default)
  clean_scalar(index_row[[name]], default)
}

index_int <- function(index_row, name) {
  suppressWarnings(as.integer(index_value(index_row, name)))
}

build_retained_result_index <- function(sources, accession_csv, contrast_index_csv) {
  accessions <- read_csv_required(accession_csv)
  if (!all(c("study_accession", "database") %in% names(accessions))) {
    stop("accession_csv must contain columns: study_accession,database")
  }
  accessions$database_key <- mapply(normalize_database_key, accessions$database, accessions$study_accession)
  accessions <- accessions[!duplicated(accessions[c("study_accession", "database_key")]), , drop = FALSE]

  allowed_designs <- c("binary_case_control", "multiclass", "multifactor")
  contrast_index <- read_contrast_index(contrast_index_csv)
  rows <- list()
  row_i <- 0L

  for (database_key in names(sources)) {
    src <- sources[[database_key]]
    wanted <- accessions$study_accession[accessions$database_key == database_key]
    wanted <- sort(unique(wanted))

    for (study_id in wanted) {
      study_meta_path <- file.path(study_id, "study_meta.json")
      study_meta <- if (source_has(src, study_meta_path)) {
        tryCatch(source_read_json(src, study_meta_path), error = function(e) list())
      } else {
        list()
      }

      root_res_path <- file.path(study_id, "anno_result", "res_sig.rda")
      if (source_has(src, root_res_path)) {
        row_i <- row_i + 1L
        rows[[row_i]] <- data.frame(
          database_key = database_key,
          database = database_label(database_key),
          study_accession = study_id,
          result_scope = "study_level",
          comparison_id = "study_level",
          comparison_kind = "case_control",
          comparison_design_type = clean_scalar(study_meta$design_type, "binary_case_control"),
          comparison_label = make_comparison_label(
            "case_control",
            study_meta$case_label,
            study_meta$control_label,
            "study-level case-control"
          ),
          case_value = clean_scalar(study_meta$case_label),
          control_value = clean_scalar(study_meta$control_label),
          n_case = NA_integer_,
          n_control = NA_integer_,
          phenotype = clean_scalar(study_meta$phenotype),
          phenotype_term = clean_scalar(study_meta$phenotype_term),
          species = clean_scalar(study_meta$species),
          biospecimen = clean_scalar(study_meta$biospecimen),
          res_sig_path = root_res_path,
          stringsAsFactors = FALSE,
          check.names = FALSE
        )
      }

      prefix <- file.path(study_id, "anno_result", "contrasts")
      meta_paths <- src$names[
        startsWith(src$names, paste0(prefix, "/")) &
          grepl("/contrast_meta[.]json$", src$names)
      ]
      meta_paths <- sort(meta_paths)

      for (meta_path in meta_paths) {
        meta <- tryCatch(source_read_json(src, meta_path), error = function(e) NULL)
        if (is.null(meta)) next
        kind <- clean_scalar(meta$kind)
        design_type <- clean_scalar(meta$design_type)
        if (!identical(kind, "vs_baseline")) next
        if (!design_type %in% allowed_designs) next

        comparison_id <- basename(dirname(meta_path))
        res_path <- file.path(dirname(meta_path), "res_sig.rda")
        if (!source_has(src, res_path)) next

        row_i <- row_i + 1L
        idx <- contrast_index_row(contrast_index, database_key, study_id, comparison_id)
        rows[[row_i]] <- data.frame(
          database_key = database_key,
          database = database_label(database_key),
          study_accession = study_id,
          result_scope = "contrast",
          comparison_id = comparison_id,
          comparison_kind = kind,
          comparison_design_type = design_type,
          comparison_label = make_comparison_label(
            kind,
            clean_scalar(meta$case_value, index_value(idx, "case_value")),
            clean_scalar(meta$control_value, index_value(idx, "control_value")),
            comparison_id
          ),
          case_value = clean_scalar(meta$case_value, index_value(idx, "case_value")),
          control_value = clean_scalar(meta$control_value, index_value(idx, "control_value")),
          n_case = suppressWarnings(as.integer(clean_scalar(meta$n_case, index_int(idx, "n_case")))),
          n_control = suppressWarnings(as.integer(clean_scalar(meta$n_control, index_int(idx, "n_control")))),
          phenotype = clean_scalar(meta$phenotype, index_value(idx, "phenotype")),
          phenotype_term = clean_scalar(meta$phenotype_term, index_value(idx, "phenotype_term")),
          species = clean_scalar(meta$species, clean_scalar(study_meta$species)),
          biospecimen = clean_scalar(meta$biospecimen, index_value(idx, "biospecimen")),
          res_sig_path = res_path,
          stringsAsFactors = FALSE,
          check.names = FALSE
        )
      }
    }
  }

  if (length(rows) == 0) return(data.frame())
  out <- do.call(rbind, rows)
  out <- out[order(out$database_key, out$study_accession, out$result_scope, out$comparison_id), , drop = FALSE]
  rownames(out) <- NULL
  out
}

metabolite_type_for_module <- function(local_module_id, module_function_row, module_table) {
  if (!all(c("Module", "INCHI_ID") %in% names(module_table))) {
    return(rep(NA_character_, nrow(module_table)))
  }
  inchi <- as.character(module_table$INCHI_ID)
  anchor_ids <- intersect(split_ids(module_function_row$anchor_metabolite_ids), split_ids(inchi))
  supporting_source <- module_function_row$top_metabolite_ids %||% module_function_row$supporting_metabolite_ids
  top_ids <- setdiff(intersect(split_ids(supporting_source), split_ids(inchi)), anchor_ids)
  out <- rep("contextual", length(inchi))
  out[inchi %in% top_ids] <- "supporting"
  out[inchi %in% anchor_ids] <- "core"
  out
}

extract_one_result <- function(src, result_row) {
  res <- source_load_res(src, result_row$res_sig_path)
  module_function <- flatten_df(safe_df(tryCatch(res$module_function, error = function(e) NULL)))
  module_table <- flatten_df(safe_df(tryCatch(res$module_table, error = function(e) NULL)))
  module_score <- module_metric_table(res)

  if (nrow(module_function) == 0 || !"module_id" %in% names(module_function)) {
    return(list(modules = data.frame(), memberships = data.frame(), status = "no_module_function"))
  }

  module_function <- merge_missing_metrics(module_function, module_score)
  pathway_coverage <- tryCatch(res$module_evidence$pathway_coverage, error = function(e) NULL)
  module_function$module_id <- as.character(module_function$module_id)
  if ("top_metabolites" %in% names(module_function) && !"supporting_metabolites" %in% names(module_function)) {
    names(module_function)[names(module_function) == "top_metabolites"] <- "supporting_metabolites"
  }
  if ("top_metabolite_ids" %in% names(module_function) && !"supporting_metabolite_ids" %in% names(module_function)) {
    names(module_function)[names(module_function) == "top_metabolite_ids"] <- "supporting_metabolite_ids"
  }
  if (!"hmdb_pathway_ids" %in% names(module_function)) module_function$hmdb_pathway_ids <- NA_character_
  if (!"kegg_pathway_ids" %in% names(module_function)) module_function$kegg_pathway_ids <- NA_character_
  if (!is.null(pathway_coverage)) {
    for (i in seq_len(nrow(module_function))) {
      module_function$hmdb_pathway_ids[[i]] <- pathway_ids_for_module(
        pathway_coverage,
        "hmdb",
        module_function$module_id[[i]],
        if ("top_hmdb_pathways" %in% names(module_function)) module_function$top_hmdb_pathways[[i]] else NA_character_
      )
      module_function$kegg_pathway_ids[[i]] <- pathway_ids_for_module(
        pathway_coverage,
        "kegg",
        module_function$module_id[[i]],
        if ("top_kegg_pathways" %in% names(module_function)) module_function$top_kegg_pathways[[i]] else NA_character_
      )
    }
  }

  comparison_id <- clean_scalar(result_row$comparison_id, "study_level")
  module_keys <- paste(
    result_row$database_key,
    result_row$study_accession,
    comparison_id,
    module_function$module_id,
    sep = "::"
  )

  module_prefix <- data.frame(
    Module_Key = module_keys,
    Database_Key = result_row$database_key,
    Database = result_row$database,
    Study_Accession = result_row$study_accession,
    Result_Scope = result_row$result_scope,
    Comparison_ID = comparison_id,
    Comparison_Kind = result_row$comparison_kind,
    Comparison_Design_Type = result_row$comparison_design_type,
    Comparison_Label = result_row$comparison_label,
    Case_Value = result_row$case_value,
    Control_Value = result_row$control_value,
    N_Case = result_row$n_case,
    N_Control = result_row$n_control,
    Phenotype = clean_scalar(result_row$phenotype, study_context_value(res, "phenotype")),
    Phenotype_Term = result_row$phenotype_term,
    Species = clean_scalar(result_row$species, study_context_value(res, "species")),
    Biospecimen = clean_scalar(result_row$biospecimen, study_context_value(res, "biospecimen")),
    Local_Module_ID = module_function$module_id,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  module_out <- cbind(module_prefix, module_function[, setdiff(names(module_function), "module_id"), drop = FALSE])

  membership_out <- data.frame()
  if (nrow(module_table) > 0 && "Module" %in% names(module_table)) {
    module_table$Module <- as.character(module_table$Module)
    membership_rows <- list()
    row_i <- 0L
    for (i in seq_len(nrow(module_function))) {
      local_module_id <- module_function$module_id[[i]]
      local_table <- module_table[module_table$Module == local_module_id, , drop = FALSE]
      if (nrow(local_table) == 0) next
      local_table <- flatten_df(local_table)
      local_table$Membership_Type <- metabolite_type_for_module(local_module_id, module_function[i, , drop = FALSE], local_table)
      local_table$Module_Key <- module_keys[[i]]
      local_table$Database_Key <- result_row$database_key
      local_table$Study_Accession <- result_row$study_accession
      local_table$Comparison_ID <- comparison_id
      local_table$Local_Module_ID <- local_module_id
      row_i <- row_i + 1L
      membership_rows[[row_i]] <- local_table
    }
    if (length(membership_rows) > 0) {
      membership_out <- do.call(rbind, membership_rows)
      preferred <- c(
        "Module_Key", "Database_Key", "Study_Accession", "Comparison_ID",
        "Local_Module_ID", "Membership_Type", "Module", "INCHI_ID",
        "HMDB_ID", "KEGG_ID", "Compound_name", "Importance"
      )
      membership_out <- membership_out[
        ,
        c(intersect(preferred, names(membership_out)), setdiff(names(membership_out), preferred)),
        drop = FALSE
      ]
    }
  }

  list(modules = module_out, memberships = membership_out, status = "ok")
}

main <- function() {
  args <- parse_args()
  sources <- build_sources(args)
  result_index <- build_retained_result_index(sources, args$accession_csv, args$contrast_index_csv)

  if (!is.na(args$limit_results)) {
    result_index <- head(result_index, args$limit_results)
  }

  message("Retained result objects to inspect: ", nrow(result_index))
  write_csv(result_index, file.path(args$output_dir, "retained_result_index.csv"))

  modules <- list()
  memberships <- list()
  report <- result_index
  report$n_modules <- 0L
  report$n_membership_rows <- 0L
  report$extract_status <- "not_started"
  report$error <- NA_character_

  if (nrow(result_index) > 0) {
    for (i in seq_len(nrow(result_index))) {
      rr <- result_index[i, , drop = FALSE]
      message("[", i, "/", nrow(result_index), "] ", rr$database_key, " ", rr$study_accession, " ", rr$comparison_id)
      src <- sources[[rr$database_key]]
      extracted <- tryCatch(
        extract_one_result(src, rr),
        error = function(e) list(modules = data.frame(), memberships = data.frame(), status = "error", error = conditionMessage(e))
      )
      modules[[i]] <- extracted$modules
      memberships[[i]] <- extracted$memberships
      report$n_modules[[i]] <- if (is.data.frame(extracted$modules)) nrow(extracted$modules) else 0L
      report$n_membership_rows[[i]] <- if (is.data.frame(extracted$memberships)) nrow(extracted$memberships) else 0L
      report$extract_status[[i]] <- clean_scalar(extracted$status, "error")
      report$error[[i]] <- clean_scalar(extracted$error)

      # Write progress after every result so a long server run can be audited
      # even if it is interrupted.
      module_df <- modules[vapply(modules, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))]
      membership_df <- memberships[vapply(memberships, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))]
      write_csv(if (length(module_df) > 0) do.call(rbind, module_df) else data.frame(),
                file.path(args$output_dir, "nodes_module_prelim.csv"))
      write_csv(if (length(membership_df) > 0) do.call(rbind, membership_df) else data.frame(),
                file.path(args$output_dir, "edges_metabolite_module_prelim.csv"))
      write_csv(report, file.path(args$output_dir, "module_extract_report.csv"))
    }
  }

  module_df <- modules[vapply(modules, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))]
  membership_df <- memberships[vapply(memberships, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))]
  module_out <- if (length(module_df) > 0) do.call(rbind, module_df) else data.frame()
  membership_out <- if (length(membership_df) > 0) do.call(rbind, membership_df) else data.frame()

  write_csv(module_out, file.path(args$output_dir, "nodes_module_prelim.csv"))
  write_csv(membership_out, file.path(args$output_dir, "edges_metabolite_module_prelim.csv"))
  write_csv(report, file.path(args$output_dir, "module_extract_report.csv"))

  message("Done.")
  message("Results: ", nrow(result_index))
  message("Modules: ", nrow(module_out))
  message("Metabolite-module rows: ", nrow(membership_out))
  message("Output dir: ", args$output_dir)
  message("Status counts:")
  print(table(report$extract_status, useNA = "ifany"))
}

if (identical(environment(), globalenv()) && !interactive()) {
  main()
}
