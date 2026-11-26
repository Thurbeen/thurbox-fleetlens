#!/usr/bin/env bash
#
# Acceptance: Fleet Lens lists Tasks from a real Fleet store, the mouse drives
# it, and an unreadable store is never drawn as an empty list.
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

# Press the left button on the first cell of the first match of a regex, the
# way a terminal reports it (SGR 1006). `click RE 2` is a double-click: both
# presses land inside the kernel's 400 ms.
click() {
  local at x y events=""
  at="$(capture | python3 -c '
import re, sys
for y, line in enumerate(sys.stdin.read().split("\n"), start=1):
    m = re.search(sys.argv[1], line)
    if m:
        print(m.start() + 1, y)
        break
' "$1")"
  [ -n "$at" ] || die "nothing on screen matches '$1' to click"
  read -r x y <<<"$at"
  for _ in $(seq "${2:-1}"); do events="$events"$'\e'"[<0;$x;${y}M"$'\e'"[<0;$x;${y}m"; done
  tmux -L "$SOCKET" send-keys -t lens -l "$events"
}
# One wheel notch down (65) or up (64) at the first match of a regex.
wheel() {
  local at x y
  at="$(capture | python3 -c '
import re, sys
for y, line in enumerate(sys.stdin.read().split("\n"), start=1):
    m = re.search(sys.argv[1], line)
    if m:
        print(m.start() + 1, y)
        break
' "$1")"
  [ -n "$at" ] || die "nothing on screen matches '$1' to scroll over"
  read -r x y <<<"$at"
  tmux -L "$SOCKET" send-keys -t lens -l $'\e'"[<$2;$x;${y}M"
}

