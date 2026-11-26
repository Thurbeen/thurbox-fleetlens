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

test("a list asks for JSON and keeps fleet's exit status past the trim", function()
  local cmd = source.list_command({ bin = "fleet", config = "" }, "ChangeRequest")
  eq(cmd:find("date +%s; out=$(fleet list changerequest --json)", 1, true), 1)
  eq(cmd:sub(-9), "; exit $s")
end)

-- A fake fleet: prints the pretty JSON in FAKE_JSON and exits FAKE_EXIT.
local FAKE = os.getenv("FAKE_FLEET")

local function list_through(json_text, exit)
  local cmd = source.list_command({ bin = FAKE, config = "" }, "Task")
  local pipe = assert(
    io.popen(
      string.format(
        "FAKE_EXIT=%d FAKE_JSON=%s sh -c %s",
        exit or 0,
        source.quote(json_text),
        source.quote(cmd)
      )
    )
  )
  local out = pipe:read("a")
  local _, _, status = pipe:close()
  return source.classify({ state = "done", status = status, stdout = out, stderr = "" }, "local"),
    out
end

local PRETTY = table.concat({
  "[",
  "  {",
  '    "kind": "Task",',
  '    "metadata": {',
  '      "labels": {',
  '        "note": "' .. string.rep("l", 300) .. '"',
  "      },",
  '      "name": "a"',
  "    },",
  '    "spec": {',
  '      "brief": "' .. string.rep("b", 300) .. '",',
  '      "configRef": {',
  '        "name": "defaults"',
  "      },",
  '      "workspace": [',
  '        "file:///w"',
  "      ]",
  "    },",
  '    "status": {',
  '      "agentState": "working",',
  '      "declared": [',
  "        {",
  '          "id": "q1",',
  '          "kind": "Question",',
  '          "text": "say \\"' .. string.rep("q", 300) .. '\\" now"',
  "        }",
  "      ],",
  '      "phase": "Briefed",',
  '      "receipts": {',
  '        "k": {',
  '          "at": 1',
  "        }",
  "      }",
  "    }",
  "  }",
  "]",
}, "\n")

test("a list keeps what the table reads and drops the rest", function()
  local c = list_through(PRETTY)
  eq(c.kind, "ok")
  local t = c.value[1]
  eq(t.metadata.name, "a")
  eq(t.spec.configRef.name, "defaults")
  eq(t.spec.workspace, nil, "spec.workspace")
  eq(t.status.agentState, "working")
  eq(t.status.phase, "Briefed")
  eq(t.status.receipts, nil, "status.receipts")
  eq(t.status.declared[1].id, "q1")
end)

test("a list drops long strings, escaped quotes and all", function()
  local t = list_through(PRETTY).value[1]
  eq(t.spec.brief, "…")
  eq(t.status.declared[1].text, "…")
  eq(t.metadata.labels.note, "…")
end)

