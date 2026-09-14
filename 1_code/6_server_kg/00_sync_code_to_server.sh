#!/usr/bin/env bash
# Run this script on the Mac from the PhenoMAP project root. It copies only
# the KG-building code to the existing server clone and never touches 2_data.

set -euo pipefail

REMOTE_HOST="${PHENOMAP_REMOTE_HOST:-yuting@10.96.129.143}"
REMOTE_SRC="${PHENOMAP_REMOTE_SRC:-/mnt/hdd1/home/yuting/phenomap-deploy/src}"

if [ ! -f "1_code/00_phenomap_helpers.R" ]; then
  echo "Run this script from the PhenoMAP project root." >&2
  exit 1
fi

echo "Destination: ${REMOTE_HOST}:${REMOTE_SRC}/"
echo "Only 1_code/0_prepare_raw through 1_code/3_neo4j_import and"
echo "1_code/6_server_kg will be copied. Existing server data/config are untouched."

rsync -av --itemize-changes \
  --exclude='.DS_Store' \
  --relative \
  1_code/00_phenomap_helpers.R \
  1_code/0_prepare_raw \
  1_code/1_tidy_entity \
  1_code/2_tidy_relationship \
  1_code/3_neo4j_import \
  1_code/6_server_kg \
  "${REMOTE_HOST}:${REMOTE_SRC}/"

echo "Code sync complete."
