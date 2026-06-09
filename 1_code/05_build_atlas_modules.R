# =============================================================================
# PhenoMAP v0.1 — Build Cross-study Atlas Modules
#
# Collapses study-specific module instances into reusable atlas modules, similar
# to pathway databases. The first-pass merge key is normalized title plus
# hypothesis_type, which is conservative and avoids semantic over-merging.
#
# Output tables:
#   atlas_module            — one row per merged functional module
#   atlas_module_instance   — mapping from atlas modules to study modules
#   atlas_signature         — merged anchor/top signatures for atlas queries
#   atlas_anchor_unmatched  — unmatched anchor names projected to atlas modules
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(DBI)
  library(RSQLite)
})

DB_PATH <- "2_data/phenomap_v0.1.db"

normalize_title <- function(x) {
  x %>%
    str_to_lower() %>%
    str_replace_all("[^a-z0-9]+", " ") %>%
    str_squish()
}

first_nonempty <- function(x) {
  x <- x[!is.na(x) & x != "" & x != "NA"]
  if (length(x) == 0) NA_character_ else x[1]
}

collapse_unique <- function(x, max_items = Inf) {
  vals <- unique(x[!is.na(x) & x != "" & x != "NA"])
  if (length(vals) == 0) return(NA_character_)
  vals <- vals[seq_len(min(length(vals), max_items))]
  paste(vals, collapse = "; ")
}

priority_rank <- function(x) {
  case_when(
    any(x == "high", na.rm = TRUE) ~ "high",
    any(x == "medium", na.rm = TRUE) ~ "medium",
    TRUE ~ "low"
  )
}

max_or_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) NA_real_ else max(x)
}

mean_or_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) NA_real_ else mean(x)
}

build_atlas_tables <- function(module_tbl, signature_tbl, anchor_unmatched_tbl = tibble()) {
  module_key <- module_tbl %>%
    mutate(
      title_norm = normalize_title(title),
      merge_key = paste(title_norm, coalesce(hypothesis_type, "NA"), sep = "||")
    )

  atlas_keys <- module_key %>%
    distinct(merge_key, title_norm, hypothesis_type) %>%
    arrange(title_norm, hypothesis_type) %>%
    mutate(atlas_module_id = sprintf("AM%04d", row_number()))

  instance_tbl <- module_key %>%
    left_join(atlas_keys, by = c("merge_key", "title_norm", "hypothesis_type")) %>%
    transmute(
      atlas_module_id,
      global_module_id,
      study_id,
      phenotype,
      biospecimen,
      title,
      hypothesis_type,
      confidence_label,
      p_value,
      fdr,
      module_size,
      annotated_nodes
    )

  atlas_module <- instance_tbl %>%
    group_by(atlas_module_id) %>%
    summarise(
      canonical_title = names(sort(table(title), decreasing = TRUE))[1],
      title_norm = normalize_title(canonical_title),
      hypothesis_type = first_nonempty(hypothesis_type),
      n_instances = n_distinct(global_module_id),
      n_studies = n_distinct(study_id),
      n_phenotypes = n_distinct(phenotype[!is.na(phenotype) & phenotype != "NA"]),
      n_biospecimens = n_distinct(biospecimen[!is.na(biospecimen) & biospecimen != "NA"]),
      study_ids = collapse_unique(study_id),
      phenotypes = collapse_unique(phenotype),
      biospecimens = collapse_unique(biospecimen),
      instance_ids = collapse_unique(global_module_id),
      confidence_labels = collapse_unique(confidence_label),
      min_p_value = suppressWarnings(min(p_value, na.rm = TRUE)),
      min_fdr = suppressWarnings(min(fdr, na.rm = TRUE)),
      .groups = "drop"
    ) %>%
    mutate(
      min_p_value = if_else(is.infinite(min_p_value), NA_real_, min_p_value),
      min_fdr = if_else(is.infinite(min_fdr), NA_real_, min_fdr)
    )

  atlas_signature <- signature_tbl %>%
    inner_join(instance_tbl %>% select(atlas_module_id, global_module_id),
               by = "global_module_id") %>%
    group_by(atlas_module_id, tier, INCHI_ID) %>%
    summarise(
      HMDB_ID = first_nonempty(HMDB_ID),
      KEGG_ID = first_nonempty(KEGG_ID),
      Compound_name = names(sort(table(Compound_name), decreasing = TRUE))[1],
      n_instances = n_distinct(global_module_id),
      n_studies = n_distinct(study_id),
      weighted_score = max_or_na(weighted_score),
      mean_weighted_score = mean_or_na(weighted_score),
      priority_level = priority_rank(priority_level),
      source_instances = collapse_unique(global_module_id),
      .groups = "drop"
    )

  if (nrow(anchor_unmatched_tbl) > 0) {
    atlas_anchor_unmatched <- anchor_unmatched_tbl %>%
      inner_join(instance_tbl %>% select(atlas_module_id, global_module_id),
                 by = "global_module_id") %>%
      transmute(atlas_module_id, global_module_id, study_id, anchor_rank, anchor_name)
  } else {
    atlas_anchor_unmatched <- tibble(
      atlas_module_id = character(),
      global_module_id = character(),
      study_id = character(),
      anchor_rank = integer(),
      anchor_name = character()
    )
  }

  list(
    atlas_module = atlas_module,
    atlas_module_instance = instance_tbl,
    atlas_signature = atlas_signature,
    atlas_anchor_unmatched = atlas_anchor_unmatched
  )
}

con <- dbConnect(SQLite(), DB_PATH)

module_tbl <- dbReadTable(con, "module")
signature_tbl <- dbReadTable(con, "signature")
anchor_unmatched_tbl <- if ("anchor_unmatched" %in% dbListTables(con)) {
  dbReadTable(con, "anchor_unmatched")
} else {
  tibble()
}

tables <- build_atlas_tables(module_tbl, signature_tbl, anchor_unmatched_tbl)

dbWriteTable(con, "atlas_module", tables$atlas_module, overwrite = TRUE)
dbWriteTable(con, "atlas_module_instance", tables$atlas_module_instance, overwrite = TRUE)
dbWriteTable(con, "atlas_signature", tables$atlas_signature, overwrite = TRUE)
dbWriteTable(con, "atlas_anchor_unmatched", tables$atlas_anchor_unmatched, overwrite = TRUE)

invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_atlas_module_title ON atlas_module(title_norm)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_atlas_instance_atlas ON atlas_module_instance(atlas_module_id)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_atlas_instance_global ON atlas_module_instance(global_module_id)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_atlas_sig_inchi ON atlas_signature(INCHI_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_atlas_sig_hmdb ON atlas_signature(HMDB_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_atlas_sig_kegg ON atlas_signature(KEGG_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_atlas_sig_module ON atlas_signature(atlas_module_id)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_atlas_sig_tier ON atlas_signature(tier)"))

dbDisconnect(con)

cat(sprintf(
  "Atlas modules written: %d modules | %d instances | %d signature rows\n",
  nrow(tables$atlas_module),
  nrow(tables$atlas_module_instance),
  nrow(tables$atlas_signature)
))
