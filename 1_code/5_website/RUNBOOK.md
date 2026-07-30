# PhenoMAP 网站 — 搭建步骤与命令汇总

记录到目前为止做过的所有事情，以及每次要重新跑起来时需要的确认无误的命令。

## 架构

```
Neo4j Desktop (图数据库, 本地)
      ↑ Bolt :7687
Go backend (:8080)  ──HTTP──>  R plumber enrichment service (:8787)
      │  ↑ HTTP (CORS + cookie)      ↑ 直接读 2_data/tidy_entity, tidy_relationship
      └─────────HTTP──>  Python chat-service (:8788) ──HTTP──> 回调 Go backend 自己的
                                                                 /api/search /api/node
                                                                 /api/path /api/enrichment
Vue frontend (:5173, dev) / 打包后的静态文件
```

五块各自独立进程，本地开发时要分别启动。chat-service 不直接碰 Neo4j 或 R
plumber，只调用 Go backend 已有的四个只读接口（见第 7 节）。

---

## 1. R 数据管线 → Neo4j 导入文件

`1_code/3_neo4j_import/01_format_neo4j_import.R` 把 `2_data/tidy_entity/` 和
`2_data/tidy_relationship/` 里的表转成 neo4j-admin 认识的 CSV 格式，输出到
`2_data/neo4j/import/`。

**关键修复**：原来的 `format_node()` 把 `Lab_ID` 列改名成 `:ID`，导致
`Lab_ID` 这个属性在导入后查不到了。已修复为保留 `Lab_ID` 同时另外复制一份
`:ID` 列。

跑一次生成最新的导入文件：

```r
source("1_code/3_neo4j_import/01_format_neo4j_import.R")
```

会在 `2_data/neo4j/import/` 生成：

```
nodes_study.csv        nodes_phenotype.csv
nodes_module.csv       nodes_metabolite.csv
edges_study_phenotype.csv
edges_module_study.csv
edges_metabolite_module.csv
edges_module_module.csv
edges_metabolite_metabolite.csv
```

---

## 2. Neo4j Desktop 本地环境

### 2.1 Java 21（Neo4j 2025.01+/2026.x 需要，Java 17 不再支持）

```bash
brew install openjdk@21
```

如果装完 `java -version` 还是报 "Unable to locate a Java Runtime"（keg-only
没链接到系统路径），执行：

```bash
sudo ln -sfn /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk \
  /Library/Java/JavaVirtualMachines/openjdk-21.jdk
```

验证：

```bash
java -version
```

### 2.2 创建 DBMS 并导入数据

1. Neo4j Desktop 里新建一个 DBMS（比如叫 PhenoMAP）
2. 点 DBMS 卡片的 "..." → "Open folder" → "Import"，把第 1 步生成的 9 个
   CSV 全部复制进去
3. 在这个 DBMS 目录下打开 Terminal（`cd` 到 Desktop 卡片显示的 `Path`），
   停止数据库（Desktop 里点 Stop），执行：

```bash
bin/neo4j-admin database import full neo4j \
  --nodes=Study=import/nodes_study.csv \
  --nodes=Phenotype=import/nodes_phenotype.csv \
  --nodes=Module=import/nodes_module.csv \
  --nodes=Metabolite=import/nodes_metabolite.csv \
  --relationships=INVESTIGATED=import/edges_study_phenotype.csv \
  --relationships=REPORTED_IN=import/edges_module_study.csv \
  --relationships=MEMBER_OF=import/edges_metabolite_module.csv \
  --relationships=SIMILAR_TO=import/edges_module_module.csv \
  --relationships=CONNECTED_WITH=import/edges_metabolite_metabolite.csv \
  --multiline-fields=true \
  --overwrite-destination=true
```

`--multiline-fields=true` 是必须的（否则 `nodes_phenotype.csv` 会报
"field spanned multiple lines" 报错）。

4. Desktop 里重新 Start 这个 DBMS
5. 确认数据库真的在线（不是只有 DBMS 在跑），在 Neo4j Browser 里对 `system`
   库执行：

```cypher
SHOW DATABASES YIELD name, currentStatus, statusMessage
```

