//! go.sum -> normalized model.
//!
//! go.sum is a flat list of "module version hash" and "module version/go.mod
//! hash" lines. It records no dependency graph (that lives in go.mod), so the
//! model has `supports_graph = false`. Each module version collapses to one
//! package; the module-zip hash is preferred over the /go.mod hash.
//!
//! The line grammar is parsed with `nom` combinators.

use std::collections::HashMap;

use nom::{
    IResult, Parser,
    bytes::complete::take_while1,
    character::complete::{not_line_ending, space1},
};

use crate::model::{Lockfile, Package, make_id};

const GOMOD_SUFFIX: &str = "/go.mod";

/// A run of non-whitespace characters.
fn token(input: &str) -> IResult<&str, &str> {
    take_while1(|c: char| c != ' ' && c != '\t' && c != '\n' && c != '\r').parse(input)
}

/// Parse a single go.sum entry line into (module, version, hash).
fn entry(input: &str) -> IResult<&str, (&str, &str, &str)> {
    let (rest, (module, _, version, _, hash)) =
        (token, space1, token, space1, not_line_ending).parse(input)?;
    Ok((rest, (module, version, hash)))
}

pub fn parse(src: &str) -> Result<Lockfile, String> {
    let mut lf = Lockfile::new("go");
    lf.supports_graph = false;

    // Tracks ids that already hold a module-zip (non-/go.mod) hash so a later
    // /go.mod line doesn't overwrite the preferred checksum.
    let mut has_zip_hash: HashMap<String, bool> = HashMap::new();
    let mut index: HashMap<String, usize> = HashMap::new();

    for raw in src.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let (module, version, hash) = match entry(line) {
            Ok((_, parsed)) => parsed,
            Err(_) => continue, // skip malformed lines rather than failing the file
        };

        let is_gomod = version.ends_with(GOMOD_SUFFIX);
        let version = version.strip_suffix(GOMOD_SUFFIX).unwrap_or(version);
        let id = make_id(module, version);

        if let Some(&idx) = index.get(&id) {
            if !is_gomod && !has_zip_hash.get(&id).copied().unwrap_or(false) {
                lf.packages[idx].checksum = Some(hash.to_string());
                has_zip_hash.insert(id, true);
            }
        } else {
            let mut pkg = Package::new(module, version);
            pkg.checksum = Some(hash.to_string());
            index.insert(id.clone(), lf.packages.len());
            if !is_gomod {
                has_zip_hash.insert(id, true);
            }
            lf.push(pkg);
        }
    }

    Ok(lf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entry_parser_splits_three_tokens() {
        let (_, (m, v, h)) = entry("github.com/pkg/errors v0.9.1 h1:zip=").unwrap();
        assert_eq!(m, "github.com/pkg/errors");
        assert_eq!(v, "v0.9.1");
        assert_eq!(h, "h1:zip=");
    }

    #[test]
    fn collapses_gomod_and_prefers_zip_hash() {
        let src = "\
github.com/pkg/errors v0.9.1/go.mod h1:modhash=
github.com/pkg/errors v0.9.1 h1:ziphash=
golang.org/x/sys v0.5.0/go.mod h1:onlymod=
";
        let lf = parse(src).unwrap();
        assert!(!lf.supports_graph);
        assert_eq!(lf.packages.len(), 2);

        let errors = lf
            .packages
            .iter()
            .find(|p| p.name == "github.com/pkg/errors")
            .unwrap();
        assert_eq!(errors.version, "v0.9.1");
        assert_eq!(errors.checksum.as_deref(), Some("h1:ziphash="));

        let sys = lf
            .packages
            .iter()
            .find(|p| p.name == "golang.org/x/sys")
            .unwrap();
        assert_eq!(sys.checksum.as_deref(), Some("h1:onlymod="));
    }
}
