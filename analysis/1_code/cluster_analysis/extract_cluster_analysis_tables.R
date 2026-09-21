# Extract lightweight community/cluster interpretation tables.
#
# Run from the project root:
#   Rscript analysis/1_code/cluster_analysis/extract_cluster_analysis_tables.R
#
# Inputs:
#   analysis/3_result/cluster_analysis/community_members.csv
#   analysis/3_result/cluster_analysis/community_stability.csv
#   analysis/3_result/phenotype_similarity_matrix.csv
#   analysis/3_result/phenotype_similarity_pairs.csv
#   analysis/2_data/selected_module_phenotype_map.csv
#
# Outputs:
#   analysis/3_result/cluster_analysis/cluster_metrics.csv
#   analysis/3_result/cluster_analysis/cluster_members_with_metrics.csv
#   analysis/3_result/cluster_analysis/cluster_edges.csv
#   analysis/3_result/cluster_analysis/cluster_edges_with_module_titles.csv

# Match the network plotting scripts. Edges in cluster_edges*.csv are the
# within-community edges that are actually drawn in the network figures.
edge_quantile <- 0.95

options(stringsAsFactors = FALSE)

read_csv <- function(file) {
  read.csv(file, check.names = FALSE, na.strings = c("", "NA"))
}

write_csv <- function(x, file) {
  write.csv(x, file, row.names = FALSE, na = "")
  message("Wrote ", file)
}

collapse_unique <- function(x, sep = "; ") {
  x <- unique(x[!is.na(x) & x != ""])
  if (length(x) == 0) return(NA_character_)
  paste(x, collapse = sep)
}

top_n_table <- function(x, n = 8) {
  x <- x[!is.na(x) & x != ""]
  if (length(x) == 0) return(NA_character_)
  tab <- sort(table(x), decreasing = TRUE)
  tab <- head(tab, n)
  paste(paste0(names(tab), " (", as.integer(tab), ")"), collapse = "; ")
}

safe_median <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  median(x)
}

safe_mean <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  mean(x)
}

shared_titles <- function(a, b) {
  a <- unique(trimws(unlist(strsplit(ifelse(is.na(a), "", a), ";", fixed = TRUE))))
  b <- unique(trimws(unlist(strsplit(ifelse(is.na(b), "", b), ";", fixed = TRUE))))
  a <- a[a != ""]
  b <- b[b != ""]
  shared <- intersect(a, b)
  if (length(shared) == 0) return(NA_character_)
  paste(shared, collapse = "; ")
}

args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", args, value = TRUE)
if (length(file_arg) > 0) {
  script_file <- sub("^--file=", "", file_arg[[1]])
} else {
  script_file <- "analysis/1_code/cluster_analysis/extract_cluster_analysis_tables.R"
}
script_dir <- dirname(normalizePath(script_file, mustWork = TRUE))

# Script is analysis/1_code/cluster_analysis; project root is three levels up.
project_root <- normalizePath(file.path(script_dir, "..", "..", ".."), mustWork = TRUE)
data_dir <- file.path(project_root, "analysis", "2_data")
result_dir <- file.path(project_root, "analysis", "3_result")
cluster_result_dir <- file.path(result_dir, "cluster_analysis")

if (!dir.exists(cluster_result_dir)) {
  dir.create(cluster_result_dir, recursive = TRUE)
}

community_members_file <- file.path(cluster_result_dir, "community_members.csv")
community_stability_file <- file.path(cluster_result_dir, "community_stability.csv")
similarity_matrix_file <- file.path(result_dir, "phenotype_similarity_matrix.csv")
phenotype_pairs_file <- file.path(result_dir, "phenotype_similarity_pairs.csv")
module_phenotype_file <- file.path(data_dir, "selected_module_phenotype_map.csv")

required_files <- c(
  community_members_file,
  community_stability_file,
  similarity_matrix_file,
  phenotype_pairs_file,
  module_phenotype_file
)
missing_files <- required_files[!file.exists(required_files)]
if (length(missing_files) > 0) {
  stop("Missing required input files:\n", paste(missing_files, collapse = "\n"), call. = FALSE)
}

