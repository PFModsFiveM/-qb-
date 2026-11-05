-- pf-ambulancejob batch 16A: the legacy client-trusted events are closed or become checked
-- forwarders (architecture 9): free food/water, client armour and doctor counts are gone, the
-- status callback and the EMS stash are gated by job, duty and server distance, hospital beds need
-- the reception point (and no doctors on duty for an AI check-in), alerts come only from a player
-- the server has down, the CanHelp answer is ignored and txAdmin's heal is a server revive.
load_resource('tests/lua/ledger_env.lua')
function IsDuplicityVersion() return true end

-- FiveM runs every handler of an event; the mock keeps one per name, so this spec chains them
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
-- replicated state bags with :set, as on a server
Bags = {}
function Player(src)
    Bags[src] = Bags[src] or {}
    local b = Bags[src]
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end
Health, Armour, Attached = {}, {}, {}
function GetEntityHealth(ped) return Health[ped] or 200 end
function GetPedArmour(ped) return Armour[ped] or 0 end
function GetEntityAttachedTo(ped) return Attached[ped] or 0 end
Items = {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, src, item, n)
        local have = (Items[src] or {})[item] or 0
        if have < (n or 1) then return false end
        Items[src][item] = have - (n or 1)
        return true
    end,
    AddItem = function() return true end,
}
QBCoreMock.Functions.HasItem = function(src, item) return ((Items[src] or {})[item] or 0) > 0 end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.HasPermission = function(src, perm) return Mock.aces[src] ~= nil and Mock.aces[src][perm] == true end
QBCoreMock.Functions.IsOptin = function() return true end
QBCoreMock.Functions.GetIdentifier = function(src, kind) return kind .. ':' .. tostring(src) end
function GetPlayers() local out = {} for s in pairs(Mock.players) do out[#out + 1] = tostring(s) end return out end
function SetEntityCoords() end
Requests, Closes = {}, {}
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function(_, opts)
        Requests[#Requests + 1] = opts
        return { ok = true, id = #Requests }
    end,
    CloseByRef = function(_, t, id, status, reason) Closes[#Closes + 1] = { type = t, id = id, status = status, reason = reason } return { ok = true } end,
    Emit = function() return 1 end,
}
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

-- in-memory SQL for the medical store (its statements run in the batch-15 real-DB spec)
DB = { patients = {}, injuries = {}, events = {}, nextId = 0 }
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end
local function installFakeSQL()
    local Q = PFMed.SQL
    Q.LoadPatient = function(cid) return copy(DB.patients[cid]) end
    Q.LoadOpenInjuries = function(cid)
        local out = {}
        for _, r in pairs(DB.injuries) do if r.citizenid == cid and r.stage ~= 'recovered' then out[#out + 1] = copy(r) end end
        return out
    end
    Q.FindInjuryByKey = function(key) for _, r in pairs(DB.injuries) do if r.idem_key == key then return { id = r.id, citizenid = r.citizenid, attrs = r.attrs } end end end
    Q.InsertInjury = function(r) DB.nextId = DB.nextId + 1; local row = copy(r); row.id = DB.nextId; DB.injuries[row.id] = row; return row.id end
    Q.UpsertPatients = function(rows) for _, r in ipairs(rows) do DB.patients[r.citizenid] = copy(r) end return true end
    Q.UpsertInjuries = function(rows) for _, r in ipairs(rows) do local o = DB.injuries[r.id] or {}; for k, v in pairs(r) do o[k] = v end; DB.injuries[r.id] = o end return true end
    Q.InsertEvents = function(rows) for _, e in ipairs(rows) do DB.events[#DB.events + 1] = copy(e) end return true end
    Q.Sweep = function() return {} end
end

local AJ = '[pfscripts]/pf-ambulancejob/'
local FILES = { AJ .. 'config.lua', AJ .. 'config_medical.lua', AJ .. 'shared/framework.lua' }
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model' }) do FILES[#FILES + 1] = AJ .. 'shared/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/main.lua'
for _, f in ipairs({ 'schema', 'store', 'engine', 'downstate', 'effects', 'api' }) do FILES[#FILES + 1] = AJ .. 'server/medical/' .. f .. '.lua' end

local D, Store, Engine
--- Loads the resource (and pfm-adminmenu) from scratch; `keepDB` keeps the patient rows (restart).
local function boot(keepDB, schemaDown)
    Mock.eventHandlers, Mock.netHandlers, Mock.netHandlerList, Mock.callbacks = {}, {}, {}, {}
    PFMed, PFEmsRequests = nil, nil
    if not keepDB then DB = { patients = {}, injuries = {}, events = {}, nextId = 0 } end
    LedgerEnv.load('pf-ambulancejob', FILES)
    installFakeSQL()
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    D, Store, Engine = PFMed.Down, PFMed.Store, PFMed.Engine
    QBCore = QBCoreMock
    load_resource('pfm-adminmenu/server/server.lua')
    if not schemaDown then assert(PFMed.Schema.Start(), 'schema ready') end
end

local PATIENT, MEDIC, CIV, ADMIN = 1, 2, 3, 4
local function online(src, cid)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = 5000 }
    p.PlayerData.metadata.injail = 0
    p.ClearInventory = function() p.cleared = true end
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function meta(src) return Mock.players[src].PlayerData.metadata end
local function lastSetDown(src)
    local list = Mock.clientEventsNamed('pf-ambulancejob:client:SetDown')
    for i = #list, 1, -1 do if list[i].target == src then return list[i].args[1], list[i].args[2] end end
    return nil
end
local function lastToken(src, name)
    local list = Mock.clientEventsNamed(name or 'pf-ambulancejob:client:Revive')
    for i = #list, 1, -1 do
        if list[i].target == src then return name and list[i].args[4] or list[i].args[1] end
    end
end
local function events(name)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do if e.name == name then out[#out + 1] = e end end
    return out
end
local function level(cid) return Store.Peek(cid or 'PATIENTCID').consciousness end
local function advance(s) Mock.clock = Mock.clock + s end
local function goDown()
    Health[PATIENT] = 0
    Mock.fireNet('pf-ambulancejob:server:ReportDown', PATIENT, { nonce = 'n1', kind = 'laststand' })
    Health[PATIENT] = 150 -- the client resurrected into the last-stand pose
end
local function applyRevive(src, token)
    Health[src] = 200
    advance(2)
    Mock.fireNet('pf-ambulancejob:server:ReviveApplied', src, token)
end
local function closes(reason)
    local n = 0
    for _, c in ipairs(Closes) do if c.type == 'patient' and c.reason == reason then n = n + 1 end end
    return n
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords, Mock.aces, Mock.dropped = {}, {}, {}, {}
    Mock.invokingResource = nil
    Health, Armour, Attached, Items, Bags, Requests, Closes = {}, {}, {}, {}, {}, {}, {}
    FakeDB.society('ambulance', 0)
    boot(false)
    Engine.Random = function() return 0.5 end
    online(PATIENT, 'PATIENTCID')
    online(MEDIC, 'MEDICCID').PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true }
    online(CIV, 'CIVCID')
    Mock.coords[PATIENT] = vector3(100.0, 100.0, 30.0)
    Mock.coords[MEDIC] = vector3(101.0, 100.0, 30.0)
    Mock.coords[CIV] = vector3(100.0, 101.0, 30.0)
end


describe('closed legacy events', function()
    it('resetHungerThirst does nothing (free food and water)', function()
        meta(CIV).hunger, meta(CIV).thirst = 10, 10
        Mock.fireNet('hospital:server:resetHungerThirst', CIV)
        assert_eq(meta(CIV).hunger, 10)
        assert_eq(meta(CIV).thirst, 10)
    end)
    it('the client SetArmor is ignored; armour is saved from the server ped', function()
        Mock.fireNet('hospital:server:SetArmor', MEDIC, 100)
        assert_true(meta(MEDIC).armor ~= 100)
        Armour[CIV] = 37
        D.ArmourTick()
        assert_eq(meta(CIV).armor, 37)
        assert_eq(meta(MEDIC).armor, 0)
    end)
    it('AddDoctor/RemoveDoctor do not change the doctor count; duty does', function()
        Mock.fireNet('hospital:server:AddDoctor', CIV, 'ambulance')
        Mock.fireNet('hospital:server:AddDoctor', MEDIC, 'ambulance')
        assert_eq(exports['pf-ambulancejob']:GetDoctorCount(), 0)
        Mock.fireEvent('QBCore:Server:SetDuty', nil, MEDIC, true)
        assert_eq(exports['pf-ambulancejob']:GetDoctorCount(), 1)
        Mock.fireNet('hospital:server:RemoveDoctor', MEDIC, 'ambulance')
        assert_eq(exports['pf-ambulancejob']:GetDoctorCount(), 1)
    end)
    it('the CanHelp answer is ignored (it could aim a revive progress bar at anyone)', function()
        Mock.fireNet('hospital:server:CanHelp', PATIENT, CIV, true)
        assert_eq(#Mock.clientEventsNamed('hospital:client:HelpPerson'), 0)
    end)
end)

describe('gated legacy callbacks and events', function()
    it('GetPlayerStatus: only an on-duty medic within 5 m reads a patient (engine injuries, legacy shape)', function()
        Engine.AddInjury('PATIENTCID', { mechanism = 'blunt', type = 'fracture', structure = 'femur_l', severity = 3 }, {})
        local r = Mock.callCallback('hospital:GetPlayerStatus', CIV, PATIENT)
        assert_eq(r.LLEG, nil, 'a civilian sees nothing')
        Mock.coords[MEDIC] = vector3(110.0, 100.0, 30.0)
        r = Mock.callCallback('hospital:GetPlayerStatus', MEDIC, PATIENT)
        assert_eq(r.LLEG, nil, 'too far')
        Mock.coords[MEDIC] = vector3(102.0, 100.0, 30.0)
        r = Mock.callCallback('hospital:GetPlayerStatus', MEDIC, PATIENT)
        assert_true(r.LLEG ~= nil and r.LLEG.severity == 3)
        Mock.players[MEDIC].PlayerData.job.onduty = false
        r = Mock.callCallback('hospital:GetPlayerStatus', MEDIC, PATIENT)
        assert_eq(r.LLEG, nil, 'off duty')
    end)
    it('the EMS stash needs the job, duty and the stash point', function()
        local opened = 0
        Mock.exportsByResource['pfm-inventory'].OpenInventory = function() opened = opened + 1 end
        Mock.fireNet('qb-ambulancejob:server:stash', CIV)
        Mock.fireNet('qb-ambulancejob:server:stash', MEDIC)
        assert_eq(opened, 0)
        Mock.coords[MEDIC] = Config.Locations['stash'][1]
        Mock.fireNet('qb-ambulancejob:server:stash', MEDIC)
        assert_eq(opened, 1)
    end)
    it('SendToBed: check-in only at the reception, without doctors on duty, and not while down', function()
        Mock.fireNet('hospital:server:SendToBed', CIV, 1, true, 1)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 0, 'away from the desk')
        Mock.coords[CIV] = Config.Locations['hospital'][1]['location']
        Mock.players[MEDIC].PlayerData.job.onduty = true
        Config.MinimalDoctors = 1
        advance(3)
        Mock.fireNet('hospital:server:SendToBed', CIV, 1, true, 1)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 0, 'doctors are on duty')
        Config.MinimalDoctors = 2
        advance(3)
        Mock.fireNet('hospital:server:SendToBed', CIV, 1, true, 1)
        local beds = Mock.clientEventsNamed('hospital:client:SendToBed')
        assert_eq(#beds, 1)
        assert_eq(Mock.players[CIV].PlayerData.money.bank, 5000 - Config.BillCost)
        local token = beds[1].args[4]
        applyRevive(CIV, token)
        assert_eq(#events('pf-ambulancejob:server:patientRevived'), 1)
        -- a down player cannot check in (nor be placed in a bed to be healed)
        Mock.coords[PATIENT] = Config.Locations['hospital'][1]['location']
        goDown()
        advance(3)
        Mock.fireNet('hospital:server:SendToBed', PATIENT, 2, true, 1)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 1)
    end)
    it('lying in a bed needs the player at the bed', function()
        Mock.fireNet('hospital:server:SendToBed', CIV, 2, false, 1)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 0)
        local b = Config.Locations['hospital'][1]['beds'][2].coords
        Mock.coords[CIV] = vector3(b.x, b.y, b.z)
        advance(3)
        Mock.fireNet('hospital:server:SendToBed', CIV, 2, false, 1)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 1)
    end)
    it('ambulanceAlert: only from a player the server has down, with the server text and position', function()
        Mock.fireNet('hospital:server:ambulanceAlert', CIV, 'FAKE ROBBERY AT THE BANK')
        assert_eq(#Mock.clientEventsNamed('hospital:client:ambulanceAlert'), 0)
        goDown()
        local auto = #Mock.clientEventsNamed('hospital:client:ambulanceAlert')
        assert_true(auto >= 1, 'going down alerts on-duty EMS by itself')
        Mock.fireNet('hospital:server:ambulanceAlert', PATIENT, 'FAKE TEXT')
        local list = Mock.clientEventsNamed('hospital:client:ambulanceAlert')
        assert_eq(#list, auto + 1)
        assert_true(list[#list].args[2] ~= 'FAKE TEXT')
        assert_eq(list[#list].target, MEDIC)
        Mock.fireNet('hospital:server:ambulanceAlert', PATIENT, 'again')
        assert_eq(#Mock.clientEventsNamed('hospital:client:ambulanceAlert'), auto + 1, 'rate limited')
    end)
    it('txAdmin heal is a server revive (token), not a client-side revive', function()
        goDown()
        Mock.invokingResource = 'monitor'
        Mock.fireEvent('txAdmin:events:healedPlayer', nil, { id = PATIENT })
        Mock.invokingResource = nil
        assert_eq(#Mock.clientEventsNamed('hospital:client:Revive'), 0)
        applyRevive(PATIENT, lastToken(PATIENT))
        assert_eq(level(), 'alert')
    end)
    it('the legacy GetPlayerBleeding returns only the caller\'s own level', function()
        assert_eq(Mock.callCallback('hospital:GetPlayerBleeding', PATIENT), 0)
    end)
end)
