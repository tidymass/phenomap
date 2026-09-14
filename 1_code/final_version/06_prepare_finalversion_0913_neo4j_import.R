#!/usr/bin/env Rscript

# Prepare the 2026-09-13 final PhenoMAP KG tables for Neo4j import.
#
# Input:
#   2_data/finalversion_0913/nodes/*.csv
#   2_data/finalversion_0913/edges/*.csv
#
# Output, by default:
#   2_data/finalversion_0913_kg/tidy_entity/*.csv
#   2_data/finalversion_0913_kg/tidy_relationship/*.csv
#   2_data/finalversion_0913_kg/neo4j/import/*.csv
#   2_data/finalversion_0913_kg/validation/*.csv
#
# The generated tidy schemas intentionally match the old PhenoMAP KG tables.
# The only module-node extension carried into Neo4j is the multi-group
# comparison metadata already present in the new nodes_module.csv, especially
# Comparison_Label. One study can therefore keep all modules from all
# comparisons, while the frontend can group module rows by Comparison_Label.

parse_bool <- function(x) {
  x <- tolower(trimws(as.character(x[[1]])))
  x %in% c("1", "true", "t", "yes", "y")
}

parse_args <- function() {
  args <- list(
    source_dir = file.path("2_data", "finalversion_0913"),
    build_root = file.path("2_data", "finalversion_0913_kg"),
    formatter = file.path("1_code", "3_neo4j_import", "01_format_neo4j_import.R"),
    overwrite = "FALSE",
    also_update_project_data = "FALSE",
    project_entity_dir = file.path("2_data", "tidy_entity"),
    project_relationship_dir = file.path("2_data", "tidy_relationship"),
    project_import_dir = file.path("2_data", "neo4j", "import")
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) == 2 && kv[[1]] %in% names(args)) args[[kv[[1]]]] <- kv[[2]]
  }

  args$overwrite <- parse_bool(args$overwrite)
  args$also_update_project_data <- parse_bool(args$also_update_project_data)
  args
}

clean_text_columns <- function(df) {
  text_cols <- vapply(df, is.character, logical(1))
  df[text_cols] <- lapply(df[text_cols], function(x) {
    x <- gsub("[\r\n]+", " ", x)
    x <- gsub("[[:space:]]+", " ", trimws(x))
    x[!nzchar(x) | toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")] <- NA_character_
    x
  })
  df
}

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  clean_text_columns(utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE))
}

write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(df, path, row.names = FALSE, na = "")
  invisible(path)
}

copy_csv_table <- function(df, output_dir, file_name) {
  write_csv(df, file.path(output_dir, file_name))
}

require_columns <- function(df, cols, table_name) {
  missing <- setdiff(cols, names(df))
  if (length(missing) > 0) {
    stop(table_name, " missing required columns: ", paste(missing, collapse = ", "))
  }
}

normalize_blank <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x
}

nonblank <- function(x) {
  !is.na(x) & nzchar(as.character(x))
}

validate_ids <- function(df, id_col, table_name) {
  ids <- normalize_blank(df[[id_col]])
  data.frame(
    table = table_name,
    rows = nrow(df),
    blank_ids = sum(!nzchar(ids)),
    duplicate_ids = sum(duplicated(ids[nzchar(ids)])),
    stringsAsFactors = FALSE
  )
}

validate_fk <- function(edges, edge_col, nodes, node_col, check_name) {
  value <- edges[[edge_col]]
  keep <- nonblank(value)
  missing <- value[keep & !value %in% nodes[[node_col]]]
  data.frame(
    check = check_name,
    checked_values = sum(keep),
    missing_endpoint_count = length(missing),
    example_missing_endpoint = if (length(missing) == 0) NA_character_ else missing[[1]],
    stringsAsFactors = FALSE
  )
}