message("Using community members: ", community_members_file)
message("Using community stability: ", community_stability_file)
message("Using similarity matrix: ", similarity_matrix_file)
message("Using phenotype pairs: ", phenotype_pairs_file)
message("Using module-phenotype map: ", module_phenotype_file)

community_members <- read_csv(community_members_file)
community_stability <- read_csv(community_stability_file)
similarity_matrix <- as.matrix(read.csv(similarity_matrix_file, row.names = 1, check.names = FALSE))
storage.mode(similarity_matrix) <- "double"
phenotype_pairs <- read_csv(phenotype_pairs_file)
module_phenotype <- read_csv(module_phenotype_file)

required_member_cols <- c("Phenotype_ID", "Community", "Phenotype", "Phenotype_Type", "Module_N")
missing_member_cols <- setdiff(required_member_cols, names(community_members))
if (length(missing_member_cols) > 0) {
  stop("community_members.csv is missing columns: ", paste(missing_member_cols, collapse = ", "), call. = FALSE)
}

required_pair_cols <- c(
  "Phenotype_ID_1", "Phenotype_1", "Phenotype_Type_1",
  "Phenotype_ID_2", "Phenotype_2", "Phenotype_Type_2",
  "BMA_Similarity"
)
missing_pair_cols <- setdiff(required_pair_cols, names(phenotype_pairs))
if (length(missing_pair_cols) > 0) {
  stop("phenotype_similarity_pairs.csv is missing columns: ", paste(missing_pair_cols, collapse = ", "), call. = FALSE)
}

module_id_col <- if ("Module_ID" %in% names(module_phenotype)) {
  "Module_ID"
} else if ("module_id" %in% names(module_phenotype)) {
  "module_id"
} else {
  stop("selected_module_phenotype_map.csv needs Module_ID or module_id", call. = FALSE)
}

module_title_col <- if ("title" %in% names(module_phenotype)) {
  "title"
} else if ("Module_Title" %in% names(module_phenotype)) {
  "Module_Title"
} else {
  stop("selected_module_phenotype_map.csv needs title or Module_Title", call. = FALSE)
}

community_members$Cluster <- suppressWarnings(as.integer(community_members$Community))

if (!("Community_Stability" %in% names(community_members))) {
  community_members <- merge(
    community_members,
    community_stability[, c("Community", "Bootstrap_Jaccard")],
    by = "Community",
    all.x = TRUE
  )
  community_members$Community_Stability <- community_members$Bootstrap_Jaccard
}

community_members$Bootstrap_Jaccard <- community_members$Community_Stability

if (!("Reportable" %in% names(community_members))) {
  community_members$Reportable <- !is.na(community_members$Bootstrap_Jaccard) &
    community_members$Bootstrap_Jaccard >= 0.6
}

phenotype_pairs$Cluster_1 <- community_members$Cluster[
  match(phenotype_pairs$Phenotype_ID_1, community_members$Phenotype_ID)
]
phenotype_pairs$Cluster_2 <- community_members$Cluster[
  match(phenotype_pairs$Phenotype_ID_2, community_members$Phenotype_ID)
]
phenotype_pairs$Within_Cluster <- !is.na(phenotype_pairs$Cluster_1) &
  !is.na(phenotype_pairs$Cluster_2) &
  phenotype_pairs$Cluster_1 == phenotype_pairs$Cluster_2 &
  phenotype_pairs$Phenotype_ID_1 != phenotype_pairs$Phenotype_ID_2
phenotype_pairs$Cluster <- ifelse(phenotype_pairs$Within_Cluster, phenotype_pairs$Cluster_1, NA)

