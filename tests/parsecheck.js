// Parses Lua files with the same preprocessor and Lua VM the tests use (no code is run).
//   node parsecheck.js <file.lua> [...]
const fs = require("fs");
const { lua, lauxlib, to_luastring, to_jsstring } = require("fengari");
const { preprocess } = require("./harness.js");

let bad = 0;
for (const f of process.argv.slice(2)) {
    const L = lauxlib.luaL_newstate();
    const src = preprocess(fs.readFileSync(f, "utf8").replace(/^﻿/, ""));
    if (lauxlib.luaL_loadbuffer(L, to_luastring(src), null, to_luastring("@" + f)) !== lua.LUA_OK) {
        console.log("SYNTAX " + to_jsstring(lua.lua_tostring(L, -1)));
        bad++;
    }
}
console.log(`checked ${process.argv.length - 2} files, ${bad} with errors`);
process.exit(bad ? 1 : 0);