validate_required_files <- function(source_dir) {
  required <- c(
    file.path("nodes", "nodes_study.csv"),
    file.path("nodes", "nodes_phenotype.csv"),
    file.path("nodes", "nodes_module.csv"),
    file.path("nodes", "nodes_metabolite.csv"),
    file.path("edges", "edges_study_phenotype.csv"),
    file.path("edges", "edges_module_study.csv"),
    file.path("edges", "edges_metabolite_module.csv"),
    file.path("edges", "edges_metabolite_metabolite.csv"),
    file.path("edges", "edges_module_module.csv")
  )
  missing <- required[!file.exists(file.path(source_dir, required))]
  if (length(missing) > 0) {
    stop("Missing source CSV files under ", source_dir, ": ", paste(missing, collapse = ", "))
  }
}

read_final_tables <- function(source_dir) {
  validate_required_files(source_dir)
  list(
    nodes = list(
      study = read_csv_required(file.path(source_dir, "nodes", "nodes_study.csv")),
      phenotype = read_csv_required(file.path(source_dir, "nodes", "nodes_phenotype.csv")),
      module = read_csv_required(file.path(source_dir, "nodes", "nodes_module.csv")),
      metabolite = read_csv_required(file.path(source_dir, "nodes", "nodes_metabolite.csv"))
    ),
    edges = list(
      study_phenotype = read_csv_required(file.path(source_dir, "edges", "edges_study_phenotype.csv")),
      module_study = read_csv_required(file.path(source_dir, "edges", "edges_module_study.csv")),
      metabolite_module = read_csv_required(file.path(source_dir, "edges", "edges_metabolite_module.csv")),
      metabolite_metabolite = read_csv_required(file.path(source_dir, "edges", "edges_metabolite_metabolite.csv")),
      module_module = read_csv_required(file.path(source_dir, "edges", "edges_module_module.csv"))
    )
  )
}

check_schema <- function(tables) {
  require_columns(tables$nodes$study, c(
    "Lab_ID", "Accession", "Repository", "Title", "Study_Summary", "Study_Design",
    "Sample_Size", "Biospecimen", "Chromatography", "Mass_Spectrometry",
    "Publication_DOI", "Link", "Phenotype", "Phenotype_ID", "MS2_Supported"
  ), "nodes_study.csv")
  require_columns(tables$nodes$phenotype, c(
    "Lab_ID", "Phenotype", "Type", "OLS_ID", "OLS_Link", "OLS_Definition", "Study_ID"
  ), "nodes_phenotype.csv")
  require_columns(tables$nodes$metabolite, c(
    "Lab_ID", "Metabolite_Name", "INCHI_ID", "HMDB_ID", "KEGG_ID",
    "HMDB_Chemical_Class", "KEGG_Chemical_Class", "Origin", "HMDB_URL", "KEGG_URL"
  ), "nodes_metabolite.csv")
  require_columns(tables$nodes$module, c(
    "Lab_ID", "Study_ID", "module_id", "annotation_mode", "hypothesis_type",
    "title", "functional_summary", "anchor_metabolites", "anchor_metabolite_ids",
    "supporting_metabolites", "supporting_metabolite_ids",
    "contextual_metabolites", "contextual_metabolite_ids", "class_names",
    "phenotype_relationship", "confidence_label", "rationale", "global_direction",
    "origin_endogenous_frac", "origin_exogenous_frac", "top_kegg_pathways",
    "top_hmdb_pathways", "pubmed_pmids", "hmdb_pathway_ids", "kegg_pathway_ids",
    "Module_Key", "Study_Accession", "Result_Scope", "Comparison_ID",
    "Comparison_Kind", "Comparison_Design_Type", "Comparison_Label",
    "Case_Value", "Control_Value", "N_Case", "N_Control", "Phenotype_Term"
  ), "nodes_module.csv")

  require_columns(tables$edges$study_phenotype, c("Lab_ID", "Study_ID", "Relationship", "Phenotype_ID"), "edges_study_phenotype.csv")
  require_columns(tables$edges$module_study, c("Lab_ID", "Module_ID", "Relationship", "Study_ID"), "edges_module_study.csv")
  require_columns(tables$edges$metabolite_module, c("Lab_ID", "Metabolite_ID", "Relationship", "Module_ID", "Type"), "edges_metabolite_module.csv")
  require_columns(tables$edges$metabolite_metabolite, c("Lab_ID", "Metabolite_ID_1", "Relationship", "Metabolite_ID_2"), "edges_metabolite_metabolite.csv")
  require_columns(tables$edges$module_module, c(
    "Lab_ID", "Module_ID_1", "Relationship", "Module_ID_2", "Type",
    "Similarity_Score", "Similarity_Tier", "Biological_Score",
    "Compositional_Score", "Cross_Study"
  ), "edges_module_module.csv")
}

