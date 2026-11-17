-- pfm-policejob officer telemetry on a real database (batch 18, unit 18C): batched multi-row inserts
-- with NULL columns, the timeline read with its window and cursor paging, holds that keep a window
-- past retention (idempotent), and the retention sweep that skips held rows.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
function GetCurrentResourceName() return 'pfm-policejob' end
function GetEntityHeading() return 0.0 end
QBCore = QBCoreMock
QBCoreMock.Commands.Add = function() end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
Mock.exportsByResource['pfm-inventory'] = { HasItem = function() return true end }

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/config_equipment.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/schema.lua')
assert(PFPoliceSchema.Run(), 'schema')
load_resource('pfm-policejob/server/telemetry.lua')
local T = PFTelemetry

local COP, SGT = 1, 2
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params or {})) or 0 end

local p = Mock.newPlayer(COP, 'COPCID')
p.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 0 } }
local s = Mock.newPlayer(SGT, 'SGTCID')
s.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 3 } }
Mock.coords[COP] = vector3(123.456, -78.9, 30.1)
Player(COP).state.radioChannel = 0

describe('telemetry on a real database', function()
    it('the tables exist (server/schema.lua v3)', function()
        assert_eq(count("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name IN ('pf_police_telemetry', 'pf_police_telemetry_holds')"), 2)
    end)
    it('recording writes batched rows; NULL coordinates and data are stored as NULL', function()
        Mock.useables.bodycam(COP)
        T.Tick()
        T.Push({ cid = 'COPCID', device = 'srv', kind = 'anomaly', clientReported = 0, at = Mock.clock })
        Config.Equipment.Telemetry.InsertBatch = 2
        local n = #T.buffer
        assert_eq(T.Flush(), n)
        assert_eq(count('SELECT COUNT(*) FROM pf_police_telemetry WHERE citizenid = ?', { 'COPCID' }), n)
        local row = MySQL.single.await("SELECT x, data FROM pf_police_telemetry WHERE kind = 'pos' LIMIT 1", {})
        assert_near(tonumber(row.x), 123.46, 0.001)
        assert_eq(row.data, nil)
        assert_eq(count("SELECT COUNT(*) FROM pf_police_telemetry WHERE kind = 'anomaly' AND x IS NULL"), 1)
    end)
    it('GetTimeline reads a window in pages for a supervisor; a lower grade cannot read others', function()
        local base = Mock.clock
        for i = 1, 5 do T.Push({ cid = 'COPCID', device = 'body', kind = 'note', data = json.encode({ i = i }), clientReported = i == 5 and 1 or 0, at = base + i }) end
        local r = T.GetTimeline('COPCID', base + 1, base + 10, { viewer = SGT, limit = 3 })
        assert_true(r.ok, r.error)
        assert_eq(#r.events, 3)
        assert_true(r.next ~= nil)
        local r2 = T.GetTimeline('COPCID', base + 1, base + 10, { viewer = SGT, limit = 3, after = r.next })
        assert_eq(#r2.events, 2)
        assert_eq(r2.next, nil)
        assert_eq(r2.events[2].data.i, 5)
        assert_true(r2.events[2].clientReported)
        assert_eq(T.GetTimeline('SGTCID', base, base + 10, { viewer = COP }).error, 'no_permission')
    end)
    it('a hold is idempotent and keeps its window through the retention sweep', function()
        MySQL.query.await('DELETE FROM pf_police_telemetry', {})
        local old = Mock.clock - 40 * 86400
        for i = 1, 4 do T.Push({ cid = 'COPCID', device = 'body', kind = 'pos', x = 1, y = 2, z = 3, clientReported = 0, at = old + i * 100 }) end
        T.Push({ cid = 'SGTCID', device = 'dash', kind = 'pos', x = 1, y = 2, z = 3, clientReported = 0, at = old + 150 })
        T.Push({ cid = 'COPCID', device = 'body', kind = 'pos', x = 1, y = 2, z = 3, clientReported = 0, at = Mock.clock })
        T.Flush()
        local h = T.Hold('COPCID', old + 150, old + 250, 'case:42')
        assert_true(h.ok)
        local again = T.Hold('COPCID', old + 150, old + 250, 'case:42')
        assert_true(again.duplicate)
        assert_eq(again.holdId, h.holdId)
        assert_eq(count('SELECT COUNT(*) FROM pf_police_telemetry_holds'), 1)
        local removed = T.Sweep(Mock.clock)
        assert_eq(removed, 4)                                    -- COP at +100, +300, +400 and SGT at +150 (not held)
        assert_eq(count('SELECT COUNT(*) FROM pf_police_telemetry WHERE citizenid = ? AND at BETWEEN ? AND ?', { 'COPCID', old + 150, old + 250 }), 1)
        assert_eq(count('SELECT COUNT(*) FROM pf_police_telemetry WHERE at = ?', { Mock.clock }), 1)
    end)
end)
