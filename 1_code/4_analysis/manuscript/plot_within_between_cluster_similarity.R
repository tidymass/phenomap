# Compare phenotype similarities within versus between clusters.
#
# This script uses each unordered phenotype pair once. The primary statistical
# test permutes cluster labels across phenotypes while preserving cluster sizes,
# which retains the dependence structure created by repeated phenotypes across
# pairs. The Wilcoxon rank-sum test is reported only as a familiar supplementary
# analysis because phenotype pairs are not independent observations.
#
# Run from the repository root:
#   Rscript 1_code/4_analysis/manuscript/plot_within_between_cluster_similarity.R
#
# Optional arguments:
#   --input_dir=3_data_analysis/global_high_confidence_phenotype_neighborhood_host_endogenous
#   --output_dir=3_data_analysis/global_high_confidence_phenotype_neighborhood_host_endogenous/within_between_cluster_similarity
#   --n_permutations=10000
#   --seed=2026

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(scales)
})

parse_args <- function() {
  args <- list(
    input_dir = file.path(
      "3_data_analysis",
      "global_high_confidence_phenotype_neighborhood_host_endogenous"
    ),
    output_dir = file.path(
      "3_data_analysis",
      "global_high_confidence_phenotype_neighborhood_host_endogenous",
      "within_between_cluster_similarity"
    ),
    n_permutations = 10000L,
    seed = 2026L
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2L || !kv[[1]] %in% names(args)) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% c("n_permutations", "seed")) value <- as.integer(value)
    args[[key]] <- value
  }
  args
}

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

format_p <- function(p) {
  if (is.na(p)) return("P = NA")
  if (p < 0.0001) return("P < 0.0001")
  paste0("P = ", formatC(p, format = "f", digits = 4))
}

args <- parse_args()
dir.create(args$output_dir, recursive = TRUE, showWarnings = FALSE)

pair_file <- file.path(args$input_dir, "phenotype_similarity_pairs_final.csv")
cluster_file <- file.path(args$input_dir, "phenotype_cluster_assignments.csv")

pairs <- read_csv_required(pair_file)
clusters <- read_csv_required(cluster_file)

required_pair_columns <- c(
  "Phenotype_ID_1", "Phenotype_1", "Phenotype_ID_2", "Phenotype_2", "Similarity"
)
required_cluster_columns <- c("Phenotype_ID", "Cluster")

missing_pair_columns <- setdiff(required_pair_columns, names(pairs))
missing_cluster_columns <- setdiff(required_cluster_columns, names(clusters))
if (length(missing_pair_columns) > 0L) {
  stop("Pair file is missing: ", paste(missing_pair_columns, collapse = ", "))
}
if (length(missing_cluster_columns) > 0L) {
  stop("Cluster file is missing: ", paste(missing_cluster_columns, collapse = ", "))
}

cluster_lookup <- setNames(clusters$Cluster, clusters$Phenotype_ID)

plot_data <- pairs %>%
  transmute(
    Phenotype_ID_1,
    Phenotype_1,
    Cluster_1 = unname(cluster_lookup[Phenotype_ID_1]),
    Phenotype_ID_2,
    Phenotype_2,
    Cluster_2 = unname(cluster_lookup[Phenotype_ID_2]),
    Similarity = as.numeric(Similarity)
  ) %>%
  filter(
    !is.na(Cluster_1),
    !is.na(Cluster_2),
    is.finite(Similarity),
    Phenotype_ID_1 != Phenotype_ID_2
  ) %>%
  distinct(Phenotype_ID_1, Phenotype_ID_2, .keep_all = TRUE) %>%
  mutate(
    Comparison = if_else(
      Cluster_1 == Cluster_2,
      "Within cluster",
      "Between clusters"
    ),
    Comparison = factor(
      Comparison,
      levels = c("Within cluster", "Between clusters")
    )
  ) %>%
  group_by(Comparison) %>%
  mutate(
    Box_Q1 = quantile(Similarity, 0.25),
    Box_Q3 = quantile(Similarity, 0.75),
    Box_IQR = IQR(Similarity),
    Boxplot_Outlier =
      Similarity < Box_Q1 - 1.5 * Box_IQR |
      Similarity > Box_Q3 + 1.5 * Box_IQR
  ) %>%
  ungroup() %>%
  select(-Box_Q1, -Box_Q3, -Box_IQR)

expected_pairs <- nrow(clusters) * (nrow(clusters) - 1L) / 2L
if (nrow(plot_data) != expected_pairs) {
  warning(
    "Expected ", expected_pairs, " unordered phenotype pairs but found ",
    nrow(plot_data), ". Check whether the pair table is complete."
  )
}

if (!all(levels(plot_data$Comparison) %in% unique(as.character(plot_data$Comparison)))) {
  stop("Both within-cluster and between-cluster pairs are required.")
}

write.csv(
  plot_data,
  file.path(args$output_dir, "within_between_similarity_pair_data.csv"),
  row.names = FALSE
)

summary_data <- plot_data %>%
  group_by(Comparison) %>%
  summarise(
    Pair_N = n(),
    Mean = mean(Similarity),
    SD = sd(Similarity),
    Median = median(Similarity),
    Q1 = quantile(Similarity, 0.25),
    Q3 = quantile(Similarity, 0.75),
    IQR = IQR(Similarity),
    .groups = "drop"
  )

write.csv(
  summary_data,
  file.path(args$output_dir, "within_between_similarity_summary.csv"),
  row.names = FALSE
)

# Primary test: shuffle phenotype cluster labels, not individual pair labels.
phenotype_ids <- clusters$Phenotype_ID
observed_labels <- setNames(clusters$Cluster, phenotype_ids)
pair_index_1 <- match(plot_data$Phenotype_ID_1, phenotype_ids)
pair_index_2 <- match(plot_data$Phenotype_ID_2, phenotype_ids)
similarity <- plot_data$Similarity