`neo4j` 那一行 `currentStatus` 要是 `online`。

### 2.3 安装 APOC 插件（Path Query 功能依赖）

Path Query 的连接子图查询（`backend/path.go` 的 `apocExpandQuery`）用的是
APOC 库自带的 `apoc.path.expandConfig` 原生遍历过程，而不是手写的逐层 BFS
循环 —— 一次 Cypher 调用就能拿到"从某个节点出发、限定跳数内、每个可达节点
的最短距离"，比原来每一层都要走一次 Go<->Neo4j 往返快得多，也更不容易在
高连通度节点上出问题。这个功能**必须**装 APOC 插件才能用。

1. Neo4j Desktop 里点这个 DBMS 卡片 → 右侧 "Plugins" 标签
2. 找到 "APOC"，点 Install（装的是 APOC Core，不用额外配置 APOC Extended）
3. 装完之后重启这个 DBMS（Stop 再 Start）
4. 验证装成功了，在 Neo4j Browser 里执行：

```cypher
RETURN apoc.version()
```

能返回版本号就说明可用了。如果 Path Query 报错提示
`Unknown function 'apoc.path.expandConfig'`，说明插件没装上或者没重启。

---

## 3. R plumber enrichment 服务（Module Enrichment 功能用）

```bash
cd "1_code/5_website/enrichment-service"
Rscript -e "plumber::plumb('plumber.R')\$run(port=8787)"
```

看到监听 `:8787` 就是启动成功。前端的 Module Enrichment 页面会通过 Go
backend 转发请求到这里。

---

## 4. Go backend

`1_code/5_website/backend/.env` 需要配置好（Neo4j 密码 + SMTP，见第 6 节）。

```bash
cd "1_code/5_website/backend"
brew install go        # 只需装一次
go mod tidy
set -a; source .env; set +a
go run .
```

看到 `phenomap-web backend listening on :8080 (neo4j db=neo4j)` 就是成功。

**每次改了 `.env` 都要重新走一遍 `source .env; go run .`**（不能只是重启
`go run .`，环境变量是 source 那一刻读进去的）。

---

## 5. Vue frontend

```bash
cd "1_code/5_website/frontend"
npm install        # 只需装一次
npm run dev
```

打开 `http://localhost:5173`。

---

## 6. Sign In 功能：Gmail App Password 配置

`.env` 里现在这些字段都要填好：

```
AUTH_DB_PATH=phenomap_auth.db
SESSION_COOKIE_SECURE=false

SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USERNAME=phenomap.shenlab@gmail.com
SMTP_PASSWORD=<16位应用专用密码，不要用 Gmail 登录密码>
SMTP_FROM=phenomap.shenlab@gmail.com

PUBLIC_BACKEND_URL=http://localhost:8080
PUBLIC_FRONTEND_URL=http://localhost:5173
```

获取应用专用密码的步骤：

1. 用 `SMTP_USERNAME` 这个 Google 账号登录浏览器（不是你个人账号）
2. https://myaccount.google.com/security 开启两步验证（没开的话）
3. https://myaccount.google.com/apppasswords → App name 填 `PhenoMAP` →
   Create → 复制生成的 16 位密码
4. 填进 `.env` 的 `SMTP_PASSWORD=`，去掉中间空格
5. 重启 backend（`source .env; go run .`）

注意：验证邮件里的链接是 `http://localhost:8080/...`，只能在**同一台电脑**
上打开才有效，手机打开会没反应（不是 bug）。

### 本地测试账号数据库操作

数据库文件：`1_code/5_website/backend/phenomap_auth.db`

删掉一个测试账号（方便重复用同一个邮箱注册测试）：

```bash
cd "1_code/5_website/backend"
sqlite3 phenomap_auth.db "DELETE FROM users WHERE email = '测试用的邮箱@example.com';"
```

确认删除成功：

```bash
sqlite3 phenomap_auth.db "SELECT email FROM users;"
```

---

## 7. AI Q&A Agent（chat-service，Python）

