--- User configuration with sensible defaults.

local M = {}

---@class lockfile.Config
---@field window lockfile.WindowConfig
---@field icons lockfile.Icons
---@field highlights table<string,string>  # map of plugin hl group -> linked group
---@field analysis lockfile.AnalysisConfig
---@field default_diff_base string          # git ref to diff working tree against

---@class lockfile.WindowConfig
---@field style "float"|"split"             # how to present the report
---@field width number                      # float width (cols, or fraction <=1)
---@field height number                     # float height (rows, or fraction <=1)
---@field border string                     # float border style

---@class lockfile.Icons
---@field added string
---@field removed string
---@field updated string
---@field suspicious string
---@field collapsed string
---@field expanded string

---@class lockfile.AnalysisConfig
---@field flag_major boolean                # flag major version bumps
---@field flag_downgrade boolean            # flag version downgrades
---@field flag_source_change boolean        # flag a package's source url changing
---@field flag_checksum_change boolean      # flag same-version checksum changes
---@field flag_new_git_source boolean       # flag added packages from git/url/path
---@field big_transitive_threshold integer  # added deps from one change to flag as "big"

---@type lockfile.Config
local defaults = {
  window = {
    style = "float",
    width = 0.8,
    height = 0.8,
    border = "rounded",
  },
  icons = {
    added = "+",
    removed = "-",
    updated = "~",
    suspicious = "⚠",
    collapsed = "▸",
    expanded = "▾",
  },
  highlights = {
    LockfileAdded = "DiffAdd",
    LockfileRemoved = "DiffDelete",
    LockfileUpdated = "DiffChange",
    LockfileSuspicious = "DiagnosticError",
    LockfileHeader = "Title",
    LockfileSection = "Function",
    LockfileVersion = "Number",
    LockfileVersionOld = "Comment",
    LockfileName = "Identifier",
    LockfileReason = "Comment",
    LockfileSource = "String",
    LockfileMuted = "NonText",
    LockfileMajor = "WarningMsg",
  },
  analysis = {
    flag_major = true,
    flag_downgrade = true,
    flag_source_change = true,
    flag_checksum_change = true,
    flag_new_git_source = true,
    big_transitive_threshold = 10,
  },
  default_diff_base = "HEAD",
}

---@type lockfile.Config
M.options = vim.deepcopy(defaults)

--- Merge user options over the defaults.
---@param opts lockfile.Config?
---@return lockfile.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  return M.options
end

--- The default configuration table (a fresh copy).
---@return lockfile.Config
function M.defaults()
  return vim.deepcopy(defaults)
end

return M
