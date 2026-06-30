--- A small hand-written character scanner used as the shared primitive for all
--- of lockfile.nvim's parsers. It deliberately avoids regular expressions:
--- every parser in this plugin is implemented as hand-written recursive descent
--- on top of this cursor.
---
--- The scanner tracks byte position as well as line/column so that parse errors
--- can point at a precise location in the source.

---@class lockfile.Scanner
---@field src string         # the full source being scanned
---@field pos integer        # 1-based index of the next unread byte
---@field len integer        # byte length of `src`
---@field line integer       # 1-based current line
---@field col integer        # 1-based current column
local Scanner = {}
Scanner.__index = Scanner

--- Create a new scanner over `src`.
---@param src string
---@return lockfile.Scanner
function Scanner.new(src)
  return setmetatable({
    src = src,
    pos = 1,
    len = #src,
    line = 1,
    col = 1,
  }, Scanner)
end

--- Has the scanner consumed all input?
---@return boolean
function Scanner:eof()
  return self.pos > self.len
end

--- Return the character at the current position + `offset` (default 0) without
--- consuming it. Returns nil past end of input.
---@param offset integer?
---@return string?
function Scanner:peek(offset)
  local i = self.pos + (offset or 0)
  if i < 1 or i > self.len then
    return nil
  end
  return self.src:sub(i, i)
end

--- Return the byte value at the current position + `offset`, or nil at EOF.
---@param offset integer?
---@return integer?
function Scanner:byte(offset)
  local i = self.pos + (offset or 0)
  if i < 1 or i > self.len then
    return nil
  end
  return self.src:byte(i)
end

--- Consume and return a single character, advancing line/column bookkeeping.
---@return string?
function Scanner:next()
  if self.pos > self.len then
    return nil
  end
  local ch = self.src:sub(self.pos, self.pos)
  self.pos = self.pos + 1
  if ch == "\n" then
    self.line = self.line + 1
    self.col = 1
  else
    self.col = self.col + 1
  end
  return ch
end

--- Advance by `n` characters (default 1), maintaining line/column counts.
---@param n integer?
function Scanner:advance(n)
  n = n or 1
  for _ = 1, n do
    if self.pos > self.len then
      return
    end
    self:next()
  end
end

--- Does the upcoming input start with the literal string `s`?
---@param s string
---@return boolean
function Scanner:starts_with(s)
  return self.src:sub(self.pos, self.pos + #s - 1) == s
end

--- If the upcoming input starts with `s`, consume it and return true.
---@param s string
---@return boolean
function Scanner:consume(s)
  if self:starts_with(s) then
    self:advance(#s)
    return true
  end
  return false
end

--- Consume characters while `pred(char)` is true and return the consumed run.
---@param pred fun(ch: string): boolean
---@return string
function Scanner:take_while(pred)
  local start = self.pos
  while self.pos <= self.len do
    local ch = self.src:sub(self.pos, self.pos)
    if not pred(ch) then
      break
    end
    self:next()
  end
  return self.src:sub(start, self.pos - 1)
end

--- Consume characters until `ch` (exclusive) or EOF; return the consumed run.
---@param ch string  # single character sentinel
---@return string
function Scanner:take_until(ch)
  return self:take_while(function(c)
    return c ~= ch
  end)
end

--- Consume spaces and tabs (not newlines).
function Scanner:skip_inline_space()
  self:take_while(function(c)
    return c == " " or c == "\t"
  end)
end

--- Consume any run of whitespace including newlines.
function Scanner:skip_space()
  self:take_while(function(c)
    return c == " " or c == "\t" or c == "\r" or c == "\n"
  end)
end

--- Consume up to and including the next newline (or to EOF). Returns the line
--- contents without the trailing newline.
---@return string
function Scanner:take_line()
  local line = self:take_while(function(c)
    return c ~= "\n"
  end)
  -- strip a trailing carriage return for CRLF inputs
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  if self:peek() == "\n" then
    self:next()
  end
  return line
end

--- Require the literal `s` next; raise a structured parse error otherwise.
---@param s string
function Scanner:expect(s)
  if not self:consume(s) then
    self:error(("expected %q"):format(s))
  end
end

--- Raise a parse error carrying line/column information. Errors are raised as
--- Lua error objects (tables) so callers can distinguish them from arbitrary
--- runtime errors via `err.lockfile_parse_error`.
---@param msg string
function Scanner:error(msg)
  error({
    lockfile_parse_error = true,
    msg = msg,
    line = self.line,
    col = self.col,
    pos = self.pos,
  }, 0)
end

return Scanner
