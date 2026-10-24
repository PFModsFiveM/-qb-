// Runs every tests/specs/*_spec.lua in its own fresh Lua VM (fengari, Lua 5.3).
// Resource files are loaded from disk unmodified except for a small preprocessor that
// rewrites the Cfx Lua extensions fengari does not understand.
const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const TESTS = __dirname;
const QB_ROOT = path.resolve(TESTS, "..");
const RESOURCES = path.resolve(QB_ROOT, "..");

// Replaces `name` hash literals with their joaat number, but only in code: backticks inside string
// literals and comments (SQL identifiers such as `players`) are left alone, as in FiveM's Lua.
function replaceHashLiterals(src) {
    let out = "", i = 0;
    const n = src.length;
    const longOpen = (at) => /^\[(=*)\[/.exec(src.slice(at, at + 64));
    while (i < n) {
        const c = src[i];
        if (c === "-" && src[i + 1] === "-") {                          // comment
            const m = longOpen(i + 2);
            let end;
            if (m) { end = src.indexOf("]" + m[1] + "]", i + 2 + m[0].length); end = end < 0 ? n : end + m[1].length + 2; }
            else { end = src.indexOf("\n", i); if (end < 0) end = n; }
            out += src.slice(i, end); i = end; continue;
        }
        if (c === "[") {                                                 // long string
            const m = longOpen(i);
            if (m) {
                let end = src.indexOf("]" + m[1] + "]", i + m[0].length);
                end = end < 0 ? n : end + m[1].length + 2;
                out += src.slice(i, end); i = end; continue;
            }
        }
        if (c === '"' || c === "'") {                                   // quoted string
            let j = i + 1;
            while (j < n && src[j] !== c && src[j] !== "\n") { if (src[j] === "\\") j++; j++; }
            out += src.slice(i, j + 1); i = j + 1; continue;
        }
        if (c === "`") {                                                 // `hash` literal
            const end = src.indexOf("`", i + 1);
            const nl = src.indexOf("\n", i + 1);
            if (end > 0 && (nl < 0 || end < nl)) { out += String(joaat(src.slice(i + 1, end))); i = end + 1; continue; }
        }
        out += c; i++;
    }
    return out;
}

function preprocess(src) {
    return replaceHashLiterals(src)
        // a?.b?.c  ->  ((a or {}).b or {}).c
        .replace(/^.*\?[.\[].*$/gm, rewriteSafeNav)
        // x += y  ->  x = x + (y)   (statement form, also inline before `end`)
        .replace(/([A-Za-z_][\w.]*(?:\[[^\]\n]+\])?)[ \t]*([+\-*/])=(?!=)[ \t]*(.+?)(?=[ \t]+end\b|[ \t]*$)/gm, "$1 = $1 $2 ($3)");
}

// Rewrites Cfx safe navigation on one line by wrapping the whole expression in front of each
// `?.` / `?[` (identifiers, dots, balanced (...) and [...]) as `(expr or {})`.
function rewriteSafeNav(line) {
    let i;
    while ((i = line.search(/\?[.\[]/)) !== -1) {
        let start = i;
        let depth = 0;
        while (start > 0) {
            const ch = line[start - 1];
            if (ch === ")" || ch === "]") { depth++; start--; continue; }
            if (ch === "(" || ch === "[") {
                if (depth === 0) break;
                depth--; start--; continue;
            }
            if (depth > 0 || /[\w.:]/.test(ch)) { start--; continue; }
            break;
        }
        const expr = line.slice(start, i);
        line = line.slice(0, start) + "(" + expr + " or {})" + line.slice(i + 1);
    }
    return line;
}

function joaat(s) {
    let h = 0;
    for (const ch of s.toLowerCase()) {
        h = (h + ch.charCodeAt(0)) >>> 0;
        h = (h + (h << 10)) >>> 0;
        h = (h ^ (h >>> 6)) >>> 0;
    }
    h = (h + (h << 3)) >>> 0;
    h = (h ^ (h >>> 11)) >>> 0;
    h = (h + (h << 15)) >>> 0;
    return h | 0;
}

function resolveResourcePath(rel) {
    // "pfm-inventory/server/main.lua" -> [qb]/pfm-inventory/...; "[pfscripts]/pf-x/..." -> resources/[pfscripts]/...
    if (rel.startsWith("[")) return path.join(RESOURCES, rel);
    if (rel.startsWith("tests/")) return path.join(QB_ROOT, rel);
    return path.join(QB_ROOT, rel);
}

function newState() {
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    lua.lua_pushcfunction(L, (Ls) => {
        const rel = to_jsstring(lauxlib.luaL_checkstring(Ls, 1));
        const file = resolveResourcePath(rel);
        if (!fs.existsSync(file)) return lauxlib.luaL_error(Ls, to_luastring("file not found: " + rel));
        lua.lua_pushstring(Ls, to_luastring(preprocess(fs.readFileSync(file, "utf8"))));
        return 1;
    });
    lua.lua_setglobal(L, to_luastring("__readfile"));
    return L;
}

function runChunk(L, src, name) {
    if (lauxlib.luaL_loadbuffer(L, to_luastring(src), null, to_luastring("@" + name)) !== lua.LUA_OK) {
        throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
    }
    if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
        throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
    }
    const out = lua.lua_isstring(L, -1) ? to_jsstring(lua.lua_tostring(L, -1)) : null;
    lua.lua_pop(L, 1);
    return out;
}

// Runs every *_spec.lua in `dir` (filtered by name). `prepare(L, spec)` can install extra globals
// into each fresh Lua state before the spec runs (the real-database runner uses it).
function runSpecs(dir, filter, prepare) {
    const specs = fs.readdirSync(dir).filter(f => f.endsWith("_spec.lua") && (!filter || f.includes(filter))).sort();
    const testlib = fs.readFileSync(path.join(TESTS, "lua", "testlib.lua"), "utf8");
    let passed = 0, failed = 0;
    const failures = [];
    for (const spec of specs) {
        const L = newState();
        try {
            if (prepare) prepare(L, spec);
            runChunk(L, testlib, "tests/lua/testlib.lua");
            runChunk(L, preprocess(fs.readFileSync(path.join(dir, spec), "utf8")), "tests/" + path.basename(dir) + "/" + spec);
            const summary = JSON.parse(runChunk(L, "return __SUMMARY_JSON()", "summary"));
            passed += summary.passed;
            failed += summary.failed;
            console.log(`${summary.failed ? "FAIL" : "ok  "}  ${spec}  (${summary.passed} passed, ${summary.failed} failed)`);
            for (const f of summary.failures) failures.push(`${spec}: ${f}`);
        } catch (e) {
            failed++;
            console.log(`FAIL  ${spec}  (crashed)`);
            failures.push(`${spec}: CRASH ${e.message}`);
        }
    }
    if (failures.length) {
        console.log("\nFailures:");
        for (const f of failures) console.log("  - " + f);
    }
    console.log(`\n${passed} passed, ${failed} failed, ${specs.length} spec files`);
    return failed;
}

module.exports = { preprocess, newState, runChunk, runSpecs, TESTS, QB_ROOT, RESOURCES };

if (require.main === module) {
    const failedCount = runSpecs(path.join(TESTS, "specs"), process.argv[2]);
    process.exit(failedCount ? 1 : 0);
}
