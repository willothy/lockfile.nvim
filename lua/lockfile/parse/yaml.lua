--- A hand-written YAML parser covering the subset used by lockfiles:
--- indentation-based block mappings and sequences, flow mappings `{...}` and
--- flow sequences `[...]`, and plain / single-quoted / double-quoted scalars.
---
--- This is the subset that pnpm-lock.yaml and Yarn Berry's yarn.lock actually
--- use. Block scalars (`|`, `>`), anchors, aliases, tags and multi-document
--- streams are intentionally unsupported — none appear in real lockfiles — and
--- the parser fails loudly rather than guessing if it meets them.

local Scanner = require("lockfile.parse.scanner")

local M = {}

--- Sentinel for an explicit/empty null value, so that a present-but-empty key
--- is distinguishable from an absent key. Consumers can compare against this.
M.NULL = setmetatable({}, { __tostring = function() return "<yaml.NULL>" end })

---@param ch string?
---@return boolean
local function is_space(ch)
  return ch == " " or ch == "\t"
end

--- Count the leading indentation (in columns) of a raw line and return the
--- indent plus the remaining content.
---@param line string
---@return integer indent
---@return string content
local function split_indent(line)
  local i = 1
  local n = #line
  while i <= n do
    local c = line:sub(i, i)
    if c == " " or c == "\t" then
      i = i + 1
    else
      break
    end
  end
  return i - 1, line:sub(i)
end

--- Trim trailing whitespace from a string (no patterns).
---@param s string
---@return string
local function rtrim(s)
  local n = #s
  while n > 0 do
    local c = s:sub(n, n)
    if c == " " or c == "\t" or c == "\r" then
      n = n - 1
    else
      break
    end
  end
  return s:sub(1, n)
end

