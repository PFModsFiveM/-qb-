-- pf-jobgarages: adding a car to a fleet refuses a car that is for sale on the used lot, re-checks
-- everything in the statement that adds it (a car listed or moved after the checks is not added, and
-- the manager is not told "added"), and fails closed when the lot's table cannot be looked up. A car
-- the dealership repossessed (pfm-vehicleshop's server event) leaves every fleet and the road, but
-- only when its record is really gone.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')

local vehicles = {}
function GetAllVehicles() local out = {} for e in pairs(vehicles) do out[#out + 1] = e end return out end
function DoesEntityExist(e) return vehicles[e] ~= nil or Mock.players[e] ~= nil end
function DeleteEntity(e) vehicles[e] = nil end
local timeouts = {}
function SetTimeout(_, fn) timeouts[#timeouts + 1] = fn end
local function runTimeouts() local t = timeouts timeouts = {} for _, fn in ipairs(t) do fn() end end

local owned, fleet, lot, nextId = {}, {}, {}, 1
local lotTable, lotLookupBroken = 1, false
local onInsert = nil   -- runs in the moment the INSERT ... SELECT executes (another player acting)
local function lastQuery() return FakeDB.log[#FakeDB.log] end

FakeDB.extraPatterns = {
    { 'FROM player_vehicles WHERE plate = ? AND (citizenid = ? OR license = ?)', function(p)
        local v = owned[p[1]]
        if v and v.citizenid == p[2] then return { plate = p[1], vehicle = v.vehicle, state = v.state or 1, depotprice = v.depotprice or 0 } end
    end },
    { 'SELECT 1 FROM player_vehicles WHERE plate = ?', function(p) return owned[p[1]] and 1 or nil end },
    { 'SELECT id FROM job_garage_vehicles WHERE plate = ? AND active = 1', function(p)
        for id, r in pairs(fleet) do if r.plate == p[1] and r.active == 1 then return id end end
    end },
    { 'SELECT min_grade_manage FROM job_garage_permissions', function() return nil end },
    { "AND TABLE_NAME = 'occasion_vehicles'", function()
        if lotLookupBroken then return nil end   -- what oxmysql gives for a query that failed
        return lotTable
    end },
    { 'SELECT id FROM occasion_vehicles WHERE plate = ?', function(p) return lot[p[1]] end },
    -- the add: one INSERT ... SELECT that re-checks the owner, parked, not impounded, no active
    -- fleet and (when the statement says so) not on the lot
    { 'INSERT INTO job_garage_vehicles', function(p)
        if onInsert then onInsert() end
        local v = owned[p[4]]
        if not v or v.citizenid ~= p[5] or (v.state or 1) ~= 1 or (v.depotprice or 0) > 0 then return 0 end
        for _, r in pairs(fleet) do if r.plate == p[7] and r.active == 1 then return 0 end end
        if lastQuery():find('occasion_vehicles', 1, true) and lot[p[8]] then return 0 end
        local id = nextId; nextId = nextId + 1
        fleet[id] = { id = id, garage_id = p[1], plate = p[4], model = v.vehicle, label = p[2], min_grade = p[3], active = 1, out = 0 }
        return 1
    end },
    { 'SELECT id, garage_id, plate, model, `out` FROM job_garage_vehicles WHERE plate = ? AND active = 1', function(p)
        local out = {}
        for _, r in pairs(fleet) do if r.plate == p[1] and r.active == 1 then out[#out + 1] = { id = r.id, garage_id = r.garage_id, plate = r.plate, model = r.model, out = r.out } end end
        return out
    end },
    { 'UPDATE job_garage_vehicles SET active = 0, `out` = 0', function(p)
        local r = fleet[p[1]]
        if r then r.active, r.out = 0, 0 end
        return 1
    end },
    { 'INSERT INTO job_garage_logs', function() return 1 end },
}

Config = nil
load_resource('[pfscripts]/pf-jobgarages/config.lua')
load_resource('[pfscripts]/pf-jobgarages/server/main.lua')

local GARAGE = 'mechanic_main'
local MANAGER = 1
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function told(text)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.args[1] == text then return true end end
    return false
end
local function add(plate) Mock.fireNet('jobgarages:addFleetVehicle', MANAGER, GARAGE, { plate = plate, label = 'Truck' }) end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    owned, fleet, lot, nextId, lotTable, lotLookupBroken, onInsert = {}, {}, {}, 1, 1, false, nil
    local p = Mock.newPlayer(MANAGER, 'CIDM')
    p.PlayerData.job = { name = 'mechanic', grade = { level = 4 }, onduty = true, isboss = true }
    p.PlayerData.license = 'license:1'
end

-- first in the file: the lot's table has not been looked up yet (a found table is kept)
describe('the used-lot check fails closed', function()
    it('without the lot installed the add works and does not name its table', function()
        lotTable = 0
        owned.NOLOT1 = { citizenid = 'CIDM', vehicle = 'flatbed' }
        add('NOLOT1')
        assert_eq(count(fleet), 1)
        for _, s in ipairs(FakeDB.log) do
            if s:find('INSERT INTO job_garage_vehicles', 1, true) then assert_true(s:find('occasion_vehicles', 1, true) == nil) end
        end
        assert_true(told('Vehicle added to job fleet.'))
        runTimeouts()   -- "no lot" is asked again after a while (pfm-vehiclesales may be installed meanwhile)
    end)

    it('a failed lookup refuses the add and is asked again next time', function()
        owned.LOT001 = { citizenid = 'CIDM', vehicle = 'flatbed' }
        lotLookupBroken = true
        add('LOT001')
        assert_eq(count(fleet), 0, 'refused while it cannot be told')
        lotLookupBroken = false
        lot.LOT001 = 7
        add('LOT001')
        assert_eq(count(fleet), 0, 'asked again: the car is on the lot')
    end)
end)

describe('adding a car to a fleet', function()
    it('a car for sale on the used lot is not added', function()
        owned.LOT002 = { citizenid = 'CIDM', vehicle = 'flatbed' }
        lot.LOT002 = 3
        add('LOT002')
        assert_eq(count(fleet), 0)
        assert_true(told('This vehicle is for sale on the used car lot.'))
        lot.LOT002 = nil
        add('LOT002')
        assert_eq(count(fleet), 1)
    end)

    it('a car listed on the lot after the checks is not added, and the manager is not told it was', function()
        owned.LOT003 = { citizenid = 'CIDM', vehicle = 'flatbed' }
        -- the owner lists it in the moment between the checks and the add
        onInsert = function() owned.LOT003 = nil lot.LOT003 = 9 end
        add('LOT003')
        assert_eq(count(fleet), 0)
        assert_false(told('Vehicle added to job fleet.'), 'not reported as added')
        assert_true(told('This vehicle changed meanwhile (moved, sold or listed) and was not added.'))
    end)

    it('the add statement itself refuses a listed car (the lot condition is in it)', function()
        owned.LOT004 = { citizenid = 'CIDM', vehicle = 'flatbed' }
        onInsert = function() lot.LOT004 = 9 end   -- listed while its record is still there
        add('LOT004')
        assert_eq(count(fleet), 0)
        local q
        for _, s in ipairs(FakeDB.log) do if s:find('INSERT INTO job_garage_vehicles', 1, true) then q = s end end
        assert_true(q:find('NOT EXISTS (SELECT 1 FROM occasion_vehicles', 1, true) ~= nil)
        assert_true(q:find('pv.state = 1', 1, true) ~= nil)
    end)

end)

describe('a repossessed car leaves the fleet', function()
    it('the fleet entries go inactive and a car out is taken off the road, only when the record is gone', function()
        owned.REPO01 = { citizenid = 'CIDM', vehicle = 'flatbed' }
        add('REPO01')
        local id = next(fleet)
        fleet[id].out = 1
        -- the record still exists: nothing happens (any server resource can raise the event)
        TriggerEvent('pfm-vehicleshop:server:vehicleRepossessed', 'REPO01', 'CIDM')
        assert_eq(fleet[id].active, 1)
        owned.REPO01 = nil
        TriggerEvent('pfm-vehicleshop:server:vehicleRepossessed', 'REPO01', 'CIDM')
        assert_eq(fleet[id].active, 0)
        assert_eq(fleet[id].out, 0)
        local despawned = Mock.clientEventsNamed('jobgarages:forceDespawn')
        assert_eq(#despawned, 1)
        assert_eq(despawned[1].args[1], 'REPO01')
    end)
end)

describe('a repossession whose fleet update fails', function()
    local DEACTIVATE = 'UPDATE job_garage_vehicles SET active = 0, `out` = 0'
    local function failOnce(text)
        for _, pat in ipairs(FakeDB.extraPatterns) do
            if pat[1] == text then
                local orig = pat[2]
                pat[2] = function() pat[2] = orig error('injected: database connection lost') end
                return
            end
        end
    end

    it('is asked again later until the fleet entry is closed (the old code left it active)', function()
        owned.REPO02 = { citizenid = 'CIDM', vehicle = 'flatbed' }
        add('REPO02')
        local id = next(fleet)
        owned.REPO02 = nil
        timeouts = {}
        failOnce(DEACTIVATE)
        TriggerEvent('pfm-vehicleshop:server:vehicleRepossessed', 'REPO02', 'CIDM')
        assert_eq(fleet[id].active, 1, 'the update failed')
        assert_eq(#timeouts, 1, 'a retry is scheduled')
        runTimeouts()
        assert_eq(fleet[id].active, 0, 'closed on the retry')
        assert_eq(#timeouts, 0, 'no more retries')
    end)

    it('a failed lookup of the car record is asked again too, and a car still owned is left alone', function()
        owned.REPO03 = { citizenid = 'CIDM', vehicle = 'flatbed' }
        add('REPO03')
        local id = next(fleet)
        timeouts = {}
        failOnce('SELECT 1 FROM player_vehicles WHERE plate = ?')
        TriggerEvent('pfm-vehicleshop:server:vehicleRepossessed', 'REPO03', 'CIDM')
        assert_eq(#timeouts, 1)
        runTimeouts()   -- the record is still there: nothing to do, no more retries
        assert_eq(fleet[id].active, 1)
        assert_eq(#timeouts, 0)
    end)
end)
