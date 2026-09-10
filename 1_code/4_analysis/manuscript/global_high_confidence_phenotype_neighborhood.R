# PhenoMAP global high-confidence phenotype metabolic neighborhoods.
#
# Goal:
#   Put all phenotype types into one high-confidence metabolic module space
#   and identify disease-centered neighbors such as exposure, chemical,
#   genetic perturbation, trait, biological process, intervention, and cell
#   type phenotypes.
#
# The script does not use phenotype type or disease class for clustering.
# Phenotype-phenotype similarity is computed only from high-confidence module
# profiles and precomputed module-module similarity.
#
# Run from repository root:
#   Rscript 1_code/4_analysis/manuscript/global_high_confidence_phenotype_neighborhood.R
#
# Optional arguments:
#   --entity_dir=2_data/tidy_entity
#   --relationship_dir=2_data/tidy_relationship
#   --output_dir=3_data_analysis/global_high_confidence_phenotype_neighborhood
#   --score_variant=final
#   --hypothesis_filter=all
#   --min_modules_per_phenotype=2
#   --top_neighbors=10
#   --top_edges_per_node=5
#   --k=auto
#   --max_k=10
#   --seed=1
#
# Useful sensitivity runs:
#   Rscript 1_code/4_analysis/manuscript/global_high_confidence_phenotype_neighborhood.R --hypothesis_filter=Host-Endogenous
#   Rscript 1_code/4_analysis/manuscript/global_high_confidence_phenotype_neighborhood.R --score_variant=compositional
#   Rscript 1_code/4_analysis/manuscript/global_high_confidence_phenotype_neighborhood.R --min_modules_per_phenotype=1

parse_args <- function() {
  args <- list(
    entity_dir = file.path("2_data", "tidy_entity"),
    relationship_dir = file.path("2_data", "tidy_relationship"),
    output_dir = file.path("3_data_analysis", "global_high_confidence_phenotype_neighborhood"),
    score_variant = "final",
    hypothesis_filter = "all",
    min_modules_per_phenotype = 2L,
    top_neighbors = 10L,
    top_edges_per_node = 5L,
    k = "auto",
    max_k = 10L,
    seed = 1L
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2 || !kv[[1]] %in% names(args)) next
    key <- kv[[1]]
    val <- kv[[2]]
    if (key %in% c("min_modules_per_phenotype", "top_neighbors", "top_edges_per_node", "max_k", "seed")) {
      val <- as.integer(val)
    }
    args[[key]] <- val
  }
  args
}

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

write_csv <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(x, path, row.names = FALSE, na = "")
  invisible(path)
}

score_column <- function(edges, variant) {
  lookup <- c(
    final = "Similarity_Score",
    biological = "Biological_Score",
    compositional = "Compositional_Score"
  )
  if (!variant %in% names(lookup)) {
    stop("--score_variant must be one of: ", paste(names(lookup), collapse = ", "))
  }
  col <- lookup[[variant]]
  if (!col %in% colnames(edges)) stop("edges_module_module.csv missing score column: ", col)
  col
}

clean_scalar <- function(x) {
  x <- trimws(as.character(x))
  x[is.na(x) | !nzchar(x)] <- NA_character_
  x
}

split_semicolon <- function(x) {
  x <- unlist(strsplit(as.character(x), ";", fixed = TRUE), use.names = FALSE)
  x <- trimws(x)
  unique(x[!is.na(x) & nzchar(x)])
}

collapse_top <- function(x, n = 8) {
  x <- clean_scalar(x)
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_character_)
  tab <- sort(table(x), decreasing = TRUE)
  paste(names(head(tab, n)), collapse = "; ")
}

collapse_top_terms <- function(x, n = 8) {
  terms <- split_semicolon(paste(x, collapse = ";"))
  if (length(terms) == 0) return(NA_character_)
  tab <- sort(table(terms), decreasing = TRUE)
  paste(names(head(tab, n)), collapse = "; ")
}

normalize_key <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x[is.na(x)] <- ""
  gsub("[^a-z0-9]+", "_", x)
}

