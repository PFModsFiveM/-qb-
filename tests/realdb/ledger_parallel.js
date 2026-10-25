// The ledger under truly parallel database sessions: N separate processes (each with its own
// connection) send the same and different idempotency keys to one database at the same time.
//   PF_TEST_DB="mysql://root@127.0.0.1:3399" node realdb/ledger_parallel.js [workers]
// Uses the throwaway database pf_rt_ledger_parallel (dropped before and after).
const { spawn, spawnSync } = require("child_process");
const path = require("path");
const mysql = require("mysql2/promise");

const url = process.env.PF_TEST_DB;
if (!url) { console.log("PF_TEST_DB is not set; parallel ledger test skipped."); process.exit(0); }
const N = Number(process.argv[2] || 4);
const DB = "pf_rt_ledger_parallel";
const run = path.join(__dirname, "run.js");
const env = (extra) => ({ ...process.env, PF_RT_SPEC_DIR: "realdb_parallel", PF_RT_SHARED_DB: DB, ...extra });

async function dropDb() {
    const c = await mysql.createConnection({ uri: url });
    await c.query(`DROP DATABASE IF EXISTS ${DB}`);
    await c.end();
}
function step(filter, extra) {
    const r = spawnSync(process.execPath, [run, filter], { env: env(extra), encoding: "utf8" });
    process.stdout.write(r.stdout.split("\n").filter(l => !l.includes("pf-migrations")).join("\n"));
    return r.status === 0;
}

(async () => {
    await dropDb();
    let ok = step("1_setup");
    if (ok) {
        const started = Date.now();
        const spans = [];
        const results = await Promise.all(Array.from({ length: N }, (_, i) => new Promise(resolve => {
            const t0 = Date.now();
            const child = spawn(process.execPath, [run, "2_worker"], { env: env({ PF_RT_WORKER: "w" + (i + 1) }) });
            let out = "";
            child.stdout.on("data", d => { out += d; });
            child.stderr.on("data", d => { out += d; });
            child.on("close", code => { spans.push([t0 - started, Date.now() - started]); resolve({ code, out }); });
        })));
        results.forEach((r, i) => {
            if (process.env.PF_RT_VERBOSE) console.log(r.out.split("\n").filter(l => l.startsWith("RESULT")).join("\n"));
            if (r.code !== 0) { ok = false; console.log(`worker ${i + 1} failed:\n` + r.out); } });
        const overlapStart = Math.max(...spans.map(s => s[0]));
        const overlapEnd = Math.min(...spans.map(s => s[1]));
        console.log(`${N} workers; all of them running at once for ${Math.max(0, overlapEnd - overlapStart)} ms of ${Math.max(...spans.map(s => s[1]))} ms`);
        if (ok) ok = step("3_verify", { PF_RT_WORKER: String(N) });
    }
    await dropDb();
    console.log(ok ? "parallel ledger test passed" : "parallel ledger test FAILED");
    process.exit(ok ? 0 : 1);
})().catch(e => { console.log("ERR", e.message); process.exit(1); });