# ── a Fleet store with two Tasks in two phases, one using a TaskConfig ──────
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
[{"apiVersion":"fleet/v1alpha1","kind":"TaskConfig","metadata":{"name":"defaults"},
  "spec":{"harness":"sh"}},
 {"apiVersion":"fleet/v1alpha1","kind":"Task","metadata":{"name":"alpha"},
  "spec":{"harness":"sh","configRef":{"name":"defaults"},"host":"local","brief":"Wait for the release branch to be cut, then check every service in the monorepo still builds against it, list the ones that do not, and open one issue per failing service with the build log attached so the owners can pick them up tomorrow morning before standup end-of-brief.","workspace":["file://$FLEET_DIR/work/alpha"],"dispatch":false}},
 {"apiVersion":"fleet/v1alpha1","kind":"Task","metadata":{"name":"beta"},
  "spec":{"harness":"sh","host":"local","brief":"Go.","workspace":["file://$FLEET_DIR/work/beta"],"dispatch":true}}]
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
UI_DIR="$("$THURBOX_CLI" mod dir | sed -n 's/^dir: //p')"
case "$UI_DIR" in "$ROOT"/*) ;; *) die "interface '$UI_DIR' is outside the sandbox" ;; esac
# `mod new` materialises the stock interface; its starter is not wanted.
"$THURBOX_CLI" mod new seed >/dev/null
rm -f "$UI_DIR"/mods/*_seed.lua
[ -d "$UI_DIR/mods" ] || die "no interface at '$UI_DIR'"
CONFIG="$(dirname "$UI_DIR")"
ln -sfn "$HERE" "$UI_DIR/thurbox-fleetlens"
cat >>"$UI_DIR/mods.toml" <<TOML

[[mod]]
src  = "git+file://$HERE"
file = "thurbox-fleetlens/plugins/88_fleet_lens.lua"
TOML

# `run` is absent until the file is trusted. There is no `mod trust`, so this
# writes the record the Interface tab's `t` writes into mod-state.json: the
# absolute path against an FNV-1a digest of the file (`kernel::bundled::digest`).
# The file is not synced, so no lock covers it and a bare digest is its grant.
PANE="$UI_DIR/thurbox-fleetlens/plugins/88_fleet_lens.lua"
if [ -f "$PANE" ]; then
  python3 - "$PANE" "$CONFIG/mod-state.json" <<'PY'
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

# The Lens finds the store through its `config` setting and `fleet` on PATH.
# thurbox itself gets no FLEET_CONFIG: from 3.x it would run its own engine on
# the store, which holds the lease this test's `reconcile` needs.
python3 - "$CONFIG/ui.json" "$FLEET_DIR/fleet.toml" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
held = json.loads(out.read_text()) if out.exists() else {}
held.setdefault("settings", {})["fleetlens.config"] = sys.argv[2]
out.write_text(json.dumps(held, indent=2))
PY
export PATH="$(dirname "$FLEET"):$PATH"

# ── the scenario ────────────────────────────────────────────────────────────
log "launching thurbox (${COLS}x${ROWS})"
tmux -L "$SOCKET" new-session -d -s lens -x "$COLS" -y "$ROWS" \
  "env PATH='$PATH' '$THURBOX'"
wait_for '.' "thurbox drew nothing" 100
sleep 1

log "alt+k opens the Lens, and F2 is left to other panes"
send F2
sleep 1
never 'Fleet Lens' "F2 opened the Lens; it belongs to the info panel"
send M-k
wait_for 'Fleet Lens' "frame has no 'Fleet Lens'"
wait_for 'Task +2' "the rail has no 'Task  2'"
wait_for 'alpha +Pending' "no row 'alpha … Pending'"
row 'beta +Briefed' "no row 'beta … Briefed'"

log "every kind on the rail is counted before it is selected"
wait_for 'TaskConfig +1 ' "the rail does not count TaskConfig until it is selected"
wait_for 'EnvProvider +0 ' "the rail does not count EnvProvider until it is selected"

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

# The rail is the kinds fleet serves, in its order; the test reads them rather
# than assuming a release's list.
mapfile -t KINDS < <(fleet_ version --json | python3 -c 'import json, sys; print("\n".join(json.load(sys.stdin)["kinds"]))')
LAST="${KINDS[${#KINDS[@]} - 1]}"
BEFORE_LAST="${KINDS[${#KINDS[@]} - 2]}"

log "tab steps to the next kind"
send Tab
wait_for 'defaults +' "tab did not show the TaskConfig list"
for _ in $(seq $((${#KINDS[@]} - 1))); do send Tab; done
wait_for 'alpha +Pending' "tab did not wrap back to Task"

log "shift+tab steps back, wrapping to the last kind"
send BTab
wait_for "No ${LAST}s" "shift+tab did not wrap from Task to $LAST"
send BTab
wait_for "No ${BEFORE_LAST}s" "shift+tab did not step back to $BEFORE_LAST"
send Tab
send Tab
wait_for 'alpha +Pending' "tab did not come back to Task"

log "a digit jumps to that kind, and h and l step through them"
send 2
wait_for '▸ TaskConfig' "2 did not jump to the second kind"
wait_for 'Fleet Lens · TaskConfig' "the title does not name the kind shown"
send l
wait_for '▸ EnvProvider' "l did not step to the next kind"
send h
send h
wait_for 'alpha +Pending' "h did not step back to Task"

log "the mouse: a kind, a row, the wheel, a footer hint"
click 'TaskConfig'
wait_for '▸ TaskConfig' "a click on TaskConfig did not select it"
sleep 0.5
click 'Task +[0-9]'
wait_for '▸ Task ' "a click on Task did not select it"
wait_for 'alpha +Pending' "a click on Task did not list the Tasks"
click "$other +[A-Z]"
wait_for "^│ *│ Task/$other " "a click on row $other did not select it"
wheel "$other +[A-Z]" 64
wheel "$other +[A-Z]" 65
wheel "$other +[A-Z]" 64
wait_for "^│ *│ Task/$first " "the wheel did not move the selection to $first"
click 'tab kind'
wait_for 'defaults +' "a click on the 'tab kind' hint did not step the kind"
send BTab
wait_for 'alpha +Pending' "shift+tab did not come back to Task"

log "a resource's content: Enter or a double-click shows it as YAML"
send Enter
wait_for '│ +apiVersion: fleet/v1alpha1' "Enter did not show $first as YAML"
row "│ +name: $first\b" "the YAML is not $first's"
row '│ +kind: Task' "the YAML has no 'kind: Task'"
never 'NAME +PHASE' "the table is still drawn under the YAML"
send Escape
wait_for 'NAME +PHASE' "Esc did not go back from the YAML to the table"
wait_for 'Fleet Lens' "Esc in the YAML closed the Lens"
# beta was briefed, so its status runs past one screen.
click 'beta +Briefed' 2
wait_for '│ +name: beta\b' "a double-click on beta did not show its YAML"
send End
wait_gone '│ +apiVersion: ' "End did not scroll the YAML"
send Home
wait_for '│ +apiVersion: ' "Home did not scroll back to the top"
send Escape
wait_for 'NAME +PHASE' "Esc did not leave the double-clicked YAML"

log "the wheel scrolls a resource"
click 'beta +Briefed' 2
wait_for '│ +name: beta\b' "a double-click on beta did not show its YAML"
wheel '│ +kind: Task' 65
wait_gone '│ +apiVersion: ' "the wheel did not scroll the YAML down"
wheel '│ +kind: Task' 64
wait_for '│ +apiVersion: ' "the wheel did not scroll the YAML back up"
send Escape
wait_for 'NAME +PHASE' "Esc did not leave beta's YAML"

log "a relation is a link: a click goes to the resource it names"
click 'alpha +Pending'
wait_for '^│ *│ Task/alpha .*TaskConfig/defaults' "alpha's trail does not link its TaskConfig"
click 'TaskConfig/defaults'
wait_for '▸ TaskConfig' "a click on alpha's TaskConfig link did not go to TaskConfig"
wait_for '^│ *│ TaskConfig/defaults ' "the linked TaskConfig 'defaults' is not selected"
send BTab
wait_for 'alpha +Pending' "shift+tab did not come back to Task"
click 'alpha +Pending' 2
wait_for '│ +name: alpha\b' "a double-click on alpha did not show its YAML"
click 'TaskConfig/defaults'
wait_for '│ +kind: TaskConfig' "a link clicked in alpha's YAML did not show the TaskConfig"
row '│ +name: defaults\b' "the YAML a link showed is not 'defaults'"
send Escape
wait_for 'NAME +PHASE' "Esc did not leave the linked YAML"
send BTab
wait_for 'alpha +Pending' "shift+tab did not come back to Task"

log "a line wider than the Lens wraps instead of being cut"
click 'alpha +Pending' 2
wait_for '│ +brief: Wait for the release branch' "alpha's YAML has no brief"
wait_for 'end-of-brief\. *│' "the end of a long brief was cut, not wrapped onto another line"
# The continuation hangs under the value, not at the left edge.
row '│ {9,}[a-z]' "a wrapped line does not hang under its value"
send Escape
wait_for 'NAME +PHASE' "Esc did not leave alpha's YAML"

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

log "a Task needing attention still links what it names"
LONG=release-branch-build-check-defaults-for-every-service-in-the-monorepo-x
cat >"$FLEET_DIR/gamma.json" <<JSON
[{"apiVersion":"fleet/v1alpha1","kind":"TaskConfig","metadata":{"name":"$LONG"},
  "spec":{"harness":"sh"}},
 {"apiVersion":"fleet/v1alpha1","kind":"Task","metadata":{"name":"gamma"},
  "spec":{"harness":"sh","configRef":{"name":"$LONG"},"host":"local","brief":"Go.","workspace":["file://$FLEET_DIR/work/beta"],"dispatch":true}}]
JSON
fleet_ apply -f "$FLEET_DIR/gamma.json" >/dev/null
fleet_ reconcile --max-passes 10 >/dev/null
# gamma's session vanishes before it answers: fleet raises NeedsAttention.
python3 - "$FLEET_DIR/fake-host/state.json" <<'PY'
import json, sys
path = sys.argv[1]
state = json.load(open(path))
for key, session in state["sessions"].items():
    if key.startswith("gamma."):
        session["gone"] = True
json.dump(state, open(path, "w"))
PY
fleet_ reconcile --max-passes 10 >/dev/null
send R
wait_for '! gamma +' "gamma is not drawn as needing attention"
wait_for 'TaskConfig +2 ' "the rail's TaskConfig count did not follow a new TaskConfig"
click 'gamma +'
wait_for '^│ *│ ! NeedsAttention/' "gamma's trail does not say why it needs attention"
# The reason and the link are wider than the Lens: the reason gives way.
wait_for "TaskConfig/$LONG *│" "a long reason pushed gamma's TaskConfig link off the Lens"
click "TaskConfig/$LONG"
wait_for "^│ *│ TaskConfig/$LONG " "a click on gamma's TaskConfig link did not go to it"
send BTab
wait_for 'alpha +Pending' "shift+tab did not come back to Task"

log "a Task shows what its agent is doing"
wait_for 'NAME +PHASE +AGENT' "the Task table has no AGENT column"
row 'beta +Briefed +working' "beta's agent is not drawn as working"

log "a Question the worker asks puts its Task first, until it is answered"
click 'alpha +Pending'
wait_for '^│ *│ Task/alpha ' "a click on alpha did not select it"
fleet_ declare beta --json '{"kind":"Question","id":"q1","text":"Ship it?"}' >/dev/null
send R
wait_for '\? beta +Briefed' "beta's open Question does not mark its row"
row '^│ *│ Task/alpha ' "the selection left alpha when beta moved above it"
click 'beta +Briefed'
wait_for '^│ *│ \? q1: Ship it\?' "beta's trail does not show the Question it asks"
fleet_ send beta --answers q1 yes >/dev/null
send R
wait_gone '\? beta +Briefed' "an answered Question still marks beta"

log "a Task list over one run's 256 KiB is still listed"
python3 - "$FLEET_DIR" >"$FLEET_DIR/big.json" <<'PY'
import json, sys
work = sys.argv[1] + "/work/beta"
print(json.dumps([
    {"apiVersion": "fleet/v1alpha1", "kind": "Task", "metadata": {"name": f"big-{i}"},
     "spec": {"harness": "sh", "host": "local", "brief": f"brief-{i} " + "x" * 100000,
              "workspace": ["file://" + work], "dispatch": False}}
    for i in (1, 2, 3)
]))
PY
fleet_ apply -f "$FLEET_DIR/big.json" >/dev/null
fleet_ reconcile --max-passes 10 >/dev/null
[ "$(fleet_ list task --json | wc -c)" -gt 262144 ] || die "fixture: the Task list fits one run"
send R
wait_for 'big-1 +Pending' "a Task list over 256 KiB was not listed"
row 'beta +Briefed' "beta is missing from the long list"
never '256 KiB' "the Lens refused a long Task list"

log "a resource is read whole, not as the list trimmed it"
click 'big-2 +Pending' 2
wait_for 'Task/big-2 +· yaml +1–[0-9]+ of [0-9]{3,}' "big-2's YAML does not carry its whole brief"
send Escape
wait_for 'NAME +PHASE' "Esc did not leave big-2's YAML"

log "a resource deleted while read, then made again, reads again"
click 'big-3 +Pending' 2
wait_for 'Task/big-3 +· yaml' "a double-click on big-3 did not show its YAML"
fleet_ delete task big-3 >/dev/null
fleet_ reconcile --max-passes 10 >/dev/null
send R
wait_for 'NAME +PHASE' "deleting big-3 did not take the Lens back to the table"
wait_gone 'big-3 +' "big-3 is still listed after its deletion"
python3 - "$FLEET_DIR/big.json" >"$FLEET_DIR/big-3.json" <<'PY'
import json, sys
print(json.dumps([t for t in json.load(open(sys.argv[1])) if t["metadata"]["name"] == "big-3"]))
PY
fleet_ apply -f "$FLEET_DIR/big-3.json" >/dev/null
fleet_ reconcile --max-passes 10 >/dev/null
send R
wait_for 'big-3 +Pending' "big-3 is not listed again"
click 'big-3 +Pending' 2
wait_for 'Task/big-3 +· yaml' "a double-click on the new big-3 did not show its YAML"
send Escape
wait_for 'NAME +PHASE' "Esc did not leave big-3's YAML"

log "Esc closes it"
send Escape
wait_gone 'Fleet Lens' "Esc did not close the Lens"

log "alt+k closes it again, and a click outside closes it too"
send M-k
wait_for 'alpha +Pending' "alt+k did not open the Lens again"
send M-k
wait_gone 'Fleet Lens' "alt+k did not close the Lens"
send M-k
wait_for 'alpha +Pending' "alt+k did not reopen the Lens"
click 'Multi-Session'
wait_gone 'Fleet Lens' "a click outside the Lens did not close it"

printf '\033[1;32mPASS\033[0m lens_lists_tasks\n'
