-- The Lens as a node tree: rail, table, trail and footer, in one float.
--
-- A function of one plain table the pane builds (`snap`), so it renders the same
-- under a faked snapshot in the tests as under thurbox.
--
-- snap = {
--   where = "local · ~/.config/fleet/config.toml", version = "3.1.0",
--   kinds = { { kind = "Task", count = 2 }, ... }, kind = "Task",
--     (a count is a number, "?" when fleet could not tell, nil while counting)
--   columns = { "NAME", ... }, rows = { model rows }, selected = 1,
--   loading = bool, stale = bool, banner = { title, detail } | nil,
--   note = "untrusted text" | nil,
--   detail = { title = "Task/alpha", lines = { { text, first }... }, offset = 0,
--     loading = bool } | nil,
--     (`lines` as `yaml.wrap` breaks them, at `M.text_width`)
-- }
--
-- Clicks land by id: `kind:<Kind>` on a rail line, `row:<name>` on a table row,
-- `rel:<Kind>/<name>` on a relation in the trail. A footer hint carries
-- `key:<chord>`, so the kernel replays the key itself.

local theme = require("lib.theme")
local hover = require("lib.hover")
local ui = require("lib.ui")
local widgets = require("lib.widgets")

local M = {}

local RAIL = 20
local NAME_MIN = 12

local MARKER_ROLE = { ["!"] = "danger", ["?"] = "status_blocked" }

local function line(spans, extra)
  local node = { type = "text", len = 1, text = { spans } }
  for k, v in pairs(extra or {}) do
    node[k] = v
  end
  return node
end

local function selection_bar()
  return { bg = theme.role("selection_bg"), fg = theme.role("selection_fg"), bold = true }
end

--- The float's inner width: 92 % of the screen, less its two borders.
---@param ctx table
---@return integer
function M.inner_width(ctx)
  return math.floor((ctx.width or 100) * 0.92) - 2
end

--- How many columns a resource's line may take: the inner width, less the
--- leading space and one spare column.
---@param ctx table
---@return integer
function M.text_width(ctx)
  return math.max(20, M.inner_width(ctx) - 2)
end

---@param ctx table
---@return integer
function M.height(ctx)
  return math.max(8, math.floor((ctx.height or 40) * 0.9) - 6)
end

--- How many lines of a resource fit under its title.
---@param ctx table
---@return integer
function M.room(ctx)
  return math.max(1, M.height(ctx) - 1)
end

--- How many table rows fit under its head and column titles.
---@param ctx table
---@return integer
function M.rows_room(ctx)
  return math.max(1, M.height(ctx) - 2)
end

--- `No Tasks`, `No Policies`, `No Classes`.
---@param kind string
---@return string
function M.plural(kind)
  if kind:match("[^aeiou]y$") then
    return kind:sub(1, -2) .. "ies"
  elseif kind:match("[sxz]$") or kind:match("[cs]h$") then
    return kind .. "es"
  end
  return kind .. "s"
end

--- Column widths from the content; NAME gives way so the row fits `room`.
local function widths(columns, rows, room)
  local w = {}
  for i, title in ipairs(columns) do
    w[i] = widgets.len(title)
  end
  for _, row in ipairs(rows) do
    for i, cell in ipairs(row.cells) do
      w[i] = math.max(w[i] or 0, widgets.len(cell))
    end
  end
  local others = 0
  for i = 2, #w do
    others = others + w[i] + 2
  end
  w[1] = math.min(w[1], math.max(NAME_MIN, room - others))
  return w
end

local function cells_spans(cells, w, tones, base)
  local spans = {}
  for i, cell in ipairs(cells) do
    local text = widgets.pad(widgets.truncate(cell, w[i]), w[i])
    local role = tones and tones[i]
    spans[#spans + 1] = {
      text = (i == 1 and "" or "  ") .. text,
      style = { fg = role and theme.role(role) or base },
    }
  end
  return spans
end

local function count_text(count)
  if count == nil then
    return "…", theme.muted
  elseif count == "?" then
    return "?", theme.bad
  end
  return tostring(count), count == 0 and theme.muted or theme.secondary
end

local function rail(snap)
  local out = { line({ { text = " KINDS", style = { fg = theme.muted } } }) }
  for _, k in ipairs(snap.kinds) do
    local on = k.kind == snap.kind
    local count, colour = count_text(k.count)
    local label = (on and "▸ " or "  ") .. widgets.truncate(k.kind, RAIL - 7)
    local gap = math.max(1, RAIL - 1 - widgets.len(label) - widgets.len(count))
    local id = "kind:" .. k.kind
    out[#out + 1] = line({
      { text = label .. string.rep(" ", gap), style = { fg = not on and theme.text or nil } },
      { text = count .. " ", style = { fg = not on and colour or nil } },
    }, {
      id = id,
      style = on and selection_bar() or (hover.id(id) and hover.row_style() or nil),
    })
  end
  return { type = "box", len = RAIL, children = out }
