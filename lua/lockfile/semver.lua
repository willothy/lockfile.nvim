--- A tolerant semantic-version parser and comparator.
---
--- Lockfiles across ecosystems use versions that are *mostly* semver but with
--- quirks: Go prefixes with "v", Python uses PEP 440 (epochs, post/dev
--- releases), and plenty of packages ship two- or four-segment versions. This
--- module parses what it can and degrades gracefully, exposing enough structure
--- to classify a change as major / minor / patch / prerelease / downgrade.
---
--- Parsing is hand-written (no regex), consistent with the rest of the plugin.

local M = {}

---@class lockfile.SemVer
---@field epoch integer            # PEP 440 epoch (0 when absent)
---@field release integer[]        # numeric release segments, e.g. {1,2,3}
---@field pre (string|integer)[]?  # pre-release identifiers, nil if none
---@field raw string               # the original string

--- Is `ch` an ASCII digit?
---@param ch string?
---@return boolean
local function is_digit(ch)
  return ch ~= nil and ch >= "0" and ch <= "9"
end

--- Split a dotted identifier list (the prerelease portion) into identifiers,
--- coercing all-numeric identifiers to integers for correct numeric ordering.
---@param s string
---@return (string|integer)[]
local function split_pre(s)
  local parts = {}
  local buf = {}
  local function flush()
    local id = table.concat(buf)
    buf = {}
    if id == "" then
      return
    end
    -- numeric identifiers compare numerically per semver spec
    local all_digits = true
    for i = 1, #id do
      local c = id:sub(i, i)
      if not is_digit(c) then
        all_digits = false
        break
      end
    end
    table.insert(parts, all_digits and tonumber(id) or id)
  end
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "." then
      flush()
    else
      table.insert(buf, c)
    end
  end
  flush()
  return parts
end

--- Parse a version string into a structured `lockfile.SemVer`, or nil if it
--- has no recognizable numeric release component.
---@param str string
---@return lockfile.SemVer?
function M.parse(str)
  if type(str) ~= "string" or str == "" then
    return nil
  end
  local raw = str
  local s = str

  -- Strip a single leading "v" / "V" (Go modules, some npm tags).
  if s:sub(1, 1) == "v" or s:sub(1, 1) == "V" then
    s = s:sub(2)
  end

  local epoch = 0
  -- PEP 440 epoch: "N!" prefix.
  do
    local bang = s:find("!", 1, true)
    if bang then
      local maybe = s:sub(1, bang - 1)
      -- accept only if `maybe` is all digits
      local all_digits = #maybe > 0
      for i = 1, #maybe do
        if not is_digit(maybe:sub(i, i)) then
          all_digits = false
          break
        end
      end
      if all_digits then
        epoch = tonumber(maybe) --[[@as integer]]
        s = s:sub(bang + 1)
      end
    end
  end

  -- Separate release/prerelease (before any "+build" metadata).
  local plus = s:find("+", 1, true)
  if plus then
    s = s:sub(1, plus - 1)
  end

  -- Split off prerelease on "-" (semver) — but only the first hyphen.
  local pre_str
  local dash = s:find("-", 1, true)
  if dash then
    pre_str = s:sub(dash + 1)
    s = s:sub(1, dash - 1)
  end

  -- Parse dotted numeric release segments. Stop at the first non-numeric
  -- segment and treat the remainder (e.g. PEP 440 "rc1", "post2", "dev3",
  -- or "1.2.3a1") as prerelease information.
  local release = {}
  local rest = ""
  local idx = 1
  while idx <= #s do
    -- read a run of digits
    local start = idx
    while idx <= #s and is_digit(s:sub(idx, idx)) do
      idx = idx + 1
    end
    if idx == start then
      -- not a digit where a segment was expected: bail into `rest`
      rest = s:sub(idx)
      break
    end
    table.insert(release, tonumber(s:sub(start, idx - 1)))
    local sep = s:sub(idx, idx)
    if sep == "." then
      idx = idx + 1
    elseif sep == "" then
      break
    else
      -- e.g. "1.2.3rc1" -> release {1,2,3} but here the non-dot trails a number
      rest = s:sub(idx)
      break
    end
  end

  if #release == 0 then
    return nil
  end

  -- Combine any PEP-440-style trailing text with the semver prerelease.
  local pre = nil
  if pre_str and pre_str ~= "" then
    pre = split_pre(pre_str)
  end
  if rest ~= "" then
    local extra = split_pre(rest)
    if pre then
      for _, v in ipairs(extra) do
        table.insert(pre, v)
      end
    else
      pre = extra
    end
  end

  return {
    epoch = epoch,
    release = release,
    pre = pre,
    raw = raw,
  }
