#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(ggplot2)
  library(ggrepel)
  library(igraph)
})

parse_args <- function(args) {
  out <- list(
    input_dir = "3_data_analysis/global_high_confidence_phenotype_neighborhood_host_endogenous",
    output_dir = NA_character_,
    edge_threshold = 0.45,
    layout_neighbors = 3L,
    label_wrap = 20L,
    cluster_compactness = 0.98,
    cluster_separation = 0.72,
    width = 16.0,
    height = 10.5
  )

  for (arg in args) {
    if (!grepl("^--", arg)) next
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    key <- kv[[1]]
    val <- if (length(kv) > 1) paste(kv[-1], collapse = "=") else "TRUE"
    if (!key %in% names(out)) stop("Unknown argument: --", key, call. = FALSE)
    if (key %in% c(
      "edge_threshold", "cluster_compactness", "cluster_separation",
      "width", "height"
    )) val <- as.numeric(val)
    if (key %in% c("layout_neighbors", "label_wrap")) val <- as.integer(val)
    out[[key]] <- val
  }

  if (is.na(out$output_dir)) {
    tag <- gsub("\\.", "p", sprintf("%.2f", out$edge_threshold))
    out$output_dir <- file.path(
      out$input_dir,
      paste0("cluster_level_phenotype_network_thr", tag)
    )
  }
  out
}

args <- parse_args(commandArgs(trailingOnly = TRUE))

cluster_file <- file.path(args$input_dir, "phenotype_cluster_assignments.csv")
pair_file <- file.path(args$input_dir, "phenotype_similarity_pairs_final.csv")
if (!file.exists(cluster_file)) stop("Missing file: ", cluster_file, call. = FALSE)
if (!file.exists(pair_file)) stop("Missing file: ", pair_file, call. = FALSE)

nodes_all <- read.csv(cluster_file, check.names = FALSE, stringsAsFactors = FALSE)
pairs_all <- read.csv(pair_file, check.names = FALSE, stringsAsFactors = FALSE)

required_node_cols <- c("Phenotype_ID", "Phenotype", "Type", "HighConf_Module_N", "Cluster")
required_pair_cols <- c(
  "Phenotype_ID_1", "Phenotype_1", "Type_1",
  "Phenotype_ID_2", "Phenotype_2", "Type_2",
  "Similarity", "Same_Type", "Disease_NonDisease",
  "Top_Shared_Programs", "Top_Shared_Module_Matches"
)
if (!all(required_node_cols %in% names(nodes_all))) {
  stop("Cluster file has missing columns.", call. = FALSE)
}
if (!all(required_pair_cols %in% names(pairs_all))) {
  stop("Pair file has missing columns.", call. = FALSE)
}

nodes_all$Cluster <- as.integer(nodes_all$Cluster)
cluster_lookup <- setNames(nodes_all$Cluster, nodes_all$Phenotype_ID)
pairs_all$Cluster_1 <- as.integer(cluster_lookup[pairs_all$Phenotype_ID_1])
pairs_all$Cluster_2 <- as.integer(cluster_lookup[pairs_all$Phenotype_ID_2])
pairs_all <- pairs_all[
  !is.na(pairs_all$Cluster_1) & !is.na(pairs_all$Cluster_2),
]
pairs_all$Within_Cluster <- pairs_all$Cluster_1 == pairs_all$Cluster_2

within_pairs <- pairs_all[pairs_all$Within_Cluster, ]
retained_edges <- pairs_all[
  is.finite(pairs_all$Similarity) &
    pairs_all$Similarity >= args$edge_threshold,
]
retained_edges <- retained_edges[
  order(!retained_edges$Within_Cluster, -retained_edges$Similarity),
]

new_output_dir <- file.path(args$output_dir, "labeled_and_individual_networks")
individual_output_dir <- file.path(new_output_dir, "individual_clusters")
dir.create(individual_output_dir, recursive = TRUE, showWarnings = FALSE)

