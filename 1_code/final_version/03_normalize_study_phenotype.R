#!/usr/bin/env Rscript

# Classify and normalize the phenotype of every study in the final PhenoMAP
# 2026-09-13 set.
#
# Same method as 1_code/0_prepare_raw/01_normalize_study_phenotype.R, applied to
# the new input. That script read one study_meta.json per case directory; the
# final set is a single flat CSV of re-fetched titles/descriptions
# (2_data/finalversion_0913/study_descriptions_refetched.csv, written by
# 1_code/final_version/01_fetch_study_descriptions.R). Everything else is the
# same pipeline:
#
#   1. GPT reads the study's title + description, names the ONE phenotype the
#      study is about, and classifies it into one of 11 phenotype_type
#      categories. Severity/stage is a qualifier, not a type.
#   1.5 A second, short GPT call decides whether the measured samples are human.
#      PhenoMAP's Phenotype layer is human-only; non-human studies (rodent and
#      other animal models, livestock, plants, non-human cultures) are excluded
#      here, before any ontology work, and listed in excluded_non_human.csv.
#      Human cell lines, organoids and human-sample microbiome studies count as
#      human. See organism_scope_prompt().
#   2. Each type is searched in a FIXED set of ontologies via EMBL-EBI OLS
#      (phenomap_ontology_scope_by_type) -- fixed routing is what stops the same
#      phenotype from landing on a different ontology source in each study.
#   3. Candidates are rule-scored, then GPT picks one best match or sends the
#      study to manual review.
#   4. genetic_perturbation resolves to an NCBI Gene ID instead;
#      not_applicable is excluded from the Phenotype layer on purpose.
#   5. Disease matches that did not land on MONDO are canonicalized afterwards
#      by 1_code/0_prepare_raw/03_canonicalize_disease_to_mondo.R (unchanged --
#      it reads this script's output folder).
#
# The 11 categories and their priority order are unchanged. What did change is
# how the task is put to the model, because the input changed:
#   * The set is no longer case-control only. It also contains multi-group
#     designs (doses, time points, severities, subtypes, treatment arms), so the
#     extraction prompt no longer says "the case-vs-control variable". It asks
#     for the one thing that DISTINGUISHES the compared groups, whatever their
#     number -- explicitly not the setting/procedure/population they share (the
#     first draft said "what the study is about", which made the model answer
#     "in vitro fertilization" for a study whose two arms were IVF with vs
#     without added LH) -- and says that when the groups are levels of one
#     underlying condition, that condition is the answer.
#   * No case-control filtering step either: the retained-accession list is
#     already the final filtered set and the CSV carries no design metadata.
#     Studies that are not a biological comparison at all are still caught by
#     `not_applicable`.
#   * Neither prompt mentions featuremap or any other internal project name --
#     the model has no idea what those are. query_terms is explained by what it
#     is used for: search queries against biomedical ontologies.
#   * The selection prompt does not print case_label / control_label /
#     current_phenotype: the CSV has none of them, and sending three "NA" fields
#     only invites the model to read their absence as evidence.
#
# Input text is tidied first (see read_final_studies): the Workbench mwTab
# export stores both title and description twice back to back (218 of 399 mw
# records, ~21% of all description text), and 141 MetaboLights records have a
# placeholder title ("Investigation") or none.
#
# Every GPT call, OLS search and NCBI Gene lookup is cached to disk under
# --output_dir, keyed by the exact text sent, so a re-run only pays for what is
# new. Delete a cache file to force that stage to re-run.
#
# Requirements: run from the project root; Sys.getenv("OPENAI_API_KEY") set;
# packages httr, jsonlite, digest.
#
# Usage:
#   Rscript 1_code/final_version/03_normalize_study_phenotype.R --database=mw --workers=8
#   Rscript 1_code/final_version/03_normalize_study_phenotype.R --database=ml --workers=8
#
#   # then, per output folder:
#   Rscript 1_code/0_prepare_raw/03_canonicalize_disease_to_mondo.R \
#     --phenotype_dir=2_data/finalversion_0913/phenotype_normalization_mw --workers=8
#   Rscript 1_code/0_prepare_raw/02_add_ontology_ids_to_phenotype_outputs.R \
#     --output_dir=2_data/finalversion_0913/phenotype_normalization_mw
#
# mw and ml are run separately because they stay two folders all the way to
# 1_tidy_entity/01_tidy_phenotype_entity.R (one manual-review workbook each).
#
# Outputs, per --output_dir (same files, same columns as 0_prepare_raw writes):
#   study_meta_index.csv, phenotype_principal_candidates.csv,
#   phenotype_ols_candidates.csv, phenotype_final_selection.csv,
#   phenotype_manual_review.csv, phenotype_normalization_all.csv,
#   excluded_non_human.csv, *.rds caches
#
# Writes CSV/RDS only; does not modify any delivered result file.

