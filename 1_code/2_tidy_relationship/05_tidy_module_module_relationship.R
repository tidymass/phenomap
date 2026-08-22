# Generate PhenoMAP module-module similarity relationship table.
#
# --min_similarity_score is the ONLY filter on which pairs make it into
# edges_module_module.csv (default 0.70 when the script is run directly, see
# the CLI dispatcher below). There used to also be an unconditional
# filter_existing_module_module_edges(min_similarity_score = 0.70) call at
# the bottom of this file that re-filtered and overwrote the just-written
# CSV to a stricter, hardcoded 0.70 cutoff every single time this script ran
# -- silently discarding whatever --min_similarity_score the caller actually
# asked for. Removed as a bug fix (2026-08-21); if a second, stricter cutoff
# is ever wanted, pass a higher --min_similarity_score instead of adding a
# second unconditional filtering pass.
#
# Pairwise scoring is VECTORIZED (2026-08-22), not a per-pair loop. The
# original implementation scored each of the ~n^2/2 module pairs with its
# own R function calls (jaccard sets + cosine similarity) inside a double
# for loop, parallelized across CPU cores with parallel::mclapply and a
# persistent module_pair_scores.rds cache to avoid re-paying for pairs
# already scored in a previous rebuild. Even after fixing a quadratic list-
# growth bug in that loop (see git history), it still measured ~600
# pairs/sec on a single core against this project's real data -- i.e. tens
# of minutes even fully parallel, and it only gets worse as more modules are
# added over time (module count grows -> pair count grows quadratically).
#
# The pairwise math is entirely made of two vectorizable primitives applied
# to EVERY pair at once instead of one pair at a time:
#   - cosine similarity of two embedding vectors -> for all pairs at once,
#     this is exactly what a single matrix product of L2-normalized
#     embedding rows gives you (tcrossprod), computed by BLAS instead of by
#     the R interpreter.
#   - Jaccard overlap of two ID/term sets -> encode each module's set as a
#     0/1 row in a sparse (module x term) indicator matrix; a single sparse
#     matrix product of that indicator matrix against its own transpose
#     gives the pairwise intersection COUNT for every pair at once (see
#     build_jaccard_matrix() below).
# Doing the whole n x n score matrix this way took ~37 seconds for this
# project's ~4,300 modules (~9.3M pairs) on a single core, vs. tens of
# minutes to hours for the old parallel per-pair loop -- and correctness was
# validated against the old loop-based scorer on a held-out subset of real
# modules (exact match to floating-point precision, ~1e-15). Because a full
# from-scratch rescore is now cheap regardless of how module Lab_IDs got
# renumbered, the old persistent module_pair_scores.rds cache (and the
# --workers CLI flag that controlled its parallel fill) is no longer needed
# and has been removed -- one less moving part, one less place for a stale
# cache to go wrong.
#
# This does still scale as O(n^2) in module count -- that is inherent to
# "compare every module to every other module", vectorized or not -- so if
# the module count grows by another order of magnitude (tens of thousands),
# expect this to take proportionately longer and the dense n x n score
# matrices to use proportionately more memory (a dense n x n double matrix
# is 8*n^2 bytes; ~4,300 modules is ~150MB per matrix, comfortably fine, but
# e.g. 40,000 modules would be ~13GB per matrix and would need a chunked or
# sparse-output rewrite rather than materializing full dense matrices).
#
# Output:
#   edges_module_module.csv
#   module_text_embeddings.rds

source(file.path("1_code", "2_tidy_relationship", "00_relationship_helpers.R"))

embedding_endpoint <- function(base_url) {
  endpoint <- sub("/+$", "", base_url)
  if (!grepl("/embeddings$", endpoint)) endpoint <- paste0(endpoint, "/embeddings")
  endpoint
}

call_embedding_batch <- function(texts,
                                 api_key = Sys.getenv("OPENAI_API_KEY"),
                                 model = "text-embedding-3-small",
                                 base_url = "https://api.openai.com/v1") {
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required.")
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.")
  if (is.na(api_key) || !nzchar(api_key)) stop("API key is empty. Set OPENAI_API_KEY.")

  resp <- httr::POST(
    embedding_endpoint(base_url),
    httr::add_headers(
      Authorization = paste("Bearer", api_key),
      `Content-Type` = "application/json"
    ),
    body = jsonlite::toJSON(list(model = model, input = as.list(texts)), auto_unbox = TRUE),
    encode = "raw",
    httr::timeout(120)
  )

  txt <- httr::content(resp, as = "text", encoding = "UTF-8")
  if (httr::status_code(resp) >= 400) {
    stop("Embedding request failed with status ", httr::status_code(resp), ": ", txt)
  }

  payload <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
  lapply(payload$data, function(x) as.numeric(unlist(x$embedding, use.names = FALSE)))
}

