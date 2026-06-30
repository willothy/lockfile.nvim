use mlua::prelude::*;

mod git;
mod model;
mod parse;

/// Parse a lockfile of the given format `kind` and return the normalized model
/// as a Lua table. Raises a Lua error with a human-readable message on failure.
fn parse_lockfile(lua: &Lua, (kind, src): (String, String)) -> LuaResult<LuaValue> {
    let lockfile = parse::parse(&kind, &src).map_err(LuaError::RuntimeError)?;
    lua.to_value(&lockfile)
}

#[mlua::lua_module]
fn lockfile_native(lua: &Lua) -> LuaResult<LuaTable> {
    let exports = lua.create_table()?;

    exports.set("parse", lua.create_function(parse_lockfile)?)?;

    exports.set(
        "git_root",
        lua.create_function(|_, path: String| Ok(git::root(&path)))?,
    )?;
    exports.set(
        "git_show",
        lua.create_function(|_, (root, rev, relpath): (String, String, String)| {
            git::show(&root, &rev, &relpath).map_err(LuaError::RuntimeError)
        })?,
    )?;
    exports.set(
        "git_rev_exists",
        lua.create_function(|_, (root, rev): (String, String)| Ok(git::rev_exists(&root, &rev)))?,
    )?;
    exports.set(
        "git_list_lockfiles",
        lua.create_function(|_, (root, basenames): (String, Vec<String>)| {
            git::list_lockfiles(&root, &basenames).map_err(LuaError::RuntimeError)
        })?,
    )?;
    exports.set(
        "git_relpath",
        lua.create_function(|_, (root, abspath): (String, String)| {
            Ok(git::relpath(&root, &abspath))
        })?,
    )?;

    Ok(exports)
}
