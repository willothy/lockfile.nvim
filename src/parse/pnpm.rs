//! pnpm-lock.yaml -> normalized model.
//!
//! Handles the major pnpm layouts:
//!   * v9: package metadata in `packages`, dependency edges in `snapshots`,
//!     keys "name@version(peers)".
//!   * v6: metadata and edges both in `packages`, keys "/name@version(peers)".
//!   * v5: keys "/name/version".
//! Direct dependencies come from `importers` or the top-level dependency maps.

use std::collections::HashMap;

use serde::Deserialize;
use serde_yaml_ng::Value;

use crate::model::{Dep, Lockfile, Package, make_id};

#[derive(Deserialize)]
struct PnpmLock {
    #[serde(rename = "lockfileVersion")]
    lockfile_version: Option<Value>,
    #[serde(default)]
    importers: HashMap<String, Importer>,
    #[serde(default)]
    packages: HashMap<String, PnpmPkg>,
    #[serde(default)]
    snapshots: HashMap<String, PnpmSnapshot>,
    #[serde(default)]
    dependencies: HashMap<String, DepRef>,
    #[serde(rename = "devDependencies", default)]
    dev_dependencies: HashMap<String, DepRef>,
    #[serde(rename = "optionalDependencies", default)]
    optional_dependencies: HashMap<String, DepRef>,
}

#[derive(Deserialize, Default)]
struct Importer {
    #[serde(default)]
    dependencies: HashMap<String, DepRef>,
    #[serde(rename = "devDependencies", default)]
    dev_dependencies: HashMap<String, DepRef>,
    #[serde(rename = "optionalDependencies", default)]
    optional_dependencies: HashMap<String, DepRef>,
}

/// An importer dependency, either a bare version string (v5) or a detailed
/// `{ specifier, version }` mapping (v6/v9).
#[derive(Deserialize)]
#[serde(untagged)]
enum DepRef {
    Detailed { version: String },
    Simple(String),
}

impl DepRef {
    fn version(&self) -> &str {
        match self {
            DepRef::Detailed { version } => version,
            DepRef::Simple(v) => v,
        }
    }
}

#[derive(Deserialize)]
struct PnpmPkg {
    resolution: Option<Resolution>,
    #[serde(default)]
    dev: bool,
    #[serde(default)]
    dependencies: HashMap<String, String>,
    #[serde(rename = "optionalDependencies", default)]
    optional_dependencies: HashMap<String, String>,
}

#[derive(Deserialize)]
struct Resolution {
    integrity: Option<String>,
}

#[derive(Deserialize)]
struct PnpmSnapshot {
    #[serde(default)]
    dependencies: HashMap<String, String>,
    #[serde(rename = "optionalDependencies", default)]
    optional_dependencies: HashMap<String, String>,
}

fn version_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

/// Drop a trailing pnpm peer-dependency suffix "(...)".
fn strip_peers(s: &str) -> &str {
    match s.find('(') {
        Some(p) => &s[..p],
        None => s,
    }
}

/// Parse a pnpm package key into (name, version), tolerating all layouts.
fn parse_key(key: &str) -> (String, String) {
    let mut s = key;
    if let Some(stripped) = s.strip_prefix('/') {
        s = stripped;
    }
    s = strip_peers(s);
    // Prefer "name@version": the last '@' past a leading scope '@'.
    if let Some(idx) = s.rfind('@') {
        if idx > 0 {
            return (s[..idx].to_string(), s[idx + 1..].to_string());
        }
    }
    // Fall back to v5 "name/version".
    if let Some(idx) = s.rfind('/') {
        return (s[..idx].to_string(), s[idx + 1..].to_string());
    }
    (s.to_string(), String::new())
}

/// Dependency edges from a pnpm `{ name: versionspec }` map.
fn deps_from(map: &HashMap<String, String>) -> Vec<Dep> {
    map.iter()
        .map(|(name, ver)| Dep::pinned(name, strip_peers(ver)))
        .collect()
}