end

--- Compare two release tuples, padding the shorter with zeros.
---@param a integer[]
---@param b integer[]
---@return integer  # -1, 0, 1
local function cmp_release(a, b)
  local n = math.max(#a, #b)
  for i = 1, n do
    local x = a[i] or 0
    local y = b[i] or 0
    if x < y then
      return -1
    elseif x > y then
      return 1
    end
  end
  return 0
end

--- Compare prerelease identifier lists per semver rules. A version with no
--- prerelease outranks one that has a prerelease.
---@param a (string|integer)[]?
---@param b (string|integer)[]?
---@return integer
local function cmp_pre(a, b)
  if not a and not b then
    return 0
  end
  if not a then
    return 1 -- a is a release, outranks prerelease b
  end
  if not b then
    return -1
  end
  local n = math.max(#a, #b)
  for i = 1, n do
    local x = a[i]
    local y = b[i]
    if x == nil then
      return -1 -- shorter prerelease is lower
    end
    if y == nil then
      return 1
    end
    local xn = type(x) == "number"
    local yn = type(y) == "number"
    if xn and yn then
      if x < y then
        return -1
      elseif x > y then
        return 1
      end
    elseif xn ~= yn then
      -- numeric identifiers always have lower precedence than alphanumeric
      return xn and -1 or 1
    else
      if x < y then
        return -1
      elseif x > y then
        return 1
      end
    end
  end
  return 0
end

--- Compare two parsed versions. Returns -1, 0, or 1.
---@param a lockfile.SemVer
---@param b lockfile.SemVer
---@return integer
function M.compare(a, b)
  if a.epoch ~= b.epoch then
    return a.epoch < b.epoch and -1 or 1
  end
  local r = cmp_release(a.release, b.release)
  if r ~= 0 then
    return r
  end
  return cmp_pre(a.pre, b.pre)
end

--- Compare two version *strings*, parsing where possible and falling back to a
--- byte comparison for non-semver inputs. Returns -1, 0, or 1.
---@param a string
---@param b string
---@return integer
function M.compare_strings(a, b)
  if a == b then
    return 0
  end
  local pa, pb = M.parse(a), M.parse(b)
  if pa and pb then
    return M.compare(pa, pb)
  end
  return a < b and -1 or 1
end

--- "changed" is used by callers for formats whose versions are opaque (not
--- semver), where a difference is detectable but not classifiable.
---@alias lockfile.VersionChange "major"|"minor"|"patch"|"prerelease"|"downgrade"|"none"|"other"|"changed"

--- Classify the change from version `old` to version `new`.
---
--- Returns one of: "major", "minor", "patch", "prerelease", "downgrade",
--- "none", or "other" (when versions are not comparable as semver).
---@param old string
---@param new string
---@return lockfile.VersionChange
function M.classify(old, new)
  if old == new then
    return "none"
  end
  local a = M.parse(old)
  local b = M.parse(new)
  if not a or not b then
    return "other"
  end

  local c = M.compare(a, b)
  if c == 0 then
    return "none"
  elseif c > 0 then
    return "downgrade"
  end

  -- Upgrade: determine which release segment changed first.
  local maj_a, maj_b = a.release[1] or 0, b.release[1] or 0
  if maj_a ~= maj_b then
    -- A 0.x bump is conventionally treated like a major (breaking) change in
    -- the leading nonzero segment, but the first segment differing is "major".
    return "major"
  end
  local min_a, min_b = a.release[2] or 0, b.release[2] or 0
  if min_a ~= min_b then
    return "minor"
  end
  local pat_a, pat_b = a.release[3] or 0, b.release[3] or 0
  if pat_a ~= pat_b then
    return "patch"
  end
  -- Release tuple identical: difference is in further segments or prerelease.
  if (a.pre ~= nil) ~= (b.pre ~= nil) or a.pre or b.pre then
    return "prerelease"
  end
  return "patch"
end

return M
