-- Batch 15H platform hooks, pfm-doorlock: SetDoorState / GetDoorState change and read a door with no
-- player at all (the legacy server path needs an online player as sentSource), only for the resources
-- in Config.StateCallers; doors are named by their list key or by a coordinate alias (pf-justice
-- holding cells, Bolingbroke gates); corrections staff open the Bolingbroke gates and police keep
-- access; the legacy updateState server path (heists, prison break) works as before. Also the new
-- justice jobs in pfm-core shared/jobs.lua whose grade numbers pf-government and pf-justice read.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pfm-doorlock' end
local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
local printed = {}
print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, ' ')
end

Config = nil
load_resource('pfm-doorlock/config.lua')
Config.DoorStates = Config.DoorStates or {}
local realDoors = Config.DoorList
load_resource('pfm-doorlock/server/main.lua')
-- print stays captured: the refusal lines are asserted on

local SetDoorState = Mock.selfExport('SetDoorState')
local GetDoorState = Mock.selfExport('GetDoorState')
Mock.exportsByResource['pfm-doorlock'] = Mock.exportsByResource['__self']
local api = exports['pfm-doorlock']

local DOOR = vector3(10.0, 0.0, 0.0)

local function setStates() return Mock.clientEventsNamed('qb-doorlock:client:setState') end
local function as(resource, fn)
    Mock.invokingResource = resource
    local ok, a, b = pcall(fn)
    Mock.invokingResource = nil
    if not ok then error(a, 2) end
    return a, b
end
local function refusedLines(name)
    local n = 0
    for _, line in ipairs(printed) do if line:find(name .. ' refused', 1, true) then n = n + 1 end end
    return n
end

local function player(src, job, grade, at)
    local p = Mock.newPlayer(src)
    p.PlayerData.job = { name = job, grade = { level = grade or 0 } }
    p.PlayerData.gang = { name = 'none', grade = { level = 0 } }
    p.GetItemByName = function() return nil end
    Mock.coords[src] = at
    return p
end

local function testDoors()
    Config.DoorList = {
        ['mrpd-armory'] = { objCoords = DOOR, authorizedJobs = { police = 0 }, locked = true, distance = 2.0 },
        ['cell-1'] = { objCoords = vector3(50.0, 0.0, 0.0), locked = false, distance = 1.0, autoLock = 5000 },
        [7] = { objCoords = vector3(90.0, 0.0, 0.0), locked = true, distance = 1.0 },
    }
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.coords = {}
    Mock.invokingResource = nil
    timers, printed = {}, {}
    Config.DoorStates = {}
    Config.StateCallers = { ['pfm-prison'] = true, ['pf-justice'] = true }
    Config.StateReaders = '*'
    testDoors()
end