write_tidy_tables <- function(tables, entity_dir, relationship_dir) {
  copy_csv_table(tables$nodes$study, entity_dir, "nodes_study.csv")
  copy_csv_table(tables$nodes$phenotype, entity_dir, "nodes_phenotype.csv")
  copy_csv_table(tables$nodes$module, entity_dir, "nodes_module.csv")
  copy_csv_table(tables$nodes$metabolite, entity_dir, "nodes_metabolite.csv")

  copy_csv_table(tables$edges$study_phenotype, relationship_dir, "edges_study_phenotype.csv")
  copy_csv_table(tables$edges$module_study, relationship_dir, "edges_module_study.csv")
  copy_csv_table(tables$edges$metabolite_module, relationship_dir, "edges_metabolite_module.csv")
  copy_csv_table(tables$edges$metabolite_metabolite, relationship_dir, "edges_metabolite_metabolite.csv")
  copy_csv_table(tables$edges$module_module, relationship_dir, "edges_module_module.csv")
}

write_validation_reports <- function(tables, validation_dir) {
  nodes <- tables$nodes
  edges <- tables$edges

  counts <- data.frame(
    table = c(
      "nodes_study", "nodes_phenotype", "nodes_module", "nodes_metabolite",
      "edges_study_phenotype", "edges_module_study", "edges_metabolite_module",
      "edges_metabolite_metabolite", "edges_module_module"
    ),
    rows = c(
      nrow(nodes$study), nrow(nodes$phenotype), nrow(nodes$module), nrow(nodes$metabolite),
      nrow(edges$study_phenotype), nrow(edges$module_study), nrow(edges$metabolite_module),
      nrow(edges$metabolite_metabolite), nrow(edges$module_module)
    ),
    stringsAsFactors = FALSE
  )

  id_checks <- rbind(
    validate_ids(nodes$study, "Lab_ID", "nodes_study"),
    validate_ids(nodes$phenotype, "Lab_ID", "nodes_phenotype"),
    validate_ids(nodes$module, "Lab_ID", "nodes_module"),
    validate_ids(nodes$metabolite, "Lab_ID", "nodes_metabolite"),
    validate_ids(edges$study_phenotype, "Lab_ID", "edges_study_phenotype"),
    validate_ids(edges$module_study, "Lab_ID", "edges_module_study"),
    validate_ids(edges$metabolite_module, "Lab_ID", "edges_metabolite_module"),
    validate_ids(edges$metabolite_metabolite, "Lab_ID", "edges_metabolite_metabolite"),
    validate_ids(edges$module_module, "Lab_ID", "edges_module_module")
  )

  endpoint_checks <- rbind(
    validate_fk(edges$study_phenotype, "Study_ID", nodes$study, "Lab_ID", "edges_study_phenotype.Study_ID"),
    validate_fk(edges$study_phenotype, "Phenotype_ID", nodes$phenotype, "Lab_ID", "edges_study_phenotype.Phenotype_ID"),
    validate_fk(edges$module_study, "Module_ID", nodes$module, "Lab_ID", "edges_module_study.Module_ID"),
    validate_fk(edges$module_study, "Study_ID", nodes$study, "Lab_ID", "edges_module_study.Study_ID"),
    validate_fk(edges$metabolite_module, "Metabolite_ID", nodes$metabolite, "Lab_ID", "edges_metabolite_module.Metabolite_ID"),
    validate_fk(edges$metabolite_module, "Module_ID", nodes$module, "Lab_ID", "edges_metabolite_module.Module_ID"),
    validate_fk(edges$metabolite_metabolite, "Metabolite_ID_1", nodes$metabolite, "Lab_ID", "edges_metabolite_metabolite.Metabolite_ID_1"),
    validate_fk(edges$metabolite_metabolite, "Metabolite_ID_2", nodes$metabolite, "Lab_ID", "edges_metabolite_metabolite.Metabolite_ID_2"),
    validate_fk(edges$module_module, "Module_ID_1", nodes$module, "Lab_ID", "edges_module_module.Module_ID_1"),
    validate_fk(edges$module_module, "Module_ID_2", nodes$module, "Lab_ID", "edges_module_module.Module_ID_2")
  )

  modules <- nodes$module
  modules$Comparison_Label <- normalize_blank(modules$Comparison_Label)
  modules$Comparison_ID <- normalize_blank(modules$Comparison_ID)
  modules$Study_ID <- normalize_blank(modules$Study_ID)
  modules$Study_Accession <- normalize_blank(modules$Study_Accession)

  comparison_counts <- aggregate(
    Lab_ID ~ Study_ID + Study_Accession + Comparison_ID + Comparison_Label,
    modules,
    length
  )
  names(comparison_counts)[names(comparison_counts) == "Lab_ID"] <- "Module_Count"
  comparison_counts <- comparison_counts[order(
    comparison_counts$Study_ID,
    comparison_counts$Comparison_Label,
    comparison_counts$Comparison_ID
  ), , drop = FALSE]

  study_comparison_summary <- aggregate(
    Comparison_Label ~ Study_ID + Study_Accession,
    modules,
    function(x) length(unique(x[nzchar(x)]))
  )
  names(study_comparison_summary)[names(study_comparison_summary) == "Comparison_Label"] <- "Comparison_Label_Count"
  module_counts_by_study <- aggregate(Lab_ID ~ Study_ID + Study_Accession, modules, length)
  names(module_counts_by_study)[names(module_counts_by_study) == "Lab_ID"] <- "Module_Count"
  study_comparison_summary <- merge(
    study_comparison_summary,
    module_counts_by_study,
    by = c("Study_ID", "Study_Accession"),
    all.x = TRUE,
    sort = FALSE
  )
  study_comparison_summary <- study_comparison_summary[order(
    -study_comparison_summary$Comparison_Label_Count,
    study_comparison_summary$Study_ID
  ), , drop = FALSE]

  module_key_duplicates <- modules[duplicated(modules$Module_Key) | duplicated(modules$Module_Key, fromLast = TRUE), , drop = FALSE]
  module_key_duplicates <- module_key_duplicates[order(module_key_duplicates$Module_Key, module_key_duplicates$Lab_ID), , drop = FALSE]

  write_csv(counts, file.path(validation_dir, "table_counts.csv"))
  write_csv(id_checks, file.path(validation_dir, "id_checks.csv"))
  write_csv(endpoint_checks, file.path(validation_dir, "endpoint_checks.csv"))
  write_csv(comparison_counts, file.path(validation_dir, "module_comparison_counts.csv"))
  write_csv(study_comparison_summary, file.path(validation_dir, "study_comparison_summary.csv"))
  write_csv(module_key_duplicates, file.path(validation_dir, "duplicate_module_keys.csv"))

  fatal <- character(0)
  if (any(id_checks$blank_ids > 0 | id_checks$duplicate_ids > 0)) {
    fatal <- c(fatal, "blank or duplicate Lab_ID values")
  }
  if (any(endpoint_checks$missing_endpoint_count > 0)) {
    fatal <- c(fatal, "orphan edge endpoints")
  }
  if (nrow(module_key_duplicates) > 0) {
    fatal <- c(fatal, "duplicate Module_Key values")
  }
  if (!"Comparison_Label" %in% names(nodes$module) || any(!nonblank(nodes$module$Comparison_Label))) {
    fatal <- c(fatal, "blank Comparison_Label values in nodes_module.csv")
  }

  list(
    counts = counts,
    id_checks = id_checks,
    endpoint_checks = endpoint_checks,
    study_comparison_summary = study_comparison_summary,
    fatal = unique(fatal)
  )
}

