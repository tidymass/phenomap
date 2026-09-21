project_dir <- normalizePath(getwd())
if (!file.exists(file.path(project_dir, "analysis", "3_result", "phenotype_similarity_matrix.csv"))) {
  project_dir <- normalizePath(file.path(project_dir, "..", "..", ".."))
}

# Replace the hard k = 12 Ward partition with a similarity network and consensus
# community detection.
#
# Why:
#   Across seven similarity definitions (see cluster_and_consistency_test.R) the
#   silhouette never rose above 0.142 and its maximum always sat at the top of
#   the k range, so no k is supported by the data. Phenotype similarity is a
#   continuous spectrum, and forcing it into 12 mutually exclusive groups
#   invents boundaries that are not there. Community detection on a similarity
#   network does not require a k, allows a phenotype to sit between communities
#   without being forced into one, and comes with a natural quality measure
#   (modularity) plus per-community stability.
#
#   BMA is kept as the similarity. It was the best definition on both criteria
#   that may legitimately be selected on -- cross-study reliability and
#   cluster stability -- and the debiased variants damaged the CTD result. The
#   module-count bias is handled by reporting the z_null sensitivity analysis,
#   not by changing the main similarity.
#
# What this script does:
#   1. Sweeps edge density (keep the strongest X% of pairs) against Louvain
#      resolution.
#   2. At every combination, runs CONSENSUS Louvain: Louvain is order-dependent,
#      so it is run many times on reshuffled node orders, a co-assignment matrix
#      is built, and communities are read off that. This removes the run-to-run
#      instability that makes single-run modularity clustering unreproducible.
#   3. Bootstraps each combination to get a per-community Jaccard stability.
#   4. Picks one combination by a rule fixed in advance (see selection_rule
#      below), then reports each community with its stability, its members and
#      its composition.
#   5. Writes MDS (and UMAP if uwot is installed) coordinates, so the continuous
#      structure can be shown alongside the communities.
#
# REPORT ONLY communities whose bootstrap Jaccard exceeds stability_floor.
# Communities below it are not findings; they are noise, and the report marks
# them so.

data_dir <- file.path(project_dir, "analysis", "2_data")
source_result_dir <- file.path(project_dir, "analysis", "3_result")
result_dir <- file.path(source_result_dir, "test")
dir.create(result_dir, showWarnings = FALSE, recursive = TRUE)

similarity_file <- file.path(source_result_dir, "phenotype_similarity_matrix.csv")
phenotype_count_file <- file.path(data_dir, "phenotype_module_count.csv")
ward_cluster_file <- file.path(source_result_dir, "phenotype_clusters_ward.D2_k12.csv")

sweep_file <- file.path(result_dir, "community_sweep.csv")
members_file <- file.path(result_dir, "community_members.csv")
stability_file <- file.path(result_dir, "community_stability.csv")
embedding_file <- file.path(result_dir, "community_embedding_coordinates.csv")
report_file <- file.path(result_dir, "community_detection_report.txt")

# ------------------------------------------------------------------ settings ----

# Edge rule: keep the strongest (1 - q) share of phenotype pairs as edges.
edge_quantiles <- c(0.80, 0.85, 0.90, 0.95)
resolutions <- c(0.6, 0.8, 1.0, 1.2, 1.5, 2.0)

consensus_runs <- 50          # Louvain repeats per consensus
consensus_threshold <- 0.5    # co-assignment fraction kept as a consensus edge
bootstrap_repeats <- 50
bootstrap_fraction <- 0.85
bootstrap_consensus_runs <- 20

min_community_size <- 3       # smaller groups are reported as unassigned
stability_floor <- 0.6        # below this a community is noise, not a finding

# Selection rule, fixed before looking at any output: among combinations that
# leave at least min_coverage of phenotypes in communities of at least
# min_community_size, and that produce between 3 and 20 communities, take the
# one with the highest mean bootstrap stability. Modularity breaks ties.
min_coverage <- 0.70
min_communities <- 3
max_communities <- 20

random_seed <- 20260917
set.seed(random_seed)

if (!requireNamespace("igraph", quietly = TRUE)) {
  stop("This script needs igraph: install.packages('igraph')")
}

# ------------------------------------------------------------------- helpers ----

jaccard <- function(a, b) {
  if (length(a) == 0 && length(b) == 0) return(0)
  length(intersect(a, b)) / length(union(a, b))
}

# Louvain with a resolution parameter where igraph supports it, falling back to
# the default resolution on older versions.
louvain_membership <- function(graph, resolution) {
  weights <- igraph::E(graph)$weight
  result <- tryCatch(
    igraph::cluster_louvain(graph, weights = weights, resolution = resolution),
    error = function(e) igraph::cluster_louvain(graph, weights = weights)
  )
  igraph::membership(result)
}

