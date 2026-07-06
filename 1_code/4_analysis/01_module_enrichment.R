# PhenoMAP module enrichment analysis.

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

map_input_metabolites <- function(input_ids, metabolites, id_type) {
  id_type <- match.arg(id_type, c("hmdb", "kegg", "inchi"))
  input_ids <- split_input_ids(input_ids)

  col <- switch(
    id_type,
    hmdb = "HMDB_ID",
    kegg = "KEGG_ID",
    inchi = "INCHI_ID"
  )
  if (!col %in% colnames(metabolites)) stop("nodes_metabolite.csv missing column: ", col)

  query_key <- if (id_type == "inchi") input_ids else toupper(input_ids)
  db_key <- if (id_type == "inchi") metabolites[[col]] else toupper(metabolites[[col]])
  idx <- match(query_key, db_key)

  data.frame(
    Input_ID = input_ids,
    ID_Type = id_type,
    Matched = !is.na(idx),
    Metabolite_ID = ifelse(is.na(idx), NA_character_, metabolites$Lab_ID[idx]),
    Metabolite_Name = ifelse(is.na(idx), NA_character_, metabolites$Metabolite_Name[idx]),
    Matched_ID = ifelse(is.na(idx), NA_character_, metabolites[[col]][idx]),
    stringsAsFactors = FALSE
  )
}

build_module_sets <- function(edges, member_types = c("core", "supporting")) {
  edges <- edges[edges$Type %in% member_types, c("Module_ID", "Metabolite_ID", "Type"), drop = FALSE]
  edges <- edges[!duplicated(edges[, c("Module_ID", "Metabolite_ID")]), , drop = FALSE]
  split(edges$Metabolite_ID, edges$Module_ID)
}

run_module_enrichment <- function(input_ids,
                                  id_type = c("hmdb", "kegg", "inchi"),
                                  method = c("fisher", "hypergeometric"),
                                  entity_dir = file.path("2_data", "tidy_entity"),
                                  relationship_dir = file.path("2_data", "tidy_relationship"),
                                  member_types = c("core", "supporting"),
                                  fdr_cutoff = 0.05,
                                  min_overlap = 2) {
  id_type <- match.arg(id_type)
  method <- match.arg(method)

  metabolites <- read_csv_required(file.path(entity_dir, "nodes_metabolite.csv"))
  modules <- read_csv_required(file.path(entity_dir, "nodes_module.csv"))
  edges <- read_csv_required(file.path(relationship_dir, "edges_metabolite_module.csv"))

  needed_edges <- c("Metabolite_ID", "Module_ID", "Type")
  missing_edges <- setdiff(needed_edges, colnames(edges))
  if (length(missing_edges) > 0) stop("edges_metabolite_module.csv missing columns: ", paste(missing_edges, collapse = ", "))

  input_map <- map_input_metabolites(input_ids, metabolites, id_type)
  background <- unique(edges$Metabolite_ID)
  matched_ids <- unique(input_map$Metabolite_ID[input_map$Matched & input_map$Metabolite_ID %in% background])

  module_sets <- build_module_sets(edges, member_types = member_types)
  bg_size <- length(background)
  input_size <- length(matched_ids)

  rows <- lapply(names(module_sets), function(module_id) {
    module_metabolites <- unique(module_sets[[module_id]])
    module_metabolites <- module_metabolites[module_metabolites %in% background]
    overlap_ids <- intersect(matched_ids, module_metabolites)

    a <- length(overlap_ids)
    module_size <- length(module_metabolites)
    b <- input_size - a
    c <- module_size - a
    d <- bg_size - module_size - b

    p_value <- if (input_size == 0 || module_size == 0 || a == 0) {
      1
    } else if (method == "fisher") {
      stats::fisher.test(matrix(c(a, b, c, d), nrow = 2), alternative = "greater")$p.value
    } else {
      stats::phyper(a - 1, module_size, bg_size - module_size, input_size, lower.tail = FALSE)
    }

    hit <- metabolites[match(overlap_ids, metabolites$Lab_ID), , drop = FALSE]
    edge_hit <- edges[edges$Module_ID == module_id & edges$Metabolite_ID %in% overlap_ids, , drop = FALSE]

    data.frame(
      Module_ID = module_id,
      Input_N = input_size,
      Background_N = bg_size,
      Module_Set_Size = module_size,
      Overlap_N = a,
      Core_Overlap_N = sum(edge_hit$Type == "core"),
      Supporting_Overlap_N = sum(edge_hit$Type == "supporting"),
      P_Value = p_value,
      Enrichment_Ratio = ifelse(input_size == 0 || module_size == 0, NA_real_, (a / input_size) / (module_size / bg_size)),
      Overlap_Metabolite_IDs = collapse_text(overlap_ids),
      Overlap_Metabolite_Names = collapse_text(hit$Metabolite_Name),
      stringsAsFactors = FALSE
    )
  })

  enrichment <- if (length(rows) == 0) data.frame() else do.call(rbind, rows)
  enrichment$FDR <- stats::p.adjust(enrichment$P_Value, method = "BH")
  enrichment$Significant <- enrichment$FDR < fdr_cutoff & enrichment$Overlap_N >= min_overlap

  module_cols <- c("Lab_ID", "Study_ID", "title", "hypothesis_type", "confidence_label", "functional_summary")
  module_cols <- intersect(module_cols, colnames(modules))
  enrichment <- merge(
    enrichment,
    modules[, module_cols, drop = FALSE],
    by.x = "Module_ID",
    by.y = "Lab_ID",
    all.x = TRUE,
    sort = FALSE
  )
  enrichment <- enrichment[
    order(enrichment$FDR, -enrichment$Enrichment_Ratio, -enrichment$Overlap_N),
    ,
    drop = FALSE
  ]

  list(
    enrichment = enrichment,
    matched_input = input_map[input_map$Matched, , drop = FALSE],
    unmatched_input = input_map[!input_map$Matched, , drop = FALSE],
    parameters = list(
      id_type = id_type,
      method = method,
      member_types = member_types,
      fdr_cutoff = fdr_cutoff,
      min_overlap = min_overlap,
      input_n = length(split_input_ids(input_ids)),
      matched_background_n = input_size,
      background_n = bg_size
    )
  )
}
