project_dir <- normalizePath(getwd())
if (!file.exists(file.path(project_dir, "analysis", "2_data", "disease_ctd_pathway_review.csv"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", ".."))
}

# Define shared metabolic mechanism from external CTD disease-pathway terms.
#
# For each disease pair, count shared CTD pathway terms under three term sets:
#   1. all CTD pathway terms
#   2. KEGG terms only
#   3. Reactome terms only
#
# Within each term set, a pair is labeled as having a shared metabolic mechanism
# when its shared CTD term count is strictly greater than the mean shared count
# across all tested disease pairs for that term set. BMA similarity is then
# compared between pairs above vs not above this threshold with a one-sided
# Wilcoxon rank-sum test.

data_dir <- file.path(project_dir, "analysis", "2_data")
result_dir <- file.path(project_dir, "analysis", "3_result")
dir.create(result_dir, showWarnings = FALSE, recursive = TRUE)

ctd_review_file <- file.path(data_dir, "disease_ctd_pathway_review.csv")
disease_pairs_file <- file.path(result_dir, "disease_phenotype_similarity_pairs.csv")

pair_output_file <- file.path(result_dir, "disease_similarity_ctd_shared_mechanism_pairs.csv")
summary_output_file <- file.path(result_dir, "disease_similarity_ctd_shared_mechanism_wilcoxon_summary.csv")
report_output_file <- file.path(result_dir, "disease_similarity_ctd_shared_mechanism_wilcoxon_report.txt")

# Settings
use_only_similarity_diseases <- TRUE
use_only_review_approved_diseases <- TRUE
exclude_same_ctd_disease_id_pairs <- TRUE
alternative_hypothesis <- "greater"

term_sets <- list(
  all_ctd_terms = list(
    label = "All CTD pathway terms",
    pattern = NULL
  ),
  kegg_only = list(
    label = "KEGG terms only",
    pattern = "^KEGG:"
  ),
  reactome_only = list(
    label = "Reactome terms only",
    pattern = "^REACT:"
  )
)

as_logical_flag <- function(x) {
  if (is.logical(x)) return(x)
  tolower(trimws(as.character(x))) %in% c("true", "t", "1", "yes", "y")
}

split_semicolon <- function(x) {
  x <- trimws(x)
  if (is.na(x) || x == "") return(character())
  parts <- unlist(strsplit(x, ";", fixed = TRUE), use.names = FALSE)
  parts <- trimws(parts)
  unique(parts[parts != ""])
}

filter_terms <- function(x, pattern = NULL) {
  terms <- split_semicolon(x)
  if (is.null(pattern)) return(terms)
  terms[grepl(pattern, terms, ignore.case = TRUE)]
}

shared_count_for_term_set <- function(a, b, pattern = NULL) {
  aa <- filter_terms(a, pattern)
  bb <- filter_terms(b, pattern)
  length(intersect(aa, bb))
}

auc_from_values <- function(x, y) {
  if (length(x) == 0 || length(y) == 0) return(NA_real_)
  comparisons <- outer(x, y, FUN = "-")
  mean(comparisons > 0) + 0.5 * mean(comparisons == 0)
}

value_summary <- function(x) {
  if (length(x) == 0) {
    return(c(
      n = 0,
      mean = NA_real_,
      median = NA_real_,
      q1 = NA_real_,
      q3 = NA_real_
    ))
  }

  c(
    n = length(x),
    mean = mean(x),
    median = median(x),
    q1 = as.numeric(quantile(x, 0.25)),
    q3 = as.numeric(quantile(x, 0.75))
  )
}

ctd_review <- read.csv(ctd_review_file, stringsAsFactors = FALSE, check.names = FALSE)
disease_pairs <- read.csv(disease_pairs_file, stringsAsFactors = FALSE, check.names = FALSE)

required_columns <- c(
  "Phenotype_ID",
  "Phenotype",
  "Used_In_Disease_Similarity",
  "CTD_Disease_ID_Final",
  "Use_For_CTD_Validation",
  "CTD_Pathway_IDs",
  "CTD_Pathway_N"
)
missing_columns <- setdiff(required_columns, colnames(ctd_review))
if (length(missing_columns) > 0) {
  stop("CTD review table is missing required columns: ", paste(missing_columns, collapse = ", "))
}

required_pair_columns <- c(
  "Phenotype_ID_1",
  "Phenotype_ID_2",
  "BMA_Similarity"
)
missing_pair_columns <- setdiff(required_pair_columns, colnames(disease_pairs))
if (length(missing_pair_columns) > 0) {
  stop("Disease pair table is missing required columns: ", paste(missing_pair_columns, collapse = ", "))
}

ctd_review$Used_In_Disease_Similarity <- as_logical_flag(ctd_review$Used_In_Disease_Similarity)
ctd_review$Use_For_CTD_Validation <- as_logical_flag(ctd_review$Use_For_CTD_Validation)

if (use_only_similarity_diseases) {
  ctd_review <- ctd_review[ctd_review$Used_In_Disease_Similarity,]
}

if (use_only_review_approved_diseases) {
  ctd_review <- ctd_review[
    ctd_review$Use_For_CTD_Validation &
      !is.na(ctd_review$CTD_Disease_ID_Final) &
      trimws(ctd_review$CTD_Disease_ID_Final) != "",
  ]
}

ctd_review <- ctd_review[
  !is.na(ctd_review$CTD_Pathway_IDs) &
    trimws(ctd_review$CTD_Pathway_IDs) != "",
]

if (nrow(ctd_review) < 3) {
  stop("Fewer than 3 CTD pathway-annotated diseases are available for validation.")
}

ctd_id_by_id <- setNames(ctd_review$CTD_Disease_ID_Final, ctd_review$Phenotype_ID)
pathway_ids_by_id <- setNames(ctd_review$CTD_Pathway_IDs, ctd_review$Phenotype_ID)
pathway_n_by_id <- setNames(ctd_review$CTD_Pathway_N, ctd_review$Phenotype_ID)

pair_table <- disease_pairs[
  disease_pairs$Phenotype_ID_1 != disease_pairs$Phenotype_ID_2 &
    disease_pairs$Phenotype_ID_1 %in% ctd_review$Phenotype_ID &
    disease_pairs$Phenotype_ID_2 %in% ctd_review$Phenotype_ID,
]

pair_table$CTD_Disease_ID_1 <- ctd_id_by_id[pair_table$Phenotype_ID_1]
pair_table$CTD_Disease_ID_2 <- ctd_id_by_id[pair_table$Phenotype_ID_2]
pair_table$CTD_Pathway_IDs_1 <- pathway_ids_by_id[pair_table$Phenotype_ID_1]
pair_table$CTD_Pathway_IDs_2 <- pathway_ids_by_id[pair_table$Phenotype_ID_2]
pair_table$CTD_Pathway_N_1 <- pathway_n_by_id[pair_table$Phenotype_ID_1]
pair_table$CTD_Pathway_N_2 <- pathway_n_by_id[pair_table$Phenotype_ID_2]

if (exclude_same_ctd_disease_id_pairs) {
  pair_table <- pair_table[
    is.na(pair_table$CTD_Disease_ID_1) |
      is.na(pair_table$CTD_Disease_ID_2) |
      pair_table$CTD_Disease_ID_1 != pair_table$CTD_Disease_ID_2,
  ]
}

if (nrow(pair_table) < 3) {
  stop("Fewer than 3 disease pairs have CTD pathway annotations.")
}

pair_rows_by_term_set <- list()
summary_rows <- data.frame()

for (term_set_name in names(term_sets)) {
  term_set <- term_sets[[term_set_name]]
  shared_counts <- vapply(
    seq_len(nrow(pair_table)),
    function(i) {
      shared_count_for_term_set(
        pair_table$CTD_Pathway_IDs_1[i],
        pair_table$CTD_Pathway_IDs_2[i],
        term_set$pattern
      )
    },
    integer(1)
  )

  mean_threshold <- mean(shared_counts)
  shared_mechanism <- shared_counts > mean_threshold

  term_pair_table <- pair_table
  term_pair_table$CTD_Term_Set <- term_set_name
  term_pair_table$CTD_Term_Set_Label <- term_set$label
  term_pair_table$Shared_CTD_Term_N <- shared_counts
  term_pair_table$Shared_CTD_Term_Mean_Threshold <- mean_threshold
  term_pair_table$Shared_Metabolic_Mechanism <- shared_mechanism
  pair_rows_by_term_set[[term_set_name]] <- term_pair_table

  shared_values <- term_pair_table$BMA_Similarity[term_pair_table$Shared_Metabolic_Mechanism]
  not_shared_values <- term_pair_table$BMA_Similarity[!term_pair_table$Shared_Metabolic_Mechanism]
  shared_summary <- value_summary(shared_values)
  not_shared_summary <- value_summary(not_shared_values)

  wilcox_w <- NA_real_
  wilcox_p <- NA_real_
  auc <- NA_real_
  if (length(shared_values) > 0 && length(not_shared_values) > 0) {
    wilcox_result <- wilcox.test(
      shared_values,
      not_shared_values,
      alternative = alternative_hypothesis,
      exact = FALSE
    )
    wilcox_w <- unname(wilcox_result$statistic)
    wilcox_p <- wilcox_result$p.value
    auc <- auc_from_values(shared_values, not_shared_values)
  }

  summary_rows <- rbind(
    summary_rows,
    data.frame(
      CTD_Term_Set = term_set_name,
      CTD_Term_Set_Label = term_set$label,
      Definition = "Shared metabolic mechanism if shared CTD term count is greater than the mean shared count for this CTD term set",
      Alternative = "pairs above the mean shared CTD term count have higher BMA similarity",
      Disease_N = length(unique(c(term_pair_table$Phenotype_ID_1, term_pair_table$Phenotype_ID_2))),
      Pair_N_Total = nrow(term_pair_table),
      Shared_CTD_Term_N_Min = min(shared_counts),
      Shared_CTD_Term_N_Mean_Threshold = mean_threshold,
      Shared_CTD_Term_N_Median = median(shared_counts),
      Shared_CTD_Term_N_Max = max(shared_counts),
      Pair_N_Shared_Metabolic_Mechanism = unname(shared_summary["n"]),
      Pair_N_Not_Shared_Metabolic_Mechanism = unname(not_shared_summary["n"]),
      Shared_Mechanism_Mean_BMA = unname(shared_summary["mean"]),
      Shared_Mechanism_Median_BMA = unname(shared_summary["median"]),
      Shared_Mechanism_Q1_BMA = unname(shared_summary["q1"]),
      Shared_Mechanism_Q3_BMA = unname(shared_summary["q3"]),
      Not_Shared_Mechanism_Mean_BMA = unname(not_shared_summary["mean"]),
      Not_Shared_Mechanism_Median_BMA = unname(not_shared_summary["median"]),
      Not_Shared_Mechanism_Q1_BMA = unname(not_shared_summary["q1"]),
      Not_Shared_Mechanism_Q3_BMA = unname(not_shared_summary["q3"]),
      Median_Difference = unname(shared_summary["median"] - not_shared_summary["median"]),
      Mean_Difference = unname(shared_summary["mean"] - not_shared_summary["mean"]),
      AUC_Shared_Mechanism_Greater_Than_Not = auc,
      Wilcoxon_W = wilcox_w,
      P_Value = wilcox_p,
      stringsAsFactors = FALSE
    )
  )
}

pair_output_table <- do.call(rbind, pair_rows_by_term_set)

write.csv(pair_output_table, pair_output_file, row.names = FALSE)
write.csv(summary_rows, summary_output_file, row.names = FALSE)

report_lines <- c(
  "Disease similarity by CTD-derived shared metabolic mechanism",
  paste0("CTD review table: ", ctd_review_file),
  paste0("Disease pair table: ", disease_pairs_file),
  "",
  "Definition:",
  "For each CTD term set, shared metabolic mechanism is TRUE when a disease pair's shared CTD term count is strictly greater than the mean shared CTD term count across all tested disease pairs in that term set.",
  "",
  "Summary:"
)

for (i in seq_len(nrow(summary_rows))) {
  report_lines <- c(
    report_lines,
    "",
    paste0("CTD term set: ", summary_rows$CTD_Term_Set_Label[i], " (", summary_rows$CTD_Term_Set[i], ")"),
    paste0("Diseases tested: ", summary_rows$Disease_N[i]),
    paste0("Total tested pairs: ", summary_rows$Pair_N_Total[i]),
    paste0("Mean shared CTD term threshold: ", signif(summary_rows$Shared_CTD_Term_N_Mean_Threshold[i], 4)),
    paste0("Shared CTD term count range: ", summary_rows$Shared_CTD_Term_N_Min[i], " to ", summary_rows$Shared_CTD_Term_N_Max[i]),
    paste0("Pairs above threshold: ", summary_rows$Pair_N_Shared_Metabolic_Mechanism[i]),
    paste0("Pairs at or below threshold: ", summary_rows$Pair_N_Not_Shared_Metabolic_Mechanism[i]),
    paste0("Above-threshold median BMA similarity: ", signif(summary_rows$Shared_Mechanism_Median_BMA[i], 4)),
    paste0("At-or-below-threshold median BMA similarity: ", signif(summary_rows$Not_Shared_Mechanism_Median_BMA[i], 4)),
    paste0("Median difference: ", signif(summary_rows$Median_Difference[i], 4)),
    paste0("AUC above > at-or-below: ", signif(summary_rows$AUC_Shared_Mechanism_Greater_Than_Not[i], 4)),
    paste0("Wilcoxon W: ", signif(summary_rows$Wilcoxon_W[i], 6)),
    paste0("Wilcoxon p-value: ", signif(summary_rows$P_Value[i], 6))
  )
}

report_lines <- c(
  report_lines,
  "",
  "Interpretation note:",
  "Pairwise disease similarities are not fully independent because each disease appears in multiple pairs. Interpret this as a validation screen unless a permutation or mixed-model sensitivity analysis is added."
)

writeLines(report_lines, report_output_file)

message("Wrote CTD shared metabolic mechanism pair table: ", pair_output_file)
message("Wrote CTD shared metabolic mechanism Wilcoxon summary: ", summary_output_file)
message("Wrote CTD shared metabolic mechanism report: ", report_output_file)