write_import_command <- function(import_dir, path) {
  lines <- c(
    "neo4j-admin database import full neo4j \\",
    paste0("  --nodes=Study=\"", file.path(import_dir, "nodes_study.csv"), "\" \\"),
    paste0("  --nodes=Phenotype=\"", file.path(import_dir, "nodes_phenotype.csv"), "\" \\"),
    paste0("  --nodes=Module=\"", file.path(import_dir, "nodes_module.csv"), "\" \\"),
    paste0("  --nodes=Metabolite=\"", file.path(import_dir, "nodes_metabolite.csv"), "\" \\"),
    paste0("  --relationships=INVESTIGATED=\"", file.path(import_dir, "edges_study_phenotype.csv"), "\" \\"),
    paste0("  --relationships=REPORTED_IN=\"", file.path(import_dir, "edges_module_study.csv"), "\" \\"),
    paste0("  --relationships=MEMBER_OF=\"", file.path(import_dir, "edges_metabolite_module.csv"), "\" \\"),
    paste0("  --relationships=SIMILAR_TO=\"", file.path(import_dir, "edges_module_module.csv"), "\" \\"),
    paste0("  --relationships=CONNECTED_WITH=\"", file.path(import_dir, "edges_metabolite_metabolite.csv"), "\" \\"),
    "  --multiline-fields=true \\",
    "  --overwrite-destination=true"
  )
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(lines, path, useBytes = TRUE)
  invisible(path)
}

