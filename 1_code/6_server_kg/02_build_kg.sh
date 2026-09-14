#!/usr/bin/env bash
# Build all PhenoMAP node/relationship/Neo4j import tables in an isolated
# directory. Nothing in the active deployment is overwritten by this script.

set -euo pipefail

CONFIG_FILE="${1:-}"
if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
  echo "Usage: $0 /absolute/path/to/server_kg.env" >&2
  exit 2
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

required_vars=(
  PHENOMAP_PROJECT_ROOT CASE_ROOT_MW CASE_ROOT_ML PHENOTYPE_DIR_MW
  PHENOTYPE_DIR_ML BUILD_ROOT SEED_DATA_ROOT
)
for name in "${required_vars[@]}"; do
  if [ -z "${!name:-}" ]; then
    echo "Missing required config variable: $name" >&2
    exit 2
  fi
done

WORKERS="${WORKERS:-8}"
RUN_PHENOTYPE_NORMALIZATION="${RUN_PHENOTYPE_NORMALIZATION:-no}"
REUSE_REFERENCE_GRAPH="${REUSE_REFERENCE_GRAPH:-yes}"
RUN_MODULE_SIMILARITY="${RUN_MODULE_SIMILARITY:-yes}"
PHENOTYPE_MODEL="${PHENOTYPE_MODEL:-gpt-4.1}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-text-embedding-3-small}"
EMBEDDING_BASE_URL="${EMBEDDING_BASE_URL:-https://api.openai.com/v1}"
MIN_MODULE_SIMILARITY="${MIN_MODULE_SIMILARITY:-0.70}"

export R_LIBS_USER="${R_LIBS_USER:-}"
export PHENOMAP_FEATUREMAP_ROOT="${PHENOMAP_FEATUREMAP_ROOT:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n== %s ==\n' "$*"; }

[ -d "$PHENOMAP_PROJECT_ROOT" ] || die "Project root not found: $PHENOMAP_PROJECT_ROOT"
[ -f "$PHENOMAP_PROJECT_ROOT/1_code/00_phenomap_helpers.R" ] || die "Incomplete PhenoMAP code under $PHENOMAP_PROJECT_ROOT"
[ -d "$CASE_ROOT_MW" ] || die "MW case root not found: $CASE_ROOT_MW"
[ -d "$CASE_ROOT_ML" ] || die "ML case root not found: $CASE_ROOT_ML"
command -v Rscript >/dev/null || die "Rscript is not available"

mw_meta=$(find "$CASE_ROOT_MW" -mindepth 2 -maxdepth 2 -name study_meta.json -type f 2>/dev/null | wc -l)
ml_meta=$(find "$CASE_ROOT_ML" -mindepth 2 -maxdepth 2 -name study_meta.json -type f 2>/dev/null | wc -l)
mw_res=$(find "$CASE_ROOT_MW" -mindepth 3 -maxdepth 3 -path '*/anno_result/res_sig.rda' -type f 2>/dev/null | wc -l)
ml_res=$(find "$CASE_ROOT_ML" -mindepth 3 -maxdepth 3 -path '*/anno_result/res_sig.rda' -type f 2>/dev/null | wc -l)
[ "$mw_meta" -gt 0 ] || die "No MW study_meta.json files found one level below $CASE_ROOT_MW"
[ "$ml_meta" -gt 0 ] || die "No ML study_meta.json files found one level below $CASE_ROOT_ML"
[ "$mw_res" -gt 0 ] || die "No MW anno_result/res_sig.rda files found"
[ "$ml_res" -gt 0 ] || die "No ML anno_result/res_sig.rda files found"

[ ! -e "$BUILD_ROOT" ] || die "BUILD_ROOT already exists; choose a new path: $BUILD_ROOT"
mkdir -p "$BUILD_ROOT/logs" "$BUILD_ROOT/tidy_entity" \
  "$BUILD_ROOT/tidy_relationship" "$BUILD_ROOT/neo4j/import"

cd "$PHENOMAP_PROJECT_ROOT"

run_step() {
  local label="$1"
  shift
  say "$label"
  "$@" 2>&1 | tee "$BUILD_ROOT/logs/${label}.log"
}

say "input summary"
printf 'MW: %s metadata, %s res_sig\n' "$mw_meta" "$mw_res"
printf 'ML: %s metadata, %s res_sig\n' "$ml_meta" "$ml_res"
printf 'Build root: %s\n' "$BUILD_ROOT"

