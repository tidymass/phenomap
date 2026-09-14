#!/usr/bin/env Rscript

# Fetch full study descriptions for the final PhenoMAP 2026-09-13 accession set.
#
# Inputs:
#   2_data/finalversion_0913/phenomap_retained_study_accessions.csv
#
# Outputs:
#   2_data/finalversion_0913/study_descriptions_refetched.csv
#   2_data/finalversion_0913/study_descriptions_refetch_report.csv
#
# This script only creates CSV outputs. It does not modify study_meta.json or
# any delivered result files.

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

parse_args <- function() {
  args <- list(
    input_csv = file.path("2_data", "finalversion_0913", "phenomap_retained_study_accessions.csv"),
    output_csv = file.path("2_data", "finalversion_0913", "study_descriptions_refetched.csv"),
    report_csv = file.path("2_data", "finalversion_0913", "study_descriptions_refetch_report.csv"),
    source = "all",
    limit = NA_integer_,
    overwrite = FALSE,
    sleep_seconds = 0.3,
    timeout_seconds = 60
  )

  raw <- commandArgs(trailingOnly = TRUE)
  for (arg in raw) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (!key %in% names(args)) next
    args[[key]] <- value
  }

  args$source <- tolower(clean_scalar(args$source, "all"))
  if (!args$source %in% c("all", "mw", "ml")) args$source <- "all"

  args$limit <- suppressWarnings(as.integer(args$limit))
  if (is.na(args$limit) || args$limit < 1L) args$limit <- NA_integer_

  args$overwrite <- as.logical(args$overwrite)
  if (is.na(args$overwrite)) args$overwrite <- FALSE

  args$sleep_seconds <- suppressWarnings(as.numeric(args$sleep_seconds))
  if (is.na(args$sleep_seconds) || args$sleep_seconds < 0) args$sleep_seconds <- 0.3

  args$timeout_seconds <- suppressWarnings(as.numeric(args$timeout_seconds))
  if (is.na(args$timeout_seconds) || args$timeout_seconds < 1) args$timeout_seconds <- 60

  args
}

clean_scalar <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0) return(default)
  x <- as.character(x[[1]])
  x <- trimws(x)
  if (!nzchar(x) || toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")) return(default)
  x
}

collapse_text <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  x <- unlist(x, recursive = TRUE, use.names = FALSE)
  x <- trimws(as.character(x))
  x <- x[nzchar(x) & !is.na(x)]
  if (length(x) == 0) return(NA_character_)
  paste(unique(x), collapse = " ")
}

decode_basic_html_entities <- function(x) {
  if (is.na(x) || !nzchar(x)) return(x)
  x <- gsub("&nbsp;|&#160;", " ", x)
  x <- gsub("&amp;", "&", x)
  x <- gsub("&lt;", "<", x)
  x <- gsub("&gt;", ">", x)
  x <- gsub("&quot;", "\"", x)
  x <- gsub("&#39;|&apos;", "'", x)
  x
}

plain_text <- function(x) {
  if (is.na(x) || !nzchar(x)) return(NA_character_)
  x <- gsub("<br\\s*/?>", " ", x, ignore.case = TRUE)
  x <- gsub("</p\\s*>", " ", x, ignore.case = TRUE)
  x <- gsub("<[^>]+>", " ", x)
  x <- decode_basic_html_entities(x)
  x <- gsub("[[:space:]]+", " ", x)
  trimws(x)
}

http_get_text <- function(url, timeout_seconds = 60) {
  if (!requireNamespace("httr", quietly = TRUE)) {
    stop("Package 'httr' is required. Install it with install.packages('httr').")
  }
  resp <- tryCatch(
    httr::GET(url, httr::timeout(timeout_seconds)),
    error = function(e) e
  )
  if (inherits(resp, "error")) {
    return(list(ok = FALSE, status = NA_integer_, text = NA_character_, error = conditionMessage(resp)))
  }
  status <- httr::status_code(resp)
  text <- httr::content(resp, as = "text", encoding = "UTF-8")
  if (status >= 400) {
    return(list(ok = FALSE, status = status, text = text, error = paste("HTTP", status)))
  }
  list(ok = TRUE, status = status, text = text, error = NA_character_)
}

parse_json <- function(text) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("Package 'jsonlite' is required. Install it with install.packages('jsonlite').")
  }
  tryCatch(
    jsonlite::fromJSON(text, simplifyVector = FALSE),
    error = function(e) NULL
  )
}

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

