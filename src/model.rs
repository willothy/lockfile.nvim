//! The normalized data model shared by every lockfile format.
//!
//! Each parser produces a [`Lockfile`]; the mlua bindings serialize it into a
//! Lua table that the plugin's diff/analysis layer consumes. Field names and
//! shapes are chosen to match what the Lua side expects (`type`, `packages`,
//! `roots`, package `deps`, etc.).

use serde::Serialize;

/// A directed dependency edge as recorded by the source lockfile. `version` is
/// populated only when the format pins the exact resolved version of the edge
/// (Cargo, pnpm); otherwise the edge is resolved by name during analysis.
#[derive(Debug, Clone, Serialize)]
pub struct Dep {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
}

impl Dep {
    /// A dependency edge identified only by name.
    pub fn by_name(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            version: None,
        }
    }

    /// A dependency edge with a pinned version.
    pub fn pinned(name: impl Into<String>, version: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            version: Some(version.into()),
        }
    }
}

/// A single resolved package.
#[derive(Debug, Clone, Serialize)]
pub struct Package {
    /// Canonical key, `"name@version"`.
    pub id: String,
    pub name: String,
    pub version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checksum: Option<String>,
    pub deps: Vec<Dep>,
    pub optional: bool,
    pub dev: bool,
}

impl Package {
    /// Create a package with a computed id and no source/checksum/deps.
    pub fn new(name: impl Into<String>, version: impl Into<String>) -> Self {
        let name = name.into();
        let version = version.into();
        let id = make_id(&name, &version);
        Self {
            id,
            name,
            version,
            source: None,
            checksum: None,
            deps: Vec::new(),
            optional: false,
            dev: false,
        }
    }
}

/// The canonical id for a `(name, version)` pair.
pub fn make_id(name: &str, version: &str) -> String {
    format!("{name}@{version}")
}

/// A fully parsed lockfile.
#[derive(Debug, Clone, Serialize)]
pub struct Lockfile {
    /// Format id, e.g. `"cargo"`, serialized as the Lua key `type`.
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub format_version: Option<String>,
    /// Whether dependency edges are meaningful for this format (false for
    /// go.sum, which records no graph).
    pub supports_graph: bool,
    /// Whether `version` strings are ordered semantic versions (true) or opaque
    /// identifiers like git commit SHAs (false, e.g. lazy-lock.json). When
    /// false, version changes are not classified as major/minor/etc.
    pub semver_versions: bool,
    pub packages: Vec<Package>,
    /// Ids (or names) of direct/root dependencies.
    pub roots: Vec<String>,
}

impl Lockfile {
    /// Create an empty lockfile of the given format.
    pub fn new(kind: impl Into<String>) -> Self {
        Self {
            kind: kind.into(),
            format_version: None,
            supports_graph: true,
            semver_versions: true,
            packages: Vec::new(),
            roots: Vec::new(),
        }
    }

    /// Append a package.
    pub fn push(&mut self, pkg: Package) {
        self.packages.push(pkg);
    }

    /// Record a root dependency by id.
    pub fn add_root(&mut self, id: impl Into<String>) {
        self.roots.push(id.into());
    }
}