statistic_from_labels <- function(labels) {
  is_within <- labels[pair_index_1] == labels[pair_index_2]
  c(
    median_difference = median(similarity[is_within]) - median(similarity[!is_within]),
    mean_difference = mean(similarity[is_within]) - mean(similarity[!is_within])
  )
}

observed_statistics <- statistic_from_labels(observed_labels)
set.seed(args$seed)
permuted_statistics <- replicate(
  args$n_permutations,
  statistic_from_labels(sample(observed_labels, replace = FALSE))
)

# Add one to numerator and denominator so a Monte Carlo P value is never zero.
permutation_p_median <- (
  sum(abs(permuted_statistics["median_difference", ]) >=
        abs(observed_statistics[["median_difference"]])) + 1
) / (args$n_permutations + 1)

permutation_p_mean <- (
  sum(abs(permuted_statistics["mean_difference", ]) >=
        abs(observed_statistics[["mean_difference"]])) + 1
) / (args$n_permutations + 1)

wilcox_result <- wilcox.test(
  Similarity ~ Comparison,
  data = plot_data,
  alternative = "two.sided",
  exact = FALSE,
  conf.int = FALSE
)

test_results <- data.frame(
  Test = c(
    "Phenotype-label permutation test: median difference",
    "Phenotype-label permutation test: mean difference",
    "Wilcoxon rank-sum test (supplementary; pairs not independent)"
  ),
  Alternative = rep("two-sided", 3),
  Statistic = c(
    observed_statistics[["median_difference"]],
    observed_statistics[["mean_difference"]],
    unname(wilcox_result$statistic)
  ),
  P_value = c(
    permutation_p_median,
    permutation_p_mean,
    wilcox_result$p.value
  ),
  Permutations = c(args$n_permutations, args$n_permutations, NA_integer_),
  stringsAsFactors = FALSE
)

write.csv(
  test_results,
  file.path(args$output_dir, "within_between_similarity_tests.csv"),
  row.names = FALSE
)

fill_colors <- c(
  "Within cluster" = "#E64B35",
  "Between clusters" = "#00A087"
)

point_data <- plot_data %>%
  filter(!Boxplot_Outlier)

annotation_y <- 0.825
bracket_bottom <- 0.800
p_label <- format_p(wilcox_result$p.value)

p <- ggplot(mapping = aes(y = Similarity)) +
  geom_point(
    data = point_data,
    aes(
      x = as.numeric(Comparison),
      y = Similarity,
      color = Comparison
    ),
    position = position_jitter(width = 0.10, height = 0, seed = args$seed),
    shape = 16,
    size = 1.25,
    stroke = 0,
    alpha = 1,
    inherit.aes = FALSE
  ) +
  geom_boxplot(
    data = plot_data,
    aes(
      x = as.numeric(Comparison),
      y = Similarity,
      group = Comparison
    ),
    width = 0.26,
    linewidth = 0.52,
    color = "black",
    fill = NA,
    outlier.shape = NA,
    inherit.aes = FALSE
  ) +
  annotate(
    "segment",
    x = 1,
    xend = 2,
    y = bracket_bottom,
    yend = bracket_bottom,
    linewidth = 0.55,
    color = "black"
  ) +
  annotate(
    "segment",
    x = c(1, 2),
    xend = c(1, 2),
    y = bracket_bottom,
    yend = bracket_bottom - 0.012,
    linewidth = 0.55,
    color = "black"
  ) +
  annotate(
    "text",
    x = 1.5,
    y = annotation_y,
    label = p_label,
    size = 4.5,
    color = "black"
  ) +
  scale_color_manual(values = fill_colors, guide = "none") +
  scale_x_continuous(
    breaks = c(1, 2),
    labels = c("Within cluster", "Between clusters"),
    limits = c(0.55, 2.45),
    expand = expansion(mult = c(0, 0))
  ) +
  scale_y_continuous(
    breaks = seq(0, 0.8, 0.2),
    minor_breaks = NULL,
    expand = expansion(mult = c(0, 0.01))
  ) +
  coord_cartesian(ylim = c(0, 0.85), clip = "off") +
  labs(
    x = NULL,
    y = "Phenotype similarity"
  ) +
  theme_classic(base_size = 11) +
  theme(
    plot.title = element_blank(),
    legend.position = "none",
    panel.border = element_rect(color = "black", fill = NA, linewidth = 0.6),
    panel.grid.major.y = element_line(color = "grey86", linewidth = 0.25),
    panel.grid.major.x = element_line(color = "grey92", linewidth = 0.25),
    panel.grid.minor = element_blank(),
    axis.line = element_blank(),
    axis.ticks = element_line(linewidth = 0.45, color = "black"),
    axis.text = element_text(size = 10.5, color = "black"),
    axis.title.y = element_text(size = 11, color = "black", margin = margin(r = 7)),
    plot.margin = margin(5, 6, 4, 5)
  )

pdf(
  file.path(args$output_dir, "within_between_cluster_similarity_boxplot.pdf"),
  width = 3.5,
  height = 3.4,
  useDingbats = FALSE
)
print(p)
dev.off()

message("Saved outputs to: ", args$output_dir)
message("Primary test: two-sided phenotype-label permutation test.")
message("Observed median difference (within - between): ",
        signif(observed_statistics[["median_difference"]], 4))
message("Permutation ", format_p(permutation_p_median))
message("Direct two-sided Wilcoxon ", format_p(wilcox_result$p.value),
        " (displayed in the figure).")
message(
  "Interpretation note: clusters were derived from the same similarity matrix, ",
  "so this test quantifies internal cluster separation rather than independent validation."
)
