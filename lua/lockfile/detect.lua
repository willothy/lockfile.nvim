--- Detect which lockfile format a file is, from its basename.

local M = {}

--- Map of recognized lockfile basenames to their format id.
---@type table<string, string>
local BY_BASENAME = {
  ["Cargo.lock"] = "cargo",
  ["pnpm-lock.yaml"] = "pnpm",
  ["pnpm-lock.yml"] = "pnpm",
  ["package-lock.json"] = "npm",
  ["npm-shrinkwrap.json"] = "npm",
  ["yarn.lock"] = "yarn",
  ["poetry.lock"] = "poetry",
  ["uv.lock"] = "uv",
  ["go.sum"] = "go",
  ["lazy-lock.json"] = "lazy",
}

--- Extract the basename (final path segment) of a path, handling both POSIX
--- and Windows separators without regex.
---@param path string
---@return string
local function basename(path)
  local last = 0
  for i = 1, #path do
    local c = path:sub(i, i)
    if c == "/" or c == "\\" then
      last = i
    end
  end
  return path:sub(last + 1)
end

M.basename = basename

--- Detect the lockfile format id for a given path, or nil if unrecognized.
---@param path string
---@return string?  # format id
function M.detect(path)
  return BY_BASENAME[basename(path)]
end

--- Whether a path is a recognized lockfile.
---@param path string
---@return boolean
function M.is_lockfile(path)
  return M.detect(path) ~= nil
end

--- The set of recognized lockfile basenames (for autocmd patterns, etc.).
---@return string[]
function M.basenames()
  local names = {}
  for name in pairs(BY_BASENAME) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

--- Human-readable label for a format id.
---@param type string
---@return string
function M.label(type)
  local labels = {
    cargo = "Cargo.lock",
    pnpm = "pnpm-lock.yaml",
    npm = "package-lock.json",
    yarn = "yarn.lock",
    poetry = "poetry.lock",
    uv = "uv.lock",
    go = "go.sum",
    lazy = "lazy-lock.json",
  }
  return labels[type] or type
end

return M
