#!/usr/bin/env bash
# 把 2_data/neo4j/import 下的 9 个 CSV 导入 Neo4j。
# 这是全量覆盖导入（--overwrite-destination），会清掉库里原有数据。

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ensure_dirs
load_config

[ -x "$NEO4J_HOME/bin/neo4j-admin" ] || die "还没装 Neo4j，先跑 ./bootstrap.sh"
[ -d "$IMPORT_DIR" ] || die "找不到导入目录: $IMPORT_DIR"
for f in nodes_study nodes_phenotype nodes_module nodes_metabolite \
         edges_study_phenotype edges_module_study edges_metabolite_module \
         edges_module_module edges_metabolite_metabolite; do
  [ -f "$IMPORT_DIR/$f.csv" ] || die "缺少 $IMPORT_DIR/$f.csv"
done

if [ "${1:-}" != "-y" ]; then
  echo "即将全量覆盖导入数据库 '$NEO4J_DATABASE'，原有数据会被清空。"
  read -r -p "继续？(yes/N) " ans
  [ "$ans" = "yes" ] || die "已取消"
fi

say "停止 Neo4j（导入必须在数据库离线时进行）"
"$NEO4J_HOME/bin/neo4j" stop >/dev/null 2>&1 || true
sleep 2

say "导入中（几分钟，取决于磁盘）"
# --multiline-fields=true 是必须的：nodes_phenotype.csv 里有跨行的字段，
# 少了这个参数会报 "field spanned multiple lines"。
"$NEO4J_HOME/bin/neo4j-admin" database import full "$NEO4J_DATABASE" \
  --nodes=Study="$IMPORT_DIR/nodes_study.csv" \
  --nodes=Phenotype="$IMPORT_DIR/nodes_phenotype.csv" \
  --nodes=Module="$IMPORT_DIR/nodes_module.csv" \
  --nodes=Metabolite="$IMPORT_DIR/nodes_metabolite.csv" \
  --relationships=INVESTIGATED="$IMPORT_DIR/edges_study_phenotype.csv" \
  --relationships=REPORTED_IN="$IMPORT_DIR/edges_module_study.csv" \
  --relationships=MEMBER_OF="$IMPORT_DIR/edges_metabolite_module.csv" \
  --relationships=SIMILAR_TO="$IMPORT_DIR/edges_module_module.csv" \
  --relationships=CONNECTED_WITH="$IMPORT_DIR/edges_metabolite_metabolite.csv" \
  --multiline-fields=true \
  --overwrite-destination=true

say "导入完成。用 ./run_app.sh start 启动，或 ./run_app.sh restart 重启全部服务。"
