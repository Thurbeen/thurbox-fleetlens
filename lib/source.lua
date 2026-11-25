-- Reading Fleet: the command a run executes, and what its answer means.
--
-- Pure: no `run`, no `thurbox`, no `state`. The pane asks; this module only
-- builds the command and classifies the answer, so every row of the error-state
-- table is a unit test rather than something seen once on a screen.
--
-- An answer is one of:
--   { kind = "pending" }                       nothing yet
--   { kind = "ok", value = <decoded>, now = s }  status 0 and valid JSON
--   { kind = "error", title = ..., detail = ... } anything else
-- An error never carries rows. The caller keeps the last ok answer and draws it
-- stale, which is how "unreadable" stays distinct from "empty".

local json = require("thurbox-fleetlens.lib.json")

local M = {}

-- Fleet's exit codes (`fleet-cli/src/main.rs`, `mod exit`).
M.EXIT = { error = 1, not_found = 3, unknown = 4, conflict = 5, lease = 6 }

--- One POSIX shell word.
---@param s string
---@return string
function M.quote(s)
  if s:match("^[%w%._/:=%-]+$") then
    return s
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function fleet_words(settings, args)
  local words = { M.quote(settings.bin ~= "" and settings.bin or "fleet") }
  if settings.config and settings.config ~= "" then
    words[#words + 1] = "--config"
    words[#words + 1] = M.quote(settings.config)
  end
  for _, arg in ipairs(args) do
    words[#words + 1] = M.quote(arg)
  end
  return table.concat(words, " ")
end

--- The shell command for one fleet call.
---
--- `date +%s` comes first because the mod VM has no clock, and an age needs
--- one. `exec` hands the exit status to fleet, which is the status classified.
---@param settings { bin: string, config: string }
---@param args string[]
---@return string
function M.command(settings, args)
  return "date +%s; exec " .. fleet_words(settings, args)
end

M.LIST_FIELDS = {
  "phase",
  "conditions",
  "observedGeneration",
  "session",
  "sessionState",
  "agentState",
  "brief",
  "result",
  "declared",
  "answered",
  "configRef",
  "envFrom",
  "url",
}

-- Reads fleet's pretty-printed JSON, one value per line at two spaces a level:
-- a resource's spec and status members sit at indent 6, and no string spans a
-- line, so a line can be dropped or shortened without parsing the JSON.
local TRIM = [[
{
  match($0, /^ */)
  ind = RLENGTH
  line = substr($0, ind + 1)
  if (skip) {
    if (ind == 6 && line ~ /^[]}]/) skip = 0
    next
  }
  if (ind == 4) section = line
  if (ind == 6 && line ~ /^"/ && section ~ /^"(spec|status)"/) {
    key = line
    sub(/^"/, "", key)
    sub(/".*/, "", key)
    if (index(keep, " " key " ") == 0) {
      if (line ~ /[[{]$/) skip = 1
      next
    }
  }
  if (length(line) > 240) sub(/"(\\.|[^"\\])*",?$/, "\"…\"", line)
  sub(/,$/, "", line)
  if (have) printf "%s%s", prev, (line ~ /^[]}]/ || prev ~ /[[{]$/) ? "" : ","
  prev = line
  have = 1
}
END { if (have) print prev }
]]

--- The shell command listing one kind, trimmed on the host to the fields
--- `LIST_FIELDS` names and with long strings dropped, so a long list fits one
--- run's 256 KiB. The exit status is still fleet's.
---@param settings { bin: string, config: string }
---@param kind string
---@return string
function M.list_command(settings, kind)
  return "date +%s; out=$("
    .. fleet_words(settings, { "list", kind:lower(), "--json" })
    .. "); s=$?; printf '%s\\n' \"$out\" | awk -v keep="
    .. M.quote(" " .. table.concat(M.LIST_FIELDS, " ") .. " ")
    .. " "
    .. M.quote(TRIM)
    .. "; exit $s"
end

--- The first stderr line fleet wrote, without its `error: ` prefix.
local function reason(stderr)
  local line = (stderr or ""):match("([^\n]+)") or ""
  return (line:gsub("^error:%s*", ""))
end

--- Classify one `thurbox.runs` entry.
---@param got table|nil
---@param machine string where it ran, for the message
---@return table
function M.classify(got, machine)
  if got == nil or got.state == "pending" then
    return { kind = "pending" }
  end
  if got.state == "failed" then
    return { kind = "error", title = "Cannot run fleet on " .. machine, detail = got.error or "" }
  end
  if got.timed_out then
    return { kind = "error", title = "fleet did not answer in time", detail = "" }
  end
  if got.truncated then
    return {
      kind = "error",
      title = "Answer over 256 KiB — not parsed",
      detail = "the list is too large for one run",
    }
  end
  local status = got.status
  -- The shell's own "command not found".
  if status == 127 then
    return {
      kind = "error",
      title = "fleet not found on " .. machine,
      detail = "set fleetlens.bin to its absolute path",
    }
  end
  if status == M.EXIT.unknown then
    return {
      kind = "error",
      title = "Store unreadable",
      detail = reason(got.stderr),
      unknown = true,
    }
  end
  if status == M.EXIT.not_found then
    return { kind = "error", title = "Gone", detail = reason(got.stderr), gone = true }
  end
  if status ~= 0 then
    local why = reason(got.stderr)
    if why:match("unknown kind") then
      return { kind = "error", title = "Kind no longer served", detail = why, unserved = true }
    end
    return { kind = "error", title = "fleet failed (exit " .. tostring(status) .. ")", detail = why }
  end
  local now, body = (got.stdout or ""):match("^(%d+)\n(.*)$")
  if not now then
    return { kind = "error", title = "Unreadable answer from fleet", detail = "no clock line" }
  end
  local ok, value = pcall(json.decode, body)
  if not ok then
    return { kind = "error", title = "Unreadable answer from fleet", detail = tostring(value) }
  end
  return { kind = "ok", value = value, now = tonumber(now) }
end

return M