# Only the newly named outputs are replaced. The edited global network already
# present in args$output_dir is deliberately left untouched.
old_outputs <- list.files(
  new_output_dir,
  pattern = "^(global_clustered_phenotype_network_with_type_legend\\.pdf|global_clustered_phenotype_network_with_cluster_labels\\.pdf|retained_edges\\.csv|edge_threshold_summary\\.csv|phenotype_type_color_key\\.csv)$",
  full.names = TRUE,
  recursive = FALSE
)
if (length(old_outputs) > 0) unlink(old_outputs)
old_individual <- list.files(
  individual_output_dir,
  pattern = "^cluster_[0-9]{2}_network\\.pdf$",
  full.names = TRUE
)
if (length(old_individual) > 0) unlink(old_individual)

type_palette <- c(
  biological_process = "#E64B35",
  cell_type_or_line = "#7E6148",
  chemical = "#F2B701",
  disease = "#009E73",
  exposure = "#00A6D6",
  genetic_perturbation = "#3C5488",
  intervention = "#7A5DC7",
  trait = "#D64F9D"
)
missing_types <- setdiff(sort(unique(nodes_all$Type)), names(type_palette))
if (length(missing_types) > 0) {
  extra_cols <- grDevices::hcl.colors(length(missing_types), "Dark 3")
  names(extra_cols) <- missing_types
  type_palette <- c(type_palette, extra_cols)
}

write.csv(
  data.frame(Type = names(type_palette), Color = unname(type_palette)),
  file.path(new_output_dir, "phenotype_type_color_key.csv"),
  row.names = FALSE
)
write.csv(retained_edges, file.path(new_output_dir, "retained_edges.csv"), row.names = FALSE)

summarise_threshold <- function(thresholds) {
  do.call(rbind, lapply(thresholds, function(thr) {
    e <- pairs_all[is.finite(pairs_all$Similarity) & pairs_all$Similarity >= thr, ]
    data.frame(
      edge_threshold = thr,
      total_edges = nrow(e),
      within_cluster_edges = sum(e$Within_Cluster),
      between_cluster_edges = sum(!e$Within_Cluster),
      connected_nodes = length(unique(c(e$Phenotype_ID_1, e$Phenotype_ID_2))),
      cross_type_edges = sum(!e$Same_Type, na.rm = TRUE),
      disease_nondisease_edges = sum(e$Disease_NonDisease, na.rm = TRUE),
      stringsAsFactors = FALSE
    )
  }))
}
write.csv(
  summarise_threshold(c(0.40, 0.45, 0.50, 0.55, 0.60)),
  file.path(new_output_dir, "edge_threshold_summary.csv"),
  row.names = FALSE
)

wrap_label <- function(x, width = 20L) {
  x <- gsub("\\s+", " ", trimws(x))
  vapply(x, function(s) paste(strwrap(s, width = width), collapse = "\n"), character(1))
}

rescale_safe <- function(x, to = c(0, 1), from = range(x, na.rm = TRUE)) {
  if (length(x) == 0) return(numeric())
  if (!all(is.finite(from)) || diff(from) == 0) return(rep(mean(to), length(x)))
  (x - from[1]) / diff(from) * diff(to) + to[1]
}

edge_key <- function(a, b) {
  paste(pmin(a, b), pmax(a, b), sep = "||")
}

select_knn_edges <- function(ids, pairs, k = 3L) {
  p <- pairs[
    pairs$Phenotype_ID_1 %in% ids &
      pairs$Phenotype_ID_2 %in% ids &
      is.finite(pairs$Similarity) &
      pairs$Similarity > 0,
    c("Phenotype_ID_1", "Phenotype_ID_2", "Similarity"),
    drop = FALSE
  ]
  if (nrow(p) == 0) return(p)

  picked <- integer()
  for (id in ids) {
    incident <- which(p$Phenotype_ID_1 == id | p$Phenotype_ID_2 == id)
    if (length(incident) == 0) next
    incident <- incident[order(p$Similarity[incident], decreasing = TRUE)]
    picked <- c(picked, head(incident, k))
  }

  p <- p[unique(picked), , drop = FALSE]
  p$key <- edge_key(p$Phenotype_ID_1, p$Phenotype_ID_2)
  p <- p[order(p$key, -p$Similarity), , drop = FALSE]
  p <- p[!duplicated(p$key), , drop = FALSE]
  p$key <- NULL
  p
}

