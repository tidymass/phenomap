suppressPackageStartupMessages({
  library(ggplot2)
})

# Position one FeatureMAP AD case in the PhenoMAP phenotype landscape.
#
# Intended copies:
#   featuremap_case/3_data_analysis/IPSC_AD_NNI/formeeting/9_phenomap_positioning.R
#   featuremap_case/3_data_analysis/CSF_AD_biotree/formeeting/9_phenomap_positioning.R
#
# This version uses the same module similarity logic as the PhenoMAP build:
#   title/summary embeddings + core/supporting/contextual metabolite overlap +
#   pathway/class/hypothesis overlap, followed by BMA aggregation to phenotypes.
#
# It does not recompute embeddings for PhenoMAP modules. Those are read from:
#   pre_phenomap/2_data/tidy_relationship/module_text_embeddings.rds
#
# By default it also avoids API calls for case embeddings. If a case title or
# summary is missing from existing caches, set allow_new_case_embeddings <- TRUE.

# ----------------------------- user settings -----------------------------

case_id_override <- NA_character_

require_case_confidence <- "high"
require_case_hypothesis <- "Host-Endogenous"
require_case_annotation_mode <- NA_character_ # files are already function_*_adv*.csv
require_case_verdict_status <- "accepted"
require_case_p_below <- NA_real_
require_case_fdr_below <- NA_real_

embedding_model <- "text-embedding-3-small"
min_similarity_score <- 0.70
allow_new_case_embeddings <- FALSE
embedding_batch_size <- 64L
openai_base_url <- Sys.getenv("OPENAI_BASE_URL", unset = "https://api.openai.com/v1")
openai_api_key <- Sys.getenv("OPENAI_API_KEY")

top_n_to_plot <- 30L
top_n_for_module_pair_report <- 5L

# ------------------------------- utilities -------------------------------

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

clean_scalar <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0) return(default)
  x <- trimws(as.character(x[[1]]))
  if (!nzchar(x) || toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")) default else x
}

drop_empty <- function(x) {
  if (is.null(x) || length(x) == 0) return(character(0))
  x <- trimws(as.character(x))
  x[!is.na(x) & nzchar(x) & !toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")]
}

split_semicolon <- function(x) {
  x <- clean_scalar(x)
  if (is.na(x)) return(character(0))
  unique(drop_empty(unlist(strsplit(x, ";", fixed = TRUE), use.names = FALSE)))
}

strip_count_suffix <- function(x) {
  trimws(gsub("\\s*\\([^)]*\\)\\s*$", "", x))
}

normalize_token <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", " ", x)
  x <- trimws(gsub("[[:space:]]+", " ", x))
  unique(drop_empty(x))
}

normalize_hypothesis <- function(x) {
  tolower(gsub("[^a-z0-9]+", "_", trimws(as.character(x))))
}

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(df, path, row.names = FALSE, na = "")
  invisible(path)
}

get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[[1]]), mustWork = TRUE)))
  }
  if (!is.null(sys.frames()[[1]]$ofile)) {
    return(dirname(normalizePath(sys.frames()[[1]]$ofile, mustWork = TRUE)))
  }
  normalizePath(getwd(), mustWork = TRUE)
}

find_up <- function(marker, start_dir, max_depth = 8L) {
  cur <- normalizePath(start_dir, mustWork = TRUE)
  for (i in seq_len(max_depth)) {
    if (file.exists(file.path(cur, marker))) return(cur)
    parent <- dirname(cur)
    if (identical(parent, cur)) break
    cur <- parent
  }
  NA_character_
}

col_or_na <- function(df, col) {
  if (col %in% names(df)) as.character(df[[col]]) else rep(NA_character_, nrow(df))
}

filter_equal_if_requested <- function(df, col, value) {
  if (is.na(value) || !nzchar(value) || !col %in% names(df)) return(df)
  df[tolower(trimws(as.character(df[[col]]))) == tolower(value), , drop = FALSE]
}

jaccard <- function(a, b) {
  a <- unique(drop_empty(a))
  b <- unique(drop_empty(b))
  if (length(a) == 0 && length(b) == 0) return(0)
  length(intersect(a, b)) / length(union(a, b))
}

