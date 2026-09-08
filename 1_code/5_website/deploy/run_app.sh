#!/usr/bin/env bash
# PhenoMAP 内网站点的启停入口。
#
#   ./run_app.sh start | stop | restart | status | logs [服务名] | update
#
# 四个服务：neo4j（图数据库）、enrich（R plumber 富集）、chat（Python 问答）、
# web（Go 后端 + 前端静态文件，唯一对内网开放的端口）。

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ensure_dirs
load_config

# ------------------------------------------------------------------ 通用
start_bg() {          # start_bg <名字> <工作目录> <命令...>
  local name="$1" wd="$2"; shift 2
  if is_running "$name"; then echo "  $name 已在运行 (pid $(cat "$(pid_file "$name")"))"; return 0; fi
  local log; log="$(log_file "$name")"
  # 注意括号里的写法：只把 nohup 那一条放到后台，$! 才是服务进程本身的 pid。
  # 写成 `cd ... && nohup ... &` 的话 $! 是外层子 shell 的 pid，之后 stop 会杀错进程。
  (
    cd "$wd" || exit 1
    nohup "$@" >>"$log" 2>&1 &
    echo $! > "$(pid_file "$name")"
  )
  sleep 1
  if is_running "$name"; then
    echo "  $name 已启动 (pid $(cat "$(pid_file "$name")"))"
  else
    warn "$name 启动即退出，日志尾部："; tail -20 "$log" >&2; return 1
  fi
}

stop_bg() {
  local name="$1" pf; pf="$(pid_file "$name")"
  if ! is_running "$name"; then echo "  $name 未在运行"; rm -f "$pf"; return 0; fi
  local pid; pid="$(cat "$pf")"
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$pid" 2>/dev/null && { warn "$name 没退，强制 kill"; kill -9 "$pid" 2>/dev/null || true; }
  rm -f "$pf"; echo "  $name 已停止"
}

# ------------------------------------------------------------------ neo4j
neo4j_running() { "$NEO4J_HOME/bin/neo4j" status >/dev/null 2>&1; }

start_neo4j() {
  if neo4j_running; then echo "  neo4j 已在运行"; return 0; fi
  "$NEO4J_HOME/bin/neo4j" start >>"$(log_file neo4j)" 2>&1 || die "neo4j 启动失败，看 $(log_file neo4j)"
  wait_for_port "$NEO4J_BOLT_PORT" neo4j 90 || die "等了 90 秒 bolt 端口还没起来，看 $NEO4J_HOME/logs/neo4j.log"
  # 端口通了不等于数据库 online（RUNBOOK 第 2.2 节踩过这个坑），再确认一次。
  for _ in $(seq 1 30); do
    if "$NEO4J_HOME/bin/cypher-shell" -a "bolt://127.0.0.1:$NEO4J_BOLT_PORT" \
         -u "$NEO4J_USER" -p "$NEO4J_PASSWORD" -d "$NEO4J_DATABASE" \
         "RETURN 1" >/dev/null 2>&1; then
      echo "  neo4j 已启动，数据库 $NEO4J_DATABASE 在线"; return 0
    fi
    sleep 2
  done
  warn "neo4j 进程起来了但数据库还没 online，看 $NEO4J_HOME/logs/neo4j.log"
}

stop_neo4j() {
  if neo4j_running; then "$NEO4J_HOME/bin/neo4j" stop >/dev/null 2>&1 && echo "  neo4j 已停止";
  else echo "  neo4j 未在运行"; fi
}

# ------------------------------------------------------------------ 动作
do_start() {
  [ -x "$BIN_DIR/phenomap-web" ] || die "还没构建，先跑 ./build.sh"
  [ -f "$DIST_DIR/index.html" ]  || die "前端还没构建，先跑 ./build.sh"
  say "启动"
  start_neo4j
  # .libPaths 和 LD_LIBRARY_PATH 要跟 bootstrap.sh 里装包时用的一致：R 包装在
  # 部署目录自己的库里，sodium 链接的是 opt/libsodium 下那份运行时库。
  start_bg enrich "$WEB_DIR/enrichment-service" \
    env LD_LIBRARY_PATH="$OPT_DIR/libsodium/lib:${LD_LIBRARY_PATH:-}" \
    Rscript -e ".libPaths('$R_LIB_DIR')" \
            -e "pr <- plumber::plumb('$WEB_DIR/enrichment-service/plumber.R'); pr\$run(host='127.0.0.1', port=$ENRICHMENT_PORT)"
  if [ "${ENABLE_CHAT:-yes}" = "yes" ]; then
    start_bg chat "$WEB_DIR/chat-service" \
      "$VENV_DIR/bin/uvicorn" main:app --host 127.0.0.1 --port "$CHAT_PORT"
  else
    echo "  chat 已在配置里关闭 (ENABLE_CHAT=no)"
  fi
  start_bg web "$DEPLOY_ROOT" "$BIN_DIR/phenomap-web"
  wait_for_port "$PORT" web 30 || warn "网站端口 $PORT 还没响应，看 $(log_file web)"
  echo
  echo "  组员访问:  $SITE_URL"
  echo "  日志:      $LOG_DIR/"
}

do_stop() { say "停止"; stop_bg web; stop_bg chat; stop_bg enrich; stop_neo4j; }

do_status() {
  say "状态"
  if neo4j_running; then echo "  neo4j   运行中  (bolt 127.0.0.1:$NEO4J_BOLT_PORT)"; else echo "  neo4j   已停止"; fi
  for s in enrich chat web; do
    if is_running "$s"; then printf '  %-7s 运行中  (pid %s)\n' "$s" "$(cat "$(pid_file "$s")")";
    else printf '  %-7s 已停止\n' "$s"; fi
  done
  echo
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/health" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then echo "  健康检查 /api/health: OK  -> $SITE_URL"
  else echo "  健康检查 /api/health: 失败 (HTTP $code)"; fi
}

do_logs() {
  local which="${1:-}"
  if [ -n "$which" ]; then tail -f "$(log_file "$which")"; else tail -f "$LOG_DIR"/*.log; fi
}

do_update() {
  say "拉取最新代码"
  git -C "$SRC_DIR" pull --ff-only
  say "重新构建"
  "$DEPLOY_SCRIPT_DIR/build.sh"
  say "重启"
  do_stop; do_start
}

case "${1:-}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  status)  do_status ;;
  logs)    shift; do_logs "${1:-}" ;;
  update)  do_update ;;
  *) echo "用法: $0 {start|stop|restart|status|logs [neo4j|enrich|chat|web]|update}"; exit 1 ;;
esac