--- Pre-split the source into significant logical lines, dropping blank lines and
--- whole-line comments. Each entry is { indent = N, content = "..." }.
---@param src string
---@return {indent: integer, content: string}[]
local function logical_lines(src)
  local lines = {}
  local start = 1
  local len = #src
  local i = 1
  -- iterate manually splitting on "\n"
  while i <= len + 1 do
    local c = (i <= len) and src:sub(i, i) or "\n"
    if c == "\n" then
      local raw = src:sub(start, i - 1)
      if raw:sub(-1) == "\r" then
        raw = raw:sub(1, -2)
      end
      local indent, content = split_indent(raw)
      content = rtrim(content)
      if content ~= "" and content:sub(1, 1) ~= "#" then
        lines[#lines + 1] = { indent = indent, content = content }
      end
      start = i + 1
    end
    i = i + 1
  end
  return lines
end

------------------------------------------------------------------------------
-- Flow scalars / collections (single-line)
------------------------------------------------------------------------------

--- Parse a double-quoted scalar from a scanner positioned at the opening quote.
---@param sc lockfile.Scanner
---@return string
local function parse_double(sc)
  sc:expect('"')
  local out = {}
  while true do
    local ch = sc:next()
    if ch == nil then
      sc:error("unterminated double-quoted scalar")
    elseif ch == '"' then
      break
    elseif ch == "\\" then
      local e = sc:next()
      if e == "n" then
        out[#out + 1] = "\n"
      elseif e == "t" then
        out[#out + 1] = "\t"
      elseif e == "r" then
        out[#out + 1] = "\r"
      elseif e == '"' then
        out[#out + 1] = '"'
      elseif e == "\\" then
        out[#out + 1] = "\\"
      elseif e == "/" then
        out[#out + 1] = "/"
      elseif e == "u" or e == "U" then
        local n = (e == "u") and 4 or 8
        local hex = {}
        for _ = 1, n do
          hex[#hex + 1] = sc:next()
        end
        local code = tonumber(table.concat(hex), 16)
        out[#out + 1] = code and vim.fn.nr2char(code) or ""
      elseif e == nil then
        sc:error("unterminated escape")
      else
        out[#out + 1] = e
      end
    else
      out[#out + 1] = ch
    end
  end
  return table.concat(out)
end

--- Parse a single-quoted scalar (doubled '' is a literal quote).
---@param sc lockfile.Scanner
---@return string
local function parse_single(sc)
  sc:expect("'")
  local out = {}
  while true do
    local ch = sc:next()
    if ch == nil then
      sc:error("unterminated single-quoted scalar")
    elseif ch == "'" then
      if sc:peek() == "'" then
        sc:next()
        out[#out + 1] = "'"
      else
        break
      end
    else
      out[#out + 1] = ch
    end
  end
  return table.concat(out)
end

--- Coerce a plain (unquoted) scalar token into a Lua value.
---@param tok string
---@return any
local function coerce_plain(tok)
  tok = rtrim(tok)
  -- trim leading spaces too
  local s = 1
  while s <= #tok and is_space(tok:sub(s, s)) do
    s = s + 1
  end
  tok = tok:sub(s)
  if tok == "" or tok == "~" or tok == "null" or tok == "Null" or tok == "NULL" then
    return M.NULL
  elseif tok == "true" or tok == "True" or tok == "TRUE" then
    return true
  elseif tok == "false" or tok == "False" or tok == "FALSE" then
    return false
  end
  local num = tonumber(tok)
  if num ~= nil then
    return num
  end
  return tok
end

local parse_flow_node -- forward declaration

--- Parse a flow mapping `{ k: v, ... }`.
---@param sc lockfile.Scanner
---@return table
local function parse_flow_mapping(sc)
  sc:expect("{")
  local map = {}
  sc:skip_inline_space()
  if sc:peek() == "}" then
    sc:next()
    return map
  end
  while true do
    sc:skip_inline_space()
    -- read key
    local key
    local ch = sc:peek()
    if ch == '"' then
      key = parse_double(sc)
    elseif ch == "'" then
      key = parse_single(sc)
    else
      local buf = sc:take_while(function(c)
        return c ~= ":" and c ~= "," and c ~= "}" and c ~= "\n"
      end)
      key = rtrim(buf)
    end
    sc:skip_inline_space()
    local value = M.NULL
    if sc:peek() == ":" then
      sc:next()
      sc:skip_inline_space()
      value = parse_flow_node(sc)
    end
    map[key] = value
    sc:skip_inline_space()
    local sep = sc:peek()
    if sep == "," then
      sc:next()
    elseif sep == "}" then
      sc:next()
      break
    elseif sep == nil then
      sc:error("unterminated flow mapping")
    else
      sc:error("expected ',' or '}' in flow mapping")
    end
  end
  return map
end

--- Parse a flow sequence `[ v, ... ]`.
---@param sc lockfile.Scanner
---@return table
local function parse_flow_sequence(sc)
  sc:expect("[")
  local seq = {}
  sc:skip_inline_space()
  if sc:peek() == "]" then
    sc:next()
    return seq
  end
  while true do
    sc:skip_inline_space()
    seq[#seq + 1] = parse_flow_node(sc)
    sc:skip_inline_space()
    local sep = sc:peek()
    if sep == "," then
      sc:next()
    elseif sep == "]" then
      sc:next()
      break
    elseif sep == nil then
      sc:error("unterminated flow sequence")
    else
      sc:error("expected ',' or ']' in flow sequence")
    end
  end
  return seq
end

--- Parse a single flow node: nested collection, quoted scalar, or plain scalar
--- (terminated by a flow structural character).
---@param sc lockfile.Scanner
---@return any
function parse_flow_node(sc)
  local ch = sc:peek()
  if ch == "{" then
    return parse_flow_mapping(sc)
  elseif ch == "[" then
    return parse_flow_sequence(sc)
  elseif ch == '"' then
    return parse_double(sc)
  elseif ch == "'" then
    return parse_single(sc)
  else
    local tok = sc:take_while(function(c)
      return c ~= "," and c ~= "}" and c ~= "]" and c ~= "\n"
    end)
    return coerce_plain(tok)
  end
end

--- Strip a trailing plain-scalar comment (" #...") that is not inside quotes.
--- Only applies to plain values; quoted/flow values are parsed structurally.
---@param s string
---@return string
local function strip_plain_comment(s)
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "#" and (i == 1 or is_space(s:sub(i - 1, i - 1))) then
      return rtrim(s:sub(1, i - 1))
    end
  end
  return s
end

--- Parse a value string that appears after `key:` on a single line.
---@param raw string
---@return any
local function parse_inline_value(raw)
  -- trim leading space
  local s = 1
  while s <= #raw and is_space(raw:sub(s, s)) do
    s = s + 1
  end
  raw = raw:sub(s)
  if raw == "" then
    return M.NULL
  end
  local first = raw:sub(1, 1)
  if first == "{" or first == "[" then
    return parse_flow_node(Scanner.new(raw))
  elseif first == '"' then
    return parse_double(Scanner.new(raw))
  elseif first == "'" then
    return parse_single(Scanner.new(raw))
  else
    return coerce_plain(strip_plain_comment(raw))
  end
end

--- Split a mapping line into its key and the trailing value string (or nil if
--- the value is on following lines). Handles quoted keys.
---@param sc lockfile.Scanner   # positioned at start of the (already de-indented) content
---@return string key
---@return string? value
local function split_key_value(content)
  local sc = Scanner.new(content)
  local key
  local ch = sc:peek()
  if ch == '"' then
    key = parse_double(sc)
  elseif ch == "'" then
    key = parse_single(sc)
  else
    -- plain key: up to the first ":" that is followed by space or EOL
    local buf = {}
    while not sc:eof() do
      local c = sc:peek()
      if c == ":" then
        local after = sc:peek(1)
        if after == nil or after == " " or after == "\t" then
          break
        end
      end
      buf[#buf + 1] = sc:next()
    end
    key = rtrim(table.concat(buf))
  end
  sc:skip_inline_space()
  if sc:peek() ~= ":" then
    -- No mapping separator: treat the whole line as a key with an empty value.
    return key, nil
  end
  sc:next() -- consume ':'
  -- remaining text (may be empty -> nested block follows)
  local rest = content:sub(sc.pos)
  -- trim leading inline space
  local t = 1
  while t <= #rest and is_space(rest:sub(t, t)) do
    t = t + 1
  end
  rest = rest:sub(t)
  rest = strip_plain_comment(rest)
  if rest == "" then
    return key, nil
  end
  return key, rest
end

------------------------------------------------------------------------------
-- Block structure
------------------------------------------------------------------------------

---@class lockfile.yaml.Parser
---@field lines {indent: integer, content: string}[]
---@field n integer
local Parser = {}
Parser.__index = Parser

--- Does the line at index `i` begin a sequence entry ("- ...")?
---@param i integer
---@return boolean
function Parser:is_dash(i)
  local content = self.lines[i].content
  return content == "-" or content:sub(1, 2) == "- "
end

--- Parse the node beginning at line `i` whose block indent is `indent`.
--- Returns the value and the index of the next unconsumed line.
---@param i integer
---@param indent integer
---@return any, integer
function Parser:parse_node(i, indent)
  if self:is_dash(i) then
    return self:parse_sequence(i, indent)
  end
  return self:parse_mapping(i, indent)
end

--- Parse a block mapping at the given indent.
---@param start integer
---@param indent integer
---@return table, integer
function Parser:parse_mapping(start, indent)
  local map = {}
  local i = start
  while i <= self.n do
    local line = self.lines[i]
    if line.indent ~= indent or self:is_dash(i) then
      break
    end
    local key, value = split_key_value(line.content)
    if value ~= nil then
      map[key] = parse_inline_value(value)
      i = i + 1
    else
      -- value is either a nested block (deeper indent) or empty
      local nxt = self.lines[i + 1]
      if nxt and nxt.indent > indent then
        local v, ni = self:parse_node(i + 1, nxt.indent)
        map[key] = v
        i = ni
      else
        map[key] = M.NULL
        i = i + 1
      end
    end
  end
  return map, i
end

--- Parse a block sequence at the given indent.
---@param start integer
---@param indent integer
---@return table, integer
function Parser:parse_sequence(start, indent)
  local seq = {}
  local i = start
  while i <= self.n do
    local line = self.lines[i]
    if line.indent ~= indent or not self:is_dash(i) then
      break
    end
    local content = line.content
    -- text after the dash
    local after = content == "-" and "" or content:sub(3)
    -- the column at which `after` begins (dash + following spaces)
    local lead = #content - #content:sub(3)
    local extra = 0
    while extra < #after and is_space(after:sub(extra + 1, extra + 1)) do
      extra = extra + 1
    end
    local item_indent = indent + lead + extra
    after = after:sub(extra + 1)

    if after == "" then
      local nxt = self.lines[i + 1]
      if nxt and nxt.indent > indent then
        local v, ni = self:parse_node(i + 1, nxt.indent)
        seq[#seq + 1] = v
        i = ni
      else
        seq[#seq + 1] = M.NULL
        i = i + 1
      end
    else
      -- Re-seat the current line as if `after` started at item_indent, then
      -- parse a node there (which will also consume aligned following lines).
      local saved = self.lines[i]
      self.lines[i] = { indent = item_indent, content = after }
      local v, ni = self:parse_node(i, item_indent)
      self.lines[i] = saved
      seq[#seq + 1] = v
      i = ni
    end
  end
  return seq, i
end

--- Parse a YAML document into a Lua value.
---@param src string
---@return any
function M.parse(src)
  local lines = logical_lines(src)
  if #lines == 0 then
    return {}
  end
  local p = setmetatable({ lines = lines, n = #lines }, Parser)
  local base = lines[1].indent
  local value = p:parse_node(1, base)
  return value
end

return M
