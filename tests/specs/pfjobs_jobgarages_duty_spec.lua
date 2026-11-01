-- pf-jobgarages: taking a fleet car out needs the garage's job on duty (Config.RequireOnDuty, per
-- garage override), fleet management follows the saved "minimum grade to manage" (bosses always
-- manage, nobody can lock themselves out), and a deleted character's assignments and cars out are
-- cleared.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')

local vehicles = {}
function GetAllVehicles() local out = {} for e in pairs(vehicles) do out[#out + 1] = e end return out end
function DoesEntityExist(e) return vehicles[e] ~= nil or Mock.players[e] ~= nil end
function DeleteEntity(e) vehicles[e] = nil end
function SetTimeout(_, fn) fn() end

local owned, fleet, perms, nextId = {}, {}, {}, 1
FakeDB.extraPatterns = {
    { 'FROM player_vehicles WHERE plate = ? AND (citizenid = ? OR license = ?)', function(p)
        local v = owned[p[1]]
        if v and v.citizenid == p[2] then return { plate = p[1], vehicle = v.vehicle, state = 1, depotprice = 0 } end
    end },
    { 'SELECT mods, engine, body FROM player_vehicles', function() return nil end },
    { 'SELECT id FROM job_garage_vehicles WHERE plate = ? AND active = 1', function(p)
        for id, r in pairs(fleet) do if r.plate == p[1] and r.active == 1 then return id end end
    end },
    { 'SELECT min_grade_use FROM job_garage_permissions', function(p) return perms[p[1]] end },
    { 'SELECT min_grade_manage FROM job_garage_permissions', function(p) return perms[p[1]] end },
    { 'SELECT min_grade_use, min_grade_manage FROM job_garage_permissions', function(p) return perms[p[1]] end },
    { 'SELECT id FROM job_garage_permissions', function(p) return perms[p[1]] and { id = 1 } or nil end },
    { 'UPDATE job_garage_permissions', function(p) perms[p[3]] = { min_grade_use = p[1], min_grade_manage = p[2] } return 1 end },
    { 'INSERT INTO job_garage_permissions', function(p) perms[p[1]] = { min_grade_use = p[2], min_grade_manage = p[3] } return 1 end },
    { "AND TABLE_NAME = 'occasion_vehicles'", function() return 0 end },
    -- the add is one INSERT ... SELECT: the car only joins while it is still the manager's, parked,
    -- not impounded and in no active fleet (params: garage, label, grade, plate, cid, license, plate)
    { 'INSERT INTO job_garage_vehicles', function(p)
        local v = owned[p[4]]
        if not v or (v.citizenid ~= p[5]) or (v.state or 1) ~= 1 or (v.depotprice or 0) > 0 then return 0 end
        for _, r in pairs(fleet) do if r.plate == p[7] and r.active == 1 then return 0 end end
        local id = nextId; nextId = nextId + 1
        fleet[id] = { id = id, garage_id = p[1], plate = p[4], model = v.vehicle, min_grade = p[3], active = 1, out = 0, assignment_type = 'none' }
        return 1
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
    { 'SELECT id, plate FROM job_garage_vehicles WHERE out_citizenid = ?', function(p)
        local out = {}
        for id, r in pairs(fleet) do if r.out == 1 and r.out_citizenid == p[1] then out[#out + 1] = { id = id, plate = r.plate } end end
        return out
    end },
    { 'SELECT id, plate, model FROM job_garage_vehicles WHERE plate = ?', function(p)
        for _, r in pairs(fleet) do if r.plate == p[1] and r.garage_id == p[2] and r.active == 1 then return r end end
    end },
    { 'SET `out` = 0', function(p) local r = fleet[p[1]]; if r then r.out, r.out_citizenid = 0, nil end; return 1 end },
    { "SET assignment_type = 'none', assigned_citizenid = NULL, assigned_name = NULL, assigned_grade = NULL WHERE assignment_type = 'citizenid'", function(p)
        local n = 0
        for _, r in pairs(fleet) do
            if r.assignment_type == 'citizenid' and r.assigned_citizenid == p[1] then r.assignment_type, r.assigned_citizenid = 'none', nil; n = n + 1 end
        end
        return n
    end },
    { 'UPDATE job_garage_vehicles SET active = 0', function(p) local r = fleet[tonumber(p[1])]; if r then r.active = 0 end; return 1 end },
    { 'INSERT INTO job_garage_logs', function() return 1 end },
    { 'FROM job_garage_vehicles', function() return {} end },
    { 'FROM job_garage_logs', function() return {} end },
}

Config = nil
load_resource('[pfscripts]/pf-jobgarages/config.lua')
load_resource('[pfscripts]/pf-jobgarages/server/main.lua')

local GARAGE = 'mechanic_main'
local cfg = Config.JobGarages[GARAGE]
local AT = vector3(cfg.targetCoords.x, cfg.targetCoords.y, cfg.targetCoords.z)
local BOSS, MECH, SENIOR = 1, 2, 3

local function setJob(src, grade, onduty, isboss)
    Mock.players[src].PlayerData.job = { name = 'mechanic', grade = { level = grade }, onduty = onduty, isboss = isboss == true }
end
local function addCar(plate, extra)
    local id = nextId; nextId = nextId + 1
    fleet[id] = { id = id, garage_id = GARAGE, plate = plate, model = 'flatbed', min_grade = 0, active = 1, out = 0, assignment_type = 'none' }
    for k, v in pairs(extra or {}) do fleet[id][k] = v end
    return id
end
local function take(src, id) return Mock.callCallback('jobgarages:takeVehicle', src, GARAGE, id) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    vehicles, owned, fleet, perms = {}, {}, {}, {}
    Config.RequireOnDuty = true
    cfg.requireOnDuty = nil
    Mock.newPlayer(BOSS, 'CIDB'); setJob(BOSS, 0, true, true)
    Mock.newPlayer(MECH, 'CIDM'); setJob(MECH, 0, false)
    Mock.newPlayer(SENIOR, 'CIDS'); setJob(SENIOR, 3, true)
    for src = 1, 3 do Mock.coords[src] = AT end
end

describe('fleet cars need the job on duty', function()
    it('an off-duty mechanic cannot take a car out; on duty they can', function()
        local id = addCar('FLEET1')
        local ok, msg = take(MECH, id)
        assert_eq(ok, false)
        assert_true(type(msg) == 'string' and msg:find('Clock in') ~= nil, 'told to clock in')
        assert_eq(fleet[id].out, 0)
        Mock.players[MECH].PlayerData.job.onduty = true
        assert_eq((take(MECH, id)), true)
        assert_eq(fleet[id].out, 1)
    end)

    it('the rule can be switched off for the server or a garage', function()
        local id = addCar('FLEET2')
        Config.RequireOnDuty = false
        assert_eq((take(MECH, id)), true)
        local id2 = addCar('FLEET3')
        Config.RequireOnDuty = true
        cfg.requireOnDuty = false
        assert_eq((take(MECH, id2)), true)
    end)

    it('a car can be stored back off duty', function()
        local id = addCar('FLEET4', { out = 1 })
        vehicles[500] = true; Mock.plates[500] = 'FLEET4  '; Mock.coords[500] = AT
        Mock.fireNet('jobgarages:storeVehicle', MECH, 'FLEET4', GARAGE)
        assert_eq(fleet[id].out, 0)
    end)
end)

describe('fleet management follows the saved manage grade', function()
    it('the default manage grade applies until a garage saves its own', function()
        owned['MINE1'] = { citizenid = 'CIDS', vehicle = 'flatbed' }
        Mock.fireNet('jobgarages:addFleetVehicle', SENIOR, GARAGE, { plate = 'MINE1' })
        assert_eq(next(fleet), nil, 'grade 3 is below the default 4')
        assert_false(Mock.callCallback('jobgarages:getGarageData', SENIOR, GARAGE).isManager)
        perms[GARAGE] = { min_grade_use = 0, min_grade_manage = 3 }
        assert_true(Mock.callCallback('jobgarages:getGarageData', SENIOR, GARAGE).isManager)
        Mock.fireNet('jobgarages:addFleetVehicle', SENIOR, GARAGE, { plate = 'MINE1' })
        local id = next(fleet)
        assert_true(id ~= nil, 'grade 3 manages once the garage says so')
        Mock.fireNet('jobgarages:removeFleetVehicle', MECH, GARAGE, id)
        assert_eq(fleet[id].active, 1, 'a grade 0 mechanic does not')
        Mock.fireNet('jobgarages:removeFleetVehicle', SENIOR, GARAGE, id)
        assert_eq(fleet[id].active, 0)
    end)

    it('bosses always manage, and nobody saves a manage grade above their own', function()
        assert_true(Mock.callCallback('jobgarages:getGarageData', BOSS, GARAGE).isManager)
        perms[GARAGE] = { min_grade_use = 0, min_grade_manage = 3 }
        Mock.fireNet('jobgarages:savePermissions', SENIOR, GARAGE, { min_grade_use = 1, min_grade_manage = 5 })
        assert_eq(perms[GARAGE].min_grade_manage, 3, 'grade 3 cannot lock grade 3 out')
        Mock.fireNet('jobgarages:savePermissions', SENIOR, GARAGE, { min_grade_use = 1, min_grade_manage = 2 })
        assert_eq(perms[GARAGE].min_grade_manage, 2)
        assert_eq(perms[GARAGE].min_grade_use, 1)
        Mock.fireNet('jobgarages:savePermissions', BOSS, GARAGE, { min_grade_use = 0, min_grade_manage = 6 })
        assert_eq(perms[GARAGE].min_grade_manage, 6, 'a boss may')
        assert_false(Mock.callCallback('jobgarages:getGarageData', SENIOR, GARAGE).isManager)
        assert_true(Mock.callCallback('jobgarages:getGarageData', BOSS, GARAGE).isManager)
    end)
end)

describe('a deleted character', function()
    it('loses its assignments, and its cars out come back', function()
        local a = addCar('ASSIGN1', { assignment_type = 'citizenid', assigned_citizenid = 'CIDM' })
        local b = addCar('OUTCAR1', { out = 1, out_citizenid = 'CIDM' })
        local c = addCar('OTHER1', { out = 1, out_citizenid = 'CIDS' })
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, { 'CIDM' })
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, "CIDM'; DROP TABLE x")
        assert_eq(fleet[a].assignment_type, 'citizenid', 'bad citizen ids are ignored')
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'CIDM')
        assert_eq(fleet[a].assignment_type, 'none')
        assert_eq(fleet[b].out, 0)
        assert_eq(fleet[c].out, 1)
        local despawn = Mock.clientEventsNamed('jobgarages:forceDespawn')
        assert_eq(#despawn, 1)
        assert_eq(despawn[1].args[1], 'OUTCAR1')
    end)
end)
