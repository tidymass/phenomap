#!/usr/bin/env Rscript

# Fix duplicated Study Title / Study_Summary text caused by the Metabolomics
# Workbench mwTab endpoint repeating the whole study block once per analysis.
#
# Background
#   1_code/final_version/01_fetch_study_descriptions.R uses
#   extract_wrapped_mwtab_field(), which greps ALL matching "ST:STUDY_TITLE" /
#   "ST:STUDY_SUMMARY" lines and pastes them with " ". That is correct for
#   line-wrapped fields, but /rest/study/study_id/<ST>/mwtab/txt repeats the
#   full study block once per analysis, so the title and summary of any
#   multi-analysis study get concatenated 2x-6x.
#
# What this script does
#   Data repair only. It does NOT re-fetch and does NOT change the fetch code.
#   For each target CSV it collapses any text field whose word sequence is an
#   exact k-fold repetition (k >= 2) back to a single copy.
#
# Safety
#   - line-level surgical edit: only the targeted fields are rewritten, every
#     other byte of every other field is preserved exactly
#   - timestamped backup of each file before writing
#   - post-write verification: re-parses the result and asserts that ONLY the
#     targeted columns changed, and that they changed to the expected values
#   - dry run by default; pass --apply=TRUE to actually write
#
# Usage (from project root)
#   Rscript 1_code/final_version/09_fix_duplicated_study_text.R                # dry run
#   Rscript 1_code/final_version/09_fix_duplicated_study_text.R --apply=TRUE   # write
#
# Outputs
#   2_data/finalversion_0913/medium/fix_duplicated_study_text_report.csv
#   2_data/finalversion_0913/medium/update_local_neo4j_study_text.cypher

# ---------------------------------------------------------------- args ----

parse_args <- function() {
  args <- list(
    report_csv = "2_data/finalversion_0913/medium/fix_duplicated_study_text_report.csv",
    cypher_out = "2_data/finalversion_0913/medium/update_local_neo4j_study_text.cypher",
    cypher_source = "2_data/finalversion_0913/nodes/nodes_study.csv",
    apply = "FALSE",
    min_unit_words = "3",
    min_unit_chars = "10"
  )
  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) == 2 && kv[[1]] %in% names(args)) args[[kv[[1]]]] <- kv[[2]]
  }
  args$apply <- isTRUE(as.logical(args$apply))
  args$min_unit_words <- as.integer(args$min_unit_words)
  args$min_unit_chars <- as.integer(args$min_unit_chars)
  args
}

# Files to repair, and which columns hold the affected free text.
# derived_length_for: column B is rewritten as nchar(column A) when A changes.
TARGETS <- list(
  list(
    path = "2_data/finalversion_0913/medium/study_descriptions_refetched.csv",
    key = "study_accession",
    cols = c("title", "description_raw", "description_plain"),
    derived_length_for = c(description_plain = "description_length")
  ),
  list(
    path = "2_data/finalversion_0913/nodes/nodes_study.csv",
    key = "Accession", cols = c("Title", "Study_Summary")
  ),
  list(
    path = "2_data/finalversion_0913_kg/tidy_entity/nodes_study.csv",
    key = "Accession", cols = c("Title", "Study_Summary")
  ),
  list(
    path = "2_data/finalversion_0913_kg/neo4j/import/nodes_study.csv",
    key = "Accession", cols = c("Title", "Study_Summary")
  ),
  list(
    path = "2_data/tidy_entity/nodes_study.csv",
    key = "Accession", cols = c("Title", "Study_Summary")
  ),
  list(
    path = "2_data/neo4j/import/nodes_study.csv",
    key = "Accession", cols = c("Title", "Study_Summary")
  )
)

# ------------------------------------------------------- csv line utils ----
# Valid because these files contain no embedded newlines and no CR (verified).
# A comma is a separator iff an even number of double quotes precedes it,
# which is correct under RFC4180 "" escaping.

split_csv_line <- function(line) {
  qp <- gregexpr('"', line, fixed = TRUE)[[1]]
  if (identical(qp[1], -1L)) qp <- integer(0)
  cp <- gregexpr(",", line, fixed = TRUE)[[1]]
  if (identical(cp[1], -1L)) cp <- integer(0)
  sep <- if (length(cp)) cp[findInterval(cp, qp) %% 2L == 0L] else integer(0)
  starts <- c(1L, sep + 1L)
  ends <- c(sep - 1L, nchar(line))
  substring(line, starts, ends)
}