cross_jaccard <- function(a_list, b_list) {
  out <- matrix(0, nrow = length(a_list), ncol = length(b_list))
  if (length(a_list) == 0 || length(b_list) == 0) return(out)
  for (i in seq_along(a_list)) {
    ai <- a_list[[i]]
    out[i, ] <- vapply(b_list, jaccard, numeric(1), a = ai)
  }
  out
}

cosine_rows <- function(x, y) {
  x_norm <- sqrt(rowSums(x * x))
  y_norm <- sqrt(rowSums(y * y))
  x_norm[x_norm == 0] <- 1
  y_norm[y_norm == 0] <- 1
  x <- x / x_norm
  y <- y / y_norm
  pmax(pmin(x %*% t(y), 1), -1)
}

# ------------------------------- paths -----------------------------------

script_dir <- get_script_dir()
featuremap_root <- find_up("featuremap_case.Rproj", script_dir)
if (is.na(featuremap_root)) featuremap_root <- find_up("featuremap_case.Rproj", getwd())
if (is.na(featuremap_root)) stop("Cannot find featuremap_case.Rproj.")

phenomap_root <- file.path(dirname(featuremap_root), "phenomap")
pre_phenomap_root <- file.path(dirname(featuremap_root), "pre_phenomap")
if (!dir.exists(phenomap_root)) stop("Cannot find sibling phenomap directory: ", phenomap_root)
if (!dir.exists(pre_phenomap_root)) stop("Cannot find sibling pre_phenomap directory: ", pre_phenomap_root)

case_dir <- dirname(script_dir)
case_id <- if (!is.na(case_id_override) && nzchar(case_id_override)) {
  case_id_override
} else {
  basename(case_dir)
}

out_dir <- file.path(script_dir, "phenomap_positioning")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

message("FeatureMAP root: ", featuremap_root)
message("PhenoMAP root: ", phenomap_root)
message("Case directory: ", case_dir)
message("Output directory: ", out_dir)

# --------------------------- case modules --------------------------------

find_platform_file <- function(platform) {
  platform_dir <- file.path(case_dir, platform)
  candidates <- c(
    file.path(platform_dir, sprintf("function_%s_adv_match.csv", platform)),
    file.path(platform_dir, sprintf("function_%s_adv.csv", platform)),
    Sys.glob(file.path(platform_dir, "function_*.csv"))
  )
  candidates <- unique(candidates[file.exists(candidates)])
  if (length(candidates) == 0) stop("No function_*.csv found for ", platform, " in ", platform_dir)
  candidates[[1]]
}

read_case_platform <- function(platform) {
  path <- find_platform_file(platform)
  x <- read_csv_required(path)
  x$Platform <- toupper(platform)
  x$Source_File <- path
  x
}

case_modules <- rbind(read_case_platform("hilic"), read_case_platform("rp"))
case_modules <- filter_equal_if_requested(case_modules, "confidence_label", require_case_confidence)
case_modules <- filter_equal_if_requested(case_modules, "hypothesis_type", require_case_hypothesis)
case_modules <- filter_equal_if_requested(case_modules, "annotation_mode", require_case_annotation_mode)
case_modules <- filter_equal_if_requested(case_modules, "verdict_status", require_case_verdict_status)

if (!is.na(require_case_p_below) && "p" %in% names(case_modules)) {
  p <- suppressWarnings(as.numeric(case_modules$p))
  case_modules <- case_modules[!is.na(p) & p < require_case_p_below, , drop = FALSE]
}
if (!is.na(require_case_fdr_below) && "fdr" %in% names(case_modules)) {
  fdr <- suppressWarnings(as.numeric(case_modules$fdr))
  case_modules <- case_modules[!is.na(fdr) & fdr < require_case_fdr_below, , drop = FALSE]
}

if (nrow(case_modules) == 0) stop("No case modules passed the requested filters.")
case_modules$Case_ID <- case_id
case_modules$Case_Module_ID <- paste(case_id, case_modules$Platform, case_modules$module_id, sep = "::")
case_modules <- case_modules[!duplicated(case_modules$Case_Module_ID), , drop = FALSE]

write_csv(case_modules, file.path(out_dir, "input_case_modules_used.csv"))

# -------------------------- reference modules ----------------------------

module_pheno_path <- file.path(phenomap_root, "analysis", "2_data", "selected_module_phenotype_map.csv")
nodes_module_path <- file.path(phenomap_root, "neo4j", "import", "nodes_module.csv")
nodes_metabolite_path <- file.path(phenomap_root, "neo4j", "import", "nodes_metabolite.csv")

