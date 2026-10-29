#!/usr/bin/env bash
#
# Record media/demo.gif: the Lens in a real thurbox, against a scratch Fleet
# store on the fake runtime, so no agent runs and nothing real is read.
#
# asciinema records the pty and agg rasterises the cast. Not VHS: it drives a
# headless browser and cannot send F2. tmux presses the keys, so what lands in
# the cast is the pane reacting to real keys.
#
# Needs: asciinema, agg, tmux, python3, and thurbox, thurbox-cli and fleet on
# PATH (or THURBOX_BIN / FLEET_BIN naming their directories).
#
#   demo/record.sh [output.gif]
#   SNAP=<dir> demo/record.sh     # also write the screen at each step
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO/media/demo.gif}"
COLS=112
ROWS=26
SNAP="${SNAP:-}"

bin() {
  local dir="$1" name="$2"
  if [ -n "$dir" ]; then echo "$dir/$name"; else command -v "$name"; fi
}
missing=
for tool in asciinema agg tmux python3; do
  command -v "$tool" >/dev/null || missing="$missing $tool"
done
THURBOX="$(bin "${THURBOX_BIN:-}" thurbox)" || missing="$missing thurbox"
THURBOX_CLI="$(bin "${THURBOX_BIN:-}" thurbox-cli)" || missing="$missing thurbox-cli"
FLEET="$(bin "${FLEET_BIN:-}" fleet)" || missing="$missing fleet"
[ -n "$missing" ] && { echo "missing:$missing" >&2; exit 2; }

