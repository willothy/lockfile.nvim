--- The diff viewer: renders a report into a scratch buffer in a float or split,
--- applies highlights as extmarks, drives folding via a per-buffer foldexpr, and
--- wires buffer-local keymaps.

local config = require("lockfile.config")
local highlights = require("lockfile.highlights")
local render = require("lockfile.render")

local M = {}

local ns = vim.api.nvim_create_namespace("lockfile_diff")

--- Per-buffer fold expression strings, keyed by buffer number. Read by
--- `foldexpr` (which only receives the line number via `v:lnum`).
---@type table<integer, table<integer, string>>
local fold_state = {}

--- 'foldexpr' implementation; returns the precomputed fold expression for the
--- current buffer's line.
---@return string
function M.foldexpr()
  local levels = fold_state[vim.api.nvim_get_current_buf()]
  if not levels then
    return "0"
  end
  return levels[vim.v.lnum] or "0"
end

--- Write rendered lines, highlights and fold levels into `buf`.
---@param buf integer
---@param report lockfile.Report
---@param opts { old_label: string, new_label: string }
local function render_into(buf, report, opts)
  local rlines = render.render(report, opts)

  local texts = {}
  local levels = {}
  for i, rl in ipairs(rlines) do
    texts[i] = rl.text
    levels[i] = rl.fold
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, rl in ipairs(rlines) do
    for _, seg in ipairs(rl.hls) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, seg.from, {
        end_col = seg.to,
        hl_group = seg.group,
      })
    end
  end

  fold_state[buf] = levels
end

--- Create the scratch buffer used for the report.
---@return integer
local function create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "lockfilediff"
  return buf
end

--- Open a window for `buf` according to the configured style.
---@param buf integer
---@return integer win
local function open_window(buf)
  local w = config.options.window
  if w.style == "split" then
    vim.cmd("botright vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    return win
  end

  local cols, rows = vim.o.columns, vim.o.lines
  local width = w.width <= 1 and math.floor(cols * w.width) or w.width
  local height = w.height <= 1 and math.floor(rows * w.height) or w.height
  width = math.max(20, math.min(width, cols - 2))
  height = math.max(5, math.min(height, rows - 2))

  return vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((rows - height) / 2),
    col = math.floor((cols - width) / 2),
    border = w.border,
    title = " lockfile.nvim ",
    title_pos = "center",
  })
end

--- Apply window-local display options for the viewer.
---@param win integer
local function set_window_options(win)
  vim.wo[win].foldmethod = "expr"
  vim.wo[win].foldexpr = "v:lua.require'lockfile.ui'.foldexpr()"
  vim.wo[win].foldenable = true
  vim.wo[win].foldlevel = 99
  vim.wo[win].foldcolumn = "1"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].list = false
end

--- Open a diff report in a new viewer window.
---@param report lockfile.Report
---@param opts { old_label: string, new_label: string, recompute?: fun(): lockfile.Report?, table?, string? }
---@return { buf: integer, win: integer }
function M.open(report, opts)
  highlights.setup()

  local buf = create_buf()
  render_into(buf, report, opts)
  local win = open_window(buf)
  set_window_options(win)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      fold_state[buf] = nil
    end,
  })

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  map("q", close)
  map("<Esc>", close)
  map("<Tab>", function()
    pcall(vim.cmd, "normal! za")
  end)
  map("<CR>", function()
    pcall(vim.cmd, "normal! za")
  end)
  map("zR", function()
    vim.wo[win].foldlevel = 99
  end)
  map("zM", function()
    vim.wo[win].foldlevel = 1
  end)

  if opts.recompute then
    map("R", function()
      local new_report, new_labels = opts.recompute()
      if new_report then
        render_into(buf, new_report, new_labels)
      end
    end)
  end

  return { buf = buf, win = win }
end

return M
