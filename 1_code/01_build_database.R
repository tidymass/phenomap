# =============================================================================
# PhenoMAP v0.1 — Build SQLite Database
#
# Input:  featuremap_case/3_data_analysis/phenomap/study_exports/
# Output: 2_data/phenomap_v0.1.db
#
# Tables:
#   study   — one row per study (metadata)
#   module  — one row per significant module
#   member  — one row per module member (INCHI_ID level)
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(DBI)
  library(RSQLite)
  library(jsonlite)
})

# ---- Paths -------------------------------------------------------------------
EXPORT_DIR <- "../featuremap_case/3_data_analysis/phenomap/study_exports"
DB_PATH    <- "2_data/phenomap_v0.1.db"

dir.create("2_data", showWarnings = FALSE)

# ---- Artifact/technical studies to exclude -----------------------------------
EXCLUDE_STUDIES <- c(
  "MTBLS1785",   # technical: xenobiotic spike benchmark
  "MTBLS13382",  # methodology: DBS vs serum comparison
  "MTBLS2427",   # nutritional supplementation on sweat
  "MTBLS4437",   # archaeological bone samples
  "MTBLS4556",   # Nigeria vs Austria exposome
  "MTBLS842"     # breath filter standardization
)

# ---- Artifact xenobiotic module titles to exclude ----------------------------
BAD_TITLE_KEYWORDS <- c(
  "kanamycin", "gentamicin", "neomycin", "gibberellin",
  "trichlorobenzene", "chloroethane", "nitroalkane",
  "avermectin", "pilocarpine", "isoniazid"
)

is_bad_title <- function(title) {
  any(str_detect(tolower(title), BAD_TITLE_KEYWORDS))
}

# ---- Load all study exports --------------------------------------------------
study_dirs <- list.dirs(EXPORT_DIR, full.names = TRUE, recursive = FALSE)
study_dirs <- study_dirs[!basename(study_dirs) %in% EXCLUDE_STUDIES]

cat("Loading", length(study_dirs), "studies...\n")

study_list  <- list()
module_list <- list()
member_list <- list()
sig_list    <- list()

for (d in study_dirs) {
  sid <- basename(d)

  meta_path   <- file.path(d, "study_meta.csv")
  ann_path    <- file.path(d, "annotation.csv")
  scores_path <- file.path(d, "scores.csv")
  mem_path    <- file.path(d, "members.csv")

  if (!file.exists(ann_path) || !file.exists(scores_path) || !file.exists(mem_path)) next

  # ---- study table -----------------------------------------------------------
  if (file.exists(meta_path)) {
    meta <- read_csv(meta_path, show_col_types = FALSE)
  } else {
    meta <- tibble(study_id = sid)
  }
  study_list[[sid]] <- meta

  # ---- scores + annotation → module table ------------------------------------
  scores <- read_csv(scores_path, show_col_types = FALSE)
  ann    <- read_csv(ann_path,    show_col_types = FALSE)

  modules <- scores %>%
    left_join(ann, by = c("global_module_id", "study_id")) %>%
    filter(!map_lgl(coalesce(title, ""), is_bad_title)) %>%
    transmute(
      global_module_id,
      study_id,
      module_local_id  = Module,
      module_size      = as.integer(Module_size),
      annotated_nodes  = as.integer(Annotated_nodes),
      module_score     = as.numeric(Module_score),
      p_value          = as.numeric(p),
      fdr              = as.numeric(fdr),
      hypothesis_type,
      title,
      functional_summary,
      anchor_metabolites,
      confidence_label,
      phenotype_relationship,
      rationale,
      core_drivers,
      top_kegg_pathways,
      top_hmdb_pathways,
      pubmed_pmids,
      phenotype   = meta$phenotype[1]   %||% NA_character_,
      biospecimen = meta$biospecimen[1] %||% NA_character_
    )

  module_list[[sid]] <- modules

  # ---- members table ---------------------------------------------------------
  members <- read_csv(mem_path, show_col_types = FALSE) %>%
    filter(global_module_id %in% modules$global_module_id) %>%
    transmute(
      global_module_id,
      study_id,
      INCHI_ID,
      HMDB_ID,
      KEGG_ID,
      Compound_name,
      feature_type     = Type,
      node_freq        = as.numeric(Node_freq),
      importance       = as.numeric(Importance),
      use_for_annotation = as.logical(Use_for_annotation),
      is_core_driver   = as.logical(is_core_driver)
    )

  member_list[[sid]] <- members

  # ---- signature table -------------------------------------------------------
  sig_path <- file.path(d, "signature.csv")
  if (file.exists(sig_path)) {
    sig <- read_csv(sig_path, show_col_types = FALSE) %>%
      filter(global_module_id %in% modules$global_module_id) %>%
      transmute(
        global_module_id,
        study_id,
        INCHI_ID,
        HMDB_ID,
        KEGG_ID,
        Compound_name,
        tier,                              # "anchor" | "top"
        weighted_score = as.numeric(weighted_score),
        priority_level                     # "high" | "medium" | "low"
      )
    sig_list[[sid]] <- sig
  }
}