source(file.path("1_code", "00_phenomap_helpers.R"))

DEFAULT_INPUT_CSV <- file.path("2_data", "finalversion_0913", "study_descriptions_refetched.csv")
DEFAULT_OUTPUT_ROOT <- file.path("2_data", "finalversion_0913")

parse_final_pheno_args <- function() {
  args <- list(
    input_csv = DEFAULT_INPUT_CSV,
    output_dir = NA_character_,
    database = "all",
    model = "gpt-4.1",
    base_url = "https://api.openai.com/v1",
    ols_base_url = "https://www.ebi.ac.uk/ols4/api",
    ontology_rows = 10L,
    limit = NA_integer_,
    sleep_seconds = 0.05,
    workers = max(1L, parallel::detectCores(logical = FALSE) - 1L)
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    if (!kv[[1]] %in% names(args)) next
    args[[kv[[1]]]] <- kv[[2]]
  }

  args$database <- tolower(phenomap_clean_scalar(args$database, "all"))
  if (!args$database %in% c("mw", "ml", "all")) {
    stop("--database must be one of: mw, ml, all")
  }
  if (is.na(args$output_dir) || !nzchar(args$output_dir)) {
    args$output_dir <- file.path(DEFAULT_OUTPUT_ROOT, paste0("phenotype_normalization_", args$database))
  }

  args$ontology_rows <- suppressWarnings(as.integer(args$ontology_rows))
  if (is.na(args$ontology_rows) || args$ontology_rows < 1L) args$ontology_rows <- 10L
  args$limit <- suppressWarnings(as.integer(args$limit))
  if (!is.na(args$limit) && args$limit < 1L) args$limit <- NA_integer_
  args$sleep_seconds <- suppressWarnings(as.numeric(args$sleep_seconds))
  if (is.na(args$sleep_seconds) || args$sleep_seconds < 0) args$sleep_seconds <- 0.05
  args$workers <- suppressWarnings(as.integer(args$workers))
  if (is.na(args$workers) || args$workers < 1L) args$workers <- 1L
  args
}


# ---------------------------------------------------------------------------
# Input: the re-fetched study description CSV -> the study table every stage
# below works from.
# ---------------------------------------------------------------------------

strip_html <- function(x) {
  x <- phenomap_clean_scalar(x)
  if (is.na(x)) return(NA_character_)
  x <- gsub("<br\\s*/?>", " ", x, ignore.case = TRUE)
  x <- gsub("</p\\s*>", " ", x, ignore.case = TRUE)
  x <- gsub("<[^>]+>", " ", x)
  x <- gsub("&nbsp;|&#160;", " ", x)
  x <- gsub("&amp;", "&", x)
  x <- gsub("&lt;", "<", x)
  x <- gsub("&gt;", ">", x)
  x <- gsub("&quot;", "\"", x)
  x <- gsub("&#39;|&apos;", "'", x)
  phenomap_clean_scalar(trimws(gsub("[[:space:]]+", " ", x)))
}

# The mwTab export repeats both the title and the description verbatim
# ("<text> <text>"). Collapse only an EXACT doubling around a single space, so
# text that merely repeats a phrase internally is left alone.
collapse_exact_doubling <- function(x) {
  x <- phenomap_clean_scalar(x)
  if (is.na(x)) return(NA_character_)
  x <- trimws(gsub("[[:space:]]+", " ", x))
  if (!nzchar(x)) return(NA_character_)

  n <- nchar(x)
  if (n %% 2L == 1L) {
    half <- (n - 1L) %/% 2L
    if (half > 0L &&
        identical(substr(x, half + 1L, half + 1L), " ") &&
        identical(substr(x, 1L, half), substr(x, half + 2L, n))) {
      return(substr(x, 1L, half))
    }
  }
  x
}

# Titles carrying no phenotype information. Kept short on purpose: anything
# genuinely ambiguous should reach the model and be classified `unclear` by it,
# not dropped by a regex here.
PLACEHOLDER_TITLES <- c("investigation", "untitled", "study", "no title", "n/a", "none", "-")

tidy_study_title <- function(x) {
  x <- collapse_exact_doubling(x)
  if (is.na(x)) return(NA_character_)
  if (tolower(x) %in% PLACEHOLDER_TITLES) return(NA_character_)
  x
}

