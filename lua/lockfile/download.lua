--- Install the native module for a plugin-manager build step: download a
--- prebuilt binary matching the installed release tag, and fall back to building
--- from source when no matching prebuilt exists (e.g. tracking a branch) or the
--- download fails.
---
--- Use as a lazy.nvim build step:
---     build = function() require("lockfile.download").download_or_build() end
---
--- Prebuilt binaries are published per release tag (see .github/workflows). A
--- prebuilt is only used when the checked-out HEAD is exactly at a release tag,
--- so the binary always matches the source it ships with; otherwise the module
--- is built from source.

local M = {}

--- GitHub "owner/repo" that publishes the release binaries.
local REPO = "willothy/lockfile.nvim"

--- Absolute path to the plugin root (the directory containing `lua/`).
---@return string
local function plugin_root()
  -- download.lua -> lockfile/ -> lua/ -> <root>
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
end

--- Whether the host is Windows.
---@return boolean
local function is_windows()
  return vim.fn.has("win32") == 1
end

--- Extension of the loadable module file on this platform ("so" | "dll").
---@return string
local function lib_extension()
  return is_windows() and "dll" or "so"
end

--- The Rust target triple for the current platform, or nil if unsupported.
---@return string?
local function target_triple()
  local uname = vim.uv.os_uname()
  local sysname = uname.sysname:lower()
  local machine = uname.machine:lower()

  local arch
  if machine == "x86_64" or machine == "amd64" then
    arch = "x86_64"
  elseif machine == "aarch64" or machine == "arm64" then
    arch = "aarch64"
  else
    return nil
  end

  if sysname:find("darwin", 1, true) then
    return arch .. "-apple-darwin"
  elseif sysname:find("windows", 1, true) or sysname:find("mingw", 1, true) then
    return arch .. "-pc-windows-msvc"
  elseif sysname:find("linux", 1, true) then
    -- Distinguish musl from glibc; the binaries are not interchangeable.
    -- Guard the probe: `ldd` may be absent, and a missing binary makes
    -- vim.system raise rather than return.
    local libc = "gnu"
    if vim.fn.executable("ldd") == 1 then
      local ok, ldd = pcall(function()
        return vim.system({ "ldd", "--version" }):wait()
      end)
      if ok and ldd then
        local out = ((ldd.stdout or "") .. (ldd.stderr or "")):lower()
        if out:find("musl", 1, true) then
          libc = "musl"
        end
      end
    end
    return arch .. "-unknown-linux-" .. libc
  end
  return nil
end

--- Path where the loadable module must live for `native.lua` to find it.
---@param root string
---@return string
local function installed_path(root)
  return root .. "/lua/lockfile_native." .. lib_extension()
end

--- Path of the freshly built library for a host `cargo build --release`.
---@param root string
---@return string
local function built_path(root)
  local base = root .. "/target/release/"
  if is_windows() then
    return base .. "lockfile_native.dll"
  elseif vim.uv.os_uname().sysname:lower():find("darwin", 1, true) then
    return base .. "liblockfile_native.dylib"
  end
  return base .. "liblockfile_native.so"
end

--- The release tag at the current HEAD, or nil if HEAD is not exactly at a tag.
---@param root string
---@return string?
local function release_tag(root)
  local res = vim.system({ "git", "-C", root, "describe", "--tags", "--exact-match", "HEAD" }):wait()
  if res.code == 0 then
    local tag = vim.trim(res.stdout or "")
    if tag ~= "" then
      return tag
    end
  end
  return nil
end

--- Download `url` to `out` with curl. Returns ok, error message.
---@param url string
---@param out string
---@return boolean ok
---@return string? err
local function curl(url, out)
  if vim.fn.executable("curl") == 0 then
    return false, "curl is not available"
  end
  local res = vim.system({
    "curl",
    "--fail",
    "--location",
    "--silent",
    "--show-error",
    "--output",
    out,
    url,
  }):wait()
  if res.code ~= 0 then
    return false, vim.trim(res.stderr or "download failed")
  end
  return true, nil
end

--- Try to download and install a prebuilt binary for `tag`. Returns ok, err.
---@param root string
---@param tag string
---@param triple string
---@return boolean ok
---@return string? err
local function install_prebuilt(root, tag, triple)
  local asset = ("lockfile_native-%s.%s"):format(triple, lib_extension())
  local url = ("https://github.com/%s/releases/download/%s/%s"):format(REPO, tag, asset)
  local dest = installed_path(root)
  local tmp = dest .. ".tmp"

  local ok, err = curl(url, tmp)
  if not ok then
    return false, err
  end

  -- Validate the download actually loads before swapping it in.
  local loader = package.loadlib(tmp, "luaopen_lockfile_native")
  if not loader then
    pcall(vim.uv.fs_unlink, tmp)
    return false, "downloaded binary failed to load"
  end

  local renamed, rename_err = vim.uv.fs_rename(tmp, dest)
  if not renamed then
    if is_windows() then
      -- The live DLL may be locked by this session; leave the validated .tmp
      -- for the next restart to promote.
      vim.notify(
        "lockfile.nvim: downloaded binary saved to " .. tmp .. "; restart Neovim to apply.",
        vim.log.levels.WARN
      )
      return true, nil
    end
    pcall(vim.uv.fs_unlink, tmp)
    return false, "failed to install binary: " .. tostring(rename_err)
  end
  return true, nil
end

--- Build the native module from source and copy it into place.
---@param root string?
function M.build(root)
  root = root or plugin_root()
  if vim.fn.executable("cargo") == 0 then
    error(
      "lockfile.nvim: no prebuilt binary for this platform and `cargo` was not found "
        .. "to build from source. Install Rust from https://rustup.rs/",
      0
    )
  end

  local res = vim.system({ "cargo", "build", "--release" }, { cwd = root }):wait()
  if res.code ~= 0 then
    error("lockfile.nvim: `cargo build --release` failed:\n" .. (res.stderr or ""), 0)
  end

  local dest = installed_path(root)
  local ok, err = vim.uv.fs_copyfile(built_path(root), dest)
  if not ok then
    error("lockfile.nvim: failed to copy built binary to " .. dest .. ": " .. tostring(err), 0)
  end
  vim.notify("lockfile.nvim: built native module from source.")
end

--- Install the native module: prefer a prebuilt binary matching the installed
--- release tag, otherwise build from source.
function M.download_or_build()
  local root = plugin_root()
  local tag = release_tag(root)
  local triple = target_triple()

  if tag and triple then
    local ok, err = install_prebuilt(root, tag, triple)
    if ok then
      vim.notify(("lockfile.nvim: installed prebuilt binary for %s (%s)."):format(triple, tag))
      return
    end
    vim.notify(
      ("lockfile.nvim: prebuilt unavailable (%s); building from source."):format(err or "unknown"),
      vim.log.levels.INFO
    )
  end

  M.build(root)
end

return M
