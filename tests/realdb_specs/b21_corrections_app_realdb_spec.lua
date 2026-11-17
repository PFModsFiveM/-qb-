-- Batch 21E on MariaDB: the Corrections MDT's own reads in pfm-prison server/apps.lua, on the
-- pfm-prison schema (key pfm-prison) and a players table:
--   * names of offline inmates from players.charinfo (one IN query), unknown ids remembered;
--   * infractions paged 25 at a time (LIMIT ? OFFSET ?) per filter: awaiting a hearing oldest
--     first, decided and all newest first;
--   * an inmate's work log and trust moves, newest first;
--   * the trust overview: settled rows only, accounts above zero, largest first;
--   * the headcount history.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState(name) return name == 'pf-devices' and 'missing' or 'started' end
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

function GetCurrentResourceName() return 'pfm-prison' end
Config = nil
load_resource('pfm-prison/config.lua')
load_resource('pfm-prison/config_facility.lua')
load_resource('pfm-prison/server/schema.lua')
PFPrison = {
    Bridge = { rows = {}, SaveRow = function() end, Justice = function() return nil end, LegacyRuntime = function() return false end },
    Internal = {
        insidePrison = function() return true end, pedPos = function() return nil end,
        lockdownUntil = function() return 0 end, alarmActive = function() return false end,
        inmates = {}, gateOpen = {}, sentenceOf = function() return 0 end,
    },
}
load_resource('pfm-prison/server/facility.lua')
load_resource('pfm-prison/server/schedule.lua')
load_resource('pfm-prison/server/discipline.lua')
load_resource('pfm-prison/server/apps.lua')
local F, A, B = PFPrison.Facility, PFPrison.Apps, PFPrison.Bridge
PFPrison.Economy = { Balance = function() return { settled = 0, outPending = 0, inPending = 0, available = 0 } end }

local T0 = os.time({ year = 2026, month = 11, day = 17, hour = 12, min = 0, sec = 0 })
Mock.clock = T0
local function staff(src, cid, grade)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'corrections', onduty = true, grade = { level = grade } }
    Mock.players[src] = p
end

