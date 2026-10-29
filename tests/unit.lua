-- The pure modules under a real Lua: every row of the error-state table, and
-- the rows the model builds. Run through tests/run.sh.

local source = require("thurbox-fleet.lib.source")
local model = require("thurbox-fleet.lib.model")

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

print(string.format("%d/%d passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)
