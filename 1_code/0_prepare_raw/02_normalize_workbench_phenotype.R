# Normalize the free-text phenotype field in Workbench study_meta.json files.
#
# Strategy:
#   1. Use a GPT model to extract exactly one principal human phenotype from
#      study title/summary/design.
#   2. Search that phenotype and its aliases in all ontology sources:
#      MONDO, EFO, MeSH, and HPO through EMBL-EBI OLS.
#   3. Use a GPT model to select one best ontology match, or mark the case for
#      manual review when no match or no clear best match exists.
#
# This script writes reviewable CSV outputs only. It does not modify
# study_meta.json files.
#
# Usage:
#   Rscript 1_code/0_prepare_raw/02_normalize_workbench_phenotype.R
#   Rscript 1_code/0_prepare_raw/02_normalize_workbench_phenotype.R --model=gpt-4.1
#   Rscript 1_code/0_prepare_raw/02_normalize_workbench_phenotype.R --limit=10

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

parse_workbench_pheno_args <- function() {
  raw <- commandArgs(trailingOnly = TRUE)
  args <- list(
    case_root = file.path("2_data", "raw", "workbench_20260629", "out_qwen_eval_mw_anno"),
    output_dir = file.path("2_data", "raw", "workbench_20260629", "phenotype_normalization"),
    model = "gpt-4.1-mini",
    base_url = "https://api.openai.com/v1",
    ols_base_url = "https://www.ebi.ac.uk/ols4/api",
    ontology_rows = 10L,
    limit = NA_integer_,
    sleep_seconds = 0.05
  )

  for (arg in raw) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% names(args)) args[[key]] <- value
  }

  args$ontology_rows <- suppressWarnings(as.integer(args$ontology_rows))
  if (is.na(args$ontology_rows) || args$ontology_rows < 1L) args$ontology_rows <- 10L
  args$limit <- suppressWarnings(as.integer(args$limit))
  args$sleep_seconds <- suppressWarnings(as.numeric(args$sleep_seconds))
  if (is.na(args$sleep_seconds) || args$sleep_seconds < 0) args$sleep_seconds <- 0.05
  args
}

json_or_na <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  tryCatch(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null"), error = function(e) NA_character_)
}

clean_vec <- function(x) {
  if (is.null(x) || length(x) == 0) return(character(0))
  x <- unlist(x, recursive = TRUE, use.names = FALSE)
  x <- trimws(as.character(x))
  x[nzchar(x) & !is.na(x) & !toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")]
}

split_semicolon <- function(x) {
  x <- phenomap_clean_scalar(x)
  if (is.na(x)) return(character(0))
  clean_vec(strsplit(x, ";", fixed = TRUE)[[1]])
}

normalize_key <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[[:space:]]+", " ", x)
  x
}

normalize_phenotype_type <- function(x) {
  x <- tolower(phenomap_clean_scalar(x, "unclear"))
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  allowed <- c("disease", "severity", "exposure", "treatment", "trait", "unclear")
  if (x %in% allowed) x else "unclear"
}

normalize_ontology_id <- function(id, ontology = NA_character_) {
  id <- phenomap_clean_scalar(id)
  if (is.na(id)) return(NA_character_)
  id <- gsub("_", ":", id, fixed = TRUE)
  id <- gsub("^http.*/", "", id)
  id <- toupper(id)
  ontology <- tolower(phenomap_clean_scalar(ontology, ""))
  if (!grepl(":", id) && nzchar(ontology)) {
    prefix <- switch(
      ontology,
      mondo = "MONDO",
      efo = "EFO",
      hp = "HP",
      hpo = "HP",
      mesh = "MESH",
      toupper(ontology)
    )
    id <- paste0(prefix, ":", id)
  }
  id
}

