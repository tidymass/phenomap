# Generate PhenoMAP Metabolic module entity table.
#
# Output:
#   nodes_module.csv

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

split_metabolite_names <- function(x) {
  x <- phenomap_clean_scalar(x)
  if (is.na(x)) return(character(0))
  vals <- trimws(unlist(strsplit(x, ";", fixed = TRUE), use.names = FALSE))
  vals <- vals[nzchar(vals) & !is.na(vals)]
  unique(vals)
}

normalize_metabolite_name <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[[:space:]]+", " ", x)
  x
}

module_metabolite_match_prompt <- function(unmatched_terms,
                                           candidate_df,
                                           module_id,
                                           module_title = NA_character_) {
  candidate_df <- candidate_df[, intersect(
    "Compound_name",
    colnames(candidate_df)
  ), drop = FALSE]
  candidate_df <- candidate_df[!duplicated(candidate_df$Compound_name), , drop = FALSE]

  paste(
    "You are helping curate metabolite name mappings for a metabolomics knowledge graph.",
    "",
    "Task:",
    "For each unmatched metabolite name, decide whether it refers to one of the candidate metabolites from the SAME module.",
    "Only choose from the candidate list. Do not invent metabolites or identifiers.",
    "Use biochemical naming knowledge, synonyms, Greek-letter variants, hyphenation variants, and common stereochemical/name variants.",
    "If a generic name clearly refers to multiple stereochemical or naming variants in the candidate list, return all plausible candidate names.",
    "For example, if the query is Carvone and the candidates contain both (S)-Carvone and (R)-Carvone, return both candidate names.",
    "If no candidate is clearly the same metabolite, return an empty matched_names array.",
    "Your only job is name matching. Do not provide metabolite identifiers.",
    "",
    "Return STRICT JSON only:",
    "{",
    '  "matches": [',
    "    {",
    '      "query_name": "...",',
    '      "matched_names": ["candidate Compound_name 1", "candidate Compound_name 2"],',
    '      "confidence": "high | medium | low | none",',
    '      "rationale": "short reason"',
    "    }",
    "  ]",
    "}",
    "",
    paste0("Module ID: ", module_id),
    paste0("Module title: ", phenomap_clean_scalar(module_title, "NA")),
    "",
    "Unmatched metabolite names:",
    paste(paste0("- ", unmatched_terms), collapse = "\n"),
    "",
    "Candidate metabolites from this module:",
    paste(utils::capture.output(utils::write.table(
      candidate_df,
      sep = "\t",
      quote = FALSE,
      row.names = FALSE,
      na = ""
    )), collapse = "\n"),
    sep = "\n"
  )
}

call_gpt_for_metabolite_match <- function(prompt,
                                          api_key = Sys.getenv("OPENAI_API_KEY"),
                                          model = "gpt-4.1-mini",
                                          base_url = "https://api.openai.com/v1") {
  if (!requireNamespace("httr", quietly = TRUE)) {
    stop("Package 'httr' is required for LLM metabolite matching.")
  }
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("Package 'jsonlite' is required for LLM metabolite matching.")
  }
  if (is.na(api_key) || !nzchar(api_key)) {
    stop("API key is empty. Set OPENAI_API_KEY or pass api_key.")
  }

  endpoint <- sub("/+$", "", base_url)
  if (!grepl("/chat/completions$", endpoint)) {
    endpoint <- paste0(endpoint, "/chat/completions")
  }

  body <- list(
    model = model,
    messages = list(
      list(
        role = "system",
        content = "You are a careful metabolomics database curator. Return only valid JSON."
      ),
      list(role = "user", content = prompt)
    ),
    temperature = 0,
    response_format = list(type = "json_object")
  )

  resp <- httr::POST(
    endpoint,
    httr::add_headers(
      Authorization = paste("Bearer", api_key),
      `Content-Type` = "application/json"
    ),
    body = jsonlite::toJSON(body, auto_unbox = TRUE, null = "null"),
    encode = "raw",
    httr::timeout(120)
  )

  if (httr::status_code(resp) >= 400) {
    body$response_format <- NULL
    resp <- httr::POST(
      endpoint,
      httr::add_headers(
        Authorization = paste("Bearer", api_key),
        `Content-Type` = "application/json"
      ),
      body = jsonlite::toJSON(body, auto_unbox = TRUE, null = "null"),
      encode = "raw",
      httr::timeout(120)
    )
  }

  txt <- httr::content(resp, as = "text", encoding = "UTF-8")
  if (httr::status_code(resp) >= 400) {
    stop("LLM metabolite matching failed with status ", httr::status_code(resp), ": ", txt)
  }

  payload <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
  content <- payload$choices[[1]]$message$content
  parsed <- tryCatch(
    jsonlite::fromJSON(content, simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.null(parsed)) {
    json_text <- regmatches(content, regexpr("\\{[\\s\\S]*\\}", content, perl = TRUE))
    if (length(json_text) == 0 || !nzchar(json_text[[1]])) {
      stop("Could not parse LLM metabolite matching JSON: ", content)
    }
    parsed <- jsonlite::fromJSON(json_text[[1]], simplifyVector = FALSE)
  }
  parsed$raw_response <- content
  parsed
}

