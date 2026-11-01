-- pfm-vehicleshop repossession while pf-jobgarages is not running: the fleet entry of the car is
-- closed by pfm-vehicleshop itself, also when the fleet-table lookup failed (it used to be skipped
-- then, leaving a repossessed car in a job fleet). A fresh load: the table lookup has never been
-- answered, so the failed lookup is what the repossession sees.
load_resource('tests/lua/ledger_env.lua')
QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Vehicles = { blista = { name = 'Blista', price = 10000, shop = 'pdm', category = 'compacts' } }
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local vehicles, closed = {}, {}
local lookupBroken = true
FakeDB.extraPatterns = {
    { "AND TABLE_NAME = 'job_garage_vehicles'", function()
        if lookupBroken then error('injected: database connection lost') end
        return 1
    end },
    { 'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? AND balance > 0 AND financetime < 1', function(p)
        local v = vehicles[p[1]]
        if not v or v.citizenid ~= p[2] or (v.balance or 0) <= 0 or (v.financetime or 0) >= 1 then return { affectedRows = 0 } end
        vehicles[p[1]] = nil
        return { affectedRows = 1 }
    end },
    { 'UPDATE job_garage_vehicles SET active = 0, `out` = 0 WHERE plate = ? AND active = 1', function(p)
        closed[#closed + 1] = p[1]
        return 1
    end },
}
LedgerEnv.load('pfm-vehicleshop', { 'pfm-vehicleshop/config.lua', 'pfm-vehicleshop/settlements.lua', 'pfm-vehicleshop/server.lua' })

local realState = GetResourceState
BeforeEach = function()
    Mock.reset()
    vehicles, closed = {}, {}
    GetResourceState = function(res) if res == 'pf-jobgarages' then return 'stopped' end return realState(res) end
end

describe('repossession without pf-jobgarages running', function()
    it('closes the fleet entry even when the fleet table lookup failed', function()
        lookupBroken = true
        vehicles.REPO09 = { citizenid = 'CID1', vehicle = 'blista', plate = 'REPO09', balance = 5000, financetime = 0 }
        assert_true(PFShop.Repossess('CID1', 'REPO09'))
        assert_eq(vehicles.REPO09, nil)
        assert_eq(closed[1], 'REPO09', 'the old code skipped it when the lookup failed')
    end)

    it('closes it when the table is known', function()
        lookupBroken = false
        vehicles.REPO10 = { citizenid = 'CID1', vehicle = 'blista', plate = 'REPO10', balance = 5000, financetime = 0 }
        assert_true(PFShop.Repossess('CID1', 'REPO10'))
        assert_eq(closed[1], 'REPO10')
        GetResourceState = realState
    end)
end)
