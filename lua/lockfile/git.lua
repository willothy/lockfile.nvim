--- Git access, backed by libgit2 through the Rust native module.

local native = require("lockfile.native")

local M = {}

--- The repository working-directory root containing `path`, or nil.
---@param path string
---@return string?
function M.root(path)
  return native.load().git_root(path)
end

--- The repo-relative path of `abspath` within repo `root`.
---@param root string
---@param abspath string
---@return string
function M.relpath(root, abspath)
  return native.load().git_relpath(root, abspath)
end

--- Read the contents of `relpath` at revision `rev` within `root`.
--- Returns nil + error message on failure (e.g. the file did not exist there).
---@param root string
---@param rev string
---@param relpath string
---@return string? contents
---@return string? err
function M.show(root, rev, relpath)
  local ok, result = pcall(native.load().git_show, root, rev, relpath)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

--- Does `rev` resolve to a commit in the repo at `root`?
---@param root string
---@param rev string
---@return boolean
function M.rev_exists(root, rev)
  return native.load().git_rev_exists(root, rev)
end

--- List tracked lockfiles in the repo at `root` (repo-relative paths).
---@param root string
---@param basenames string[]
---@return string[]
function M.list_lockfiles(root, basenames)
  return native.load().git_list_lockfiles(root, basenames)
end

return M
