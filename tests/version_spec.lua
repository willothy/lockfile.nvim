-- Tests for the native-backed version classifier (exercises the Lua shim and
-- the Rust semver/pep440 dispatch end to end).

return function(T)
  local version = require("lockfile.version")

  -- SemVer family.
  T.eq(version.classify("cargo", "1.0.0", "2.0.0"), "major", "cargo major")
  T.eq(version.classify("npm", "1.2.0", "1.3.0"), "minor", "npm minor")
  T.eq(version.classify("npm", "1.2.3", "1.2.4"), "patch", "npm patch")
  T.eq(version.classify("cargo", "2.0.0", "1.0.0"), "downgrade", "cargo downgrade")
  T.eq(version.classify("cargo", "1.0.0", "1.0.0"), "none", "cargo no change")
  T.eq(version.classify("npm", "1.0.0-alpha", "1.0.0"), "prerelease", "prerelease to release")
  T.eq(version.classify("cargo", "zzz", "qqq"), "other", "unparseable -> other")

  -- Go (leading v).
  T.eq(version.classify("go", "v1.2.3", "v2.0.0"), "major", "go v-prefix major")

  -- PEP 440 (poetry/uv) — versions the SemVer crate would reject.
  T.eq(version.classify("uv", "23.0", "24.0"), "major", "pep440 two-segment major")
  T.eq(version.classify("poetry", "1.0.0rc1", "1.0.0"), "prerelease", "pep440 rc to release")
  T.eq(version.classify("uv", "2.0.0", "1.0.0"), "downgrade", "pep440 downgrade")

  -- Ordering.
  T.ok(version.compare("cargo", "2.0.0", "1.0.0") > 0, "2.0.0 > 1.0.0")
  T.ok(version.compare("cargo", "1.0.0-alpha", "1.0.0") < 0, "prerelease < release")
  T.ok(version.compare("uv", "1.0.0rc1", "1.0.0") < 0, "pep440 rc < release")
  T.eq(version.compare("cargo", "1.0.0", "1.0.0"), 0, "equal")
end