upper_values <- similarity_matrix[upper.tri(similarity_matrix)]
upper_values <- upper_values[!is.na(upper_values)]
network_similarity_cutoff <- as.numeric(quantile(upper_values, edge_quantile, na.rm = TRUE))
message("Network edge cutoff (quantile ", edge_quantile, "): ",
        signif(network_similarity_cutoff, 4))

module_phenotype$Module_ID_Clean <- module_phenotype[[module_id_col]]
module_phenotype$Module_Title <- module_phenotype[[module_title_col]]
module_phenotype$Cluster <- community_members$Cluster[
  match(module_phenotype$Phenotype_ID, community_members$Phenotype_ID)
]

assigned_clusters <- sort(unique(na.omit(community_members$Cluster)))

cluster_metrics <- do.call(rbind, lapply(assigned_clusters, function(k) {
  members <- community_members[which(community_members$Cluster == k), , drop = FALSE]
  ids <- members$Phenotype_ID
  internal_edges <- phenotype_pairs[
    which(phenotype_pairs$Within_Cluster & phenotype_pairs$Cluster == k),
    ,
    drop = FALSE
  ]
  external_edges <- phenotype_pairs[
    # exactly one endpoint inside the cluster (pairs are stored once, in either order)
    (phenotype_pairs$Phenotype_ID_1 %in% ids) != (phenotype_pairs$Phenotype_ID_2 %in% ids),
    ,
    drop = FALSE
  ]
  cluster_modules <- module_phenotype[
    !is.na(module_phenotype$Cluster) & module_phenotype$Cluster == k,
    ,
    drop = FALSE
  ]
  title_counts <- sort(table(cluster_modules$Module_Title), decreasing = TRUE)
  type_counts <- table(members$Phenotype_Type)

  data.frame(
    Cluster = k,
    Size = nrow(members),
    Bootstrap_Jaccard = unique(members$Bootstrap_Jaccard)[[1]],
    Reportable = unique(members$Reportable)[[1]],
    Disease_N = sum(members$Phenotype_Type == "disease", na.rm = TRUE),
    Exposure_N = sum(members$Phenotype_Type == "exposure", na.rm = TRUE),
    Trait_N = sum(members$Phenotype_Type == "trait", na.rm = TRUE),
    Chemical_N = sum(members$Phenotype_Type == "chemical", na.rm = TRUE),
    Genetic_Perturbation_N = sum(members$Phenotype_Type == "genetic_perturbation", na.rm = TRUE),
    Phenotype_Type_Summary = paste(paste0(names(type_counts), "=", as.integer(type_counts)), collapse = "; "),
    Internal_Edge_N = nrow(internal_edges),
    Internal_BMA_Median = safe_median(internal_edges$BMA_Similarity),
    Internal_BMA_Mean = safe_mean(internal_edges$BMA_Similarity),
    Internal_BMA_Max = if (nrow(internal_edges) > 0) max(internal_edges$BMA_Similarity, na.rm = TRUE) else NA_real_,
    External_BMA_Median = safe_median(external_edges$BMA_Similarity),
    BMA_Separation_Median = safe_median(internal_edges$BMA_Similarity) - safe_median(external_edges$BMA_Similarity),
    Module_Assignment_N = nrow(cluster_modules),
    Unique_Module_N = length(unique(cluster_modules$Module_ID_Clean)),
    Top1_Module_Title_Fraction = if (sum(title_counts) > 0) as.numeric(title_counts[[1]]) / sum(title_counts) else NA_real_,
    Top3_Module_Title_Fraction = if (sum(title_counts) > 0) sum(as.numeric(head(title_counts, 3))) / sum(title_counts) else NA_real_,
    Top_Module_Titles = top_n_table(cluster_modules$Module_Title, 8),
    Members = paste(members$Phenotype, collapse = "; "),
    stringsAsFactors = FALSE
  )
}))

cluster_metrics <- cluster_metrics[order(-cluster_metrics$Bootstrap_Jaccard, cluster_metrics$Cluster), ]
write_csv(cluster_metrics, file.path(cluster_result_dir, "cluster_metrics.csv"))

