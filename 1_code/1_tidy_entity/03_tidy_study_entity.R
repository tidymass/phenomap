# Build the Study/Project table for PhenoMAP.
#
# Runs THIRD among the 1_tidy_entity scripts -- requires
# 01_tidy_phenotype_entity.R to have already produced nodes_phenotype.csv
# (used below to look up each study's Phenotype_ID). Order: 01_tidy_
# phenotype_entity.R -> 02_tidy_metabolite_entity.R -> 03 (this) ->
# 04_tidy_module_entity.R.
#
# PhenoMAP now integrates two source databases in one run: Metabolomics
# Workbench ("mw") and MetaboLights ("ml"). This script takes a separate
# case_root/phenotype_dir pair for each database (rather than a single
# case_root) and combines them into one nodes_study.csv -- study_id prefixes
# (ST... for mw, MTBLS... for ml) never collide between the two, so no
# extra namespacing is needed.
#
# Phenotype source (per database):
#   - manual review studies: <phenotype_dir>/phenotype_manual_short.xlsx
#   - all other studies: <phenotype_dir>/phenotype_final_selection.csv
# Studies with missing phenotype final label are excluded.
#
# Scope: case-control studies only (continuous-variable studies are out of
# scope for now and will be added in a later run). Non-case-control studies
# are excluded and written to excluded_non_case_control_<mw|ml>.csv under
# output_dir, not silently dropped.
#
# Output:
#   2_data/tidy_entity/nodes_study.csv

source(file.path("1_code", "00_phenomap_helpers.R"))

parse_args <- function() {
  args <- list(
    case_root_mw = "",
    case_root_ml = "",
    phenotype_dir_mw = "",
    phenotype_dir_ml = "",
    repository_mw = "Metabolomics Workbench",
    repository_ml = "MetaboLights",
    output_dir = file.path("2_data", "tidy_entity"),
    case_control_only = TRUE
  )
  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) == 2 && kv[[1]] %in% names(args)) args[[kv[[1]]]] <- kv[[2]]
  }
  args$case_control_only <- as.logical(args$case_control_only)
  if (is.na(args$case_control_only)) args$case_control_only <- TRUE
  args
}

