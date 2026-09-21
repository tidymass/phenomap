# KEGG benchmark, step 1: build the list of human metabolic pathways and their
# compound sets.
#
# Definition of "human metabolic pathway":
#   * listed in KEGG list/pathway/hsa (exists for Homo sapiens), AND
#   * classified under "Metabolism" in the KEGG pathway hierarchy (br08901),
#   * excluding "Global and overview maps" (01100, 01200, ...) and
#     "Chemical structure transformation maps" (01010, 01060, ...), which are
#     aggregates of other maps rather than pathways.
#
# Compounds come from KEGG link at map level (the reference pathway; KEGG
# attaches compounds to mapXXXXX, not to hsaXXXXX). The bulk link
# (link/pathway/compound) is tried first; if KEGG rejects it, the script falls
# back to one link/compound/mapXXXXX call per pathway.
#
# Raw KEGG responses are cached in analysis/2_data/kegg_benchmark/raw/ so the
# script only hits the KEGG API once. Delete that folder to re-download.
#
# Run from the project root (the folder containing phenomap.Rproj):
#   Rscript analysis/1_code/kegg_benchmark/01_fetch_kegg_human_metabolic_pathways.R
#
# Output:
#   analysis/2_data/kegg_benchmark/kegg_human_metabolic_pathways.csv
#     one row per pathway: Pathway_ID, Pathway_Name, Category, Compound_N
#   analysis/2_data/kegg_benchmark/kegg_human_metabolic_pathway_compounds.csv
#     one row per (pathway, compound): Pathway_ID, KEGG_ID

suppressPackageStartupMessages(library(jsonlite))

# ------------------------------------------------------------ settings ----
project_dir <- normalizePath(getwd())
if (!file.exists(file.path(project_dir, "phenomap.Rproj"))) {
  stop("Run this script from the project root (the folder containing phenomap.Rproj).")
}

out_dir <- file.path(project_dir, "analysis", "2_data", "kegg_benchmark")
raw_dir <- file.path(out_dir, "raw")
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

excluded_categories <- c("Global and overview maps", "Chemical structure transformation maps")

kegg_urls <- c(
  hsa_pathways = "https://rest.kegg.jp/list/pathway/hsa",
  hierarchy    = "https://rest.kegg.jp/get/br:br08901/json"
)

# ------------------------------------------------------------ download ----
fetch_cached <- function(name, url, must_succeed = TRUE) {
  path <- file.path(raw_dir, paste0(name, ".txt"))
  if (!file.exists(path) || file.info(path)$size == 0) {
    message("Downloading ", url)
    ok <- tryCatch({
      utils::download.file(url, path, quiet = TRUE, mode = "wb")
      TRUE
    }, error = function(e) {
      if (file.exists(path)) unlink(path)
      if (must_succeed) stop(e)
      message("  failed: ", conditionMessage(e))
      FALSE
    }, warning = function(w) {
      if (file.exists(path)) unlink(path)
      if (must_succeed) stop(w)
      message("  failed: ", conditionMessage(w))
      FALSE
    })
    Sys.sleep(0.4)  # be polite to the KEGG API
    if (!ok) return(NA_character_)
  } else {
    message("Using cached ", path)
  }
  path
}

raw_paths <- mapply(fetch_cached, names(kegg_urls), kegg_urls)

# ------------------------------------------------- 1. human pathway list ----
# Lines look like: "hsa00010\tGlycolysis / Gluconeogenesis - Homo sapiens (human)"
hsa_lines <- readLines(raw_paths[["hsa_pathways"]], warn = FALSE)
hsa_lines <- hsa_lines[nzchar(hsa_lines)]
hsa_split <- strsplit(hsa_lines, "\t", fixed = TRUE)
hsa <- data.frame(
  hsa_id = sub("^path:", "", vapply(hsa_split, `[`, "", 1)),
  hsa_name = vapply(hsa_split, `[`, "", 2),
  stringsAsFactors = FALSE
)
hsa$map_number <- sub("^hsa", "", hsa$hsa_id)
hsa$Pathway_Name <- trimws(sub("\\s+-\\s+Homo sapiens \\(human\\)$", "", hsa$hsa_name))

