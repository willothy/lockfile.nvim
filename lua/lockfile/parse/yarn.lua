--- yarn.lock -> normalized model.
---
--- Two on-disk formats share this filename:
---   * Yarn Classic (v1): a bespoke indentation format ("name@range":\n  version
---     "x"\n  dependencies:\n    dep "range"). Parsed by hand below.
---   * Yarn Berry (v2+): valid YAML with a `__metadata` block. Parsed via the
---     YAML parser.

local yaml = require("lockfile.parse.yaml")
local model = require("lockfile.model")
local util = require("lockfile.util")

local M = {}

--- Extract the package name from a descriptor like "name@range",
--- "@scope/name@range", or Berry's "name@npm:range".
---@param descriptor string
---@return string
local function name_from_descriptor(descriptor)
  local s = util.trim(descriptor)
  -- strip surrounding quotes
  if (s:sub(1, 1) == '"' and s:sub(-1) == '"') or (s:sub(1, 1) == "'" and s:sub(-1) == "'") then
    s = s:sub(2, -2)
  end
  -- name is everything before the last '@' that is past a leading scope '@'.
  for i = #s, 2, -1 do
    if s:sub(i, i) == "@" then
      return s:sub(1, i - 1)
    end
  end
  return s
end

--- Strip surrounding double/single quotes from a value, if present.
---@param s string
---@return string
local function unquote(s)
  s = util.trim(s)
  if #s >= 2 and ((s:sub(1, 1) == '"' and s:sub(-1) == '"') or (s:sub(1, 1) == "'" and s:sub(-1) == "'")) then
    return s:sub(2, -2)
  end
  return s
end

--- Split a Yarn Classic header line into individual descriptors. Descriptors
--- are separated by ", "; quoted descriptors are handled so commas inside
--- (rare) are not split points.
---@param header string
---@return string[]
local function split_descriptors(header)
  local out = {}
  local buf = {}
  local in_quote = nil ---@type string?
  local i = 1
  while i <= #header do
    local c = header:sub(i, i)
    if in_quote then
      buf[#buf + 1] = c
      if c == in_quote then
        in_quote = nil
      end
    elseif c == '"' or c == "'" then
      in_quote = c
      buf[#buf + 1] = c
    elseif c == "," then
      -- consume following space(s)
      out[#out + 1] = util.trim(table.concat(buf))
      buf = {}
      while i + 1 <= #header and header:sub(i + 1, i + 1) == " " do
        i = i + 1
      end
    else
      buf[#buf + 1] = c
    end
    i = i + 1
  end
  if #buf > 0 then
    out[#out + 1] = util.trim(table.concat(buf))
  end
  return out
end

--- Build logical (indent, content) lines, dropping comments and blank lines.
---@param src string
---@return {indent: integer, content: string}[]
local function logical_lines(src)
  local lines = {}
  local start = 1
  local len = #src
  for i = 1, len + 1 do
    local c = (i <= len) and src:sub(i, i) or "\n"
    if c == "\n" then
      local raw = src:sub(start, i - 1)
      if raw:sub(-1) == "\r" then
        raw = raw:sub(1, -2)
      end
      local indent = 0
      while indent < #raw and raw:sub(indent + 1, indent + 1) == " " do
        indent = indent + 1
      end
      local content = util.trim(raw:sub(indent + 1))
      if content ~= "" and content:sub(1, 1) ~= "#" then
        lines[#lines + 1] = { indent = indent, content = content }
      end
      start = i + 1
    end
  end
  return lines
end

--- Split a field line "key value" into key and (unquoted) value.
---@param content string
---@return string key
---@return string value
local function split_field(content)
  local sp = content:find(" ", 1, true)
  if not sp then
    return content, ""
  end
  return content:sub(1, sp - 1), unquote(content:sub(sp + 1))
end

--- Parse Yarn Classic (v1) format.
---@param src string
---@return lockfile.Lockfile
local function build_classic(src)
  local lf = model.new("yarn")
  lf.format_version = "1"
  local lines = logical_lines(src)
  local n = #lines
  local i = 1
  while i <= n do
    local line = lines[i]
    if line.indent == 0 then
      -- header: descriptors..., trailing ':'
      local header = line.content
      if header:sub(-1) == ":" then
        header = header:sub(1, -2)
      end
      local descriptors = split_descriptors(header)
      i = i + 1

      local version, resolved, integrity
      local deps = {}
      while i <= n and lines[i].indent > 0 do
        local f = lines[i]
        if f.content:sub(-1) == ":" then
          -- sub-block, e.g. dependencies:
          local block_key = util.trim(f.content:sub(1, -2))
          local block_indent = f.indent
          i = i + 1
          while i <= n and lines[i].indent > block_indent do
            if block_key == "dependencies" or block_key == "optionalDependencies" then
              local dep_name = unquote((split_field(lines[i].content)))
              if dep_name ~= "" then
                deps[#deps + 1] = { name = dep_name }
              end
            end
            i = i + 1
          end
        else
          local key, value = split_field(f.content)
          if key == "version" then
            version = value
          elseif key == "resolved" then
            resolved = value
          elseif key == "integrity" then
            integrity = value
          end
          i = i + 1
        end
      end

      if version and descriptors[1] then
        local name = name_from_descriptor(descriptors[1])
        lf:add({
          name = name,
          version = version,
          source = resolved,
          checksum = integrity,
          deps = deps,
        })
      end
    else
      i = i + 1
    end
  end
  return lf
end

--- Parse Yarn Berry (v2+) YAML format.
---@param src string
---@return lockfile.Lockfile
local function build_berry(src)
  local data = yaml.parse(src)
  local lf = model.new("yarn")
  if type(data) ~= "table" then
    return lf
  end
  if type(data.__metadata) == "table" and data.__metadata.version ~= nil then
    lf.format_version = tostring(data.__metadata.version)
  end

  for key, entry in pairs(data) do
    if key ~= "__metadata" and type(key) == "string" and type(entry) == "table" then
      local version = entry.version
      if version ~= nil and version ~= yaml.NULL then
        local first = split_descriptors(key)[1] or key
        local name = name_from_descriptor(first)
        local deps = {}
        if type(entry.dependencies) == "table" then
          for dname in pairs(entry.dependencies) do
            if type(dname) == "string" then
              deps[#deps + 1] = { name = dname }
            end
          end
        end
        local source
        if type(entry.resolution) == "string" then
          source = entry.resolution
        end
        local checksum
        if type(entry.checksum) == "string" then
          checksum = entry.checksum
        end
        lf:add({
          name = name,
          version = tostring(version),
          source = source,
          checksum = checksum,
          deps = deps,
        })
      end
    end
  end
  return lf
end

--- Build a normalized lockfile from yarn.lock source text, auto-detecting the
--- Classic vs Berry format.
---@param src string
---@return lockfile.Lockfile
function M.build(src)
  -- Berry lockfiles always contain a `__metadata` block and are valid YAML.
  if src:find("__metadata", 1, true) then
    return build_berry(src)
  end
  return build_classic(src)
end

return M