# ---- Combine -----------------------------------------------------------------
study_tbl  <- bind_rows(study_list)  %>% distinct(study_id, .keep_all = TRUE)
module_tbl <- bind_rows(module_list)
member_tbl <- bind_rows(member_list)
sig_tbl    <- bind_rows(sig_list)

cat(sprintf(
  "Studies: %d | Modules: %d | Members: %d | Signature rows: %d\n",
  nrow(study_tbl), nrow(module_tbl), nrow(member_tbl), nrow(sig_tbl)
))

# ---- Write SQLite ------------------------------------------------------------
con <- dbConnect(SQLite(), DB_PATH)

dbWriteTable(con, "study",  study_tbl,  overwrite = TRUE)
dbWriteTable(con, "module", module_tbl, overwrite = TRUE)
dbWriteTable(con, "member", member_tbl, overwrite = TRUE)

# Indexes for fast lookup
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_member_inchi   ON member(INCHI_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_member_hmdb    ON member(HMDB_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_member_kegg    ON member(KEGG_ID)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_member_module  ON member(global_module_id)"))
invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_module_study   ON module(study_id)"))

# signature table (prefer exported signature.csv; otherwise derive from module/member)
if (nrow(sig_tbl) > 0) {
  dbWriteTable(con, "signature", sig_tbl, overwrite = TRUE)
  invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_inchi  ON signature(INCHI_ID)"))
  invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_hmdb   ON signature(HMDB_ID)"))
  invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_kegg   ON signature(KEGG_ID)"))
  invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_module ON signature(global_module_id)"))
  invisible(dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_sig_tier   ON signature(tier)"))
  cat(sprintf("Signature table written: %d rows\n", nrow(sig_tbl)))
} else {
  cat("No signature.csv found — deriving signature from module/member tables after DB write.\n")
}

dbDisconnect(con)

if (nrow(sig_tbl) == 0) {
  source("1_code/04_build_signature.R")
}

source("1_code/05_build_atlas_modules.R")

cat("Database written to:", DB_PATH, "\n")

# ---- Quick summary -----------------------------------------------------------
con <- dbConnect(SQLite(), DB_PATH)

cat("\n=== PhenoMAP v0.1 Summary ===\n")
cat("Studies:  ", dbGetQuery(con, "SELECT COUNT(*) FROM study")[[1]], "\n")
cat("Modules:  ", dbGetQuery(con, "SELECT COUNT(*) FROM module")[[1]], "\n")
cat("Members:  ", dbGetQuery(con, "SELECT COUNT(*) FROM member")[[1]], "\n")

cat("\n--- Modules by hypothesis_type ---\n")
print(dbGetQuery(con, "
  SELECT hypothesis_type, COUNT(*) as n
  FROM module GROUP BY hypothesis_type ORDER BY n DESC"))

cat("\n--- Modules by confidence_label ---\n")
print(dbGetQuery(con, "
  SELECT confidence_label, COUNT(*) as n
  FROM module GROUP BY confidence_label ORDER BY n DESC"))

cat("\n--- Top phenotypes (by module count) ---\n")
print(dbGetQuery(con, "
  SELECT phenotype, COUNT(*) as n_modules
  FROM module
  WHERE phenotype IS NOT NULL AND phenotype != 'NA'
  GROUP BY phenotype ORDER BY n_modules DESC LIMIT 15"))

dbDisconnect(con)
