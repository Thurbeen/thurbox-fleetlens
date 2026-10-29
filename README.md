# Fleet Lens

A [thurbox](https://github.com/Thurbeen/thurbox) pane that browses
[Fleet](https://github.com/Thurbeen/fleet) v2 resources: every kind Fleet
serves, Tasks first, in one keyboard-first float.

```text
╭ Fleet Lens ───────────────────────────────────────────────────────────────╮
│ local · fleet's default config  · fleet 2.3.0                             │
│ KINDS             Task 2  · attention first                               │
│▸ Task          2    NAME     PHASE    COND  SESSION     GEN  RESULT CR AGE│
│  TaskConfig         alpha    Pending  ○     -           -    -      -  2s │
│  EnvProvider        beta     Briefed  ●●●○  local gone  1/1  -      -  2s │
│  ChangeRequest                                                            │
│  Conversation                                                             │
│  Listener                                                                 │
│ Task/alpha                                                                │
│ j/k move · tab kind · R refresh · esc close                               │
╰───────────────────────────────────────────────────────────────────────────╯
```

It reads Fleet only through `fleet … --json`, and writes nothing to Fleet.

## Install

```sh
thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-fleet
thurbox-cli plugin check
```

Then trust it, because it runs `fleet`: Settings (`Ctrl+,`) → `]` → select
`thurbox-fleet/plugins/88_fleet_lens.lua` → `t`. Until then, F2 opens the
pane and it tells you this.

`thurbox-cli plugin update` fetches a newer version. A changed file of an
installed pane needs trust again; that is thurbox's rule for a pane that runs
commands.

## Use

| Key | Does |
| --- | --- |
| `F2` | Open or close the Lens (also in the palette as "Fleet: open Lens") |
| `j` / `k`, `↓` / `↑` | Move |
| `tab` | Next kind |
| `R` | Ask fleet again now |
| `esc`, `q` | Close |

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
- No describe view, relations, filter or attach yet.
- One `fleet list --json` per refresh. Past 256 KiB (about 45 Tasks today),
  the Lens says so instead of parsing a cut answer.
- POSIX hosts only: the run prints `date +%s` first, because the plugin VM
  has no clock.

## Develop

```sh
selene . && stylua --check .     # lint, against thurbox's plugin sandbox (thurbox.yml)
tests/run.sh                     # the pure modules, Lua 5.4
tests/e2e/lens_lists_tasks.sh    # real thurbox + real fleet in tmux, sandboxed HOME
```

The end-to-end test needs `tmux`, `python3`, `thurbox`, `thurbox-cli` and
`fleet`. CI pins their versions in `.github/workflows/ci.yml`.

## License

MIT
