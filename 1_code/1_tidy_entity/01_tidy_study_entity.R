# Build the Study/Project table for PhenoMAP.
#
# Phenotype source:
#   - manual review studies: phenotype_manual_short.xlsx
#   - all other studies: phenotype_final_selection.csv
# Studies with missing phenotype final label are excluded.
#
# Output:
#   2_data/tidy_entity/nodes_study.csv

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

parse_args <- function() {
  args <- list(
    case_root = file.path("2_data", "raw", "workbench_20260629", "out_qwen_eval_mw_anno"),
    phenotype_dir = file.path("2_data", "raw", "workbench_20260629", "phenotype_normalization"),
    output_dir = file.path("2_data", "tidy_entity")
  )
  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) == 2 && kv[[1]] %in% names(args)) args[[kv[[1]]]] <- kv[[2]]
  }
  args
}

clean <- function(x) {
  x <- as.character(x)
  x <- trimws(x)
  x[!nzchar(x) | toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")] <- NA_character_
  x
}

study_link <- function(study_id) {
  paste0("https://www.metabolomicsworkbench.org/data/DRCCMetadata.php?Mode=Study&StudyID=", study_id)
}

read_studies <- function(case_root) {
  case_dirs <- phenomap_case_dirs(case_root, require_meta = TRUE)
  rows <- lapply(case_dirs, function(case_dir) {
    meta <- phenomap_read_json(file.path(case_dir, "study_meta.json"))
    study_id <- phenomap_clean_scalar(meta$study_id %||% basename(case_dir), basename(case_dir))
    data.frame(
      Accession = study_id,
      Repository = "Metabolomics Workbench",
      Title = phenomap_clean_scalar(meta$study_title),
      Study_Summary = phenomap_clean_scalar(meta$study_summary),
      Study_Design = phenomap_clean_scalar(meta$study_design$design_type),
      Sample_Size = suppressWarnings(as.integer(meta$study_design$n_samples_analyzed)),
      Biospecimen = phenomap_clean_scalar(meta$study_design$biospecimen),
      Chromatography = phenomap_clean_scalar(meta$instrument$chromatography_instrument),
      Mass_Spectrometry = phenomap_clean_scalar(meta$instrument$ms_instrument_name),
      Publication_DOI = phenomap_clean_scalar(meta$publication_doi),
      Link = study_link(study_id),
      MS2_Supported = isTRUE(meta$ms2_supported),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

read_phenotypes <- function(phenotype_dir) {
  final <- utils::read.csv(
    file.path(phenotype_dir, "phenotype_final_selection.csv"),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  manual <- as.data.frame(readxl::read_excel(file.path(phenotype_dir, "phenotype_manual_short.xlsx")))

  final <- final[, c("study_id", "final_label", "final_ontology_id"), drop = FALSE]
  manual <- manual[, c("study_id", "final_label", "final_ontology_id"), drop = FALSE]

  final$source <- "phenotype_final_selection.csv"
  manual$source <- "phenotype_manual_short.xlsx"
  phenotypes <- rbind(final[!final$study_id %in% manual$study_id, ], manual)

  phenotypes$phenotype_final_label <- clean(phenotypes$final_label)
  phenotypes$OLS_ID <- clean(phenotypes$final_ontology_id)
  phenotypes <- phenotypes[!is.na(phenotypes$phenotype_final_label), ]
  phenotypes[, c("study_id", "phenotype_final_label", "OLS_ID"), drop = FALSE]
}

build_study_entity <- function(case_root, phenotype_dir, output_dir) {
  if (!requireNamespace("readxl", quietly = TRUE)) stop("Package 'readxl' is required.")

  studies <- read_studies(case_root)
  phenotypes <- read_phenotypes(phenotype_dir)
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
  out$Lab_ID <- sprintf("PMAP_STUDY_%06d", seq_len(nrow(out)))
  names(out)[names(out) == "phenotype_final_label"] <- "Phenotype"
  out <- out[, c(
    "Lab_ID", "Accession", "Repository", "Title", "Study_Summary", "Study_Design",
    "Sample_Size", "Biospecimen", "Chromatography", "Mass_Spectrometry",
    "Publication_DOI", "Link", "Phenotype", "Phenotype_ID", "MS2_Supported"
  )]

  phenomap_write_csv(out, file.path(output_dir, "nodes_study.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- parse_args()
  build_study_entity(args$case_root, args$phenotype_dir, args$output_dir)
}
