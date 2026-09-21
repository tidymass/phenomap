project_dir <- normalizePath(getwd())
if (!file.exists(file.path(project_dir, "analysis", "2_data", "disease_phenotype_module_count.csv"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", ".."))
}

# Prepare external disease-pathway annotations from the Comparative
# Toxicogenomics Database (CTD). This script maps our disease phenotypes to CTD
# MEDIC disease IDs, then attaches CTD disease-pathway associations.
#
# Review CTD_Disease_ID_Final and Use_For_CTD_Validation in the output CSV
# before running disease_similarity_ctd_pathway_validation.R.

data_dir <- file.path(project_dir, "analysis", "2_data")
result_dir <- file.path(project_dir, "analysis", "3_result")
dir.create(data_dir, showWarnings = FALSE, recursive = TRUE)

disease_count_file <- file.path(data_dir, "disease_phenotype_module_count.csv")
disease_similarity_matrix_file <- file.path(result_dir, "disease_phenotype_similarity_matrix.csv")

ctd_disease_file <- file.path(data_dir, "CTD_diseases.tsv.gz")
ctd_disease_pathway_file <- file.path(data_dir, "CTD_diseases_pathways.tsv.gz")
ctd_review_file <- file.path(data_dir, "disease_ctd_pathway_review.csv")
ctd_manual_alias_file <- file.path(data_dir, "disease_ctd_mapping_aliases.csv")
ctd_disease_pathway_filtered_file <- file.path(data_dir, "ctd_disease_pathway_associations_mapped.tsv")

download_ctd_if_missing <- TRUE
ctd_disease_url <- "http://ctdbase.org/reports/CTD_diseases.tsv.gz"
ctd_disease_pathway_url <- "http://ctdbase.org/reports/CTD_diseases_pathways.tsv.gz"

normalize_name <- function(x) {
  x <- tolower(trimws(x))
  x <- gsub("&", " and ", x, fixed = TRUE)
  x <- gsub("[[:punct:]]+", " ", x)
  x <- gsub("\\s+", " ", x)
  trimws(x)
}

normalize_id <- function(x) {
  x <- trimws(x)
  x[x == ""] <- NA_character_
  x <- gsub("^MESH:", "MESH:", x)
  x <- gsub("^MeSH:", "MESH:", x)
  x <- gsub("^OMIM:", "OMIM:", x)
  x
}

split_pipe <- function(x) {
  if (is.na(x) || trimws(x) == "") return(character())
  parts <- unlist(strsplit(x, "|", fixed = TRUE), use.names = FALSE)
  unique(trimws(parts[parts != ""]))
}

collapse_unique <- function(x) {
  x <- unique(trimws(x[!is.na(x) & trimws(x) != ""]))
  paste(sort(x), collapse = ";")
}

download_if_missing <- function(url, destfile) {
  if (file.exists(destfile) && file.info(destfile)$size > 0) return(invisible(FALSE))
  if (!download_ctd_if_missing) {
    stop("Missing CTD file: ", destfile, ". Set download_ctd_if_missing <- TRUE or download manually.")
  }
  message("Downloading CTD file: ", url)
  download.file(url, destfile, mode = "wb", quiet = FALSE)
  invisible(TRUE)
}

read_ctd_table <- function(path) {
  header_lines <- readLines(gzfile(path), n = 200, warn = FALSE)
  header_candidates <- header_lines[grepl("^#", header_lines) & grepl("\t", header_lines, fixed = TRUE)]
  if (length(header_candidates) == 0) stop("Could not find CTD header in ", path)
  header <- strsplit(sub("^#\\s*", "", tail(header_candidates, 1)), "\t", fixed = TRUE)[[1]]
  header <- header[header != ""]

  x <- read.delim(
    gzfile(path),
    header = FALSE,
    comment.char = "#",
    sep = "\t",
    quote = "",
    stringsAsFactors = FALSE,
    check.names = FALSE
  )

  if (ncol(x) < length(header)) {
    stop("CTD file has fewer columns than expected header: ", path)
  }

  colnames(x)[seq_along(header)] <- header
  x
}

make_disease_name_index <- function(ctd_diseases) {
  rows <- data.frame(
    CTD_Disease_ID = character(),
    CTD_Disease_Name = character(),
    CTD_Disease_Name_Normalized = character(),
    Match_Source = character(),
    stringsAsFactors = FALSE
  )

  for (i in seq_len(nrow(ctd_diseases))) {
    disease_id <- ctd_diseases$DiseaseID[i]
    primary_name <- ctd_diseases$DiseaseName[i]
    synonyms <- if ("Synonyms" %in% colnames(ctd_diseases)) split_pipe(ctd_diseases$Synonyms[i]) else character()
    all_names <- unique(c(primary_name, synonyms))
    all_names <- all_names[!is.na(all_names) & trimws(all_names) != ""]

    if (length(all_names) == 0) next
    rows <- rbind(
      rows,
      data.frame(
        CTD_Disease_ID = disease_id,
        CTD_Disease_Name = all_names,
        CTD_Disease_Name_Normalized = normalize_name(all_names),
        Match_Source = c("ctd_primary_name", rep("ctd_synonym", length(all_names) - 1)),
        stringsAsFactors = FALSE
      )
    )
  }

  unique(rows)
}

make_candidate_string <- function(query_name, ctd_name_index, n = 8) {
  query_norm <- normalize_name(query_name)
  d <- adist(query_norm, ctd_name_index$CTD_Disease_Name_Normalized)
  d <- as.numeric(d)
  denom <- pmax(nchar(query_norm), nchar(ctd_name_index$CTD_Disease_Name_Normalized), 1)
  score <- d / denom
  idx <- order(score)[seq_len(min(n, length(score)))]
  paste(
    paste0(
      ctd_name_index$CTD_Disease_ID[idx],
      ": ",
      ctd_name_index$CTD_Disease_Name[idx],
      " [",
      ctd_name_index$Match_Source[idx],
      ", distance=",
      signif(score[idx], 3),
      "]"
    ),
    collapse = " | "
  )
}

manual_aliases <- data.frame(
  Phenotype = c(
    "Crohn's disease",
    "Lung adenocarcinoma",
    "Non-small cell lung carcinoma",
    "Liver cancer",
    "Kidney cancer",
    "Urinary bladder cancer",
    "Bladder carcinoma",
    "Hepatitis B virus infection",
    "Plasmodium falciparum malaria",
    "X-linked adrenoleukodystrophy",
    "Community-Acquired Pneumonia",
    "Chronic obstructive pulmonary disease",
    "Acute graft versus host disease",
    "Metabolic dysfunction-associated steatotic liver disease",
    "Metabolic dysfunction-associated steatohepatitis",
    "Proliferative diabetic retinopathy",
    "Hypertension, Pregnancy-Induced",
    "Myalgic encephalomeyelitis/chronic fatigue syndrome",
    "Nontuberculous mycobacterial pulmonary infection",
    "Anemia of chronic renal failure",
    "Autism spectrum disorder",
    "Metabolic syndrome",
    "Nasopharyngeal carcinoma",
    "Chronic progressive multiple sclerosis",
    "Dry eye syndrome",
    "Glioblastoma",
    "HIV infectious disease",
    "Ovarian endometriosis",
    "Acute coronary syndrome",
    "Renal cell carcinoma",
    "Hepatocellular carcinoma",
    "Type 1 diabetes mellitus"
  ),
  CTD_Search_Name = c(
    "Crohn Disease",
    "Lung Adenocarcinoma",
    "Carcinoma, Non-Small-Cell Lung",
    "Liver Neoplasms",
    "Kidney Neoplasms",
    "Urinary Bladder Neoplasms",
    "Urinary Bladder Neoplasms",
    "Hepatitis B",
    "Malaria, Falciparum",
    "Adrenoleukodystrophy",
    "Pneumonia",
    "Pulmonary Disease, Chronic Obstructive",
    "Graft vs Host Disease",
    "Fatty Liver",
    "Non-alcoholic Fatty Liver Disease",
    "Diabetic Retinopathy",
    "Hypertension, Pregnancy-Induced",
    "Chronic Fatigue Syndrome",
    "Mycobacterium Infections, Nontuberculous",
    "Kidney Failure, Chronic",
    "Autism Spectrum Disorder",
    "Metabolic Syndrome",
    "Nasopharyngeal Neoplasms",
    "Multiple Sclerosis, Chronic Progressive",
    "Dry Eye Syndromes",
    "Glioblastoma",
    "HIV Infections",
    "Endometriosis",
    "Acute Coronary Syndrome",
    "Carcinoma, Renal Cell",
    "Carcinoma, Hepatocellular",
    "Diabetes Mellitus, Type 1"
  ),
  Manual_CTD_Disease_ID = "",
  stringsAsFactors = FALSE
)

manual_aliases$Manual_CTD_Disease_ID[manual_aliases$Phenotype == "Anemia of chronic renal failure"] <- "MESH:D007676"
manual_aliases$Manual_CTD_Disease_ID[manual_aliases$Phenotype == "Hepatic fibrosis"] <- "MESH:D008103"
manual_aliases$Manual_CTD_Disease_ID[manual_aliases$Phenotype == "Cirrhosis of liver"] <- "MESH:D008103"

extra_manual_aliases <- data.frame(
  Phenotype = c(
    "Hepatic fibrosis",
    "Cirrhosis of liver"
  ),
  CTD_Search_Name = c(
    "Liver Cirrhosis",
    "Liver Cirrhosis"
  ),
  Manual_CTD_Disease_ID = c(
    "MESH:D008103",
    "MESH:D008103"
  ),
  stringsAsFactors = FALSE
)

manual_aliases <- rbind(manual_aliases, extra_manual_aliases)

write.csv(manual_aliases, ctd_manual_alias_file, row.names = FALSE)

download_if_missing(ctd_disease_url, ctd_disease_file)
download_if_missing(ctd_disease_pathway_url, ctd_disease_pathway_file)

disease_info <- read.csv(disease_count_file, stringsAsFactors = FALSE, check.names = FALSE)

used_in_similarity <- rep(FALSE, nrow(disease_info))
if (file.exists(disease_similarity_matrix_file)) {
  similarity_ids <- rownames(read.csv(disease_similarity_matrix_file, row.names = 1, check.names = FALSE))
  used_in_similarity <- disease_info$Phenotype_ID %in% similarity_ids
}
disease_info$Used_In_Disease_Similarity <- used_in_similarity

ctd_diseases <- read_ctd_table(ctd_disease_file)
ctd_pathways <- read_ctd_table(ctd_disease_pathway_file)

ctd_name_index <- make_disease_name_index(ctd_diseases)
name_to_ids <- split(ctd_name_index$CTD_Disease_ID, ctd_name_index$CTD_Disease_Name_Normalized)

alt_id_rows <- data.frame(AltDiseaseID = character(), CTD_Disease_ID = character(), stringsAsFactors = FALSE)
if ("AltDiseaseIDs" %in% colnames(ctd_diseases)) {
  for (i in seq_len(nrow(ctd_diseases))) {
    alt_ids <- split_pipe(ctd_diseases$AltDiseaseIDs[i])
    alt_ids <- normalize_id(alt_ids)
    alt_ids <- alt_ids[!is.na(alt_ids)]
    if (length(alt_ids) == 0) next
    alt_id_rows <- rbind(
      alt_id_rows,
      data.frame(
        AltDiseaseID = alt_ids,
        CTD_Disease_ID = ctd_diseases$DiseaseID[i],
        stringsAsFactors = FALSE
      )
    )
  }
}
alt_id_rows <- unique(alt_id_rows)

match_ctd_id <- function(phenotype, ols_id) {
  ols_id <- normalize_id(ols_id)
  if (!is.na(ols_id) && ols_id %in% ctd_diseases$DiseaseID) {
    return(list(id = ols_id, source = "direct_ctd_id", status = "mapped"))
  }
  if (!is.na(ols_id) && nrow(alt_id_rows) > 0 && ols_id %in% alt_id_rows$AltDiseaseID) {
    return(list(id = alt_id_rows$CTD_Disease_ID[match(ols_id, alt_id_rows$AltDiseaseID)], source = "ctd_alt_id", status = "mapped"))
  }

  phenotype_norm <- normalize_name(phenotype)
  exact_ids <- unique(name_to_ids[[phenotype_norm]])

  alias_row <- manual_aliases[manual_aliases$Phenotype == phenotype,]
  alias_ids <- character()
  manual_ids <- character()
  if (nrow(alias_row) > 0) {
    alias_norm <- normalize_name(alias_row$CTD_Search_Name[1])
    alias_ids <- unique(name_to_ids[[alias_norm]])
    manual_ids <- normalize_id(alias_row$Manual_CTD_Disease_ID)
    manual_ids <- manual_ids[!is.na(manual_ids)]
  }

  if (length(manual_ids) > 0) {
    return(list(id = manual_ids[1], source = "manual_id_override", status = "mapped"))
  }
  if (length(exact_ids) > 0) {
    return(list(id = exact_ids[1], source = "exact_name_or_synonym", status = "mapped"))
  }
  if (length(alias_ids) > 0) {
    return(list(id = alias_ids[1], source = "alias_exact_name_or_synonym", status = "mapped"))
  }

  list(id = NA_character_, source = "unmapped", status = "manual_review_needed")
}

matches <- mapply(
  match_ctd_id,
  disease_info$Phenotype,
  disease_info$OLS_ID,
  SIMPLIFY = FALSE
)

ctd_name_by_id <- setNames(ctd_diseases$DiseaseName, ctd_diseases$DiseaseID)

ctd_review <- disease_info
ctd_review$CTD_Disease_ID_Proposed <- vapply(matches, `[[`, character(1), "id")
ctd_review$CTD_Mapping_Source <- vapply(matches, `[[`, character(1), "source")
ctd_review$CTD_Mapping_Status <- vapply(matches, `[[`, character(1), "status")
ctd_review$CTD_Disease_ID_Final <- ctd_review$CTD_Disease_ID_Proposed
ctd_review$Use_For_CTD_Validation <- !is.na(ctd_review$CTD_Disease_ID_Final) & trimws(ctd_review$CTD_Disease_ID_Final) != ""
ctd_review$Reviewer_Note <- ""
ctd_review$CTD_Disease_Name_Final <- ctd_name_by_id[ctd_review$CTD_Disease_ID_Final]
ctd_review$CTD_Candidate_Matches <- vapply(
  disease_info$Phenotype,
  make_candidate_string,
  character(1),
  ctd_name_index = ctd_name_index,
  n = 8
)

aggregate_pathway_terms <- function(review_table, pathway_table) {
  required <- c("DiseaseID", "PathwayID", "PathwayName")
  missing <- setdiff(required, colnames(pathway_table))
  if (length(missing) > 0) {
    stop("CTD disease-pathway table is missing required columns: ", paste(missing, collapse = ", "))
  }

  review_table$CTD_Pathway_IDs <- ""
  review_table$CTD_Pathway_Names <- ""
  review_table$CTD_Pathway_N <- 0L

  for (i in seq_len(nrow(review_table))) {
    disease_id <- review_table$CTD_Disease_ID_Final[i]
    if (is.na(disease_id) || disease_id == "") next

    rows <- pathway_table[pathway_table$DiseaseID == disease_id,]
    if (nrow(rows) == 0) next

    pathway_ids <- rows$PathwayID
    pathway_names <- rows$PathwayName
    review_table$CTD_Pathway_IDs[i] <- collapse_unique(pathway_ids)
    review_table$CTD_Pathway_Names[i] <- collapse_unique(pathway_names)
    review_table$CTD_Pathway_N[i] <- length(unique(pathway_ids[!is.na(pathway_ids) & pathway_ids != ""]))
  }

  review_table
}

ctd_review <- aggregate_pathway_terms(ctd_review, ctd_pathways)

if (file.exists(ctd_review_file)) {
  old_review <- read.csv(ctd_review_file, stringsAsFactors = FALSE, check.names = FALSE)
  preserve_columns <- c("CTD_Disease_ID_Final", "Use_For_CTD_Validation", "Reviewer_Note")
  for (col in preserve_columns) {
    if (!col %in% colnames(old_review)) next
    old_values <- setNames(old_review[[col]], old_review$Phenotype_ID)
    has_old <- ctd_review$Phenotype_ID %in% names(old_values)
    if (col == "CTD_Disease_ID_Final") {
      old_nonempty <- has_old & !is.na(old_values[ctd_review$Phenotype_ID]) & trimws(old_values[ctd_review$Phenotype_ID]) != ""
      ctd_review[[col]][old_nonempty] <- old_values[ctd_review$Phenotype_ID[old_nonempty]]
    } else {
      ctd_review[[col]][has_old] <- old_values[ctd_review$Phenotype_ID[has_old]]
    }
  }
  ctd_review$CTD_Disease_Name_Final <- ctd_name_by_id[ctd_review$CTD_Disease_ID_Final]
  ctd_review <- aggregate_pathway_terms(ctd_review, ctd_pathways)
}

manual_id_approved <- ctd_review$CTD_Mapping_Source == "manual_id_override" &
  !is.na(ctd_review$CTD_Disease_ID_Final) &
  trimws(ctd_review$CTD_Disease_ID_Final) != ""
ctd_review$Use_For_CTD_Validation[manual_id_approved] <- TRUE

ctd_review <- ctd_review[order(-ctd_review$Module_N, ctd_review$Phenotype),]
write.csv(ctd_review, ctd_review_file, row.names = FALSE)

mapped_ids <- unique(ctd_review$CTD_Disease_ID_Final[ctd_review$Use_For_CTD_Validation])
mapped_pathways <- ctd_pathways[ctd_pathways$DiseaseID %in% mapped_ids,]
write.table(mapped_pathways, ctd_disease_pathway_filtered_file, sep = "\t", row.names = FALSE, quote = FALSE)

message("Wrote CTD mapping alias table: ", ctd_manual_alias_file)
message("Wrote disease CTD pathway review table: ", ctd_review_file)
message("Wrote mapped CTD disease-pathway associations: ", ctd_disease_pathway_filtered_file)
message("Please review CTD_Disease_ID_Final and Use_For_CTD_Validation before downstream validation.")