select_cluster_links <- function(pairs, k = 2L) {
  p <- pairs[
    !pairs$Within_Cluster & is.finite(pairs$Similarity) & pairs$Similarity > 0,
    c("Cluster_1", "Cluster_2", "Similarity"),
    drop = FALSE
  ]
  if (nrow(p) == 0) return(p)

  p$from_cluster <- pmin(p$Cluster_1, p$Cluster_2)
  p$to_cluster <- pmax(p$Cluster_1, p$Cluster_2)
  p$key <- paste(p$from_cluster, p$to_cluster, sep = "||")
  p <- p[order(p$key, -p$Similarity), ]
  p <- p[!duplicated(p$key), ]

  picked <- integer()
  clusters <- sort(unique(nodes_all$Cluster))
  for (cl in clusters) {
    incident <- which(p$from_cluster == cl | p$to_cluster == cl)
    if (length(incident) == 0) next
    incident <- incident[order(p$Similarity[incident], decreasing = TRUE)]
    picked <- c(picked, head(incident, k))
  }
  p[unique(picked), c("from_cluster", "to_cluster", "Similarity"), drop = FALSE]
}

compute_global_layout <- function() {
  layout_edges <- list()
  edge_i <- 1L

  # Strong within-cluster attraction preserves each local phenotype neighborhood.
  for (cl in sort(unique(nodes_all$Cluster))) {
    ids <- nodes_all$Phenotype_ID[nodes_all$Cluster == cl]
    local_pairs <- within_pairs[within_pairs$Cluster_1 == cl, ]
    local_edges <- select_knn_edges(ids, local_pairs, args$layout_neighbors)
    if (nrow(local_edges) == 0) next
    layout_edges[[edge_i]] <- data.frame(
      from = local_edges$Phenotype_ID_1,
      to = local_edges$Phenotype_ID_2,
      weight = pmax(local_edges$Similarity, 0.01)^3 * 3.0,
      stringsAsFactors = FALSE
    )
    edge_i <- edge_i + 1L
  }

  # Visible cross-cluster relationships organize the clusters into one network.
  cross_edges <- retained_edges[!retained_edges$Within_Cluster, ]
  if (nrow(cross_edges) > 0) {
    layout_edges[[edge_i]] <- data.frame(
      from = cross_edges$Phenotype_ID_1,
      to = cross_edges$Phenotype_ID_2,
      weight = pmax(cross_edges$Similarity, 0.01)^3 * 0.75,
      stringsAsFactors = FALSE
    )
    edge_i <- edge_i + 1L
  }

  # Hidden anchors compact each cluster. They affect coordinates only.
  anchors <- paste0("__cluster_", sort(unique(nodes_all$Cluster)))
  anchor_edges <- data.frame(
    from = nodes_all$Phenotype_ID,
    to = paste0("__cluster_", nodes_all$Cluster),
    weight = 0.78,
    stringsAsFactors = FALSE
  )
  layout_edges[[edge_i]] <- anchor_edges
  edge_i <- edge_i + 1L

  # A sparse cluster-level backbone prevents disconnected islands without
  # imposing a grid or a circular arrangement.
  cluster_links <- select_cluster_links(pairs_all, k = 2L)
  if (nrow(cluster_links) > 0) {
    layout_edges[[edge_i]] <- data.frame(
      from = paste0("__cluster_", cluster_links$from_cluster),
      to = paste0("__cluster_", cluster_links$to_cluster),
      weight = pmax(cluster_links$Similarity, 0.01)^3 * 0.45,
      stringsAsFactors = FALSE
    )
  }

  graph_edges <- do.call(rbind, layout_edges)
  vertices <- data.frame(
    name = c(nodes_all$Phenotype_ID, anchors),
    stringsAsFactors = FALSE
  )
  g <- graph_from_data_frame(graph_edges, directed = FALSE, vertices = vertices)

  set.seed(20260910L)
  coords <- layout_with_fr(
    g,
    weights = E(g)$weight,
    niter = 10000,
    grid = "nogrid"
  )
  rownames(coords) <- V(g)$name

  anchor_coords <- coords[anchors, , drop = FALSE]
  pc <- tryCatch(prcomp(anchor_coords, center = TRUE, scale. = FALSE), error = function(e) NULL)
  if (!is.null(pc)) coords <- scale(coords, center = pc$center, scale = FALSE) %*% pc$rotation

  # Separate cluster centers slightly and contract their internal geometry.
  for (cl in sort(unique(nodes_all$Cluster))) {
    ids <- nodes_all$Phenotype_ID[nodes_all$Cluster == cl]
    anchor_id <- paste0("__cluster_", cl)
    center <- coords[anchor_id, ]
    local_offset <- sweep(coords[ids, , drop = FALSE], 2, center, "-")
    new_center <- center * args$cluster_separation
    coords[ids, ] <- sweep(local_offset * args$cluster_compactness, 2, new_center, "+")
  }

  node_coords <- coords[nodes_all$Phenotype_ID, , drop = FALSE]
  node_coords <- norm_coords(
    node_coords,
    xmin = -3.25, xmax = 3.25,
    ymin = -2.15, ymax = 2.15
  )

  laid <- nodes_all[match(rownames(node_coords), nodes_all$Phenotype_ID), ]
  laid$x <- node_coords[, 1]
  laid$y <- node_coords[, 2]
  rownames(laid) <- NULL
  laid
}

