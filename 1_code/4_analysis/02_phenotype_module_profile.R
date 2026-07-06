# PhenoMAP phenotype-level metabolic module profile.

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(df, path, row.names = FALSE, na = "")
  invisible(path)
}

clean_scalar <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0) return(default)
  x <- trimws(as.character(x[[1]]))
  if (!nzchar(x) || is.na(x)) return(default)
  x
}

confidence_weight <- function(x) {
  x <- tolower(trimws(as.character(x)))
  out <- rep(0.5, length(x))
  out[x == "high"] <- 1.0
  out[x == "medium"] <- 0.7
  out[x == "low"] <- 0.4
  out
}

ms2_weight <- function(x) {
  x <- tolower(trimws(as.character(x)))
  ifelse(x %in% c("true", "t", "1", "yes"), 1.0, 0.8)
}

make_profile <- function(entity_dir, relationship_dir) {
  phenotypes <- read_csv_required(file.path(entity_dir, "nodes_phenotype.csv"))
  studies <- read_csv_required(file.path(entity_dir, "nodes_study.csv"))
  modules <- read_csv_required(file.path(entity_dir, "nodes_module.csv"))
  study_phenotype <- read_csv_required(file.path(relationship_dir, "edges_study_phenotype.csv"))
  module_study <- read_csv_required(file.path(relationship_dir, "edges_module_study.csv"))

  x <- merge(
    module_study[, c("Module_ID", "Study_ID"), drop = FALSE],
    study_phenotype[, c("Study_ID", "Phenotype_ID"), drop = FALSE],
    by = "Study_ID",
    all.x = FALSE,
    sort = FALSE
  )
  x <- merge(
    x,
    studies[, c("Lab_ID", "Accession", "MS2_Supported"), drop = FALSE],
    by.x = "Study_ID",
    by.y = "Lab_ID",
    all.x = TRUE,
    sort = FALSE
  )
  x <- merge(
    x,
    phenotypes[, c("Lab_ID", "Phenotype", "Type", "OLS_ID"), drop = FALSE],
    by.x = "Phenotype_ID",
    by.y = "Lab_ID",
    all.x = TRUE,
    sort = FALSE
  )
  x <- merge(
    x,
    modules[, c("Lab_ID", "title", "hypothesis_type", "confidence_label"), drop = FALSE],
    by.x = "Module_ID",
    by.y = "Lab_ID",
    all.x = TRUE,
    sort = FALSE
  )

  x$Confidence_Weight <- confidence_weight(x$confidence_label)
  x$MS2_Weight <- ms2_weight(x$MS2_Supported)
  x$Module_Weight <- x$Confidence_Weight * x$MS2_Weight

  out <- data.frame(
    Phenotype_ID = x$Phenotype_ID,
    Phenotype = x$Phenotype,
    Phenotype_Type = x$Type,
    OLS_ID = x$OLS_ID,
    Module_ID = x$Module_ID,
    Module_Title = x$title,
    Study_ID = x$Study_ID,
    Study_Accession = x$Accession,
    Hypothesis_Type = x$hypothesis_type,
    Confidence_Label = x$confidence_label,
    MS2_Supported = x$MS2_Supported,
    Module_Weight = x$Module_Weight,
    stringsAsFactors = FALSE
  )
  out[order(out$Phenotype, out$Study_ID, out$Module_ID), , drop = FALSE]
}

similarity_lookup <- function(module_similarity, min_module_similarity = 0.70) {
  module_similarity <- module_similarity[
    module_similarity$Similarity_Score >= min_module_similarity,
    c("Module_ID_1", "Module_ID_2", "Similarity_Score"),
    drop = FALSE
  ]
  key1 <- paste(module_similarity$Module_ID_1, module_similarity$Module_ID_2, sep = "||")
  key2 <- paste(module_similarity$Module_ID_2, module_similarity$Module_ID_1, sep = "||")
  c(setNames(module_similarity$Similarity_Score, key1), setNames(module_similarity$Similarity_Score, key2))
}