apply_llm_metabolite_matches <- function(map_result,
                                         module_candidates,
                                         module_id,
                                         module_title,
                                         use_llm = TRUE,
                                         api_key = Sys.getenv("OPENAI_API_KEY"),
                                         model = "gpt-4.1-mini",
                                         base_url = "https://api.openai.com/v1") {
  unmatched_terms <- split_metabolite_names(map_result$unmatched)
  map_result$llm_json <- NA_character_
  map_result$llm_error <- NA_character_
  if (is.null(map_result$names)) {
    map_result$names <- NA_character_
  }

  if (length(unmatched_terms) == 0 || !isTRUE(use_llm)) {
    return(map_result)
  }
  if (!is.data.frame(module_candidates) ||
      nrow(module_candidates) == 0 ||
      !all(c("Module", "Compound_name", "INCHI_ID") %in% colnames(module_candidates))) {
    return(map_result)
  }

  prompt <- module_metabolite_match_prompt(
    unmatched_terms = unmatched_terms,
    candidate_df = module_candidates,
    module_id = module_id,
    module_title = module_title
  )

  parsed <- tryCatch(
    call_gpt_for_metabolite_match(
      prompt = prompt,
      api_key = api_key,
      model = model,
      base_url = base_url
    ),
    error = function(e) {
      map_result$llm_error <<- conditionMessage(e)
      NULL
    }
  )

  if (is.null(parsed) || is.null(parsed$matches)) {
    return(map_result)
  }

  matches <- parsed$matches
  if (is.data.frame(matches)) {
    matches <- split(matches, seq_len(nrow(matches)))
  }

  candidate_df <- module_candidates[, c("Compound_name", "INCHI_ID"), drop = FALSE]
  candidate_df$Compound_name <- as.character(candidate_df$Compound_name)
  candidate_df$INCHI_ID <- as.character(candidate_df$INCHI_ID)
  candidate_df <- candidate_df[
    !is.na(candidate_df$Compound_name) & nzchar(candidate_df$Compound_name) &
      !is.na(candidate_df$INCHI_ID) & nzchar(candidate_df$INCHI_ID),
    ,
    drop = FALSE
  ]

  resolve_llm_candidate_names <- function(match_item) {
    matched_names <- match_item$matched_names
    if (is.null(matched_names)) matched_names <- match_item$matched_name
    if (is.null(matched_names)) return(character(0))
    if (is.list(matched_names)) matched_names <- unlist(matched_names, use.names = FALSE)
    matched_names <- unique(phenomap_drop_empty(as.character(matched_names)))
    if (length(matched_names) == 0) return(character(0))

    out <- character(0)
    for (matched_name in matched_names) {
      hit <- candidate_df[candidate_df$Compound_name == matched_name, , drop = FALSE]
      if (nrow(hit) == 0) {
        hit <- candidate_df[
          normalize_metabolite_name(candidate_df$Compound_name) ==
            normalize_metabolite_name(matched_name),
          ,
          drop = FALSE
        ]
      }

      names <- unique(as.character(hit$Compound_name))
      names <- names[!is.na(names) & nzchar(names)]
      if (length(names) > 0) out <- c(out, names)
    }

    unique(out)
  }

  current_terms <- split_metabolite_names(map_result$names)
  if (length(current_terms) == 0) current_terms <- unmatched_terms
  resolved <- character(0)

  for (m in matches) {
    query <- phenomap_clean_scalar(m$query_name)
    conf <- tolower(phenomap_clean_scalar(m$confidence, "none"))
    matched_names <- resolve_llm_candidate_names(m)
    if (!is.na(query) && length(matched_names) > 0 && conf %in% c("high", "medium")) {
      next_terms <- character(0)
      for (term in current_terms) {
        if (identical(term, query)) {
          next_terms <- c(next_terms, matched_names)
        } else {
          next_terms <- c(next_terms, term)
        }
      }
      current_terms <- unique(next_terms)
      if (!is.na(query)) resolved <- c(resolved, query)
    }
  }

  local_module_id <- unique(as.character(module_candidates$Module))
  local_module_id <- local_module_id[!is.na(local_module_id) & nzchar(local_module_id)]
  if (length(local_module_id) == 0) return(map_result)

  remapped <- map_module_names_to_inchi(
    names_text = paste(current_terms, collapse = "; "),
    module_table = module_candidates,
    local_module_id = local_module_id[[1]]
  )
  still_unmatched <- setdiff(unmatched_terms, resolved)
  if (!is.na(remapped$unmatched)) {
    still_unmatched <- unique(c(still_unmatched, split_metabolite_names(remapped$unmatched)))
  }

  map_result$names <- paste(current_terms, collapse = "; ")
  map_result$ids <- remapped$ids
  map_result$unmatched <- if (length(still_unmatched) > 0) paste(still_unmatched, collapse = "; ") else NA_character_
  map_result$llm_json <- phenomap_clean_scalar(parsed$raw_response)
  map_result
}

