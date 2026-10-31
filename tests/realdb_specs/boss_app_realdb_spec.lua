-- pfm-management's Boss app on a real database: the staff list from the players table (the boss's own
-- job only, saved characters read from their JSON), and society deposits / withdrawals through the
-- real ledger: exactly once per ref, no overdraft, cash only at the desk, the books reconcile.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
local started = { ['pf-devices'] = true, ['pfm-banking'] = true, ['pfm-core'] = true, ['pfm-management'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
local function addPlayer(cid, job, charinfo, money)
    MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, ?, ?, ?, '{"name":"none"}', '{}', '{}', '[]')]], { cid, 'license:' .. cid, cid, json.encode(money or { cash = 0, bank = 0 }), json.encode(charinfo), json.encode(job) })
end
addPlayer('BOSS0001', { name = 'mechanic', grade = { level = 4, name = 'Owner' }, isboss = true }, { firstname = 'Bo', lastname = 'Boss' }, { cash = 500, bank = 4000 })
addPlayer('EMP00001', { name = 'mechanic', grade = { level = 1, name = 'Mechanic', payment = 75 } }, { firstname = 'Eve', lastname = 'Wrench' })
addPlayer('EMP00002', { name = 'mechanic2', grade = { level = 1 } }, { firstname = 'Not', lastname = 'Ours' })   -- LIKE '%mechanic%' matches
addPlayer('COP00001', { name = 'police', grade = { level = 3 } }, { firstname = 'Cop', lastname = 'Per' })
MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('mechanic', 1000, 'job', '[]')")

function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('[pfscripts]/pf-devices/shared/config.lua')
load_resource('pfm-management/config.lua')
function GetCurrentResourceName() return 'pf-devices' end
for _, f in ipairs({ 'registry', 'installs', 'rpc', 'push', 'sites', 'builtin_apps', 'main' }) do
    load_resource('[pfscripts]/pf-devices/server/' .. f .. '.lua')
