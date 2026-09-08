# Plot PhenoMAP KG entity and relationship scale as a compact heatmap.
#
# Output:
#   3_data_analysis/phenomap_kg_relationship_heatmap.pdf
#
# Run from the repository root:
#   Rscript 1_code/4_analysis/manuscript/plot_kg_relationship_heatmap.R

entity_dir <- file.path("2_data", "tidy_entity")
relationship_dir <- file.path("2_data", "tidy_relationship")
output_dir <- "3_data_analysis"
output_path <- file.path(output_dir, "phenomap_kg_relationship_heatmap.pdf")

entity_order <- c("Phenotype", "Study", "Module", "Metabolite")

entity_files <- c(
  Study = "nodes_study.csv",
  Phenotype = "nodes_phenotype.csv",
  Module = "nodes_module.csv",
  Metabolite = "nodes_metabolite.csv"
)

relationship_files <- data.frame(
  row = c("Study", "Study", "Module", "Module", "Metabolite"),
  col = c("Phenotype", "Module", "Module", "Metabolite", "Metabolite"),
  file = c(
    "edges_study_phenotype.csv",
    "edges_module_study.csv",
    "edges_module_module.csv",
    "edges_metabolite_module.csv",
    "edges_metabolite_metabolite.csv"
  ),
  stringsAsFactors = FALSE
)

entity_counts <- vapply(names(entity_files), function(label) {
  path <- file.path(entity_dir, entity_files[[label]])
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  nrow(utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE))
}, integer(1))
entity_counts <- entity_counts[entity_order]

relationship_files$count <- vapply(relationship_files$file, function(file) {
  path <- file.path(relationship_dir, file)
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  nrow(utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE))
}, integer(1))

relationship_matrix <- matrix(
  NA_real_,
  nrow = length(entity_order),
  ncol = length(entity_order),
  dimnames = list(entity_order, entity_order)
)

for (i in seq_len(nrow(relationship_files))) {
  row_entity <- relationship_files$row[[i]]
  col_entity <- relationship_files$col[[i]]
  row_pos <- match(row_entity, entity_order)
  col_pos <- match(col_entity, entity_order)
  if (is.na(row_pos) || is.na(col_pos)) {
    stop("Relationship entity is not in entity_order: ", row_entity, " - ", col_entity)
  }
  if (row_pos > col_pos) {
    tmp <- row_entity
    row_entity <- col_entity
    col_entity <- tmp
  }
  relationship_matrix[row_entity, col_entity] <- relationship_files$count[[i]]
}

format_count <- function(x) {
  format(x, big.mark = ",", scientific = FALSE, trim = TRUE)
}

rescale01 <- function(x, from = range(x, na.rm = TRUE)) {
  if (!all(is.finite(from)) || diff(from) == 0) return(rep(0.5, length(x)))
  (x - from[[1]]) / diff(from)
}

entity_colors <- c(
  Study = "#6b6aa8",
  Phenotype = "#cf6a62",
  Module = "#2b9b8f",
  Metabolite = "#3c83bd"
)

heat_cols <- grDevices::colorRampPalette(c(
  "#f6f8fa", "#dceaf2", "#a9ccda", "#5e9db7", "#17647f"
))(100)

z <- log10(relationship_matrix)
z_range <- range(z, na.rm = TRUE)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

grDevices::pdf(output_path, width = 4.6, height = 4, useDingbats = FALSE)
old_par <- graphics::par(no.readonly = TRUE)
graphics::par(
  mar = c(0.35, 0.35, 0.35, 0.35),
  family = "Helvetica",
  xaxs = "i",
  yaxs = "i"
)
graphics::plot.new()
graphics::plot.window(xlim = c(0, 1), ylim = c(0, 1))

x0 <- 0.08
y0 <- 0.12
size <- 0.66
cell <- size / length(entity_order)
y_top <- y0 + size

entity_log_counts <- log10(entity_counts)
entity_axis_range <- c(2, 4)
entity_bar_heights <- 0.035 + 0.085 * rescale01(entity_log_counts, entity_axis_range)
entity_bar_y <- y_top + 0.075