map_module_names_to_inchi <- function(names_text, module_table, local_module_id) {
  terms <- split_metabolite_names(names_text)
  if (length(terms) == 0 ||
      !is.data.frame(module_table) ||
      nrow(module_table) == 0 ||
      !all(c("Module", "Compound_name", "INCHI_ID") %in% colnames(module_table))) {
    return(list(
      names = if (length(terms) > 0) paste(terms, collapse = "; ") else NA_character_,
      ids = NA_character_,
      unmatched = if (length(terms) > 0) paste(terms, collapse = "; ") else NA_character_
    ))
  }

  mt <- module_table[module_table$Module == local_module_id, , drop = FALSE]
  mt <- mt[!is.na(mt$Compound_name) & nzchar(as.character(mt$Compound_name)) &
             !is.na(mt$INCHI_ID) & nzchar(as.character(mt$INCHI_ID)), , drop = FALSE]
  if (nrow(mt) == 0) {
    return(list(
      names = if (length(terms) > 0) paste(terms, collapse = "; ") else NA_character_,
      ids = NA_character_,
      unmatched = if (length(terms) > 0) paste(terms, collapse = "; ") else NA_character_
    ))
  }

  ids <- character(0)
  unmatched <- character(0)

  for (term in terms) {
    exact <- mt$INCHI_ID[mt$Compound_name == term]
    if (length(exact) == 0) {
      exact <- mt$INCHI_ID[
        normalize_metabolite_name(mt$Compound_name) == normalize_metabolite_name(term)
      ]
    }

    exact <- unique(as.character(exact[!is.na(exact) & nzchar(exact)]))
    if (length(exact) > 0) {
      ids <- c(ids, exact)
    } else {
      unmatched <- c(unmatched, term)
    }
  }

  list(
    names = if (length(terms) > 0) paste(terms, collapse = "; ") else NA_character_,
    ids = if (length(ids) > 0) paste(unique(ids), collapse = "; ") else NA_character_,
    unmatched = if (length(unmatched) > 0) paste(unique(unmatched), collapse = "; ") else NA_character_
  )
}

