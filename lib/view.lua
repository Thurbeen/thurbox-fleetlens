-- The Lens as a node tree: rail, table, trail and footer, in one float.
--
-- A function of one plain table the pane builds (`snap`), so it renders the same
-- under a faked snapshot in the tests as under thurbox.
--
-- snap = {
--   where = "local · ~/.config/fleet/config.toml", version = "2.3.0",
--   kinds = { { kind = "Task", count = 2 }, ... }, kind = "Task",
--   columns = { "NAME", ... }, rows = { model rows }, selected = 1,
--   loading = bool, stale = bool, banner = { title, detail } | nil,
--   note = "untrusted text" | nil,
--   detail = { title = "Task/alpha", lines = { string... }, offset = 0 } | nil,
-- }
--
-- Clicks land by id: `kind:<Kind>` on a rail line, `row:<name>` on a table row.
-- A footer hint carries `key:<chord>`, so the kernel replays the key itself.

local theme = require("lib.theme")
local hover = require("lib.hover")
local widgets = require("lib.widgets")

local M = {}

local RAIL = 18
local NAME_MAX = 44

local function tone(role)
  if role == "success" then
    return theme.ok
  elseif role == "warning" then
    return theme.warn
  elseif role == "error" then
    return theme.bad
  elseif role == "muted" then
    return theme.muted
  end
  return nil
end

local function line(spans, extra)
  local node = { type = "text", len = 1, text = { spans } }
  for k, v in pairs(extra or {}) do
    node[k] = v
  end
  return node
end

--- Column widths from the content: the widest cell, NAME capped.
local function widths(columns, rows)
  local w = {}
  for i, title in ipairs(columns) do
    w[i] = widgets.len(title)
  end
  for _, row in ipairs(rows) do
    for i, cell in ipairs(row.cells) do
      w[i] = math.max(w[i] or 0, widgets.len(cell))
    end
  end
  w[1] = math.min(w[1] + 2, NAME_MAX)
  return w
end

local function cells_spans(cells, w, tones, base)
  local spans = {}
  for i, cell in ipairs(cells) do
    local text = widgets.pad(widgets.truncate(cell, w[i]), w[i])
    spans[#spans + 1] = {
      text = (i == 1 and "" or "  ") .. text,
      style = { fg = tone(tones and tones[i]) or base },
    }
  end
  return spans
end

local function rail(snap)
  local out = { line({ { text = " KINDS", style = { fg = theme.muted } } }) }
  for _, k in ipairs(snap.kinds) do
    local on = k.kind == snap.kind
    local count = k.count and tostring(k.count) or ""
    if on and snap.stale then
      count = "?"
    end
    local label = (on and "▸ " or "  ") .. widgets.truncate(k.kind, RAIL - 6)
    local gap = math.max(1, RAIL - 1 - widgets.len(label) - widgets.len(count))
    out[#out + 1] = line({
      { text = label .. string.rep(" ", gap), style = { fg = on and theme.accent or theme.text } },
      { text = count, style = { fg = on and theme.accent or theme.muted } },
    }, { id = "kind:" .. k.kind, style = on and { bg = theme.role("selection_bg") } or nil })
  end
  return { type = "box", len = RAIL, children = out }
end

