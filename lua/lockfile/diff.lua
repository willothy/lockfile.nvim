--- Diff two normalized lockfiles into a structured report.
---
--- Changes are computed per package *name*. A name may resolve to several
--- versions in one lockfile (common in Cargo/npm/pnpm), so each change carries
--- the full set of old and new versions plus a representative package on each
--- side for detailed display.

local version = require("lockfile.version")

local M = {}

---@class lockfile.Change
---@field kind "added"|"removed"|"updated"
---@field name string
---@field old_versions string[]        # descending
---@field new_versions string[]        # descending
---@field old lockfile.Package?        # representative old package
---@field new lockfile.Package?        # representative new package
---@field semver lockfile.VersionChange? # for "updated" changes
---@field flags lockfile.Flag[]        # filled in by analysis
---@field reason_path string[]?        # shortest root→package path, filled in by analysis
---@field dependents string[]?         # direct dependents, filled in by analysis

---@class lockfile.Report
---@field old lockfile.Lockfile
---@field new lockfile.Lockfile
---@field type string
---@field changes lockfile.Change[]
---@field summary lockfile.Summary

---@class lockfile.Summary
---@field added integer
---@field removed integer
---@field updated integer
---@field suspicious integer

--- Sorted (descending) list of versions present in a package list.
---@param pkgs lockfile.Package[]
---@param kind string  # lockfile format id, for the versioning scheme
---@return string[]
local function versions_of(pkgs, kind)
  local vs = {}
  for _, p in ipairs(pkgs) do
    vs[#vs + 1] = p.version
  end
  table.sort(vs, function(a, b)
    return version.compare(kind, a, b) > 0
  end)
  return vs
end

--- The package with the highest version in a list.
---@param pkgs lockfile.Package[]
---@param kind string
---@return lockfile.Package
local function highest(pkgs, kind)
  local best = pkgs[1]
  for i = 2, #pkgs do
    if version.compare(kind, pkgs[i].version, best.version) > 0 then
      best = pkgs[i]
    end
  end
  return best
end

--- Map version -> package for quick lookup.
---@param pkgs lockfile.Package[]
---@return table<string, lockfile.Package>
local function by_version(pkgs)
  local m = {}
  for _, p in ipairs(pkgs) do
    m[p.version] = p
  end
  return m
end

--- Whether two version lists describe the same set of versions.
---@param a string[]
---@param b string[]
---@return boolean
local function same_versions(a, b)
  if #a ~= #b then
    return false
  end
  local set = {}
  for _, v in ipairs(a) do
    set[v] = true
  end
  for _, v in ipairs(b) do
    if not set[v] then
      return false
    end
  end
  return true
end

--- Find a version present in both lists whose checksum differs between old and
--- new (the classic supply-chain tamper signal: same version, different hash).
---@param old_pkgs lockfile.Package[]
---@param new_pkgs lockfile.Package[]
---@return lockfile.Package? old
---@return lockfile.Package? new
local function checksum_conflict(old_pkgs, new_pkgs)
  local new_by_v = by_version(new_pkgs)
  for _, op in ipairs(old_pkgs) do
    local np = new_by_v[op.version]
    if np and op.checksum and np.checksum and op.checksum ~= np.checksum then
      return op, np
    end
  end
  return nil, nil
end

--- Compute the diff between two lockfiles.
---@param old lockfile.Lockfile
---@param new lockfile.Lockfile
---@return lockfile.Report
function M.diff(old, new)
  ---@type lockfile.Report
  local report = {
    old = old,
    new = new,
    type = new.type or old.type,
    changes = {},
    summary = { added = 0, removed = 0, updated = 0, suspicious = 0 },
  }
  local kind = report.type

  -- Union of all package names.
  local names = {}
  for name in pairs(old.by_name) do
    names[name] = true
  end
  for name in pairs(new.by_name) do
    names[name] = true
  end
  local namelist = {}
  for name in pairs(names) do
    namelist[#namelist + 1] = name
  end
  table.sort(namelist)

  for _, name in ipairs(namelist) do
    local op = old.by_name[name]
    local np = new.by_name[name]
    ---@type lockfile.Change?
    local change

    if not op then
      change = {
        kind = "added",
        name = name,
        old_versions = {},
        new_versions = versions_of(np, kind),
        new = highest(np, kind),
        flags = {},
      }
      report.summary.added = report.summary.added + 1
    elseif not np then
      change = {
        kind = "removed",
        name = name,
        old_versions = versions_of(op, kind),
        new_versions = {},
        old = highest(op, kind),
        flags = {},
      }
      report.summary.removed = report.summary.removed + 1
    else
      local ov = versions_of(op, kind)
      local nv = versions_of(np, kind)
      if same_versions(ov, nv) then
        -- Same versions: only a change if a checksum was tampered with.
        local oc, nc = checksum_conflict(op, np)
        if oc then
          change = {
            kind = "updated",
            name = name,
            old_versions = ov,
            new_versions = nv,
            old = oc,
            new = nc,
            semver = "none",
            flags = {},
          }
          report.summary.updated = report.summary.updated + 1
        end
      else
        local oh = highest(op, kind)
        local nh = highest(np, kind)
        -- Formats whose "version" is an opaque identifier (e.g. lazy-lock.json
        -- commit SHAs) are reported as "changed" rather than semver-classified.
        local sem = new.semver_versions == false and "changed"
          or version.classify(kind, oh.version, nh.version)
        change = {
          kind = "updated",
          name = name,
          old_versions = ov,
          new_versions = nv,
          old = oh,
          new = nh,
          semver = sem,
          flags = {},
        }
        report.summary.updated = report.summary.updated + 1
      end
    end

    if change then
      report.changes[#report.changes + 1] = change
    end
  end

  return report
end

return M
