# Publication-style annotated global phenotype similarity heatmap.
#
# This standalone script redraws an existing phenotype similarity matrix. It
# does not rerun the similarity analysis.
#
# Default input is the main Host-Endogenous best-match result:
#   3_data_analysis/global_high_confidence_phenotype_neighborhood_host_endogenous
#
# Run from repository root:
#   Rscript 1_code/4_analysis/manuscript/plot_global_phenotype_similarity_heatmap_annotated.R
#
# Optional arguments:
#   --input_dir=3_data_analysis/global_high_confidence_phenotype_neighborhood_host_endogenous
#   --matrix_file=phenotype_similarity_matrix_final.csv
#   --metadata_file=phenotype_cluster_assignments.csv
#   --output_path=3_data_analysis/global_high_confidence_phenotype_neighborhood_host_endogenous/global_phenotype_similarity_heatmap_publication.pdf
#   --scale_max=0.85
#   --show_diagonal=TRUE
#   --label_max_chars=44
#
# scale_max options:
#   offdiag_max: use the maximum non-diagonal similarity as the darkest color.
#   matrix_max: use the full matrix maximum, including the diagonal.
#   q99: use the 99th percentile of non-diagonal similarities and cap above it.
#   numeric value, e.g. --scale_max=0.65

parse_args <- function() {
  args <- list(
    input_dir = file.path(
      "3_data_analysis",
      "global_high_confidence_phenotype_neighborhood_host_endogenous"
    ),
    matrix_file = "phenotype_similarity_matrix_final.csv",
    metadata_file = "phenotype_cluster_assignments.csv",
    output_path = NA_character_,
    scale_max = "0.85",
    show_diagonal = "TRUE",
    label_max_chars = 44L
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2 || !kv[[1]] %in% names(args)) next
    key <- kv[[1]]
    val <- kv[[2]]
    if (key == "label_max_chars") val <- as.integer(val)
    args[[key]] <- val
  }

  if (is.na(args$output_path) || !nzchar(args$output_path)) {
    args$output_path <- file.path(
      args$input_dir,
      "global_phenotype_similarity_heatmap_publication.pdf"
    )
  }

  args$show_diagonal <- tolower(args$show_diagonal) %in% c("true", "t", "1", "yes", "y")
  args
}

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

resolve_scale_max <- function(z, mode) {
  offdiag <- z
  diag(offdiag) <- NA_real_
  vals <- as.numeric(offdiag)
  vals <- vals[is.finite(vals)]

  numeric_mode <- suppressWarnings(as.numeric(mode))
  if (is.finite(numeric_mode) && numeric_mode > 0) return(numeric_mode)

  if (mode == "matrix_max") {
    out <- max(z, na.rm = TRUE)
  } else if (mode == "q99") {
    out <- unname(stats::quantile(vals, 0.99, na.rm = TRUE))
  } else if (mode == "offdiag_max") {
    out <- max(vals, na.rm = TRUE)
  } else {
    stop("--scale_max must be offdiag_max, matrix_max, q99, or a positive number.")
  }

  if (!is.finite(out) || out <= 0) out <- max(z, na.rm = TRUE)
  out
}

value_to_color <- function(x, palette, scale_max, na_color = "#f5f2ea") {
  out <- rep(na_color, length(x))
  ok <- is.finite(x)
  idx <- floor(pmin(pmax(x[ok], 0), scale_max) / scale_max * (length(palette) - 1L)) + 1L
  out[ok] <- palette[idx]
  out
}

shorten_labels <- function(x, max_chars) {
  x <- as.character(x)
  if (!is.finite(max_chars) || max_chars <= 4) return(x)
  too_long <- nchar(x, type = "width") > max_chars
  x[too_long] <- paste0(substr(x[too_long], 1, max_chars - 3), "...")
  x
}

draw_heatmap_cells <- function(z, palette, scale_max) {
  n <- nrow(z)
  for (i in seq_len(n)) {
    y <- 1 - (i - 0.5) / n
    colors <- value_to_color(z[i, ], palette, scale_max)
    grid::grid.rect(
      x = (seq_len(n) - 0.5) / n,
      y = y,
      width = 1 / n,
      height = 1 / n,
      default.units = "npc",
      gp = grid::gpar(fill = colors, col = NA)
    )
  }
}

