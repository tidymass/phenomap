suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(ggpubr)
})

# BMA similarity of disease pairs with vs without a CTD-derived shared
# mechanism (KEGG pathway terms only), shown as a violin plot.
# Run from the project root or from analysis/1_code.

project_dir <- normalizePath(getwd())
if (!dir.exists(file.path(project_dir, "analysis", "3_result"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", ".."))
}

result_dir <- file.path(project_dir, "analysis", "3_result", "CTD_class")
pair_file <- file.path(result_dir, "disease_similarity_ctd_shared_mechanism_pairs.csv")

# KEGG pathway terms only
term_set_to_plot <- "kegg_only"

# Data -------------------------------------------------------------------------

plot_data <- read.csv(pair_file, check.names = FALSE) %>%
  as_tibble() %>%
  filter(CTD_Term_Set == term_set_to_plot) %>%
  transmute(
    group = if_else(as.logical(Shared_Metabolic_Mechanism), "Shared", "Nonshared"),
    group = factor(group, levels = c("Shared", "Nonshared")),
    similarity = BMA_Similarity
  ) %>%
  filter(!is.na(similarity))

# One-sided Wilcoxon rank-sum test (shared > non-shared), as in the main analysis
p_value <- wilcox.test(
  plot_data$similarity[plot_data$group == "Shared"],
  plot_data$similarity[plot_data$group == "Nonshared"],
  alternative = "greater",
  exact = FALSE
)$p.value

p_label <- if (p_value < 1e-4) "p < 0.0001" else paste0("p = ", signif(p_value, 2))

ymax <- max(plot_data$similarity, na.rm = TRUE)

stat_df <- tibble(
  group1 = "Shared",
  group2 = "Nonshared",
  y.position = ymax + 0.07,
  label = p_label
)

# Plot -------------------------------------------------------------------------

# Teal from the Study quadrant of the main figure; pale teal-grey as background
group_fill <- c(
  Shared = "#5BB5A2",
  Nonshared = "#D5E4DF"
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
    labels = c(Shared = "Shared\nmechanism", Nonshared = "Non-shared\nmechanism")
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
    y = "Disease BMA similarity"
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
  file.path(result_dir, "disease_similarity_ctd_shared_mechanism_violin_kegg.pdf"),
  width = 4.2,
  height = 4.2
)
print(p_violin)
dev.off()
