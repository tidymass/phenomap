#!/usr/bin/env Rscript

# Generate a small Cypher script to update MS2_Supported on local Neo4j Study nodes.
#
# It does not connect to Neo4j and does not modify the database.
# Run the generated .cypher file with cypher-shell after the local import succeeds.

parse_args <- function() {
  args <- list(
    ms2_csv = "2_data/finalversion_0913/medium/study_ms2_supported_by_study.csv",
    output_cypher = "2_data/finalversion_0913/medium/update_local_neo4j_study_ms2.cypher",
    label = "Study",
    match_property = "Accession",
    update_property = "MS2_Supported"
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

as_bool <- function(x) {
  x <- trimws(as.character(x))
  out <- ifelse(toupper(x) %in% c("TRUE", "T", "1", "YES", "Y"), TRUE,
                ifelse(toupper(x) %in% c("FALSE", "F", "0", "NO", "N"), FALSE, NA))
  as.logical(out)
}

cypher_string <- function(x) {
  x <- as.character(x)
  x <- gsub("\\\\", "\\\\\\\\", x)
  x <- gsub("\"", "\\\\\"", x)
  paste0("\"", x, "\"")
}

validate_identifier <- function(x, label) {
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", x)) {
    stop(label, " is not a safe Cypher identifier: ", x)
  }
  x
}

main <- function() {
  args <- parse_args()
  label <- validate_identifier(args$label, "label")
  match_property <- validate_identifier(args$match_property, "match_property")
  update_property <- validate_identifier(args$update_property, "update_property")

  ms2 <- read_csv_required(args$ms2_csv)
  required_cols <- c("Accession", "MS2_Supported")
  missing_cols <- setdiff(required_cols, names(ms2))
  if (length(missing_cols) > 0) {
    stop("MS2 CSV is missing columns: ", paste(missing_cols, collapse = ", "))
  }

  ms2 <- ms2[!is.na(ms2$Accession) & nzchar(ms2$Accession), , drop = FALSE]
  duplicated_accessions <- unique(ms2$Accession[duplicated(ms2$Accession)])
  if (length(duplicated_accessions) > 0) {
    stop("Duplicated Accession values: ", paste(utils::head(duplicated_accessions, 20), collapse = ", "))
  }

  ms2_value <- as_bool(ms2$MS2_Supported)
  if (anyNA(ms2_value)) {
    bad <- ms2$Accession[is.na(ms2_value)]
    stop("Unparseable MS2_Supported values for: ", paste(utils::head(bad, 20), collapse = ", "))
  }

  ms2 <- ms2[order(tolower(ms2$Accession)), , drop = FALSE]
  ms2_value <- ms2_value[order(tolower(ms2$Accession))]

  row_lines <- sprintf(
    "  {%s: %s, %s: %s}",
    match_property,
    vapply(ms2$Accession, cypher_string, character(1)),
    update_property,
    ifelse(ms2_value, "true", "false")
  )

  cypher <- c(
    "// Update Study.MS2_Supported after local Neo4j import.",
    "// Generated from study_ms2_supported_by_study.csv.",
    "// Expected rows: 501. Expected final counts: false=296, true=205.",
    "",
    "UNWIND [",
    paste(row_lines, collapse = ",\n"),
    "] AS row",
    sprintf("MATCH (s:%s {%s: row.%s})", label, match_property, match_property),
    sprintf("SET s.%s = row.%s", update_property, update_property),
    "RETURN count(s) AS updated_studies;",
    "",
    sprintf("MATCH (s:%s)", label),
    sprintf("RETURN s.%s AS %s, count(*) AS n", update_property, update_property),
    sprintf("ORDER BY s.%s;", update_property),
    "",
    sprintf("MATCH (s:%s)", label),
    sprintf("WHERE s.%s IS NULL", update_property),
    "RETURN count(s) AS studies_without_ms2_supported;"
  )

  dir.create(dirname(args$output_cypher), recursive = TRUE, showWarnings = FALSE)
  writeLines(cypher, args$output_cypher, useBytes = TRUE)

  message("Done. Cypher file written to: ", normalizePath(args$output_cypher, winslash = "/", mustWork = FALSE))
  message("Rows: ", nrow(ms2))
  print(table(ms2_value, useNA = "ifany"))
}

if (sys.nframe() == 0L && !interactive()) {
  main()
}