embed_text_vector <- function(texts,
                              api_key,
                              model,
                              base_url,
                              batch_size,
                              label) {
  texts <- as.character(texts)
  texts[is.na(texts) | !nzchar(texts)] <- " "
  embeddings <- vector("list", length(texts))

  for (start in seq(1L, length(texts), by = batch_size)) {
    end <- min(length(texts), start + batch_size - 1L)
    message("Embedding module ", label, " ", start, "-", end, " / ", length(texts))
    embeddings[start:end] <- call_embedding_batch(
      texts[start:end],
      api_key = api_key,
      model = model,
      base_url = base_url
    )
  }
  embeddings
}

# The embedding cache is keyed by TEXT CONTENT (title / functional_summary +
# model), never by Lab_ID. Lab_ID is a processing-order artifact -- adding or
# removing studies upstream (e.g. Part 3 re-run after new studies are added)
# shifts nearly every module's Lab_ID even though the module's own title and
# functional_summary text is unchanged. A Lab_ID-inclusive key would treat
# that as "everything changed" and force a full, unnecessary re-embed of
# every module. Keying on content instead means: unchanged module text is
# always reused from cache regardless of how its ID was renumbered, and only
# genuinely new or edited text triggers a paid OpenAI call.
#
# Storage: a hashed environment (O(1) lookup) mapping
#   "<model><unit-separator><text>" -> embedding vector
# persisted via saveRDS/readRDS (R serializes environment contents fine).

embedding_cache_key <- function(text, model) {
  paste0(model, "␟", text)
}

new_embedding_store <- function() new.env(parent = emptyenv())

store_get <- function(store, key) {
  if (exists(key, envir = store, inherits = FALSE)) get(key, envir = store, inherits = FALSE) else NULL
}

store_set <- function(store, key, value) {
  assign(key, value, envir = store)
}

# Best-effort migration from the old (pre-2026-08-21) Lab_ID-inclusive
# whole-dataframe cache format into the new content-keyed store, so a
# pre-existing module_text_embeddings.rds isn't just thrown away. Only rows
# whose recorded `model` matches the current model are migrated.
migrate_legacy_cache <- function(on_disk, store, model) {
  old_key <- on_disk$cache_key
  if (!is.data.frame(old_key) || !all(c("title", "functional_summary", "model") %in% colnames(old_key))) {
    return(store)
  }
  n <- nrow(old_key)
  for (i in seq_len(n)) {
    if (!identical(old_key$model[[i]], model)) next
    if (i <= length(on_disk$title_embeddings) && !is.null(on_disk$title_embeddings[[i]])) {
      store_set(store, embedding_cache_key(old_key$title[[i]], model), on_disk$title_embeddings[[i]])
    }
    if (i <= length(on_disk$summary_embeddings) && !is.null(on_disk$summary_embeddings[[i]])) {
      store_set(store, embedding_cache_key(old_key$functional_summary[[i]], model), on_disk$summary_embeddings[[i]])
    }
  }
  store
}

embed_text_vector_cached <- function(texts, store, api_key, model, base_url, batch_size, label) {
  texts <- as.character(texts)
  texts[is.na(texts) | !nzchar(texts)] <- " "
  keys <- vapply(texts, embedding_cache_key, character(1), model = model)

  result <- vector("list", length(texts))
  missing_idx <- integer(0)
  for (i in seq_along(texts)) {
    hit <- store_get(store, keys[[i]])
    if (!is.null(hit)) {
      result[[i]] <- hit
    } else {
      missing_idx <- c(missing_idx, i)
    }
  }

  reused <- length(texts) - length(missing_idx)
  if (length(missing_idx) > 0) {
    message(
      "Embedding ", label, ": ", length(missing_idx), " new (reused ", reused,
      " unchanged from cache)"
    )
    fetched <- embed_text_vector(texts[missing_idx], api_key, model, base_url, batch_size, label)
    for (k in seq_along(missing_idx)) {
      i <- missing_idx[[k]]
      result[[i]] <- fetched[[k]]
      store_set(store, keys[[i]], fetched[[k]])
    }
  } else {
    message("Embedding ", label, ": all ", length(texts), " reused from cache (0 new)")
  }

  result
}

