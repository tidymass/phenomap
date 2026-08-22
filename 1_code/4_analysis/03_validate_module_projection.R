# PhenoMAP: leave-one-study-out validation of "module / study projection".
#
# Question this script answers: if we take one study's FeatureMAP modules out
# of the atlas, treat them as a brand-new incoming module profile, and score
# them against every module belonging to every OTHER study, can the resulting
# phenotype ranking recover the study's real phenotype at/near the top?
#
# This is a feasibility check for the proposed "Module / Study Projection"
# workflow (query module(s) -> most similar atlas modules -> associated
# studies -> associated phenotypes), run entirely offline against the
# existing atlas. It does NOT call any LLM/embedding API: it reuses the
# title/summary embeddings already cached in
# 2_data/tidy_relationship/module_text_embeddings.rds by
# 1_code/2_tidy_relationship/05_tidy_module_module_relationship.R. If that
# cache is older than the current nodes_module.csv, some modules may be
# missing an embedding; this script drops those modules from the evaluation
# and reports exactly how many, rather than silently biasing the result.
#
# Caveat worth keeping in mind when reading the numbers: because every
# "query" module here is actually already a real PhenoMAP module (just
# temporarily hidden), all of its metabolites are guaranteed to already exist
# in the PhenoMAP metabolite dictionary. A genuinely external new study may
# contain metabolites PhenoMAP has never seen, which would weaken the
# compositional similarity signal in a way this test cannot capture.
#
# Output (written to output_dir, default 2_data/analysis/module_projection_validation/):
#   study_level_results.csv   one row per query study x similarity variant x
#                             aggregation method
#   summary_by_method.csv     accuracy@1/3/5, MRR, and a random-chance
#                             baseline, one row per similarity variant x
#                             aggregation method
#
# Usage (from project root):
#   Rscript 1_code/4_analysis/03_validate_module_projection.R
#
# Requires the "Matrix" package (ships with most R installs; if missing:
# install.packages("Matrix")).

source(file.path("1_code", "00_phenomap_helpers.R"))
source(file.path("1_code", "2_tidy_relationship", "00_relationship_helpers.R"))

if (!requireNamespace("Matrix", quietly = TRUE)) {
  stop("Package 'Matrix' is required. Install it with install.packages('Matrix').")
}

# ---- small local helpers (kept local so this script has no side effects on
#      any other file when sourced/run) -------------------------------------

pmv_confidence_weight <- function(x) {
  x <- tolower(trimws(as.character(x)))
  out <- rep(0.5, length(x))
  out[x == "high"] <- 1.0
  out[x == "medium"] <- 0.7
  out[x == "low"] <- 0.4
  out
}

pmv_ms2_weight <- function(x) {
  x <- tolower(trimws(as.character(x)))
  ifelse(x %in% c("true", "t", "1", "yes"), 1.0, 0.8)
}

pmv_extract_class_terms <- function(x) {
  unique(phenomap_drop_empty(vapply(
    phenomap_split_semicolon(x),
    phenomap_normalize_token,
    character(1)
  )))
}

pmv_split_id_text <- function(x) unique(phenomap_split_semicolon(x))

# ---- 1. load inputs ---------------------------------------------------------

