--- go.sum -> normalized model.
---
--- go.sum is a flat list of lines: "module version hash" and
--- "module version/go.mod hash". It records *no* dependency graph (that lives
--- in go.mod), so the resulting model has `supports_graph = false`. Each module
--- version collapses to one package; the module-zip hash is preferred as the
--- representative checksum, with the /go.mod hash as a fallback.

local model = require("lockfile.model")
local util = require("lockfile.util")

local M = {}

local GOMOD_SUFFIX = "/go.mod"

--- Build a normalized lockfile from go.sum source text.
---@param src string
---@return lockfile.Lockfile
function M.build(src)
  local lf = model.new("go")
  lf.supports_graph = false

  -- Track which packages already have a non-/go.mod (module zip) checksum so a
  -- later /go.mod line doesn't overwrite the preferred hash.
  local has_zip_hash = {}

  local start = 1
  local len = #src
  for i = 1, len + 1 do
    local c = (i <= len) and src:sub(i, i) or "\n"
    if c == "\n" then
      local raw = src:sub(start, i - 1)
      if raw:sub(-1) == "\r" then
        raw = raw:sub(1, -2)
      end
      local line = util.trim(raw)
      if line ~= "" then
        local parts = util.split_ws(line)
        if #parts >= 3 then
          local module = parts[1]
          local version = parts[2]
          local hash = parts[3]
          local is_gomod = util.ends_with(version, GOMOD_SUFFIX)
          if is_gomod then
            version = version:sub(1, #version - #GOMOD_SUFFIX)
          end
          local id = model.make_id(module, version)
          local existing = lf.by_id[id]
          if existing then
            -- prefer the module-zip hash over the /go.mod hash
            if not is_gomod and not has_zip_hash[id] then
              existing.checksum = hash
              has_zip_hash[id] = true
            end
          else
            lf:add({
              name = module,
              version = version,
              checksum = hash,
              deps = {},
            })
            if not is_gomod then
              has_zip_hash[id] = true
            end
          end
        end
      end
      start = i + 1
    end
  end

  return lf
end

return M
