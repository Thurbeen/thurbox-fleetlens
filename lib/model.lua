-- Fleet objects as table rows.
--
-- Pure: objects in, rows out. Every kind gets the generic columns, built only
-- from Fleet's envelope and the status conventions `fleet status` understands
-- (`phase`, `conditions`, `observedGeneration`). Task has its own spec.
--
-- A row is { name, attention, why, created, cells = { string... },
-- tones = { role|nil... }, related = { { kind, name }... } }, where a tone
-- names a theme role for that cell.

local M = {}

--- A Task condition a person must answer. Drawn as `!`, not as a glyph.
local ATTENTION = "NeedsAttention"

local GLYPH = { True = "●", False = "○" }

--- How long ago, from seconds.
---@param seconds number|nil
---@return string
function M.age(seconds)
  if not seconds or seconds < 0 then
    return "-"
  end
  if seconds < 60 then
    return string.format("%ds", seconds)
  elseif seconds < 3600 then
    return string.format("%dm", math.floor(seconds / 60))
  elseif seconds < 86400 then
    return string.format("%dh", math.floor(seconds / 3600))
  end
  return string.format("%dd", math.floor(seconds / 86400))
end

--- One glyph per condition, in Fleet's order; the attention condition is left
--- to the `!` marker.
---@param conditions table[]|nil
---@return string
function M.glyphs(conditions)
  local out = {}
  for _, c in ipairs(conditions or {}) do
    if c.type ~= ATTENTION then
      out[#out + 1] = GLYPH[c.status] or "?"
    end
  end
  return table.concat(out)
end

--- The attention condition's reason and message, when it is True.
---@param conditions table[]|nil
---@return string|nil
function M.attention(conditions)
  for _, c in ipairs(conditions or {}) do
    if c.type == ATTENTION and c.status == "True" then
      local text = c.reason or ATTENTION
      if c.message and c.message ~= "" then
        text = text .. ": " .. c.message
      end
      return ATTENTION .. "/" .. text
    end
  end
  return nil
end

local function phase_tone(phase)
  if phase == "Concluded" or phase == "Settled" then
    return "success"
  elseif phase == "Stalled" then
    return "error"
  end
  return nil
end

local function observed(obj)
  local status = obj.status or {}
  local meta = obj.metadata or {}
  return status.observedGeneration or meta.generation, meta.generation
end

--- The columns of a kind, by title.
---@param kind string
---@return string[]
function M.columns(kind)
  if kind == "Task" then
    return { "NAME", "PHASE", "COND", "SESSION", "GEN", "RESULT", "CR", "AGE" }
  end
  return { "NAME", "PHASE", "COND", "SYNC", "AGE" }
end

local function task_cells(obj, sessions)
  local status = obj.status or {}
  local meta = obj.metadata or {}
  local session = status.session
  local live = session and sessions[session.id] or nil
  local where = "-"
  if session then
    where = (session.host or "?") .. " " .. (live or "gone")
  end
  local gen = "-"
  if status.brief and status.brief.generation then
    gen = string.format("%d/%d", status.brief.generation, meta.generation or 0)
  end
  local crs = 0
  for _, fact in ipairs(status.declared or {}) do
    if fact.kind == "ChangeRequest" then
      crs = crs + 1
    end
  end
  local outcome = status.result and status.result.outcome or "-"
  local result_tone = ({ shipped = "success", stuck = "warning", failed = "error" })[outcome]
  return { where, gen, outcome, crs > 0 and tostring(crs) or "-" }, {
    live and nil or "muted",
    gen ~= "-" and status.brief.generation ~= meta.generation and "error" or nil,
    result_tone,
    nil,
  }
end

--- The resources an object names, as { kind, name }: a Task's TaskConfig and
--- what it declared, a TaskConfig's EnvProviders. Malformed references are
--- skipped.
---@param kind string
---@param obj table
---@return table[]
function M.relations(kind, obj)
  local out = {}
  local function add(to, name)
    if type(to) == "string" and type(name) == "string" and name ~= "" then
      out[#out + 1] = { kind = to, name = name }
    end
  end
  local spec = obj.spec or {}
  if kind == "Task" then
    add("TaskConfig", (spec.configRef or {}).name)
    for _, fact in ipairs((obj.status or {}).declared or {}) do
      add(fact.kind, fact.name)
    end
  elseif kind == "TaskConfig" then
    for _, ref in ipairs(spec.envFrom or {}) do
      add("EnvProvider", ref.name)
    end
  end
  return out
end

--- Rows for one kind: attention first, then newest.
---@param kind string
---@param objects table[]
---@param now number|nil seconds since the epoch
---@param sessions table<string, string> thurbox session id → its status
---@return table[]
function M.rows(kind, objects, now, sessions)
  local rows = {}
  for _, obj in ipairs(objects or {}) do
    local meta = obj.metadata or {}
    local status = obj.status or {}
    local created = meta.creationTimestamp or 0
    local why = kind == "Task" and M.attention(status.conditions) or nil
    local name = meta.name or "?"
    if meta.deletionTimestamp then
      name = "✕ " .. name
    end
    local cells = { name, status.phase or "-", M.glyphs(status.conditions) }
    local tones = { why and "error" or nil, phase_tone(status.phase), nil }
    if kind == "Task" then
      local extra, extra_tones = task_cells(obj, sessions or {})
      for i = 1, 4 do
        cells[#cells + 1] = extra[i]
        tones[#cells] = extra_tones[i]
      end
    else
      local seen, gen = observed(obj)
      cells[#cells + 1] = seen == gen and "✓" or "±"
      tones[#cells] = seen ~= gen and "warning" or nil
    end
    cells[#cells + 1] = M.age(now and (now - math.floor(created / 1000)) or nil)
    rows[#rows + 1] = {
      name = meta.name,
      attention = why ~= nil,
      why = why,
      created = created,
      cells = cells,
      tones = tones,
      related = M.relations(kind, obj),
      object = obj,
    }
  end
  table.sort(rows, function(a, b)
    if a.attention ~= b.attention then
      return a.attention
    end
    if a.created ~= b.created then
      return a.created > b.created
    end
    return (a.name or "") < (b.name or "")
  end)
  return rows
end

return M