pmv_load_inputs <- function(entity_dir = file.path("2_data", "tidy_entity"),
                            relationship_dir = file.path("2_data", "tidy_relationship")) {
  modules <- phenomap_read_csv_required(file.path(entity_dir, "nodes_module.csv"))
  studies <- phenomap_read_csv_required(file.path(entity_dir, "nodes_study.csv"))
  phenotypes <- phenomap_read_csv_required(file.path(entity_dir, "nodes_phenotype.csv"))
  edges_metabolite_module <- phenomap_read_csv_required(file.path(relationship_dir, "edges_metabolite_module.csv"))
  study_phenotype <- phenomap_read_csv_required(file.path(relationship_dir, "edges_study_phenotype.csv"))

  embeddings_path <- file.path(relationship_dir, "module_text_embeddings.rds")
  if (!file.exists(embeddings_path)) {
    stop(
      "Missing ", embeddings_path, ". This script reuses the embedding cache built by ",
      "1_code/2_tidy_relationship/05_tidy_module_module_relationship.R; run that script ",
      "at least once (with an embedding API key configured) before running this validation."
    )
  }
  embeddings_cache <- readRDS(embeddings_path)

  needed_module_cols <- c(
    "Lab_ID", "Study_ID", "title", "functional_summary", "hypothesis_type",
    "class_names", "hmdb_pathway_ids", "kegg_pathway_ids", "confidence_label"
  )
  for (nm in needed_module_cols) if (!nm %in% colnames(modules)) modules[[nm]] <- NA_character_
  modules <- modules[!is.na(modules$Lab_ID) & nzchar(modules$Lab_ID), needed_module_cols, drop = FALSE]

  if (!"MS2_Supported" %in% colnames(studies)) studies$MS2_Supported <- NA_character_
  if (!"Lab_ID" %in% colnames(studies) || !"Accession" %in% colnames(studies)) {
    stop("nodes_study.csv must contain Lab_ID and Accession.")
  }

  needed_edge_cols <- c("Metabolite_ID", "Module_ID", "Type")
  missing_edge_cols <- setdiff(needed_edge_cols, colnames(edges_metabolite_module))
  if (length(missing_edge_cols) > 0) {
    stop("edges_metabolite_module.csv missing columns: ", paste(missing_edge_cols, collapse = ", "))
  }

  if (!all(c("Study_ID", "Phenotype_ID") %in% colnames(study_phenotype))) {
    stop("edges_study_phenotype.csv must contain Study_ID and Phenotype_ID.")
  }

  list(
    modules = modules,
    studies = studies,
    phenotypes = phenotypes,
    edges_metabolite_module = edges_metabolite_module,
    study_phenotype = study_phenotype,
    embeddings_cache = embeddings_cache
  )
}

# ---- 2. restrict to modules with a cached embedding -------------------------

pmv_filter_to_embedded_modules <- function(modules, embeddings_cache) {
  cached_ids <- embeddings_cache$cache_key$Lab_ID
  has_embedding <- modules$Lab_ID %in% cached_ids
  n_total <- nrow(modules)
  n_kept <- sum(has_embedding)
  message(sprintf(
    "Embedding cache coverage: %d / %d modules (%.1f%%) have a cached title/summary embedding.",
    n_kept, n_total, 100 * n_kept / n_total
  ))
  if (n_kept < n_total) {
    message(sprintf(
      "%d module(s) dropped from validation for lack of a cached embedding (cache is likely older than nodes_module.csv).",
      n_total - n_kept
    ))
  }
  modules[has_embedding, , drop = FALSE]
}

# ---- 3. per-module metabolite/class/pathway sets -----------------------------

pmv_build_module_sets <- function(modules, edges_metabolite_module) {
  split_edges <- split(edges_metabolite_module, edges_metabolite_module$Module_ID)
  sets <- vector("list", nrow(modules))
  names(sets) <- modules$Lab_ID

  for (i in seq_len(nrow(modules))) {
    module_edges <- split_edges[[modules$Lab_ID[[i]]]]
    if (is.null(module_edges)) module_edges <- data.frame(Metabolite_ID = character(), Type = character())
    ids_by_type <- split(module_edges$Metabolite_ID, module_edges$Type)

    sets[[i]] <- list(
      core = phenomap_drop_empty(ids_by_type$core),
      supporting = phenomap_drop_empty(ids_by_type$supporting),
      contextual = phenomap_drop_empty(ids_by_type$contextual),
      class = pmv_extract_class_terms(modules$class_names[[i]]),
      pathway = unique(c(
        pmv_split_id_text(modules$hmdb_pathway_ids[[i]]),
        pmv_split_id_text(modules$kegg_pathway_ids[[i]])
      ))
    )
  }
  sets
}

# ---- 4. vectorized N x N similarity matrices ---------------------------------

