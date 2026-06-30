//! package-lock.json / npm-shrinkwrap.json -> normalized model.
//!
//! Supports lockfileVersion 2/3 (the `packages` map keyed by install path) and
//! the legacy v1 `dependencies` tree. npm dependency edges are semver ranges,
//! not resolved versions, so edges carry only a name.

use std::collections::HashMap;

use serde::Deserialize;
use serde_json::Value;

use crate::model::{Dep, Lockfile, Package};

const NODE_MODULES: &str = "node_modules/";

#[derive(Deserialize)]
struct NpmLock {
    #[serde(rename = "lockfileVersion")]
    lockfile_version: Option<Value>,
    packages: Option<HashMap<String, NpmPkg>>,
    dependencies: Option<HashMap<String, NpmV1Dep>>,
}

#[derive(Deserialize)]
struct NpmPkg {
    name: Option<String>,
    version: Option<String>,
    resolved: Option<String>,
    integrity: Option<String>,
    #[serde(default)]
    dependencies: HashMap<String, Value>,
    #[serde(rename = "devDependencies", default)]
    dev_dependencies: HashMap<String, Value>,
    #[serde(rename = "optionalDependencies", default)]
    optional_dependencies: HashMap<String, Value>,
    #[serde(default)]
    dev: bool,
    #[serde(default)]
    optional: bool,
    #[serde(default)]
    link: bool,
}

#[derive(Deserialize)]
struct NpmV1Dep {
    version: String,
    resolved: Option<String>,
    integrity: Option<String>,
    #[serde(default)]
    requires: HashMap<String, Value>,
    #[serde(default)]
    dependencies: HashMap<String, NpmV1Dep>,
    #[serde(default)]
    dev: bool,
    #[serde(default)]
    optional: bool,
}

/// Derive a package name from a `packages` install-path key.
/// "node_modules/a/node_modules/@s/b" -> Some("@s/b"); "" -> None.
fn name_from_path(path: &str) -> Option<&str> {
    if path.is_empty() {
        return None;
    }
    path.rfind(NODE_MODULES)
        .map(|idx| &path[idx + NODE_MODULES.len()..])
}

/// Dependency edges (by name) from an npm dependency-spec map.
fn edges_from(map: &HashMap<String, Value>) -> Vec<Dep> {
    map.keys().map(Dep::by_name).collect()
}

fn version_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn build_v3(lf: &mut Lockfile, packages: HashMap<String, NpmPkg>) {
    // Direct dependency names declared by the project root entry.
    let mut root_names: Vec<String> = Vec::new();
    // name -> id for resolving root names to concrete installs.
    let mut by_name: HashMap<String, String> = HashMap::new();

    for (path, entry) in &packages {
        if path.is_empty() {
            root_names.extend(entry.dependencies.keys().cloned());
            root_names.extend(entry.dev_dependencies.keys().cloned());
            root_names.extend(entry.optional_dependencies.keys().cloned());
            continue;
        }

        let name = name_from_path(path)
            .map(str::to_string)
            .or_else(|| entry.name.clone());
        let (Some(name), Some(version)) = (name, entry.version.clone()) else {
            continue;
        };

        let mut pkg = Package::new(&name, &version);
        let mut deps = edges_from(&entry.dependencies);
        deps.extend(edges_from(&entry.optional_dependencies));
        pkg.deps = deps;
        pkg.source = entry.resolved.clone();
        pkg.checksum = entry.integrity.clone();
        pkg.dev = entry.dev;
        pkg.optional = entry.optional;

        by_name
            .entry(name.clone())
            .or_insert_with(|| pkg.id.clone());

        // Workspace packages (path without node_modules) are roots.
        if name_from_path(path).is_none() && !entry.link {
            lf.add_root(pkg.id.clone());
        }
        lf.push(pkg);
    }

    for name in root_names {
        if let Some(id) = by_name.get(&name) {
            lf.add_root(id.clone());
        }
    }
}

fn build_v1(lf: &mut Lockfile, deps: HashMap<String, NpmV1Dep>, roots: bool) {
    for (name, entry) in deps {
        let mut pkg = Package::new(&name, &entry.version);
        pkg.deps = edges_from(&entry.requires);
        pkg.source = entry.resolved;
        pkg.checksum = entry.integrity;
        pkg.dev = entry.dev;
        pkg.optional = entry.optional;
        if roots {
            lf.add_root(pkg.id.clone());
        }
        lf.push(pkg);
        build_v1(lf, entry.dependencies, false);
    }
}

pub fn parse(src: &str) -> Result<Lockfile, String> {
    let doc: NpmLock =
        serde_json::from_str(src).map_err(|e| format!("invalid package-lock.json: {e}"))?;

    let mut lf = Lockfile::new("npm");
    lf.format_version = doc.lockfile_version.as_ref().map(version_string);

    if let Some(packages) = doc.packages {
        build_v3(&mut lf, packages);
    } else if let Some(deps) = doc.dependencies {
        build_v1(&mut lf, deps, true);
    }

    Ok(lf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_v3_packages_and_roots() {
        let src = r#"
        {
          "name": "myapp",
          "lockfileVersion": 3,
          "packages": {
            "": { "name": "myapp", "dependencies": { "express": "^4.18.0" } },
            "node_modules/express": {
              "version": "4.18.2",
              "resolved": "https://registry.npmjs.org/express/-/express-4.18.2.tgz",
              "integrity": "sha512-abc",
              "dependencies": { "accepts": "~1.3.8" }
            },
            "node_modules/accepts": { "version": "1.3.8", "integrity": "sha512-def" }
          }
        }
        "#;
        let lf = parse(src).unwrap();
        assert_eq!(lf.format_version.as_deref(), Some("3"));
        assert_eq!(lf.packages.len(), 2);
        assert_eq!(lf.roots, vec!["express@4.18.2"]);
        let express = lf.packages.iter().find(|p| p.name == "express").unwrap();
        assert_eq!(express.checksum.as_deref(), Some("sha512-abc"));
        assert_eq!(express.deps.len(), 1);
        assert_eq!(express.deps[0].name, "accepts");
    }

    #[test]
    fn scoped_name_from_nested_path() {
        assert_eq!(
            name_from_path("node_modules/a/node_modules/@s/b"),
            Some("@s/b")
        );
        assert_eq!(name_from_path(""), None);
        assert_eq!(name_from_path("packages/app"), None);
    }

    #[test]
    fn parses_v1_tree() {
        let src = r#"
        {
          "lockfileVersion": 1,
          "dependencies": {
            "express": {
              "version": "4.18.2",
              "integrity": "sha512-abc",
              "requires": { "accepts": "~1.3.8" },
              "dependencies": {
                "accepts": { "version": "1.3.8", "integrity": "sha512-def" }
              }
            }
          }
        }
        "#;
        let lf = parse(src).unwrap();
        assert_eq!(lf.packages.len(), 2);
        assert_eq!(lf.roots, vec!["express@4.18.2"]);
    }
}
