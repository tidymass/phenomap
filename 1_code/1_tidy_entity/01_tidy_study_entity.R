# Generate PhenoMAP Study/Project entity table.
#
# Output:
#   nodes_study.csv
#
# Usage:
#   Rscript 1_code/1_tidy_entity/01_tidy_study_entity.R \
#     --case_root=../featuremap_case/2_data/case_metabolights \
#     --output_dir=2_data/tidy_entity

source(file.path("1_code", "1_tidy_entity", "00_entity_helpers.R"))

normalize_study_design <- function(x) {
  x <- phenomap_clean_scalar(x)
  if (is.na(x)) return(NA_character_)
  key <- tolower(gsub("[^a-z0-9]+", "_", x))
  key <- gsub("^_+|_+$", "", key)
  if (key %in% c("binary_case_control", "case_control", "case_vs_control")) {
    return("case-control")
  }
  if (key %in% c("paired", "paired_case_control", "pre_post", "before_after")) {
    return("paired/pre-post")
  }
  if (key %in% c("multi_group", "multigroup")) {
    return("multi-group")
  }
  if (key %in% c("continuous", "correlation", "regression")) {
    return("continuous trait")
  }
  gsub("_", "-", key)
}

study_phenotype_prompt <- function(study_id,
                                   title,
                                   description,
                                   study_design,
                                   study_design_detail,
                                   factor_column,
                                   case_label,
                                   control_label,
                                   biospecimen,
                                   biospecimen_detail,
                                   existing_phenotype) {
  paste(
    "You are helping curate study-level phenotype metadata for a human metabolomics knowledge graph named PhenoMAP.",
    "",
    "Task:",
    "Curate two levels of study phenotype metadata.",
    "",
    "Level 1: study_focus_raw",
    "- A concise noun phrase describing what this specific study/contrast is about.",
    "- This may include a disease, exposure, treatment, trait, cell perturbation, or sample/method context.",
    "- Do not write an X versus Y comparison.",
    "",
    "Level 2: phenotype_name_normalized",
    "- A cleaner candidate name for future phenotype-node deduplication.",
    "- Name the case/perturbation/exposure/disease/state itself.",
    "- Do NOT name downstream mechanisms, metabolic responses, research conclusions, biomarkers, or pathway interpretations.",
    "- Prefer 'caffeine treatment' over 'enhanced antitumor T-cell activity'.",
    "- Prefer 'tetrandrine treatment' over 'LIMP-2-dependent NAADP-mediated calcium signaling inhibition'.",
    "- Prefer 'OCIAD1 knockout' over 'OCIAD1 knockout cellular lipid metabolism'.",
    "- Prefer 'retinopathy of prematurity' over 'Yes versus No'.",
    "- For treatment pre/post studies, name the treatment, treated condition, or treatment response rather than 'post versus pre'.",
    "- For cell-line comparisons, name the cell perturbation/model state using a short phrase.",
    "",
    "Allowed phenotype_type values:",
    "disease | severity | exposure | treatment | trait | cell_model | method_sample_context | unclear",
    "",
    "Type guidance:",
    "- disease: named disease, syndrome, infection, cancer subtype, or clinical condition.",
    "- severity: disease stage, severity, prognosis, responder status, outcome grade, or risk stratum.",
    "- exposure: diet, alcohol, coffee, hypoxia, altitude, xenobiotic, environmental/geographic exposure, or spiked exposure.",
    "- treatment: drug, supplement, intervention, pre/post treatment, vehicle-controlled perturbation, or therapeutic response.",
    "- trait: age, obesity, fertility outcome, pregnancy/live-birth outcome, skin aging, genetic trait, physiological trait.",
    "- cell_model: knockout, knockdown, overexpression, mutation, cell-line state, co-culture, or engineered cell perturbation.",
    "- method_sample_context: sampling method, sample preservation, analytical standardization, DBS-vs-serum, breath filter, archaeological sample context.",
    "- unclear: insufficient metadata.",
    "Be conservative and use only the provided metadata.",
    "",
    "Return STRICT JSON only:",
    "{",
    '  "study_focus_raw": "specific study focus phrase",',
    '  "phenotype_name_normalized": "deduplication-ready candidate phrase",',
    '  "phenotype_type": "disease | severity | exposure | treatment | trait | cell_model | method_sample_context | unclear",',
    '  "phenotype_scope": "human | cell_model | method | mixed | unclear",',
    '  "phenotype_id_candidate": "lowercase snake_case candidate ID stem",',
    '  "normalization_note": "short reason for the normalized name/type",',
    '  "confidence": "high | medium | low",',
    '  "rationale": "short reason"',
    "}",
    "",
    "Study metadata:",
    paste0("- study_id: ", study_id),
    paste0("- title: ", title),
    paste0("- description: ", description),
    paste0("- existing phenotype field: ", existing_phenotype),
    paste0("- study design: ", study_design),
    paste0("- study design detail/notes: ", study_design_detail),
    paste0("- factor column: ", factor_column),
    paste0("- case label: ", case_label),
    paste0("- control label: ", control_label),
    paste0("- biospecimen: ", biospecimen),
    paste0("- biospecimen detail: ", biospecimen_detail),
    sep = "\n"
  )
}