build_graph <- function(similarity, quantile_cut) {
  values <- similarity[upper.tri(similarity)]
  values <- values[!is.na(values)]
  cutoff <- as.numeric(quantile(values, quantile_cut, na.rm = TRUE))
  if (!is.finite(cutoff) || cutoff <= 0) cutoff <- .Machine$double.eps

  adjacency <- similarity
  adjacency[is.na(adjacency)] <- 0
  adjacency[adjacency < cutoff] <- 0
  diag(adjacency) <- 0

  list(
    graph = igraph::graph_from_adjacency_matrix(
      adjacency, mode = "undirected", weighted = TRUE, diag = FALSE
    ),
    cutoff = cutoff
  )
}

# Consensus Louvain: reshuffle node order, cluster, accumulate co-assignment,
# then cluster the co-assignment matrix itself.
consensus_communities <- function(graph, resolution, runs) {
  ids <- igraph::V(graph)$name
  n <- length(ids)
  co_assignment <- matrix(0, n, n, dimnames = list(ids, ids))

  for (r in seq_len(runs)) {
    order_index <- sample.int(n)
    permuted <- igraph::permute(graph, order(order_index))
    membership <- louvain_membership(permuted, resolution)
    membership <- membership[ids]
    same <- outer(membership, membership, "==")
    co_assignment <- co_assignment + same
  }
  co_assignment <- co_assignment / runs

  consensus_adjacency <- co_assignment
  consensus_adjacency[consensus_adjacency < consensus_threshold] <- 0
  diag(consensus_adjacency) <- 0

  if (sum(consensus_adjacency) == 0) {
    return(setNames(seq_len(n), ids))
  }

  consensus_graph <- igraph::graph_from_adjacency_matrix(
    consensus_adjacency, mode = "undirected", weighted = TRUE, diag = FALSE
  )
  membership <- louvain_membership(consensus_graph, resolution)
  setNames(as.integer(membership), igraph::V(consensus_graph)$name)[ids]
}

# Communities smaller than min_community_size are set aside as unassigned (0).
apply_size_floor <- function(membership, floor_size) {
  sizes <- table(membership)
  small <- names(sizes)[sizes < floor_size]
  membership[as.character(membership) %in% small] <- 0L
  membership
}

summarise_partition <- function(membership, graph) {
  assigned <- membership[membership > 0]
  list(
    n_communities = length(unique(assigned)),
    coverage = length(assigned) / length(membership),
    modularity = tryCatch(
      igraph::modularity(graph, ifelse(membership == 0, max(membership) + seq_along(membership), membership),
                         weights = igraph::E(graph)$weight),
      error = function(e) NA_real_
    )
  )
}

bootstrap_stability <- function(similarity, quantile_cut, resolution, reference) {
  ids <- rownames(similarity)
  reference_groups <- split(names(reference)[reference > 0], reference[reference > 0])
  if (length(reference_groups) == 0) return(list(mean = NA_real_, per_community = numeric(0)))

  per_community <- lapply(reference_groups, function(x) numeric(0))

  for (b in seq_len(bootstrap_repeats)) {
    picked <- sort(sample(seq_along(ids), floor(bootstrap_fraction * length(ids))))
    sub_similarity <- similarity[picked, picked, drop = FALSE]
    built <- build_graph(sub_similarity, quantile_cut)
    sub_membership <- consensus_communities(built$graph, resolution, bootstrap_consensus_runs)
    sub_membership <- apply_size_floor(sub_membership, min_community_size)
    sub_groups <- split(names(sub_membership)[sub_membership > 0], sub_membership[sub_membership > 0])
    if (length(sub_groups) == 0) next

    present_ids <- ids[picked]
    for (key in names(reference_groups)) {
      present <- intersect(reference_groups[[key]], present_ids)
      if (length(present) == 0) next
      best <- max(vapply(sub_groups, function(g) jaccard(present, g), numeric(1)))
      per_community[[key]] <- c(per_community[[key]], best)
    }
  }

  means <- vapply(
    per_community,
    function(x) if (length(x) == 0) NA_real_ else mean(x),
    numeric(1)
  )
  list(mean = mean(means, na.rm = TRUE), per_community = means)
}

# ---------------------------------------------------------------------- load ----

similarity_raw <- read.csv(similarity_file, row.names = 1, check.names = FALSE)
similarity <- as.matrix(similarity_raw)
storage.mode(similarity) <- "double"
diag(similarity) <- NA_real_
ids <- rownames(similarity)

phenotype_counts <- read.csv(phenotype_count_file, stringsAsFactors = FALSE, check.names = FALSE)
rownames(phenotype_counts) <- phenotype_counts$Phenotype_ID

