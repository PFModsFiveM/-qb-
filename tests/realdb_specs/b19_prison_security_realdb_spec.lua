-- Batch 19F on MariaDB: every statement of pfm-prison/server/security.lua against the v4 tables
-- (pf_prison_searches, pf_prison_escapes) and the v1/v2 tables it touches (pf_prison_events,
-- pf_prison_visits): search rows and the pending-forfeiture read-back, the escape lifecycle (insert,
-- warrant once, recapture once), the open-escape read-back and the character-deletion cleanup.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
load_resource('pfm-core/server/migrations.lua')
function GetResourceState() return 'missing' end
function GetCurrentResourceName() return 'pfm-prison' end
Mock.exportsByResource['pfm-core'] = Mock.exportsByResource['pfm-core'] or {}
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
Config = {}
load_resource('pfm-prison/config.lua')
load_resource('pfm-prison/server/schema.lua')

-- the parts of main.lua / justice_bridge.lua security.lua uses
local saved = {}
PFPrison = {
    Internal = {
        isCallable = function(v) return type(v) == 'function' end,
        players = function() return {} end,
        getPlayer = function() return nil end,
        pedPos = function() return nil end,
        notify = function() end,
        lockdownActive = function() return false end,
    },
    Bridge = { rows = {}, SaveRow = function(row) saved[#saved + 1] = row end },
}
load_resource('pfm-prison/server/security.lua')
local Sec = PFPrison.Security
local B = PFPrison.Bridge

local function n(sql, args) return tonumber(MySQL.scalar.await(sql, args or {})) end

describe('pfm-prison security statements (MariaDB)', function()
    it('the schema has the v4 tables', function()
        assert_true(PFPrisonSchema.Run(), tostring(PFPrisonSchema.lastError))
        assert_eq(n("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN ('pf_prison_searches', 'pf_prison_escapes')"), 2)
    end)
    it('a search row is written, completed, and a pending forfeiture is read back', function()
        local now = os.time()
        local id = MySQL.insert.await(Sec.SQL.searchInsert, { 'bolingbroke', 'pat', 'CIDS1', 'GUARD1', now })
        assert_true(tonumber(id) and tonumber(id) > 0)
        local clean = MySQL.insert.await(Sec.SQL.searchInsert, { 'bolingbroke', 'cell', 'cell:A101', 'GUARD1', now })
        MySQL.update.await(Sec.SQL.searchUpdate, { json.encode({ state = 'forfeit_pending', receiptId = 44, items = {} }), nil, id })
        MySQL.update.await(Sec.SQL.searchUpdate, { json.encode({ state = 'clean', items = {} }), nil, clean })
        Sec.pending = {}
        Sec.LoadPending()
        assert_eq(Sec.pending[tonumber(id)].receiptId, 44)
        assert_eq(Sec.pending[tonumber(clean)], nil)
        MySQL.update.await(Sec.SQL.searchUpdate, { json.encode({ state = 'evidence', receiptId = 44 }), '901,902', id })
        local row = MySQL.single.await('SELECT * FROM pf_prison_searches WHERE id = ?', { id })
        assert_eq(row.evidence_ids, '901,902')
        Sec.pending = {}
        Sec.LoadPending()
        assert_eq(next(Sec.pending), nil)
    end)
    it('an escape is recorded, gets its warrant once and is closed once at the recapture', function()
        B.rows.CIDE1 = { citizenid = 'CIDE1', order_id = 12, status = 'escaped', status_at = os.time() - 50, classification = 'medium' }
        Sec.OnEscape(1, 'CIDE1', { x = 1, y = 2, z = 3 }, { method = 'gate_hack', gate = 2 })
        local esc = Sec.escapes.CIDE1
        assert_true(esc.id ~= nil)
        assert_eq(B.rows.CIDE1.classification, 'max')
        local row = MySQL.single.await('SELECT * FROM pf_prison_escapes WHERE id = ?', { esc.id })
        assert_eq(row.order_id, 12)
        assert_eq(row.gate, '2')
        assert_eq(row.method, 'gate_hack')
        assert_eq(MySQL.update.await(Sec.SQL.escapeWarrant, { 'W1', esc.id }), 1)
        assert_eq(MySQL.update.await(Sec.SQL.escapeWarrant, { 'W2', esc.id }), 0, 'the first warrant stays')
        Sec.escapes = {}
        Sec.LoadEscapes()
        assert_eq(Sec.escapes.CIDE1.warrantId, 'W1')
        Sec.OnRecaptured('CIDE1', 12, B.rows.CIDE1.status_at)
        assert_true(MySQL.single.await('SELECT recaptured_at FROM pf_prison_escapes WHERE id = ?', { esc.id }).recaptured_at ~= nil)
        assert_eq(MySQL.update.await(Sec.SQL.escapeRecaptured, { os.time(), esc.id }), 0, 'closed once')
        Sec.escapes = {}
        Sec.LoadEscapes()
        assert_eq(Sec.escapes.CIDE1, nil)
        -- an escape row without its id in memory is closed by citizen and order
        MySQL.insert.await(Sec.SQL.escapeInsert, { 'CIDE2', 13, 'unknown', nil, os.time() })
        MySQL.update.await(Sec.SQL.escapeRecapturedByOrder, { os.time(), 'CIDE2', 13 })
        assert_eq(n('SELECT COUNT(*) FROM pf_prison_escapes WHERE citizenid = ? AND recaptured_at IS NULL', { 'CIDE2' }), 0)
    end)
    it('a visitor search marks the visit; events take the security kinds; a deleted character is cleaned up', function()
        local now = os.time()
        MySQL.insert.await("INSERT INTO pf_prison_visits (inmate_cid, visitor_cid, slot_at, state, created_at) VALUES ('CIDI', 'CIDV', ?, 'booked', ?)", { now + 600, now })
        MySQL.insert.await("INSERT INTO pf_prison_visits (inmate_cid, visitor_cid, slot_at, state, created_at) VALUES ('CIDI', 'CIDV', ?, 'booked', ?)", { now + 86400, now })
        MySQL.update.await(Sec.SQL.visitSearched, { 'CIDV', now - 3600, now + 3600 })
        assert_eq(n('SELECT COUNT(*) FROM pf_prison_visits WHERE searched = 1'), 1)
        assert_true(Sec.Event('CIDV', 'camera', { camera = 'yard' }, 'GUARD1'))
        assert_true(Sec.Event(nil, 'door', { door = 'bolingbroke_gate_1', locked = true }, 'GUARD1'))
        assert_false(Sec.Event(nil, 'nonsense', {}))
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_events WHERE kind IN ('camera', 'door')"), 2)
        MySQL.insert.await(Sec.SQL.searchInsert, { 'bolingbroke', 'pat', 'CIDS9', 'GUARD9', now })
        MySQL.insert.await(Sec.SQL.searchInsert, { 'bolingbroke', 'pat', 'CIDX', 'CIDS9', now })
        MySQL.insert.await(Sec.SQL.escapeInsert, { 'CIDS9', 20, 'gate_hack', '1', now })
        Mock.eventHandlers['pfm-core:server:characterDeleted']('CIDS9')
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_searches WHERE target = 'CIDS9'"), 0)
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_searches WHERE by_cid = 'deleted'"), 1)
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_escapes WHERE citizenid = 'CIDS9'"), 0)
    end)
end)
