# Agent rules

Fleet Lens is a thurbox interface pane (Lua) that reads Fleet through
`fleet … --json`. Read README.md first.

- For an issue, first write an end-to-end test that reproduces it, and see it
  fail for the intended reason. New behaviour starts with a failing test.
- Never give estimates of time, effort or completion.
- Keep it simple. Prefer a diagram to a long explanation.
- Check versions in registries and release pages; never guess one.

## Boundaries

- The pane reads Fleet only through the `fleet` CLI with `--json`. It never
  reads Fleet's store files, and never writes to Fleet.
- Unknown is not empty. A failed or unreadable answer keeps the last rows,
  drawn stale, under a banner. Only an exit-0 `[]` draws "No <kind>s".
- `lib/source.lua` and `lib/model.lua` are pure: no `run`, `thurbox`,
  `state` or `store`. Their behaviour is unit tested in `tests/unit.lua`.
- The plugin VM has no `os`, `io` or clock. `selene .` checks the sandbox
  against the vendored `thurbox.yml`, which must match CI's `THURBOX_TAG`.

## Tests

| Command | Proves |
| --- | --- |
| `selene . && stylua --check .` | The Lua is sound and stays in the sandbox |
| `tests/run.sh` | The pure modules, under Lua 5.4 |
| `tests/e2e/lens_lists_tasks.sh` | The pane in a real thurbox against a real fleet store |

The e2e runs under a throwaway HOME. Inside a thurbox session,
`THURBOX_CONFIG_DIR` points at the real config; the script unsets it and
refuses any interface outside its sandbox. Keep that guard.

## Publishing

Publishing uses the `publish` skill and `.publish.yaml`. Squash merge only,
with a conventional PR title.
