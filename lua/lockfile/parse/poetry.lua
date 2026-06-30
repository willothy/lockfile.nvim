--- poetry.lock -> normalized model.
---
--- poetry.lock is TOML with `[[package]]` entries. Dependencies are a
--- `[package.dependencies]` sub-table mapping dependency name -> constraint
--- (a string, an inline table, or an array of inline tables for multiple
--- markers). File hashes live in per-package `files` (poetry >=1.5) or in a
--- top-level `[metadata.files]` table (poetry 1.x).

local toml = require("lockfile.parse.toml")
local model = require("lockfile.model")

local M = {}

--- Extract a representative checksum from a poetry `files` array.
---@param files any
---@return string?
local function checksum_from_files(files)
  if type(files) ~= "table" then
    return nil
  end
  for _, f in ipairs(files) do
    if type(f) == "table" and type(f.hash) == "string" then
      return f.hash
    end
  end
  return nil
end

--- Build a normalized lockfile from poetry.lock source text.
---@param src string
---@return lockfile.Lockfile
function M.build(src)
  local data = toml.parse(src)
  local lf = model.new("poetry")

  if type(data.metadata) == "table" and data.metadata["lock-version"] then
    lf.format_version = tostring(data.metadata["lock-version"])
  end

  -- poetry 1.x stored hashes centrally under [metadata.files][name] = {...}.
  local meta_files = {}
  if type(data.metadata) == "table" and type(data.metadata.files) == "table" then
    meta_files = data.metadata.files
  end

  local packages = data.package
  if type(packages) == "table" then
    for _, p in ipairs(packages) do
      if type(p) == "table" and p.name and p.version then
        local deps = {}
        if type(p.dependencies) == "table" then
          for name, _ in pairs(p.dependencies) do
            if type(name) == "string" then
              deps[#deps + 1] = { name = name }
            end
          end
        end

        local source
        if type(p.source) == "table" and type(p.source.url) == "string" then
          source = p.source.url
        end

        local checksum = checksum_from_files(p.files)
        if not checksum and meta_files[p.name] then
          checksum = checksum_from_files(meta_files[p.name])
        end

        lf:add({
          name = p.name,
          version = tostring(p.version),
          source = source,
          checksum = checksum,
          deps = deps,
          optional = p.optional == true,
        })
      end
    end
  end

  -- poetry.lock does not record which packages are direct (that lives in
  -- pyproject.toml). Roots are derived later from the dependency graph.
  return lf
end

return M
