// Install SQL files on a fresh database: each must load without errors, and loading it a second
// time must not fail either (server owners re-import files when updating).
//   PF_TEST_DB="mysql://root@127.0.0.1:3399" node realdb/sql_install_check.js
// Uses a throwaway database `pf_rt_sql_install` that is dropped at the end. Never point it at live.
const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');

const url = process.env.PF_TEST_DB;
if (!url) { console.log('PF_TEST_DB is not set; SQL install check skipped.'); process.exit(0); }

const RES = path.resolve(__dirname, '..', '..', '..');   // .../resources
const qb = (...p) => path.join(RES, '[qb]', ...p);
const pf = (...p) => path.join(RES, '[pfscripts]', ...p);

// loaded whole first: the tables the checked files build on
const PREREQS = [qb('pfm-core', 'qbcore.sql'), qb('pfm-garages', 'player_vehicles.sql'), qb('pfm-inventory', 'qb-inventory.sql')];
const CHECKED = [
    qb('pfm-vehicleshop', 'vehshop.sql'),
    pf('pf-garageuionly', 'sql', 'garage.sql'),
];

function statements(file) {
    return fs.readFileSync(file, 'utf8').replace(/^\s*--.*$/gm, '')
        .split(/;\s*(?:\r?\n|$)/).map(s => s.trim()).filter(Boolean);
}

(async () => {
    const c = await mysql.createConnection({ uri: url, multipleStatements: true });
    const DB = 'pf_rt_sql_install';
    await c.query(`DROP DATABASE IF EXISTS ${DB}; CREATE DATABASE ${DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; USE ${DB}`);
    let failed = 0;
    try {
        for (const f of PREREQS) await c.query(fs.readFileSync(f, 'utf8'));
        for (const f of CHECKED) {
            for (const pass of [1, 2]) {
                for (const s of statements(f)) {
                    try { await c.query(s); } catch (e) {
                        failed++;
                        console.log(`FAIL ${path.relative(RES, f)} (load ${pass}): ${e.message}\n    ${s.slice(0, 140).replace(/\s+/g, ' ')}`);
                    }
                }
            }
            if (!failed) console.log(`ok    ${path.relative(RES, f)} (loaded twice)`);
        }
        // the inventory upgrade: copies old rows once and keeps newer inventories
        await c.query(`CREATE TABLE gloveboxitems (plate varchar(20), items longtext);
            CREATE TABLE stashitems (stash varchar(100), items longtext);
            CREATE TABLE trunkitems (plate varchar(20), items longtext);
            INSERT INTO gloveboxitems VALUES ('TEST01', '[]');
            INSERT INTO stashitems VALUES ('stash_a', '[{"name":"old"}]');
            INSERT INTO trunkitems VALUES ('TEST01', '[]');
            INSERT INTO inventories (identifier, items) VALUES ('stash_a', '[{"name":"newer"}]')`);
        const up = fs.readFileSync(qb('pfm-inventory', 'upgrade', 'migrate_from_old_qb_inventory.sql'), 'utf8');
        await c.query(up); await c.query(up);
        const [rows] = await c.query('SELECT identifier, items FROM inventories ORDER BY identifier');
        const got = rows.map(r => r.identifier + '=' + r.items).join(' | ');
        const want = 'glovebox-TEST01=[] | stash_a=[{"name":"newer"}] | trunk-TEST01=[]';
        if (got !== want) { failed++; console.log(`FAIL inventory upgrade: ${got}`); }
        else console.log('ok    pfm-inventory upgrade (copies once, keeps newer inventories)');
    } finally {
        await c.query(`DROP DATABASE IF EXISTS ${DB}`);
        await c.end();
    }
    console.log(failed ? `${failed} failed` : 'all SQL install checks passed');
    process.exit(failed ? 1 : 0);
})().catch(e => { console.log('ERR', e.message); process.exit(1); });