draw_type_squares <- function(meta, type_colors) {
  n <- nrow(meta)
  square <- 0.56 / n
  top_y <- 1 + 0.018
  left_x <- -0.018
  grid::grid.rect(
    x = (seq_len(n) - 0.5) / n,
    y = rep(top_y, n),
    width = square,
    height = square,
    default.units = "npc",
    gp = grid::gpar(fill = type_colors[meta$Type], col = NA)
  )
  grid::grid.rect(
    x = rep(left_x, n),
    y = 1 - (seq_len(n) - 0.5) / n,
    width = square,
    height = square,
    default.units = "npc",
    gp = grid::gpar(fill = type_colors[meta$Type], col = NA)
  )
}

draw_axis_labels <- function(labels) {
  n <- length(labels)
  label_gp <- grid::gpar(fontsize = 5.0, col = "#2f3437", fontfamily = "Helvetica")
  grid::grid.text(
    labels,
    x = (seq_len(n) - 0.5) / n,
    y = grid::unit(-0.018, "npc"),
    just = c("right", "centre"),
    rot = 90,
    gp = label_gp
  )
  grid::grid.text(
    labels,
    x = grid::unit(-0.026, "npc"),
    y = 1 - (seq_len(n) - 0.5) / n,
    just = c("right", "centre"),
    gp = label_gp
  )
}

draw_cluster_boundaries <- function(clusters) {
  n <- length(clusters)
  runs <- rle(clusters)
  ends <- cumsum(runs$lengths)
  starts <- c(1, head(ends, -1) + 1)

  for (i in seq_along(starts)) {
    x0 <- (starts[[i]] - 1) / n
    x1 <- ends[[i]] / n
    y0 <- 1 - ends[[i]] / n
    y1 <- 1 - (starts[[i]] - 1) / n
    grid::grid.rect(
      x = (x0 + x1) / 2,
      y = (y0 + y1) / 2,
      width = x1 - x0,
      height = y1 - y0,
      default.units = "npc",
      gp = grid::gpar(fill = NA, col = "#343a40", lwd = 0.55)
    )
  }

  grid::grid.rect(gp = grid::gpar(fill = NA, col = "#1f2933", lwd = 0.75))
}

draw_type_legend <- function(type_levels, type_colors) {
  y0 <- 0.985
  step <- 0.045
  for (i in seq_along(type_levels)) {
    y <- y0 - (i - 1) * step
    grid::grid.rect(
      x = 0.015,
      y = y,
      width = grid::unit(0.085, "in"),
      height = grid::unit(0.085, "in"),
      just = c("left", "centre"),
      gp = grid::gpar(fill = type_colors[[type_levels[[i]]]], col = NA)
    )
    grid::grid.text(
      type_levels[[i]],
      x = grid::unit(0.145, "in"),
      y = y,
      just = c("left", "centre"),
      gp = grid::gpar(fontsize = 6.5, col = "#2f3437", fontfamily = "Helvetica")
    )
  }
}

draw_similarity_legend <- function(palette, scale_max) {
  n <- length(palette)
  x0 <- 0.00
  x1 <- 0.92
  y0 <- 0.405
  y1 <- 0.445
  for (i in seq_len(n)) {
    grid::grid.rect(
      x = x0 + (i - 0.5) / n * (x1 - x0),
      y = (y0 + y1) / 2,
      width = (x1 - x0) / n,
      height = y1 - y0,
      gp = grid::gpar(fill = palette[[i]], col = NA)
    )
  }
  grid::grid.rect(
    x = (x0 + x1) / 2,
    y = (y0 + y1) / 2,
    width = x1 - x0,
    height = y1 - y0,
    gp = grid::gpar(fill = NA, col = "#4b5563", lwd = 0.45)
  )
  grid::grid.text(
    "0",
    x = x0,
    y = y0 - 0.030,
    just = c("left", "top"),
    gp = grid::gpar(fontsize = 6.8, col = "#2f3437", fontfamily = "Helvetica")
  )
  grid::grid.text(
    sprintf("%.2f", scale_max),
    x = x1,
    y = y0 - 0.030,
    just = c("right", "top"),
    gp = grid::gpar(fontsize = 6.8, col = "#2f3437", fontfamily = "Helvetica")
  )
}

