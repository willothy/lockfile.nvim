--- JSON parsing for package-lock.json / npm-shrinkwrap.json.
---
--- Neovim ships a real JSON parser (`vim.json.decode`); we use it rather than
--- hand-rolling one. It is a genuine recursive-descent decoder, not a
--- regex-based scraper, so it honours the "no regex parsing" rule.

local M = {}

--- Decode a JSON document into Lua values.
---@param src string
---@return any
function M.parse(src)
  -- luv_dependent: vim.json.decode errors on invalid input; surface a
  -- structured error consistent with the other parsers.
  local ok, result = pcall(vim.json.decode, src, { luanil = { object = true, array = true } })
  if not ok then
    error({
      lockfile_parse_error = true,
      msg = "invalid JSON: " .. tostring(result),
      line = 0,
      col = 0,
      pos = 0,
    }, 0)
  end
  return result
end

return M
