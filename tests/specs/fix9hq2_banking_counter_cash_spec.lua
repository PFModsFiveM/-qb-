-- pfm-banking counter cash (qb-banking:server:withdraw / deposit): the server checks that the player
-- stands at a bank counter (Config.locations), so a modified client cannot move cash or society cash
-- from anywhere. ATM withdrawals keep working near the spot where the ATM was opened. Branch closures
-- still refuse at the counter the player stands at. Real ledger on the fake database.
load_resource('tests/lua/ledger_env.lua')
load_resource('pfm-banking/server_branches.lua')
Mock.exportsByResource['pfm-inventory'] = { GetItemsByName = function() return { { info = { cardPin = 1234 } } } end }

local ME, BOSS = 1, 2
local LEGION = Config.locations[1]
local ALTA = Config.locations[2]
local FAR = vector3(1000.0, 1000.0, 30.0)

local function cash(src) return Mock.players[src].PlayerData.money.cash end
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function withdraw(src, accountName, amount) return Mock.callCallback('qb-banking:server:withdraw', src, { accountName = accountName, amount = amount }) end
local function deposit(src, accountName, amount) return Mock.callCallback('qb-banking:server:deposit', src, { accountName = accountName, amount = amount }) end
local function at(src, p) Mock.coords[src] = vector3(p.x, p.y, p.z) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    BankBranches.__reset()
    Mock.players, Mock.coords = {}, {}
    local me = Mock.newPlayer(ME, 'ME000001')
    me.PlayerData.money = { cash = 300, bank = 5000 }
    me.PlayerData.gang = { name = 'none', isboss = false }
    local boss = Mock.newPlayer(BOSS, 'BOSS0001')
    boss.PlayerData.money = { cash = 300, bank = 5000 }
    boss.PlayerData.job = { name = 'mechanic', isboss = true, grade = { level = 4 } }
    boss.PlayerData.gang = { name = 'none', isboss = false }
    for _, p in ipairs({ me, boss }) do
        FakeDB.players[p.PlayerData.citizenid] = { citizenid = p.PlayerData.citizenid, money = json.encode(p.PlayerData.money) }
    end
    exports['pfm-banking']:CreateJobAccount('mechanic', 1000)
end

describe('counter cash needs a bank counter', function()
    it('withdraw and deposit away from every counter are refused and nothing moves', function()
        at(ME, FAR)
        local wd = withdraw(ME, 'checking', 100)
        assert_false(wd.success)
        assert_eq(wd.message, 'error.toofar')
        local dp = deposit(ME, 'checking', 100)
        assert_false(dp.success)
        assert_eq(dp.message, 'error.toofar')
        assert_eq(cash(ME), 300)
        assert_eq(bank(ME), 5000)
        assert_eq(#LedgerEnv.paid('bank:'), 0)
    end)

    it('society cash away from a counter is refused for the boss too', function()
        at(BOSS, FAR)
        assert_false(withdraw(BOSS, 'mechanic', 100).success)
        assert_false(deposit(BOSS, 'mechanic', 100).success)
        assert_eq(cash(BOSS), 300)
        assert_eq(exports['pfm-banking']:GetAccountBalance('mechanic'), 1000)
    end)

    it('at a counter cash moves once through the ledger', function()
        at(ME, vector3(LEGION.x + 1.5, LEGION.y, LEGION.z))
        assert_true(withdraw(ME, 'checking', 100).success)
        assert_eq(cash(ME), 400)
        assert_eq(bank(ME), 4900)
        assert_true(deposit(ME, 'checking', 50).success)
        assert_eq(cash(ME), 350)
        assert_eq(bank(ME), 4950)
        at(BOSS, ALTA)
        assert_true(withdraw(BOSS, 'mechanic', 200).success)
        assert_eq(cash(BOSS), 500)
        assert_true(deposit(BOSS, 'mechanic', 100).success)
        assert_eq(exports['pfm-banking']:GetAccountBalance('mechanic'), 900)
    end)

    it('a closed branch still refuses at its own counter; another counter works', function()
        TriggerEvent('qb-banking:server:SetBankClosed', 1, true) -- robbery bank 1 is Alta (branch 2)
        at(ME, ALTA)
        local wd = withdraw(ME, 'checking', 100)
        assert_false(wd.success)
        assert_true(wd.message:find('closed', 1, true) ~= nil, wd.message)
        assert_false(deposit(ME, 'checking', 100).success)
        assert_eq(cash(ME), 300)
        at(ME, LEGION)
        assert_true(withdraw(ME, 'checking', 100).success)
        assert_eq(cash(ME), 400)
    end)
end)

describe('ATM withdrawals', function()
    it('work near the ATM that was opened, not from elsewhere or after the session ends', function()
        local atm = vector3(500.0, -500.0, 30.0)
        at(ME, atm)
        assert_eq(withdraw(ME, 'checking', 10).message, 'error.toofar', 'no ATM opened yet')
        assert_true(type(Mock.callCallback('qb-banking:server:openATM', ME)) == 'table')
        assert_true(withdraw(ME, 'checking', 10).success)
        assert_eq(cash(ME), 310)
        assert_false(deposit(ME, 'checking', 10).success, 'the ATM has no deposit')
        at(ME, FAR)
        assert_false(withdraw(ME, 'checking', 10).success, 'walked away from the ATM')
        at(ME, atm)
        Mock.clock = Mock.clock + 601
        assert_false(withdraw(ME, 'checking', 10).success, 'session expired')
        assert_true(type(Mock.callCallback('qb-banking:server:openATM', ME)) == 'table')
        Mock.fireEvent('playerDropped', ME)
        assert_false(withdraw(ME, 'checking', 10).success, 'session cleared on drop')
        assert_eq(cash(ME), 310)
    end)
end)

describe('remote bank transfers', function()
    it('internal transfers between accounts need no counter', function()
        at(BOSS, FAR)
        local res = Mock.callCallback('qb-banking:server:internalTransfer', BOSS, { fromAccountName = 'checking', toAccountName = 'mechanic', amount = 100 })
        assert_true(res.success, res.message)
        assert_eq(bank(BOSS), 4900)
        assert_eq(cash(BOSS), 300)
    end)
end)