prepare_output_dirs <- function(args) {
  if (dir.exists(args$build_root)) {
    if (!isTRUE(args$overwrite)) {
      stop(
        "build_root already exists: ", args$build_root, "\n",
        "Choose a new --build_root or pass --overwrite=TRUE."
      )
    }
    unlink(args$build_root, recursive = TRUE, force = TRUE)
  }

  dirs <- list(
    entity = file.path(args$build_root, "tidy_entity"),
    relationship = file.path(args$build_root, "tidy_relationship"),
    import = file.path(args$build_root, "neo4j", "import"),
    validation = file.path(args$build_root, "validation")
  )
  for (d in dirs) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  dirs
}

run_neo4j_formatter <- function(formatter, entity_dir, relationship_dir, import_dir) {
  if (!file.exists(formatter)) stop("Neo4j formatter does not exist: ", formatter)
  env <- new.env(parent = globalenv())
  sys.source(formatter, envir = env)
  if (!exists("format_neo4j_import", envir = env, mode = "function")) {
    stop("Formatter did not define format_neo4j_import(): ", formatter)
  }
  env$format_neo4j_import(entity_dir, relationship_dir, import_dir)
}

maybe_update_project_data <- function(args, tables) {
  if (!isTRUE(args$also_update_project_data)) return(invisible(NULL))

  message("Updating project data directories because --also_update_project_data=TRUE")
  write_tidy_tables(tables, args$project_entity_dir, args$project_relationship_dir)
  run_neo4j_formatter(
    args$formatter,
    args$project_entity_dir,
    args$project_relationship_dir,
    args$project_import_dir
  )
}

main <- function() {
  args <- parse_args()
  dirs <- prepare_output_dirs(args)

  tables <- read_final_tables(args$source_dir)
  check_schema(tables)

  reports <- write_validation_reports(tables, dirs$validation)
  if (length(reports$fatal) > 0) {
    stop(
      "Final KG validation failed before Neo4j formatting:\n- ",
      paste(reports$fatal, collapse = "\n- "),
      "\nSee validation reports under: ", dirs$validation
    )
  }

  write_tidy_tables(tables, dirs$entity, dirs$relationship)
  run_neo4j_formatter(args$formatter, dirs$entity, dirs$relationship, dirs$import)
  write_import_command(dirs$import, file.path(args$build_root, "neo4j-admin-import-command.txt"))
  maybe_update_project_data(args, tables)

  multi_group_studies <- sum(reports$study_comparison_summary$Comparison_Label_Count > 1)

  message("Done. Staged final tidy tables: ", args$build_root)
  message("Neo4j import CSVs: ", dirs$import)
  message("Validation reports: ", dirs$validation)
  message("Studies with multiple Comparison_Label groups: ", multi_group_studies)
  print(reports$counts, row.names = FALSE)
}

if (sys.nframe() == 0L && !interactive()) {
  main()
}
