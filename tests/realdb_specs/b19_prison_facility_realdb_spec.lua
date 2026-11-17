-- Batch 19 (19D) on MariaDB: pfm-prison schema v2 facility, v3 economy, v4 security (key pfm-prison)
-- and the facility modules' own SQL (server/facility.lua, schedule.lua, discipline.lua,
-- visitation.lua):
--   * v2-v4 apply once on a v1 install, a rerun applies nothing, every step can run again;
--   * cells are seeded from config (layout from config, out-of-service kept from the table);
--   * classification reads escapes and serious sanctioned infractions;
--   * infractions are keyed (UNIQUE idem_key: duplicate / key_reused), hearings write privileges and
--     solitary rows, a forfeit pf-justice could not take is found again after a restart, automatic
--     hearings only restrict privileges;
--   * headcounts open, close once (compare-and-set) and a restart closes an open one as interrupted;
--   * visit bookings count the slot, the inmate's day and the visitor's open bookings; a restart
--     reloads open visits; a manual lockdown survives a restart; deleted characters are removed.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState(name) return name == 'pf-citizen' and 'missing' or 'started' end
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
function SetEntityCoords() end

function GetCurrentResourceName() return 'pfm-prison' end
Config = nil
load_resource('pfm-prison/config.lua')
load_resource('pfm-prison/config_facility.lua')
load_resource('pfm-prison/server/schema.lua')

