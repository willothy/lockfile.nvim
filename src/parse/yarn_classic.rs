//! Yarn Classic (v1) yarn.lock parsing.
//!
//! The v1 format is a bespoke indentation-based format:
//!
//! ```text
//! "name@range", "name@range2":
//!   version "1.2.3"
//!   resolved "https://...#hash"
//!   integrity sha512-...
//!   dependencies:
//!     dep "^1.0.0"
//! ```
//!
//! Indentation grouping is handled by line iteration; the token-level grammar
//! (descriptor lists, key/value field lines) is parsed with `nom` combinators.

use nom::{
    IResult, Parser,
    branch::alt,
    bytes::complete::{tag, take_till, take_while1},
    character::complete::{char, not_line_ending, space0},
    multi::separated_list1,
    sequence::delimited,
};

use crate::model::{Dep, Lockfile, Package};

/// A double-quoted string, returning its inner contents (no escape handling is
/// required for the values Yarn writes).
fn quoted(input: &str) -> IResult<&str, &str> {
    delimited(char('"'), take_till(|c| c == '"'), char('"')).parse(input)
}

/// One descriptor: a quoted string, or a bare run up to the next comma.
fn descriptor(input: &str) -> IResult<&str, &str> {
    alt((quoted, take_while1(|c: char| c != ','))).parse(input)
}

/// A comma-separated descriptor list (the header line, with its trailing colon
/// already removed).
fn descriptor_list(input: &str) -> IResult<&str, Vec<&str>> {
    separated_list1(tag(", "), descriptor).parse(input)
}

/// A bare key token (up to whitespace or a colon).
fn bare_key(input: &str) -> IResult<&str, &str> {
    take_while1(|c: char| c != ' ' && c != '\t' && c != ':').parse(input)
}

/// A field line `key value` / `key "value"`, or a bare `key` (no value).
fn key_value(input: &str) -> IResult<&str, (&str, Option<&str>)> {
    let (rest, key) = alt((quoted, bare_key)).parse(input)?;
    let (rest, _) = space0(rest)?;
    if rest.is_empty() {
        return Ok((rest, (key, None)));
    }
    let (rest, value) = alt((quoted, not_line_ending)).parse(rest)?;
    Ok((rest, (key, Some(value))))
}

/// Extract the package name from a descriptor such as "name@range",
/// "@scope/name@range", or Berry's "name@npm:range".
pub(super) fn name_from_descriptor(desc: &str) -> &str {
    let mut d = desc.trim();
    if let Some(stripped) = d.strip_prefix('"').and_then(|x| x.strip_suffix('"')) {
        d = stripped;
    }
    match d.rfind('@') {
        Some(i) if i > 0 => &d[..i],
        _ => d,
    }
}

/// Leading-space indentation of a raw line.
fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start_matches(' ').len()
}

pub fn parse(src: &str) -> Result<Lockfile, String> {
    let mut lf = Lockfile::new("yarn");
    lf.format_version = Some("1".to_string());

    let lines: Vec<&str> = src.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let raw = lines[i];
        let content = raw.trim();
        if content.is_empty() || content.starts_with('#') {
            i += 1;
            continue;
        }
        if indent_of(raw) != 0 {
            i += 1;
            continue;
        }

        // Header line: descriptors..., trailing ':'.
        let header = content.strip_suffix(':').unwrap_or(content);
        let descriptors = match descriptor_list(header) {
            Ok((_, d)) => d,
            Err(_) => {
                i += 1;
                continue;
            }
        };
        i += 1;

        let mut version: Option<String> = None;
        let mut resolved: Option<String> = None;
        let mut integrity: Option<String> = None;
        let mut deps: Vec<Dep> = Vec::new();

        while i < lines.len() && indent_of(lines[i]) > 0 {
            let field = lines[i].trim();
            if field.is_empty() || field.starts_with('#') {
                i += 1;
                continue;
            }
            if field.ends_with(':') {
                // Sub-block, e.g. `dependencies:`.
                let block_key = field.strip_suffix(':').unwrap();
                let block_indent = indent_of(lines[i]);
                i += 1;
                while i < lines.len() && indent_of(lines[i]) > block_indent {
                    let sub = lines[i].trim();
                    if !sub.is_empty() && !sub.starts_with('#') {
                        if block_key == "dependencies" || block_key == "optionalDependencies" {
                            if let Ok((_, (dep_name, _))) = key_value(sub) {
                                deps.push(Dep::by_name(dep_name));
                            }
                        }
                    }
                    i += 1;
                }
            } else if let Ok((_, (key, value))) = key_value(field) {
                match key {
                    "version" => version = value.map(str::to_string),
                    "resolved" => resolved = value.map(str::to_string),
                    "integrity" => integrity = value.map(str::to_string),
                    _ => {}
                }
                i += 1;
            } else {
                i += 1;
            }
        }

        if let (Some(version), Some(first)) = (version, descriptors.first()) {
            let name = name_from_descriptor(first);
            let mut pkg = Package::new(name, &version);
            pkg.deps = deps;
            pkg.source = resolved;
            pkg.checksum = integrity;
            lf.push(pkg);
        }
    }

    Ok(lf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_entries_with_dependencies() {
        let src = r#"# yarn lockfile v1
express@^4.18.0:
  version "4.18.2"
  resolved "https://registry.yarnpkg.com/express/-/express-4.18.2.tgz#abc"
  integrity sha512-abc
  dependencies:
    accepts "~1.3.8"

accepts@~1.3.8:
  version "1.3.8"
  integrity sha512-def
"#;
        let lf = parse(src).unwrap();
        assert_eq!(lf.format_version.as_deref(), Some("1"));
        assert_eq!(lf.packages.len(), 2);
        let express = lf.packages.iter().find(|p| p.name == "express").unwrap();
        assert_eq!(express.version, "4.18.2");
        assert_eq!(express.checksum.as_deref(), Some("sha512-abc"));
        assert_eq!(express.deps.len(), 1);
        assert_eq!(express.deps[0].name, "accepts");
    }

    #[test]
    fn handles_multiple_quoted_descriptors_and_scopes() {
        let src = r#""@babel/core@^7.0.0", "@babel/core@^7.12.0":
  version "7.23.0"
  dependencies:
    "@babel/code-frame" "^7.22.13"
"#;
        let lf = parse(src).unwrap();
        assert_eq!(lf.packages.len(), 1);
        let core = &lf.packages[0];
        assert_eq!(core.name, "@babel/core");
        assert_eq!(core.version, "7.23.0");
        assert_eq!(core.deps[0].name, "@babel/code-frame");
    }

    #[test]
    fn descriptor_name_extraction() {
        assert_eq!(name_from_descriptor("lodash@^4.17.21"), "lodash");
        assert_eq!(name_from_descriptor("@scope/x@^1.0.0"), "@scope/x");
        assert_eq!(name_from_descriptor("foo@npm:^4.0.0"), "foo");
    }
}