filter_hypothesis <- function(x, hypothesis_filter) {
  if (tolower(hypothesis_filter) == "all") return(rep(TRUE, nrow(x)))
  wanted <- split_semicolon(gsub(",", ";", hypothesis_filter, fixed = TRUE))
  normalize_key(x$hypothesis_type) %in% normalize_key(wanted)
}

module_program <- function(title, summary, classes, kegg, hmdb, hypothesis_type) {
  text <- tolower(paste(title, summary, classes, kegg, hmdb, hypothesis_type, sep = " "))
  text[is.na(text)] <- ""

  out <- rep("other", length(text))
  assign_if <- function(label, pattern) {
    hit <- out == "other" & grepl(pattern, text, perl = TRUE)
    out[hit] <<- label
  }

  assign_if("arachidonic_eicosanoid", "arachidonic|eicosanoid|prostaglandin|leukotriene|endocannabinoid")
  assign_if("glycerophospholipid", "glycerophospholipid|phosphatidyl|lysopc|lysophosph|choline metabolism|phospholipid")
  assign_if("sphingolipid", "sphingolipid|sphingomyelin|ceramide|ganglioside")
  assign_if("fatty_acid_acylcarnitine", "fatty acid|acylcarnitine|beta-oxidation|carnitine|linoleic|linolenic|omega")
  assign_if("steroid_bile_acid", "steroid|bile acid|cholesterol|retinol|carotenoid")
  assign_if("tryptophan_indole", "tryptophan|indole|kynurenine|serotonin")
  assign_if("arginine_proline_polyamine", "arginine|proline|citrulline|ornithine|polyamine|agmatine|creatine")
  assign_if("amino_acid_one_carbon", "amino acid|methionine|cysteine|glutamate|glutamine|alanine|aspartate|glycine|serine|phenylalanine|tyrosine|histidine|lysine|valine|leucine|isoleucine|one-carbon|folate")
  assign_if("nucleotide", "purine|pyrimidine|nucleotide|nucleoside|adenosine|guanosine|uridine|cytidine")
  assign_if("carbohydrate", "galactose|glucose|glycolysis|pentose|glucuronate|fructose|mannose|carbohydrate|sugar")
  assign_if("mitochondrial_energy_cofactor", "ubiquinone|coenzyme q|tca|citric acid|oxidative phosphorylation|thiamine|vitamin b6|riboflavin|nicotinate|nicotinamide|cofactor")
  assign_if("taurine_hypotaurine", "taurine|hypotaurine")
  assign_if("xenobiotic_drug", "xenobiotic|drug|antibiotic|antimicrobial|cytochrome p450|detoxification|arsenic|caffeine|nicotine|penicillin|aminoglycoside|macrolide|beta-lactam")
  assign_if("diet_plant_secondary", "diet|plant|flavonoid|isoflavonoid|terpene|phenylpropanoid|alkaloid|glycoside|glucosinolate")
  assign_if("microbiome_related", "microbiome|microbial|bacterial|host.microbiome|microbiota")
  out
}

build_high_confidence_profile <- function(phenotypes, modules, study_phenotype, module_study, hypothesis_filter) {
  needed_module_cols <- c(
    "Lab_ID", "title", "functional_summary", "hypothesis_type", "confidence_label",
    "global_direction", "origin_endogenous_frac", "origin_exogenous_frac",
    "class_names", "top_kegg_pathways", "top_hmdb_pathways", "anchor_metabolites"
  )
  for (col in needed_module_cols) if (!col %in% colnames(modules)) modules[[col]] <- NA_character_

  x <- merge(
    module_study[, c("Module_ID", "Study_ID"), drop = FALSE],
    study_phenotype[, c("Study_ID", "Phenotype_ID"), drop = FALSE],
    by = "Study_ID",
    all = FALSE,
    sort = FALSE
  )
  x <- merge(
    x,
    phenotypes[, c("Lab_ID", "Phenotype", "Type", "OLS_ID", "OLS_Definition"), drop = FALSE],
    by.x = "Phenotype_ID",
    by.y = "Lab_ID",
    all.x = TRUE,
    sort = FALSE
  )
  x <- merge(
    x,
    modules[, needed_module_cols, drop = FALSE],
    by.x = "Module_ID",
    by.y = "Lab_ID",
    all.x = TRUE,
    sort = FALSE
  )
  x <- x[tolower(trimws(x$confidence_label)) == "high", , drop = FALSE]
  x <- x[filter_hypothesis(x, hypothesis_filter), , drop = FALSE]
  x$Module_Program <- module_program(
    x$title,
    x$functional_summary,
    x$class_names,
    x$top_kegg_pathways,
    x$top_hmdb_pathways,
    x$hypothesis_type
  )
  unique(x)
}