cluster_members_with_metrics <- merge(
  community_members,
  cluster_metrics[, c(
    "Cluster", "Bootstrap_Jaccard", "Internal_BMA_Median",
    "BMA_Separation_Median", "Top_Module_Titles"
  )],
  by = "Cluster",
  all.x = TRUE,
  suffixes = c("", "_Cluster")
)
cluster_members_with_metrics <- cluster_members_with_metrics[
  order(cluster_members_with_metrics$Cluster, -cluster_members_with_metrics$Module_N),
]
write_csv(cluster_members_with_metrics, file.path(cluster_result_dir, "cluster_members_with_metrics.csv"))

cluster_edges <- phenotype_pairs[
  phenotype_pairs$Within_Cluster &
    !is.na(phenotype_pairs$BMA_Similarity) &
    phenotype_pairs$BMA_Similarity > network_similarity_cutoff,
  ,
  drop = FALSE
]
cluster_edges$Phenotype_Edge_ID <- paste0(
  "C", cluster_edges$Cluster, "__",
  cluster_edges$Phenotype_ID_1, "__",
  cluster_edges$Phenotype_ID_2
)
cluster_edges <- merge(
  cluster_edges,
  cluster_metrics[, c("Cluster", "Bootstrap_Jaccard", "Reportable")],
  by = "Cluster",
  all.x = TRUE
)
cluster_edges <- cluster_edges[order(cluster_edges$Cluster, -cluster_edges$BMA_Similarity), ]
write_csv(cluster_edges, file.path(cluster_result_dir, "cluster_edges.csv"))

module_summary_by_phenotype <- do.call(rbind, lapply(
  split(module_phenotype, module_phenotype$Phenotype_ID),
  function(x) {
    data.frame(
      Phenotype_ID = x$Phenotype_ID[[1]],
      Module_Assignment_N = nrow(x),
      Unique_Module_N = length(unique(x$Module_ID_Clean)),
      Module_Titles = collapse_unique(x$Module_Title),
      stringsAsFactors = FALSE
    )
  }
))

cluster_edges_with_modules <- merge(
  cluster_edges,
  module_summary_by_phenotype,
  by.x = "Phenotype_ID_1",
  by.y = "Phenotype_ID",
  all.x = TRUE
)
names(cluster_edges_with_modules)[names(cluster_edges_with_modules) %in% c(
  "Module_Assignment_N", "Unique_Module_N", "Module_Titles"
)] <- c(
  "Module_Assignment_N_1", "Unique_Module_N_1", "Module_Titles_1"
)

cluster_edges_with_modules <- merge(
  cluster_edges_with_modules,
  module_summary_by_phenotype,
  by.x = "Phenotype_ID_2",
  by.y = "Phenotype_ID",
  all.x = TRUE
)
names(cluster_edges_with_modules)[names(cluster_edges_with_modules) %in% c(
  "Module_Assignment_N", "Unique_Module_N", "Module_Titles"
)] <- c(
  "Module_Assignment_N_2", "Unique_Module_N_2", "Module_Titles_2"
)

cluster_edges_with_modules$Shared_Module_Titles <- mapply(
  shared_titles,
  cluster_edges_with_modules$Module_Titles_1,
  cluster_edges_with_modules$Module_Titles_2,
  USE.NAMES = FALSE
)
cluster_edges_with_modules$Shared_Module_Title_N <- ifelse(
  is.na(cluster_edges_with_modules$Shared_Module_Titles),
  0,
  lengths(strsplit(cluster_edges_with_modules$Shared_Module_Titles, ";", fixed = TRUE))
)

cluster_edges_with_modules <- cluster_edges_with_modules[
  order(cluster_edges_with_modules$Cluster, -cluster_edges_with_modules$BMA_Similarity),
]
write_csv(cluster_edges_with_modules, file.path(cluster_result_dir, "cluster_edges_with_module_titles.csv"))

message("Done. Outputs are in ", cluster_result_dir)
