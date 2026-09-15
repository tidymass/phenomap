#!/usr/bin/env Rscript

# Extract one MS2 support judgment per final study.
#
# Output:
#   medium/study_ms2_supported_by_study.csv
#
# Logic matches the old PhenoMAP definition:
#   MS2 support is judged only from direct evidence in:
#     <study>/anno_result/annotated_table_ms2.rda
#   MS2_Supported = TRUE only when that RDA exists, can be read, and has >0 rows.
#   If it cannot be read, it is treated as unsupported. No study_meta.json fallback.
#
# This script only writes the small study-level MS2 table. It does not modify
# final nodes/edges.

parse_args <- function() {
  args <- list(
    base_dir = "/mnt/hdd1/home/yuting/module_lists_20260911",
    rawdata_dir = "",
    study_csv = "",
    output_csv = ""
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) == 2 && kv[[1]] %in% names(args)) args[[kv[[1]]]] <- kv[[2]]
  }

  if (!nzchar(args$rawdata_dir)) args$rawdata_dir <- file.path(args$base_dir, "rawdata")
  if (!nzchar(args$study_csv)) args$study_csv <- file.path(args$base_dir, "nodes", "nodes_study.csv")
  if (!nzchar(args$output_csv)) args$output_csv <- file.path(args$base_dir, "medium", "study_ms2_supported_by_study.csv")
  args
}

clean_scalar <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0) return(default)
  x <- as.character(x[[1]])
  if (is.na(x)) return(default)
  x <- gsub("[\r\n]+", " ", x)
  x <- gsub("[[:space:]]+", " ", trimws(x))
  if (!nzchar(x) || toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")) return(default)
  x
}

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(df, path, row.names = FALSE, na = "")
  invisible(path)
}

database_key_for_accession <- function(accession, repository = NA_character_) {
  repository <- clean_scalar(repository)
  if (!is.na(repository)) {
    if (identical(repository, "MetaboLights")) return("ml")
    if (identical(repository, "Metabolomics Workbench")) return("mw")
  }
  if (grepl("^MTBLS", accession)) return("ml")
  if (grepl("^ST", accession)) return("mw")
  NA_character_
}

database_label_for_key <- function(database_key) {
  if (identical(database_key, "ml")) return("MetaboLights")
  if (identical(database_key, "mw")) return("Metabolomics Workbench")
  NA_character_
}

zip_path_for_db <- function(db_key, rawdata_dir) {
  if (identical(db_key, "mw")) {
    return(file.path(rawdata_dir, "out_qwen_eval_mw_anno_20260911.zip"))
  }
  if (identical(db_key, "ml")) {
    return(file.path(rawdata_dir, "out_qwen_eval_ml_anno_20260911.zip"))
  }
  stop("Unknown database key: ", db_key)
}

ms2_annotation_count_from_zip <- function(zip_path, accession) {
  inner_path <- paste0(accession, "/anno_result/annotated_table_ms2.rda")
  con <- unz(zip_path, inner_path, open = "rb")
  on.exit(close(con), add = TRUE)

  tryCatch({
    env <- new.env(parent = emptyenv())
    object_names <- load(con, envir = env)
    row_counts <- vapply(object_names, function(nm) {
      n <- tryCatch(nrow(env[[nm]]), error = function(e) NULL)
      if (is.null(n) || length(n) == 0 || is.na(n)) 0L else as.integer(n)
    }, integer(1))
    if (length(row_counts) == 0) 0L else max(row_counts)
  }, error = function(e) NA_integer_)
}

ms2_row_for_study <- function(accession, repository, rawdata_dir) {
  db_key <- database_key_for_accession(accession, repository)
  zip_path <- zip_path_for_db(db_key, rawdata_dir)
  annotation_count <- ms2_annotation_count_from_zip(zip_path, accession)

  source <- "annotated_table_ms2.rda"
  supported <- !is.na(annotation_count) && annotation_count > 0L
  annotation_count_out <- if (is.na(annotation_count)) 0L else annotation_count

  data.frame(
    Accession = accession,
    Repository = clean_scalar(repository, database_label_for_key(db_key)),
    Database_Key = db_key,
    MS2_Annotation_Count = annotation_count_out,
    MS2_Supported = supported,
    MS2_Source = source,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

main <- function() {
  args <- parse_args()
  studies <- read_csv_required(args$study_csv)
  if (!"Accession" %in% names(studies)) stop("study_csv must contain Accession.")
  if (!"Repository" %in% names(studies)) studies$Repository <- NA_character_

  studies <- studies[!is.na(studies$Accession) & nzchar(studies$Accession), , drop = FALSE]
  studies <- studies[!duplicated(studies$Accession), , drop = FALSE]
  studies <- studies[order(tolower(studies$Accession)), , drop = FALSE]

  rows <- lapply(seq_len(nrow(studies)), function(i) {
    message("[", i, "/", nrow(studies), "] ", studies$Accession[[i]])
    ms2_row_for_study(studies$Accession[[i]], studies$Repository[[i]], args$rawdata_dir)
  })
  out <- do.call(rbind, rows)
  write_csv(out, args$output_csv)

  message("Done.")
  message("Output: ", args$output_csv)
  message("Studies: ", nrow(out))
  print(table(out$MS2_Supported, useNA = "ifany"))
  print(table(out$MS2_Source, useNA = "ifany"))
}

if (sys.nframe() == 0L && !interactive()) {
  main()
}
