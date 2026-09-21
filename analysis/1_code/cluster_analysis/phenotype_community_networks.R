project_dir <- normalizePath(getwd())
if (!file.exists(file.path(project_dir, "analysis", "3_result", "phenotype_similarity_matrix.csv"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", "..", ".."))
}

# One network per community, following analysis/1_code/phenotype_cluster_networks.R.
#
# Same conventions as that script: one PDF per group in a subfolder plus a
# combined multi-page PDF, same phenotype-type palette, node labels drawn by
# igraph beside each vertex, the main connected component laid out with FR and
# any detached components tucked around it rather than flung to the edge.
#
# Differences:
#   1. Groups are the consensus-Louvain communities, not Ward k = 12 clusters.
#   2. The unassigned phenotypes are not drawn -- they are not a community.
#   3. The edge cutoff is the same quantile used to detect the communities and
#      to draw the overview network, so all three figures show the same edges.
#
# Layouts are computed once and reused for both the combined and the single
# PDFs, so a community looks identical in both.

data_dir <- file.path(project_dir, "analysis", "2_data")
source_result_dir <- file.path(project_dir, "analysis", "3_result")
result_dir <- file.path(source_result_dir, "cluster_analysis")
community_network_dir <- file.path(result_dir, "community_networks")
dir.create(community_network_dir, showWarnings = FALSE, recursive = TRUE)

matrix_file <- file.path(source_result_dir, "phenotype_similarity_matrix.csv")
phenotype_count_file <- file.path(data_dir, "phenotype_module_count.csv")
community_members_file <- file.path(result_dir, "community_members.csv")
community_stability_file <- file.path(result_dir, "community_stability.csv")

combined_output <- file.path(result_dir, "phenotype_similarity_community_networks.pdf")

# ------------------------------------------------------------------ settings ----

edge_quantile <- 0.95            # same cutoff as the community detection
order_communities_by <- "stability"   # "stability" | "size"
show_stability_in_title <- FALSE      # TRUE appends "J = 0.93" to each title

pdf_width <- 8
pdf_height <- 7
vertex_size <- 12
node_label_cex <- 0.70
legend_cex <- 0.65

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

if (!requireNamespace("igraph", quietly = TRUE)) {
  stop("The community network plots need the igraph package. Please install it before running this script.")
}

upper_values <- similarity_matrix[upper.tri(similarity_matrix)]
upper_values <- upper_values[!is.na(upper_values)]
network_similarity_cutoff <- as.numeric(quantile(upper_values, edge_quantile, na.rm = TRUE))
message("Edge cutoff (quantile ", edge_quantile, "): ", signif(network_similarity_cutoff, 4))

community_ids <- sort(unique(phenotype_info$Community[phenotype_info$Community > 0]))
if (order_communities_by == "size") {
  community_sequence <- community_ids[order(
    -vapply(community_ids, function(c) sum(phenotype_info$Community == c), integer(1))
  )]
} else {
  community_sequence <- community_ids[order(-stability_of[as.character(community_ids)])]
}
message("Communities drawn: ", length(community_sequence),
        "   (", sum(phenotype_info$Community == 0), " unassigned phenotypes are not drawn)")

# ------------------------------------------------- build one community's graph ----

build_community <- function(community_id) {
  nodes <- phenotype_info[phenotype_info$Community == community_id, ]
  ids <- nodes$Phenotype_ID

  sub <- similarity_matrix[ids, ids, drop = FALSE]
  upper_index <- which(upper.tri(sub), arr.ind = TRUE)
  edges <- data.frame(
    from = ids[upper_index[, 1]],
    to = ids[upper_index[, 2]],
    similarity = sub[upper_index],
    stringsAsFactors = FALSE
  )
  edges <- edges[!is.na(edges$similarity) & edges$similarity > network_similarity_cutoff, ]

  vertex_table <- nodes
  vertex_table$name <- vertex_table$Phenotype_ID
  vertex_table$label <- vapply(
    vertex_table$Phenotype,
    function(x) paste(strwrap(x, width = 16), collapse = "\n"),
    character(1)
  )

  g <- igraph::graph_from_data_frame(edges, directed = FALSE, vertices = vertex_table)

  # Keep detached nodes and components near the main component instead of
  # letting the layout push them far away.
  if (igraph::vcount(g) == 1) {
    layout_xy <- matrix(c(0, 0), ncol = 2)
  } else {
    comp <- igraph::components(g)
    comp_sizes <- comp$csize
    main_comp <- which.max(comp_sizes)
    layout_xy <- matrix(NA_real_, nrow = igraph::vcount(g), ncol = 2)

    for (comp_id in seq_along(comp_sizes)) {
      comp_vids <- which(comp$membership == comp_id)
      subg <- igraph::induced_subgraph(g, comp_vids)

      if (length(comp_vids) == 1) {
        local_layout <- matrix(c(0, 0), ncol = 2)
      } else if (igraph::ecount(subg) > 0) {
        local_layout <- igraph::layout_with_fr(subg, niter = 3000, grid = "nogrid")
      } else {
        local_layout <- igraph::layout_in_circle(subg)
      }

      local_layout <- scale(local_layout, center = TRUE, scale = FALSE)
      local_span <- max(diff(range(local_layout[, 1])), diff(range(local_layout[, 2])))
      if (local_span > 0) local_layout <- local_layout / local_span

      if (comp_id == main_comp) {
        local_layout <- local_layout * (1.55 + 0.07 * sqrt(length(comp_vids)))
        comp_center <- c(0, 0)
      } else {
        local_layout <- local_layout * (0.22 + 0.04 * sqrt(length(comp_vids)))
        small_comp_ids <- setdiff(seq_along(comp_sizes), main_comp)
        angle <- 2 * pi * (match(comp_id, small_comp_ids) - 1) / length(small_comp_ids)
        comp_center <- c(cos(angle), sin(angle)) * 1.35
      }

      layout_xy[comp_vids, ] <- sweep(local_layout, 2, comp_center, "+")
    }
  }
  layout_xy <- sweep(layout_xy, 2, colMeans(layout_xy), "-")

  x_range <- range(layout_xy[, 1])
  y_range <- range(layout_xy[, 2])
  if (diff(x_range) == 0) x_range <- x_range + c(-1, 1)
  if (diff(y_range) == 0) y_range <- y_range + c(-1, 1)

  edge_similarity <- igraph::E(g)$similarity
  edge_width <- numeric(0)
  edge_color <- character(0)
  if (igraph::ecount(g) > 0) {
    scaled <- (edge_similarity - network_similarity_cutoff) /
      max(1e-9, 1 - network_similarity_cutoff)
    edge_width <- 0.35 + 3.2 * scaled
    edge_color <- vapply(
      0.18 + 0.45 * scaled,
      function(a) grDevices::adjustcolor("#6b6b6b", alpha.f = a),
      character(1)
    )
  }

  title <- paste0(
    "C", community_id,
    "  n=", igraph::vcount(g),
    "  edges>", signif(network_similarity_cutoff, 3), "=", igraph::ecount(g)
  )
  if (show_stability_in_title) {
    title <- paste0(
      title, "  J=",
      formatC(stability_of[as.character(community_id)], format = "f", digits = 2)
    )
  }

  list(
    graph = g,
    layout = layout_xy,
    x_range = x_range,
    y_range = y_range,
    edge_width = edge_width,
    edge_color = edge_color,
    title = title
  )
}

draw_community <- function(item) {
  g <- item$graph
  x_pad <- diff(item$x_range) * 0.28
  y_pad <- diff(item$y_range) * 0.28

  par(bg = "white", mar = c(1, 1, 3, 1))
  igraph::plot.igraph(
    g,
    layout = item$layout,
    rescale = FALSE,
    xlim = item$x_range + c(-x_pad, x_pad),
    ylim = item$y_range + c(-y_pad, y_pad),
    vertex.color = type_colors[igraph::V(g)$Phenotype_Type],
    vertex.frame.color = "#111111",
    vertex.frame.width = 0.9,
    vertex.size = vertex_size,
    vertex.label = igraph::V(g)$label,
    vertex.label.color = "#222222",
    vertex.label.cex = node_label_cex,
    vertex.label.family = "sans",
    vertex.label.dist = 1.15,
    edge.color = item$edge_color,
    edge.width = item$edge_width,
    edge.curved = 0,
    main = item$title,
    asp = 0
  )

  present_types <- unique(igraph::V(g)$Phenotype_Type)
  legend(
    "bottomleft",
    legend = type_labels[names(type_colors) %in% present_types],
    pch = 19,
    col = type_colors[names(type_colors) %in% present_types],
    bty = "n",
    text.col = "#222222",
    cex = legend_cex,
    title = "Phenotype type",
    title.col = "#222222"
  )
}

# Compute every layout once so the combined and single PDFs match exactly.
items <- lapply(community_sequence, build_community)
names(items) <- as.character(community_sequence)

pdf(combined_output, width = pdf_width, height = pdf_height, useDingbats = FALSE)
for (key in names(items)) draw_community(items[[key]])
dev.off()
message("Wrote combined: ", combined_output)

for (key in names(items)) {
  single_output <- file.path(
    community_network_dir,
    paste0("phenotype_similarity_community_C", key, ".pdf")
  )
  pdf(single_output, width = pdf_width, height = pdf_height, useDingbats = FALSE)
  draw_community(items[[key]])
  dev.off()
  message("Wrote ", single_output)
}
