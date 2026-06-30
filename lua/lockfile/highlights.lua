--- Highlight group definitions for the diff view.

local config = require("lockfile.config")

local M = {}

--- Define the plugin's highlight groups, linking each to the user-configured
--- target group (defaulting to sensible builtin groups). Safe to call repeatedly
--- (e.g. after a colorscheme change).
function M.setup()
  for group, link in pairs(config.options.highlights) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

return M
