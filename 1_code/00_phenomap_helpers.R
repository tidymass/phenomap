# Shared helpers for PhenoMAP entity table export.
# These helpers are intentionally lightweight so each entity script can be run
# independently with Rscript.

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

phenomap_parse_args <- function(default_output_dir = file.path("2_data", "tidy_entity")) {
  args <- commandArgs(trailingOnly = TRUE)
  out <- list(
    case_root = file.path("..", "featuremap_case", "2_data", "case_metabolights"),
    # PhenoMAP now integrates two source databases (Metabolomics Workbench =
    # "mw", MetaboLights = "ml") in a single run. Scripts that need to read
    # study folders from both databases at once (the 1_tidy_entity /
    # 2_tidy_relationship scripts that build combined node/edge tables) take
    # one case_root per database instead of a single case_root, so nothing
    # has to be merged on disk beforehand. Scripts that only ever look at one
    # database at a time (the 0_prepare_raw scripts) still use the plain
    # case_root above and are simply invoked once per database with
    # different --case_root/--output_dir values. These two keys default to
    # "" and are simply unused by scripts that don't reference them.
    case_root_mw = "",
    case_root_ml = "",
    repository_mw = "Metabolomics Workbench",
    repository_ml = "MetaboLights",
    output_dir = default_output_dir,
    workers = max(1L, parallel::detectCores(logical = FALSE) - 1L),
    use_llm = TRUE,
    model = "gpt-4.1-mini",
    base_url = "https://api.openai.com/v1",
    overwrite = TRUE
  )
  if (length(args) == 0) return(out)

  for (arg in args) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% names(out)) out[[key]] <- value
  }
  out$overwrite <- as.logical(out$overwrite)
  out$use_llm <- as.logical(out$use_llm)
  if (is.na(out$use_llm)) out$use_llm <- TRUE
  out$workers <- suppressWarnings(as.integer(out$workers))
  if (is.na(out$workers) || out$workers < 1L) out$workers <- 1L
  out
}

phenomap_clean_scalar <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0) return(default)
  x <- as.character(x[[1]])
  x <- trimws(x)
  if (!nzchar(x) || toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")) {
    return(default)
  }
  x
}

