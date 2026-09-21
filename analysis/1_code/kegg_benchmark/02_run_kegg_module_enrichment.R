# KEGG benchmark, step 2: run PhenoMAP module enrichment once per KEGG human
# metabolic pathway, using the pathway's compound set as the input list.
#
# Uses run_module_enrichment() from code/module_enrichment.R unchanged, with
# the same defaults as the website (core + supporting members, all modules,
# FDR < 0.05, overlap >= 2). The data are loaded once and reused.
#
# Run from the project root, after step 1:
#   Rscript analysis/1_code/kegg_benchmark/02_run_kegg_module_enrichment.R
#
# Output (analysis/3_result/kegg_benchmark/):
#   kegg_module_enrichment_by_pathway.csv
#     one row per pathway: input size, matched size, tested / significant
#     module counts
#   kegg_module_enrichment_significant_modules.csv
#     every significant module for every pathway, with Sig_Rank = 1 being the
#     most significant (the website's ordering: FDR, then enrichment ratio,
#     then overlap)

# ------------------------------------------------------------ settings ----
project_dir <- normalizePath(getwd())
if (!file.exists(file.path(project_dir, "phenomap.Rproj"))) {
  stop("Run this script from the project root (the folder containing phenomap.Rproj).")
}

data_dir <- file.path(project_dir, "analysis", "2_data", "kegg_benchmark")
result_dir <- file.path(project_dir, "analysis", "3_result", "kegg_benchmark")
dir.create(result_dir, recursive = TRUE, showWarnings = FALSE)

import_dir <- file.path(project_dir, "neo4j", "import")
enrichment_script <- file.path(project_dir, "code", "module_enrichment.R")

fdr_cutoff <- 0.05
min_overlap <- 2
member_types <- c("core", "supporting")

# ------------------------------------------------------------ inputs ------
source(enrichment_script)

pathways <- utils::read.csv(file.path(data_dir, "kegg_human_metabolic_pathways.csv"),
                            stringsAsFactors = FALSE, colClasses = "character")
pathways$Compound_N <- as.integer(pathways$Compound_N)
compounds <- utils::read.csv(file.path(data_dir, "kegg_human_metabolic_pathway_compounds.csv"),
                             stringsAsFactors = FALSE, colClasses = "character")
compounds_by_pathway <- split(compounds$KEGG_ID, compounds$Pathway_ID)

message("Loading PhenoMAP enrichment data ...")
enrich_data <- load_enrichment_data(import_dir = import_dir)

# ------------------------------------------------------------ run ---------
summary_rows <- vector("list", nrow(pathways))
sig_rows <- vector("list", nrow(pathways))

sig_cols <- c("Module_ID", "title", "Study_ID", "hypothesis_type", "confidence_label",
              "Overlap_N", "Module_Set_Size", "Input_N", "Background_N",
              "P_Value", "FDR", "Enrichment_Ratio")

for (i in seq_len(nrow(pathways))) {
  pid <- pathways$Pathway_ID[i]
  ids <- compounds_by_pathway[[pid]]
  message(sprintf("[%d/%d] %s  %s  (%d compounds)", i, nrow(pathways), pid,
                  pathways$Pathway_Name[i], length(ids)))

  matched_n <- 0L
  tested_n <- 0L
  sig <- NULL
  status <- "ok"

  if (length(ids) == 0) {
    status <- "no_compounds"
  } else {
    res <- tryCatch(
      run_module_enrichment(
        input_ids = ids, id_type = "kegg", data = enrich_data,
        member_types = member_types, fdr_cutoff = fdr_cutoff, min_overlap = min_overlap
      ),
      error = function(e) e
    )
    if (inherits(res, "error")) {
      status <- paste("error:", conditionMessage(res))
    } else {
      matched_n <- as.integer(res$parameters$matched_background_n)
      tested_n <- as.integer(res$parameters$tested_module_n)
      tab <- res$enrichment  # already sorted by FDR, -Enrichment_Ratio, -Overlap_N
      tab <- tab[tab$Significant, intersect(sig_cols, colnames(tab)), drop = FALSE]
      if (nrow(tab) > 0) {
        sig <- data.frame(Pathway_ID = pid, Sig_Rank = seq_len(nrow(tab)), tab,
                          stringsAsFactors = FALSE, check.names = FALSE)
      }
      if (matched_n == 0) status <- "no_compound_in_phenomap"
    }
  }

  summary_rows[[i]] <- data.frame(
    Pathway_ID = pid,
    Pathway_Name = pathways$Pathway_Name[i],
    Category = pathways$Category[i],
    Compound_N = pathways$Compound_N[i],
    Matched_In_PhenoMAP_N = matched_n,
    Tested_Module_N = tested_n,
    Significant_Module_N = if (is.null(sig)) 0L else nrow(sig),
    Status = status,
    stringsAsFactors = FALSE
  )
  sig_rows[[i]] <- sig
}

by_pathway <- do.call(rbind, summary_rows)
significant <- do.call(rbind, sig_rows[!vapply(sig_rows, is.null, logical(1))])
if (is.null(significant)) {
  significant <- data.frame(Pathway_ID = character(0), Sig_Rank = integer(0))
}

# ------------------------------------------------------------ write -------
utils::write.csv(by_pathway, file.path(result_dir, "kegg_module_enrichment_by_pathway.csv"), row.names = FALSE)
utils::write.csv(significant, file.path(result_dir, "kegg_module_enrichment_significant_modules.csv"), row.names = FALSE)

message(sprintf("Done. %d pathways, %d with >= 1 significant module.",
                nrow(by_pathway), sum(by_pathway$Significant_Module_N > 0)))
message("Written to ", result_dir)
