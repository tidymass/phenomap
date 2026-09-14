#!/usr/bin/env Rscript

# Compute preliminary module-module similarity for the final PhenoMAP build.
#
# No final KG Lab_IDs are assigned here. This script keeps natural identifiers:
#   Module_Key = database::study::comparison::local_module_id
#   INCHI_ID   = metabolite natural key from the MRN-derived module table
#
# The similarity method follows the old pipeline:
#   - embed `title` and `functional_summary` separately
#   - compare core/supporting/contextual metabolite sets
#   - compare class/pathway/hypothesis annotations
#   - combine with the same weights and default cutoff 0.70

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

parse_args <- function() {
  args <- list(
    data_dir = "/mnt/hdd1/home/yuting/module_lists_20260911",
    module_prelim_dir = "",
    output_dir = "",
    api_key = Sys.getenv("OPENAI_API_KEY"),
    embedding_model = "text-embedding-3-small",
    base_url = "https://api.openai.com/v1",
    embedding_batch_size = 64L,
    min_similarity_score = 0.70,
    chunk_size = 200L,
    limit_modules = NA_integer_,
    phenotype_csv = "",
    step = "all"
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% names(args)) args[[key]] <- value
  }

  if (!nzchar(args$module_prelim_dir)) {
    args$module_prelim_dir <- file.path(args$data_dir, "module_prelim")
  }
  if (!nzchar(args$output_dir)) {
    args$output_dir <- file.path(args$data_dir, "module_similarity_prelim")
  }

  args$embedding_batch_size <- suppressWarnings(as.integer(args$embedding_batch_size))
  if (is.na(args$embedding_batch_size) || args$embedding_batch_size < 1L) {
    args$embedding_batch_size <- 64L
  }
  args$min_similarity_score <- suppressWarnings(as.numeric(args$min_similarity_score))
  if (is.na(args$min_similarity_score)) args$min_similarity_score <- 0.70
  args$chunk_size <- suppressWarnings(as.integer(args$chunk_size))
  if (is.na(args$chunk_size) || args$chunk_size < 1L) args$chunk_size <- 200L
  args$limit_modules <- suppressWarnings(as.integer(args$limit_modules))
  if (is.na(args$limit_modules) || args$limit_modules < 1L) {
    args$limit_modules <- NA_integer_
  }
  args$phenotype_csv <- trimws(args$phenotype_csv)
  args$step <- tolower(trimws(args$step))
  valid_steps <- c("prepare", "embed", "similarity", "all")
  if (!args$step %in% valid_steps) {
    stop("--step must be one of: ", paste(valid_steps, collapse = ", "))
  }

  args
}

clean_scalar <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0) return(default)
  x <- as.character(x[[1]])
  x <- trimws(x)
  if (!nzchar(x) || toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")) return(default)
  x
}

