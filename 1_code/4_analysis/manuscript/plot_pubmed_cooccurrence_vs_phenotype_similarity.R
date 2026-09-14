# Compare pairwise phenotype similarity with PubMed co-occurrence counts.
#
# A PubMed co-occurrence is defined as a record in which both phenotype terms
# occur in the title or abstract. A small set of explicit aliases handles clear
# nomenclature changes or widely used abbreviations. All generated queries and
# retrieved counts are saved for inspection and reproducibility.
#
# The script checkpoints API results and can be rerun after an interruption.
# It does not modify any existing PhenoMAP analysis or figure.
#
# Run from the repository root:
#   Rscript 1_code/4_analysis/manuscript/plot_pubmed_cooccurrence_vs_phenotype_similarity.R
#
# Optional arguments:
#   --input_dir=3_data_analysis/global_high_confidence_phenotype_neighborhood_host_endogenous
#   --output_dir=3_data_analysis/global_high_confidence_phenotype_neighborhood_host_endogenous/pubmed_pair_similarity
#   --request_delay=0.34
#   --max_retries=5
#   --checkpoint_every=25
#   --seed=2026
#
# Optional environment variables:
#   NCBI_EMAIL=your_email@example.com
#   NCBI_API_KEY=your_NCBI_API_key

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(scales)
})

if (!requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Package 'jsonlite' is required. Install it with install.packages('jsonlite').")
}

parse_args <- function() {
  args <- list(
    input_dir = file.path(
      "3_data_analysis",
      "global_high_confidence_phenotype_neighborhood_host_endogenous"
    ),
    output_dir = file.path(
      "3_data_analysis",
      "global_high_confidence_phenotype_neighborhood_host_endogenous",
      "pubmed_pair_similarity"
    ),
    request_delay = 0.34,
    max_retries = 5L,
    checkpoint_every = 25L,
    seed = 2026L
  )

  for (arg in commandArgs(trailingOnly = TRUE)) {
    kv <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1]]
    if (length(kv) != 2L || !kv[[1]] %in% names(args)) next
    key <- kv[[1]]
    value <- kv[[2]]
    if (key %in% c("request_delay")) value <- as.numeric(value)
    if (key %in% c("max_retries", "checkpoint_every", "seed")) {
      value <- as.integer(value)
    }
    args[[key]] <- value
  }
  args
}

