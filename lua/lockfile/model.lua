--- The normalized data model that every lockfile format is translated into.
---
--- All ecosystem-specific parsers produce a `lockfile.Lockfile`. Everything
--- downstream (diffing, dependency-graph analysis, suspicious-change detection,
--- rendering) operates only on this model, so adding a new format never touches
--- the rest of the plugin.

local M = {}

---@class lockfile.Dep
--- A directed dependency edge expressed by the *source* lockfile. `version` is
--- populated when the format pins the exact resolved version of the edge
--- (Cargo does this); otherwise only `name` is known and the edge is resolved
--- by name during analysis.
---@field name string
---@field version string?
---@field optional boolean?
---@field dev boolean?

---@class lockfile.Package
---@field id string            # canonical key, "name@version"
---@field name string
---@field version string
---@field source string?       # registry url, git url, path, ...
---@field checksum string?     # integrity hash / checksum, if the format records one
---@field deps lockfile.Dep[]  # outgoing dependency edges
---@field optional boolean?    # whether the package is wholly optional
---@field dev boolean?         # whether the package is dev-only

---@class lockfile.Lockfile
---@field type string                              # "cargo" | "pnpm" | ...
---@field format_version string?                   # lockfile schema version, if present
---@field packages lockfile.Package[]              # all packages, insertion order
---@field by_id table<string, lockfile.Package>    # id -> package
---@field by_name table<string, lockfile.Package[]># name -> packages (multiple versions possible)
---@field roots string[]                           # ids (or names) of direct project deps
---@field supports_graph boolean                   # whether dependency edges are meaningful
local Lockfile = {}
Lockfile.__index = Lockfile

--- Canonical id for a (name, version) pair.
---@param name string
---@param version string
---@return string
function M.make_id(name, version)
  return name .. "@" .. version
end

--- Create an empty lockfile of the given type.
---@param type string
---@return lockfile.Lockfile
function M.new(type)
  return setmetatable({
    type = type,
    format_version = nil,
    packages = {},
    by_id = {},
    by_name = {},
    roots = {},
    supports_graph = true,
  }, Lockfile)
end

--- Add a package to the lockfile, maintaining the id/name indexes.
---
--- If a package with the same id already exists, dependency edges are merged
--- rather than producing a duplicate (some formats list a package more than
--- once across sections).
---@param pkg lockfile.Package
---@return lockfile.Package  # the stored package (may be a pre-existing one)
function Lockfile:add(pkg)
  if not pkg.id then
    pkg.id = M.make_id(pkg.name, pkg.version)
  end
  pkg.deps = pkg.deps or {}

  local existing = self.by_id[pkg.id]
  if existing then
    -- Merge dependency edges, de-duplicating by (name, version).
    local seen = {}
    for _, d in ipairs(existing.deps) do
      seen[d.name .. "\0" .. (d.version or "")] = true
    end
    for _, d in ipairs(pkg.deps) do
      local key = d.name .. "\0" .. (d.version or "")
      if not seen[key] then
        seen[key] = true
        table.insert(existing.deps, d)
      end
    end
    existing.source = existing.source or pkg.source
    existing.checksum = existing.checksum or pkg.checksum
    return existing
  end

  self.by_id[pkg.id] = pkg
  local list = self.by_name[pkg.name]
  if not list then
    list = {}
    self.by_name[pkg.name] = list
  end
  table.insert(list, pkg)
  table.insert(self.packages, pkg)
  return pkg
end

--- Mark a package id (or name) as a project root / direct dependency.
---@param id string
function Lockfile:add_root(id)
  table.insert(self.roots, id)
end

--- Resolve a dependency edge to a concrete package. Prefers an exact id match
--- (name@version) and falls back to the first package with a matching name.
---@param dep lockfile.Dep
---@return lockfile.Package?
function Lockfile:resolve(dep)
  if dep.version then
    local exact = self.by_id[M.make_id(dep.name, dep.version)]
    if exact then
      return exact
    end
  end
  local list = self.by_name[dep.name]
  if list and list[1] then
    return list[1]
  end
  return nil
end

M.Lockfile = Lockfile

return M
