# Format tidy PhenoMAP entity and relationship tables for Neo4j import.
#
# Output:
#   2_data/neo4j/import/*.csv

read_csv <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  clean_multiline_fields(utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE))
}

clean_multiline_fields <- function(df) {
  text_cols <- vapply(df, is.character, logical(1))
  df[text_cols] <- lapply(df[text_cols], function(x) {
    x <- gsub("[\r\n]+", " ", x)
    gsub("[[:space:]]+", " ", trimws(x))
  })
  df
}

write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(df, path, row.names = FALSE, na = "")
  invisible(path)
}

neo4j_type <- function(x) {
  x <- toupper(trimws(as.character(x)))
  x <- gsub("[^A-Z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  x
}

format_node <- function(path, label, output_path) {
  df <- read_csv(path)
  if (!"Lab_ID" %in% colnames(df)) stop(path, " must contain Lab_ID.")
  # neo4j-admin import treats ":ID" as a structural column only -- its values
  # are used to wire up relationships but are NOT kept as a queryable node
  # property after import. Keep Lab_ID as a normal property AND add a
  # duplicate ":ID" column so the app can still look nodes up by Lab_ID.
  df[":ID"] <- df$Lab_ID
  df[":LABEL"] <- label
  write_csv(df, output_path)
}

format_edge <- function(path, start_col, end_col, output_path) {
  df <- read_csv(path)
  needed <- c("Lab_ID", start_col, "Relationship", end_col)
  missing <- setdiff(needed, colnames(df))
  if (length(missing) > 0) stop(path, " missing columns: ", paste(missing, collapse = ", "))

  out <- data.frame(
    edge_id = df$Lab_ID,
    `:START_ID` = df[[start_col]],
    `:END_ID` = df[[end_col]],
    `:TYPE` = neo4j_type(df$Relationship),
    Relationship = df$Relationship,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )

  extra_cols <- setdiff(colnames(df), c("Lab_ID", start_col, "Relationship", end_col))
  out <- cbind(out, df[, extra_cols, drop = FALSE])
  write_csv(out, output_path)
}

format_neo4j_import <- function(
  entity_dir = file.path("2_data", "tidy_entity"),
  relationship_dir = file.path("2_data", "tidy_relationship"),
  output_dir = file.path("2_data", "neo4j", "import")
) {
  format_node(
    file.path(entity_dir, "nodes_study.csv"),
    "Study",
    file.path(output_dir, "nodes_study.csv")
  )
  format_node(
    file.path(entity_dir, "nodes_phenotype.csv"),
    "Phenotype",
    file.path(output_dir, "nodes_phenotype.csv")
  )
  format_node(
    file.path(entity_dir, "nodes_metabolite.csv"),
    "Metabolite",
    file.path(output_dir, "nodes_metabolite.csv")
  )
  format_node(
    file.path(entity_dir, "nodes_module.csv"),
    "Module",
    file.path(output_dir, "nodes_module.csv")
  )

  format_edge(
    file.path(relationship_dir, "edges_study_phenotype.csv"),
    "Study_ID",
    "Phenotype_ID",
    file.path(output_dir, "edges_study_phenotype.csv")
  )
  format_edge(
    file.path(relationship_dir, "edges_module_study.csv"),
    "Module_ID",
    "Study_ID",
    file.path(output_dir, "edges_module_study.csv")
  )
  format_edge(
    file.path(relationship_dir, "edges_metabolite_module.csv"),
    "Metabolite_ID",
    "Module_ID",
    file.path(output_dir, "edges_metabolite_module.csv")
  )
  format_edge(
    file.path(relationship_dir, "edges_metabolite_metabolite.csv"),
    "Metabolite_ID_1",
    "Metabolite_ID_2",
    file.path(output_dir, "edges_metabolite_metabolite.csv")
  )
  format_edge(
    file.path(relationship_dir, "edges_module_module.csv"),
    "Module_ID_1",
    "Module_ID_2",
    file.path(output_dir, "edges_module_module.csv")
  )

  invisible(output_dir)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- list(
    entity_dir = file.path("2_data", "tidy_entity"),
    relationship_dir = file.path("2_data", "tidy_relationship"),
    output_dir = file.path("2_data", "neo4j", "import")
  )
  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) == 2 && kv[[1]] %in% names(args)) args[[kv[[1]]]] <- kv[[2]]
  }
  format_neo4j_import(args$entity_dir, args$relationship_dir, args$output_dir)
}