pmv_cosine_similarity_matrix <- function(mat) {
  norm <- sqrt(rowSums(mat * mat))
  norm[norm == 0 | is.na(norm)] <- 1e-12
  normed <- mat / norm
  normed %*% t(normed)
}

pmv_incidence_matrix <- function(sets, n) {
  # sets: list of length n, each a character vector of terms for that module.
  vocab <- unique(unlist(sets, use.names = FALSE))
  if (length(vocab) == 0) {
    return(Matrix::Matrix(0, nrow = n, ncol = 1, sparse = TRUE))
  }
  vocab_index <- setNames(seq_along(vocab), vocab)
  row_i <- integer(0)
  col_j <- integer(0)
  for (i in seq_len(n)) {
    terms <- sets[[i]]
    if (length(terms) == 0) next
    idx <- vocab_index[terms]
    row_i <- c(row_i, rep(i, length(idx)))
    col_j <- c(col_j, unname(idx))
  }
  if (length(row_i) == 0) {
    return(Matrix::Matrix(0, nrow = n, ncol = length(vocab), sparse = TRUE))
  }
  Matrix::sparseMatrix(i = row_i, j = col_j, x = 1, dims = c(n, length(vocab)))
}

pmv_pairwise_jaccard_from_incidence <- function(inc) {
  inter <- as.matrix(inc %*% Matrix::t(inc))
  sizes <- Matrix::rowSums(inc)
  uni <- outer(sizes, sizes, "+") - inter
  jac <- inter / uni
  jac[uni == 0] <- 0
  jac
}

pmv_build_similarity_matrices <- function(modules, module_sets, embeddings_cache) {
  n <- nrow(modules)
  lab_ids <- modules$Lab_ID

  title_emb_by_id <- setNames(embeddings_cache$title_embeddings, embeddings_cache$cache_key$Lab_ID)
  summary_emb_by_id <- setNames(embeddings_cache$summary_embeddings, embeddings_cache$cache_key$Lab_ID)
  title_mat <- do.call(rbind, title_emb_by_id[lab_ids])
  summary_mat <- do.call(rbind, summary_emb_by_id[lab_ids])

  title_cos <- pmv_cosine_similarity_matrix(title_mat)
  summary_cos <- pmv_cosine_similarity_matrix(summary_mat)

  ht <- tolower(trimws(modules$hypothesis_type))
  ht[is.na(ht) | !nzchar(ht)] <- NA
  same_ht <- outer(ht, ht, `==`)
  same_ht <- matrix(as.numeric(same_ht), nrow = n)
  same_ht[is.na(same_ht)] <- 0

  core_inc <- pmv_incidence_matrix(lapply(module_sets, `[[`, "core"), n)
  supporting_inc <- pmv_incidence_matrix(lapply(module_sets, `[[`, "supporting"), n)
  contextual_inc <- pmv_incidence_matrix(lapply(module_sets, `[[`, "contextual"), n)
  class_inc <- pmv_incidence_matrix(lapply(module_sets, `[[`, "class"), n)
  pathway_inc <- pmv_incidence_matrix(lapply(module_sets, `[[`, "pathway"), n)

  core_jac <- pmv_pairwise_jaccard_from_incidence(core_inc)
  supporting_jac <- pmv_pairwise_jaccard_from_incidence(supporting_inc)
  contextual_jac <- pmv_pairwise_jaccard_from_incidence(contextual_inc)
  class_jac <- pmv_pairwise_jaccard_from_incidence(class_inc)
  pathway_jac <- pmv_pairwise_jaccard_from_incidence(pathway_inc)

  metabolite_score <- 0.50 * core_jac + 0.30 * supporting_jac + 0.20 * contextual_jac
  compositional_score <- 0.40 * metabolite_score + 0.25 * pathway_jac + 0.25 * class_jac + 0.10 * same_ht
  biological_score <- 0.50 * summary_cos + 0.40 * title_cos + 0.10 * same_ht
  combined_score <- 0.75 * pmax(biological_score, compositional_score) +
    0.25 * ((biological_score + compositional_score) / 2)

  dimnames(combined_score) <- list(lab_ids, lab_ids)
  dimnames(biological_score) <- list(lab_ids, lab_ids)
  dimnames(compositional_score) <- list(lab_ids, lab_ids)

  list(
    combined = combined_score,
    biological_only = biological_score,
    compositional_only = compositional_score
  )
}

