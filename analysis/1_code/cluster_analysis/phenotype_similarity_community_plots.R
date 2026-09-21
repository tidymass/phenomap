project_dir <- normalizePath(getwd())
if (!file.exists(file.path(project_dir, "analysis", "3_result", "phenotype_similarity_matrix.csv"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", "..", ".."))
}

# Heatmap and network for the consensus-Louvain communities.
#
# The plot body is identical to analysis/1_code/phenotype_similarity_plots.R:
# same phenotype-type palette, same heatmap colour ramp, one type-annotation
# strip on the top and one on the left, phenotype names on the left axis and
# along the bottom, same two-level network layout.
#
# Only three things differ:
#   1. Blocks are COMMUNITIES from phenotype_similarity_community_detection.R,
#      not Ward k = 12 clusters.
#   2. Every phenotype that entered the analysis is drawn, including the ones
#      community detection left unassigned. They form a final block in the
#      heatmap, drawn with a dashed thin border, and a peripheral group in the
#      network drawn exactly like every other node.
#   3. The network edge cutoff comes from the same quantile that built the
#      communities, so the edges drawn are the edges the communities were
#      detected on rather than a separate threshold.

data_dir <- file.path(project_dir, "analysis", "2_data")
source_result_dir <- file.path(project_dir, "analysis", "3_result")
result_dir <- file.path(source_result_dir, "cluster_analysis")
dir.create(result_dir, showWarnings = FALSE, recursive = TRUE)

matrix_file <- file.path(source_result_dir, "phenotype_similarity_matrix.csv")
phenotype_count_file <- file.path(data_dir, "phenotype_module_count.csv")
community_members_file <- file.path(result_dir, "community_members.csv")
community_stability_file <- file.path(result_dir, "community_stability.csv")

heatmap_output <- file.path(result_dir, "phenotype_similarity_community_heatmap.pdf")
network_output <- file.path(result_dir, "phenotype_similarity_community_network.pdf")
network_edge_output <- file.path(result_dir, "phenotype_similarity_community_network_edges.csv")
network_node_output <- file.path(result_dir, "phenotype_similarity_community_network_nodes.csv")

# ------------------------------------------------------------------ settings ----

edge_quantile <- 0.95        # matches the chosen community-detection setting
order_communities_by <- "stability"   # "stability" | "size"
within_block_order <- "hclust"        # "hclust" | "module_n"
cluster_method <- "ward.D2"

# Network compactness. Lower values pull the picture in; raise them if labels
# start colliding.
group_spread <- 1.05         # how far apart community centres are placed
group_packing <- 0.42        # collision target between communities
local_spread <- 1.10         # size of each community's internal layout
plot_padding <- 0.07         # margin around the drawn layout

# Network canvas and mark sizes. plot.igraph is called with asp = 0, so the
# layout stretches to fill the device: narrowing pdf_width narrows the picture
# directly, without distorting the force-directed layout itself.
pdf_width <- 10
pdf_height <- 8
vertex_size <- 5.5
node_label_cex <- 0.56
group_label_cex <- 0.95
legend_cex <- 0.95

set.seed(20260916)

# ---------------------------------------------------------------------- load ----

similarity_matrix <- as.matrix(read.csv(matrix_file, row.names = 1, check.names = FALSE))
storage.mode(similarity_matrix) <- "double"
phenotype_ids <- rownames(similarity_matrix)

phenotype_info <- read.csv(phenotype_count_file, stringsAsFactors = FALSE, check.names = FALSE)
phenotype_info <- phenotype_info[match(phenotype_ids, phenotype_info$Phenotype_ID), ]

members <- read.csv(community_members_file, stringsAsFactors = FALSE, check.names = FALSE)
stability <- read.csv(community_stability_file, stringsAsFactors = FALSE, check.names = FALSE)

community_of <- setNames(
  suppressWarnings(as.integer(members$Community)),
  members$Phenotype_ID
)
community_of[is.na(community_of)] <- 0L
phenotype_info$Community <- community_of[phenotype_info$Phenotype_ID]
phenotype_info$Community[is.na(phenotype_info$Community)] <- 0L

stability_of <- setNames(
  as.numeric(stability$Bootstrap_Jaccard),
  as.character(stability$Community)
)

message("Phenotypes drawn: ", length(phenotype_ids),
        "   in a community: ", sum(phenotype_info$Community > 0),
        "   unassigned: ", sum(phenotype_info$Community == 0))

# Phenotype-type palette, identical to phenotype_similarity_plots.R
type_colors <- c(
  biological_process = "#E64B35",
  cell_type_or_line = "#7E6148",
  chemical = "#F6C300",
  disease = "#00A679",
  exposure = "#00A6D6",
  genetic_perturbation = "#3B5B92",
  intervention = "#6A51A3",
  trait = "#D84B9B"
)
missing_types <- setdiff(unique(phenotype_info$Phenotype_Type), names(type_colors))
if (length(missing_types) > 0) {
  extra_colors <- grDevices::rainbow(length(missing_types), s = 0.55, v = 0.75)
  names(extra_colors) <- missing_types
  type_colors <- c(type_colors, extra_colors)
}
type_labels <- gsub("_", " ", names(type_colors))
names(type_labels) <- names(type_colors)

# ----------------------------------------------------------- ordering blocks ----

community_ids <- sort(unique(phenotype_info$Community[phenotype_info$Community > 0]))

block_order <- function(ids) {
  if (length(ids) <= 2) return(ids)
  if (within_block_order == "module_n") {
    return(ids[order(-phenotype_info$Module_N[match(ids, phenotype_info$Phenotype_ID)])])
  }
  sub <- similarity_matrix[ids, ids, drop = FALSE]
  d <- 1 - sub
  d[d < 0] <- 0
  d[d > 1] <- 1
  diag(d) <- 0
  tree <- hclust(as.dist(d), method = cluster_method)
  ids[tree$order]
}

if (order_communities_by == "size") {
  community_sequence <- community_ids[order(
    -vapply(community_ids, function(c) sum(phenotype_info$Community == c), integer(1))
  )]
} else {
  community_sequence <- community_ids[order(-stability_of[as.character(community_ids)])]
}

ordered_ids <- unlist(lapply(
  community_sequence,
  function(c) block_order(phenotype_info$Phenotype_ID[phenotype_info$Community == c])
), use.names = FALSE)
ordered_ids <- c(
  ordered_ids,
  block_order(phenotype_info$Phenotype_ID[phenotype_info$Community == 0])
)
stopifnot(length(ordered_ids) == length(phenotype_ids))

plot_matrix <- similarity_matrix[ordered_ids, ordered_ids]
ordered_info <- phenotype_info[match(ordered_ids, phenotype_info$Phenotype_ID), ]
plot_labels <- ordered_info$Phenotype
long <- nchar(plot_labels) > 42
plot_labels[long] <- paste0(substr(plot_labels[long], 1, 39), "...")

# ------------------------------------------------------------------- heatmap ----

n <- nrow(plot_matrix)
heat_cols <- colorRampPalette(
  c("#ffffff", "#e8f1f3", "#b9d7dc", "#6aa3ad", "#1e4154", "#101b33")
)(120)

pdf(heatmap_output, width = 20, height = 20, useDingbats = FALSE)
# The right margin has to hold the type legend and the colour bar. The
# original 8 lines was narrower than the legend itself, so the legend was
# being drawn off the edge of the page.
par(mar = c(22, 28, 4, 20), xpd = NA, pty = "s")

image(
  x = seq_len(n),
  y = seq_len(n),
  z = t(plot_matrix[, n:1]),
  col = heat_cols,
  zlim = c(0, 1),
  axes = FALSE,
  xlab = "",
  ylab = "",
  main = "Phenotype-phenotype similarity",
  asp = 1
)

box(col = "#444444", lwd = 1.2)
axis(2, at = seq_len(n), labels = rev(plot_labels), las = 1, tick = FALSE, cex.axis = 0.48)
# The type squares sit next to the phenotype names on both axes: below the
# matrix on the x side, left of the matrix on the y side, so each square is
# adjacent to the name it annotates.
points(
  x = seq_len(n),
  y = rep(-0.65, n),
  pch = 15,
  cex = 0.75,
  col = type_colors[ordered_info$Phenotype_Type]
)
points(
  x = rep(-0.65, n),
  y = seq_len(n),
  pch = 15,
  cex = 0.75,
  col = rev(type_colors[ordered_info$Phenotype_Type])
)

text(
  x = seq_len(n),
  y = -1.45,
  labels = plot_labels,
  srt = 90,
  adj = 1,
  cex = 0.46
)

# One box per community, solid; the unassigned block gets a dashed thin border.
block_runs <- rle(ordered_info$Community)
run_ends <- cumsum(block_runs$lengths)
run_starts <- c(1, head(run_ends, -1) + 1)

for (k in seq_along(run_starts)) {
  if (block_runs$lengths[k] <= 1) next
  is_unassigned <- block_runs$values[k] == 0
  rect(
    xleft = run_starts[k] - 0.5,
    ybottom = n - run_ends[k] + 0.5,
    xright = run_ends[k] + 0.5,
    ytop = n - run_starts[k] + 1.5,
    border = if (is_unassigned) "#999999" else "#222222",
    lty = if (is_unassigned) 2 else 1,
    lwd = if (is_unassigned) 0.8 else 1.6
  )
}

# Colour bar for the similarity scale, then the phenotype-type legend below it.
# Both are placed in user coordinates rather than with legend(inset = ...), so
# they land in the right margin predictably whatever the panel size works out to.
bar_left <- n + 8
bar_right <- n + 12
bar_bottom <- n * 0.60
bar_top <- n * 0.95
bar_steps <- length(heat_cols)
bar_edges <- seq(bar_bottom, bar_top, length.out = bar_steps + 1)

rect(
  xleft = bar_left,
  ybottom = bar_edges[-(bar_steps + 1)],
  xright = bar_right,
  ytop = bar_edges[-1],
  col = heat_cols,
  border = NA
)
rect(bar_left, bar_bottom, bar_right, bar_top, border = "#444444", lwd = 0.8)

bar_ticks <- seq(0, 1, by = 0.25)
segments(
  x0 = bar_right,
  y0 = bar_bottom + bar_ticks * (bar_top - bar_bottom),
  x1 = bar_right + 1.2,
  y1 = bar_bottom + bar_ticks * (bar_top - bar_bottom),
  col = "#444444",
  lwd = 0.8
)
text(
  x = bar_right + 2,
  y = bar_bottom + bar_ticks * (bar_top - bar_bottom),
  labels = formatC(bar_ticks, format = "f", digits = 2),
  adj = 0,
  cex = 0.72
)
text(
  x = bar_left,
  y = bar_top + 3,
  labels = "BMA similarity",
  adj = 0,
  cex = 0.80,
  font = 2
)

legend(
  x = bar_left,
  y = n * 0.46,
  legend = type_labels,
  fill = type_colors,
  border = NA,
  bty = "n",
  cex = 0.80,
  title = "Phenotype type",
  title.adj = 0
)

dev.off()
message("Wrote heatmap: ", heatmap_output)

# ------------------------------------------------------------------- network ----

if (!requireNamespace("igraph", quietly = TRUE)) {
  stop("The network plot needs the igraph package. Please install it before running this script.")
}

upper_values <- similarity_matrix[upper.tri(similarity_matrix)]
upper_values <- upper_values[!is.na(upper_values)]
network_similarity_cutoff <- as.numeric(quantile(upper_values, edge_quantile, na.rm = TRUE))
message("Network edge cutoff (quantile ", edge_quantile, "): ",
        signif(network_similarity_cutoff, 4))

upper_index <- which(upper.tri(similarity_matrix), arr.ind = TRUE)
edge_table <- data.frame(
  Phenotype_ID_1 = rownames(similarity_matrix)[upper_index[, 1]],
  Phenotype_ID_2 = rownames(similarity_matrix)[upper_index[, 2]],
  BMA_Similarity = similarity_matrix[upper_index],
  stringsAsFactors = FALSE
)
edge_table <- edge_table[
  !is.na(edge_table$BMA_Similarity) &
    edge_table$BMA_Similarity > network_similarity_cutoff,
]
edge_table <- edge_table[order(-edge_table$BMA_Similarity), ]
edge_table$Community_1 <- phenotype_info$Community[match(edge_table$Phenotype_ID_1, phenotype_info$Phenotype_ID)]
edge_table$Community_2 <- phenotype_info$Community[match(edge_table$Phenotype_ID_2, phenotype_info$Phenotype_ID)]
edge_table$Within_Community <- edge_table$Community_1 == edge_table$Community_2 &
  edge_table$Community_1 > 0
write.csv(edge_table, network_edge_output, row.names = FALSE)

network_nodes <- phenotype_info
network_nodes$name <- network_nodes$Phenotype_ID
network_nodes$label <- vapply(
  network_nodes$Phenotype,
  function(x) paste(strwrap(x, width = 18), collapse = "\n"),
  character(1)
)
network_nodes$Community_Stability <- stability_of[as.character(network_nodes$Community)]
write.csv(
  network_nodes[, c("Phenotype_ID", "Phenotype", "Phenotype_Type", "OLS_ID",
                    "Module_N", "Community", "Community_Stability")],
  network_node_output,
  row.names = FALSE
)

g <- igraph::graph_from_data_frame(
  data.frame(
    from = edge_table$Phenotype_ID_1,
    to = edge_table$Phenotype_ID_2,
    similarity = edge_table$BMA_Similarity,
    stringsAsFactors = FALSE
  ),
  directed = FALSE,
  vertices = network_nodes
)

vertex_type <- igraph::V(g)$Phenotype_Type
vertex_community <- igraph::V(g)$Community
edge_similarity <- igraph::E(g)$similarity

groups <- c(community_sequence, 0)

local_layouts <- vector("list", length(groups))
names(local_layouts) <- as.character(groups)
group_radii <- setNames(numeric(length(groups)), as.character(groups))

for (grp in groups) {
  vids <- which(vertex_community == grp)
  if (length(vids) == 0) {
    local_layouts[[as.character(grp)]] <- matrix(numeric(0), ncol = 2)
    group_radii[as.character(grp)] <- 0
    next
  }
  subg <- igraph::induced_subgraph(g, vids)
  local_layout <- matrix(NA_real_, nrow = length(vids), ncol = 2)

  if (length(vids) == 1) {
    local_layout[, ] <- c(0, 0)
  } else {
    comp <- igraph::components(subg)
    comp_ids <- sort(unique(comp$membership))
    comp_sizes <- as.integer(table(factor(comp$membership, levels = comp_ids)))
    comp_order <- comp_ids[order(comp_sizes, decreasing = TRUE)]

    for (idx in seq_along(comp_order)) {
      comp_vids <- which(comp$membership == comp_order[idx])
      comp_subg <- igraph::induced_subgraph(subg, comp_vids)

      if (length(comp_vids) == 1) {
        comp_layout <- matrix(c(0, 0), ncol = 2)
      } else if (igraph::ecount(comp_subg) > 0) {
        comp_layout <- igraph::layout_with_fr(comp_subg, niter = 2500, grid = "nogrid")
      } else {
        comp_layout <- igraph::layout_in_circle(comp_subg)
      }

      comp_layout <- scale(comp_layout, center = TRUE, scale = FALSE)
      comp_span <- max(diff(range(comp_layout[, 1])), diff(range(comp_layout[, 2])))
      if (comp_span > 0) comp_layout <- comp_layout / comp_span
      comp_layout <- comp_layout * (0.48 + 0.065 * sqrt(length(comp_vids)))

      if (length(comp_order) == 1 || idx == 1) {
        comp_center <- c(0, 0)
      } else {
        angle <- 2 * pi * (idx - 2) / max(1, length(comp_order) - 1) + grp * 0.37
        comp_center <- c(cos(angle), sin(angle)) * (0.92 + 0.050 * sqrt(length(vids)))
      }
      local_layout[comp_vids, ] <- sweep(comp_layout, 2, comp_center, "+")
    }

    local_layout <- scale(local_layout, center = TRUE, scale = FALSE)
    local_span <- max(diff(range(local_layout[, 1])), diff(range(local_layout[, 2])))
    if (local_span > 0) local_layout <- local_layout / local_span
    local_layout <- local_layout * (local_spread + 0.10 * sqrt(length(vids)))
  }

  local_layouts[[as.character(grp)]] <- local_layout
  group_radii[as.character(grp)] <- max(sqrt(rowSums(local_layout^2))) + 0.45
}

edge_ends <- igraph::ends(g, igraph::E(g), names = FALSE)
edge_group_1 <- vertex_community[edge_ends[, 1]]
edge_group_2 <- vertex_community[edge_ends[, 2]]
between_groups <- edge_group_1 != edge_group_2

if (any(between_groups)) {
  group_edge_table <- unique(data.frame(
    from = as.character(pmin(edge_group_1[between_groups], edge_group_2[between_groups])),
    to = as.character(pmax(edge_group_1[between_groups], edge_group_2[between_groups])),
    stringsAsFactors = FALSE
  ))
  group_graph <- igraph::graph_from_data_frame(
    group_edge_table, directed = FALSE,
    vertices = data.frame(name = as.character(groups))
  )
  group_centers <- igraph::layout_with_fr(group_graph, niter = 5000, grid = "nogrid")
} else {
  group_graph <- igraph::make_empty_graph(n = length(groups), directed = FALSE)
  group_centers <- igraph::layout_in_circle(group_graph)
}

group_centers <- scale(group_centers, center = TRUE, scale = FALSE)
group_span <- max(diff(range(group_centers[, 1])), diff(range(group_centers[, 2])))
if (group_span > 0) group_centers <- group_centers / group_span
group_centers <- group_centers * group_spread
rownames(group_centers) <- as.character(groups)

rotation_angle <- pi / 9
rotation_matrix <- matrix(
  c(cos(rotation_angle), sin(rotation_angle), -sin(rotation_angle), cos(rotation_angle)),
  nrow = 2
)
group_centers <- group_centers %*% rotation_matrix
rownames(group_centers) <- as.character(groups)

for (iter in seq_len(650)) {
  for (i in seq_len(length(groups) - 1)) {
    for (j in (i + 1):length(groups)) {
      gi <- as.character(groups[i])
      gj <- as.character(groups[j])
      dx <- group_centers[gj, 1] - group_centers[gi, 1]
      dy <- group_centers[gj, 2] - group_centers[gi, 2]
      dist_ij <- sqrt(dx^2 + dy^2)
      target_dist <- (group_radii[gi] + group_radii[gj]) * group_packing + 0.10
      if (dist_ij < target_dist) {
        if (dist_ij == 0) {
          angle <- 2 * pi * (j - i) / length(groups)
          dx <- cos(angle); dy <- sin(angle); dist_ij <- 1
        }
        move <- (target_dist - dist_ij) * 0.014
        shift <- c(dx, dy) / dist_ij * move
        group_centers[gi, ] <- group_centers[gi, ] - shift
        group_centers[gj, ] <- group_centers[gj, ] + shift
      }
    }
  }
  group_centers <- scale(group_centers, center = TRUE, scale = FALSE)
  rownames(group_centers) <- as.character(groups)
}

layout_xy <- matrix(NA_real_, nrow = igraph::vcount(g), ncol = 2)
for (grp in groups) {
  vids <- which(vertex_community == grp)
  if (length(vids) == 0) next
  layout_xy[vids, ] <- sweep(
    local_layouts[[as.character(grp)]], 2, group_centers[as.character(grp), ], "+"
  )
}

group_label_centers <- t(vapply(
  groups,
  function(grp) {
    vids <- which(vertex_community == grp)
    if (length(vids) == 0) return(c(NA_real_, NA_real_))
    colMeans(layout_xy[vids, , drop = FALSE])
  },
  numeric(2)
))
rownames(group_label_centers) <- as.character(groups)

x_range <- range(layout_xy[, 1])
y_range <- range(layout_xy[, 2])
x_pad <- diff(x_range) * plot_padding
y_pad <- diff(y_range) * plot_padding
label_offset <- min(diff(x_range), diff(y_range)) * 0.035
label_vectors <- sweep(group_label_centers, 2, colMeans(layout_xy), "-")
label_lengths <- sqrt(rowSums(label_vectors^2))
label_lengths[label_lengths == 0 | is.na(label_lengths)] <- 1
label_positions <- group_label_centers + label_vectors / label_lengths * label_offset

node_label_vectors <- sweep(layout_xy, 2, colMeans(layout_xy), "-")
node_label_lengths <- sqrt(rowSums(node_label_vectors^2))
node_label_lengths[node_label_lengths == 0] <- 1
node_label_offset <- min(diff(x_range), diff(y_range)) * 0.055
node_label_positions <- layout_xy + node_label_vectors / node_label_lengths * node_label_offset

scaled <- (edge_similarity - network_similarity_cutoff) /
  max(1e-9, 1 - network_similarity_cutoff)
edge_width <- 0.25 + 2.6 * scaled
edge_alpha <- 0.12 + 0.38 * scaled
edge_color <- vapply(
  edge_alpha,
  function(a) grDevices::adjustcolor("#6b6b6b", alpha.f = a),
  character(1)
)

pdf(network_output, width = pdf_width, height = pdf_height, useDingbats = FALSE)
par(bg = "white", mar = c(0, 0, 0, 0))

igraph::plot.igraph(
  g,
  layout = layout_xy,
  rescale = FALSE,
  xlim = x_range + c(-x_pad, x_pad),
  ylim = y_range + c(-y_pad, y_pad),
  vertex.color = type_colors[vertex_type],
  vertex.frame.color = "#111111",
  vertex.frame.width = 0.8,
  vertex.size = vertex_size,
  vertex.label = NA,
  edge.color = edge_color,
  edge.width = edge_width,
  edge.curved = 0,
  asp = 0
)

node_label_text <- igraph::V(g)$label
label_positions_adjusted <- node_label_positions

label_width <- vapply(
  strsplit(node_label_text, "\n", fixed = TRUE),
  function(x) max(strwidth(x, cex = node_label_cex)),
  numeric(1)
)
label_height <- vapply(
  strsplit(node_label_text, "\n", fixed = TRUE),
  function(x) length(x) * strheight("M", cex = node_label_cex) * 1.15,
  numeric(1)
)

for (iter in seq_len(350)) {
  for (i in seq_len(nrow(label_positions_adjusted) - 1)) {
    for (j in (i + 1):nrow(label_positions_adjusted)) {
      dx <- label_positions_adjusted[j, 1] - label_positions_adjusted[i, 1]
      dy <- label_positions_adjusted[j, 2] - label_positions_adjusted[i, 2]
      overlap_x <- (label_width[i] + label_width[j]) / 2 - abs(dx)
      overlap_y <- (label_height[i] + label_height[j]) / 2 - abs(dy)
      if (overlap_x > 0 && overlap_y > 0) {
        dist_ij <- sqrt(dx^2 + dy^2)
        if (dist_ij == 0) { dx <- 0.01; dy <- 0.01; dist_ij <- sqrt(dx^2 + dy^2) }
        push <- min(overlap_x, overlap_y) * 0.018
        label_positions_adjusted[i, ] <- label_positions_adjusted[i, ] - c(dx, dy) / dist_ij * push
        label_positions_adjusted[j, ] <- label_positions_adjusted[j, ] + c(dx, dy) / dist_ij * push
      }
    }
  }
  label_positions_adjusted <- layout_xy + (label_positions_adjusted - layout_xy) * 0.995
}

text(
  x = label_positions_adjusted[, 1],
  y = label_positions_adjusted[, 2],
  labels = node_label_text,
  cex = node_label_cex,
  col = "#222222",
  family = "sans"
)

group_label_text <- ifelse(
  as.character(groups) == "0",
  "Unassigned",
  paste0("C", groups)
)
keep_label <- !is.na(label_positions[, 1])
text(
  x = label_positions[keep_label, 1],
  y = label_positions[keep_label, 2],
  labels = group_label_text[keep_label],
  cex = group_label_cex,
  font = 2,
  col = "#111111"
)

legend(
  "bottomleft",
  legend = type_labels[names(type_colors) %in% unique(vertex_type)],
  pch = 19,
  col = type_colors[names(type_colors) %in% unique(vertex_type)],
  bty = "n",
  text.col = "#222222",
  cex = legend_cex,
  title = "Phenotype type",
  title.col = "#222222"
)

legend_breaks <- c(0.55, 0.70, 0.85, 0.95)
legend(
  "bottomright",
  legend = format(legend_breaks, nsmall = 2),
  lwd = 0.25 + 2.6 * (legend_breaks - network_similarity_cutoff) /
    max(1e-9, 1 - network_similarity_cutoff),
  col = "#888888",
  bty = "n",
  text.col = "#222222",
  cex = legend_cex,
  title = "BMA similarity",
  title.col = "#222222"
)

dev.off()
message("Wrote network: ", network_output)
message("Wrote network edges: ", network_edge_output)
message("Wrote network nodes: ", network_node_output)
