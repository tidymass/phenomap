#!/usr/bin/env bash
# Read-only inventory of likely complete FeatureMAP/PhenoMAP inputs.

set -euo pipefail

SCAN_ROOT="${1:-/mnt/hdd1/home/yuting}"

if [ ! -d "$SCAN_ROOT" ]; then
  echo "Directory does not exist: $SCAN_ROOT" >&2
  exit 1
fi

echo "== host =="
hostname
printf 'user: %s\n' "$(whoami)"
printf 'scan root: %s\n' "$SCAN_ROOT"
df -h "$SCAN_ROOT"

echo
echo "== likely top-level project/data directories =="
find "$SCAN_ROOT" -mindepth 1 -maxdepth 2 -type d \
  \( -iname '*module*' -o -iname '*featuremap*' -o -iname '*phenomap*' \
     -o -iname '*metabolight*' -o -iname '*workbench*' -o -iname '*qwen*' \) \
  -print 2>/dev/null | sort

echo
echo "== module_lists_20260911 structure =="
MODULE_LISTS="$SCAN_ROOT/module_lists_20260911"
if [ -d "$MODULE_LISTS" ]; then
  find "$MODULE_LISTS" -maxdepth 3 -printf '%y\t%k KB\t%p\n' 2>/dev/null | \
    sort -k3,3 | sed -n '1,300p'
else
  echo "not found: $MODULE_LISTS"
fi

echo
echo "== FeatureMAP sentinel-file counts =="
for base in \
  "$MODULE_LISTS" \
  "$SCAN_ROOT/featuremap-deploy" \
  "$SCAN_ROOT/phenomap-deploy/src/2_data"; do
  [ -d "$base" ] || continue
  printf '\n[%s]\n' "$base"
  for name in study_meta.json res_sig.rda annotated_table_ms2.rda \
              phenotype_final_selection.csv phenotype_manual_short.xlsx; do
    count=$(find "$base" -type f -name "$name" -print 2>/dev/null | wc -l)
    printf '%7d  %s\n' "$count" "$name"
  done
done

echo
echo "== candidate case roots (parents containing study folders) =="
find "$SCAN_ROOT" -type f -name study_meta.json -print 2>/dev/null | \
  sed 's#/[^/]*/study_meta.json$##' | sort | uniq -c | sort -nr | sed -n '1,80p'

echo
echo "== candidate phenotype-normalization directories =="
find "$SCAN_ROOT" -type f -name phenotype_final_selection.csv -print 2>/dev/null | \
  sed 's#/phenotype_final_selection.csv$##' | sort

echo
echo "== sample study folders =="
find "$SCAN_ROOT" -type f -name res_sig.rda -print 2>/dev/null | \
  sed 's#/anno_result/res_sig.rda$##' | sort | sed -n '1,30p'

echo
echo "Inventory complete. This script did not modify anything."
