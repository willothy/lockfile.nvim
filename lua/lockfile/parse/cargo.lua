--- Cargo.lock -> normalized model.
---
--- Cargo.lock is TOML with an array of `[[package]]` tables. Dependency edges
--- are listed as strings of the form "name", "name version", or
--- "name version (source)". Checksums live either on the package (modern) or in
--- a `[metadata]` table keyed "checksum name version (source)" (lockfile v1/v2).

local toml = require("lockfile.parse.toml")
local model = require("lockfile.model")
local util = require("lockfile.util")

local M = {}

--- Parse a Cargo dependency string into a dependency edge.
---@param s string
---@return lockfile.Dep
local function parse_dep(s)
  local parts = util.split_ws(s)
  local dep = { name = parts[1] }
  -- A version is the second token unless it is the "(source)" part.
  if parts[2] and parts[2]:sub(1, 1) ~= "(" then
    dep.version = parts[2]
  end
  return dep
end

--- Build a normalized lockfile from Cargo.lock source text.
---@param src string
---@return lockfile.Lockfile
function M.build(src)
  local data = toml.parse(src)
  local lf = model.new("cargo")
  if data.version ~= nil then
    lf.format_version = tostring(data.version)
  end

  -- Collect checksums stored in the legacy [metadata] table.
  local meta_checksums = {}
  if type(data.metadata) == "table" then
    for k, v in pairs(data.metadata) do
      if type(k) == "string" and util.starts_with(k, "checksum ") then
        local rest = k:sub(#"checksum " + 1)
        local parts = util.split_ws(rest)
        if parts[1] and parts[2] then
          meta_checksums[model.make_id(parts[1], parts[2])] = v
        end
      end
    end
  end

  local packages = data.package
  if type(packages) == "table" then
    for _, p in ipairs(packages) do
      if type(p) == "table" and p.name and p.version then
        local deps = {}
        if type(p.dependencies) == "table" then
          for _, d in ipairs(p.dependencies) do
            if type(d) == "string" then
              deps[#deps + 1] = parse_dep(d)
            end
          end
        end
        local checksum = p.checksum or meta_checksums[model.make_id(p.name, p.version)]
        local pkg = lf:add({
          name = p.name,
          version = tostring(p.version),
          source = p.source,
          checksum = checksum,
          deps = deps,
        })
        -- Workspace / local crates have no `source`; treat them as roots.
        if not p.source then
          lf:add_root(pkg.id)
        end
      end
    end
  end

  return lf
end

return M