call_gpt_json <- function(prompt,
                          api_key = Sys.getenv("OPENAI_API_KEY"),
                          model = "gpt-4.1-mini",
                          base_url = "https://api.openai.com/v1",
                          task = "GPT request") {
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required.")
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.")
  if (is.na(api_key) || !nzchar(api_key)) stop("API key is empty. Set OPENAI_API_KEY.")

  endpoint <- sub("/+$", "", base_url)
  if (!grepl("/chat/completions$", endpoint)) endpoint <- paste0(endpoint, "/chat/completions")

  body <- list(
    model = model,
    messages = list(
      list(
        role = "system",
        content = paste(
          "You are a careful biomedical phenotype and ontology curator.",
          "Return only valid JSON. Do not include markdown fences."
        )
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
    stop(task, " failed with status ", httr::status_code(resp), ": ", txt)
  }

  payload <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
  content <- payload$choices[[1]]$message$content
  parsed <- tryCatch(jsonlite::fromJSON(content, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(parsed)) {
    json_text <- regmatches(content, regexpr("\\{[\\s\\S]*\\}", content, perl = TRUE))
    if (length(json_text) == 0 || !nzchar(json_text[[1]])) {
      stop("Could not parse ", task, " JSON: ", content)
    }
    parsed <- jsonlite::fromJSON(json_text[[1]], simplifyVector = FALSE)
  }
  parsed$raw_response <- content
  parsed
}

read_workbench_meta_row <- function(case_dir) {
  meta <- phenomap_read_json(file.path(case_dir, "study_meta.json"))
  if (is.null(meta)) return(NULL)

  study_design <- meta$study_design %||% list()
  instrument <- meta$instrument %||% list()

  data.frame(
    study_id = phenomap_clean_scalar(meta$study_id %||% basename(case_dir), basename(case_dir)),
    case_dir = case_dir,
    study_title = phenomap_clean_scalar(meta$study_title),
    study_summary = phenomap_clean_scalar(meta$study_summary),
    current_phenotype = phenomap_clean_scalar(meta$phenotype),
    design_type = phenomap_clean_scalar(study_design$design_type),
    case_label = phenomap_clean_scalar(study_design$case),
    control_label = phenomap_clean_scalar(study_design$control),
    study_type_raw = phenomap_clean_scalar(study_design$study_type_raw),
    n_samples_analyzed = suppressWarnings(as.integer(study_design$n_samples_analyzed)),
    biospecimen = phenomap_clean_scalar(study_design$biospecimen),
    publication = phenomap_clean_scalar(meta$publication),
    publication_doi = phenomap_clean_scalar(meta$publication_doi),
    ms2_supported = isTRUE(meta$ms2_supported),
    chromatography_type = phenomap_clean_scalar(instrument$chromatography_type),
    ms_instrument_type = phenomap_clean_scalar(instrument$ms_instrument_type),
    ion_mode = phenomap_clean_scalar(instrument$ion_mode),
    stringsAsFactors = FALSE
  )
}

principal_phenotype_prompt <- function(row) {
  paste(
    "Task:",
    "Extract exactly one principal human phenotype for literature retrieval in featuremap.",
    "The phenotype must be the main human biological/clinical condition, exposure, treatment, severity state, or trait that the study focuses on.",
    "",
    "Allowed phenotype_type values:",
    "disease | severity | exposure | treatment | trait",
    "",
    "Hard exclusion rules:",
    "- Do not output healthy control, control, untreated, baseline, before, after, case-control, or other comparison-only labels.",
    "- Do not output country, ethnicity, cohort, age group, sex, sample source, biospecimen, platform, assay, chromatography, MS method, omics layer, pathway, biomarker, or mechanism.",
    "- Do not output broad words if a specific phenotype is available. For example, prefer non-small cell lung cancer over cancer.",
    "- If the study is not focused on a human phenotype, still return the closest human-relevant phenotype if it is explicit; otherwise set manual_review to true.",
    "",
    "Return STRICT JSON only:",
    "{",
    '  "principal_phenotype": "single professional term",',
    '  "phenotype_type": "disease | severity | exposure | treatment | trait",',
    '  "aliases": ["synonym or abbreviation", "expanded term"],',
    '  "query_terms": ["terms to search in every ontology"],',
    '  "manual_review": false,',
    '  "confidence": "high | medium | low",',
    '  "rationale": "short reason"',
    "}",
    "",
    "Study metadata:",
    paste0("- study_id: ", row$study_id),
    paste0("- title: ", row$study_title),
    paste0("- summary: ", row$study_summary),
    paste0("- current phenotype field: ", row$current_phenotype),
    paste0("- design_type: ", row$design_type),
    paste0("- case label: ", row$case_label),
    paste0("- control label: ", row$control_label),
    paste0("- raw study type: ", row$study_type_raw),
    paste0("- biospecimen: ", row$biospecimen),
    sep = "\n"
  )
}

extract_principal_phenotype <- function(row,
                                        api_key = Sys.getenv("OPENAI_API_KEY"),
                                        model = "gpt-4.1-mini",
                                        base_url = "https://api.openai.com/v1") {
  prompt <- principal_phenotype_prompt(row)
  parsed <- NULL
  error <- NA_character_

  parsed <- tryCatch(
    call_gpt_json(
      prompt = prompt,
      api_key = api_key,
      model = model,
      base_url = base_url,
      task = "principal phenotype extraction"
    ),
    error = function(e) {
      error <<- conditionMessage(e)
      NULL
    }
  )

  phenotype <- phenomap_clean_scalar(parsed$principal_phenotype)
  aliases <- clean_vec(parsed$aliases)
  query_terms <- clean_vec(c(parsed$query_terms, phenotype, aliases))
  manual_review <- isTRUE(parsed$manual_review) || is.na(phenotype) || !is.na(error)

  data.frame(
    study_id = row$study_id,
    principal_phenotype = phenotype,
    phenotype_type = normalize_phenotype_type(parsed$phenotype_type),
    aliases = phenomap_collapse(aliases),
    query_terms = phenomap_collapse(unique(query_terms)),
    extraction_manual_review = manual_review,
    extraction_confidence = tolower(phenomap_clean_scalar(parsed$confidence, "low")),
    extraction_rationale = phenomap_clean_scalar(parsed$rationale),
    extraction_prompt = prompt,
    extraction_raw_response = phenomap_clean_scalar(parsed$raw_response),
    extraction_error = error,
    stringsAsFactors = FALSE
  )
}

ols_search_one <- function(query,
                           ontology,
                           rows = 10L,
                           ols_base_url = "https://www.ebi.ac.uk/ols4/api") {
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required.")
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.")

  query <- phenomap_clean_scalar(query)
  ontology <- phenomap_clean_scalar(ontology)
  if (is.na(query) || is.na(ontology)) return(data.frame())

  empty_error_row <- function(error_message) {
    data.frame(
      ontology = tolower(ontology),
      query = query,
      rank = NA_integer_,
      ontology_id = NA_character_,
      ontology_label = NA_character_,
      ontology_iri = NA_character_,
      ontology_short_form = NA_character_,
      ontology_type = NA_character_,
      synonyms = NA_character_,
      definition = NA_character_,
      search_error = error_message,
      stringsAsFactors = FALSE
    )
  }

  resp <- tryCatch(
    httr::GET(
      paste0(sub("/+$", "", ols_base_url), "/search"),
      query = list(q = query, ontology = ontology, rows = rows),
      httr::timeout(60)
    ),
    error = function(e) e
  )
  if (inherits(resp, "error")) return(empty_error_row(conditionMessage(resp)))

  txt <- httr::content(resp, as = "text", encoding = "UTF-8")
  if (httr::status_code(resp) >= 400) {
    return(empty_error_row(paste0("HTTP ", httr::status_code(resp), ": ", txt)))
  }

  payload <- tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE), error = function(e) NULL)
  docs <- payload$response$docs
  if (is.null(docs) || length(docs) == 0) return(data.frame())

  out <- lapply(seq_along(docs), function(i) {
    d <- docs[[i]]
    ontology_name <- phenomap_clean_scalar(d$ontology_name, ontology)
    ontology_id <- phenomap_clean_scalar(d$obo_id)
    if (is.na(ontology_id)) ontology_id <- phenomap_clean_scalar(d$short_form)
    ontology_id <- normalize_ontology_id(ontology_id, ontology_name)

    data.frame(
      ontology = tolower(ontology_name),
      query = query,
      rank = i,
      ontology_id = ontology_id,
      ontology_label = phenomap_clean_scalar(d$label),
      ontology_iri = phenomap_clean_scalar(d$iri),
      ontology_short_form = phenomap_clean_scalar(d$short_form),
      ontology_type = phenomap_clean_scalar(d$type),
      synonyms = phenomap_collapse(clean_vec(d$synonym %||% d$synonyms)),
      definition = phenomap_collapse(clean_vec(d$description)),
      search_error = NA_character_,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, out)
}

search_all_ontologies <- function(candidate_row,
                                  ontology_rows = 10L,
                                  ols_base_url = "https://www.ebi.ac.uk/ols4/api",
                                  sleep_seconds = 0.05) {
  ontologies <- c("mondo", "efo", "mesh", "hp")
  queries <- unique(split_semicolon(candidate_row$query_terms))
  queries <- head(queries, 8L)
  if (length(queries) == 0) return(data.frame())

  rows <- list()
  for (ontology in ontologies) {
    for (query in queries) {
      rows[[length(rows) + 1L]] <- ols_search_one(
        query = query,
        ontology = ontology,
        rows = ontology_rows,
        ols_base_url = ols_base_url
      )
      if (sleep_seconds > 0) Sys.sleep(sleep_seconds)
    }
  }

  rows <- rows[vapply(rows, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))]
  if (length(rows) == 0) return(data.frame())

  out <- do.call(rbind, rows)
  out <- out[!is.na(out$ontology_id) & nzchar(out$ontology_id), , drop = FALSE]
  if (nrow(out) == 0) return(data.frame())

  out$study_id <- candidate_row$study_id
  out$principal_phenotype <- candidate_row$principal_phenotype
  out$phenotype_type <- candidate_row$phenotype_type
  out <- out[
    !duplicated(paste(out$study_id, out$ontology, out$ontology_id, out$ontology_label)),
    ,
    drop = FALSE
  ]
  out
}

add_simple_match_score <- function(candidate_row, ontology_candidates) {
  if (!is.data.frame(ontology_candidates) || nrow(ontology_candidates) == 0) {
    return(ontology_candidates)
  }

  target <- normalize_key(candidate_row$principal_phenotype)
  aliases <- normalize_key(split_semicolon(candidate_row$aliases))
  queries <- normalize_key(split_semicolon(candidate_row$query_terms))
  accepted_terms <- unique(clean_vec(c(target, aliases, queries)))

  scores <- numeric(nrow(ontology_candidates))
  match_types <- character(nrow(ontology_candidates))
  for (i in seq_len(nrow(ontology_candidates))) {
    label <- normalize_key(ontology_candidates$ontology_label[[i]])
    synonyms <- normalize_key(split_semicolon(ontology_candidates$synonyms[[i]]))

    if (!is.na(label) && label == target) {
      scores[[i]] <- 100
      match_types[[i]] <- "exact_label"
    } else if (length(synonyms) > 0 && target %in% synonyms) {
      scores[[i]] <- 95
      match_types[[i]] <- "exact_synonym"
    } else if (!is.na(label) && label %in% accepted_terms) {
      scores[[i]] <- 90
      match_types[[i]] <- "query_or_alias_label"
    } else if (length(synonyms) > 0 && any(synonyms %in% accepted_terms)) {
      scores[[i]] <- 85
      match_types[[i]] <- "query_or_alias_synonym"
    } else if (!is.na(label) && (grepl(target, label, fixed = TRUE) || grepl(label, target, fixed = TRUE))) {
      scores[[i]] <- 70
      match_types[[i]] <- "label_contains"
    } else {
      scores[[i]] <- max(10, 45 - ontology_candidates$rank[[i]])
      match_types[[i]] <- "weak"
    }
    scores[[i]] <- scores[[i]] - min(10, ontology_candidates$rank[[i]] - 1)
  }

  ontology_candidates$rule_score <- round(scores, 2)
  ontology_candidates$rule_match_type <- match_types
  ontology_candidates[order(-ontology_candidates$rule_score, ontology_candidates$rank), , drop = FALSE]
}

summarize_ontology_candidates_by_study <- function(ontology_candidates, max_per_ontology = 10L) {
  if (!is.data.frame(ontology_candidates) || nrow(ontology_candidates) == 0) {
    return(data.frame(study_id = character(0), stringsAsFactors = FALSE))
  }

  ontology_candidates$id_source <- tolower(sub(":.*$", "", ontology_candidates$ontology_id))
  ontology_candidates$id_source <- gsub("[^a-z0-9]+", "_", ontology_candidates$id_source)
  source_order <- c("mondo", "efo", "mesh", "hp", sort(setdiff(unique(ontology_candidates$id_source), c("mondo", "efo", "mesh", "hp"))))
  output_prefix <- ifelse(source_order == "hp", "hpo", source_order)

  ontology_candidates <- ontology_candidates[
    order(ontology_candidates$study_id, ontology_candidates$id_source, -ontology_candidates$rule_score, ontology_candidates$rank),
    ,
    drop = FALSE
  ]

  study_ids <- sort(unique(ontology_candidates$study_id))
  rows <- lapply(study_ids, function(study_id) {
    study_hits <- ontology_candidates[ontology_candidates$study_id == study_id, , drop = FALSE]
    row <- data.frame(study_id = study_id, stringsAsFactors = FALSE)

    for (i in seq_along(source_order)) {
      source <- source_order[[i]]
      prefix <- output_prefix[[i]]
      hits <- study_hits[study_hits$id_source == source, , drop = FALSE]
      if (nrow(hits) > 0) {
        hits <- hits[!duplicated(hits$ontology_id), , drop = FALSE]
        hits <- head(hits, max_per_ontology)
      }

      row[[paste0(prefix, "_ids")]] <- phenomap_collapse(hits$ontology_id)
      row[[paste0(prefix, "_labels")]] <- phenomap_collapse(hits$ontology_label)
      row[[paste0(prefix, "_queries")]] <- phenomap_collapse(hits$query)
      row[[paste0(prefix, "_match_types")]] <- phenomap_collapse(hits$rule_match_type)
      row[[paste0(prefix, "_rule_scores")]] <- phenomap_collapse(hits$rule_score)
    }

    row
  })

  do.call(rbind, rows)
}

ontology_selection_prompt <- function(study_row, candidate_row, ontology_candidates) {
  cand <- ontology_candidates[order(-ontology_candidates$rule_score, ontology_candidates$rank), , drop = FALSE]
  cand <- head(cand, 40L)
  cand$candidate_key <- paste0("C", seq_len(nrow(cand)))
  cand <- cand[, c(
    "candidate_key", "ontology", "ontology_id", "ontology_label",
    "synonyms", "definition", "query", "rank", "rule_score", "rule_match_type"
  ), drop = FALSE]

  cand_text <- paste(utils::capture.output(utils::write.table(
    cand,
    sep = "\t",
    quote = FALSE,
    row.names = FALSE,
    na = ""
  )), collapse = "\n")

  paste(
    "Task:",
    "Select exactly one best ontology term for the principal phenotype, or mark manual_review.",
    "All ontology databases were searched. Choose only from the provided candidate_key values.",
    "Do not invent ontology IDs.",
    "",
    "Selection rules:",
    "- Select a candidate only if it clearly represents the same principal human phenotype.",
    "- Do not select healthy control, cohort, biospecimen, assay, omics, pathway, mechanism, or broad parent terms when a more exact term is needed.",
    "- If multiple candidates are plausible and no single one is clearly best, return decision = manual_review.",
    "- If none of the candidates are appropriate, return decision = no_match.",
    "",
    "Return STRICT JSON only:",
    "{",
    '  "decision": "match | no_match | manual_review",',
    '  "selected_candidate_key": "C1 or null",',
    '  "canonical_label": "final label or null",',
    '  "confidence": "high | medium | low",',
    '  "reason": "short reason"',
    "}",
    "",
    "Study metadata:",
    paste0("- study_id: ", study_row$study_id),
    paste0("- title: ", study_row$study_title),
    paste0("- summary: ", study_row$study_summary),
    paste0("- current phenotype field: ", study_row$current_phenotype),
    paste0("- case label: ", study_row$case_label),
    paste0("- control label: ", study_row$control_label),
    "",
    "Principal phenotype proposed by GPT:",
    paste0("- principal_phenotype: ", candidate_row$principal_phenotype),
    paste0("- phenotype_type: ", candidate_row$phenotype_type),
    paste0("- aliases: ", candidate_row$aliases),
    paste0("- extraction rationale: ", candidate_row$extraction_rationale),
    "",
    "Ontology candidates:",
    cand_text,
    sep = "\n"
  )
}

select_best_ontology <- function(study_row,
                                 candidate_row,
                                 ontology_candidates,
                                 api_key = Sys.getenv("OPENAI_API_KEY"),
                                 model = "gpt-4.1-mini",
                                 base_url = "https://api.openai.com/v1") {
  empty <- data.frame(
    study_id = candidate_row$study_id,
    decision = "no_match",
    selected = FALSE,
    selected_candidate_key = NA_character_,
    final_label = NA_character_,
    final_phenotype_type = candidate_row$phenotype_type,
    final_ontology = NA_character_,
    final_ontology_id = NA_character_,
    final_ontology_iri = NA_character_,
    final_ontology_definition = NA_character_,
    selection_confidence = "low",
    manual_review = TRUE,
    review_reason = "No ontology candidates returned from MONDO, EFO, MeSH, or HPO.",
    selection_prompt = NA_character_,
    selection_raw_response = NA_character_,
    selection_error = NA_character_,
    stringsAsFactors = FALSE
  )

  if (!is.data.frame(ontology_candidates) || nrow(ontology_candidates) == 0) {
    return(empty)
  }

  ontology_candidates <- ontology_candidates[order(-ontology_candidates$rule_score, ontology_candidates$rank), , drop = FALSE]
  ontology_candidates <- head(ontology_candidates, 40L)
  ontology_candidates$candidate_key <- paste0("C", seq_len(nrow(ontology_candidates)))

  prompt <- ontology_selection_prompt(study_row, candidate_row, ontology_candidates)
  parsed <- NULL
  error <- NA_character_
  parsed <- tryCatch(
    call_gpt_json(
      prompt = prompt,
      api_key = api_key,
      model = model,
      base_url = base_url,
      task = "ontology best-match selection"
    ),
    error = function(e) {
      error <<- conditionMessage(e)
      NULL
    }
  )

  decision <- tolower(phenomap_clean_scalar(parsed$decision, "manual_review"))
  selected_key <- phenomap_clean_scalar(parsed$selected_candidate_key)
  confidence <- tolower(phenomap_clean_scalar(parsed$confidence, "low"))
  if (!decision %in% c("match", "no_match", "manual_review")) decision <- "manual_review"

  if (decision != "match" || is.na(selected_key) || !selected_key %in% ontology_candidates$candidate_key) {
    empty$decision <- decision
    empty$review_reason <- phenomap_clean_scalar(
      parsed$reason,
      ifelse(decision == "no_match", "GPT found no appropriate ontology match.", "GPT could not select one clear best ontology match.")
    )
    empty$selection_prompt <- prompt
    empty$selection_raw_response <- phenomap_clean_scalar(parsed$raw_response)
    empty$selection_error <- error
    empty$selection_confidence <- confidence
    return(empty)
  }

  hit <- ontology_candidates[ontology_candidates$candidate_key == selected_key, , drop = FALSE]
  data.frame(
    study_id = candidate_row$study_id,
    decision = decision,
    selected = TRUE,
    selected_candidate_key = selected_key,
    final_label = phenomap_clean_scalar(parsed$canonical_label, hit$ontology_label[[1]]),
    final_phenotype_type = candidate_row$phenotype_type,
    final_ontology = hit$ontology[[1]],
    final_ontology_id = hit$ontology_id[[1]],
    final_ontology_iri = hit$ontology_iri[[1]],
    final_ontology_definition = hit$definition[[1]],
    selection_confidence = confidence,
    manual_review = confidence != "high" || isTRUE(candidate_row$extraction_manual_review),
    review_reason = if (confidence == "high" && !isTRUE(candidate_row$extraction_manual_review)) {
      NA_character_
    } else {
      phenomap_clean_scalar(parsed$reason, "Selected match requires review because extraction or selection was not high-confidence.")
    },
    selection_prompt = prompt,
    selection_raw_response = phenomap_clean_scalar(parsed$raw_response),
    selection_error = error,
    stringsAsFactors = FALSE
  )
}

normalize_workbench_phenotypes <- function(case_root = file.path("2_data", "raw", "workbench_20260629", "out_qwen_eval_mw_anno"),
                                           output_dir = file.path("2_data", "raw", "workbench_20260629", "phenotype_normalization"),
                                           api_key = Sys.getenv("OPENAI_API_KEY"),
                                           model = "gpt-4.1-mini",
                                           base_url = "https://api.openai.com/v1",
                                           ols_base_url = "https://www.ebi.ac.uk/ols4/api",
                                           ontology_rows = 10L,
                                           limit = NA_integer_,
                                           sleep_seconds = 0.05) {
  case_dirs <- phenomap_case_dirs(case_root, require_meta = TRUE)
  if (!is.na(limit) && limit > 0L) case_dirs <- head(case_dirs, limit)

  meta_rows <- lapply(case_dirs, read_workbench_meta_row)
  meta_rows <- meta_rows[!vapply(meta_rows, is.null, logical(1))]
  studies <- do.call(rbind, meta_rows)
  studies <- studies[order(studies$study_id), , drop = FALSE]

  message("Extracting principal phenotypes for ", nrow(studies), " Workbench cases.")
  candidate_rows <- lapply(seq_len(nrow(studies)), function(i) {
    message("GPT phenotype extraction: ", studies$study_id[[i]])
    extract_principal_phenotype(
      row = studies[i, , drop = FALSE],
      api_key = api_key,
      model = model,
      base_url = base_url
    )
  })
  candidates <- do.call(rbind, candidate_rows)

  message("Searching MONDO, EFO, MeSH, and HPO for every candidate.")
  ontology_rows_list <- lapply(seq_len(nrow(candidates)), function(i) {
    message("OLS search: ", candidates$study_id[[i]], " / ", candidates$principal_phenotype[[i]])
    found <- search_all_ontologies(
      candidate_row = candidates[i, , drop = FALSE],
      ontology_rows = ontology_rows,
      ols_base_url = ols_base_url,
      sleep_seconds = sleep_seconds
    )
    if (nrow(found) == 0) return(data.frame())
    add_simple_match_score(candidates[i, , drop = FALSE], found)
  })
  ontology_candidates <- ontology_rows_list[
    vapply(ontology_rows_list, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))
  ]
  ontology_candidates <- if (length(ontology_candidates) > 0) {
    do.call(rbind, ontology_candidates)
  } else {
    data.frame()
  }

  message("Selecting one best ontology match or routing to manual review.")
  selection_rows <- lapply(seq_len(nrow(candidates)), function(i) {
    study_id <- candidates$study_id[[i]]
    found <- if (nrow(ontology_candidates) > 0) {
      ontology_candidates[ontology_candidates$study_id == study_id, , drop = FALSE]
    } else {
      data.frame()
    }
    message("GPT ontology selection: ", study_id)
    select_best_ontology(
      study_row = studies[studies$study_id == study_id, , drop = FALSE],
      candidate_row = candidates[i, , drop = FALSE],
      ontology_candidates = found,
      api_key = api_key,
      model = model,
      base_url = base_url
    )
  })
  selections <- do.call(rbind, selection_rows)
  ontology_summary <- summarize_ontology_candidates_by_study(ontology_candidates)
  selections <- merge(selections, ontology_summary, by = "study_id", all.x = TRUE, sort = FALSE)

  final <- merge(studies, candidates, by = "study_id", all.x = TRUE, sort = FALSE)
  final <- merge(final, selections, by = "study_id", all.x = TRUE, sort = FALSE)
  selected_ok <- !is.na(final$selected) & final$selected
  review_needed <- is.na(final$manual_review) | final$manual_review
  final$normalization_status <- ifelse(selected_ok & !review_needed, "auto_selected", "manual_review")

  review <- final[final$normalization_status == "manual_review", , drop = FALSE]

  phenomap_write_csv(studies, file.path(output_dir, "workbench_study_meta_index.csv"))
  phenomap_write_csv(candidates, file.path(output_dir, "phenotype_principal_candidates.csv"))
  phenomap_write_csv(ontology_candidates, file.path(output_dir, "phenotype_ols_candidates.csv"))
  phenomap_write_csv(selections, file.path(output_dir, "phenotype_final_selection.csv"))
  phenomap_write_csv(review, file.path(output_dir, "phenotype_manual_review.csv"))
  phenomap_write_csv(final, file.path(output_dir, "phenotype_normalization_all.csv"))

  invisible(list(
    studies = studies,
    phenotype_principal_candidates = candidates,
    phenotype_ols_candidates = ontology_candidates,
    phenotype_ontology_summary = ontology_summary,
    phenotype_final_selection = selections,
    phenotype_manual_review = review,
    phenotype_normalization_all = final
  ))
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- parse_workbench_pheno_args()
  normalize_workbench_phenotypes(
    case_root = args$case_root,
    output_dir = args$output_dir,
    model = args$model,
    base_url = args$base_url,
    ols_base_url = args$ols_base_url,
    ontology_rows = args$ontology_rows,
    limit = args$limit,
    sleep_seconds = args$sleep_seconds
  )
}
