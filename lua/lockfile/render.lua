--- Render a diff report into display lines.
---
--- This module is pure: it turns a `lockfile.Report` into a list of
--- `lockfile.RenderLine`s (text + highlight segments + a fold expression). The
--- UI layer is responsible for putting these into a buffer and wiring folds and
--- keymaps. Keeping rendering pure makes the layout testable without a window.

local M = {}

---@class lockfile.HlSegment
---@field group string
---@field from integer  # 0-based byte column, inclusive
---@field to integer    # 0-based byte column, exclusive

---@class lockfile.RenderLine
---@field text string
---@field hls lockfile.HlSegment[]
---@field fold string   # value for 'foldexpr' on this line ("0", ">1", ">2", "3")

--- A small builder for assembling one line with highlighted segments.
---@class lockfile.LineBuilder
---@field text string
---@field hls lockfile.HlSegment[]
---@field fold string
local Line = {}
Line.__index = Line

--- Start a new line with the given fold expression.
---@param fold string
---@return lockfile.LineBuilder
local function line(fold)
  return setmetatable({ text = "", hls = {}, fold = fold }, Line)
end

--- Append `text`, optionally highlighted with `group`.
---@param text string
---@param group string?
---@return lockfile.LineBuilder
function Line:put(text, group)
  local from = #self.text
  self.text = self.text .. text
  if group and text ~= "" then
    self.hls[#self.hls + 1] = { group = group, from = from, to = #self.text }
  end
  return self
end

--- Icon for a change kind.
---@param kind string
---@param icons lockfile.Icons
---@return string
local function kind_icon(kind, icons)
  if kind == "added" then
    return icons.added
  elseif kind == "removed" then
    return icons.removed
  else
    return icons.updated
  end
end

--- Highlight group for a change kind.
---@param kind string
---@return string
local function kind_hl(kind)
  if kind == "added" then
    return "LockfileAdded"
  elseif kind == "removed" then
    return "LockfileRemoved"
  else
    return "LockfileUpdated"
  end
end

--- Join a version list for display.
---@param versions string[]
---@return string
local function join_versions(versions)
  return table.concat(versions, ", ")
end

--- Build the version fragment shown on a change's summary line.
---@param builder lockfile.LineBuilder
---@param change lockfile.Change
local function put_versions(builder, change)
  if change.kind == "added" then
    builder:put(join_versions(change.new_versions), "LockfileVersion")
  elseif change.kind == "removed" then
    builder:put(join_versions(change.old_versions), "LockfileVersionOld")
  else
    builder:put(join_versions(change.old_versions), "LockfileVersionOld")
    builder:put(" → ", "LockfileMuted")
    builder:put(join_versions(change.new_versions), "LockfileVersion")
  end
end

--- Truncate a string to `max` display columns, adding an ellipsis.
---@param s string
---@param max integer
---@return string
local function truncate(s, max)
  if #s <= max then
    return s
  end
  return s:sub(1, max - 1) .. "…"
end

--- Append the detail lines (flags, reason, source) for a change.
---@param out lockfile.RenderLine[]
---@param change lockfile.Change
---@param report lockfile.Report
local function detail_lines(out, change, report)
  -- Suspicious flags.
  for _, flag in ipairs(change.flags) do
    local hl = flag.severity == "high" and "LockfileSuspicious" or "LockfileMajor"
    local l = line("3")
    l:put("      ", nil)
    l:put("⚠ ", hl)
    l:put(flag.message, hl)
    out[#out + 1] = l
  end

  -- Transitive reason ("why is this here"). Suppressed for formats that record
  -- no dependency graph (e.g. go.sum), where every package would otherwise look
  -- like a direct dependency.
  if report.new.supports_graph then
    local l = line("3")
    l:put("      ", nil)
    if change.reason_path and #change.reason_path > 0 then
      if #change.reason_path == 1 then
        l:put("direct dependency", "LockfileReason")
      else
        l:put("why: ", "LockfileReason")
        l:put(table.concat(change.reason_path, " → "), "LockfileReason")
      end
    elseif change.dependents and #change.dependents > 0 then
      l:put("required by: ", "LockfileReason")
      l:put(truncate(table.concat(change.dependents, ", "), 80), "LockfileReason")
    else
      l:put("direct dependency", "LockfileReason")
    end
    out[#out + 1] = l
  end

  -- Source, shown for added packages and origin changes.
  local pkg = change.new or change.old
  local show_source = change.kind == "added"
  for _, f in ipairs(change.flags) do
    if f.kind == "source_change" or f.kind == "new_source" then
      show_source = true
    end
  end
  if show_source and pkg and pkg.source and pkg.source ~= "" then
    local sl = line("3")
    sl:put("      ", nil)
    sl:put("source: ", "LockfileMuted")
    sl:put(truncate(pkg.source, 100), "LockfileSource")
    out[#out + 1] = sl
  end
end

--- Append one change (summary line + details).
---@param out lockfile.RenderLine[]
---@param change lockfile.Change
---@param report lockfile.Report
---@param icons lockfile.Icons
local function change_lines(out, change, report, icons)
  local summary = line(">2")
  summary:put("  ", nil)
  summary:put(kind_icon(change.kind, icons) .. " ", kind_hl(change.kind))
  summary:put(change.name, "LockfileName")
  summary:put("  ", nil)
  put_versions(summary, change)
  out[#out + 1] = summary
  detail_lines(out, change, report)
end

--- Append a section (header + its changes) if non-empty.
---@param out lockfile.RenderLine[]
---@param title string
---@param changes lockfile.Change[]
---@param report lockfile.Report
---@param icons lockfile.Icons
local function section(out, title, changes, report, icons)
  if #changes == 0 then
    return
  end
  local header = line(">1")
  header:put(("%s (%d)"):format(title, #changes), "LockfileSection")
  out[#out + 1] = header
  for _, change in ipairs(changes) do
    change_lines(out, change, report, icons)
  end
end

--- Render a report into display lines.
---@param report lockfile.Report
---@param opts { old_label: string, new_label: string }
---@return lockfile.RenderLine[]
function M.render(report, opts)
  local config = require("lockfile.config")
  local icons = config.options.icons
  local detect = require("lockfile.detect")

  ---@type lockfile.RenderLine[]
  local out = {}

  -- Title.
  local title = line("0")
  title:put(detect.label(report.type), "LockfileHeader")
  title:put("   ", nil)
  title:put(opts.old_label, "LockfileMuted")
  title:put(" → ", "LockfileMuted")
  title:put(opts.new_label, "LockfileMuted")
  out[#out + 1] = title

  -- Summary counts.
  local s = report.summary
  local sum = line("0")
  sum:put(("%s %d added"):format(icons.added, s.added), "LockfileAdded")
  sum:put("   ", nil)
  sum:put(("%s %d removed"):format(icons.removed, s.removed), "LockfileRemoved")
  sum:put("   ", nil)
  sum:put(("%s %d updated"):format(icons.updated, s.updated), "LockfileUpdated")
  if s.suspicious > 0 then
    sum:put("   ", nil)
    sum:put(("%s %d suspicious"):format(icons.suspicious, s.suspicious), "LockfileSuspicious")
  end
  out[#out + 1] = sum

  out[#out + 1] = line("0")

  if #report.changes == 0 then
    local none = line("0")
    none:put("No changes.", "LockfileMuted")
    out[#out + 1] = none
    return out
  end

  -- Partition: suspicious first, then by kind.
  local suspicious, updated, added, removed = {}, {}, {}, {}
  for _, c in ipairs(report.changes) do
    if #c.flags > 0 then
      suspicious[#suspicious + 1] = c
    elseif c.kind == "updated" then
      updated[#updated + 1] = c
    elseif c.kind == "added" then
      added[#added + 1] = c
    else
      removed[#removed + 1] = c
    end
  end

  section(out, icons.suspicious .. " Suspicious changes", suspicious, report, icons)
  section(out, icons.updated .. " Updated", updated, report, icons)
  section(out, icons.added .. " Added", added, report, icons)
  section(out, icons.removed .. " Removed", removed, report, icons)

  return out
end

return M
