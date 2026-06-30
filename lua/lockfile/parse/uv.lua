--- uv.lock -> normalized model.
---
--- uv.lock is TOML with `[[package]]` entries. Each `dependencies` is an array
--- of inline tables `{ name = "...", ... }`. The project itself appears as a
--- package whose `source` is `{ editable = "." }` or `{ virtual = "." }`, which
--- we treat as a root. Hashes come from `sdist` / `wheels`.

local toml = require("lockfile.parse.toml")
local model = require("lockfile.model")

local M = {}

--- Collect dependency edges from a uv dependency array (inline tables).
---@param arr any
---@param out lockfile.Dep[]
local function collect_deps(arr, out)
  if type(arr) ~= "table" then
    return
  end
  for _, d in ipairs(arr) do
    if type(d) == "table" and type(d.name) == "string" then
      out[#out + 1] = { name = d.name }
    end
  end
end

--- Extract a representative checksum from a uv package's sdist/wheels.
---@param p table
---@return string?
local function checksum_of(p)
  if type(p.sdist) == "table" and type(p.sdist.hash) == "string" then
    return p.sdist.hash
  end
  if type(p.wheels) == "table" then
    for _, w in ipairs(p.wheels) do
      if type(w) == "table" and type(w.hash) == "string" then
        return w.hash
      end
    end
  end
  return nil
end

--- Build a normalized lockfile from uv.lock source text.
---@param src string
---@return lockfile.Lockfile
function M.build(src)
  local data = toml.parse(src)
  local lf = model.new("uv")
  if data.version ~= nil then
    lf.format_version = tostring(data.version)
  end

  local packages = data.package
  if type(packages) == "table" then
    for _, p in ipairs(packages) do
      if type(p) == "table" and p.name and p.version then
        local deps = {}
        collect_deps(p.dependencies, deps)
        -- optional-dependencies is a table of extra-name -> array of deps
        if type(p["optional-dependencies"]) == "table" then
          for _, arr in pairs(p["optional-dependencies"]) do
            collect_deps(arr, deps)
          end
        end
        -- dev-dependencies is a table of group-name -> array of deps
        if type(p["dev-dependencies"]) == "table" then
          for _, arr in pairs(p["dev-dependencies"]) do
            collect_deps(arr, deps)
          end
        end

        local source
        local is_root = false
        if type(p.source) == "table" then
          if p.source.editable ~= nil or p.source.virtual ~= nil then
            is_root = true
            source = nil
          elseif type(p.source.registry) == "string" then
            source = p.source.registry
          elseif type(p.source.git) == "string" then
            source = "git+" .. p.source.git
          elseif type(p.source.url) == "string" then
            source = p.source.url
          elseif type(p.source.path) == "string" then
            source = p.source.path
          end
        end

        local pkg = lf:add({
          name = p.name,
          version = tostring(p.version),
          source = source,
          checksum = checksum_of(p),
          deps = deps,
        })
        if is_root then
          lf:add_root(pkg.id)
        end
      end
    end
  end

  return lf
end

return M
