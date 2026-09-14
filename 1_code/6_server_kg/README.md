# PhenoMAP server KG rebuild

This folder turns the existing R scripts into a repeatable, staged server
workflow. A build is written outside the live deployment, validated for
duplicate IDs and orphan edges, then published only through a separate
confirmation step.

## 1. Copy the code from the Mac

Run from the local PhenoMAP project root:

```bash
bash 1_code/6_server_kg/00_sync_code_to_server.sh
```

This copies code only. It does not copy or delete `2_data`, server secrets,
accounts, uploads, logs, or Neo4j state.

## 2. Inspect the server data

Run on the server:

```bash
cd /mnt/hdd1/home/yuting/phenomap-deploy/src
bash 1_code/6_server_kg/01_inspect_server_data.sh \
  /mnt/hdd1/home/yuting | tee /mnt/hdd1/home/yuting/phenomap_input_inventory.txt
```

The build needs two *case roots*: their immediate children must be `ST...`
or `MTBLS...` directories containing both `study_meta.json` and
`anno_result/res_sig.rda`. A directory containing only exported module-list
CSV/XLSX files is not sufficient for the current KG builder.

## 3. Configure and build in isolation

```bash
mkdir -p /mnt/hdd1/home/yuting/phenomap-kg-config
cp 1_code/6_server_kg/server_kg.env.example \
  /mnt/hdd1/home/yuting/phenomap-kg-config/server_kg.env
nano /mnt/hdd1/home/yuting/phenomap-kg-config/server_kg.env
```

Fill in the four input paths and choose a new `BUILD_ROOT`. If reviewed
phenotype-normalization folders already cover the complete data, keep
`RUN_PHENOTYPE_NORMALIZATION=no`. Otherwise set it to `yes` and export the
OpenAI key in the shell without writing it into the config file:

```bash
export OPENAI_API_KEY='...'
```

For a long run, use tmux:

```bash
tmux new -s phenomap-kg
cd /mnt/hdd1/home/yuting/phenomap-deploy/src
bash 1_code/6_server_kg/02_build_kg.sh \
  /mnt/hdd1/home/yuting/phenomap-kg-config/server_kg.env
```

Detach with `Ctrl-b d`; return with `tmux attach -t phenomap-kg`. Logs and
`validation_summary.csv` are written inside `BUILD_ROOT`. The live website
and Neo4j database are unchanged at this point.

## 4. Review phenotype normalization

If normalization was run from scratch, inspect each
`phenotype_manual_review.csv`. The automatic result can be used for a test
build, but a production release should apply reviewed overrides through
`phenotype_manual_short.xlsx` and rerun into a new build directory.

## 5. Publish and optionally import Neo4j

Publish generated tables without changing Neo4j:

```bash
bash 1_code/6_server_kg/04_publish_and_import.sh \
  /mnt/hdd1/home/yuting/phenomap-kg-builds/build_YYYYMMDD publish-only
```

Publish and then start the full Neo4j import:

```bash
bash 1_code/6_server_kg/04_publish_and_import.sh \
  /mnt/hdd1/home/yuting/phenomap-kg-builds/build_YYYYMMDD import
```

The publish script validates again, shows exact paths, requires `yes`, and
backs up the previous generated data under `phenomap-deploy/backups/`.
Neo4j import has its own second confirmation because it replaces the active
database. Restart the app after a successful import:

```bash
cd /mnt/hdd1/home/yuting/phenomap-deploy/src/1_code/5_website/deploy
./run_app.sh restart
./run_app.sh status
```
