//! Version comparison and change classification.
//!
//! Lockfile ecosystems use two distinct versioning schemes, so we dispatch by
//! format and lean on the canonical crates rather than re-implementing them:
//!   * SemVer 2.0 (Cargo, npm, pnpm, yarn, Go) via the `semver` crate. Go
//!     versions carry a leading `v`, which is stripped first.
//!   * PEP 440 (poetry, uv) via the `pep440_rs` crate.
//!
//! Formats with opaque version identifiers (lazy-lock.json commit SHAs) never
//! reach here for classification; the Lua layer marks them non-semver.

use std::cmp::Ordering;
use std::str::FromStr;

/// The versioning scheme a lockfile format uses.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Scheme {
    Semver,
    Pep440,
}

/// The scheme for a given lockfile format id.
fn scheme(kind: &str) -> Scheme {
    match kind {
        "poetry" | "uv" => Scheme::Pep440,
        _ => Scheme::Semver,
    }
}

/// Parse a SemVer version, tolerating a leading `v` (Go).
fn parse_semver(s: &str) -> Option<semver::Version> {
    semver::Version::parse(s.strip_prefix('v').unwrap_or(s)).ok()
}

/// Compare two version strings under the format's scheme. Falls back to a byte
/// comparison when a version is unparseable, so the result is always a total
/// order (used for sorting/representative selection).
pub fn compare(kind: &str, a: &str, b: &str) -> i32 {
    let ord = match scheme(kind) {
        Scheme::Semver => match (parse_semver(a), parse_semver(b)) {
            (Some(x), Some(y)) => x.cmp(&y),
            _ => a.cmp(b),
        },
        Scheme::Pep440 => match (
            pep440_rs::Version::from_str(a),
            pep440_rs::Version::from_str(b),
        ) {
            (Ok(x), Ok(y)) => x.cmp(&y),
            _ => a.cmp(b),
        },
    };
    match ord {
        Ordering::Less => -1,
        Ordering::Equal => 0,
        Ordering::Greater => 1,
    }
}

/// Which of the first three release segments differs first, given two segment
/// lists (missing segments are treated as zero).
fn segment_change(a: &[u64], b: &[u64]) -> &'static str {
    for i in 0..3 {
        if a.get(i).copied().unwrap_or(0) != b.get(i).copied().unwrap_or(0) {
            return ["major", "minor", "patch"][i];
        }
    }
    // Release tuple identical: the difference is in a pre/post/dev/build part.
    "prerelease"
}

fn classify_semver(old: &str, new: &str) -> &'static str {
    let (Some(a), Some(b)) = (parse_semver(old), parse_semver(new)) else {
        return "other";
    };
    match a.cmp(&b) {
        Ordering::Equal => "none",
        Ordering::Greater => "downgrade",
        Ordering::Less => {
            segment_change(&[a.major, a.minor, a.patch], &[b.major, b.minor, b.patch])
        }
    }
}

fn classify_pep440(old: &str, new: &str) -> &'static str {
    let (Ok(a), Ok(b)) = (
        pep440_rs::Version::from_str(old),
        pep440_rs::Version::from_str(new),
    ) else {
        return "other";
    };
    match a.cmp(&b) {
        Ordering::Equal => "none",
        Ordering::Greater => "downgrade",
        Ordering::Less => segment_change(a.release(), b.release()),
    }
}

/// Classify the change from `old` to `new` under the format's scheme. Returns
/// one of: "major", "minor", "patch", "prerelease", "downgrade", "none",
/// "other" (unparseable).
pub fn classify(kind: &str, old: &str, new: &str) -> &'static str {
    if old == new {
        return "none";
    }
    match scheme(kind) {
        Scheme::Semver => classify_semver(old, new),
        Scheme::Pep440 => classify_pep440(old, new),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semver_classification() {
        assert_eq!(classify("cargo", "1.0.0", "2.0.0"), "major");
        assert_eq!(classify("npm", "1.2.0", "1.3.0"), "minor");
        assert_eq!(classify("npm", "1.2.3", "1.2.4"), "patch");
        assert_eq!(classify("cargo", "2.0.0", "1.0.0"), "downgrade");
        assert_eq!(classify("cargo", "1.2.3", "1.2.3"), "none");
        assert_eq!(classify("cargo", "0.1.0", "0.2.0"), "minor");
        assert_eq!(classify("npm", "1.0.0-alpha", "1.0.0"), "prerelease");
        assert_eq!(classify("cargo", "abc", "def"), "other");
    }

    #[test]
    fn go_v_prefix() {
        assert_eq!(classify("go", "v1.2.3", "v2.0.0"), "major");
        assert!(compare("go", "v2.0.0", "v1.0.0") > 0);
    }

    #[test]
    fn pep440_classification() {
        assert_eq!(classify("poetry", "1.0.0", "2.0.0"), "major");
        assert_eq!(classify("uv", "1.2.0", "1.3.0"), "minor");
        assert_eq!(classify("poetry", "2.0.0", "1.0.0"), "downgrade");
        assert_eq!(classify("uv", "23.0", "23.0"), "none");
        // Two-segment and rc versions that the SemVer crate would reject.
        assert_eq!(classify("uv", "23.0", "24.0"), "major");
        assert_eq!(classify("poetry", "1.0.0rc1", "1.0.0"), "prerelease");
    }

    #[test]
    fn ordering() {
        assert!(compare("cargo", "2.0.0", "1.0.0") > 0);
        assert!(compare("cargo", "1.0.0-alpha", "1.0.0") < 0);
        assert_eq!(compare("cargo", "1.0.0", "1.0.0"), 0);
        assert!(compare("uv", "1.0.0rc1", "1.0.0") < 0);
        // Unparseable falls back to byte comparison (total order, no panic).
        assert_eq!(compare("cargo", "zzz", "zzz"), 0);
    }
}
