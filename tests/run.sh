#!/usr/bin/env bash
#
# The pure modules under a real Lua 5.4. The pane requires its modules as
# `thurbox-fleet.lib.<name>`, the directory a clone install lands in, so the
# checkout is linked under that name in a scratch directory.
#
#   tests/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LUA="$(command -v lua5.4 || command -v lua)"
"$LUA" -v 2>&1 | grep -q "Lua 5.4" || { echo "Lua 5.4 not found" >&2; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
ln -s "$HERE" "$ROOT/thurbox-fleet"

LUA_PATH="$ROOT/?.lua" "$LUA" "$HERE/tests/unit.lua"