describe('SetDoorState (server-only, no player needed)', function()
    it('an allowlisted resource locks and unlocks a door with nobody online', function()
        assert_eq(next(Mock.players), nil)
        local res = as('pfm-prison', function() return api:SetDoorState('mrpd-armory', false, { reason = 'lockdown lifted' }) end)
        assert_true(res.ok)
        assert_eq(res.changed, true)
        assert_eq(res.doorId, 'mrpd-armory')
        assert_false(Config.DoorList['mrpd-armory'].locked)
        local sent = setStates()
        assert_eq(#sent, 1)
        assert_eq(sent[1].target, -1)
        assert_eq(sent[1].args[1], 0, 'no player: server id 0 animates nobody')
        assert_eq(sent[1].args[2], 'mrpd-armory')
        assert_eq(sent[1].args[3], false)
        assert_eq(sent[1].args[6], false, 'no animation')
        res = as('pf-justice', function() return api:SetDoorState('mrpd-armory', true) end)
        assert_true(res.ok)
        assert_true(Config.DoorList['mrpd-armory'].locked)
    end)

    it('refuses a resource that is not in Config.StateCallers, with one console line a minute', function()
        local res = as('pfm-houserobbery', function() return api:SetDoorState('mrpd-armory', false) end)
        assert_eq(res.ok, false)
        assert_eq(res.error, 'not_allowed')
        assert_true(Config.DoorList['mrpd-armory'].locked)
        assert_eq(#setStates(), 0)
        as('pfm-houserobbery', function() return api:SetDoorState('mrpd-armory', false) end)
        assert_eq(refusedLines('SetDoorState'), 1)
        Mock.gameTimer = Mock.gameTimer + 61000
        as('pfm-houserobbery', function() return api:SetDoorState('mrpd-armory', false) end)
        assert_eq(refusedLines('SetDoorState'), 2)
    end)

    it('the resource itself (no invoker) may set a state', function()
        local res = SetDoorState('mrpd-armory', false)
        assert_true(res.ok)
        assert_false(Config.DoorList['mrpd-armory'].locked)
    end)

    it('validates its arguments: locked must be a boolean, the door must exist', function()
        local res = as('pfm-prison', function() return api:SetDoorState('mrpd-armory', 'false') end)
        assert_eq(res.error, 'bad_args')
        res = as('pfm-prison', function() return api:SetDoorState('mrpd-armory', nil) end)
        assert_eq(res.error, 'bad_args')
        res = as('pfm-prison', function() return api:SetDoorState('nope', false) end)
        assert_eq(res.error, 'not_found')
        res = as('pfm-prison', function() return api:SetDoorState({ 'mrpd-armory' }, false) end)
        assert_eq(res.error, 'not_found')
        res = as('pfm-prison', function() return api:SetDoorState(0 / 0, false) end)
        assert_eq(res.error, 'not_found')
        res = as('pfm-prison', function() return api:SetDoorState(string.rep('a', 65), false) end)
        assert_eq(res.error, 'not_found')
        assert_true(Config.DoorList['mrpd-armory'].locked)
        assert_eq(#setStates(), 0)
    end)

    it('a numeric door id also works as a string (ids from JSON configs)', function()
        local res = as('pfm-prison', function() return api:SetDoorState('7', false) end)
        assert_true(res.ok)
        assert_eq(res.doorId, 7)
        assert_false(Config.DoorList[7].locked)
    end)

    it('a door already in that state is not broadcast again', function()
        local res = as('pfm-prison', function() return api:SetDoorState('mrpd-armory', true) end)
        assert_true(res.ok)
        assert_eq(res.changed, false)
        assert_eq(#setStates(), 0)
    end)

    it("an unlocked door with autoLock locks again by itself (the door's own timer)", function()
        Config.DoorList['cell-1'].locked = true
        local res = as('pf-justice', function() return api:SetDoorState('cell-1', false) end)
        assert_true(res.ok)
        assert_eq(#timers, 1)
        assert_eq(timers[1].ms, 5000)
        timers[1].fn()
        assert_true(Config.DoorList['cell-1'].locked)
    end)

    it('opts.sound = false sends the change without its sound', function()
        as('pfm-prison', function() return api:SetDoorState('mrpd-armory', false, { sound = false }) end)
        assert_eq(setStates()[1].args[5], false)
        as('pfm-prison', function() return api:SetDoorState('mrpd-armory', true) end)
        assert_eq(setStates()[2].args[5], true)
    end)
end)

describe('GetDoorState', function()
    it('returns true / false for a door, nil for an unknown one', function()
        assert_eq(as('pfm-prison', function() return api:GetDoorState('mrpd-armory') end), true)
        assert_eq(as('pf-anything', function() return api:GetDoorState('cell-1') end), false, "StateReaders = '*'")
        assert_eq(as('pfm-prison', function() return api:GetDoorState('nope') end), nil)
        assert_eq(GetDoorState(7), true)
    end)
    it('follows Config.StateReaders when it is a list', function()
        Config.StateReaders = { ['pfm-prison'] = true }
        assert_eq(as('pfm-prison', function() return api:GetDoorState('mrpd-armory') end), true)
        assert_eq(as('pf-other', function() return api:GetDoorState('mrpd-armory') end), nil)
        assert_eq(refusedLines('GetDoorState'), 1)
    end)
end)

describe('door aliases on the shipped config', function()
    it('name the doors by coordinates: Bolingbroke gates are the pfm-prison gatekeys, the cells are Mission Row cells 1-3', function()
        Config.DoorList = realDoors
        assert_eq(PFDoorlock.ResolveDoorId('bolingbroke_gate_1'), 13)
        assert_eq(PFDoorlock.ResolveDoorId('bolingbroke_gate_2'), 14)
        assert_eq(PFDoorlock.ResolveDoorId('bolingbroke_gate_3'), 15)
        assert_eq(PFDoorlock.ResolveDoorId('mrpd_cells_main'), 23)
        assert_eq(PFDoorlock.ResolveDoorId('mrpd_cell_1'), 24)
        assert_eq(PFDoorlock.ResolveDoorId('mrpd_cell_2'), 25)
        assert_eq(PFDoorlock.ResolveDoorId('mrpd_cell_3'), 26)
        for _, name in ipairs({ 'mrpd_cell_1', 'mrpd_cell_2', 'mrpd_cell_3' }) do
            assert_eq(realDoors[PFDoorlock.ResolveDoorId(name)].objName, 'v_ilev_ph_cellgate')
        end
        assert_eq(PFDoorlock.ResolveDoorId('no_such_alias'), nil)
        -- pfm-prison's gate keys (its Config.Gates) are these doors
        local doorConfig = Config
        Config = nil
        load_resource('pfm-prison/config.lua')
        local gates = Config.Gates
        Config = doorConfig
        assert_eq(gates[1].gatekey, 13)
        assert_eq(gates[2].gatekey, 14)
        assert_eq(gates[3].gatekey, 15)
    end)
    it('an alias keeps pointing at the same door when doors are added before it', function()
        Config.DoorList = {}
        for i, d in ipairs(realDoors) do Config.DoorList[i + 1] = d end
        Config.DoorList[1] = { objCoords = vector3(0.0, 0.0, 0.0), locked = true }
        assert_eq(PFDoorlock.ResolveDoorId('mrpd_cell_2'), 26)
        local res = as('pf-justice', function() return api:SetDoorState('mrpd_cell_2', false) end)
        assert_true(res.ok)
        assert_eq(res.doorId, 26)
        assert_false(Config.DoorList[26].locked)
        Config.DoorList[26].locked = true
        Config.DoorList = realDoors
    end)
end)

describe('Bolingbroke gate access (corrections) and the legacy server path', function()
    local GATE = 13
    BeforeEach = function()
        Mock.reset()
        Mock.players = {}
        Mock.coords = {}
        Mock.invokingResource = nil
        Config.DoorStates = {}
        Config.DoorList = realDoors
        for _, id in ipairs({ 13, 14, 15 }) do realDoors[id].locked = true end
    end

    it('every Bolingbroke gate lets corrections (grade 0 and up) and police through', function()
        for _, id in ipairs({ 13, 14, 15 }) do
            assert_eq(realDoors[id].objName, 'prop_gate_prison_01')
            assert_eq(realDoors[id].authorizedJobs.corrections, 0)
            assert_eq(realDoors[id].authorizedJobs.police, 0)
        end
    end)

    it('a corrections cadet at the gate opens it; a civilian there does not', function()
        local at = vector3(1844.9, 2604.8, 44.6)
        player(1, 'unemployed', 0, at)
        Mock.fireNet('qb-doorlock:server:updateState', 1, GATE, false, false, false, false)
        assert_true(realDoors[GATE].locked)
        player(2, 'corrections', 0, at)
        Mock.fireNet('qb-doorlock:server:updateState', 2, GATE, false, false, false, false)
        assert_false(realDoors[GATE].locked)
        player(3, 'police', 1, at)
        Mock.fireNet('qb-doorlock:server:updateState', 3, GATE, true, false, false, false)
        assert_true(realDoors[GATE].locked)
    end)

    it('the heist / prison-break server path (sentSource, unlockAnyway) still works as before', function()
        player(4, 'unemployed', 0, vector3(0.0, 0.0, 0.0))
        source = ''
        Mock.netHandlers['qb-doorlock:server:updateState'](GATE, false, false, false, true, false, false, 4)
        assert_false(realDoors[GATE].locked)
        Mock.netHandlers['qb-doorlock:server:updateState'](GATE, true, false, false, true, false, false, 4)
        source = nil
        assert_true(realDoors[GATE].locked)
    end)

    it('the new export relocks a gate the legacy path could not with nobody online', function()
        realDoors[GATE].locked = false
        source = ''
        Mock.netHandlers['qb-doorlock:server:updateState'](GATE, true, false, false, true, false, false, 99)
        source = nil
        assert_false(realDoors[GATE].locked, 'legacy path: no online player, nothing happens')
        local res = as('pfm-prison', function() return api:SetDoorState('bolingbroke_gate_1', true, { reason = 'alarm over' }) end)
        assert_true(res.ok)
        assert_true(realDoors[GATE].locked)
    end)
end)

describe('justice jobs in pfm-core shared/jobs.lua (decision D7)', function()
    local saved = QBCore
    QBCore = { Shared = {} }
    load_resource('pfm-core/shared/jobs.lua')
    local jobs = QBCore.Shared.Jobs
    QBCore = saved

    local function grades(job)
        local out = {}
        for k, g in pairs(jobs[job].grades) do out[tonumber(k)] = g end
        return out
    end

    it('corrections: type corrections, grades 0 Cadet .. 5 Warden (the boss)', function()
        assert_eq(jobs.corrections.type, 'corrections')
        local g = grades('corrections')
        assert_eq(#g, 5)
        assert_true(g[0] ~= nil)
        assert_eq(g[0].name, 'Cadet')
        assert_eq(g[5].name, 'Warden')
        assert_eq(g[5].isboss, true)
        for i = 0, 4 do assert_true(not g[i].isboss) end
    end)
    it('doj: type doj, 0 clerk, 1 prosecutor, 2 public defender, 3 probation officer, 4 chief', function()
        assert_eq(jobs.doj.type, 'doj')
        local g = grades('doj')
        assert_eq(g[0].name, 'Court Clerk')
        assert_eq(g[1].name, 'Prosecutor')
        assert_eq(g[2].name, 'Public Defender')
        assert_eq(g[3].name, 'Probation Officer')
        assert_eq(g[4].isboss, true)
        assert_eq(g[5], nil)
    end)
    it('judge: 0 magistrate, 1 judge, 2 chief judge; lawyer keeps grade 0 and gains partner grades', function()
        local j = grades('judge')
        assert_eq(j[0].name, 'Magistrate')
        assert_eq(j[1].name, 'Judge')
        assert_eq(j[2].name, 'Chief Judge')
        assert_eq(j[2].isboss, true)
        local l = grades('lawyer')
        assert_eq(l[0].name, 'Associate')
        assert_eq(l[0].payment, 50)
        assert_true(l[1].name:find('Partner') ~= nil)
        assert_eq(l[3].isboss, true)
    end)
    it('pay is set for every grade, conservatively (no grade above the police chief)', function()
        for _, job in ipairs({ 'corrections', 'doj', 'judge', 'lawyer' }) do
            for _, g in pairs(jobs[job].grades) do
                assert_true(type(g.payment) == 'number' and g.payment > 0 and g.payment <= 150, job .. ' ' .. g.name)
            end
        end
        assert_eq(jobs.police.grades['4'].payment, 150)
    end)
end)
