-- Tests for the lockfile diff engine.

return function(T)
  local model = require("lockfile.model")
  local diff = require("lockfile.diff")

  --- Build a lockfile from a compact spec.
  local function build(kind, packages, roots)
    local lf = model.new(kind)
    for _, p in ipairs(packages) do
      lf:add(p)
    end
    for _, r in ipairs(roots or {}) do
      lf:add_root(r)
    end
    return lf
  end

  --- Find the change for a package name.
  local function change_for(report, name)
    for _, c in ipairs(report.changes) do
      if c.name == name then
        return c
      end
    end
    return nil
  end

  local old = build("cargo", {
    { name = "keep", version = "1.0.0", checksum = "k" },
    { name = "gone", version = "1.0.0" },
    { name = "bump", version = "1.0.0" },
    { name = "tamper", version = "1.0.0", checksum = "old" },
  })
  local new = build("cargo", {
    { name = "keep", version = "1.0.0", checksum = "k" },
    { name = "added", version = "0.1.0" },
    { name = "bump", version = "2.0.0" },
    { name = "tamper", version = "1.0.0", checksum = "new" },
  })

  local report = diff.diff(old, new)

  T.eq(report.summary.added, 1, "one added")
  T.eq(report.summary.removed, 1, "one removed")
  -- bump (version) and tamper (same version, checksum) are both "updated".
  T.eq(report.summary.updated, 2, "two updated")

  T.eq(change_for(report, "added").kind, "added", "added kind")
  T.eq(change_for(report, "gone").kind, "removed", "removed kind")

  local bump = change_for(report, "bump")
  T.eq(bump.kind, "updated", "bump updated")
  T.eq(bump.semver, "major", "bump major")
  T.eq(bump.old_versions, { "1.0.0" }, "bump old version")
  T.eq(bump.new_versions, { "2.0.0" }, "bump new version")

  local tamper = change_for(report, "tamper")
  T.eq(tamper.kind, "updated", "tamper detected as updated")
  T.eq(tamper.semver, "none", "tamper same version")

  -- "keep" is unchanged and must not appear.
  T.ok(change_for(report, "keep") == nil, "unchanged package omitted")

  -- Opaque-version formats (e.g. lazy-lock.json commit SHAs) are reported as
  -- "changed", never semver-classified as a bump.
  local lo = build("lazy", { { name = "p", version = "1abc" } })
  lo.semver_versions = false
  local ln = build("lazy", { { name = "p", version = "9def" } })
  ln.semver_versions = false
  local lazy_report = diff.diff(lo, ln)
  T.eq(change_for(lazy_report, "p").semver, "changed", "opaque version change not classified")

  -- Multiple versions of one name: descending order.
  local mv_old = build("npm", { { name = "x", version = "1.0.0" } })
  local mv_new = build("npm", {
    { name = "x", version = "1.0.0" },
    { name = "x", version = "2.0.0" },
  })
  local mv = diff.diff(mv_old, mv_new)
  T.eq(change_for(mv, "x").new_versions, { "2.0.0", "1.0.0" }, "versions sorted descending")
end