module_pheno <- read_csv_required(module_pheno_path)
module_pheno <- filter_equal_if_requested(module_pheno, "confidence_label", "high")
module_pheno <- filter_equal_if_requested(module_pheno, "hypothesis_type", require_case_hypothesis)
module_pheno <- module_pheno[!duplicated(module_pheno[, c("Phenotype_ID", "Module_ID")]), , drop = FALSE]

nodes_module <- read_csv_required(nodes_module_path)
if (!"Lab_ID" %in% names(nodes_module)) stop("nodes_module.csv is missing Lab_ID.")
ref_modules <- nodes_module[nodes_module$Lab_ID %in% unique(module_pheno$Module_ID), , drop = FALSE]
ref_modules <- ref_modules[!duplicated(ref_modules$Lab_ID), , drop = FALSE]
if (nrow(ref_modules) == 0) stop("No PhenoMAP reference modules found after filtering.")

module_pheno <- module_pheno[module_pheno$Module_ID %in% ref_modules$Lab_ID, , drop = FALSE]
write_csv(module_pheno, file.path(out_dir, "phenomap_reference_module_phenotype_map_used.csv"))
write_csv(ref_modules, file.path(out_dir, "phenomap_reference_modules_used.csv"))

# -------------------------- metabolite mapping ---------------------------

metabolites <- read_csv_required(nodes_metabolite_path)
inchi_to_pme <- metabolites$Lab_ID
names(inchi_to_pme) <- metabolites$INCHI_ID
inchi_to_pme <- inchi_to_pme[!is.na(names(inchi_to_pme)) & nzchar(names(inchi_to_pme))]
inchi_to_pme <- inchi_to_pme[!duplicated(names(inchi_to_pme))]

map_inchi_to_pme <- function(ids) {
  ids <- split_semicolon(paste(ids, collapse = ";"))
  mapped <- unname(inchi_to_pme[ids])
  unique(drop_empty(mapped))
}

case_inchi <- unique(c(
  unlist(lapply(col_or_na(case_modules, "anchor_metabolite_ids"), split_semicolon), use.names = FALSE),
  unlist(lapply(col_or_na(case_modules, "top_metabolite_ids"), split_semicolon), use.names = FALSE)
))
case_mapping_report <- data.frame(
  Case_ID = case_id,
  n_unique_case_inchi = length(drop_empty(case_inchi)),
  n_case_inchi_mapped_to_pme = sum(drop_empty(case_inchi) %in% names(inchi_to_pme)),
  mapping_source = nodes_metabolite_path,
  stringsAsFactors = FALSE
)
write_csv(case_mapping_report, file.path(out_dir, "case_metabolite_id_mapping_report.csv"))

# ----------------------------- set builders ------------------------------

pathway_tokens <- function(row) {
  ids <- c(split_semicolon(row[["hmdb_pathway_ids"]] %||% NA), split_semicolon(row[["kegg_pathway_ids"]] %||% NA))
  if (length(ids) > 0) return(unique(ids))
  names <- c(
    strip_count_suffix(split_semicolon(row[["top_hmdb_pathways"]] %||% NA)),
    strip_count_suffix(split_semicolon(row[["top_kegg_pathways"]] %||% NA))
  )
  normalize_token(names)
}

class_tokens <- function(row) normalize_token(split_semicolon(row[["class_names"]] %||% NA))

case_sets_for_row <- function(i) {
  row <- case_modules[i, , drop = FALSE]
  list(
    core = map_inchi_to_pme(row$anchor_metabolite_ids),
    supporting = map_inchi_to_pme(row$top_metabolite_ids),
    contextual = character(0),
    class = class_tokens(as.list(row[1, , drop = TRUE])),
    pathway = pathway_tokens(as.list(row[1, , drop = TRUE]))
  )
}

ref_sets_for_row <- function(i) {
  row <- ref_modules[i, , drop = FALSE]
  list(
    core = split_semicolon(row$anchor_metabolite_ids),
    supporting = split_semicolon(row$supporting_metabolite_ids),
    contextual = split_semicolon(row$contextual_metabolite_ids),
    class = class_tokens(as.list(row[1, , drop = TRUE])),
    pathway = pathway_tokens(as.list(row[1, , drop = TRUE]))
  )
}

