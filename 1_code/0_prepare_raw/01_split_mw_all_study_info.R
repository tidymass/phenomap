suppressPackageStartupMessages({
  library(jsonlite)
})

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0 || (length(x) == 1 && is.na(x))) y else x
}

parse_args <- function(args) {
  out <- list(
    master_json = "2_data/raw/workbench_20260629/mw_all_study_info.json",
    study_root = "2_data/raw/workbench_20260629/out_qwen_eval_mw_anno",
    metadata_filename = "study_meta.json",
    report_csv = "2_data/raw/workbench_20260629/study_meta_update_report.csv",
    backup = FALSE,
    dry_run = FALSE
  )

  if (length(args) == 0) {
    return(out)
  }

  for (arg in args) {
    if (!startsWith(arg, "--") || !grepl("=", arg, fixed = TRUE)) {
      stop("Arguments must use --name=value format: ", arg, call. = FALSE)
    }

    key <- sub("^--", "", sub("=.*$", "", arg))
    value <- sub("^[^=]+=", "", arg)

    if (!key %in% names(out)) {
      stop("Unknown argument: --", key, call. = FALSE)
    }

    if (key %in% c("backup", "dry_run")) {
      out[[key]] <- tolower(value) %in% c("true", "t", "1", "yes", "y")
    } else {
      out[[key]] <- value
    }
  }

  out
}

normalize_study_id <- function(x) {
  x <- as.character(x %||% NA_character_)
  if (is.na(x) || !nzchar(x)) {
    return(NA_character_)
  }

  hit <- regmatches(toupper(x), regexpr("ST[0-9]+", toupper(x), perl = TRUE))
  if (length(hit) == 0 || identical(hit, character(0))) {
    return(NA_character_)
  }
  hit
}

extract_study_id_from_entry <- function(entry, fallback_name = NULL) {
  fallback_id <- normalize_study_id(fallback_name)
  if (!is.na(fallback_id)) {
    return(fallback_id)
  }

  likely_fields <- c(
    "study_id", "studyId", "studyID", "StudyID", "STUDY_ID",
    "accession", "study_accession", "studyAccession", "id"
  )

  if (is.list(entry)) {
    for (field in likely_fields) {
      if (!is.null(entry[[field]]) && length(entry[[field]]) == 1) {
        id <- normalize_study_id(entry[[field]])
        if (!is.na(id)) {
          return(id)
        }
      }
    }

    scalar_values <- unlist(entry, recursive = TRUE, use.names = FALSE)
    scalar_values <- scalar_values[vapply(scalar_values, function(z) length(z) == 1, logical(1))]
    for (value in scalar_values) {
      id <- normalize_study_id(value)
      if (!is.na(id)) {
        return(id)
      }
    }
  }

  NA_character_
}

metadata_entries_to_lookup <- function(master) {
  if (is.data.frame(master)) {
    entries <- lapply(seq_len(nrow(master)), function(i) as.list(master[i, , drop = FALSE]))
    names(entries) <- vapply(entries, extract_study_id_from_entry, character(1))
  } else if (is.list(master)) {
    entries <- master
  } else {
    stop("Unsupported metadata JSON structure.", call. = FALSE)
  }

  top_id <- if (length(entries) == 1) {
    extract_study_id_from_entry(entries[[1]], names(entries)[1])
  } else {
    NA_character_
  }

  if (length(entries) == 1 && is.list(entries[[1]]) && is.na(top_id)) {
    inner_names <- names(entries[[1]])
    if (!is.null(inner_names) && any(!is.na(vapply(inner_names, normalize_study_id, character(1))))) {
      entries <- entries[[1]]
    }
  }

  ids <- mapply(
    FUN = extract_study_id_from_entry,
    entry = entries,
    fallback_name = names(entries) %||% rep(NA_character_, length(entries)),
    USE.NAMES = FALSE
  )

  keep <- !is.na(ids)
  entries <- entries[keep]
  ids <- ids[keep]

  if (anyDuplicated(ids)) {
    dup_ids <- unique(ids[duplicated(ids)])
    stop("Duplicated study IDs in master metadata: ", paste(dup_ids, collapse = ", "), call. = FALSE)
  }

  names(entries) <- ids
  entries
}