local function table_body(snap, height)
  local children = {}
  local head = string.format(" %s %d", snap.kind, #snap.rows)
  local fresh = snap.loading and "loading…" or (snap.stale and "stale" or "")
  children[#children + 1] = line({
    { text = head, style = { fg = theme.text } },
    { text = "  · attention first  ", style = { fg = theme.muted } },
    { text = fresh, style = { fg = snap.stale and theme.bad or theme.muted } },
  })
  if snap.banner then
    children[#children + 1] = line({
      { text = " ! " .. snap.banner.title, style = { fg = theme.bad } },
      {
        text = snap.banner.detail ~= "" and (" — " .. snap.banner.detail) or "",
        style = { fg = theme.muted },
      },
    })
  end
  if snap.note then
    children[#children + 1] = { type = "text", fill = 1, wrap = true, text = snap.note }
    return { type = "box", fill = 1, children = children }
  end
  if #snap.rows == 0 then
    local empty = snap.loading and "Asking fleet…"
      or (snap.stale and "Unknown" or ("No " .. snap.kind .. "s"))
    children[#children + 1] = line({ { text = "   " .. empty, style = { fg = theme.muted } } })
    return { type = "box", fill = 1, children = children }
  end
  local w = widths(snap.columns, snap.rows)
  local header = cells_spans(snap.columns, w, nil, theme.muted)
  table.insert(header, 1, { text = "  " })
  children[#children + 1] = line(header)
  local room = math.max(1, height - #children)
  local first = math.max(1, math.min(snap.selected - room + 1, #snap.rows - room + 1))
  first = math.max(1, math.min(first, snap.selected))
  for i = first, math.min(#snap.rows, first + room - 1) do
    local row = snap.rows[i]
    local base = snap.stale and theme.muted or theme.text
    local tones = snap.stale and {} or row.tones
    local spans = cells_spans(row.cells, w, tones, base)
    table.insert(spans, 1, {
      text = row.attention and "! " or "  ",
      style = { fg = theme.bad },
    })
    local selected = i == snap.selected
    children[#children + 1] = line(spans, {
      id = "row:" .. (row.name or i),
      style = selected and { bg = theme.role("selection_bg") } or nil,
    })
  end
  return { type = "box", fill = 1, children = children }
end

--- How many lines of a resource fit under its title.
---@param ctx table
---@return integer
function M.room(ctx)
  return math.max(1, M.height(ctx) - 1)
end

---@param ctx table
---@return integer
function M.height(ctx)
  return math.max(8, math.floor((ctx.height or 40) * 0.9) - 6)
end

local function detail_body(snap, height)
  local d = snap.detail
  local room = math.max(1, height - 1)
  local offset = math.max(0, math.min(d.offset or 0, #d.lines - room))
  local last = math.min(#d.lines, offset + room)
  local children = {
    line({
      { text = " " .. d.title, style = { fg = theme.accent, bold = true } },
      {
        text = string.format("  · yaml  %d–%d of %d", offset + 1, last, #d.lines),
        style = { fg = theme.muted },
      },
    }),
  }
  for i = offset + 1, last do
    local key, rest = d.lines[i]:match("^(%s*[^%s:][^:]*:)(.*)$")
    if key and not d.lines[i]:find('^%s*["|]') then
      children[#children + 1] = line({
        { text = " " .. key, style = { fg = theme.accent } },
        { text = rest, style = { fg = theme.text } },
      })
    else
      children[#children + 1] = line({ { text = " " .. d.lines[i], style = { fg = theme.text } } })
    end
  end
  return { type = "box", fill = 1, children = children }
end

--- The footer: each hint is a button replaying its key.
local function footer(hints)
  local spans = { { text = " " } }
  for i, h in ipairs(hints) do
    if i > 1 then
      spans[#spans + 1] = { text = " · ", style = { fg = theme.muted } }
    end
    local role = "key:" .. h[1]
    spans[#spans + 1] = {
      text = h[2],
      role = role,
      style = hover.style(role, hover.button_style(), { fg = theme.muted }),
    }
  end
  return line(spans)
end

local LIST_HINTS = {
  { "j", "j/k move" },
  { "tab", "tab kind" },
  { "shift+tab", "⇧tab back" },
  { "enter", "enter view" },
  { "shift+r", "R refresh" },
  { "esc", "esc close" },
}
local DETAIL_HINTS = {
  { "j", "j/k scroll" },
  { "home", "g/G top/end" },
  { "esc", "esc back" },
}

--- The whole float.
---@param ctx table
---@param snap table
---@return table
function M.render(ctx, snap)
  local height = M.height(ctx)
  local sel = snap.rows[snap.selected]
  local trail = { { text = " ", style = { fg = theme.muted } } }
  if sel and sel.why then
    trail = { { text = " ! " .. sel.why, style = { fg = theme.bad } } }
  elseif sel then
    trail = { { text = " " .. snap.kind .. "/" .. (sel.name or ""), style = { fg = theme.muted } } }
  end
  local body = {
    line({
      { text = " " .. snap.where, style = { fg = theme.muted } },
      {
        text = snap.version and ("  · fleet " .. snap.version) or "",
        style = { fg = theme.muted },
      },
    }),
    snap.detail and detail_body(snap, height) or {
      type = "box",
      axis = "horizontal",
      fill = 1,
      children = { rail(snap), table_body(snap, height) },
    },
    line(trail),
    footer(snap.detail and DETAIL_HINTS or LIST_HINTS),
  }
  return {
    type = "box",
    float = { width = 92, height = 90 },
    children = body,
    frame = {
      title = { { text = " Fleet Lens ", style = { fg = theme.accent, bold = true } } },
      border_type = "rounded",
      border_style = { fg = theme.role("border_focused") },
      style = { fg = theme.text, bg = theme.role("app_bg") },
    },
  }
end

return M