case_sets <- lapply(seq_len(nrow(case_modules)), case_sets_for_row)
ref_sets <- lapply(seq_len(nrow(ref_modules)), ref_sets_for_row)

# ---------------------------- embeddings ---------------------------------

embedding_cache_key <- function(text, model) paste0(model, intToUtf8(0x241F), text)

extract_store <- function(path) {
  if (!file.exists(path)) return(NULL)
  x <- readRDS(path)
  if (is.environment(x)) return(x)
  if (is.list(x) && is.environment(x$store)) return(x$store)
  NULL
}

cache_paths <- c(
  file.path(pre_phenomap_root, "2_data", "tidy_relationship", "module_text_embeddings.rds"),
  file.path(featuremap_root, "3_data_analysis", "IPSC_CSF_comparison",
            "module_similarity_p005_high_host_endogenous", "module_text_embeddings.rds"),
  file.path(out_dir, "module_text_embeddings_case.rds")
)
stores <- lapply(cache_paths, extract_store)
names(stores) <- cache_paths
stores <- stores[!vapply(stores, is.null, logical(1))]
if (length(stores) == 0) stop("No embedding cache could be loaded.")

local_case_cache_path <- file.path(out_dir, "module_text_embeddings_case.rds")
local_case_cache <- extract_store(local_case_cache_path)
if (is.null(local_case_cache)) local_case_cache <- new.env(parent = emptyenv())

get_cached_embedding <- function(text) {
  key <- embedding_cache_key(text, embedding_model)
  for (store in c(list(local_case_cache), stores)) {
    if (exists(key, envir = store, inherits = FALSE)) {
      value <- get(key, envir = store, inherits = FALSE)
      return(as.numeric(value))
    }
  }
  NULL
}

embedding_endpoint <- function(base_url) {
  endpoint <- sub("/+$", "", base_url)
  if (!grepl("/embeddings$", endpoint)) endpoint <- paste0(endpoint, "/embeddings")
  endpoint
}

fetch_embeddings <- function(texts) {
  if (!allow_new_case_embeddings) {
    stop(
      "Missing embeddings for case text and allow_new_case_embeddings is FALSE.\n",
      "Set allow_new_case_embeddings <- TRUE to embed only missing case titles/summaries."
    )
  }
  if (!nzchar(openai_api_key)) stop("OPENAI_API_KEY is empty.")
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required for API embedding calls.")
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required for API embedding calls.")

  endpoint <- embedding_endpoint(openai_base_url)
  out <- vector("list", length(texts))
  for (start in seq(1L, length(texts), by = embedding_batch_size)) {
    idx <- seq.int(start, min(start + embedding_batch_size - 1L, length(texts)))
    body <- jsonlite::toJSON(list(model = embedding_model, input = texts[idx]), auto_unbox = TRUE)
    response <- httr::POST(
      endpoint,
      httr::add_headers(
        Authorization = paste("Bearer", openai_api_key),
        "Content-Type" = "application/json"
      ),
      body = body,
      encode = "raw"
    )
    if (httr::status_code(response) >= 300) {
      stop("Embedding API request failed: ", httr::content(response, "text", encoding = "UTF-8"))
    }
    parsed <- jsonlite::fromJSON(httr::content(response, "text", encoding = "UTF-8"), simplifyVector = FALSE)
    for (item in parsed$data) out[[idx[[item$index + 1L]]]] <- as.numeric(item$embedding)
  }
  out
}

get_embeddings <- function(texts, label, allow_fetch = FALSE) {
  texts <- as.character(texts)
  texts[is.na(texts) | !nzchar(texts)] <- " "
  cached <- lapply(texts, get_cached_embedding)
  missing <- which(vapply(cached, is.null, logical(1)))
  if (length(missing) > 0) {
    message("Missing ", length(missing), " ", label, " embeddings.")
    if (!allow_fetch) {
      stop("Missing cached embeddings for ", label, ". This script does not recompute PhenoMAP reference embeddings.")
    }
    new_embeddings <- fetch_embeddings(texts[missing])
    for (j in seq_along(missing)) {
      key <- embedding_cache_key(texts[[missing[[j]]]], embedding_model)
      assign(key, new_embeddings[[j]], envir = local_case_cache)
      cached[[missing[[j]]]] <- new_embeddings[[j]]
    }
    saveRDS(list(store = local_case_cache), local_case_cache_path)
  }
  lens <- vapply(cached, length, integer(1))
  if (length(unique(lens)) != 1) stop("Embedding dimensions are inconsistent for ", label, ".")
  do.call(rbind, cached)
}

