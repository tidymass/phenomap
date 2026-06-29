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

phenomap_case_dirs <- function(case_root, require_meta = FALSE, require_res = FALSE) {
  if (!dir.exists(case_root)) stop("case_root does not exist: ", case_root)
  dirs <- list.dirs(case_root, recursive = FALSE, full.names = TRUE)
  if (isTRUE(require_meta)) {
    dirs <- dirs[file.exists(file.path(dirs, "study_meta.json"))]
  }
  if (isTRUE(require_res)) {
    dirs <- dirs[file.exists(file.path(dirs, "anno_result", "res.rda"))]
  }
  sort(dirs)
}

phenomap_case_id <- function(case_dir, meta = NULL) {
  phenomap_clean_scalar(meta$study_id %||% basename(case_dir), basename(case_dir))
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