fetch_metabolights <- function(accession, timeout_seconds) {
  base <- "https://www.ebi.ac.uk/metabolights/ws/studies"
  desc_url <- paste0(base, "/", accession, "/description")
  desc_resp <- http_get_text(desc_url, timeout_seconds)

  description <- NA_character_
  title <- NA_character_
  fetch_source <- desc_url

  if (isTRUE(desc_resp$ok)) {
    payload <- parse_json(desc_resp$text)
    description <- clean_scalar(payload$description %||% payload$content)
  }

  study_url <- paste0(base, "/", accession)
  study_resp <- http_get_text(study_url, timeout_seconds)
  if (isTRUE(study_resp$ok)) {
    payload <- parse_json(study_resp$text)
    title <- clean_scalar(
      payload$title %||%
        payload$content$title %||%
        payload$study$title %||%
        payload$data$title %||%
        payload$isaInvestigation$title %||%
        payload$investigation$title
    )
    if (is.na(description)) {
      description <- clean_scalar(
        payload$description %||%
          payload$content$description %||%
          payload$study$description %||%
          payload$data$description %||%
          payload$isaInvestigation$description %||%
          payload$investigation$description
      )
      fetch_source <- study_url
    }
  }

  status <- if (!is.na(description)) "ok" else "fetch_failed"
  error <- if (identical(status, "ok")) NA_character_ else desc_resp$error %||% study_resp$error

  list(
    status = status,
    title = title,
    description_raw = description,
    fetch_source = fetch_source,
    http_status = desc_resp$status %||% study_resp$status,
    error = clean_scalar(error)
  )
}

fetch_workbench <- function(accession, timeout_seconds) {
  url <- paste0(
    "https://www.metabolomicsworkbench.org/rest/study/study_id/",
    accession,
    "/mwtab/txt"
  )
  resp <- http_get_text(url, timeout_seconds)
  if (!isTRUE(resp$ok)) {
    return(list(
      status = "fetch_failed",
      title = NA_character_,
      description_raw = NA_character_,
      fetch_source = url,
      http_status = resp$status,
      error = clean_scalar(resp$error)
    ))
  }

  title <- extract_wrapped_mwtab_field(resp$text, "ST:STUDY_TITLE")
  if (is.na(title)) title <- extract_wrapped_mwtab_field(resp$text, "PR:PROJECT_TITLE")

  description <- extract_wrapped_mwtab_field(resp$text, "ST:STUDY_SUMMARY")
  if (is.na(description)) description <- extract_wrapped_mwtab_field(resp$text, "PR:PROJECT_SUMMARY")

  list(
    status = if (!is.na(description)) "ok" else "fetch_failed",
    title = title,
    description_raw = description,
    fetch_source = url,
    http_status = resp$status,
    error = if (!is.na(description)) NA_character_ else "No STUDY_SUMMARY or PROJECT_SUMMARY in mwtab"
  )
}

normalize_database <- function(database, accession) {
  db <- tolower(clean_scalar(database, ""))
  if (grepl("workbench|^mw$", db)) return("mw")
  if (grepl("metabolights|^ml$", db)) return("ml")
  if (grepl("^ST[0-9]+$", accession)) return("mw")
  if (grepl("^MTBLS[0-9]+$", accession)) return("ml")
  NA_character_
}