case_title_mat <- get_embeddings(col_or_na(case_modules, "title"), "case title", allow_fetch = allow_new_case_embeddings)
case_summary_mat <- get_embeddings(col_or_na(case_modules, "functional_summary"), "case summary", allow_fetch = allow_new_case_embeddings)
ref_title_mat <- get_embeddings(col_or_na(ref_modules, "title"), "PhenoMAP title", allow_fetch = FALSE)
ref_summary_mat <- get_embeddings(col_or_na(ref_modules, "functional_summary"), "PhenoMAP summary", allow_fetch = FALSE)

# ----------------------- module-module similarity ------------------------

title_sim <- cosine_rows(case_title_mat, ref_title_mat)
summary_sim <- cosine_rows(case_summary_mat, ref_summary_mat)

same_hypothesis <- outer(
  normalize_hypothesis(col_or_na(case_modules, "hypothesis_type")),
  normalize_hypothesis(col_or_na(ref_modules, "hypothesis_type")),
  Vectorize(function(a, b) as.numeric(nzchar(a) && identical(a, b)))
)

core_jac <- cross_jaccard(lapply(case_sets, `[[`, "core"), lapply(ref_sets, `[[`, "core"))
supporting_jac <- cross_jaccard(lapply(case_sets, `[[`, "supporting"), lapply(ref_sets, `[[`, "supporting"))
contextual_jac <- cross_jaccard(lapply(case_sets, `[[`, "contextual"), lapply(ref_sets, `[[`, "contextual"))
class_jac <- cross_jaccard(lapply(case_sets, `[[`, "class"), lapply(ref_sets, `[[`, "class"))
pathway_jac <- cross_jaccard(lapply(case_sets, `[[`, "pathway"), lapply(ref_sets, `[[`, "pathway"))

metabolite_score <- 0.50 * core_jac + 0.30 * supporting_jac + 0.20 * contextual_jac
compositional_score <- 0.40 * metabolite_score + 0.25 * pathway_jac + 0.25 * class_jac + 0.10 * same_hypothesis
biological_score <- 0.50 * summary_sim + 0.40 * title_sim + 0.10 * same_hypothesis
final_score <- 0.75 * pmax(biological_score, compositional_score) +
  0.25 * ((biological_score + compositional_score) / 2)
score_for_bma <- ifelse(final_score >= min_similarity_score, final_score, 0)

pair_grid <- data.frame(
  Case_Module_ID = rep(case_modules$Case_Module_ID, each = nrow(ref_modules)),
  Module_ID = rep(ref_modules$Lab_ID, times = nrow(case_modules)),
  stringsAsFactors = FALSE
)
pair_grid$Case_ID <- case_id
pair_grid$Case_Platform <- rep(case_modules$Platform, each = nrow(ref_modules))
pair_grid$Case_Module_Local_ID <- rep(case_modules$module_id, each = nrow(ref_modules))
pair_grid$Case_Title <- rep(col_or_na(case_modules, "title"), each = nrow(ref_modules))
pair_grid$Phenotype_Module_Title <- rep(col_or_na(ref_modules, "title"), times = nrow(case_modules))
pair_grid$Title_Similarity <- as.vector(t(title_sim))
pair_grid$Summary_Similarity <- as.vector(t(summary_sim))
pair_grid$Core_Jaccard <- as.vector(t(core_jac))
pair_grid$Supporting_Jaccard <- as.vector(t(supporting_jac))
pair_grid$Contextual_Jaccard <- as.vector(t(contextual_jac))
pair_grid$Class_Jaccard <- as.vector(t(class_jac))
pair_grid$Pathway_Jaccard <- as.vector(t(pathway_jac))
pair_grid$Same_Hypothesis <- as.vector(t(same_hypothesis))
pair_grid$Metabolite_Score <- as.vector(t(metabolite_score))
pair_grid$Biological_Score <- as.vector(t(biological_score))
pair_grid$Compositional_Score <- as.vector(t(compositional_score))
pair_grid$Similarity_Score <- as.vector(t(final_score))
pair_grid$Similarity_For_BMA <- as.vector(t(score_for_bma))
pair_grid <- pair_grid[order(-pair_grid$Similarity_Score), , drop = FALSE]

