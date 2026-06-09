# =============================================================================
# PhenoMAP v0.1 — Query Functions
#
# Two-tier ORA using the `signature` table:
#   Tier 1 (anchor): LLM-selected anchor metabolites — module's core identity
#   Tier 2 (top):    All topN metabolites (use_for_annotation, ranked by
#                    weighted_score) — broader but still discriminating
#
# Both tiers have full INCHI_ID / HMDB_ID / KEGG_ID from the same annotation.
#
# query_phenomap(ids, id_type, db_path, min_hits, fdr_cutoff)
# id_type: "HMDB" | "KEGG" | "INCHI"
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
  library(tidyverse)
})

DB_PATH <- "2_data/phenomap_v0.1.db"

# =============================================================================
# ORA for a single tier
# =============================================================================

run_ora <- function(sig, ids, col, min_hits, fdr_cutoff) {
  # sig: tibble with global_module_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name

  hits <- sig %>%
    filter(!is.na(INCHI_ID), !is.na(.data[[col]])) %>%
    filter(.data[[col]] %in% ids) %>%
    select(INCHI_ID, matched_id = all_of(col), Compound_name, global_module_id) %>%
    distinct()

  if (nrow(hits) == 0) return(tibble())

  query_size <- n_distinct(hits$INCHI_ID)
  bg_size    <- sig %>%
    filter(!is.na(INCHI_ID)) %>%
    summarise(n = n_distinct(INCHI_ID)) %>%
    pull(n)

  mod_sizes <- sig %>%
    filter(!is.na(INCHI_ID)) %>%
    group_by(global_module_id) %>%
    summarise(n_sig = n_distinct(INCHI_ID), .groups = "drop")

  hit_counts <- hits %>%
    group_by(global_module_id) %>%
    summarise(n_hit = n_distinct(INCHI_ID), .groups = "drop")

  hit_names <- hits %>%
    group_by(global_module_id) %>%
    summarise(matched_names = paste(unique(Compound_name), collapse = "; "),
              .groups = "drop")

  mod_sizes %>%
    left_join(hit_counts, by = "global_module_id") %>%
    replace_na(list(n_hit = 0L)) %>%
    filter(n_hit >= min_hits) %>%
    mutate(
      p_ora = phyper(
        q = n_hit - 1,
        m = n_sig,
        n = bg_size - n_sig,
        k = query_size,
        lower.tail = FALSE
      ),
      coverage_pct = round(n_hit / n_sig * 100, 1)
    ) %>%
    mutate(fdr_ora = p.adjust(p_ora, method = "BH")) %>%
    filter(fdr_ora <= fdr_cutoff) %>%
    left_join(hit_names, by = "global_module_id")
}

# =============================================================================
# Main query function
# =============================================================================

