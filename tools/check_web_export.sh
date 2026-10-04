#!/usr/bin/env bash
# Static checks on a Web export directory (default builds/web).
set -euo pipefail
dir="${1:-builds/web}"
fail=0
err() { echo "FAIL: $*"; fail=1; }

for f in index.html index.js index.wasm index.pck; do
	[[ -s "$dir/$f" ]] || err "missing $dir/$f"
done
html="$dir/index.html"
if [[ -f "$html" ]]; then
	if grep -n '\$GODOT_' "$html"; then err "unreplaced \$GODOT_ placeholder in index.html"; fi
	grep -q 'const GODOT_THREADS_ENABLED = false;' "$html" || err "GODOT_THREADS_ENABLED is not false (single-threaded build expected)"
	grep -q 'Engine.getMissingFeatures({ threads: GODOT_THREADS_ENABLED })' "$html" || err "feature check does not use GODOT_THREADS_ENABLED"
	grep -q '"executable":"index"' "$html" || err "engine config executable is not relative 'index'"
	if grep -nE '(src|href)="/|"/index\.' "$html"; then err "root-absolute path found (breaks /<repo>/ sub-path hosting)"; fi
	if grep -q '"serviceWorker":"[^"]' "$html"; then err "service worker should be disabled (PWA off)"; fi
fi
# Nothing that should never ship.
if find "$dir" -name '*.tpz' -o -name 'Godot_v*' -o -name '*.mp4' -o -name '*.mov' | grep -q .; then
	err "engine binaries or videos found in $dir"
fi
ls -la "$dir"
[[ $fail -eq 0 ]] && echo "web export checks passed" || exit 1
