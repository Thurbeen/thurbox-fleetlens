-- Fleet objects as table rows.
--
-- Pure: objects in, rows out. Every kind gets the generic columns, built only
-- from Fleet's envelope and the status conventions `fleet status` understands
-- (`phase`, `conditions`, `observedGeneration`). Task and ChangeRequest have
-- their own.
--
-- A row is { name, marker, why, created, cells = { string... },
-- tones = { role|nil... }, related = { { kind, name }... } }, where a tone
-- names the thurbox theme role (`thurbox.theme.roles`) that colours the cell.

local M = {}

local ATTENTION = "NeedsAttention"
local DROPPED = "…"

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

--- The first Question the worker declared that nobody has answered yet.
---@param status table
---@return string|nil
function M.question(status)
  local answered = status.answered or {}
  for _, fact in ipairs(status.declared or {}) do
    if fact.kind == "Question" and type(fact.id) == "string" and not answered[fact.id] then
      if type(fact.text) ~= "string" or fact.text == "" or fact.text == DROPPED then
        return fact.id .. " waits for an answer"
      end
      return fact.id .. ": " .. (fact.text:match("[^\n]+") or "")
    end
  end
  return nil
end

local SETTLED = { Concluded = true, Settled = true }

local function phase_tone(phase)
  if SETTLED[phase] then
    return "status_done"
  elseif phase == "Stalled" then
    return "status_error"
  elseif phase == "Pending" then
    return "text_muted"
  end
  return nil
end

local AGENT_TONE = {
  working = "status_working",
  attention = "status_blocked",
  idle = "status_idle",
  unknown = "status_unknown",
}
local SESSION_TONE = {
  Idle = "status_idle",
  Paused = "text_muted",
  Lost = "status_error",
  Gone = "status_error",
}
local RESULT_TONE = { shipped = "status_done", stuck = "status_blocked", failed = "status_error" }

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
    return { "NAME", "PHASE", "AGENT", "SESSION", "GEN", "RESULT", "CR", "AGE" }
  elseif kind == "ChangeRequest" then
    return { "NAME", "CHANGE", "PHASE", "COND", "SYNC", "AGE" }
  end
  return { "NAME", "PHASE", "COND", "SYNC", "AGE" }
end

--- A change's URL as `owner/repo#N` (GitHub) or `group/project!N` (GitLab).
---@param url string|nil
---@return string
function M.change(url)
  if type(url) ~= "string" or url == "" then
    return "-"
  end
  local repo, n = url:match("^https?://[^/]+/(.-)/pull/(%d+)")
  if repo then
    return repo .. "#" .. n
  end
  repo, n = url:match("^https?://[^/]+/(.-)/%-/merge_requests/(%d+)")
  if repo then
    return repo .. "!" .. n
  end
  return url
end

local function session_cell(status)
  local state = status.sessionState
  if not status.session and not state then
    return "-", nil
  end
  local host = (status.session or {}).host
  local text = state or "?"
  if host and host ~= "local" then
    text = host .. " " .. text
  end
  return text, SESSION_TONE[state]
end

local function task_cells(obj)
  local status = obj.status or {}
  local meta = obj.metadata or {}
  local session, session_tone = session_cell(status)
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
  local agent = status.agentState or "-"
  return { agent, session, gen, outcome, crs > 0 and tostring(crs) or "-" }, {
    AGENT_TONE[agent],
    session_tone,
    gen ~= "-" and status.brief.generation ~= meta.generation and "danger" or nil,
    RESULT_TONE[outcome],
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

local function needs_person(row)
  return row.marker ~= nil
end

--- Rows for one kind: what needs a person first, then open work, then newest.
---@param kind string
---@param objects table[]
---@param now number|nil seconds since the epoch
---@return table[]
function M.rows(kind, objects, now)
  local rows = {}
  for _, obj in ipairs(objects or {}) do
    local meta = obj.metadata or {}
    local status = obj.status or {}
    local created = meta.creationTimestamp or 0
    local marker, why = nil, nil
    if kind == "Task" then
      why = M.attention(status.conditions)
      marker = why and "!" or nil
      if not why then
        why = M.question(status)
        marker = why and "?" or nil
      end
    end
    local name = meta.name or "?"
    if meta.deletionTimestamp then
      name = "✕ " .. name
    end
    local cells, tones = { name }, { marker == "!" and "danger" or nil }
    local function add(cell, tone)
      cells[#cells + 1] = cell
      tones[#cells] = tone
    end
    if kind == "ChangeRequest" then
      add(M.change((obj.spec or {}).url))
    end
    add(status.phase or "-", phase_tone(status.phase))
    if kind == "Task" then
      local extra, extra_tones = task_cells(obj)
      for i = 1, #extra do
        add(extra[i], extra_tones[i])
      end
    else
      add(M.glyphs(status.conditions))
      local seen, gen = observed(obj)
      add(seen == gen and "✓" or "±", seen ~= gen and "status_working" or nil)
    end
    add(M.age(now and (now - math.floor(created / 1000)) or nil))
    rows[#rows + 1] = {
      name = meta.name,
      marker = marker,
      why = why,
      settled = SETTLED[status.phase] == true,
      created = created,
      cells = cells,
      tones = tones,
      related = M.relations(kind, obj),
      object = obj,
    }
  end
  table.sort(rows, function(a, b)
    if needs_person(a) ~= needs_person(b) then
      return needs_person(a)
    end
    if a.settled ~= b.settled then
      return b.settled
    end
    if a.created ~= b.created then
      return a.created > b.created
    end
    return (a.name or "") < (b.name or "")
  end)
  return rows
end

return M