module_pair_similarity <- function(a, b, lookup) {
  keys <- as.vector(outer(a, b, paste, sep = "||"))
  vals <- unname(lookup[keys])
  vals[is.na(vals)] <- 0
  matrix(vals, nrow = length(a), ncol = length(b))
}

top_shared_mechanisms <- function(pa, pb, sim_mat, top_n = 5) {
  if (length(sim_mat) == 0 || max(sim_mat) <= 0) return(NA_character_)
  idx <- which(sim_mat > 0, arr.ind = TRUE)
  score <- sim_mat[idx]
  idx <- idx[order(-score), , drop = FALSE]
  score <- score[order(-score)]
  idx <- idx[seq_len(min(top_n, nrow(idx))), , drop = FALSE]
  score <- score[seq_len(nrow(idx))]
  paste(
    paste0(
      pa$Module_Title[idx[, 1]],
      " <-> ",
      pb$Module_Title[idx[, 2]],
      " (",
      round(score, 3),
      ")"
    ),
    collapse = "; "
  )
}

make_phenotype_similarity <- function(profile,
                                      module_similarity,
                                      min_module_similarity = 0.70,
                                      min_shared_module_pair_n = 1) {
  lookup <- similarity_lookup(module_similarity, min_module_similarity)
  phenotype_ids <- sort(unique(profile$Phenotype_ID))
  rows <- list()
  row_i <- 0L

  if (length(phenotype_ids) < 2) return(data.frame())

  for (i in seq_len(length(phenotype_ids) - 1L)) {
    pa <- profile[profile$Phenotype_ID == phenotype_ids[[i]], , drop = FALSE]
    for (j in seq.int(i + 1L, length(phenotype_ids))) {
      pb <- profile[profile$Phenotype_ID == phenotype_ids[[j]], , drop = FALSE]
      sim_mat <- module_pair_similarity(pa$Module_ID, pb$Module_ID, lookup)
      shared_n <- sum(sim_mat > 0)
      if (shared_n < min_shared_module_pair_n) next

      weight_mat <- outer(pa$Module_Weight, pb$Module_Weight, "*")
      score <- sum(weight_mat * sim_mat) / sum(weight_mat)
      if (is.na(score) || score <= 0) next

      row_i <- row_i + 1L
      rows[[row_i]] <- data.frame(
        Phenotype_ID_1 = pa$Phenotype_ID[[1]],
        Phenotype_1 = pa$Phenotype[[1]],
        Phenotype_ID_2 = pb$Phenotype_ID[[1]],
        Phenotype_2 = pb$Phenotype[[1]],
        Similarity_Score = score,
        Shared_Module_Pair_N = shared_n,
        Module_N_1 = nrow(pa),
        Module_N_2 = nrow(pb),
        Top_Shared_Mechanisms = top_shared_mechanisms(pa, pb, sim_mat),
        stringsAsFactors = FALSE
      )
    }
  }

  out <- if (length(rows) == 0) data.frame() else do.call(rbind, rows)
  out[order(-out$Similarity_Score, -out$Shared_Module_Pair_N), , drop = FALSE]
}

build_phenotype_module_profile <- function(
  entity_dir = file.path("2_data", "tidy_entity"),
  relationship_dir = file.path("2_data", "tidy_relationship"),
  output_dir = file.path("2_data", "analysis", "phenotype_module_profile"),
  min_module_similarity = 0.70
) {
  profile <- make_profile(entity_dir, relationship_dir)
  module_similarity <- read_csv_required(file.path(relationship_dir, "edges_module_module.csv"))
  phenotype_similarity <- make_phenotype_similarity(
    profile = profile,
    module_similarity = module_similarity,
    min_module_similarity = min_module_similarity
  )

  write_csv(profile, file.path(output_dir, "phenotype_module_profile.csv"))
  write_csv(phenotype_similarity, file.path(output_dir, "phenotype_phenotype_similarity.csv"))

  invisible(list(
    profile = profile,
    phenotype_similarity = phenotype_similarity
  ))
}
