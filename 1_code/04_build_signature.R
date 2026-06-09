# =============================================================================
# PhenoMAP v0.1 — Build Signature Table
#
# Derives a query-ready signature table from the current SQLite atlas:
#   anchor: LLM-selected anchor_metabolites resolved back to member IDs
#   top:    top member metabolites ranked by importance and node frequency
#
# Also writes anchor_unmatched for manual review.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(DBI)
  library(RSQLite)
})

DB_PATH <- "2_data/phenomap_v0.1.db"
TOP_N   <- 50

normalize_name <- function(x) {
  x %>%
    str_to_lower() %>%
    str_replace_all("[^a-z0-9]+", "")
}

best_fuzzy_match <- function(anchor_name, anchor_norm, candidates) {
  empty <- tibble(
    Compound_name = NA_character_,
    INCHI_ID = NA_character_,
    HMDB_ID = NA_character_,
    KEGG_ID = NA_character_,
    match_method = NA_character_,
    match_score = NA_real_
  )

  candidates <- candidates %>%
    filter(!is.na(compound_norm), compound_norm != "")

  if (nrow(candidates) == 0 || is.na(anchor_norm) || nchar(anchor_norm) < 6) {
    return(empty)
  }

  dist <- adist(anchor_norm, candidates$compound_norm)
  denom <- pmax(nchar(anchor_norm), nchar(candidates$compound_norm))
  score <- as.numeric(1 - dist / denom)
  best_i <- which.max(score)
  best_score <- score[best_i]
  second_score <- sort(score, decreasing = TRUE)[min(2, length(score))]

  if (is.na(best_score) || best_score < 0.92 || best_score - second_score < 0.02) {
    return(empty)
  }

  candidates[best_i, ] %>%
    transmute(
      Compound_name, INCHI_ID, HMDB_ID, KEGG_ID,
      match_method = "fuzzy",
      match_score = round(best_score, 3)
    )
}

build_signature_tables <- function(module_tbl, member_tbl, top_n = TOP_N) {
  member_lookup <- member_tbl %>%
    mutate(compound_norm = normalize_name(Compound_name)) %>%
    filter(!is.na(INCHI_ID), compound_norm != "") %>%
    distinct(global_module_id, compound_norm, Compound_name, INCHI_ID, HMDB_ID, KEGG_ID)

  anchors <- module_tbl %>%
    filter(!is.na(anchor_metabolites), anchor_metabolites != "", anchor_metabolites != "NA") %>%
    select(global_module_id, study_id, anchor_metabolites) %>%
    separate_rows(anchor_metabolites, sep = ";") %>%
    mutate(
      anchor_name = str_squish(anchor_metabolites),
      anchor_norm = normalize_name(anchor_name)
    ) %>%
    filter(anchor_name != "", anchor_norm != "") %>%
    group_by(global_module_id) %>%
    mutate(anchor_rank = row_number()) %>%
    ungroup() %>%
    select(global_module_id, study_id, anchor_rank, anchor_name, anchor_norm)

  exact_anchor <- anchors %>%
    left_join(member_lookup, by = c("global_module_id", "anchor_norm" = "compound_norm")) %>%
    mutate(
      match_method = if_else(!is.na(INCHI_ID), "exact", NA_character_),
      match_score = if_else(!is.na(INCHI_ID), 1, NA_real_)
    )

  matched_exact <- exact_anchor %>%
    filter(!is.na(INCHI_ID))

  unmatched_exact <- exact_anchor %>%
    filter(is.na(INCHI_ID)) %>%
    select(global_module_id, study_id, anchor_rank, anchor_name, anchor_norm)

  fuzzy_anchor <- unmatched_exact %>%
    group_by(global_module_id) %>%
    group_modify(~ {
      candidates <- member_lookup %>% filter(global_module_id == .y$global_module_id)
      map_dfr(seq_len(nrow(.x)), function(i) {
        match <- best_fuzzy_match(.x$anchor_name[i], .x$anchor_norm[i], candidates)
        bind_cols(.x[i, ], match)
      })
    }) %>%
    ungroup()

  matched_fuzzy <- fuzzy_anchor %>%
    filter(!is.na(INCHI_ID))

  anchor_sig <- bind_rows(matched_exact, matched_fuzzy) %>%
    transmute(
      global_module_id, study_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name,
      tier = "anchor",
      weighted_score = 1,
      priority_level = "high",
      source_name = anchor_name,
      match_method,
      match_score
    ) %>%
    distinct()

  anchor_unmatched <- fuzzy_anchor %>%
    filter(is.na(INCHI_ID)) %>%
    transmute(global_module_id, study_id, anchor_rank, anchor_name)

  top_sig <- member_tbl %>%
    filter(use_for_annotation == 1, !is.na(INCHI_ID)) %>%
    mutate(weighted_score = 0.7 * importance + 0.3 * node_freq) %>%
    group_by(global_module_id) %>%
    arrange(desc(weighted_score), .by_group = TRUE) %>%
    slice_head(n = top_n) %>%
    mutate(
      top_rank = row_number(),
      priority_level = case_when(
        top_rank <= 10 ~ "high",
        top_rank <= ceiling(top_n / 2) ~ "medium",
        TRUE ~ "low"
      )
    ) %>%
    ungroup() %>%
    transmute(
      global_module_id, study_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name,
      tier = "top",
      weighted_score,
      priority_level,
      source_name = Compound_name,
      match_method = "member_rank",
      match_score = NA_real_
    ) %>%
    distinct()

  list(
    signature = bind_rows(anchor_sig, top_sig) %>% distinct(),
    anchor_unmatched = anchor_unmatched
  )
}

con <- dbConnect(SQLite(), DB_PATH)

module_tbl <- dbReadTable(con, "module")
member_tbl <- dbReadTable(con, "member")

tables <- build_signature_tables(module_tbl, member_tbl, TOP_N)

dbWriteTable(con, "signature", tables$signature, overwrite = TRUE)
dbWriteTable(con, "anchor_unmatched", tables$anchor_unmatched, overwrite = TRUE)

invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_inchi  ON signature(INCHI_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_hmdb   ON signature(HMDB_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_kegg   ON signature(KEGG_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_module ON signature(global_module_id)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_tier   ON signature(tier)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_anchor_unmatched_module ON anchor_unmatched(global_module_id)"))

dbDisconnect(con)

cat(sprintf(
  "Signature written: %d rows | anchor rows: %d | top rows: %d | unmatched anchors: %d\n",
  nrow(tables$signature),
  sum(tables$signature$tier == "anchor"),
  sum(tables$signature$tier == "top"),
  nrow(tables$anchor_unmatched)
))
