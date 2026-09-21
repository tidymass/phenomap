suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(igraph)
  library(readxl)
  library(ggrepel)
})

# Two networks for one case-study cluster, drawn on the same layout:
#   1. edge width = PhenoMAP BMA similarity
#   2. edge width = number of evidence types (HUM, EXP, MECH, SHARED, STRUCT),
#      edge line type = Direct (solid) / Indirect (dashed)
# Run from the project root or from analysis/1_code/case_study.

cluster_id <- 9

project_dir <- normalizePath(getwd())
if (!dir.exists(file.path(project_dir, "analysis", "3_result"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", "..", ".."))
}

result_dir <- file.path(project_dir, "analysis", "3_result")
case_dir <- file.path(result_dir, "case_study", paste0("cluster_", cluster_id))
members_file <- file.path(result_dir, "cluster_analysis", "community_members.csv")
scoring_file <- file.path(case_dir, paste0("cluster_", cluster_id, "_edge_evidence_scoring.xlsx"))

# Data -------------------------------------------------------------------------

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

nodes <- read.csv(members_file, check.names = FALSE) %>%
  as_tibble() %>%
  filter(Community == cluster_id) %>%
  transmute(
    id = Phenotype_ID,
    name = Phenotype,
    type = factor(Phenotype_Type, levels = names(type_labels))
  )

is_yes <- function(x) toupper(trimws(coalesce(as.character(x), ""))) == "YES"

edges <- read_excel(scoring_file, sheet = 1) %>%
  filter(!is.na(`Edge ID`), trimws(`Edge ID`) != "") %>%
  mutate(
    from = sapply(strsplit(`Edge ID`, "__", fixed = TRUE), `[`, 2),
    to = sapply(strsplit(`Edge ID`, "__", fixed = TRUE), `[`, 3),
    bma = as.numeric(`PhenoMAP BMA`),
    evidence_n = is_yes(HUM) + is_yes(EXP) + is_yes(MECH) + is_yes(SHARED) + is_yes(STRUCT),
    class = factor(trimws(`Final class`), levels = c("Direct", "Indirect"))
  ) %>%
  filter(from %in% nodes$id, to %in% nodes$id) %>%
  select(from, to, bma, evidence_n, class)

# Layout (computed once, shared by both networks) ------------------------------

g <- graph_from_data_frame(
  edges %>% transmute(from, to, weight = bma),
  directed = FALSE,
  vertices = nodes %>% select(id)
)

set.seed(20260919)
layout_xy <- layout_with_fr(g, weights = E(g)$weight, niter = 3000)
layout_xy <- apply(layout_xy, 2, function(v) (v - min(v)) / (max(v) - min(v)) * 2 - 1)

node_xy <- nodes %>%
  mutate(x = layout_xy[, 1], y = layout_xy[, 2])

# Thinner / dashed edges drawn last so they stay visible
edge_xy <- edges %>%
  left_join(node_xy %>% select(id, x, y), by = c("from" = "id")) %>%
  left_join(node_xy %>% select(id, xend = x, yend = y), by = c("to" = "id")) %>%
  arrange(class, desc(bma))

# Style ------------------------------------------------------------------------

# Muted hues taken from the main figure (purple / teal / orange / blue)
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
node_size <- 8

base_network <- function(edge_layer) {
  ggplot() +
    edge_layer +
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
      size = 4.4,
      color = "black",
      point.size = node_size,
      box.padding = 0.5,
      min.segment.length = Inf,
      seed = 20260919
    ) +
    scale_fill_manual(
      values = type_fill,
      labels = type_labels,
      drop = TRUE,
      name = NULL
    ) +
    scale_x_continuous(expand = expansion(mult = 0.18)) +
    scale_y_continuous(expand = expansion(mult = 0.12)) +
    coord_fixed(clip = "off") +
    guides(fill = guide_legend(override.aes = list(size = 5), order = 1, nrow = 2)) +
    theme_void(base_size = 15) +
    theme(
      legend.position = "bottom",
      legend.box = "vertical",
      legend.text = element_text(size = 11, color = "black"),
      legend.title = element_text(size = 11, color = "black"),
      legend.key.width = unit(0.9, "cm"),
      plot.margin = margin(10, 12, 10, 12)
    )
}

# Network 1: BMA similarity ----------------------------------------------------

p_bma <- base_network(
  geom_segment(
    data = edge_xy,
    aes(x = x, y = y, xend = xend, yend = yend, linewidth = bma),
    color = edge_color,
    lineend = "round",
    alpha = 0.75
  )
) +
  scale_linewidth_continuous(
    range = c(0.6, 1.4),
    name = "BMA similarity",
    guide = guide_legend(order = 2, override.aes = list(color = edge_color))
  )

print(p_bma)

pdf(
  file.path(case_dir, paste0("cluster_", cluster_id, "_network_bma.pdf")),
  width = 6.2,
  height = 6.6
)
print(p_bma)
dev.off()

# Network 2: evidence ----------------------------------------------------------

p_evidence <- base_network(
  geom_segment(
    data = edge_xy,
    aes(x = x, y = y, xend = xend, yend = yend, linewidth = evidence_n, linetype = class),
    color = edge_color,
    lineend = "butt",
    alpha = 0.75
  )
) +
  scale_linewidth_continuous(
    range = c(0.6, 1.4),
    limits = c(0, 5),
    breaks = sort(unique(edges$evidence_n)),
    name = "Evidence types",
    guide = guide_legend(order = 2, override.aes = list(color = edge_color))
  ) +
  scale_linetype_manual(
    values = c(Direct = "solid", Indirect = "22"),
    drop = TRUE,
    name = NULL,
    guide = guide_legend(order = 3, override.aes = list(color = edge_color, linewidth = 1))
  )

print(p_evidence)

pdf(
  file.path(case_dir, paste0("cluster_", cluster_id, "_network_evidence.pdf")),
  width = 6.2,
  height = 6.6
)
print(p_evidence)
dev.off()
