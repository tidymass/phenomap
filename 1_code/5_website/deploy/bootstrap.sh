#!/usr/bin/env bash
# 一次性环境安装。可以重复跑：已经装好的部分会跳过。
# 全程不需要 sudo —— 所有东西都装在部署根目录下的 opt/ 里。

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ensure_dirs
load_config

ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || die "这个脚本只处理 x86_64，当前是 $ARCH"

# ---------------------------------------------------------------- 前置检查
say "检查系统已有的依赖"
command -v java >/dev/null || die "找不到 java。Neo4j 需要 Java 21。"
JAVA_MAJOR="$(java -version 2>&1 | sed -nE 's/.*version "([0-9]+).*/\1/p' | head -1)"
[ "${JAVA_MAJOR:-0}" -ge 21 ] || die "Java 版本是 $JAVA_MAJOR，Neo4j 2025.x 需要 21 或以上"
command -v Rscript >/dev/null || die "找不到 Rscript"
command -v node >/dev/null || die "找不到 node"
command -v npm  >/dev/null || die "找不到 npm"
command -v python3 >/dev/null || die "找不到 python3"
command -v curl >/dev/null || die "找不到 curl"
echo "  java $JAVA_MAJOR / $(node -v) / $(Rscript --version 2>&1 | head -1) / $(python3 -V)"

for p in "$PORT" "$NEO4J_BOLT_PORT" "$NEO4J_HTTP_PORT" "$ENRICHMENT_PORT" "$CHAT_PORT"; do
  if port_busy "$p"; then
    warn "端口 $p 已经被占用 —— 如果不是本部署自己的进程，请在 config/phenomap.env 里换一个"
  fi
done

# ---------------------------------------------------------------- Go
if [ -x "$GO_ROOT/bin/go" ]; then
  say "Go 已就位: $("$GO_ROOT/bin/go" version)"
else
  GOVER="${GO_VERSION:-}"
  [ -n "$GOVER" ] || GOVER="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
  [ -n "$GOVER" ] || die "查不到 Go 版本，请在配置里写死 GO_VERSION（形如 go1.24.0）"
  say "下载 Go $GOVER"
  curl -fSL --progress-bar "https://go.dev/dl/${GOVER}.linux-amd64.tar.gz" -o "$OPT_DIR/go.tar.gz"
  rm -rf "$GO_ROOT"; mkdir -p "$GO_ROOT"
  tar -xzf "$OPT_DIR/go.tar.gz" -C "$GO_ROOT" --strip-components=1
  rm -f "$OPT_DIR/go.tar.gz"
  say "Go 安装完成: $("$GO_ROOT/bin/go" version)"
fi

# ---------------------------------------------------------------- Neo4j + APOC
if [ -x "$NEO4J_HOME/bin/neo4j" ]; then
  say "Neo4j 已就位: $("$NEO4J_HOME/bin/neo4j" --version 2>/dev/null || echo 未知版本)"
