# Validate a staged PhenoMAP KG build before it can be published/imported.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L || !dir.exists(args[[1]])) {
  stop("Usage: Rscript 1_code/6_server_kg/03_validate_kg.R /absolute/build/root")
}

build_root <- normalizePath(args[[1]], mustWork = TRUE)
entity_dir <- file.path(build_root, "tidy_entity")
relationship_dir <- file.path(build_root, "tidy_relationship")
import_dir <- file.path(build_root, "neo4j", "import")

read_required <- function(path) {
  if (!file.exists(path)) stop("Missing required file: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

nodes <- list(
  Study = read_required(file.path(entity_dir, "nodes_study.csv")),
  Phenotype = read_required(file.path(entity_dir, "nodes_phenotype.csv")),
  Module = read_required(file.path(entity_dir, "nodes_module.csv")),
  Metabolite = read_required(file.path(entity_dir, "nodes_metabolite.csv"))
)
edges <- list(
  Study_Phenotype = read_required(file.path(relationship_dir, "edges_study_phenotype.csv")),
  Module_Study = read_required(file.path(relationship_dir, "edges_module_study.csv")),
  Metabolite_Module = read_required(file.path(relationship_dir, "edges_metabolite_module.csv")),
  Module_Module = read_required(file.path(relationship_dir, "edges_module_module.csv")),
  Metabolite_Metabolite = read_required(file.path(relationship_dir, "edges_metabolite_metabolite.csv"))
)

rows <- list()
add_result <- function(metric, value, status = "OK") {
  rows[[length(rows) + 1L]] <<- data.frame(
    Metric = metric,
    Value = as.character(value),
    Status = status,
    stringsAsFactors = FALSE
  )
}

fatal <- character(0)
fail <- function(message) {
  fatal <<- c(fatal, message)
  add_result(message, 1L, "FAIL")
}

for (label in names(nodes)) {
  x <- nodes[[label]]
  if (!"Lab_ID" %in% names(x)) {
    fail(paste(label, "node table missing Lab_ID"))
    next
  }
  add_result(paste0("nodes_", tolower(label)), nrow(x), if (nrow(x) > 0) "OK" else "FAIL")
  if (nrow(x) == 0) fatal <- c(fatal, paste(label, "node table is empty"))
  bad <- sum(is.na(x$Lab_ID) | !nzchar(x$Lab_ID))
  dup <- sum(duplicated(x$Lab_ID[!is.na(x$Lab_ID) & nzchar(x$Lab_ID)]))
  add_result(paste0("blank_node_ids_", tolower(label)), bad, if (bad == 0) "OK" else "FAIL")
  add_result(paste0("duplicate_node_ids_", tolower(label)), dup, if (dup == 0) "OK" else "FAIL")
  if (bad > 0 || dup > 0) fatal <- c(fatal, paste(label, "has blank or duplicate Lab_ID values"))
}

for (label in names(edges)) {
  x <- edges[[label]]
  add_result(paste0("edges_", tolower(label)), nrow(x), "OK")
  if (!"Lab_ID" %in% names(x)) {
    fail(paste(label, "edge table missing Lab_ID"))
    next
  }
  bad <- sum(is.na(x$Lab_ID) | !nzchar(x$Lab_ID))
  dup <- sum(duplicated(x$Lab_ID[!is.na(x$Lab_ID) & nzchar(x$Lab_ID)]))
  add_result(paste0("blank_edge_ids_", tolower(label)), bad, if (bad == 0) "OK" else "FAIL")
  add_result(paste0("duplicate_edge_ids_", tolower(label)), dup, if (dup == 0) "OK" else "FAIL")
  if (bad > 0 || dup > 0) fatal <- c(fatal, paste(label, "has blank or duplicate Lab_ID values"))
}

check_fk <- function(edge_name, column, node_name) {
  x <- edges[[edge_name]]
  if (!column %in% names(x)) {
    fail(paste(edge_name, "missing column", column))
    return(invisible(NULL))
  }
  missing <- sum(!is.na(x[[column]]) & nzchar(x[[column]]) & !x[[column]] %in% nodes[[node_name]]$Lab_ID)
  metric <- paste0("orphan_", tolower(edge_name), "_", tolower(column))
  add_result(metric, missing, if (missing == 0) "OK" else "FAIL")
  if (missing > 0) fatal <<- c(fatal, paste(edge_name, column, "has", missing, "orphan references"))
}

check_fk("Study_Phenotype", "Study_ID", "Study")
check_fk("Study_Phenotype", "Phenotype_ID", "Phenotype")
check_fk("Module_Study", "Module_ID", "Module")
check_fk("Module_Study", "Study_ID", "Study")
check_fk("Metabolite_Module", "Metabolite_ID", "Metabolite")
check_fk("Metabolite_Module", "Module_ID", "Module")
check_fk("Module_Module", "Module_ID_1", "Module")
check_fk("Module_Module", "Module_ID_2", "Module")
check_fk("Metabolite_Metabolite", "Metabolite_ID_1", "Metabolite")
check_fk("Metabolite_Metabolite", "Metabolite_ID_2", "Metabolite")

studies <- nodes$Study
if ("MS2_Supported" %in% names(studies)) {
  ms2_true <- tolower(as.character(studies$MS2_Supported)) %in% c("true", "t", "1", "yes")
  add_result("studies_ms2_supported", sum(ms2_true, na.rm = TRUE), "INFO")
}
if ("MS2_Annotation_Count" %in% names(studies)) {
  counts <- suppressWarnings(as.integer(studies$MS2_Annotation_Count))
  add_result("total_ms2_annotation_rows", sum(counts, na.rm = TRUE), "INFO")
  add_result("studies_missing_ms2_assessment", sum(is.na(counts)), "INFO")
}

required_import <- c(
  "nodes_study.csv", "nodes_phenotype.csv", "nodes_module.csv", "nodes_metabolite.csv",
  "edges_study_phenotype.csv", "edges_module_study.csv", "edges_metabolite_module.csv",
  "edges_module_module.csv", "edges_metabolite_metabolite.csv"
)
missing_import <- required_import[!file.exists(file.path(import_dir, required_import))]
add_result("missing_neo4j_import_files", length(missing_import), if (length(missing_import) == 0) "OK" else "FAIL")
if (length(missing_import) > 0) fatal <- c(fatal, paste("Missing Neo4j import files:", paste(missing_import, collapse = ", ")))

summary <- do.call(rbind, rows)
summary_path <- file.path(build_root, "validation_summary.csv")
write_summary <- !tolower(Sys.getenv("PHENOMAP_VALIDATE_NO_WRITE", "no")) %in% c("yes", "true", "1")
if (write_summary) utils::write.csv(summary, summary_path, row.names = FALSE, na = "")
print(summary, row.names = FALSE)
if (write_summary) cat("\nWrote ", summary_path, "\n", sep = "")

if (length(fatal) > 0) {
  stop("KG validation failed:\n- ", paste(unique(fatal), collapse = "\n- "))
}
cat("KG validation passed.\n")
