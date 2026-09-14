#!/usr/bin/env Rscript

# Build final PhenoMAP tidy nodes/edges from the server-side module outputs.
#
# This script intentionally keeps the final CSV schema compatible with the
# existing phenomap-deploy build. The only intentional schema extension is on
# nodes_module.csv, where multi-group comparison metadata is appended as normal
# properties so the study/module pages can show which baseline comparison each
# module came from.
#
# It does not run FeatureMAP, embeddings, or similarity. It only converts the
# already-prepared natural-key files into final Lab_ID-keyed KG CSVs.

parse_args <- function() {
  args <- list(
    base_dir = "/mnt/hdd1/home/yuting/module_lists_20260911",
    deploy_src = "/mnt/hdd1/home/yuting/phenomap-deploy/src",
    medium_dir = "",
    nodes_dir = "",
    edges_dir = "",
    rawdata_dir = "",
    module_similarity_dir = "",
    stop_on_duplicate_study_phenotype = "1"
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) == 2 && kv[[1]] %in% names(args)) args[[kv[[1]]]] <- kv[[2]]
  }

  if (!nzchar(args$medium_dir)) args$medium_dir <- file.path(args$base_dir, "medium")
  if (!nzchar(args$nodes_dir)) args$nodes_dir <- file.path(args$base_dir, "nodes")
  if (!nzchar(args$edges_dir)) args$edges_dir <- file.path(args$base_dir, "edges")
  if (!nzchar(args$rawdata_dir)) args$rawdata_dir <- file.path(args$base_dir, "rawdata")
  if (!nzchar(args$module_similarity_dir)) {
    args$module_similarity_dir <- file.path(args$base_dir, "module_similarity_final")
  }
  args$stop_on_duplicate_study_phenotype <- parse_bool(args$stop_on_duplicate_study_phenotype)
  args
}

parse_bool <- function(x) {
  x <- tolower(trimws(as.character(x[[1]])))
  x %in% c("1", "true", "t", "yes", "y")
}

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

clean_scalar <- function(x, default = NA_character_) {
  if (is.null(x) || length(x) == 0) return(default)
  x <- as.character(x[[1]])
  x <- gsub("[\r\n]+", " ", x)
  x <- gsub("[[:space:]]+", " ", trimws(x))
  if (!nzchar(x) || toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")) return(default)
  x
}

clean_vec <- function(x) {
  x <- as.character(x)
  x <- gsub("[\r\n]+", " ", x)
  x <- gsub("[[:space:]]+", " ", trimws(x))
  bad <- is.na(x) | !nzchar(x) | toupper(x) %in% c("NA", "NULL", "NAN", "<NA>")
  x[bad] <- NA_character_
  x
}

drop_empty <- function(x) {
  x <- clean_vec(unlist(x, recursive = TRUE, use.names = FALSE))
  x[!is.na(x) & nzchar(x)]
}

split_multi <- function(x) {
  unique(drop_empty(unlist(strsplit(as.character(x), ";", fixed = TRUE), use.names = FALSE)))
}

collapse_values <- function(x, sep = "; ") {
  x <- unique(drop_empty(x))
  if (length(x) == 0) return(NA_character_)
  paste(x, collapse = sep)
}

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(df, path, row.names = FALSE, na = "")
  invisible(path)
}

assign_ordered_ids <- function(n, prefix, width = 6L) {
  sprintf(paste0(prefix, "%0", width, "d"), seq_len(n))
}

sort_key <- function(x) {
  x <- clean_vec(x)
  x[is.na(x)] <- ""
  tolower(x)
}

ols_link <- function(ols_id) {
  ols_id <- clean_vec(ols_id)
  out <- rep(NA_character_, length(ols_id))
  keep <- !is.na(ols_id)
  out[keep] <- paste0("https://www.ebi.ac.uk/ols4/search?q=", utils::URLencode(ols_id[keep], reserved = TRUE))
  out
}

study_url <- function(accession, repository) {
  if (identical(repository, "MetaboLights")) {
    return(paste0("https://www.ebi.ac.uk/metabolights/", accession))
  }
  paste0("https://www.metabolomicsworkbench.org/data/DRCCMetadata.php?Mode=Study&StudyID=", accession)
}