say "R dependency check"
Rscript -e 'needed <- c("jsonlite", "readxl", "Matrix"); missing <- needed[!vapply(needed, requireNamespace, logical(1), quietly=TRUE)]; if(length(missing)) stop("Missing R packages: ", paste(missing, collapse=", ")); cat("Required R packages are available.\n")'

if [ "$RUN_PHENOTYPE_NORMALIZATION" = "yes" ]; then
  [ -n "${OPENAI_API_KEY:-}" ] || die "OPENAI_API_KEY is required for phenotype normalization"
  [ ! -e "$PHENOTYPE_DIR_MW" ] || die "Phenotype output already exists: $PHENOTYPE_DIR_MW"
  [ ! -e "$PHENOTYPE_DIR_ML" ] || die "Phenotype output already exists: $PHENOTYPE_DIR_ML"

  run_step phenotype_normalize_mw Rscript 1_code/0_prepare_raw/01_normalize_study_phenotype.R \
    "--case_root=$CASE_ROOT_MW" "--output_dir=$PHENOTYPE_DIR_MW" \
    "--model=$PHENOTYPE_MODEL" "--workers=$WORKERS"
  run_step phenotype_normalize_ml Rscript 1_code/0_prepare_raw/01_normalize_study_phenotype.R \
    "--case_root=$CASE_ROOT_ML" "--output_dir=$PHENOTYPE_DIR_ML" \
    "--model=$PHENOTYPE_MODEL" "--workers=$WORKERS"

  for db in mw ml; do
    if [ "$db" = mw ]; then phenotype_dir="$PHENOTYPE_DIR_MW"; else phenotype_dir="$PHENOTYPE_DIR_ML"; fi
    run_step "phenotype_add_ids_$db" Rscript 1_code/0_prepare_raw/02_add_ontology_ids_to_phenotype_outputs.R \
      "--output_dir=$phenotype_dir"
    run_step "phenotype_mondo_$db" Rscript 1_code/0_prepare_raw/03_canonicalize_disease_to_mondo.R \
      "--phenotype_dir=$phenotype_dir" "--workers=$WORKERS"
  done
else
  for dir in "$PHENOTYPE_DIR_MW" "$PHENOTYPE_DIR_ML"; do
    [ -f "$dir/phenotype_final_selection.csv" ] || die "Missing phenotype_final_selection.csv under $dir"
    [ -f "$dir/phenotype_ols_candidates.csv" ] || die "Missing phenotype_ols_candidates.csv under $dir"
    if [ ! -f "$dir/phenotype_manual_short.xlsx" ]; then
      echo "WARNING: no manual phenotype override file under $dir; automatic selections will be used." >&2
    fi
  done
fi