build_adjacency <- function(module_module, modules_to_keep, score_col) {
  edges <- module_module[
    module_module$Module_ID_1 %in% modules_to_keep &
      module_module$Module_ID_2 %in% modules_to_keep &
      !is.na(module_module[[score_col]]),
    c("Module_ID_1", "Module_ID_2", score_col),
    drop = FALSE
  ]
  if (nrow(edges) == 0) return(list())

  names(edges) <- c("from", "to", "score")
  reverse <- data.frame(from = edges$to, to = edges$from, score = edges$score, stringsAsFactors = FALSE)
  split(rbind(edges, reverse), c(edges$from, reverse$from))
}

best_directed_score <- function(from_modules, to_modules, adjacency) {
  from_modules <- unique(from_modules)
  to_modules <- unique(to_modules)
  if (length(from_modules) == 0 || length(to_modules) == 0) return(NA_real_)

  best <- numeric(length(from_modules))
  for (i in seq_along(from_modules)) {
    module_id <- from_modules[[i]]
    if (module_id %in% to_modules) {
      best[[i]] <- 1
      next
    }
    nb <- adjacency[[module_id]]
    if (is.null(nb) || nrow(nb) == 0) {
      best[[i]] <- 0
      next
    }
    hit <- nb$to %in% to_modules
    best[[i]] <- if (any(hit)) max(nb$score[hit], na.rm = TRUE) else 0
  }
  mean(best)
}

top_module_matches <- function(a_modules, b_modules, adjacency, module_lookup, n = 5) {
  rows <- list()
  k <- 0L
  for (a in unique(a_modules)) {
    if (a %in% b_modules) {
      k <- k + 1L
      rows[[k]] <- data.frame(Module_1 = a, Module_2 = a, Score = 1, stringsAsFactors = FALSE)
      next
    }
    nb <- adjacency[[a]]
    if (is.null(nb) || nrow(nb) == 0) next
    nb <- nb[nb$to %in% b_modules, , drop = FALSE]
    if (nrow(nb) == 0) next
    nb <- nb[order(-nb$score), , drop = FALSE]
    k <- k + 1L
    rows[[k]] <- data.frame(Module_1 = a, Module_2 = nb$to[[1]], Score = nb$score[[1]], stringsAsFactors = FALSE)
  }
  if (length(rows) == 0) return(NA_character_)
  out <- do.call(rbind, rows)
  out <- out[order(-out$Score), , drop = FALSE]
  out <- out[seq_len(min(n, nrow(out))), , drop = FALSE]

  title1 <- module_lookup[out$Module_1, "title"]
  title2 <- module_lookup[out$Module_2, "title"]
  paste0(title1, " <-> ", title2, " (", sprintf("%.3f", out$Score), ")", collapse = "; ")
}

top_shared_programs <- function(a_modules, b_modules, adjacency, module_lookup, n = 5) {
  rows <- list()
  k <- 0L
  for (a in unique(a_modules)) {
    program <- module_lookup[a, "Module_Program"]
    if (length(program) == 0 || is.na(program) || !nzchar(program)) program <- "other"
    nb <- adjacency[[a]]
    if (a %in% b_modules) {
      k <- k + 1L
      rows[[k]] <- data.frame(Program = program, Score = 1, stringsAsFactors = FALSE)
    }
    if (is.null(nb) || nrow(nb) == 0) next
    nb <- nb[nb$to %in% b_modules, , drop = FALSE]
    if (nrow(nb) == 0) next
    nb <- nb[order(-nb$score), , drop = FALSE]
    k <- k + 1L
    rows[[k]] <- data.frame(Program = program, Score = nb$score[[1]], stringsAsFactors = FALSE)
  }
  if (length(rows) == 0) return(NA_character_)
  out <- do.call(rbind, rows)
  score_by_program <- aggregate(Score ~ Program, out, max)
  score_by_program <- score_by_program[order(-score_by_program$Score), , drop = FALSE]
  paste(head(score_by_program$Program, n), collapse = "; ")
}

