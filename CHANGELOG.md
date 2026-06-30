# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Features

- Add parsing foundation, data model, and semver (by @willothy)
- Add hand-written TOML, YAML, and JSON parsers (by @willothy)
- Add lockfile adapters for all seven formats (by @willothy)
- Add diffing and dependency-graph analysis (by @willothy)
- Add Rust native module for parsing and git access (by @willothy)
- Add diff viewer, public API, and user command (by @willothy)
- Support lazy-lock.json (lazy.nvim) (by @willothy)
- Download prebuilt binary in build step, fall back to source (by @willothy)
- Use nightly prebuilt when it matches HEAD exactly (by @willothy)

### Bug Fixes

- Suppress transitive reason for graphless formats (by @willothy)
- Guard musl detection when ldd is unavailable (by @willothy)

### Refactor

- Parse and access git through the native module (by @willothy)
- Classify versions with semver and pep440_rs crates (by @willothy)

### Documentation

- Add README, help doc, and license (by @willothy)

### Testing

- Add Makefile and Lua test suite (by @willothy)

### CI

- Add test and release workflows (by @willothy)
- Build and publish nightly binaries on main pushes (by @willothy)
- Fix zig setup to match fff.nvim (by @willothy)

### Styling

- Apply rustfmt (by @willothy)