make_pathway_name_lookup <- function(pathway_df) {
  if (is.null(pathway_df) || !is.data.frame(pathway_df) || nrow(pathway_df) == 0) {
    return(data.frame())
  }
  if (!all(c("pathway_id", "pathway_name") %in% colnames(pathway_df))) {
    return(data.frame())
  }
  out <- pathway_df[!is.na(pathway_df$pathway_name) &
                      nzchar(as.character(pathway_df$pathway_name)) &
                      !is.na(pathway_df$pathway_id) &
                      nzchar(as.character(pathway_df$pathway_id)),
                    c("pathway_name", "pathway_id"),
                    drop = FALSE]
  out <- out[!duplicated(out$pathway_name), , drop = FALSE]
  out$key <- normalize_metabolite_name(out$pathway_name)
  out
}

add_pathway_ids_to_text <- function(pathway_text, pathway_lookup) {
  pathway_text <- phenomap_clean_scalar(pathway_text)
  if (is.na(pathway_text)) return(NA_character_)
  if (is.null(pathway_lookup) || !is.data.frame(pathway_lookup) || nrow(pathway_lookup) == 0) {
    return(pathway_text)
  }

  parts <- trimws(unlist(strsplit(pathway_text, ";", fixed = TRUE), use.names = FALSE))
  parts <- parts[nzchar(parts) & !is.na(parts)]

  out <- vapply(parts, function(part) {
    pathway_name <- trimws(sub("\\s*\\([^)]*\\)\\s*$", "", part))
    key <- normalize_metabolite_name(pathway_name)
    idx <- match(key, pathway_lookup$key)
    if (!is.na(idx)) {
      paste0(pathway_lookup$pathway_id[[idx]], ":", part)
    } else {
      part
    }
  }, character(1))
  paste(out, collapse = "; ")
}

