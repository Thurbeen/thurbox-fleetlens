-- The pure modules under a real Lua: every row of the error-state table, and
-- the rows the model builds. Run through tests/run.sh.

local source = require("thurbox-fleetlens.lib.source")
local model = require("thurbox-fleetlens.lib.model")
local yaml = require("thurbox-fleetlens.lib.yaml")

local failures, count = 0, 0
local function test(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if not ok then
    failures = failures + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end
local function eq(got, want, what)
  if got ~= want then
    error(string.format("%s: got %s, want %s", what or "value", tostring(got), tostring(want)), 2)
  end
end

local function done(status, stdout, stderr, extra)
  local got = { state = "done", status = status, stdout = stdout or "", stderr = stderr or "" }
  for k, v in pairs(extra or {}) do
    got[k] = v
  end
  return got
end

-- ── source.command ──────────────────────────────────────────────────────────

test("command prints the clock first and execs fleet", function()
  eq(
    source.command({ bin = "fleet", config = "" }, { "list", "task", "--json" }),
    "date +%s; exec fleet list task --json"
  )
end)

test("command passes --config when set, quoted", function()
  eq(
    source.command({ bin = "/opt/my fleet", config = "/a b/c.toml" }, { "version", "--json" }),
    "date +%s; exec '/opt/my fleet' --config '/a b/c.toml' version --json"
  )
end)

test("quote escapes a single quote", function()
  eq(source.quote("it's"), "'it'\\''s'")
end)

-- ── source.classify: the error-state table ──────────────────────────────────

test("nothing yet is pending", function()
  eq(source.classify(nil, "local").kind, "pending")
  eq(source.classify({ state = "pending" }, "local").kind, "pending")
end)

test("exit 0 with a list is ok, with the clock", function()
  local c = source.classify(done(0, "1700000000\n[]\n"), "local")
  eq(c.kind, "ok")
  eq(#c.value, 0)
  eq(c.now, 1700000000)
end)

test("exit 4 is Store unreadable, never ok", function()
  local c = source.classify(
    done(4, "1700000000\n", "error: could not tell: corrupt x.json\nhint: …"),
    "local"
  )
  eq(c.kind, "error")
  eq(c.title, "Store unreadable")
  eq(c.detail, "could not tell: corrupt x.json")
  eq(c.unknown, true)
  eq(c.value, nil)
end)

test("exit 3 is Gone", function()
  eq(source.classify(done(3, "1\n", "error: not found: Task/x"), "local").gone, true)
end)

test("unknown kind is no longer served", function()
  eq(
    source.classify(done(1, "1\n", 'error: invalid: unknown kind "Issue"'), "local").unserved,
    true
  )
end)

test("exit 127 is fleet not found", function()
  eq(
    source.classify(done(127, "1\n", "sh: fleet: not found"), "host:box").title,
    "fleet not found on host:box"
  )
end)

test("truncated output is never parsed", function()
  local c = source.classify(done(0, "1\n[{", "", { truncated = true }), "local")
  eq(c.kind, "error")
  eq(c.title, "Answer over 256 KiB — not parsed")
end)

test("timeout is an error", function()
  eq(source.classify(done(nil, "", "", { timed_out = true, ok = false }), "local").kind, "error")
end)

test("a failed run names the machine", function()
  eq(
    source.classify({ state = "failed", error = "no host" }, "host:x").title,
    "Cannot run fleet on host:x"
  )
end)

test("unreadable JSON is an error", function()
  eq(source.classify(done(0, "1\n{nope"), "local").title, "Unreadable answer from fleet")
end)

-- ── model ───────────────────────────────────────────────────────────────────

local function task(name, phase, created, extra)
  local obj = {
    metadata = { name = name, generation = 2, creationTimestamp = created },
    status = { phase = phase, conditions = {} },
  }
  for k, v in pairs(extra or {}) do
    obj.status[k] = v
  end
  return obj
end

test("age", function()
  eq(model.age(5), "5s")
  eq(model.age(120), "2m")
  eq(model.age(7200), "2h")
  eq(model.age(172800), "2d")
  eq(model.age(nil), "-")
end)

test("glyphs leave NeedsAttention to the marker", function()
  eq(
    model.glyphs({
      { type = "HostReachable", status = "True" },
      { type = "NeedsAttention", status = "True" },
      { type = "Concluded", status = "False" },
      { type = "Briefed", status = "Unknown" },
    }),
    "●○?"
  )
end)

test("attention rows come first, then newest", function()
  local rows = model.rows("Task", {
    task("old", "Briefed", 1000),
    task("new", "Briefed", 5000),
    task("stuck", "Briefed", 2000, {
      conditions = {
        { type = "NeedsAttention", status = "True", reason = "DeliveryFailed", message = "m" },
      },
    }),
  }, 10, {})
  eq(rows[1].name, "stuck")
  eq(rows[1].why, "NeedsAttention/DeliveryFailed: m")
  eq(rows[2].name, "new")
  eq(rows[3].name, "old")
end)

test("task cells: session, generation, result, changes", function()
  local rows = model.rows("Task", {
    task("t", "Concluded", 0, {
      session = { id = "s1", host = "local" },
      brief = { generation = 1 },
      result = { outcome = "shipped" },
      declared = { { kind = "ChangeRequest", url = "u" }, { kind = "Note" } },
    }),
  }, 90, { s1 = "idle" })
  local c = rows[1].cells
  eq(table.concat(model.columns("Task"), ","), "NAME,PHASE,COND,SESSION,GEN,RESULT,CR,AGE")
  eq(c[4], "local idle")
  eq(c[5], "1/2")
  eq(rows[1].tones[5], "error", "a brief generation behind the spec")
  eq(c[6], "shipped")
  eq(c[7], "1")
  eq(c[8], "1m")
end)

test("a session thurbox no longer has is gone", function()
  local rows = model.rows(
    "Task",
    { task("t", "Briefed", 0, { session = { id = "x", host = "local" } }) },
    0,
    {}
  )
  eq(rows[1].cells[4], "local gone")
end)

test("generic kinds: sync from observedGeneration", function()
  local rows = model.rows("Issue", {
    {
      metadata = { name = "a", generation = 2 },
      status = { phase = "tasked", observedGeneration = 1 },
    },
  }, 0, {})
  eq(table.concat(model.columns("Issue"), ","), "NAME,PHASE,COND,SYNC,AGE")
  eq(rows[1].cells[4], "±")
end)

test("a deleting object is marked", function()
  local rows = model.rows(
    "ChangeRequest",
    { { metadata = { name = "cr", deletionTimestamp = 1 } } },
    0,
    {}
  )
  eq(rows[1].cells[1], "✕ cr")
end)

test("a row keeps the object it was built from", function()
  local obj = { metadata = { name = "a" } }
  eq(model.rows("Task", { obj }, 0, {})[1].object, obj)
end)

-- ── yaml.lines ──────────────────────────────────────────────────────────────

local function yaml_of(value)
  return table.concat(yaml.lines(value), "\n")
end

test("yaml: the envelope first, then the rest by name", function()
  eq(
    yaml_of({
      status = { phase = "Briefed" },
      zeta = 1,
      kind = "Task",
      apiVersion = "fleet/v1alpha1",
    }),
    "apiVersion: fleet/v1alpha1\nkind: Task\nstatus:\n  phase: Briefed\nzeta: 1"
  )
end)

test("yaml: only the top level puts the envelope first", function()
  eq(
    yaml_of({ spec = { status = "x", kind = "z", a = 1 } }),
    "spec:\n  a: 1\n  kind: z\n  status: x"
  )
end)

test("yaml: a list of maps nests under dashes", function()
  eq(
    yaml_of({ conditions = { { type = "Spawned", status = "True" }, { type = "Briefed" } } }),
    'conditions:\n  - status: "True"\n    type: Spawned\n  - type: Briefed'
  )
end)

test("yaml: scalars a reader would misread are quoted", function()
  eq(
    yaml_of({
      a = "",
      b = "true",
      c = "42",
      d = "x: y",
      e = " pad",
      f = "null",
      g = "- x",
      h = "#c",
    }),
    'a: ""\nb: "true"\nc: "42"\nd: "x: y"\ne: " pad"\nf: "null"\ng: "- x"\nh: "#c"'
  )
end)

test("yaml: a multi-line string is a block, a plain one is bare", function()
  eq(
    yaml_of({ brief = "line one\nline two", name = "fix-login" }),
    "brief: |-\n  line one\n  line two\nname: fix-login"
  )
end)

test("yaml: numbers, booleans and empties", function()
  eq(
    yaml_of({ at = 1793301314870, big = 1793301314870.0, half = 0.5, on = true, none = {} }),
    'at: 1793301314870\nbig: 1793301314870\nhalf: 0.5\nnone: {}\n"on": true'
  )
end)

test("yaml: a list of lists and of scalars", function()
  eq(yaml_of({ m = { { 1, 2 }, "x" } }), "m:\n  - - 1\n    - 2\n  - x")
end)

-- ── yaml.wrap ───────────────────────────────────────────────────────────────

local function wrapped(lines, width)
  local out = {}
  for _, l in ipairs(yaml.wrap(lines, width)) do
    out[#out + 1] = (l.first and "" or "~") .. l.text
  end
  return table.concat(out, "\n")
end

test("wrap: a short line is left alone", function()
  eq(wrapped({ "kind: Task" }, 20), "kind: Task")
end)

test("wrap: a long value breaks at spaces and hangs under itself", function()
  eq(
    wrapped({ "  brief: one two three four five six" }, 20),
    "  brief: one two\n~         three four\n~         five six"
  )
end)

test("wrap: a list item hangs after its dash", function()
  eq(wrapped({ "  - aaa bbb ccc ddd" }, 12), "  - aaa bbb\n~    ccc ddd")
end)

test("wrap: a word wider than the room is cut, never lost", function()
  eq(wrapped({ "k: abcdefghijkl" }, 8), "k: abcde\n~   fghij\n~   kl")
end)

test("wrap: too deep a hang falls back to the line's own indent", function()
  eq(wrapped({ "  some_long_key: a b c d" }, 20), "  some_long_key: a b\n~    c d")
end)

print(string.format("%d/%d passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)