describe('21E corrections app reads on MariaDB', function()
    it('migrates the prison schema and has a players table', function()
        assert_true(PFPrisonSchema.Run())
        assert_true(PFPrisonSchema.Ready())
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS players (citizenid VARCHAR(50) NOT NULL PRIMARY KEY, charinfo LONGTEXT NULL)]])
    end)

    it('names offline inmates from players.charinfo and remembers unknown ids', function()
        MySQL.insert.await('INSERT INTO players (citizenid, charinfo) VALUES (?, ?), (?, ?)',
            { 'RA1', json.encode({ firstname = 'Rae', lastname = 'Able' }), 'RB2', json.encode({ firstname = 'Rob', lastname = 'Baker' }) })
        A.names = {}
        local names = A.Names({ 'RA1', 'RB2', 'NOPE', 'RA1' })
        assert_eq(names.RA1, 'Rae Able')
        assert_eq(names.RB2, 'Rob Baker')
        assert_eq(names.NOPE, nil)
        assert_true(A.names.NOPE ~= nil)
        assert_eq(A.names.NOPE.name, false)
    end)

    it('pages infractions per filter with LIMIT ? OFFSET ?', function()
        staff(9, 'CO9', 2)
        for i = 1, 27 do
            MySQL.insert.await([[INSERT INTO pf_prison_infractions (citizenid, order_id, code, severity, state, at) VALUES (?, 1, 'P-100', 1, ?, ?)]],
                { 'RA1', i <= 26 and 'reported' or 'sanctioned', T0 + i })
        end
        MySQL.insert.await([[INSERT INTO pf_prison_infractions (citizenid, order_id, code, severity, state, at) VALUES ('RB2', 1, 'P-300', 4, 'dismissed', ?)]], { T0 + 50 })
        local p1 = A.Handlers.infractions(9, { filter = 'open', page = 1 })
        assert_true(p1.ok)
        assert_eq(#p1.list, 25)
        assert_true(p1.hasMore)
        assert_eq(p1.list[1].id, 1)
        assert_eq(p1.names.RA1, 'Rae Able')
        local p2 = A.Handlers.infractions(9, { filter = 'open', page = 2 })
        assert_eq(#p2.list, 1)
        assert_false(p2.hasMore)
        assert_eq(p2.list[1].id, 26)
        local closed = A.Handlers.infractions(9, { filter = 'closed' })
        assert_eq(#closed.list, 2)
        assert_eq(closed.list[1].state, 'dismissed')
        assert_eq(closed.list[2].state, 'sanctioned')
        local all = A.Handlers.infractions(9, { filter = 'all' })
        assert_eq(all.list[1].id, 28)
        assert_eq(#all.list, 25)
        assert_true(all.hasMore)
    end)

    it('reads the work log, the trust moves and the trust overview', function()
        staff(9, 'CO9', 1)
        MySQL.insert.await([[INSERT INTO pf_prison_work_log (citizenid, order_id, job, ticket, credit_seconds, wage, at) VALUES
            ('RA1', 7, 'kitchen', 1, 300, 20, ?), ('RA1', 7, 'laundry', 2, 240, 15, ?)]], { T0, T0 + 10 })
        MySQL.insert.await([[INSERT INTO pf_prison_account_tx (citizenid, kind, amount, ledger_key, ledger_state, ref, at) VALUES
            ('RA1', 'deposit', 100, 'k1', 'completed', NULL, ?), ('RA1', 'purchase', -30, 'k2', 'completed', NULL, ?),
            ('RA1', 'deposit', 500, 'k3', 'failed', NULL, ?), ('RB2', 'earning', 200, 'k4', 'completed', NULL, ?),
            ('RC3', 'earning', 40, 'k5', 'pending', NULL, ?), ('RD4', 'deposit', 10, 'k6', 'completed', NULL, ?),
            ('RD4', 'purchase', -10, 'k7', 'completed', NULL, ?)]], { T0, T0 + 1, T0 + 2, T0, T0, T0, T0 + 1 })
        local work = F.Db('query', 'SELECT job, credit_seconds, wage, at FROM pf_prison_work_log WHERE citizenid = ? ORDER BY id DESC LIMIT 10', { 'RA1' })
        assert_eq(work[1].job, 'laundry')
        local t = A.Trust('RA1')
        assert_true(t.available)
        assert_eq(#t.recent, 3)
        assert_eq(t.recent[1].state, 'failed')
        assert_eq(t.recent[2].kind, 'purchase')
        local res = A.Handlers.trust(9, {})
        assert_true(res.ok)
        assert_eq(#res.accounts, 2) -- RC3 only pending, RD4 at zero
        assert_eq(res.accounts[1].cid, 'RB2')
        assert_eq(res.accounts[1].balance, 200)
        assert_eq(res.accounts[2].balance, 70)
        assert_eq(res.total, 270)
    end)

    it('reads the headcount history newest first', function()
        staff(9, 'CO9', 0)
        MySQL.insert.await([[INSERT INTO pf_prison_counts (facility, due_at, closed_at, expected, present, missing, by_cid) VALUES
            ('bolingbroke', ?, ?, 2, 1, ?, 'CO9'), ('bolingbroke', ?, ?, 1, 1, '{"interrupted":true}', NULL)]],
            { T0, T0 + 60, json.encode({ missing = { 'RA1' }, offline = {} }), T0 + 100, T0 + 160 })
        local res = A.Handlers.schedule(9)
        assert_true(res.ok)
        assert_eq(#res.counts, 2)
        assert_true(res.counts[1].interrupted)
        assert_eq(res.counts[2].present, 1)
        assert_eq(res.counts[2].by, 'CO9')
        assert_eq(res.counts[2].missing[1], 'RA1')
        assert_eq(res.names.RA1, 'Rae Able')
    end)
end)
