--- Dependency-graph analysis over the normalized model:
---   * builds forward/reverse adjacency by package name,
---   * answers "why is this package here?" with a shortest path from a root,
---   * flags suspicious changes on a diff report (major bumps, downgrades,
---     source-origin changes, same-version checksum changes, untrusted new
---     sources, and large transitive expansions).

local util = require("lockfile.util")

local M = {}

---@class lockfile.Graph
---@field forward table<string, table<string, boolean>>  # name -> set of dep names
---@field reverse table<string, table<string, boolean>>  # name -> set of dependent names
---@field roots table<string, boolean>                   # root package names
---@field parent table<string, string|false>             # BFS parent (false at a root)
local Graph = {}
Graph.__index = Graph

--- Build the dependency graph for a lockfile.
---@param lf lockfile.Lockfile
---@return lockfile.Graph
function M.build_graph(lf)
  local forward = {}
  local reverse = {}

  -- Ensure every package name has adjacency entries, including leaves.
  for name in pairs(lf.by_name) do
    forward[name] = forward[name] or {}
    reverse[name] = reverse[name] or {}
  end

  for _, pkg in ipairs(lf.packages) do
    for _, dep in ipairs(pkg.deps) do
      local target = dep.name
      -- Only record edges to packages actually present in this lockfile.
      if lf.by_name[target] and target ~= pkg.name then
        forward[pkg.name][target] = true
        reverse[target] = reverse[target] or {}
        reverse[target][pkg.name] = true
      end
    end
  end

  -- Determine root names.
  local roots = {}
  if #lf.roots > 0 then
    for _, id in ipairs(lf.roots) do
      local pkg = lf.by_id[id]
      if pkg then
        roots[pkg.name] = true
      end
    end
  end
  -- Fall back to in-degree-zero nodes when the format records no roots.
  if next(roots) == nil then
    for name in pairs(forward) do
      if next(reverse[name] or {}) == nil then
        roots[name] = true
      end
    end
  end

  local graph = setmetatable({
    forward = forward,
    reverse = reverse,
    roots = roots,
    parent = {},
  }, Graph)
  graph:compute_paths()
  return graph
end

