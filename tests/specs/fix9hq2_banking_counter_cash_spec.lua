-- pfm-banking cash points (qb-banking:server:withdraw / deposit / openATM): the server checks where
-- the player stands. Counter cash (own and society accounts, withdraw and deposit) needs a bank counter
-- (Config.locations); ATM withdrawals need one of the listed ATMs (Config.ATMs) and a bank card; the ATM
-- screen has no deposit. A modified client cannot move cash from anywhere. Branch closures still
-- refuse at the closed branch. Real ledger on the fake database.
load_resource('tests/lua/ledger_env.lua')
load_resource('pfm-banking/server_branches.lua')

local ME, BOSS = 1, 2
local LEGION = Config.locations[1]
local ALTA = Config.locations[2]
local FAR = vector3(1000.0, 1000.0, 30.0)
local ATM = Config.ATMs[1]           -- esx_atm's Paleto Bay ATM, far from every bank counter
local hasCard

local function cash(src) return Mock.players[src].PlayerData.money.cash end
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function withdraw(src, accountName, amount) return Mock.callCallback('qb-banking:server:withdraw', src, { accountName = accountName, amount = amount }) end
local function deposit(src, accountName, amount) return Mock.callCallback('qb-banking:server:deposit', src, { accountName = accountName, amount = amount }) end
local function openATM(src) return Mock.callCallback('qb-banking:server:openATM', src) end
local function at(src, p, dx) Mock.coords[src] = vector3(p.x + (dx or 0), p.y, p.z) end
local function lastNotice(src)
    local msg
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.target == src then msg = e.args[1] end end
    return msg
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    BankBranches.__reset()
    Mock.players, Mock.coords = {}, {}
    hasCard = true
    Mock.exportsByResource['pfm-inventory'] = {
        GetItemsByName = function(_, src, name)
            assert_eq(name, 'bank_card')
            return hasCard and { { name = 'bank_card', info = { cardPin = 1234 } } } or {}
        end,
    }
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