# ---- 5. module weight (confidence x MS2 support) -----------------------------

pmv_build_module_weight <- function(modules, studies) {
  study_ms2 <- setNames(studies$MS2_Supported, studies$Lab_ID)
  ms2_for_module <- unname(study_ms2[modules$Study_ID])
  weight <- pmv_confidence_weight(modules$confidence_label) * pmv_ms2_weight(ms2_for_module)
  setNames(weight, modules$Lab_ID)
}

# ---- 6. leave-one-study-out evaluation ---------------------------------------

pmv_aggregate_score <- function(sim_submatrix, weight_query, weight_candidate, method) {
  # sim_submatrix: query modules (rows) x candidate modules (cols)
  if (length(sim_submatrix) == 0) return(NA_real_)
  if (method == "weighted_mean") {
    weight_mat <- outer(weight_query, weight_candidate)
    denom <- sum(weight_mat)
    if (denom <= 0) return(NA_real_)
    return(sum(weight_mat * sim_submatrix) / denom)
  }
  if (method == "max") {
    return(max(sim_submatrix))
  }
  if (method == "mean_of_query_max") {
    per_query_best <- apply(sim_submatrix, 1, max)
    denom <- sum(weight_query)
    if (denom <= 0) return(mean(per_query_best))
    return(sum(per_query_best * weight_query) / denom)
  }
  stop("Unknown aggregation method: ", method)
}

