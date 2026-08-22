# Re-fetch FULL study descriptions (no truncation, no length gating) for
# every study in the delivery_20260819 manifest, from each source database's
# own public REST API, and patch `description` in place in study_meta.json.
#
# Background: the description field shipped in
#   2_data/raw/delivery_20260819/out_qwen_eval_ml_anno_20260819/*/study_meta.json
# is cut off at exactly 500 characters, mid-sentence, for 57 of 66 ML
# (MetaboLights) studies. MW (Metabolomics Workbench) study_meta.json uses
# the same "description" key but was NOT found truncated in the same way
# (Workbench abstracts tend to be short) -- still refetched here for
# completeness / consistency, using Workbench's own API ("Study Summary" on
# the website, `STUDY.STUDY_SUMMARY` field under the `mwtab` REST context).
#
# This is not a phenomap bug -- phenomap_read_study_meta_row() just does
# coalesce(meta$study_summary, meta$description) with no truncation logic.
# The field already arrives short in the delivered JSON, upstream of this
# repo. But it DOES feed both GPT phenotype-classification prompts in
# 02_normalize_workbench_phenotype.R (principal_phenotype_prompt() and
# ontology_selection_prompt() both include study_summary as context), so a
# truncated description can silently degrade phenotype extraction too.
#
# Design:
#   - Input is a manifest CSV (study_id, source_db, case_dir) rather than a
#     live directory walk, so a server run works from a fixed, reviewable
#     list of exactly the studies already in our data (build the manifest
#     with build_description_refetch_manifest(), or use the
#     study_description_manifest.csv shipped alongside this script).
#   - source_db dispatches to the right API: "ml" -> MetaboLights, "mw" ->
#     Metabolomics Workbench.
#   - No length/"improvement" gating: whatever the API returns on a
#     successful fetch is written, unconditionally (per your call -- you
#     want the full text, not "only if longer"). A failed fetch leaves the
#     existing study_meta.json untouched (there's nothing better to write).
#   - Fork-based parallelism via parallel::mclapply (same approach as
#     1_code/2_tidy_relationship/05_tidy_module_module_relationship.R),
#     Unix-only; falls back to serial lapply elsewhere.
#   - A timestamped backup of each study_meta.json is written before it's
#     overwritten (--backup=FALSE to skip).
#   - Every study gets a row in the output report (updated / fetch_failed),
#     nothing is silently skipped.
#
# Both fetchers are now confirmed working empirically:
#   - get_study_description_ml("MTBLS12713") -> longer than 500 chars, not
#     cut at the old boundary.
#   - get_study_description_mw("ST000270") -> went through two wrong guesses
#     before landing here: (1) the `summary` context is just overview
#     metadata (title/institute/n_samples), no free text at all; (2) the
#     `mwtab`/`mwtab/json` context DOES contain STUDY.STUDY_SUMMARY with the
#     full text, but that payload also includes the entire per-sample
#     metabolite data matrix and, for ST000270 at least, fails to parse as
#     JSON (jsonlite::fromJSON() returns NULL on it -- most likely an
#     invalid JSON token somewhere in the numeric data block). The fix:
#     fetch `mwtab/txt` (the plain-text mwTab file, same content) and pull
#     "ST:STUDY_SUMMARY" out with a regex instead of a JSON parser -- see
#     extract_wrapped_mwtab_field() / get_study_description_mw() below.
#
#   source("1_code/0_prepare_raw/06_refetch_study_description.R")
#   d_ml <- get_study_description_ml("MTBLS12713"); nchar(d_ml); cat(d_ml, "\n")
#   d_mw <- get_study_description_mw("ST000270");     nchar(d_mw); cat(d_mw, "\n")
#
# Usage (on the server, after uploading the repo + 2_data):
#   Rscript 1_code/0_prepare_raw/06_refetch_study_description.R \
#     --manifest_csv=2_data/raw/delivery_20260819/study_description_manifest.csv \
#     --workers=16
#
#   # Test/limit to one database first:
#   Rscript 1_code/0_prepare_raw/06_refetch_study_description.R --source=ml --workers=8
#   Rscript 1_code/0_prepare_raw/06_refetch_study_description.R --source=mw --workers=8

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

