-- pfm-streetraces: the server builds and judges races; stakes and pots move through the ledger.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetCurrentResourceName() return 'pfm-banking' end
function GetResourceState() return 'started' end

Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']

Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
local bankingConfig = Config
Config = nil
load_resource('pfm-streetraces/config.lua')
for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
load_resource('pfm-streetraces/server/main.lua')

local L = PFLedger
local A, B, C = 1, 2, 3
local START, FINISH = vector3(0.0, 0.0, 0.0), vector3(1000.0, 0.0, 0.0)
local function cash(src) return Mock.players[src].PlayerData.money.cash end
local function cmd(name, src, args) Commands[name](src, args or {}) end
local function raceIdOf(src)
    local ev = Mock.clientEventsNamed('qb-streetraces:SetRaceId')
    for i = #ev, 1, -1 do if ev[i].target == src then return ev[i].args[1] end end
end
local function create(src, stake)
    cmd('createrace', src, { tostring(stake) })
    Mock.fireNet('qb-streetraces:NewRace', src, { endx = FINISH.x, endy = FINISH.y, endz = FINISH.z })
    return raceIdOf(src)
end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    FakeDB.migrations = {}
    Mock.clock = Mock.clock + 10000
    Mock.players, Mock.coords = {}, {}
    for k in pairs(BankingAccounts) do BankingAccounts[k] = nil end
    for _, src in ipairs({ A, B, C }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = 20000, bank = 0 }
        Mock.coords[src] = START
    end
    L.ready, L.failed = false, false
    assert(L.Start(), 'ledger start')
end

describe('street races', function()
    it('a forged race table with a huge pot pays nothing', function()
        Mock.fireNet('qb-streetraces:NewRace', A, { amount = 0, pot = 100000000, joined = {}, startx = 0, starty = 0, startz = 0, endx = 500, endy = 0, endz = 0 })
        assert_eq(raceIdOf(A), nil)                                    -- no /createrace: no race
        for id = 1000, 9999, 997 do Mock.fireNet('qb-streetraces:RaceWon', A, id) end
        assert_eq(cash(A), 20000)
    end)
    it('the stake is the one /createrace checked, and a forged entrant list is ignored', function()
        cmd('createrace', A, { '500' })
        Mock.fireNet('qb-streetraces:NewRace', A, { amount = 1, pot = 1, joined = { A, A, A, A }, endx = FINISH.x, endy = FINISH.y, endz = FINISH.z })
        assert_eq(cash(A), 19500)
        cmd('cancelrace', A)
        assert_eq(cash(A), 20000)                                      -- refunded once, not four times
    end)
    it('a race pays the pot once, to an entrant at the finish after a real drive', function()
        local id = create(A, 1000)
        Mock.fireNet('qb-streetraces:JoinRace', B, id)
        assert_eq(cash(B), 19000)
        cmd('startrace', A)
        -- C never joined; A claims instantly from the start; B claims away from the finish
        Mock.coords[C] = FINISH
        Mock.fireNet('qb-streetraces:RaceWon', C, id)
        Mock.fireNet('qb-streetraces:RaceWon', A, id)
        Mock.fireNet('qb-streetraces:RaceWon', B, id)
        assert_eq(cash(C), 20000)
        assert_eq(cash(A), 19000)
        Mock.clock = Mock.clock + 60
        Mock.coords[B] = FINISH
        Mock.fireNet('qb-streetraces:RaceWon', B, id)
        assert_eq(cash(B), 21000)
        Mock.coords[A] = FINISH
        Mock.fireNet('qb-streetraces:RaceWon', A, id)                 -- the pot is gone
        assert_eq(cash(A), 19000)
    end)
    it('joining needs to be at the start, once, and not after the start', function()
        local id = create(A, 1000)
        Mock.coords[B] = FINISH
        Mock.fireNet('qb-streetraces:JoinRace', B, id)
        assert_eq(cash(B), 20000)
        Mock.coords[B] = START
        Mock.fireNet('qb-streetraces:JoinRace', B, id)
        Mock.fireNet('qb-streetraces:JoinRace', B, id)
        assert_eq(cash(B), 19000)
        cmd('startrace', A)
        Mock.fireNet('qb-streetraces:JoinRace', C, id)
        assert_eq(cash(C), 20000)
    end)
    it('quitting before the start refunds the stake once', function()
        local id = create(A, 1000)
        Mock.fireNet('qb-streetraces:JoinRace', B, id)
        cmd('quitrace', B)
        cmd('quitrace', B)
        assert_eq(cash(B), 20000)
    end)
end)