phenotype_similarity_matrix <- function(profile_list, adjacency) {
  ids <- names(profile_list)
  n <- length(ids)
  mat <- matrix(NA_real_, nrow = n, ncol = n, dimnames = list(ids, ids))
  diag(mat) <- 1
  if (n < 2) return(mat)

  for (i in seq_len(n - 1L)) {
    for (j in seq.int(i + 1L, n)) {
      ab <- best_directed_score(profile_list[[i]], profile_list[[j]], adjacency)
      ba <- best_directed_score(profile_list[[j]], profile_list[[i]], adjacency)
      mat[i, j] <- mat[j, i] <- mean(c(ab, ba), na.rm = TRUE)
    }
  }
  mat
}

choose_cluster_k <- function(dist_obj, max_k) {
  n <- attr(dist_obj, "Size")
  if (n < 4) return(list(k = 1L, table = data.frame(K = 1L, Mean_Silhouette = NA_real_)))
  hc <- stats::hclust(dist_obj, method = "average")
  max_k <- min(max_k, n - 1L)
  ks <- seq.int(2L, max_k)

  if (!requireNamespace("cluster", quietly = TRUE)) {
    fallback_k <- min(max_k, max(2L, round(sqrt(n))))
    return(list(k = fallback_k, table = data.frame(K = ks, Mean_Silhouette = NA_real_)))
  }

  sil <- vapply(ks, function(k) {
    cl <- stats::cutree(hc, k = k)
    mean(cluster::silhouette(cl, dist_obj)[, "sil_width"])
  }, numeric(1))
  data.frame(K = ks, Mean_Silhouette = sil, stringsAsFactors = FALSE) |>
    (\(x) list(k = x$K[which.max(x$Mean_Silhouette)], table = x))()
}

phenotype_pairs <- function(mat, phenotype_info, profile_list, adjacency, module_lookup) {
  idx <- which(upper.tri(mat), arr.ind = TRUE)
  p1 <- rownames(mat)[idx[, "row"]]
  p2 <- colnames(mat)[idx[, "col"]]
  info <- phenotype_info
  rownames(info) <- info$Phenotype_ID

  matches <- vapply(seq_along(p1), function(i) {
    top_module_matches(profile_list[[p1[[i]]]], profile_list[[p2[[i]]]], adjacency, module_lookup, n = 5)
  }, character(1))
  programs <- vapply(seq_along(p1), function(i) {
    top_shared_programs(profile_list[[p1[[i]]]], profile_list[[p2[[i]]]], adjacency, module_lookup, n = 5)
  }, character(1))

  out <- data.frame(
    Phenotype_ID_1 = p1,
    Phenotype_1 = info[p1, "Phenotype"],
    Type_1 = info[p1, "Type"],
    HighConf_Module_N_1 = info[p1, "HighConf_Module_N"],
    Phenotype_ID_2 = p2,
    Phenotype_2 = info[p2, "Phenotype"],
    Type_2 = info[p2, "Type"],
    HighConf_Module_N_2 = info[p2, "HighConf_Module_N"],
    Same_Type = info[p1, "Type"] == info[p2, "Type"],
    Disease_Involved = info[p1, "Type"] == "disease" | info[p2, "Type"] == "disease",
    Disease_NonDisease = (info[p1, "Type"] == "disease") != (info[p2, "Type"] == "disease"),
    Similarity = mat[idx],
    Top_Shared_Programs = programs,
    Top_Shared_Module_Matches = matches,
    stringsAsFactors = FALSE
  )
  out[order(-out$Similarity), , drop = FALSE]
}