plot_heatmap <- function(input_dir, matrix_file, metadata_file, output_path,
                         scale_max_mode, show_diagonal, label_max_chars) {
  mat_df <- read_csv_required(file.path(input_dir, matrix_file))
  meta <- read_csv_required(file.path(input_dir, metadata_file))

  needed_meta <- c("Phenotype_ID", "Phenotype", "Type", "Cluster", "HighConf_Module_N")
  missing_meta <- setdiff(needed_meta, colnames(meta))
  if (length(missing_meta) > 0) {
    stop("Metadata file missing columns: ", paste(missing_meta, collapse = ", "))
  }

  z <- as.matrix(mat_df[, setdiff(colnames(mat_df), "Phenotype_ID"), drop = FALSE])
  mode(z) <- "numeric"
  rownames(z) <- mat_df$Phenotype_ID

  common_ids <- intersect(meta$Phenotype_ID, rownames(z))
  meta <- meta[meta$Phenotype_ID %in% common_ids, , drop = FALSE]
  meta <- meta[
    order(meta$Cluster, meta$Type, -meta$HighConf_Module_N, meta$Phenotype),
    ,
    drop = FALSE
  ]

  ids <- meta$Phenotype_ID
  z <- z[ids, ids, drop = FALSE]
  z[!is.finite(z)] <- 0
  scale_max <- resolve_scale_max(z, scale_max_mode)
  z_plot <- pmin(z, scale_max)
  if (!show_diagonal) diag(z_plot) <- NA_real_

  heat_palette <- grDevices::colorRampPalette(
    c("#fbfaf6", "#e9eff0", "#c7dadd", "#8fb8bd", "#4f8190", "#20314f")
  )(160)

  type_palette <- c(
    biological_process = "#8C9A36",
    cell_type_or_line = "#A56B45",
    chemical = "#B9902F",
    disease = "#2F7D6B",
    exposure = "#3F91A6",
    genetic_perturbation = "#6F6AB7",
    intervention = "#6D7785",
    trait = "#BE5A7A"
  )
  type_levels <- sort(unique(meta$Type))
  fallback <- grDevices::hcl.colors(length(type_levels), "Set 2")
  names(fallback) <- type_levels
  type_colors <- fallback
  type_colors[names(type_palette)] <- type_palette[names(type_palette)]
  type_colors <- type_colors[type_levels]

  dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
  grDevices::pdf(output_path, width = 9.6, height = 8.8, useDingbats = FALSE)
  on.exit(grDevices::dev.off(), add = TRUE)

  grid::grid.newpage()
  grid::pushViewport(grid::viewport(gp = grid::gpar(fontfamily = "Helvetica")))

  heat_vp <- grid::viewport(
    x = 0.505,
    y = 0.560,
    width = grid::unit(5.05, "in"),
    height = grid::unit(5.05, "in"),
    just = c("centre", "centre"),
    clip = "off"
  )
  grid::pushViewport(heat_vp)
  draw_heatmap_cells(z_plot, heat_palette, scale_max)
  draw_cluster_boundaries(meta$Cluster)
  draw_type_squares(meta, type_colors)
  draw_axis_labels(shorten_labels(meta$Phenotype, label_max_chars))
  grid::popViewport()

  legend_vp <- grid::viewport(
    x = 0.825,
    y = 0.560,
    width = grid::unit(1.35, "in"),
    height = grid::unit(5.05, "in"),
    just = c("left", "centre"),
    clip = "off"
  )
  grid::pushViewport(legend_vp)
  draw_type_legend(type_levels, type_colors)
  draw_similarity_legend(heat_palette, scale_max)
  grid::popViewport()
  grid::popViewport()

  invisible(output_path)
}

args <- parse_args()
plot_heatmap(
  input_dir = args$input_dir,
  matrix_file = args$matrix_file,
  metadata_file = args$metadata_file,
  output_path = args$output_path,
  scale_max_mode = args$scale_max,
  show_diagonal = args$show_diagonal,
  label_max_chars = args$label_max_chars
)

message("Wrote publication heatmap to: ", args$output_path)
