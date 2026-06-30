--- package-lock.json / npm-shrinkwrap.json -> normalized model.
---
--- Supports lockfileVersion 2/3 (the `packages` map keyed by install path) and
--- falls back to the legacy v1 `dependencies` tree. Dependency edges in npm are
--- semver *ranges*, not resolved versions, so edges carry only a name and are
--- resolved against the installed set by name during analysis.

local json = require("lockfile.parse.json")
local model = require("lockfile.model")

local M = {}

local NODE_MODULES = "node_modules/"

--- Derive a package name from a `packages` install path key.
--- "node_modules/a/node_modules/@s/b" -> "@s/b". Returns nil for the root "".
---@param path string
---@return string?
local function name_from_path(path)
  if path == "" then
    return nil
  end
  local idx
  local start = 1
  while true do
    local f = path:find(NODE_MODULES, start, true)
    if not f then
      break
    end
    idx = f
    start = f + 1
  end
  if idx then
    return path:sub(idx + #NODE_MODULES)
  end
  -- A path without node_modules is a local workspace package.
  return nil
end

--- Append dependency edges (by name) from an npm dependency-spec map.
---@param map any
---@param out lockfile.Dep[]
local function collect_edges(map, out)
  if type(map) ~= "table" then
    return
  end
  for name in pairs(map) do
    if type(name) == "string" then
      out[#out + 1] = { name = name }
    end
  end
end

--- Build from a lockfileVersion 2/3 `packages` map.
---@param lf lockfile.Lockfile
---@param packages table
local function build_v3(lf, packages)
  local root_names = {}

  for path, entry in pairs(packages) do
    if type(path) == "string" and type(entry) == "table" then
      if path == "" then
        -- The project root: its declared deps are the direct dependencies.
        collect_edges(entry.dependencies, root_names)
        collect_edges(entry.devDependencies, root_names)
        collect_edges(entry.optionalDependencies, root_names)
      else
        local name = name_from_path(path)
        if name == nil and type(entry.name) == "string" then
          -- workspace package addressed by directory path
          name = entry.name
        end
        if name and type(entry.version) == "string" then
          local deps = {}
          collect_edges(entry.dependencies, deps)
          collect_edges(entry.optionalDependencies, deps)
          local pkg = lf:add({
            name = name,
            version = entry.version,
            source = entry.resolved,
            checksum = entry.integrity,
            deps = deps,
            dev = entry.dev == true,
            optional = entry.optional == true,
          })
          -- workspace packages (path without node_modules) are roots
          if name_from_path(path) == nil then
            lf:add_root(pkg.id)
          end
        end
      end
    end
  end

  -- Resolve declared root names to concrete installed package ids.
  for _, dep in ipairs(root_names) do
    local list = lf.by_name[dep.name]
    if list and list[1] then
      lf:add_root(list[1].id)
    end
  end
end

--- Recursively build from a legacy v1 `dependencies` tree.
---@param lf lockfile.Lockfile
---@param deps table
---@param roots boolean   # whether this level's entries are project roots
local function build_v1(lf, deps, roots)
  for name, entry in pairs(deps) do
    if type(name) == "string" and type(entry) == "table" and type(entry.version) == "string" then
      local edges = {}
      collect_edges(entry.requires, edges)
      local pkg = lf:add({
        name = name,
        version = entry.version,
        source = entry.resolved,
        checksum = entry.integrity,
        deps = edges,
        dev = entry.dev == true,
        optional = entry.optional == true,
      })
      if roots then
        lf:add_root(pkg.id)
      end
      if type(entry.dependencies) == "table" then
        build_v1(lf, entry.dependencies, false)
      end
    end
  end
end

--- Build a normalized lockfile from package-lock.json source text.
---@param src string
---@return lockfile.Lockfile
function M.build(src)
  local data = json.parse(src)
  local lf = model.new("npm")
  if type(data) ~= "table" then
    return lf
  end
  if data.lockfileVersion ~= nil then
    lf.format_version = tostring(data.lockfileVersion)
  end

  if type(data.packages) == "table" then
    build_v3(lf, data.packages)
  elseif type(data.dependencies) == "table" then
    build_v1(lf, data.dependencies, true)
  end

  return lf
end

return M