# ── the sandbox: its own HOME, XDG roots and tmux sockets ───────────────────
# fleet names the store's absolute path when it cannot read it, so the take
# leaves that state out: the README shows it and the e2e proves it.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lens-demo.XXXXXX")"
export HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/config" XDG_DATA_HOME="$ROOT/data"
export XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
export TMUX_TMPDIR="$ROOT/tmux" THURBOX_SOCKET="lens-demo"
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR THURBOX_UI_DIR FLEET_CONFIG TMUX
unset THURBOX_SESSION THURBOX_SESSION_ID THURBOX_SOCKET_FOR
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$TMUX_TMPDIR"
TM=(tmux -L lens-demo-rec)
cleanup() {
  "${TM[@]}" kill-server >/dev/null 2>&1 || true
  tmux -L "$THURBOX_SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

# ── a Fleet store with a Task in each state worth seeing ────────────────────
FLEET_DIR="$ROOT/fleet"
mkdir -p "$FLEET_DIR"
cat >"$FLEET_DIR/fleet.toml" <<'TOML'
version = 1
[data]
dir = "data"
[runtime]
kind = "fake"
dir = "fake-host"
# A forge that is never called, so a declared change has somewhere to point.
[forge.hosts]
"git.example.invalid" = { kind = "github", cli = "false" }
TOML
task() {
  mkdir -p "$FLEET_DIR/work/$1"
  printf '{"apiVersion":"fleet/v1alpha1","kind":"Task","metadata":{"name":"%s"},"spec":{"harness":"sh","host":"local","brief":"%s","workspace":{"dir":"%s"},"dispatch":%s}}' \
    "$1" "$2" "$FLEET_DIR/work/$1" "$3"
}
printf '[%s,%s,%s,%s]' \
  "$(task fix-login-redirect 'Fix the login redirect.' true)" \
  "$(task bump-deps 'Bump the dependencies.' true)" \
  "$(task flaky-ci 'Find the flaky test.' true)" \
  "$(task write-docs 'Document the API.' false)" >"$FLEET_DIR/tasks.json"
fleet_() { "$FLEET" --config "$FLEET_DIR/fleet.toml" "$@" >/dev/null; }
fleet_ apply -f "$FLEET_DIR/tasks.json"
fleet_ reconcile --max-passes 10
fleet_ declare fix-login-redirect --change-request https://git.example.invalid/acme/shop/pull/42
fleet_ result fix-login-redirect --generation 1 --outcome shipped --summary "Opened the fix."
fleet_ result flaky-ci --generation 1 --outcome stuck --summary "Needs a maintainer."
# bump-deps's session vanishes before it answers: fleet raises NeedsAttention.
python3 - "$FLEET_DIR/fake-host/state.json" <<'PY'
import json, sys
path = sys.argv[1]
state = json.load(open(path))
for key, session in state["sessions"].items():
    if key.startswith("bump-deps."):
        session["gone"] = True
json.dump(state, open(path, "w"), indent=2)
PY
fleet_ reconcile --max-passes 10

# ── a scratch interface with the working copy in it ─────────────────────────
UI_DIR="$("$THURBOX_CLI" plugin dir | sed -n 's/^dir: //p')"
case "$UI_DIR" in "$ROOT"/*) ;; *) echo "interface '$UI_DIR' is outside the sandbox" >&2; exit 1 ;; esac
"$THURBOX_CLI" plugin new seed >/dev/null
rm -f "$UI_DIR"/plugins/*_seed.lua
CONFIG="$(dirname "$UI_DIR")"
ln -sfn "$REPO" "$UI_DIR/thurbox-fleet"
cat >>"$UI_DIR/plugins.toml" <<TOML

[[plugin]]
src  = "git+file://$REPO"
file = "thurbox-fleet/plugins/88_fleet_lens.lua"
TOML
# Trust the pane the way the Interface tab's `t` does (see the e2e).
python3 - "$UI_DIR/thurbox-fleet/plugins/88_fleet_lens.lua" "$CONFIG/ui.json" <<'PY'
import json, pathlib, sys
pane, out = sys.argv[1], pathlib.Path(sys.argv[2])
h = 0xCBF29CE484222325
for byte in pathlib.Path(pane).read_bytes():
    h = ((h ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
held = json.loads(out.read_text()) if out.exists() else {}
held.setdefault("trusted", {})[pane] = f"{h:016x}"
out.write_text(json.dumps(held, indent=2))
PY
# No release badge or update prompt mid-take.
printf '[features]\nversion_check = false\nauto_update = false\nnotifications = false\n' >"$CONFIG/settings.toml"
# The first launch asks about v2 and waits: answer it up front. The theme goes
# in the row the theme picker writes: `doom`, which the sibling plugins' demos
# are recorded in. THEME=<name> picks another.
"$THURBOX_CLI" session list --json >/dev/null
python3 - "$XDG_DATA_HOME/thurbox/thurbox.db" "${THEME:-doom}" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    for key, value in (("v2_interface_acknowledged", "1"), ("active_theme", sys.argv[2])):
        db.execute("INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)", (key, value))
PY

cat >"$ROOT/run.sh" <<RUN
#!/usr/bin/env bash
export TERM=xterm-256color COLORTERM=truecolor SHELL=/bin/sh PS1='\$ '
export PATH="$(dirname "$FLEET"):\$PATH" FLEET_CONFIG="$FLEET_DIR/fleet.toml"
cd "$HOME"
exec "$THURBOX"
RUN
chmod +x "$ROOT/run.sh"

# ── the take ────────────────────────────────────────────────────────────────
CAST="$ROOT/demo.cast"
"${TM[@]}" new-session -d -x "$COLS" -y "$ROWS" \
  "asciinema rec --overwrite --quiet --cols $COLS --rows $ROWS --command '$ROOT/run.sh' '$CAST'"

screen() { "${TM[@]}" capture-pane -p -t 0; }
k() { "${TM[@]}" send-keys -t 0 "$1"; sleep "${2:-0.8}"; }
snap() { [ -z "$SNAP" ] || screen >"$SNAP/$1.txt"; }
wait_for() {
  for _ in $(seq 100); do
    screen | grep -Eq -- "$1" && return 0
    sleep 0.2
  done
  echo "never saw '$1'" >&2
  screen >&2
  exit 1
}
[ -z "$SNAP" ] || mkdir -p "$SNAP"

wait_for '.'
sleep 2
snap 0-start

# Open it: Tasks first, the one that needs a person on top.
k F2 0.2
wait_for 'bump-deps'
sleep 2.5
snap 1-open
# Down the rows: the line under the table follows the selection.
k j 1.4
k j 1.4
k j 1.4
snap 2-moved
# Every kind fleet serves; the ChangeRequest the shipped Task declared.
k Tab 0.8
k Tab 0.8
k Tab 0.2
wait_for 'cr-'
sleep 2
snap 3-change-request
k Tab 0.5
k Tab 0.5
k Tab 0.2
wait_for 'bump-deps'
sleep 2
snap 4-back
k Escape 1.5
k C-q 2
for _ in $(seq 20); do [ -s "$CAST" ] && break; sleep 1; done

# A GIF loops, so cut the cast where thurbox leaves the alternate screen,
# rather than ending on a bare terminal.
python3 - "$CAST" <<'TRIM'
import json, sys
path = sys.argv[1]
lines = open(path).read().splitlines()
for i, line in enumerate(lines[1:], start=1):
    if "\x1b[?1049l" in json.loads(line)[2]:
        open(path, "w").write("\n".join(lines[:i]) + "\n")
        break
TRIM

# The GIF is published: refuse a cast carrying the user, the host or a path of
# this machine.
python3 - "$CAST" "$(id -un)" "$(uname -n)" "$REPO" "$ROOT" <<'PRIVATE'
import json, sys
path, *needles = sys.argv[1:]
text = "".join(json.loads(line)[2] for line in open(path).read().splitlines()[1:])
found = [n for n in needles if n and n in text]
if found:
    sys.exit(f"the recording contains {found!r}; not rendering it")
PRIVATE

mkdir -p "$(dirname "$OUT")"
agg --font-size 16 --idle-time-limit 3 --last-frame-duration 3 "$CAST" "$OUT"
ls -lh "$OUT"