build_module_entity_one_case <- function(case_dir,
                                         pathway_hmdb_lookup = NULL,
                                         pathway_kegg_lookup = NULL,
                                         use_llm = TRUE,
                                         api_key = Sys.getenv("OPENAI_API_KEY"),
                                         model = "gpt-4.1-mini",
                                         base_url = "https://api.openai.com/v1") {
  meta <- phenomap_read_json(file.path(case_dir, "study_meta.json"))
  study_id <- phenomap_case_id(case_dir, meta)
  res <- phenomap_load_res(case_dir)
  if (is.null(res)) return(data.frame())

  module_function <- phenomap_safe_df(res$module_function)
  if (nrow(module_function) == 0) return(data.frame())

  module_score <- phenomap_safe_df(res$module_score)
  module_table <- phenomap_safe_df(res$module_table)
  if (nrow(module_score) > 0 && "Module" %in% colnames(module_score)) {
    module_score$Module <- as.character(module_score$Module)
  }

  local_module <- as.character(phenomap_col(module_function, "module_id"))
  top_metabolites_raw <- if ("core_drivers" %in% colnames(module_function)) {
    phenomap_col(module_function, "core_drivers")
  } else {
    phenomap_col(module_function, "top_metabolites")
  }

  out <- data.frame(
    module_id = vapply(local_module, function(x) phenomap_make_module_id(study_id, x), character(1)),
    local_module_id_internal = local_module,
    study_id = study_id,
    structured_outputs = NA_character_,
    origin_type = phenomap_col(module_function, "hypothesis_type"),
    module_title = phenomap_col(module_function, "title"),
    functional_summary = phenomap_col(module_function, "functional_summary"),
    anchor_metabolites = phenomap_col(module_function, "anchor_metabolites"),
    top_metabolites = top_metabolites_raw,
    anchor_metabolite_ids = NA_character_,
    top_metabolite_ids = NA_character_,
    anchor_metabolites_unmatched = NA_character_,
    top_metabolites_unmatched = NA_character_,
    anchor_metabolites_llm_match = NA_character_,
    top_metabolites_llm_match = NA_character_,
    metabolite_match_llm_error = NA_character_,
    top_kegg_pathways = phenomap_col(module_function, "top_kegg_pathways"),
    top_hmdb_pathways = phenomap_col(module_function, "top_hmdb_pathways"),
    top_kegg_pathways_with_id = NA_character_,
    top_hmdb_pathways_with_id = NA_character_,
    class_coverage = phenomap_col(module_function, "class_names"),
    global_direction = phenomap_col(module_function, "global_direction"),
    confidence_label = phenomap_col(module_function, "confidence_label"),
    confidence_rationale = phenomap_col(module_function, "rationale"),
    phenotype_relationship = phenomap_col(module_function, "phenotype_relationship"),
    literature_support = phenomap_col(module_function, "pubmed_evidence_json"),
    pubmed_pmids = phenomap_col(module_function, "pubmed_pmids"),
    origin_endogenous_frac = suppressWarnings(as.numeric(phenomap_col(module_function, "origin_endogenous_frac"))),
    origin_exogenous_frac = suppressWarnings(as.numeric(phenomap_col(module_function, "origin_exogenous_frac"))),
    raw_response_call1 = phenomap_col(module_function, "raw_response_call1"),
    raw_response_call2 = phenomap_col(module_function, "raw_response_call2"),
    featuremap_stage = phenomap_clean_scalar(res$stage),
    stringsAsFactors = FALSE
  )

  for (i in seq_len(nrow(out))) {
    local_id <- local_module[[i]]
    module_candidates <- module_table[module_table$Module == local_id, , drop = FALSE]

    anchor_map <- map_module_names_to_inchi(
      names_text = out$anchor_metabolites[[i]],
      module_table = module_table,
      local_module_id = local_id
    )
    core_map <- map_module_names_to_inchi(
      names_text = out$top_metabolites[[i]],
      module_table = module_table,
      local_module_id = local_id
    )

    anchor_map <- apply_llm_metabolite_matches(
      map_result = anchor_map,
      module_candidates = module_candidates,
      module_id = out$module_id[[i]],
      module_title = out$module_title[[i]],
      use_llm = use_llm,
      api_key = api_key,
      model = model,
      base_url = base_url
    )
    out$anchor_metabolites[[i]] <- anchor_map$names
    out$anchor_metabolite_ids[[i]] <- anchor_map$ids
    out$anchor_metabolites_unmatched[[i]] <- anchor_map$unmatched
    out$top_metabolite_ids[[i]] <- core_map$ids
    out$top_metabolites_unmatched[[i]] <- core_map$unmatched
    out$anchor_metabolites_llm_match[[i]] <- anchor_map$llm_json
    out$top_metabolites_llm_match[[i]] <- NA_character_
    out$metabolite_match_llm_error[[i]] <- paste(
      unique(anchor_map$llm_error[!is.na(anchor_map$llm_error)]),
      collapse = "; "
    )
    if (!nzchar(out$metabolite_match_llm_error[[i]])) out$metabolite_match_llm_error[[i]] <- NA_character_

    out$top_kegg_pathways_with_id[[i]] <- add_pathway_ids_to_text(
      out$top_kegg_pathways[[i]],
      pathway_kegg_lookup
    )
    out$top_hmdb_pathways_with_id[[i]] <- add_pathway_ids_to_text(
      out$top_hmdb_pathways[[i]],
      pathway_hmdb_lookup
    )
  }

  if (nrow(module_score) > 0) {
    score_cols <- c("Module", "Module_size", "Annotated_nodes", "Module_score", "p", "fdr")
    for (nm in score_cols) if (!nm %in% colnames(module_score)) module_score[[nm]] <- NA
    module_score <- module_score[, score_cols, drop = FALSE]
    out <- merge(
      out,
      module_score,
      by.x = "local_module_id_internal",
      by.y = "Module",
      all.x = TRUE,
      sort = FALSE
    )
  } else {
    out$Module_size <- NA_integer_
    out$Annotated_nodes <- NA_integer_
    out$Module_score <- NA_real_
    out$p <- NA_real_
    out$fdr <- NA_real_
  }

  # Keep a compact JSON copy of structured featureMAP output for traceability.
  out$structured_outputs <- vapply(seq_len(nrow(out)), function(i) {
    row <- module_function[i, , drop = FALSE]
    tryCatch(
      jsonlite::toJSON(row, dataframe = "rows", auto_unbox = TRUE, na = "null"),
      error = function(e) NA_character_
    )
  }, character(1))

  out$local_module_id_internal <- NULL
  out
}