message("Phenotypes: ", length(ids))

# ------------------------------------------------------------------ the sweep ----

sweep_rows <- list()
partitions <- list()
stabilities <- list()

for (q in edge_quantiles) {
  built <- build_graph(similarity, q)
  graph <- built$graph
  isolated <- sum(igraph::degree(graph) == 0)

  for (resolution in resolutions) {
    key <- paste0("q", q, "_r", resolution)
    message("Sweeping edge quantile ", q, ", resolution ", resolution, " ...")

    membership <- consensus_communities(graph, resolution, consensus_runs)
    membership <- apply_size_floor(membership, min_community_size)
    summary_stats <- summarise_partition(membership, graph)

    stability <- bootstrap_stability(similarity, q, resolution, membership)

    partitions[[key]] <- membership
    stabilities[[key]] <- stability

    sweep_rows[[key]] <- data.frame(
      Key = key,
      Edge_Quantile = q,
      Edge_Cutoff = built$cutoff,
      Resolution = resolution,
      N_Edges = igraph::ecount(graph),
      N_Isolated_Nodes = isolated,
      N_Communities = summary_stats$n_communities,
      Coverage = summary_stats$coverage,
      Modularity = summary_stats$modularity,
      Mean_Stability = stability$mean,
      N_Stable_Communities = sum(stability$per_community >= stability_floor, na.rm = TRUE),
      stringsAsFactors = FALSE
    )
  }
}

sweep <- do.call(rbind, sweep_rows)
write.csv(sweep, sweep_file, row.names = FALSE)

# ------------------------------------------------------------ apply the rule ----

eligible <- sweep[
  sweep$Coverage >= min_coverage &
    sweep$N_Communities >= min_communities &
    sweep$N_Communities <= max_communities,
]

if (nrow(eligible) == 0) {
  warning("No combination satisfied the selection rule; falling back to the highest mean stability overall.")
  eligible <- sweep
}
eligible <- eligible[order(-eligible$Mean_Stability, -eligible$Modularity), ]
chosen_key <- eligible$Key[1]
chosen <- sweep[sweep$Key == chosen_key, ]
chosen_membership <- partitions[[chosen_key]]
chosen_stability <- stabilities[[chosen_key]]

message("Chosen combination: ", chosen_key)

# ------------------------------------------------------------------- outputs ----

members <- data.frame(
  Phenotype_ID = names(chosen_membership),
  Community = as.integer(chosen_membership),
  stringsAsFactors = FALSE
)
members$Phenotype <- phenotype_counts[members$Phenotype_ID, "Phenotype"]
members$Phenotype_Type <- phenotype_counts[members$Phenotype_ID, "Phenotype_Type"]
members$Module_N <- phenotype_counts[members$Phenotype_ID, "Module_N"]
members$Community_Stability <- as.numeric(
  chosen_stability$per_community[as.character(members$Community)]
)
members$Reportable <- !is.na(members$Community_Stability) &
  members$Community_Stability >= stability_floor
members$Community[members$Community == 0] <- NA_integer_
members <- members[order(members$Community, -members$Module_N), ]

if (file.exists(ward_cluster_file)) {
  ward <- read.csv(ward_cluster_file, stringsAsFactors = FALSE, check.names = FALSE)
  members$Ward_k12_Cluster <- ward$Cluster[match(members$Phenotype_ID, ward$Phenotype_ID)]
}

write.csv(members, members_file, row.names = FALSE)

stability_table <- data.frame(
  Community = names(chosen_stability$per_community),
  Size = as.integer(table(chosen_membership)[names(chosen_stability$per_community)]),
  Bootstrap_Jaccard = as.numeric(chosen_stability$per_community),
  stringsAsFactors = FALSE
)
stability_table$Reportable <- stability_table$Bootstrap_Jaccard >= stability_floor
stability_table <- stability_table[order(-stability_table$Bootstrap_Jaccard), ]
write.csv(stability_table, stability_file, row.names = FALSE)

# Continuous view: the communities are a summary of a spectrum, so always ship
# coordinates for a continuous plot next to them.
distance <- 1 - similarity
distance[is.na(distance)] <- 1
diag(distance) <- 0
mds <- cmdscale(as.dist(distance), k = 2)
embedding <- data.frame(
  Phenotype_ID = ids,
  Phenotype = phenotype_counts[ids, "Phenotype"],
  Phenotype_Type = phenotype_counts[ids, "Phenotype_Type"],
  Module_N = phenotype_counts[ids, "Module_N"],
  Community = as.integer(chosen_membership[ids]),
  MDS1 = mds[, 1],
  MDS2 = mds[, 2],
  stringsAsFactors = FALSE
)
embedding$Community[embedding$Community == 0] <- NA_integer_

