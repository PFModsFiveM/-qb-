// Real-database test runner: runs tests/realdb_specs/*_spec.lua with the same fengari Lua VM and
// mocks as harness.js, but MySQL is a real MariaDB/MySQL server. Each spec file gets a freshly
// created database, so migrations, SQL text, column types and constraints are exercised for real.
//
//   PF_TEST_DB="mysql://root@127.0.0.1:3399" node realdb/run.js [filter]
//
// Never point this at a server that holds real data: it creates and drops `pf_rt_*` databases.
const fs = require("fs");
const path = require("path");
const { Worker } = require("worker_threads");
const { lua, lauxlib, to_luastring, to_jsstring } = require("fengari");
const H = require("../harness.js");

const url = process.env.PF_TEST_DB;
if (!url) {
    console.log("PF_TEST_DB is not set (e.g. mysql://root@127.0.0.1:3399); real-database tests skipped.");
    process.exit(0);
}
const parsed = new URL(url);
const baseConfig = {
    host: parsed.hostname, port: Number(parsed.port || 3306),
    user: decodeURIComponent(parsed.username || "root"), password: decodeURIComponent(parsed.password || ""),
};

const shared = new SharedArrayBuffer(8 + 64 * 1024 * 1024);
const control = new Int32Array(shared, 0, 2);
const bytes = new Uint8Array(shared, 8);
const worker = new Worker(path.join(__dirname, "sqlworker.js"), { workerData: { shared } });

function call(msg) {
    Atomics.store(control, 0, 0);
    worker.postMessage(msg);
    Atomics.wait(control, 0, 0, 30000);
    if (Atomics.load(control, 0) !== 1) throw new Error("database call timed out: " + (msg.sql || msg.op));
    const len = Atomics.load(control, 1);
    return JSON.parse(Buffer.from(bytes.slice(0, len)).toString("utf8"));
}

// ── Lua <-> JS values ────────────────────────────────────────────────
function luaToJs(L, idx) {
    const t = lua.lua_type(L, idx);
    if (t === lua.LUA_TNIL || t === lua.LUA_TNONE) return null;
    if (t === lua.LUA_TBOOLEAN) return lua.lua_toboolean(L, idx);
    if (t === lua.LUA_TNUMBER) return lua.lua_tonumber(L, idx);
    if (t === lua.LUA_TSTRING) return to_jsstring(lua.lua_tostring(L, idx));
    if (t !== lua.LUA_TTABLE) return null;
    idx = lua.lua_absindex(L, idx);
    const entries = [];
    let maxInt = 0, allInt = true;
    lua.lua_pushnil(L);
    while (lua.lua_next(L, idx) !== 0) {
        let key;
        if (lua.lua_type(L, -2) === lua.LUA_TNUMBER) {
            key = lua.lua_tonumber(L, -2);
            if (Number.isInteger(key) && key >= 1) maxInt = Math.max(maxInt, key); else allInt = false;
        } else {
            key = to_jsstring(lua.lua_tostring(L, -2));
            allInt = false;
        }
        entries.push([key, luaToJs(L, -1)]);
        lua.lua_pop(L, 1);
    }
    if (allInt) {
        const arr = new Array(maxInt).fill(null);
        for (const [k, v] of entries) arr[k - 1] = v;
        return arr;
    }
    const obj = {};
    for (const [k, v] of entries) obj[k] = v;
    return obj;
}

function pushJs(L, v) {
    if (v === null || v === undefined) lua.lua_pushnil(L);
    else if (typeof v === "boolean") lua.lua_pushboolean(L, v);
    else if (typeof v === "number") { if (Number.isInteger(v) && Math.abs(v) < 2 ** 31) lua.lua_pushinteger(L, v); else lua.lua_pushnumber(L, v); }
    else if (typeof v === "string") lua.lua_pushstring(L, to_luastring(v));
    else if (Array.isArray(v)) {
        lua.lua_createtable(L, v.length, 0);
        v.forEach((item, i) => { pushJs(L, item); lua.lua_rawseti(L, -2, i + 1); });
    } else if (typeof v === "object" && v.type === "Buffer" && Array.isArray(v.data)) {
        lua.lua_pushstring(L, to_luastring(Buffer.from(v.data).toString("utf8")));
    } else if (typeof v === "object") {
        lua.lua_createtable(L, 0, 0);
        for (const [k, item] of Object.entries(v)) { pushJs(L, item); lua.lua_setfield(L, -2, to_luastring(k)); }
    } else lua.lua_pushnil(L);
}

