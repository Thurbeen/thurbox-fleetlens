#!/usr/bin/env bash
#
# Acceptance: Fleet Lens lists Tasks from a real Fleet store, and an unreadable
# store is never drawn as an empty list.
#
# A real `fleet` (fake runtime, so no agent runs) and a real `thurbox` in a
# private tmux server, both under a throwaway HOME, so nothing real is read or
# written. The pane is the working copy, symlinked into a scratch interface.
#
#   tests/e2e/lens_lists_tasks.sh
#   THURBOX_BIN=/dir/with/thurbox FLEET_BIN=/dir/with/fleet tests/e2e/lens_lists_tasks.sh
#   KEEP=1 tests/e2e/lens_lists_tasks.sh     # keep the sandbox and print where
set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
COLS=160
ROWS=45

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2
  if [ -n "${SOCKET:-}" ]; then
    printf '%s\n' '--- last frame ---' >&2
    capture >&2 || true
  fi
  exit 1
}

# Each binary from its own directory when given, else from PATH. Resolved
# before HOME moves, so a binary under the real ~/.local/bin is still found.
bin() {
  local dir="$1" name="$2"
  if [ -n "$dir" ]; then echo "$dir/$name"; else command -v "$name"; fi
}
THURBOX="$(bin "${THURBOX_BIN:-}" thurbox)" || die "thurbox not found"
THURBOX_CLI="$(bin "${THURBOX_BIN:-}" thurbox-cli)" || die "thurbox-cli not found"
FLEET="$(bin "${FLEET_BIN:-}" fleet)" || die "fleet not found"
command -v tmux >/dev/null || die "tmux not found"
command -v python3 >/dev/null || die "python3 not found"

# ── the sandbox ─────────────────────────────────────────────────────────────
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/thurbox-fleetlens-e2e.XXXXXX")"
export HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/config" XDG_DATA_HOME="$ROOT/data"
export XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
export TMUX_TMPDIR="$ROOT/tmux" THURBOX_SOCKET="thurbox-fleetlens-e2e"
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR THURBOX_UI_DIR FLEET_CONFIG TMUX
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$TMUX_TMPDIR"
SOCKET="lens-e2e"
cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  tmux -L "$THURBOX_SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "${KEEP:-}" ]; then echo "sandbox kept at $ROOT"; else rm -rf "$ROOT"; fi
}
trap cleanup EXIT INT TERM

capture() { tmux -L "$SOCKET" capture-pane -p -t lens; }
send() { tmux -L "$SOCKET" send-keys -t lens "$@"; }

# Wait until the frame matches a regex, or fail naming what never appeared.
wait_for() {
  local pattern="$1" what="$2" tries="${3:-50}"
  for _ in $(seq "$tries"); do
    if capture | grep -Eq -- "$pattern"; then return 0; fi
    sleep 0.2
  done
  die "$what"
}
wait_gone() {
  local pattern="$1" what="$2"
  for _ in $(seq 50); do
    if ! capture | grep -Eq -- "$pattern"; then return 0; fi
    sleep 0.2
  done
  die "$what"
}
row() { capture | grep -E -- "$1" >/dev/null || die "$2"; }
never() { if capture | grep -Eq -- "$1"; then die "$2"; fi; }

# ── a Fleet store with two Tasks in two phases ──────────────────────────────
log "seeding a fake-runtime Fleet store"
FLEET_DIR="$ROOT/fleet"
mkdir -p "$FLEET_DIR/work/alpha" "$FLEET_DIR/work/beta"
cat >"$FLEET_DIR/fleet.toml" <<'TOML'
version = 1
[data]
dir = "data"
[runtime]
kind = "fake"
dir = "fake-host"
TOML
cat >"$FLEET_DIR/tasks.json" <<JSON
[{"apiVersion":"fleet/v1alpha1","kind":"Task","metadata":{"name":"alpha"},
  "spec":{"harness":"sh","host":"local","brief":"Wait.","workspace":{"dir":"$FLEET_DIR/work/alpha"},"dispatch":false}},
 {"apiVersion":"fleet/v1alpha1","kind":"Task","metadata":{"name":"beta"},
  "spec":{"harness":"sh","host":"local","brief":"Go.","workspace":{"dir":"$FLEET_DIR/work/beta"},"dispatch":true}}]
JSON
fleet_() { "$FLEET" --config "$FLEET_DIR/fleet.toml" "$@"; }
fleet_ apply -f "$FLEET_DIR/tasks.json" >/dev/null
fleet_ reconcile --max-passes 10 >/dev/null
fleet_ list task | grep -Eq '^alpha +Pending' || die "fixture: alpha is not Pending"
fleet_ list task | grep -Eq '^beta +Briefed' || die "fixture: beta is not Briefed"