else
  VER="${NEO4J_VERSION:-}"
  if [ -z "$VER" ]; then
    # APOC 的 release tag 跟 Neo4j 版本一一对应，所以从 APOC 的 release 列表里
    # 挑第一个「对应的 Neo4j 发行包确实存在」的 tag，两边版本天然匹配。
    say "查找可用的 Neo4j / APOC 版本组合"
    TAGS="$(curl -fsSL 'https://api.github.com/repos/neo4j/apoc/releases?per_page=20' \
            | grep -o '"tag_name"[^,]*' | sed -E 's/.*: *"([^"]+)".*/\1/')"
    for t in $TAGS; do
      if curl -fsI "https://dist.neo4j.org/neo4j-community-${t}-unix.tar.gz" >/dev/null 2>&1; then
        VER="$t"; break
      fi
    done
  fi
  [ -n "$VER" ] || die "自动找不到匹配的 Neo4j 版本，请在配置里填 NEO4J_VERSION"
  say "下载 Neo4j $VER"
  curl -fSL --progress-bar "https://dist.neo4j.org/neo4j-community-${VER}-unix.tar.gz" -o "$OPT_DIR/neo4j.tar.gz"
  rm -rf "$NEO4J_HOME"; mkdir -p "$NEO4J_HOME"
  tar -xzf "$OPT_DIR/neo4j.tar.gz" -C "$NEO4J_HOME" --strip-components=1
  rm -f "$OPT_DIR/neo4j.tar.gz"

  say "安装 APOC 插件 $VER（Path Query 的 apoc.path.expandConfig 依赖它）"
  curl -fSL --progress-bar \
    "https://github.com/neo4j/apoc/releases/download/${VER}/apoc-${VER}-core.jar" \
    -o "$NEO4J_HOME/plugins/apoc-${VER}-core.jar" \
    || die "APOC 下载失败。手动放一个 apoc-*-core.jar 到 $NEO4J_HOME/plugins/ 再重跑。"

  say "设置 Neo4j 初始密码"
  "$NEO4J_HOME/bin/neo4j-admin" dbms set-initial-password "$NEO4J_PASSWORD" >/dev/null
  echo "$VER" > "$NEO4J_HOME/.phenomap-version"
fi

say "写入 Neo4j 配置（只监听 127.0.0.1，不对内网暴露数据库）"
CONF="$NEO4J_HOME/conf/neo4j.conf"
cp -n "$CONF" "$CONF.orig" 2>/dev/null || true
# 先删掉这些 key 的所有现存行（含注释掉的），再统一追加，避免重复项。
sed -i -E '/^#?[[:space:]]*(server\.default_listen_address|server\.bolt\.listen_address|server\.http\.listen_address|server\.https\.enabled|server\.memory\.heap\.(initial|max)_size|server\.memory\.pagecache\.size|dbms\.security\.procedures\.(unrestricted|allowlist))=/d' "$CONF"
cat >> "$CONF" <<CONFEOF

# ---- 由 phenomap deploy/bootstrap.sh 写入 ----
server.default_listen_address=127.0.0.1
server.bolt.listen_address=127.0.0.1:${NEO4J_BOLT_PORT}
server.http.listen_address=127.0.0.1:${NEO4J_HTTP_PORT}
server.https.enabled=false
server.memory.heap.initial_size=${NEO4J_HEAP:-4G}
server.memory.heap.max_size=${NEO4J_HEAP:-4G}
server.memory.pagecache.size=${NEO4J_PAGECACHE:-4G}
dbms.security.procedures.unrestricted=apoc.*
dbms.security.procedures.allowlist=apoc.*
CONFEOF

# ---------------------------------------------------------------- libsodium
# R 的 plumber 硬依赖 sodium 包，它要在编译时链接 libsodium 的头文件。很多
# 服务器上只有运行时的 libsodium.so 而没有开发头文件，装 libsodium-dev 又要
# root。所以优先用系统的，没有就从 conda-forge 拉一份到 opt/ 下 —— 纯用户态，
# 不需要 sudo，也不污染系统。
SODIUM_PREFIX="$OPT_DIR/libsodium"
if [ -f "$SODIUM_PREFIX/include/sodium.h" ]; then
  say "libsodium 已就位: $SODIUM_PREFIX"
elif [ -f /usr/include/sodium.h ]; then
  SODIUM_PREFIX=/usr
  say "系统自带 libsodium 开发文件，直接用"
else
  MAMBA="$(command -v micromamba || command -v mamba || command -v conda || true)"
  [ -n "$MAMBA" ] || die "既没有 libsodium 开发文件，也没有 micromamba/conda 可以装它"
  # micromamba 没做过 shell init 时会没有 root prefix（包缓存位置），显式给一个，
  # 免得它去写用户家目录或直接报错。
  export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$OPT_DIR/mamba}"
  say "从 conda-forge 安装 libsodium 到 $SODIUM_PREFIX（不需要 sudo）"
  "$MAMBA" create -y -q -p "$SODIUM_PREFIX" -c conda-forge libsodium >/dev/null \
    || die "libsodium 安装失败"
  [ -f "$SODIUM_PREFIX/include/sodium.h" ] || die "装完了却找不到 sodium.h，看 $SODIUM_PREFIX"
fi

# ---------------------------------------------------------------- R plumber
mkdir -p "$R_LIB_DIR"
# 不靠 R_LIBS_USER：这台机器的 Renviron.site/.Renviron 会覆盖它（实测包被装到
# 了 /scratch 下而不是这里）。直接在 R 里 .libPaths() 指定，包全部装进部署目录
# 自己的库，跟系统 R 和别人的用户库互不影响，/scratch 被清也不受牵连。
r_run() {
  LD_LIBRARY_PATH="$SODIUM_PREFIX/lib:${LD_LIBRARY_PATH:-}" \
    Rscript -e ".libPaths('$R_LIB_DIR')" -e "$1"
}
if r_run 'quit(status = !requireNamespace("plumber", quietly=TRUE))' 2>/dev/null; then
  say "R plumber 已就位"
else
  say "安装 R 包 sodium + plumber 到 $R_LIB_DIR（要编译，几分钟，输出较多）"
  r_run "install.packages('sodium', lib='$R_LIB_DIR', repos='https://cloud.r-project.org', configure.vars='INCLUDE_DIR=$SODIUM_PREFIX/include LIB_DIR=$SODIUM_PREFIX/lib')"
  r_run "install.packages('plumber', lib='$R_LIB_DIR', repos='https://cloud.r-project.org')"
  # install.packages 装失败时退出码仍然是 0，只打一条 warning —— 所以必须显式
  # 复查一次，否则脚本会带着一个装了一半的 R 库继续往下跑。
  r_run 'quit(status = !requireNamespace("plumber", quietly=TRUE))' \
    || die "plumber 还是没装上，看上面的编译报错"
  say "R plumber 安装完成"
fi

# ---------------------------------------------------------------- Python
if [ -x "$VENV_DIR/bin/python" ]; then
  say "Python 虚拟环境已就位: $("$VENV_DIR/bin/python" -V)"
else
  say "创建 Python 虚拟环境"
  python3 -m venv "$VENV_DIR"
fi
say "安装 chat-service 依赖"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet -r "$WEB_DIR/chat-service/requirements.txt"

# ---------------------------------------------------------------- 前端依赖
say "安装前端依赖（npm，第一次会慢）"
(cd "$WEB_DIR/frontend" && npm install --no-audit --no-fund)

# ---------------------------------------------------------------- 数据检查
if [ -d "$IMPORT_DIR" ] && [ -f "$IMPORT_DIR/nodes_module.csv" ]; then
  say "Neo4j 导入文件已就位: $IMPORT_DIR"
else
  warn "还没有 Neo4j 导入文件。从本机 scp 过来后再跑 import_neo4j.sh："
  warn "  目标目录: $IMPORT_DIR"
fi
for d in tidy_entity tidy_relationship; do
  [ -d "$SRC_DIR/2_data/$d" ] || warn "缺少 2_data/$d（Module Enrichment 和 Download 功能需要）"
done

say "bootstrap 完成。下一步： ./build.sh 然后 ./import_neo4j.sh 然后 ./run_app.sh start"