laid <- compute_global_layout()
laid$label <- wrap_label(laid$Phenotype, args$label_wrap)

module_range <- range(nodes_all$HighConf_Module_N, na.rm = TRUE)
laid$node_size <- rescale_safe(
  sqrt(laid$HighConf_Module_N),
  to = c(3.8, 7.4),
  from = sqrt(module_range)
)

cluster_centers <- aggregate(cbind(x, y) ~ Cluster, data = laid, FUN = mean)

center_x <- setNames(cluster_centers$x, cluster_centers$Cluster)
center_y <- setNames(cluster_centers$y, cluster_centers$Cluster)
dx <- laid$x - center_x[as.character(laid$Cluster)]
dy <- laid$y - center_y[as.character(laid$Cluster)]
radial_norm <- sqrt(dx^2 + dy^2)
radial_norm[radial_norm < 0.05] <- 1
laid$nudge_x <- 0.045 * dx / radial_norm
laid$nudge_y <- 0.045 * dy / radial_norm
laid$label_hjust <- ifelse(dx >= 0, 0, 1)
central <- sqrt(dx^2 + dy^2) < 0.05
laid$nudge_x[central] <- 0
laid$nudge_y[central] <- 0.06
laid$label_hjust[central] <- 0.5

make_edge_df <- function(edges, laid) {
  if (nrow(edges) == 0) return(data.frame())
  i1 <- match(edges$Phenotype_ID_1, laid$Phenotype_ID)
  i2 <- match(edges$Phenotype_ID_2, laid$Phenotype_ID)
  data.frame(
    x = laid$x[i1],
    y = laid$y[i1],
    xend = laid$x[i2],
    yend = laid$y[i2],
    Similarity = edges$Similarity,
    Within_Cluster = edges$Within_Cluster
  )
}

edge_df <- make_edge_df(retained_edges, laid)
global_edge_max <- max(c(args$edge_threshold, retained_edges$Similarity), na.rm = TRUE)
within_edge_df <- edge_df[edge_df$Within_Cluster, , drop = FALSE]
between_edge_df <- edge_df[!edge_df$Within_Cluster, , drop = FALSE]

if (nrow(within_edge_df) > 0) {
  within_edge_df$edge_width <- rescale_safe(
    within_edge_df$Similarity,
    to = c(0.45, 1.65),
    from = c(args$edge_threshold, global_edge_max)
  )
  within_edge_df$edge_alpha <- rescale_safe(
    within_edge_df$Similarity,
    to = c(0.34, 0.82),
    from = c(args$edge_threshold, global_edge_max)
  )
}
if (nrow(between_edge_df) > 0) {
  between_edge_df$edge_width <- rescale_safe(
    between_edge_df$Similarity,
    to = c(0.28, 0.95),
    from = c(args$edge_threshold, global_edge_max)
  )
  between_edge_df$edge_alpha <- rescale_safe(
    between_edge_df$Similarity,
    to = c(0.14, 0.48),
    from = c(args$edge_threshold, global_edge_max)
  )
}

