# lockfile.nvim

Make lockfile diffs understandable.

Lockfile diffs are terrible. A one-line dependency bump can produce a thousand
lines of churn in `Cargo.lock` or `package-lock.json`, and the things you
actually care about — *what got added, what changed version, and whether
anything looks suspicious* — are buried. `lockfile.nvim` parses both sides of a
lockfile change and shows you the part that matters.

```
Cargo.lock   HEAD → working tree
+ 2 added   - 1 removed   ~ 2 updated   ⚠ 3 suspicious

⚠ Suspicious changes (3)
  ~ tokio  1.20.0 → 1.20.0
      ⚠ checksum changed for an unchanged version
      why: myapp → tokio
  ~ serde  1.0.150 → 2.0.0
      ⚠ major version bump (1.0.150 → 2.0.0)
      why: myapp → serde
  + evilcrate  0.1.0
      ⚠ new package pulled from a git source
      why: myapp → evilcrate
      source: git+https://github.com/evil/evilcrate#abc
+ Added (1)
  + sub1  1.0.0
      why: myapp → evilcrate → sub1
- Removed (1)
  - left-pad  1.0.0
      why: myapp → left-pad
```

## Features

- **Added / removed / updated packages**, grouped and de-noised.
- **Version-change classification** — major / minor / patch / prerelease /
  downgrade, computed per ecosystem with the `semver` crate (Cargo/npm/pnpm/
  yarn/Go) and `pep440_rs` (poetry/uv).
- **Transitive dependency reasons** — *why* is a package here? Each change shows
  the shortest path from a project root (`myapp → evilcrate → sub1`).
- **Suspicious change detection**:
  - checksum changed for an **unchanged version** (the classic tamper signal),
  - a package's **source origin** changed (e.g. registry → git),
  - **major version** bumps and **downgrades**,
  - a new package pulled from a **git / arbitrary URL** source,
  - a single change introducing a **large number of new transitive deps**.
- **Foldable view** in a floating window or split.

## Supported lockfiles

| File                 | Ecosystem | Dependency graph |
| -------------------- | --------- | ---------------- |
| `Cargo.lock`         | Rust      | yes              |
| `pnpm-lock.yaml`     | pnpm      | yes              |
| `package-lock.json`  | npm       | yes              |
| `yarn.lock`          | Yarn (Classic & Berry) | yes |
| `poetry.lock`        | Poetry    | yes              |
| `uv.lock`            | uv        | yes              |
| `go.sum`             | Go        | no¹              |
| `lazy-lock.json`     | lazy.nvim | no¹              |

¹ `go.sum` and `lazy-lock.json` record no dependency graph, so transitive
reasons are unavailable for them. For `lazy-lock.json` the pinned commit is
treated as the package "version", so a diff shows which plugins moved and to
which commit (these are not classified as semver bumps).

## Requirements

