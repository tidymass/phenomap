# KEGG benchmark, step 3: coverage of KEGG human metabolic pathways by PhenoMAP
# module enrichment.
#
# Coverage rule:
#   a pathway is COVERED if
#     (1) module enrichment returns >= 1 significant module, AND
#     (2) the most significant module (Sig_Rank = 1) has
#         ROUGE-L(module title, KEGG pathway name) = 1.
#
# ROUGE-L here is the token-level longest-common-subsequence F1
# (beta = 1). Text is lower-cased and every non-alphanumeric character is
# treated as a separator, so "Glycolysis / Gluconeogenesis" and
# "Glycolysis/Gluconeogenesis" are the same token sequence. ROUGE-L = 1
# therefore means the two names are identical up to case and punctuation.
#
# Run from the project root, after step 2:
#   Rscript analysis/1_code/kegg_benchmark/03_kegg_coverage_rougeL.R
#
# Output (analysis/3_result/kegg_benchmark/):
#   kegg_coverage_by_pathway.csv    one row per pathway, top module + ROUGE-L + Covered
#   kegg_coverage_by_category.csv   coverage per KEGG metabolism category
#   kegg_coverage_report.txt        overall coverage

# ------------------------------------------------------------ settings ----
project_dir <- normalizePath(getwd())
if (!file.exists(file.path(project_dir, "phenomap.Rproj"))) {
  stop("Run this script from the project root (the folder containing phenomap.Rproj).")
}
result_dir <- file.path(project_dir, "analysis", "3_result", "kegg_benchmark")

# ------------------------------------------------------------ ROUGE-L -----
tokenize <- function(x) {
  x <- tolower(ifelse(is.na(x), "", x))
  x <- gsub("[^[:alnum:]]+", " ", x)
  toks <- strsplit(trimws(x), "\\s+")
  lapply(toks, function(t) t[nzchar(t)])
}

lcs_length <- function(a, b) {
  if (length(a) == 0 || length(b) == 0) return(0L)
  prev <- integer(length(b) + 1)
  for (i in seq_along(a)) {
    cur <- integer(length(b) + 1)
    for (j in seq_along(b)) {
      cur[j + 1] <- if (a[i] == b[j]) prev[j] + 1L else max(prev[j + 1], cur[j])
    }
    prev <- cur
  }
  prev[length(b) + 1]
}

rouge_l <- function(candidate, reference) {
  cand <- tokenize(candidate)
  ref <- tokenize(reference)
  mapply(function(c, r) {
    lcs <- lcs_length(c, r)
    if (lcs == 0) return(0)
    p <- lcs / length(c)
    rc <- lcs / length(r)
    2 * p * rc / (p + rc)
  }, cand, ref)
}

# ------------------------------------------------------------ inputs ------
by_pathway <- utils::read.csv(file.path(result_dir, "kegg_module_enrichment_by_pathway.csv"),
                              stringsAsFactors = FALSE)
significant <- utils::read.csv(file.path(result_dir, "kegg_module_enrichment_significant_modules.csv"),
                               stringsAsFactors = FALSE)

top <- significant[significant$Sig_Rank == 1,
                   c("Pathway_ID", "Module_ID", "title", "hypothesis_type", "FDR", "Overlap_N"),
                   drop = FALSE]
colnames(top) <- c("Pathway_ID", "Top_Module_ID", "Top_Module_Title", "Top_Module_Hypothesis_Type",
                   "Top_Module_FDR", "Top_Module_Overlap_N")

cov <- merge(by_pathway, top, by = "Pathway_ID", all.x = TRUE, sort = FALSE)
cov$Has_Significant_Module <- cov$Significant_Module_N > 0
cov$ROUGE_L <- ifelse(cov$Has_Significant_Module,
                      rouge_l(cov$Top_Module_Title, cov$Pathway_Name), NA_real_)
cov$Covered <- cov$Has_Significant_Module & !is.na(cov$ROUGE_L) & cov$ROUGE_L >= 1 - 1e-9
cov <- cov[order(cov$Category, cov$Pathway_ID), , drop = FALSE]
rownames(cov) <- NULL

# ------------------------------------------------------------ summaries ---
# Pathways with < 2 compounds in PhenoMAP can never reach min_overlap = 2, so
# coverage is also reported over the "testable" subset.
cov$Testable <- cov$Matched_In_PhenoMAP_N >= 2

summarise <- function(d) {
  data.frame(
    Pathway_N = nrow(d),
    Testable_N = sum(d$Testable),
    With_Significant_Module_N = sum(d$Has_Significant_Module),
    Covered_N = sum(d$Covered),
    Coverage_All = if (nrow(d) > 0) sum(d$Covered) / nrow(d) else NA_real_,
    Coverage_Testable = if (sum(d$Testable) > 0) sum(d$Covered & d$Testable) / sum(d$Testable) else NA_real_,
    stringsAsFactors = FALSE
  )
}

by_category <- do.call(rbind, lapply(split(cov, cov$Category), function(d) {
  cbind(Category = d$Category[1], summarise(d))
}))
by_category <- by_category[order(-by_category$Coverage_All), , drop = FALSE]
rownames(by_category) <- NULL
overall <- summarise(cov)

# ------------------------------------------------------------ write -------
utils::write.csv(cov, file.path(result_dir, "kegg_coverage_by_pathway.csv"), row.names = FALSE)
utils::write.csv(by_category, file.path(result_dir, "kegg_coverage_by_category.csv"), row.names = FALSE)

pct <- function(x) sprintf("%.1f%%", 100 * x)
report <- c(
  "KEGG human metabolic pathway coverage by PhenoMAP module enrichment",
  "",
  "Covered = >= 1 significant module (FDR < 0.05, overlap >= 2) AND",
  "          ROUGE-L(top module title, KEGG pathway name) = 1",
  "",
  sprintf("KEGG human metabolic pathways:            %d", overall$Pathway_N),
  sprintf("Testable (>= 2 compounds in PhenoMAP):    %d", overall$Testable_N),
  sprintf("With >= 1 significant module:             %d", overall$With_Significant_Module_N),
  sprintf("Covered:                                  %d", overall$Covered_N),
  "",
  sprintf("Coverage over all pathways:               %s", pct(overall$Coverage_All)),
  sprintf("Coverage over testable pathways:          %s", pct(overall$Coverage_Testable)),
  "",
  "By category (covered / all):",
  sprintf("  %-50s %3d / %3d  (%s)", by_category$Category, by_category$Covered_N,
          by_category$Pathway_N, pct(by_category$Coverage_All))
)
writeLines(report, file.path(result_dir, "kegg_coverage_report.txt"))
cat(report, sep = "\n")
