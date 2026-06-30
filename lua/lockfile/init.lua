--- lockfile.nvim — make lockfile diffs understandable.
---
--- Public API and orchestration: resolve which lockfile and which two revisions
--- to compare, parse both, diff and analyze them, and present the result.

local config = require("lockfile.config")
local detect = require("lockfile.detect")
local native = require("lockfile.native")

local M = {}

--- Notify the user with a plugin-prefixed message.
---@param msg string
---@param level integer?
local function notify(msg, level)
  vim.notify("lockfile.nvim: " .. msg, level or vim.log.levels.ERROR)
end

--- Configure the plugin.
---@param opts lockfile.Config?
function M.setup(opts)
  config.setup(opts)
  require("lockfile.highlights").setup()
end

--- Read the working-tree contents of `path`.
---@param path string
---@return string? contents
---@return string? err
local function read_worktree(path)
  if vim.fn.filereadable(path) == 0 then
    return nil, "file not readable: " .. path
  end
  return table.concat(vim.fn.readfile(path), "\n"), nil
end

--- Resolve the lockfile path to operate on, from an explicit option or the
--- current buffer. Returns nil if neither yields a recognized lockfile.
---@param path string?
---@return string?
local function resolve_path(path)
  if path and path ~= "" then
    return vim.fn.fnamemodify(path, ":p")
  end
  local current = vim.api.nvim_buf_get_name(0)
  if current ~= "" and detect.is_lockfile(current) then
    return current
  end
  return nil
end

--- Obtain the contents and a display label for one side of a diff.
--- `rev` is a git revision, or nil/"" to read the working tree.
---@param git table
---@param root string
---@param relpath string
---@param path string
---@param rev string?
---@return string? contents
---@return string? label
---@return string? err
local function side(git, root, relpath, path, rev)
  if rev and rev ~= "" then
    if not git.rev_exists(root, rev) then
      return nil, nil, "revision not found: " .. rev
    end
    local contents, err = git.show(root, rev, relpath)
    if not contents then
      return nil, nil, ("could not read %s at %s: %s"):format(relpath, rev, tostring(err))
    end
    return contents, rev, nil
  end
  local contents, err = read_worktree(path)
  if not contents then
    return nil, nil, err
  end
  return contents, "working tree", nil
end

--- Build an analyzed diff report for `path`.
---@param path string
---@param opts { old?: string, new?: string }
---@return lockfile.Report?
---@return { old_label: string, new_label: string }?
---@return string? err
function M.build_report(path, opts)
  local parse = require("lockfile.parse")
  local diff = require("lockfile.diff")
  local analyze = require("lockfile.analyze")
  local git = require("lockfile.git")

  local kind = detect.detect(path)
  if not kind then
    return nil, nil, "not a recognized lockfile: " .. path
  end
  local root = git.root(path)
  if not root then
    return nil, nil, "not inside a git repository: " .. path
  end
  local relpath = git.relpath(root, path)

  local base = (opts.old and opts.old ~= "") and opts.old or config.options.default_diff_base
  local old_src, old_label, oerr = side(git, root, relpath, path, base)
  if not old_src then
    return nil, nil, oerr
  end
  local new_src, new_label, nerr = side(git, root, relpath, path, opts.new)
  if not new_src then
    return nil, nil, nerr
  end

  local old_lf, e1 = parse.parse(kind, old_src)
  if not old_lf then
    return nil, nil, ("parsing %s @ %s: %s"):format(relpath, old_label, e1.msg)
  end
  local new_lf, e2 = parse.parse(kind, new_src)
  if not new_lf then
    return nil, nil, ("parsing %s @ %s: %s"):format(relpath, new_label, e2.msg)
  end

  local report = diff.diff(old_lf, new_lf)
  analyze.annotate(report, config.options)
  return report, { old_label = old_label, new_label = new_label }, nil
end

--- Build and open the diff view for a resolved lockfile path.
---@param path string
---@param opts { old?: string, new?: string }
local function open_path(path, opts)
  local report, labels, err = M.build_report(path, opts)
  if not report then
    notify(err or "failed to build diff")
    return
  end
  require("lockfile.ui").open(report, {
    old_label = labels.old_label,
    new_label = labels.new_label,
    recompute = function()
      local r, l = M.build_report(path, opts)
      return r, l
    end,
  })
end

--- Diff a lockfile and open the viewer.
---
--- With no `path`, uses the current buffer if it is a lockfile, otherwise
--- prompts to pick a tracked lockfile in the repository. `old` defaults to the
--- configured base revision (HEAD); `new` defaults to the working tree.
---@param opts { path?: string, old?: string, new?: string }?
function M.diff(opts)
  opts = opts or {}
  if not native.available() then
    notify("native module not built — run `make` (or `cargo build --release`) in the plugin directory")
    return
  end

  local path = resolve_path(opts.path)
  if path then
    open_path(path, opts)
    return
  end

  -- No lockfile in context: offer the repo's tracked lockfiles.
  local git = require("lockfile.git")
  local root = git.root(vim.fn.getcwd())
  if not root then
    notify("open a lockfile, or run inside a git repository")
    return
  end
  local files = git.list_lockfiles(root, detect.basenames())
  if #files == 0 then
    notify("no tracked lockfiles found in " .. root)
    return
  end
  vim.ui.select(files, { prompt = "Diff which lockfile?" }, function(choice)
    if choice then
      open_path(root .. "/" .. choice, opts)
    end
  end)
end

return M
