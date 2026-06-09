# =============================================================================
# PhenoMAP Shiny App
#
# Input:  metabolite IDs (HMDB / KEGG / InChI)
# Output: enriched functional modules from the PhenoMAP atlas
# =============================================================================

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(DT)
  library(DBI)
  library(RSQLite)
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(plotly)
  library(shinycssloaders)
})

# ---- Paths -------------------------------------------------------------------
# When launched via shiny::runApp("1_code/shiny_app") the working directory is
# set to the app folder. We look for the DB relative to the app, then fall back
# to relative to the project root.
.candidates <- c(
  normalizePath("../../2_data/phenomap_v0.1.db", mustWork = FALSE),
  normalizePath("2_data/phenomap_v0.1.db",       mustWork = FALSE)
)
DB_PATH <- Filter(file.exists, .candidates)[1]
if (is.na(DB_PATH) || length(DB_PATH) == 0) {
  warning("phenomap_v0.1.db not found — set DB_PATH manually.")
  DB_PATH <- "2_data/phenomap_v0.1.db"
}

# ---- ORA helpers (adapted from 02_query.R) -----------------------------------

run_ora <- function(sig, ids, col, min_hits, fdr_cutoff) {
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

  mod_sizes  <- sig %>%
    filter(!is.na(INCHI_ID)) %>%
    group_by(global_module_id) %>%
    summarise(n_sig = n_distinct(INCHI_ID), .groups = "drop")

  hit_counts <- hits %>%
    group_by(global_module_id) %>%
    summarise(n_hit = n_distinct(INCHI_ID), .groups = "drop")

  hit_names  <- hits %>%
    group_by(global_module_id) %>%
    summarise(matched_names = paste(unique(Compound_name), collapse = "; "),
              .groups = "drop")

  mod_sizes %>%
    left_join(hit_counts, by = "global_module_id") %>%
    replace_na(list(n_hit = 0L)) %>%
    filter(n_hit >= min_hits) %>%
    mutate(
      p_ora = phyper(n_hit - 1, n_sig, bg_size - n_sig, query_size,
                     lower.tail = FALSE),
      coverage_pct = round(n_hit / n_sig * 100, 1)
    ) %>%
    mutate(fdr_ora = p.adjust(p_ora, method = "BH")) %>%
    filter(fdr_ora <= fdr_cutoff) %>%
    left_join(hit_names, by = "global_module_id")
}