end

local function separator(height)
  local out = {}
  for i = 1, height do
    out[i] = line({ { text = "│", style = { fg = theme.border } } })
  end
  return { type = "box", len = 1, children = out }
end

local function empty_state(snap, width)
  local title, note
  if snap.loading then
    title = "Asking fleet…"
  elseif snap.stale then
    title, note = "Unknown: fleet could not tell", "R asks again"
  else
    title, note = "No " .. M.plural(snap.kind), "R asks fleet again"
  end
  local out = {}
  for _, spans in ipairs(ui.empty({ title = title, width = width, note = note })) do
    out[#out + 1] = line(spans)
  end
  return out
end

local function head_line(snap, width, first, last)
  local waiting = 0
  for _, row in ipairs(snap.rows) do
    if row.marker then
      waiting = waiting + 1
    end
  end
  local left = {
    { text = " " .. snap.kind, style = { fg = theme.text, bold = true } },
    { text = " " .. #snap.rows, style = { fg = theme.secondary } },
  }
  if waiting > 0 then
    left[#left + 1] =
      { text = string.format("  · %d need you", waiting), style = { fg = theme.warn } }
  end
  if snap.loading then
    left[#left + 1] = { text = "  · asking fleet…", style = { fg = theme.muted } }
  elseif snap.stale then
    left[#left + 1] = { text = "  · stale", style = { fg = theme.bad } }
  end
  local right = ""
  if first and (first > 1 or last < #snap.rows) then
    right = string.format("%d–%d of %d ", first, last, #snap.rows)
  end
  local used = 0
  for _, span in ipairs(left) do
    used = used + widgets.len(span.text)
  end
  left[#left + 1] = {
    text = string.rep(" ", math.max(1, width - used - widgets.len(right))) .. right,
    style = { fg = theme.muted },
  }
  return line(left)
end

local function table_body(snap, height, width)
  local children = {}
  if snap.banner then
    children[#children + 1] = line({
      { text = " ! " .. snap.banner.title, style = { fg = theme.bad, bold = true } },
      {
        text = snap.banner.detail ~= "" and (" — " .. snap.banner.detail) or "",
        style = { fg = theme.muted },
      },
    })
  end
  if #snap.rows == 0 then
    table.insert(children, 1, head_line(snap, width))
    for _, l in ipairs(empty_state(snap, width)) do
      children[#children + 1] = l
    end
    return { type = "box", fill = 1, children = children }
  end
  local w = widths(snap.columns, snap.rows, width - 3)
  local header = cells_spans(snap.columns, w, nil, theme.muted)
  table.insert(header, 1, { text = "  " })
  children[#children + 1] = line(header)
  local room = math.max(1, height - #children - 1)
  local first = math.max(1, math.min(snap.selected - room + 1, #snap.rows - room + 1))
  first = math.max(1, math.min(first, snap.selected))
  local last = math.min(#snap.rows, first + room - 1)
  table.insert(children, 1, head_line(snap, width, first, last))
  for i = first, last do
    local row = snap.rows[i]
    local selected = i == snap.selected
    local id = "row:" .. (row.name or i)
    local spans
    if selected then
      spans = cells_spans(row.cells, w, nil, nil)
    else
      local base = snap.stale and theme.muted or theme.text
      spans = cells_spans(row.cells, w, not snap.stale and row.tones or nil, base)
    end
    local marker_role = not selected and MARKER_ROLE[row.marker] or nil
    table.insert(spans, 1, {
      text = row.marker and (row.marker .. " ") or "  ",
      style = { fg = marker_role and theme.role(marker_role) or nil, bold = row.marker ~= nil },
    })
    children[#children + 1] = line(spans, {
      id = id,
      style = selected and selection_bar() or (hover.id(id) and hover.row_style() or nil),
    })
  end
  return { type = "box", fill = 1, children = children }
end

local function detail_body(snap, height)
  local d = snap.detail
  if d.loading then
    return {
      type = "box",
      fill = 1,
      children = {
        line({ { text = " " .. d.title, style = { fg = theme.accent, bold = true } } }),
        line({ { text = "   Asking fleet…", style = { fg = theme.muted } } }),
      },
    }
  end
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
    local text = d.lines[i].text
    local key, rest = text:match("^(%s*[^%s:][^:]*:)(.*)$")
    if d.lines[i].first and key and not text:find('^%s*["|]') then
      children[#children + 1] = line({
        { text = " " .. key, style = { fg = theme.accent } },
        { text = rest, style = { fg = theme.text } },
      })
    else
      children[#children + 1] = line({ { text = " " .. text, style = { fg = theme.text } } })
    end
  end
  return { type = "box", fill = 1, children = children }
end

local function note_body(note)
  local children = { line({ { text = "" } }) }
  for text in note:gmatch("[^\n]+") do
    children[#children + 1] = line({ { text = "   " .. text, style = { fg = theme.text } } })
  end
  return { type = "box", fill = 1, children = children }
end

--- The footer: each hint is a button replaying its key, the chord in the
--- key-hint colour as thurbox's own footers draw it. Hints marked optional
--- give way first when the Lens is narrow.
local function footer(hints, width)
  local budget = width - 1
  for _, h in ipairs(hints) do
    budget = budget - widgets.len(h.chord .. " " .. h.label .. "  ")
  end
  local spans = { { text = " " } }
  for i = #hints, 1, -1 do
    if budget < 0 and hints[i].optional then
      budget = budget + widgets.len(hints[i].chord .. " " .. hints[i].label .. "  ")
      hints[i] = false
    end
  end
  for _, h in ipairs(hints) do
    if h then
      local role = "key:" .. h.key
      local lit = hover.role(role)
      spans[#spans + 1] = {
        text = h.chord,
        role = role,
        style = lit and hover.button_style() or { fg = theme.hint },
      }
      spans[#spans + 1] = {
        text = " " .. h.label,
        role = role,
        style = lit and hover.button_style() or { fg = theme.muted },
      }
      spans[#spans + 1] = { text = "  " }
    end
  end
  return line(spans)
end

local function list_hints()
  return {
    { key = "j", chord = "j/k", label = "move" },
    { key = "tab", chord = "tab", label = "kind" },
    { key = "shift+tab", chord = "⇧tab", label = "back" },
    { key = "home", chord = "g/G", label = "first/last", optional = true },
    { key = "1", chord = "1-9", label = "jump to kind", optional = true },
    { key = "enter", chord = "enter", label = "read" },
    { key = "shift+r", chord = "R", label = "refresh", optional = true },
    { key = "esc", chord = "esc", label = "close" },
  }
end

local function detail_hints()
  return {
    { key = "j", chord = "j/k", label = "scroll" },
    { key = "pagedown", chord = "PgDn/PgUp", label = "page", optional = true },
    { key = "home", chord = "g/G", label = "top/end" },
    { key = "shift+r", chord = "R", label = "refresh", optional = true },
    { key = "esc", chord = "esc", label = "back" },
  }
end

local function trail(snap, ctx)
  local sel = snap.rows[snap.selected]
  local links, room = {}, M.text_width(ctx)
  for i, r in ipairs(sel and sel.related or {}) do
    local gap = i == 1 and "  → " or "  "
    local ref = r.kind .. "/" .. r.name
    local id = "rel:" .. ref
    links[#links + 1] = { text = gap, style = { fg = theme.muted } }
    links[#links + 1] = {
      text = ref,
      id = id,
      style = hover.id(id) and hover.button_style() or { fg = theme.accent, underline = true },
    }
    room = room - widgets.len(gap) - widgets.len(ref)
  end
  local out = { { text = " ", style = { fg = theme.muted } } }
  if sel and sel.why then
    local why = widgets.truncate_hard(sel.marker .. " " .. sel.why, room)
    out = { { text = " " .. why, style = { fg = theme.role(MARKER_ROLE[sel.marker]) } } }
  elseif sel then
    local name = widgets.truncate_hard(snap.kind .. "/" .. (sel.name or ""), room)
    out = { { text = " " .. name, style = { fg = theme.muted } } }
  end
  for _, span in ipairs(links) do
    out[#out + 1] = span
  end
  return line(out)
end

--- The whole float.
---@param ctx table
---@param snap table
---@return table
function M.render(ctx, snap)
  local height = M.height(ctx)
  local inner = M.inner_width(ctx)
  local where = { { text = " " .. snap.where, style = { fg = theme.muted } } }
  if snap.version then
    where[#where + 1] = { text = " · fleet " .. snap.version, style = { fg = theme.muted } }
  end
  local body
  if snap.note then
    body = note_body(snap.note)
  elseif snap.detail then
    body = detail_body(snap, height)
  else
    body = {
      type = "box",
      axis = "horizontal",
      fill = 1,
      children = { rail(snap), separator(height), table_body(snap, height, inner - RAIL - 1) },
    }
  end
  local hints = snap.note and { { key = "esc", chord = "esc", label = "close" } }
    or (snap.detail and detail_hints() or list_hints())
  local crumb = snap.detail and snap.detail.title or (not snap.note and snap.kind or nil)
  local title = { { text = " Fleet Lens ", style = { fg = theme.accent, bold = true } } }
  if crumb then
    title[#title + 1] = { text = "· " .. crumb .. " ", style = { fg = theme.muted } }
  end
  return {
    type = "box",
    float = { width = 92, height = 90 },
    children = { line(where), body, trail(snap, ctx), footer(hints, inner) },
    frame = {
      title = title,
      border_type = "rounded",
      border_style = { fg = theme.role("border_focused") },
      style = { fg = theme.text, bg = theme.role("app_bg") },
    },
  }
end

return M
