-- pf-ambulancejob (the ambulance job in use) with the server hardening: beds, armour, wound
-- treatment and revives are checked on the server (batch 16A: down state, revive tokens and
-- server-read armour; the client armour event is ignored).
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


describe('pf-ambulancejob hardening', function()
    it('a taken bed cannot be taken by someone else', function()
        Mock.coords[CIV] = Config.Locations['hospital'][1]['location']
        Mock.coords[MEDIC] = Config.Locations['hospital'][1]['location']
        Mock.players[MEDIC].PlayerData.job.onduty = false
        Mock.fireNet('hospital:server:SendToBed', CIV, 1, true, 1)
        Mock.fireNet('hospital:server:SendToBed', MEDIC, 1, true, 1)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 1)
        assert_eq(Mock.clientEventsNamed('hospital:client:SendToBed')[1].target, CIV)
    end)
    it('an unknown hospital or bed is refused without an error', function()
        Mock.fireNet('hospital:server:SendToBed', CIV, 999, true, 1)
        advance(3)
        Mock.fireNet('hospital:server:SendToBed', CIV, 1, true, 999)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 0)
    end)
    it('armour comes from the server ped, never from the client event', function()
        Mock.fireNet('hospital:server:SetArmor', MEDIC, 9999)
        assert_true(meta(MEDIC).armor ~= 100)
        Armour[MEDIC] = 250
        D.ArmourTick()
        assert_eq(meta(MEDIC).armor, 100)
    end)
    it('treating wounds needs an on-duty medic and a bandage', function()
        Mock.fireNet('hospital:server:TreatWounds', CIV, PATIENT)       -- not a medic
        Mock.fireNet('hospital:server:TreatWounds', MEDIC, PATIENT)     -- no bandage
        assert_eq(#Mock.clientEventsNamed('hospital:client:HealInjuries'), 0)
        Items[MEDIC] = { bandage = 1 }
        Mock.fireNet('hospital:server:TreatWounds', MEDIC, PATIENT)
        assert_eq(#Mock.clientEventsNamed('hospital:client:HealInjuries'), 1)
    end)
    it('an on-duty medic revives a down patient; an off-duty one is refused (not banned)', function()
        goDown()
        Items[MEDIC] = { firstaid = 2 }
        Mock.players[MEDIC].PlayerData.job.onduty = false
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        assert_eq(lastToken(PATIENT), nil)
        assert_eq(#Mock.dropped, 0)
        Mock.players[MEDIC].PlayerData.job.onduty = true
        advance(2)
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        applyRevive(PATIENT, lastToken(PATIENT))
        assert_eq(level(), 'alert')
    end)
end)