write_csv(pair_grid, file.path(out_dir, "case_to_phenomap_module_similarity_all.csv"))
write_csv(
  pair_grid[pair_grid$Similarity_Score >= min_similarity_score, , drop = FALSE],
  file.path(out_dir, "case_to_phenomap_module_similarity_edges_ge_0p70.csv")
)

# ------------------------ phenotype positioning --------------------------

rownames(score_for_bma) <- case_modules$Case_Module_ID
colnames(score_for_bma) <- ref_modules$Lab_ID

best_directed <- function(from_modules, to_modules, score_matrix, from_axis = c("row", "col")) {
  from_axis <- match.arg(from_axis)
  from_modules <- unique(drop_empty(from_modules))
  to_modules <- unique(drop_empty(to_modules))
  if (length(from_modules) == 0 || length(to_modules) == 0) return(NA_real_)

  if (from_axis == "row") {
    from_modules <- intersect(from_modules, rownames(score_matrix))
    to_modules <- intersect(to_modules, colnames(score_matrix))
    if (length(from_modules) == 0 || length(to_modules) == 0) return(NA_real_)
    mean(apply(score_matrix[from_modules, to_modules, drop = FALSE], 1, max, na.rm = TRUE))
  } else {
    from_modules <- intersect(from_modules, colnames(score_matrix))
    to_modules <- intersect(to_modules, rownames(score_matrix))
    if (length(from_modules) == 0 || length(to_modules) == 0) return(NA_real_)
    mean(apply(score_matrix[to_modules, from_modules, drop = FALSE], 2, max, na.rm = TRUE))
  }
}

case_profile <- case_modules$Case_Module_ID
phenotype_profiles <- split(module_pheno$Module_ID, module_pheno$Phenotype_ID)

phenotype_meta <- module_pheno[!duplicated(module_pheno$Phenotype_ID),
                               c("Phenotype_ID", "Phenotype", "Phenotype_Type", "OLS_ID"),
                               drop = FALSE]
row.names(phenotype_meta) <- phenotype_meta$Phenotype_ID

case_to_pheno <- lapply(names(phenotype_profiles), function(pid) {
  pheno_modules <- phenotype_profiles[[pid]]
  a_to_b <- best_directed(case_profile, pheno_modules, score_for_bma, "row")
  b_to_a <- best_directed(pheno_modules, case_profile, score_for_bma, "col")
  data.frame(
    Case_ID = case_id,
    Phenotype_ID = pid,
    Phenotype = phenotype_meta[pid, "Phenotype"],
    Phenotype_Type = phenotype_meta[pid, "Phenotype_Type"],
    OLS_ID = phenotype_meta[pid, "OLS_ID"],
    N_Case_Modules = length(unique(case_profile)),
    N_Phenotype_Modules = length(unique(pheno_modules)),
    BMA_Case_to_Phenotype = a_to_b,
    BMA_Phenotype_to_Case = b_to_a,
    Similarity_Score = mean(c(a_to_b, b_to_a), na.rm = TRUE),
    stringsAsFactors = FALSE
  )
})
case_to_pheno <- do.call(rbind, case_to_pheno)
case_to_pheno <- case_to_pheno[order(-case_to_pheno$Similarity_Score), , drop = FALSE]
case_to_pheno$Rank <- seq_len(nrow(case_to_pheno))

write_csv(case_to_pheno, file.path(out_dir, "case_to_phenotype_similarity.csv"))
write_csv(head(case_to_pheno, top_n_to_plot), file.path(out_dir, "case_to_phenotype_similarity_top.csv"))

top_module_matches <- function(pid, n = 5L) {
  pheno_modules <- intersect(unique(phenotype_profiles[[pid]]), colnames(score_for_bma))
  if (length(pheno_modules) == 0) return(data.frame())
  sub <- score_for_bma[, pheno_modules, drop = FALSE]
  rows <- list()
  for (case_module_id in rownames(sub)) {
    j <- which.max(sub[case_module_id, ])
    rows[[length(rows) + 1L]] <- data.frame(
      Phenotype_ID = pid,
      Case_Module_ID = case_module_id,
      Module_ID = colnames(sub)[[j]],
      Similarity_For_BMA = sub[case_module_id, j],
      stringsAsFactors = FALSE
    )
  }
  out <- do.call(rbind, rows)
  out <- out[order(-out$Similarity_For_BMA), , drop = FALSE]
  out <- head(out, n)
  merge(
    out,
    pair_grid[, c("Case_Module_ID", "Module_ID", "Case_Platform", "Case_Title",
                  "Phenotype_Module_Title", "Similarity_Score", "Biological_Score",
                  "Compositional_Score", "Core_Jaccard", "Supporting_Jaccard",
                  "Class_Jaccard", "Pathway_Jaccard")],
    by = c("Case_Module_ID", "Module_ID"),
    all.x = TRUE,
    sort = FALSE
  )
}

