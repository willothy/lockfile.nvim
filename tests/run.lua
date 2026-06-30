-- Minimal test runner for the Lua side of lockfile.nvim.
--
-- Run with: nvim --headless --noplugin -u NONE -l tests/run.lua
-- Exits non-zero if any assertion fails (so `make test` / CI can detect it).

-- Make `require("lockfile.*")` and `require("tests.*")` resolve from the repo
-- root, regardless of cwd: derive the root from this script's path.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h:h")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/?.lua",
  package.path,
}, ";")

local total, failures = 0, 0

---@class lockfile.test.T
local T = {}

--- Assert deep equality.
function T.eq(got, exp, msg)
  total = total + 1
  if not vim.deep_equal(got, exp) then
    failures = failures + 1
    print(("  FAIL %s\n    got: %s\n    exp: %s"):format(msg or "", vim.inspect(got), vim.inspect(exp)))
  end
end

--- Assert a truthy condition.
function T.ok(cond, msg)
  total = total + 1
  if not cond then
    failures = failures + 1
    print("  FAIL " .. (msg or "expected truthy"))
  end
end

local specs = {
  "semver_spec",
  "diff_spec",
  "analyze_spec",
  "render_spec",
}

for _, name in ipairs(specs) do
  print("== " .. name)
  local chunk = assert(loadfile(root .. "/tests/" .. name .. ".lua"))
  local run = chunk()
  local ok, err = pcall(run, T)
  if not ok then
    failures = failures + 1
    print("  ERROR in " .. name .. ": " .. tostring(err))
  end
end

print(("\n%d assertions, %d failures"):format(total, failures))
if failures > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("quit")
end