backup_existing_file <- function(path) {
  if (!file.exists(path)) {
    return(NA_character_)
  }

  backup_path <- paste0(path, ".bak_", format(Sys.time(), "%Y%m%d%H%M%S"))
  ok <- file.copy(path, backup_path, overwrite = FALSE)
  if (!ok) {
    stop("Failed to create backup for: ", path, call. = FALSE)
  }
  backup_path
}

write_metadata_json <- function(entry, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- tempfile(pattern = paste0(basename(path), "."), tmpdir = dirname(path))
  write_json(
    entry,
    path = tmp,
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null",
    na = "null"
  )
  file.rename(tmp, path)
  if (!file.exists(path)) {
    stop("Failed to write metadata JSON: ", path, call. = FALSE)
  }
}

args <- parse_args(commandArgs(trailingOnly = TRUE))

if (!file.exists(args$master_json)) {
  stop("Master metadata JSON not found: ", args$master_json, call. = FALSE)
}
if (!dir.exists(args$study_root)) {
  stop("Study root not found: ", args$study_root, call. = FALSE)
}

master <- fromJSON(args$master_json, simplifyVector = FALSE)
metadata_lookup <- metadata_entries_to_lookup(master)

study_dirs <- list.dirs(args$study_root, recursive = FALSE, full.names = TRUE)
study_ids <- vapply(basename(study_dirs), normalize_study_id, character(1))
keep_study_dirs <- !is.na(study_ids)
study_dirs <- study_dirs[keep_study_dirs]
study_ids <- study_ids[keep_study_dirs]

report <- lapply(seq_along(study_dirs), function(i) {
  study_id <- study_ids[[i]]
  study_dir <- study_dirs[[i]]
  metadata_path <- file.path(study_dir, args$metadata_filename)

  status <- "updated"
  message <- ""
  backup_path <- NA_character_
  field_count <- NA_integer_

  if (!study_id %in% names(metadata_lookup)) {
    status <- "missing_in_master"
    message <- "No matching study ID in master metadata."
  } else {
    entry <- metadata_lookup[[study_id]]
    field_count <- if (is.list(entry)) length(entry) else NA_integer_

    if (!args$dry_run) {
      if (args$backup && file.exists(metadata_path)) {
        backup_path <- backup_existing_file(metadata_path)
      }
      write_metadata_json(entry, metadata_path)
    } else {
      status <- "dry_run_matched"
    }
  }

  data.frame(
    study_id = study_id,
    study_dir = study_dir,
    metadata_path = metadata_path,
    status = status,
    field_count = field_count,
    backup_path = backup_path,
    message = message,
    stringsAsFactors = FALSE
  )
})

report_df <- do.call(rbind, report)

master_not_in_dirs <- setdiff(names(metadata_lookup), study_ids)
if (length(master_not_in_dirs) > 0) {
  report_df <- rbind(
    report_df,
    data.frame(
      study_id = master_not_in_dirs,
      study_dir = NA_character_,
      metadata_path = NA_character_,
      status = "master_only",
      field_count = vapply(metadata_lookup[master_not_in_dirs], length, integer(1)),
      backup_path = NA_character_,
      message = "Study exists in master metadata but no matching project folder was found.",
      stringsAsFactors = FALSE
    )
  )
}

dir.create(dirname(args$report_csv), recursive = TRUE, showWarnings = FALSE)
write.csv(report_df, args$report_csv, row.names = FALSE, na = "")

cat("Master metadata entries:", length(metadata_lookup), "\n")
cat("Study folders found:", length(study_ids), "\n")
cat("Updated/dry-run matched:", sum(report_df$status %in% c("updated", "dry_run_matched")), "\n")
cat("Missing in master:", sum(report_df$status == "missing_in_master"), "\n")
cat("Master only:", sum(report_df$status == "master_only"), "\n")
cat("Report:", args$report_csv, "\n")
