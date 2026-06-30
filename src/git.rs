//! Git access via libgit2 (the `git2` crate), used to retrieve lockfile
//! contents at arbitrary revisions for diffing. Preferred over shelling out to
//! the `git` CLI: no subprocess, structured errors, and no output parsing.

use std::collections::HashSet;
use std::path::Path;

use git2::Repository;

/// Discover the repository containing `path` and return its working-directory
/// root (without a trailing separator), or `None` if `path` is not in a
/// non-bare repository.
pub fn root(path: &str) -> Option<String> {
    let repo = Repository::discover(path).ok()?;
    let workdir = repo.workdir()?;
    let s = workdir.to_string_lossy();
    Some(s.trim_end_matches('/').to_string())
}

/// Read the contents of `relpath` at revision `rev` within the repo at `root`.
/// Errors if the revision or path does not resolve to a blob.
pub fn show(root: &str, rev: &str, relpath: &str) -> Result<String, String> {
    let repo = Repository::open(root).map_err(|e| e.message().to_string())?;
    let spec = format!("{rev}:{relpath}");
    let object = repo
        .revparse_single(&spec)
        .map_err(|e| format!("{spec}: {}", e.message()))?;
    let blob = object
        .peel_to_blob()
        .map_err(|e| format!("{spec}: not a file ({})", e.message()))?;
    Ok(String::from_utf8_lossy(blob.content()).into_owned())
}

/// Whether `rev` resolves to anything in the repo at `root`.
pub fn rev_exists(root: &str, rev: &str) -> bool {
    match Repository::open(root) {
        Ok(repo) => repo.revparse_single(rev).is_ok(),
        Err(_) => false,
    }
}

/// List tracked lockfiles (repo-relative paths) whose basename is in
/// `basenames`, sorted and de-duplicated.
pub fn list_lockfiles(root: &str, basenames: &[String]) -> Result<Vec<String>, String> {
    let repo = Repository::open(root).map_err(|e| e.message().to_string())?;
    let index = repo.index().map_err(|e| e.message().to_string())?;
    let set: HashSet<&str> = basenames.iter().map(String::as_str).collect();

    let mut out: Vec<String> = Vec::new();
    for entry in index.iter() {
        let path = String::from_utf8_lossy(&entry.path).into_owned();
        let base = path.rsplit('/').next().unwrap_or(&path);
        if set.contains(base) {
            out.push(path);
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}

/// The path of `abspath` relative to repo `root`, or `abspath` unchanged if it
/// is not under `root`.
pub fn relpath(root: &str, abspath: &str) -> String {
    let root_path = Path::new(root);
    match Path::new(abspath).strip_prefix(root_path) {
        Ok(rel) => rel.to_string_lossy().into_owned(),
        Err(_) => abspath.to_string(),
    }
}
