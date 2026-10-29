-- Fleet Lens: every Fleet v2 resource kind, browsed from one float.
--
-- F2 opens it. It reads Fleet only through `fleet … --json`, run with the `run`
-- capability on the machine the `machine` setting names, and draws what came
-- back. It writes nothing to Fleet.
--
-- NOT PURE, deliberately. A run answer goes stale by its TTL, and a TTL expiring
-- is not something the kernel publishes, so a pure Lens would never ask again.
-- Closed, render returns nil before doing anything.
--
-- UNKNOWN IS NOT EMPTY. An answer that is not a readable list keeps the last
-- rows on screen, drawn stale, under a banner saying why. Only an exit-0 `[]`
-- draws "No Tasks".

local source = require("thurbox-fleetlens.lib.source")
local model = require("thurbox-fleetlens.lib.model")
local view = require("thurbox-fleetlens.lib.view")
local settings = require("lib.settings")

local NAME = "fleetlens"
local LIST_TTL = 3
local SLOW_TTL = 300
local TIMEOUT = 20

-- Per run key: the `thurbox.runs` entry last classified, what it said, and the
-- last answer that was ok. Upvalues, not `state`: they are caches of published
-- data, rebuilt from `thurbox.runs` after a reload.
local seen, said, good = {}, {}, {}
-- The rail as last drawn, which `tab` steps through.
local drawn_kinds = {}
-- The selected row per kind, and the run keys `R` asked to refresh. Upvalues:
-- `state` keeps what is assigned to it, not what is changed inside a table it
-- holds, so a nested `state.sel[kind] = n` would be lost.
local selection, refreshing = {}, {}
-- How many rows the last render drew, which bounds `j`.
local drawn_rows = 0

local function setting(id, fallback)
  return settings.get(NAME, id, fallback)
end

local function where()
  return {
    machine = setting("machine", "local"),
    bin = setting("bin", "fleet"),
    config = setting("config", ""),
  }
end

--- Whether this frame asks. Every other frame, not every frame: thurbox 2.76
--- folds finished runs in only on a loop pass with no new asks
--- (`serve_runs`: `!asked.is_empty() || runs.poll(..)`), so a pane asking on
--- every paint holds its own answers in flight forever. A frame with no ask
--- lets them land.
local asking = false

--- Ask for `key` and return its classification.
local function ask(key, args, ttl, w)
  if asking then
    local refresh = refreshing[key]
    refreshing[key] = nil
    run(key, source.command(w, args), {
      machine = w.machine,
      ttl = ttl,
      timeout = TIMEOUT,
      refresh = refresh or nil,
    })
  end
  local got = (thurbox.runs or {})[key]
  if not rawequal(got, seen[key]) then
    seen[key] = got
    said[key] = source.classify(got, w.machine)
    if said[key].kind == "ok" then
      good[key] = said[key]
    end
  end
  return said[key] or { kind = "pending" }, good[key]
end

