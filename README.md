# Fleet Lens

A [thurbox](https://github.com/Thurbeen/thurbox) pane that browses
[Fleet](https://github.com/Thurbeen/fleet) v2 resources: every kind Fleet
serves, Tasks first, in one keyboard-first float.

![Fleet Lens in thurbox's Doom theme: Alt+K opens it on four Tasks, the one that needs attention on top; j and k move; enter reads the shipped Task as YAML and j and G scroll it; tab steps through the kinds to the ChangeRequest it declared and shift+tab steps back; esc closes it](media/demo.gif)

The recording is a released thurbox (v2.76.2) and fleet (v2.3.0) with a
throwaway HOME and a scratch Fleet store on the fake runtime, so no agent runs
and nothing real is read. Reproduce it with `demo/record.sh`.

It reads Fleet only through `fleet … --json`, and writes nothing to Fleet.

## Install

```sh
thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-fleetlens
thurbox-cli plugin check
```

Then trust it, because it runs `fleet`: Settings (`Ctrl+,`) → `]` → select
`thurbox-fleetlens/plugins/88_fleet_lens.lua` → `t`. Until then, Alt+K opens the
pane and it tells you this.

`thurbox-cli plugin update` fetches a newer version. A changed file of an
installed pane needs trust again; that is thurbox's rule for a pane that runs
commands.

## Use

| Key | Does |
| --- | --- |
| `Alt+K` | Open or close the Lens (also in the palette as "Fleet: open Lens") |
| `j` / `k`, `↓` / `↑`, the wheel | Move, or scroll a resource |
| `PgDn` / `PgUp`, `g` / `G`, `Home` / `End` | Ten rows, or to the first / last |
| `tab` / `shift+tab`, `Ctrl+L` / `Ctrl+H` | Next / previous kind |
| `enter` | Read the selected resource as YAML |
| `R` | Ask fleet again now |
| `esc`, `q` | Back from a resource; close |

The mouse works too: click a kind or a row to select it, double-click a row
to read it, turn the wheel to move or to scroll a resource, click a hint in
the footer to do what it says, and click outside the Lens to close it.

The line under the table links what the selected resource names: a Task's
TaskConfig and the resources it declared (its ChangeRequests), a TaskConfig's
EnvProviders. Click one to go to it; clicked while reading a resource, it
reads the linked one.

To copy text, hold `Shift` and drag: in most terminals that is their own
selection. thurbox's drag-to-copy covers terminal panes only, not a plugin's
float.

A resource is the object fleet returned for the list, as YAML: the envelope
first, then every field by name. A line wider than the Lens wraps, and goes
on under where its value starts. It is read-only and follows each refresh.

Rows that need a person (a Task whose `NeedsAttention` is True) come first,
marked `!`. The line under the table gives the reason and message.

| Task column | From |
| --- | --- |
| PHASE | `status.phase` |
| COND | One glyph per condition: `●` True, `○` False, `?` Unknown |
| SESSION | `status.session.host`, and the session's live status in thurbox, or `gone` |
| GEN | Brief generation / spec generation; red when they differ |
| RESULT | `status.result.outcome` |
| CR | Declared ChangeRequests |
| AGE | Since creation |

Every other kind gets NAME, PHASE, COND, SYNC (`✓` when the status observed
the current generation, `±` when not) and AGE.

### When fleet cannot answer

The Lens never shows an unreadable store as an empty list. If `fleet` exits
4 ("could not tell"), the last rows stay on screen, greyed out, under a
`Store unreadable` banner with fleet's reason. "No Tasks" means fleet
answered with an empty list. Other failures get their own banner: fleet not
found, timeout, an answer too large for one run, an unreachable host.

## Settings

In Settings, under `fleetlens`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `machine` | `local` | Where `fleet` runs: `local`, or `host:<name>` for a host in thurbox's `hosts.toml` |
| `bin` | `fleet` | The fleet binary: a name on PATH, or an absolute path |
| `config` | empty | Passed as `--config`. Empty lets fleet resolve its own (`FLEET_CONFIG`, then the per-user config) |

## Limits of this version

- Read-only. There are no actions yet.
- Relations go one way: a ChangeRequest does not link back to its Task.
- No filter or attach yet.
- One `fleet list --json` per refresh. Past 256 KiB (about 45 Tasks today),
  the Lens says so instead of parsing a cut answer.
- POSIX hosts only: the run prints `date +%s` first, because the plugin VM
  has no clock.

## Develop

```sh
selene . && stylua --check .     # lint, against thurbox's plugin sandbox (thurbox.yml)
tests/run.sh                     # the pure modules, Lua 5.4
tests/e2e/lens_lists_tasks.sh    # real thurbox + real fleet in tmux, sandboxed HOME
demo/record.sh                   # re-record media/demo.gif
```

The end-to-end test needs `tmux`, `python3`, `thurbox`, `thurbox-cli` and
`fleet`. CI pins their versions in `.github/workflows/ci.yml`.

`demo/record.sh` builds the same kind of sandbox, seeds four Tasks (one whose
session vanished, so it needs attention; one shipped with a declared
ChangeRequest; one stuck; one waiting), and records the pane with asciinema,
driven by tmux so the keys are real ones, then renders it with agg. It also
needs `asciinema` and `agg`, takes `THURBOX_BIN` / `FLEET_BIN` like the e2e,
and refuses to render a cast that contains the user name, the host name, the
checkout's path or the sandbox's. The store's path shows in a "could not tell" banner, so the take
leaves that state out; the e2e covers it.

## License

MIT
