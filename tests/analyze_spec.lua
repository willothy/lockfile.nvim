-- Tests for dependency-graph analysis and suspicious-change flagging.

return function(T)
  local model = require("lockfile.model")
  local diff = require("lockfile.diff")
  local analyze = require("lockfile.analyze")
  local config = require("lockfile.config")

  local cfg = config.defaults()

  local function build(kind, packages, roots, supports_graph)
    local lf = model.new(kind)
    if supports_graph ~= nil then
      lf.supports_graph = supports_graph
    end
    for _, p in ipairs(packages) do
      lf:add(p)
    end
    for _, r in ipairs(roots or {}) do
      lf:add_root(r)
    end
    return lf
  end

  local function change_for(report, name)
    for _, c in ipairs(report.changes) do
      if c.name == name then
        return c
      end
    end
  end

  local function has_flag(change, kind)
    for _, f in ipairs(change.flags) do
      if f.kind == kind then
        return f
      end
    end
  end

  -- Graph + reason path.
  do
    local lf = build("cargo", {
      { name = "app", version = "1.0.0", deps = { { name = "mid" } } },
      { name = "mid", version = "1.0.0", deps = { { name = "leaf" } } },
      { name = "leaf", version = "1.0.0" },
    }, { "app@1.0.0" })
    local g = analyze.build_graph(lf)
    T.eq(g:reason_path("leaf"), { "app", "mid", "leaf" }, "reason path app->mid->leaf")
    T.eq(g:dependents("leaf"), { "mid" }, "leaf dependents")
    T.ok(g:is_root("app"), "app is root")
  end

  -- Suspicious flags.
  do
    local old = build("cargo", {
      { name = "app", version = "1.0.0", deps = { { name = "serde" }, { name = "tok" } } },
      { name = "serde", version = "1.0.0", source = "registry+https://x", checksum = "a" },
      { name = "tok", version = "1.0.0", source = "registry+https://x", checksum = "old" },
    }, { "app@1.0.0" })
    local new = build("cargo", {
      { name = "app", version = "1.0.0", deps = { { name = "serde" }, { name = "tok" }, { name = "evil" } } },
      { name = "serde", version = "2.0.0", source = "git+https://x", checksum = "b" },
      { name = "tok", version = "1.0.0", source = "registry+https://x", checksum = "new" },
      { name = "evil", version = "0.1.0", source = "git+https://evil#abc" },
    }, { "app@1.0.0" })

    local report = diff.diff(old, new)
    analyze.annotate(report, cfg)

    local serde = change_for(report, "serde")
    T.ok(has_flag(serde, "major"), "serde major flagged")
    T.ok(has_flag(serde, "source_change"), "serde source change flagged")

    local tok = change_for(report, "tok")
    T.ok(has_flag(tok, "checksum"), "tok checksum tamper flagged")

    local evil = change_for(report, "evil")
    T.ok(has_flag(evil, "new_source"), "evil new git source flagged")

    -- The high-severity tamper/source change sort to the very top.
    T.ok(#report.changes > 0, "has changes")
    T.ok(report.changes[1].name == "serde" or report.changes[1].name == "tok", "high severity first")
  end

  -- Big transitive expansion.
  do
    local old = build("cargo", { { name = "app", version = "1.0.0", deps = {} } }, { "app@1.0.0" })
    local pkgs = {
      { name = "app", version = "1.0.0", deps = { { name = "big" } } },
      { name = "big", version = "1.0.0", deps = {} },
    }
    for i = 1, 12 do
      table.insert(pkgs[2].deps, { name = "t" .. i })
      table.insert(pkgs, { name = "t" .. i, version = "1.0.0" })
    end
    local new = build("cargo", pkgs, { "app@1.0.0" })
    local report = diff.diff(old, new)
    analyze.annotate(report, cfg)
    local big = change_for(report, "big")
    T.ok(has_flag(big, "big_transitive"), "big transitive expansion flagged")
  end

  -- go.sum-style: no graph -> no reason path, no crash.
  do
    local old = build("go", { { name = "m", version = "v1.0.0", checksum = "a" } }, {}, false)
    local new = build("go", { { name = "m", version = "v1.0.0", checksum = "b" } }, {}, false)
    local report = diff.diff(old, new)
    analyze.annotate(report, cfg)
    local m = change_for(report, "m")
    T.ok(m ~= nil, "go checksum change detected")
    T.ok(has_flag(m, "checksum"), "go checksum tamper flagged")
  end
end
