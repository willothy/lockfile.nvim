//! uv.lock -> normalized model.
//!
//! uv.lock is TOML with `[[package]]` entries whose `dependencies` is an array
//! of inline tables `{ name = "..." }`. The project itself appears with a
//! `source` of `{ editable = "." }` or `{ virtual = "." }`, treated as a root.
//! Hashes come from `sdist` / `wheels`.

use std::collections::HashMap;

use serde::Deserialize;

use crate::model::{Dep, Lockfile, Package};

#[derive(Deserialize)]
struct UvLock {
    version: Option<toml::Value>,
    #[serde(default)]
    package: Vec<UvPackage>,
}

#[derive(Deserialize)]
struct UvPackage {
    name: String,
    version: String,
    source: Option<HashMap<String, toml::Value>>,
    #[serde(default)]
    dependencies: Vec<UvDep>,
    #[serde(rename = "optional-dependencies", default)]
    optional_dependencies: HashMap<String, Vec<UvDep>>,
    #[serde(rename = "dev-dependencies", default)]
    dev_dependencies: HashMap<String, Vec<UvDep>>,
    sdist: Option<UvHash>,
    #[serde(default)]
    wheels: Vec<UvHash>,
}

#[derive(Deserialize)]
struct UvDep {
    name: String,
}

#[derive(Deserialize)]
struct UvHash {
    hash: Option<String>,
}

fn version_string(v: &toml::Value) -> String {
    match v {
        toml::Value::String(s) => s.clone(),
        toml::Value::Integer(i) => i.to_string(),
        other => other.to_string(),
    }
}

/// Representative checksum from a package's sdist or first wheel.
fn checksum_of(p: &UvPackage) -> Option<String> {
    p.sdist
        .as_ref()
        .and_then(|s| s.hash.clone())
        .or_else(|| p.wheels.iter().find_map(|w| w.hash.clone()))
}

/// Resolve a uv `source` inline table into (display source, is_root).
fn resolve_source(source: Option<&HashMap<String, toml::Value>>) -> (Option<String>, bool) {
    let Some(src) = source else {
        return (None, false);
    };
    if src.contains_key("editable") || src.contains_key("virtual") {
        return (None, true);
    }
    let as_str = |key: &str| src.get(key).and_then(|v| v.as_str()).map(str::to_string);
    if let Some(registry) = as_str("registry") {
        (Some(registry), false)
    } else if let Some(git) = as_str("git") {
        (Some(format!("git+{git}")), false)
    } else if let Some(url) = as_str("url") {
        (Some(url), false)
    } else if let Some(path) = as_str("path") {
        (Some(path), false)
    } else {
        (None, false)
    }
}

pub fn parse(src: &str) -> Result<Lockfile, String> {
    let doc: UvLock = toml::from_str(src).map_err(|e| format!("invalid uv.lock: {e}"))?;

    let mut lf = Lockfile::new("uv");
    lf.format_version = doc.version.as_ref().map(version_string);

    for p in &doc.package {
        let mut pkg = Package::new(&p.name, &p.version);

        let mut deps: Vec<Dep> = p
            .dependencies
            .iter()
            .map(|d| Dep::by_name(&d.name))
            .collect();
        for extra in p.optional_dependencies.values() {
            deps.extend(extra.iter().map(|d| Dep::by_name(&d.name)));
        }
        for group in p.dev_dependencies.values() {
            deps.extend(group.iter().map(|d| Dep::by_name(&d.name)));
        }
        pkg.deps = deps;

        let (source, is_root) = resolve_source(p.source.as_ref());
        pkg.source = source;
        pkg.checksum = checksum_of(p);

        let id = pkg.id.clone();
        lf.push(pkg);
        if is_root {
            lf.add_root(id);
        }
    }

    Ok(lf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_packages_deps_roots_and_hashes() {
        let src = r#"
version = 1

[[package]]
name = "myapp"
version = "0.1.0"
source = { editable = "." }
dependencies = [{ name = "requests" }]

[[package]]
name = "requests"
version = "2.31.0"
source = { registry = "https://pypi.org/simple" }
dependencies = [{ name = "urllib3" }]
sdist = { url = "https://x", hash = "sha256:abc" }
"#;
        let lf = parse(src).unwrap();
        assert_eq!(lf.format_version.as_deref(), Some("1"));
        assert_eq!(lf.roots, vec!["myapp@0.1.0"]);

        let requests = lf.packages.iter().find(|p| p.name == "requests").unwrap();
        assert_eq!(requests.source.as_deref(), Some("https://pypi.org/simple"));
        assert_eq!(requests.checksum.as_deref(), Some("sha256:abc"));
        assert_eq!(requests.deps[0].name, "urllib3");
    }
}