entity_axis_x <- x0 - 0.026
entity_axis_y0 <- entity_bar_y + 0.035 * 0.86
entity_axis_y1 <- entity_bar_y + (0.035 + 0.085) * 0.86
graphics::segments(entity_axis_x, entity_axis_y0, entity_axis_x, entity_axis_y1, col = "#9aa4b2", lwd = 0.8)
for (tick in 2:4) {
  tick_y <- entity_bar_y + (0.035 + 0.085 * rescale01(tick, entity_axis_range)) * 0.86
  graphics::segments(entity_axis_x - 0.006, tick_y, entity_axis_x, tick_y, col = "#9aa4b2", lwd = 0.8)
  graphics::text(
    entity_axis_x - 0.010,
    tick_y,
    labels = parse(text = paste0("10^", tick)),
    adj = c(1, 0.5),
    cex = 0.45,
    col = "#66717f"
  )
}

for (i in seq_along(entity_order)) {
  label <- entity_order[[i]]
  cx <- x0 + (i - 0.5) * cell
  bar_h <- entity_bar_heights[[i]] * 0.86

  graphics::rect(
    cx - cell * 0.22,
    entity_bar_y,
    cx + cell * 0.22,
    entity_bar_y + bar_h,
    col = grDevices::adjustcolor(entity_colors[[label]], alpha.f = 0.72),
    border = NA
  )
  graphics::text(
    cx,
    entity_bar_y + bar_h + 0.022,
    format_count(entity_counts[[i]]),
    cex = 0.74,
    col = "#4b5563"
  )
  graphics::text(
    cx,
    entity_bar_y - 0.032,
    label,
    cex = 0.82,
    font = 2,
    col = "#202832"
  )
}

for (i in seq_along(entity_order)) {
  for (j in seq_along(entity_order)) {
    if (j < i) next

    x_left <- x0 + (j - 1) * cell
    y_bottom <- y_top - i * cell
    value <- relationship_matrix[i, j]

    if (is.na(value)) {
      fill <- "#fbfcfd"
    } else {
      color_index <- 1L + floor(99 * rescale01(log10(value), z_range))
      color_index <- max(1L, min(100L, color_index))
      fill <- heat_cols[[color_index]]
    }

    graphics::rect(
      x_left,
      y_bottom,
      x_left + cell,
      y_bottom + cell,
      col = fill,
      border = "#d7dde5",
      lwd = 1.05
    )

    if (!is.na(value)) {
      text_col <- if (log10(value) > mean(z_range)) "#ffffff" else "#111827"
      graphics::text(
        x_left + cell / 2,
        y_bottom + cell / 2,
        format_count(value),
        cex = 0.88,
        font = 2,
        col = text_col
      )
    }
  }
}

for (i in seq_along(entity_order)) {
  y_center <- y_top - (i - 0.5) * cell
  graphics::text(
    x0 + size + 0.03,
    y_center,
    entity_order[[i]],
    adj = c(0, 0.5),
    cex = 0.82,
    font = 2,
    col = "#202832"
  )
}

legend_x <- x0 + size + 0.145
legend_y0 <- y0 + 0.055
legend_h <- 0.34
legend_w <- 0.025
for (k in seq_along(heat_cols)) {
  y1 <- legend_y0 + (k - 1) * legend_h / length(heat_cols)
  y2 <- legend_y0 + k * legend_h / length(heat_cols)
  graphics::rect(legend_x, y1, legend_x + legend_w, y2, col = heat_cols[[k]], border = NA)
}
graphics::rect(legend_x, legend_y0, legend_x + legend_w, legend_y0 + legend_h, border = "#9aa4b2", lwd = 0.7)
graphics::text(
  legend_x + legend_w / 2,
  legend_y0 + legend_h + 0.032,
  "edges",
  cex = 0.58,
  font = 2,
  col = "#202832"
)
for (tick in 3:5) {
  if (tick < z_range[[1]] || tick > z_range[[2]]) next
  tick_y <- legend_y0 + rescale01(tick, z_range) * legend_h
  graphics::segments(legend_x + legend_w, tick_y, legend_x + legend_w + 0.006, tick_y, col = "#9aa4b2", lwd = 0.7)
  graphics::text(
    legend_x + legend_w + 0.012,
    tick_y,
    labels = parse(text = paste0("10^", tick)),
    adj = c(0, 0.5),
    cex = 0.50,
    col = "#66717f"
  )
}

graphics::par(old_par)
grDevices::dev.off()

message("Wrote ", output_path)
