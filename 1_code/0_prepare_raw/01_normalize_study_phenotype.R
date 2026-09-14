# Normalize the free-text phenotype field in study_meta.json files for one
# source database at a time (Metabolomics Workbench = "mw" or MetaboLights =
# "ml" -- pass its case_root/output_dir via --case_root/--output_dir).
#
# (Originally 02_normalize_workbench_phenotype.R -- despite that old name,
# this script has processed both databases -- once per database, with
# different --case_root/--output_dir -- since the 2026-08-19 delivery, so it
# was renamed to 02_normalize_study_phenotype.R for what it does rather than
# its first use, then to this file's current 01_ number once
# 0_prepare_raw/'s numbering was cleaned up to run 01-04 with no gaps.)
#
# Strategy (revised 2026 -- see phenomap_phenotype_taxonomy.md for the full
# rationale and evidence behind this design):
#   1. Use a GPT model to classify each study into one of a fixed set of
#      phenotype_type categories (see normalize_phenotype_type() below) and
#      extract the corresponding candidate term. Severity/stage is captured
#      separately as a qualifier, not as its own phenotype_type.
#   2. Depending on phenotype_type, search a FIXED, type-specific set of
#      ontology sources through EMBL-EBI OLS (see
#      phenomap_ontology_scope_by_type below) -- e.g. disease is searched
#      broadly across MONDO/EFO/MeSH/HPO, intervention is searched only in
#      NCIT, chemical only in ChEBI. This fixed routing (instead of letting
#      GPT pick a source ad hoc) is what fixes the "same phenotype gets a
#      different ontology source in different studies" duplication problem.
#   3. Use a GPT model to select one best ontology match from the type-scoped
#      candidate pool, or mark the case for manual review when no match or no
#      clear best match exists.
#   4. genetic_perturbation studies skip ontology search entirely and instead
#      resolve directly to an NCBI Gene ID (see select_best_ontology());
#      not_applicable studies are excluded from the Phenotype layer
#      entirely, on purpose (see select_best_ontology()).
#   5. Disease-type matches that did NOT land on MONDO are, in a later
#      pipeline step, canonicalized to MONDO via MONDO's own published
#      cross-references (see 1_code/0_prepare_raw/03_canonicalize_disease_to_mondo.R).
#      This script does not do that canonicalization itself.
#
# Caching: every GPT call and every EBI OLS search is cached to disk, keyed
# by the exact text sent to the API plus the model/endpoint (see
# phenomap_cache_key() / phenomap_cache_map() in 00_phenomap_helpers.R). Three
# cache files live under --output_dir:
#   phenotype_extraction_cache.rds   GPT principal-phenotype extraction
#   ols_search_cache.rds             EBI OLS ontology search (deduplicated
#                                     across ALL studies -- two studies that
#                                     happen to search the same term/ontology
#                                     share one cached result)
#   phenotype_selection_cache.rds    GPT best-ontology-match selection, and
#                                     NCBI Gene lookups for genetic_perturbation
# Re-running this script after new studies are merged in only pays for
# studies whose input metadata is new or has changed since the last run (or
# for query terms/genes never seen before) -- everything else is reused.
# Delete the relevant cache file(s) under --output_dir to force specific
# stages to fully re-run.
#
# This script writes reviewable CSV outputs only. It does not modify
# study_meta.json files.
#
# Usage (run once per source database):
#   Rscript 1_code/0_prepare_raw/01_normalize_study_phenotype.R \
#     --case_root=2_data/raw/delivery_20260819/out_qwen_eval_mw_anno_20260819 \
#     --output_dir=2_data/raw/delivery_20260819/phenotype_normalization_mw \
#     --workers=8
#   Rscript 1_code/0_prepare_raw/01_normalize_study_phenotype.R \
#     --case_root=2_data/raw/delivery_20260819/out_qwen_eval_ml_anno_20260819 \
#     --output_dir=2_data/raw/delivery_20260819/phenotype_normalization_ml \
#     --workers=8

source(file.path("1_code", "00_phenomap_helpers.R"))