load_or_build_embeddings <- function(modules,
                                     output_dir,
                                     api_key = Sys.getenv("OPENAI_API_KEY"),
                                     model = "text-embedding-3-small",
                                     base_url = "https://api.openai.com/v1",
                                     batch_size = 64L) {
  cache_path <- file.path(output_dir, "module_text_embeddings.rds")
  store <- new_embedding_store()

  if (file.exists(cache_path)) {
    on_disk <- tryCatch(readRDS(cache_path), error = function(e) NULL)
    if (is.list(on_disk) && !is.null(on_disk$store) && is.environment(on_disk$store)) {
      # already the new content-keyed format
      store <- on_disk$store
    } else if (is.list(on_disk) && !is.null(on_disk$cache_key)) {
      # legacy Lab_ID-keyed format -- migrate what we can
      store <- migrate_legacy_cache(on_disk, store, model)
    }
  }

  title_embeddings <- embed_text_vector_cached(modules$title, store, api_key, model, base_url, batch_size, "titles")
  summary_embeddings <- embed_text_vector_cached(modules$functional_summary, store, api_key, model, base_url, batch_size, "summaries")

  saveRDS(list(store = store), cache_path)
  list(title_embeddings = title_embeddings, summary_embeddings = summary_embeddings)
}

split_id_text <- function(x) {
  unique(phenomap_split_semicolon(x))
}

extract_class_terms <- function(x) {
  unique(phenomap_drop_empty(vapply(
    phenomap_split_semicolon(x),
    phenomap_normalize_token,
    character(1)
  )))
}

build_module_sets <- function(modules, relationship_dir) {
  edges <- phenomap_read_csv_required(file.path(relationship_dir, "edges_metabolite_module.csv"))
  if (!all(c("Metabolite_ID", "Module_ID", "Type") %in% colnames(edges))) {
    stop("edges_metabolite_module.csv must contain Metabolite_ID, Module_ID and Type.")
  }

  split_edges <- split(edges, edges$Module_ID)
  sets <- vector("list", nrow(modules))

  for (i in seq_len(nrow(modules))) {
    module_edges <- split_edges[[modules$Lab_ID[[i]]]]
    if (is.null(module_edges)) module_edges <- data.frame(Metabolite_ID = character(), Type = character())
    ids_by_type <- split(module_edges$Metabolite_ID, module_edges$Type)

    sets[[i]] <- list(
      core = phenomap_drop_empty(ids_by_type$core),
      supporting = phenomap_drop_empty(ids_by_type$supporting),
      contextual = phenomap_drop_empty(ids_by_type$contextual),
      class = extract_class_terms(modules$class_names[[i]]),
      pathway = unique(c(
        split_id_text(modules$hmdb_pathway_ids[[i]]),
        split_id_text(modules$kegg_pathway_ids[[i]])
      ))
    )
  }
  sets
}

# ---- Vectorized pairwise scoring -------------------------------------------
#
# Each of the helpers below computes one FULL n x n matrix (module i vs.
# module j, all i/j at once) instead of a per-pair scalar. They are
# drop-in-equivalent to the old scalar cosine_similarity() /
# same_value_score() / phenomap_jaccard() used pairwise in a loop -- see the
# header comment above for how/why they were validated to match exactly.

phenomap_clean_scalar_vec <- function(x) {
  x <- trimws(as.character(x))
  bad <- is.na(x) | !nzchar(x) | toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")
  x[bad] <- NA_character_
  x
}

# n x n same-hypothesis-type indicator matrix. Equivalent to calling the old
# scalar same_value_score(hypothesis_type[i], hypothesis_type[j]) for every
# (i, j): NA on either side -> 0, else 1 iff the (cleaned, lower-cased)
# values are identical.
build_same_hypothesis_matrix <- function(hypothesis_type) {
  cleaned <- tolower(phenomap_clean_scalar_vec(hypothesis_type))
  ids <- match(cleaned, unique(cleaned[!is.na(cleaned)]))
  same <- outer(ids, ids, `==`)
  same[is.na(same)] <- FALSE
  storage.mode(same) <- "double"
  same
}