pmv_evaluate <- function(modules, similarity_matrices, module_weight, study_phenotype, phenotypes,
                         aggregation_methods = c("weighted_mean", "max", "mean_of_query_max")) {
  study_to_phenotypes <- split(study_phenotype$Phenotype_ID, study_phenotype$Study_ID)
  phenotype_name_lookup <- setNames(phenotypes$Phenotype, phenotypes$Lab_ID)

  # module -> its phenotype(s), via its own Study_ID
  module_phenotypes <- lapply(modules$Study_ID, function(sid) study_to_phenotypes[[sid]])
  names(module_phenotypes) <- modules$Lab_ID

  query_study_ids <- sort(unique(modules$Study_ID[modules$Study_ID %in% names(study_to_phenotypes)]))

  study_rows <- list()
  row_i <- 0L

  for (sid in query_study_ids) {
    query_idx <- which(modules$Study_ID == sid)
    if (length(query_idx) == 0) next
    query_ids <- modules$Lab_ID[query_idx]
    true_phenotype_ids <- unique(phenomap_drop_empty(study_to_phenotypes[[sid]]))
    if (length(true_phenotype_ids) == 0) next

    candidate_idx <- which(modules$Study_ID != sid)
    if (length(candidate_idx) == 0) next
    candidate_ids <- modules$Lab_ID[candidate_idx]

    # candidate module -> phenotype (expand modules that map to >1 phenotype)
    cand_phenotype_list <- module_phenotypes[candidate_ids]
    cand_phenotype_list <- lapply(cand_phenotype_list, phenomap_drop_empty)
    has_phenotype <- lengths(cand_phenotype_list) > 0
    candidate_ids <- candidate_ids[has_phenotype]
    cand_phenotype_list <- cand_phenotype_list[has_phenotype]
    if (length(candidate_ids) == 0) next

    expanded <- data.frame(
      Module_ID = rep(candidate_ids, lengths(cand_phenotype_list)),
      Phenotype_ID = unlist(cand_phenotype_list, use.names = FALSE),
      stringsAsFactors = FALSE
    )
    modules_by_phenotype <- split(expanded$Module_ID, expanded$Phenotype_ID)
    n_candidate_phenotypes <- length(modules_by_phenotype)
    has_independent_replication <- any(true_phenotype_ids %in% names(modules_by_phenotype))

    for (variant_name in names(similarity_matrices)) {
      sim_mat <- similarity_matrices[[variant_name]]

      phenotype_scores <- vapply(names(modules_by_phenotype), function(ph_id) {
        NA_real_
      }, numeric(1))

      for (method in aggregation_methods) {
        scores <- vapply(names(modules_by_phenotype), function(ph_id) {
          cand_mod_ids <- modules_by_phenotype[[ph_id]]
          sub <- sim_mat[query_ids, cand_mod_ids, drop = FALSE]
          pmv_aggregate_score(
            sub,
            weight_query = module_weight[query_ids],
            weight_candidate = module_weight[cand_mod_ids],
            method = method
          )
        }, numeric(1))

        ord <- order(-scores)
        ranked_phenotypes <- names(scores)[ord]
        ranks <- match(ranked_phenotypes, ranked_phenotypes) # 1..n in ranked order
        rank_of <- setNames(seq_along(ranked_phenotypes), ranked_phenotypes)

        true_ranks <- rank_of[true_phenotype_ids]
        true_ranks <- true_ranks[!is.na(true_ranks)]
        best_rank <- if (length(true_ranks) == 0) NA_integer_ else min(true_ranks)
        best_score <- if (is.na(best_rank)) NA_real_ else scores[ranked_phenotypes[best_rank]]

        top1_id <- ranked_phenotypes[1]
        top1_score <- scores[[top1_id]]

        row_i <- row_i + 1L
        study_rows[[row_i]] <- data.frame(
          Study_ID = sid,
          Similarity_Variant = variant_name,
          Aggregation_Method = method,
          Query_Module_N = length(query_ids),
          N_Candidate_Phenotypes = n_candidate_phenotypes,
          True_Phenotype_IDs = paste(true_phenotype_ids, collapse = "; "),
          True_Phenotype_Names = paste(phenomap_drop_empty(phenotype_name_lookup[true_phenotype_ids]), collapse = "; "),
          Has_Independent_Replication = has_independent_replication,
          Best_True_Rank = best_rank,
          Best_True_Score = best_score,
          Top1_Predicted_Phenotype_ID = top1_id,
          Top1_Predicted_Phenotype_Name = unname(phenotype_name_lookup[top1_id]),
          Top1_Predicted_Score = top1_score,
          Top1_Hit = !is.na(best_rank) && best_rank == 1,
          Top3_Hit = !is.na(best_rank) && best_rank <= 3,
          Top5_Hit = !is.na(best_rank) && best_rank <= 5,
          Reciprocal_Rank = if (is.na(best_rank)) 0 else 1 / best_rank,
          stringsAsFactors = FALSE
        )
      }
    }
  }

  if (length(study_rows) == 0) return(data.frame())
  do.call(rbind, study_rows)
}