parse_refetch_args <- function() {
  raw <- commandArgs(trailingOnly = TRUE)
  args <- list(
    manifest_csv = file.path("2_data", "raw", "delivery_20260819", "study_description_manifest.csv"),
    report_csv = file.path("2_data", "raw", "delivery_20260819", "study_description_refetch_report.csv"),
    ml_api_base_url = "https://www.ebi.ac.uk/metabolights/ws/studies",
    mw_api_base_url = "https://www.metabolomicsworkbench.org/rest/study/study_id",
    source = "all",   # "all" | "mw" | "ml" -- filters the manifest before running
    backup = TRUE,
    dry_run = FALSE,
    sleep_seconds = 0.3,
    workers = max(1L, parallel::detectCores(logical = FALSE) - 1L)
  )
  for (arg in raw) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (!key %in% names(args)) next
    args[[key]] <- value
  }
  args$backup <- as.logical(args$backup)
  if (is.na(args$backup)) args$backup <- TRUE
  args$dry_run <- as.logical(args$dry_run)
  if (is.na(args$dry_run)) args$dry_run <- FALSE
  args$sleep_seconds <- suppressWarnings(as.numeric(args$sleep_seconds))
  if (is.na(args$sleep_seconds) || args$sleep_seconds < 0) args$sleep_seconds <- 0.3
  args$workers <- suppressWarnings(as.integer(args$workers))
  if (is.na(args$workers) || args$workers < 1L) {
    args$workers <- max(1L, parallel::detectCores(logical = FALSE) - 1L)
  }
  args$source <- tolower(phenomap_clean_scalar(args$source, "all"))
  if (!args$source %in% c("all", "mw", "ml")) args$source <- "all"
  args
}

try_get_json <- function(url, timeout_seconds = 30) {
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required.")
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.")
  resp <- tryCatch(httr::GET(url, httr::timeout(timeout_seconds)), error = function(e) e)
  if (inherits(resp, "error") || httr::status_code(resp) >= 400) return(NULL)
  tryCatch(
    jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"), simplifyVector = FALSE),
    error = function(e) NULL
  )
}

# MetaboLights -- confirmed working against the granular /description
# sub-resource (see file header).
get_study_description_ml <- function(accession,
                                     api_base_url = "https://www.ebi.ac.uk/metabolights/ws/studies") {
  base <- sub("/+$", "", api_base_url)

  payload <- try_get_json(paste0(base, "/", accession, "/description"))
  desc <- phenomap_clean_scalar(payload$description %||% payload$content)
  if (!is.na(desc)) return(desc)

  # Fallback: general study endpoint, a few plausible nested shapes.
  payload <- try_get_json(paste0(base, "/", accession))
  if (is.null(payload)) return(NA_character_)
  candidates <- list(
    payload$description,
    payload$content$description,
    payload$study$description,
    payload$data$description,
    payload$isaInvestigation$description,
    payload$investigation$description
  )
  for (candidate in candidates) {
    resolved <- phenomap_clean_scalar(candidate)
    if (!is.na(resolved)) return(resolved)
  }
  NA_character_
}

# Metabolomics Workbench -- website field "Study Summary". Confirmed the
# `summary` context is just overview metadata (title/institute/n_samples,
# no free text). The real text is in the `mwtab` file, under the
# "ST:STUDY_SUMMARY" tag ("PR:PROJECT_SUMMARY" is a shorter duplicate of the
# same text, used only as a fallback). IMPORTANT: this fetches `mwtab/txt`
# (the plain mwTab text format) rather than `mwtab`/`mwtab/json` -- the JSON
# variant includes the FULL data section (every metabolite x every sample
# intensity value for the whole study) and, empirically, that payload fails
# to parse as JSON for at least ST000270 (jsonlite::fromJSON() on it comes
# back NULL -- most likely an invalid JSON token somewhere in the numeric
# data block, e.g. a bare NaN, which the data itself can contain but JSON
# does not allow). The plain-text file has the exact same content but is
# parsed here with a simple regex instead of a JSON parser, so it's immune
# to that failure regardless of what the data section contains.
#
# mwTab wraps long free-text fields across multiple lines, each line
# repeating the same tag, e.g.:
#   ST:STUDY_SUMMARY   In the current study we will perform global...
#   ST:STUDY_SUMMARY   metabolic profiling on serum samples obtained...
# extract_wrapped_mwtab_field() collects every such line and joins them with
# a single space to reconstruct the full paragraph.
extract_wrapped_mwtab_field <- function(text, tag) {
  if (is.na(text) || !nzchar(text)) return(NA_character_)
  lines <- strsplit(text, "\r?\n")[[1]]
  pattern <- paste0("^[ \t]*", tag, "[ \t]+(.*)$")
  hits <- grep(pattern, lines, value = TRUE)
  if (length(hits) == 0) return(NA_character_)
  parts <- trimws(sub(pattern, "\\1", hits))
  parts <- parts[nzchar(parts)]
  if (length(parts) == 0) return(NA_character_)
  paste(parts, collapse = " ")
}

