--- A hand-written TOML parser, sufficient for the lockfiles this plugin reads
--- (Cargo.lock, poetry.lock, uv.lock) and for general well-formed TOML.
---
--- Supported: comments, bare/quoted/dotted keys, basic & literal strings
--- (single and multi-line), integers, floats, booleans, offset/local
--- datetimes (kept as their raw string), arrays, inline tables, `[table]`
--- headers and `[[array of table]]` headers.
---
--- Not a validator: it is lenient where leniency cannot change the meaning of a
--- real lockfile, and raises a structured error (see scanner) on genuine
--- malformed input.

local Scanner = require("lockfile.parse.scanner")

local M = {}

--- Marker so consumers / re-encoders can tell an array table from a map table.
--- (Lua can't otherwise distinguish `[]` from `{}` once both are tables.)
M.ARRAY = setmetatable({}, { __tostring = function() return "<toml.ARRAY>" end })

---@param ch string?
---@return boolean
local function is_ws(ch)
  return ch == " " or ch == "\t"
end

---@param ch string?
---@return boolean
local function is_bare_key_char(ch)
  if ch == nil then
    return false
  end
  return (ch >= "A" and ch <= "Z")
    or (ch >= "a" and ch <= "z")
    or (ch >= "0" and ch <= "9")
    or ch == "_"
    or ch == "-"
end

---@class lockfile.toml.Parser
---@field sc lockfile.Scanner
local Parser = {}
Parser.__index = Parser

--- Skip inline whitespace and comments up to (but not consuming) a newline.
function Parser:skip_ws_comment()
  while true do
    local ch = self.sc:peek()
    if is_ws(ch) then
      self.sc:next()
    elseif ch == "#" then
      self.sc:take_while(function(c)
        return c ~= "\n"
      end)
    else
      break
    end
  end
end

--- Skip whitespace, comments and blank lines (used between statements).
function Parser:skip_blank()
  while true do
    local ch = self.sc:peek()
    if ch == " " or ch == "\t" or ch == "\r" or ch == "\n" then
      self.sc:next()
    elseif ch == "#" then
      self.sc:take_while(function(c)
        return c ~= "\n"
      end)
    else
      break
    end
  end
end

--- Parse a basic string ("...") starting at the opening quote.
---@return string
function Parser:parse_basic_string()
  self.sc:expect('"')
  local out = {}
  while true do
    local ch = self.sc:next()
    if ch == nil then
      self.sc:error("unterminated string")
    elseif ch == '"' then
      break
    elseif ch == "\\" then
      table.insert(out, self:parse_escape())
    else
      table.insert(out, ch)
    end
  end
  return table.concat(out)
end

--- Parse a backslash escape sequence (the backslash already consumed).
---@return string
function Parser:parse_escape()
  local e = self.sc:next()
  if e == "n" then
    return "\n"
  elseif e == "t" then
    return "\t"
  elseif e == "r" then
    return "\r"
  elseif e == '"' then
    return '"'
  elseif e == "\\" then
    return "\\"
  elseif e == "b" then
    return "\b"
  elseif e == "f" then
    return "\f"
  elseif e == "u" or e == "U" then
    local n = (e == "u") and 4 or 8
    local hex = {}
    for _ = 1, n do
      local c = self.sc:next()
      if c == nil then
        self.sc:error("unterminated unicode escape")
      end
      table.insert(hex, c)
    end
    local code = tonumber(table.concat(hex), 16)
    if not code then
      self.sc:error("invalid unicode escape")
    end
    return vim.fn.nr2char(code)
  else
    self.sc:error("invalid escape sequence")
  end
end

--- Parse a multi-line basic string (""" ... """). Opening already detected.
---@return string
function Parser:parse_multiline_basic()
  self.sc:advance(3) -- consume """
  -- A newline immediately after the opening delimiter is trimmed.
  if self.sc:peek() == "\r" then
    self.sc:next()
  end
  if self.sc:peek() == "\n" then
    self.sc:next()
  end
  local out = {}
  while true do
    if self.sc:eof() then
      self.sc:error("unterminated multi-line string")
    end
    if self.sc:starts_with('"""') then
      self.sc:advance(3)
      break
    end
    local ch = self.sc:next()
    if ch == "\\" then
      -- Line-ending backslash: trim following whitespace (incl. newlines).
      local nxt = self.sc:peek()
      if nxt == "\n" or nxt == "\r" or is_ws(nxt) then
        -- could be a line-continuation; only treat as such if rest of line is ws
        local save = self.sc.pos
        self.sc:skip_inline_space()
        if self.sc:peek() == "\n" or self.sc:peek() == "\r" then
          self.sc:skip_space()
        else
          -- not a continuation; restore and emit a real escape
          self.sc.pos = save
          table.insert(out, self:parse_escape())
        end
      else
        table.insert(out, self:parse_escape())
      end
    else
      table.insert(out, ch)
    end
  end
  return table.concat(out)
end

--- Parse a literal string ('...'). Opening already detected.
---@return string
function Parser:parse_literal_string()
  self.sc:expect("'")
  local out = self.sc:take_while(function(c)
    return c ~= "'" and c ~= "\n"
  end)
  if self.sc:peek() ~= "'" then
    self.sc:error("unterminated literal string")
  end
  self.sc:next()
  return out
end

--- Parse a multi-line literal string (''' ... '''). Opening already detected.
---@return string
function Parser:parse_multiline_literal()
  self.sc:advance(3)
  if self.sc:peek() == "\r" then
    self.sc:next()
  end
  if self.sc:peek() == "\n" then
    self.sc:next()
  end
  local out = {}
  while true do
    if self.sc:eof() then
      self.sc:error("unterminated multi-line literal string")
    end
    if self.sc:starts_with("'''") then
      self.sc:advance(3)
      break
    end
    table.insert(out, self.sc:next())
  end
  return table.concat(out)
end

--- Parse any string form. Caller guarantees the next char begins a string.
---@return string
function Parser:parse_string()
  if self.sc:starts_with('"""') then
    return self:parse_multiline_basic()
  elseif self.sc:starts_with("'''") then
    return self:parse_multiline_literal()
  elseif self.sc:peek() == '"' then
    return self:parse_basic_string()
  else
    return self:parse_literal_string()
  end
end

--- Parse a single key segment (bare or quoted).
---@return string
function Parser:parse_key_segment()
  local ch = self.sc:peek()
  if ch == '"' or ch == "'" then
    return self:parse_string()
  end
  local key = self.sc:take_while(is_bare_key_char)
  if key == "" then
    self.sc:error("expected key")
  end
  return key
end

--- Parse a dotted key path into a list of segments.
---@return string[]
function Parser:parse_key_path()
  local path = { self:parse_key_segment() }
  while true do
    self:skip_ws_comment()
    if self.sc:peek() == "." then
      self.sc:next()
      self:skip_ws_comment()
      table.insert(path, self:parse_key_segment())
    else
      break
    end
  end
  return path
end

--- Parse a bare value token (number, bool, datetime) terminated by a
--- structural character. Classify it into a Lua value.
---@return any
function Parser:parse_bare_value()
  local tok = self.sc:take_while(function(c)
    return c ~= ","
      and c ~= "]"
      and c ~= "}"
      and c ~= "\n"
      and c ~= "\r"
      and c ~= "#"
      and c ~= " "
      and c ~= "\t"
  end)
  if tok == "" then
    self.sc:error("expected value")
  end
  if tok == "true" then
    return true
  elseif tok == "false" then
    return false
  end

  -- Numbers may contain underscores as digit separators; strip them manually
  -- (no patterns) before attempting numeric coercion.
  local cleaned
  do
    local buf = {}
    for i = 1, #tok do
      local c = tok:sub(i, i)
      if c ~= "_" then
        buf[#buf + 1] = c
      end
    end
    cleaned = table.concat(buf)
  end
  -- A datetime / version-ish token contains characters that make tonumber
  -- fail; in that case keep the raw token as a string (lockfiles never rely on
  -- numeric coercion of such fields).
  local num = tonumber(cleaned)
  if num ~= nil then
    return num
  end
  -- hex/oct/bin integer prefixes
  local prefix = tok:sub(1, 2)
  if prefix == "0x" or prefix == "0o" or prefix == "0b" then
    local base = (prefix == "0x") and 16 or (prefix == "0o") and 8 or 2
    local n = tonumber(cleaned:sub(3), base)
    if n then
      return n
    end
  end
  return tok
end

--- Parse any value (string, array, inline table, or bare value).
---@return any
function Parser:parse_value()
  self:skip_ws_comment()
  local ch = self.sc:peek()
  if ch == nil then
    self.sc:error("expected value, got end of input")
  end
  if ch == '"' or ch == "'" then
    return self:parse_string()
  elseif ch == "[" then
    return self:parse_array()
  elseif ch == "{" then
    return self:parse_inline_table()
  else
    return self:parse_bare_value()
  end
end

--- Parse an array `[ v, v, ... ]`. Newlines and comments are permitted inside.
---@return table
function Parser:parse_array()
  self.sc:expect("[")
  local arr = { [M.ARRAY] = true }
  local n = 0
  while true do
    self:skip_blank()
    if self.sc:peek() == "]" then
      self.sc:next()
      break
    end
    if self.sc:eof() then
      self.sc:error("unterminated array")
    end
    local v = self:parse_value()
    n = n + 1
    arr[n] = v
    self:skip_blank()
    local sep = self.sc:peek()
    if sep == "," then
      self.sc:next()
    elseif sep == "]" then
      self.sc:next()
      break
    else
      self.sc:error("expected ',' or ']' in array")
    end
  end
  return arr
end

--- Parse an inline table `{ k = v, ... }`.
---@return table
function Parser:parse_inline_table()
  self.sc:expect("{")
  local tbl = {}
  self:skip_ws_comment()
  if self.sc:peek() == "}" then
    self.sc:next()
    return tbl
  end
  while true do
    self:skip_ws_comment()
    local path = self:parse_key_path()
    self:skip_ws_comment()
    self.sc:expect("=")
    local v = self:parse_value()
    self:assign(tbl, path, v)
    self:skip_ws_comment()
    local sep = self.sc:peek()
    if sep == "," then
      self.sc:next()
    elseif sep == "}" then
      self.sc:next()
      break
    else
      self.sc:error("expected ',' or '}' in inline table")
    end
  end
  return tbl
end

--- Assign `value` at the dotted `path` within `tbl`, creating intermediate
--- tables as needed.
---@param tbl table
---@param path string[]
---@param value any
function Parser:assign(tbl, path, value)
  local cur = tbl
  for i = 1, #path - 1 do
    local seg = path[i]
    local nxt = cur[seg]
    if nxt == nil then
      nxt = {}
      cur[seg] = nxt
    elseif type(nxt) ~= "table" then
      self.sc:error("key path conflicts with a non-table value at '" .. seg .. "'")
    end
    cur = nxt
  end
  cur[path[#path]] = value
end

--- Navigate to (creating) the table addressed by a `[header]` path.
---@param root table
---@param path string[]
---@return table
function Parser:navigate_table(root, path)
  local cur = root
  for i = 1, #path do
    local seg = path[i]
    local nxt = cur[seg]
    if nxt == nil then
      nxt = {}
      cur[seg] = nxt
    elseif type(nxt) == "table" and nxt[M.ARRAY] then
      -- step into the last element of an array-of-tables
      nxt = nxt[#nxt]
    end
    cur = nxt
  end
  return cur
end

--- Navigate to the array-of-tables addressed by a `[[header]]` path and append
--- a fresh element, returning it.
---@param root table
---@param path string[]
---@return table
function Parser:navigate_array_table(root, path)
  local cur = root
  for i = 1, #path - 1 do
    local seg = path[i]
    local nxt = cur[seg]
    if nxt == nil then
      nxt = {}
      cur[seg] = nxt
    elseif type(nxt) == "table" and nxt[M.ARRAY] then
      nxt = nxt[#nxt]
    end
    cur = nxt
  end
  local last = path[#path]
  local arr = cur[last]
  if arr == nil then
    arr = { [M.ARRAY] = true }
    cur[last] = arr
  elseif type(arr) ~= "table" or not arr[M.ARRAY] then
    self.sc:error("'" .. last .. "' was defined as a non-array")
  end
  local elem = {}
  arr[#arr + 1] = elem
  return elem
end

--- Parse a full TOML document into a nested Lua table.
---@return table
function Parser:parse()
  local root = {}
  local current = root

  while true do
    self:skip_blank()
    if self.sc:eof() then
      break
    end
    local ch = self.sc:peek()
    if ch == "[" then
      if self.sc:starts_with("[[") then
        self.sc:advance(2)
        self:skip_ws_comment()
        local path = self:parse_key_path()
        self:skip_ws_comment()
        self.sc:expect("]]")
        current = self:navigate_array_table(root, path)
      else
        self.sc:next()
        self:skip_ws_comment()
        local path = self:parse_key_path()
        self:skip_ws_comment()
        self.sc:expect("]")
        current = self:navigate_table(root, path)
      end
      -- consume rest of header line
      self:skip_ws_comment()
    else
      -- key = value
      local path = self:parse_key_path()
      self:skip_ws_comment()
      self.sc:expect("=")
      local value = self:parse_value()
      self:assign(current, path, value)
      self:skip_ws_comment()
    end
  end
  return root
end

--- Parse a TOML string into a nested Lua table.
---@param src string
---@return table
function M.parse(src)
  local parser = setmetatable({ sc = Scanner.new(src) }, Parser)
  return parser:parse()
end

--- Is `t` an array table produced by this parser?
---@param t any
---@return boolean
function M.is_array(t)
  return type(t) == "table" and t[M.ARRAY] == true
end

return M
