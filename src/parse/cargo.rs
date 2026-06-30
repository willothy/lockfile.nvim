//! Cargo.lock -> normalized model.
//!
//! Cargo.lock is TOML with an array of `[[package]]` tables. Dependency edges
//! are strings of the form "name", "name version", or "name version (source)".
//! Checksums live on the package (modern) or in a `[metadata]` table keyed
//! "checksum name version (source)" (lockfile v1/v2).

use std::collections::HashMap;

use serde::Deserialize;

use crate::model::{Dep, Lockfile, Package, make_id};

#[derive(Deserialize)]
struct CargoLock {
    version: Option<toml::Value>,
    #[serde(default)]
    package: Vec<CargoPackage>,
    #[serde(default)]
    metadata: HashMap<String, String>,
}

#[derive(Deserialize)]
struct CargoPackage {
    name: String,
    version: String,
    source: Option<String>,
    checksum: Option<String>,
    #[serde(default)]
    dependencies: Vec<String>,
}

/// Parse one Cargo dependency string into a dependency edge.
fn parse_dep(s: &str) -> Dep {
    let mut parts = s.split_whitespace();
    let name = parts.next().unwrap_or("").to_string();
    match parts.next() {
        // A "(source)" token is not a version.
        Some(v) if !v.starts_with('(') => Dep::pinned(name, v),
        _ => Dep::by_name(name),
    }
}

/// Stringify the lockfile `version` field, which may be an integer or string.
fn version_string(v: &toml::Value) -> String {
    match v {
        toml::Value::String(s) => s.clone(),
        toml::Value::Integer(i) => i.to_string(),
        other => other.to_string(),
    }
}

pub fn parse(src: &str) -> Result<Lockfile, String> {
    let doc: CargoLock = toml::from_str(src).map_err(|e| format!("invalid Cargo.lock: {e}"))?;

    let mut lf = Lockfile::new("cargo");
    lf.format_version = doc.version.as_ref().map(version_string);

    // Checksums stored in the legacy [metadata] table.
    let mut meta_checksums: HashMap<String, String> = HashMap::new();
    for (key, value) in &doc.metadata {
        if let Some(rest) = key.strip_prefix("checksum ") {
            let mut it = rest.split_whitespace();
            if let (Some(name), Some(version)) = (it.next(), it.next()) {
                meta_checksums.insert(make_id(name, version), value.clone());
            }
        }
    }

    for p in doc.package {
        let mut pkg = Package::new(&p.name, &p.version);
        pkg.deps = p.dependencies.iter().map(|d| parse_dep(d)).collect();
        pkg.checksum = p
            .checksum
            .or_else(|| meta_checksums.get(&make_id(&p.name, &p.version)).cloned());
        let has_source = p.source.is_some();
        pkg.source = p.source;
        let id = pkg.id.clone();
        lf.push(pkg);
        // Workspace / local crates have no source; treat them as roots.
        if !has_source {
            lf.add_root(id);
        }
    }

    Ok(lf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_packages_deps_and_roots() {
        let src = r#"
version = 3

[[package]]
name = "myapp"
version = "0.1.0"
dependencies = ["serde", "anyhow 1.0.75"]

[[package]]
name = "serde"
version = "1.0.188"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "deadbeef"
"#;
        let lf = parse(src).unwrap();
        assert_eq!(lf.format_version.as_deref(), Some("3"));
        assert_eq!(lf.packages.len(), 2);
        assert_eq!(lf.roots, vec!["myapp@0.1.0"]);

        let myapp = lf.packages.iter().find(|p| p.name == "myapp").unwrap();
        assert_eq!(myapp.deps.len(), 2);
        assert_eq!(myapp.deps[0].name, "serde");
        assert_eq!(myapp.deps[0].version, None);
        assert_eq!(myapp.deps[1].name, "anyhow");
        assert_eq!(myapp.deps[1].version.as_deref(), Some("1.0.75"));

        let serde_pkg = lf.packages.iter().find(|p| p.name == "serde").unwrap();
        assert_eq!(serde_pkg.checksum.as_deref(), Some("deadbeef"));
    }

    #[test]
    fn reads_legacy_metadata_checksums() {
        let src = r#"
[[package]]
name = "foo"
version = "1.2.3"
source = "registry+https://example"

[metadata]
"checksum foo 1.2.3 (registry+https://example)" = "abc123"
"#;
        let lf = parse(src).unwrap();
        let foo = lf.packages.iter().find(|p| p.name == "foo").unwrap();
        assert_eq!(foo.checksum.as_deref(), Some("abc123"));
    }
}
