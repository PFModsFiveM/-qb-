-- Batch 16 (16C) on MariaDB: pfm-prison's own migration key (v1: pf_prison_inmates, pf_prison_events) applies
-- once, is rerun-safe, and the bridge's inmate upsert keeps one row per citizen.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'] = Mock.exportsByResource['pfm-core'] or {}
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
load_resource('pfm-prison/server/schema.lua')

local function n(sql, args) return tonumber(MySQL.scalar.await(sql, args or {})) end
local function tableExists(t)
    return n("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?", { t }) == 1
end
-- the bridge's own statement (pfm-prison/server/justice_bridge.lua B.SQL.upsert)
local UPSERT = [[INSERT INTO pf_prison_inmates (citizenid, order_id, facility, status, cell_id, classification, admitted_at, status_at,
        job_ticket, receipt_ids) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE order_id = VALUES(order_id), facility = VALUES(facility), status = VALUES(status),
        cell_id = VALUES(cell_id), classification = VALUES(classification), admitted_at = VALUES(admitted_at),
        status_at = VALUES(status_at), job_ticket = VALUES(job_ticket), receipt_ids = VALUES(receipt_ids)]]

describe('pfm-prison schema (key pfm-prison)', function()
    it('v1 creates both tables once and a rerun applies nothing', function()
        assert_true(PFPrisonSchema.Run())
        assert_true(tableExists('pf_prison_inmates'))
        assert_true(tableExists('pf_prison_events'))
        assert_eq(n("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-prison'"), 1)
        PFPrisonSchema.ready = false
        assert_true(PFPrisonSchema.Run())
        assert_eq(n("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-prison'"), 1)
        for _, sql in ipairs(PFPrisonSchema.V1) do MySQL.query.await(sql) end -- every step is rerun-safe
    end)
    it('the bridge upsert keeps one row per citizen and the event table takes rows', function()
        MySQL.update.await(UPSERT, { 'CIDP1', 11, 'bolingbroke', 'serving', 'A1', 'medium', 100, 100, nil, '5' })
        MySQL.update.await(UPSERT, { 'CIDP1', 12, 'bolingbroke', 'releasing', 'A1', 'medium', 100, 200, nil, '5,6' })
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_inmates WHERE citizenid = 'CIDP1'"), 1)
        local row = MySQL.single.await("SELECT * FROM pf_prison_inmates WHERE citizenid = 'CIDP1'")
        assert_eq(tonumber(row.order_id), 12)
        assert_eq(row.status, 'releasing')
        assert_eq(row.receipt_ids, '5,6')
        MySQL.insert.await("INSERT INTO pf_prison_events (citizenid, facility, kind, detail, at) VALUES ('CIDP1', 'bolingbroke', 'intake', '{}', 100)")
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_events WHERE citizenid = 'CIDP1'"), 1)
    end)
end)
