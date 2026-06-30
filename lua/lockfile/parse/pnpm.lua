--- pnpm-lock.yaml -> normalized model.
---
--- Handles the major lockfile layouts pnpm has shipped:
---   * v9: package metadata in `packages`, dependency edges in `snapshots`,
---     keys formatted "name@version(peers)".
---   * v6: metadata and edges both in `packages`, keys "/name@version(peers)".
---   * v5: keys "/name/version".
--- Project direct dependencies come from `importers` (monorepo) or the
--- top-level `dependencies`/`devDependencies` (single package).

local yaml = require("lockfile.parse.yaml")
local model = require("lockfile.model")
local util = require("lockfile.util")

local M = {}

--- Remove a trailing pnpm peer-dependency suffix "(...)" from a key/version.
---@param s string
---@return string
local function strip_peers(s)
  local p = s:find("(", 1, true)
  if p then
    return s:sub(1, p - 1)
  end
  return s
end

--- Parse a pnpm package key into (name, version), tolerating all layouts.
---@param key string
---@return string name
---@return string version
local function parse_key(key)
  local s = key
  if s:sub(1, 1) == "/" then
    s = s:sub(2)
  end
  s = strip_peers(s)
  -- Prefer "name@version": the last '@' at a position past a leading scope '@'.
  for i = #s, 2, -1 do
    if s:sub(i, i) == "@" then
      return s:sub(1, i - 1), s:sub(i + 1)
    end
  end
  -- Fall back to v5 "name/version".
  local sl = util.last_index_of(s, "/")
  if sl then
    return s:sub(1, sl - 1), s:sub(sl + 1)
  end
  return s, ""
end

--- Convert a pnpm dependency map { name = versionspec } into dependency edges.
---@param map any
---@param out lockfile.Dep[]
local function collect_deps(map, out)
  if type(map) ~= "table" then
    return
  end
  for name, ver in pairs(map) do
    if type(name) == "string" and name ~= "" then
      local dep = { name = name }
      if type(ver) == "string" then
        dep.version = strip_peers(ver)
      end
      out[#out + 1] = dep
    end
  end
end

--- Resolve the integrity hash from a pnpm `resolution` field.
---@param resolution any
---@return string?
local function integrity_of(resolution)
  if type(resolution) == "table" and type(resolution.integrity) == "string" then
    return resolution.integrity
  end
  return nil
end

--- Register the direct dependencies declared by an importer block as roots.
---@param lf lockfile.Lockfile
---@param block any
local function add_roots_from(lf, block)
  if type(block) ~= "table" then
    return
  end
  for _, field in ipairs({ "dependencies", "devDependencies", "optionalDependencies" }) do
    local deps = block[field]
    if type(deps) == "table" then
      for name, spec in pairs(deps) do
        if type(name) == "string" then
          local version
          if type(spec) == "table" and type(spec.version) == "string" then
            version = strip_peers(spec.version)
          elseif type(spec) == "string" then
            version = strip_peers(spec)
          end
          if version and version ~= "" then
            lf:add_root(model.make_id(name, version))
          end
        end
      end
    end
  end
end

--- Build a normalized lockfile from pnpm-lock.yaml source text.
---@param src string
---@return lockfile.Lockfile
function M.build(src)
  local data = yaml.parse(src)
  local lf = model.new("pnpm")
  if type(data) ~= "table" then
    return lf
  end
  if data.lockfileVersion ~= nil and data.lockfileVersion ~= yaml.NULL then
    lf.format_version = tostring(data.lockfileVersion)
  end

  -- Dependency edges live in `snapshots` (v9) or inline in `packages` (v6/v5).
  local edge_source = (type(data.snapshots) == "table") and data.snapshots or data.packages

  -- Pass 1: package metadata.
  if type(data.packages) == "table" then
    for key, meta in pairs(data.packages) do
      if type(key) == "string" then
        local name, version = parse_key(key)
        if name ~= "" then
          local checksum, dev
          local deps = {}
          if type(meta) == "table" then
            checksum = integrity_of(meta.resolution)
            dev = meta.dev == true
            -- v6/v5 keep edges alongside metadata
            if edge_source == data.packages then
              collect_deps(meta.dependencies, deps)
              collect_deps(meta.optionalDependencies, deps)
            end
          end
          lf:add({
            name = name,
            version = version,
            checksum = checksum,
            deps = deps,
            dev = dev,
          })
        end
      end
    end
  end

  -- Pass 2: v9 dependency edges from snapshots.
  if edge_source == data.snapshots and type(data.snapshots) == "table" then
    for key, snap in pairs(data.snapshots) do
      if type(key) == "string" and type(snap) == "table" then
        local name, version = parse_key(key)
        local id = model.make_id(name, version)
        local pkg = lf.by_id[id]
        if pkg then
          collect_deps(snap.dependencies, pkg.deps)
          collect_deps(snap.optionalDependencies, pkg.deps)
        end
      end
    end
  end

  -- Roots from importers (monorepo) or top-level (single package).
  if type(data.importers) == "table" then
    for _, block in pairs(data.importers) do
      add_roots_from(lf, block)
    end
  else
    add_roots_from(lf, data)
  end

  return lf
end

return M