read_final_studies <- function(input_csv, database = "all") {
  if (!file.exists(input_csv)) stop("Missing input CSV: ", input_csv)

  raw <- utils::read.csv(input_csv, stringsAsFactors = FALSE, check.names = FALSE)
  for (col in c("study_accession", "database_key", "title")) {
    if (!col %in% names(raw)) stop("Input CSV is missing required column: ", col)
  }
  for (col in c("description_plain", "description_raw", "fetch_status")) {
    if (!col %in% names(raw)) raw[[col]] <- rep(NA_character_, nrow(raw))
  }

  raw$database_key <- tolower(trimws(as.character(raw$database_key)))
  if (database != "all") {
    raw <- raw[!is.na(raw$database_key) & raw$database_key == database, , drop = FALSE]
  }
  if (nrow(raw) == 0) stop("No studies left after applying --database=", database)

  # A study whose description fetch failed has no text to classify: reported,
  # not silently skipped.
  fetch_ok <- is.na(raw$fetch_status) | !nzchar(trimws(raw$fetch_status)) |
    tolower(trimws(raw$fetch_status)) == "ok"
  if (any(!fetch_ok)) {
    message("Skipping ", sum(!fetch_ok), " studies whose description fetch did not return ok.")
    raw <- raw[fetch_ok, , drop = FALSE]
  }

  study_id <- vapply(raw$study_accession, phenomap_clean_scalar, character(1), USE.NAMES = FALSE)
  keep <- !is.na(study_id)
  raw <- raw[keep, , drop = FALSE]
  study_id <- study_id[keep]

  dup <- duplicated(study_id)
  if (any(dup)) {
    message("Dropping ", sum(dup), " duplicate accession rows (keeping the first of each).")
    raw <- raw[!dup, , drop = FALSE]
    study_id <- study_id[!dup]
  }

  study_title <- vapply(raw$title, tidy_study_title, character(1), USE.NAMES = FALSE)
  study_summary <- vapply(seq_len(nrow(raw)), function(i) {
    plain <- phenomap_clean_scalar(raw$description_plain[[i]])
    if (is.na(plain)) plain <- strip_html(raw$description_raw[[i]])
    collapse_exact_doubling(plain)
  }, character(1))

  no_text <- is.na(study_title) & is.na(study_summary)
  if (any(no_text)) {
    message("Skipping ", sum(no_text), " studies with neither a usable title nor a description: ",
            paste(head(study_id[no_text], 20L), collapse = ", "))
    raw <- raw[!no_text, , drop = FALSE]
    study_id <- study_id[!no_text]
    study_title <- study_title[!no_text]
    study_summary <- study_summary[!no_text]
  }

  studies <- data.frame(
    study_id = study_id,
    study_title = study_title,
    study_summary = study_summary,
    source_database = vapply(raw$database_key, phenomap_clean_scalar, character(1), USE.NAMES = FALSE),
    stringsAsFactors = FALSE
  )
  studies <- studies[order(studies$study_id), , drop = FALSE]
  rownames(studies) <- NULL
  studies
}


# ---------------------------------------------------------------------------
# Classification + ontology-matching logic, unchanged from
# 1_code/0_prepare_raw/01_normalize_study_phenotype.R.
# ---------------------------------------------------------------------------

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

