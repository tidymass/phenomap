# PhenoMAP module enrichment analysis.
#
# Over-representation analysis (ORA): for every module, test whether the
# user's metabolite list is over-represented among that module's members,
# using the one-sided hypergeometric / Fisher's exact test.
#
# Two behaviour changes vs the first version:
#   * module universe can be restricted (confidence_label / hypothesis_type),
#     and the background is rebuilt from whatever universe survives
#   * "fisher" and "hypergeometric" were mathematically the same test, so
#     there is now one method. p-values are computed with phyper(), which is
#     exactly the one-sided Fisher's exact p-value and is vectorised.
#   * BH correction runs over the modules that were actually testable -- the
#     ones with a non-zero overlap -- not over every module in the universe.
#     A module that shares no metabolite with the input has p = 1 by
#     construction and cannot produce a signal; counting it only inflates
#     the BH denominator. This matches how ORA tools have always done it:
#     DOSE/clusterProfiler's enricher_internal() builds its result table
#     from qTermID (the terms the query actually hits) and calls
#     p.adjust() on exactly that table.
#
# Performance: the per-module loop that rescanned the 1.26M-row edge table
# 12,929 times is gone. Everything is precomputed once with split()/match().

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

clean_ids <- function(x) {
  x <- trimws(as.character(unlist(x, use.names = FALSE)))
  unique(x[!is.na(x) & nzchar(x)])
}

split_input_ids <- function(x) {
  clean_ids(unlist(strsplit(paste(x, collapse = "\n"), "[,;[:space:]]+", perl = TRUE), use.names = FALSE))
}

collapse_text <- function(x) {
  x <- unique(clean_ids(x))
  if (length(x) == 0) return(NA_character_)
  paste(x, collapse = "; ")
}

id_type_column <- function(id_type) {
  switch(id_type, lab_id = "Lab_ID", hmdb = "HMDB_ID", kegg = "KEGG_ID", inchi = "INCHI_ID")
}

# ---------------------------------------------------------------- data ----
# Load the three tables once. The plumber service should call this at
# startup and hand the result to run_module_enrichment(data = ...) so a
# request does not re-parse ~165 MB of CSV every time.

normalise_membership_edges <- function(edges) {
  if (!"Metabolite_ID" %in% colnames(edges) && ":START_ID" %in% colnames(edges)) {
    edges$Metabolite_ID <- edges[[":START_ID"]]
  }
  if (!"Module_ID" %in% colnames(edges) && ":END_ID" %in% colnames(edges)) {
    edges$Module_ID <- edges[[":END_ID"]]
  }
  edges
}

load_enrichment_data <- function(import_dir = file.path("neo4j", "import"),
                                 entity_dir = NULL,
                                 relationship_dir = NULL) {
  if (!is.null(entity_dir) && !is.null(relationship_dir)) {
    metabolites <- read_csv_required(file.path(entity_dir, "nodes_metabolite.csv"))
    modules <- read_csv_required(file.path(entity_dir, "nodes_module.csv"))
    edges <- read_csv_required(file.path(relationship_dir, "edges_metabolite_module.csv"))
  } else {
    metabolites <- read_csv_required(file.path(import_dir, "nodes_metabolite.csv"))
    modules <- read_csv_required(file.path(import_dir, "nodes_module.csv"))
    edges <- read_csv_required(file.path(import_dir, "edges_metabolite_module.csv"))
  }
  edges <- normalise_membership_edges(edges)

  needed <- c("Metabolite_ID", "Module_ID", "Type")
  missing <- setdiff(needed, colnames(edges))
  if (length(missing) > 0) {
    stop("edges_metabolite_module.csv missing columns: ", paste(missing, collapse = ", "))
  }

  # Only core/supporting edges can ever be an overlap hit; drop the 1.13M
  # contextual rows up front so every later step works on ~130k rows.
  edges <- edges[edges$Type %in% c("core", "supporting"), needed, drop = FALSE]

  # nodes_module.csv is ~82 MB, almost all of it free text this analysis
  # never looks at (anchor/contextual metabolite lists, rationale,
  # phenotype_relationship). Keep only what is needed so the cached copy
  # in the plumber process stays small.
  module_cols <- intersect(
    c("Lab_ID", "Study_ID", "title", "hypothesis_type", "confidence_label", "functional_summary"),
    colnames(modules)
  )
  modules <- modules[, module_cols, drop = FALSE]

  # Lab_ID -> external key, one lookup vector per id_type, built once.
  key_maps <- lapply(c("lab_id", "hmdb", "kegg", "inchi"), function(id_type) {
    col <- id_type_column(id_type)
    if (!col %in% colnames(metabolites)) return(NULL)
    keys <- trimws(as.character(metabolites[[col]]))
    keys[is.na(keys) | toupper(keys) %in% c("NA", "NULL", "NAN", "<NA>")] <- ""
    if (id_type != "inchi") keys <- toupper(keys)
    stats::setNames(keys, metabolites$Lab_ID)
  })
  names(key_maps) <- c("lab_id", "hmdb", "kegg", "inchi")

  list(metabolites = metabolites, modules = modules, edges = edges, key_maps = key_maps)
}

