//! lazy-lock.json -> normalized model.
//!
//! lazy.nvim's lockfile is a flat JSON object mapping a plugin name to its
//! pinned state: `{ "plugin": { "branch": "main", "commit": "<sha>" } }`. It
//! records no dependency graph, so `supports_graph = false`. The resolved
//! commit SHA is the package's identifying "version"; the branch is kept as the
//! source so a branch switch is visible.

use std::collections::HashMap;

use serde::Deserialize;

use crate::model::{Lockfile, Package};

#[derive(Deserialize)]
struct LazyEntry {
    branch: Option<String>,
    commit: Option<String>,
    version: Option<String>,
}

pub fn parse(src: &str) -> Result<Lockfile, String> {
    let map: HashMap<String, LazyEntry> =
        serde_json::from_str(src).map_err(|e| format!("invalid lazy-lock.json: {e}"))?;

    let mut lf = Lockfile::new("lazy");
    lf.supports_graph = false;
    // Commit SHAs are opaque identities, not ordered versions.
    lf.semver_versions = false;

    for (name, entry) in map {
        let LazyEntry {
            branch,
            commit,
            version,
        } = entry;
        // Prefer the resolved commit as the identity; fall back to a pinned
        // version tag, then the branch, for unusual/partial entries.
        let resolved = commit.or(version).or_else(|| branch.clone());
        let Some(resolved) = resolved else { continue };
        if resolved.is_empty() {
            continue;
        }
        let mut pkg = Package::new(&name, &resolved);
        pkg.source = branch;
        lf.push(pkg);
    }

    Ok(lf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plugins_with_commits() {
        let src = r#"
        {
          "lazy.nvim": { "branch": "main", "commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
          "telescope.nvim": { "branch": "master", "commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
        }
        "#;
        let lf = parse(src).unwrap();
        assert!(!lf.supports_graph);
        assert_eq!(lf.packages.len(), 2);

        let lazy = lf.packages.iter().find(|p| p.name == "lazy.nvim").unwrap();
        assert_eq!(lazy.version, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        assert_eq!(lazy.source.as_deref(), Some("main"));
    }

    #[test]
    fn skips_entries_without_a_commit_or_version() {
        let src = r#"{ "broken": { "branch": "main" }, "ok": { "commit": "cafe" } }"#;
        let lf = parse(src).unwrap();
        // "broken" falls back to its branch ("main"); "ok" uses its commit.
        assert_eq!(lf.packages.len(), 2);
        let broken = lf.packages.iter().find(|p| p.name == "broken").unwrap();
        assert_eq!(broken.version, "main");
    }
}
