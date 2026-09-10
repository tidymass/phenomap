#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(grid)
})

parse_args <- function(args) {
  out <- list(
    input_dir = "3_data_analysis/global_high_confidence_phenotype_neighborhood_host_endogenous",
    output_pdf = NA_character_,
    output_edges = NA_character_,
    edge_threshold = 0.45,
    show_isolates = TRUE,
    label_max_chars = 28,
    width = 13.5,
    height = 8.0
  )

  for (arg in args) {
    if (!grepl("^--", arg)) next
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    key <- kv[[1]]
    val <- if (length(kv) > 1) paste(kv[-1], collapse = "=") else "TRUE"
    if (!key %in% names(out)) stop("Unknown argument: --", key, call. = FALSE)
    if (key %in% c("edge_threshold", "width", "height")) val <- as.numeric(val)
    if (key %in% c("label_max_chars")) val <- as.integer(val)
    if (key %in% c("show_isolates")) val <- tolower(val) %in% c("true", "t", "1", "yes", "y")
    out[[key]] <- val
  }

  threshold_tag <- gsub("\\.", "p", sprintf("%.2f", out$edge_threshold))
  if (is.na(out$output_pdf)) {
    out$output_pdf <- file.path(out$input_dir, paste0("global_phenotype_cluster_network_thr", threshold_tag, ".pdf"))
  }
  if (is.na(out$output_edges)) {
    out$output_edges <- file.path(out$input_dir, paste0("global_phenotype_cluster_network_edges_thr", threshold_tag, ".csv"))
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

needed_node_cols <- c("Phenotype_ID", "Phenotype", "Type", "HighConf_Module_N", "Cluster")
needed_pair_cols <- c(
  "Phenotype_ID_1", "Phenotype_1", "Type_1",
  "Phenotype_ID_2", "Phenotype_2", "Type_2",
  "Similarity", "Same_Type", "Disease_NonDisease",
  "Top_Shared_Programs", "Top_Shared_Module_Matches"
)
if (!all(needed_node_cols %in% names(nodes_all))) {
  stop("Cluster file is missing required columns.", call. = FALSE)
}
if (!all(needed_pair_cols %in% names(pairs_all))) {
  stop("Pair file is missing required columns.", call. = FALSE)
}

cluster_lookup <- setNames(nodes_all$Cluster, nodes_all$Phenotype_ID)
pairs_all$Cluster_1 <- cluster_lookup[pairs_all$Phenotype_ID_1]
pairs_all$Cluster_2 <- cluster_lookup[pairs_all$Phenotype_ID_2]
within_pairs <- pairs_all[
  !is.na(pairs_all$Cluster_1) &
    pairs_all$Cluster_1 == pairs_all$Cluster_2,
]

plot_edges <- within_pairs[within_pairs$Similarity >= args$edge_threshold, ]
plot_edges <- plot_edges[order(plot_edges$Cluster_1, -plot_edges$Similarity), ]
write.csv(plot_edges, args$output_edges, row.names = FALSE)

if (args$show_isolates) {
  plot_nodes <- nodes_all
} else {
  keep_ids <- unique(c(plot_edges$Phenotype_ID_1, plot_edges$Phenotype_ID_2))
  plot_nodes <- nodes_all[nodes_all$Phenotype_ID %in% keep_ids, ]
}

plot_nodes$Cluster <- as.integer(plot_nodes$Cluster)
plot_edges$Cluster_1 <- as.integer(plot_edges$Cluster_1)
clusters <- sort(unique(nodes_all$Cluster))

type_palette <- c(
  biological_process = "#C85C74",
  cell_type_or_line = "#B87A18",
  chemical = "#8B9500",
  disease = "#009B5A",
  exposure = "#0AA398",
  genetic_perturbation = "#1196B9",
  intervention = "#7D70D6",
  trait = "#C94FB8"
)
fallback_cols <- grDevices::hcl.colors(length(unique(nodes_all$Type)), "Dark 3")
names(fallback_cols) <- sort(unique(nodes_all$Type))
type_cols <- fallback_cols
type_cols[names(type_palette)] <- type_palette[names(type_palette)]

edge_color <- "#486B82"
edge_color_high <- "#233F55"
text_col <- "#1C1F23"
muted_text <- "#626A70"
light_text <- "#9BA3A9"
panel_line <- "#D7DDE1"

shorten <- function(x, max_chars = 28) {
  x <- gsub("\\s+", " ", x)
  too_long <- nchar(x) > max_chars
  x[too_long] <- paste0(substr(x[too_long], 1, max_chars - 3), "...")
  x
}

wrap_label <- function(x, max_chars = 28) {
  x <- shorten(x, max_chars)
  vapply(
    x,
    function(s) paste(strwrap(s, width = 14), collapse = "\n"),
    character(1)
  )
}

rescale <- function(x, to = c(0, 1), from = range(x, na.rm = TRUE)) {
  if (!is.finite(from[1]) || !is.finite(from[2]) || from[1] == from[2]) {
    return(rep(mean(to), length(x)))
  }
  (x - from[1]) / (from[2] - from[1]) * diff(to) + to[1]
}

mix_color <- function(col1, col2, p = 0.5) {
  rgb1 <- grDevices::col2rgb(col1) / 255
  rgb2 <- grDevices::col2rgb(col2) / 255
  rgb <- rgb1 * (1 - p) + rgb2 * p
  grDevices::rgb(rgb[1], rgb[2], rgb[3])
}

draw_round_rect <- function(x, y, w, h, gp) {
  grid.roundrect(
    x = unit(x, "npc"), y = unit(y, "npc"),
    width = unit(w, "npc"), height = unit(h, "npc"),
    r = unit(0.007, "npc"), gp = gp
  )
}

node_radius <- function(module_n) {
  0.012 + rescale(sqrt(module_n), c(0.000, 0.010), range(sqrt(nodes_all$HighConf_Module_N)))
}

cluster_positions <- data.frame(
  Cluster = clusters,
  col = ((seq_along(clusters) - 1) %% 4) + 1,
  row = 2 - floor((seq_along(clusters) - 1) / 4)
)

layout_nodes <- list()
for (cl in clusters) {
  nd <- plot_nodes[plot_nodes$Cluster == cl, ]
  nd <- nd[order(nd$Type, nd$Phenotype), ]
  idx <- match(cl, cluster_positions$Cluster)
  cell_w <- 0.760 / 4
  cell_h <- 0.820 / 2
  left <- 0.050 + (cluster_positions$col[idx] - 1) * cell_w
  bottom <- 0.095 + (cluster_positions$row[idx] - 1) * cell_h
  cx <- left + cell_w * 0.50
  cy <- bottom + cell_h * 0.50
  rx <- cell_w * 0.345
  ry <- cell_h * 0.315

  if (nrow(nd) == 1) {
    theta <- pi / 2
  } else {
    theta <- seq(pi / 2, pi / 2 - 2 * pi + 2 * pi / nrow(nd), length.out = nrow(nd))
  }
  nd$x <- cx + rx * cos(theta)
  nd$y <- cy + ry * sin(theta)
  nd$radius <- node_radius(nd$HighConf_Module_N)
  nd$label <- wrap_label(nd$Phenotype, args$label_max_chars)
  nd$degree <- 0L

  if (nrow(plot_edges) > 0) {
    ed_cl <- plot_edges[plot_edges$Cluster_1 == cl, ]
    deg_tab <- table(c(ed_cl$Phenotype_ID_1, ed_cl$Phenotype_ID_2))
    nd$degree <- as.integer(deg_tab[nd$Phenotype_ID])
    nd$degree[is.na(nd$degree)] <- 0L
  }
  layout_nodes[[as.character(cl)]] <- nd
}
node_pos <- do.call(rbind, layout_nodes)
rownames(node_pos) <- NULL
pos_lookup <- split(node_pos, node_pos$Phenotype_ID)

edge_range <- range(plot_edges$Similarity, na.rm = TRUE)
if (!all(is.finite(edge_range))) edge_range <- c(args$edge_threshold, args$edge_threshold + 0.01)

dir.create(dirname(args$output_pdf), recursive = TRUE, showWarnings = FALSE)
grDevices::pdf(args$output_pdf, width = args$width, height = args$height, useDingbats = FALSE)
grid.newpage()

for (cl in clusters) {
  idx <- match(cl, cluster_positions$Cluster)
  cell_w <- 0.760 / 4
  cell_h <- 0.820 / 2
  left <- 0.050 + (cluster_positions$col[idx] - 1) * cell_w
  bottom <- 0.095 + (cluster_positions$row[idx] - 1) * cell_h
  draw_round_rect(
    left + cell_w / 2, bottom + cell_h / 2,
    cell_w * 0.92, cell_h * 0.88,
    gpar(col = panel_line, fill = NA, lwd = 0.55)
  )

  nd_cl <- plot_nodes[plot_nodes$Cluster == cl, ]
  ed_cl <- plot_edges[plot_edges$Cluster_1 == cl, ]
  grid.text(
    paste0("C", cl),
    x = unit(left + 0.015, "npc"),
    y = unit(bottom + cell_h - 0.025, "npc"),
    just = c("left", "top"),
    gp = gpar(col = text_col, fontsize = 10.5, fontface = "bold")
  )
  grid.text(
    paste0(nrow(nd_cl), " phenotypes, ", nrow(ed_cl), " edges"),
    x = unit(left + 0.047, "npc"),
    y = unit(bottom + cell_h - 0.026, "npc"),
    just = c("left", "top"),
    gp = gpar(col = muted_text, fontsize = 7.4)
  )
}

if (nrow(plot_edges) > 0) {
  for (i in seq_len(nrow(plot_edges))) {
    e <- plot_edges[i, ]
    p1 <- pos_lookup[[e$Phenotype_ID_1]][1, ]
    p2 <- pos_lookup[[e$Phenotype_ID_2]][1, ]
    w <- rescale(e$Similarity, c(0.40, 2.20), edge_range)
    alpha <- rescale(e$Similarity, c(0.32, 0.92), edge_range)
    col <- mix_color(edge_color, edge_color_high, rescale(e$Similarity, c(0, 1), edge_range))
    grid.lines(
      x = unit(c(p1$x, p2$x), "npc"),
      y = unit(c(p1$y, p2$y), "npc"),
      gp = gpar(col = grDevices::adjustcolor(col, alpha.f = alpha), lwd = w, lineend = "round")
    )
  }
}

for (i in seq_len(nrow(node_pos))) {
  nd <- node_pos[i, ]
  is_isolate <- nd$degree == 0
  fill_col <- type_cols[[nd$Type]]
  alpha <- if (is_isolate) 0.40 else 0.96
  stroke_col <- if (is_isolate) "#B8C0C7" else "#3E464D"
  grid.circle(
    x = unit(nd$x, "npc"),
    y = unit(nd$y, "npc"),
    r = unit(nd$radius, "npc"),
    gp = gpar(
      fill = grDevices::adjustcolor(fill_col, alpha.f = alpha),
      col = stroke_col,
      lwd = if (is_isolate) 0.35 else 0.65
    )
  )
}

label_offset <- 0.026
for (i in seq_len(nrow(node_pos))) {
  nd <- node_pos[i, ]
  cl <- nd$Cluster
  idx <- match(cl, cluster_positions$Cluster)
  cell_w <- 0.760 / 4
  cell_h <- 0.820 / 2
  left <- 0.050 + (cluster_positions$col[idx] - 1) * cell_w
  bottom <- 0.095 + (cluster_positions$row[idx] - 1) * cell_h
  cx <- left + cell_w * 0.50
  cy <- bottom + cell_h * 0.50

  dx <- nd$x - cx
  dy <- nd$y - cy
  dist <- sqrt(dx^2 + dy^2)
  if (dist == 0) {
    lx <- nd$x
    ly <- nd$y + label_offset
    just <- c("center", "bottom")
  } else {
    lx <- nd$x + label_offset * dx / dist
    ly <- nd$y + label_offset * dy / dist
    just <- c(ifelse(dx >= 0, "left", "right"), "center")
  }
  grid.text(
    nd$label,
    x = unit(lx, "npc"),
    y = unit(ly, "npc"),
    just = just,
    gp = gpar(
      col = if (nd$degree == 0) light_text else text_col,
      fontsize = if (nd$degree == 0) 5.2 else 5.6,
      lineheight = 0.88
    )
  )
}

legend_x <- 0.845
legend_y <- 0.840
legend_types <- names(type_cols)[names(type_cols) %in% unique(nodes_all$Type)]
legend_types <- legend_types[order(legend_types)]
nice_type <- gsub("_", " ", legend_types)
for (i in seq_along(legend_types)) {
  y <- legend_y - (i - 1) * 0.036
  grid.rect(
    x = unit(legend_x, "npc"),
    y = unit(y, "npc"),
    width = unit(0.010, "npc"),
    height = unit(0.018, "npc"),
    gp = gpar(fill = type_cols[[legend_types[i]]], col = NA)
  )
  grid.text(
    nice_type[i],
    x = unit(legend_x + 0.016, "npc"),
    y = unit(y, "npc"),
    just = c("left", "center"),
    gp = gpar(col = text_col, fontsize = 7.2)
  )
}

edge_legend_y <- 0.305
max_edge_similarity <- if (nrow(plot_edges) > 0) max(plot_edges$Similarity, na.rm = TRUE) else args$edge_threshold
edge_vals <- c(args$edge_threshold, mean(c(args$edge_threshold, max_edge_similarity)), max_edge_similarity)
edge_vals <- unique(round(edge_vals, 2))
for (i in seq_along(edge_vals)) {
  y <- edge_legend_y - (i - 1) * 0.040
  w <- rescale(edge_vals[i], c(0.40, 2.20), edge_range)
  alpha <- rescale(edge_vals[i], c(0.32, 0.92), edge_range)
  grid.lines(
    x = unit(c(legend_x - 0.002, legend_x + 0.042), "npc"),
    y = unit(c(y, y), "npc"),
    gp = gpar(col = grDevices::adjustcolor(edge_color_high, alpha.f = alpha), lwd = w, lineend = "round")
  )
  grid.text(
    sprintf("%.2f", edge_vals[i]),
    x = unit(legend_x + 0.052, "npc"),
    y = unit(y, "npc"),
    just = c("left", "center"),
    gp = gpar(col = text_col, fontsize = 7.2)
  )
}

node_legend_y <- 0.170
node_vals <- c(2, median(nodes_all$HighConf_Module_N), max(nodes_all$HighConf_Module_N))
node_vals <- unique(round(node_vals))
for (i in seq_along(node_vals)) {
  y <- node_legend_y - (i - 1) * 0.042
  grid.circle(
    x = unit(legend_x + 0.020, "npc"),
    y = unit(y, "npc"),
    r = unit(node_radius(node_vals[i]), "npc"),
    gp = gpar(fill = "#F6F7F8", col = "#4B545C", lwd = 0.55)
  )
  grid.text(
    paste0(node_vals[i], " modules"),
    x = unit(legend_x + 0.052, "npc"),
    y = unit(y, "npc"),
    just = c("left", "center"),
    gp = gpar(col = text_col, fontsize = 7.2)
  )
}

grid.text(
  paste0("edge threshold: similarity >= ", sprintf("%.2f", args$edge_threshold)),
  x = unit(0.050, "npc"),
  y = unit(0.030, "npc"),
  just = c("left", "bottom"),
  gp = gpar(col = muted_text, fontsize = 7.2)
)
grid.text(
  "muted nodes: no retained edge at this threshold",
  x = unit(0.950, "npc"),
  y = unit(0.030, "npc"),
  just = c("right", "bottom"),
  gp = gpar(col = muted_text, fontsize = 7.2)
)

grDevices::dev.off()

cat("Wrote network PDF: ", args$output_pdf, "\n", sep = "")
cat("Wrote retained edges: ", args$output_edges, "\n", sep = "")
cat("Retained edges: ", nrow(plot_edges), "\n", sep = "")
cat("Retained connected nodes: ", length(unique(c(plot_edges$Phenotype_ID_1, plot_edges$Phenotype_ID_2))), "\n", sep = "")
cat("Clusters represented by edges: ", length(unique(plot_edges$Cluster_1)), "\n", sep = "")
