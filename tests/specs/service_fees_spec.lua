-- Service fees on the ledger: the impound release fee (pfm-garages) credits the treasury only when it
-- was paid; the car wash (pfm-smallresources) takes cash, then bank.
load_resource('tests/lua/ledger_env.lua')

local depotPrice = {}       -- [plate] = price
local treasury = {}         -- DepositToTreasury calls
local carOwner, savedMods = {}, {}   -- player_vehicles: [plate] = citizenid / mods
FakeDB.extraPatterns = {
    { 'SELECT depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p) return depotPrice[p[1]] end },
    { 'UPDATE player_vehicles SET mods = ? WHERE plate = ? AND citizenid = ?', function(p)
        if carOwner[p[2]] == p[3] then savedMods[p[2]] = p[1] return 1 end
        return 0
    end },
}
Mock.exportsByResource['pf-government'] = {
    DepositToTreasury = function(_, amount, source, desc, by, key) treasury[#treasury + 1] = { amount = amount, key = key } return true end,
}

LedgerEnv.load('pfm-garages', { 'pfm-garages/config.lua', 'pfm-garages/server/main.lua' })

local P = 1
local function money() return Mock.players[P].PlayerData.money end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players = {}
    treasury = {}
    depotPrice = { IMPOUND1 = 500 }
    Mock.newPlayer(P).PlayerData.money = { cash = 200, bank = 1000 }
end

describe('impound release fee', function()
    it('is paid (cash short, so bank) and only then credited to the treasury', function()
        Mock.fireNet('qb-garages:server:PayDepotPrice', P, { plate = 'IMPOUND1' })
        assert_eq(money().bank, 500)
        assert_eq(money().cash, 200)
        assert_eq(#treasury, 1)
        assert_eq(treasury[1].amount, 500)
        assert_true(treasury[1].key ~= nil)
        assert_eq(#Mock.clientEventsNamed('qb-garages:client:takeOutGarage'), 1)
    end)
    it('a player who cannot pay gets no car and the treasury gets nothing', function()
        Mock.players[P].PlayerData.money = { cash = 10, bank = 10 }
        Mock.fireNet('qb-garages:server:PayDepotPrice', P, { plate = 'IMPOUND1' })
        assert_eq(#treasury, 0)
        assert_eq(#Mock.clientEventsNamed('qb-garages:client:takeOutGarage'), 0)
    end)
end)

describe("saving a parked car's mods (moved here from pfm-mechanicjob)", function()
    it('the owner saves their own car', function()
        carOwner.MYCAR = 'CID1'
        Mock.fireNet('qb-garages:server:SaveVehicleProps', P, { plate = 'MYCAR', color1 = 5 })
        assert_true(savedMods.MYCAR ~= nil)
    end)
    it("nobody else can overwrite a car's mods", function()
        carOwner.THEIRS, savedMods.THEIRS = 'CID9', nil
        Mock.fireNet('qb-garages:server:SaveVehicleProps', P, { plate = 'THEIRS', color1 = 5 })
        Mock.fireNet('qb-garages:server:SaveVehicleProps', P, 'not a table')
        assert_eq(savedMods.THEIRS, nil)
    end)
end)