read_csv_required <- function(path) {
  if (!file.exists(path)) stop("Required file does not exist: ", path)
  read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

escape_pubmed_phrase <- function(x) {
  x <- trimws(as.character(x))
  x <- gsub('"', "", x, fixed = TRUE)
  paste0('"', x, '"[Title/Abstract]')
}

format_p <- function(p) {
  if (is.na(p)) return("P = NA")
  if (p < 0.0001) return("P < 0.0001")
  paste0("P = ", formatC(p, format = "f", digits = 4))
}

build_url <- function(endpoint, parameters) {
  values <- vapply(
    parameters,
    function(x) utils::URLencode(as.character(x), reserved = TRUE),
    character(1)
  )
  paste0(
    endpoint,
    "?",
    paste0(names(parameters), "=", values, collapse = "&")
  )
}

fetch_pubmed_count <- function(query, request_delay, max_retries) {
  endpoint <- "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
  parameters <- list(
    db = "pubmed",
    term = query,
    retmode = "json",
    rettype = "count",
    tool = "PhenoMAP_pubmed_pair_similarity"
  )

  ncbi_email <- Sys.getenv("NCBI_EMAIL", unset = "")
  ncbi_api_key <- Sys.getenv("NCBI_API_KEY", unset = "")
  if (nzchar(ncbi_email)) parameters$email <- ncbi_email
  if (nzchar(ncbi_api_key)) parameters$api_key <- ncbi_api_key

  request_url <- build_url(endpoint, parameters)
  last_error <- NULL

  for (attempt in seq_len(max_retries)) {
    result <- tryCatch(
      {
        connection <- url(request_url, open = "rb")
        response_text <- tryCatch(
          paste(readLines(connection, warn = FALSE), collapse = ""),
          finally = close(connection)
        )
        parsed <- jsonlite::fromJSON(response_text, simplifyVector = TRUE)
        count <- as.numeric(parsed$esearchresult$count)
        if (length(count) != 1L || !is.finite(count)) {
          stop("PubMed response did not contain a valid count.")
        }
        count
      },
      error = function(e) {
        last_error <<- conditionMessage(e)
        NA_real_
      }
    )

    if (is.finite(result)) {
      Sys.sleep(request_delay)
      return(result)
    }

    Sys.sleep(request_delay * (2 ^ (attempt - 1L)))
  }

  warning("PubMed query failed after ", max_retries, " attempts: ", last_error)
  NA_real_
}

args <- parse_args()
dir.create(args$output_dir, recursive = TRUE, showWarnings = FALSE)

pair_file <- file.path(args$input_dir, "phenotype_similarity_pairs_final.csv")
pairs <- read_csv_required(pair_file)

required_columns <- c(
  "Phenotype_ID_1", "Phenotype_1", "Type_1",
  "Phenotype_ID_2", "Phenotype_2", "Type_2", "Similarity"
)
missing_columns <- setdiff(required_columns, names(pairs))
if (length(missing_columns) > 0L) {
  stop("Pair file is missing: ", paste(missing_columns, collapse = ", "))
}

phenotypes <- bind_rows(
  pairs %>% transmute(Phenotype_ID = Phenotype_ID_1, Phenotype = Phenotype_1),
  pairs %>% transmute(Phenotype_ID = Phenotype_ID_2, Phenotype = Phenotype_2)
) %>%
  distinct(Phenotype_ID, .keep_all = TRUE) %>%
  arrange(Phenotype_ID) %>%
  mutate(PubMed_Term = escape_pubmed_phrase(Phenotype))

# Only clear nomenclature changes and common aliases are overridden. The exact
# query used for every phenotype is written to CSV before any API calls.
query_overrides <- c(
  "COVID-19" = paste0(
    '"COVID-19"[Title/Abstract] OR ',
    '"coronavirus disease 2019"[Title/Abstract]'
  ),
  "Chronic obstructive pulmonary disease" = paste0(
    '"chronic obstructive pulmonary disease"[Title/Abstract] OR ',
    'COPD[Title/Abstract]'
  ),
  "Hepatocellular carcinoma" = paste0(
    '"hepatocellular carcinoma"[Title/Abstract] OR HCC[Title/Abstract]'
  ),
  "Metabolic dysfunction-associated steatohepatitis" = paste0(
    '"metabolic dysfunction-associated steatohepatitis"[Title/Abstract] OR ',
    '"nonalcoholic steatohepatitis"[Title/Abstract] OR ',
    '"non-alcoholic steatohepatitis"[Title/Abstract] OR ',
    'MASH[Title/Abstract] OR NASH[Title/Abstract]'
  ),
  "Non-small cell lung carcinoma" = paste0(
    '"non-small cell lung carcinoma"[Title/Abstract] OR ',
    '"non-small cell lung cancer"[Title/Abstract] OR NSCLC[Title/Abstract]'
  ),
  "Polycystic ovary syndrome" = paste0(
    '"polycystic ovary syndrome"[Title/Abstract] OR PCOS[Title/Abstract]'
  ),
  "Isoprenaline" = paste0(
    'isoprenaline[Title/Abstract] OR isoproterenol[Title/Abstract]'
  )
)

override_index <- match(phenotypes$Phenotype, names(query_overrides))
has_override <- !is.na(override_index)
phenotypes$PubMed_Term[has_override] <- unname(
  query_overrides[override_index[has_override]]
)

write.csv(
  phenotypes,
  file.path(args$output_dir, "pubmed_phenotype_queries.csv"),
  row.names = FALSE
)

term_lookup <- setNames(phenotypes$PubMed_Term, phenotypes$Phenotype_ID)

pair_queries <- pairs %>%
  transmute(
    Pair_ID = paste(Phenotype_ID_1, Phenotype_ID_2, sep = "__"),
    Phenotype_ID_1,
    Phenotype_1,
    Type_1,
    Phenotype_ID_2,
    Phenotype_2,
    Type_2,
    Similarity = as.numeric(Similarity),
    Same_Phenotype_Label =
      tolower(trimws(Phenotype_1)) == tolower(trimws(Phenotype_2)),
    PubMed_Term_1 = unname(term_lookup[Phenotype_ID_1]),
    PubMed_Term_2 = unname(term_lookup[Phenotype_ID_2]),
    PubMed_Query = paste0(
      "(", PubMed_Term_1, ") AND (", PubMed_Term_2, ")"
    )
  )

query_table <- pair_queries %>%
  distinct(PubMed_Query) %>%
  arrange(PubMed_Query) %>%
  mutate(
    Query_ID = sprintf("Q%04d", row_number()),
    PubMed_Count = NA_real_,
    Retrieval_Date = NA_character_
  ) %>%
  select(Query_ID, PubMed_Query, PubMed_Count, Retrieval_Date)

checkpoint_file <- file.path(args$output_dir, "pubmed_query_count_checkpoint.csv")
if (file.exists(checkpoint_file)) {
  checkpoint <- read.csv(
    checkpoint_file,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  if (all(c("PubMed_Query", "PubMed_Count", "Retrieval_Date") %in% names(checkpoint))) {
    checkpoint_index <- match(query_table$PubMed_Query, checkpoint$PubMed_Query)
    matched <- !is.na(checkpoint_index)
    query_table$PubMed_Count[matched] <- checkpoint$PubMed_Count[checkpoint_index[matched]]
    query_table$Retrieval_Date[matched] <- checkpoint$Retrieval_Date[checkpoint_index[matched]]
  }
}

pending <- which(!is.finite(query_table$PubMed_Count))
message(
  "Unique PubMed queries: ", nrow(query_table),
  "; already cached: ", nrow(query_table) - length(pending),
  "; remaining: ", length(pending)
)

if (length(pending) > 0L) {
  for (position in seq_along(pending)) {
    row_index <- pending[[position]]
    message(
      "[", position, "/", length(pending), "] ",
      query_table$Query_ID[[row_index]]
    )

    query_table$PubMed_Count[[row_index]] <- fetch_pubmed_count(
      query = query_table$PubMed_Query[[row_index]],
      request_delay = args$request_delay,
      max_retries = args$max_retries
    )
    if (is.finite(query_table$PubMed_Count[[row_index]])) {
      query_table$Retrieval_Date[[row_index]] <- as.character(Sys.Date())
    }

    if (
      position %% args$checkpoint_every == 0L ||
      position == length(pending)
    ) {
      write.csv(query_table, checkpoint_file, row.names = FALSE)
    }
  }
}

if (any(!is.finite(query_table$PubMed_Count))) {
  failed_n <- sum(!is.finite(query_table$PubMed_Count))
  write.csv(query_table, checkpoint_file, row.names = FALSE)
  stop(
    failed_n, " PubMed queries are still missing. Rerun the same command to retry; ",
    "completed queries will be read from the checkpoint."
  )
}

count_lookup <- setNames(query_table$PubMed_Count, query_table$PubMed_Query)
date_lookup <- setNames(query_table$Retrieval_Date, query_table$PubMed_Query)

pair_results <- pair_queries %>%
  mutate(
    PubMed_Count = unname(count_lookup[PubMed_Query]),
    Retrieval_Date = unname(date_lookup[PubMed_Query])
  )

write.csv(
  pair_results,
  file.path(args$output_dir, "phenotype_pair_pubmed_counts.csv"),
  row.names = FALSE
)

analysis_data <- pair_results %>%
  filter(
    !Same_Phenotype_Label,
    is.finite(Similarity),
    is.finite(PubMed_Count)
  ) %>%
  mutate(Log10_PubMed_Count = log10(PubMed_Count + 1))

if (nrow(analysis_data) < 3L) stop("Too few valid phenotype pairs to plot.")

spearman_result <- suppressWarnings(
  cor.test(
    analysis_data$Similarity,
    analysis_data$PubMed_Count,
    method = "spearman",
    exact = FALSE
  )
)

statistics <- data.frame(
  Pair_N = nrow(analysis_data),
  Excluded_Same_Label_Pair_N = sum(pair_results$Same_Phenotype_Label),
  Spearman_Rho = unname(spearman_result$estimate),
  P_value = spearman_result$p.value,
  Search_Field = "Title/Abstract",
  Retrieval_Date_Min = min(analysis_data$Retrieval_Date),
  Retrieval_Date_Max = max(analysis_data$Retrieval_Date),
  stringsAsFactors = FALSE
)

write.csv(
  statistics,
  file.path(args$output_dir, "pubmed_similarity_spearman_statistics.csv"),
  row.names = FALSE
)

count_breaks <- c(0, 1, 10, 100, 1000, 10000, 100000, 1000000)
count_breaks <- count_breaks[count_breaks <= max(analysis_data$PubMed_Count)]
if (!0 %in% count_breaks) count_breaks <- c(0, count_breaks)
if (length(count_breaks) < 2L) count_breaks <- c(0, 1)

annotation <- paste0(
  "Spearman rho = ",
  formatC(unname(spearman_result$estimate), format = "f", digits = 2),
  "\n", format_p(spearman_result$p.value)
)

set.seed(args$seed)
p <- ggplot(
  analysis_data,
  aes(x = Similarity, y = Log10_PubMed_Count)
) +
  geom_point(
    shape = 16,
    size = 1.15,
    color = "#0072B2",
    alpha = 0.58
  ) +
  geom_smooth(
    method = "loess",
    formula = y ~ x,
    se = TRUE,
    linewidth = 0.75,
    color = "#D55E00",
    fill = alpha("#D55E00", 0.16)
  ) +
  annotate(
    "text",
    x = 0.025,
    y = Inf,
    label = annotation,
    hjust = 0,
    vjust = 1.25,
    size = 3.5,
    color = "black"
  ) +
  scale_x_continuous(
    breaks = seq(0, 0.8, 0.2),
    limits = c(0, 0.85),
    expand = expansion(mult = c(0, 0))
  ) +
  scale_y_continuous(
    breaks = log10(count_breaks + 1),
    labels = scales::comma(count_breaks),
    minor_breaks = NULL,
    expand = expansion(mult = c(0.01, 0.08))
  ) +
  labs(
    x = "Phenotype similarity",
    y = "PubMed co-occurrence count"
  ) +
  theme_classic(base_size = 11) +
  theme(
    plot.title = element_blank(),
    legend.position = "none",
    panel.border = element_rect(color = "black", fill = NA, linewidth = 0.6),
    panel.grid.major = element_line(color = "grey88", linewidth = 0.25),
    panel.grid.minor = element_blank(),
    axis.line = element_blank(),
    axis.ticks = element_line(linewidth = 0.45, color = "black"),
    axis.text = element_text(size = 10, color = "black"),
    axis.title = element_text(size = 11, color = "black"),
    axis.title.x = element_text(margin = margin(t = 7)),
    axis.title.y = element_text(margin = margin(r = 7)),
    plot.margin = margin(5, 6, 4, 5)
  )

pdf(
  file.path(args$output_dir, "pubmed_cooccurrence_vs_phenotype_similarity.pdf"),
  width = 4.2,
  height = 3.6,
  useDingbats = FALSE
)
print(p)
dev.off()

message("Saved outputs to: ", args$output_dir)
message(
  "Spearman rho = ",
  formatC(unname(spearman_result$estimate), format = "f", digits = 3),
  "; ", format_p(spearman_result$p.value)
)
message(
  "Interpretation note: PubMed co-occurrence reflects publication frequency, ",
  "not necessarily a validated biological mechanism."
)
