# Normalize PhenoMAP phenotype concepts from study-level phenotype metadata.
#
# Inputs:
#   2_data/tidy_entity/nodes_study.csv
#
# Outputs:
#   nodes_phenotype.csv
#   edges_study_phenotype.csv
#   phenotype_candidates.csv
#   phenotype_ontology_candidates.csv
#   phenotype_normalization_review.csv
#
# Usage:
#   Rscript 1_code/1_tidy_entity/05_normalize_phenotype_entity.R
#   Rscript 1_code/1_tidy_entity/05_normalize_phenotype_entity.R --use_llm=FALSE

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

phenotype_norm_parse_args <- function() {
  args <- phenomap_parse_args()
  raw <- commandArgs(trailingOnly = TRUE)
  args$input_study <- file.path(args$output_dir, "nodes_study.csv")
  args$ontology_rows <- 5L
  args$ols_base_url <- "https://www.ebi.ac.uk/ols4/api"

  for (arg in raw) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% names(args)) args[[key]] <- value
  }
  args$ontology_rows <- suppressWarnings(as.integer(args$ontology_rows))
  if (is.na(args$ontology_rows) || args$ontology_rows < 1L) args$ontology_rows <- 5L
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

normalize_spaces <- function(x) {
  x <- tolower(trimws(as.character(x)))
  gsub("[[:space:]]+", " ", x)
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

normalize_phenotype_type <- function(x) {
  x <- tolower(phenomap_clean_scalar(x, "unclear"))
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  allowed <- c(
    "disease", "severity", "exposure", "treatment", "trait",
    "cell_model", "method_sample_context", "unclear"
  )
  if (x %in% allowed) x else "unclear"
}

normalize_phenotype_scope <- function(x) {
  x <- tolower(phenomap_clean_scalar(x, "unclear"))
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  allowed <- c("human", "cell_model", "method", "mixed", "unclear")
  if (x %in% allowed) x else "unclear"
}

preferred_ontologies <- function(phenotype_type) {
  phenotype_type <- normalize_phenotype_type(phenotype_type)
  switch(
    phenotype_type,
    disease = c("mondo", "efo", "mesh"),
    severity = c("hp", "efo", "mesh"),
    exposure = c("efo", "mesh"),
    treatment = c("efo", "mesh"),
    trait = c("efo", "hp", "mesh"),
    cell_model = c("efo", "mesh"),
    method_sample_context = c("efo", "mesh"),
    c("mondo", "efo", "hp", "mesh")
  )
}

candidate_extraction_prompt <- function(row) {
  paste(
    "You are curating phenotype candidates for a metabolomics knowledge graph named PhenoMAP.",
    "",
    "Task:",
    "Extract a deduplication-ready phenotype candidate from the study metadata.",
    "Do not output an X versus Y comparison.",
    "Name the case/perturbation/exposure/disease/state itself.",
    "Do not name downstream mechanisms, metabolic responses, biomarkers, or pathway interpretations.",
    "",
    "Allowed phenotype_type values:",
    "disease | severity | exposure | treatment | trait | cell_model | method_sample_context | unclear",
    "",
    "Return STRICT JSON only:",
    "{",
    '  "candidate_name": "deduplication-ready phenotype phrase",',
    '  "phenotype_type": "disease | severity | exposure | treatment | trait | cell_model | method_sample_context | unclear",',
    '  "phenotype_scope": "human | cell_model | method | mixed | unclear",',
    '  "aliases": ["alias 1", "alias 2"],',
    '  "ontology_queries": {',
    '    "mondo": ["query"],',
    '    "efo": ["query"],',
    '    "hp": ["query"],',
    '    "mesh": ["query"]',
    "  },",
    '  "confidence": "high | medium | low",',
    '  "rationale": "short reason"',
    "}",
    "",
    "Study metadata:",
    paste0("- study_id: ", phenomap_clean_scalar(row$study_id)),
    paste0("- title: ", phenomap_clean_scalar(row$title)),
    paste0("- description: ", phenomap_clean_scalar(row$description)),
    paste0("- study_focus_raw: ", phenomap_clean_scalar(row$study_focus_raw)),
    paste0("- previous phenotype candidate: ", phenomap_clean_scalar(row$phenotype_name_normalized %||% row$phenotype)),
    paste0("- previous phenotype_type: ", phenomap_clean_scalar(row$phenotype_type)),
    paste0("- study_design: ", phenomap_clean_scalar(row$study_design)),
    paste0("- study_design_detail: ", phenomap_clean_scalar(row$study_design_detail)),
    paste0("- case_label: ", phenomap_clean_scalar(row$case_label)),
    paste0("- control_label: ", phenomap_clean_scalar(row$control_label)),
    paste0("- biospecimen: ", phenomap_clean_scalar(row$biospecimen)),
    paste0("- biospecimen_detail: ", phenomap_clean_scalar(row$biospecimen_detail)),
    sep = "\n"
  )
}

call_llm_json <- function(prompt,
                          api_key = Sys.getenv("OPENAI_API_KEY"),
                          model = "gpt-4.1-mini",
                          base_url = "https://api.openai.com/v1",
                          task = "LLM request") {
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required.")
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.")
  if (is.na(api_key) || !nzchar(api_key)) stop("API key is empty. Set OPENAI_API_KEY.")

  endpoint <- sub("/+$", "", base_url)
  if (!grepl("/chat/completions$", endpoint)) endpoint <- paste0(endpoint, "/chat/completions")

  body <- list(
    model = model,
    messages = list(
      list(role = "system", content = "You are a careful biomedical ontology curator. Return only valid JSON."),
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

fallback_candidate_from_study <- function(row) {
  name <- phenomap_clean_scalar(row$phenotype_name_normalized %||% row$phenotype)
  if (is.na(name)) name <- phenomap_clean_scalar(row$study_focus_raw)
  if (is.na(name)) name <- phenomap_clean_scalar(row$existing_phenotype)
  if (!is.na(name)) {
    name <- gsub("\\s+versus\\s+.*$", "", name, ignore.case = TRUE)
    name <- gsub("\\s+vs\\.?\\s+.*$", "", name, ignore.case = TRUE)
    name <- trimws(name)
  }
  ptype <- normalize_phenotype_type(row$phenotype_type)
  scope <- normalize_phenotype_scope(row$phenotype_scope)
  list(
    candidate_name = name,
    phenotype_type = ptype,
    phenotype_scope = scope,
    aliases = clean_vec(c(row$study_focus_raw, row$phenotype, row$existing_phenotype)),
    ontology_queries = list(
      mondo = name,
      efo = name,
      hp = name,
      mesh = name
    ),
    confidence = "low",
    rationale = "Fallback from nodes_study.csv without LLM candidate extraction.",
    raw_response = NA_character_
  )
}

extract_phenotype_candidate <- function(row,
                                        use_llm = TRUE,
                                        api_key = Sys.getenv("OPENAI_API_KEY"),
                                        model = "gpt-4.1-mini",
                                        base_url = "https://api.openai.com/v1") {
  prompt <- candidate_extraction_prompt(row)
  parsed <- NULL
  error <- NA_character_

  if (isTRUE(use_llm)) {
    parsed <- tryCatch(
      call_llm_json(prompt, api_key = api_key, model = model, base_url = base_url,
                    task = "phenotype candidate extraction"),
      error = function(e) {
        error <<- conditionMessage(e)
        NULL
      }
    )
  }

  if (is.null(parsed)) parsed <- fallback_candidate_from_study(row)

  aliases <- unique(clean_vec(c(parsed$aliases, row$study_focus_raw, row$phenotype, row$existing_phenotype)))
  candidate_name <- phenomap_clean_scalar(parsed$candidate_name)
  if (is.na(candidate_name)) candidate_name <- fallback_candidate_from_study(row)$candidate_name
  phenotype_type <- normalize_phenotype_type(parsed$phenotype_type)
  phenotype_scope <- normalize_phenotype_scope(parsed$phenotype_scope)

  queries <- parsed$ontology_queries
  if (is.null(queries) || !is.list(queries)) queries <- list()
  for (ont in c("mondo", "efo", "hp", "mesh")) {
    if (is.null(queries[[ont]])) queries[[ont]] <- candidate_name
    queries[[ont]] <- unique(clean_vec(c(queries[[ont]], candidate_name, aliases)))
  }

  data.frame(
    study_id = phenomap_clean_scalar(row$study_id),
    study_focus_raw = phenomap_clean_scalar(row$study_focus_raw),
    previous_phenotype = phenomap_clean_scalar(row$phenotype),
    existing_phenotype = phenomap_clean_scalar(row$existing_phenotype),
    candidate_name = candidate_name,
    phenotype_type = phenotype_type,
    phenotype_scope = phenotype_scope,
    aliases = phenomap_collapse(aliases),
    ontology_queries_json = json_or_na(queries),
    extraction_confidence = phenomap_clean_scalar(parsed$confidence),
    extraction_rationale = phenomap_clean_scalar(parsed$rationale),
    extraction_prompt = prompt,
    extraction_raw_response = phenomap_clean_scalar(parsed$raw_response),
    extraction_error = error,
    stringsAsFactors = FALSE
  )
}

ols_search_one <- function(query,
                           ontology,
                           rows = 5L,
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

  url <- paste0(sub("/+$", "", ols_base_url), "/search")
  resp <- tryCatch(
    httr::GET(
      url,
      query = list(q = query, ontology = ontology, rows = rows),
      httr::timeout(60)
    ),
    error = function(e) e
  )
  if (inherits(resp, "error")) {
    return(empty_error_row(conditionMessage(resp)))
  }
  txt <- httr::content(resp, as = "text", encoding = "UTF-8")
  if (httr::status_code(resp) >= 400) {
    return(empty_error_row(paste0("HTTP ", httr::status_code(resp), ": ", txt)))
  }

  payload <- tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE), error = function(e) NULL)
  docs <- payload$response$docs
  if (is.null(docs) || length(docs) == 0) return(data.frame())

  rows_out <- lapply(seq_along(docs), function(i) {
    d <- docs[[i]]
    ontology_name <- phenomap_clean_scalar(d$ontology_name, ontology)
    ontology_id <- phenomap_clean_scalar(d$obo_id)
    if (is.na(ontology_id)) ontology_id <- phenomap_clean_scalar(d$short_form)
    ontology_id <- normalize_ontology_id(ontology_id, ontology_name)
    synonyms <- clean_vec(d$synonym %||% d$synonyms)
    description <- clean_vec(d$description)
    data.frame(
      ontology = tolower(ontology_name),
      query = query,
      rank = i,
      ontology_id = ontology_id,
      ontology_label = phenomap_clean_scalar(d$label),
      ontology_iri = phenomap_clean_scalar(d$iri),
      ontology_short_form = phenomap_clean_scalar(d$short_form),
      ontology_type = phenomap_clean_scalar(d$type),
      synonyms = phenomap_collapse(synonyms),
      definition = phenomap_collapse(description),
      search_error = NA_character_,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows_out)
}

expand_ontology_queries <- function(queries) {
  queries <- unique(clean_vec(queries))
  if (length(queries) == 0) return(character(0))

  expanded <- queries
  for (query in queries) {
    q <- trimws(query)
    q_lower <- tolower(q)

    if (grepl(" cancer metastasis$", q_lower)) {
      base <- sub("(?i)\\s+cancer metastasis$", " cancer", q, perl = TRUE)
      expanded <- c(expanded, base)
      expanded <- c(expanded, sub("(?i)^(.+?)\\s+cancer metastasis$", "metastatic \\1 cancer", q, perl = TRUE))
    }
    if (grepl(" carcinoma metastasis$", q_lower)) {
      base <- sub("(?i)\\s+carcinoma metastasis$", " carcinoma", q, perl = TRUE)
      expanded <- c(expanded, base)
      expanded <- c(expanded, sub("(?i)^(.+?)\\s+carcinoma metastasis$", "metastatic \\1 carcinoma", q, perl = TRUE))
    }
    if (grepl(" metastasis$", q_lower)) {
      expanded <- c(expanded, sub("(?i)\\s+metastasis$", "", q, perl = TRUE))
      expanded <- c(expanded, sub("(?i)^(.+?)\\s+metastasis$", "metastatic \\1", q, perl = TRUE))
    }
    if (grepl(" metastatic disease$", q_lower)) {
      expanded <- c(expanded, sub("(?i)\\s+metastatic disease$", "", q, perl = TRUE))
      expanded <- c(expanded, sub("(?i)^(.+?)\\s+metastatic disease$", "metastatic \\1", q, perl = TRUE))
    }
    if (grepl("-induced ", q_lower)) {
      expanded <- c(expanded, sub("(?i)^(.+)-induced\\s+", "", q, perl = TRUE))
    }
    if (grepl("\\s+in\\s+", q_lower)) {
      expanded <- c(expanded, sub("(?i)\\s+in\\s+.+$", "", q, perl = TRUE))
    }
    if (grepl("\\s+with\\s+", q_lower)) {
      expanded <- c(expanded, sub("(?i)\\s+with\\s+.+$", "", q, perl = TRUE))
    }
  }

  unique(clean_vec(expanded))
}

parse_queries_json <- function(x, candidate_name) {
  parsed <- tryCatch(jsonlite::fromJSON(x, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(parsed) || !is.list(parsed)) parsed <- list()
  for (ont in c("mondo", "efo", "hp", "mesh")) {
    parsed[[ont]] <- expand_ontology_queries(c(parsed[[ont]], candidate_name))
  }
  parsed
}

search_ontology_candidates <- function(candidate_row,
                                       ontology_rows = 5L,
                                       ols_base_url = "https://www.ebi.ac.uk/ols4/api") {
  ptype <- normalize_phenotype_type(candidate_row$phenotype_type)
  ontologies <- preferred_ontologies(ptype)
  queries <- parse_queries_json(candidate_row$ontology_queries_json, candidate_row$candidate_name)

  rows <- list()
  for (ont in ontologies) {
    for (query in head(queries[[ont]], 8L)) {
      rows[[length(rows) + 1L]] <- ols_search_one(
        query = query,
        ontology = ont,
        rows = ontology_rows,
        ols_base_url = ols_base_url
      )
      Sys.sleep(0.05)
    }
  }
  rows <- rows[vapply(rows, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))]
  if (length(rows) == 0) return(data.frame())
  out <- do.call(rbind, rows)
  out <- out[!is.na(out$ontology_id) & nzchar(out$ontology_id), , drop = FALSE]
  if (nrow(out) == 0) return(data.frame())
  out$study_id <- candidate_row$study_id
  out$candidate_name <- candidate_row$candidate_name
  out$phenotype_type <- ptype
  out <- out[!duplicated(paste(out$study_id, out$ontology, out$ontology_id, out$ontology_label)), , drop = FALSE]
  out
}

score_ontology_candidates <- function(candidate_row, ontology_candidates) {
  if (!is.data.frame(ontology_candidates) || nrow(ontology_candidates) == 0) {
    return(ontology_candidates)
  }
  name_key <- normalize_spaces(candidate_row$candidate_name)
  alias_keys <- normalize_spaces(clean_vec(strsplit(candidate_row$aliases, ";", fixed = TRUE)[[1]]))
  pref <- preferred_ontologies(candidate_row$phenotype_type)

  scores <- numeric(nrow(ontology_candidates))
  match_types <- character(nrow(ontology_candidates))
  for (i in seq_len(nrow(ontology_candidates))) {
    label_key <- normalize_spaces(ontology_candidates$ontology_label[[i]])
    syn <- clean_vec(strsplit(ontology_candidates$synonyms[[i]], ";", fixed = TRUE)[[1]])
    syn_keys <- normalize_spaces(syn)
    score <- 0
    match_type <- "weak"

    if (!is.na(label_key) && identical(label_key, name_key)) {
      score <- 100
      match_type <- "exact_label"
    } else if (length(syn_keys) > 0 && name_key %in% syn_keys) {
      score <- 92
      match_type <- "exact_synonym"
    } else if (length(alias_keys) > 0 && label_key %in% alias_keys) {
      score <- 88
      match_type <- "alias_label"
    } else if (!is.na(label_key) && (grepl(name_key, label_key, fixed = TRUE) ||
                                     grepl(label_key, name_key, fixed = TRUE))) {
      score <- 72
      match_type <- "label_contains"
    } else if (length(syn_keys) > 0 && any(syn_keys %in% alias_keys)) {
      score <- 70
      match_type <- "alias_synonym"
    } else {
      score <- max(10, 45 - ontology_candidates$rank[[i]])
    }

    ontology_rank <- match(tolower(ontology_candidates$ontology[[i]]), pref)
    if (!is.na(ontology_rank)) score <- score + max(0, 8 - 2 * (ontology_rank - 1))
    score <- score - min(10, ontology_candidates$rank[[i]] - 1)

    scores[[i]] <- score
    match_types[[i]] <- match_type
  }

  ontology_candidates$rule_score <- round(scores, 2)
  ontology_candidates$rule_match_type <- match_types
  ontology_candidates[order(-ontology_candidates$rule_score, ontology_candidates$rank), , drop = FALSE]
}

ontology_judge_prompt <- function(candidate_row, ontology_candidates) {
  cand_cols <- c(
    "candidate_key", "ontology", "ontology_id", "ontology_label",
    "synonyms", "definition", "rule_score", "rule_match_type"
  )
  cand <- ontology_candidates
  cand$candidate_key <- paste0("C", seq_len(nrow(cand)))
  cand <- cand[, cand_cols, drop = FALSE]
  cand_text <- paste(utils::capture.output(utils::write.table(
    cand,
    sep = "\t",
    quote = FALSE,
    row.names = FALSE,
    na = ""
  )), collapse = "\n")

  paste(
    "You are selecting a real ontology term for PhenoMAP phenotype normalization.",
    "",
    "Task:",
    "Choose the best ontology candidate for the phenotype candidate, or no_match.",
    "Choose only from the provided candidate_key values. Do not invent ontology IDs.",
    "Prefer a precise term matching the candidate concept and phenotype_type.",
    "Do not select a downstream mechanism/pathway term when the study phenotype is a disease, treatment, exposure, trait, or cell perturbation.",
    "",
    "Return STRICT JSON only:",
    "{",
    '  "decision": "match | no_match | unclear",',
    '  "selected_candidate_key": "C1 or null",',
    '  "confidence": "high | medium | low",',
    '  "canonical_name": "preferred canonical name",',
    '  "reason": "short reason"',
    "}",
    "",
    "Phenotype candidate:",
    paste0("- study_id: ", candidate_row$study_id),
    paste0("- candidate_name: ", candidate_row$candidate_name),
    paste0("- phenotype_type: ", candidate_row$phenotype_type),
    paste0("- phenotype_scope: ", candidate_row$phenotype_scope),
    paste0("- aliases: ", candidate_row$aliases),
    "",
    "Ontology candidates:",
    cand_text,
    sep = "\n"
  )
}

select_best_ontology <- function(candidate_row,
                                 ontology_candidates,
                                 use_llm = TRUE,
                                 api_key = Sys.getenv("OPENAI_API_KEY"),
                                 model = "gpt-4.1-mini",
                                 base_url = "https://api.openai.com/v1") {
  empty <- data.frame(
    study_id = candidate_row$study_id,
    selected = FALSE,
    selected_candidate_key = NA_character_,
    preferred_ontology = NA_character_,
    ontology_id = NA_character_,
    ontology_label = NA_character_,
    ontology_iri = NA_character_,
    ontology_definition = NA_character_,
    ontology_match_confidence = "low",
    ontology_match_method = "no_candidate",
    ontology_match_reason = NA_character_,
    ontology_judge_prompt = NA_character_,
    ontology_judge_raw_response = NA_character_,
    ontology_judge_error = NA_character_,
    stringsAsFactors = FALSE
  )

  if (!is.data.frame(ontology_candidates) || nrow(ontology_candidates) == 0) {
    return(empty)
  }

  ontology_candidates <- ontology_candidates[order(-ontology_candidates$rule_score, ontology_candidates$rank), , drop = FALSE]
  ontology_candidates <- head(ontology_candidates, 15L)
  ontology_candidates$candidate_key <- paste0("C", seq_len(nrow(ontology_candidates)))

  prompt <- ontology_judge_prompt(candidate_row, ontology_candidates)
  parsed <- NULL
  judge_error <- NA_character_
  if (isTRUE(use_llm)) {
    parsed <- tryCatch(
      call_llm_json(prompt, api_key = api_key, model = model, base_url = base_url,
                    task = "ontology candidate judge"),
      error = function(e) {
        judge_error <<- conditionMessage(e)
        NULL
      }
    )
  }

  selected_key <- phenomap_clean_scalar(parsed$selected_candidate_key)
  decision <- tolower(phenomap_clean_scalar(parsed$decision, ""))
  confidence <- tolower(phenomap_clean_scalar(parsed$confidence, "low"))

  if (is.null(parsed) || is.na(selected_key) || !selected_key %in% ontology_candidates$candidate_key ||
      !decision %in% c("match", "unclear")) {
    top <- ontology_candidates[1, , drop = FALSE]
    if (!is.na(top$rule_score[[1]]) && top$rule_score[[1]] >= 92) {
      selected_key <- top$candidate_key[[1]]
      decision <- "match"
      confidence <- "high"
      parsed <- list(
        canonical_name = top$ontology_label[[1]],
        reason = paste0("Rule-selected ", top$rule_match_type[[1]], " with score ", top$rule_score[[1]], "."),
        raw_response = NA_character_
      )
    } else if (!is.na(top$rule_score[[1]]) && top$rule_score[[1]] >= 78) {
      selected_key <- top$candidate_key[[1]]
      decision <- "unclear"
      confidence <- "medium"
      parsed <- list(
        canonical_name = top$ontology_label[[1]],
        reason = paste0("Rule-selected medium-confidence candidate with score ", top$rule_score[[1]], "."),
        raw_response = NA_character_
      )
    } else {
      empty$ontology_match_method <- if (isTRUE(use_llm)) "llm_no_match" else "rule_no_match"
      empty$ontology_judge_prompt <- prompt
      empty$ontology_judge_raw_response <- phenomap_clean_scalar(parsed$raw_response)
      empty$ontology_judge_error <- judge_error
      empty$ontology_match_reason <- phenomap_clean_scalar(parsed$reason)
      return(empty)
    }
  }

  hit <- ontology_candidates[ontology_candidates$candidate_key == selected_key, , drop = FALSE]
  data.frame(
    study_id = candidate_row$study_id,
    selected = TRUE,
    selected_candidate_key = selected_key,
    preferred_ontology = hit$ontology[[1]],
    ontology_id = hit$ontology_id[[1]],
    ontology_label = hit$ontology_label[[1]],
    ontology_iri = hit$ontology_iri[[1]],
    ontology_definition = hit$definition[[1]],
    ontology_match_confidence = confidence,
    ontology_match_method = if (isTRUE(use_llm) && !is.na(phenomap_clean_scalar(parsed$raw_response))) "llm_selected" else "rule_selected",
    ontology_match_reason = phenomap_clean_scalar(parsed$reason),
    ontology_judge_prompt = prompt,
    ontology_judge_raw_response = phenomap_clean_scalar(parsed$raw_response),
    ontology_judge_error = judge_error,
    stringsAsFactors = FALSE
  )
}

make_local_merge_key <- function(candidate_name, phenotype_type) {
  slug <- phenomap_normalize_text_id(candidate_name)
  if (is.na(slug)) slug <- "unclear"
  paste0("LOCAL:", normalize_phenotype_type(phenotype_type), ":", slug)
}

assign_phenomap_ids <- function(concepts) {
  concepts <- concepts[order(tolower(concepts$canonical_name), concepts$merge_key), , drop = FALSE]
  concepts$phenomap_phenotype_id <- sprintf("PMAP_PHENO_%04d", seq_len(nrow(concepts)))
  concepts[, c("phenomap_phenotype_id", setdiff(colnames(concepts), "phenomap_phenotype_id")), drop = FALSE]
}

build_normalized_phenotype_entity <- function(input_study = file.path("2_data", "tidy_entity", "nodes_study.csv"),
                                              output_dir = file.path("2_data", "tidy_entity"),
                                              use_llm = TRUE,
                                              api_key = Sys.getenv("OPENAI_API_KEY"),
                                              model = "gpt-4.1-mini",
                                              base_url = "https://api.openai.com/v1",
                                              ontology_rows = 5L,
                                              ols_base_url = "https://www.ebi.ac.uk/ols4/api") {
  if (!file.exists(input_study)) stop("input_study does not exist: ", input_study)
  studies <- utils::read.csv(input_study, stringsAsFactors = FALSE, check.names = FALSE)
  if (!"study_id" %in% colnames(studies)) stop("input_study must contain study_id.")

  message("Extracting phenotype candidates from ", nrow(studies), " studies.")
  candidate_rows <- lapply(seq_len(nrow(studies)), function(i) {
    message("Extracting phenotype candidate for ", studies$study_id[[i]])
    extract_phenotype_candidate(
      row = studies[i, , drop = FALSE],
      use_llm = use_llm,
      api_key = api_key,
      model = model,
      base_url = base_url
    )
  })
  candidates <- do.call(rbind, candidate_rows)

  message("Searching ontology candidates.")
  ontology_rows_list <- lapply(seq_len(nrow(candidates)), function(i) {
    message("Ontology search for ", candidates$study_id[[i]], ": ", candidates$candidate_name[[i]])
    oc <- search_ontology_candidates(
      candidate_row = candidates[i, , drop = FALSE],
      ontology_rows = ontology_rows,
      ols_base_url = ols_base_url
    )
    if (nrow(oc) == 0) return(data.frame())
    score_ontology_candidates(candidates[i, , drop = FALSE], oc)
  })
  ontology_candidates <- ontology_rows_list[
    vapply(ontology_rows_list, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))
  ]
  ontology_candidates <- if (length(ontology_candidates) > 0) {
    do.call(rbind, ontology_candidates)
  } else {
    data.frame()
  }

  message("Selecting best ontology candidates.")
  selected_rows <- lapply(seq_len(nrow(candidates)), function(i) {
    study_id <- candidates$study_id[[i]]
    oc <- if (nrow(ontology_candidates) > 0) {
      ontology_candidates[ontology_candidates$study_id == study_id, , drop = FALSE]
    } else {
      data.frame()
    }
    select_best_ontology(
      candidate_row = candidates[i, , drop = FALSE],
      ontology_candidates = oc,
      use_llm = use_llm,
      api_key = api_key,
      model = model,
      base_url = base_url
    )
  })
  selected <- do.call(rbind, selected_rows)

  candidate_selected <- merge(candidates, selected, by = "study_id", all.x = TRUE, sort = FALSE)
  candidate_selected$merge_key <- ifelse(
    !is.na(candidate_selected$ontology_id) & nzchar(candidate_selected$ontology_id),
    paste0("ONTOLOGY:", candidate_selected$ontology_id),
    mapply(make_local_merge_key, candidate_selected$candidate_name, candidate_selected$phenotype_type)
  )
  candidate_selected$canonical_name_for_merge <- ifelse(
    !is.na(candidate_selected$ontology_label) & nzchar(candidate_selected$ontology_label),
    candidate_selected$ontology_label,
    candidate_selected$candidate_name
  )

  split_by_key <- split(candidate_selected, candidate_selected$merge_key)
  concept_rows <- lapply(split_by_key, function(df) {
    canonical_names <- clean_vec(df$canonical_name_for_merge)
    canonical_name <- if (length(canonical_names) > 0) {
      names(sort(table(canonical_names), decreasing = TRUE))[[1]]
    } else {
      NA_character_
    }
    phenotype_types <- clean_vec(df$phenotype_type)
    phenotype_type <- if (length(phenotype_types) > 0) {
      names(sort(table(phenotype_types), decreasing = TRUE))[[1]]
    } else {
      "unclear"
    }
    alias_parts <- unlist(strsplit(phenomap_collapse(df$aliases), ";", fixed = TRUE), use.names = FALSE)
    aliases <- unique(clean_vec(c(alias_parts, df$candidate_name, df$study_focus_raw)))
    ontology_hit <- df[!is.na(df$ontology_id) & nzchar(df$ontology_id), , drop = FALSE]
    ontology_hit <- if (nrow(ontology_hit) > 0) ontology_hit[1, , drop = FALSE] else NULL

    data.frame(
      merge_key = df$merge_key[[1]],
      canonical_name = canonical_name,
      phenotype_type = phenotype_type,
      phenotype_scope = phenomap_collapse(unique(clean_vec(df$phenotype_scope))),
      preferred_ontology = if (!is.null(ontology_hit)) ontology_hit$preferred_ontology[[1]] else NA_character_,
      ontology_id = if (!is.null(ontology_hit)) ontology_hit$ontology_id[[1]] else NA_character_,
      ontology_label = if (!is.null(ontology_hit)) ontology_hit$ontology_label[[1]] else NA_character_,
      ontology_iri = if (!is.null(ontology_hit)) ontology_hit$ontology_iri[[1]] else NA_character_,
      ontology_definition = if (!is.null(ontology_hit)) ontology_hit$ontology_definition[[1]] else NA_character_,
      aliases = phenomap_collapse(aliases),
      n_studies = length(unique(df$study_id)),
      source_study_ids = phenomap_collapse(unique(df$study_id)),
      merge_rule = if (!is.null(ontology_hit)) "same_best_ontology_id" else "same_local_type_name",
      review_status = if (any(df$ontology_match_confidence %in% c("low", "medium") | is.na(df$ontology_id))) {
        "needs_review"
      } else {
        "auto_high_confidence"
      },
      stringsAsFactors = FALSE
    )
  })
  concepts <- do.call(rbind, concept_rows)
  concepts <- assign_phenomap_ids(concepts)

  id_map <- concepts[, c("phenomap_phenotype_id", "merge_key"), drop = FALSE]
  study_map <- merge(candidate_selected, id_map, by = "merge_key", all.x = TRUE, sort = FALSE)
  edges <- data.frame(
    study_id = study_map$study_id,
    phenotype_id = study_map$phenomap_phenotype_id,
    relationship = "investigated",
    candidate_name = study_map$candidate_name,
    phenotype_type = study_map$phenotype_type,
    ontology_id = study_map$ontology_id,
    ontology_label = study_map$ontology_label,
    ontology_match_confidence = study_map$ontology_match_confidence,
    merge_key = study_map$merge_key,
    stringsAsFactors = FALSE
  )

  review <- candidate_selected[
    is.na(candidate_selected$ontology_id) |
      candidate_selected$ontology_match_confidence %in% c("low", "medium") |
      candidate_selected$ontology_match_method %in% c("no_candidate", "llm_no_match", "rule_no_match"),
    ,
    drop = FALSE
  ]

  phenomap_write_csv(concepts, file.path(output_dir, "nodes_phenotype.csv"))
  phenomap_write_csv(edges, file.path(output_dir, "edges_study_phenotype.csv"))
  phenomap_write_csv(candidates, file.path(output_dir, "phenotype_candidates.csv"))
  phenomap_write_csv(ontology_candidates, file.path(output_dir, "phenotype_ontology_candidates.csv"))
  phenomap_write_csv(review, file.path(output_dir, "phenotype_normalization_review.csv"))

  invisible(list(
    nodes_phenotype = concepts,
    edges_study_phenotype = edges,
    phenotype_candidates = candidates,
    phenotype_ontology_candidates = ontology_candidates,
    phenotype_normalization_review = review
  ))
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenotype_norm_parse_args()
  build_normalized_phenotype_entity(
    input_study = args$input_study,
    output_dir = args$output_dir,
    use_llm = args$use_llm,
    model = args$model,
    base_url = args$base_url,
    ontology_rows = args$ontology_rows,
    ols_base_url = args$ols_base_url
  )
}