--- Multi-source breadth-first search from the roots, recording a parent for
--- every reachable node so a shortest dependency path can be reconstructed.
function Graph:compute_paths()
  local parent = {}
  local queue = {}
  local head = 1
  for root in pairs(self.roots) do
    parent[root] = false
    queue[#queue + 1] = root
  end
  while head <= #queue do
    local node = queue[head]
    head = head + 1
    local neighbours = self.forward[node]
    if neighbours then
      -- iterate deterministically for stable paths
      local names = {}
      for n in pairs(neighbours) do
        names[#names + 1] = n
      end
      table.sort(names)
      for _, n in ipairs(names) do
        if parent[n] == nil then
          parent[n] = node
          queue[#queue + 1] = n
        end
      end
    end
  end
  self.parent = parent
end

--- The shortest dependency path from a root to `name`, as a list of names
--- (root first, `name` last), or nil if `name` is not reachable from any root.
---@param name string
---@return string[]?
function Graph:reason_path(name)
  if self.parent[name] == nil then
    return nil
  end
  local path = {}
  local cur = name
  while cur do
    table.insert(path, 1, cur)
    local p = self.parent[cur]
    if p == false or p == nil then
      break
    end
    cur = p
  end
  return path
end

--- The sorted list of packages that directly depend on `name`.
---@param name string
---@return string[]
function Graph:dependents(name)
  local out = {}
  for dep in pairs(self.reverse[name] or {}) do
    out[#out + 1] = dep
  end
  table.sort(out)
  return out
end

--- Is `name` a project root / direct dependency?
---@param name string
---@return boolean
function Graph:is_root(name)
  return self.roots[name] == true
end

--- Count newly-added packages within the forward closure of `name`, treating
--- `added` as the set of package names introduced by the diff.
---@param name string
---@param added table<string, boolean>
---@return integer
function Graph:added_in_closure(name, added)
  local count = 0
  local seen = { [name] = true }
  local stack = { name }
  while #stack > 0 do
    local cur = table.remove(stack)
    for n in pairs(self.forward[cur] or {}) do
      if not seen[n] then
        seen[n] = true
        if added[n] then
          count = count + 1
        end
        stack[#stack + 1] = n
      end
    end
  end
  return count
end

------------------------------------------------------------------------------
-- Suspicious-change flagging
------------------------------------------------------------------------------

---@class lockfile.Flag
---@field kind string                  # machine id, e.g. "major", "checksum"
---@field severity "high"|"warn"
---@field message string               # human-readable explanation

--- Append a flag to a change.
---@param change lockfile.Change
---@param kind string
---@param severity "high"|"warn"
---@param message string
local function add_flag(change, kind, severity, message)
  change.flags[#change.flags + 1] = { kind = kind, severity = severity, message = message }
end

--- Annotate a diff report in place: attach suspicious flags, transitive
--- reasons, and a stable, severity-aware ordering.
---@param report lockfile.Report
---@param config lockfile.Config
---@return lockfile.Report
function M.annotate(report, config)
  local an = config.analysis
  local new_graph = M.build_graph(report.new)
  local old_graph = M.build_graph(report.old)

  -- Set of package names added by this diff (for transitive-expansion sizing).
  local added = {}
  for _, change in ipairs(report.changes) do
    if change.kind == "added" then
      added[change.name] = true
    end
  end

  for _, change in ipairs(report.changes) do
    if change.kind == "updated" then
      if change.semver == "major" and an.flag_major then
        add_flag(change, "major", "warn", "major version bump (" .. change.old.version .. " → " .. change.new.version .. ")")
      elseif change.semver == "downgrade" and an.flag_downgrade then
        add_flag(change, "downgrade", "warn", "version downgrade (" .. change.old.version .. " → " .. change.new.version .. ")")
      end

      -- Origin (registry/git/url/path) change is a strong supply-chain signal.
      if an.flag_source_change and change.old and change.new then
        local ok = util.source_kind(change.old.source)
        local nk = util.source_kind(change.new.source)
        if ok ~= nk then
          add_flag(change, "source_change", "high", "source origin changed (" .. ok .. " → " .. nk .. ")")
        end
      end

      -- Same version, different checksum: tampering.
      if an.flag_checksum_change and change.semver == "none" and change.old and change.new then
        if change.old.checksum and change.new.checksum and change.old.checksum ~= change.new.checksum then
          add_flag(change, "checksum", "high", "checksum changed for an unchanged version")
        end
      end
    elseif change.kind == "added" then
      if an.flag_new_git_source and change.new then
        local kind = util.source_kind(change.new.source)
        if kind == "git" or kind == "url" then
          add_flag(change, "new_source", "warn", "new package pulled from a " .. kind .. " source")
        end
      end
      if an.big_transitive_threshold and an.big_transitive_threshold > 0 then
        local n = new_graph:added_in_closure(change.name, added)
        if n >= an.big_transitive_threshold then
          add_flag(change, "big_transitive", "warn", "introduces " .. n .. " new transitive dependencies")
        end
      end
    end

    -- Transitive reason ("why is this here") from the relevant graph.
    if change.kind == "removed" then
      change.reason_path = old_graph:reason_path(change.name)
      change.dependents = old_graph:dependents(change.name)
    else
      change.reason_path = new_graph:reason_path(change.name)
      change.dependents = new_graph:dependents(change.name)
    end
  end

  -- Recount suspicious and sort.
  report.summary.suspicious = 0
  for _, change in ipairs(report.changes) do
    if #change.flags > 0 then
      report.summary.suspicious = report.summary.suspicious + 1
    end
  end

  M.sort(report)
  return report
end

--- Severity rank for ordering (lower sorts first).
---@param change lockfile.Change
---@return integer
local function severity_rank(change)
  local rank = 3
  for _, f in ipairs(change.flags) do
    if f.severity == "high" then
      return 0
    elseif f.severity == "warn" then
      rank = math.min(rank, 1)
    end
  end
  return rank
end

local KIND_RANK = { updated = 0, added = 1, removed = 2 }

--- Sort changes: most suspicious first, then by kind, then by name.
---@param report lockfile.Report
function M.sort(report)
  table.sort(report.changes, function(a, b)
    local sa, sb = severity_rank(a), severity_rank(b)
    if sa ~= sb then
      return sa < sb
    end
    local ka, kb = KIND_RANK[a.kind] or 9, KIND_RANK[b.kind] or 9
    if ka ~= kb then
      return ka < kb
    end
    return a.name < b.name
  end)
end

M.Graph = Graph

return M
