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
local yaml = require("thurbox-fleetlens.lib.yaml")
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
-- The names of the rows the last render drew, in order, which bound `j` and
-- turn a clicked name into a position.
local drawn_names = {}
-- The resource being read, by name, and how far it is scrolled; nil while the
-- table is shown. Its object is looked up again on every render, so a refresh
-- lands in what is being read.
local detail = nil
-- How far the last resource drawn could scroll, which bounds `j`.
local detail_max = 0

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
  drawn_names = {}
  for i, row in ipairs(rows) do
    drawn_names[i] = row.name
  end
  local shown = nil
  if detail then
    for i, row in ipairs(rows) do
      if row.name == detail.name then
        selected = i
        local lines = yaml.lines(row.object)
        detail_max = math.max(0, #lines - view.room(ctx))
        detail.offset = math.min(detail.offset, detail_max)
        shown = { title = kind .. "/" .. row.name, lines = lines, offset = detail.offset }
      end
    end
    -- Gone from the list (deleted, or the kind changed under it): back to the
    -- table, so the keys move rows again.
    if not shown then
      detail = nil
    end
  end
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
    detail = shown,
  })
end

--- Move the selection, or scroll the resource being read.
local function move(delta)
  if detail then
    detail.offset = math.max(0, math.min(detail.offset + delta, detail_max))
    return
  end
  local kind = state.kind or "Task"
  selection[kind] = math.max(1, math.min((selection[kind] or 1) + delta, math.max(#drawn_names, 1)))
end

--- Step `step` kinds along the rail, wrapping either way.
local function step_kind(step)
  local current = state.kind or "Task"
  for i, k in ipairs(drawn_kinds) do
    if k.kind == current then
      state.kind = drawn_kinds[(i - 1 + step) % #drawn_kinds + 1].kind
      detail = nil
      return
    end
  end
end

--- Read the selected row's resource, from the list already held.
local function open_detail()
  local kind = state.kind or "Task"
  local held = good["fl:list:" .. kind]
  if not held then
    return
  end
  local rows = model.rows(kind, held.value, held.now, {})
  local row = rows[math.max(1, math.min(selection[kind] or 1, #rows))]
  if row then
    detail = { name = row.name, offset = 0 }
  end
end

--- Select a kind by name, leaving any resource being read.
local function select_kind(kind)
  if type(kind) == "string" and kind ~= (state.kind or "Task") then
    state.kind = kind
    detail = nil
  end
end

--- Select a row of the current kind by its resource's name.
local function select_name(name)
  for i, n in ipairs(drawn_names) do
    if n == name then
      selection[state.kind or "Task"] = i
      return true
    end
  end
  return false
end

local function close()
  state.open = false
  detail = nil
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
  ["fleetlens.page_down"] = function()
    move(10)
  end,
  ["fleetlens.page_up"] = function()
    move(-10)
  end,
  ["fleetlens.first"] = function()
    move(-math.huge)
  end,
  ["fleetlens.last"] = function()
    move(math.huge)
  end,
  ["fleetlens.kind"] = function()
    step_kind(1)
  end,
  ["fleetlens.kind_back"] = function()
    step_kind(-1)
  end,
  ["fleetlens.view"] = function(args)
    if not args.name or select_name(args.name) then
      open_detail()
    end
  end,
  ["fleetlens.select"] = function(args)
    select_name(args.name)
  end,
  ["fleetlens.select_kind"] = function(args)
    select_kind(args.kind)
  end,
  ["fleetlens.refresh"] = refresh,
  -- Esc steps out of a resource first, then closes.
  ["fleetlens.close"] = function()
    if detail then
      detail = nil
    else
      close()
    end
  end,
}

local KEYS = {
  j = "fleetlens.down",
  down = "fleetlens.down",
  k = "fleetlens.up",
  up = "fleetlens.up",
  pagedown = "fleetlens.page_down",
  pageup = "fleetlens.page_up",
  home = "fleetlens.first",
  g = "fleetlens.first",
  ["end"] = "fleetlens.last",
  G = "fleetlens.last",
  tab = "fleetlens.kind",
  backtab = "fleetlens.kind_back",
  enter = "fleetlens.view",
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
  -- What a click does, as actions anything can invoke by name.
  actions = {
    {
      name = "fleetlens.select_kind",
      effect = "ui-write",
      args = { { name = "kind", kind = "string", required = true } },
    },
    {
      name = "fleetlens.select",
      effect = "ui-write",
      args = { { name = "name", kind = "string", required = true } },
    },
    {
      name = "fleetlens.view",
      effect = "ui-write",
      args = { { name = "name", kind = "string" } },
    },
  },
  render = render,
  on_action = function(action, args)
    if action == "fleetlens.toggle" then
      if state.open then
        close()
      else
        state.open = true
      end
      return true
    end
    local fn = state.open and ACTIONS[action]
    if fn then
      fn(args or {})
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
      ACTIONS[action]({})
    end
    -- A float takes every key; swallow the rest rather than let them type.
    return true
  end,
  -- A kind selects it; a row selects it, and a second quick press reads it.
  on_click = function(hit)
    if not state.open then
      return false
    end
    local id = hit.id or ""
    local kind = id:match("^kind:(.+)$")
    local name = id:match("^row:(.+)$")
    if kind then
      ACTIONS["fleetlens.select_kind"]({ kind = kind })
    elseif name then
      ACTIONS[hit.clicks == 2 and "fleetlens.view" or "fleetlens.select"]({ name = name })
    end
    -- Claimed either way, so a press inside the float never reaches below.
    return true
  end,
  -- Ctrl+L / Ctrl+H step through the kinds, as they step through panes.
  on_focus_cycle = function(direction)
    if not state.open or detail then
      return false
    end
    step_kind(direction == "next" and 1 or -1)
    return true
  end,
  on_outside = function()
    if state.open then
      close()
    end
    return true
  end,
}