get_study_description_mw <- function(accession,
                                     api_base_url = "https://www.metabolomicsworkbench.org/rest/study/study_id",
                                     timeout_seconds = 60) {
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required.")
  base <- sub("/+$", "", api_base_url)
  url <- paste0(base, "/", accession, "/mwtab/txt")

  resp <- tryCatch(httr::GET(url, httr::timeout(timeout_seconds)), error = function(e) e)
  if (inherits(resp, "error") || httr::status_code(resp) >= 400) return(NA_character_)
  txt <- httr::content(resp, as = "text", encoding = "UTF-8")

  desc <- extract_wrapped_mwtab_field(txt, "ST:STUDY_SUMMARY")
  if (!is.na(desc)) return(desc)
  extract_wrapped_mwtab_field(txt, "PR:PROJECT_SUMMARY")
}

get_study_description <- function(accession, source_db, ml_api_base_url, mw_api_base_url) {
  if (identical(source_db, "ml")) {
    get_study_description_ml(accession, ml_api_base_url)
  } else if (identical(source_db, "mw")) {
    get_study_description_mw(accession, mw_api_base_url)
  } else {
    NA_character_
  }
}

backup_json <- function(path) {
  backup_path <- paste0(path, ".bak_", format(Sys.time(), "%Y%m%d%H%M%S"))
  ok <- file.copy(path, backup_path, overwrite = FALSE)
  if (!ok) stop("Failed to create backup for: ", path)
  backup_path
}

write_study_meta_json <- function(meta, path) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.")
  tmp <- tempfile(pattern = paste0(basename(path), "."), tmpdir = dirname(path))
  jsonlite::write_json(meta, path = tmp, pretty = TRUE, auto_unbox = TRUE, null = "null", na = "null")
  file.rename(tmp, path)
}

refetch_one_study <- function(row, ml_api_base_url, mw_api_base_url, backup, dry_run, sleep_seconds) {
  accession <- row$study_id
  source_db <- tolower(row$source_db)
  case_dir <- row$case_dir
  meta_path <- file.path(case_dir, "study_meta.json")

  if (!file.exists(meta_path)) {
    return(data.frame(
      study_id = accession, source_db = source_db, status = "missing_study_meta_json",
      old_length = NA_integer_, new_length = NA_integer_, stringsAsFactors = FALSE
    ))
  }

  meta <- phenomap_read_json(meta_path)
  old_desc <- phenomap_clean_scalar(meta$description)
  old_len <- if (is.na(old_desc)) 0L else nchar(old_desc)

  message("Fetching: [", source_db, "] ", accession, " (current length ", old_len, ")")
  new_desc <- tryCatch(
    get_study_description(accession, source_db, ml_api_base_url, mw_api_base_url),
    error = function(e) NA_character_
  )
  if (sleep_seconds > 0) Sys.sleep(sleep_seconds)

  if (is.na(new_desc) || !nzchar(new_desc)) {
    return(data.frame(
      study_id = accession, source_db = source_db, status = "fetch_failed",
      old_length = old_len, new_length = NA_integer_, stringsAsFactors = FALSE
    ))
  }

  new_len <- nchar(new_desc)

  if (isTRUE(dry_run)) {
    return(data.frame(
      study_id = accession, source_db = source_db, status = "dry_run_would_update",
      old_length = old_len, new_length = new_len, stringsAsFactors = FALSE
    ))
  }

  if (isTRUE(backup)) backup_json(meta_path)
  meta$description <- new_desc
  write_study_meta_json(meta, meta_path)

  data.frame(
    study_id = accession, source_db = source_db, status = "updated",
    old_length = old_len, new_length = new_len, stringsAsFactors = FALSE
  )
}

