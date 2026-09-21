suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(igraph)
})

# Community-level overview (meta-network).
#   Node  = one community; pie = phenotype-type composition;
#           pie area proportional to the number of phenotypes.
#   Edge  = number of phenotype pairs between two communities whose BMA is at
#           or above the phenotype-network cutoff (95th percentile of all
#           pairwise BMA, the same cutoff used for community detection).
#   Layout = force-directed on the between-community mean BMA.
# Run from the project root or from analysis/1_code/cluster_analysis.

project_dir <- normalizePath(getwd())
if (!dir.exists(file.path(project_dir, "analysis", "3_result"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", "..", ".."))
}

result_dir <- file.path(project_dir, "analysis", "3_result")
cluster_dir <- file.path(result_dir, "cluster_analysis")
members_file <- file.path(cluster_dir, "community_members.csv")
similarity_file <- file.path(result_dir, "phenotype_similarity_matrix.csv")

edge_quantile <- 0.95       # phenotype-level network cutoff (same as community detection)
min_edge_count <- 1         # draw community pairs with at least this many network edges
pie_radius_max <- 0.16      # radius of the largest community (layout spans -1..1)

# Data -------------------------------------------------------------------------

members <- read.csv(members_file, check.names = FALSE) %>%
  as_tibble() %>%
  filter(!is.na(Community)) %>%
  transmute(id = Phenotype_ID, community = Community, type = Phenotype_Type)

similarity <- as.matrix(read.csv(similarity_file, row.names = 1, check.names = FALSE))
storage.mode(similarity) <- "double"

communities <- sort(unique(members$community))

community_nodes <- members %>%
  count(community, name = "size") %>%
  mutate(name = paste0("C", community))

# Mean BMA between every pair of communities
community_pairs <- t(combn(communities, 2))
community_edges <- tibble(
  from = community_pairs[, 1],
  to = community_pairs[, 2]
) %>%
  rowwise() %>%
  mutate(
    mean_bma = mean(
      similarity[
        members$id[members$community == from],
        members$id[members$community == to]
      ],
      na.rm = TRUE
    )
  ) %>%
  ungroup()

# Phenotype-level network cutoff and number of network edges between communities
network_cutoff <- as.numeric(quantile(similarity[upper.tri(similarity)], edge_quantile, na.rm = TRUE))

community_edges <- community_edges %>%
  rowwise() %>%
  mutate(
    edge_n = sum(
      similarity[
        members$id[members$community == from],
        members$id[members$community == to]
      ] >= network_cutoff,
      na.rm = TRUE
    )
  ) %>%
  ungroup()

# Layout (force-directed on all community pairs) --------------------------------

g <- graph_from_data_frame(
  community_edges %>% transmute(from = as.character(from), to = as.character(to), weight = mean_bma),
  directed = FALSE,
  vertices = tibble(name = as.character(communities))
)

set.seed(20260921)
layout_xy <- layout_with_fr(g, weights = E(g)$weight, niter = 3000)
layout_xy <- apply(layout_xy, 2, function(v) (v - min(v)) / (max(v) - min(v)) * 2 - 1)

community_nodes <- community_nodes %>%
  mutate(
    x = layout_xy[match(as.character(community), V(g)$name), 1],
    y = layout_xy[match(as.character(community), V(g)$name), 2],
    r = pie_radius_max * sqrt(size / max(size))
  )

edge_xy <- community_edges %>%
  filter(edge_n >= min_edge_count) %>%
  left_join(community_nodes %>% select(community, x, y), by = c("from" = "community")) %>%
  left_join(community_nodes %>% select(community, xend = x, yend = y), by = c("to" = "community")) %>%
  arrange(edge_n)

# Pie wedges drawn as polygons ------------------------------------------------

type_levels <- c(
  "disease", "exposure", "chemical", "intervention", "trait",
  "biological_process", "cell_type_or_line", "genetic_perturbation", "symptom"
)

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

# Same type colours as the case-study networks
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

wedges <- members %>%
  mutate(type = factor(type, levels = type_levels)) %>%
  count(community, type) %>%
  group_by(community) %>%
  mutate(
    end = 2 * pi * cumsum(n) / sum(n),
    start = lag(end, default = 0)
  ) %>%
  ungroup() %>%
  left_join(community_nodes %>% select(community, x, y, r), by = "community")

wedge_polygons <- wedges %>%
  rowwise() %>%
  do({
    w <- .
    theta <- seq(w$start, w$end, length.out = max(3, ceiling(60 * (w$end - w$start) / (2 * pi))))
    tibble(
      community = w$community,
      type = w$type,
      wedge = paste(w$community, w$type),
      px = c(w$x, w$x + w$r * sin(theta)),
      py = c(w$y, w$y + w$r * cos(theta))
    )
  }) %>%
  ungroup()

outlines <- community_nodes %>%
  rowwise() %>%
  do({
    n <- .
    theta <- seq(0, 2 * pi, length.out = 120)
    tibble(community = n$community, px = n$x + n$r * sin(theta), py = n$y + n$r * cos(theta))
  }) %>%
  ungroup()

# Size key (drawn in data units, so the circles match the pies exactly) --------

size_breaks <- sort(unique(c(
  min(community_nodes$size),
  round(mean(range(community_nodes$size))),
  max(community_nodes$size)
)))

key_x <- max(community_nodes$x + community_nodes$r) + 0.35
key_r <- pie_radius_max * sqrt(size_breaks / max(community_nodes$size))
key_gap <- 0.08
key_y_top <- min(community_nodes$y) + sum(2 * key_r + key_gap) + 0.1

size_key <- tibble(size = size_breaks, r = key_r) %>%
  mutate(
    y = key_y_top - cumsum(2 * r + key_gap) + r,
    x = key_x
  )

size_key_circles <- size_key %>%
  rowwise() %>%
  do({
    k <- .
    theta <- seq(0, 2 * pi, length.out = 120)
    tibble(size = k$size, px = k$x + k$r * sin(theta), py = k$y + k$r * cos(theta))
  }) %>%
  ungroup()

size_key_title <- tibble(
  x = key_x - pie_radius_max,
  y = key_y_top + 0.06,
  label = "Phenotypes"
)

# Plot -------------------------------------------------------------------------

p_overview <- ggplot() +
  geom_segment(
    data = edge_xy,
    aes(x = x, y = y, xend = xend, yend = yend, linewidth = edge_n),
    color = "#8F8F8F",
    alpha = 0.75,
    lineend = "round"
  ) +
  geom_polygon(
    data = wedge_polygons,
    aes(x = px, y = py, group = wedge, fill = type),
    color = "white",
    linewidth = 0.3,
    show.legend = FALSE
  ) +
  # invisible points: only used to draw a circular legend key for phenotype type
  geom_point(
    data = wedges,
    aes(x = x, y = y, fill = type),
    shape = 21,
    alpha = 0
  ) +
  geom_path(
    data = outlines,
    aes(x = px, y = py, group = community),
    color = "black",
    linewidth = 0.4
  ) +
  geom_text(
    data = community_nodes,
    aes(x = x, y = y - r - 0.06, label = name),
    size = 4.4,
    vjust = 1,
    color = "black"
  ) +
  geom_polygon(
    data = size_key_circles,
    aes(x = px, y = py, group = size),
    fill = "grey88",
    color = "black",
    linewidth = 0.4
  ) +
  geom_text(
    data = size_key,
    aes(x = x + pie_radius_max + 0.06, y = y, label = size),
    hjust = 0,
    size = 3.9,
    color = "black"
  ) +
  geom_text(
    data = size_key_title,
    aes(x = x, y = y, label = label),
    hjust = 0,
    vjust = 0,
    size = 3.9,
    color = "black"
  ) +
  scale_fill_manual(
    values = type_fill,
    labels = type_labels,
    drop = TRUE,
    name = NULL,
    guide = guide_legend(
      order = 1,
      override.aes = list(alpha = 1, size = 4.5, shape = 21, color = "black", stroke = 0.4)
    )
  ) +
  scale_linewidth_continuous(
    range = c(0.4, 1.8),
    name = "Inter-cluster links",
    breaks = function(lim) unique(round(seq(max(1, lim[1]), lim[2], length.out = 4))),
    guide = guide_legend(order = 2, override.aes = list(color = "#8F8F8F"))
  ) +
  scale_x_continuous(expand = expansion(mult = 0.12)) +
  scale_y_continuous(expand = expansion(mult = 0.14)) +
  coord_fixed(clip = "off") +
  theme_void(base_size = 15) +
  theme(
    legend.position = "right",
    legend.text = element_text(size = 11, color = "black"),
    legend.title = element_text(size = 11, color = "black"),
    legend.key.size = unit(0.45, "cm"),
    plot.margin = margin(10, 12, 10, 12)
  )

print(p_overview)

pdf(
  file.path(cluster_dir, "community_overview_metanetwork.pdf"),
  width = 7,
  height = 4.6
)
print(p_overview)
dev.off()
