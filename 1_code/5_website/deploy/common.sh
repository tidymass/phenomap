#!/usr/bin/env bash
# Shared paths and config loading for every script in this directory.
# Not meant to be run on its own -- the others source it.

set -euo pipefail

DEPLOY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This file lives at <clone>/1_code/5_website/deploy/common.sh, so the git
# clone is three levels up, and the deployment root is its parent.
SRC_DIR="$(cd "$DEPLOY_SCRIPT_DIR/../../.." && pwd)"
DEPLOY_ROOT="${PHENOMAP_DEPLOY_ROOT:-$(cd "$SRC_DIR/.." && pwd)}"

WEB_DIR="$SRC_DIR/1_code/5_website"
OPT_DIR="$DEPLOY_ROOT/opt"
BIN_DIR="$DEPLOY_ROOT/bin"
LOG_DIR="$DEPLOY_ROOT/logs"
RUN_DIR="$DEPLOY_ROOT/run"
STATE_DIR="$DEPLOY_ROOT/state"
CONFIG_DIR="$DEPLOY_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/phenomap.env"

GO_ROOT="$OPT_DIR/go"
NEO4J_HOME="$OPT_DIR/neo4j"
VENV_DIR="$OPT_DIR/venv"
R_LIB_DIR="$OPT_DIR/rlib"
DIST_DIR="$WEB_DIR/frontend/dist"
IMPORT_DIR="$SRC_DIR/2_data/neo4j/import"

say()  { printf '\033[1;36m==\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

ensure_dirs() {
  mkdir -p "$OPT_DIR" "$BIN_DIR" "$LOG_DIR" "$RUN_DIR" "$STATE_DIR" "$CONFIG_DIR"
}

# Load the deployment config and derive everything the four services read.
# Every service is configured purely through environment variables here --
# no .env files are written anywhere, so there is exactly one place
# (config/phenomap.env) where a setting can be wrong.
load_config() {
  [ -f "$CONFIG_FILE" ] || die "缺少配置文件: $CONFIG_FILE
先复制模板并填写: cp '$DEPLOY_SCRIPT_DIR/phenomap.env.example' '$CONFIG_FILE'"
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  set +a

  : "${PORT:?配置里缺少 PORT}"
  : "${SITE_URL:?配置里缺少 SITE_URL}"
  : "${NEO4J_PASSWORD:?配置里缺少 NEO4J_PASSWORD}"
  [ "$NEO4J_PASSWORD" = "change-me" ] && die "NEO4J_PASSWORD 还是模板里的 change-me，请改掉"

  NEO4J_BOLT_PORT="${NEO4J_BOLT_PORT:-7687}"
  NEO4J_HTTP_PORT="${NEO4J_HTTP_PORT:-7474}"
  ENRICHMENT_PORT="${ENRICHMENT_PORT:-8797}"
  CHAT_PORT="${CHAT_PORT:-8798}"

  # --- what the Go backend reads (see its getenv calls) ---
  export PORT
  export NEO4J_URI="neo4j://127.0.0.1:$NEO4J_BOLT_PORT"
  export NEO4J_USER="${NEO4J_USER:-neo4j}"
  export NEO4J_PASSWORD
  export NEO4J_DATABASE="${NEO4J_DATABASE:-neo4j}"
  export ENRICHMENT_SERVICE_URL="http://127.0.0.1:$ENRICHMENT_PORT"
  export CHAT_SERVICE_URL="http://127.0.0.1:$CHAT_PORT"
  export FRONTEND_DIST_DIR="$DIST_DIR"
  # State that must survive a `git pull` lives outside the clone.
  export AUTH_DB_PATH="$STATE_DIR/phenomap_auth.db"
  export COMMUNITY_UPLOAD_DIR="$STATE_DIR/community_uploads"
  # download.go resolves 2_data relative to this.
  export PHENOMAP_DATA_ROOT="$SRC_DIR"
  # Plain HTTP on the intranet: a Secure cookie would never be sent back.
  export SESSION_COOKIE_SECURE="${SESSION_COOKIE_SECURE:-false}"
  export PUBLIC_BACKEND_URL="$SITE_URL"
  export PUBLIC_FRONTEND_URL="$SITE_URL"
  export ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-$SITE_URL}"
  export SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_FROM

  # --- what the Python chat-service reads (see chat-service/config.py) ---
  export BACKEND_URL="http://127.0.0.1:$PORT"

  mkdir -p "$COMMUNITY_UPLOAD_DIR"
}

pid_file() { echo "$RUN_DIR/$1.pid"; }
log_file() { echo "$LOG_DIR/$1.log"; }

is_running() {
  local pf; pf="$(pid_file "$1")"
  [ -f "$pf" ] || return 1
  local pid; pid="$(cat "$pf" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# 纯 bash 的 TCP 探测，不依赖 ss/netstat/nc 是否装了。
port_busy() { timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

# Wait until a port answers, or give up. Beats `sleep 5` and a guess.
wait_for_port() {
  local port="$1" name="$2" tries="${3:-60}"
  for _ in $(seq 1 "$tries"); do
    port_busy "$port" && return 0
    sleep 1
  done
  return 1
}
