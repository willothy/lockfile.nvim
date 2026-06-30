--- Source-origin classification used by suspicious-change analysis.

local M = {}

--- Does `s` start with `prefix`?
---@param s string
---@param prefix string
---@return boolean
local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

--- Does `s` end with `suffix`?
---@param s string
---@param suffix string
---@return boolean
local function ends_with(s, suffix)
  if #suffix == 0 then
    return true
  end
  return s:sub(-#suffix) == suffix
end

--- Well-known package registry hosts. A source served from one of these is
--- considered a normal registry download.
local REGISTRIES = {
  "registry.npmjs.org",
  "registry.yarnpkg.com",
  "pypi.org",
  "files.pythonhosted.org",
  "crates.io",
  "proxy.golang.org",
}

--- Classify a package source URL/string into a coarse origin category, used to
--- flag suspicious origin changes. Returns one of:
--- "registry" | "git" | "path" | "url" | "unknown".
---@param source string?
---@return string
function M.source_kind(source)
  if not source or source == "" then
    -- A package with no source is typically a local/workspace member.
    return "path"
  end
  local s = source

  -- Cargo-style "registry+https://..." / "git+https://..." prefixes.
  if starts_with(s, "registry+") then
    return "registry"
  elseif starts_with(s, "git+") or starts_with(s, "git://") then
    return "git"
  end

  if starts_with(s, "https://") or starts_with(s, "http://") then
    for _, host in ipairs(REGISTRIES) do
      if s:find(host, 1, true) then
        return "registry"
      end
    end
    if ends_with(s, ".git") or s:find("github.com", 1, true) or s:find("gitlab.com", 1, true) then
      return "git"
    end
    return "url"
  end

  if
    starts_with(s, "file:")
    or starts_with(s, "link:")
    or starts_with(s, ".")
    or starts_with(s, "/")
  then
    return "path"
  end

  return "unknown"
end

return M
