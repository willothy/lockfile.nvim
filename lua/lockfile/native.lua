--- Loads the compiled Rust native module (`lockfile_native`).
---
--- Neovim does not add runtimepath `lua/?.so` to `package.cpath`, so the module
--- is loaded explicitly via `package.loadlib` from a path derived relative to
--- this file. The native module is a hard dependency: if it has not been built,
--- loading fails with instructions rather than degrading to a partial feature.

local M = {}

---@type table? cached module table
local lib = nil

--- Absolute path to the plugin root (the directory containing `lua/`).
---@return string
local function plugin_root()
  -- `source` is "@/abs/path/lua/lockfile/native.lua"; strip the leading '@'.
  local path = debug.getinfo(1, "S").source:sub(2)
  -- native.lua -> lockfile/ -> lua/ -> <root>
  return vim.fn.fnamemodify(path, ":h:h:h")
end

--- Platform-specific shared library filename.
---@return string
local function lib_filename()
  if vim.fn.has("win32") == 1 then
    return "lockfile_native.dll"
  end
  return "lockfile_native.so"
end

--- Load (and cache) the native module, raising a descriptive error if it is
--- not present.
---@return table
function M.load()
  if lib then
    return lib
  end
  local root = plugin_root()
  local path = root .. "/lua/" .. lib_filename()
  if vim.fn.filereadable(path) == 0 then
    error(
      ("lockfile.nvim: native module not found at %s\nBuild it with `make` (or `cargo build --release`) in %s")
        :format(path, root),
      0
    )
  end
  local loader, err = package.loadlib(path, "luaopen_lockfile_native")
  if not loader then
    error(("lockfile.nvim: failed to load native module at %s: %s"):format(path, tostring(err)), 0)
  end
  lib = loader()
  return lib
end

--- Whether the native module is available (built and loadable).
---@return boolean
function M.available()
  local ok = pcall(M.load)
  return ok
end

return M
