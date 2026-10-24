// Worker thread that owns the MariaDB/MySQL connection for the real-database test runner.
// The Lua VM runs synchronously on the main thread, like oxmysql's `.await` inside a FiveM thread,
// so the main thread posts a query here and blocks on Atomics.wait until the result is written
// into the shared buffer.
const { parentPort, workerData } = require("worker_threads");
const mysql = require("mysql2/promise");

const control = new Int32Array(workerData.shared, 0, 2); // [0] = ready flag, [1] = byte length
const bytes = new Uint8Array(workerData.shared, 8);
let conn = null;

// oxmysql returns DATE/DATETIME/TIMESTAMP as unix milliseconds; mirror that
function typeCast(field, next) {
    if (field.type === "TIMESTAMP" || field.type === "DATETIME" || field.type === "DATE") {
        const v = field.string();
        return v === null ? null : Date.parse(v.replace(" ", "T") + (field.type === "DATE" ? "" : "Z"));
    }
    return next();
}

function reply(out) {
    const buf = Buffer.from(JSON.stringify(out));
    if (buf.length > bytes.length) {
        const err = Buffer.from(JSON.stringify({ ok: false, error: "result too large" }));
        bytes.set(err);
        Atomics.store(control, 1, err.length);
    } else {
        bytes.set(buf);
        Atomics.store(control, 1, buf.length);
    }
    Atomics.store(control, 0, 1);
    Atomics.notify(control, 0);
}

parentPort.on("message", async (msg) => {
    let out;
    try {
        if (msg.op === "connect") {
            if (conn) await conn.end();
            conn = await mysql.createConnection({
                ...msg.config, multipleStatements: true, decimalNumbers: true, supportBigNumbers: true,
                bigNumberStrings: false, typeCast,
            });
            out = { ok: true };
        } else if (msg.op === "close") {
            if (conn) await conn.end();
            conn = null;
            out = { ok: true };
        } else {
            const [result] = msg.params ? await conn.query(msg.sql, msg.params) : await conn.query(msg.sql);
            out = { ok: true, result };
        }
    } catch (e) {
        out = { ok: false, error: e.message, code: e.code };
    }
    reply(out);
});
