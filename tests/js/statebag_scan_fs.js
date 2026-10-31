// Test helper for tests/specs/statebag_strict_scan_spec.lua (not a spec itself).
// The Lua harness can read a file (__readfile) but cannot list a folder, so the scan spec loads
// this module with package.loadlib and calls list(root) to get every Lua file of a repository.
//   list('qb')          -> { 'pfm-core/client/events.lua', ... }        (paths __readfile accepts)
//   list('[pfscripts]') -> { '[pfscripts]/pf-hud/client.lua', ... }
const fs = require("fs");
const path = require("path");
const { lua, lauxlib, to_luastring, to_jsstring } = require("fengari");

const QB_ROOT = path.resolve(__dirname, "..", "..");
const RESOURCES = path.resolve(QB_ROOT, "..");
const SKIP_DIRS = new Set(["node_modules", ".git", "tests"]);

function walk(dir, rel, out) {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
    for (const entry of entries) {
        if (entry.isSymbolicLink()) continue;
        if (entry.isDirectory()) {
            if (SKIP_DIRS.has(entry.name) || entry.name.startsWith(".")) continue;
            walk(path.join(dir, entry.name), rel ? rel + "/" + entry.name : entry.name, out);
        } else if (entry.isFile() && entry.name.endsWith(".lua")) {
            out.push(rel ? rel + "/" + entry.name : entry.name);
        }
    }
}

function list(L) {
    const root = to_jsstring(lauxlib.luaL_checkstring(L, 1));
    const out = [];
    if (root === "qb") walk(QB_ROOT, "", out);
    else if (/^\[[\w-]+\]$/.test(root)) walk(path.join(RESOURCES, root), root, out);
    out.sort();
    lua.lua_createtable(L, out.length, 0);
    out.forEach((p, i) => {
        lua.lua_pushstring(L, to_luastring(p));
        lua.lua_rawseti(L, -2, i + 1);
    });
    return 1;
}

module.exports = { list };