parse_study_pheno_args <- function() {
  raw <- commandArgs(trailingOnly = TRUE)
  args <- list(
    case_root = NA_character_,
    output_dir = NA_character_,
    model = "gpt-4.1",
    base_url = "https://api.openai.com/v1",
    ols_base_url = "https://www.ebi.ac.uk/ols4/api",
    ontology_rows = 10L,
    limit = NA_integer_,
    sleep_seconds = 0.05,
    case_control_only = TRUE,
    workers = max(1L, parallel::detectCores(logical = FALSE) - 1L)
  )

  for (arg in raw) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% names(args)) args[[key]] <- value
  }

  # case_root/output_dir intentionally have NO default. A dated raw-data
  # folder (e.g. "workbench_20260629", "delivery_20260819") is exactly the
  # kind of thing that changes with every new delivery; hardcoding one
  # delivery's path as "the default" is how a script quietly keeps reading
  # stale data after the next delivery arrives (this happened once already
  # -- see git history). Require both explicitly instead.
  if (is.na(args$case_root) || !nzchar(args$case_root)) {
    stop("--case_root is required, e.g. --case_root=2_data/raw/<delivery>/out_qwen_eval_mw_anno_<date>")
  }
  if (is.na(args$output_dir) || !nzchar(args$output_dir)) {
    stop("--output_dir is required, e.g. --output_dir=2_data/raw/<delivery>/phenotype_normalization_mw")
  }

  args$ontology_rows <- suppressWarnings(as.integer(args$ontology_rows))
  if (is.na(args$ontology_rows) || args$ontology_rows < 1L) args$ontology_rows <- 10L
  args$limit <- suppressWarnings(as.integer(args$limit))
  args$sleep_seconds <- suppressWarnings(as.numeric(args$sleep_seconds))
  if (is.na(args$sleep_seconds) || args$sleep_seconds < 0) args$sleep_seconds <- 0.05
  args$case_control_only <- as.logical(args$case_control_only)
  if (is.na(args$case_control_only)) args$case_control_only <- TRUE
  args$workers <- suppressWarnings(as.integer(args$workers))
  if (is.na(args$workers) || args$workers < 1L) args$workers <- 1L
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
  allowed <- c(
    "disease", "symptom", "intervention", "chemical", "exposure", "trait",
    "genetic_perturbation", "cell_type_or_line", "biological_process",
    "not_applicable", "unclear"
  )
  if (x %in% allowed) x else "unclear"
}

# Canonical ontology search scope per phenotype_type. This mapping is the
# core fix for the "same phenotype resolves to different ontology sources in
# different studies" problem: instead of letting OLS-ranking/GPT judgment
# decide which source to use on a per-call basis, the source (or fixed set of
# sources) is determined entirely by phenotype_type, deterministically, every
# time.
#
# Evidence behind each mapping (see phenomap_phenotype_taxonomy.md):
#   - disease: searched broadly (mondo/efo/mesh/hp) because a meaningful
#     share of disease studies have no MONDO term yet; non-MONDO results are
#     canonicalized to MONDO downstream (03_canonicalize_disease_to_mondo.R)
#     rather than excluded here.
#   - intervention: NCIT validated empirically against real cases (CAR-T
#     cell therapy, in vitro fertilization, cryotherapy) -- NCIT matched or
#     beat MeSH on every case. MONDO/EFO/HP returned only noise for this
#     category and are deliberately excluded from the search scope.
#   - chemical: ChEBI.
#   - symptom / trait / exposure / cell_type_or_line / biological_process:
#     see phenomap_phenotype_taxonomy.md for the supporting examples. Note
#     trait uses EFO, NOT OBA -- OBA returned essentially no candidates for
#     this dataset's trait queries despite being the "textbook" choice.
#
# genetic_perturbation and not_applicable are intentionally absent from this
# list -- they are not ontology-search categories at all (see
# select_best_ontology()).
phenomap_ontology_scope_by_type <- list(
  disease            = c("mondo", "efo", "mesh", "hp"),
  symptom            = c("hp"),
  intervention       = c("ncit"),
  chemical           = c("chebi"),
  exposure           = c("efo", "mesh"),
  trait              = c("efo", "hp"),
  cell_type_or_line  = c("cl", "efo"),
  biological_process = c("go")
)

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
                          model = "gpt-4.1",
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

  txt <- httr::content(resp, as = "text", encoding = "UTF-8")
  if (httr::status_code(resp) >= 400) {
    stop(task, " failed with status ", httr::status_code(resp), ": ", txt)
  }

  # response_format = json_object guarantees `content` is valid, fence-free
  # JSON (per the OpenAI API contract) -- no salvage/retry parsing needed. If
  # this ever fails, that means the API itself broke its contract, and the
  # resulting error is caught one level up (extract_principal_phenotype() /
  # the selection compute_fn) and recorded as a manual_review row, same as
  # any other GPT-call failure -- it does not need its own recovery path here.
  payload <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
  content <- payload$choices[[1]]$message$content
  parsed <- jsonlite::fromJSON(content, simplifyVector = FALSE)
  parsed$raw_response <- content
  parsed
}

