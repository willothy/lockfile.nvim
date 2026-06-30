//! yarn.lock -> normalized model.
//!
//! Two formats share this filename: Yarn Classic (v1, a bespoke indentation
//! format) and Yarn Berry (v2+, valid YAML with a `__metadata` block). They are
//! distinguished by the presence of `__metadata` and dispatched accordingly.

use serde_yaml_ng::Value;

use super::yarn_classic;
use crate::model::{Dep, Lockfile, Package};

pub fn parse(src: &str) -> Result<Lockfile, String> {
    if src.contains("__metadata") {
        parse_berry(src)
    } else {
        yarn_classic::parse(src)
    }
}

fn value_to_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

fn parse_berry(src: &str) -> Result<Lockfile, String> {
    let doc: Value = serde_yaml_ng::from_str(src).map_err(|e| format!("invalid yarn.lock: {e}"))?;
    let map = doc
        .as_mapping()
        .ok_or_else(|| "invalid yarn.lock: expected a mapping at the top level".to_string())?;

    let mut lf = Lockfile::new("yarn");
    if let Some(meta) = map.get("__metadata").and_then(Value::as_mapping) {
        if let Some(version) = meta.get("version") {
            lf.format_version = Some(value_to_string(version));
        }
    }

    for (key, entry) in map {
        let Some(key) = key.as_str() else { continue };
        if key == "__metadata" {
            continue;
        }
        let Some(entry) = entry.as_mapping() else {
            continue;
        };
        let Some(version) = entry.get("version").and_then(Value::as_str) else {
            continue;
        };

        let first = key.split(", ").next().unwrap_or(key);
        let name = yarn_classic::name_from_descriptor(first);
        let mut pkg = Package::new(name, version);
        pkg.source = entry
            .get("resolution")
            .and_then(Value::as_str)
            .map(str::to_string);
        pkg.checksum = entry
            .get("checksum")
            .and_then(Value::as_str)
            .map(str::to_string);
        if let Some(deps) = entry.get("dependencies").and_then(Value::as_mapping) {
            for (dep_name, _) in deps {
                if let Some(dep_name) = dep_name.as_str() {
                    pkg.deps.push(Dep::by_name(dep_name));
                }
            }
        }
        lf.push(pkg);
    }

    Ok(lf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_berry_format() {
        let src = r#"__metadata:
  version: 8
  cacheKey: 10

"express@npm:^4.18.0":
  version: 4.18.2
  resolution: "express@npm:4.18.2"
  dependencies:
    accepts: "npm:~1.3.8"
  checksum: 10c0/abc

"accepts@npm:~1.3.8":
  version: 1.3.8
  resolution: "accepts@npm:1.3.8"
  checksum: 10c0/def
"#;
        let lf = parse(src).unwrap();
        assert_eq!(lf.format_version.as_deref(), Some("8"));
        assert_eq!(lf.packages.len(), 2);
        let express = lf.packages.iter().find(|p| p.name == "express").unwrap();
        assert_eq!(express.version, "4.18.2");
        assert_eq!(express.source.as_deref(), Some("express@npm:4.18.2"));
        assert_eq!(express.checksum.as_deref(), Some("10c0/abc"));
        assert_eq!(express.deps[0].name, "accepts");
    }

    #[test]
    fn dispatches_to_classic_without_metadata() {
        let src = "lodash@^4.17.21:\n  version \"4.17.21\"\n  integrity sha512-x\n";
        let lf = parse(src).unwrap();
        assert_eq!(lf.format_version.as_deref(), Some("1"));
        assert_eq!(lf.packages[0].name, "lodash");
    }
}
