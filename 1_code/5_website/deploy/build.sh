#!/usr/bin/env bash
# 构建前端静态文件和 Go 后端二进制。改了代码之后重跑这个，再 ./run_app.sh restart。

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ensure_dirs
load_config

[ -x "$GO_ROOT/bin/go" ] || die "还没装 Go，先跑 ./bootstrap.sh"

say "构建前端 (vite build)"
# .env.production 里 VITE_API_BASE_URL 是空的 —— 打出来的包用相对路径调 /api/…，
# 所以不管组员用 IP 还是主机名访问都能用，换端口也不用重新构建。
(cd "$WEB_DIR/frontend" && npm run build)
[ -f "$DIST_DIR/index.html" ] || die "前端构建没产出 dist/index.html"

say "构建 Go 后端"
# 产物放在部署根目录的 bin/ 下，不覆盖仓库里那个 backend/phenomap-web，
# 免得下次 git pull 冲突。
(
  cd "$WEB_DIR/backend"
  export PATH="$GO_ROOT/bin:$PATH"
  export GOPATH="$OPT_DIR/gopath" GOCACHE="$OPT_DIR/gocache"
  go mod download
  CGO_ENABLED=0 go build -trimpath -o "$BIN_DIR/phenomap-web" .
)
say "构建完成: $BIN_DIR/phenomap-web ($(du -h "$BIN_DIR/phenomap-web" | cut -f1))"
