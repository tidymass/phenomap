# Canonicalize disease-type phenotype IDs to MONDO via MONDO's own published
# cross-references, instead of leaving them on whatever ontology source
# happened to win the per-study GPT selection in 01_normalize_study_phenotype.R.
#
# Why this exists (see phenomap_phenotype_taxonomy.md for the full writeup):
# the same real disease concept was ending up on different ontology sources
# in different studies (e.g. one study -> MESH:D000067877 "Autism Spectrum
# Disorder", another study -> MONDO:0005258 "autism spectrum disorder"),
# which produced duplicate Phenotype nodes downstream. A meaningful share of
# the disease-type studies that did NOT select a MONDO ID already had a
# MONDO candidate sitting in their own search results (mondo_ids column) --
# this script's job is to check whether that MONDO candidate is officially
# the same concept (via MONDO's own cross-reference annotations) and, if so,
# adopt it.
#
# Method: for every disease-type row whose final_ontology_id is NOT a MONDO
# ID, look at the MONDO candidates already retrieved for that study during
# 01_normalize_study_phenotype.R (phenotype_ols_candidates.csv), fetch each
# candidate's official cross-references from OLS4, and check whether the
# study's currently-selected ID appears among them. If yes, replace
# final_ontology_id/final_label with the MONDO one. If no MONDO candidate has
# a matching xref (or no MONDO candidate exists at all for that study), the
# row is left unchanged -- this is the correct, honest outcome, not a gap to
# patch (see phenomap_phenotype_taxonomy.md).
#
# This script does NOT go through GPT. It is a deterministic, auditable
# lookup against MONDO's own maintained mapping data, matching the approach
# described in the Monarch Initiative 2024 paper's "Entity mapping and
# merging" section (SSSOM-based canonicalization via Mondo, not per-instance
# LLM judgment).
#
# Verified: get_mondo_term_xrefs() and the overall matching logic were
# confirmed empirically against the 2026-08-19 delivery (e.g. ST001709 ->
# MONDO:0100096 "COVID-19" correctly recovered via cross-reference). Both
# candidate JSON field shapes below (`obo_xref` and
# `annotation.database_cross_reference`) are kept since OLS4's response shape
# differs by ontology/version.
#
# Caching: every MONDO term's cross-reference list is cached to disk (keyed
# by its OLS IRI, deduplicated across every study and every disease in the
# whole run -- a MONDO term is the same term everywhere it shows up) at
# <phenotype_dir>/mondo_xref_cache.rds. Re-running after new studies are
# merged in only fetches xrefs for MONDO terms never looked up before.
#
# Usage:
#   Rscript 1_code/0_prepare_raw/03_canonicalize_disease_to_mondo.R \
#     --phenotype_dir=2_data/raw/delivery_20260819/phenotype_normalization_mw
#   Rscript 1_code/0_prepare_raw/03_canonicalize_disease_to_mondo.R \
#     --phenotype_dir=2_data/raw/delivery_20260819/phenotype_normalization_ml --workers=8

source(file.path("1_code", "00_phenomap_helpers.R"))

parse_canonicalize_args <- function() {
  raw <- commandArgs(trailingOnly = TRUE)
  args <- list(
    phenotype_dir = NA_character_,
    ols_base_url = "https://www.ebi.ac.uk/ols4/api",
    overwrite = TRUE,
    sleep_seconds = 0.1,
    workers = max(1L, parallel::detectCores(logical = FALSE) - 1L)
  )
  for (arg in raw) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% names(args)) args[[key]] <- value
  }

  # No default phenotype_dir -- see 01_normalize_study_phenotype.R's arg
  # parser for why a dated delivery folder should never be a hardcoded
  # default.
  if (is.na(args$phenotype_dir) || !nzchar(args$phenotype_dir)) {
    stop("--phenotype_dir is required, e.g. --phenotype_dir=2_data/raw/<delivery>/phenotype_normalization_mw")
  }

  args$overwrite <- as.logical(args$overwrite)
  if (is.na(args$overwrite)) args$overwrite <- TRUE
  args$sleep_seconds <- suppressWarnings(as.numeric(args$sleep_seconds))
  if (is.na(args$sleep_seconds) || args$sleep_seconds < 0) args$sleep_seconds <- 0.1
  args$workers <- suppressWarnings(as.integer(args$workers))
  if (is.na(args$workers) || args$workers < 1L) args$workers <- 1L
  args
}