# n x n cosine similarity matrix for a list of numeric embedding vectors (one
# per module). Equivalent to calling the old scalar cosine_similarity(x, y)
# for every (i, j): a zero-norm embedding is treated as similarity 0 against
# everything (including itself), same as the original's zero-denominator
# guard.
build_cosine_similarity_matrix <- function(embedding_list) {
  d <- length(embedding_list[[1]])
  mat <- matrix(0, nrow = length(embedding_list), ncol = d)
  for (i in seq_along(embedding_list)) {
    v <- embedding_list[[i]]
    if (!is.null(v) && length(v) == d) mat[i, ] <- v
  }
  norms <- sqrt(rowSums(mat * mat))
  ok <- norms > 0 & !is.na(norms)
  mat[ok, ] <- mat[ok, , drop = FALSE] / norms[ok]
  mat[!ok, ] <- 0
  tcrossprod(mat)
}

# n x n Jaccard-overlap matrix for a list of character-vector ID/term sets
# (one set per module). Equivalent to calling the old scalar
# phenomap_jaccard(x, y)$jaccard for every (i, j): both-empty pairs score 0
# rather than NaN/0-of-0. Implemented as a single sparse (module x term)
# indicator matrix product instead of a per-pair intersect()/union() loop --
# this is the main reason the whole rescore drops from tens of minutes to
# seconds. Requires the Matrix package, which ships as a "recommended"
# package with every standard R installation (no separate install needed).
build_jaccard_matrix <- function(set_list) {
  if (!requireNamespace("Matrix", quietly = TRUE)) {
    stop("Package 'Matrix' is required (it ships with base R as a recommended package).")
  }
  n <- length(set_list)
  set_list <- lapply(set_list, function(x) unique(x[!is.na(x) & nzchar(x)]))
  sizes <- lengths(set_list)
  terms <- unique(unlist(set_list, use.names = FALSE))
  if (length(terms) == 0) return(matrix(0, n, n))

  term_id <- setNames(seq_along(terms), terms)
  rows <- rep(seq_len(n), sizes)
  cols <- term_id[unlist(set_list, use.names = FALSE)]
  indicator <- Matrix::sparseMatrix(i = rows, j = cols, x = 1, dims = c(n, length(terms)))

  overlap <- as.matrix(Matrix::tcrossprod(indicator))
  union_n <- outer(sizes, sizes, `+`) - overlap
  jaccard <- overlap / union_n
  jaccard[union_n == 0] <- 0
  jaccard
}

# Scores every module pair at once and returns the edges_module_module rows
# that clear min_similarity_score, ready for Lab_ID assignment. See the
# header comment for the design rationale.
score_all_module_pairs <- function(modules, embeddings, module_sets, min_similarity_score) {
  title_sim <- build_cosine_similarity_matrix(embeddings$title_embeddings)
  summary_sim <- build_cosine_similarity_matrix(embeddings$summary_embeddings)
  same_hypothesis <- build_same_hypothesis_matrix(modules$hypothesis_type)

  core_jac <- build_jaccard_matrix(lapply(module_sets, `[[`, "core"))
  supporting_jac <- build_jaccard_matrix(lapply(module_sets, `[[`, "supporting"))
  contextual_jac <- build_jaccard_matrix(lapply(module_sets, `[[`, "contextual"))
  class_jac <- build_jaccard_matrix(lapply(module_sets, `[[`, "class"))
  pathway_jac <- build_jaccard_matrix(lapply(module_sets, `[[`, "pathway"))

  metabolite_score <- 0.50 * core_jac + 0.30 * supporting_jac + 0.20 * contextual_jac
  compositional_score <- 0.40 * metabolite_score + 0.25 * pathway_jac + 0.25 * class_jac +
    0.10 * same_hypothesis
  biological_score <- 0.50 * summary_sim + 0.40 * title_sim + 0.10 * same_hypothesis
  final_score <- 0.75 * pmax(biological_score, compositional_score) +
    0.25 * ((biological_score + compositional_score) / 2)

  rm(title_sim, summary_sim, same_hypothesis, core_jac, supporting_jac, contextual_jac,
     class_jac, pathway_jac, metabolite_score)

  # Only the upper triangle (i < j) is a distinct pair; the matrices above
  # are symmetric with a meaningless diagonal (a module "vs. itself").
  keep <- upper.tri(final_score) & !is.na(final_score) & final_score >= min_similarity_score
  idx <- which(keep, arr.ind = TRUE)
  if (nrow(idx) == 0) return(data.frame())

  i_idx <- idx[, "row"]
  j_idx <- idx[, "col"]
  scores <- final_score[idx]
  bio <- biological_score[idx]
  comp <- compositional_score[idx]

  type <- ifelse(
    bio >= 0.35 & comp >= 0.35 & abs(bio - comp) <= 0.10, "mixed",
    ifelse(bio >= comp, "biological", "compositional")
  )
  tier <- as.character(cut(
    scores,
    breaks = c(-Inf, 0.35, 0.55, 0.75, Inf),
    labels = c("candidate", "low", "medium", "high"),
    right = FALSE
  ))

  data.frame(
    Module_ID_1 = modules$Lab_ID[i_idx],
    Relationship = "similar to",
    Module_ID_2 = modules$Lab_ID[j_idx],
    Type = type,
    Similarity_Score = scores,
    Similarity_Tier = tier,
    Biological_Score = bio,
    Compositional_Score = comp,
    Cross_Study = modules$Study_ID[i_idx] != modules$Study_ID[j_idx],
    stringsAsFactors = FALSE
  )
}

