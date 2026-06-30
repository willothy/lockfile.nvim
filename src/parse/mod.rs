//! Format detection dispatch: route raw lockfile text to the right parser,
//! producing a normalized [`Lockfile`].

use crate::model::Lockfile;

mod cargo;
mod gosum;
mod npm;
mod pnpm;
mod poetry;
mod uv;
mod yarn;
mod yarn_classic;

/// Parse lockfile `src` of the given format `kind` into the normalized model.
///
/// Returns a human-readable error string on failure.
pub fn parse(kind: &str, src: &str) -> Result<Lockfile, String> {
    match kind {
        "cargo" => cargo::parse(src),
        "npm" => npm::parse(src),
        "pnpm" => pnpm::parse(src),
        "poetry" => poetry::parse(src),
        "uv" => uv::parse(src),
        "yarn" => yarn::parse(src),
        "go" => gosum::parse(src),
        other => Err(format!("unsupported lockfile type: {other}")),
    }
}