normalize_xref_id <- function(x) {
  # Cross-reference values from OLS/MONDO show up in inconsistent casing and
  # separators (e.g. "MESH:D000067877", "mesh:D000067877", "MeSH_D000067877").
  # Normalize to "<UPPER_PREFIX>:<VALUE>" so comparisons are robust.
  x <- phenomap_clean_scalar(x)
  if (is.na(x)) return(NA_character_)
  x <- gsub("_", ":", x, fixed = TRUE)
  parts <- strsplit(x, ":", fixed = TRUE)[[1]]
  if (length(parts) < 2) return(toupper(x))
  paste0(toupper(parts[[1]]), ":", paste(parts[-1], collapse = ":"))
}

# Fetch a MONDO term's own cross-references from OLS4, given its IRI.
# Returns a character vector of normalized "PREFIX:VALUE" xref IDs.
get_mondo_term_xrefs <- function(iri, ols_base_url = "https://www.ebi.ac.uk/ols4/api") {
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required.")
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.")
  iri <- phenomap_clean_scalar(iri)
  if (is.na(iri)) return(character(0))

  resp <- tryCatch(
    httr::GET(
      paste0(sub("/+$", "", ols_base_url), "/terms"),
      query = list(iri = iri),
      httr::timeout(60)
    ),
    error = function(e) e
  )
  if (inherits(resp, "error") || httr::status_code(resp) >= 400) return(character(0))

  payload <- tryCatch(
    jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"), simplifyVector = FALSE),
    error = function(e) NULL
  )
  terms <- payload$`_embedded`$terms
  if (is.null(terms) || length(terms) == 0) return(character(0))
  term <- terms[[1]]

  # Shape A: obo_xref as a structured list of {database, id}.
  xrefs_a <- character(0)
  if (!is.null(term$obo_xref)) {
    xrefs_a <- vapply(term$obo_xref, function(x) {
      db <- phenomap_clean_scalar(x$database)
      id <- phenomap_clean_scalar(x$id)
      if (is.na(db) || is.na(id)) return(NA_character_)
      paste0(db, ":", id)
    }, character(1))
  }

  # Shape B: annotation$database_cross_reference as a flat string list.
  xrefs_b <- character(0)
  if (!is.null(term$annotation) && !is.null(term$annotation$database_cross_reference)) {
    xrefs_b <- vapply(term$annotation$database_cross_reference, phenomap_clean_scalar, character(1))
  }

  xrefs <- unique(c(xrefs_a, xrefs_b))
  xrefs <- xrefs[!is.na(xrefs)]
  vapply(xrefs, normalize_xref_id, character(1))
}

