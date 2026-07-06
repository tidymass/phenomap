# Generate PhenoMAP module-module similarity relationship table.
#
# Output:
#   edges_module_module.csv
#   module_text_embeddings.rds

source(file.path("1_code", "2_tidy_relationship", "00_relationship_helpers.R"))

cosine_similarity <- function(x, y) {
  denom <- sqrt(sum(x * x)) * sqrt(sum(y * y))
  if (is.na(denom) || denom == 0) return(0)
  sum(x * y) / denom
}

same_value_score <- function(x, y) {
  x <- phenomap_clean_scalar(x)
  y <- phenomap_clean_scalar(y)
  if (is.na(x) || is.na(y)) return(0)
  as.numeric(identical(tolower(x), tolower(y)))
}

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

load_or_build_embeddings <- function(modules,
                                     output_dir,
                                     api_key = Sys.getenv("OPENAI_API_KEY"),
                                     model = "text-embedding-3-small",
                                     base_url = "https://api.openai.com/v1",
                                     batch_size = 64L) {
  cache_path <- file.path(output_dir, "module_text_embeddings.rds")
  cache_key <- data.frame(
    Lab_ID = modules$Lab_ID,
    title = modules$title,
    functional_summary = modules$functional_summary,
    model = model,
    stringsAsFactors = FALSE
  )

  if (file.exists(cache_path)) {
    cache <- readRDS(cache_path)
    if (is.list(cache) &&
        identical(cache$cache_key, cache_key) &&
        length(cache$title_embeddings) == nrow(modules) &&
        length(cache$summary_embeddings) == nrow(modules)) {
      return(cache)
    }
  }

  cache <- list(
    cache_key = cache_key,
    title_embeddings = embed_text_vector(
      modules$title, api_key, model, base_url, batch_size, "titles"
    ),
    summary_embeddings = embed_text_vector(
      modules$functional_summary, api_key, model, base_url, batch_size, "summaries"
    )
  )
  saveRDS(cache, cache_path)
  cache
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

similarity_tier <- function(score) {
  if (score >= 0.75) return("high")
  if (score >= 0.55) return("medium")
  if (score >= 0.35) return("low")
  "candidate"
}

similarity_type <- function(biological_score, compositional_score) {
  if (biological_score >= 0.35 && compositional_score >= 0.35 &&
      abs(biological_score - compositional_score) <= 0.10) {
    return("mixed")
  }
  if (biological_score >= compositional_score) return("biological")
  "compositional"
}

score_module_pair <- function(i, j, modules, embeddings, module_sets) {
  set_i <- module_sets[[i]]
  set_j <- module_sets[[j]]

  core <- phenomap_jaccard(set_i$core, set_j$core)
  supporting <- phenomap_jaccard(set_i$supporting, set_j$supporting)
  contextual <- phenomap_jaccard(set_i$contextual, set_j$contextual)
  class <- phenomap_jaccard(set_i$class, set_j$class)
  pathway <- phenomap_jaccard(set_i$pathway, set_j$pathway)
  same_hypothesis <- same_value_score(modules$hypothesis_type[[i]], modules$hypothesis_type[[j]])

  metabolite_score <- 0.50 * core$jaccard +
    0.30 * supporting$jaccard +
    0.20 * contextual$jaccard

  compositional_score <- 0.40 * metabolite_score +
    0.25 * pathway$jaccard +
    0.25 * class$jaccard +
    0.10 * same_hypothesis

  biological_score <- 0.50 * cosine_similarity(
    embeddings$summary_embeddings[[i]],
    embeddings$summary_embeddings[[j]]
  ) +
    0.40 * cosine_similarity(
      embeddings$title_embeddings[[i]],
      embeddings$title_embeddings[[j]]
    ) +
    0.10 * same_hypothesis

  final_score <- 0.75 * max(biological_score, compositional_score) +
    0.25 * mean(c(biological_score, compositional_score))

  data.frame(
    Module_ID_1 = modules$Lab_ID[[i]],
    Relationship = "similar to",
    Module_ID_2 = modules$Lab_ID[[j]],
    Type = similarity_type(biological_score, compositional_score),
    Similarity_Score = final_score,
    Similarity_Tier = similarity_tier(final_score),
    Biological_Score = biological_score,
    Compositional_Score = compositional_score,
    Cross_Study = !identical(modules$Study_ID[[i]], modules$Study_ID[[j]]),
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
                                             min_similarity_score = 0.35) {
  modules <- phenomap_read_csv_required(file.path(entity_dir, "nodes_module.csv"))
  needed <- c(
    "Lab_ID", "Study_ID", "title", "functional_summary", "hypothesis_type",
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

  rows <- list()
  row_i <- 0L
  if (nrow(modules) >= 2) {
    for (i in seq_len(nrow(modules) - 1L)) {
      for (j in seq.int(i + 1L, nrow(modules))) {
        one <- score_module_pair(i, j, modules, embeddings, module_sets)
        if (!is.na(one$Similarity_Score[[1]]) &&
            one$Similarity_Score[[1]] >= min_similarity_score) {
          row_i <- row_i + 1L
          rows[[row_i]] <- one
        }
      }
    }
  }

  if (length(rows) == 0) {
    out <- data.frame()
  } else {
    out <- do.call(rbind, rows)
    out <- out[order(-out$Similarity_Score, out$Module_ID_1, out$Module_ID_2), , drop = FALSE]
    out <- data.frame(
      Lab_ID = sprintf("MOD_MOD_%06d", seq_len(nrow(out))),
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
  if (!any(grepl("^--min_similarity_score=", raw_args))) args$min_similarity_score <- 0.35

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

filter_existing_module_module_edges <- function(
  relationship_dir = file.path("2_data", "tidy_relationship"),
  min_similarity_score = 0.70
) {
  path <- file.path(relationship_dir, "edges_module_module.csv")
  edges <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  edges <- edges[edges$Similarity_Score >= min_similarity_score, , drop = FALSE]
  edges <- edges[order(-edges$Similarity_Score, edges$Module_ID_1, edges$Module_ID_2), , drop = FALSE]
  edges$Lab_ID <- sprintf("MOD_MOD_%06d", seq_len(nrow(edges)))
  utils::write.csv(edges, path, row.names = FALSE, na = "")
  invisible(edges)
}

filter_existing_module_module_edges(min_similarity_score = 0.70)
