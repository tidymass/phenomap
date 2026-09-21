suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(igraph)
  library(readxl)
  library(ggrepel)
})

# Case-study communities drawn side by side in one figure with a shared legend.
#   Node colour = phenotype type
#   Edge width  = PhenoMAP BMA similarity
#   Edge type   = literature support: solid = Direct, dashed = Indirect
# Run from the project root or from analysis/1_code/case_study.

case_clusters <- c(7, 9, 5)     # drawn left to right
panel_gap <- 1.0                # blank space between clusters (layout units)
layout_seed <- 20260919

project_dir <- normalizePath(getwd())
if (!dir.exists(file.path(project_dir, "analysis", "3_result"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", "..", ".."))
}

result_dir <- file.path(project_dir, "analysis", "3_result")
members_file <- file.path(result_dir, "cluster_analysis", "community_members.csv")
out_file <- file.path(result_dir, "case_study", "case_clusters_network.pdf")

# Style ------------------------------------------------------------------------

type_labels <- c(
  disease = "Disease",
  exposure = "Exposure",
  chemical = "Chemical",
  intervention = "Intervention",
  trait = "Trait",
  biological_process = "Biological process",
  cell_type_or_line = "Cell type/line",
  genetic_perturbation = "Genetic perturbation",
  symptom = "Symptom"
)

type_fill <- c(
  disease = "#A07BBF",
  exposure = "#5BB5A2",
  chemical = "#E8896B",
  intervention = "#D9B26F",
  trait = "#E7A9C4",
  biological_process = "#6FA3D2",
  cell_type_or_line = "#9C8A7A",
  genetic_perturbation = "#4E6E9E",
  symptom = "#B7B7B7"
)

edge_color <- "#8F8F8F"
node_size <- 7

# Data -------------------------------------------------------------------------

all_members <- read.csv(members_file, check.names = FALSE) %>% as_tibble()

is_yes <- function(x) toupper(trimws(coalesce(as.character(x), ""))) == "YES"

read_cluster <- function(cluster_id) {
  nodes <- all_members %>%
    filter(Community == cluster_id) %>%
    transmute(
      cluster = cluster_id,
      id = Phenotype_ID,
      name = Phenotype,
      type = factor(Phenotype_Type, levels = names(type_labels))
    )

  scoring_file <- file.path(
    result_dir, "case_study", paste0("cluster_", cluster_id),
    paste0("cluster_", cluster_id, "_edge_evidence_scoring.xlsx")
  )

  edges <- read_excel(scoring_file, sheet = 1) %>%
    filter(!is.na(`Edge ID`), trimws(`Edge ID`) != "") %>%
    mutate(
      cluster = cluster_id,
      from = sapply(strsplit(`Edge ID`, "__", fixed = TRUE), `[`, 2),
      to = sapply(strsplit(`Edge ID`, "__", fixed = TRUE), `[`, 3),
      bma = as.numeric(`PhenoMAP BMA`),
      class = factor(trimws(`Final class`), levels = c("Direct", "Indirect"))
    ) %>%
    filter(from %in% nodes$id, to %in% nodes$id, !is.na(class)) %>%
    select(cluster, from, to, bma, class)

  list(nodes = nodes, edges = edges)
}

# Layout: force-directed per cluster, scaled to [-1, 1], then shifted right ------

layout_cluster <- function(cl, offset_x) {
  g <- graph_from_data_frame(
    cl$edges %>% transmute(from, to, weight = bma),
    directed = FALSE,
    vertices = cl$nodes %>% select(id)
  )
  set.seed(layout_seed)
  xy <- layout_with_fr(g, weights = E(g)$weight, niter = 3000)
  xy <- apply(xy, 2, function(v) (v - min(v)) / (max(v) - min(v)) * 2 - 1)
  cl$nodes %>%
    mutate(
      x = xy[match(id, V(g)$name), 1] + offset_x,
      y = xy[match(id, V(g)$name), 2]
    )
}

clusters <- lapply(case_clusters, read_cluster)
offsets <- (seq_along(case_clusters) - 1) * (2 + panel_gap)

node_xy <- bind_rows(Map(layout_cluster, clusters, offsets))
edges <- bind_rows(lapply(clusters, `[[`, "edges"))

edge_xy <- edges %>%
  left_join(node_xy %>% select(id, x, y), by = c("from" = "id")) %>%
  left_join(node_xy %>% select(id, xend = x, yend = y), by = c("to" = "id")) %>%
  arrange(class, desc(bma))   # dashed edges drawn last so they stay visible

cluster_titles <- tibble(
  label = paste0("C", case_clusters),
  x = offsets,
  y = 1.32
)

# Plot -------------------------------------------------------------------------

p_network <- ggplot() +
  geom_segment(
    data = edge_xy,
    aes(x = x, y = y, xend = xend, yend = yend, linewidth = bma, linetype = class),
    color = edge_color,
    alpha = 0.85,
    lineend = "butt"
  ) +
  geom_point(
    data = node_xy,
    aes(x = x, y = y, fill = type),
    shape = 21,
    size = node_size,
    stroke = 0.5,
    color = "black"
  ) +
  geom_text_repel(
    data = node_xy,
    aes(x = x, y = y, label = name),
    size = 3.9,
    color = "black",
    point.size = node_size,
    box.padding = 0.45,
    min.segment.length = Inf,
    max.overlaps = Inf,
    seed = layout_seed
  ) +
  geom_text(
    data = cluster_titles,
    aes(x = x, y = y, label = label),
    size = 5.2,
    fontface = "bold",
    color = "black"
  ) +
  scale_fill_manual(
    values = type_fill,
    labels = type_labels,
    drop = TRUE,
    name = "Phenotype type",
    guide = guide_legend(order = 1, override.aes = list(size = 4.5))
  ) +
  scale_linewidth_continuous(
    range = c(0.6, 1.4),
    name = "BMA similarity",
    guide = guide_legend(order = 2, override.aes = list(color = edge_color))
  ) +
  scale_linetype_manual(
    values = c(Direct = "solid", Indirect = "22"),
    labels = c(Direct = "Direct evidence", Indirect = "Indirect evidence"),
    drop = TRUE,
    name = "Literature support",
    guide = guide_legend(order = 3, override.aes = list(color = edge_color, linewidth = 0.9))
  ) +
  scale_x_continuous(expand = expansion(mult = 0.06)) +
  scale_y_continuous(expand = expansion(mult = 0.1)) +
  coord_fixed(clip = "off") +
  theme_void(base_size = 15) +
  theme(
    legend.position = "bottom",
    legend.box = "horizontal",
    legend.title = element_text(size = 11, color = "black"),
    legend.text = element_text(size = 11, color = "black"),
    legend.key.width = unit(0.9, "cm"),
    plot.margin = margin(10, 12, 10, 12)
  )

print(p_network)

pdf(out_file, width = 13, height = 5.6)
print(p_network)
dev.off()
