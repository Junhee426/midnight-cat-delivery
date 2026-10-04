#!/usr/bin/env bash
# Import -> smoke test -> Web export -> static checks. Used locally and by CI.
#   GODOT=/path/to/godot tools/build_web.sh
# Requires Godot 4.5.1 and the matching 4.5.1 export templates (web_nothreads_*.zip).
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"

"$GODOT" --version
echo "== import"
timeout 600 "$GODOT" --headless --path . --import
echo "== smoke test"
timeout 300 "$GODOT" --headless --path . --fixed-fps 60 --disable-vsync -- --smoke-test
echo "== web export"
rm -rf builds/web
mkdir -p builds/web
timeout 600 "$GODOT" --headless --path . --export-release "Web" builds/web/index.html
tools/check_web_export.sh builds/web