build_module_module_relationship <- function(entity_dir = file.path("2_data", "tidy_entity"),
                                             relationship_dir = file.path("2_data", "tidy_relationship"),
                                             output_dir = relationship_dir,
                                             api_key = Sys.getenv("OPENAI_API_KEY"),
                                             embedding_model = "text-embedding-3-small",
                                             base_url = "https://api.openai.com/v1",
                                             embedding_batch_size = 64L,
                                             min_similarity_score = 0.70) {
  modules <- phenomap_read_csv_required(file.path(entity_dir, "nodes_module.csv"))
  needed <- c(
    "Lab_ID", "Study_ID", "module_id", "title", "functional_summary", "hypothesis_type",
    "class_names", "hmdb_pathway_ids", "kegg_pathway_ids"
  )
  for (nm in needed) if (!nm %in% colnames(modules)) modules[[nm]] <- NA_character_
  modules <- modules[!is.na(modules$Lab_ID) & nzchar(modules$Lab_ID), needed, drop = FALSE]
  modules <- modules[order(modules$Study_ID, modules$Lab_ID), , drop = FALSE]

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  embeddings <- load_or_build_embeddings(
    modules = modules,
    output_dir = output_dir,
    api_key = api_key,
    model = embedding_model,
    base_url = base_url,
    batch_size = embedding_batch_size
  )
  module_sets <- build_module_sets(modules, relationship_dir)

  out <- if (nrow(modules) < 2) {
    data.frame()
  } else {
    score_all_module_pairs(modules, embeddings, module_sets, min_similarity_score)
  }

  if (nrow(out) == 0) {
    out <- data.frame()
  } else {
    out <- out[order(-out$Similarity_Score, out$Module_ID_1, out$Module_ID_2), , drop = FALSE]
    # Module_ID_1/2 are already permanent, stable Lab_IDs; Module_ID_1/2
    # were assigned in modules-dataframe row order (i < j), not a fixed
    # canonical order of the IDs themselves, so pmin/pmax here (not the
    # existing 1/2 order) is what makes the pair key order-invariant.
    edge_key <- paste(pmin(out$Module_ID_1, out$Module_ID_2), pmax(out$Module_ID_1, out$Module_ID_2))
    out <- data.frame(
      Lab_ID = phenomap_assign_stable_ids(
        edge_key, "MOD_MOD_", file.path(output_dir, "module_module_edge_id_registry.csv")
      ),
      out,
      stringsAsFactors = FALSE
    )
  }

  phenomap_write_csv(out, file.path(output_dir, "edges_module_module.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  raw_args <- commandArgs(trailingOnly = TRUE)
  args <- phenomap_relationship_parse_args()
  if (!any(grepl("^--min_similarity_score=", raw_args))) args$min_similarity_score <- 0.70

  build_module_module_relationship(
    entity_dir = args$entity_dir,
    relationship_dir = args$relationship_dir,
    output_dir = args$relationship_dir,
    embedding_model = args$embedding_model,
    base_url = args$base_url,
    embedding_batch_size = args$embedding_batch_size,
    min_similarity_score = args$min_similarity_score
  )
}