local MIDDLE = Config.Locations.middle
local justiceCalls, justiceAnswer = {}, { ok = true, applied = 600 }
PFPrison = {
    Bridge = {
        rows = {},
        SaveRow = function(row)
            MySQL.update.await([[INSERT INTO pf_prison_inmates (citizenid, order_id, facility, status, cell_id, classification, admitted_at, status_at)
                VALUES (?, ?, 'bolingbroke', ?, ?, ?, 0, 0) ON DUPLICATE KEY UPDATE cell_id = VALUES(cell_id), classification = VALUES(classification)]],
                { row.citizenid, row.order_id, row.status, row.cell_id, row.classification })
        end,
        Justice = function(name, ...)
            justiceCalls[#justiceCalls + 1] = { name = name, args = { ... } }
            return justiceAnswer
        end,
        LegacyRuntime = function() return false end,
    },
    Internal = {
        insidePrison = function(pos) return pos ~= nil and #(vector3(pos.x, pos.y, 0) - vector3(MIDDLE.x, MIDDLE.y, 0)) <= 200 end,
        pedPos = function(src) return GetEntityCoords(GetPlayerPed(src)) end,
        lockdownUntil = function() return 0 end,
        alarmActive = function() return false end,
        inmates = {}, gateOpen = {},
        sentenceOf = function() return 0 end,
    },
}
load_resource('pfm-prison/server/facility.lua')
load_resource('pfm-prison/server/schedule.lua')
load_resource('pfm-prison/server/discipline.lua')
load_resource('pfm-prison/server/visitation.lua')
local F, S, D, V, B = PFPrison.Facility, PFPrison.Schedule, PFPrison.Discipline, PFPrison.Visitation, PFPrison.Bridge

local function n(sql, args) return tonumber(MySQL.scalar.await(sql, args or {})) end
local function tableExists(t)
    return n('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }) == 1
end
local T0 = os.time({ year = 2026, month = 11, day = 17, hour = 12, min = 0, sec = 0 })
Mock.clock = T0
local SLOT = Config.Facility.Visitation.SlotMinutes * 60
local function inside(src) Mock.coords[src] = vector3(MIDDLE.x + 5, MIDDLE.y, MIDDLE.z) end
local function admit(src, cid, orderId)
    Mock.players[src] = Mock.newPlayer(src, cid)
    inside(src)
    B.rows[cid] = { citizenid = cid, order_id = orderId, status = 'in_cell', classification = 'medium', admitted_at = T0, status_at = T0 }
    B.SaveRow(B.rows[cid])
end
local function staff(src, cid, grade)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'corrections', onduty = true, grade = { level = grade } }
    Mock.players[src] = p
    inside(src)
end

describe('pfm-prison schema v2-v4 (19D)', function()
    it('applies v2-v4 once on a v1 install; a rerun applies nothing; every step is rerun-safe', function()
        assert_true(RunMigrations('pfm-prison', { PFPrisonSchema.Migrations[1] }))
        assert_eq(n("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-prison'"), 1)
        assert_true(PFPrisonSchema.Run())
        assert_eq(n("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-prison'"), 4)
        for _, t in ipairs({ 'pf_prison_cells', 'pf_prison_counts', 'pf_prison_infractions', 'pf_prison_visits', 'pf_prison_privileges',
            'pf_prison_account_tx', 'pf_prison_work_log', 'pf_prison_searches', 'pf_prison_escapes' }) do
            assert_true(tableExists(t), t)
        end
        PFPrisonSchema.ready = false
        assert_true(PFPrisonSchema.Run())
        assert_eq(n("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-prison'"), 4)
        for _, list in ipairs({ PFPrisonSchema.V2, PFPrisonSchema.V3, PFPrisonSchema.V4 }) do
            for _, sql in ipairs(list) do MySQL.query.await(sql) end
        end
    end)
    it('v3 / v4 keys hold: one trust row per ledger key, one work row per order ticket', function()
        MySQL.insert.await("INSERT INTO pf_prison_account_tx (citizenid, kind, amount, ledger_key, ledger_state, at) VALUES ('C1', 'earning', 10, 'k1', 'completed', 1)")
        assert_false(pcall(MySQL.insert.await, "INSERT INTO pf_prison_account_tx (citizenid, kind, amount, ledger_key, at) VALUES ('C1', 'earning', 10, 'k1', 1)"))
        MySQL.insert.await("INSERT INTO pf_prison_work_log (citizenid, order_id, job, ticket, at) VALUES ('C1', 5, 'laundry', 1, 1)")
        assert_false(pcall(MySQL.insert.await, "INSERT INTO pf_prison_work_log (citizenid, order_id, job, ticket, at) VALUES ('C1', 5, 'kitchen', 1, 1)"))
        MySQL.insert.await("INSERT INTO pf_prison_escapes (citizenid, order_id, method, escaped_at) VALUES ('C1', 5, 'gate', 1)")
        MySQL.insert.await("INSERT INTO pf_prison_searches (facility, kind, target, by_cid, at) VALUES ('bolingbroke', 'cell', 'A101', 'CO', 1)")
        MySQL.update.await("DELETE FROM pf_prison_escapes")
    end)
end)

describe('pfm-prison facility SQL (19D)', function()
    it('seeds cells from config and keeps the out-of-service flag across a reseed', function()
        assert_true(F.Boot(T0))
        assert_eq(n('SELECT COUNT(*) FROM pf_prison_cells'), #Config.Facility.Cells)
        MySQL.update.await("UPDATE pf_prison_cells SET out_of_service = 1, capacity = 9 WHERE cell_id = 'A101'")
        F.LoadCells()
        assert_true(F.cells.A101.outOfService)
        assert_eq(n("SELECT capacity FROM pf_prison_cells WHERE cell_id = 'A101'"), 2) -- layout is config's
        MySQL.update.await("UPDATE pf_prison_cells SET out_of_service = 0")
        F.LoadCells()
    end)
    it('classification: time to serve, then an escape record or a serious sanctioned infraction', function()
        assert_eq(F.Classify('K1', { requiredSeconds = 30 * 60 }), 'min')
        assert_eq(F.Classify('K1', { requiredSeconds = 600 * 60 }), 'max')
        MySQL.insert.await("INSERT INTO pf_prison_infractions (citizenid, code, severity, state, at) VALUES ('K1', 'P-310', 5, 'sanctioned', ?)", { T0 - 60 })
        assert_eq(F.Classify('K1', { requiredSeconds = 30 * 60 }), 'medium')
        MySQL.insert.await("INSERT INTO pf_prison_escapes (citizenid, order_id, method, escaped_at) VALUES ('K1', 1, 'gate', ?)", { T0 - 60 })
        assert_eq(F.Classify('K1', { requiredSeconds = 30 * 60 }), 'max')
        assert_eq(F.Classify('K2', { requiredSeconds = 120 * 60 }), 'medium')
    end)
    it('infractions are keyed: the same key returns the first row, another code is key_reused', function()
        admit(1, 'INM1', 71)
        local a = D.Record('INM1', { code = 'P-200' }, { key = 'pfm-prison:test:1', actor = { kind = 'system', label = 'spec' } })
        assert_true(a.ok)
        local b = D.Record('INM1', { code = 'P-200' }, { key = 'pfm-prison:test:1', actor = { kind = 'system', label = 'spec' } })
        assert_true(b.duplicate)
        assert_eq(b.infractionId, a.infractionId)
        local c = D.Record('INM1', { code = 'P-100' }, { key = 'pfm-prison:test:1', actor = { kind = 'system', label = 'spec' } })
        assert_eq(c.error, 'key_reused')
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_infractions WHERE citizenid = 'INM1'"), 1)
        assert_eq(n('SELECT order_id FROM pf_prison_infractions WHERE id = ?', { a.infractionId }), 71)
    end)
    it('a hearing writes privilege and solitary rows; a forfeit pf-justice could not take is retried after a restart', function()
        staff(10, 'CO10', 3)
        local r = D.Record('INM1', { code = 'P-300' }, { actor = { src = 10 } })
        staff(11, 'CO11', 2)
        Mock.clock = T0 + 400
        justiceAnswer = { ok = false, error = 'busy' }
        local res = D.HoldHearing(11, r.infractionId, { verdict = 'guilty', sanctions = { forfeitMinutes = 10, solitaryMinutes = 20,
            privileges = { { kind = 'yard', hours = 2 }, { kind = 'yard', hours = 5 } } } })
        assert_true(res.ok)
        assert_eq(res.sanction.forfeit.state, 'pending')
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_prison_infractions WHERE id = ?', { r.infractionId }), 'sanctioned')
        assert_eq(MySQL.scalar.await('SELECT heard_by FROM pf_prison_infractions WHERE id = ?', { r.infractionId }), 'CO11')
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_privileges WHERE citizenid = 'INM1' AND kind = 'solitary'"), 1)
        D.priv = {}
        D.LoadPrivileges('INM1')
        assert_eq(D.priv.INM1.yard, Mock.clock + 5 * 3600)
        assert_true(D.InSolitary('INM1'))
        -- restart: privileges and the pending forfeit come back from the tables
        D.pending, D.priv = {}, {}
        D.Boot(Mock.clock)
        assert_true(D.InSolitary('INM1'))
        assert_true(D.pending[r.infractionId] ~= nil)
        justiceAnswer = { ok = true, applied = 600 }
        justiceCalls = {}
        assert_eq(D.RetryForfeits(), 1)
        assert_eq(justiceCalls[1].args[3].key, ('pfm-prison:discipline:%d:forfeit'):format(r.infractionId))
        local rec = json.decode(MySQL.scalar.await('SELECT sanction FROM pf_prison_infractions WHERE id = ?', { r.infractionId }))
        assert_eq(rec.forfeit.state, 'applied')
        assert_eq(rec.forfeit.applied, 600)
    end)
    it('an automatic hearing (nobody on duty) restricts privileges only and skips a released inmate', function()
        Mock.players[10], Mock.players[11] = nil, nil
        admit(2, 'INM2', 72)
        local a = D.Record('INM2', { code = 'P-300' }, { actor = { kind = 'system' } })
        local gone = D.Record('INM2', { code = 'P-100' }, { actor = { kind = 'system' } })
        MySQL.update.await("UPDATE pf_prison_infractions SET citizenid = 'GONE' WHERE id = ?", { gone.infractionId })
        D.lastOfficerAt = Mock.clock
        Mock.clock = Mock.clock + Config.Facility.Discipline.AutoHearingAfter + 10
        justiceCalls = {}
        assert_eq(D.AutoHearings(Mock.clock), 3) -- also the keyed INM1 report still waiting
        assert_eq(#justiceCalls, 0)
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_prison_infractions WHERE id = ?', { a.infractionId }), 'sanctioned')
        assert_eq(MySQL.scalar.await('SELECT heard_by FROM pf_prison_infractions WHERE id = ?', { a.infractionId }), 'auto')
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_prison_infractions WHERE id = ?', { gone.infractionId }), 'dismissed')
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_privileges WHERE citizenid = 'INM2' AND kind = 'solitary'"), 0)
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_privileges WHERE citizenid = 'INM2'"), 2)
    end)
    it('a headcount opens with an inmate online, closes once, and a restart closes an open one', function()
        Mock.clock = T0
        local c = S.OpenCount(T0, T0 + 300, T0)
        assert_true(c ~= nil)
        Mock.coords[2] = vector3(0, 0, 0) -- INM2 outside the walls
        local res = S.CloseCount('CO10', T0 + 60)
        assert_eq(res.expected, 2)
        assert_eq(res.present, 1)
        assert_eq(res.missing[1], 'INM2')
        local row = MySQL.single.await('SELECT * FROM pf_prison_counts WHERE id = ?', { c.id })
        assert_eq(tonumber(row.present), 1)
        assert_eq(row.by_cid, 'CO10')
        assert_eq(json.decode(row.missing).missing[1], 'INM2')
        S.openCount = { id = c.id, dueAt = T0, closesAt = T0, expected = { INM1 = true } }
        assert_eq(S.CloseCount(nil, T0 + 70), nil) -- closed already: compare-and-set refuses
        inside(2)
        local c2 = S.OpenCount(T0 + 100, T0 + 400, T0 + 100)
        S.Boot(T0 + 200)
        assert_eq(S.openCount, nil)
        assert_eq(MySQL.scalar.await('SELECT missing FROM pf_prison_counts WHERE id = ?', { c2.id }), '{"interrupted":true}')
    end)
    it('visit bookings count the slot, the day and the visitor; a restart reloads open visits', function()
        Mock.clock = T0
        local slot = math.floor(T0 / SLOT) * SLOT + SLOT
        for i = 1, 4 do Mock.players[20 + i] = Mock.newPlayer(20 + i, 'VIS' .. i) end
        admit(3, 'INM3', 73)
        admit(4, 'INM4', 74)
        admit(5, 'INM5', 75)
        admit(6, 'INM6', 76)
        admit(7, 'INM7', 77)
        D.priv = {}
        assert_true(V.Book(21, 'INM3', slot).ok)
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_eq(V.Book(21, 'INM4', slot).error, 'conflict') -- the visitor already has that slot
        assert_true(V.Book(22, 'INM4', slot).ok)
        assert_true(V.Book(23, 'INM5', slot).ok)
        assert_true(V.Book(24, 'INM6', slot).ok)
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.players[25] = Mock.newPlayer(25, 'VIS5')
        assert_eq(V.Book(25, 'INM7', slot).error, 'conflict') -- room capacity 4
        -- the inmate's day: two social visits
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_true(V.Book(25, 'INM3', slot + SLOT).ok)
        Mock.players[26] = Mock.newPlayer(26, 'VIS6')
        assert_eq(V.Book(26, 'INM3', slot + 2 * SLOT).error, 'conflict')
        -- the visitor's open bookings: three
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_true(V.Book(26, 'INM7', slot + 2 * SLOT).ok)
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_true(V.Book(26, 'INM6', slot + 3 * SLOT).ok)
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_true(V.Book(26, 'INM5', slot + 4 * SLOT).ok)
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_eq(V.Book(26, 'INM4', slot + 5 * SLOT).error, 'conflict')
        local slots = V.Slots(21, T0)
        local first
        for _, s in ipairs(slots.slots) do if s.slotAt == slot then first = s end end
        assert_eq(first.booked, 4)
        -- restart: open visits come back; very old open ones become no-shows
        MySQL.insert.await("INSERT INTO pf_prison_visits (inmate_cid, visitor_cid, slot_at, state, created_at) VALUES ('INM3', 'OLD', ?, 'booked', 1)", { T0 - 3 * 86400 })
        V.active = {}
        V.Boot(T0)
        local count = 0
        for _ in pairs(V.active) do count = count + 1 end
        assert_eq(count, 8)
        assert_eq(MySQL.scalar.await("SELECT state FROM pf_prison_visits WHERE visitor_cid = 'OLD'"), 'no_show')
        -- a visit moves once (compare-and-set)
        local v
        for _, x in pairs(V.active) do if x.visitor == 'VIS1' then v = x end end
        local copy = { id = v.id, inmate = v.inmate, visitor = v.visitor, slotAt = v.slotAt, state = 'booked' }
        assert_true(V.Move(v, 'cancelled'))
        assert_false(V.Move(copy, 'checked_in'))
    end)
    it('a manual lockdown survives a restart until it runs out', function()
        Mock.clock = T0
        assert_true(F.ApplyLockdown(true, { reason = 'riot', minutes = 30, actorCid = 'CO10' }).ok)
        F.lockdown = { on = false }
        assert_true(F.RestoreLockdown(T0 + 60))
        assert_true(F.lockdown.on)
        assert_eq(F.lockdown.reason, 'riot')
        F.lockdown = { on = false }
        assert_false(F.RestoreLockdown(T0 + 31 * 60))
        F.ApplyLockdown(false, {})
        assert_false(F.RestoreLockdown(T0 + 60))
    end)
    it('a deleted character leaves no infraction, privilege or visit rows', function()
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'INM3')
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_infractions WHERE citizenid = 'INM3'"), 0)
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_visits WHERE inmate_cid = 'INM3' OR visitor_cid = 'INM3'"), 0)
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'INM1')
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_privileges WHERE citizenid = 'INM1'"), 0)
        assert_eq(n("SELECT COUNT(*) FROM pf_prison_infractions WHERE citizenid = 'INM1'"), 0)
    end)
end)
