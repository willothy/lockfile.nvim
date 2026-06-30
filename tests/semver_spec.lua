-- Tests for the version classifier.

return function(T)
  local semver = require("lockfile.semver")

  T.eq(semver.classify("1.0.0", "2.0.0"), "major", "major bump")
  T.eq(semver.classify("1.2.0", "1.3.0"), "minor", "minor bump")
  T.eq(semver.classify("1.2.3", "1.2.4"), "patch", "patch bump")
  T.eq(semver.classify("2.0.0", "1.0.0"), "downgrade", "downgrade")
  T.eq(semver.classify("1.2.3", "1.2.3"), "none", "no change")
  T.eq(semver.classify("0.1.0", "0.2.0"), "minor", "0.x minor")
  T.eq(semver.classify("1.0.0-alpha", "1.0.0"), "prerelease", "prerelease to release")

  -- Go-style "v" prefix.
  T.eq(semver.classify("v1.2.3", "v2.0.0"), "major", "go v-prefix major")

  -- PEP 440-ish.
  T.eq(semver.classify("1.0.0", "1.0.1"), "patch", "pep patch")

  -- Non-semver inputs fall back to "other" when unparseable.
  T.eq(semver.classify("abc", "def"), "other", "unparseable")

  -- Ordering.
  T.ok(semver.compare_strings("2.0.0", "1.0.0") > 0, "2.0.0 > 1.0.0")
  T.ok(semver.compare_strings("1.0.0-alpha", "1.0.0") < 0, "prerelease < release")
  T.ok(semver.compare_strings("1.0.0", "1.0.0") == 0, "equal")
  T.ok(semver.compare_strings("1.0.0-alpha.1", "1.0.0-alpha.2") < 0, "prerelease numeric ordering")
end
