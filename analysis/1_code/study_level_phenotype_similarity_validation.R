project_dir <- normalizePath(getwd())
if (!file.exists(file.path(project_dir, "analysis", "2_data", "selected_module_phenotype_map.csv"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", ".."))
}

# Validate whether independent studies assigned to the same canonical phenotype
# have more similar module sets than studies assigned to different phenotypes.
#
# Unit of comparison:
#   one Study_ID + Phenotype_ID pair, represented by all selected modules
#   mapped to that study-phenotype pair.
#
# Similarity between two study-phenotype units:
#   BMA over their module sets, using the existing module-module similarity.

# Input and output paths
data_dir <- file.path(project_dir, "analysis", "2_data")
result_dir <- file.path(project_dir, "analysis", "3_result")
dir.create(result_dir, showWarnings = FALSE, recursive = TRUE)

module_phenotype_file <- file.path(data_dir, "selected_module_phenotype_map.csv")
module_similarity_file <- file.path(data_dir, "selected_module_module_similarity_edges.csv")

pair_output_file <- file.path(result_dir, "study_level_phenotype_similarity_validation_pairs.csv")
summary_output_file <- file.path(result_dir, "study_level_phenotype_similarity_validation_summary.csv")
phenotype_output_file <- file.path(result_dir, "study_level_phenotype_similarity_validation_by_phenotype.csv")
report_output_file <- file.path(result_dir, "study_level_phenotype_similarity_validation_report.txt")

# Analysis settings
min_modules_per_study_phenotype <- 1
min_studies_per_phenotype <- 2
missing_module_similarity <- 0
exclude_same_study_negative_pairs <- TRUE

# Optional downsampling for different-phenotype pairs. Leave as NA to use all.
# If the full pair table gets too large in future data versions, set this to
# a number such as 100000.
max_different_phenotype_pairs <- NA_integer_
set.seed(20260916)

bma_similarity <- function(modules_a, modules_b, similarity_matrix) {
  pair_sim <- similarity_matrix[modules_a, modules_b, drop = FALSE]
  best_a_to_b <- apply(pair_sim, 1, max, na.rm = TRUE)
  best_b_to_a <- apply(pair_sim, 2, max, na.rm = TRUE)
  mean(c(mean(best_a_to_b), mean(best_b_to_a)))
}

auc_from_values <- function(x, y) {
  if (length(x) == 0 || length(y) == 0) return(NA_real_)
  comparisons <- outer(x, y, FUN = "-")
  mean(comparisons > 0) + 0.5 * mean(comparisons == 0)
}

selected_module_phenotype <- read.csv(
  module_phenotype_file,
  stringsAsFactors = FALSE,
  check.names = FALSE
)
module_sim <- read.csv(
  module_similarity_file,
  stringsAsFactors = FALSE,
  check.names = FALSE
)

required_map_cols <- c("Phenotype_ID", "Study_ID", "Module_ID", "Phenotype", "Phenotype_Type", "OLS_ID")
missing_map_cols <- setdiff(required_map_cols, colnames(selected_module_phenotype))
if (length(missing_map_cols) > 0) {
  stop("Module-phenotype map is missing required columns: ", paste(missing_map_cols, collapse = ", "))
}

required_sim_cols <- c(":START_ID", ":END_ID", "Similarity_Score")
missing_sim_cols <- setdiff(required_sim_cols, colnames(module_sim))
if (length(missing_sim_cols) > 0) {
  stop("Module similarity table is missing required columns: ", paste(missing_sim_cols, collapse = ", "))
}

selected_module_phenotype <- unique(selected_module_phenotype[, required_map_cols])

# Build study-phenotype units.
unit_keys <- unique(selected_module_phenotype[, c("Phenotype_ID", "Study_ID")])
unit_rows <- vector("list", nrow(unit_keys))

for (i in seq_len(nrow(unit_keys))) {
  phenotype_id <- unit_keys$Phenotype_ID[i]
  study_id <- unit_keys$Study_ID[i]
  rows <- selected_module_phenotype[
    selected_module_phenotype$Phenotype_ID == phenotype_id &
      selected_module_phenotype$Study_ID == study_id,
  ]
  modules <- sort(unique(rows$Module_ID))
  info <- rows[1,]

  unit_rows[[i]] <- data.frame(
    Unit_ID = paste(phenotype_id, study_id, sep = "__"),
    Phenotype_ID = phenotype_id,
    Phenotype = info$Phenotype,
    Phenotype_Type = info$Phenotype_Type,
    OLS_ID = info$OLS_ID,
    Study_ID = study_id,
    Module_N = length(modules),
    Module_IDs = paste(modules, collapse = "; "),
    stringsAsFactors = FALSE
  )
}

study_units <- do.call(rbind, unit_rows)
study_units <- study_units[study_units$Module_N >= min_modules_per_study_phenotype,]

phenotype_study_count <- aggregate(
  Study_ID ~ Phenotype_ID + Phenotype + Phenotype_Type + OLS_ID,
  data = study_units,
  FUN = function(x) length(unique(x))
)
colnames(phenotype_study_count)[colnames(phenotype_study_count) == "Study_ID"] <- "Study_N"

eligible_phenotypes <- phenotype_study_count$Phenotype_ID[
  phenotype_study_count$Study_N >= min_studies_per_phenotype
]

study_units <- study_units[study_units$Phenotype_ID %in% eligible_phenotypes,]
study_units <- study_units[order(study_units$Phenotype_ID, study_units$Study_ID),]

if (nrow(study_units) < 2) {
  stop("Need at least two eligible study-phenotype units for validation.")
}

# Build a dense module-module similarity matrix for modules present in eligible units.
module_ids <- sort(unique(unlist(strsplit(study_units$Module_IDs, "; ", fixed = TRUE), use.names = FALSE)))
module_index <- seq_along(module_ids)
names(module_index) <- module_ids

module_similarity_matrix <- matrix(
  missing_module_similarity,
  nrow = length(module_ids),
  ncol = length(module_ids),
  dimnames = list(module_ids, module_ids)
)
diag(module_similarity_matrix) <- 1

module_sim <- module_sim[
  module_sim[[":START_ID"]] %in% module_ids &
    module_sim[[":END_ID"]] %in% module_ids,
]
module_sim$Similarity_Score <- as.numeric(module_sim$Similarity_Score)
module_sim <- module_sim[!is.na(module_sim$Similarity_Score),]

if (nrow(module_sim) > 0) {
  start_i <- module_index[module_sim[[":START_ID"]]]
  end_i <- module_index[module_sim[[":END_ID"]]]
  module_similarity_matrix[cbind(start_i, end_i)] <- module_sim$Similarity_Score
  module_similarity_matrix[cbind(end_i, start_i)] <- module_sim$Similarity_Score
}

unit_modules <- strsplit(study_units$Module_IDs, "; ", fixed = TRUE)
names(unit_modules) <- study_units$Unit_ID

# Build all cross-unit pairs among eligible study-phenotype units.
pair_index <- utils::combn(seq_len(nrow(study_units)), 2)
pair_rows <- vector("list", ncol(pair_index))

for (idx in seq_len(ncol(pair_index))) {
  i <- pair_index[1, idx]
  j <- pair_index[2, idx]
  unit_i <- study_units[i,]
  unit_j <- study_units[j,]

  same_phenotype <- unit_i$Phenotype_ID == unit_j$Phenotype_ID
  same_study <- unit_i$Study_ID == unit_j$Study_ID

  pair_rows[[idx]] <- data.frame(
    Unit_ID_1 = unit_i$Unit_ID,
    Phenotype_ID_1 = unit_i$Phenotype_ID,
    Phenotype_1 = unit_i$Phenotype,
    Phenotype_Type_1 = unit_i$Phenotype_Type,
    Study_ID_1 = unit_i$Study_ID,
    Module_N_1 = unit_i$Module_N,
    Unit_ID_2 = unit_j$Unit_ID,
    Phenotype_ID_2 = unit_j$Phenotype_ID,
    Phenotype_2 = unit_j$Phenotype,
    Phenotype_Type_2 = unit_j$Phenotype_Type,
    Study_ID_2 = unit_j$Study_ID,
    Module_N_2 = unit_j$Module_N,
    Same_Phenotype = same_phenotype,
    Same_Study = same_study,
    Study_Level_BMA_Similarity = bma_similarity(
      unit_modules[[unit_i$Unit_ID]],
      unit_modules[[unit_j$Unit_ID]],
      module_similarity_matrix
    ),
    stringsAsFactors = FALSE
  )
}

pair_table <- do.call(rbind, pair_rows)

# Positive pairs are independent studies mapped to the same phenotype.
# Negative pairs are independent studies mapped to different phenotypes by default.
pair_table <- pair_table[
  pair_table$Same_Phenotype |
    (!pair_table$Same_Phenotype & (!exclude_same_study_negative_pairs | !pair_table$Same_Study)),
  ,
]

if (!is.na(max_different_phenotype_pairs)) {
  same_rows <- pair_table[pair_table$Same_Phenotype,]
  different_rows <- pair_table[!pair_table$Same_Phenotype,]
  if (nrow(different_rows) > max_different_phenotype_pairs) {
    different_rows <- different_rows[sample(seq_len(nrow(different_rows)), max_different_phenotype_pairs),]
  }
  pair_table <- rbind(same_rows, different_rows)
  pair_table <- pair_table[order(pair_table$Same_Phenotype, decreasing = TRUE),]
}

same_values <- pair_table$Study_Level_BMA_Similarity[pair_table$Same_Phenotype]
different_values <- pair_table$Study_Level_BMA_Similarity[!pair_table$Same_Phenotype]

if (length(same_values) == 0 || length(different_values) == 0) {
  stop("Need at least one same-phenotype pair and one different-phenotype pair.")
}

wilcox_result <- wilcox.test(
  same_values,
  different_values,
  alternative = "greater",
  exact = FALSE
)

summary_table <- data.frame(
  Test = "Wilcoxon rank-sum",
  Unit = "study-phenotype module set",
  Alternative = "same-phenotype cross-study similarity is greater than different-phenotype cross-study similarity",
  Eligible_Phenotype_N = length(unique(study_units$Phenotype_ID)),
  Eligible_Study_Phenotype_Unit_N = nrow(study_units),
  Same_Phenotype_Pair_N = length(same_values),
  Different_Phenotype_Pair_N = length(different_values),
  Same_Phenotype_Mean = mean(same_values),
  Same_Phenotype_Median = median(same_values),
  Same_Phenotype_Q1 = as.numeric(quantile(same_values, 0.25)),
  Same_Phenotype_Q3 = as.numeric(quantile(same_values, 0.75)),
  Different_Phenotype_Mean = mean(different_values),
  Different_Phenotype_Median = median(different_values),
  Different_Phenotype_Q1 = as.numeric(quantile(different_values, 0.25)),
  Different_Phenotype_Q3 = as.numeric(quantile(different_values, 0.75)),
  Median_Difference = median(same_values) - median(different_values),
  Mean_Difference = mean(same_values) - mean(different_values),
  AUC_Same_Greater_Than_Different = auc_from_values(same_values, different_values),
  Wilcoxon_W = unname(wilcox_result$statistic),
  P_Value = wilcox_result$p.value,
  stringsAsFactors = FALSE
)

phenotype_rows <- data.frame()
for (phenotype_id in sort(unique(study_units$Phenotype_ID))) {
  units <- study_units[study_units$Phenotype_ID == phenotype_id,]
  internal_pairs <- pair_table[pair_table$Same_Phenotype & pair_table$Phenotype_ID_1 == phenotype_id,]
  info <- units[1,]

  phenotype_rows <- rbind(
    phenotype_rows,
    data.frame(
      Phenotype_ID = phenotype_id,
      Phenotype = info$Phenotype,
      Phenotype_Type = info$Phenotype_Type,
      OLS_ID = info$OLS_ID,
      Study_N = length(unique(units$Study_ID)),
      Study_Phenotype_Unit_N = nrow(units),
      Module_N_Total = length(unique(unlist(strsplit(units$Module_IDs, "; ", fixed = TRUE), use.names = FALSE))),
      Same_Phenotype_Pair_N = nrow(internal_pairs),
      Mean_Study_Level_BMA_Similarity = if (nrow(internal_pairs) == 0) NA_real_ else mean(internal_pairs$Study_Level_BMA_Similarity),
      Median_Study_Level_BMA_Similarity = if (nrow(internal_pairs) == 0) NA_real_ else median(internal_pairs$Study_Level_BMA_Similarity),
      stringsAsFactors = FALSE
    )
  )
}
phenotype_rows <- phenotype_rows[order(-phenotype_rows$Study_N, phenotype_rows$Phenotype),]

write.csv(pair_table, pair_output_file, row.names = FALSE)
write.csv(summary_table, summary_output_file, row.names = FALSE)
write.csv(phenotype_rows, phenotype_output_file, row.names = FALSE)

report_lines <- c(
  "Study-level phenotype similarity validation",
  paste0("Input module-phenotype map: ", module_phenotype_file),
  paste0("Input module similarity table: ", module_similarity_file),
  "",
  paste0("Eligible phenotypes with >= ", min_studies_per_phenotype, " studies: ", summary_table$Eligible_Phenotype_N),
  paste0("Eligible study-phenotype units: ", summary_table$Eligible_Study_Phenotype_Unit_N),
  paste0("Same-phenotype cross-study pairs: ", summary_table$Same_Phenotype_Pair_N),
  paste0("Different-phenotype cross-study pairs: ", summary_table$Different_Phenotype_Pair_N),
  "",
  paste0("Same-phenotype median study-level BMA similarity: ", signif(summary_table$Same_Phenotype_Median, 4)),
  paste0("Different-phenotype median study-level BMA similarity: ", signif(summary_table$Different_Phenotype_Median, 4)),
  paste0("Median difference: ", signif(summary_table$Median_Difference, 4)),
  paste0("AUC same > different: ", signif(summary_table$AUC_Same_Greater_Than_Different, 4)),
  "",
  paste0("Wilcoxon W: ", signif(summary_table$Wilcoxon_W, 6)),
  paste0("Wilcoxon p-value: ", signif(summary_table$P_Value, 6)),
  "",
  "Note: study-level pair similarities are not fully independent because each study-phenotype unit appears in multiple pairs.",
  "For final inference, add a phenotype-label permutation test or bootstrap by phenotype/study."
)

writeLines(report_lines, report_output_file)