# Reads one database's study folders into Study-node rows. `repository` is
# passed explicitly (not inferred from study_meta.json) because the ml side
# of the 2026-08-19 delivery has no "source" field at all -- which database a
# study came from is known simply by which case_root it was read from.
read_studies <- function(case_root, repository, output_dir, case_control_only = TRUE, db_label = "db") {
  case_dirs <- phenomap_case_dirs(
    case_root, require_meta = TRUE,
    case_control_only = case_control_only,
    exclude_report_path = file.path(output_dir, paste0("excluded_non_case_control_", db_label, ".csv"))
  )
  rows <- lapply(case_dirs, function(case_dir) {
    meta <- phenomap_read_json(file.path(case_dir, "study_meta.json"))
    study_id <- phenomap_clean_scalar(meta$study_id %||% basename(case_dir), basename(case_dir))
    fields <- phenomap_read_study_meta_row(meta, case_dir = case_dir)
    data.frame(
      Accession = study_id,
      Repository = repository,
      Title = fields$study_title,
      Study_Summary = fields$study_summary,
      Study_Design = fields$design_type,
      Sample_Size = fields$n_samples_analyzed,
      Biospecimen = fields$biospecimen,
      Chromatography = fields$chromatography_display,
      Mass_Spectrometry = fields$ms_instrument_display,
      Publication_DOI = fields$publication_doi,
      Link = phenomap_make_study_url(study_id, repository),
      MS2_Supported = fields$ms2_supported,
      MS2_Annotation_Count = fields$ms2_annotation_count,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

read_phenotypes <- function(phenotype_dir) {
  keep <- c("study_id", "final_label", "final_ontology_id")
  phenotypes <- phenomap_read_phenotype_overrides(phenotype_dir, keep)

  phenotypes$phenotype_final_label <- phenomap_clean_vec(phenotypes$final_label)
  phenotypes$OLS_ID <- phenomap_clean_vec(phenotypes$final_ontology_id)
  phenotypes <- phenotypes[!is.na(phenotypes$phenotype_final_label), ]
  phenotypes[, c("study_id", "phenotype_final_label", "OLS_ID"), drop = FALSE]
}

build_study_entity <- function(case_root_mw, case_root_ml,
                               phenotype_dir_mw, phenotype_dir_ml,
                               repository_mw = "Metabolomics Workbench",
                               repository_ml = "MetaboLights",
                               output_dir, case_control_only = TRUE) {
  if (!requireNamespace("readxl", quietly = TRUE)) stop("Package 'readxl' is required.")
  if (!nzchar(case_root_mw) || !nzchar(case_root_ml)) {
    stop("Both --case_root_mw and --case_root_ml must be provided.")
  }
  if (!nzchar(phenotype_dir_mw) || !nzchar(phenotype_dir_ml)) {
    stop("Both --phenotype_dir_mw and --phenotype_dir_ml must be provided.")
  }

  studies <- rbind(
    read_studies(case_root_mw, repository_mw, output_dir, case_control_only, db_label = "mw"),
    read_studies(case_root_ml, repository_ml, output_dir, case_control_only, db_label = "ml")
  )
  phenotypes <- rbind(
    read_phenotypes(phenotype_dir_mw),
    read_phenotypes(phenotype_dir_ml)
  )
  if (anyDuplicated(phenotypes$study_id)) {
    dup_ids <- unique(phenotypes$study_id[duplicated(phenotypes$study_id)])
    stop("Duplicate study_id across mw/ml phenotype tables (should never happen -- ",
         "mw uses ST... and ml uses MTBLS... prefixes): ", paste(dup_ids, collapse = ", "))
  }

  phenotype_nodes <- utils::read.csv(file.path(output_dir, "nodes_phenotype.csv"), stringsAsFactors = FALSE, check.names = FALSE)
  phenotype_nodes$key <- ifelse(is.na(phenotype_nodes$OLS_ID) | phenotype_nodes$OLS_ID == "",
                                paste0("name:", tolower(phenotype_nodes$Phenotype)),
                                paste0("id:", phenotype_nodes$OLS_ID))
  phenotypes$key <- ifelse(is.na(phenotypes$OLS_ID) | phenotypes$OLS_ID == "",
                           paste0("name:", tolower(phenotypes$phenotype_final_label)),
                           paste0("id:", phenotypes$OLS_ID))
  phenotypes$Phenotype_ID <- phenotype_nodes$Lab_ID[match(phenotypes$key, phenotype_nodes$key)]

  out <- merge(studies, phenotypes, by.x = "Accession", by.y = "study_id", all = FALSE, sort = FALSE)
  out <- out[order(out$Accession), ]
  # Accession (the raw ST.../MTBLS... study_id) is already a globally unique,
  # permanent natural key -- it never changes across reruns, so it doubles
  # directly as the stable-ID registry key.
  out$Lab_ID <- phenomap_assign_stable_ids(
    out$Accession, "PST", file.path(output_dir, "study_id_registry.csv")
  )
  names(out)[names(out) == "phenotype_final_label"] <- "Phenotype"
  out <- out[, c(
    "Lab_ID", "Accession", "Repository", "Title", "Study_Summary", "Study_Design",
    "Sample_Size", "Biospecimen", "Chromatography", "Mass_Spectrometry",
    "Publication_DOI", "Link", "Phenotype", "Phenotype_ID", "MS2_Supported",
    "MS2_Annotation_Count"
  )]

  phenomap_write_csv(out, file.path(output_dir, "nodes_study.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- parse_args()
  build_study_entity(
    case_root_mw = args$case_root_mw,
    case_root_ml = args$case_root_ml,
    phenotype_dir_mw = args$phenotype_dir_mw,
    phenotype_dir_ml = args$phenotype_dir_ml,
    repository_mw = args$repository_mw,
    repository_ml = args$repository_ml,
    output_dir = args$output_dir,
    case_control_only = args$case_control_only
  )
}