pmv_summarize <- function(study_level_results) {
  if (nrow(study_level_results) == 0) return(data.frame())
  keys <- unique(study_level_results[, c("Similarity_Variant", "Aggregation_Method")])
  rows <- list()
  for (i in seq_len(nrow(keys))) {
    sub <- study_level_results[
      study_level_results$Similarity_Variant == keys$Similarity_Variant[[i]] &
        study_level_results$Aggregation_Method == keys$Aggregation_Method[[i]],
      ,
      drop = FALSE
    ]
    n_total <- nrow(sub)
    evaluable <- sub[sub$Has_Independent_Replication, , drop = FALSE]
    n_excluded <- n_total - nrow(evaluable)
    n_evaluated <- nrow(evaluable)

    baseline_top1 <- mean(1 / evaluable$N_Candidate_Phenotypes)
    baseline_top3 <- mean(pmin(3 / evaluable$N_Candidate_Phenotypes, 1))
    baseline_top5 <- mean(pmin(5 / evaluable$N_Candidate_Phenotypes, 1))

    rows[[i]] <- data.frame(
      Similarity_Variant = keys$Similarity_Variant[[i]],
      Aggregation_Method = keys$Aggregation_Method[[i]],
      N_Query_Studies_With_Phenotype = n_total,
      N_Excluded_No_Independent_Replication = n_excluded,
      N_Evaluated = n_evaluated,
      Accuracy_Top1 = if (n_evaluated == 0) NA_real_ else mean(evaluable$Top1_Hit),
      Accuracy_Top3 = if (n_evaluated == 0) NA_real_ else mean(evaluable$Top3_Hit),
      Accuracy_Top5 = if (n_evaluated == 0) NA_real_ else mean(evaluable$Top5_Hit),
      Mean_Reciprocal_Rank = if (n_evaluated == 0) NA_real_ else mean(evaluable$Reciprocal_Rank),
      Baseline_Random_Top1 = if (n_evaluated == 0) NA_real_ else baseline_top1,
      Baseline_Random_Top3 = if (n_evaluated == 0) NA_real_ else baseline_top3,
      Baseline_Random_Top5 = if (n_evaluated == 0) NA_real_ else baseline_top5,
      Mean_N_Candidate_Phenotypes = if (n_evaluated == 0) NA_real_ else mean(evaluable$N_Candidate_Phenotypes),
      stringsAsFactors = FALSE
    )
  }
  out <- do.call(rbind, rows)
  out[order(out$Similarity_Variant, out$Aggregation_Method), , drop = FALSE]
}

# ---- 7. main entry point ------------------------------------------------------

run_module_projection_validation <- function(
  entity_dir = file.path("2_data", "tidy_entity"),
  relationship_dir = file.path("2_data", "tidy_relationship"),
  output_dir = file.path("2_data", "analysis", "module_projection_validation")
) {
  message("Loading inputs...")
  inputs <- pmv_load_inputs(entity_dir, relationship_dir)

  modules <- pmv_filter_to_embedded_modules(inputs$modules, inputs$embeddings_cache)
  if (nrow(modules) < 2) stop("Fewer than 2 modules have cached embeddings; cannot evaluate.")

  message("Building module metabolite/class/pathway sets...")
  module_sets <- pmv_build_module_sets(modules, inputs$edges_metabolite_module)

  message(sprintf("Building %d x %d similarity matrices (this is the slow step)...", nrow(modules), nrow(modules)))
  similarity_matrices <- pmv_build_similarity_matrices(modules, module_sets, inputs$embeddings_cache)

  module_weight <- pmv_build_module_weight(modules, inputs$studies)

  message("Running leave-one-study-out evaluation...")
  study_level_results <- pmv_evaluate(
    modules = modules,
    similarity_matrices = similarity_matrices,
    module_weight = module_weight,
    study_phenotype = inputs$study_phenotype,
    phenotypes = inputs$phenotypes
  )

  summary_by_method <- pmv_summarize(study_level_results)

  phenomap_write_csv(study_level_results, file.path(output_dir, "study_level_results.csv"))
  phenomap_write_csv(summary_by_method, file.path(output_dir, "summary_by_method.csv"))

  message("\n=== PhenoMAP module/study projection: leave-one-study-out validation ===\n")
  print(summary_by_method, row.names = FALSE)
  message(
    "\nAccuracy_Top1/3/5 = fraction of held-out studies whose real phenotype was ranked ",
    "1st / in the top 3 / in the top 5 out of that study's candidate phenotype pool.\n",
    "Baseline_Random_* = expected accuracy if phenotypes were ranked randomly (for context).\n",
    "N_Excluded_No_Independent_Replication = studies whose real phenotype has no OTHER study ",
    "in the atlas, so it can never be recovered once this study's own modules are held out; ",
    "these are excluded from the accuracy numbers above rather than counted as automatic misses.\n",
    "Full per-study detail (including which phenotype was predicted instead) is in ",
    file.path(output_dir, "study_level_results.csv"), "."
  )

  invisible(list(study_level_results = study_level_results, summary_by_method = summary_by_method))
}

if (identical(environment(), globalenv()) && !interactive()) {
  run_module_projection_validation()
}
