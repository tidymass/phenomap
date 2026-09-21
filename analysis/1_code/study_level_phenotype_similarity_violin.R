suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(ggpubr)
})

# Within- vs between-phenotype study-level BMA similarity (violin plot).
# Run from the project root or from analysis/1_code.

project_dir <- normalizePath(getwd())
if (!dir.exists(file.path(project_dir, "analysis", "3_result"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", ".."))
}

result_dir <- file.path(project_dir, "analysis", "3_result", "cross_study_similarity")
pair_file <- file.path(result_dir, "study_level_phenotype_similarity_validation_pairs.csv")

# Data -------------------------------------------------------------------------

plot_data <- read.csv(pair_file, check.names = FALSE) %>%
  as_tibble() %>%
  transmute(
    group = if_else(as.logical(Same_Phenotype), "Within", "Between"),
    group = factor(group, levels = c("Within", "Between")),
    similarity = Study_Level_BMA_Similarity
  ) %>%
  filter(!is.na(similarity))

# One-sided Wilcoxon rank-sum test (within > between), as in the validation script
p_value <- wilcox.test(
  plot_data$similarity[plot_data$group == "Within"],
  plot_data$similarity[plot_data$group == "Between"],
  alternative = "greater",
  exact = FALSE
)$p.value

p_label <- if (p_value < 1e-4) "p < 0.0001" else paste0("p = ", signif(p_value, 2))

ymax <- max(plot_data$similarity, na.rm = TRUE)

stat_df <- tibble(
  group1 = "Within",
  group2 = "Between",
  y.position = ymax + 0.07,
  label = p_label
)

# Plot -------------------------------------------------------------------------

group_fill <- c(
  Within = "#A07BBF",
  Between = "#DAD4DF"
)

p_violin <- ggplot(
  plot_data,
  aes(x = group, y = similarity, fill = group)
) +
  geom_violin(
    width = 0.78,
    linewidth = 0.38,
    color = "black",
    scale = "width",
    trim = TRUE
  ) +
  geom_boxplot(
    width = 0.14,
    linewidth = 0.3,
    outlier.shape = NA,
    fill = "white",
    color = "black"
  ) +
  stat_summary(
    fun = median,
    geom = "crossbar",
    width = 0.22,
    linewidth = 0.28,
    color = "black"
  ) +
  stat_pvalue_manual(
    stat_df,
    label = "label",
    tip.length = 0,
    bracket.size = 0.35,
    size = 4.6
  ) +
  scale_fill_manual(values = group_fill, guide = "none") +
  scale_x_discrete(
    labels = c(Within = "Within\nphenotype", Between = "Between\nphenotypes")
  ) +
  scale_y_continuous(
    breaks = seq(0, 1, 0.25),
    minor_breaks = NULL,
    expand = expansion(mult = c(0.02, 0.12))
  ) +
  coord_cartesian(
    ylim = c(0, ymax + 0.12),
    clip = "off"
  ) +
  labs(
    x = NULL,
    y = "Study-level BMA similarity"
  ) +
  theme_classic(base_size = 15) +
  theme(
    legend.position = "none",
    aspect.ratio = 1,
    panel.border = element_blank(),
    panel.grid.major.y = element_blank(),
    panel.grid.minor.y = element_blank(),
    panel.grid.major.x = element_blank(),
    axis.line = element_line(linewidth = 0.65, color = "black"),
    axis.ticks = element_line(linewidth = 0.65, color = "black"),
    axis.text.x = element_text(size = 13, color = "black", lineheight = 0.9),
    axis.text.y = element_text(size = 12, color = "black"),
    axis.title.y = element_text(size = 14, margin = margin(r = 10)),
    plot.margin = margin(10, 12, 10, 8)
  )

print(p_violin)

pdf(
  file.path(result_dir, "study_level_phenotype_similarity_violin.pdf"),
  width = 4.2,
  height = 4.2
)
print(p_violin)
dev.off()