# ── a scratch interface with the working copy in it ─────────────────────────
log "installing the pane into a scratch interface"
# A session thurbox spawned carries THURBOX_CONFIG_DIR, which beats HOME: the
# guard refuses to write anywhere but the sandbox.
UI_DIR="$("$THURBOX_CLI" plugin dir | sed -n 's/^dir: //p')"
case "$UI_DIR" in "$ROOT"/*) ;; *) die "interface '$UI_DIR' is outside the sandbox" ;; esac
# `plugin new` materialises the stock interface; its starter is not wanted.
"$THURBOX_CLI" plugin new seed >/dev/null
rm -f "$UI_DIR"/plugins/*_seed.lua
[ -d "$UI_DIR/plugins" ] || die "no interface at '$UI_DIR'"
CONFIG="$(dirname "$UI_DIR")"
ln -sfn "$HERE" "$UI_DIR/thurbox-fleetlens"
cat >>"$UI_DIR/plugins.toml" <<TOML

[[plugin]]
src  = "git+file://$HERE"
file = "thurbox-fleetlens/plugins/88_fleet_lens.lua"
TOML

# `run` is absent until the file is trusted. There is no `plugin trust`, so this
# writes the record the Interface tab's `t` writes: the absolute path against an
# FNV-1a digest of the file (`kernel::bundled::digest`).
PANE="$UI_DIR/thurbox-fleetlens/plugins/88_fleet_lens.lua"
if [ -f "$PANE" ]; then
  python3 - "$PANE" "$CONFIG/ui.json" <<'PY'
import json, pathlib, sys
pane, out = sys.argv[1], pathlib.Path(sys.argv[2])
h = 0xCBF29CE484222325
for byte in pathlib.Path(pane).read_bytes():
    h = ((h ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
held = json.loads(out.read_text()) if out.exists() else {}
held.setdefault("trusted", {})[pane] = f"{h:016x}"
out.write_text(json.dumps(held, indent=2))
PY
fi

# The Lens reads FLEET_CONFIG through fleet's own resolution when its config
# setting is empty, and finds `fleet` on PATH.
export FLEET_CONFIG="$FLEET_DIR/fleet.toml"
export PATH="$(dirname "$FLEET"):$PATH"

# ── the scenario ────────────────────────────────────────────────────────────
log "launching thurbox (${COLS}x${ROWS})"
tmux -L "$SOCKET" new-session -d -s lens -x "$COLS" -y "$ROWS" \
  "env PATH='$PATH' FLEET_CONFIG='$FLEET_CONFIG' '$THURBOX'"
wait_for '.' "thurbox drew nothing" 100
sleep 1

log "F2 opens the Lens"
send F2
wait_for 'Fleet Lens' "frame has no 'Fleet Lens'"
wait_for 'Task +2' "the rail has no 'Task  2'"
wait_for 'alpha +Pending' "no row 'alpha … Pending'"
row 'beta +Briefed' "no row 'beta … Briefed'"

# One `apply` made both, a millisecond or none apart, so which is newest and
# drawn first depends on the machine. The test reads it rather than assuming.
log "j and k move the selection"
wait_for '^│ *│ Task/(alpha|beta) ' "no Task is selected"
first="$(capture | grep -Eo '^│ *│ Task/(alpha|beta) ' | grep -Eo 'alpha|beta')"
other=alpha
[ "$first" = alpha ] && other=beta
send j
wait_for "^│ *│ Task/$other " "j did not move the selection from $first to $other"
send k
wait_for "^│ *│ Task/$first " "k did not move the selection back to $first"

log "tab steps to the next kind; an empty kind says so"
send Tab
wait_for 'No TaskConfigs' "tab did not show the empty TaskConfig list"
for _ in 1 2 3 4 5; do send Tab; done
wait_for 'alpha +Pending' "tab did not wrap back to Task"

log "an unreadable record is Unknown, not empty"
cp "$FLEET_DIR/data/objects/Task/beta.json" "$ROOT/beta.json.bak"
printf 'not json' >"$FLEET_DIR/data/objects/Task/beta.json"
send R
wait_for 'Store unreadable' "no 'Store unreadable' banner"
row 'alpha +Pending' "row 'alpha' was dropped while the store was Unknown"
row 'beta +Briefed' "row 'beta' was dropped while the store was Unknown"
never 'No Tasks' "an Unknown store was drawn as 'No Tasks'"

log "a readable store clears the banner"
cp "$ROOT/beta.json.bak" "$FLEET_DIR/data/objects/Task/beta.json"
send R
wait_gone 'Store unreadable' "the banner stayed after the store was readable"
row 'alpha +Pending' "row 'alpha' is gone after recovery"

log "Esc closes it"
send Escape
wait_gone 'Fleet Lens' "Esc did not close the Lens"

printf '\033[1;32mPASS\033[0m lens_lists_tasks\n'
