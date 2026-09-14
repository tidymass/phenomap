#!/usr/bin/env Rscript

# Merge corrected per-study MS2 support calls into final local nodes_study.csv.
#
# This is intentionally narrow:
#   - match by Accession
#   - replace only nodes_study$MS2_Supported
#   - preserve all other columns and row order
#   - create a timestamped backup before writing

parse_args <- function() {
  args <- list(
    nodes_study = "2_data/finalversion_0913/nodes/nodes_study.csv",
    ms2_csv = "2_data/finalversion_0913/medium/study_ms2_supported_by_study.csv",
    report_csv = "2_data/finalversion_0913/medium/update_nodes_study_ms2_report.csv"
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) == 2 && kv[[1]] %in% names(args)) args[[kv[[1]]]] <- kv[[2]]
  }
  args
}

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

as_bool_text <- function(x) {
  x <- trimws(as.character(x))
  ifelse(toupper(x) %in% c("TRUE", "T", "1", "YES", "Y"), "TRUE",
         ifelse(toupper(x) %in% c("FALSE", "F", "0", "NO", "N"), "FALSE", NA_character_))
}

stop_if_duplicates <- function(x, label) {
  duplicated_values <- unique(x[duplicated(x) & !is.na(x) & nzchar(x)])
  if (length(duplicated_values) > 0) {
    stop(label, " has duplicated keys: ", paste(utils::head(duplicated_values, 20), collapse = ", "))
  }
}

main <- function() {
  args <- parse_args()

  nodes <- read_csv_required(args$nodes_study)
  ms2 <- read_csv_required(args$ms2_csv)

  required_nodes_cols <- c("Accession", "MS2_Supported")
  missing_nodes_cols <- setdiff(required_nodes_cols, names(nodes))
  if (length(missing_nodes_cols) > 0) {
    stop("nodes_study is missing columns: ", paste(missing_nodes_cols, collapse = ", "))
  }

  required_ms2_cols <- c("Accession", "MS2_Supported")
  missing_ms2_cols <- setdiff(required_ms2_cols, names(ms2))
  if (length(missing_ms2_cols) > 0) {
    stop("ms2_csv is missing columns: ", paste(missing_ms2_cols, collapse = ", "))
  }

  stop_if_duplicates(nodes$Accession, "nodes_study$Accession")
  stop_if_duplicates(ms2$Accession, "ms2_csv$Accession")

  missing_in_ms2 <- setdiff(nodes$Accession, ms2$Accession)
  extra_in_ms2 <- setdiff(ms2$Accession, nodes$Accession)
  if (length(missing_in_ms2) > 0 || length(extra_in_ms2) > 0) {
    if (length(missing_in_ms2) > 0) {
      message("Missing in MS2 table: ", paste(utils::head(missing_in_ms2, 20), collapse = ", "))
    }
    if (length(extra_in_ms2) > 0) {
      message("Extra in MS2 table: ", paste(utils::head(extra_in_ms2, 20), collapse = ", "))
    }
    stop("Accession mismatch between nodes_study and MS2 table; not writing output.")
  }

  old_ms2 <- as_bool_text(nodes$MS2_Supported)
  new_ms2 <- as_bool_text(ms2$MS2_Supported[match(nodes$Accession, ms2$Accession)])

  if (anyNA(new_ms2)) {
    bad <- nodes$Accession[is.na(new_ms2)]
    stop("MS2 table has unparseable MS2_Supported values for: ", paste(utils::head(bad, 20), collapse = ", "))
  }

  changed <- is.na(old_ms2) | old_ms2 != new_ms2
  nodes$MS2_Supported <- new_ms2

  timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  backup_path <- paste0(args$nodes_study, ".bak_before_ms2_", timestamp)
  ok_backup <- file.copy(args$nodes_study, backup_path, overwrite = FALSE)
  if (!ok_backup) stop("Could not create backup: ", backup_path)

  utils::write.csv(nodes, args$nodes_study, row.names = FALSE, na = "")

  report <- data.frame(
    metric = c(
      "nodes_rows",
      "ms2_rows",
      "updated_column",
      "changed_rows",
      "new_FALSE",
      "new_TRUE",
      "backup_path",
      "updated_nodes_study"
    ),
    value = c(
      nrow(nodes),
      nrow(ms2),
      "MS2_Supported",
      sum(changed),
      sum(nodes$MS2_Supported == "FALSE"),
      sum(nodes$MS2_Supported == "TRUE"),
      normalizePath(backup_path, winslash = "/", mustWork = FALSE),
      normalizePath(args$nodes_study, winslash = "/", mustWork = FALSE)
    ),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  dir.create(dirname(args$report_csv), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(report, args$report_csv, row.names = FALSE, na = "")

  message("Done. Updated nodes_study in place.")
  print(report, row.names = FALSE)
}

if (sys.nframe() == 0L && !interactive()) {
  main()
}
