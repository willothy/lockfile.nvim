--- Dispatch raw lockfile text to the right adapter, producing a normalized
--- `lockfile.Lockfile`.

local detect = require("lockfile.detect")

local M = {}

--- Adapter module name per format id.
---@type table<string, string>
local ADAPTERS = {
  cargo = "lockfile.parse.cargo",
  pnpm = "lockfile.parse.pnpm",
  npm = "lockfile.parse.npm",
  yarn = "lockfile.parse.yarn",
  poetry = "lockfile.parse.poetry",
  uv = "lockfile.parse.uv",
  go = "lockfile.parse.gosum",
}

---@class lockfile.ParseError
---@field msg string
---@field line integer
---@field col integer

--- Parse lockfile `src` of the given format `kind` into the normalized model.
---
--- Returns `nil, err` on failure where `err` is a `lockfile.ParseError`.
---@param kind string         # format id from `detect`
---@param src string
---@return lockfile.Lockfile?, lockfile.ParseError?
function M.parse(kind, src)
  local mod = ADAPTERS[kind]
  if not mod then
    return nil, { msg = "unsupported lockfile type: " .. tostring(kind), line = 0, col = 0 }
  end
  local adapter = require(mod)
  local ok, result = pcall(adapter.build, src)
  if not ok then
    if type(result) == "table" and result.lockfile_parse_error then
      return nil, { msg = result.msg, line = result.line or 0, col = result.col or 0 }
    end
    return nil, { msg = tostring(result), line = 0, col = 0 }
  end
  return result, nil
end

--- Parse a lockfile by path, detecting its type from the basename.
---@param path string
---@param src string
---@return lockfile.Lockfile?, lockfile.ParseError?
function M.parse_path(path, src)
  local kind = detect.detect(path)
  if not kind then
    return nil, { msg = "not a recognized lockfile: " .. path, line = 0, col = 0 }
  end
  return M.parse(kind, src)
end

return M
