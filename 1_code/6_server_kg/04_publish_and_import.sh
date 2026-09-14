#!/usr/bin/env bash
# Publish a validated staged build into phenomap-deploy/src/2_data. The old
# active tables are backed up first. Neo4j import is optional and prompts
# again because it replaces the database contents.

set -euo pipefail

BUILD_ROOT="${1:-}"
MODE="${2:-publish-only}"
DEPLOY_ROOT="${PHENOMAP_DEPLOY_ROOT:-/mnt/hdd1/home/yuting/phenomap-deploy}"
ACTIVE_DATA="$DEPLOY_ROOT/src/2_data"
STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_ROOT="$DEPLOY_ROOT/backups/kg_$STAMP"

if [ -z "$BUILD_ROOT" ] || [ ! -f "$BUILD_ROOT/.phenomap_kg_build_complete" ]; then
  echo "Usage: $0 /absolute/validated/build/root [publish-only|import]" >&2
  exit 2
fi
if [ "$MODE" != "publish-only" ] && [ "$MODE" != "import" ]; then
  echo "Mode must be publish-only or import." >&2
  exit 2
fi
if [ ! -x "$DEPLOY_ROOT/src/1_code/5_website/deploy/import_neo4j.sh" ]; then
  echo "Deployment import script not found under $DEPLOY_ROOT" >&2
  exit 1
fi

Rscript "$DEPLOY_ROOT/src/1_code/6_server_kg/03_validate_kg.R" "$BUILD_ROOT"

echo
echo "Validated build: $BUILD_ROOT"
echo "Active data:     $ACTIVE_DATA"
echo "Backup:          $BACKUP_ROOT"
echo "Mode:            $MODE"
echo
echo "Publishing replaces the active generated CSV/RDS tables after backing them up."
read -r -p "Type yes to continue: " answer
[ "$answer" = "yes" ] || { echo "Cancelled."; exit 1; }

mkdir -p "$BACKUP_ROOT" "$ACTIVE_DATA"
for dir in tidy_entity tidy_relationship neo4j; do
  [ -e "$ACTIVE_DATA/$dir" ] && cp -a "$ACTIVE_DATA/$dir" "$BACKUP_ROOT/"
done

mkdir -p "$ACTIVE_DATA/tidy_entity" "$ACTIVE_DATA/tidy_relationship" "$ACTIVE_DATA/neo4j/import"
rsync -a --delete "$BUILD_ROOT/tidy_entity/" "$ACTIVE_DATA/tidy_entity/"
rsync -a --delete "$BUILD_ROOT/tidy_relationship/" "$ACTIVE_DATA/tidy_relationship/"
rsync -a --delete "$BUILD_ROOT/neo4j/import/" "$ACTIVE_DATA/neo4j/import/"

echo "Published. Previous active tables are recoverable from $BACKUP_ROOT"

if [ "$MODE" = "import" ]; then
  echo
  echo "Starting the deployment's Neo4j full-import workflow."
  echo "It will stop Neo4j and ask for confirmation before replacing the database."
  "$DEPLOY_ROOT/src/1_code/5_website/deploy/import_neo4j.sh"
fi