say "seed stable identifiers and reusable caches"
if [ -d "$SEED_DATA_ROOT/tidy_entity" ]; then
  for src in "$SEED_DATA_ROOT"/tidy_entity/*_registry.csv; do
    [ -f "$src" ] && cp "$src" "$BUILD_ROOT/tidy_entity/"
  done
fi
if [ -d "$SEED_DATA_ROOT/tidy_relationship" ]; then
  for src in "$SEED_DATA_ROOT"/tidy_relationship/*_registry.csv; do
    [ -f "$src" ] && cp "$src" "$BUILD_ROOT/tidy_relationship/"
  done
  [ -f "$SEED_DATA_ROOT/tidy_relationship/module_text_embeddings.rds" ] && \
    cp "$SEED_DATA_ROOT/tidy_relationship/module_text_embeddings.rds" "$BUILD_ROOT/tidy_relationship/"
fi

run_step entity_phenotype Rscript 1_code/1_tidy_entity/01_tidy_phenotype_entity.R \
  "--phenotype_dir_mw=$PHENOTYPE_DIR_MW" "--phenotype_dir_ml=$PHENOTYPE_DIR_ML" \
  "--output_dir=$BUILD_ROOT/tidy_entity"

if [ "$REUSE_REFERENCE_GRAPH" = "yes" ]; then
  for f in nodes_metabolite.csv metabolite_id_registry.csv; do
    [ -f "$SEED_DATA_ROOT/tidy_entity/$f" ] || die "Cannot reuse reference graph; missing $SEED_DATA_ROOT/tidy_entity/$f"
    cp "$SEED_DATA_ROOT/tidy_entity/$f" "$BUILD_ROOT/tidy_entity/$f"
  done
else
  run_step entity_metabolite Rscript 1_code/1_tidy_entity/02_tidy_metabolite_entity.R \
    "--output_dir=$BUILD_ROOT/tidy_entity"
fi

run_step entity_study Rscript 1_code/1_tidy_entity/03_tidy_study_entity.R \
  "--case_root_mw=$CASE_ROOT_MW" "--case_root_ml=$CASE_ROOT_ML" \
  "--phenotype_dir_mw=$PHENOTYPE_DIR_MW" "--phenotype_dir_ml=$PHENOTYPE_DIR_ML" \
  "--output_dir=$BUILD_ROOT/tidy_entity" "--case_control_only=TRUE"

run_step entity_module Rscript 1_code/1_tidy_entity/04_tidy_module_entity.R \
  "--case_root_mw=$CASE_ROOT_MW" "--case_root_ml=$CASE_ROOT_ML" \
  "--output_dir=$BUILD_ROOT/tidy_entity" "--workers=$WORKERS"

if [ "$REUSE_REFERENCE_GRAPH" = "yes" ]; then
  for f in edges_metabolite_metabolite.csv metabolite_metabolite_edge_id_registry.csv; do
    [ -f "$SEED_DATA_ROOT/tidy_relationship/$f" ] || die "Cannot reuse reference graph; missing $SEED_DATA_ROOT/tidy_relationship/$f"
    cp "$SEED_DATA_ROOT/tidy_relationship/$f" "$BUILD_ROOT/tidy_relationship/$f"
  done
else
  run_step relationship_metabolite_metabolite Rscript 1_code/2_tidy_relationship/01_tidy_metabolite_metabolite_relationship.R \
    "--entity_dir=$BUILD_ROOT/tidy_entity" "--relationship_dir=$BUILD_ROOT/tidy_relationship"
fi

run_step relationship_metabolite_module Rscript 1_code/2_tidy_relationship/02_tidy_metabolite_module_relationship.R \
  "--case_root_mw=$CASE_ROOT_MW" "--case_root_ml=$CASE_ROOT_ML" \
  "--entity_dir=$BUILD_ROOT/tidy_entity" "--relationship_dir=$BUILD_ROOT/tidy_relationship" \
  "--workers=$WORKERS"
run_step relationship_module_study Rscript 1_code/2_tidy_relationship/03_tidy_module_study_relationship.R \
  "--entity_dir=$BUILD_ROOT/tidy_entity" "--relationship_dir=$BUILD_ROOT/tidy_relationship"
run_step relationship_study_phenotype Rscript 1_code/2_tidy_relationship/04_tidy_study_phenotype_relationship.R \
  "--entity_dir=$BUILD_ROOT/tidy_entity" "--relationship_dir=$BUILD_ROOT/tidy_relationship"

if [ "$RUN_MODULE_SIMILARITY" = "yes" ]; then
  run_step relationship_module_module Rscript 1_code/2_tidy_relationship/05_tidy_module_module_relationship.R \
    "--entity_dir=$BUILD_ROOT/tidy_entity" "--relationship_dir=$BUILD_ROOT/tidy_relationship" \
    "--embedding_model=$EMBEDDING_MODEL" "--base_url=$EMBEDDING_BASE_URL" \
    "--min_similarity_score=$MIN_MODULE_SIMILARITY"
else
  echo '"Lab_ID","Module_ID_1","Relationship","Module_ID_2","Type","Similarity_Score","Similarity_Tier","Biological_Score","Compositional_Score","Cross_Study"' \
    > "$BUILD_ROOT/tidy_relationship/edges_module_module.csv"
fi

run_step neo4j_format Rscript 1_code/3_neo4j_import/01_format_neo4j_import.R \
  "--entity_dir=$BUILD_ROOT/tidy_entity" \
  "--relationship_dir=$BUILD_ROOT/tidy_relationship" \
  "--output_dir=$BUILD_ROOT/neo4j/import"

run_step validate Rscript 1_code/6_server_kg/03_validate_kg.R "$BUILD_ROOT"
touch "$BUILD_ROOT/.phenomap_kg_build_complete"

say "build complete"
echo "Validated KG tables: $BUILD_ROOT"
echo "Review: $BUILD_ROOT/validation_summary.csv"
echo "Publishing is a separate explicit step; this build has not changed the live database."