p <- ggplot()
if (nrow(between_edge_df) > 0) {
  p <- p + geom_segment(
    data = between_edge_df,
    aes(
      x = x, y = y, xend = xend, yend = yend,
      linewidth = edge_width, alpha = edge_alpha
    ),
    color = "#111111",
    lineend = "round"
  )
}
if (nrow(within_edge_df) > 0) {
  p <- p + geom_segment(
    data = within_edge_df,
    aes(
      x = x, y = y, xend = xend, yend = yend,
      linewidth = edge_width, alpha = edge_alpha
    ),
    color = "#111111",
    lineend = "round"
  )
}

p <- p +
  geom_point(
    data = laid,
    aes(x = x, y = y, fill = Type, size = node_size),
    shape = 21,
    color = "#111111",
    stroke = 0.85
  ) +
  geom_text_repel(
    data = laid,
    aes(x = x, y = y, label = label, hjust = label_hjust),
    nudge_x = laid$nudge_x,
    nudge_y = laid$nudge_y,
    seed = 20260910L,
    color = "#111111",
    family = "Helvetica",
    size = 3.05,
    lineheight = 0.86,
    box.padding = 0.13,
    point.padding = 0.20,
    force = 1.00,
    force_pull = 1.50,
    max.time = 15,
    max.iter = 100000,
    max.overlaps = Inf,
    min.segment.length = Inf,
    segment.color = NA,
    xlim = c(-3.72, 3.72),
    ylim = c(-2.48, 2.48)
  ) +
  scale_fill_manual(
    values = type_palette,
    breaks = names(type_palette),
    labels = gsub("_", " ", names(type_palette)),
    name = "Phenotype type"
  ) +
  scale_size_identity() +
  scale_linewidth_identity() +
  scale_alpha_identity() +
  coord_equal(
    xlim = c(-3.78, 3.78),
    ylim = c(-2.52, 2.52),
    expand = FALSE,
    clip = "off"
  ) +
  theme_void(base_family = "Helvetica") +
  theme(
    legend.position = "none",
    plot.background = element_rect(fill = "white", color = NA),
    panel.background = element_rect(fill = "white", color = NA),
    plot.margin = margin(14, 18, 14, 18, unit = "pt")
  )

p_labeled <- p +
  guides(
    fill = guide_legend(
      override.aes = list(shape = 22, size = 5.0, color = "#111111", stroke = 0.7)
    )
  ) +
  theme(
    legend.position = "right",
    legend.title = element_text(
      family = "Helvetica",
      face = "bold",
      size = 11,
      color = "#111111",
      margin = margin(b = 7)
    ),
    legend.text = element_text(
      family = "Helvetica",
      size = 9.5,
      color = "#111111",
      margin = margin(l = 3)
    ),
    legend.key.height = grid::unit(0.34, "in"),
    legend.key.width = grid::unit(0.24, "in"),
    legend.spacing.y = grid::unit(0.02, "in"),
    legend.margin = margin(0, 8, 0, 10)
  )

output_pdf <- file.path(
  new_output_dir,
  "global_clustered_phenotype_network_with_type_legend.pdf"
)
grDevices::pdf(
  output_pdf,
  width = args$width + 2.2,
  height = args$height,
  useDingbats = FALSE,
  family = "Helvetica",
  bg = "white"
)
print(p_labeled)
grDevices::dev.off()