`1_code/5_website/chat-service/` 是一个新的独立进程，跟 enrichment-service 是同一种角色：
Go backend 转发 `/api/chat` 请求过去，chat-service 自己不碰 Neo4j 或 R plumber，
只调用 Go backend 已有的 `/api/search`、`/api/node`、`/api/path`、`/api/enrichment`
这四个接口——跟前端四个 Analysis 页面能查到的东西完全一致，不会多出一个数据源。

### 定位（详见对话记录 / chat-service/README.md）

结构化检索型 agent，不是文本 RAG：LLM 只负责理解意图 + 决定调用哪个工具 + 把结构化
结果转述成自然语言，**不允许它凭自身知识回答任何 PhenoMAP 图谱里的具体事实**（Lab_ID、
模块标题、富集结果等）——这些 ID 和内容从没出现在任何 LLM 的训练数据里，模型如果不是
刚查到的，几乎肯定是编的。

回答里引用某个实体时用 `{{Lab_ID}}` 语法标记，前端只有在这个 ID 真的来自本轮某次工具
调用时才会渲染成可点击链接，模型没查过就编出来的 ID 会原样显示成文字，不会被渲染成
指向任何页面的链接。

### 启动

```bash
cd "1_code/5_website/chat-service"
pip install -r requirements.txt
cp .env.example .env        # 填入 LLM_API_KEY
uvicorn main:app --port 8788
```

看到 `Uvicorn running on http://0.0.0.0:8788` 就是启动成功。Go backend 的 `.env` 已加了
`CHAT_SERVICE_URL=http://127.0.0.1:8788`，`go run .` 会自动去转发。

前端导航栏 Analysis 下拉里的 "Q&A Agent" 现在指向 `/chat`（之前是禁用的占位项）。

### 这一版还没做的

- 对话历史不持久化，只存在浏览器这一次会话里（每次请求由前端把之前几轮重新发过去）。
- 不支持流式输出，一轮工具调用可能要等几秒。
- 只有一种 evidence-grounded 模式，还没有 fast/lite 切换。
- **没有在本环境里跑起来验证过**：Python 语法用 `py_compile` 过了一遍，前端
  `ChatView.vue` 用 `vite build` 实际编译成功了，但 Go backend 这边因为沙盒里没有
  Go 工具链（跟 frontend/README.md 里之前遇到的问题一样），只能人工比对语法，没有
  真正 `go run .` 编译过；`chat.go`/`handlers.go`/`main.go` 的改动如果报错，把错误
  贴回来我再改。真正端到端跑一次（问一个问题、点一次引用链接）还是需要你本地起全部
  五个进程（Neo4j + Go backend + enrichment-service + chat-service + frontend）来测。

---

## 8. 目前的状态

| 阶段 | 内容 | 状态 |
|---|---|---|
| Neo4j | 本地导入，Lab_ID 属性正常 | 已确认可用 |
| Phase 1 | 单节点搜索 + 详情 + 邻居跳转 | 已确认可用 |
| Phase 2 | 两节点路径查询（连接子图，依赖 APOC 插件，见 2.3） | 改用 APOC 原生遍历，待你重新 build+实测 |
| Phase 3 | Module Enrichment（R plumber） | 已确认可用 |
| Phase 4a | About / Download / Help / Community 静态页 + 导航栏 | 前端已构建，未见反馈 |
| Sign In | 注册 + 邮箱验证 + 登录 + Session Cookie | 刚加了机构字段 + 密码强度校验，待测试 |
| Phase 5 | AI Q&A Agent（chat-service，见第 7 节） | v1 代码已写完（结构化检索型 agent，四个只读工具），未端到端跑过，待你本地起五个进程实测 |
| 未开始 | Community 实际功能（评论/投票/审核） | 仅占位页面 |
| 未开始 | 找回密码 / OAuth 登录 | 明确暂不做 |

### 待你确认的最新改动

刚加的三项还没实测：
1. 注册需要填机构（Institution）
2. 密码要求：长度大于 8，且大写/小写/数字/特殊字符至少占 3 种
3. 邮箱重复注册会被拒绝（这个其实之前就有，这次没改动逻辑）

重启 backend 后去 `/signup` 试一次即可。
