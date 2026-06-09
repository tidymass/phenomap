# =============================================================================
# PhenoMAP v0.1 — Build Signature Table
#
# Derives a query-ready signature table from the current SQLite atlas:
#   anchor: LLM-selected anchor_metabolites resolved back to member IDs
#   top:    LLM/module-function core_drivers resolved back to member IDs
#
# Also writes anchor_unmatched for manual review.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(DBI)
  library(RSQLite)
})

DB_PATH <- "2_data/phenomap_v0.1.db"

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

resolve_named_signature <- function(module_tbl,
                                    member_lookup,
                                    source_col,
                                    tier,
                                    priority_from_rank = FALSE) {
  if (!source_col %in% colnames(module_tbl)) {
    empty_sig <- tibble(
      global_module_id = character(),
      study_id = character(),
      INCHI_ID = character(),
      HMDB_ID = character(),
      KEGG_ID = character(),
      Compound_name = character(),
      tier = character(),
      weighted_score = numeric(),
      priority_level = character(),
      source_name = character(),
      match_method = character(),
      match_score = numeric()
    )
    empty_unmatched <- tibble(
      global_module_id = character(),
      study_id = character(),
      tier = character(),
      source_rank = integer(),
      source_name = character()
    )
    return(list(signature = empty_sig, unmatched = empty_unmatched))
  }

  sources <- module_tbl %>%
    filter(!is.na(.data[[source_col]]), .data[[source_col]] != "", .data[[source_col]] != "NA") %>%
    select(global_module_id, study_id, source_text = all_of(source_col)) %>%
    separate_rows(source_text, sep = ";") %>%
    mutate(
      source_name = str_squish(source_text),
      source_norm = normalize_name(source_name)
    ) %>%
    filter(source_name != "", source_norm != "") %>%
    group_by(global_module_id) %>%
    mutate(source_rank = row_number()) %>%
    ungroup() %>%
    select(global_module_id, study_id, source_rank, source_name, source_norm)

  exact <- sources %>%
    left_join(member_lookup, by = c("global_module_id", "source_norm" = "compound_norm")) %>%
    mutate(
      match_method = if_else(!is.na(INCHI_ID), "exact", NA_character_),
      match_score = if_else(!is.na(INCHI_ID), 1, NA_real_)
    )

  matched_exact <- exact %>%
    filter(!is.na(INCHI_ID))

  unmatched_exact <- exact %>%
    filter(is.na(INCHI_ID)) %>%
    select(global_module_id, study_id, source_rank, source_name, source_norm)

  if (nrow(unmatched_exact) > 0) {
    fuzzy <- unmatched_exact %>%
      group_by(global_module_id) %>%
      group_modify(~ {
        candidates <- member_lookup %>% filter(global_module_id == .y$global_module_id)
        map_dfr(seq_len(nrow(.x)), function(i) {
          match <- best_fuzzy_match(.x$source_name[i], .x$source_norm[i], candidates)
          bind_cols(.x[i, ], match)
        })
      }) %>%
      ungroup()
  } else {
    fuzzy <- unmatched_exact %>%
      mutate(
        Compound_name = NA_character_,
        INCHI_ID = NA_character_,
        HMDB_ID = NA_character_,
        KEGG_ID = NA_character_,
        match_method = NA_character_,
        match_score = NA_real_
      )
  }

  matched_fuzzy <- fuzzy %>%
    filter(!is.na(INCHI_ID))

  sig <- bind_rows(matched_exact, matched_fuzzy) %>%
    mutate(
      priority_level = case_when(
        !priority_from_rank ~ "high",
        source_rank <= 5 ~ "high",
        source_rank <= 10 ~ "medium",
        TRUE ~ "low"
      )
    ) %>%
    transmute(
      global_module_id, study_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name,
      tier = tier,
      weighted_score,
      priority_level,
      source_name,
      match_method,
      match_score
    ) %>%
    distinct()

  unmatched <- fuzzy %>%
    filter(is.na(INCHI_ID)) %>%
    transmute(global_module_id, study_id, tier, source_rank, source_name)

  list(signature = sig, unmatched = unmatched)
}

build_signature_tables <- function(module_tbl, member_tbl) {
  member_lookup <- member_tbl %>%
    mutate(weighted_score = 0.7 * importance + 0.3 * node_freq) %>%
    mutate(compound_norm = normalize_name(Compound_name)) %>%
    filter(!is.na(INCHI_ID), compound_norm != "") %>%
    arrange(global_module_id, compound_norm, desc(weighted_score)) %>%
    group_by(global_module_id, compound_norm) %>%
    slice_head(n = 1) %>%
    ungroup() %>%
    select(global_module_id, compound_norm, Compound_name, INCHI_ID, HMDB_ID, KEGG_ID, weighted_score)

  anchor_res <- resolve_named_signature(
    module_tbl = module_tbl,
    member_lookup = member_lookup,
    source_col = "anchor_metabolites",
    tier = "anchor",
    priority_from_rank = FALSE
  )

  top_res <- resolve_named_signature(
    module_tbl = module_tbl,
    member_lookup = member_lookup,
    source_col = "core_drivers",
    tier = "top",
    priority_from_rank = TRUE
  )

  signature_unmatched <- bind_rows(anchor_res$unmatched, top_res$unmatched)
  anchor_unmatched <- signature_unmatched %>%
    filter(tier == "anchor") %>%
    transmute(
      global_module_id,
      study_id,
      anchor_rank = source_rank,
      anchor_name = source_name
    )

  list(
    signature = bind_rows(anchor_res$signature, top_res$signature) %>% distinct(),
    anchor_unmatched = anchor_unmatched,
    signature_unmatched = signature_unmatched
  )
}

con <- dbConnect(SQLite(), DB_PATH)

module_tbl <- dbReadTable(con, "module")
member_tbl <- dbReadTable(con, "member")

tables <- build_signature_tables(module_tbl, member_tbl)

dbWriteTable(con, "signature", tables$signature, overwrite = TRUE)
dbWriteTable(con, "anchor_unmatched", tables$anchor_unmatched, overwrite = TRUE)
dbWriteTable(con, "signature_unmatched", tables$signature_unmatched, overwrite = TRUE)

invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_inchi  ON signature(INCHI_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_hmdb   ON signature(HMDB_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_kegg   ON signature(KEGG_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_module ON signature(global_module_id)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_tier   ON signature(tier)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_anchor_unmatched_module ON anchor_unmatched(global_module_id)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_signature_unmatched_module ON signature_unmatched(global_module_id)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_signature_unmatched_tier ON signature_unmatched(tier)"))

dbDisconnect(con)

cat(sprintf(
  "Signature written: %d rows | anchor rows: %d | top rows: %d | unmatched anchors: %d\n",
  nrow(tables$signature),
  sum(tables$signature$tier == "anchor"),
  sum(tables$signature$tier == "top"),
  nrow(tables$anchor_unmatched)
))
