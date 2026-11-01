-- pfm-management's Boss app on pf-devices (server/sv_app.lua) with the staff rules it shares with the
-- boss and gang menus (sv_boss.lua), the real pf-devices bridge and the real bank ledger on the fake
-- database: only bosses get the app, staff changes follow the menu's rules from anywhere, hiring needs
-- the person nearby, and society money moves through the ledger (cash only at the office desk).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
local started = { ['pf-devices'] = true, ['pfm-banking'] = true, ['pfm-core'] = true, ['pfm-management'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

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
function GetCurrentResourceName() return 'pfm-management' end
local offline = {}
QBCoreMock.Functions.GetOfflinePlayerByCitizenId = function(cid) return offline[cid] end
load_resource('pfm-management/server/sv_boss.lua')
load_resource('pfm-management/server/sv_gang.lua')
load_resource('pfm-management/server/sv_app.lua')
Mock.exportsByResource['pfm-management'] = Mock.exportsByResource['__self']
local L = PFLedger

local roster = {} -- rows of the players table for the employee list
FakeDB.extraPatterns = {
    { 'SELECT * FROM `players` WHERE `job` LIKE ?', function(p)
        local out = {}
        for _, r in ipairs(roster) do if ('%' .. r.jobname .. '%') == p[1] then out[#out + 1] = r end end
        return out
    end },
    { 'SELECT * FROM `players` WHERE `gang` LIKE ?', function() return {} end },
    { 'COALESCE(SUM(CASE WHEN to_account', function() return { { credits = 0, debits = 0, line_count = 0 } } end },
    { 'SELECT id, tx_id, kind, from_account, to_account, amount, reason, metadata', function(p)
        local out = {}
        for i = #FakeDB.transactions, 1, -1 do
            local tx = FakeDB.transactions[i]
            if tx.state == 'completed' and (tx.to_account == p[1] or tx.from_account == p[1]) then
                out[#out + 1] = { id = tx.id, kind = tx.kind, from_account = tx.from_account, to_account = tx.to_account, amount = tx.amount, reason = tx.reason, at = tx.created_at }
            end
        end
        return out
    end },
    { 'SELECT citizenid, charinfo FROM players WHERE citizenid IN', function() return {} end },
}

local grades = {
    ['0'] = { name = 'Trainee', payment = 50 }, ['1'] = { name = 'Mechanic', payment = 75 },
    ['2'] = { name = 'Senior', payment = 100 }, ['4'] = { name = 'Owner', payment = 150, isboss = true },
}
QBCoreMock.Shared.Jobs.mechanic = { label = 'Mechanic', grades = grades }
QBCoreMock.Shared.Jobs.police = { label = 'Police', grades = { ['0'] = { name = 'Cadet' } } }
QBCoreMock.Shared.Jobs.unemployed = { label = 'Civilian', grades = { ['0'] = { name = 'Freelancer' } } }
QBCoreMock.Shared.Gangs.ballas = { label = 'Ballas', grades = { ['0'] = { name = 'Recruit' }, ['3'] = { name = 'Boss', isboss = true } } }
QBCoreMock.Shared.Gangs.none = { label = 'None', grades = { ['0'] = { name = 'Unaffiliated' } } }

local OFFICE = Config.BossMenus.mechanic[1]
local BOSS, WORKER, OUTSIDER, SENIOR, GANGBOSS = 1, 2, 3, 4, 5

-- players whose SetJob/SetGang behave like pfm-core's (an unknown grade becomes level 0 'No Grades')
local function setter(p, field, shared)
    return function(name, grade)
        local def = shared[name]
        if not def then return false end
        local g = def.grades[tostring(grade)]
        p.PlayerData[field] = { name = name, label = def.label, onduty = true,
            grade = { level = g and tonumber(grade) or 0, name = g and g.name or 'No Grades', payment = g and g.payment or 30, isboss = g and g.isboss or false },
            isboss = g and g.isboss or false }
        return true
    end
end
local function person(src, cid, job, level, gang, glevel)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 200, bank = 3000 }
    p.Functions.SetJob = setter(p, 'job', QBCoreMock.Shared.Jobs)
    p.Functions.SetGang = setter(p, 'gang', QBCoreMock.Shared.Gangs)
    p.Functions.Save = function() end
    p.Functions.SetJob(job, level)
    p.Functions.SetGang(gang or 'none', glevel or 0)
    Mock.coords[src] = vector3(500, 500, 0)
    return p
end
local function job(src) return Mock.players[src].PlayerData.job end
local function rpc(src, method, payload) return PFDevices.HandleRpc(src, 'boss', method, payload) end
local n = 0
local function ref() n = n + 1 return ('boss-ref-%05d'):format(n) end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    FakeDB.migrations = {}
    Mock.players, Mock.coords, Mock.dropped = {}, {}, {}
    offline, roster = {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000
    PFDevices.__reset()
    PFDevices.__resetRpc()
    PFManagementApp.__reset()
    for k in pairs(BankingAccounts) do BankingAccounts[k] = nil end
    person(BOSS, 'BOSS1', 'mechanic', 4)
    person(WORKER, 'WORK1', 'mechanic', 1)
    person(OUTSIDER, 'OUT1', 'police', 0)
    person(SENIOR, 'SEN1', 'mechanic', 2)
    person(GANGBOSS, 'GANG1', 'unemployed', 0, 'ballas', 3)
    FakeDB.society('mechanic', 1000, 'job')
    FakeDB.society('ballas', 400, 'gang')
    L.ready, L.failed = false, false
    assert(L.Start(), 'ledger start')
    BankingAccounts.mechanic = { account_name = 'mechanic', account_balance = 1000, account_type = 'job' }
    BankingAccounts.ballas = { account_name = 'ballas', account_balance = 400, account_type = 'gang' }
    Mock.invokingResource = 'pfm-management'
    PFManagementApp.Register()
    Mock.invokingResource = nil
end

describe('who gets the Boss app', function()
    it('job and gang bosses, on both devices; nobody else', function()
        local app = PFDevices.GetApp('boss')
        assert_eq(app.resource, 'pfm-management')
        assert_eq(app.access.handler, true)
        assert_eq(table.concat(app.devices, ','), 'computer,tablet')
        assert_true(PFDevices.CanUseApp(BOSS, 'boss'))
        assert_true(PFDevices.CanUseApp(GANGBOSS, 'boss'))
        assert_false(PFDevices.CanUseApp(WORKER, 'boss'))
        assert_eq(rpc(WORKER, 'overview').error, 'not_authorized')
        assert_eq(rpc(WORKER, 'withdraw', { scope = 'job', amount = 10, ref = ref() }).error, 'not_authorized')
        assert_eq(rpc(BOSS, '__access').error, 'unknown_method', 'the access check is not callable')
    end)
    it('a boss who is demoted loses it at once', function()
        Mock.players[BOSS].Functions.SetJob('mechanic', 2)
        assert_eq(rpc(BOSS, 'overview').error, 'not_authorized')
    end)
    it('the overview shows the boss’s own groups, ranks, wages and balances', function()
        local res = rpc(BOSS, 'overview', { scope = 'police' })
        assert_true(res.ok)
        assert_eq(res.job.name, 'mechanic')
        assert_eq(res.job.balance, 1000)
        assert_eq(#res.job.grades, 4)
        assert_eq(res.job.grades[1].payment, 50)
        assert_eq(res.gang, nil, 'not a gang boss')
        assert_false(res.job.atOffice)
        local g = rpc(GANGBOSS, 'overview')
        assert_eq(g.job, nil)
        assert_eq(g.gang.name, 'ballas')
    end)
end)

describe('staff changes from the app', function()
    it('lists only the boss’s own staff, online and offline', function()
        roster = { { citizenid = 'WORK1', jobname = 'mechanic' }, { citizenid = 'OFF1', jobname = 'mechanic',
            job = json.encode({ name = 'mechanic', grade = { level = 0, name = 'Trainee' } }), charinfo = json.encode({ firstname = 'Olly', lastname = 'Off' }) },
            { citizenid = 'OUT1', jobname = 'mechanic' } }
        local res = rpc(BOSS, 'members', { scope = 'job' })
        assert_true(res.ok)
        local byCid = {}
        for _, m in ipairs(res.members) do byCid[m.citizenid] = m end
        assert_true(byCid.WORK1.online)
        assert_eq(byCid.OFF1.name, 'Olly Off')
        assert_false(byCid.OFF1.online)
        assert_eq(byCid.OUT1, nil, 'a police officer whose row matched the LIKE is not staff')
    end)
    it('ranks a member, never above the boss, never to a missing rank, never themselves', function()
        assert_true(rpc(BOSS, 'setGrade', { scope = 'job', citizenid = 'WORK1', grade = 2 }).ok)
        assert_eq(job(WORKER).grade.level, 2)
        assert_eq(rpc(BOSS, 'setGrade', { scope = 'job', citizenid = 'WORK1', grade = 5 }).error, 'grade_above_yours')
        assert_eq(rpc(BOSS, 'setGrade', { scope = 'job', citizenid = 'WORK1', grade = 3 }).error, 'unknown_grade')
        assert_eq(job(WORKER).grade.level, 2, 'a missing rank used to set level 0')
        assert_eq(rpc(BOSS, 'setGrade', { scope = 'job', citizenid = 'BOSS1', grade = 0 }).error, 'cannot_change_self')
        assert_eq(rpc(BOSS, 'setGrade', { scope = 'job', citizenid = 'OUT1', grade = 0 }).error, 'not_member')
        assert_eq(rpc(BOSS, 'setGrade', { scope = 'job', citizenid = 'WORK1', grade = -1 }).error, 'bad_grade')
        assert_eq(rpc(BOSS, 'setGrade', { scope = 'police', citizenid = 'WORK1', grade = 1 }).error, 'bad_request')
        assert_eq(job(OUTSIDER).name, 'police')
    end)
    it('the member is told the rank they have now (the copy from before the change held the old one)', function()
        Mock.clientEvents = {}
        assert_true(rpc(BOSS, 'setGrade', { scope = 'job', citizenid = 'WORK1', grade = 2 }).ok)
        local told = {}
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
            if e.target == WORKER then told[#told + 1] = tostring(e.args[1]) end
        end
        assert_eq(told[1], 'Your rank is now Senior.', table.concat(told, ' | '))
        assert_eq(#told, 1)
    end)
    it('an offline member is ranked and saved without a notice', function()
        offline.OFF3 = { Offline = true, PlayerData = { citizenid = 'OFF3', charinfo = {}, job = { name = 'mechanic', grade = { level = 0 } } }, Functions = {} }
        offline.OFF3.Functions.SetJob = setter(offline.OFF3, 'job', QBCoreMock.Shared.Jobs)
        local saved = false
        offline.OFF3.Functions.Save = function() saved = true end
        Mock.clientEvents = {}
        assert_true(rpc(BOSS, 'setGrade', { scope = 'job', citizenid = 'OFF3', grade = 1 }).ok)
        assert_eq(offline.OFF3.PlayerData.job.grade.name, 'Mechanic')
        assert_true(saved)
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 0)
    end)
    it('a member ranked above the boss is out of reach', function()
        Mock.players[SENIOR].PlayerData.job.grade.level = 5
        assert_eq(rpc(BOSS, 'fire', { scope = 'job', citizenid = 'SEN1' }).error, 'outranks_you')
        assert_eq(job(SENIOR).name, 'mechanic')
    end)
    it('fires its own staff, an offline member too, never itself or outsiders', function()
        offline.OFF2 = { Offline = true, PlayerData = { citizenid = 'OFF2', charinfo = {}, job = { name = 'mechanic', grade = { level = 0 } } }, Functions = {} }
        offline.OFF2.Functions.SetJob = setter(offline.OFF2, 'job', QBCoreMock.Shared.Jobs)
        local saved = false
        offline.OFF2.Functions.Save = function() saved = true end
        assert_true(rpc(BOSS, 'fire', { scope = 'job', citizenid = 'WORK1' }).ok)
        assert_eq(job(WORKER).name, 'unemployed')
        assert_true(rpc(BOSS, 'fire', { scope = 'job', citizenid = 'OFF2' }).ok)
        assert_eq(offline.OFF2.PlayerData.job.name, 'unemployed')
        assert_true(saved, 'the offline character is saved')
        assert_eq(rpc(BOSS, 'fire', { scope = 'job', citizenid = 'BOSS1' }).error, 'cannot_fire_self')
        assert_eq(rpc(BOSS, 'fire', { scope = 'job', citizenid = 'OUT1' }).error, 'not_member')
        assert_eq(rpc(BOSS, 'fire', { scope = 'job' }).error, 'bad_request')
    end)
    it('hires only someone standing next to the boss who is not on the staff yet', function()
        Mock.coords[BOSS] = vector3(0, 0, 0)
        Mock.coords[OUTSIDER] = vector3(300, 0, 0)
        assert_eq(rpc(BOSS, 'hire', { scope = 'job', id = OUTSIDER }).error, 'too_far')
        assert_eq(#rpc(BOSS, 'nearby', { scope = 'job' }).players, 0)
        Mock.coords[OUTSIDER] = vector3(2, 0, 0)
        Mock.coords[WORKER] = vector3(1, 0, 0)
        local near = rpc(BOSS, 'nearby', { scope = 'job' }).players
        assert_eq(#near, 1, 'the worker already on the staff is not offered')
        assert_eq(near[1].id, OUTSIDER)
        assert_true(rpc(BOSS, 'hire', { scope = 'job', id = OUTSIDER }).ok)
        assert_eq(job(OUTSIDER).name, 'mechanic')
        assert_eq(job(OUTSIDER).grade.level, 0)
        assert_eq(rpc(BOSS, 'hire', { scope = 'job', id = WORKER }).error, 'already_member')
        assert_eq(job(WORKER).grade.level, 1, 'an employee is not reset to the lowest rank')
        assert_eq(rpc(BOSS, 'hire', { scope = 'job', id = BOSS }).error, 'cannot_hire_self')
        assert_eq(rpc(BOSS, 'hire', { scope = 'job', id = 'x' }).error, 'bad_request')
    end)
    it('the legacy menu follows the same rules (a missing rank is refused there too)', function()
        Mock.fireNet('qb-bossmenu:server:GradeUpdate', BOSS, { cid = 'WORK1', grade = 3 })
        assert_eq(job(WORKER).grade.level, 1)
        Mock.coords[BOSS], Mock.coords[WORKER] = vector3(0, 0, 0), vector3(1, 0, 0)
        Mock.fireNet('qb-bossmenu:server:HireEmployee', BOSS, WORKER)
        assert_eq(job(WORKER).grade.level, 1)
        Mock.fireNet('qb-bossmenu:server:HireEmployee', BOSS, BOSS)
        assert_eq(job(BOSS).grade.level, 4, 'the boss cannot hire themselves down to rank 0')
    end)
    it('the exports give other resources the same rules', function()
        local ex = Mock.exportsByResource['pfm-management']
        assert_true(ex.IsBoss(BOSS))
        assert_false(ex.IsBoss(WORKER))
        local ok, err = ex.SetEmployeeGrade(BOSS, 'WORK1', 9)
        assert_false(ok)
        assert_eq(err, 'grade_above_yours')
        assert_true(ex.FireEmployee(BOSS, 'WORK1'))
    end)
end)

describe('the society account from the app', function()
    it('deposits from and withdraws to the boss’s bank through the ledger, once per ref', function()
        local r = ref()
        local dep = rpc(BOSS, 'deposit', { scope = 'job', amount = 500, account = 'bank', ref = r })
        assert_true(dep.ok, tostring(dep.error))
        assert_eq(dep.balance, 1500)
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_true(rpc(BOSS, 'deposit', { scope = 'job', amount = 500, account = 'bank', ref = r }).duplicate)
        assert_eq(Mock.players[BOSS].PlayerData.money.bank, 2500)
        assert_eq(FakeDB.bank_accounts.mechanic.account_balance, 1500)
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_true(rpc(BOSS, 'withdraw', { scope = 'job', amount = 1500, ref = ref() }).ok)
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_eq(rpc(BOSS, 'withdraw', { scope = 'job', amount = 1, ref = ref() }).error, 'insufficient_funds', 'no money is created')
        assert_eq(Mock.players[BOSS].PlayerData.money.bank, 4000)
        assert_eq(#L.Reconcile().mismatches, 0)
        local st = rpc(BOSS, 'society', { scope = 'job' })
        assert_true(st.ok)
        assert_eq(#st.rows, 2)
    end)
    it('cash only at the office desk', function()
        assert_eq(rpc(BOSS, 'deposit', { scope = 'job', amount = 100, account = 'cash', ref = ref() }).error, 'not_at_office')
        assert_eq(Mock.players[BOSS].PlayerData.money.cash, 200)
        Mock.coords[BOSS] = vector3(OFFICE.x + 1, OFFICE.y, OFFICE.z)
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_true(rpc(BOSS, 'deposit', { scope = 'job', amount = 100, account = 'cash', ref = ref() }).ok)
        assert_eq(Mock.players[BOSS].PlayerData.money.cash, 100)
        assert_eq(FakeDB.bank_accounts.mechanic.account_balance, 1100)
    end)
    it('validates amounts and refs, and the gang scope is the gang boss’s only', function()
        for _, amount in ipairs({ -1, 0, 2.5, 'abc' }) do
            assert_eq(rpc(BOSS, 'deposit', { scope = 'job', amount = amount, ref = ref() }).error, 'bad_amount', tostring(amount))
        end
        assert_eq(rpc(BOSS, 'deposit', { scope = 'job', amount = 10 }).error, 'bad_request')
        assert_eq(rpc(BOSS, 'deposit', { scope = 'gang', amount = 10, ref = ref() }).error, 'not_boss')
        assert_true(rpc(GANGBOSS, 'deposit', { scope = 'gang', amount = 50, ref = ref() }).ok)
        assert_eq(FakeDB.bank_accounts.ballas.account_balance, 450)
        assert_eq(FakeDB.bank_accounts.mechanic.account_balance, 1000)
    end)
end)

-- After a lost answer the app keeps the ref; the server must never report a different action under it
-- as done (the earlier result would be echoed with the new request's numbers).
describe('a reused ref on the society account', function()
    local function later() Mock.gameTimer = Mock.gameTimer + 5000 end
    it('the other direction under the same ref is a real move of its own', function()
        local r = ref()
        assert_true(rpc(BOSS, 'deposit', { scope = 'job', amount = 500, ref = r }).ok)
        later()
        local wd = rpc(BOSS, 'withdraw', { scope = 'job', amount = 200, ref = r })
        assert_true(wd.ok, tostring(wd.error))
        assert_false(wd.duplicate, 'the deposit was reported as a withdrawal')
        assert_eq(wd.amount, 200)
        assert_eq(FakeDB.bank_accounts.mechanic.account_balance, 1300)
        assert_eq(Mock.players[BOSS].PlayerData.money.bank, 2700)
    end)
    it('another amount under the same ref is refused and moves nothing', function()
        local r = ref()
        assert_true(rpc(BOSS, 'deposit', { scope = 'job', amount = 500, ref = r }).ok)
        later()
        local res = rpc(BOSS, 'deposit', { scope = 'job', amount = 2000, ref = r })
        assert_false(res.ok, 'reported as deposited')
        assert_eq(res.error, 'already_processed')
        assert_eq(FakeDB.bank_accounts.mechanic.account_balance, 1500)
        assert_eq(Mock.players[BOSS].PlayerData.money.bank, 2500)
    end)
    it('the other scope under the same ref is refused', function()
        Mock.players[BOSS].Functions.SetGang('ballas', 3)
        local r = ref()
        assert_true(rpc(BOSS, 'deposit', { scope = 'job', amount = 100, ref = r }).ok)
        later()
        local res = rpc(BOSS, 'deposit', { scope = 'gang', amount = 100, ref = r })
        assert_false(res.ok, 'the job deposit was reported as a gang deposit')
        assert_eq(res.error, 'already_processed')
        assert_eq(FakeDB.bank_accounts.ballas.account_balance, 400)
        assert_eq(FakeDB.bank_accounts.mechanic.account_balance, 1100)
    end)
    it('the same action resent answers with the stored amount', function()
        local r = ref()
        assert_true(rpc(BOSS, 'withdraw', { scope = 'job', amount = 300, ref = r }).ok)
        later()
        local again = rpc(BOSS, 'withdraw', { scope = 'job', amount = 300, ref = r })
        assert_true(again.ok and again.duplicate)
        assert_eq(again.amount, 300)
        assert_eq(FakeDB.bank_accounts.mechanic.account_balance, 700)
        assert_eq(Mock.players[BOSS].PlayerData.money.bank, 3300)
        assert_eq(#L.Reconcile().mismatches, 0)
    end)
    it('SocietyTransfer itself refuses a reused key for another move', function()
        local ex = Mock.exportsByResource['pfm-banking']
        local key = 'test:society:' .. ref()
        assert_true(ex.SocietyTransfer(BOSS, { society = 'mechanic', direction = 'deposit', amount = 50, key = key }).ok)
        local other = ex.SocietyTransfer(BOSS, { society = 'mechanic', direction = 'withdraw', amount = 50, key = key })
        assert_eq(other.error, 'already_processed', 'a withdrawal reported under a deposit’s key')
        assert_eq(ex.SocietyTransfer(BOSS, { society = 'mechanic', direction = 'deposit', amount = 60, key = key }).error, 'already_processed')
        local same = ex.SocietyTransfer(BOSS, { society = 'mechanic', direction = 'deposit', amount = 50, key = key })
        assert_true(same.ok and same.duplicate)
        assert_eq(same.amount, 50)
        assert_eq(FakeDB.bank_accounts.mechanic.account_balance, 1050)
    end)
end)