canonicalize_disease_to_mondo <- function(phenotype_dir,
                                          ols_base_url = "https://www.ebi.ac.uk/ols4/api",
                                          overwrite = TRUE,
                                          sleep_seconds = 0.1,
                                          workers = 1L) {
  selection_path <- file.path(phenotype_dir, "phenotype_final_selection.csv")
  candidates_path <- file.path(phenotype_dir, "phenotype_ols_candidates.csv")
  if (!file.exists(selection_path)) stop("Missing file: ", selection_path)
  if (!file.exists(candidates_path)) stop("Missing file: ", candidates_path)

  selections <- utils::read.csv(selection_path, stringsAsFactors = FALSE, check.names = FALSE)
  ols_candidates <- utils::read.csv(candidates_path, stringsAsFactors = FALSE, check.names = FALSE)

  mondo_candidates <- ols_candidates[
    tolower(ols_candidates$ontology) == "mondo" &
      !is.na(ols_candidates$ontology_id) & nzchar(ols_candidates$ontology_id) &
      !is.na(ols_candidates$ontology_iri) & nzchar(ols_candidates$ontology_iri),
    ,
    drop = FALSE
  ]

  target_rows <- which(
    selections$final_phenotype_type == "disease" &
      !is.na(selections$final_ontology_id) & nzchar(selections$final_ontology_id) &
      !startsWith(toupper(selections$final_ontology_id), "MONDO")
  )

  selections$mapping_method <- ifelse(
    seq_len(nrow(selections)) %in% target_rows, "unresolved", NA_character_
  )
  selections$mondo_canonical_id <- NA_character_
  selections$mondo_canonical_label <- NA_character_

  message("Disease-type rows not already on MONDO: ", length(target_rows))

  # ---- fetch every distinct MONDO IRI's cross-references once (cached, parallel) ----
  # Deduplicated across ALL target rows at once (not per-study): the same
  # MONDO term (e.g. MONDO:0005258 "autism spectrum disorder") can be a
  # candidate for many different studies, and is the same term everywhere,
  # so it only ever needs fetching once per run -- and, via the persisted
  # cache, only once ever.
  target_study_ids <- unique(selections$study_id[target_rows])
  relevant_mondo <- mondo_candidates[mondo_candidates$study_id %in% target_study_ids, , drop = FALSE]
  relevant_mondo <- relevant_mondo[!duplicated(relevant_mondo$ontology_iri), , drop = FALSE]

  xref_cache_path <- file.path(phenotype_dir, "mondo_xref_cache.rds")
  xref_cache <- phenomap_load_cache_store(xref_cache_path)

  iri_items <- as.list(relevant_mondo$ontology_iri)
  xref_results <- phenomap_cache_map(
    items = iri_items,
    key_fn = function(iri) phenomap_cache_key("mondo_xref", iri),
    compute_fn = function(iri) {
      if (sleep_seconds > 0) Sys.sleep(sleep_seconds)
      get_mondo_term_xrefs(iri, ols_base_url = ols_base_url)
    },
    store = xref_cache,
    workers = workers,
    label = "MONDO cross-reference lookup"
  )
  phenomap_save_cache_store(xref_cache, xref_cache_path)
  xrefs_by_iri <- setNames(xref_results, relevant_mondo$ontology_iri)

  # ---- reassemble: does each target row's currently-selected ID appear in
  #      any of its own MONDO candidates' cross-references? ----
  for (i in target_rows) {
    study_id <- selections$study_id[[i]]
    current_id <- normalize_xref_id(selections$final_ontology_id[[i]])
    study_mondo <- mondo_candidates[mondo_candidates$study_id == study_id, , drop = FALSE]

    if (nrow(study_mondo) == 0) {
      selections$mapping_method[[i]] <- "no_mondo_candidate"
      next
    }

    study_mondo <- study_mondo[!duplicated(study_mondo$ontology_id), , drop = FALSE]
    matched <- FALSE

    for (j in seq_len(nrow(study_mondo))) {
      mondo_id <- study_mondo$ontology_id[[j]]
      mondo_iri <- study_mondo$ontology_iri[[j]]
      mondo_label <- study_mondo$ontology_label[[j]]

      xrefs <- xrefs_by_iri[[mondo_iri]]
      if (is.null(xrefs)) xrefs <- character(0)

      if (current_id %in% xrefs) {
        selections$final_ontology_id[[i]] <- mondo_id
        selections$final_label[[i]] <- mondo_label
        selections$final_ontology[[i]] <- "mondo"
        selections$mondo_canonical_id[[i]] <- mondo_id
        selections$mondo_canonical_label[[i]] <- mondo_label
        selections$mapping_method[[i]] <- "mondo_xref_canonicalized"
        matched <- TRUE
        break
      }
    }

    if (!matched) selections$mapping_method[[i]] <- "no_matching_mondo_xref"
  }

  summary_counts <- table(selections$mapping_method[target_rows], useNA = "ifany")
  message("Canonicalization outcome counts:")
  print(summary_counts)

  out_path <- if (isTRUE(overwrite)) selection_path else sub("\\.csv$", "_mondo_canonicalized.csv", selection_path)
  phenomap_write_csv(selections, out_path)
  message("Wrote ", out_path)

  # Always also write an audit-friendly report of just the rows this script
  # touched (changed or attempted), regardless of --overwrite, so a reviewer
  # doesn't have to diff the entire file to see what happened.
  report <- selections[target_rows, c(
    "study_id", "final_label", "final_ontology_id", "mapping_method",
    "mondo_canonical_id", "mondo_canonical_label"
  ), drop = FALSE]
  report_path <- file.path(phenotype_dir, "disease_mondo_canonicalization_report.csv")
  phenomap_write_csv(report, report_path)
  message("Wrote ", report_path)

  invisible(selections)
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- parse_canonicalize_args()
  canonicalize_disease_to_mondo(
    phenotype_dir = args$phenotype_dir,
    ols_base_url = args$ols_base_url,
    overwrite = args$overwrite,
    sleep_seconds = args$sleep_seconds,
    workers = args$workers
  )
}