--- Built-ins from `version --json`, then each registered plugin's kinds.
local function kinds(w)
  local out, have = {}, {}
  local function add(kind)
    if type(kind) == "string" and not have[kind] then
      have[kind] = true
      out[#out + 1] = { kind = kind }
    end
  end
  local _, version = ask("fl:version", { "version", "--json" }, SLOW_TTL, w)
  for _, kind in ipairs(version and version.value.kinds or {}) do
    add(kind)
  end
  local _, plugins = ask("fl:plugins", { "list", "plugins", "--json" }, SLOW_TTL, w)
  for _, plugin in ipairs(plugins and plugins.value or {}) do
    for _, kind in ipairs(plugin.kinds or {}) do
      add(kind)
    end
  end
  if #out == 0 then
    add("Task")
  end
  return out, version and version.value.version or nil
end

local function sessions()
  local by_id = {}
  for _, s in ipairs((thurbox and thurbox.sessions) or {}) do
    by_id[s.id] = s.status
  end
  return by_id
end

local function untrusted(ctx)
  return view.render(ctx, {
    where = "not trusted",
    kinds = {},
    kind = "Task",
    columns = {},
    rows = {},
    selected = 1,
    note = "  Fleet Lens runs `fleet` and needs your trust first.\n\n"
      .. "  Settings (Ctrl+,) → ] → select 88_fleet_lens.lua → t",
  })
end

local function render(ctx)
  if not state.open then
    return nil
  end
  if not run then
    return untrusted(ctx)
  end
  asking = (ctx.frame or 0) % 2 == 0
  local w = where()
  local list, version = kinds(w)
  drawn_kinds = list
  local kind = state.kind or "Task"
  local now_answer, last = ask("fl:list:" .. kind, { "list", kind:lower(), "--json" }, LIST_TTL, w)
  local rows = last and model.rows(kind, last.value, last.now, sessions()) or {}
  for _, k in ipairs(list) do
    local held = good["fl:list:" .. k.kind]
    k.count = held and #held.value or nil
  end
  local selected = math.max(1, math.min(selection[kind] or 1, #rows))
  local banner = now_answer.kind == "error" and now_answer or nil
  drawn_rows = #rows
  return view.render(ctx, {
    where = w.machine .. " · " .. (w.config ~= "" and w.config or "fleet's default config"),
    version = version,
    kinds = list,
    kind = kind,
    columns = model.columns(kind),
    rows = rows,
    selected = selected,
    loading = now_answer.kind == "pending" and not last,
    stale = banner ~= nil and last ~= nil,
    banner = banner,
  })
end

local function move(delta)
  local kind = state.kind or "Task"
  selection[kind] = math.max(1, math.min((selection[kind] or 1) + delta, math.max(drawn_rows, 1)))
end

--- The next kind in the rail, wrapping.
local function next_kind()
  local current = state.kind or "Task"
  for i, k in ipairs(drawn_kinds) do
    if k.kind == current then
      state.kind = drawn_kinds[i % #drawn_kinds + 1].kind
      return
    end
  end
end

local function refresh()
  refreshing["fl:list:" .. (state.kind or "Task")] = true
  refreshing["fl:version"] = true
  refreshing["fl:plugins"] = true
end

local ACTIONS = {
  ["fleetlens.down"] = function()
    move(1)
  end,
  ["fleetlens.up"] = function()
    move(-1)
  end,
  ["fleetlens.kind"] = next_kind,
  ["fleetlens.refresh"] = refresh,
  ["fleetlens.close"] = function()
    state.open = false
  end,
}

local KEYS = {
  j = "fleetlens.down",
  down = "fleetlens.down",
  k = "fleetlens.up",
  up = "fleetlens.up",
  tab = "fleetlens.kind",
  R = "fleetlens.refresh",
  esc = "fleetlens.close",
  q = "fleetlens.close",
}

return {
  name = NAME,
  floats = true,
  order = 88,
  focusable = false,
  requires_api = 2,
  capabilities = { "run" },
  settings = {
    {
      id = "machine",
      desc = "Where fleet runs: local, or host:<name> from hosts.toml",
      default = "local",
    },
    {
      id = "bin",
      desc = "The fleet binary, a name on PATH or an absolute path",
      default = "fleet",
    },
    { id = "config", desc = "Fleet config file; empty uses fleet's own default", default = "" },
  },
  keys = {
    {
      key = "f2",
      action = "fleetlens.toggle",
      desc = "open or close Fleet Lens",
      scope = "global",
      group = "Fleet",
    },
  },
  commands = { { action = "fleetlens.toggle", desc = "Fleet: open Lens" } },
  render = render,
  on_action = function(action)
    if action == "fleetlens.toggle" then
      state.open = not state.open
      return true
    end
    local fn = state.open and ACTIONS[action]
    if fn then
      fn()
      return true
    end
    return false
  end,
  on_key = function(key)
    if not state.open then
      return false
    end
    local name = key.char or key.key
    if key.shift and name == "r" then
      name = "R"
    end
    local action = KEYS[name] or KEYS[key.key]
    if action then
      ACTIONS[action]()
    end
    -- A float takes every key; swallow the rest rather than let them type.
    return true
  end,
}
