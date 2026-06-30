--- Small string helpers shared across adapters. All hand-written; no patterns.

local M = {}

--- Split `s` on runs of whitespace (space/tab), dropping empty fields.
---@param s string
---@return string[]
function M.split_ws(s)
  local parts = {}
  local buf = {}
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == " " or c == "\t" then
      if #buf > 0 then
        parts[#parts + 1] = table.concat(buf)
        buf = {}
      end
    else
      buf[#buf + 1] = c
    end
  end
  if #buf > 0 then
    parts[#parts + 1] = table.concat(buf)
  end
  return parts
end

--- Trim leading/trailing whitespace (space, tab, CR, LF) from `s`.
---@param s string
---@return string
function M.trim(s)
  local a = 1
  local b = #s
  while a <= b do
    local c = s:sub(a, a)
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      a = a + 1
    else
      break
    end
  end
  while b >= a do
    local c = s:sub(b, b)
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      b = b - 1
    else
      break
    end
  end
  return s:sub(a, b)
end

--- Does `s` start with `prefix`?
---@param s string
---@param prefix string
---@return boolean
function M.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

--- Does `s` end with `suffix`?
---@param s string
---@param suffix string
---@return boolean
function M.ends_with(s, suffix)
  if #suffix == 0 then
    return true
  end
  return s:sub(-#suffix) == suffix
end

--- Find the last index of byte `ch` in `s`, or nil. (Plain search, no pattern.)
---@param s string
---@param ch string  # single character
---@return integer?
function M.last_index_of(s, ch)
  for i = #s, 1, -1 do
    if s:sub(i, i) == ch then
      return i
    end
  end
  return nil
end

--- Classify a package source URL/string into a coarse origin category, used by
--- suspicious-change analysis. Returns one of:
--- "registry" | "git" | "path" | "url" | "unknown".
---@param source string?
---@return string
function M.source_kind(source)
  if not source or source == "" then
    return "path" -- a package with no source is typically a local/workspace member
  end
  local s = source
  -- Cargo-style "registry+https://..." / "git+https://..." prefixes.
  if M.starts_with(s, "registry+") then
    return "registry"
  elseif M.starts_with(s, "git+") then
    return "git"
  elseif M.starts_with(s, "git://") then
    return "git"
  end
  if M.starts_with(s, "https://") or M.starts_with(s, "http://") then
    -- Heuristic: well-known registries vs arbitrary URLs.
    local registries = {
      "registry.npmjs.org",
      "registry.yarnpkg.com",
      "pypi.org",
      "files.pythonhosted.org",
      "crates.io",
      "proxy.golang.org",
    }
    for _, host in ipairs(registries) do
      if s:find(host, 1, true) then
        return "registry"
      end
    end
    -- a tarball/git over http that isn't a known registry
    if M.ends_with(s, ".git") or s:find("github.com", 1, true) or s:find("gitlab.com", 1, true) then
      return "git"
    end
    return "url"
  end
  if M.starts_with(s, "file:") or M.starts_with(s, ".") or M.starts_with(s, "/") or M.starts_with(s, "link:") then
    return "path"
  end
  return "unknown"
end

return M
