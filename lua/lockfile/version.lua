--- Version comparison and change classification.
---
--- Backed by the native module, which dispatches by lockfile format to the
--- canonical crates: `semver` (Cargo/npm/pnpm/yarn/Go) and `pep440_rs`
--- (poetry/uv). This Lua module is a thin, cached front-end.

local native = require("lockfile.native")

local M = {}

--- "changed" is used by callers for formats whose versions are opaque (not
--- semver), where a difference is detectable but not classifiable.
---@alias lockfile.VersionChange "major"|"minor"|"patch"|"prerelease"|"downgrade"|"none"|"other"|"changed"

--- Classify the change from `old` to `new` under `kind`'s versioning scheme.
---@param kind string  # lockfile format id
---@param old string
---@param new string
---@return lockfile.VersionChange
function M.classify(kind, old, new)
  return native.load().version_classify(kind, old, new)
end

--- Compare two versions under `kind`'s scheme. Returns -1, 0, or 1.
---@param kind string
---@param a string
---@param b string
---@return integer
function M.compare(kind, a, b)
  return native.load().version_compare(kind, a, b)
end

return M