end
Mock.exportsByResource['pf-devices'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
function GetCurrentResourceName() return 'pfm-banking' end
for _, f in ipairs({ 'pfm-core/server/migrations.lua', 'pfm-banking/server_ledger.lua', 'pfm-banking/server.lua', 'pfm-banking/server_finance.lua',
    'pfm-banking/server_accounts.lua', 'pfm-banking/server_branches.lua', 'pfm-banking/server_app.lua' }) do
    load_resource(f)
end
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
assert(PFLedger.Start(), 'ledger start')
BankingAccounts.mechanic = MySQL.single.await("SELECT * FROM bank_accounts WHERE account_name = 'mechanic'")
function GetCurrentResourceName() return 'pfm-management' end
QBCoreMock.Functions.GetOfflinePlayerByCitizenId = function() return nil end   -- saved characters come from their row
load_resource('pfm-management/server/sv_boss.lua')
load_resource('pfm-management/server/sv_gang.lua')
load_resource('pfm-management/server/sv_app.lua')
Mock.invokingResource = 'pfm-management'
PFManagementApp.Register()
Mock.invokingResource = nil

local BOSS = 1
local boss = Mock.newPlayer(BOSS, 'BOSS0001')
boss.PlayerData.money = { cash = 500, bank = 4000 }
boss.PlayerData.job = { name = 'mechanic', label = 'Mechanic', grade = { level = 4, name = 'Owner' }, isboss = true }
boss.PlayerData.gang = { name = 'none', isboss = false }
boss.PlayerData.charinfo = { firstname = 'Bo', lastname = 'Boss' }
Mock.coords[BOSS] = vector3(900, 900, 0)

local function rpc(method, payload)
    Mock.gameTimer = Mock.gameTimer + 5000
    PFDevices.__resetRpc()
    return PFDevices.HandleRpc(BOSS, 'boss', method, payload)
end
local function society() return tonumber(MySQL.scalar.await("SELECT account_balance FROM bank_accounts WHERE account_name = 'mechanic'")) end
local function count(sql) return tonumber(MySQL.scalar.await(sql)) end

describe('the staff list on a real database', function()
    it('lists the boss and their employees, not a look-alike job or other jobs', function()
        local res = rpc('members', { scope = 'job' })
        assert_true(res.ok)
        local seen = {}
        for _, m in ipairs(res.members) do seen[m.citizenid] = m end
        assert_true(seen.BOSS0001 and seen.BOSS0001.me)
        assert_eq(seen.EMP00001.name, 'Eve Wrench')
        assert_eq(seen.EMP00001.grade.level, 1)
        assert_eq(seen.EMP00001.grade.payment, 75)
        assert_false(seen.EMP00001.online)
        assert_eq(seen.EMP00002, nil, "'mechanic2' matched the LIKE but is another job")
        assert_eq(seen.COP00001, nil)
        assert_eq(res.members[1].citizenid, 'BOSS0001', 'highest rank first')
    end)
end)

describe('society money on a real database', function()
    it('moves bank money exactly once per ref, refuses overdrafts and reconciles', function()
        local dep = rpc('deposit', { scope = 'job', amount = 600, account = 'bank', ref = 'rt-boss-0001' })
        assert_true(dep.ok, tostring(dep.error))
        assert_true(rpc('deposit', { scope = 'job', amount = 600, account = 'bank', ref = 'rt-boss-0001' }).duplicate)
        assert_eq(society(), 1600)
        assert_eq(boss.PlayerData.money.bank, 3400)
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key = 'boss:BOSS0001:deposit:rt-boss-0001' AND kind = 'society_deposit' AND state = 'completed'"), 1)
        assert_true(rpc('withdraw', { scope = 'job', amount = 1600, ref = 'rt-boss-0002' }).ok)
        assert_eq(society(), 0)
        assert_eq(rpc('withdraw', { scope = 'job', amount = 1, ref = 'rt-boss-0003' }).error, 'insufficient_funds')
        assert_eq(society(), 0)
        assert_eq(boss.PlayerData.money.bank, 5000)
        assert_eq(#PFLedger.Reconcile().mismatches, 0)
    end)
    it('cash only at the office desk, through the ledger', function()
        assert_eq(rpc('deposit', { scope = 'job', amount = 200, account = 'cash', ref = 'rt-boss-0004' }).error, 'not_at_office')
        local desk = Config.BossMenus.mechanic[1]
        Mock.coords[BOSS] = vector3(desk.x, desk.y + 1, desk.z)
        assert_true(rpc('deposit', { scope = 'job', amount = 200, account = 'cash', ref = 'rt-boss-0005' }).ok)
        assert_eq(boss.PlayerData.money.cash, 300)
        assert_eq(society(), 200)
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE from_account = 'player:BOSS0001:cash' AND to_account = 'society:mechanic' AND state = 'completed'"), 1)
    end)
    it('the society tab shows the balance and the ledger lines', function()
        local res = rpc('society', { scope = 'job' })
        assert_true(res.ok)
        assert_eq(res.balance, 200)
        assert_eq(#res.rows, 3)
        assert_eq(res.rows[1].direction, 'in')
        assert_eq(res.rows[1].counterparty.label, 'Your cash')
        assert_true(res.atOffice)
    end)
end)

-- a ref the app kept after a lost answer never stands for another action
describe('a reused ref on a real database', function()
    it('another amount is refused, the other direction is a move of its own, the same action answers as stored', function()
        local soc, bank = society(), boss.PlayerData.money.bank
        assert_true(rpc('deposit', { scope = 'job', amount = 300, ref = 'rt-boss-r001' }).ok)
        local more = rpc('deposit', { scope = 'job', amount = 400, ref = 'rt-boss-r001' })
        assert_false(more.ok, 'reported as deposited')
        assert_eq(more.error, 'already_processed')
        local same = rpc('deposit', { scope = 'job', amount = 300, ref = 'rt-boss-r001' })
        assert_true(same.ok and same.duplicate)
        assert_eq(same.amount, 300, 'the stored amount (DECIMAL in the database)')
        local wd = rpc('withdraw', { scope = 'job', amount = 100, ref = 'rt-boss-r001' })
        assert_true(wd.ok, tostring(wd.error))
        assert_false(wd.duplicate, 'the deposit was reported as a withdrawal')
        assert_eq(society(), soc + 200)
        assert_eq(boss.PlayerData.money.bank, bank - 200)
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key IN ('boss:BOSS0001:deposit:rt-boss-r001', 'boss:BOSS0001:withdraw:rt-boss-r001') AND state = 'completed'"), 2)
        assert_eq(#PFLedger.Reconcile().mismatches, 0)
    end)
end)
