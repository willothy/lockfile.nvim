//! poetry.lock -> normalized model.
//!
//! poetry.lock is TOML with `[[package]]` entries. Dependencies are a
//! `[package.dependencies]` table mapping name -> constraint. File hashes live
//! in per-package `files` (poetry >=1.5) or in `[metadata.files]` (poetry 1.x).

use std::collections::HashMap;

use serde::Deserialize;

use crate::model::{Dep, Lockfile, Package};

#[derive(Deserialize)]
struct PoetryLock {
    #[serde(default)]
    package: Vec<PoetryPackage>,
    metadata: Option<PoetryMeta>,
}

#[derive(Deserialize)]
struct PoetryMeta {
    #[serde(rename = "lock-version")]
    lock_version: Option<String>,
    #[serde(default)]
    files: HashMap<String, Vec<PoetryFile>>,
}

#[derive(Deserialize)]
struct PoetryPackage {
    name: String,
    version: String,
    #[serde(default)]
    optional: bool,
    #[serde(default)]
    dependencies: HashMap<String, toml::Value>,
    source: Option<PoetrySource>,
    #[serde(default)]
    files: Vec<PoetryFile>,
}

#[derive(Deserialize)]
struct PoetrySource {
    url: Option<String>,
}

#[derive(Deserialize)]
struct PoetryFile {
    hash: Option<String>,
}

/// First available hash in a list of file records.
fn checksum_from_files(files: &[PoetryFile]) -> Option<String> {
    files.iter().find_map(|f| f.hash.clone())
}

pub fn parse(src: &str) -> Result<Lockfile, String> {
    let doc: PoetryLock = toml::from_str(src).map_err(|e| format!("invalid poetry.lock: {e}"))?;

    let mut lf = Lockfile::new("poetry");
    let meta_files = doc.metadata.as_ref().map(|m| &m.files);
    lf.format_version = doc.metadata.as_ref().and_then(|m| m.lock_version.clone());

    for p in &doc.package {
        let mut pkg = Package::new(&p.name, &p.version);
        pkg.optional = p.optional;
        pkg.deps = p.dependencies.keys().map(Dep::by_name).collect();
        pkg.source = p.source.as_ref().and_then(|s| s.url.clone());
        pkg.checksum = checksum_from_files(&p.files).or_else(|| {
            meta_files
                .and_then(|mf| mf.get(&p.name))
                .and_then(|files| checksum_from_files(files))
        });
        lf.push(pkg);
    }

    Ok(lf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_dependencies_and_hashes() {
        let src = r#"
[[package]]
name = "requests"
version = "2.31.0"
optional = false

[package.dependencies]
urllib3 = ">=1.21.1,<3"
certifi = ">=2017.4.17"

[[package]]
name = "urllib3"
version = "2.0.7"
files = [{file = "urllib3-2.0.7.tar.gz", hash = "sha256:zzz"}]

[metadata]
lock-version = "2.0"
"#;
        let lf = parse(src).unwrap();
        assert_eq!(lf.format_version.as_deref(), Some("2.0"));
        let requests = lf.packages.iter().find(|p| p.name == "requests").unwrap();
        let mut dep_names: Vec<_> = requests.deps.iter().map(|d| d.name.as_str()).collect();
        dep_names.sort();
        assert_eq!(dep_names, vec!["certifi", "urllib3"]);

        let urllib3 = lf.packages.iter().find(|p| p.name == "urllib3").unwrap();
        assert_eq!(urllib3.checksum.as_deref(), Some("sha256:zzz"));
    }

    #[test]
    fn reads_legacy_metadata_files() {
        let src = r#"
[[package]]
name = "foo"
version = "1.0.0"

[metadata]
lock-version = "1.1"

[metadata.files]
foo = [{file = "foo-1.0.0.tar.gz", hash = "sha256:abc"}]
"#;
        let lf = parse(src).unwrap();
        let foo = lf.packages.iter().find(|p| p.name == "foo").unwrap();
        assert_eq!(foo.checksum.as_deref(), Some("sha256:abc"));
    }
}