call_gpt_for_study_phenotype <- function(prompt,
                                         api_key = Sys.getenv("OPENAI_API_KEY"),
                                         model = "gpt-4.1-mini",
                                         base_url = "https://api.openai.com/v1") {
  if (!requireNamespace("httr", quietly = TRUE)) {
    stop("Package 'httr' is required for GPT study phenotype curation.")
  }
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("Package 'jsonlite' is required for GPT study phenotype curation.")
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
        content = "You are a careful biomedical metadata curator. Return only valid JSON."
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
    stop("GPT study phenotype request failed with status ", httr::status_code(resp), ": ", txt)
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
      stop("Could not parse GPT study phenotype JSON: ", content)
    }
    parsed <- jsonlite::fromJSON(json_text[[1]], simplifyVector = FALSE)
  }
  parsed$raw_response <- content
  parsed
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

fallback_study_phenotype <- function(meta) {
  existing <- phenomap_clean_scalar(meta$phenotype)
  if (!is.na(existing)) {
    raw <- existing
    normalized <- gsub("\\s+versus\\s+.*$", "", existing, ignore.case = TRUE)
    normalized <- gsub("\\s+vs\\.?\\s+.*$", "", normalized, ignore.case = TRUE)
    normalized <- trimws(normalized)
    if (nzchar(normalized)) {
      return(list(
        study_focus_raw = raw,
        phenotype_name_normalized = normalized,
        phenotype_type = "unclear",
        phenotype_scope = "unclear",
        phenotype_id_candidate = phenomap_normalize_text_id(normalized),
        normalization_note = "Fallback from existing phenotype field."
      ))
    }
  }
  factor_column <- phenomap_clean_scalar(meta$factor_column)
  if (!is.na(factor_column)) {
    x <- sub("^Factor Value\\[", "", factor_column)
    x <- sub("\\]$", "", x)
    x <- trimws(x)
    if (nzchar(x)) {
      return(list(
        study_focus_raw = x,
        phenotype_name_normalized = x,
        phenotype_type = "unclear",
        phenotype_scope = "unclear",
        phenotype_id_candidate = phenomap_normalize_text_id(x),
        normalization_note = "Fallback from factor column."
      ))
    }
  }
  list(
    study_focus_raw = NA_character_,
    phenotype_name_normalized = NA_character_,
    phenotype_type = "unclear",
    phenotype_scope = "unclear",
    phenotype_id_candidate = NA_character_,
    normalization_note = "No usable fallback metadata."
  )
}