build_individual_cluster_plot <- function(cluster_id) {
  nd <- laid[laid$Cluster == cluster_id, , drop = FALSE]
  local_center <- c(mean(nd$x), mean(nd$y))
  local_xy <- sweep(as.matrix(nd[, c("x", "y")]), 2, local_center, "-")
  local_span <- max(diff(range(local_xy[, 1])), diff(range(local_xy[, 2])), 0.10)
  local_xy <- local_xy / local_span * 1.75
  nd$x_local <- local_xy[, 1]
  nd$y_local <- local_xy[, 2]

  local_edges <- retained_edges[
    retained_edges$Within_Cluster & retained_edges$Cluster_1 == cluster_id,
    ,
    drop = FALSE
  ]
  if (nrow(local_edges) > 0) {
    i1 <- match(local_edges$Phenotype_ID_1, nd$Phenotype_ID)
    i2 <- match(local_edges$Phenotype_ID_2, nd$Phenotype_ID)
    local_edge_df <- data.frame(
      x = nd$x_local[i1],
      y = nd$y_local[i1],
      xend = nd$x_local[i2],
      yend = nd$y_local[i2],
      Similarity = local_edges$Similarity
    )
    local_edge_df$edge_width <- rescale_safe(
      local_edge_df$Similarity,
      to = c(0.55, 2.10),
      from = c(args$edge_threshold, global_edge_max)
    )
    local_edge_df$edge_alpha <- rescale_safe(
      local_edge_df$Similarity,
      to = c(0.42, 0.90),
      from = c(args$edge_threshold, global_edge_max)
    )
  } else {
    local_edge_df <- data.frame()
  }

  local_norm <- sqrt(nd$x_local^2 + nd$y_local^2)
  local_norm[local_norm < 0.05] <- 1
  nd$nudge_x_local <- 0.050 * nd$x_local / local_norm
  nd$nudge_y_local <- 0.050 * nd$y_local / local_norm
  nd$hjust_local <- ifelse(nd$x_local >= 0, 0, 1)
  local_central <- sqrt(nd$x_local^2 + nd$y_local^2) < 0.05
  nd$nudge_x_local[local_central] <- 0
  nd$nudge_y_local[local_central] <- 0.07
  nd$hjust_local[local_central] <- 0.5

  p_local <- ggplot()
  if (nrow(local_edge_df) > 0) {
    p_local <- p_local + geom_segment(
      data = local_edge_df,
      aes(
        x = x, y = y, xend = xend, yend = yend,
        linewidth = edge_width, alpha = edge_alpha
      ),
      color = "#111111",
      lineend = "round"
    )
  }

  p_local +
    geom_point(
      data = nd,
      aes(x = x_local, y = y_local, fill = Type, size = node_size),
      shape = 21,
      color = "#111111",
      stroke = 0.90
    ) +
    geom_text_repel(
      data = nd,
      aes(x = x_local, y = y_local, label = label, hjust = hjust_local),
      nudge_x = nd$nudge_x_local,
      nudge_y = nd$nudge_y_local,
      seed = 20260910L + as.integer(cluster_id),
      color = "#111111",
      family = "Helvetica",
      size = 3.35,
      lineheight = 0.86,
      box.padding = 0.14,
      point.padding = 0.20,
      force = 1.00,
      force_pull = 1.50,
      max.time = 10,
      max.iter = 75000,
      max.overlaps = Inf,
      min.segment.length = Inf,
      segment.color = NA,
      xlim = c(-1.52, 1.52),
      ylim = c(-1.22, 1.22)
    ) +
    scale_fill_manual(values = type_palette, guide = "none") +
    scale_size_identity() +
    scale_linewidth_identity() +
    scale_alpha_identity() +
    coord_equal(
      xlim = c(-1.55, 1.55),
      ylim = c(-1.25, 1.25),
      expand = FALSE,
      clip = "off"
    ) +
    theme_void(base_family = "Helvetica") +
    theme(
      legend.position = "none",
      plot.background = element_rect(fill = "white", color = NA),
      panel.background = element_rect(fill = "white", color = NA),
      plot.margin = margin(12, 16, 12, 16, unit = "pt")
    )
}

for (cl in sort(unique(laid$Cluster))) {
  p_cluster <- build_individual_cluster_plot(cl)
  cluster_pdf <- file.path(
    individual_output_dir,
    sprintf("cluster_%02d_network.pdf", cl)
  )
  grDevices::pdf(
    cluster_pdf,
    width = 7.5,
    height = 6.2,
    useDingbats = FALSE,
    family = "Helvetica",
    bg = "white"
  )
  print(p_cluster)
  grDevices::dev.off()
}

cat("Output directory: ", new_output_dir, "\n", sep = "")
cat("Network PDF with type legend: ", output_pdf, "\n", sep = "")
cat("Individual cluster PDFs: ", individual_output_dir, "\n", sep = "")
cat("Edge threshold: ", sprintf("%.2f", args$edge_threshold), "\n", sep = "")
cat("Retained edges: ", nrow(retained_edges), "\n", sep = "")
cat("Within-cluster edges: ", sum(retained_edges$Within_Cluster), "\n", sep = "")
cat("Between-cluster edges: ", sum(!retained_edges$Within_Cluster), "\n", sep = "")