# Vectorized counterpart of phenomap_clean_scalar() -- trims a whole
# character column and blanks out any element that's empty or one of the
# usual "missing" string spellings ("NA"/"NULL"/"NAN"/"<NA>", case-
# insensitive). Used by every 1_tidy_entity script that reads a raw CSV/xlsx
# column straight from upstream output (phenotype_final_selection.csv,
# phenotype_manual_short.xlsx, featuremap MRN node attributes, ...).
phenomap_clean_vec <- function(x) {
  x <- as.character(x)
  x <- trimws(x)
  x[!nzchar(x) | toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")] <- NA_character_
  x
}

# Reads one database's phenotype_final_selection.csv and overlays any
# phenotype_manual_short.xlsx rows by study_id (manual review always wins --
# see 1_tidy_entity/01_tidy_phenotype_entity.R's header comment for why the
# two databases each keep their own manual_short.xlsx rather than a merged
# one). Returns just `keep` columns, one row per study_id. Both
# 03_tidy_study_entity.R and 01_tidy_phenotype_entity.R build the Study/
# Phenotype node tables from the exact same automatic-vs-manual merge, so
# that logic lives in exactly one place instead of being copy-pasted twice.
phenomap_read_phenotype_overrides <- function(phenotype_dir, keep) {
  final <- utils::read.csv(
    file.path(phenotype_dir, "phenotype_final_selection.csv"),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  manual <- as.data.frame(readxl::read_excel(file.path(phenotype_dir, "phenotype_manual_short.xlsx")))

  for (col in setdiff(keep, names(final))) final[[col]] <- NA_character_
  for (col in setdiff(keep, names(manual))) manual[[col]] <- NA_character_
  final <- final[, keep, drop = FALSE]
  manual <- manual[, keep, drop = FALSE]

  rbind(final[!final$study_id %in% manual$study_id, ], manual)
}

phenomap_collapse <- function(x, sep = "; ") {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  x <- unlist(x, recursive = TRUE, use.names = FALSE)
  x <- trimws(as.character(x))
  x <- x[nzchar(x) & !is.na(x) & !toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")]
  if (length(x) == 0) return(NA_character_)
  paste(unique(x), collapse = sep)
}

phenomap_json_value <- function(x, name, collapse = TRUE) {
  value <- x[[name]]
  if (is.null(value)) return(NA_character_)
  if (isTRUE(collapse)) phenomap_collapse(value) else value
}

phenomap_read_json <- function(path) {
  if (!file.exists(path)) return(NULL)
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("Package 'jsonlite' is required to read study_meta.json.")
  }
  jsonlite::fromJSON(path, simplifyVector = FALSE)
}

phenomap_case_dirs <- function(case_root, require_meta = FALSE, require_res = FALSE,
                               require_res_sig = FALSE, case_control_only = FALSE,
                               exclude_report_path = NULL) {
  if (!dir.exists(case_root)) stop("case_root does not exist: ", case_root)
  dirs <- list.dirs(case_root, recursive = FALSE, full.names = TRUE)
  if (isTRUE(require_meta) || isTRUE(case_control_only)) {
    dirs <- dirs[file.exists(file.path(dirs, "study_meta.json"))]
  }
  if (isTRUE(require_res)) {
    dirs <- dirs[file.exists(file.path(dirs, "anno_result", "res.rda"))]
  }
  if (isTRUE(require_res_sig)) {
    dirs <- dirs[file.exists(file.path(dirs, "anno_result", "res_sig.rda"))]
  }
  if (isTRUE(case_control_only)) {
    dirs <- phenomap_filter_case_control_dirs(dirs, exclude_report_path = exclude_report_path)
  }
  sort(dirs)
}

# PhenoMAP is currently scoped to case-control studies only (continuous-
# variable studies will be added in a later delivery). This checks each
# study's design_type -- tolerating both the old nested study_meta.json shape
# (`study_design.design_type`) and the new flat shape (`design_type` at the
# top level, used by the 2026-08-19 delivery for both mw and ml) -- and
# drops anything that isn't "binary_case_control". Excluded studies are never
# silently dropped: if exclude_report_path is given, they're written out so
# it's visible what got excluded and why (this matters once continuous-
# variable studies start showing up in future deliveries).
phenomap_filter_case_control_dirs <- function(case_dirs, exclude_report_path = NULL) {
  if (length(case_dirs) == 0) return(case_dirs)

  keep <- logical(length(case_dirs))
  excluded_rows <- vector("list", length(case_dirs))

  for (i in seq_along(case_dirs)) {
    meta <- phenomap_read_json(file.path(case_dirs[[i]], "study_meta.json"))
    design_type <- phenomap_clean_scalar(meta$study_design$design_type %||% meta$design_type)
    is_case_control <- !is.na(design_type) && identical(design_type, "binary_case_control")
    keep[[i]] <- is_case_control
    if (!is_case_control) {
      excluded_rows[[i]] <- data.frame(
        case_dir = case_dirs[[i]],
        study_id = phenomap_clean_scalar(meta$study_id, basename(case_dirs[[i]])),
        design_type = design_type,
        stringsAsFactors = FALSE
      )
    }
  }

  excluded_rows <- excluded_rows[!vapply(excluded_rows, is.null, logical(1))]
  if (length(excluded_rows) > 0) {
    excluded <- do.call(rbind, excluded_rows)
    message(
      "Excluding ", nrow(excluded), " non-case-control (or design_type-less) ",
      "stud", if (nrow(excluded) == 1) "y" else "ies", " from ", basename(dirname(case_dirs[[1]] %||% "."))
    )
    if (!is.null(exclude_report_path)) {
      phenomap_write_csv(excluded, exclude_report_path)
      message("Wrote exclusion report: ", exclude_report_path)
    }
  }

  case_dirs[keep]
}

phenomap_case_id <- function(case_dir, meta = NULL) {
  phenomap_clean_scalar(meta$study_id %||% basename(case_dir), basename(case_dir))
}

# Returns the first argument that cleans to a non-NA scalar. Note this is NOT
# the same as `%||%`: `%||%` only falls through on NULL/length-0, but
# phenomap_clean_scalar() turns a missing JSON field into NA_character_ (not
# NULL), so a chain like `study_design$foo %||% meta$foo` would never reach
# the fallback once the first field is merely NA. Use this instead whenever
# the fallback should trigger on NA too.
phenomap_coalesce_scalar <- function(...) {
  for (v in list(...)) {
    v <- phenomap_clean_scalar(v)
    if (!is.na(v)) return(v)
  }
  NA_character_
}

# study_meta.json has shipped in two incompatible shapes across deliveries:
#   - workbench_20260629 (old): design/instrument fields nested under
#     `study_design` / `instrument` objects (e.g. study_design$design_type,
#     instrument$chromatography_instrument).
#   - delivery_20260819 (current, both mw and ml): the same information but
#     flattened to the top level (design_type, case_label, control_label,
#     biospecimen, column_type, column_notes, polarities, ...), and some old
#     fields (ms2_supported, instrument$ms_instrument_name) have no
#     equivalent at all.
# This is the single place that knows about both shapes, so every script
# that reads study_meta.json goes through it instead of re-deriving its own
# fallback chain (and silently drifting out of sync with the others).
phenomap_read_study_meta_row <- function(meta) {
  study_design <- meta$study_design %||% list()
  instrument <- meta$instrument %||% list()

  list(
    study_title = phenomap_coalesce_scalar(meta$study_title, meta$title),
    study_summary = phenomap_coalesce_scalar(meta$study_summary, meta$description),
    design_type = phenomap_coalesce_scalar(study_design$design_type, meta$design_type),
    case_label = phenomap_coalesce_scalar(study_design$case, meta$case_label),
    control_label = phenomap_coalesce_scalar(study_design$control, meta$control_label),
    study_type_raw = phenomap_coalesce_scalar(study_design$study_type_raw, meta$analysis_type),
    n_samples_analyzed = suppressWarnings(as.integer(
      phenomap_coalesce_scalar(study_design$n_samples_analyzed, meta$n_samples)
    )),
    biospecimen = phenomap_coalesce_scalar(study_design$biospecimen, meta$biospecimen),
    publication = phenomap_clean_scalar(meta$publication),
    publication_doi = phenomap_clean_scalar(meta$publication_doi),
    ms2_supported = isTRUE(meta$ms2_supported),
    # "_type" fields are short/categorical (used for the GPT prompt);
    # "_display" fields prefer the more descriptive instrument-level value
    # and are meant for the Study node's human-readable columns.
    chromatography_type = phenomap_coalesce_scalar(instrument$chromatography_type, meta$column_type),
    chromatography_display = phenomap_coalesce_scalar(
      instrument$chromatography_instrument, meta$column_notes,
      instrument$chromatography_type, meta$column_type
    ),
    ms_instrument_type = phenomap_coalesce_scalar(instrument$ms_instrument_type, meta$analysis_type),
    ms_instrument_display = phenomap_coalesce_scalar(instrument$ms_instrument_name, meta$analysis_type),
    ion_mode = phenomap_coalesce_scalar(instrument$ion_mode, phenomap_collapse(meta$polarities))
  )
}

phenomap_load_res <- function(case_dir) {
  path <- file.path(case_dir, "anno_result", "res.rda")
  if (!file.exists(path)) return(NULL)
  env <- new.env(parent = emptyenv())
  object_names <- load(path, envir = env)

  if ("res_fast" %in% object_names) return(env$res_fast)
  if ("res" %in% object_names) return(env$res)

  for (nm in object_names) {
    obj <- env[[nm]]
    if (!is.null(obj$object_type) && identical(obj$object_type, "featuremap_result")) {
      return(obj)
    }
  }
  env[[object_names[[1]]]]
}

# Loads a study's module-detection result (anno_result/res_sig.rda), the
# input every module/metabolite-module/module-module relationship script
# needs. Used identically by 1_tidy_entity/04_tidy_module_entity.R and
# 2_tidy_relationship/02_tidy_metabolite_module_relationship.R -- was
# copy-pasted verbatim in both before being promoted here.
phenomap_load_res_sig <- function(case_dir) {
  path <- file.path(case_dir, "anno_result", "res_sig.rda")
  if (!file.exists(path)) return(NULL)
  env <- new.env(parent = emptyenv())
  object_names <- load(path, envir = env)
  if ("res_sig" %in% object_names) return(env$res_sig)

  for (nm in object_names) {
    obj <- env[[nm]]
    if (!is.null(obj$object_type) && identical(obj$object_type, "featuremap_result")) {
      return(obj)
    }
  }
  env[[object_names[[1]]]]
}

# Vectorized "drop anything empty/missing" filter -- unlike
# phenomap_clean_vec() (which keeps the vector's length and blanks out
# missing entries to NA), this one returns only the surviving elements, which
# is what set-like operations (Jaccard overlap, module ID lists, ...) need.
# Was independently duplicated as a local `drop_empty()` in
# 1_tidy_entity/04_tidy_module_entity.R and as `phenomap_drop_empty()` in
# 2_tidy_relationship/00_relationship_helpers.R.
phenomap_drop_empty <- function(x) {
  if (is.null(x) || length(x) == 0) return(character(0))
  x <- trimws(as.character(x))
  x[!is.na(x) & nzchar(x) & !toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")]
}

# Splits a semicolon-collapsed ID/name list column back into a de-duplicated
# character vector, dropping empties along the way. Was independently
# duplicated as a local `split_ids()` in both
# 1_tidy_entity/04_tidy_module_entity.R and
# 2_tidy_relationship/02_tidy_metabolite_module_relationship.R.
phenomap_split_ids <- function(x) {
  ids <- phenomap_drop_empty(x)
  if (length(ids) == 0) return(character(0))
  ids <- phenomap_drop_empty(unlist(strsplit(ids, ";", fixed = TRUE), use.names = FALSE))
  unique(ids)
}

phenomap_safe_df <- function(x) {
  if (is.null(x) || !is.data.frame(x)) return(data.frame())
  as.data.frame(x, stringsAsFactors = FALSE)
}

phenomap_col <- function(df, name, default = NA) {
  if (!is.data.frame(df) || !name %in% colnames(df)) {
    n <- max(1L, nrow(df))
    if (length(default) == n) return(default)
    if (length(default) == 1L) return(rep(default, n))
    return(rep(default[[1]], n))
  }
  df[[name]]
}

phenomap_make_study_url <- function(study_id, repository = "MetaboLights") {
  if (is.na(study_id) || !nzchar(study_id)) return(NA_character_)
  repository_key <- tolower(phenomap_clean_scalar(repository, ""))
  if (repository_key %in% c("metabolights")) {
    return(paste0("https://www.ebi.ac.uk/metabolights/", study_id))
  }
  if (repository_key %in% c("workbench", "metabolomics workbench", "metabolomics_workbench")) {
    return(paste0("https://www.metabolomicsworkbench.org/data/DRCCMetadata.php?Mode=Study&StudyID=", study_id))
  }
  NA_character_
}

phenomap_normalize_text_id <- function(x) {
  x <- phenomap_clean_scalar(x, "")
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  if (!nzchar(x)) return(NA_character_)
  x
}

phenomap_make_phenotype <- function(meta) {
  phenotype <- phenomap_clean_scalar(meta$phenotype)
  case_label <- phenomap_clean_scalar(meta$case_label)
  control_label <- phenomap_clean_scalar(meta$control_label)
  biospecimen <- phenomap_clean_scalar(meta$biospecimen)

  if (!is.na(phenotype)) {
    return(list(
      phenotype_name = phenotype,
      phenotype_source = "study_meta"
    ))
  }

  if (!is.na(case_label) || !is.na(control_label)) {
    generated <- paste0(
      ifelse(is.na(case_label), "case", case_label),
      " versus ",
      ifelse(is.na(control_label), "control", control_label)
    )
    if (!is.na(biospecimen)) generated <- paste0(generated, ", in ", biospecimen)
    return(list(
      phenotype_name = generated,
      phenotype_source = "generated_from_case_control"
    ))
  }

  list(
    phenotype_name = NA_character_,
    phenotype_source = "missing"
  )
}

phenomap_make_phenotype_id <- function(study_id, phenotype_name) {
  # Pilot behavior: keep phenotype IDs study-specific to avoid false merging
  # before GPT/manual normalization is added.
  suffix <- phenomap_normalize_text_id(phenotype_name)
  if (is.na(suffix)) suffix <- "phenotype"
  paste0(study_id, "__", suffix)
}

phenomap_make_module_id <- function(study_id, module_id) {
  paste0(study_id, "_", phenomap_clean_scalar(module_id, "module"))
}

phenomap_make_metabolite_id <- function(hmdb_id = NA_character_,
                                        kegg_id = NA_character_,
                                        inchikey = NA_character_,
                                        inchi_id = NA_character_,
                                        name = NA_character_) {
  hmdb_id <- phenomap_clean_scalar(hmdb_id)
  kegg_id <- phenomap_clean_scalar(kegg_id)
  inchikey <- phenomap_clean_scalar(inchikey)
  inchi_id <- phenomap_clean_scalar(inchi_id)
  name <- phenomap_clean_scalar(name)

  if (!is.na(inchi_id)) return(inchi_id)
  if (!is.na(inchikey)) return(inchikey)
  if (!is.na(hmdb_id)) return(paste0("HMDB:", hmdb_id))
  if (!is.na(kegg_id)) return(paste0("KEGG:", kegg_id))
  if (!is.na(name)) return(paste0("NAME:", phenomap_normalize_text_id(name)))
  NA_character_
}

phenomap_hmdb_url <- function(hmdb_id) {
  hmdb_id <- phenomap_clean_scalar(hmdb_id)
  if (is.na(hmdb_id)) return(NA_character_)
  paste0("https://hmdb.ca/metabolites/", hmdb_id)
}

phenomap_kegg_url <- function(kegg_id) {
  kegg_id <- phenomap_clean_scalar(kegg_id)
  if (is.na(kegg_id)) return(NA_character_)
  paste0("https://www.kegg.jp/entry/", kegg_id)
}

phenomap_write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(df, path, row.names = FALSE, na = "")
  invisible(path)
}

# Assigns stable, content-keyed Lab_IDs that never change across reruns, even
# as new studies/phenotypes/metabolites/modules get merged in later.
#
# Without this, every 1_tidy_entity script recomputed Lab_ID as
# sprintf(prefix, seq_len(nrow(sorted_df))) after sorting -- so a single new
# entity that happened to sort before an existing one would silently
# renumber every Lab_ID after it on the very next full rebuild, breaking
# anything downstream keyed to a Lab_ID (Neo4j nodes already imported,
# manual annotations, external links, ...).
#
# `keys`: one natural key per row of the CURRENT build -- something that
# identifies "the same real-world entity" across reruns (e.g. a Phenotype's
# dedup_key, a Study's Accession, a Metabolite's INCHI_ID, a Module's
# "<accession>::<module_id>"). NOT the sort order or row position.
# `registry_path`: a small two-column CSV (key, Lab_ID) persisted across runs
# under 2_data/tidy_entity. A key seen before always gets its existing
# Lab_ID back. A key never seen before gets the next unused ID number (max
# ever assigned + 1); when several keys are new in the same run, they're
# handed out numbers in `keys` order, so pass `keys` pre-sorted if a
# specific tie-break among simultaneously-new entities matters to you.
# An ID already handed out for a key that's no longer present in the
# current build is left in the registry untouched (never recycled, never
# deleted) -- so if that entity reappears in a later delivery, it gets its
# old Lab_ID back instead of a new one.
phenomap_assign_stable_ids <- function(keys, prefix, registry_path, width = 6L) {
  registry <- if (file.exists(registry_path)) {
    utils::read.csv(registry_path, stringsAsFactors = FALSE, check.names = FALSE)
  } else {
    data.frame(key = character(0), Lab_ID = character(0), stringsAsFactors = FALSE)
  }

  next_num <- if (nrow(registry) == 0) {
    1L
  } else {
    max(suppressWarnings(as.integer(sub(paste0("^", prefix), "", registry$Lab_ID))), na.rm = TRUE) + 1L
  }

  new_keys <- setdiff(unique(keys), registry$key)
  if (length(new_keys) > 0) {
    new_rows <- data.frame(
      key = new_keys,
      Lab_ID = sprintf(paste0(prefix, "%0", width, "d"), seq(next_num, length.out = length(new_keys))),
      stringsAsFactors = FALSE
    )
    registry <- rbind(registry, new_rows)
    phenomap_write_csv(registry, registry_path)
  }

  unname(setNames(registry$Lab_ID, registry$key)[keys])
}

# Resolves a gene symbol to an NCBI Gene ID via the free, keyless NCBI
# E-utilities API (esearch + esummary). Used for genetic_perturbation-type
# Phenotype nodes in 01_normalize_study_phenotype.R.
#
# STRICTLY human-restricted, on purpose: this KG's Phenotype layer is
# human-phenotype-only by project requirement, even when the underlying
# study is a mouse/rat/other model-organism knockout -- a "Tigar knockout
# mouse" study is recorded as a perturbation of the HUMAN TIGAR gene (the
# model organism is evidence *for* a human-relevant gene effect, not a
# different entity to store). There is deliberately NO fallback to an
# unrestricted-species search: an earlier version of this function fell back
# to matching any organism when the human-restricted search failed, which
# could silently attach a mouse/rat-specific NCBI Gene ID to a node in a
# supposedly human-only layer. Returns NULL only for a confirmed empty
# result (a real HTTP 200 response with no matching gene) -- callers must
# treat that as "could not resolve a human gene ID", not substitute a
# non-human one. A network/rate-limit/parsing failure throws instead (after
# a few retries), so it is left uncached and retried on the next run rather
# than being mistaken for "not found" -- see get_json_with_retry() below.
phenomap_ncbi_gene_lookup <- function(symbol, base_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils") {
  symbol <- phenomap_clean_scalar(symbol)
  if (is.na(symbol)) return(NULL)
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required.")
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.")

  base_url <- sub("/+$", "", base_url)

  # NCBI E-utilities without an API key are rate-limited (3 requests/second
  # per IP); under parallel workers, a burst of simultaneous gene lookups can
  # get a 429/5xx back. That is a TRANSIENT failure, not "this gene has no
  # human entry" -- conflating the two (an earlier version of this function
  # did) silently and permanently mis-cached well-known human genes (SIRT5,
  # AR, PIK3CA, ...) as "no human match", because a rate-limited response and
  # a genuine empty idlist both just returned NULL. Retry a few times with
  # backoff for a transient failure; only a true 200-with-empty-idlist counts
  # as "not found". If retries are exhausted, throw instead of returning
  # NULL, so phenomap_cache_map() leaves this symbol uncached and retries it
  # on the next run rather than caching a false negative forever.
  get_json_with_retry <- function(url, query, max_tries = 4L) {
    for (attempt in seq_len(max_tries)) {
      resp <- tryCatch(
        httr::GET(url, query = query, httr::timeout(15)),
        error = function(e) e
      )
      if (!inherits(resp, "error") && httr::status_code(resp) == 200) {
        parsed <- tryCatch(
          jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"), simplifyVector = FALSE),
          error = function(e) NULL
        )
        if (!is.null(parsed)) return(parsed)
      }
      if (attempt < max_tries) Sys.sleep(2^(attempt - 1))  # 1s, 2s, 4s
    }
    stop("NCBI E-utilities request failed after ", max_tries, " attempts: ", url)
  }

  esearch <- function(term) {
    parsed <- get_json_with_retry(
      paste0(base_url, "/esearch.fcgi"),
      list(db = "gene", term = term, retmode = "json", retmax = 1)
    )
    ids <- parsed$esearchresult$idlist
    if (is.null(ids) || length(ids) == 0) return(NULL)
    phenomap_clean_scalar(ids[[1]])
  }

  esummary <- function(gene_id) {
    parsed <- get_json_with_retry(
      paste0(base_url, "/esummary.fcgi"),
      list(db = "gene", id = gene_id, retmode = "json")
    )
    parsed$result[[as.character(gene_id)]]
  }

  gene_id <- esearch(paste0(symbol, "[sym] AND Homo sapiens[orgn]"))
  if (is.null(gene_id)) return(NULL)

  summary <- esummary(gene_id)
  list(
    gene_id = gene_id,
    official_symbol = phenomap_clean_scalar(summary$name),
    description = phenomap_clean_scalar(summary$description),
    matched_via = "symbol+human"
  )
}

# ---------------------------------------------------------------------------
# Generic content-keyed, disk-persisted cache store.
#
# Every expensive external call anywhere in the pipeline that is a pure
# function of some text/identifier (GPT phenotype extraction, GPT ontology
# selection, EBI OLS ontology search, MONDO cross-reference lookup, NCBI Gene
# lookup, module-text embeddings) should go through this same tiny mechanism,
# so there is exactly one caching pattern in the codebase, not one
# reinvented per script. It is the same shape as the module-text-embedding
# cache in 1_code/2_tidy_relationship/05_tidy_module_module_relationship.R:
# an environment used as an O(1) hash map, persisted with saveRDS/readRDS.
#
# Keys are always built from CONTENT (the exact text sent to the API, plus
# the model/endpoint), never from a row position, Lab_ID, or any other
# processing-order artifact. That is what makes a cache survive across full
# pipeline reruns: when new studies are merged in later, a study/query/term
# whose underlying text is unchanged always reuses its previous result no
# matter how IDs get renumbered, and only genuinely new or edited content
# ever triggers a new (paid) API call.
#
# `phenomap_cache_key()` joins its arguments with the ASCII unit separator
# (chosen because it does not legitimately appear in any of the free text,
# IDs, gene symbols, or ontology labels these caches key on), then hashes the
# joined string with digest::digest() rather than using it directly as the
# store's key. The store is an environment, and an environment binding name
# is still an R symbol under the hood -- R errors ("variable names are
# limited to 10000 bytes") once a key gets long enough, which the ontology
# selection prompt's key (model + the full prompt, including up to 40
# candidates' labels/synonyms/definitions) can exceed for a study with many
# ontology candidates. Hashing keeps every key a fixed, short length
# regardless of how much text produced it, while still being a pure function
# of that same content -- two calls with identical content still hash to the
# same key and share one cached result.
# ---------------------------------------------------------------------------

phenomap_cache_sep <- "␟"

phenomap_cache_key <- function(...) {
  parts <- vapply(list(...), function(x) phenomap_clean_scalar(x, ""), character(1))
  raw <- paste(parts, collapse = phenomap_cache_sep)
  if (!requireNamespace("digest", quietly = TRUE)) stop("Package 'digest' is required.")
  digest::digest(raw, algo = "sha1", serialize = FALSE)
}

phenomap_new_cache_store <- function() new.env(parent = emptyenv())

phenomap_cache_get <- function(store, key) {
  if (exists(key, envir = store, inherits = FALSE)) get(key, envir = store, inherits = FALSE) else NULL
}

phenomap_cache_set <- function(store, key, value) {
  assign(key, value, envir = store)
}

phenomap_load_cache_store <- function(path) {
  store <- phenomap_new_cache_store()
  if (file.exists(path)) {
    on_disk <- tryCatch(readRDS(path), error = function(e) NULL)
    if (is.environment(on_disk)) {
      store <- on_disk
    } else if (is.list(on_disk)) {
      list2env(on_disk, envir = store)
    }
  }
  store
}

phenomap_save_cache_store <- function(store, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  saveRDS(store, path)
  invisible(path)
}

# Run `compute_fn(item)` for every item in `items` whose `key_fn(item)` is
# not already present in `store`, in parallel across `workers` (fork-based
# via parallel::mclapply; falls back to serial lapply on Windows or when
# workers <= 1), merges every newly computed result into `store`, and
# returns ALL results (cached + newly computed, in the same order as
# `items`) as a plain list. This is the one shared shape behind every
# cache-aware external call in 0_prepare_raw: check cache -> parallel-fetch
# only what's missing -> merge into the persistent store -> return
# everything. Callers are responsible for calling phenomap_save_cache_store()
# once after all their cache_map() calls are done (not after each one), so a
# multi-stage script only writes its cache file(s) to disk a single time.
#
# A result for which compute_fn() errored is left uncached, so it is
# retried on the next run instead of being silently treated as a permanent
# negative result.
#
# Every stored entry is wrapped as list(value = ...) before being written to
# `store`, and unwrapped again on read. This is what lets a *legitimate*
# result of NULL (e.g. "this gene symbol has no NCBI Gene match") be cached
# correctly: without the wrapper, a cached NULL and a genuinely-missing key
# would look identical to is.null(), and every "no match" result would be
# uselessly recomputed (re-hitting the network) on every single run.
phenomap_cache_map <- function(items, key_fn, compute_fn, store, workers = 1L, label = "item") {
  n <- length(items)
  if (n == 0) return(list())

  keys <- vapply(items, key_fn, character(1))
  wrapped <- lapply(keys, function(k) phenomap_cache_get(store, k))
  missing_idx <- which(vapply(wrapped, is.null, logical(1)))
  cached <- lapply(wrapped, function(w) if (is.null(w)) NULL else w$value)

  message(
    "  ", label, ": ", n - length(missing_idx), " reused from cache, ",
    length(missing_idx), " to compute."
  )

  if (length(missing_idx) > 0) {
    use_workers <- suppressWarnings(as.integer(workers))
    if (is.na(use_workers) || use_workers < 1L) use_workers <- 1L
    if (.Platform$OS.type != "unix") use_workers <- 1L

    computed <- if (use_workers > 1L) {
      parallel::mclapply(items[missing_idx], function(item) {
        tryCatch(compute_fn(item), error = function(e) e)
      }, mc.cores = use_workers)
    } else {
      lapply(items[missing_idx], function(item) {
        tryCatch(compute_fn(item), error = function(e) e)
      })
    }

    n_failed <- 0L
    for (k in seq_along(missing_idx)) {
      idx <- missing_idx[[k]]
      value <- computed[[k]]
      # mclapply returns a try-error condition object (not the expected
      # value) for any worker that crashed rather than propagating; the
      # tryCatch() above catches the same kind of failure in the serial
      # path too. Either way, leave that entry uncached so it is retried on
      # the next run instead of being cached as a failure.
      if (inherits(value, "try-error") || inherits(value, "error")) {
        n_failed <- n_failed + 1L
        next
      }
      # `cached[[idx]] <- value` would be wrong here: assigning NULL via
      # [[<- deletes the list element instead of setting it to NULL,
      # silently shortening `cached`. `[<-` with a wrapped list(value)
      # preserves the slot (and its NULL) instead.
      cached[idx] <- list(value)
      phenomap_cache_set(store, keys[[idx]], list(value = value))
    }
    if (n_failed > 0) {
      message("  ", label, ": ", n_failed, " failed and were left uncached (will retry next run).")
    }
  }

  cached
}

# ---------------------------------------------------------------------------
# Shared ontology-candidate summarizer.
#
# Used by both 01_normalize_study_phenotype.R (to attach a compact per-study
# ontology-candidate summary onto its own fresh output) and
# 02_add_ontology_ids_to_phenotype_outputs.R (to re-attach/refresh that same
# summary onto an already-written phenotype_normalization_all.csv without
# re-running any GPT/OLS calls). Kept here instead of duplicated in both
# scripts so the two never quietly drift out of sync with each other.
# ---------------------------------------------------------------------------

phenomap_summarize_ontology_candidates_by_study <- function(ontology_candidates, max_per_ontology = 10L) {
  if (!is.data.frame(ontology_candidates) || nrow(ontology_candidates) == 0) {
    return(data.frame(study_id = character(0), stringsAsFactors = FALSE))
  }

  ontology_candidates$id_source <- tolower(sub(":.*$", "", ontology_candidates$ontology_id))
  ontology_candidates$id_source <- gsub("[^a-z0-9]+", "_", ontology_candidates$id_source)
  source_order <- c(
    "mondo", "efo", "mesh", "hp",
    sort(setdiff(unique(ontology_candidates$id_source), c("mondo", "efo", "mesh", "hp")))
  )
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

phenomap_try_load_featuremap_resource <- function(name) {
  # Load cached featuremap resources when available. If the package/resource
  # is not installed or not cached, return NULL and keep empty fields.
  loader <- NULL
  if (requireNamespace("featuremap", quietly = TRUE)) {
    loader <- tryCatch(getFromNamespace("featuremap_load_resource", "featuremap"),
                       error = function(e) NULL)
  }

  if (is.null(loader)) {
    featuremap_dir <- normalizePath(file.path("..", "featuremap"), mustWork = FALSE)
    resource_file <- file.path(featuremap_dir, "R", "5_resource_cache.R")
    if (file.exists(resource_file)) {
      env <- new.env(parent = globalenv())
      try(source(resource_file, local = env), silent = TRUE)
      if (exists("featuremap_load_resource", envir = env)) {
        loader <- get("featuremap_load_resource", envir = env)
      }
    }
  }

  if (is.null(loader)) return(NULL)
  tryCatch(loader(name), error = function(e) NULL)
}

phenomap_first_existing_col <- function(df, candidates) {
  hit <- candidates[candidates %in% colnames(df)]
  if (length(hit) == 0) return(NULL)
  hit[[1]]
}

phenomap_add_reference_fields <- function(metabolites) {
  # Best-effort enrichment from featuremap resources. Missing resources or
  # columns are tolerated because pilot runs may happen before references are
  # fully cached.
  hmdb_ref <- phenomap_try_load_featuremap_resource("functional_reference_hmdb")
  kegg_ref <- phenomap_try_load_featuremap_resource("functional_reference_kegg")
  hmdb_pathway <- phenomap_try_load_featuremap_resource("pathway_hmdb")
  kegg_pathway <- phenomap_try_load_featuremap_resource("pathway_kegg")

  add_ref <- function(x, ref, id_col, suffix) {
    if (is.null(ref) || !is.data.frame(ref) || nrow(ref) == 0) return(x)
    ref <- as.data.frame(ref, stringsAsFactors = FALSE)
    if (!"id" %in% colnames(ref) || !id_col %in% colnames(x)) return(x)

    keep <- unique(c(
      "id",
      phenomap_first_existing_col(ref, c("class", "chemical_class", "super_class", "direct_parent")),
      phenomap_first_existing_col(ref, c("pathway", "pathways", "pathway_name")),
      phenomap_first_existing_col(ref, c("origin", "biological_origin", "source"))
    ))
    keep <- keep[!is.na(keep) & keep %in% colnames(ref)]
    ref <- ref[, keep, drop = FALSE]
    ref <- ref[!duplicated(ref$id), , drop = FALSE]

    names(ref) <- ifelse(names(ref) == "id", id_col, paste0(names(ref), ".", suffix))
    merge(x, ref, by = id_col, all.x = TRUE, sort = FALSE)
  }

  metabolites <- add_ref(metabolites, hmdb_ref, "hmdb_id", "hmdb")
  metabolites <- add_ref(metabolites, kegg_ref, "kegg_id", "kegg")

  add_pathway <- function(x, pathway_df, id_col, pathway_col, out_col) {
    if (is.null(pathway_df) || !is.data.frame(pathway_df) || nrow(pathway_df) == 0) return(x)
    pathway_df <- as.data.frame(pathway_df, stringsAsFactors = FALSE)
    if (!id_col %in% colnames(x) ||
        !pathway_col %in% colnames(pathway_df) ||
        !"pathway_name" %in% colnames(pathway_df)) {
      return(x)
    }

    pathway_df <- pathway_df[
      !is.na(pathway_df[[pathway_col]]) &
        nzchar(as.character(pathway_df[[pathway_col]])) &
        !is.na(pathway_df$pathway_name) &
        nzchar(as.character(pathway_df$pathway_name)),
      c(pathway_col, "pathway_name"),
      drop = FALSE
    ]
    names(pathway_df)[names(pathway_df) == pathway_col] <- id_col

    pathway_df <- stats::aggregate(
      pathway_name ~ .,
      data = pathway_df,
      FUN = function(z) paste(unique(as.character(z)), collapse = "; ")
    )
    names(pathway_df)[names(pathway_df) == "pathway_name"] <- out_col
    merge(x, pathway_df, by = id_col, all.x = TRUE, sort = FALSE)
  }

  metabolites <- add_pathway(
    metabolites,
    hmdb_pathway,
    id_col = "hmdb_id",
    pathway_col = "HMDB_ID",
    out_col = "hmdb_pathway.from_pathway_resource"
  )
  metabolites <- add_pathway(
    metabolites,
    kegg_pathway,
    id_col = "kegg_id",
    pathway_col = "KEGG_ID",
    out_col = "kegg_pathway.from_pathway_resource"
  )

  coalesce_cols <- function(df, out, candidates) {
    values <- rep(NA_character_, nrow(df))
    for (nm in candidates) {
      if (nm %in% colnames(df)) {
        cur <- as.character(df[[nm]])
        values[is.na(values) | !nzchar(values)] <- cur[is.na(values) | !nzchar(values)]
      }
    }
    df[[out]] <- values
    df
  }

  metabolites <- coalesce_cols(
    metabolites,
    "hmdb_chemical_class",
    c("class.hmdb", "chemical_class.hmdb", "super_class.hmdb", "direct_parent.hmdb")
  )
  metabolites <- coalesce_cols(
    metabolites,
    "kegg_chemical_class",
    c("class.kegg", "chemical_class.kegg", "super_class.kegg", "direct_parent.kegg")
  )
  metabolites <- coalesce_cols(
    metabolites,
    "hmdb_pathway",
    c("hmdb_pathway.from_pathway_resource",
      "pathway.hmdb", "pathways.hmdb", "pathway_name.hmdb")
  )
  metabolites <- coalesce_cols(
    metabolites,
    "kegg_pathway",
    c("kegg_pathway.from_pathway_resource",
      "pathway.kegg", "pathways.kegg", "pathway_name.kegg")
  )
  metabolites <- coalesce_cols(
    metabolites,
    "origin",
    c("origin.hmdb", "biological_origin.hmdb", "source.hmdb",
      "origin.kegg", "biological_origin.kegg", "source.kegg")
  )

  wanted <- c(
    "metabolite_id", "hmdb_id", "kegg_id", "inchi_id",
    "metabolite_name", "hmdb_chemical_class", "kegg_chemical_class",
    "hmdb_pathway", "kegg_pathway",
    "origin", "hmdb_url", "kegg_url"
  )
  for (nm in wanted) if (!nm %in% colnames(metabolites)) metabolites[[nm]] <- NA_character_
  metabolites[, wanted, drop = FALSE]
}