build_study_entity <- function(case_root,
                               output_dir = file.path("2_data", "tidy_entity"),
                               repository = "metabolights",
                               use_llm = TRUE,
                               api_key = Sys.getenv("OPENAI_API_KEY"),
                               model = "gpt-4.1-mini",
                               base_url = "https://api.openai.com/v1") {
  case_dirs <- phenomap_case_dirs(case_root, require_meta = TRUE)

  rows <- lapply(case_dirs, function(case_dir) {
    meta <- phenomap_read_json(file.path(case_dir, "study_meta.json"))
    study_id <- phenomap_case_id(case_dir, meta)
    accession <- study_id
    study_design <- normalize_study_design(phenomap_json_value(meta, "design_type"))
    study_design_detail <- phenomap_json_value(meta, "notes")
    biospecimen <- phenomap_json_value(meta, "biospecimen")
    biospecimen_detail <- phenomap_json_value(meta, "biospecimen_raw")
    existing_phenotype <- phenomap_json_value(meta, "phenotype")
    title <- phenomap_json_value(meta, "title")
    description <- phenomap_json_value(meta, "description")
    factor_column <- phenomap_json_value(meta, "factor_column")
    case_label <- phenomap_json_value(meta, "case_label")
    control_label <- phenomap_json_value(meta, "control_label")

    gpt_prompt <- study_phenotype_prompt(
      study_id = study_id,
      title = title,
      description = description,
      study_design = study_design,
      study_design_detail = study_design_detail,
      factor_column = factor_column,
      case_label = case_label,
      control_label = control_label,
      biospecimen = biospecimen,
      biospecimen_detail = biospecimen_detail,
      existing_phenotype = existing_phenotype
    )

    gpt_result <- NULL
    gpt_error <- NA_character_
    if (isTRUE(use_llm)) {
      message("Curating study phenotype for ", study_id)
      gpt_result <- tryCatch(
        call_gpt_for_study_phenotype(
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

    fallback <- fallback_study_phenotype(meta)
    study_focus_raw <- phenomap_clean_scalar(gpt_result$study_focus_raw)
    phenotype_name_normalized <- phenomap_clean_scalar(gpt_result$phenotype_name_normalized)
    phenotype_type <- normalize_phenotype_type(gpt_result$phenotype_type)
    phenotype_scope <- normalize_phenotype_scope(gpt_result$phenotype_scope)
    normalization_note <- phenomap_clean_scalar(gpt_result$normalization_note)

    if (is.na(study_focus_raw)) study_focus_raw <- fallback$study_focus_raw
    if (is.na(phenotype_name_normalized)) phenotype_name_normalized <- fallback$phenotype_name_normalized
    if (identical(phenotype_type, "unclear") && !is.null(fallback$phenotype_type)) {
      phenotype_type <- fallback$phenotype_type
    }
    if (identical(phenotype_scope, "unclear") && !is.null(fallback$phenotype_scope)) {
      phenotype_scope <- fallback$phenotype_scope
    }
    normalized_id_stem <- phenomap_normalize_text_id(phenotype_name_normalized)
    if (!is.na(normalized_id_stem)) {
      phenotype_id_candidate <- paste(
        phenotype_type,
        normalized_id_stem,
        sep = "__"
      )
    } else {
      phenotype_id_candidate <- fallback$phenotype_id_candidate
    }
    if (is.na(normalization_note)) normalization_note <- fallback$normalization_note
    phenotype_source <- if (!is.na(phenomap_clean_scalar(gpt_result$phenotype_name_normalized))) {
      "llm_normalized"
    } else {
      "fallback"
    }

    data.frame(
      study_id = study_id,
      accession = accession,
      repository = repository,
      repository_accession = study_id,
      study_design = study_design,
      study_design_detail = study_design_detail,
      sample_size = suppressWarnings(as.integer(phenomap_json_value(meta, "n_samples"))),
      biospecimen = biospecimen,
      biospecimen_detail = biospecimen_detail,
      platform = NA_character_,
      publication_link = NA_character_,
      study_focus_raw = study_focus_raw,
      phenotype_name_normalized = phenotype_name_normalized,
      phenotype = phenotype_name_normalized,
      phenotype_type = phenotype_type,
      phenotype_scope = phenotype_scope,
      phenotype_id_candidate = phenotype_id_candidate,
      normalization_note = normalization_note,
      phenotype_source = phenotype_source,
      phenotype_llm_confidence = phenomap_clean_scalar(gpt_result$confidence),
      phenotype_llm_rationale = phenomap_clean_scalar(gpt_result$rationale),
      phenotype_llm_prompt = gpt_prompt,
      phenotype_llm_raw_response = phenomap_clean_scalar(gpt_result$raw_response),
      phenotype_llm_error = gpt_error,
      title = title,
      description = description,
      organisms = phenomap_json_value(meta, "organisms"),
      factor_column = factor_column,
      case_label = case_label,
      control_label = control_label,
      design_type_raw = phenomap_json_value(meta, "design_type"),
      biospecimen_raw = biospecimen_detail,
      chromatography_type = phenomap_json_value(meta, "column_type"),
      column_type_qwen = phenomap_json_value(meta, "column_type_qwen"),
      column_type_assay = phenomap_json_value(meta, "column_type_assay"),
      column_notes = phenomap_json_value(meta, "column_notes"),
      polarities = phenomap_json_value(meta, "polarities"),
      study_url = phenomap_make_study_url(study_id, repository),
      n_samples = suppressWarnings(as.integer(phenomap_json_value(meta, "n_samples"))),
      n_assay_files = suppressWarnings(as.integer(phenomap_json_value(meta, "n_assay_files"))),
      n_files_in_h5 = suppressWarnings(as.integer(phenomap_json_value(meta, "n_files_in_h5"))),
      h5_coverage = suppressWarnings(as.numeric(phenomap_json_value(meta, "h5_coverage"))),
      factor_value_counts_json = if (!is.null(meta$factor_value_counts)) {
        jsonlite::toJSON(meta$factor_value_counts, auto_unbox = TRUE, null = "null")
      } else {
        NA_character_
      },
      class_pol_breakdown_json = if (!is.null(meta$class_pol_breakdown)) {
        jsonlite::toJSON(meta$class_pol_breakdown, auto_unbox = TRUE, null = "null")
      } else {
        NA_character_
      },
      notes = phenomap_json_value(meta, "notes"),
      existing_phenotype = existing_phenotype,
      has_res_rda = file.exists(file.path(case_dir, "anno_result", "res.rda")),
      case_dir = normalizePath(case_dir, mustWork = FALSE),
      stringsAsFactors = FALSE
    )
  })

  out <- do.call(rbind, rows)
  out <- out[order(out$study_id), , drop = FALSE]

  phenomap_write_csv(out, file.path(output_dir, "nodes_study.csv"))
  invisible(out)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- phenomap_parse_args()
  build_study_entity(
    case_root = args$case_root,
    output_dir = args$output_dir,
    use_llm = args$use_llm,
    model = args$model,
    base_url = args$base_url
  )
}