read_case_study_row <- function(case_dir) {
  meta <- phenomap_read_json(file.path(case_dir, "study_meta.json"))
  if (is.null(meta)) return(NULL)

  # phenomap_read_study_meta_row() (00_phenomap_helpers.R) tolerates both the
  # old nested study_meta.json shape and the new flat shape -- see its
  # header comment.
  fields <- phenomap_read_study_meta_row(meta, case_dir = case_dir)

  data.frame(
    study_id = phenomap_clean_scalar(meta$study_id %||% basename(case_dir), basename(case_dir)),
    case_dir = case_dir,
    study_title = fields$study_title,
    study_summary = fields$study_summary,
    current_phenotype = phenomap_clean_scalar(meta$phenotype),
    design_type = fields$design_type,
    case_label = fields$case_label,
    control_label = fields$control_label,
    study_type_raw = fields$study_type_raw,
    n_samples_analyzed = fields$n_samples_analyzed,
    biospecimen = fields$biospecimen,
    publication = fields$publication,
    publication_doi = fields$publication_doi,
    ms2_supported = fields$ms2_supported,
    chromatography_type = fields$chromatography_type,
    ms_instrument_type = fields$ms_instrument_type,
    ion_mode = fields$ion_mode,
    stringsAsFactors = FALSE
  )
}

phenotype_extraction_prompt <- function(row) {
  paste(
    "Task:",
    "Classify this study's main case-vs-control variable into exactly one phenotype_type,",
    "and extract the corresponding candidate term for literature retrieval in featuremap.",
    "",
    "Allowed phenotype_type values, in priority order when more than one could plausibly apply",
    "(apply the FIRST one that fits, top to bottom):",
    "",
    "1. genetic_perturbation - the case/control axis is a gene knockout, knockdown,",
    "   overexpression, or pharmacological inhibition/activation of a specific gene or protein",
    "   (e.g. 'TIGAR knockout', 'NAMPT inhibition', 'UGCG gene knockdown'). This takes priority",
    "   over cell_type_or_line even when the perturbation was performed in a specific cell line --",
    "   the gene is the true study variable, the cell line is just the experimental system used to",
    "   study it.",
    "2. disease - a human disease or disorder, at any severity/stage (e.g. 'Alzheimer's disease',",
    "   'hypertrophic cardiomyopathy', 'chronic asthma', 'renal cell carcinoma').",
    "3. symptom - a clinical sign or feature short of a full disease diagnosis (e.g. 'seizure',",
    "   'cognitive impairment').",
    "4. intervention - a medical procedure, cell therapy, or gene therapy (e.g. 'CAR-T cell",
    "   therapy', 'in vitro fertilization', 'cryotherapy'). Do not use this for a simple",
    "   drug/chemical exposure or treatment -- use chemical instead.",
    "5. chemical - exposure to, or treatment with, a specific chemical compound or drug (e.g.",
    "   'folic acid', 'isoproterenol', 'tetrathiomolybdate').",
    "6. exposure - a non-chemical environmental or behavioral exposure (e.g. 'cold exposure',",
    "   'exercise', 'high altitude exposure', a dietary intervention that is not a single named",
    "   compound).",
    "7. trait - a physiological or biological trait/state that is not itself a disease (e.g.",
    "   'aging', 'cholesterol homeostasis', 'overweight').",
    "8. cell_type_or_line - the study's core variable is simply which cell type or cell line is",
    "   being profiled or compared broadly (including general cell-culture/in-vitro experiments),",
    "   with no other perturbation driving the comparison (e.g. 'stromal cell', 'Jurkat').",
    "9. biological_process - a molecular or cellular process, not an organismal phenotype (e.g.",
    "   'cell migration', 'macrophage activation', 'mitochondrial biogenesis').",
    "10. not_applicable - the study has no biological phenotype at all; it compares purely",
    "    technical/methodological variables such as sample collection devices, extraction",
    "    protocols, or instrument platforms, typically in the same (often healthy) population",
    "    (e.g. comparing two blood collection methods, comparing two extraction protocols).",
    "11. unclear - none of the above clearly applies and you are not confident enough to choose.",
    "",
    "Hard exclusion rules:",
    "- Do not output healthy control, control, untreated, baseline, before, after, case-control, or other comparison-only labels.",
    "- Do not output country, ethnicity, cohort, age group, sex, sample source, biospecimen, platform, assay, chromatography, MS method, or omics layer as the phenotype itself.",
    "- Do not output broad words if a specific phenotype is available. For example, prefer non-small cell lung cancer over cancer.",
    "- Severity, stage, or grade (e.g. 'severe', 'chronic', 'late-stage', 'Grade III') is NOT a",
    "  phenotype_type on its own. If the study compares severity/stage of the same underlying",
    "  condition, classify phenotype_type as what that condition actually is (this will usually be",
    "  disease, but check the list above -- e.g. 'Cellular Senescence' and 'platelet activation'",
    "  are biological_process, not disease, even though they sound like severity states), and put",
    "  the severity/stage word in severity_qualifier instead.",
    "- If phenotype_type is genetic_perturbation, also extract the official gene symbol being",
    "  perturbed into perturbed_gene_symbol.",
    "",
    "Return STRICT JSON only:",
    "{",
    '  "principal_phenotype": "single professional term",',
    '  "phenotype_type": "one of the 11 values listed above",',
    '  "severity_qualifier": "severity/stage/grade modifier if present in the study design, else null",',
    '  "perturbed_gene_symbol": "official gene symbol if phenotype_type is genetic_perturbation, else null",',
    '  "aliases": ["synonym or abbreviation", "expanded term"],',
    '  "query_terms": ["terms to search in every ontology"],',
    '  "manual_review": false,',
    '  "confidence": "high | medium | low",',
    '  "rationale": "short reason"',
    "}",
    "",
    # Only study_id (a bare label, not classification input), title, and
    # summary are passed in -- checked empirically against 243 already-
    # classified MW studies: principal_phenotype matches case_label
    # verbatim only ~13% of the time, and in 32% of studies case_label is
    # itself an uninformative raw database code (a bare number, "case",
    # "yes", a cryptic abbreviation like a cell-line name) with no
    # phenotype content at all -- title/summary is where the real
    # information comes from in the large majority of studies. case_label/
    # control_label/design_type/study_type_raw/biospecimen/current_phenotype
    # were tried and dropped as unnecessary for this step (see
    # phenomap_phenotype_taxonomy.md for the underlying comparison).
    "Study metadata:",
    paste0("- study_id: ", row$study_id),
    paste0("- title: ", row$study_title),
    paste0("- summary: ", row$study_summary),
    sep = "\n"
  )
}