build_module_entity <- function(case_root,
                                output_dir = file.path("2_data", "tidy_entity"),
                                workers = max(1L, parallel::detectCores(logical = FALSE) - 1L),
                                use_llm = TRUE,
                                api_key = Sys.getenv("OPENAI_API_KEY"),
                                model = "gpt-4.1-mini",
                                base_url = "https://api.openai.com/v1") {
  case_dirs <- phenomap_case_dirs(case_root, require_meta = TRUE, require_res = TRUE)
  workers <- suppressWarnings(as.integer(workers))
  if (is.na(workers) || workers < 1L) workers <- 1L
  workers <- min(workers, length(case_dirs))

  message("Building module entity table from ", length(case_dirs), " cases using ", workers, " worker(s).")
  message("Loading featuremap pathway resources when available.")
  pathway_hmdb_lookup <- make_pathway_name_lookup(phenomap_try_load_featuremap_resource("pathway_hmdb"))
  pathway_kegg_lookup <- make_pathway_name_lookup(phenomap_try_load_featuremap_resource("pathway_kegg"))

  process_one <- function(case_dir) {
    message("Reading modules from ", basename(case_dir))
    tryCatch(
      build_module_entity_one_case(
        case_dir,
        pathway_hmdb_lookup = pathway_hmdb_lookup,
        pathway_kegg_lookup = pathway_kegg_lookup,
        use_llm = use_llm,
        api_key = api_key,
        model = model,
        base_url = base_url
      ),
      error = function(e) {
        warning("Failed to process ", basename(case_dir), ": ", conditionMessage(e))
        data.frame()
      }
    )
  }

  rows <- if (workers > 1L) {
    # Use PSOCK clusters instead of mclapply/fork. Forking is unstable on macOS
    # when Objective-C libraries have already been initialized.
    cl <- parallel::makeCluster(workers)
    on.exit(parallel::stopCluster(cl), add = TRUE)
    parallel::clusterExport(
      cl,
      varlist = c(
        "pathway_hmdb_lookup", "pathway_kegg_lookup",
        "use_llm", "api_key", "model", "base_url", "process_one"
      ),
      envir = environment()
    )
    parallel::clusterExport(
      cl,
      varlist = ls(
        envir = globalenv(),
        pattern = "^(phenomap_|split_|normalize_|module_|call_|apply_|map_|add_|build_)"
      ),
      envir = globalenv()
    )
    parallel::parLapply(
      cl,
      case_dirs,
      process_one
    )
  } else {
    lapply(case_dirs, process_one)
  }
  rows <- rows[vapply(rows, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))]

  if (length(rows) == 0) {
    out <- data.frame()
  } else {
    out <- do.call(rbind, rows)
    out <- out[order(out$study_id, out$module_id), , drop = FALSE]
  }

  phenomap_write_csv(out, file.path(output_dir, "nodes_module.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_parse_args()
  build_module_entity(
    case_root = args$case_root,
    output_dir = args$output_dir,
    workers = args$workers,
    use_llm = args$use_llm,
    model = args$model,
    base_url = args$base_url
  )
}