# ------------------------------------------ 2. KEGG pathway hierarchy -------
# br08901 JSON: top level (e.g. "Metabolism") -> subcategory -> leaf
# leaf names look like "00010  Glycolysis / Gluconeogenesis"
hier <- jsonlite::fromJSON(raw_paths[["hierarchy"]], simplifyVector = FALSE)

hier_rows <- list()
for (top in hier$children) {
  for (sub_cat in top$children) {
    for (leaf in sub_cat$children) {
      m <- regmatches(leaf$name, regexec("^(\\d{5})\\s+(.*)$", leaf$name))[[1]]
      if (length(m) == 3) {
        hier_rows[[length(hier_rows) + 1]] <- data.frame(
          map_number = m[2], Top_Level = top$name, Category = sub_cat$name,
          stringsAsFactors = FALSE
        )
      }
    }
  }
}
hier_df <- unique(do.call(rbind, hier_rows))

pathways <- merge(hsa, hier_df, by = "map_number", all.x = FALSE)
pathways <- pathways[
  pathways$Top_Level == "Metabolism" & !(pathways$Category %in% excluded_categories), ,
  drop = FALSE
]
pathways$Pathway_ID <- pathways$hsa_id

# ------------------------------------------------- 3. compound sets ---------
# Parse "path:map00010<TAB>cpd:C00022" lines in either column order.
parse_links <- function(lines) {
  lines <- lines[nzchar(lines)]
  parts <- strsplit(lines, "\t", fixed = TRUE)
  a <- vapply(parts, `[`, "", 1)
  b <- vapply(parts, `[`, "", 2)
  path <- ifelse(grepl("^path:map", a), a, b)
  cpd <- ifelse(grepl("^cpd:", a), a, b)
  keep <- grepl("^path:map\\d{5}$", path) & grepl("^cpd:C\\d{5}$", cpd)
  data.frame(map_number = sub("^path:map", "", path[keep]),
             KEGG_ID = sub("^cpd:", "", cpd[keep]),
             stringsAsFactors = FALSE)
}

bulk_path <- fetch_cached("compounds_bulk", "https://rest.kegg.jp/link/pathway/compound",
                          must_succeed = FALSE)
links <- if (!is.na(bulk_path)) parse_links(readLines(bulk_path, warn = FALSE)) else NULL

if (is.null(links) || nrow(links) == 0) {
  message("Bulk link unavailable; fetching compounds pathway by pathway ...")
  per_dir <- file.path(raw_dir, "per_pathway")
  dir.create(per_dir, showWarnings = FALSE)
  links <- do.call(rbind, lapply(unique(pathways$map_number), function(num) {
    p <- fetch_cached(file.path("per_pathway", paste0("map", num)),
                      paste0("https://rest.kegg.jp/link/compound/map", num),
                      must_succeed = FALSE)
    if (is.na(p)) return(NULL)  # KEGG returns an error / empty body for maps without compounds
    parse_links(readLines(p, warn = FALSE))
  }))
}

compounds <- merge(pathways[, c("Pathway_ID", "map_number")], links[, c("map_number", "KEGG_ID")],
                   by = "map_number")
compounds <- unique(compounds[, c("Pathway_ID", "KEGG_ID")])
compounds <- compounds[order(compounds$Pathway_ID, compounds$KEGG_ID), , drop = FALSE]

pathways$Compound_N <- as.integer(table(factor(compounds$Pathway_ID, levels = pathways$Pathway_ID)))
pathways <- pathways[order(pathways$Pathway_ID),
                     c("Pathway_ID", "Pathway_Name", "Category", "Compound_N"), drop = FALSE]
rownames(pathways) <- NULL

# ------------------------------------------------------------ write ---------
utils::write.csv(pathways, file.path(out_dir, "kegg_human_metabolic_pathways.csv"), row.names = FALSE)
utils::write.csv(compounds, file.path(out_dir, "kegg_human_metabolic_pathway_compounds.csv"), row.names = FALSE)

message(sprintf("Human metabolic pathways: %d (%d with >= 1 compound)",
                nrow(pathways), sum(pathways$Compound_N > 0)))
message(sprintf("Pathway-compound links: %d", nrow(compounds)))
message("Written to ", out_dir)
