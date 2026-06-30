--- Parse lockfiles into the normalized model by delegating to the Rust native
--- module and indexing the result.

local native = require("lockfile.native")
local detect = require("lockfile.detect")
local model = require("lockfile.model")

local M = {}

---@class lockfile.ParseError
---@field msg string

--- Parse lockfile `src` of the given format `kind` into the normalized model.
--- Returns `nil, err` on failure.
---@param kind string
---@param src string
---@return lockfile.Lockfile?, lockfile.ParseError?
function M.parse(kind, src)
  local ok, lib = pcall(native.load)
  if not ok then
    return nil, { msg = tostring(lib) }
  end
  local parsed_ok, raw = pcall(lib.parse, kind, src)
  if not parsed_ok then
    return nil, { msg = tostring(raw) }
  end
  return model.from_native(raw), nil
end

--- Parse a lockfile by path, detecting its type from the basename.
---@param path string
---@param src string
---@return lockfile.Lockfile?, lockfile.ParseError?
function M.parse_path(path, src)
  local kind = detect.detect(path)
  if not kind then
    return nil, { msg = "not a recognized lockfile: " .. path }
  end
  return M.parse(kind, src)
end

return M