describe('the ATM list', function()
    it('is a real list of points on the map, with no duplicates, away from the counters it does not belong to', function()
        assert_true(#Config.ATMs >= 70, 'esx_atm (71) plus vRP (5)')
        for i, p in ipairs(Config.ATMs) do
            assert_true(type(p) == 'table' or type(p) == 'userdata' or type(p) == 'vector3', 'entry ' .. i)
            assert_true(p.x > -4000 and p.x < 4500 and p.y > -4000 and p.y < 8000 and p.z > 0 and p.z < 300, 'entry ' .. i .. ' on the map')
            for j = i + 1, #Config.ATMs do
                assert_true(#(p - Config.ATMs[j]) > 0.5, ('entries %d and %d are the same point'):format(i, j))
            end
        end
        for _, c in ipairs(Config.locations) do
            assert_true(#(ATM - c) > 50, 'the test ATM is not at a counter')
        end
        assert_true(Config.CashRange.counter > 0 and Config.CashRange.atm > 0)
        assert_true(Config.CashRange.atm <= 5, 'a few metres')
    end)
end)

describe('counter cash needs a bank counter', function()
    it('withdraw and deposit away from every counter and ATM are refused and nothing moves', function()
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

    it('just outside the counter range is refused; inside it cash moves once through the ledger', function()
        local r = Config.CashRange.counter
        at(ME, LEGION, r + 0.5)
        assert_eq(withdraw(ME, 'checking', 100).message, 'error.toofar')
        at(ME, LEGION, r - 0.5)
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

    it('the counter needs no bank card', function()
        hasCard = false
        at(ME, LEGION)
        assert_true(withdraw(ME, 'checking', 100).success)
        assert_true(deposit(ME, 'checking', 100).success)
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

describe('ATM cash needs a listed ATM', function()
    it('at a listed ATM: the screen opens and a withdrawal pays out once; there is no deposit', function()
        at(ME, ATM)
        local accounts, _, pins = openATM(ME)
        assert_true(type(accounts) == 'table')
        assert_eq(pins[1], 1234)
        assert_true(withdraw(ME, 'checking', 60).success)
        assert_eq(cash(ME), 360)
        assert_eq(bank(ME), 4940)
        local dp = deposit(ME, 'checking', 10)
        assert_false(dp.success, 'the ATM has no deposit')
        assert_eq(dp.message, 'error.toofar')
        assert_eq(cash(ME), 360)
    end)

    it('the ATM range is a few metres around the listed point', function()
        local r = Config.CashRange.atm
        at(ME, ATM, r - 0.5)
        assert_true(withdraw(ME, 'checking', 10).success)
        at(ME, ATM, r + 0.5)
        assert_eq(withdraw(ME, 'checking', 10).message, 'error.toofar')
        assert_eq(openATM(ME), false)
        assert_eq(lastNotice(ME), 'error.atm')
        assert_eq(cash(ME), 310)
    end)

    it('opening the ATM screen somewhere else grants nothing (a modified client)', function()
        at(ME, FAR)
        assert_eq(openATM(ME), false, 'refused away from every listed ATM')
        assert_eq(lastNotice(ME), 'error.atm')
        assert_eq(withdraw(ME, 'checking', 10).message, 'error.toofar')
        -- even after a real ATM session, walking away ends it
        at(ME, ATM)
        assert_true(type(openATM(ME)) == 'table')
        at(ME, FAR)
        assert_eq(withdraw(ME, 'checking', 10).message, 'error.toofar')
        assert_eq(cash(ME), 300)
    end)

    it('an ATM needs a bank card on the server, not only on the screen', function()
        hasCard = false
        at(ME, ATM)
        assert_eq(openATM(ME), false)
        assert_eq(lastNotice(ME), 'error.card')
        local wd = withdraw(ME, 'checking', 10)
        assert_false(wd.success)
        assert_eq(wd.message, 'error.card')
        assert_eq(cash(ME), 300)
    end)

    it('the boss can take society cash at an ATM (the ATM lists that account); others cannot', function()
        at(BOSS, ATM)
        assert_true(withdraw(BOSS, 'mechanic', 100).success)
        assert_eq(cash(BOSS), 400)
        assert_eq(exports['pfm-banking']:GetAccountBalance('mechanic'), 900)
        at(ME, ATM)
        assert_eq(withdraw(ME, 'mechanic', 100).message, 'error.access')
        assert_false(deposit(BOSS, 'mechanic', 100).success, 'no society deposit at an ATM')
    end)

    it('an ATM next to a closed branch refuses too', function()
        local branch, nearAtm
        for id, c in ipairs(Config.locations) do
            for _, p in ipairs(Config.ATMs) do
                local d = #(p - c)
                if d < Config.BranchClosure.radius and d > Config.CashRange.counter then branch, nearAtm = id, p break end
            end
            if branch then break end
        end
        assert_true(branch ~= nil, 'a listed ATM near a branch, outside its counter')
        at(ME, nearAtm)
        assert_true(withdraw(ME, 'checking', 10).success)
        assert_true(BankBranches.Close(branch, 20, 'test'))
        local wd = withdraw(ME, 'checking', 10)
        assert_false(wd.success)
        assert_true(wd.message:find('closed', 1, true) ~= nil, wd.message)
        assert_eq(openATM(ME), false)
        assert_eq(cash(ME), 310)
    end)

    it('an empty ATM list refuses every ATM; the counter keeps working', function()
        local saved = Config.ATMs
        Config.ATMs = {}
        at(ME, ATM)
        local ok, err = pcall(function()
            assert_eq(openATM(ME), false)
            assert_eq(withdraw(ME, 'checking', 10).message, 'error.toofar')
            at(ME, LEGION)
            assert_true(withdraw(ME, 'checking', 10).success)
        end)
        Config.ATMs = saved
        assert_true(ok, err)
    end)
end)

describe('/atmcheck (staff helper for Config.ATMs)', function()
    it('names the listed ATM in range, or prints the line to add from the server position', function()
        at(ME, ATM)
        assert_true(BankingInternal.AtmCheckMessage(ME):find('entry 1 is in range', 1, true) ~= nil)
        Mock.coords[ME] = vector3(10.5, 20.25, 30.125)
        local msg = BankingInternal.AtmCheckMessage(ME)
        assert_true(msg:find('vector3(10.500, 20.250, 30.125)', 1, true) ~= nil, msg)
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