# What the model is given: the study's own title and description, exactly as
# the source repository publishes them, plus the accession as a bare label.
# Nothing else is available for the final 2026-09-13 set -- and nothing else is
# needed: checked against 243 already-classified studies, the phenotype is
# carried by the title/description in the large majority of cases, while the
# repositories' own case/control labels are uninformative database codes in
# about a third of studies.
phenotype_extraction_prompt <- function(row) {
  paste(
    "Task:",
    "Below is the title and description of a metabolomics study, as published in a public",
    "study repository (Metabolomics Workbench or MetaboLights). Work out what phenotype the",
    "study is about -- the biological condition its group comparison was designed to",
    "investigate -- then classify that phenotype into exactly one phenotype_type and name it",
    "with one standard biomedical term.",
    "",
    "The phenotype is what DISTINGUISHES the groups being compared -- not the setting,",
    "procedure, disease context or population that every group shares. If all subjects",
    "underwent the same procedure and the groups differ only by one added treatment or",
    "condition, that treatment or condition is the phenotype, and the shared procedure is not.",
    "",
    "Return exactly ONE principal phenotype per study, whatever the design:",
    "- Some studies compare one case group against controls.",
    "- Others compare several groups: doses, time points, severities, subtypes, treatment arms.",
    "  When those groups are levels of one underlying condition, that condition is the principal",
    "  phenotype and the level that separates them is not (put it in severity_qualifier if it is",
    "  a severity, stage or grade).",
    "- When a study really does vary more than one thing, choose the one its design is built",
    "  around -- usually the one the title names -- not a secondary or incidental factor.",
    "",
    "The description is author-written text: it usually also covers cohorts, sample types,",
    "instruments and analysis methods. None of that is the phenotype.",
    "",
    "Allowed phenotype_type values, in priority order when more than one could plausibly apply",
    "(apply the FIRST one that fits, top to bottom):",
    "",
    "1. genetic_perturbation - the study's main variable is a gene knockout, knockdown,",
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
    "   'folic acid', 'isoproterenol', 'tetrathiomolybdate'). Use this only when ONE named",
    "   compound is what separates the groups; if they differ by several different chemicals",
    "   with no single compound in common (e.g. 'metals, BPA and phthalates'), use exposure.",
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
    "- If the description never says what the compared groups actually are, return unclear. Do",
    "  not fall back on the biospecimen the samples were drawn from, the assay, or the study's",
    "  general subject area. (A cell type is a perfectly good answer when the cell types",
    "  themselves are what is being compared -- that is what cell_type_or_line is for.)",
    "- Do not return a group label instead of a phenotype: healthy control, control, untreated,",
    "  baseline, before, after, group A, high dose, week 12, and the like describe which arm a",
    "  sample came from, not what the study is about.",
    "- Do not return country, ethnicity, cohort, age group, sex, sample source, biospecimen,",
    "  platform, assay, chromatography, MS method, or omics layer as the phenotype itself.",
    "- Do not return a broad word when a specific phenotype is available. For example, prefer",
    "  non-small cell lung cancer over cancer.",
    "- Severity, stage, or grade (e.g. 'severe', 'chronic', 'late-stage', 'Grade III') is NOT a",
    "  phenotype_type on its own. If the study compares severity/stage of the same underlying",
    "  condition, classify phenotype_type as what that condition actually is (this will usually be",
    "  disease, but check the list above -- e.g. 'Cellular Senescence' and 'platelet activation'",
    "  are biological_process, not disease, even though they sound like severity states), and put",
    "  the severity/stage word in severity_qualifier instead.",
    "- The same holds for any stratification WITHIN one condition: responders vs non-responders,",
    "  progressors vs non-progressors, survivors vs deceased, well- vs poorly-controlled,",
    "  relapsed vs in remission, before vs after the same treatment. The condition every group",
    "  has IS the principal phenotype: 'acute myeloid leukemia', not 'treatment response in",
    "  acute myeloid leukemia'. (This is different from groups that differ by an added",
    "  treatment or agent, where that agent is the phenotype.)",
    "- If phenotype_type is genetic_perturbation, also extract the official gene symbol being",
    "  perturbed into perturbed_gene_symbol.",
    "",
    "Naming rules for principal_phenotype and query_terms:",
    "- ONE concept, expressible as a single ontology term. No conjunctions, no lists, no",
    "  combinations: not 'prenatal exposure to metals, bisphenol A and phthalates', not",
    "  'adipocyte and ovarian cancer cell co-culture'. When the groups differ by several",
    "  related things, give either the one broader term that covers them ('prenatal chemical",
    "  exposure') or the disease/condition the design is really centred on ('ovarian cancer'),",
    "  whichever the study is actually investigating.",
    "- Name the specific entity, never the category it belongs to: 'reticulocyte', not 'cell",
    "  type'; 'cytarabine', not 'chemical'. Never answer with a bare category word, and never",
    "  with the name of a phenotype_type. If you cannot name one specific concept, return",
    "  unclear.",
    "- Name the thing itself, not the comparison performed on it: 'cytarabine', not 'cytarabine",
    "  exposure'. Keep such a word only when it belongs to the standard term ('cold exposure'",
    "  is standard; 'folic acid exposure' is not).",
    "- For genetic_perturbation, name the gene AND what was done to it: 'TIGAR knockout',",
    "  'NAMPT inhibition', 'IDH1 mutation' -- never a bare gene name.",
    "- query_terms are sent verbatim as search queries against biomedical ontologies, so give",
    "  standard term names, most specific first -- not sentences or descriptions.",
    "",
    "Return STRICT JSON only:",
    "{",
    '  "principal_phenotype": "the one phenotype separating the groups, as a specific standard term",',
    '  "phenotype_type": "one of the 11 values listed above",',
    '  "severity_qualifier": "severity/stage/grade modifier if the design compares them, else null",',
    '  "perturbed_gene_symbol": "official gene symbol if phenotype_type is genetic_perturbation, else null",',
    '  "aliases": ["synonym", "abbreviation or its expanded form"],',
    '  "query_terms": ["ontology search terms, most specific first"],',
    '  "manual_review": false,',
    '  "confidence": "high | medium | low",',
    '  "rationale": "short reason"',
    "}",
    "",
    "Study:",
    paste0("- accession: ", row$study_id),
    paste0("- title: ", row$study_title),
    paste0("- description: ", row$study_summary),
    sep = "\n"
  )
}