#' Query PhenoMAP Atlas (two-tier ORA)
#'
#' @param ids        Character vector of metabolite IDs
#' @param id_type    "HMDB", "KEGG", or "INCHI"
#' @param db_path    Path to phenomap SQLite database
#' @param min_hits   Min hits per module (default 2)
#' @param fdr_cutoff FDR threshold (default 0.2; set 1 to see all)
#' @param level      "atlas" for merged cross-study modules, or "instance" for
#'                   original study-specific modules
#'
#' @return Tibble ranked by tier (anchor first) then p_ora
query_phenomap <- function(ids,
                           id_type    = c("HMDB", "KEGG", "INCHI"),
                           db_path    = DB_PATH,
                           min_hits   = 2,
                           fdr_cutoff = 0.2,
                           level      = c("atlas", "instance")) {

  id_type <- match.arg(id_type)
  level   <- match.arg(level)
  ids     <- unique(na.omit(as.character(ids)))
  if (length(ids) == 0) stop("No valid IDs provided.")

  con <- dbConnect(SQLite(), db_path)
  on.exit(dbDisconnect(con), add = TRUE)

  # ---- Load signature and module info ----------------------------------------
  tables <- dbListTables(con)
  has_atlas <- all(c("atlas_module", "atlas_signature") %in% tables)
  has_sig <- "signature" %in% tables

  if (level == "atlas" && has_atlas) {
    sig_all <- dbGetQuery(con, "
      SELECT atlas_module_id AS global_module_id,
             INCHI_ID, HMDB_ID, KEGG_ID, Compound_name, tier
      FROM atlas_signature
    ")

    mod_info <- dbGetQuery(con, "
      SELECT atlas_module_id AS global_module_id,
             study_ids AS study_id,
             canonical_title AS title,
             hypothesis_type,
             phenotypes AS phenotype,
             biospecimens AS biospecimen,
             confidence_labels AS confidence_label,
             min_p_value AS p_value,
             min_fdr AS fdr,
             n_instances,
             n_studies,
             n_phenotypes,
             n_biospecimens,
             instance_ids,
             NULL AS functional_summary,
             NULL AS phenotype_relationship,
             NULL AS anchor_metabolites,
             NULL AS core_drivers,
             NULL AS top_kegg_pathways,
             NULL AS total_nodes,
             NULL AS annotated_nodes
      FROM atlas_module
    ")
  } else if (level == "atlas" && !has_atlas) {
    message("[query] No atlas tables found — falling back to instance-level query.")
    level <- "instance"
  }

  if (level == "instance" && has_sig) {
    sig_all <- dbGetQuery(con, "
      SELECT global_module_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name, tier
      FROM signature
    ")
  } else if (level == "instance") {
    # Fallback for the current v0.1 database:
    # tier="anchor" -> core drivers from the module member table
    # tier="top"    -> all annotation-eligible member nodes
    message("[query] No signature table found — deriving from member table. ",
            "Using is_core_driver as anchor and use_for_annotation as top.")
    members_full <- dbGetQuery(con, "
      SELECT global_module_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name,
             use_for_annotation, is_core_driver
      FROM member
    ")
    sig_anchor <- members_full %>%
      filter(is_core_driver == 1) %>%
      transmute(global_module_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name,
                tier = "anchor")
    sig_top <- members_full %>%
      filter(use_for_annotation == 1) %>%
      transmute(global_module_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name,
                tier = "top")
    sig_all <- bind_rows(sig_anchor, sig_top) %>% distinct()
  }

  if (level == "instance") {
    mod_info <- dbGetQuery(con, "
      SELECT global_module_id, study_id, title, hypothesis_type,
             functional_summary, confidence_label, phenotype_relationship,
             anchor_metabolites, core_drivers,
             top_kegg_pathways, phenotype, biospecimen,
             p_value, fdr, module_size AS total_nodes, annotated_nodes,
             NULL AS n_instances,
             NULL AS n_studies,
             NULL AS n_phenotypes,
             NULL AS n_biospecimens,
             NULL AS instance_ids
      FROM module
    ")
  }

  col_map <- c(HMDB = "HMDB_ID", KEGG = "KEGG_ID", INCHI = "INCHI_ID")
  col     <- col_map[[id_type]]

  sig_anchor <- sig_all %>% filter(tier == "anchor")
  sig_top    <- sig_all %>% filter(tier == "top")

  sig_stats <- sig_all %>%
    filter(!is.na(INCHI_ID)) %>%
    group_by(global_module_id, tier) %>%
    summarise(n_signature_resolved = n_distinct(INCHI_ID), .groups = "drop")

  unmatched_table <- if (level == "atlas") "atlas_anchor_unmatched" else "anchor_unmatched"
  unmatched_id <- if (level == "atlas") "atlas_module_id" else "global_module_id"

  if (unmatched_table %in% dbListTables(con)) {
    anchor_unmatched <- dbGetQuery(con, sprintf("
      SELECT %s AS global_module_id, COUNT(*) AS n_signature_unmatched
      FROM %s
      GROUP BY %s
    ", unmatched_id, unmatched_table, unmatched_id))
    sig_stats <- sig_stats %>%
      left_join(anchor_unmatched, by = "global_module_id") %>%
      mutate(n_signature_unmatched = if_else(
        tier == "anchor",
        as.integer(replace_na(n_signature_unmatched, 0L)),
        0L
      ))
  } else {
    sig_stats <- sig_stats %>% mutate(n_signature_unmatched = 0L)
  }

  sig_stats <- sig_stats %>%
    mutate(
      n_signature_total = n_signature_resolved + n_signature_unmatched,
      signature_resolution_pct = round(n_signature_resolved / n_signature_total * 100, 1)
    )

  cat(sprintf("[query:%s] Anchor: %d modules | Top: %d modules\n",
              level,
              n_distinct(sig_anchor$global_module_id),
              n_distinct(sig_top$global_module_id)))

  # ---- Tier 1: anchor --------------------------------------------------------
  res1 <- run_ora(sig_anchor, ids, col, min_hits, fdr_cutoff)

  # ---- Tier 2: top (exclude already-found modules) ---------------------------
  found_in_tier1 <- res1$global_module_id
  res2 <- run_ora(
    sig_top %>% filter(!global_module_id %in% found_in_tier1),
    ids, col, min_hits, fdr_cutoff
  )

  cat(sprintf("[query:%s] Tier-1 (anchor): %d | Tier-2 (top): %d significant modules\n",
              level, nrow(res1), nrow(res2)))

  # ---- Combine ---------------------------------------------------------------
  bind_rows(
    res1 %>% mutate(match_tier = "anchor"),
    res2 %>% mutate(match_tier = "top")
  ) %>%
    mutate(result_level = level) %>%
    left_join(mod_info, by = "global_module_id") %>%
    left_join(sig_stats, by = c("global_module_id", "match_tier" = "tier")) %>%
    arrange(match_tier, p_ora) %>%
    select(
      result_level, match_tier, global_module_id, study_id, phenotype, biospecimen,
      title, hypothesis_type, confidence_label,
      n_instances, n_studies, n_phenotypes, n_biospecimens, instance_ids,
      n_hit, n_sig, coverage_pct, p_ora, fdr_ora,
      n_signature_resolved, n_signature_unmatched, signature_resolution_pct,
      matched_names, anchor_metabolites, core_drivers,
      functional_summary, phenotype_relationship, top_kegg_pathways
    )
}

# =============================================================================
# Pretty-print helper
# =============================================================================

print_query_result <- function(res, top_n = 20) {
  if (nrow(res) == 0) {
    cat("No significant modules found.\n")
    return(invisible(NULL))
  }

  cat(sprintf("\n=== PhenoMAP Query Results (top %d) ===\n\n", min(top_n, nrow(res))))

  res %>%
    slice_head(n = top_n) %>%
    rowwise() %>%
    group_walk(~ {
      r <- .x
      idx <- which(res$global_module_id == r$global_module_id)[1]
      cat(sprintf("%-3d [%s] <%s>\n", idx, r$global_module_id, r$match_tier))
      cat(sprintf("    Title:    %s\n", r$title))
      cat(sprintf("    Type:     %s | Confidence: %s\n",
                  r$hypothesis_type, r$confidence_label))
      if ("result_level" %in% names(r) && r$result_level == "atlas") {
        cat(sprintf("    Evidence: %d instances | %d studies | %d phenotypes\n",
                    r$n_instances, r$n_studies, r$n_phenotypes))
        cat(sprintf("    Phenotypes:%s\n", str_trunc(coalesce(r$phenotype, "NA"), 120)))
      } else {
        cat(sprintf("    Phenotype:%s\n", coalesce(r$phenotype, "NA")))
      }
      cat(sprintf("    Coverage: %d/%d (%.1f%%) | p=%.3g | FDR=%.3g\n",
                  r$n_hit, r$n_sig, r$coverage_pct, r$p_ora, r$fdr_ora))
      if ("signature_resolution_pct" %in% names(r)) {
        cat(sprintf("    Resolved: %d/%d signature IDs (%.1f%%)\n",
                    r$n_signature_resolved,
                    r$n_signature_resolved + r$n_signature_unmatched,
                    r$signature_resolution_pct))
      }
      cat(sprintf("    Hits:     %s\n", str_trunc(r$matched_names, 100)))
      cat("\n")
    })

  invisible(res)
}
