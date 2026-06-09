# =============================================================================
# PhenoMAP v0.1 — Validation: Known differential metabolite lists
#
# 用已知的差异代谢物列表验证查询结果的生物学合理性
# Test cases:
#   1. T2D (Type 2 Diabetes) — well-characterized metabolite panel
#   2. Gout (uric acid pathway + purines)
# =============================================================================

setwd("/Users/yuting/Documents/AtNTUlife/ShenLab/1_MyProject/featureFMA/phenomap")

source("1_code/02_query.R")

# =============================================================================
# Test 1: Type 2 Diabetes (T2D) known differential metabolites
# Source: representative meta-analysis hits (HMDB IDs)
# Chen et al. 2022 Diabetes Care, Floegel et al. Diabetologia, etc.
# =============================================================================

cat("\n", rep("=", 70), "\n", sep = "")
cat("TEST 1: Type 2 Diabetes (T2D) known metabolite panel\n")
cat(rep("=", 70), "\n\n", sep = "")

# Well-established T2D-associated metabolites (HMDB IDs)
t2d_hmdb <- c(
  # BCAAs (branched-chain amino acids) — robustly elevated in T2D
  "HMDB0000687",  # Leucine
  "HMDB0000687",  # Isoleucine (HMDB0000172)
  "HMDB0000172",  # Isoleucine
  "HMDB0000883",  # Valine
  # Aromatic amino acids
  "HMDB0000159",  # Phenylalanine
  "HMDB0000158",  # Tyrosine
  "HMDB0000929",  # Tryptophan
  # Acylcarnitines
  "HMDB0000062",  # Carnitine
  "HMDB0000201",  # Acetylcarnitine (C2)
  "HMDB0000201",  # Propionylcarnitine (C3) HMDB0000824
  "HMDB0000824",  # Propionylcarnitine
  "HMDB0000736",  # Butyrylcarnitine (C4)
  # Organic acids
  "HMDB0000243",  # Pyruvate
  "HMDB0000072",  # Citric acid
  "HMDB0000011",  # Alpha-ketoglutarate (2-oxoglutarate)
  # Lipid-related
  "HMDB0000517",  # Palmitic acid (C16:0)
  "HMDB0001338",  # Stearic acid (C18:0)
  # Sugar metabolism
  "HMDB0000122",  # Glucose
  "HMDB0001058",  # Fructose
  "HMDB0000606",  # Galactose (HMDB0000143)
  "HMDB0000143",  # Galactose
  # Bile acids
  "HMDB0000619",  # Cholic acid
  "HMDB0000138",  # Glycocholic acid
  "HMDB0000263"   # Taurocholic acid
)
t2d_hmdb <- unique(t2d_hmdb)

res_t2d <- query_phenomap(
  ids         = t2d_hmdb,
  id_type     = "HMDB",
  min_hits    = 2,
  fdr_cutoff  = 0.1   # show all to see coverage
)

cat(sprintf("\n[T2D] Total modules with ≥2 hits: %d\n\n", nrow(res_t2d)))

if (nrow(res_t2d) > 0) {
  cat("--- Top 20 results (sorted by p_ora) ---\n\n")
  print_query_result(res_t2d, top_n = 20)

  # Check if T2D or diabetes-related modules appear
  t2d_hits <- res_t2d %>%
    filter(str_detect(tolower(phenotype), "diabet|t2d|glucose|insulin|obesity") |
           str_detect(tolower(title), "diabet|glucose|insulin|branched.chain|amino acid|acylcarnitine"))

  cat(sprintf("[Validation] Modules matching T2D-related keywords: %d/%d\n",
              nrow(t2d_hits), nrow(res_t2d)))
  if (nrow(t2d_hits) > 0) {
    cat("  →", paste(t2d_hits$global_module_id, collapse = ", "), "\n")
    cat("  Phenotypes:", paste(unique(t2d_hits$phenotype), collapse = "; "), "\n")
    cat("  Titles:\n")
    for (i in seq_len(nrow(t2d_hits))) {
      cat(sprintf("    [%s] %s\n", t2d_hits$global_module_id[i], t2d_hits$title[i]))
    }
  }
} else {
  cat("[T2D] No modules found — check HMDB ID format in database.\n")
  # Debug: check what HMDB IDs look like in DB
  con <- dbConnect(SQLite(), "2_data/phenomap_v0.1.db")
  sample_hmdb <- dbGetQuery(con, "SELECT DISTINCT HMDB_ID FROM member WHERE HMDB_ID IS NOT NULL LIMIT 10")
  cat("Sample HMDB_IDs in DB:", paste(sample_hmdb$HMDB_ID, collapse = ", "), "\n")
  dbDisconnect(con)
}