top_pids <- head(case_to_pheno$Phenotype_ID, top_n_to_plot)
module_match_table <- do.call(rbind, lapply(top_pids, top_module_matches, n = top_n_for_module_pair_report))
if (!is.null(module_match_table) && nrow(module_match_table) > 0) {
  module_match_table <- merge(
    module_match_table,
    phenotype_meta[, c("Phenotype_ID", "Phenotype", "Phenotype_Type")],
    by = "Phenotype_ID",
    all.x = TRUE,
    sort = FALSE
  )
  write_csv(module_match_table, file.path(out_dir, "top_phenotype_module_matches.csv"))
}

# -------------------------------- plots ----------------------------------

plot_df <- head(case_to_pheno, top_n_to_plot)
plot_df$Label <- paste0(plot_df$Phenotype, " [", plot_df$Phenotype_Type, "]")
plot_df$Label <- factor(plot_df$Label, levels = rev(plot_df$Label))

p <- ggplot(plot_df, aes(x = Similarity_Score, y = Label, fill = Phenotype_Type)) +
  geom_col(width = 0.74) +
  scale_x_continuous(limits = c(0, max(0.05, max(plot_df$Similarity_Score, na.rm = TRUE) * 1.05))) +
  labs(x = "BMA phenotype similarity", y = NULL, title = paste(case_id, "nearest PhenoMAP phenotypes")) +
  theme_bw(base_size = 11) +
  theme(
    legend.position = "bottom",
    panel.grid.major.y = element_blank(),
    plot.title = element_text(face = "bold")
  )

ggsave(file.path(out_dir, "case_to_phenotype_similarity_top.png"), p, width = 9, height = 7, dpi = 300)
ggsave(file.path(out_dir, "case_to_phenotype_similarity_top.pdf"), p, width = 9, height = 7)

# ------------------------------ notes ------------------------------------

notes <- c(
  paste0("Case: ", case_id),
  paste0("Case modules retained: ", nrow(case_modules)),
  paste0("Reference PhenoMAP modules retained: ", nrow(ref_modules)),
  paste0("Reference phenotype profiles retained: ", length(phenotype_profiles)),
  paste0("Embedding model: ", embedding_model),
  paste0("PhenoMAP embedding cache: ", cache_paths[[1]]),
  paste0("Module edge cutoff for BMA: ", min_similarity_score),
  "",
  "Module-module similarity formula copied from pre_phenomap/1_code/final_version/04_compute_module_similarity.R:",
  "  metabolite_score = 0.50 * core_jaccard + 0.30 * supporting_jaccard + 0.20 * contextual_jaccard",
  "  compositional_score = 0.40 * metabolite_score + 0.25 * pathway_jaccard + 0.25 * class_jaccard + 0.10 * same_hypothesis",
  "  biological_score = 0.50 * summary_embedding_cosine + 0.40 * title_embedding_cosine + 0.10 * same_hypothesis",
  "  similarity_score = 0.75 * max(biological_score, compositional_score) + 0.25 * mean(biological_score, compositional_score)",
  "",
  "Phenotype positioning formula follows global_high_confidence_phenotype_neighborhood.R:",
  "  BMA = mean(best case-module-to-phenotype-module score, best phenotype-module-to-case-module score).",
  "  Module-module scores below the PhenoMAP 0.70 edge cutoff are treated as zero for BMA.",
  "",
  paste0("Case InChI IDs mapped to PME IDs: ",
         case_mapping_report$n_case_inchi_mapped_to_pme, " / ",
         case_mapping_report$n_unique_case_inchi),
  "Case contextual metabolites are empty because FeatureMAP case function files expose anchor/top metabolite IDs, not contextual membership."
)
writeLines(notes, file.path(out_dir, "method_notes.txt"))

message("Done. Main output: ", file.path(out_dir, "case_to_phenotype_similarity.csv"))
