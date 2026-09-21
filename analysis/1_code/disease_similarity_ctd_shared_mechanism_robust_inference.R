project_dir <- normalizePath(getwd())
if (!file.exists(file.path(project_dir, "analysis", "3_result", "disease_similarity_ctd_shared_mechanism_pairs.csv"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", ".."))
}

# Robust inference for CTD-derived shared metabolic mechanism validation.
#
# This script should be run after:
#   analysis/1_code/disease_similarity_ctd_shared_mechanism_wilcoxon.R
#
# It adds two sensitivity analyses that account for the fact that disease pairs
# are not fully independent:
#   1. Disease-label permutation test:
#      Shuffle CTD pathway annotations across diseases, recompute shared CTD
#      term counts, recompute the mean-count threshold, and compare the observed
#      above-vs-below threshold BMA difference to the empirical null.
#   2. Crossed-endpoint mixed model:
#      Fit BMA similarity as a function of shared mechanism status with random
#      intercepts for the two disease endpoints in each pair.

result_dir <- file.path(project_dir, "analysis", "3_result")

pair_input_file <- file.path(result_dir, "disease_similarity_ctd_shared_mechanism_pairs.csv")
permutation_summary_file <- file.path(result_dir, "disease_similarity_ctd_shared_mechanism_permutation_summary.csv")
permutation_statistics_file <- file.path(result_dir, "disease_similarity_ctd_shared_mechanism_permutation_statistics.csv")
mixed_model_summary_file <- file.path(result_dir, "disease_similarity_ctd_shared_mechanism_mixed_model_summary.csv")
report_output_file <- file.path(result_dir, "disease_similarity_ctd_shared_mechanism_robust_inference_report.txt")

# Settings
n_permutations <- 5000
random_seed <- 20260917
alternative_hypothesis <- "greater"

split_semicolon <- function(x) {
  x <- trimws(x)
  if (is.na(x) || x == "") return(character())
  parts <- unlist(strsplit(x, ";", fixed = TRUE), use.names = FALSE)
  parts <- trimws(parts)
  unique(parts[parts != ""])
}

filter_terms <- function(x, term_set_name) {
  terms <- split_semicolon(x)
  if (term_set_name == "kegg_only") {
    return(terms[grepl("^KEGG:", terms, ignore.case = TRUE)])
  }
  if (term_set_name == "reactome_only") {
    return(terms[grepl("^REACT:", terms, ignore.case = TRUE)])
  }
  terms
}

get_statistic <- function(bma, shared_count) {
  threshold <- mean(shared_count)
  group <- shared_count > threshold

  above_values <- bma[group]
  below_values <- bma[!group]

  out <- list(
    threshold = threshold,
    n_above = length(above_values),
    n_below = length(below_values),
    mean_difference = NA_real_,
    median_difference = NA_real_,
    auc = NA_real_
  )

  if (length(above_values) == 0 || length(below_values) == 0) {
    return(out)
  }

  comparisons <- outer(above_values, below_values, FUN = "-")
  out$mean_difference <- mean(above_values) - mean(below_values)
  out$median_difference <- median(above_values) - median(below_values)
  out$auc <- mean(comparisons > 0) + 0.5 * mean(comparisons == 0)
  out
}

count_shared_terms <- function(term_sets, idx1, idx2) {
  vapply(
    seq_along(idx1),
    function(i) length(intersect(term_sets[[idx1[i]]], term_sets[[idx2[i]]])),
    integer(1)
  )
}

make_disease_term_sets <- function(term_pair_table, term_set_name) {
  disease_rows_1 <- data.frame(
    Phenotype_ID = term_pair_table$Phenotype_ID_1,
    CTD_Pathway_IDs = term_pair_table$CTD_Pathway_IDs_1,
    stringsAsFactors = FALSE
  )
  disease_rows_2 <- data.frame(
    Phenotype_ID = term_pair_table$Phenotype_ID_2,
    CTD_Pathway_IDs = term_pair_table$CTD_Pathway_IDs_2,
    stringsAsFactors = FALSE
  )
  disease_rows <- unique(rbind(disease_rows_1, disease_rows_2))
  disease_rows <- disease_rows[order(disease_rows$Phenotype_ID),]

  duplicated_ids <- disease_rows$Phenotype_ID[duplicated(disease_rows$Phenotype_ID)]
  if (length(duplicated_ids) > 0) {
    stop(
      "Found inconsistent CTD pathway annotations for disease IDs: ",
      paste(unique(duplicated_ids), collapse = ", ")
    )
  }

  term_sets <- lapply(disease_rows$CTD_Pathway_IDs, filter_terms, term_set_name = term_set_name)
  names(term_sets) <- disease_rows$Phenotype_ID
  term_sets
}

permutation_test_one_term_set <- function(term_pair_table, term_set_name, n_permutations) {
  term_sets <- make_disease_term_sets(term_pair_table, term_set_name)
  disease_ids <- names(term_sets)

  idx1 <- match(term_pair_table$Phenotype_ID_1, disease_ids)
  idx2 <- match(term_pair_table$Phenotype_ID_2, disease_ids)
  bma <- term_pair_table$BMA_Similarity

  observed_shared_count <- count_shared_terms(term_sets, idx1, idx2)
  observed <- get_statistic(bma, observed_shared_count)

  permutation_rows <- data.frame(
    CTD_Term_Set = term_set_name,
    Permutation = seq_len(n_permutations),
    Threshold = NA_real_,
    Pair_N_Above_Threshold = NA_integer_,
    Pair_N_At_Or_Below_Threshold = NA_integer_,
    Mean_Difference = NA_real_,
    Median_Difference = NA_real_,
    AUC = NA_real_,
    stringsAsFactors = FALSE
  )

  for (i in seq_len(n_permutations)) {
    permuted_term_sets <- term_sets[sample.int(length(term_sets))]
    permuted_shared_count <- count_shared_terms(permuted_term_sets, idx1, idx2)
    permuted <- get_statistic(bma, permuted_shared_count)

    permutation_rows$Threshold[i] <- permuted$threshold
    permutation_rows$Pair_N_Above_Threshold[i] <- permuted$n_above
    permutation_rows$Pair_N_At_Or_Below_Threshold[i] <- permuted$n_below
    permutation_rows$Mean_Difference[i] <- permuted$mean_difference
    permutation_rows$Median_Difference[i] <- permuted$median_difference
    permutation_rows$AUC[i] <- permuted$auc
  }

  valid_mean <- !is.na(permutation_rows$Mean_Difference)
  valid_median <- !is.na(permutation_rows$Median_Difference)
  valid_auc <- !is.na(permutation_rows$AUC)

  mean_p <- if (is.na(observed$mean_difference) || sum(valid_mean) == 0) {
    NA_real_
  } else {
    (1 + sum(permutation_rows$Mean_Difference[valid_mean] >= observed$mean_difference)) /
      (1 + sum(valid_mean))
  }

  median_p <- if (is.na(observed$median_difference) || sum(valid_median) == 0) {
    NA_real_
  } else {
    (1 + sum(permutation_rows$Median_Difference[valid_median] >= observed$median_difference)) /
      (1 + sum(valid_median))
  }

  auc_p <- if (is.na(observed$auc) || sum(valid_auc) == 0) {
    NA_real_
  } else {
    (1 + sum(permutation_rows$AUC[valid_auc] >= observed$auc)) /
      (1 + sum(valid_auc))
  }

  summary_row <- data.frame(
    CTD_Term_Set = term_set_name,
    Test = "Disease-label permutation",
    N_Permutations = n_permutations,
    Disease_N = length(disease_ids),
    Pair_N_Total = nrow(term_pair_table),
    Observed_Threshold = observed$threshold,
    Observed_Pair_N_Above_Threshold = observed$n_above,
    Observed_Pair_N_At_Or_Below_Threshold = observed$n_below,
    Observed_Mean_Difference = observed$mean_difference,
    Permutation_P_Value_Mean_Difference = mean_p,
    Observed_Median_Difference = observed$median_difference,
    Permutation_P_Value_Median_Difference = median_p,
    Observed_AUC = observed$auc,
    Permutation_P_Value_AUC = auc_p,
    Null_Mean_Difference_Mean = mean(permutation_rows$Mean_Difference, na.rm = TRUE),
    Null_Mean_Difference_Q025 = as.numeric(quantile(permutation_rows$Mean_Difference, 0.025, na.rm = TRUE)),
    Null_Mean_Difference_Q975 = as.numeric(quantile(permutation_rows$Mean_Difference, 0.975, na.rm = TRUE)),
    Null_Median_Difference_Mean = mean(permutation_rows$Median_Difference, na.rm = TRUE),
    Null_Median_Difference_Q025 = as.numeric(quantile(permutation_rows$Median_Difference, 0.025, na.rm = TRUE)),
    Null_Median_Difference_Q975 = as.numeric(quantile(permutation_rows$Median_Difference, 0.975, na.rm = TRUE)),
    Null_AUC_Mean = mean(permutation_rows$AUC, na.rm = TRUE),
    Null_AUC_Q025 = as.numeric(quantile(permutation_rows$AUC, 0.025, na.rm = TRUE)),
    Null_AUC_Q975 = as.numeric(quantile(permutation_rows$AUC, 0.975, na.rm = TRUE)),
    stringsAsFactors = FALSE
  )

  list(summary = summary_row, permutations = permutation_rows)
}

fit_mixed_model_one_term_set <- function(term_pair_table, term_set_name) {
  if (!requireNamespace("lme4", quietly = TRUE)) {
    return(data.frame(
      CTD_Term_Set = term_set_name,
      Test = "Crossed-endpoint mixed model",
      Status = "lme4_not_installed",
      Pair_N_Total = nrow(term_pair_table),
      Pair_N_Shared_Mechanism = sum(term_pair_table$Shared_Metabolic_Mechanism),
      Pair_N_Not_Shared_Mechanism = sum(!term_pair_table$Shared_Metabolic_Mechanism),
      Fixed_Effect_Estimate = NA_real_,
      Likelihood_Ratio_Statistic = NA_real_,
      P_Value_LRT = NA_real_,
      Model_Message = "Install lme4 to run this model: install.packages('lme4')",
      stringsAsFactors = FALSE
    ))
  }

  model_data <- term_pair_table
  model_data$Shared_Metabolic_Mechanism <- as.logical(model_data$Shared_Metabolic_Mechanism)
  model_data$Phenotype_ID_1 <- factor(model_data$Phenotype_ID_1)
  model_data$Phenotype_ID_2 <- factor(model_data$Phenotype_ID_2)

  if (length(unique(model_data$Shared_Metabolic_Mechanism)) < 2) {
    return(data.frame(
      CTD_Term_Set = term_set_name,
      Test = "Crossed-endpoint mixed model",
      Status = "skipped_single_group",
      Pair_N_Total = nrow(term_pair_table),
      Pair_N_Shared_Mechanism = sum(term_pair_table$Shared_Metabolic_Mechanism),
      Pair_N_Not_Shared_Mechanism = sum(!term_pair_table$Shared_Metabolic_Mechanism),
      Fixed_Effect_Estimate = NA_real_,
      Likelihood_Ratio_Statistic = NA_real_,
      P_Value_LRT = NA_real_,
      Model_Message = "Shared_Metabolic_Mechanism has fewer than two groups.",
      stringsAsFactors = FALSE
    ))
  }

  fit_result <- tryCatch(
    {
      full_model <- lme4::lmer(
        BMA_Similarity ~ Shared_Metabolic_Mechanism + (1 | Phenotype_ID_1) + (1 | Phenotype_ID_2),
        data = model_data,
        REML = FALSE
      )
      null_model <- lme4::lmer(
        BMA_Similarity ~ 1 + (1 | Phenotype_ID_1) + (1 | Phenotype_ID_2),
        data = model_data,
        REML = FALSE
      )
      lrt <- anova(null_model, full_model)
      coefficient_table <- coef(summary(full_model))
      coefficient_name <- grep("^Shared_Metabolic_Mechanism", rownames(coefficient_table), value = TRUE)

      list(
        status = "ok",
        estimate = if (length(coefficient_name) == 0) NA_real_ else coefficient_table[coefficient_name[1], "Estimate"],
        lrt = lrt$Chisq[2],
        p_value = lrt$`Pr(>Chisq)`[2],
        message = if (lme4::isSingular(full_model)) "Full model fit is singular." else ""
      )
    },
    error = function(e) {
      list(
        status = "model_error",
        estimate = NA_real_,
        lrt = NA_real_,
        p_value = NA_real_,
        message = conditionMessage(e)
      )
    }
  )

  data.frame(
    CTD_Term_Set = term_set_name,
    Test = "Crossed-endpoint mixed model",
    Status = fit_result$status,
    Pair_N_Total = nrow(term_pair_table),
    Pair_N_Shared_Mechanism = sum(term_pair_table$Shared_Metabolic_Mechanism),
    Pair_N_Not_Shared_Mechanism = sum(!term_pair_table$Shared_Metabolic_Mechanism),
    Fixed_Effect_Estimate = fit_result$estimate,
    Likelihood_Ratio_Statistic = fit_result$lrt,
    P_Value_LRT = fit_result$p_value,
    Model_Message = fit_result$message,
    stringsAsFactors = FALSE
  )
}

if (!file.exists(pair_input_file)) {
  stop(
    "Missing input file: ",
    pair_input_file,
    ". Run analysis/1_code/disease_similarity_ctd_shared_mechanism_wilcoxon.R first."
  )
}

pair_table <- read.csv(pair_input_file, stringsAsFactors = FALSE, check.names = FALSE)

required_columns <- c(
  "CTD_Term_Set",
  "Phenotype_ID_1",
  "Phenotype_ID_2",
  "BMA_Similarity",
  "CTD_Pathway_IDs_1",
  "CTD_Pathway_IDs_2",
  "Shared_Metabolic_Mechanism"
)
missing_columns <- setdiff(required_columns, colnames(pair_table))
if (length(missing_columns) > 0) {
  stop("Shared mechanism pair table is missing required columns: ", paste(missing_columns, collapse = ", "))
}

pair_table$Shared_Metabolic_Mechanism <- tolower(trimws(as.character(pair_table$Shared_Metabolic_Mechanism))) %in%
  c("true", "t", "1", "yes", "y")

set.seed(random_seed)
term_set_names <- unique(pair_table$CTD_Term_Set)

permutation_summaries <- list()
permutation_statistics <- list()
mixed_model_summaries <- list()

for (term_set_name in term_set_names) {
  message("Running robust inference for CTD term set: ", term_set_name)
  term_pair_table <- pair_table[pair_table$CTD_Term_Set == term_set_name,]

  permutation_result <- permutation_test_one_term_set(
    term_pair_table = term_pair_table,
    term_set_name = term_set_name,
    n_permutations = n_permutations
  )
  permutation_summaries[[term_set_name]] <- permutation_result$summary
  permutation_statistics[[term_set_name]] <- permutation_result$permutations

  mixed_model_summaries[[term_set_name]] <- fit_mixed_model_one_term_set(
    term_pair_table = term_pair_table,
    term_set_name = term_set_name
  )
}

permutation_summary <- do.call(rbind, permutation_summaries)
permutation_statistics_table <- do.call(rbind, permutation_statistics)
mixed_model_summary <- do.call(rbind, mixed_model_summaries)

write.csv(permutation_summary, permutation_summary_file, row.names = FALSE)
write.csv(permutation_statistics_table, permutation_statistics_file, row.names = FALSE)
write.csv(mixed_model_summary, mixed_model_summary_file, row.names = FALSE)

report_lines <- c(
  "Robust inference for CTD-derived shared metabolic mechanism validation",
  paste0("Input pair table: ", pair_input_file),
  paste0("Permutations: ", n_permutations),
  paste0("Random seed: ", random_seed),
  "",
  "Permutation test:",
  "Disease CTD pathway annotations are shuffled across diseases, shared CTD term counts and mean thresholds are recomputed, and the observed above-vs-below BMA difference is compared to this empirical null.",
  "",
  "Mixed model:",
  "BMA similarity is modeled as a function of shared mechanism status with random intercepts for the two disease endpoints in each pair: BMA ~ Shared_Metabolic_Mechanism + (1 | Phenotype_ID_1) + (1 | Phenotype_ID_2).",
  ""
)

for (term_set_name in term_set_names) {
  p_row <- permutation_summary[permutation_summary$CTD_Term_Set == term_set_name,]
  m_row <- mixed_model_summary[mixed_model_summary$CTD_Term_Set == term_set_name,]

  report_lines <- c(
    report_lines,
    paste0("CTD term set: ", term_set_name),
    paste0("  Pair count: ", p_row$Pair_N_Total),
    paste0("  Observed above-threshold pairs: ", p_row$Observed_Pair_N_Above_Threshold),
    paste0("  Observed at-or-below-threshold pairs: ", p_row$Observed_Pair_N_At_Or_Below_Threshold),
    paste0("  Observed mean difference: ", signif(p_row$Observed_Mean_Difference, 4)),
    paste0("  Permutation p-value, mean difference: ", signif(p_row$Permutation_P_Value_Mean_Difference, 6)),
    paste0("  Observed median difference: ", signif(p_row$Observed_Median_Difference, 4)),
    paste0("  Permutation p-value, median difference: ", signif(p_row$Permutation_P_Value_Median_Difference, 6)),
    paste0("  Observed AUC: ", signif(p_row$Observed_AUC, 4)),
    paste0("  Permutation p-value, AUC: ", signif(p_row$Permutation_P_Value_AUC, 6)),
    paste0("  Mixed model status: ", m_row$Status),
    paste0("  Mixed model fixed-effect estimate: ", signif(m_row$Fixed_Effect_Estimate, 4)),
    paste0("  Mixed model LRT p-value: ", signif(m_row$P_Value_LRT, 6)),
    paste0("  Mixed model message: ", m_row$Model_Message),
    ""
  )
}

report_lines <- c(
  report_lines,
  "Interpretation note:",
  "The permutation test is the more direct non-independence sensitivity check here because it preserves the disease-pair BMA structure while breaking the link between CTD annotations and disease identities.",
  "The mixed model is an approximate crossed-endpoint model for pairwise disease data; use its effect direction and likelihood-ratio test as a complementary sensitivity analysis."
)

writeLines(report_lines, report_output_file)

message("Wrote permutation summary: ", permutation_summary_file)
message("Wrote permutation statistics: ", permutation_statistics_file)
message("Wrote mixed model summary: ", mixed_model_summary_file)
message("Wrote robust inference report: ", report_output_file)