make_empty_row <- function(accession, database, database_key, status, error = NA_character_) {
  data.frame(
    study_accession = accession,
    database = database,
    database_key = database_key,
    title = NA_character_,
    description_raw = NA_character_,
    description_plain = NA_character_,
    description_length = NA_integer_,
    fetch_status = status,
    fetch_source = NA_character_,
    http_status = NA_integer_,
    error = error,
    fetched_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %z"),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

fetch_one <- function(accession, database, sleep_seconds, timeout_seconds) {
  database_key <- normalize_database(database, accession)
  if (is.na(database_key)) {
    return(make_empty_row(accession, database, database_key, "unknown_database", database))
  }

  message("[", database_key, "] fetching ", accession)
  result <- tryCatch(
    {
      if (identical(database_key, "ml")) {
        fetch_metabolights(accession, timeout_seconds)
      } else {
        fetch_workbench(accession, timeout_seconds)
      }
    },
    error = function(e) list(
      status = "error",
      title = NA_character_,
      description_raw = NA_character_,
      fetch_source = NA_character_,
      http_status = NA_integer_,
      error = conditionMessage(e)
    )
  )
  if (sleep_seconds > 0) Sys.sleep(sleep_seconds)

  desc_plain <- plain_text(result$description_raw)
  data.frame(
    study_accession = accession,
    database = database,
    database_key = database_key,
    title = clean_scalar(result$title),
    description_raw = clean_scalar(result$description_raw),
    description_plain = desc_plain,
    description_length = if (is.na(desc_plain)) 0L else nchar(desc_plain),
    fetch_status = clean_scalar(result$status, "error"),
    fetch_source = clean_scalar(result$fetch_source),
    http_status = as.integer(result$http_status %||% NA_integer_),
    error = clean_scalar(result$error),
    fetched_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %z"),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

read_existing_successes <- function(output_csv) {
  if (!file.exists(output_csv)) return(NULL)
  existing <- utils::read.csv(output_csv, stringsAsFactors = FALSE, check.names = FALSE)
  required <- c("study_accession", "database_key", "fetch_status")
  if (!all(required %in% names(existing))) return(NULL)
  existing[existing$fetch_status == "ok", , drop = FALSE]
}

write_outputs <- function(rows, output_csv, report_csv) {
  rows <- rows[order(rows$database_key, rows$study_accession), , drop = FALSE]
  dir.create(dirname(output_csv), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(rows, output_csv, row.names = FALSE, na = "")

  report <- data.frame(
    database_key = names(table(rows$database_key, useNA = "ifany")),
    stringsAsFactors = FALSE
  )
  status_counts <- as.data.frame.matrix(table(rows$database_key, rows$fetch_status, useNA = "ifany"))
  status_counts$database_key <- rownames(status_counts)
  status_counts <- status_counts[, c("database_key", setdiff(names(status_counts), "database_key")), drop = FALSE]
  utils::write.csv(status_counts, report_csv, row.names = FALSE, na = "")
}

main <- function() {
  args <- parse_args()
  if (!file.exists(args$input_csv)) stop("input_csv does not exist: ", args$input_csv)

  accessions <- utils::read.csv(args$input_csv, stringsAsFactors = FALSE, check.names = FALSE)
  if (!all(c("study_accession", "database") %in% names(accessions))) {
    stop("input_csv must contain columns: study_accession,database")
  }
  accessions$database_key <- mapply(normalize_database, accessions$database, accessions$study_accession)
  accessions <- accessions[!duplicated(accessions[c("study_accession", "database_key")]), , drop = FALSE]

  if (!identical(args$source, "all")) {
    accessions <- accessions[accessions$database_key == args$source, , drop = FALSE]
  }

  if (!is.na(args$limit)) {
    accessions <- head(accessions, args$limit)
  }

  existing_ok <- if (isTRUE(args$overwrite)) NULL else read_existing_successes(args$output_csv)
  done_keys <- character(0)
  if (!is.null(existing_ok) && nrow(existing_ok) > 0) {
    done_keys <- paste(existing_ok$study_accession, existing_ok$database_key, sep = "\r")
  }

  todo_keys <- paste(accessions$study_accession, accessions$database_key, sep = "\r")
  todo <- accessions[!todo_keys %in% done_keys, , drop = FALSE]

  message("Input studies: ", nrow(accessions))
  message("Already fetched ok: ", length(done_keys))
  message("To fetch now: ", nrow(todo))
  message("Output: ", args$output_csv)

  new_rows <- vector("list", nrow(todo))
  for (i in seq_len(nrow(todo))) {
    new_rows[[i]] <- fetch_one(
      accession = todo$study_accession[[i]],
      database = todo$database[[i]],
      sleep_seconds = args$sleep_seconds,
      timeout_seconds = args$timeout_seconds
    )
    combined <- do.call(rbind, c(
      if (!is.null(existing_ok)) list(existing_ok) else list(),
      new_rows[seq_len(i)]
    ))
    write_outputs(combined, args$output_csv, args$report_csv)
  }

  final_rows <- do.call(rbind, c(
    if (!is.null(existing_ok)) list(existing_ok) else list(),
    new_rows[!vapply(new_rows, is.null, logical(1))]
  ))
  if (is.null(final_rows)) final_rows <- make_empty_row(NA_character_, NA_character_, NA_character_, "no_rows")
  write_outputs(final_rows, args$output_csv, args$report_csv)

  message("Done. Status counts:")
  print(table(final_rows$database_key, final_rows$fetch_status, useNA = "ifany"))
  message("Wrote: ", args$output_csv)
  message("Wrote: ", args$report_csv)
}

if (identical(environment(), globalenv()) && !interactive()) {
  main()
}
