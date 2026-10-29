-- A decoded Fleet object as YAML lines, for reading, not for parsing back.
--
-- Pure: a value in, strings out. Keys come in a fixed order, since a decoded
-- table has none: at the top, the envelope (`apiVersion`, `kind`, `metadata`,
-- `spec`, `status`) first; everywhere else, by name. An empty table is `{}`: the decoder
-- cannot tell an empty list from an empty map.

local M = {}

local FIRST = { apiVersion = 1, kind = 2, metadata = 3, spec = 4, status = 5 }
local WORDS = { ["true"] = true, ["false"] = true, null = true, ["~"] = true }
for _, word in ipairs({ "yes", "no", "on", "off", "y", "n" }) do
  WORDS[word] = true
end

local function is_list(t)
  local n = #t
  if n == 0 then
    return false
  end
  for k in pairs(t) do
    if math.type(k) ~= "integer" or k < 1 or k > n then
      return false
    end
  end
  return true
end

local function keys(t, top)
  local out = {}
  for k in pairs(t) do
    out[#out + 1] = k
  end
  table.sort(out, function(a, b)
    local ra, rb = top and FIRST[a] or 99, top and FIRST[b] or 99
    if ra ~= rb then
      return ra < rb
    end
    return tostring(a) < tostring(b)
  end)
  return out
end

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }

local function quote(s)
  return '"'
    .. s:gsub('[%c"\\]', function(c)
      return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end)
    .. '"'
end

--- A string as a plain scalar when a reader would take it for what it is.
local function text(s)
  if
    s == ""
    or s:find("^%s")
    or s:find("%s$")
    or WORDS[s:lower()]
    or tonumber(s)
    or s:find("^[%-%?:,%[%]{}#&%*!|>'\"%%@`]")
    or s:find(": ")
    or s:find(" #")
    or s:find(":$")
    or s:find("%c")
  then
    return quote(s)
  end
  return s
end

local function number(n)
  if math.type(n) == "integer" then
    return string.format("%d", n)
  elseif n == math.floor(n) and math.abs(n) < 2 ^ 53 then
    return string.format("%.0f", n)
  end
  return string.format("%.14g", n)
end

local function scalar(v)
  if type(v) == "string" then
    return text(v)
  elseif type(v) == "number" then
    return number(v)
  end
  return tostring(v)
end

--- A string that reads better as a block: several lines, none led by a space.
local function block(v)
  return type(v) == "string" and v:find("\n") and not v:find("^ ") and not v:find("\n ")
end

local emit

--- `head` is the line's start (`key:` or `-`); the value follows it.
local function entry(out, pad, head, v, indent)
  if type(v) == "table" and next(v) ~= nil then
    local inner = {}
    emit(v, indent + 2, inner)
    if head == "-" then
      -- A list item's first line shares the dash.
      inner[1] = pad .. "- " .. inner[1]:sub(indent + 3)
      for _, l in ipairs(inner) do
        out[#out + 1] = l
      end
      return
    end
    out[#out + 1] = pad .. head
    for _, l in ipairs(inner) do
      out[#out + 1] = l
    end
  elseif type(v) == "table" then
    out[#out + 1] = pad .. head .. " {}"
  elseif block(v) then
    local body = v:gsub("\n$", "")
    out[#out + 1] = pad .. head .. (body == v and " |-" or " |")
    for l in (body .. "\n"):gmatch("(.-)\n") do
      out[#out + 1] = l == "" and "" or (pad .. "  " .. l)
    end
  else
    out[#out + 1] = pad .. head .. " " .. scalar(v)
  end
end

emit = function(t, indent, out)
  local pad = string.rep(" ", indent)
  if is_list(t) then
    for _, v in ipairs(t) do
      entry(out, pad, "-", v, indent)
    end
    return
  end
  for _, k in ipairs(keys(t, indent == 0)) do
    entry(out, pad, scalar(k) .. ":", t[k], indent)
  end
end

--- Lines as rows `width` wide: a line that does not fit breaks at a space,
--- or mid-word when one word is wider than the room, and continues under
--- where its value starts (after `key: ` or `- `). A hang that would leave
--- less than half the width falls back to the line's indent plus two.
--- Each row is { text, first }, `first` on the row a line starts on.
---@param lines string[]
---@param width integer
---@return table[]
function M.wrap(lines, width)
  local out = {}
  for _, l in ipairs(lines) do
    local chars = {}
    for c in l:gmatch(utf8.charpattern) do
      chars[#chars + 1] = c
    end
    if #chars <= width then
      out[#out + 1] = { text = l, first = true }
    else
      local indent = #l:match("^%s*")
      local hang = #l:match("^[%s%-]*")
      local key = l:match('^[^%s:"]+: ', hang + 1)
      hang = hang + (key and #key or 0)
      -- No break inside the key, even when the hang falls back.
      local value_at = hang
      if width - hang < math.floor(width / 2) then
        hang = math.min(indent + 2, width - 1)
      end
      local pad = string.rep(" ", hang)
      local at, first = 1, true
      while at <= #chars do
        local room = first and width or width - hang
        local floor = first and value_at or 0
        local stop = at + room - 1
        if stop >= #chars then
          stop = #chars
        else
          -- The last space that still fits, or a space right at the edge.
          local cut = nil
          for i = math.min(stop + 1, #chars), at + floor, -1 do
            if chars[i] == " " then
              cut = i
              break
            end
          end
          if cut then
            stop = cut - 1
          end
        end
        out[#out + 1] = {
          text = (first and "" or pad) .. table.concat(chars, "", at, stop),
          first = first,
        }
        at, first = stop + 1, false
        while chars[at] == " " do
          at = at + 1
        end
      end
    end
  end
  return out
end

--- The lines of `value`, no trailing newline on any.
---@param value any
---@return string[]
function M.lines(value)
  local out = {}
  if type(value) == "table" and next(value) ~= nil then
    emit(value, 0, out)
  else
    entry(out, "", "", value, 0)
    out[1] = out[1]:sub(2)
  end
  return out
end

return M