# =============================================================================
# Test 2: Gout — purine / uric acid metabolism
# =============================================================================

cat("\n", rep("=", 70), "\n", sep = "")
cat("TEST 2: Gout — purine & uric acid pathway metabolites\n")
cat(rep("=", 70), "\n\n", sep = "")

gout_hmdb <- c(
  "HMDB0000289",  # Uric acid
  "HMDB0000034",  # Adenine
  "HMDB0000050",  # Adenosine
  "HMDB0000143",  # Hypoxanthine (HMDB0000157)
  "HMDB0000157",  # Hypoxanthine
  "HMDB0000296",  # Xanthine
  "HMDB0000292",  # Xanthosine
  "HMDB0000133",  # Guanine
  "HMDB0000195",  # Guanosine
  "HMDB0000262",  # Inosine
  "HMDB0000289",  # Urate
  "HMDB0001431",  # Allantoin (downstream oxidation)
  "HMDB0000192"   # Hypoxanthine riboside
)
gout_hmdb <- unique(gout_hmdb)

res_gout <- query_phenomap(
  ids         = gout_hmdb,
  id_type     = "HMDB",
  min_hits    = 2,
  fdr_cutoff  = 0.1
)

cat(sprintf("\n[Gout] Total modules with ≥2 hits: %d\n\n", nrow(res_gout)))

if (nrow(res_gout) > 0) {
  print_query_result(res_gout, top_n = 15)

  gout_hits <- res_gout %>%
    filter(str_detect(tolower(phenotype), "gout|uric|purine") |
           str_detect(tolower(title), "purine|uric|xanthine|hypoxanthine|gout"))

  cat(sprintf("[Validation] Modules matching gout-related keywords: %d/%d\n",
              nrow(gout_hits), nrow(res_gout)))
  if (nrow(gout_hits) > 0) {
    for (i in seq_len(nrow(gout_hits))) {
      cat(sprintf("  → [%s] phenotype=%s | %s\n",
                  gout_hits$global_module_id[i],
                  coalesce(gout_hits$phenotype[i], "NA"),
                  gout_hits$title[i]))
    }
  }
}

# =============================================================================
# Diagnostic: DB content check
# =============================================================================

cat("\n", rep("=", 70), "\n", sep = "")
cat("DIAGNOSTIC: Database content check\n")
cat(rep("=", 70), "\n\n", sep = "")

con <- dbConnect(SQLite(), "2_data/phenomap_v0.1.db")

cat("Core drivers with HMDB_ID:\n")
print(dbGetQuery(con, "SELECT COUNT(*) AS total, COUNT(HMDB_ID) AS with_hmdb, COUNT(KEGG_ID) AS with_kegg FROM member WHERE is_core_driver=1"))

cat("\nSample core driver HMDB_IDs:\n")
print(dbGetQuery(con, "SELECT HMDB_ID, Compound_name FROM member WHERE HMDB_ID IS NOT NULL AND is_core_driver=1 LIMIT 15"))

cat("\nSample core driver KEGG_IDs:\n")
print(dbGetQuery(con, "SELECT KEGG_ID, Compound_name FROM member WHERE KEGG_ID IS NOT NULL AND is_core_driver=1 LIMIT 10"))

dbDisconnect(con)
