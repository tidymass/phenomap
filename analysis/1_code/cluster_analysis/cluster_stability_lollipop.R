suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
})

# Horizontal bar plot of community stability (bootstrap Jaccard similarity).
# White bars with black outline; the top 3 communities are hatched.
# Run from the project root or from analysis/1_code/cluster_analysis.

project_dir <- normalizePath(getwd())
if (!dir.exists(file.path(project_dir, "analysis", "3_result"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", "..", ".."))
}

result_dir <- file.path(project_dir, "analysis", "3_result", "cluster_analysis")
metrics_file <- file.path(result_dir, "cluster_metrics.csv")

jaccard_cutoff <- 0.8

# Data -------------------------------------------------------------------------

top_n_highlight <- 3        # most stable communities drawn with diagonal hatching
bar_width <- 0.68
hatch_spacing <- 0.04       # horizontal spacing between hatch lines (x units)
hatch_slope <- 6            # y units per x unit; ~45 degrees at the saved size

plot_data <- read.csv(metrics_file, check.names = FALSE) %>%
  as_tibble() %>%
  transmute(
    cluster = paste0("C", Cluster),
    jaccard = Bootstrap_Jaccard
  ) %>%
  arrange(jaccard) %>%
  mutate(
    cluster = factor(cluster, levels = cluster),
    y_pos = as.numeric(cluster),
    top = rank(-jaccard, ties.method = "first") <= top_n_highlight
  )

# Diagonal hatch lines, clipped to each highlighted bar
hatch_lines <- plot_data %>%
  filter(top) %>%
  rowwise() %>%
  do({
    b <- .
    y_bottom <- b$y_pos - bar_width / 2
    y_top <- b$y_pos + bar_width / 2
    run <- bar_width / hatch_slope
    x0 <- seq(-run, b$jaccard, by = hatch_spacing)
    x_start <- pmax(x0, 0)
    x_end <- pmin(x0 + run, b$jaccard)
    tibble(
      x = x_start,
      y = y_bottom + hatch_slope * (x_start - x0),
      xend = x_end,
      yend = y_bottom + hatch_slope * (x_end - x0)
    ) %>%
      filter(xend > x)
  }) %>%
  ungroup()

# Plot -------------------------------------------------------------------------

p_bar <- ggplot(plot_data, aes(y = cluster, x = jaccard)) +
  geom_col(
    width = bar_width,
    fill = "white",
    color = NA
  ) +
  geom_segment(
    data = hatch_lines,
    aes(x = x, y = y, xend = xend, yend = yend),
    inherit.aes = FALSE,
    color = "black",
    linewidth = 0.35
  ) +
  geom_col(
    width = bar_width,
    fill = NA,
    color = "black",
    linewidth = 0.45
  ) +
  geom_vline(
    xintercept = jaccard_cutoff,
    linetype = "22",
    linewidth = 0.55,
    color = "#D64541"
  ) +
  scale_x_continuous(
    limits = c(0, 1),
    breaks = seq(0, 1, 0.25),
    expand = expansion(mult = c(0, 0.03))
  ) +
  labs(
    x = "Bootstrap Jaccard similarity",
    y = NULL
  ) +
  theme_classic(base_size = 15) +
  theme(
    legend.position = "none",
    panel.border = element_rect(color = "black", fill = NA, linewidth = 0.75),
    panel.grid = element_blank(),
    axis.line = element_blank(),
    axis.ticks = element_line(linewidth = 0.65, color = "black"),
    axis.text.x = element_text(size = 12, color = "black"),
    axis.text.y = element_text(size = 13, color = "black"),
    axis.title.x = element_text(size = 14, margin = margin(t = 8)),
    plot.margin = margin(10, 14, 10, 8)
  )

print(p_bar)

pdf(
  file.path(result_dir, "cluster_stability_bar.pdf"),
  width = 3.4,
  height = 4.6
)
print(p_bar)
dev.off()