if (requireNamespace("uwot", quietly = TRUE)) {
  umap_coordinates <- tryCatch(
    uwot::umap(as.dist(distance), n_neighbors = min(15, length(ids) - 1), min_dist = 0.1),
    error = function(e) NULL
  )
  if (!is.null(umap_coordinates)) {
    embedding$UMAP1 <- umap_coordinates[, 1]
    embedding$UMAP2 <- umap_coordinates[, 2]
  }
}
write.csv(embedding, embedding_file, row.names = FALSE)

# -------------------------------------------------------------------- report ----

report_lines <- c(
  "Consensus community detection on the phenotype similarity network",
  paste0("Similarity matrix: ", similarity_file),
  paste0("Phenotypes: ", length(ids)),
  paste0("Random seed: ", random_seed),
  "",
  "Why this replaces the k = 12 Ward partition:",
  "  Across seven similarity definitions the mean silhouette never exceeded",
  "  0.142 and always peaked at the top of the tested k range, so the data do",
  "  not support any particular k. Communities on a similarity network need no",
  "  k, leave weakly connected phenotypes unassigned instead of forcing them",
  "  into a group, and carry their own stability estimate.",
  "",
  paste0("Selection rule, fixed in advance: coverage >= ", min_coverage,
         ", between ", min_communities, " and ", max_communities,
         " communities, then highest mean bootstrap stability."),
  paste0("Chosen: ", chosen_key),
  paste0("  edge quantile ", chosen$Edge_Quantile,
         " (similarity cutoff ", signif(chosen$Edge_Cutoff, 4), ")",
         ", resolution ", chosen$Resolution),
  paste0("  edges ", chosen$N_Edges,
         ", isolated nodes ", chosen$N_Isolated_Nodes),
  paste0("  communities ", chosen$N_Communities,
         ", coverage ", signif(100 * chosen$Coverage, 3), "%",
         ", modularity ", signif(chosen$Modularity, 4)),
  paste0("  mean bootstrap stability ", signif(chosen$Mean_Stability, 3),
         ", communities above ", stability_floor, ": ", chosen$N_Stable_Communities),
  "",
  paste0("Ward k = 12 on the same matrix, for comparison: mean stability 0.59, ",
         "silhouette 0.113, 19% of members at a negative silhouette."),
  "",
  "Communities, most stable first:"
)

for (i in seq_len(nrow(stability_table))) {
  row <- stability_table[i, ]
  community_members <- members[
    !is.na(members$Community) & members$Community == as.integer(row$Community),
  ]
  community_members <- community_members[order(-community_members$Module_N), ]
  label <- if (isTRUE(row$Reportable)) "REPORTABLE" else "below floor, do not report"
  report_lines <- c(
    report_lines,
    "",
    paste0("  Community ", row$Community,
           "  n = ", row$Size,
           "  Jaccard = ", signif(row$Bootstrap_Jaccard, 3),
           "   [", label, "]"),
    paste0("    ", paste(head(community_members$Phenotype, 12), collapse = "; "))
  )
  if (nrow(community_members) > 12) {
    report_lines <- c(report_lines, paste0("    ... and ", nrow(community_members) - 12, " more"))
  }
}

unassigned <- members[is.na(members$Community), ]
report_lines <- c(
  report_lines,
  "",
  paste0("Unassigned phenotypes (weakly connected, or in a group below ",
         min_community_size, " members): ", nrow(unassigned)),
  if (nrow(unassigned) > 0) paste0("  ", paste(head(unassigned$Phenotype, 20), collapse = "; ")) else NULL,
  "",
  "How to use this:",
  paste0("  Report only the communities marked REPORTABLE (bootstrap Jaccard >= ",
         stability_floor, "). The rest are not findings."),
  "  Show the network or the MDS/UMAP coordinates in the figure so readers see",
  "  that the structure is continuous and the communities are a summary of it,",
  "  not a claim that phenotypes fall into discrete groups.",
  "  In the methods, say that edge density and resolution were swept, that",
  "  communities came from consensus Louvain over reshuffled node orders, and",
  "  that the combination was chosen by the rule stated above -- not by which",
  "  one gave the nicest picture.",
  "",
  "  The full sweep is in community_sweep.csv. If mean stability is low",
  "  everywhere in that table, the honest conclusion is that this network has",
  "  no reproducible community structure, and the figure should be the",
  "  continuous embedding alone."
)

writeLines(report_lines, report_file)

message("")
message("Wrote sweep:      ", sweep_file)
message("Wrote members:    ", members_file)
message("Wrote stability:  ", stability_file)
message("Wrote embedding:  ", embedding_file)
message("Wrote report:     ", report_file)