query_phenomap_app <- function(ids, id_type = "HMDB", db_path = DB_PATH,
                               min_hits = 2, fdr_cutoff = 0.2,
                               core_fdr_cutoff = fdr_cutoff,
                               level = "atlas") {
  ids <- unique(na.omit(trimws(ids)))
  ids <- ids[nchar(ids) > 0]
  if (length(ids) == 0) stop("No valid IDs provided.")

  con <- dbConnect(SQLite(), db_path)
  on.exit(dbDisconnect(con), add = TRUE)

  tables   <- dbListTables(con)
  has_atlas <- all(c("atlas_module", "atlas_signature") %in% tables)
  has_sig   <- "signature" %in% tables

  # ---- Load signature --------------------------------------------------------
  if (level == "atlas" && has_atlas) {
    sig_all <- dbGetQuery(con, "
      SELECT atlas_module_id AS global_module_id,
             INCHI_ID, HMDB_ID, KEGG_ID, Compound_name, tier
      FROM atlas_signature
    ")
    mod_info <- dbGetQuery(con, "
      SELECT atlas_module_id AS global_module_id,
             study_ids        AS study_id,
             canonical_title  AS title,
             hypothesis_type,
             phenotypes       AS phenotype,
             biospecimens     AS biospecimen,
             confidence_labels AS confidence_label,
             min_p_value      AS p_value,
             min_fdr          AS fdr,
             n_instances, n_studies, n_phenotypes, n_biospecimens,
             instance_ids
      FROM atlas_module
    ")
  } else {
    # Instance level (or fallback)
    if (has_sig) {
      sig_all <- dbGetQuery(con, "
        SELECT global_module_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name, tier
        FROM signature
      ")
    } else {
      members_full <- dbGetQuery(con, "
        SELECT global_module_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name,
               use_for_annotation, is_core_driver FROM member
      ")
      sig_all <- bind_rows(
        members_full %>% filter(is_core_driver == 1) %>%
          transmute(global_module_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name,
                    tier = "anchor"),
        members_full %>% filter(use_for_annotation == 1) %>%
          transmute(global_module_id, INCHI_ID, HMDB_ID, KEGG_ID, Compound_name,
                    tier = "top")
      ) %>% distinct()
    }
    mod_info <- dbGetQuery(con, "
      SELECT global_module_id, study_id, title, hypothesis_type,
             functional_summary, confidence_label, phenotype_relationship,
             anchor_metabolites, core_drivers, top_kegg_pathways,
             phenotype, biospecimen, p_value, fdr,
             module_size AS total_nodes, annotated_nodes,
             NULL AS n_instances, NULL AS n_studies,
             NULL AS n_phenotypes, NULL AS n_biospecimens,
             NULL AS instance_ids
      FROM module
    ")
    level <- "instance"
  }

  col_map <- c(HMDB = "HMDB_ID", KEGG = "KEGG_ID", INCHI = "INCHI_ID")
  col     <- col_map[[id_type]]

  sig_anchor <- sig_all %>% filter(tier == "anchor")
  sig_top    <- sig_all %>% filter(tier == "top")

  # Tier 1: anchor (LLM-selected anchor metabolites)
  res1 <- run_ora(sig_anchor, ids, col, min_hits, fdr_cutoff)

  # Tier 2: core drivers — run on ALL modules, then keep only novel ones
  # (mirrors the updated 02_query.R logic)
  res2_all <- run_ora(sig_top, ids, col, min_hits, core_fdr_cutoff)
  found_in_tier1 <- res1$global_module_id
  res2 <- res2_all %>% filter(!global_module_id %in% found_in_tier1)

  bind_rows(
    res1 %>% mutate(match_tier = "anchor"),
    res2 %>% mutate(match_tier = "core")
  ) %>%
    mutate(result_level = level) %>%
    left_join(mod_info, by = "global_module_id") %>%
    arrange(match_tier, p_ora)
}

# ---- Example IDs -------------------------------------------------------------
EXAMPLES <- list(
  HMDB = c("HMDB0000289", "HMDB0000157", "HMDB0000296", "HMDB0000262",
           "HMDB0000687", "HMDB0000742", "HMDB0000251", "HMDB0000641"),
  KEGG = c("C00062", "C00025", "C00064", "C00041", "C00049", "C00082",
           "C00148", "C00135"),
  INCHI = c(
    "FFEARJCKVFRZRR-BYPYZUCNSA-N",
    "KDXKERNSBIXSRK-YFKPBYRVSA-N",
    "ZDXPYRJPNDTMRX-VKHMYHEASA-N",
    "COLNVLDHVKWLRT-QMMMGPOBSA-N"
  )
)

# ---- Hypothesis type colours -------------------------------------------------
HYP_COLORS <- c(
  "Host-Endogenous"    = "#3B82F6",
  "Host–Microbiome"    = "#10B981",
  "Xenobiotic / Exogenous" = "#F59E0B",
  "Diet-Derived"       = "#8B5CF6"
)

badge_html <- function(type) {
  col <- HYP_COLORS[type]
  if (is.na(col)) col <- "#6B7280"
  sprintf(
    '<span style="background:%s22;color:%s;border:1px solid %s44;
     border-radius:4px;padding:2px 8px;font-size:12px;white-space:nowrap;">%s</span>',
    col, col, col, htmltools::htmlEscape(type)
  )
}

conf_badge <- function(label) {
  cols <- c(high = "#10B981", medium = "#F59E0B", low = "#EF4444")
  first <- str_extract(tolower(label), "high|medium|low")
  col   <- ifelse(!is.na(first), cols[first], "#6B7280")
  sprintf(
    '<span style="background:%s22;color:%s;border:1px solid %s44;
     border-radius:4px;padding:2px 8px;font-size:12px;">%s</span>',
    col, col, col, htmltools::htmlEscape(label)
  )
}

# =============================================================================
# UI
# =============================================================================

ui <- page_sidebar(
  title = tags$span(
    tags$img(src = "https://img.icons8.com/fluency/24/dna-helix.png",
             style = "vertical-align:middle;margin-right:8px;"),
    "PhenoMAP"
  ),
  theme = bs_theme(
    bootswatch = "flatly",
    primary    = "#3B82F6",
    base_font  = font_google("Inter")
  ),
  fillable = FALSE,

  # ---- Sidebar ---------------------------------------------------------------
  sidebar = sidebar(
    width = 300,

    # Title
    tags$div(
      style = "font-size:13px;color:#6B7280;margin-bottom:4px;",
      "Paste metabolite IDs (one per line or comma-separated):"
    ),
    textAreaInput(
      "id_input", label = NULL,
      placeholder = "e.g.\nHMDB0000289\nHMDB0000157\nHMDB0000296",
      rows = 8, width = "100%"
    ),

    # ID type
    radioButtons(
      "id_type", "ID type",
      choices  = c("HMDB" = "HMDB", "KEGG" = "KEGG", "InChI Key" = "INCHI"),
      selected = "HMDB",
      inline   = TRUE
    ),

    # Query level
    radioButtons(
      "level", "Query level",
      choices  = c("Atlas (cross-study)" = "atlas",
                   "Instance (per-study)" = "instance"),
      selected = "atlas"
    ),

    hr(),

    # FDR sliders
    sliderInput(
      "fdr_cutoff", "Anchor FDR cutoff",
      min = 0.01, max = 1, value = 0.2, step = 0.01
    ),
    sliderInput(
      "core_fdr_cutoff", "Core-driver FDR cutoff",
      min = 0.01, max = 1, value = 0.2, step = 0.01
    ),

    # Min hits
    numericInput(
      "min_hits", "Min hits per module",
      value = 2, min = 1, max = 20, step = 1, width = "100%"
    ),

    hr(),

    # Buttons
    actionButton("run_query", "Run Query",
                 class = "btn-primary w-100",
                 icon  = icon("magnifying-glass")),
    tags$br(), tags$br(),
    actionButton("load_example", "Load example IDs",
                 class = "btn-outline-secondary w-100 btn-sm",
                 icon  = icon("flask")),

    hr(),

    # DB info
    tags$div(
      id    = "db_info",
      style = "font-size:11px;color:#9CA3AF;line-height:1.6;",
      uiOutput("db_summary")
    )
  ),

  # ---- Main ------------------------------------------------------------------
  navset_tab(
    id = "main_tabs",

    # ── Tab 1: Results table ──────────────────────────────────────────────────
    nav_panel(
      "Results",
      icon = icon("table"),
      br(),
      uiOutput("results_header"),
      br(),
      withSpinner(
        DTOutput("results_table"),
        type = 5, color = "#3B82F6"
      )
    ),

    # ── Tab 2: Module detail ──────────────────────────────────────────────────
    nav_panel(
      "Module Detail",
      icon = icon("circle-info"),
      br(),
      uiOutput("module_detail")
    ),

    # ── Tab 3: Phenotype overview ─────────────────────────────────────────────
    nav_panel(
      "Phenotype Overview",
      icon = icon("disease"),
      br(),
      uiOutput("pheno_header"),
      withSpinner(
        plotlyOutput("pheno_plot", height = "500px"),
        type = 5, color = "#3B82F6"
      )
    ),

    # ── Tab 4: Matched metabolites ────────────────────────────────────────────
    nav_panel(
      "Matched Metabolites",
      icon = icon("vials"),
      br(),
      withSpinner(
        DTOutput("metabolite_table"),
        type = 5, color = "#3B82F6"
      )
    )
  )
)

# =============================================================================
# Server
# =============================================================================

server <- function(input, output, session) {

  # ---- DB summary ------------------------------------------------------------
  output$db_summary <- renderUI({
    tryCatch({
      con <- dbConnect(SQLite(), DB_PATH)
      on.exit(dbDisconnect(con))
      n_study  <- dbGetQuery(con, "SELECT COUNT(*) FROM study")[[1]]
      n_mod    <- dbGetQuery(con, "SELECT COUNT(*) FROM module")[[1]]
      n_atlas  <- dbGetQuery(con, "SELECT COUNT(*) FROM atlas_module")[[1]]
      n_member <- dbGetQuery(con, "SELECT COUNT(*) FROM member")[[1]]
      tagList(
        tags$b("Database: phenomap_v0.1"), tags$br(),
        sprintf("Studies: %d", n_study), tags$br(),
        sprintf("Study modules: %d", n_mod), tags$br(),
        sprintf("Atlas modules: %d", n_atlas), tags$br(),
        sprintf("Members: %s", format(n_member, big.mark = ","))
      )
    }, error = function(e) tags$span(style = "color:red;", "DB not found"))
  })

  # ---- Example loader --------------------------------------------------------
  observeEvent(input$load_example, {
    ids <- EXAMPLES[[input$id_type]]
    updateTextAreaInput(session, "id_input",
                        value = paste(ids, collapse = "\n"))
  })

  # ---- Reactive: run query ---------------------------------------------------
  query_result <- eventReactive(input$run_query, {
    req(nchar(trimws(input$id_input)) > 0)

    raw <- input$id_input
    ids <- unique(trimws(unlist(strsplit(raw, "[,\n\r\t]+"))))
    ids <- ids[nchar(ids) > 0]

    withProgress(message = "Querying PhenoMAP…", value = 0.3, {
      tryCatch(
        query_phenomap_app(
          ids             = ids,
          id_type         = input$id_type,
          db_path         = DB_PATH,
          min_hits        = input$min_hits,
          fdr_cutoff      = input$fdr_cutoff,
          core_fdr_cutoff = input$core_fdr_cutoff,
          level           = input$level
        ),
        error = function(e) {
          showNotification(paste("Error:", conditionMessage(e)),
                           type = "error", duration = 8)
          NULL
        }
      )
    })
  })

  # ---- Reactive: input ID count ----------------------------------------------
  n_input_ids <- reactive({
    raw <- input$id_input
    ids <- unique(trimws(unlist(strsplit(raw, "[,\n\r\t]+"))))
    length(ids[nchar(ids) > 0])
  })

  # ---- Results header --------------------------------------------------------
  output$results_header <- renderUI({
    res <- query_result()
    n   <- n_input_ids()

    if (is.null(res)) {
      return(tags$div(
        class = "alert alert-info",
        icon("circle-info"), " ",
        "Enter metabolite IDs in the sidebar and click ", tags$b("Run Query"), "."
      ))
    }
    if (nrow(res) == 0) {
      return(tags$div(
        class = "alert alert-warning",
        icon("triangle-exclamation"), " ",
        sprintf("No significant modules found for %d input ID(s) at FDR ≤ %.2f.",
                n, input$fdr_cutoff)
      ))
    }

    n_anchor <- sum(res$match_tier == "anchor", na.rm = TRUE)
    n_core   <- sum(res$match_tier == "core",   na.rm = TRUE)
    level_lbl <- if (input$level == "atlas") "atlas modules" else "study modules"

    tags$div(
      class = "alert alert-success",
      icon("circle-check"), " ",
      sprintf(
        "%d input IDs → %d significant %s (anchor: %d, core-driver: %d).",
        n, nrow(res), level_lbl, n_anchor, n_core
      )
    )
  })

  # ---- Results table ---------------------------------------------------------
  output$results_table <- renderDT({
    res <- query_result()
    req(!is.null(res), nrow(res) > 0)

    display <- res %>%
      mutate(
        Tier       = match_tier,
        Module     = global_module_id,
        Title      = title,
        Type       = hypothesis_type,
        Confidence = confidence_label,
        Hits       = sprintf("%d / %d (%.0f%%)", n_hit, n_sig, coverage_pct),
        p          = signif(p_ora, 3),
        FDR        = signif(fdr_ora, 3),
        Phenotype  = str_trunc(coalesce(phenotype, "—"), 80),
        `Matched metabolites` = str_trunc(coalesce(matched_names, ""), 60)
      ) %>%
      select(Tier, Module, Title, Type, Confidence, Hits, p, FDR,
             Phenotype, `Matched metabolites`)

    datatable(
      display,
      rownames   = FALSE,
      selection  = "single",
      extensions = c("Buttons"),
      options    = list(
        pageLength = 15,
        dom        = "Bfrtip",
        buttons    = list("csv", "excel"),
        scrollX    = TRUE,
        columnDefs = list(
          list(width = "120px", targets = 2),  # Title
          list(width = "90px",  targets = 3)   # Type
        )
      ),
      escape     = FALSE
    ) %>%
      formatStyle(
        "Tier",
        backgroundColor = styleEqual(
          c("anchor", "core"),
          c("#DBEAFE", "#D1FAE5")
        ),
        fontWeight = styleEqual("anchor", "bold")
      ) %>%
      formatStyle(
        "FDR",
        backgroundColor = styleInterval(
          c(0.05, 0.1, 0.2),
          c("#D1FAE5", "#FEF3C7", "#FEE2E2", "#FFFFFF")
        )
      )
  })

  # ---- Module detail ---------------------------------------------------------
  selected_module <- reactive({
    res <- query_result()
    req(!is.null(res), nrow(res) > 0)
    sel <- input$results_table_rows_selected
    if (is.null(sel) || length(sel) == 0) return(res[1, ])
    res[sel, ]
  })

  output$module_detail <- renderUI({
    res <- query_result()
    if (is.null(res) || nrow(res) == 0) {
      return(tags$div(class = "alert alert-info",
                      "Run a query to see module details."))
    }

    r <- selected_module()

    # helper: info row
    info_row <- function(label, value, full = FALSE) {
      if (is.null(value) || is.na(value) || trimws(value) == "") return(NULL)
      tags$div(
        style = if (full) "margin-bottom:12px;" else
          "display:flex;gap:8px;margin-bottom:8px;align-items:baseline;",
        tags$span(style = "font-weight:600;color:#374151;min-width:160px;",
                  label, ":"),
        tags$span(style = "color:#4B5563;", value)
      )
    }

    tagList(
      # Header card
      tags$div(
        class = "card mb-3",
        style = "border-left:4px solid #3B82F6;",
        tags$div(
          class = "card-body",
          tags$h5(class = "card-title mb-1", r$title),
          tags$div(
            style = "display:flex;gap:8px;flex-wrap:wrap;margin-bottom:8px;",
            HTML(badge_html(r$hypothesis_type)),
            HTML(conf_badge(coalesce(r$confidence_label, "—")))
          ),
          tags$small(
            class = "text-muted",
            sprintf("Module: %s  |  Tier: %s  |  p = %.3g  |  FDR = %.3g",
                    r$global_module_id, r$match_tier,
                    r$p_ora, r$fdr_ora)
          )
        )
      ),

      # Details row
      fluidRow(
        # Left: stats
        column(4,
          tags$div(
            class = "card h-100",
            tags$div(
              class = "card-header fw-bold", "Statistics"
            ),
            tags$div(
              class = "card-body",
              info_row("Coverage",
                       sprintf("%d / %d hits (%.1f%%)",
                               r$n_hit, r$n_sig, r$coverage_pct)),
              if (!is.na(r$n_instances))
                info_row("Atlas instances", as.character(r$n_instances)),
              if (!is.na(r$n_studies))
                info_row("Studies", as.character(r$n_studies)),
              if (!is.na(r$n_phenotypes))
                info_row("Phenotypes covered", as.character(r$n_phenotypes)),
              info_row("Matched IDs", r$matched_names)
            )
          )
        ),

        # Right: phenotype + biospecimen
        column(8,
          tags$div(
            class = "card h-100",
            tags$div(class = "card-header fw-bold", "Disease / Phenotype Context"),
            tags$div(
              class = "card-body",
              if (!is.null(r$phenotype) && !is.na(r$phenotype) &&
                  trimws(r$phenotype) != "") {
                # Split semicolon-separated phenotypes for atlas
                phenotypes <- str_split(r$phenotype, ";\\s*")[[1]]
                tagList(
                  tags$div(
                    lapply(phenotypes, function(p) {
                      tags$div(
                        style = "border-left:3px solid #3B82F6;padding:4px 10px;
                                 margin-bottom:6px;background:#F0F9FF;
                                 border-radius:0 4px 4px 0;font-size:13px;",
                        p
                      )
                    })
                  )
                )
              } else {
                tags$span(class = "text-muted", "No phenotype information available.")
              }
            )
          )
        )
      ),

      br(),

      # Functional summary
      if (!is.null(r$functional_summary) && !is.na(r$functional_summary)) {
        tags$div(
          class = "card",
          tags$div(class = "card-header fw-bold", "Functional Summary"),
          tags$div(
            class = "card-body",
            tags$p(style = "line-height:1.7;color:#374151;",
                   r$functional_summary)
          )
        )
      },

      br(),

      # Phenotype relationship
      if (!is.null(r$phenotype_relationship) &&
          !is.na(r$phenotype_relationship)) {
        tags$div(
          class = "card",
          tags$div(class = "card-header fw-bold", "Phenotype Relationship"),
          tags$div(
            class = "card-body",
            tags$p(style = "line-height:1.7;color:#374151;",
                   r$phenotype_relationship)
          )
        )
      },

      br(),

      # Anchor metabolites + KEGG pathways
      fluidRow(
        column(6,
          if (!is.null(r$anchor_metabolites) &&
              !is.na(r$anchor_metabolites)) {
            tags$div(
              class = "card",
              tags$div(class = "card-header fw-bold", "Anchor Metabolites (LLM-selected)"),
              tags$div(
                class = "card-body",
                tags$p(style = "font-size:13px;color:#374151;",
                       r$anchor_metabolites)
              )
            )
          }
        ),
        column(6,
          if (!is.null(r$top_kegg_pathways) &&
              !is.na(r$top_kegg_pathways)) {
            tags$div(
              class = "card",
              tags$div(class = "card-header fw-bold", "Top KEGG Pathways"),
              tags$div(
                class = "card-body",
                tags$p(style = "font-size:13px;color:#374151;",
                       r$top_kegg_pathways)
              )
            )
          }
        )
      )
    )
  })

  # ---- Phenotype overview plot -----------------------------------------------
  output$pheno_header <- renderUI({
    res <- query_result()
    if (is.null(res) || nrow(res) == 0) {
      return(tags$div(class = "alert alert-info",
                      "Run a query to see the phenotype overview."))
    }
    NULL
  })

  output$pheno_plot <- renderPlotly({
    res <- query_result()
    req(!is.null(res), nrow(res) > 0)

    # Extract phenotypes (semicolon-separated in atlas)
    pheno_df <- res %>%
      filter(!is.na(phenotype), trimws(phenotype) != "") %>%
      mutate(
        pheno_list = str_split(phenotype, ";\\s*"),
        hypothesis = hypothesis_type
      ) %>%
      tidyr::unnest(pheno_list) %>%
      mutate(pheno_list = str_trunc(trimws(pheno_list), 80)) %>%
      filter(nchar(pheno_list) > 3)

    if (nrow(pheno_df) == 0) {
      return(plotly_empty() %>%
               layout(title = "No phenotype data available for these results."))
    }

    # Count phenotypes by hypothesis type
    counts <- pheno_df %>%
      count(pheno_list, hypothesis) %>%
      rename(phenotype = pheno_list, n = n) %>%
      arrange(desc(n)) %>%
      slice_head(n = 40)   # top 40

    col_vec <- HYP_COLORS[counts$hypothesis]
    col_vec[is.na(col_vec)] <- "#6B7280"

    plot_ly(
      counts,
      x    = ~n,
      y    = ~reorder(phenotype, n),
      type = "bar",
      orientation = "h",
      color = ~hypothesis,
      colors = HYP_COLORS,
      hovertemplate = paste0(
        "<b>%{y}</b><br>",
        "Modules: %{x}<br>",
        "<extra></extra>"
      )
    ) %>%
      layout(
        title  = list(text = "Phenotypes covered by significant modules",
                      font = list(size = 15)),
        xaxis  = list(title = "Number of significant modules", zeroline = FALSE),
        yaxis  = list(title = "", tickfont = list(size = 11)),
        legend = list(title = list(text = "Hypothesis type")),
        margin = list(l = 350, r = 20, t = 50, b = 50),
        barmode = "stack"
      )
  })

  # ---- Matched metabolites table ---------------------------------------------
  output$metabolite_table <- renderDT({
    res <- query_result()
    req(!is.null(res), nrow(res) > 0)

    # Expand matched_names to one row per metabolite × module
    met_df <- res %>%
      filter(!is.na(matched_names)) %>%
      mutate(
        met_list = str_split(matched_names, ";\\s*")
      ) %>%
      tidyr::unnest(met_list) %>%
      mutate(met_list = trimws(met_list)) %>%
      filter(nchar(met_list) > 0) %>%
      select(
        `Metabolite`   = met_list,
        `Module`       = global_module_id,
        `Module title` = title,
        `Type`         = hypothesis_type,
        `Tier`         = match_tier,
        `FDR`          = fdr_ora
      ) %>%
      distinct() %>%
      arrange(Metabolite, FDR)

    datatable(
      met_df,
      rownames   = FALSE,
      extensions = "Buttons",
      options    = list(
        pageLength = 20,
        dom        = "Bfrtip",
        buttons    = list("csv", "excel"),
        scrollX    = TRUE
      )
    ) %>%
      formatRound("FDR", digits = 4)
  })

  # ---- Auto-switch to detail tab on row click --------------------------------
  observeEvent(input$results_table_rows_selected, {
    req(length(input$results_table_rows_selected) > 0)
    # nav_select() is the bslib equivalent of updateTabsetPanel() for navset_tab
    nav_select("main_tabs", "Module Detail", session = session)
  })
}

# =============================================================================
shinyApp(ui, server)
