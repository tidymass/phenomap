# PhenoMAP 内网部署（GPU 服务器 10.96.129.143）

不需要 sudo，不需要 Docker。所有依赖装在部署根目录的 `opt/` 下，跟系统环境和
组里其他人的环境完全隔离。

## 架构（跟本地开发的区别）

本地开发是五个进程、前端单独跑在 Vite :5173；部署后是**四个**进程，前端打包成
静态文件由 Go backend 一起提供：

```
                        ┌─ 组员浏览器 (内网)
                        ↓
        http://10.96.129.143:3839   ← 唯一对内网开放的端口
                        ↓
   Go backend :3839  ── 前端静态文件 (frontend/dist)
        │             ── /api/*
        ├── bolt 127.0.0.1:7687 ──→ Neo4j (+APOC 插件)
        ├── HTTP 127.0.0.1:8797 ──→ R plumber 富集服务
        └── HTTP 127.0.0.1:8798 ──→ Python chat-service ──→ Qwen 推理服务
```

前后端同源带来两个好处：不再需要 CORS 例外，登录的 session cookie 也不存在
跨域问题。数据库和三个内部服务只监听 127.0.0.1，内网扫不到。

## 目录布局

```
phenomap-deploy/
  src/                  这个仓库的 git clone（代码 + 2_data）
  config/phenomap.env   唯一的配置文件（含密码，权限 600）
  opt/go  opt/neo4j  opt/venv  opt/rlib        自装的依赖
  bin/phenomap-web      构建产物
  state/                认证数据库、Community 上传件（git pull 不会动它）
  logs/  run/           日志和 pid
```

状态数据刻意放在 `src/` 之外：`git pull` 或重新 clone 都不会碰到用户账号。

## 首次部署

```bash
DEPLOY=/mnt/hdd1/home/yuting/phenomap-deploy
mkdir -p "$DEPLOY" && cd "$DEPLOY"
git clone git@github.com:tidymass/phenomap.git src
cd src/1_code/5_website/deploy

cp phenomap.env.example "$DEPLOY/config/phenomap.env"   # 需要先 mkdir -p config
chmod 600 "$DEPLOY/config/phenomap.env"
vim "$DEPLOY/config/phenomap.env"      # 至少要填 NEO4J_PASSWORD 和 SMTP_PASSWORD

./bootstrap.sh          # 装 Go / Neo4j+APOC / plumber / python 环境（十几分钟）
# 从本地 scp 数据到 $DEPLOY/src/2_data/ 之后：
./import_neo4j.sh       # 导入图数据库
./build.sh              # 打包前端 + 编译后端
./run_app.sh start
```

`2_data` 在 `.gitignore` 里，不会随 clone 下来，要从本地机器 scp（约 222M）：

```bash
# 在本地 Mac 上执行
cd <本地 phenomap 目录>
rsync -avz --progress 2_data/neo4j/import 2_data/tidy_entity 2_data/tidy_relationship \
  yuting@10.96.129.143:/mnt/hdd1/home/yuting/phenomap-deploy/src/2_data/
```

## 日常操作

```bash
cd /mnt/hdd1/home/yuting/phenomap-deploy/src/1_code/5_website/deploy

./run_app.sh status          # 四个服务的状态 + /api/health 健康检查
./run_app.sh restart         # 重启
./run_app.sh logs web        # 跟一个服务的日志（neo4j|enrich|chat|web）
./run_app.sh update          # git pull + 重新构建 + 重启（改了代码之后用这个）
```

改了 `config/phenomap.env` 只需要 `restart`；改了代码要走 `update`（或者
`./build.sh && ./run_app.sh restart`）。

数据更新了（重新跑过 `3_neo4j_import/01_format_neo4j_import.R`）就重新 rsync
`2_data/`，然后 `./import_neo4j.sh` 再 `./run_app.sh restart`。

## 开机自启

服务器重启后需要手动拉起来一次。想自动化，用 crontab（不需要 sudo）：

```bash
crontab -e
# 加一行：
@reboot /mnt/hdd1/home/yuting/phenomap-deploy/src/1_code/5_website/deploy/run_app.sh start >> /mnt/hdd1/home/yuting/phenomap-deploy/logs/boot.log 2>&1
```

## 排查

| 现象 | 先看哪里 |
|---|---|
| 打不开网页 | `./run_app.sh status`；`logs/web.log` |
| 网页开了但搜不到东西 | Neo4j 是否 online：`opt/neo4j/logs/neo4j.log`；是否导入过数据 |
| Path Query 报 `Unknown function 'apoc.path.expandConfig'` | APOC 插件没装上或没重启，看 `opt/neo4j/plugins/` |
| Module Enrichment 报错 | `logs/enrich.log`；确认 `src/2_data/tidy_entity` 存在 |
| Q&A 报连不上模型 | Qwen 推理服务没起，或 `OFFICIAL_QWEN_BASE_URL` 配错 |
| 注册收不到验证邮件 | `logs/web.log` 里的 SMTP 报错；确认用的是 Gmail 应用专用密码 |

端口冲突要注意：这台机器上 `8080` 已被别的服务占用，`8787` 是 RStudio Server，
`3838` 是 featuremap 的 Shiny。本部署刻意避开了这三个。
