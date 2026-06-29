# Generate PhenoMAP Phenotype entity table.
#
# Output:
#   nodes_phenotype.csv
#
# Existing phenotype values are used directly. Missing or vague phenotypes are
# curated with an OpenAI-compatible chat API when `use_gpt = TRUE`.

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

phenotype_gpt_prompt <- function(study_id,
                                 title,
                                 description,
                                 case_label,
                                 control_label,
                                 biospecimen,
                                 existing_phenotype = NA_character_) {
  paste(
    "You are helping curate phenotype metadata for a human metabolomics knowledge graph named PhenoMAP.",
    "",
    "Task:",
    "Given the study metadata below, infer a concise phenotype comparison name.",
    "Do not over-interpret experimental details. Preserve the case-control contrast.",
    "If this is a disease, exposure, treatment, trait, severity, sample-type comparison, geography comparison, or cell-model perturbation, name it explicitly.",
    "If the phenotype is ambiguous, return the best conservative wording and mark uncertainty in the note.",
    "",
    "Return STRICT JSON only with these fields:",
    "{",
    '  "phenotype_name": "...",',
    '  "phenotype_type_suggestion": "disease | exposure | treatment | trait | severity | cell_model | sample_type | geography | other | unclear",',
    '  "mesh_id": "MeSH ID if confidently known, otherwise null",',
    '  "mondo_id": "MONDO ID if confidently known, otherwise null",',
    '  "hpo_id": "HPO ID if confidently known, otherwise null",',
    '  "efo_id": "EFO ID if confidently known, otherwise null",',
    '  "mesh_query": "...",',
    '  "mondo_query": "...",',
    '  "hpo_query": "...",',
    '  "efo_query": "...",',
    '  "curation_note": "..."',
    "}",
    "",
    "Study metadata:",
    paste0("- study_id: ", study_id),
    paste0("- title: ", title),
    paste0("- description: ", description),
    paste0("- existing phenotype field: ", existing_phenotype),
    paste0("- case label: ", case_label),
    paste0("- control label: ", control_label),
    paste0("- biospecimen: ", biospecimen),
    sep = "\n"
  )
}

call_gpt_for_phenotype <- function(prompt,
                                   api_key = Sys.getenv("OPENAI_API_KEY"),
                                   model = "gpt-4.1-mini",
                                   base_url = "https://api.openai.com/v1") {
  if (!requireNamespace("httr", quietly = TRUE)) {
    stop("Package 'httr' is required for GPT phenotype curation.")
  }
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("Package 'jsonlite' is required for GPT phenotype curation.")
  }
  if (is.na(api_key) || !nzchar(api_key)) {
    stop("API key is empty. Set OPENAI_API_KEY or pass api_key.")
  }
  if (is.na(model) || !nzchar(model)) {
    stop("model is empty.")
  }
  if (is.na(base_url) || !nzchar(base_url)) {
    stop("base_url is empty.")
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
        content = paste(
          "You are a careful biomedical metadata curator.",
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
    # Some OpenAI-compatible providers do not support response_format. Retry
    # once without it before surfacing the error.
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
    stop("GPT API request failed with status ", httr::status_code(resp), ": ", txt)
  }

  payload <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
  content <- payload$choices[[1]]$message$content
  if (is.null(content) || !nzchar(content)) {
    stop("GPT API returned empty message content.")
  }

  parsed <- tryCatch(
    jsonlite::fromJSON(content, simplifyVector = FALSE),
    error = function(e) NULL
  )

  if (is.null(parsed)) {
    json_text <- regmatches(content, regexpr("\\{[\\s\\S]*\\}", content, perl = TRUE))
    if (length(json_text) == 0 || !nzchar(json_text[[1]])) {
      stop("Could not parse GPT JSON response: ", content)
    }
    parsed <- jsonlite::fromJSON(json_text[[1]], simplifyVector = FALSE)
  }

  parsed$raw_response <- content
  parsed
}

extract_ontology_id <- function(x, pattern) {
  x <- phenomap_clean_scalar(x)
  if (is.na(x)) return(NA_character_)
  hit <- regmatches(x, regexpr(pattern, x, perl = TRUE, ignore.case = TRUE))
  if (length(hit) == 0 || !nzchar(hit[[1]])) return(NA_character_)
  toupper(hit[[1]])
}