clean_vec <- function(x) {
  x <- trimws(as.character(x))
  bad <- is.na(x) | !nzchar(x) | toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")
  x[bad] <- NA_character_
  x
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

normalize_token <- function(x) {
  x <- tolower(clean_scalar(x, ""))
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(gsub("[[:space:]]+", " ", x))
}

column_value <- function(df, name, i, default = NA_character_) {
  if (!name %in% names(df)) return(default)
  clean_scalar(df[[name]][[i]], default)
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

read_final_study_filter <- function(phenotype_csv) {
  if (!nzchar(phenotype_csv)) return(character(0))
  pheno <- read_csv_required(phenotype_csv)
  id_col <- intersect(c("Study_ID", "study_accession", "Accession", "accession"), names(pheno))
  if (length(id_col) == 0) {
    stop("phenotype_csv must contain one of: Study_ID, study_accession, Accession, accession.")
  }
  unique(drop_empty(unlist(strsplit(as.character(pheno[[id_col[[1]]]]), ";", fixed = TRUE), use.names = FALSE)))
}

write_study_filter_report <- function(modules_before, modules_after, memberships_after, final_study_ids, output_dir) {
  if (length(final_study_ids) == 0) return(invisible(NULL))

  module_counts <- as.data.frame(table(modules_after$Study_Accession), stringsAsFactors = FALSE)
  names(module_counts) <- c("Study_ID", "n_modules")
  edge_counts <- as.data.frame(table(memberships_after$Study_Accession), stringsAsFactors = FALSE)
  names(edge_counts) <- c("Study_ID", "n_metabolite_module_rows")
  db_map <- modules_before[!duplicated(modules_before$Study_Accession), c("Study_Accession", "Database_Key", "Database"), drop = FALSE]
  names(db_map)[names(db_map) == "Study_Accession"] <- "Study_ID"

  report <- data.frame(Study_ID = final_study_ids, stringsAsFactors = FALSE)
  report <- merge(report, db_map, by = "Study_ID", all.x = TRUE, sort = FALSE)
  report <- merge(report, module_counts, by = "Study_ID", all.x = TRUE, sort = FALSE)
  report <- merge(report, edge_counts, by = "Study_ID", all.x = TRUE, sort = FALSE)
  report$n_modules[is.na(report$n_modules)] <- 0L
  report$n_metabolite_module_rows[is.na(report$n_metabolite_module_rows)] <- 0L
  report$retained_for_similarity <- report$n_modules > 0

  write_csv(report, file.path(output_dir, "module_similarity_study_filter_report.csv"))
  invisible(report)
}

prepare_similarity_inputs <- function(module_prelim_dir, output_dir, limit_modules = NA_integer_,
                                      phenotype_csv = "") {
  modules <- read_csv_required(file.path(module_prelim_dir, "nodes_module_prelim.csv"))
  memberships <- read_csv_required(file.path(module_prelim_dir, "edges_metabolite_module_prelim.csv"))

  if (!"Module_Key" %in% names(modules)) {
    stop("nodes_module_prelim.csv must contain Module_Key.")
  }
  if (!all(c("Module_Key", "INCHI_ID", "Membership_Type") %in% names(memberships))) {
    stop("edges_metabolite_module_prelim.csv must contain Module_Key, INCHI_ID and Membership_Type.")
  }

  modules <- modules[!is.na(modules$Module_Key) & nzchar(modules$Module_Key), , drop = FALSE]
  modules <- modules[!duplicated(modules$Module_Key), , drop = FALSE]
  modules_before_filter <- modules

  if (!"Local_Module_ID" %in% names(modules) && "module_id" %in% names(modules)) {
    modules$Local_Module_ID <- modules$module_id
  }
  if (!"module_id" %in% names(modules) && "Local_Module_ID" %in% names(modules)) {
    modules$module_id <- modules$Local_Module_ID
  }
  for (nm in c("title", "functional_summary", "hypothesis_type", "class_names")) {
    if (!nm %in% names(modules)) modules[[nm]] <- NA_character_
  }

  for (nm in c("Database_Key", "Study_Accession", "Comparison_ID")) {
    if (!nm %in% names(modules)) modules[[nm]] <- NA_character_
  }
  module_order <- suppressWarnings(as.integer(sub("^M", "", as.character(modules$Local_Module_ID))))
  module_order[is.na(module_order)] <- seq_along(module_order)[is.na(module_order)]
  modules <- modules[order(modules$Database_Key, modules$Study_Accession, modules$Comparison_ID, module_order), , drop = FALSE]

  final_study_ids <- read_final_study_filter(phenotype_csv)
  if (length(final_study_ids) > 0) {
    message("Applying final study filter from: ", phenotype_csv)
    message("Final study IDs in filter: ", length(final_study_ids))
    modules <- modules[modules$Study_Accession %in% final_study_ids, , drop = FALSE]
    memberships <- memberships[memberships$Study_Accession %in% final_study_ids, , drop = FALSE]
  }

  if (!is.na(limit_modules)) {
    keep_keys <- head(modules$Module_Key, limit_modules)
    modules <- modules[modules$Module_Key %in% keep_keys, , drop = FALSE]
    memberships <- memberships[memberships$Module_Key %in% keep_keys, , drop = FALSE]
  }

  memberships <- memberships[!is.na(memberships$Module_Key) & nzchar(memberships$Module_Key), , drop = FALSE]
  memberships <- memberships[memberships$Module_Key %in% modules$Module_Key, , drop = FALSE]
  memberships <- memberships[!is.na(memberships$INCHI_ID) & nzchar(memberships$INCHI_ID), , drop = FALSE]
  memberships$Membership_Type <- clean_vec(memberships$Membership_Type)
  memberships$Membership_Type[is.na(memberships$Membership_Type)] <- "contextual"
  memberships <- memberships[!duplicated(memberships[, c("Module_Key", "INCHI_ID", "Membership_Type")]), , drop = FALSE]

  type_order <- match(memberships$Membership_Type, c("core", "supporting", "contextual"))
  type_order[is.na(type_order)] <- 99L
  memberships <- memberships[order(memberships$Module_Key, type_order, memberships$INCHI_ID), , drop = FALSE]

  module_front <- c(
    "Module_Key", "Database_Key", "Database", "Study_Accession", "Result_Scope",
    "Comparison_ID", "Comparison_Kind", "Comparison_Design_Type", "Comparison_Label",
    "Case_Value", "Control_Value", "N_Case", "N_Control", "Phenotype",
    "Phenotype_Term", "Species", "Biospecimen", "module_id", "Local_Module_ID",
    "annotation_mode", "hypothesis_type", "title", "functional_summary",
    "anchor_metabolites", "anchor_metabolite_ids", "supporting_metabolites",
    "supporting_metabolite_ids", "contextual_metabolites",
    "contextual_metabolite_ids", "class_names", "phenotype_relationship",
    "confidence_label", "rationale", "global_direction",
    "origin_endogenous_frac", "origin_exogenous_frac", "top_kegg_pathways",
    "top_hmdb_pathways", "pubmed_pmids", "hmdb_pathway_ids", "kegg_pathway_ids",
    "Module_size", "Annotated_nodes", "Module_score", "p", "fdr"
  )
  modules <- modules[, c(intersect(module_front, names(modules)), setdiff(names(modules), module_front)), drop = FALSE]

  membership_front <- c(
    "Module_Key", "Database_Key", "Study_Accession", "Comparison_ID",
    "Local_Module_ID", "Membership_Type", "Module", "INCHI_ID", "HMDB_ID",
    "KEGG_ID", "Compound_name", "Importance"
  )
  memberships <- memberships[, c(intersect(membership_front, names(memberships)), setdiff(names(memberships), membership_front)), drop = FALSE]

  write_csv(modules, file.path(output_dir, "nodes_module_similarity_input.csv"))
  write_csv(memberships, file.path(output_dir, "edges_metabolite_module_similarity_input.csv"))
  write_study_filter_report(modules_before_filter, modules, memberships, final_study_ids, output_dir)

  list(modules = modules, memberships = memberships, final_study_ids = final_study_ids)
}

embedding_endpoint <- function(base_url) {
  endpoint <- sub("/+$", "", base_url)
  if (!grepl("/embeddings$", endpoint)) endpoint <- paste0(endpoint, "/embeddings")
  endpoint
}

embedding_cache_key <- function(text, model) {
  if (!requireNamespace("digest", quietly = TRUE)) stop("Package 'digest' is required.")
  digest::digest(paste(model, text, sep = "\034"), algo = "sha1", serialize = FALSE)
}

new_embedding_store <- function() new.env(parent = emptyenv())

store_get <- function(store, key) {
  if (exists(key, envir = store, inherits = FALSE)) get(key, envir = store, inherits = FALSE) else NULL
}

store_set <- function(store, key, value) {
  assign(key, value, envir = store)
}

save_embedding_store <- function(store, cache_path, model, base_url) {
  saveRDS(
    list(store = store, model = model, base_url = base_url, updated_at = Sys.time()),
    cache_path
  )
}

call_embedding_batch <- function(texts, api_key, model, base_url, max_tries = 4L) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.")
  if (is.na(api_key) || !nzchar(api_key)) stop("API key is empty. Set OPENAI_API_KEY or pass --api_key=...")

  body <- jsonlite::toJSON(list(model = model, input = as.list(texts)), auto_unbox = TRUE)
  last_error <- NULL

  for (attempt in seq_len(max_tries)) {
    result <- if (requireNamespace("httr", quietly = TRUE)) {
      resp <- tryCatch(
        httr::POST(
          embedding_endpoint(base_url),
          httr::add_headers(
            Authorization = paste("Bearer", api_key),
            `Content-Type` = "application/json"
          ),
          body = body,
          encode = "raw",
          httr::timeout(180)
        ),
        error = function(e) e
      )

      if (inherits(resp, "error")) {
        list(ok = FALSE, error = conditionMessage(resp), text = "")
      } else {
        txt <- httr::content(resp, as = "text", encoding = "UTF-8")
        status <- httr::status_code(resp)
        list(ok = status < 400, error = paste("HTTP", status, txt), text = txt)
      }
    } else {
      body_path <- tempfile("openai_embedding_body_", fileext = ".json")
      out_path <- tempfile("openai_embedding_out_", fileext = ".json")
      err_path <- tempfile("openai_embedding_err_", fileext = ".txt")
      config_path <- tempfile("openai_embedding_curl_", fileext = ".conf")
      on.exit(unlink(c(body_path, out_path, err_path, config_path)), add = TRUE)
      writeLines(body, body_path, useBytes = TRUE)
      writeLines(
        c(
          paste0("url = \"", embedding_endpoint(base_url), "\""),
          "request = \"POST\"",
          paste0("header = \"Authorization: Bearer ", api_key, "\""),
          "header = \"Content-Type: application/json\"",
          paste0("data-binary = \"@", body_path, "\""),
          "max-time = 180",
          "silent",
          "show-error",
          "fail-with-body"
        ),
        config_path,
        useBytes = TRUE
      )
      Sys.chmod(config_path, mode = "0600")
      status <- tryCatch(
        system2(
          "curl",
          args = c("--config", config_path),
          stdout = out_path,
          stderr = err_path
        ),
        error = function(e) e
      )
      txt <- if (file.exists(out_path)) paste(readLines(out_path, warn = FALSE), collapse = "\n") else ""
      err <- if (file.exists(err_path)) paste(readLines(err_path, warn = FALSE), collapse = "\n") else ""
      if (inherits(status, "error")) {
        list(ok = FALSE, error = conditionMessage(status), text = txt)
      } else {
        list(ok = identical(as.integer(status), 0L), error = paste(err, txt), text = txt)
      }
    }

    if (isTRUE(result$ok)) {
      payload <- jsonlite::fromJSON(result$text, simplifyVector = FALSE)
      return(lapply(payload$data, function(x) as.numeric(unlist(x$embedding, use.names = FALSE))))
    }
    last_error <- result$error
    if (attempt < max_tries) Sys.sleep(2^(attempt - 1))
  }

  stop("Embedding request failed after retries: ", last_error)
}

embed_texts_cached <- function(texts, store, api_key, model, base_url, batch_size, label,
                               cache_path = NULL) {
  texts <- as.character(texts)
  texts[is.na(texts) | !nzchar(texts)] <- " "
  keys <- vapply(texts, embedding_cache_key, character(1), model = model)

  result <- vector("list", length(texts))
  missing <- integer(0)
  for (i in seq_along(texts)) {
    hit <- store_get(store, keys[[i]])
    if (is.null(hit)) {
      missing <- c(missing, i)
    } else {
      result[[i]] <- hit
    }
  }

  message("Embedding ", label, ": ", length(texts) - length(missing), " reused, ", length(missing), " new.")
  if (length(missing) > 0) {
    for (start in seq(1L, length(missing), by = batch_size)) {
      end <- min(length(missing), start + batch_size - 1L)
      idx <- missing[start:end]
      message("  ", label, " ", start, "-", end, " / ", length(missing))
      fetched <- call_embedding_batch(texts[idx], api_key, model, base_url)
      for (k in seq_along(idx)) {
        result[[idx[[k]]]] <- fetched[[k]]
        store_set(store, keys[[idx[[k]]]], fetched[[k]])
      }
      if (!is.null(cache_path)) {
        save_embedding_store(store, cache_path, model, base_url)
      }
    }
  }

  result
}

load_or_build_embeddings <- function(modules, output_dir, api_key, model, base_url, batch_size) {
  cache_path <- file.path(output_dir, "module_text_embeddings.rds")
  store <- new_embedding_store()
  if (file.exists(cache_path)) {
    on_disk <- tryCatch(readRDS(cache_path), error = function(e) NULL)
    if (is.list(on_disk) && is.environment(on_disk$store)) store <- on_disk$store
  }

  title_embeddings <- embed_texts_cached(
    modules$title, store, api_key, model, base_url, batch_size, "titles",
    cache_path = cache_path
  )
  summary_embeddings <- embed_texts_cached(
    modules$functional_summary, store, api_key, model, base_url, batch_size, "summaries",
    cache_path = cache_path
  )
  save_embedding_store(store, cache_path, model, base_url)

  list(title = title_embeddings, summary = summary_embeddings)
}

load_embeddings_from_cache_only <- function(modules, output_dir, model) {
  cache_path <- file.path(output_dir, "module_text_embeddings.rds")
  if (!file.exists(cache_path)) {
    stop("Embedding cache does not exist: ", cache_path, ". Run --step=embed first.")
  }
  on_disk <- readRDS(cache_path)
  if (!is.list(on_disk) || !is.environment(on_disk$store)) {
    stop("Embedding cache has an unsupported format: ", cache_path)
  }
  store <- on_disk$store

  fetch_cached <- function(texts, label) {
    texts <- as.character(texts)
    texts[is.na(texts) | !nzchar(texts)] <- " "
    keys <- vapply(texts, embedding_cache_key, character(1), model = model)
    result <- vector("list", length(texts))
    missing <- integer(0)
    for (i in seq_along(keys)) {
      hit <- store_get(store, keys[[i]])
      if (is.null(hit)) {
        missing <- c(missing, i)
      } else {
        result[[i]] <- hit
      }
    }
    if (length(missing) > 0) {
      stop(
        "Embedding cache is incomplete for ", label, ": ", length(missing),
        " missing. Run --step=embed with the same --phenotype_csv and --embedding_model first."
      )
    }
    result
  }

  list(
    title = fetch_cached(modules$title, "titles"),
    summary = fetch_cached(modules$functional_summary, "summaries")
  )
}

embedding_matrix <- function(embedding_list) {
  nonempty <- which(lengths(embedding_list) > 0)
  if (length(nonempty) == 0) stop("No embeddings were returned.")
  d <- length(embedding_list[[nonempty[[1]]]])
  mat <- matrix(0, nrow = length(embedding_list), ncol = d)

  for (i in seq_along(embedding_list)) {
    v <- embedding_list[[i]]
    if (!is.null(v) && length(v) == d) mat[i, ] <- v
  }

  norms <- sqrt(rowSums(mat * mat))
  ok <- norms > 0 & !is.na(norms)
  mat[ok, ] <- mat[ok, , drop = FALSE] / norms[ok]
  mat[!ok, ] <- 0
  mat
}

build_module_sets <- function(modules, memberships) {
  split_edges <- split(memberships, memberships$Module_Key)
  sets <- vector("list", nrow(modules))

  for (i in seq_len(nrow(modules))) {
    edges <- split_edges[[modules$Module_Key[[i]]]]
    if (is.null(edges)) {
      edges <- data.frame(INCHI_ID = character(0), Membership_Type = character(0))
    }
    ids_by_type <- split(edges$INCHI_ID, edges$Membership_Type)

    pathway <- unique(c(
      split_semicolon(column_value(modules, "hmdb_pathway_ids", i)),
      split_semicolon(column_value(modules, "kegg_pathway_ids", i))
    ))
    if (length(pathway) == 0) {
      pathway <- unique(c(
        vapply(split_semicolon(column_value(modules, "top_hmdb_pathways", i)), normalize_token, character(1)),
        vapply(split_semicolon(column_value(modules, "top_kegg_pathways", i)), normalize_token, character(1))
      ))
    }

    sets[[i]] <- list(
      core = drop_empty(ids_by_type$core),
      supporting = drop_empty(ids_by_type$supporting),
      contextual = drop_empty(ids_by_type$contextual),
      class = unique(drop_empty(vapply(
        split_semicolon(column_value(modules, "class_names", i)),
        normalize_token,
        character(1)
      ))),
      pathway = drop_empty(pathway)
    )
  }

  sets
}

sparse_indicator <- function(set_list) {
  if (!requireNamespace("Matrix", quietly = TRUE)) stop("Package 'Matrix' is required.")

  n <- length(set_list)
  set_list <- lapply(set_list, function(x) unique(drop_empty(x)))
  sizes <- lengths(set_list)
  terms <- unique(unlist(set_list, use.names = FALSE))

  if (length(terms) == 0) {
    return(list(mat = Matrix::Matrix(0, nrow = n, ncol = 0, sparse = TRUE), sizes = sizes))
  }

  term_id <- setNames(seq_along(terms), terms)
  rows <- rep(seq_len(n), sizes)
  cols <- unname(term_id[unlist(set_list, use.names = FALSE)])

  list(
    mat = Matrix::sparseMatrix(i = rows, j = cols, x = 1, dims = c(n, length(terms))),
    sizes = sizes
  )
}

jaccard_chunk <- function(indicator, rows) {
  if (ncol(indicator$mat) == 0) {
    return(matrix(0, nrow = length(rows), ncol = nrow(indicator$mat)))
  }
  overlap <- as.matrix(indicator$mat[rows, , drop = FALSE] %*% Matrix::t(indicator$mat))
  union_n <- outer(indicator$sizes[rows], indicator$sizes, `+`) - overlap
  out <- overlap / union_n
  out[union_n == 0] <- 0
  out
}

append_csv <- function(df, path, append) {
  utils::write.table(
    df,
    file = path,
    sep = ",",
    row.names = FALSE,
    col.names = !append,
    append = append,
    na = "",
    quote = TRUE,
    qmethod = "double"
  )
}

empty_similarity_edges <- function() {
  data.frame(
    Module_Key_1 = character(0),
    Relationship = character(0),
    Module_Key_2 = character(0),
    Type = character(0),
    Similarity_Score = numeric(0),
    Similarity_Tier = character(0),
    Biological_Score = numeric(0),
    Compositional_Score = numeric(0),
    Cross_Study = logical(0),
    stringsAsFactors = FALSE
  )
}

score_module_pairs_chunked <- function(modules, memberships, embeddings, output_dir,
                                       min_similarity_score = 0.70, chunk_size = 200L) {
  edge_path <- file.path(output_dir, "edges_module_module_prelim.csv")
  if (file.exists(edge_path)) file.remove(edge_path)

  if (nrow(modules) < 2) {
    write_csv(empty_similarity_edges(), edge_path)
    return(0L)
  }

  title_mat <- embedding_matrix(embeddings$title)
  summary_mat <- embedding_matrix(embeddings$summary)

  hypothesis <- tolower(clean_vec(modules$hypothesis_type))
  hypothesis_ids <- match(hypothesis, unique(hypothesis[!is.na(hypothesis)]))

  sets <- build_module_sets(modules, memberships)
  core <- sparse_indicator(lapply(sets, `[[`, "core"))
  supporting <- sparse_indicator(lapply(sets, `[[`, "supporting"))
  contextual <- sparse_indicator(lapply(sets, `[[`, "contextual"))
  class <- sparse_indicator(lapply(sets, `[[`, "class"))
  pathway <- sparse_indicator(lapply(sets, `[[`, "pathway"))

  n <- nrow(modules)
  edge_count <- 0L
  append <- FALSE

  for (start in seq(1L, n, by = chunk_size)) {
    end <- min(n, start + chunk_size - 1L)
    rows <- start:end
    message("Scoring module rows ", start, "-", end, " / ", n)

    title_sim <- title_mat[rows, , drop = FALSE] %*% t(title_mat)
    summary_sim <- summary_mat[rows, , drop = FALSE] %*% t(summary_mat)

    same_hypothesis <- outer(hypothesis_ids[rows], hypothesis_ids, `==`)
    same_hypothesis[is.na(same_hypothesis)] <- FALSE
    storage.mode(same_hypothesis) <- "double"

    core_jac <- jaccard_chunk(core, rows)
    supporting_jac <- jaccard_chunk(supporting, rows)
    contextual_jac <- jaccard_chunk(contextual, rows)
    class_jac <- jaccard_chunk(class, rows)
    pathway_jac <- jaccard_chunk(pathway, rows)

    metabolite_score <- 0.50 * core_jac + 0.30 * supporting_jac + 0.20 * contextual_jac
    compositional_score <- 0.40 * metabolite_score + 0.25 * pathway_jac + 0.25 * class_jac +
      0.10 * same_hypothesis
    biological_score <- 0.50 * summary_sim + 0.40 * title_sim + 0.10 * same_hypothesis
    final_score <- 0.75 * pmax(biological_score, compositional_score) +
      0.25 * ((biological_score + compositional_score) / 2)

    for (r in seq_along(rows)) final_score[r, seq_len(rows[[r]])] <- NA_real_
    keep <- !is.na(final_score) & final_score >= min_similarity_score
    idx <- which(keep, arr.ind = TRUE)

    if (nrow(idx) > 0) {
      i_idx <- rows[idx[, "row"]]
      j_idx <- idx[, "col"]
      scores <- final_score[idx]
      bio <- biological_score[idx]
      comp <- compositional_score[idx]

      type <- ifelse(
        bio >= 0.35 & comp >= 0.35 & abs(bio - comp) <= 0.10,
        "mixed",
        ifelse(bio >= comp, "biological", "compositional")
      )
      tier <- as.character(cut(
        scores,
        breaks = c(-Inf, 0.35, 0.55, 0.75, Inf),
        labels = c("candidate", "low", "medium", "high"),
        right = FALSE
      ))

      out <- data.frame(
        Module_Key_1 = modules$Module_Key[i_idx],
        Relationship = "similar to",
        Module_Key_2 = modules$Module_Key[j_idx],
        Type = type,
        Similarity_Score = scores,
        Similarity_Tier = tier,
        Biological_Score = bio,
        Compositional_Score = comp,
        Cross_Study = modules$Study_Accession[i_idx] != modules$Study_Accession[j_idx],
        stringsAsFactors = FALSE
      )

      append_csv(out, edge_path, append = append)
      append <- TRUE
      edge_count <- edge_count + nrow(out)
    } else if (!file.exists(edge_path)) {
      write_csv(empty_similarity_edges(), edge_path)
      append <- TRUE
    }

    rm(title_sim, summary_sim, same_hypothesis, core_jac, supporting_jac,
       contextual_jac, class_jac, pathway_jac, metabolite_score,
       compositional_score, biological_score, final_score)
    gc(verbose = FALSE)
  }

  edge_count
}

write_run_report <- function(args, prepared, modules, memberships, n_edges = NA_integer_,
                             step_status = args$step) {
  report <- data.frame(
    step = args$step,
    step_status = step_status,
    n_modules = nrow(modules),
    n_metabolite_module_rows = nrow(memberships),
    n_module_module_edges = n_edges,
    phenotype_csv = args$phenotype_csv,
    n_final_study_ids = length(prepared$final_study_ids),
    n_final_studies_with_modules = length(unique(modules$Study_Accession)),
    embedding_model = args$embedding_model,
    min_similarity_score = args$min_similarity_score,
    chunk_size = args$chunk_size,
    module_id_type = "Module_Key",
    metabolite_id_type = "INCHI_ID",
    output_dir = args$output_dir,
    run_finished_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %z"),
    stringsAsFactors = FALSE
  )
  write_csv(report, file.path(args$output_dir, "module_similarity_run_report.csv"))
  report
}

main <- function() {
  args <- parse_args()
  dir.create(args$output_dir, recursive = TRUE, showWarnings = FALSE)

  prepared <- prepare_similarity_inputs(
    args$module_prelim_dir,
    args$output_dir,
    args$limit_modules,
    args$phenotype_csv
  )
  modules <- prepared$modules
  memberships <- prepared$memberships

  message("Modules: ", nrow(modules))
  message("Metabolite-module rows: ", nrow(memberships))
  message("Embedding fields: title and functional_summary, separately.")
  message("Module identifier: Module_Key. No final Lab_ID is assigned here.")
  message("Step: ", args$step)

  if (identical(args$step, "prepare")) {
    report <- write_run_report(args, prepared, modules, memberships, step_status = "prepared_inputs_only")
    message("Prepared filtered inputs only. No embedding/API call and no similarity scoring were run.")
    print(report)
    return(invisible(report))
  }

  if (nrow(modules) == 0) {
    stop("No modules remain after filtering. Check --phenotype_csv and module_prelim input.")
  }

  if (identical(args$step, "similarity")) {
    message("Loading embeddings from cache only. This step will not call the OpenAI API.")
    embeddings <- load_embeddings_from_cache_only(modules, args$output_dir, args$embedding_model)
  } else {
    embeddings <- load_or_build_embeddings(
      modules,
      args$output_dir,
      api_key = args$api_key,
      model = args$embedding_model,
      base_url = args$base_url,
      batch_size = args$embedding_batch_size
    )
  }

  if (identical(args$step, "embed")) {
    report <- write_run_report(args, prepared, modules, memberships, step_status = "embedded_only")
    message("Embedding cache is complete for the filtered modules. Similarity scoring was not run.")
    print(report)
    return(invisible(report))
  }

  n_edges <- score_module_pairs_chunked(
    modules,
    memberships,
    embeddings,
    args$output_dir,
    min_similarity_score = args$min_similarity_score,
    chunk_size = args$chunk_size
  )

  report <- write_run_report(args, prepared, modules, memberships, n_edges, step_status = "similarity_done")

  message("Done.")
  print(report)
}

if (identical(environment(), globalenv()) && !interactive()) {
  main()
}