/// Register the direct dependencies declared by an importer-shaped set of maps.
fn add_roots(lf: &mut Lockfile, maps: &[&HashMap<String, DepRef>]) {
    for map in maps {
        for (name, spec) in *map {
            let version = strip_peers(spec.version());
            if !version.is_empty() {
                lf.add_root(make_id(name, version));
            }
        }
    }
}

pub fn parse(src: &str) -> Result<Lockfile, String> {
    let doc: PnpmLock = serde_yaml_ng::from_str(src).map_err(|e| format!("invalid pnpm-lock.yaml: {e}"))?;

    let mut lf = Lockfile::new("pnpm");
    lf.format_version = doc.lockfile_version.as_ref().map(version_string);

    let use_snapshots = !doc.snapshots.is_empty();

    // Pass 1: package metadata (and, for v6/v5, dependency edges).
    let mut id_index: HashMap<String, usize> = HashMap::new();
    for (key, meta) in &doc.packages {
        let (name, version) = parse_key(key);
        if name.is_empty() {
            continue;
        }
        let mut pkg = Package::new(&name, &version);
        pkg.checksum = meta.resolution.as_ref().and_then(|r| r.integrity.clone());
        pkg.dev = meta.dev;
        if !use_snapshots {
            let mut deps = deps_from(&meta.dependencies);
            deps.extend(deps_from(&meta.optional_dependencies));
            pkg.deps = deps;
        }
        id_index.entry(pkg.id.clone()).or_insert(lf.packages.len());
        lf.push(pkg);
    }

    // Pass 2: v9 dependency edges from snapshots.
    if use_snapshots {
        for (key, snap) in &doc.snapshots {
            let (name, version) = parse_key(key);
            let id = make_id(&name, &version);
            if let Some(&idx) = id_index.get(&id) {
                let mut deps = deps_from(&snap.dependencies);
                deps.extend(deps_from(&snap.optional_dependencies));
                lf.packages[idx].deps.extend(deps);
            }
        }
    }

    // Roots from importers (monorepo) or the top-level maps (single package).
    if doc.importers.is_empty() {
        add_roots(
            &mut lf,
            &[
                &doc.dependencies,
                &doc.dev_dependencies,
                &doc.optional_dependencies,
            ],
        );
    } else {
        for importer in doc.importers.values() {
            add_roots(
                &mut lf,
                &[
                    &importer.dependencies,
                    &importer.dev_dependencies,
                    &importer.optional_dependencies,
                ],
            );
        }
    }

    Ok(lf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_v9_with_snapshots() {
        let src = r#"
lockfileVersion: '9.0'
importers:
  .:
    dependencies:
      express:
        specifier: ^4.18.0
        version: 4.18.2
packages:
  express@4.18.2:
    resolution: {integrity: sha512-abc}
  accepts@1.3.8:
    resolution: {integrity: sha512-def}
snapshots:
  express@4.18.2:
    dependencies:
      accepts: 1.3.8
  accepts@1.3.8: {}
"#;
        let lf = parse(src).unwrap();
        assert_eq!(lf.format_version.as_deref(), Some("9.0"));
        assert_eq!(lf.roots, vec!["express@4.18.2"]);
        let express = lf.packages.iter().find(|p| p.name == "express").unwrap();
        assert_eq!(express.checksum.as_deref(), Some("sha512-abc"));
        assert_eq!(express.deps.len(), 1);
        assert_eq!(express.deps[0].name, "accepts");
        assert_eq!(express.deps[0].version.as_deref(), Some("1.3.8"));
    }

    #[test]
    fn key_parsing_handles_all_layouts() {
        assert_eq!(parse_key("lodash@4.17.21"), ("lodash".into(), "4.17.21".into()));
        assert_eq!(
            parse_key("/@scope/pkg@1.0.0(react@18.0.0)"),
            ("@scope/pkg".into(), "1.0.0".into())
        );
        assert_eq!(
            parse_key("/@scope/pkg/1.0.0"),
            ("@scope/pkg".into(), "1.0.0".into())
        );
        assert_eq!(parse_key("/lodash/4.17.21"), ("lodash".into(), "4.17.21".into()));
    }
}