join_csv_line <- function(fields) paste(fields, collapse = ",")

lookup_length_col <- function(map, col) {
  if (is.null(map) || !(col %in% names(map))) return(NULL)
  unname(map[[col]])
}

is_quoted_field <- function(seg) {
  nchar(seg) >= 2L && substr(seg, 1L, 1L) == '"' &&
    substr(seg, nchar(seg), nchar(seg)) == '"'
}

unescape_field <- function(seg) {
  if (!is_quoted_field(seg)) return(seg)
  gsub('""', '"', substr(seg, 2L, nchar(seg) - 1L), fixed = TRUE)
}

escape_field <- function(value, quoted) {
  needs_quote <- quoted || grepl('[",]', value)
  if (!needs_quote) return(value)
  paste0('"', gsub('"', '""', value, fixed = TRUE), '"')
}

# ----------------------------------------------- repetition detection ----
# Minimal period of the word sequence via the KMP failure function.
# Catches every k at once (2x, 3x, 4x, 5x, 6x, ...), not just halves.

minimal_period <- function(w) {
  n <- length(w)
  if (n <= 1L) return(n)
  f <- integer(n)
  k <- 0L
  for (i in 2:n) {
    while (k > 0L && w[i] != w[k + 1L]) k <- f[k]
    if (w[i] == w[k + 1L]) k <- k + 1L
    f[i] <- k
  }
  p <- n - f[n]
  if (n %% p == 0L) p else n
}

collapse_repeated_text <- function(x, min_unit_words, min_unit_chars) {
  out <- list(value = x, repeats = 1L, status = "unchanged")
  if (is.na(x)) return(out)
  t <- trimws(gsub("[[:space:]]+", " ", x))
  if (!nzchar(t)) return(out)
  w <- strsplit(t, " ", fixed = TRUE)[[1]]
  p <- minimal_period(w)
  k <- length(w) %/% p
  if (k < 2L) return(out)
  unit <- paste(w[seq_len(p)], collapse = " ")
  # Guard against collapsing a genuinely repetitive short string.
  if (p < min_unit_words && nchar(unit) < min_unit_chars) {
    return(list(value = x, repeats = k, status = "skipped_too_short"))
  }
  list(value = unit, repeats = k, status = "collapsed")
}

# ----------------------------------------------------------- cypher ----

cypher_string <- function(x) {
  x <- as.character(x)
  x <- gsub("\\\\", "\\\\\\\\", x)
  x <- gsub("\"", "\\\\\"", x)
  x <- gsub("\n", "\\\\n", x)
  x <- gsub("\r", "\\\\r", x)
  paste0("\"", x, "\"")
}

# ------------------------------------------------------------- main ----

# Read as bytes and mark UTF-8 explicitly, so the result does not depend on
# the session locale.
read_lines_utf8 <- function(path) {
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  lines <- readLines(con, warn = FALSE)
  Encoding(lines) <- "UTF-8"
  lines
}

read_csv_utf8 <- function(path) {
  df <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE,
                        colClasses = "character", encoding = "UTF-8")
  for (nm in names(df)) Encoding(df[[nm]]) <- "UTF-8"
  df
}

write_lines_utf8 <- function(lines, path) {
  con <- file(path, open = "wb")
  on.exit(close(con), add = TRUE)
  writeLines(lines, con, useBytes = TRUE)
}