# --------------------------------------------------------- input mapping ----

map_input_metabolites <- function(input_ids, metabolites, id_type) {
  id_type <- match.arg(id_type, c("lab_id", "hmdb", "kegg", "inchi"))
  input_ids <- split_input_ids(input_ids)
  col <- id_type_column(id_type)
  if (!col %in% colnames(metabolites)) stop("nodes_metabolite.csv missing column: ", col)

  query_key <- if (id_type == "inchi") input_ids else toupper(input_ids)
  db_key <- if (id_type == "inchi") metabolites[[col]] else toupper(metabolites[[col]])
  db_key[is.na(db_key)] <- ""

  # One split() instead of a which() scan per input id.
  ok <- nzchar(db_key)
  idx_by_key <- split(seq_len(nrow(metabolites))[ok], db_key[ok])

  rows <- lapply(seq_along(input_ids), function(i) {
    idx <- idx_by_key[[query_key[i]]]
    if (is.null(idx) || length(idx) == 0) {
      return(data.frame(
        Input_ID = input_ids[i], ID_Type = id_type, Match_Key = query_key[i],
        Matched = FALSE, Metabolite_ID = NA_character_, Metabolite_Name = NA_character_,
        Matched_ID = NA_character_, stringsAsFactors = FALSE
      ))
    }
    data.frame(
      Input_ID = input_ids[i], ID_Type = id_type, Match_Key = query_key[i],
      Matched = TRUE, Metabolite_ID = metabolites$Lab_ID[idx],
      Metabolite_Name = metabolites$Metabolite_Name[idx],
      Matched_ID = metabolites[[col]][idx], stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

# ------------------------------------------------------- module universe ----
# Restricting the universe is not just cosmetic filtering: the background
# is rebuilt from the surviving modules, so the null model matches what is
# actually being tested, and the BH denominator shrinks with it.

select_module_universe <- function(modules, confidence_labels = NULL, hypothesis_types = NULL) {
  keep <- rep(TRUE, nrow(modules))
  if (!is.null(confidence_labels) && length(confidence_labels) > 0) {
    if (!"confidence_label" %in% colnames(modules)) stop("nodes_module.csv missing column: confidence_label")
    keep <- keep & tolower(trimws(modules$confidence_label)) %in% tolower(trimws(confidence_labels))
  }
  if (!is.null(hypothesis_types) && length(hypothesis_types) > 0) {
    if (!"hypothesis_type" %in% colnames(modules)) stop("nodes_module.csv missing column: hypothesis_type")
    keep <- keep & tolower(trimws(modules$hypothesis_type)) %in% tolower(trimws(hypothesis_types))
  }
  modules$Lab_ID[keep]
}

# ------------------------------------------------------------- analysis ----

run_module_enrichment <- function(input_ids,
                                  id_type = c("lab_id", "hmdb", "kegg", "inchi"),
                                  import_dir = file.path("neo4j", "import"),
                                  entity_dir = NULL,
                                  relationship_dir = NULL,
                                  member_types = c("core", "supporting"),
                                  fdr_cutoff = 0.05,
                                  min_overlap = 2,
                                  confidence_labels = NULL,
                                  hypothesis_types = NULL,
                                  data = NULL,
                                  ...) {
  id_type <- match.arg(id_type)

  if (is.null(data)) {
    data <- load_enrichment_data(
      import_dir = import_dir,
      entity_dir = entity_dir,
      relationship_dir = relationship_dir
    )
  }
  metabolites <- data$metabolites
  modules <- data$modules
  edges <- data$edges

  key_map <- data$key_maps[[id_type]]
  if (is.null(key_map)) stop("nodes_metabolite.csv missing column: ", id_type_column(id_type))

  # --- module universe + its edges -----------------------------------------
  universe <- select_module_universe(modules, confidence_labels, hypothesis_types)
  if (length(universe) == 0) stop("No modules left after the confidence / hypothesis_type filter.")

  e <- edges[edges$Type %in% member_types & edges$Module_ID %in% universe, , drop = FALSE]
  if (nrow(e) == 0) stop("No core/supporting memberships left after filtering.")

  # Project membership into the chosen ID space and drop metabolites that
  # have no such ID -- they cannot be matched by the user's input either.
  e$Key <- unname(key_map[e$Metabolite_ID])
  e <- e[!is.na(e$Key) & nzchar(e$Key), , drop = FALSE]

  # Unique (module, key) pairs define the module sets and the background.
  pair <- !duplicated(e[, c("Module_ID", "Key")])
  mk_module <- e$Module_ID[pair]
  mk_key <- e$Key[pair]

  background_keys <- unique(mk_key)
  bg_size <- length(background_keys)

  # Every module in the filtered universe stays in the output, including
  # ones whose members have no ID in the chosen id_type (size 0, p = 1) --
  # same rows as before, so the table the user sees does not change shape.
  module_ids <- sort(universe)
  module_size <- as.integer(table(factor(mk_module, levels = module_ids)))

  # --- input ----------------------------------------------------------------
  input_map <- map_input_metabolites(input_ids, metabolites, id_type)
  matched <- input_map[input_map$Matched, , drop = FALSE]
  input_keys <- unique(matched$Match_Key[matched$Match_Key %in% background_keys])
  input_size <- length(input_keys)

  # --- overlap (one pass, not one scan per module) --------------------------
  is_hit <- mk_key %in% input_keys
  overlap_n <- as.integer(table(factor(mk_module[is_hit], levels = module_ids)))

  # --- p-values, vectorised -------------------------------------------------
  # phyper upper tail == one-sided Fisher's exact ("greater") on the 2x2.
  p_value <- rep(1, length(module_ids))
  testable <- overlap_n > 0 & input_size > 0 & module_size > 0
  if (any(testable)) {
    p_value[testable] <- stats::phyper(
      overlap_n[testable] - 1,
      module_size[testable],
      bg_size - module_size[testable],
      input_size,
      lower.tail = FALSE
    )
  }

  enrichment_ratio <- rep(NA_real_, length(module_ids))
  ok_ratio <- input_size > 0 & module_size > 0
  enrichment_ratio[ok_ratio] <-
    (overlap_n[ok_ratio] / input_size) / (module_size[ok_ratio] / bg_size)

  # --- hit details, only for modules that actually have an overlap ----------
  overlap_ids_txt <- rep(NA_character_, length(module_ids))
  overlap_names_txt <- rep(NA_character_, length(module_ids))
  core_n <- integer(length(module_ids))
  supporting_n <- integer(length(module_ids))

  hit_rows <- which(overlap_n > 0)
  if (length(hit_rows) > 0) {
    matched_labs <- unique(matched$Metabolite_ID)
    h <- e[e$Key %in% input_keys & e$Metabolite_ID %in% matched_labs, , drop = FALSE]
    if (nrow(h) > 0) {
      name_by_lab <- stats::setNames(metabolites$Metabolite_Name, metabolites$Lab_ID)
      by_mod <- split(seq_len(nrow(h)), factor(h$Module_ID, levels = module_ids))
      for (i in hit_rows) {
        rows_i <- by_mod[[i]]
        if (is.null(rows_i) || length(rows_i) == 0) next
        # keep the user's input order, like the original did
        labs <- matched_labs[matched_labs %in% h$Metabolite_ID[rows_i]]
        overlap_ids_txt[i] <- collapse_text(labs)
        overlap_names_txt[i] <- collapse_text(unname(name_by_lab[labs]))
        core_n[i] <- length(unique(h$Key[rows_i][h$Type[rows_i] == "core"]))
        supporting_n[i] <- length(unique(h$Key[rows_i][h$Type[rows_i] == "supporting"]))
      }
    }
  }

  enrichment <- data.frame(
    Module_ID = module_ids,
    Input_N = input_size,
    Background_N = bg_size,
    Module_Set_Size = module_size,
    Overlap_N = overlap_n,
    Core_Overlap_N = core_n,
    Supporting_Overlap_N = supporting_n,
    P_Value = p_value,
    Enrichment_Ratio = enrichment_ratio,
    Overlap_Metabolite_IDs = overlap_ids_txt,
    Overlap_Metabolite_Names = overlap_names_txt,
    stringsAsFactors = FALSE
  )

  # --- multiple testing -----------------------------------------------------
  # BH over the tested modules only (Overlap_N > 0). Modules with no overlap
  # keep FDR = 1: they were never in the running, so they must not enlarge
  # the denominator. `tested_module_n` is reported back as the effective m.
  tested <- which(enrichment$Overlap_N > 0)
  enrichment$FDR <- 1
  if (length(tested) > 0) {
    enrichment$FDR[tested] <- stats::p.adjust(enrichment$P_Value[tested], method = "BH")
  }
  enrichment$Significant <- enrichment$FDR < fdr_cutoff & enrichment$Overlap_N >= min_overlap

  module_cols <- c("Lab_ID", "Study_ID", "title", "hypothesis_type", "confidence_label", "functional_summary")
  module_cols <- intersect(module_cols, colnames(modules))
  enrichment <- merge(
    enrichment, modules[, module_cols, drop = FALSE],
    by.x = "Module_ID", by.y = "Lab_ID", all.x = TRUE, sort = FALSE
  )
  enrichment <- enrichment[
    order(enrichment$FDR, -enrichment$Enrichment_Ratio, -enrichment$Overlap_N), , drop = FALSE
  ]
  rownames(enrichment) <- NULL

  list(
    enrichment = enrichment,
    matched_input = input_map[input_map$Matched, , drop = FALSE],
    unmatched_input = input_map[!input_map$Matched, , drop = FALSE],
    parameters = list(
      id_type = id_type,
      method = "fisher",
      member_types = member_types,
      confidence_labels = if (is.null(confidence_labels)) "all" else confidence_labels,
      hypothesis_types = if (is.null(hypothesis_types)) "all" else hypothesis_types,
      fdr_cutoff = fdr_cutoff,
      min_overlap = min_overlap,
      input_n = length(split_input_ids(input_ids)),
      matched_background_n = input_size,
      background_n = bg_size,
      module_n = length(module_ids),
      tested_module_n = length(tested)
    )
  )
}