load_deploy_helpers <- function(deploy_src) {
  helper <- file.path(deploy_src, "1_code", "00_phenomap_helpers.R")
  if (file.exists(helper)) {
    tryCatch(source(helper, local = FALSE), error = function(e) {
      warning("Could not source deploy helper; using fallback metadata parser: ", conditionMessage(e))
    })
  }
}

zip_path_for_db <- function(db_key, rawdata_dir) {
  if (identical(db_key, "mw")) {
    return(file.path(rawdata_dir, "out_qwen_eval_mw_anno_20260911.zip"))
  }
  if (identical(db_key, "ml")) {
    return(file.path(rawdata_dir, "out_qwen_eval_ml_anno_20260911.zip"))
  }
  stop("Unknown database key: ", db_key)
}

read_json_from_zip <- function(zip_path, inner_path) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Package 'jsonlite' is required.")
  con <- unz(zip_path, inner_path, open = "rb")
  on.exit(close(con), add = TRUE)
  txt <- paste(readLines(con, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  jsonlite::fromJSON(txt, simplifyVector = FALSE)
}

ms2_annotation_count_from_zip <- function(zip_path, accession) {
  inner_path <- paste0(accession, "/anno_result/annotated_table_ms2.rda")
  con <- unz(zip_path, inner_path, open = "rb")
  on.exit(close(con), add = TRUE)
  tryCatch({
    env <- new.env(parent = emptyenv())
    object_names <- load(con, envir = env)
    row_counts <- vapply(object_names, function(nm) {
      n <- tryCatch(nrow(env[[nm]]), error = function(e) NULL)
      if (is.null(n) || length(n) == 0 || is.na(n)) 0L else as.integer(n)
    }, integer(1))
    if (length(row_counts) == 0) 0L else max(row_counts)
  }, error = function(e) NA_integer_)
}

ms2_supported_for_study <- function(zip_path, accession, meta_flag) {
  count <- ms2_annotation_count_from_zip(zip_path, accession)
  if (!is.na(count)) return(count > 0L)
  isTRUE(meta_flag)
}

fallback_meta_fields <- function(meta) {
  flat <- unlist(meta, recursive = TRUE, use.names = TRUE)
  pick <- function(patterns) {
    for (pat in patterns) {
      hit <- grep(pat, names(flat), ignore.case = TRUE, value = TRUE)
      if (length(hit) > 0) return(clean_scalar(flat[[hit[[1]]]]))
    }
    NA_character_
  }
  list(
    study_title = pick(c("study.*title", "title")),
    study_summary = pick(c("study.*summary", "description", "summary")),
    design_type = pick(c("design.*type", "study.*design")),
    n_samples_analyzed = pick(c("n.*samples.*analyzed", "sample.*size", "samples")),
    biospecimen = pick(c("biospecimen", "sample.*type")),
    chromatography_display = pick(c("chromatography", "column")),
    ms_instrument_display = pick(c("mass.*spectrometry", "instrument")),
    publication_doi = pick(c("doi")),
    ms2_supported = pick(c("ms2.*supported", "ms2"))
  )
}

meta_fields_old_style <- function(meta) {
  if (exists("phenomap_read_study_meta_row", mode = "function")) {
    tryCatch(phenomap_read_study_meta_row(meta), error = function(e) fallback_meta_fields(meta))
  } else {
    fallback_meta_fields(meta)
  }
}

non_generic_title <- function(x) {
  x <- clean_scalar(x)
  !is.na(x) && !tolower(x) %in% c("investigation", "study", "untitled", "na")
}

build_phenotype_nodes <- function(raw_phenotypes, valid_accessions, medium_dir,
                                  stop_on_duplicate_study_phenotype = TRUE) {
  rows <- list()
  removed <- list()
  row_i <- 0L
  rem_i <- 0L

  for (i in seq_len(nrow(raw_phenotypes))) {
    original_ids <- split_multi(raw_phenotypes$Study_ID[[i]])
    kept_ids <- intersect(original_ids, valid_accessions)
    removed_ids <- setdiff(original_ids, kept_ids)

    if (length(removed_ids) > 0) {
      rem_i <- rem_i + 1L
      removed[[rem_i]] <- data.frame(
        Phenotype = raw_phenotypes$Phenotype[[i]],
        Removed_Study_ID = removed_ids,
        stringsAsFactors = FALSE
      )
    }
    if (length(kept_ids) == 0) next

    row_i <- row_i + 1L
    rows[[row_i]] <- data.frame(
      Phenotype = clean_scalar(raw_phenotypes$Phenotype[[i]]),
      Type = clean_scalar(raw_phenotypes$Type[[i]]),
      OLS_ID = clean_scalar(raw_phenotypes$OLS_ID[[i]]),
      OLS_Link = clean_scalar(raw_phenotypes$OLS_Link[[i]], ols_link(raw_phenotypes$OLS_ID[[i]])),
      OLS_Definition = clean_scalar(raw_phenotypes$OLS_Definition[[i]]),
      Study_ID = collapse_values(sort(kept_ids)),
      stringsAsFactors = FALSE,
      check.names = FALSE
    )
  }

  removed_df <- if (length(removed) == 0) data.frame() else do.call(rbind, removed)
  write_csv(removed_df, file.path(medium_dir, "final_removed_study_ids_from_phenotypes.csv"))

  if (length(rows) == 0) stop("No phenotype rows remain after filtering to studies with modules.")
  out <- do.call(rbind, rows)
  dedup_key <- ifelse(is.na(out$OLS_ID) | !nzchar(out$OLS_ID),
                      paste0("name:", sort_key(out$Phenotype)),
                      paste0("id:", out$OLS_ID))
  out <- out[!duplicated(dedup_key), , drop = FALSE]
  out <- out[order(sort_key(out$Phenotype), sort_key(out$OLS_ID)), , drop = FALSE]
  out$Lab_ID <- assign_ordered_ids(nrow(out), "PPH")
  out <- out[, c("Lab_ID", "Phenotype", "Type", "OLS_ID", "OLS_Link", "OLS_Definition", "Study_ID")]

  expanded <- do.call(rbind, lapply(seq_len(nrow(out)), function(i) {
    data.frame(
      Study_Accession = split_multi(out$Study_ID[[i]]),
      Phenotype_ID = out$Lab_ID[[i]],
      Phenotype = out$Phenotype[[i]],
      stringsAsFactors = FALSE
    )
  }))
  dup <- expanded[duplicated(expanded$Study_Accession) | duplicated(expanded$Study_Accession, fromLast = TRUE), , drop = FALSE]
  if (nrow(dup) > 0) {
    dup <- dup[order(dup$Study_Accession, dup$Phenotype_ID), , drop = FALSE]
    write_csv(dup, file.path(medium_dir, "final_duplicate_study_phenotype_assignments.csv"))
    if (isTRUE(stop_on_duplicate_study_phenotype)) {
      stop(
        "Some studies map to more than one phenotype. See ",
        file.path(medium_dir, "final_duplicate_study_phenotype_assignments.csv")
      )
    }
    expanded <- expanded[!duplicated(expanded$Study_Accession), , drop = FALSE]
  }

  list(
    nodes = out,
    study_to_phenotype_id = setNames(expanded$Phenotype_ID, expanded$Study_Accession),
    study_to_phenotype = setNames(expanded$Phenotype, expanded$Study_Accession),
    removed = removed_df
  )
}

build_study_nodes <- function(accessions, module_db_map, descriptions, rawdata_dir,
                              study_to_phenotype_id, study_to_phenotype) {
  desc_by_acc <- split(descriptions, descriptions$study_accession)
  rows <- vector("list", length(accessions))

  for (i in seq_along(accessions)) {
    accession <- accessions[[i]]
    db_key <- module_db_map$Database_Key[match(accession, module_db_map$Study_Accession)]
    repository <- module_db_map$Database[match(accession, module_db_map$Study_Accession)]
    if (is.na(repository) || !nzchar(repository)) {
      repository <- if (identical(db_key, "ml")) "MetaboLights" else "Metabolomics Workbench"
    }

    zip_path <- zip_path_for_db(db_key, rawdata_dir)
    meta <- tryCatch(
      read_json_from_zip(zip_path, paste0(accession, "/study_meta.json")),
      error = function(e) list()
    )
    fields <- meta_fields_old_style(meta)
    ms2_supported <- ms2_supported_for_study(zip_path, accession, fields$ms2_supported)
    desc <- desc_by_acc[[accession]]
    ref_title <- if (!is.null(desc) && nrow(desc) > 0) clean_scalar(desc$title[[1]]) else NA_character_
    title <- if (non_generic_title(ref_title)) ref_title else clean_scalar(fields$study_title, ref_title)
    summary <- if (!is.null(desc) && nrow(desc) > 0) {
      clean_scalar(desc$description_plain[[1]], clean_scalar(fields$study_summary))
    } else {
      clean_scalar(fields$study_summary)
    }

    rows[[i]] <- data.frame(
      Accession = accession,
      Repository = repository,
      Title = title,
      Study_Summary = summary,
      Study_Design = clean_scalar(fields$design_type),
      Sample_Size = clean_scalar(fields$n_samples_analyzed),
      Biospecimen = clean_scalar(fields$biospecimen),
      Chromatography = clean_scalar(fields$chromatography_display),
      Mass_Spectrometry = clean_scalar(fields$ms_instrument_display),
      Publication_DOI = clean_scalar(fields$publication_doi),
      Link = study_url(accession, repository),
      Phenotype = unname(study_to_phenotype[accession]),
      Phenotype_ID = unname(study_to_phenotype_id[accession]),
      MS2_Supported = ms2_supported,
      stringsAsFactors = FALSE,
      check.names = FALSE
    )
  }

  out <- do.call(rbind, rows)
  out <- out[!is.na(out$Phenotype_ID) & nzchar(out$Phenotype_ID), , drop = FALSE]
  out <- out[order(sort_key(out$Title), sort_key(out$Accession)), , drop = FALSE]
  out$Lab_ID <- assign_ordered_ids(nrow(out), "PST")
  out <- out[, c(
    "Lab_ID", "Accession", "Repository", "Title", "Study_Summary", "Study_Design",
    "Sample_Size", "Biospecimen", "Chromatography", "Mass_Spectrometry",
    "Publication_DOI", "Link", "Phenotype", "Phenotype_ID", "MS2_Supported"
  )]
  out
}

build_metabolite_nodes <- function(old_metabolites) {
  old_metabolites$old_Lab_ID <- old_metabolites$Lab_ID
  old_metabolites <- old_metabolites[order(sort_key(old_metabolites$Metabolite_Name), sort_key(old_metabolites$INCHI_ID)), , drop = FALSE]
  old_metabolites$Lab_ID <- assign_ordered_ids(nrow(old_metabolites), "PME")
  old_to_new <- setNames(old_metabolites$Lab_ID, old_metabolites$old_Lab_ID)
  inchi_to_new <- setNames(old_metabolites$Lab_ID, old_metabolites$INCHI_ID)
  old_metabolites$old_Lab_ID <- NULL
  list(nodes = old_metabolites, old_to_new = old_to_new, inchi_to_new = inchi_to_new)
}

translate_id_string <- function(x, id_map) {
  ids <- split_multi(x)
  if (length(ids) == 0) return(NA_character_)
  collapse_values(unname(id_map[ids]))
}

build_module_nodes <- function(module_input, study_id_map, metabolite_id_map) {
  module_input <- module_input[module_input$Study_Accession %in% names(study_id_map), , drop = FALSE]
  module_input$Study_ID <- unname(study_id_map[module_input$Study_Accession])
  module_input$module_id <- module_input$Local_Module_ID %||% module_input$module_id

  for (col in c("anchor_metabolite_ids", "supporting_metabolite_ids", "contextual_metabolite_ids")) {
    if (!col %in% names(module_input)) module_input[[col]] <- NA_character_
    module_input[[col]] <- vapply(module_input[[col]], translate_id_string, character(1), id_map = metabolite_id_map)
  }

  module_input <- module_input[order(
    sort_key(module_input$title),
    sort_key(module_input$functional_summary),
    sort_key(module_input$Study_Accession),
    sort_key(module_input$Comparison_ID),
    sort_key(module_input$module_id)
  ), , drop = FALSE]
  module_input$Lab_ID <- assign_ordered_ids(nrow(module_input), "PMO")

  old_cols <- c(
    "Lab_ID", "Study_ID", "module_id", "annotation_mode", "hypothesis_type",
    "title", "functional_summary", "anchor_metabolites", "anchor_metabolite_ids",
    "supporting_metabolites", "supporting_metabolite_ids",
    "contextual_metabolites", "contextual_metabolite_ids", "class_names",
    "phenotype_relationship", "confidence_label", "rationale", "global_direction",
    "origin_endogenous_frac", "origin_exogenous_frac", "top_kegg_pathways",
    "top_hmdb_pathways", "pubmed_pmids", "hmdb_pathway_ids", "kegg_pathway_ids"
  )
  extra_cols <- c(
    "Module_Key", "Study_Accession", "Result_Scope", "Comparison_ID",
    "Comparison_Kind", "Comparison_Design_Type", "Comparison_Label",
    "Case_Value", "Control_Value", "N_Case", "N_Control", "Phenotype_Term"
  )
  for (col in setdiff(c(old_cols, extra_cols), names(module_input))) {
    module_input[[col]] <- NA_character_
  }
  out <- module_input[, c(old_cols, extra_cols), drop = FALSE]
  list(nodes = out, module_key_to_id = setNames(out$Lab_ID, out$Module_Key))
}

edge_ids <- function(n, prefix) {
  sprintf(paste0(prefix, "%06d"), seq_len(n))
}

build_study_phenotype_edges <- function(studies) {
  out <- data.frame(
    Study_ID = studies$Lab_ID,
    Relationship = "investigated",
    Phenotype_ID = studies$Phenotype_ID,
    stringsAsFactors = FALSE
  )
  out <- out[order(out$Study_ID, out$Phenotype_ID), , drop = FALSE]
  out$Lab_ID <- edge_ids(nrow(out), "STU_PHE_")
  out[, c("Lab_ID", "Study_ID", "Relationship", "Phenotype_ID")]
}

build_module_study_edges <- function(modules) {
  out <- data.frame(
    Module_ID = modules$Lab_ID,
    Relationship = "reported in",
    Study_ID = modules$Study_ID,
    stringsAsFactors = FALSE
  )
  out <- out[!duplicated(out[, c("Module_ID", "Study_ID")]), , drop = FALSE]
  out <- out[order(out$Study_ID, out$Module_ID), , drop = FALSE]
  out$Lab_ID <- edge_ids(nrow(out), "MOD_STU_")
  out[, c("Lab_ID", "Module_ID", "Relationship", "Study_ID")]
}

build_metabolite_module_edges <- function(membership_input, module_key_to_id, inchi_to_metabolite_id, medium_dir) {
  out <- data.frame(
    Metabolite_ID = unname(inchi_to_metabolite_id[membership_input$INCHI_ID]),
    Relationship = "member of",
    Module_ID = unname(module_key_to_id[membership_input$Module_Key]),
    Type = membership_input$Membership_Type,
    INCHI_ID = membership_input$INCHI_ID,
    Module_Key = membership_input$Module_Key,
    stringsAsFactors = FALSE
  )
  unmapped <- out[is.na(out$Metabolite_ID) | !nzchar(out$Metabolite_ID) |
                    is.na(out$Module_ID) | !nzchar(out$Module_ID), , drop = FALSE]
  write_csv(unmapped, file.path(medium_dir, "final_unmapped_metabolite_module_rows.csv"))
  out <- out[!is.na(out$Metabolite_ID) & nzchar(out$Metabolite_ID) &
               !is.na(out$Module_ID) & nzchar(out$Module_ID), , drop = FALSE]

  type_priority <- match(out$Type, c("core", "supporting", "contextual"))
  type_priority[is.na(type_priority)] <- 99L
  out <- out[order(out$Module_ID, out$Metabolite_ID, type_priority), , drop = FALSE]
  out <- out[!duplicated(out[, c("Metabolite_ID", "Module_ID")]), , drop = FALSE]
  type_priority <- match(out$Type, c("core", "supporting", "contextual"))
  type_priority[is.na(type_priority)] <- 99L
  out <- out[order(out$Module_ID, type_priority, out$Metabolite_ID), , drop = FALSE]
  out$Lab_ID <- edge_ids(nrow(out), "MET_MOD_")
  out[, c("Lab_ID", "Metabolite_ID", "Relationship", "Module_ID", "Type")]
}

build_metabolite_metabolite_edges <- function(old_edges, old_metabolite_id_to_new, medium_dir) {
  out <- data.frame(
    Metabolite_ID_1 = unname(old_metabolite_id_to_new[old_edges$Metabolite_ID_1]),
    Relationship = old_edges$Relationship,
    Metabolite_ID_2 = unname(old_metabolite_id_to_new[old_edges$Metabolite_ID_2]),
    stringsAsFactors = FALSE
  )
  unmapped <- out[is.na(out$Metabolite_ID_1) | !nzchar(out$Metabolite_ID_1) |
                    is.na(out$Metabolite_ID_2) | !nzchar(out$Metabolite_ID_2), , drop = FALSE]
  write_csv(unmapped, file.path(medium_dir, "final_unmapped_metabolite_metabolite_rows.csv"))
  out <- out[!is.na(out$Metabolite_ID_1) & nzchar(out$Metabolite_ID_1) &
               !is.na(out$Metabolite_ID_2) & nzchar(out$Metabolite_ID_2), , drop = FALSE]
  a <- pmin(out$Metabolite_ID_1, out$Metabolite_ID_2)
  b <- pmax(out$Metabolite_ID_1, out$Metabolite_ID_2)
  out$Metabolite_ID_1 <- a
  out$Metabolite_ID_2 <- b
  out <- out[!duplicated(out[, c("Metabolite_ID_1", "Metabolite_ID_2")]), , drop = FALSE]
  out <- out[order(out$Metabolite_ID_1, out$Metabolite_ID_2), , drop = FALSE]
  out$Lab_ID <- edge_ids(nrow(out), "MET_MET_")
  out[, c("Lab_ID", "Metabolite_ID_1", "Relationship", "Metabolite_ID_2")]
}

build_module_module_edges <- function(similarity_edges, module_key_to_id, medium_dir) {
  out <- data.frame(
    Module_ID_1 = unname(module_key_to_id[similarity_edges$Module_Key_1]),
    Relationship = similarity_edges$Relationship,
    Module_ID_2 = unname(module_key_to_id[similarity_edges$Module_Key_2]),
    Type = similarity_edges$Type,
    Similarity_Score = similarity_edges$Similarity_Score,
    Similarity_Tier = similarity_edges$Similarity_Tier,
    Biological_Score = similarity_edges$Biological_Score,
    Compositional_Score = similarity_edges$Compositional_Score,
    Cross_Study = similarity_edges$Cross_Study,
    Module_Key_1 = similarity_edges$Module_Key_1,
    Module_Key_2 = similarity_edges$Module_Key_2,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  unmapped <- out[is.na(out$Module_ID_1) | !nzchar(out$Module_ID_1) |
                    is.na(out$Module_ID_2) | !nzchar(out$Module_ID_2), , drop = FALSE]
  write_csv(unmapped, file.path(medium_dir, "final_unmapped_module_module_rows.csv"))
  out <- out[!is.na(out$Module_ID_1) & nzchar(out$Module_ID_1) &
               !is.na(out$Module_ID_2) & nzchar(out$Module_ID_2), , drop = FALSE]
  out <- out[order(-as.numeric(out$Similarity_Score), out$Module_ID_1, out$Module_ID_2), , drop = FALSE]
  out$Lab_ID <- edge_ids(nrow(out), "MOD_MOD_")
  out[, c(
    "Lab_ID", "Module_ID_1", "Relationship", "Module_ID_2", "Type",
    "Similarity_Score", "Similarity_Tier", "Biological_Score",
    "Compositional_Score", "Cross_Study"
  )]
}

validate_endpoints <- function(edges, col, nodes, label) {
  bad <- edges[[col]][is.na(edges[[col]]) | !edges[[col]] %in% nodes$Lab_ID]
  data.frame(
    check = label,
    missing_endpoint_count = length(bad),
    stringsAsFactors = FALSE
  )
}

write_final_reports <- function(args, nodes, edges, missing_study_ids) {
  counts <- data.frame(
    table = c(
      "nodes_study", "nodes_phenotype", "nodes_module", "nodes_metabolite",
      "edges_study_phenotype", "edges_module_study", "edges_metabolite_module",
      "edges_metabolite_metabolite", "edges_module_module"
    ),
    rows = c(
      nrow(nodes$study), nrow(nodes$phenotype), nrow(nodes$module), nrow(nodes$metabolite),
      nrow(edges$study_phenotype), nrow(edges$module_study), nrow(edges$metabolite_module),
      nrow(edges$metabolite_metabolite), nrow(edges$module_module)
    ),
    stringsAsFactors = FALSE
  )
  write_csv(counts, file.path(args$medium_dir, "final_build_counts.csv"))

  endpoint_checks <- rbind(
    validate_endpoints(edges$study_phenotype, "Study_ID", nodes$study, "edges_study_phenotype.Study_ID"),
    validate_endpoints(edges$study_phenotype, "Phenotype_ID", nodes$phenotype, "edges_study_phenotype.Phenotype_ID"),
    validate_endpoints(edges$module_study, "Module_ID", nodes$module, "edges_module_study.Module_ID"),
    validate_endpoints(edges$module_study, "Study_ID", nodes$study, "edges_module_study.Study_ID"),
    validate_endpoints(edges$metabolite_module, "Metabolite_ID", nodes$metabolite, "edges_metabolite_module.Metabolite_ID"),
    validate_endpoints(edges$metabolite_module, "Module_ID", nodes$module, "edges_metabolite_module.Module_ID"),
    validate_endpoints(edges$metabolite_metabolite, "Metabolite_ID_1", nodes$metabolite, "edges_metabolite_metabolite.Metabolite_ID_1"),
    validate_endpoints(edges$metabolite_metabolite, "Metabolite_ID_2", nodes$metabolite, "edges_metabolite_metabolite.Metabolite_ID_2"),
    validate_endpoints(edges$module_module, "Module_ID_1", nodes$module, "edges_module_module.Module_ID_1"),
    validate_endpoints(edges$module_module, "Module_ID_2", nodes$module, "edges_module_module.Module_ID_2")
  )
  write_csv(endpoint_checks, file.path(args$medium_dir, "final_endpoint_validation.csv"))

  if (length(missing_study_ids) > 0) {
    present <- data.frame(
      Study_ID = missing_study_ids,
      in_nodes_study = missing_study_ids %in% nodes$study$Accession,
      in_nodes_phenotype = vapply(missing_study_ids, function(id) {
        any(vapply(nodes$phenotype$Study_ID, function(x) id %in% split_multi(x), logical(1)))
      }, logical(1)),
      stringsAsFactors = FALSE
    )
    write_csv(present, file.path(args$medium_dir, "final_missing_study_exclusion_check.csv"))
  }

  invisible(list(counts = counts, endpoint_checks = endpoint_checks))
}

main <- function() {
  args <- parse_args()
  dir.create(args$medium_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(args$nodes_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(args$edges_dir, recursive = TRUE, showWarnings = FALSE)
  load_deploy_helpers(args$deploy_src)

  old_entity_dir <- file.path(args$deploy_src, "2_data", "tidy_entity")
  old_relationship_dir <- file.path(args$deploy_src, "2_data", "tidy_relationship")

  raw_phenotypes <- read_csv_required(file.path(args$medium_dir, "nodes_phenotype_final.csv"))
  descriptions <- read_csv_required(file.path(args$medium_dir, "study_descriptions_refetched.csv"))
  module_input <- read_csv_required(file.path(args$module_similarity_dir, "nodes_module_similarity_input.csv"))
  membership_input <- read_csv_required(file.path(args$module_similarity_dir, "edges_metabolite_module_similarity_input.csv"))
  similarity_edges <- read_csv_required(file.path(args$module_similarity_dir, "edges_module_module_prelim.csv"))
  old_metabolites <- read_csv_required(file.path(old_entity_dir, "nodes_metabolite.csv"))
  old_metabolite_edges <- read_csv_required(file.path(old_relationship_dir, "edges_metabolite_metabolite.csv"))

  filter_report_path <- file.path(args$module_similarity_dir, "module_similarity_study_filter_report.csv")
  missing_study_ids <- character(0)
  if (file.exists(filter_report_path)) {
    filter_report <- read_csv_required(filter_report_path)
    if (all(c("Study_ID", "retained_for_similarity") %in% names(filter_report))) {
      missing_study_ids <- filter_report$Study_ID[as.character(filter_report$retained_for_similarity) %in% c("FALSE", "False", "false", "0")]
    }
  }

  valid_accessions <- sort(unique(module_input$Study_Accession))
  phenotype <- build_phenotype_nodes(
    raw_phenotypes,
    valid_accessions,
    args$medium_dir,
    args$stop_on_duplicate_study_phenotype
  )
  final_accessions <- intersect(valid_accessions, names(phenotype$study_to_phenotype_id))
  module_input <- module_input[module_input$Study_Accession %in% final_accessions, , drop = FALSE]
  membership_input <- membership_input[membership_input$Study_Accession %in% final_accessions, , drop = FALSE]

  module_db_map <- module_input[!duplicated(module_input$Study_Accession),
                                c("Study_Accession", "Database_Key", "Database"), drop = FALSE]
  studies <- build_study_nodes(
    final_accessions,
    module_db_map,
    descriptions,
    args$rawdata_dir,
    phenotype$study_to_phenotype_id,
    phenotype$study_to_phenotype
  )
  study_id_map <- setNames(studies$Lab_ID, studies$Accession)

  metabolites <- build_metabolite_nodes(old_metabolites)
  modules <- build_module_nodes(module_input, study_id_map, metabolites$inchi_to_new)

  nodes <- list(
    study = studies,
    phenotype = phenotype$nodes,
    module = modules$nodes,
    metabolite = metabolites$nodes
  )
  edges <- list(
    study_phenotype = build_study_phenotype_edges(nodes$study),
    module_study = build_module_study_edges(nodes$module),
    metabolite_module = build_metabolite_module_edges(membership_input, modules$module_key_to_id, metabolites$inchi_to_new, args$medium_dir),
    metabolite_metabolite = build_metabolite_metabolite_edges(old_metabolite_edges, metabolites$old_to_new, args$medium_dir),
    module_module = build_module_module_edges(similarity_edges, modules$module_key_to_id, args$medium_dir)
  )

  write_csv(nodes$study, file.path(args$nodes_dir, "nodes_study.csv"))
  write_csv(nodes$phenotype, file.path(args$nodes_dir, "nodes_phenotype.csv"))
  write_csv(nodes$module, file.path(args$nodes_dir, "nodes_module.csv"))
  write_csv(nodes$metabolite, file.path(args$nodes_dir, "nodes_metabolite.csv"))

  write_csv(edges$study_phenotype, file.path(args$edges_dir, "edges_study_phenotype.csv"))
  write_csv(edges$module_study, file.path(args$edges_dir, "edges_module_study.csv"))
  write_csv(edges$metabolite_module, file.path(args$edges_dir, "edges_metabolite_module.csv"))
  write_csv(edges$metabolite_metabolite, file.path(args$edges_dir, "edges_metabolite_metabolite.csv"))
  write_csv(edges$module_module, file.path(args$edges_dir, "edges_module_module.csv"))

  reports <- write_final_reports(args, nodes, edges, missing_study_ids)
  message("Done. Final tidy nodes written to: ", args$nodes_dir)
  message("Done. Final tidy edges written to: ", args$edges_dir)
  print(reports$counts)
  if (any(reports$endpoint_checks$missing_endpoint_count > 0)) {
    warning("Some edge endpoints did not validate. Check: ", file.path(args$medium_dir, "final_endpoint_validation.csv"))
  }
}

if (sys.nframe() == 0L && !interactive()) {
  main()
}