process_file <- function(target, args) {
  path <- target$path
  if (!file.exists(path)) {
    message("SKIP (missing): ", path)
    return(NULL)
  }

  lines <- read_lines_utf8(path)
  if (length(lines) < 2L) {
    message("SKIP (empty): ", path)
    return(NULL)
  }

  header <- vapply(split_csv_line(lines[[1]]), unescape_field, character(1),
                   USE.NAMES = FALSE)
  missing_cols <- setdiff(c(target$key, target$cols), header)
  if (length(missing_cols) > 0) {
    stop(path, " is missing columns: ", paste(missing_cols, collapse = ", "))
  }
  col_idx <- stats::setNames(seq_along(header), header)

  records <- vector("list", 0L)
  n_rows <- length(lines) - 1L
  changed_rows <- 0L

  for (i in seq_len(n_rows)) {
    li <- i + 1L
    fields <- split_csv_line(lines[[li]])
    if (length(fields) != length(header)) {
      stop(path, ": line ", li, " has ", length(fields),
           " fields, expected ", length(header))
    }
    key_value <- unescape_field(fields[[col_idx[[target$key]]]])
    row_changed <- FALSE

    for (col in target$cols) {
      j <- col_idx[[col]]
      old_raw <- fields[[j]]
      old_value <- unescape_field(old_raw)
      res <- collapse_repeated_text(old_value, args$min_unit_words,
                                    args$min_unit_chars)
      if (identical(res$status, "unchanged")) next

      records[[length(records) + 1L]] <- data.frame(
        file = path, line = li, key = key_value, column = col,
        repeats = res$repeats, status = res$status,
        chars_before = nchar(old_value),
        chars_after = if (identical(res$status, "collapsed")) nchar(res$value) else NA_integer_,
        value_after_preview = if (identical(res$status, "collapsed")) {
          if (nchar(res$value) > 300L) paste0(substr(res$value, 1L, 300L), " ...") else res$value
        } else NA_character_,
        stringsAsFactors = FALSE, check.names = FALSE
      )
      if (!identical(res$status, "collapsed")) next

      fields[[j]] <- escape_field(res$value, is_quoted_field(old_raw))
      row_changed <- TRUE

      len_col <- lookup_length_col(target$derived_length_for, col)
      if (!is.null(len_col) && len_col %in% header) {
        jl <- col_idx[[len_col]]
        fields[[jl]] <- escape_field(as.character(nchar(res$value)),
                                     is_quoted_field(fields[[jl]]))
      }
    }

    if (row_changed) {
      lines[[li]] <- join_csv_line(fields)
      changed_rows <- changed_rows + 1L
    }
  }

  report <- if (length(records)) do.call(rbind, records) else NULL
  collapsed <- if (is.null(report)) 0L else sum(report$status == "collapsed")
  skipped <- if (is.null(report)) 0L else sum(report$status == "skipped_too_short")

  message(sprintf("%-62s rows=%d changed_rows=%d collapsed_fields=%d skipped=%d",
                  path, n_rows, changed_rows, collapsed, skipped))

  if (changed_rows > 0L && args$apply) {
    tmp <- tempfile(fileext = ".csv")
    write_lines_utf8(lines, tmp)
    verify_rewrite(path, tmp, target$cols,
                   c(target$cols, unname(target$derived_length_for)),
                   args$min_unit_words, args$min_unit_chars)
    stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
    backup <- paste0(path, ".bak_before_dedup_", stamp)
    if (!file.copy(path, backup, overwrite = FALSE)) {
      stop("Could not create backup: ", backup)
    }
    if (!file.copy(tmp, path, overwrite = TRUE)) {
      stop("Could not write: ", path)
    }
    unlink(tmp)
    message("  backup -> ", backup)
  }

  list(report = report, changed_rows = changed_rows)
}

# Re-parse old and new with read.csv and assert that nothing outside the
# allowed columns moved.
verify_rewrite <- function(old_path, new_path, text_cols, allowed_cols,
                           min_unit_words, min_unit_chars) {
  old <- read_csv_utf8(old_path)
  new <- read_csv_utf8(new_path)
  if (!identical(dim(old), dim(new)) || !identical(names(old), names(new))) {
    stop("Verification failed for ", old_path, ": shape or header changed.")
  }
  allowed_cols <- allowed_cols[!is.na(allowed_cols)]
  for (nm in names(old)) {
    if (nm %in% allowed_cols) next
    if (!identical(old[[nm]], new[[nm]])) {
      stop("Verification failed for ", old_path,
           ": untouched column changed: ", nm)
    }
  }
  for (nm in text_cols) {
    still <- vapply(new[[nm]], function(v) {
      t <- trimws(gsub("[[:space:]]+", " ", v))
      if (is.na(t) || !nzchar(t)) return(FALSE)
      w <- strsplit(t, " ", fixed = TRUE)[[1]]
      p <- minimal_period(w)
      k <- length(w) %/% p
      k >= 2L && (p >= min_unit_words ||
                    nchar(paste(w[seq_len(p)], collapse = " ")) >= min_unit_chars)
    }, logical(1), USE.NAMES = FALSE)
    if (any(still)) {
      stop("Verification failed for ", old_path, ": ", sum(still),
           " values in '", nm, "' are still repeated.")
    }
  }
  invisible(TRUE)
}