build_phenotype_entity <- function(case_root,
                                   output_dir = file.path("2_data", "tidy_entity"),
                                   use_gpt = TRUE,
                                   api_key = Sys.getenv("OPENAI_API_KEY"),
                                   model = "gpt-4.1-mini",
                                   base_url = "https://api.openai.com/v1") {
  case_dirs <- phenomap_case_dirs(case_root, require_meta = TRUE)

  rows <- lapply(case_dirs, function(case_dir) {
    meta <- phenomap_read_json(file.path(case_dir, "study_meta.json"))
    study_id <- phenomap_case_id(case_dir, meta)
    phenotype <- phenomap_make_phenotype(meta)
    phenotype_name <- phenotype$phenotype_name
    phenotype_id <- phenomap_make_phenotype_id(study_id, phenotype_name)

    case_label <- phenomap_json_value(meta, "case_label")
    control_label <- phenomap_json_value(meta, "control_label")
    biospecimen <- phenomap_json_value(meta, "biospecimen")
    title <- phenomap_json_value(meta, "title")
    description <- phenomap_json_value(meta, "description")
    existing <- phenomap_json_value(meta, "phenotype")

    needs_gpt <- is.na(existing) || !nzchar(existing) ||
      existing %in% c("Yes versus No", "High versus Low", "Poor versus Good",
                      "Treatment Group versus Study Control", "Affected versus Control")

    gpt_prompt <- if (isTRUE(needs_gpt)) {
      phenotype_gpt_prompt(
        study_id = study_id,
        title = title,
        description = description,
        case_label = case_label,
        control_label = control_label,
        biospecimen = biospecimen,
        existing_phenotype = existing
      )
    } else {
      NA_character_
    }

    gpt_result <- NULL
    gpt_error <- NA_character_
    if (isTRUE(needs_gpt) && isTRUE(use_gpt)) {
      gpt_result <- tryCatch(
        call_gpt_for_phenotype(
          prompt = gpt_prompt,
          api_key = api_key,
          model = model,
          base_url = base_url
        ),
        error = function(e) {
          gpt_error <<- conditionMessage(e)
          NULL
        }
      )
    }

    gpt_phenotype_name <- phenomap_clean_scalar(gpt_result$phenotype_name)
    phenotype_type_suggestion <- phenomap_clean_scalar(gpt_result$phenotype_type_suggestion)
    mesh_id_from_gpt <- phenomap_clean_scalar(gpt_result$mesh_id)
    mondo_id_from_gpt <- phenomap_clean_scalar(gpt_result$mondo_id)
    hpo_id_from_gpt <- phenomap_clean_scalar(gpt_result$hpo_id)
    efo_id_from_gpt <- phenomap_clean_scalar(gpt_result$efo_id)
    mesh_query <- phenomap_clean_scalar(gpt_result$mesh_query)
    mondo_query <- phenomap_clean_scalar(gpt_result$mondo_query)
    hpo_query <- phenomap_clean_scalar(gpt_result$hpo_query)
    efo_query <- phenomap_clean_scalar(gpt_result$efo_query)
    curation_note <- phenomap_clean_scalar(gpt_result$curation_note)
    gpt_raw_response <- phenomap_clean_scalar(gpt_result$raw_response)

    mesh_id <- if (!is.na(mesh_id_from_gpt)) {
      mesh_id_from_gpt
    } else {
      extract_ontology_id(mesh_query, "(MESH:)?[CD][0-9]{6,}")
    }
    mondo_id <- if (!is.na(mondo_id_from_gpt)) {
      mondo_id_from_gpt
    } else {
      extract_ontology_id(mondo_query, "MONDO:[0-9]{7}")
    }
    hpo_id <- if (!is.na(hpo_id_from_gpt)) {
      hpo_id_from_gpt
    } else {
      extract_ontology_id(hpo_query, "HP:[0-9]{7}")
    }
    efo_id <- if (!is.na(efo_id_from_gpt)) {
      efo_id_from_gpt
    } else {
      extract_ontology_id(efo_query, "EFO:[0-9]{7}")
    }

    final_phenotype_name <- if (!is.na(gpt_phenotype_name)) {
      gpt_phenotype_name
    } else {
      phenotype_name
    }
    final_phenotype_id <- phenomap_make_phenotype_id(study_id, final_phenotype_name)
    final_source <- if (!is.na(gpt_phenotype_name)) {
      "gpt_curated"
    } else {
      phenotype$phenotype_source
    }

    data.frame(
      phenotype_id = final_phenotype_id,
      phenotype_name = final_phenotype_name,
      phenotype_type = phenotype_type_suggestion,
      mesh_id = mesh_id,
      mondo_id = mondo_id,
      hpo_id = hpo_id,
      efo_id = efo_id,
      ontology_note = if (!is.na(curation_note)) {
        paste(curation_note, "Ontology IDs are GPT-suggested and not yet database-validated.")
      } else if (any(!is.na(c(mesh_id, mondo_id, hpo_id, efo_id)))) {
        "Ontology IDs are GPT-suggested and not yet database-validated."
      } else {
        NA_character_
      },
      phenotype_source = final_source,
      needs_gpt_curation = needs_gpt,
      gpt_prompt = gpt_prompt,
      gpt_phenotype_name = gpt_phenotype_name,
      phenotype_type_suggestion = phenotype_type_suggestion,
      mesh_id_from_gpt = mesh_id_from_gpt,
      mondo_id_from_gpt = mondo_id_from_gpt,
      hpo_id_from_gpt = hpo_id_from_gpt,
      efo_id_from_gpt = efo_id_from_gpt,
      mesh_query = mesh_query,
      mondo_query = mondo_query,
      hpo_query = hpo_query,
      efo_query = efo_query,
      curation_note = curation_note,
      gpt_raw_response = gpt_raw_response,
      gpt_error = gpt_error,
      study_id = study_id,
      case_label = case_label,
      control_label = control_label,
      biospecimen = biospecimen,
      title = title,
      stringsAsFactors = FALSE
    )
  })

  out <- do.call(rbind, rows)
  out <- out[order(out$study_id), , drop = FALSE]

  phenomap_write_csv(out, file.path(output_dir, "nodes_phenotype.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_parse_args()
  build_phenotype_entity(
    case_root = args$case_root,
    output_dir = args$output_dir
  )
}