// __sql(kind, query, params) -> result shaped like oxmysql, or raises a Lua error
function sqlFn(L) {
    const kind = to_jsstring(lauxlib.luaL_checkstring(L, 1));
    const sql = to_jsstring(lauxlib.luaL_checkstring(L, 2));
    let params = lua.lua_gettop(L) >= 3 ? luaToJs(L, 3) : null;
    if (params && !Array.isArray(params)) {
        // named parameters (@name / :name) -> positional, as oxmysql does
        const named = params;
        params = [];
        const rewritten = sql.replace(/[@:]([A-Za-z_][A-Za-z0-9_]*)/g, (_, n) => { params.push(named[n] ?? null); return "?"; });
        return finish(L, kind, call({ sql: rewritten, params }));
    }
    // Lua drops trailing nils from a parameter list; oxmysql pads missing parameters with NULL
    const placeholders = countPlaceholders(sql);
    if (placeholders > 0) {
        params = params || [];
        while (params.length < placeholders) params.push(null);
    }
    return finish(L, kind, call({ sql, params: params && params.length ? params : undefined }));
}

// number of ? placeholders outside quoted strings and `identifiers`
function countPlaceholders(sql) {
    let count = 0, quote = null;
    for (let i = 0; i < sql.length; i++) {
        const c = sql[i];
        if (quote) { if (c === "\\") i++; else if (c === quote) quote = null; continue; }
        if (c === "'" || c === '"' || c === "`") quote = c;
        else if (c === "?") count++;
    }
    return count;
}

function finish(L, kind, res) {
    if (!res.ok) return lauxlib.luaL_error(L, to_luastring("SQL error: " + res.error));
    const r = res.result;
    const isRows = Array.isArray(r);
    let out;
    switch (kind) {
        case "single": out = isRows ? (r[0] ?? null) : null; break;
        case "scalar": out = isRows && r[0] ? Object.values(r[0])[0] ?? null : null; break;
        case "insert": out = isRows ? null : r.insertId; break;
        case "update": out = isRows ? 0 : r.affectedRows; break;
        default: out = r; // query / rawExecute: rows, or the result header (affectedRows, insertId)
    }
    pushJs(L, out);
    return 1;
}

// __sqlfile(path) runs a .sql file (multi-statement), path relative to the resources folder rules
function sqlFileFn(L) {
    const rel = to_jsstring(lauxlib.luaL_checkstring(L, 1));
    const file = rel.startsWith("[") ? path.join(H.RESOURCES, rel) : path.join(H.QB_ROOT, rel);
    const res = call({ sql: fs.readFileSync(file, "utf8") });
    if (!res.ok) return lauxlib.luaL_error(L, to_luastring("SQL file " + rel + ": " + res.error));
    return 0;
}

// PF_RT_SHARED_DB=<pf_rt_name>: use that database as it is (no drop/create), so several processes can
// work on one database at the same time (realdb/ledger_parallel.js). PF_RT_SPEC_DIR picks the folder.
const sharedDb = process.env.PF_RT_SHARED_DB;
if (sharedDb && !/^pf_rt_[a-z0-9_]+$/.test(sharedDb)) throw new Error("PF_RT_SHARED_DB must look like pf_rt_<name>");

function freshDatabase(spec) {
    const name = sharedDb || "pf_rt_" + spec.replace(/_spec\.lua$/, "").replace(/[^a-z0-9_]/gi, "_").toLowerCase();
    let res = call({ op: "connect", config: baseConfig });
    if (!res.ok) throw new Error("cannot connect to " + url + ": " + res.error);
    res = call({ sql: sharedDb ? `CREATE DATABASE IF NOT EXISTS \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;`
        : `DROP DATABASE IF EXISTS \`${name}\`; CREATE DATABASE \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;` });
    if (!res.ok) throw new Error(res.error);
    res = call({ op: "connect", config: { ...baseConfig, database: name } });
    if (!res.ok) throw new Error(res.error);
    return name;
}

const failedCount = H.runSpecs(path.join(H.TESTS, process.env.PF_RT_SPEC_DIR || "realdb_specs"), process.argv[2], (L, spec) => {
    const db = freshDatabase(spec);
    lua.lua_pushcfunction(L, sqlFn);
    lua.lua_setglobal(L, to_luastring("__sql"));
    lua.lua_pushcfunction(L, sqlFileFn);
    lua.lua_setglobal(L, to_luastring("__sqlfile"));
    lua.lua_pushstring(L, to_luastring(db));
    lua.lua_setglobal(L, to_luastring("__TEST_DATABASE"));
    lua.lua_pushstring(L, to_luastring(process.env.PF_RT_WORKER || ""));
    lua.lua_setglobal(L, to_luastring("__TEST_WORKER"));
    // reconnect helper for "server restart" scenarios
    lua.lua_pushcfunction(L, (Ls) => { const r = call({ op: "connect", config: { ...baseConfig, database: db } }); lua.lua_pushboolean(Ls, r.ok); return 1; });
    lua.lua_setglobal(L, to_luastring("__sqlreconnect"));
});
call({ op: "close" });
worker.terminate();
process.exit(failedCount ? 1 : 0);
