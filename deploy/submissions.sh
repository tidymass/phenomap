#!/usr/bin/env bash
# Curator tool for Community submissions -- see submissions.py for usage.
#   ./submissions.sh list | show <ID> | set <ID> [--status ...] [--inclusion ...] [--link ...] [--note ...]

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_config

PY="$VENV_DIR/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
exec "$PY" "$DEPLOY_SCRIPT_DIR/submissions.py" "$@"