top_neighbors <- function(pairs, phenotype_info, top_n) {
  rows <- list()
  ids <- phenotype_info$Phenotype_ID
  info <- phenotype_info
  rownames(info) <- info$Phenotype_ID

  for (id in ids) {
    a <- pairs[pairs$Phenotype_ID_1 == id, , drop = FALSE]
    if (nrow(a) > 0) {
      a <- data.frame(
        Query_ID = a$Phenotype_ID_1,
        Query = a$Phenotype_1,
        Query_Type = a$Type_1,
        Query_Module_N = a$HighConf_Module_N_1,
        Neighbor_ID = a$Phenotype_ID_2,
        Neighbor = a$Phenotype_2,
        Neighbor_Type = a$Type_2,
        Neighbor_Module_N = a$HighConf_Module_N_2,
        Similarity = a$Similarity,
        Top_Shared_Programs = a$Top_Shared_Programs,
        Top_Shared_Module_Matches = a$Top_Shared_Module_Matches,
        stringsAsFactors = FALSE
      )
    }
    b <- pairs[pairs$Phenotype_ID_2 == id, , drop = FALSE]
    if (nrow(b) > 0) {
      b <- data.frame(
        Query_ID = b$Phenotype_ID_2,
        Query = b$Phenotype_2,
        Query_Type = b$Type_2,
        Query_Module_N = b$HighConf_Module_N_2,
        Neighbor_ID = b$Phenotype_ID_1,
        Neighbor = b$Phenotype_1,
        Neighbor_Type = b$Type_1,
        Neighbor_Module_N = b$HighConf_Module_N_1,
        Similarity = b$Similarity,
        Top_Shared_Programs = b$Top_Shared_Programs,
        Top_Shared_Module_Matches = b$Top_Shared_Module_Matches,
        stringsAsFactors = FALSE
      )
    }
    x <- rbind(a, b)
    x <- x[order(-x$Similarity), , drop = FALSE]
    if (nrow(x) > 0) rows[[id]] <- x[seq_len(min(top_n, nrow(x))), , drop = FALSE]
  }
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

network_edges_topk <- function(neighbors, top_edges_per_node) {
  edges <- do.call(rbind, lapply(split(neighbors, neighbors$Query_ID), function(x) {
    x <- x[order(-x$Similarity), , drop = FALSE]
    x[seq_len(min(top_edges_per_node, nrow(x))), , drop = FALSE]
  }))
  key <- paste(pmin(edges$Query_ID, edges$Neighbor_ID), pmax(edges$Query_ID, edges$Neighbor_ID), sep = "||")
  edges$Edge_Key <- key
  edges <- edges[order(edges$Edge_Key, -edges$Similarity), , drop = FALSE]
  edges <- edges[!duplicated(edges$Edge_Key), , drop = FALSE]
  data.frame(
    Source = edges$Query_ID,
    Target = edges$Neighbor_ID,
    Similarity = edges$Similarity,
    Source_Label = edges$Query,
    Source_Type = edges$Query_Type,
    Target_Label = edges$Neighbor,
    Target_Type = edges$Neighbor_Type,
    Top_Shared_Programs = edges$Top_Shared_Programs,
    Top_Shared_Module_Matches = edges$Top_Shared_Module_Matches,
    stringsAsFactors = FALSE
  )
}

cluster_summary <- function(clustered, profile, modules) {
  rows <- list()
  for (cl in sort(unique(clustered$Cluster))) {
    ids <- clustered$Phenotype_ID[clustered$Cluster == cl]
    p <- profile[profile$Phenotype_ID %in% ids, , drop = FALSE]
    m <- modules[match(unique(p$Module_ID), modules$Lab_ID), , drop = FALSE]
    rows[[as.character(cl)]] <- data.frame(
      Cluster = cl,
      Phenotype_N = length(unique(p$Phenotype_ID)),
      Study_N = length(unique(p$Study_ID)),
      HighConf_Module_N = length(unique(p$Module_ID)),
      Phenotype_Types = collapse_top(p$Type, 8),
      Phenotypes = paste(clustered$Phenotype[clustered$Cluster == cl], collapse = "; "),
      Top_Module_Programs = collapse_top(p$Module_Program, 10),
      Top_Module_Titles = collapse_top(m$title, 10),
      Top_Hypothesis_Types = collapse_top(m$hypothesis_type, 6),
      Top_Global_Directions = collapse_top(m$global_direction, 3),
      Top_Anchor_Metabolites = collapse_top_terms(m$anchor_metabolites, 12),
      stringsAsFactors = FALSE
    )
  }
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

plot_mds_network <- function(mat, phenotype_info, edge_table, output_path) {
  dist_mat <- 1 - mat
  dist_mat[!is.finite(dist_mat)] <- 1
  diag(dist_mat) <- 0
  coords <- stats::cmdscale(stats::as.dist(dist_mat), k = 2)
  info <- phenotype_info[match(rownames(mat), phenotype_info$Phenotype_ID), , drop = FALSE]

  types <- sort(unique(info$Type))
  cols <- setNames(grDevices::hcl.colors(length(types), "Dark 3"), types)

  grDevices::pdf(output_path, width = 9.2, height = 7.0, useDingbats = FALSE)
  old_par <- graphics::par(no.readonly = TRUE)
  graphics::par(mar = c(0.8, 0.8, 2.2, 8.8), xpd = TRUE, family = "Helvetica")
  graphics::plot(coords[, 1], coords[, 2], type = "n", axes = FALSE, xlab = "", ylab = "", main = "Global high-confidence phenotype metabolic neighborhoods")

  rownames(coords) <- rownames(mat)
  if (nrow(edge_table) > 0) {
    for (i in seq_len(nrow(edge_table))) {
      a <- edge_table$Source[[i]]
      b <- edge_table$Target[[i]]
      if (!a %in% rownames(coords) || !b %in% rownames(coords)) next
      w <- edge_table$Similarity[[i]]
      graphics::segments(
        coords[a, 1], coords[a, 2], coords[b, 1], coords[b, 2],
        col = grDevices::adjustcolor("#64748b", alpha.f = 0.10 + 0.55 * w),
        lwd = 0.35 + 2.8 * w
      )
    }
  }

  graphics::points(
    coords[, 1],
    coords[, 2],
    pch = 21,
    bg = grDevices::adjustcolor(cols[info$Type], alpha.f = 0.88),
    col = "#111827",
    cex = 0.9 + 1.9 * sqrt(info$HighConf_Module_N) / max(sqrt(info$HighConf_Module_N), na.rm = TRUE)
  )
  label <- ifelse(info$Type == "disease" | info$HighConf_Module_N >= stats::quantile(info$HighConf_Module_N, 0.80), info$Phenotype, "")
  graphics::text(coords[, 1], coords[, 2], labels = label, pos = 3, cex = 0.50, col = "#111827")
  graphics::legend(
    "right",
    inset = c(-0.43, 0),
    legend = types,
    pch = 21,
    pt.bg = cols[types],
    col = "#111827",
    bty = "n",
    cex = 0.72,
    title = "Phenotype type"
  )
  graphics::par(old_par)
  grDevices::dev.off()

  data.frame(
    Phenotype_ID = rownames(mat),
    Phenotype = info$Phenotype,
    Type = info$Type,
    Cluster = info$Cluster,
    HighConf_Module_N = info$HighConf_Module_N,
    MDS1 = coords[, 1],
    MDS2 = coords[, 2],
    stringsAsFactors = FALSE
  )
}

plot_similarity_heatmap <- function(mat, phenotype_info, output_path) {
  ord <- order(phenotype_info$Cluster, phenotype_info$Type, -phenotype_info$HighConf_Module_N, phenotype_info$Phenotype)
  info <- phenotype_info[ord, , drop = FALSE]
  mat <- mat[info$Phenotype_ID, info$Phenotype_ID, drop = FALSE]
  z <- mat
  z[!is.finite(z)] <- 0
  labels <- paste0(info$Phenotype, " [", info$Type, "]")
  pal <- grDevices::colorRampPalette(c("#f8fafc", "#d7e7ef", "#8bb9ce", "#2c789c", "#083f5d"))(100)

  grDevices::pdf(output_path, width = 10.2, height = 9.8, useDingbats = FALSE)
  old_par <- graphics::par(no.readonly = TRUE)
  graphics::par(mar = c(10.5, 10.5, 2.4, 0.8), family = "Helvetica")
  graphics::image(seq_len(nrow(z)), seq_len(ncol(z)), z[nrow(z):1, ], col = pal, axes = FALSE, xlab = "", ylab = "", main = "Global phenotype similarity from high-confidence modules")
  graphics::axis(1, at = seq_along(labels), labels = labels, las = 2, cex.axis = 0.38)
  graphics::axis(2, at = seq_along(labels), labels = rev(labels), las = 2, cex.axis = 0.38)
  runs <- rle(info$Cluster)
  ends <- cumsum(runs$lengths)
  starts <- c(1, head(ends, -1) + 1)
  for (i in seq_along(starts)) {
    graphics::rect(starts[[i]] - 0.5, nrow(z) - ends[[i]] + 0.5, ends[[i]] + 0.5, nrow(z) - starts[[i]] + 1.5, border = "#111827", lwd = 0.65)
  }
  graphics::box()
  graphics::par(old_par)
  grDevices::dev.off()
}

run_analysis <- function(args = parse_args()) {
  set.seed(args$seed)
  dir.create(args$output_dir, recursive = TRUE, showWarnings = FALSE)

  phenotypes <- read_csv_required(file.path(args$entity_dir, "nodes_phenotype.csv"))
  modules <- read_csv_required(file.path(args$entity_dir, "nodes_module.csv"))
  study_phenotype <- read_csv_required(file.path(args$relationship_dir, "edges_study_phenotype.csv"))
  module_study <- read_csv_required(file.path(args$relationship_dir, "edges_module_study.csv"))
  module_module <- read_csv_required(file.path(args$relationship_dir, "edges_module_module.csv"))
  score_col <- score_column(module_module, args$score_variant)

  profile <- build_high_confidence_profile(
    phenotypes = phenotypes,
    modules = modules,
    study_phenotype = study_phenotype,
    module_study = module_study,
    hypothesis_filter = args$hypothesis_filter
  )
  if (nrow(profile) == 0) stop("No high-confidence modules after filtering.")

  summary_all <- aggregate(
    Module_ID ~ Phenotype_ID + Phenotype + Type,
    data = profile,
    FUN = function(x) length(unique(x))
  )
  names(summary_all)[4] <- "HighConf_Module_N"
  summary_all$Study_N <- vapply(
    summary_all$Phenotype_ID,
    function(id) length(unique(profile$Study_ID[profile$Phenotype_ID == id])),
    integer(1)
  )
  summary_all <- summary_all[order(summary_all$Type, -summary_all$HighConf_Module_N, summary_all$Phenotype), , drop = FALSE]
  write_csv(summary_all, file.path(args$output_dir, "all_high_confidence_phenotype_summary.csv"))
  write_csv(profile, file.path(args$output_dir, "high_confidence_phenotype_module_links.csv"))

  keep_ids <- summary_all$Phenotype_ID[summary_all$HighConf_Module_N >= args$min_modules_per_phenotype]
  profile_keep <- profile[profile$Phenotype_ID %in% keep_ids, , drop = FALSE]
  if (length(unique(profile_keep$Phenotype_ID)) < 2) {
    stop("Fewer than two phenotypes pass --min_modules_per_phenotype. Lower the threshold.")
  }

  phenotype_info <- summary_all[match(sort(unique(profile_keep$Phenotype_ID)), summary_all$Phenotype_ID), , drop = FALSE]
  profile_list <- lapply(split(profile_keep$Module_ID, profile_keep$Phenotype_ID), unique)
  phenotype_info <- phenotype_info[match(names(profile_list), phenotype_info$Phenotype_ID), , drop = FALSE]

  module_lookup <- modules
  module_program_lookup <- unique(profile_keep[, c("Module_ID", "Module_Program"), drop = FALSE])
  module_lookup$Module_Program <- module_program_lookup$Module_Program[
    match(module_lookup$Lab_ID, module_program_lookup$Module_ID)
  ]
  rownames(module_lookup) <- module_lookup$Lab_ID
  modules_to_keep <- unique(unlist(profile_list, use.names = FALSE))
  adjacency <- build_adjacency(module_module, modules_to_keep, score_col)
  sim_mat <- phenotype_similarity_matrix(profile_list, adjacency)

  write_csv(
    data.frame(Phenotype_ID = rownames(sim_mat), sim_mat, check.names = FALSE),
    file.path(args$output_dir, paste0("phenotype_similarity_matrix_", args$score_variant, ".csv"))
  )

  pairs <- phenotype_pairs(sim_mat, phenotype_info, profile_list, adjacency, module_lookup)
  write_csv(pairs, file.path(args$output_dir, paste0("phenotype_similarity_pairs_", args$score_variant, ".csv")))

  neighbors <- top_neighbors(pairs, phenotype_info, args$top_neighbors)
  write_csv(neighbors, file.path(args$output_dir, "top_neighbors_by_phenotype.csv"))
  write_csv(
    neighbors[neighbors$Query_Type == "disease" & neighbors$Neighbor_Type != "disease", , drop = FALSE],
    file.path(args$output_dir, "disease_top_nondisease_neighbors.csv")
  )
  write_csv(
    pairs[pairs$Disease_NonDisease, , drop = FALSE],
    file.path(args$output_dir, "all_disease_nondisease_pairs.csv")
  )
  write_csv(
    head(pairs[pairs$Disease_NonDisease, , drop = FALSE], 100),
    file.path(args$output_dir, "top100_disease_nondisease_candidate_examples.csv")
  )

  dist_obj <- stats::as.dist(1 - sim_mat)
  hc <- stats::hclust(dist_obj, method = "average")
  if (tolower(args$k) == "auto") {
    k_choice <- choose_cluster_k(dist_obj, args$max_k)
    k <- k_choice$k
    write_csv(k_choice$table, file.path(args$output_dir, "cluster_k_silhouette_scan.csv"))
  } else {
    k <- as.integer(args$k)
  }
  k <- max(1L, min(k, nrow(sim_mat)))
  clusters <- stats::cutree(hc, k = k)
  phenotype_info$Cluster <- unname(clusters[phenotype_info$Phenotype_ID])
  phenotype_info <- phenotype_info[order(phenotype_info$Cluster, phenotype_info$Type, -phenotype_info$HighConf_Module_N), , drop = FALSE]
  write_csv(phenotype_info, file.path(args$output_dir, "phenotype_cluster_assignments.csv"))

  cl_summary <- cluster_summary(phenotype_info, profile_keep, modules)
  write_csv(cl_summary, file.path(args$output_dir, "phenotype_cluster_summary.csv"))

  network_edges <- network_edges_topk(neighbors, args$top_edges_per_node)
  write_csv(phenotype_info[, c("Phenotype_ID", "Phenotype", "Type", "Cluster", "HighConf_Module_N", "Study_N"), drop = FALSE],
            file.path(args$output_dir, "global_network_nodes.csv"))
  write_csv(network_edges, file.path(args$output_dir, "global_network_edges_topk.csv"))

  coords <- plot_mds_network(
    sim_mat,
    phenotype_info,
    network_edges,
    file.path(args$output_dir, paste0("global_phenotype_mds_network_", args$score_variant, ".pdf"))
  )
  write_csv(coords, file.path(args$output_dir, paste0("global_phenotype_mds_coordinates_", args$score_variant, ".csv")))
  plot_similarity_heatmap(
    sim_mat,
    phenotype_info,
    file.path(args$output_dir, paste0("global_phenotype_similarity_heatmap_", args$score_variant, ".pdf"))
  )

  message("\nWrote outputs to: ", args$output_dir)
  message("\n=== Global high-confidence phenotype neighborhoods ===")
  message("Score variant: ", args$score_variant, " (", score_col, ")")
  message("Hypothesis filter: ", args$hypothesis_filter)
  message("Phenotypes retained: ", nrow(phenotype_info), " / ", nrow(summary_all))
  message("High-confidence modules retained: ", length(modules_to_keep))
  message("Clusters: ", k)
  message("\nPhenotype types retained:")
  print(sort(table(phenotype_info$Type), decreasing = TRUE))
  message("\nTop disease-non-disease candidate examples:")
  print(head(pairs[pairs$Disease_NonDisease, c("Phenotype_1", "Type_1", "Phenotype_2", "Type_2", "Similarity", "Top_Shared_Programs", "Top_Shared_Module_Matches"), drop = FALSE], 30), row.names = FALSE)

  invisible(list(
    profile = profile,
    phenotype_info = phenotype_info,
    similarity = sim_mat,
    pairs = pairs,
    neighbors = neighbors,
    cluster_summary = cl_summary,
    network_edges = network_edges
  ))
}

if (identical(environment(), globalenv()) && !interactive()) {
  run_analysis()
}