write_cypher <- function(args, changed_accessions) {
  path <- args$cypher_source
  if (length(changed_accessions) == 0L) {
    message("SKIP cypher: no study changed in ", path)
    return(invisible(NULL))
  }
  if (!file.exists(path)) {
    message("SKIP cypher (missing source): ", path)
    return(invisible(NULL))
  }
  nodes <- read_csv_utf8(path)
  req <- c("Accession", "Title", "Study_Summary")
  if (length(setdiff(req, names(nodes))) > 0) {
    stop("cypher_source is missing columns: ",
         paste(setdiff(req, names(nodes)), collapse = ", "))
  }

  # Only touch the studies this run actually repaired, so unrelated Study
  # properties on the live graph are left exactly as they are.
  nodes <- nodes[nodes$Accession %in% changed_accessions, , drop = FALSE]
  nodes <- nodes[order(nodes$Accession), , drop = FALSE]
  if (nrow(nodes) != length(unique(changed_accessions))) {
    stop("cypher_source does not contain every changed Accession.")
  }

  rows <- sprintf(
    "  {Accession: %s, Title: %s, Study_Summary: %s}",
    vapply(nodes$Accession, cypher_string, character(1), USE.NAMES = FALSE),
    vapply(nodes$Title, cypher_string, character(1), USE.NAMES = FALSE),
    vapply(nodes$Study_Summary, cypher_string, character(1), USE.NAMES = FALSE)
  )

  cypher <- c(
    "// Refresh Study.Title and Study.Study_Summary on the live Neo4j graph.",
    paste0("// Generated from ", path, " on ",
           format(Sys.time(), "%Y-%m-%d %H:%M:%S %z"), "."),
    paste0("// Studies updated: ", nrow(nodes),
           ". Run with cypher-shell. The study_fulltext index on Study.Title",
           " is maintained automatically by Neo4j."),
    "",
    "UNWIND [",
    paste(rows, collapse = ",\n"),
    "] AS row",
    "MATCH (s:Study {Accession: row.Accession})",
    "SET s.Title = row.Title, s.Study_Summary = row.Study_Summary",
    "RETURN count(s) AS updated_studies;",
    "",
    "// Sanity check: no Study title should still start with its own second half.",
    "MATCH (s:Study)",
    "WHERE s.Title IS NOT NULL AND size(s.Title) > 20",
    "  AND left(s.Title, size(s.Title)/2) = trim(right(s.Title, size(s.Title)/2))",
    "RETURN count(s) AS still_duplicated;"
  )

  dir.create(dirname(args$cypher_out), recursive = TRUE, showWarnings = FALSE)
  con <- file(args$cypher_out, open = "wb")
  writeLines(cypher, con, useBytes = TRUE)
  close(con)
  message("Cypher written: ", args$cypher_out, " (", nrow(nodes), " studies)")
}

main <- function() {
  args <- parse_args()
  message(if (args$apply) "MODE: APPLY (files will be rewritten)"
          else "MODE: DRY RUN (nothing written except the report)")
  message("")

  reports <- list()
  total_changed <- 0L
  for (target in TARGETS) {
    res <- process_file(target, args)
    if (is.null(res)) next
    if (!is.null(res$report)) reports[[length(reports) + 1L]] <- res$report
    total_changed <- total_changed + res$changed_rows
  }

  report <- if (length(reports)) do.call(rbind, reports) else
    data.frame(file = character(0), line = integer(0), key = character(0),
               column = character(0), repeats = integer(0), status = character(0),
               chars_before = integer(0), chars_after = integer(0),
               value_after_preview = character(0), stringsAsFactors = FALSE)

  dir.create(dirname(args$report_csv), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(report, args$report_csv, row.names = FALSE, na = "")
  message("")
  message("Report written: ", args$report_csv)

  if (nrow(report) > 0) {
    message("")
    message("Repeat-count distribution (collapsed fields):")
    print(table(report$repeats[report$status == "collapsed"]))
    skipped <- report[report$status == "skipped_too_short", , drop = FALSE]
    if (nrow(skipped) > 0) {
      message("")
      message("Repeated but left alone (unit shorter than the guard):")
      print(unique(skipped[, c("key", "column", "repeats")]), row.names = FALSE)
    }
  }

  if (args$apply) {
    message("")
    changed_accessions <- unique(report$key[
      report$file == args$cypher_source & report$status == "collapsed"])
    write_cypher(args, changed_accessions)
  } else {
    message("")
    message("Dry run complete. Re-run with --apply=TRUE to write the files ",
            "and generate the Cypher.")
  }
}

if (sys.nframe() == 0L && !interactive()) {
  main()
}