test("a list keeps an empty answer and fleet's failure", function()
  eq(#list_through("[]").value, 0)
  local c = list_through("", 4)
  eq(c.kind, "error")
  eq(c.title, "Store unreadable")
end)

local function count_through(json_text, exit, kinds)
  local cmd = source.count_command({ bin = FAKE, config = "" }, kinds)
  local pipe = assert(
    io.popen(
      string.format(
        "FAKE_EXIT=%d FAKE_JSON=%s sh -c %s",
        exit or 0,
        source.quote(json_text),
        source.quote(cmd)
      )
    )
  )
  local out = pipe:read("a")
  local _, _, status = pipe:close()
  local got =
    source.classify({ state = "done", status = status, stdout = out, stderr = "" }, "local")
  return got.kind == "ok" and source.counts(got.value, kinds) or got
end

local TWO = '[\n  {\n    "a": [\n      {\n        "b": 1\n      }\n    ]\n  },\n  {}\n]'

test("one run counts every kind, top-level objects only", function()
  local counts = count_through(TWO, 0, { "Task", "TaskConfig" })
  eq(counts.Task, 2)
  eq(counts.TaskConfig, 2)
end)

test("an empty list counts zero", function()
  eq(count_through("[]", 0, { "Board" }).Board, 0)
end)

test("a kind fleet cannot list is not counted, never zero", function()
  local counts = count_through("", 4, { "Task", "Board" })
  eq(counts.Task, "?")
  eq(counts.Board, "?")
end)

test("counts of an unreadable answer are all unknown", function()
  eq(source.counts({ 1 }, { "Task", "Board" }).Board, "?")
  eq(source.counts("x", { "Task" }).Task, "?")
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

test("rows needing a person come first, then open work, then newest", function()
  local rows = model.rows("Task", {
    task("old", "Briefed", 1000),
    task("done", "Concluded", 9000),
    task("new", "Briefed", 5000),
    task("stuck", "Briefed", 2000, {
      conditions = {
        { type = "NeedsAttention", status = "True", reason = "DeliveryFailed", message = "m" },
      },
    }),
    task("asks", "Concluded", 500, { declared = { { kind = "Question", id = "q1" } } }),
  }, 10)
  local names = {}
  for i, row in ipairs(rows) do
    names[i] = row.name
  end
  eq(table.concat(names, ","), "stuck,asks,new,old,done")
  eq(rows[1].marker, "!")
  eq(rows[1].why, "NeedsAttention/DeliveryFailed: m")
end)

test("an open Question marks its Task until it is answered", function()
  local asks = task("t", "Briefed", 0, {
    declared = {
      { kind = "Question", id = "q1", text = "Ship it?" },
      { kind = "Question", id = "q2", text = "And docs?" },
    },
    answered = { q1 = { from = "cli/x" } },
  })
  local row = model.rows("Task", { asks }, 0)[1]
  eq(row.marker, "?")
  eq(row.why, "q2: And docs?")
  asks.status.answered.q2 = { from = "cli/x" }
  eq(model.rows("Task", { asks }, 0)[1].marker, nil)
end)

test("NeedsAttention outranks a Question on the marker", function()
  local row = model.rows("Task", {
    task("t", "Briefed", 0, {
      declared = { { kind = "Question", id = "q1", text = "?" } },
      conditions = { { type = "NeedsAttention", status = "True", reason = "Lost" } },
    }),
  }, 0)[1]
  eq(row.marker, "!")
end)

test("a Question whose text the list dropped says so", function()
  local row = model.rows("Task", {
    task("t", "Briefed", 0, { declared = { { kind = "Question", id = "q1", text = "…" } } }),
  }, 0)[1]
  eq(row.why, "q1 waits for an answer")
end)

test("task cells: agent, session, generation, result, changes", function()
  local rows = model.rows("Task", {
    task("t", "Concluded", 0, {
      agentState = "idle",
      sessionState = "Paused",
      session = { id = "s1", host = "local" },
      brief = { generation = 1 },
      result = { outcome = "shipped" },
      declared = { { kind = "ChangeRequest", url = "u" }, { kind = "Note" } },
    }),
  }, 90)
  local c = rows[1].cells
  eq(table.concat(model.columns("Task"), ","), "NAME,PHASE,AGENT,SESSION,GEN,RESULT,CR,AGE")
  eq(c[3], "idle")
  eq(c[4], "Paused")
  eq(c[5], "1/2")
  eq(rows[1].tones[5], "error", "a brief generation behind the spec")
  eq(c[6], "shipped")
  eq(c[7], "1")
  eq(c[8], "1m")
end)

test("a session on another place names it", function()
  local rows = model.rows("Task", {
    task("t", "Briefed", 0, {
      agentState = "attention",
      sessionState = "Running",
      session = { host = "exec/nixos" },
    }),
  }, 0)
  eq(rows[1].cells[3], "attention")
  eq(rows[1].tones[3], "warning")
  eq(rows[1].cells[4], "exec/nixos Running")
end)

test("a lost session is an error, none is a dash", function()
  local rows = model.rows("Task", {
    task("lost", "Briefed", 1, { sessionState = "Lost", session = { host = "local" } }),
    task("none", "Pending", 0),
  }, 0)
  eq(rows[1].cells[4], "Lost")
  eq(rows[1].tones[4], "error")
  eq(rows[2].cells[3], "-")
  eq(rows[2].cells[4], "-")
end)

test("a ChangeRequest names its change", function()
  local rows = model.rows("ChangeRequest", {
    { metadata = { name = "a", generation = 1 }, spec = { url = "https://github.com/o/r/pull/7" } },
    {
      metadata = { name = "b", generation = 1 },
      spec = { url = "https://gitlab.com/g/sub/p/-/merge_requests/12" },
    },
    { metadata = { name = "c", generation = 1 }, spec = { url = "https://x.test/change" } },
  }, 0)
  eq(table.concat(model.columns("ChangeRequest"), ","), "NAME,CHANGE,PHASE,COND,SYNC,AGE")
  local changes = {}
  for _, row in ipairs(rows) do
    changes[row.name] = row.cells[2]
  end
  eq(changes.a, "o/r#7")
  eq(changes.b, "g/sub/p!12")
  eq(changes.c, "https://x.test/change")
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

-- ── model.relations ─────────────────────────────────────────────────────────

local function related(kind, obj)
  local out = {}
  for _, r in ipairs(model.relations(kind, obj)) do
    out[#out + 1] = r.kind .. "/" .. r.name
  end
  return table.concat(out, ",")
end

test("relations: a Task's config, then what it declared", function()
  eq(
    related("Task", {
      spec = { configRef = { name = "defaults" } },
      status = {
        declared = {
          { kind = "ChangeRequest", name = "cr-1", url = "https://example.test/pull/1" },
          { kind = "ChangeRequest", name = "cr-2" },
        },
      },
    }),
    "TaskConfig/defaults,ChangeRequest/cr-1,ChangeRequest/cr-2"
  )
end)

test("relations: a TaskConfig's env providers", function()
  eq(
    related("TaskConfig", { spec = { envFrom = { { name = "gh" }, { name = "aws" } } } }),
    "EnvProvider/gh,EnvProvider/aws"
  )
end)

test("relations: none, and malformed references are skipped", function()
  eq(related("Task", { metadata = { name = "a" } }), "")
  eq(related("Task", { spec = { configRef = {} }, status = { declared = { { kind = 1 } } } }), "")
  eq(related("ChangeRequest", { spec = { url = "x" } }), "")
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