- Neovim 0.10+ (uses `vim.system`, `vim.fs`, extmark highlights).
- The native module (a hard dependency). All parsing, version comparison, and
  git access are implemented in Rust (via [`mlua`](https://github.com/mlua-rs/mlua),
  [`nom`](https://github.com/rust-bakery/nom),
  [`git2`](https://github.com/rust-lang/git2-rs),
  [`semver`](https://github.com/dtolnay/semver), and
  [`pep440_rs`](https://github.com/konstin/pep440-rs)). When you install a
  **tagged release**, a prebuilt binary is downloaded for your platform; otherwise
  the build step compiles from source, which needs a **Rust toolchain** (`cargo`).

Prebuilt binaries are published for Linux (x86_64, aarch64) and macOS (x86_64,
aarch64), both for tagged releases and as a rolling `nightly` for `main`. Other
platforms — and any checkout that doesn't exactly match a published build —
compile from source.

## Installation

The build step downloads a prebuilt native module for the installed release tag,
falling back to compiling from source (requires `cargo`).

### lazy.nvim

```lua
{
  "willothy/lockfile.nvim",
  build = function()
    require("lockfile.download").download_or_build()
  end,
  opts = {},
}
```

Prebuilt binaries are used whenever they're guaranteed to match your checked-out
source: at a release tag (e.g. `version = "*"` / `tag = "v1.0.0"`), or — when
tracking `main` — if your commit is exactly the one the latest `nightly` build
was produced from. Anything else builds from source.

### packer.nvim

```lua
use({
  "willothy/lockfile.nvim",
  run = function() require("lockfile.download").download_or_build() end,
  config = function() require("lockfile").setup() end,
})
```

### Manual

```sh
git clone https://github.com/willothy/lockfile.nvim
cd lockfile.nvim
make            # builds lua/lockfile_native.so via cargo
```

## Usage

Open a lockfile (or run from anywhere in a repository) and:

```vim
:LockfileDiff               " base (HEAD) vs working tree
:LockfileDiff HEAD~3        " an older revision vs working tree
:LockfileDiff v1.0 v2.0     " between two revisions
```

If the current buffer is not a lockfile, you'll be prompted to pick one of the
repository's tracked lockfiles.

From Lua:

```lua
require("lockfile").diff()                                  -- current buffer / pick
require("lockfile").diff({ old = "HEAD~1" })
require("lockfile").diff({ path = "/path/to/Cargo.lock", old = "main", new = "HEAD" })
```

### Keymaps inside the view

| Key            | Action                    |
| -------------- | ------------------------- |
| `q` / `<Esc>`  | close                     |
| `<Tab>` / `<CR>` | toggle fold under cursor |
| `zR` / `zM`    | open all / collapse to sections |
| `R`            | refresh                   |

## Configuration

Defaults shown:

```lua
require("lockfile").setup({
  window = {
    style = "float",     -- "float" | "split"
    width = 0.8,         -- fraction of columns, or absolute count
    height = 0.8,
    border = "rounded",
  },
  default_diff_base = "HEAD",
  analysis = {
    flag_major = true,
    flag_downgrade = true,
    flag_source_change = true,
    flag_checksum_change = true,
    flag_new_git_source = true,
    big_transitive_threshold = 10,
  },
  icons = {
    added = "+", removed = "-", updated = "~",
    suspicious = "⚠", collapsed = "▸", expanded = "▾",
  },
  -- Each plugin highlight group links (with default = true) to the target below.
  highlights = {
    LockfileAdded = "DiffAdd",
    LockfileRemoved = "DiffDelete",
    LockfileUpdated = "DiffChange",
    LockfileSuspicious = "DiagnosticError",
    LockfileMajor = "WarningMsg",
    -- ...see lua/lockfile/config.lua for the full set
  },
})
```

## How it works

```
            ┌──────────────────────── Rust native module (lockfile_native) ────────────────────────┐
raw text ──▶│ serde parsers (cargo/npm/pnpm/poetry/uv/yarn-berry)                                   │
            │ nom parser combinators (yarn-classic, go.sum)            ──▶ normalized Lockfile model │──▶ Lua table
git ───────▶│ libgit2 (read a lockfile at any revision)                                             │
            └──────────────────────────────────────────────────────────────────────────────────────┘
                                                   │
        Lua: model indexing ──▶ diff (per package name) ──▶ analyze (graph, reasons, suspicious) ──▶ render ──▶ float/split
```

Parsing, version comparison, and git access live in a Rust crate loaded through
`mlua`. Structured formats use `serde` (`toml`, `serde_yaml_ng`, `serde_json`),
the two bespoke formats (Yarn Classic, `go.sum`) use `nom` parser combinators,
and version classification uses the `semver` and `pep440_rs` crates dispatched
by ecosystem. The Lua side handles diffing, dependency-graph analysis, and
presentation.

## Development

```sh
make build      # compile the native module
make test       # cargo test (parsers) + headless-nvim Lua tests
make            # == make build
```

The compiled module is written to `lua/lockfile_native.so` (`.dll` on Windows)
and loaded via `package.loadlib`, since Neovim does not add runtimepath
`lua/?.so` to `package.cpath`.

## License

MIT