# Deterministic backstop for the one failure mode the prompt cannot reliably
# prevent: the model sometimes answers with the CATEGORY instead of a term
# ("cell type" rather than "reticulocyte"), or echoes a phenotype_type name.
# Observed on co-culture and cell-type studies, and it is not stable -- two
# studies with the same description can disagree. Such a value would end up as
# a Phenotype node name, so it is forced to manual review here rather than
# trusted. The not_applicable and genetic_perturbation branches of
# select_best_ontology() have their own review logic and are unaffected.
PHENOTYPE_CATEGORY_WORDS <- c(
  "cell type", "cell types", "cell line", "cell lines", "cell type or line",
  "disease", "disorder", "symptom", "trait", "phenotype", "condition",
  "chemical", "compound", "drug", "exposure", "intervention", "treatment",
  "biological process", "genetic perturbation", "gene", "tissue", "sample type",
  "not applicable", "unclear", "none", "na", "unknown"
)

is_category_answer <- function(x) {
  x <- tolower(phenomap_clean_scalar(x, ""))
  x <- trimws(gsub("[[:space:]]+", " ", gsub("[^a-z]+", " ", x)))
  nzchar(x) && x %in% PHENOTYPE_CATEGORY_WORDS
}

# Pure: turns a study row + already-fetched GPT response into the candidate
# data.frame row. Never makes a network call itself -- see
# extract_principal_phenotype() below for the cached/I-O wrapper.
build_extraction_row <- function(row, prompt, parsed, error) {
  phenotype <- phenomap_clean_scalar(parsed$principal_phenotype)
  aliases <- clean_vec(parsed$aliases)
  query_terms <- clean_vec(c(parsed$query_terms, phenotype, aliases))
  manual_review <- isTRUE(parsed$manual_review) || is.na(phenotype) || !is.na(error) ||
    is_category_answer(phenotype)

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

# ---------------------------------------------------------------------------
# Stage 1.5: is this study human?
#
# PhenoMAP's Phenotype layer is human-only, but the 2026-09-13 set is not: a
# keyword scan of the first full run found ~27% of the studies to be plants,
# microbial cultures, livestock or rodent models (42% of MetaboLights alone).
# They classify fine -- 'huanglongbing', 'litter size', 'Prunus mume rootstock
# grafting' are all correct answers -- but no human ontology can represent
# them, so every one of them burned an OLS search and a selection call only to
# land in manual review. Deciding scope here, before any of that, is both
# cheaper and honest: an excluded study says why it was excluded.
#
# This is deliberately a SEPARATE, short call rather than another field on the
# extraction prompt: adding a field there would change that prompt's text,
# invalidate its cache and re-roll all 723 classifications, and those
# classifications took several rounds to settle.
#
# Scope, as confirmed for this project -- a study is in scope if EITHER its
# samples are human-related OR the phenotype it studies is a human one:
#   human      -- human subjects; human cell lines, primary cells and organoids;
#                 human tissue grown in an animal host (xenograft); microbiome
#                 samples collected from humans; AND any study of a human
#                 disease, trait, drug or exposure, including when the
#                 experiment was run in an animal model or a cell system.
#   non_human  -- neither holds: plants, crops, food products, livestock, fish,
#                 insects, environmental or industrial microbes, materials.
#
# Two things this wording fixes, both seen in the first run:
#   * The first version said "decide from the description" and "answer unknown
#     if it does not say", which made the model discard what it knew: ST002231's
#     whole description is "HOG cells were plated in 6-well plates..." -- it
#     named HOG as a human oligodendroglioma line in its own answer and then
#     excluded the study because the text never writes "human".
#   * It also excluded rodent models of human disease, which contradicts this
#     KG's own design -- see phenomap_ncbi_gene_lookup(), which deliberately
#     maps a model-organism knockout onto the human gene.
# `unknown` is kept IN scope on purpose: a study whose description says too
# little should not be dropped silently, so it goes on through the normal path
# and stays visible in the organism_scope column.
organism_scope_prompt <- function(row) {
  paste(
    "Task:",
    "Below is the title and description of a metabolomics study. Decide whether it belongs in",
    "an atlas of HUMAN phenotypes.",
    "",
    "Answer human if EITHER is true:",
    "(a) the samples are human-related -- from human subjects or patients (blood, plasma,",
    "    urine, tissue, saliva, stool...), human cell lines, primary human cells, human",
    "    organoids, human tissue grown in an animal host (xenograft), or microbiome samples",
    "    collected from humans; or",
    "(b) the phenotype it studies is a human one -- a human disease, trait, drug or exposure --",
    "    even when the experiment was run in an animal model or a cell system.",
    "",
    "Answer non_human only when NEITHER holds: the study is about plants, crops, food",
    "products, livestock, poultry, fish, insects, environmental or industrial microbes, soil,",
    "wastewater, or materials, and the phenotype it studies is not a human one.",
    "",
    "Use what you already know about the material the description names. Named cell lines and",
    "strains carry their own species -- HOG, HeLa, GES-1, Panc1 and MCF-7 are human cell",
    "lines -- so do not answer non_human or unknown merely because the description never",
    "writes the word 'human'.",
    "",
    "Answer unknown only when the description says too little to tell either way.",
    "",
    "Return STRICT JSON only:",
    "{",
    '  "organism_scope": "human | non_human | unknown",',
    '  "organism": "the organism or sample source, in a few words",',
    '  "basis": "the words in the description that decided it",',
    '  "confidence": "high | medium | low"',
    "}",
    "",
    "Study:",
    paste0("- accession: ", row$study_id),
    paste0("- title: ", row$study_title),
    paste0("- description: ", row$study_summary),
    sep = "\n"
  )
}

normalize_organism_scope <- function(x) {
  x <- tolower(phenomap_clean_scalar(x, "unknown"))
  x <- gsub("[^a-z]+", "_", x)
  if (x %in% c("human", "non_human", "unknown")) x else "unknown"
}

build_organism_row <- function(row, parsed, error) {
  scope <- normalize_organism_scope(parsed$organism_scope)
  # A failed call must not silently exclude a study: fall back to unknown,
  # which stays in scope.
  if (!is.na(error)) scope <- "unknown"
  data.frame(
    study_id = row$study_id,
    organism_scope = scope,
    organism = phenomap_clean_scalar(parsed$organism),
    organism_basis = phenomap_clean_scalar(parsed$basis),
    organism_confidence = tolower(phenomap_clean_scalar(parsed$confidence, "low")),
    organism_error = error,
    stringsAsFactors = FALSE
  )
}

classify_organism_scope <- function(row, api_key, model, base_url) {
  prompt <- organism_scope_prompt(row)
  error <- NA_character_
  parsed <- tryCatch(
    call_gpt_json(prompt = prompt, api_key = api_key, model = model, base_url = base_url,
                  task = "organism scope classification"),
    error = function(e) {
      error <<- conditionMessage(e)
      NULL
    }
  )
  build_organism_row(row, parsed, error)
}

# The selection row for a study excluded as non-human. Column set matches
# select_best_ontology()'s base_row() exactly so the two rbind together.
non_human_selection_row <- function(candidate_row) {
  organism <- phenomap_clean_scalar(candidate_row$organism[[1]], "a non-human source")
  data.frame(
    study_id = candidate_row$study_id,
    decision = "non_human",
    selected = FALSE,
    selected_candidate_key = NA_character_,
    final_label = NA_character_,
    final_phenotype_type = candidate_row$phenotype_type,
    final_ontology = NA_character_,
    final_ontology_id = NA_character_,
    final_ontology_iri = NA_character_,
    final_ontology_definition = NA_character_,
    selection_confidence = phenomap_clean_scalar(candidate_row$organism_confidence[[1]], "low"),
    manual_review = FALSE,
    review_reason = paste0(
      "Neither human-related samples nor a human phenotype (", organism, "). PhenoMAP's ",
      "Phenotype layer is human-only, so this study is intentionally excluded before ontology ",
      "search -- not sent to manual review. The phenotype extracted for it is kept in ",
      "phenotype_principal_candidates.csv."
    ),
    selection_prompt = NA_character_,
    selection_raw_response = NA_character_,
    selection_error = NA_character_,
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

# The (ontology, query) pairs a single candidate needs searched, as a plain
# data.frame -- pure, no I/O. Deduplicating and caching happens one level up
# in normalize_study_phenotypes(), across ALL studies at once, so two
# studies that happen to search the same term/ontology (e.g. a common
# disease name) share one cached OLS call instead of paying for it twice.
ols_tasks_for_candidate <- function(candidate_row) {
  ptype <- phenomap_clean_scalar(candidate_row$phenotype_type[[1]], "unclear")
  # Non-human studies are out of scope for the Phenotype layer: no ontology
  # search, no selection call (see organism_scope_prompt()).
  if (identical(phenomap_clean_scalar(candidate_row$organism_scope[[1]], "human"), "non_human")) {
    return(data.frame(ontology = character(0), query = character(0), stringsAsFactors = FALSE))
  }
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
    "A previous step decided what phenotype this study is about. The candidate terms below were",
    "then retrieved from the ontologies that are appropriate for that phenotype_type. Pick the",
    "one candidate that best represents the phenotype, or say that none of them does.",
    "",
    "Choose only from the listed candidate_key values, and never invent an ontology ID.",
    "",
    "Selection rules:",
    "- Pick a candidate only if it clearly denotes the same concept as the principal phenotype.",
    "- rule_score and rule_match_type are a string-similarity prior, not an answer: a perfect",
    "  label match on the wrong concept is still wrong, and a lower-scoring candidate whose",
    "  definition actually fits is the better pick.",
    "- Do not pick a broad parent term when a more exact one is available, and never pick a term",
    "  denoting a cohort, sample type, assay, omics layer, pathway or mechanism rather than the",
    "  phenotype itself.",
    "- If several candidates are plausible and none is clearly best, return decision = manual_review.",
    "- If none of the candidates is appropriate, return decision = no_match.",
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
    # The re-fetched CSV has no case/control labels and no pre-existing
    # phenotype field, so (unlike 0_prepare_raw/01) those lines are not printed
    # here at all rather than being sent as "NA".
    "Study:",
    paste0("- accession: ", study_row$study_id),
    paste0("- title: ", study_row$study_title),
    paste0("- description: ", study_row$study_summary),
    "",
    "Principal phenotype decided in the previous step:",
    paste0("- principal_phenotype: ", candidate_row$principal_phenotype),
    paste0("- phenotype_type: ", candidate_row$phenotype_type),
    paste0("- aliases: ", candidate_row$aliases),
    paste0("- rationale: ", candidate_row$extraction_rationale),
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


# ---------------------------------------------------------------------------

normalize_final_study_phenotypes <- function(input_csv = DEFAULT_INPUT_CSV,
                                             output_dir,
                                             database = "all",
                                             api_key = Sys.getenv("OPENAI_API_KEY"),
                                             model = "gpt-4.1",
                                             base_url = "https://api.openai.com/v1",
                                             ols_base_url = "https://www.ebi.ac.uk/ols4/api",
                                             ontology_rows = 10L,
                                             limit = NA_integer_,
                                             sleep_seconds = 0.05,
                                             workers = 1L) {
  if (is.na(api_key) || !nzchar(api_key)) {
    stop("OPENAI_API_KEY is empty. Set it before running -- both the extraction ",
         "and the selection stage call the API.")
  }
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  studies <- read_final_studies(input_csv, database = database)
  if (!is.na(limit) && limit > 0L) studies <- head(studies, limit)
  message("Loaded ", nrow(studies), " studies from ", input_csv, " (database=", database, ").")

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

  # ---- stage 1.5: human / non-human scope (cached, parallel) ----
  message("Deciding which studies are human (PhenoMAP's Phenotype layer is human-only).")
  organism_cache_path <- file.path(output_dir, "organism_scope_cache.rds")
  organism_cache <- phenomap_load_cache_store(organism_cache_path)

  organism_rows <- phenomap_cache_map(
    items = study_rows,
    key_fn = function(row) phenomap_cache_key(model, organism_scope_prompt(row)),
    compute_fn = function(row) classify_organism_scope(row, api_key = api_key, model = model, base_url = base_url),
    store = organism_cache,
    workers = workers,
    label = "GPT organism scope"
  )
  phenomap_save_cache_store(organism_cache, organism_cache_path)
  organisms <- do.call(rbind, organism_rows)

  # Cheap deterministic audit flag, computed here (NOT inside the cached
  # classifier, so it also applies to results already in the cache): a study
  # ruled non-human whose own organism/basis text still mentions humans is
  # worth eyeballing. Most are correct -- germ-free mice colonised with human
  # microbiota, a mouse study that cites a human finding -- but this is exactly
  # where the real misses sit: a human cell line the description never calls
  # "human" (ST002231, HOG cells), a xenograft of human tumour cells in a
  # mouse, a study that measured human tissue AND mouse tissue. Excluded
  # studies never reach manual review, so without this flag those would
  # disappear silently. It only marks rows; it never changes a decision.
  organisms$organism_check_needed <- organisms$organism_scope == "non_human" &
    grepl("human|patient|volunteer|donor",
          paste(organisms$organism, organisms$organism_basis), ignore.case = TRUE)

  candidates <- merge(candidates, organisms, by = "study_id", all.x = TRUE, sort = FALSE)
  candidates$organism_scope[is.na(candidates$organism_scope)] <- "unknown"
  candidates <- candidates[order(candidates$study_id), , drop = FALSE]
  rownames(candidates) <- NULL
  message(
    "  organism_scope: ",
    paste(utils::capture.output(print(table(candidates$organism_scope))), collapse = " | ")
  )
  in_scope <- candidates$organism_scope != "non_human"

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
    candidates$perturbed_gene_symbol[candidates$phenotype_type == "genetic_perturbation" & in_scope]
  )))
  gene_results <- phenomap_cache_map(
    items = as.list(gp_genes),
    key_fn = function(g) phenomap_cache_key("ncbigene", g),
    compute_fn = function(g) {
      # NCBI E-utilities are rate-limited without an API key; a small delay
      # before each call makes a 429 under `workers` parallel lookups less
      # likely. phenomap_ncbi_gene_lookup() also retries with backoff.
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
    in_scope[[i]] &&
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
    if (!in_scope[[i]]) return(non_human_selection_row(candidates[i, , drop = FALSE]))
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
  # not_applicable is a deliberate classification outcome, not a failure: it
  # must not be lumped into manual_review just because it has no
  # final_ontology_id (it was never supposed to get one).
  final$normalization_status <- ifelse(
    final$decision %in% "non_human", "non_human_excluded",
    ifelse(
    final$decision %in% "not_applicable", "not_applicable",
    ifelse(
      final$decision %in% "genetic_perturbation" & !review_needed, "gene_perturbation_resolved",
      ifelse(selected_ok & !review_needed, "auto_selected", "manual_review")
    )
  ))

  review <- final[final$normalization_status == "manual_review", , drop = FALSE]

  phenomap_write_csv(studies, file.path(output_dir, "study_meta_index.csv"))
  phenomap_write_csv(candidates, file.path(output_dir, "phenotype_principal_candidates.csv"))
  phenomap_write_csv(ontology_candidates, file.path(output_dir, "phenotype_ols_candidates.csv"))
  phenomap_write_csv(selections, file.path(output_dir, "phenotype_final_selection.csv"))
  phenomap_write_csv(review, file.path(output_dir, "phenotype_manual_review.csv"))
  phenomap_write_csv(final, file.path(output_dir, "phenotype_normalization_all.csv"))

  excluded <- final[final$normalization_status == "non_human_excluded", , drop = FALSE]
  excluded <- excluded[order(!excluded$organism_check_needed, excluded$study_id), , drop = FALSE]
  message("Excluded as non-human: ", nrow(excluded),
          " (", sum(excluded$organism_check_needed, na.rm = TRUE),
          " flagged organism_check_needed -- listed first in excluded_non_human.csv).")
  excluded_cols <- intersect(
    c("study_id", "organism_check_needed", "study_title", "organism", "organism_scope",
      "organism_confidence", "organism_basis", "principal_phenotype", "phenotype_type",
      "source_database"),
    names(excluded)
  )
  phenomap_write_csv(excluded[, excluded_cols, drop = FALSE],
                     file.path(output_dir, "excluded_non_human.csv"))

  message(
    "Done. normalization_status counts:\n",
    paste(utils::capture.output(print(table(final$normalization_status))), collapse = "\n")
  )
  message(
    "phenotype_type counts:\n",
    paste(utils::capture.output(print(table(final$phenotype_type, useNA = "ifany"))), collapse = "\n")
  )
  message("Wrote outputs to ", output_dir)
  message("Next: Rscript 1_code/0_prepare_raw/03_canonicalize_disease_to_mondo.R --phenotype_dir=", output_dir)

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
  args <- parse_final_pheno_args()
  normalize_final_study_phenotypes(
    input_csv = args$input_csv,
    output_dir = args$output_dir,
    database = args$database,
    model = args$model,
    base_url = args$base_url,
    ols_base_url = args$ols_base_url,
    ontology_rows = args$ontology_rows,
    limit = args$limit,
    sleep_seconds = args$sleep_seconds,
    workers = args$workers
  )
}