# Pure: turns a study row + already-fetched GPT response into the candidate
# data.frame row. Never makes a network call itself -- see
# extract_principal_phenotype() below for the cached/I-O wrapper.
build_extraction_row <- function(row, prompt, parsed, error) {
  phenotype <- phenomap_clean_scalar(parsed$principal_phenotype)
  aliases <- clean_vec(parsed$aliases)
  query_terms <- clean_vec(c(parsed$query_terms, phenotype, aliases))
  manual_review <- isTRUE(parsed$manual_review) || is.na(phenotype) || !is.na(error)

  data.frame(
    study_id = row$study_id,
    principal_phenotype = phenotype,
    phenotype_type = normalize_phenotype_type(parsed$phenotype_type),
    severity_qualifier = phenomap_clean_scalar(parsed$severity_qualifier),
    perturbed_gene_symbol = phenomap_clean_scalar(parsed$perturbed_gene_symbol),
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

# Cached/I-O wrapper: makes (at most) one GPT call, never throws (a failed
# call becomes a manual_review row with extraction_error set, same as a
# GPT response the model itself flagged as low-confidence) -- so this is
# always safe to cache: a permanently-failing call does not get retried
# forever, it is simply recorded as needing manual review, exactly as it
# would have been before caching existed.
extract_principal_phenotype <- function(row, api_key, model, base_url) {
  prompt <- phenotype_extraction_prompt(row)
  error <- NA_character_
  parsed <- tryCatch(
    call_gpt_json(prompt = prompt, api_key = api_key, model = model, base_url = base_url,
                  task = "principal phenotype extraction"),
    error = function(e) {
      error <<- conditionMessage(e)
      NULL
    }
  )
  build_extraction_row(row, prompt, parsed, error)
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

# The (ontology, query) pairs a single candidate needs searched, as a plain
# data.frame -- pure, no I/O. Deduplicating and caching happens one level up
# in normalize_study_phenotypes(), across ALL studies at once, so two
# studies that happen to search the same term/ontology (e.g. a common
# disease name) share one cached OLS call instead of paying for it twice.
ols_tasks_for_candidate <- function(candidate_row) {
  ptype <- phenomap_clean_scalar(candidate_row$phenotype_type[[1]], "unclear")
  ontologies <- phenomap_ontology_scope_by_type[[ptype]]
  empty <- data.frame(ontology = character(0), query = character(0), stringsAsFactors = FALSE)
  if (is.null(ontologies)) return(empty)

  queries <- unique(split_semicolon(candidate_row$query_terms))
  queries <- head(queries, 8L)
  if (length(queries) == 0) return(empty)

  expand.grid(ontology = ontologies, query = queries, stringsAsFactors = FALSE)
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

# Pure: builds the final selection row for a study, given whatever the
# outer orchestration already resolved for it (an already-fetched GPT
# selection response for the default ontology-search path, or an
# already-fetched NCBI Gene lookup for the genetic_perturbation path).
# Makes no network/GPT calls itself -- see normalize_study_phenotypes()
# for how each dependency is fetched (cached, deduplicated, parallel).
select_best_ontology <- function(study_row,
                                 candidate_row,
                                 ontology_candidates,
                                 gene_lookup = NULL,
                                 selection_response = NULL,
                                 selection_prompt = NA_character_,
                                 selection_error = NA_character_) {
  ptype <- phenomap_clean_scalar(candidate_row$phenotype_type[[1]], "unclear")

  base_row <- function(decision, selected, final_label, final_ontology,
                        final_ontology_id, manual_review, review_reason,
                        selection_confidence = "low") {
    data.frame(
      study_id = candidate_row$study_id,
      decision = decision,
      selected = selected,
      selected_candidate_key = NA_character_,
      final_label = final_label,
      final_phenotype_type = ptype,
      final_ontology = final_ontology,
      final_ontology_id = final_ontology_id,
      final_ontology_iri = NA_character_,
      final_ontology_definition = NA_character_,
      selection_confidence = selection_confidence,
      manual_review = manual_review,
      review_reason = review_reason,
      selection_prompt = NA_character_,
      selection_raw_response = NA_character_,
      selection_error = NA_character_,
      stringsAsFactors = FALSE
    )
  }

  # not_applicable: intentionally excluded from the Phenotype layer entirely
  # (e.g. studies comparing blood-collection devices, not a biological
  # phenotype). No ontology search happens for this type; final_label stays
  # NA on purpose so that 03_tidy_study_entity.R's existing inner join drops
  # this study from nodes_study.csv -- not_applicable studies do not get a
  # Study node.
  if (ptype == "not_applicable") {
    return(base_row(
      decision = "not_applicable", selected = FALSE,
      final_label = NA_character_, final_ontology = NA_character_,
      final_ontology_id = NA_character_,
      manual_review = FALSE,
      review_reason = "Study compares technical/methodological variables (e.g. sample collection or processing method), not a biological phenotype. Intentionally excluded, not sent to manual review.",
      selection_confidence = candidate_row$extraction_confidence[[1]] %||% "low"
    ))
  }

  # genetic_perturbation: identity is a gene symbol, not an ontology term, so
  # it does not go through the OLS4 search/GPT-selection flow the other
  # types use. These ARE kept as Phenotype nodes, labeled with the
  # already-extracted principal_phenotype phrase (e.g. "MCJ knockout", "ATF4
  # inhibition" -- this already names the gene AND the kind of perturbation,
  # which a bare "<gene> knockout" template would get wrong for non-knockout
  # studies), falling back to "<gene> knockout" only if principal_phenotype
  # itself is missing. The gene is resolved against NCBI Gene, restricted to
  # Homo sapiens (this KG's Phenotype layer is human-only, so a model-organism
  # knockout study is recorded as a perturbation of the human gene -- see
  # phenomap_ncbi_gene_lookup() in 00_phenomap_helpers.R). Falls back to a
  # name-only node (no ID, flagged for manual review) when no human match
  # exists.
  if (ptype == "genetic_perturbation") {
    gene <- phenomap_clean_scalar(candidate_row$perturbed_gene_symbol[[1]])
    if (is.na(gene)) {
      return(base_row(
        decision = "genetic_perturbation", selected = FALSE,
        final_label = NA_character_, final_ontology = NA_character_,
        final_ontology_id = NA_character_,
        manual_review = TRUE,
        review_reason = "Classified as genetic_perturbation but no gene symbol was extracted -- needs manual review.",
        selection_confidence = candidate_row$extraction_confidence[[1]] %||% "low"
      ))
    }

    label <- phenomap_coalesce_scalar(candidate_row$principal_phenotype[[1]], paste0(gene, " knockout"))
    ncbi_gene <- if (!is.null(gene_lookup)) gene_lookup[[toupper(gene)]] else NULL
    if (!is.null(ncbi_gene) && !is.na(ncbi_gene$gene_id)) {
      row <- base_row(
        decision = "genetic_perturbation", selected = TRUE,
        final_label = label, final_ontology = "ncbigene",
        final_ontology_id = paste0("NCBIGene:", ncbi_gene$gene_id),
        manual_review = FALSE,
        review_reason = paste0(
          "Classified as genetic_perturbation (gene: ", gene, "). Matched to NCBI Gene ID ",
          ncbi_gene$gene_id, " (", ncbi_gene$official_symbol %||% gene, ") via ", ncbi_gene$matched_via, " lookup."
        ),
        selection_confidence = candidate_row$extraction_confidence[[1]] %||% "low"
      )
      row$final_ontology_iri <- paste0("https://www.ncbi.nlm.nih.gov/gene/", ncbi_gene$gene_id)
      row$final_ontology_definition <- ncbi_gene$description
      return(row)
    }

    return(base_row(
      decision = "genetic_perturbation", selected = TRUE,
      final_label = label, final_ontology = NA_character_,
      final_ontology_id = NA_character_,
      manual_review = TRUE,
      review_reason = paste0(
        "Classified as genetic_perturbation (gene: ", gene, "). No HUMAN NCBI Gene match found -- ",
        "phenomap_ncbi_gene_lookup() only matches Homo sapiens by design (this KG's Phenotype layer is ",
        "human-only), so this is either a lookup error, an unrecognized symbol, or a gene with no ",
        "annotated human ortholog under this symbol. Kept as a name-only Phenotype node pending manual ID assignment."
      ),
      selection_confidence = candidate_row$extraction_confidence[[1]] %||% "low"
    ))
  }

  empty <- base_row(
    decision = "no_match", selected = FALSE,
    final_label = NA_character_, final_ontology = NA_character_,
    final_ontology_id = NA_character_,
    manual_review = TRUE,
    review_reason = paste0(
      "No ontology candidates returned from ",
      paste(toupper(phenomap_ontology_scope_by_type[[ptype]] %||% "the searched ontologies"), collapse = ", "),
      "."
    )
  )

  if (!is.data.frame(ontology_candidates) || nrow(ontology_candidates) == 0) {
    return(empty)
  }

  ontology_candidates <- ontology_candidates[order(-ontology_candidates$rule_score, ontology_candidates$rank), , drop = FALSE]
  ontology_candidates <- head(ontology_candidates, 40L)
  ontology_candidates$candidate_key <- paste0("C", seq_len(nrow(ontology_candidates)))

  parsed <- selection_response
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
    empty$selection_prompt <- selection_prompt
    empty$selection_raw_response <- phenomap_clean_scalar(parsed$raw_response)
    empty$selection_error <- selection_error
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
    # Derived from the ontology_id prefix rather than hit$ontology (the
    # ontology that was *searched*), because OLS4 ontology-scoped searches
    # (e.g. ontology=efo) can return hits whose native ID belongs to a
    # different ontology that the searched one imports/aggregates (e.g.
    # MONDO:..., GO:..., ECTO:... turning up under an efo search).
    final_ontology = tolower(sub(":.*$", "", hit$ontology_id[[1]])),
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
    selection_prompt = selection_prompt,
    selection_raw_response = phenomap_clean_scalar(parsed$raw_response),
    selection_error = selection_error,
    stringsAsFactors = FALSE
  )
}

normalize_study_phenotypes <- function(case_root,
                                       output_dir,
                                       api_key = Sys.getenv("OPENAI_API_KEY"),
                                       model = "gpt-4.1",
                                       base_url = "https://api.openai.com/v1",
                                       ols_base_url = "https://www.ebi.ac.uk/ols4/api",
                                       ontology_rows = 10L,
                                       limit = NA_integer_,
                                       sleep_seconds = 0.05,
                                       case_control_only = TRUE,
                                       workers = 1L) {
  # PhenoMAP is currently scoped to case-control studies only; continuous-
  # variable studies will be added in a later run. Anything excluded here is
  # written to excluded_non_case_control.csv under output_dir instead of
  # being silently skipped.
  case_dirs <- phenomap_case_dirs(
    case_root, require_meta = TRUE,
    case_control_only = case_control_only,
    exclude_report_path = file.path(output_dir, "excluded_non_case_control.csv")
  )
  if (!is.na(limit) && limit > 0L) case_dirs <- head(case_dirs, limit)

  meta_rows <- lapply(case_dirs, read_case_study_row)
  meta_rows <- meta_rows[!vapply(meta_rows, is.null, logical(1))]
  studies <- do.call(rbind, meta_rows)
  studies <- studies[order(studies$study_id), , drop = FALSE]
  message("Loaded ", nrow(studies), " case-control studies from ", case_root, ".")

  # ---- stage 1: GPT principal-phenotype extraction (cached, parallel) ----
  extraction_cache_path <- file.path(output_dir, "phenotype_extraction_cache.rds")
  extraction_cache <- phenomap_load_cache_store(extraction_cache_path)

  study_rows <- split(studies, seq_len(nrow(studies)))
  candidate_rows <- phenomap_cache_map(
    items = study_rows,
    key_fn = function(row) phenomap_cache_key(model, phenotype_extraction_prompt(row)),
    compute_fn = function(row) extract_principal_phenotype(row, api_key = api_key, model = model, base_url = base_url),
    store = extraction_cache,
    workers = workers,
    label = "GPT phenotype extraction"
  )
  phenomap_save_cache_store(extraction_cache, extraction_cache_path)
  candidates <- do.call(rbind, candidate_rows)

  # ---- stage 2: EBI OLS ontology search (cached, deduplicated, parallel) ----
  message("Searching each candidate's type-specific ontology scope (see phenomap_ontology_scope_by_type).")
  ols_cache_path <- file.path(output_dir, "ols_search_cache.rds")
  ols_cache <- phenomap_load_cache_store(ols_cache_path)

  candidate_row_list <- split(candidates, seq_len(nrow(candidates)))
  all_tasks <- do.call(rbind, lapply(candidate_row_list, ols_tasks_for_candidate))
  all_tasks <- unique(all_tasks)
  message("Distinct (ontology, query) pairs needed across all studies: ", nrow(all_tasks))

  task_items <- if (nrow(all_tasks) == 0) list() else split(all_tasks, seq_len(nrow(all_tasks)))
  task_results <- phenomap_cache_map(
    items = task_items,
    key_fn = function(t) phenomap_cache_key(t$ontology[[1]], t$query[[1]], ontology_rows),
    compute_fn = function(t) {
      if (sleep_seconds > 0) Sys.sleep(sleep_seconds)
      ols_search_one(query = t$query[[1]], ontology = t$ontology[[1]], rows = ontology_rows, ols_base_url = ols_base_url)
    },
    store = ols_cache,
    workers = workers,
    label = "EBI OLS ontology search"
  )
  phenomap_save_cache_store(ols_cache, ols_cache_path)

  task_keys <- if (length(task_items) == 0) character(0) else {
    vapply(task_items, function(t) phenomap_cache_key(t$ontology[[1]], t$query[[1]], ontology_rows), character(1))
  }
  ols_results_by_task <- setNames(task_results, task_keys)

  ontology_candidates_by_study <- lapply(candidate_row_list, function(candidate_row) {
    tasks <- ols_tasks_for_candidate(candidate_row)
    if (nrow(tasks) == 0) return(data.frame())
    keys <- vapply(seq_len(nrow(tasks)), function(i) {
      phenomap_cache_key(tasks$ontology[[i]], tasks$query[[i]], ontology_rows)
    }, character(1))
    hits <- ols_results_by_task[keys]
    hits <- hits[vapply(hits, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))]
    if (length(hits) == 0) return(data.frame())

    found <- do.call(rbind, hits)
    found <- found[!is.na(found$ontology_id) & nzchar(found$ontology_id), , drop = FALSE]
    if (nrow(found) == 0) return(data.frame())

    found$study_id <- candidate_row$study_id
    found$principal_phenotype <- candidate_row$principal_phenotype
    found$phenotype_type <- candidate_row$phenotype_type
    found <- found[
      !duplicated(paste(found$study_id, found$ontology, found$ontology_id, found$ontology_label)),
      ,
      drop = FALSE
    ]
    add_simple_match_score(candidate_row, found)
  })

  ontology_candidates <- ontology_candidates_by_study[
    vapply(ontology_candidates_by_study, function(x) is.data.frame(x) && nrow(x) > 0, logical(1))
  ]
  ontology_candidates <- if (length(ontology_candidates) > 0) do.call(rbind, ontology_candidates) else data.frame()

  # ---- stage 3: resolve genetic_perturbation gene symbols (cached, parallel) ----
  message("Resolving genetic_perturbation gene symbols via NCBI Gene.")
  gene_cache_path <- file.path(output_dir, "ncbi_gene_cache.rds")
  gene_cache <- phenomap_load_cache_store(gene_cache_path)

  gp_genes <- unique(toupper(clean_vec(
    candidates$perturbed_gene_symbol[candidates$phenotype_type == "genetic_perturbation"]
  )))
  gene_results <- phenomap_cache_map(
    items = as.list(gp_genes),
    key_fn = function(g) phenomap_cache_key("ncbigene", g),
    compute_fn = function(g) {
      # NCBI E-utilities are rate-limited without an API key; a small delay
      # before each call (same idea as the OLS stage's sleep_seconds) makes
      # a 429 under `workers` parallel lookups less likely in the first
      # place. phenomap_ncbi_gene_lookup() itself also retries with backoff
      # and throws (rather than returning a false "not found") if a request
      # still fails after retries, so this is a courtesy, not the only
      # safeguard.
      if (sleep_seconds > 0) Sys.sleep(sleep_seconds)
      phenomap_ncbi_gene_lookup(g)
    },
    store = gene_cache,
    workers = workers,
    label = "NCBI Gene lookup"
  )
  phenomap_save_cache_store(gene_cache, gene_cache_path)
  gene_lookup <- setNames(gene_results, gp_genes)

  # ---- stage 4: GPT best-ontology-match selection (cached, parallel) ----
  message("Selecting one best ontology match or routing to manual review.")
  selection_cache_path <- file.path(output_dir, "phenotype_selection_cache.rds")
  selection_cache <- phenomap_load_cache_store(selection_cache_path)

  needs_gpt_selection <- vapply(seq_len(nrow(candidates)), function(i) {
    ptype <- candidates$phenotype_type[[i]]
    !ptype %in% c("not_applicable", "genetic_perturbation") &&
      is.data.frame(ontology_candidates) && nrow(ontology_candidates) > 0 &&
      any(ontology_candidates$study_id == candidates$study_id[[i]])
  }, logical(1))

  selection_tasks <- lapply(which(needs_gpt_selection), function(i) {
    study_id <- candidates$study_id[[i]]
    list(
      study_row = studies[studies$study_id == study_id, , drop = FALSE],
      candidate_row = candidates[i, , drop = FALSE],
      ontology_candidates = ontology_candidates[ontology_candidates$study_id == study_id, , drop = FALSE]
    )
  })

  selection_responses <- phenomap_cache_map(
    items = selection_tasks,
    key_fn = function(task) {
      phenomap_cache_key(model, ontology_selection_prompt(task$study_row, task$candidate_row, task$ontology_candidates))
    },
    compute_fn = function(task) {
      prompt <- ontology_selection_prompt(task$study_row, task$candidate_row, task$ontology_candidates)
      error <- NA_character_
      parsed <- tryCatch(
        call_gpt_json(prompt = prompt, api_key = api_key, model = model, base_url = base_url,
                      task = "ontology best-match selection"),
        error = function(e) {
          error <<- conditionMessage(e)
          NULL
        }
      )
      list(prompt = prompt, parsed = parsed, error = error)
    },
    store = selection_cache,
    workers = workers,
    label = "GPT ontology selection"
  )
  phenomap_save_cache_store(selection_cache, selection_cache_path)
  names(selection_responses) <- vapply(selection_tasks, function(task) task$candidate_row$study_id[[1]], character(1))

  selection_rows <- lapply(seq_len(nrow(candidates)), function(i) {
    study_id <- candidates$study_id[[i]]
    resolved <- selection_responses[[study_id]]
    select_best_ontology(
      study_row = studies[studies$study_id == study_id, , drop = FALSE],
      candidate_row = candidates[i, , drop = FALSE],
      ontology_candidates = if (is.data.frame(ontology_candidates) && nrow(ontology_candidates) > 0) {
        ontology_candidates[ontology_candidates$study_id == study_id, , drop = FALSE]
      } else {
        data.frame()
      },
      gene_lookup = gene_lookup,
      selection_response = if (!is.null(resolved)) resolved$parsed else NULL,
      selection_prompt = if (!is.null(resolved)) resolved$prompt else NA_character_,
      selection_error = if (!is.null(resolved)) resolved$error else NA_character_
    )
  })
  selections <- do.call(rbind, selection_rows)
  ontology_summary <- phenomap_summarize_ontology_candidates_by_study(ontology_candidates)
  selections <- merge(selections, ontology_summary, by = "study_id", all.x = TRUE, sort = FALSE)

  final <- merge(studies, candidates, by = "study_id", all.x = TRUE, sort = FALSE)
  final <- merge(final, selections, by = "study_id", all.x = TRUE, sort = FALSE)
  selected_ok <- !is.na(final$selected) & final$selected
  review_needed <- is.na(final$manual_review) | final$manual_review
  # not_applicable is a deliberate, confident classification outcome -- it
  # should not be lumped into "manual_review" just because it has no
  # final_ontology_id (it was never supposed to get one). genetic_perturbation
  # is similar but DOES get a final_label (the gene symbol) and a Phenotype
  # node, with final_ontology_id populated via NCBI Gene when a match is
  # found -- see select_best_ontology().
  final$normalization_status <- ifelse(
    final$decision %in% "not_applicable", "not_applicable",
    ifelse(
      final$decision %in% "genetic_perturbation" & !review_needed, "gene_perturbation_resolved",
      ifelse(selected_ok & !review_needed, "auto_selected", "manual_review")
    )
  )

  review <- final[final$normalization_status == "manual_review", , drop = FALSE]

  phenomap_write_csv(studies, file.path(output_dir, "study_meta_index.csv"))
  phenomap_write_csv(candidates, file.path(output_dir, "phenotype_principal_candidates.csv"))
  phenomap_write_csv(ontology_candidates, file.path(output_dir, "phenotype_ols_candidates.csv"))
  phenomap_write_csv(selections, file.path(output_dir, "phenotype_final_selection.csv"))
  phenomap_write_csv(review, file.path(output_dir, "phenotype_manual_review.csv"))
  phenomap_write_csv(final, file.path(output_dir, "phenotype_normalization_all.csv"))

  message(
    "Done. normalization_status counts:\n",
    paste(capture.output(print(table(final$normalization_status))), collapse = "\n")
  )

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
  args <- parse_study_pheno_args()
  normalize_study_phenotypes(
    case_root = args$case_root,
    output_dir = args$output_dir,
    model = args$model,
    base_url = args$base_url,
    ols_base_url = args$ols_base_url,
    ontology_rows = args$ontology_rows,
    limit = args$limit,
    sleep_seconds = args$sleep_seconds,
    case_control_only = args$case_control_only,
    workers = args$workers
  )
}
