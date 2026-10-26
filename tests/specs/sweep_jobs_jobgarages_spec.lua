-- pf-jobgarages: fleet permissions fail closed. A fleet car must be the manager's own car (its model
-- comes from player_vehicles), taking one needs the garage's job, grade and saved minimum use grade
-- at the terminal, and storing one needs the car itself at the garage.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')

-- server natives the shared mocks lack
local vehicles = {}            -- [entity] = true
function GetAllVehicles() local out = {} for e in pairs(vehicles) do out[#out + 1] = e end return out end
function DoesEntityExist(e) return vehicles[e] ~= nil or Mock.players[e] ~= nil end
function DeleteEntity(e) vehicles[e] = nil; Mock.deleted[#Mock.deleted + 1] = e end
local timeouts = {}
function SetTimeout(_, fn) timeouts[#timeouts + 1] = fn end

local owned = {}               -- [plate] = { citizenid, vehicle }
local fleet = {}               -- [id] = row
local perms = {}               -- [garageId] = { min_grade_use }
local nextId = 1

local function fleetByPlate(plate, garageId)
    for _, r in pairs(fleet) do
        if r.plate == plate and r.garage_id == garageId and r.active == 1 then return r end
    end
end

FakeDB.extraPatterns = {
    { 'FROM player_vehicles WHERE plate = ? AND (citizenid = ? OR license = ?)', function(p)
        local v = owned[p[1]]
        if v and (v.citizenid == p[2]) then return { plate = p[1], vehicle = v.vehicle, state = v.state or 1, depotprice = v.depotprice or 0 } end
        return nil
    end },
    { 'SELECT mods, engine, body FROM player_vehicles', function() return nil end },
    { 'SELECT id FROM job_garage_vehicles WHERE plate = ? AND active = 1', function(p)
        for id, r in pairs(fleet) do if r.plate == p[1] and r.active == 1 then return id end end
    end },
    { 'SELECT min_grade_use FROM job_garage_permissions', function(p) return perms[p[1]] end },
    { 'INSERT INTO job_garage_vehicles', function(p)
        local id = nextId; nextId = nextId + 1
        fleet[id] = { id = id, garage_id = p[1], plate = p[2], model = p[3], label = p[4], min_grade = p[5], active = 1, out = 0, assignment_type = 'none' }
        return id
    end },
    { 'FROM job_garage_vehicles WHERE id = ? AND garage_id = ? AND active = 1', function(p)
        local r = fleet[tonumber(p[1])]
        if r and r.garage_id == p[2] and r.active == 1 then return r end
    end },
    { 'SET `out` = 1, out_citizenid = ?', function(p)
        local r = fleet[p[3]]
        if not r or r.out ~= 0 then return 0 end
        r.out, r.out_citizenid = 1, p[1]
        return 1
    end },
    { 'SELECT id, plate, model FROM job_garage_vehicles WHERE plate = ?', function(p) return fleetByPlate(p[1], p[2]) end },
    { 'SET `out` = 0', function(p) local r = fleet[p[1]]; if r then r.out = 0 end; return 1 end },
    { 'INSERT INTO job_garage_logs', function() return 1 end },
}

Config = nil
load_resource('[pfscripts]/pf-jobgarages/config.lua')
load_resource('[pfscripts]/pf-jobgarages/server/main.lua')

local GARAGE = 'mechanic_main'
local cfg = Config.JobGarages[GARAGE]
local MANAGER, MECHANIC, OUTSIDER = 1, 2, 3
local AT_TERMINAL = vector3(cfg.targetCoords.x, cfg.targetCoords.y, cfg.targetCoords.z)

local function setJob(src, name, grade)
    Mock.players[src].PlayerData.job = { name = name, grade = { level = grade }, onduty = true }
end
local function spawned(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('jobgarages:spawnVehicle')) do if e.target == src then n = n + 1 end end
    return n
end
local function addFleetCar(plate, model)
    local id = nextId; nextId = nextId + 1
    fleet[id] = { id = id, garage_id = GARAGE, plate = plate, model = model or 'flatbed', min_grade = 0, active = 1, out = 0, assignment_type = 'none' }
    return id
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.deleted = {}, {}, {}
    vehicles, owned, fleet, perms, timeouts = {}, {}, {}, {}, {}
    Mock.newPlayer(MANAGER, 'CIDM'); setJob(MANAGER, 'mechanic', 4)
    Mock.newPlayer(MECHANIC, 'CIDE'); setJob(MECHANIC, 'mechanic', 0)
    Mock.newPlayer(OUTSIDER, 'CIDO'); setJob(OUTSIDER, 'police', 4)
    for src = 1, 3 do Mock.coords[src] = AT_TERMINAL end
end

describe('a fleet car belongs to the job garage only', function()
    it('a car that is out or impounded cannot join a fleet', function()
        owned['OUTCAR'] = { citizenid = 'CIDM', vehicle = 'flatbed', state = 0 }
        owned['IMPCAR'] = { citizenid = 'CIDM', vehicle = 'flatbed', state = 0, depotprice = 500 }
        Mock.fireNet('jobgarages:addFleetVehicle', MANAGER, GARAGE, { plate = 'OUTCAR' })
        Mock.fireNet('jobgarages:addFleetVehicle', MANAGER, GARAGE, { plate = 'IMPCAR' })
        assert_eq(next(fleet), nil)
    end)
    it('a car already in a fleet is not added again', function()
        owned['TWICE1'] = { citizenid = 'CIDM', vehicle = 'flatbed' }
        Mock.fireNet('jobgarages:addFleetVehicle', MANAGER, GARAGE, { plate = 'TWICE1' })
        Mock.fireNet('jobgarages:addFleetVehicle', MANAGER, GARAGE, { plate = 'TWICE1' })
        local n = 0
        for _ in pairs(fleet) do n = n + 1 end
        assert_eq(n, 1)
    end)
end)

describe('pf-jobgarages fleet permissions', function()
    it("a manager cannot add a car they do not own (the old check allowed any plate)", function()
        owned['OTHER1'] = { citizenid = 'CIDX', vehicle = 'sultan' }
        Mock.fireNet('jobgarages:addFleetVehicle', MANAGER, GARAGE, { plate = 'OTHER1', model = 'sultan' })
        Mock.fireNet('jobgarages:addFleetVehicle', MANAGER, GARAGE, { plate = 'NOBODY', model = 'rhino' })
        assert_eq(next(fleet), nil)
    end)

    it("an owned car is added with its own model, whatever model the client names", function()
        owned['MINE01'] = { citizenid = 'CIDM', vehicle = 'flatbed' }
        Mock.fireNet('jobgarages:addFleetVehicle', MANAGER, GARAGE, { plate = 'mine01  ', model = 'rhino', min_grade = 2 })
        local id, row = next(fleet)
        assert_true(id ~= nil)
        assert_eq(row.plate, 'MINE01')
        assert_eq(row.model, 'flatbed')
        assert_eq(row.min_grade, 2)
    end)

    it('rejects a non-table payload without erroring', function()
        Mock.fireNet('jobgarages:addFleetVehicle', MANAGER, GARAGE, 'junk')
        assert_eq(next(fleet), nil)
    end)

    it("the garage's saved minimum use grade is enforced", function()
        local id = addFleetCar('FLEET1')
        perms[GARAGE] = { min_grade_use = 2 }
        local ok = Mock.callCallback('jobgarages:takeVehicle', MECHANIC, GARAGE, id)
        assert_eq(ok, false)
        assert_eq(spawned(MECHANIC), 0)
        assert_eq(fleet[id].out, 0)
    end)

    it('other jobs and players away from the terminal cannot take a car', function()
        local id = addFleetCar('FLEET1')
        assert_eq(Mock.callCallback('jobgarages:takeVehicle', OUTSIDER, GARAGE, id), false)
        Mock.coords[MECHANIC] = vector3(0, 0, 0)
        assert_eq(Mock.callCallback('jobgarages:takeVehicle', MECHANIC, GARAGE, id), false)
        assert_eq(fleet[id].out, 0)
    end)

    it('an employee at the terminal takes a car once', function()
        local id = addFleetCar('FLEET1')
        assert_eq(Mock.callCallback('jobgarages:takeVehicle', MECHANIC, GARAGE, id), true)
        assert_eq(fleet[id].out, 1)
        assert_eq(Mock.callCallback('jobgarages:takeVehicle', MANAGER, GARAGE, id), false)
        assert_eq(spawned(MECHANIC) + spawned(MANAGER), 1)
    end)

    it('storing needs the car at the garage (no remote store to take it out again)', function()
        local id = addFleetCar('FLEET1')
        fleet[id].out = 1
        Mock.fireNet('jobgarages:storeVehicle', MECHANIC, 'FLEET1  ', GARAGE)
        assert_eq(fleet[id].out, 1)
        -- the car is far away
        vehicles[500] = true; Mock.plates[500] = 'FLEET1  '; Mock.coords[500] = vector3(0, 0, 0)
        Mock.fireNet('jobgarages:storeVehicle', MECHANIC, 'FLEET1  ', GARAGE)
        assert_eq(fleet[id].out, 1)
        -- another job cannot store it either
        Mock.coords[500] = AT_TERMINAL
        Mock.fireNet('jobgarages:storeVehicle', OUTSIDER, 'FLEET1  ', GARAGE)
        assert_eq(fleet[id].out, 1)
    end)

    it('an employee stores the car next to them and the server removes it', function()
        local id = addFleetCar('FLEET1')
        fleet[id].out = 1
        vehicles[500] = true; Mock.plates[500] = 'FLEET1  '; Mock.coords[500] = AT_TERMINAL
        Mock.fireNet('jobgarages:storeVehicle', MECHANIC, 'FLEET1  ', GARAGE)
        assert_eq(fleet[id].out, 0)
        for _, fn in ipairs(timeouts) do fn() end
        assert_eq(vehicles[500], nil)
    end)
end)