refetch_study_descriptions_parallel <- function(manifest_csv,
                                                report_csv,
                                                ml_api_base_url = "https://www.ebi.ac.uk/metabolights/ws/studies",
                                                mw_api_base_url = "https://www.metabolomicsworkbench.org/rest/study/study_id",
                                                source = "all",
                                                backup = TRUE,
                                                dry_run = FALSE,
                                                sleep_seconds = 0.3,
                                                workers = max(1L, parallel::detectCores(logical = FALSE) - 1L)) {
  if (!file.exists(manifest_csv)) stop("manifest_csv does not exist: ", manifest_csv)
  manifest <- utils::read.csv(manifest_csv, stringsAsFactors = FALSE, check.names = FALSE)
  if (!all(c("study_id", "source_db", "case_dir") %in% colnames(manifest))) {
    stop("manifest_csv must contain study_id, source_db, case_dir columns.")
  }
  manifest$source_db <- tolower(manifest$source_db)

  if (!identical(source, "all")) {
    manifest <- manifest[manifest$source_db == source, , drop = FALSE]
  }
  message("Refetching descriptions for ", nrow(manifest), " study/studies (source = ", source, ", workers = ", workers, ").")

  use_workers <- if (.Platform$OS.type == "unix") max(1L, workers) else 1L
  row_list <- split(manifest, seq_len(nrow(manifest)))

  results <- if (use_workers > 1L) {
    parallel::mclapply(
      row_list,
      refetch_one_study,
      ml_api_base_url = ml_api_base_url,
      mw_api_base_url = mw_api_base_url,
      backup = backup,
      dry_run = dry_run,
      sleep_seconds = sleep_seconds,
      mc.cores = use_workers
    )
  } else {
    lapply(
      row_list,
      refetch_one_study,
      ml_api_base_url = ml_api_base_url,
      mw_api_base_url = mw_api_base_url,
      backup = backup,
      dry_run = dry_run,
      sleep_seconds = sleep_seconds
    )
  }

  # mclapply returns a try-error object (not a data.frame) for any worker
  # that crashed rather than propagating -- keep those visible in the
  # report instead of letting do.call(rbind, ...) fail outright.
  results <- lapply(seq_along(results), function(i) {
    res <- results[[i]]
    if (is.data.frame(res)) return(res)
    row <- row_list[[i]]
    data.frame(
      study_id = row$study_id[[1]], source_db = row$source_db[[1]], status = "worker_error",
      old_length = NA_integer_, new_length = NA_integer_, stringsAsFactors = FALSE
    )
  })

  report <- do.call(rbind, results)
  phenomap_write_csv(report, report_csv)

  message("Done. Status counts:")
  print(table(report$source_db, report$status))
  message("Report: ", report_csv)
  invisible(report)
}

# Rebuild the manifest from disk (study_id, source_db, case_dir) if you ever
# need a fresh one instead of the shipped study_description_manifest.csv --
# e.g. after a future delivery adds more studies.
build_description_refetch_manifest <- function(
  mw_case_root = file.path("2_data", "raw", "delivery_20260819", "out_qwen_eval_mw_anno_20260819"),
  ml_case_root = file.path("2_data", "raw", "delivery_20260819", "out_qwen_eval_ml_anno_20260819"),
  output_csv = file.path("2_data", "raw", "delivery_20260819", "study_description_manifest.csv")
) {
  one_db <- function(case_root, source_db) {
    dirs <- sort(list.dirs(case_root, recursive = FALSE, full.names = TRUE))
    do.call(rbind, lapply(dirs, function(d) {
      meta_path <- file.path(d, "study_meta.json")
      current_length <- NA_integer_
      if (file.exists(meta_path)) {
        meta <- phenomap_read_json(meta_path)
        desc <- phenomap_clean_scalar(meta$description)
        current_length <- if (is.na(desc)) 0L else nchar(desc)
      }
      data.frame(
        study_id = basename(d), source_db = source_db, case_dir = d,
        current_description_length = current_length, stringsAsFactors = FALSE
      )
    }))
  }

  manifest <- rbind(one_db(mw_case_root, "mw"), one_db(ml_case_root, "ml"))
  phenomap_write_csv(manifest, output_csv)
  message("Wrote manifest with ", nrow(manifest), " studies to ", output_csv)
  invisible(manifest)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- parse_refetch_args()
  refetch_study_descriptions_parallel(
    manifest_csv = args$manifest_csv,
    report_csv = args$report_csv,
    ml_api_base_url = args$ml_api_base_url,
    mw_api_base_url = args$mw_api_base_url,
    source = args$source,
    backup = args$backup,
    dry_run = args$dry_run,
    sleep_seconds = args$sleep_seconds,
    workers = args$workers
  )
}
