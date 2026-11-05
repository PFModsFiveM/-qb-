-- pf-ambulancejob batch 16A: the server owns the down / death state. A client report is accepted
-- only with the server-read ped down; the patient is held unconscious (no wake after 10 s), the last
-- stand ends in death, respawn waits for the timer, revives need a server token and a server-read
-- health check, movement while down is logged and re-synced, the state survives a relog and a
-- resource restart, admin revive/kill go through the exports with the ACE, and the honest flow
-- (die -> last stand -> EMS revive / first aid / respawn) works end to end.
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

describe('reports: the server decides who is down', function()
    it('a report with a healthy server ped is refused; a client cannot clear its own down state', function()
        Mock.fireNet('pf-ambulancejob:server:ReportDown', PATIENT, { nonce = 'x', kind = 'laststand' })
        Mock.fireNet('hospital:server:SetLaststandStatus', PATIENT, true)
        assert_eq(level(), 'alert')
        assert_true(meta(PATIENT).inlaststand ~= true)
        advance(3)
        goDown()
        assert_eq(level(), 'unconscious')
        assert_eq(meta(PATIENT).inlaststand, true)
        assert_eq(Bags[PATIENT]['pf:down'], 'unconscious')
        assert_eq(lastSetDown(PATIENT), 'unconscious', 'the client resurrects only after SetDown')
        advance(5)
        Mock.fireNet('hospital:server:SetDeathStatus', PATIENT, false)
        Mock.fireNet('hospital:server:SetLaststandStatus', PATIENT, false)
        assert_eq(level(), 'unconscious')
        assert_eq(meta(PATIENT).inlaststand, true)
        assert_eq(#events('pf-ambulancejob:server:patientDown'), 1)
    end)
    it('a reported down is held: the engine does not wake a healthy patient after 10 s', function()
        goDown()
        for _ = 1, 24 do advance(5); Engine.Tick(os.time()); D.Tick(os.time()) end
        assert_eq(level(), 'unconscious')
        assert_true(Store.Peek('PATIENTCID').ctx.holdUntil > os.time())
    end)
    it('the legacy SetDeathStatus(true) is a report too (checked the same way)', function()
        Health[PATIENT] = 0
        Mock.fireNet('hospital:server:SetDeathStatus', PATIENT, true)
        assert_eq(level(), 'unconscious')
    end)
    it('bleeding out on the server puts a player down without any client report', function()
        local inj = Engine.AddInjury('PATIENTCID', { mechanism = 'edged', type = 'laceration', subtype = 'arterial', structure = 'femoral_l', severity = 5 }, {})
        assert_true(inj ~= nil)
        for _ = 1, 120 do advance(5); Engine.Tick(os.time()) if level() ~= 'alert' and level() ~= 'altered' then break end end
        assert_true(level() == 'unconscious' or level() == 'arrest', 'down from the engine: ' .. level())
        assert_eq(meta(PATIENT).inlaststand, true)
        assert_true(Bags[PATIENT]['pf:down'] == 'unconscious' or Bags[PATIENT]['pf:down'] == 'arrest')
    end)
end)

describe('last stand, death and respawn', function()
    it('the last stand ends in death; respawn waits for the timer; one bill per death', function()
        goDown()
        advance(Config.Medical.Down.LaststandSeconds - 5); D.Tick(os.time())
        assert_eq(level(), 'unconscious')
        advance(6); D.Tick(os.time())
        assert_eq(level(), 'dead')
        assert_eq(meta(PATIENT).isdead, true)
        assert_eq(meta(PATIENT).inlaststand, false)
        assert_eq(#events('pf-ambulancejob:server:patientDied'), 1)
        Mock.fireNet('pf-ambulancejob:server:RequestRespawn', PATIENT)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 0, 'too soon')
        advance(Config.Medical.Consciousness.RespawnAfterSeconds + 1)
        Config.WipeInventoryOnRespawn = false
        Mock.fireNet('hospital:server:RespawnAtHospital', PATIENT, 1)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 1)
        assert_eq(Mock.players[PATIENT].PlayerData.money.bank, 5000 - Config.BillCost)
        assert_eq(#events('pf-ambulancejob:server:respawned'), 1)
        advance(6)
        Mock.fireNet('pf-ambulancejob:server:RequestRespawn', PATIENT)
        assert_eq(Mock.players[PATIENT].PlayerData.money.bank, 5000 - Config.BillCost, 'asked again: no second bill')
        assert_eq(#events('pf-ambulancejob:server:respawned'), 1)
        local token = lastToken(PATIENT, 'hospital:client:SendToBed')
        assert_true(type(token) == 'string')
        applyRevive(PATIENT, token)
        assert_eq(level(), 'alert')
        assert_eq(meta(PATIENT).isdead, false)
        assert_eq(lastSetDown(PATIENT), false)
    end)
    it('a living player cannot respawn (no free heal, no escape from cuffs)', function()
        Mock.fireNet('pf-ambulancejob:server:RequestRespawn', PATIENT)
        Mock.fireNet('hospital:server:RespawnAtHospital', PATIENT, 1)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 0)
        assert_eq(#events('pf-ambulancejob:server:respawned'), 0)
        assert_eq(Mock.players[PATIENT].PlayerData.money.bank, 5000)
    end)
end)

describe('revives need a server token and a server-read health check', function()
    it('EMS revive: 2.5 m, item consumed on the server, refused health keeps the patient down', function()
        goDown()
        Items[MEDIC] = { firstaid = 2 }
        Mock.coords[MEDIC] = vector3(110.0, 100.0, 30.0)
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        assert_eq(lastToken(PATIENT), nil, 'too far')
        Mock.coords[MEDIC] = vector3(101.5, 100.0, 30.0)
        advance(2)
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        local token = lastToken(PATIENT)
        assert_true(type(token) == 'string')
        assert_eq(Items[MEDIC].firstaid, 1)
        Health[PATIENT] = 0 -- the client did not come back up
        advance(2)
        Mock.fireNet('pf-ambulancejob:server:ReviveApplied', PATIENT, token)
        assert_eq(level(), 'unconscious', 'refused revive leaves the player down')
        Mock.fireNet('pf-ambulancejob:server:ReviveApplied', PATIENT, 'forged-token')
        assert_eq(level(), 'unconscious')
        applyRevive(PATIENT, token)
        assert_eq(level(), 'alert')
        assert_eq(meta(PATIENT).inlaststand, false)
        assert_eq(#events('pf-ambulancejob:server:patientRevived'), 1)
        assert_eq(closes('revived'), 1)
    end)
    it('an expired token does nothing; a medic cannot revive someone who is up', function()
        Items[MEDIC] = { firstaid = 2 }
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        assert_eq(lastToken(PATIENT), nil)
        goDown()
        advance(2)
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        local token = lastToken(PATIENT)
        advance(60); D.Tick(os.time())
        applyRevive(PATIENT, token)
        assert_eq(level(), 'unconscious')
    end)
    it('civilian first aid: only after the server started it, its full time, on an unconscious patient', function()
        goDown()
        Items[CIV] = { firstaid = 1 }
        Mock.fireNet('hospital:server:UseFirstAid', CIV, PATIENT)
        assert_eq(#Mock.clientEventsNamed('hospital:client:HelpPerson'), 0, 'not before the first-aid window')
        advance(Config.Medical.Down.FirstAidAfterSeconds + 1)
        Mock.fireNet('hospital:server:RevivePlayer', CIV, PATIENT)
        assert_eq(lastToken(PATIENT), nil, 'not started by the server')
        Mock.fireNet('hospital:server:UseFirstAid', CIV, PATIENT)
        local help = Mock.clientEventsNamed('hospital:client:HelpPerson')
        assert_eq(#help, 1)
        assert_eq(help[1].target, CIV)
        advance(2)
        Mock.fireNet('hospital:server:RevivePlayer', CIV, PATIENT)
        assert_eq(lastToken(PATIENT), nil, 'too fast')
        advance(math.floor(help[1].args[2] / 1000))
        Mock.fireNet('hospital:server:RevivePlayer', CIV, PATIENT)
        local token = lastToken(PATIENT)
        assert_true(type(token) == 'string')
        assert_eq(Items[CIV].firstaid, 0)
        applyRevive(PATIENT, token)
        assert_eq(level(), 'alert')
    end)
    it('no ban for a missing item; first aid never on a dead patient', function()
        goDown()
        advance(Config.Medical.Down.LaststandSeconds + 1); D.Tick(os.time())
        assert_eq(level(), 'dead')
        Items[CIV] = { firstaid = 1 }
        Mock.fireNet('hospital:server:UseFirstAid', CIV, PATIENT)
        Mock.fireNet('hospital:server:RevivePlayer', CIV, PATIENT, true)
        assert_eq(lastToken(PATIENT), nil)
        assert_eq(#Mock.dropped, 0)
        Items[MEDIC] = {}
        advance(2)
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        assert_eq(lastToken(PATIENT), nil, 'the medic has no kit: no revive')
        assert_eq(#Mock.dropped, 0, 'and nobody is banned')
    end)
end)

describe('movement while down', function()
    it('moving faster than an escort (not attached) is logged and re-sends SetDown', function()
        goDown()
        D.Tick(os.time())
        local before = #Mock.clientEventsNamed('pf-ambulancejob:client:SetDown')
        advance(1)
        Mock.coords[PATIENT] = vector3(120.0, 100.0, 30.0)
        D.Tick(os.time())
        assert_eq(#Mock.clientEventsNamed('pf-ambulancejob:client:SetDown'), before + 1)
        Store.Flush()
        local found = false
        for _, e in ipairs(DB.events) do if e.action == 'anomaly' and tostring(e.detail):find('moving_while_down') then found = true end end
        assert_true(found, 'anomaly row')
        -- carried (attached): no anomaly, no resend
        Attached[PATIENT] = 77
        local n = #Mock.clientEventsNamed('pf-ambulancejob:client:SetDown')
        advance(10)
        Mock.coords[PATIENT] = vector3(160.0, 100.0, 30.0)
        D.Tick(os.time())
        assert_eq(#Mock.clientEventsNamed('pf-ambulancejob:client:SetDown'), n)
    end)
end)

describe('relog and resource restart', function()
    it('relogging while down: still down, the offline time does not count toward the last stand', function()
        goDown()
        advance(100); Engine.Tick(os.time())
        Mock.fireEvent('QBCore:Server:OnPlayerUnload', nil, PATIENT)
        Mock.fireEvent('playerDropped', PATIENT)
        Mock.players[PATIENT] = nil
        advance(3600)
        online(PATIENT, 'PATIENTCID')
        assert_eq(level(), 'unconscious')
        assert_eq(meta(PATIENT).inlaststand, true)
        local _, info = lastSetDown(PATIENT)
        assert_true(info.laststandIn > 200, 'last stand left after relog: ' .. tostring(info.laststandIn))
        D.Tick(os.time())
        assert_eq(level(), 'unconscious')
    end)
    it('a resource restart while down restores the state from the records', function()
        goDown()
        advance(5); Engine.Tick(os.time())
        Store.Flush()
        meta(PATIENT).inlaststand = false -- whatever the metadata says, the record decides
        boot(true)
        assert_eq(Store.Peek('PATIENTCID').consciousness, 'unconscious')
        assert_eq(meta(PATIENT).inlaststand, true)
        assert_eq(lastSetDown(PATIENT), 'unconscious')
    end)
    it('without the patient records (database down) a death still works in memory', function()
        boot(false, true)
        online(PATIENT, 'PATIENTCID')
        Mock.coords[PATIENT] = vector3(100.0, 100.0, 30.0)
        goDown()
        assert_eq(meta(PATIENT).inlaststand, true)
        advance(Config.Medical.Down.LaststandSeconds + 1); D.Tick(os.time())
        assert_eq(meta(PATIENT).isdead, true)
        advance(Config.Medical.Consciousness.RespawnAfterSeconds + 1)
        Config.WipeInventoryOnRespawn = false
        Mock.fireNet('pf-ambulancejob:server:RequestRespawn', PATIENT)
        applyRevive(PATIENT, lastToken(PATIENT, 'hospital:client:SendToBed'))
        assert_eq(meta(PATIENT).isdead, false)
    end)
end)

describe('admin revive and kill through the exports', function()
    it('pfm-adminmenu kill and revive use the exports with the ACE and close the EMS call', function()
        Mock.aces[ADMIN] = { admin = true }
        online(ADMIN, 'ADMINCID')
        Mock.invokingResource = 'pfm-adminmenu'
        Mock.fireNet('qb-admin:server:kill', ADMIN, { id = PATIENT })
        Mock.invokingResource = nil
        assert_eq(level(), 'unconscious')
        assert_eq(#Requests, 1, 'EMS call opened')
        Mock.invokingResource = 'pfm-adminmenu'
        Mock.fireNet('qb-admin:server:revive', ADMIN, { id = PATIENT })
        Mock.invokingResource = nil
        applyRevive(PATIENT, lastToken(PATIENT))
        assert_eq(level(), 'alert')
        assert_eq(closes('admin_revive'), 1)
        assert_eq(#Mock.clientEventsNamed('hospital:client:Revive'), 0, 'no client-side revive any more')
        assert_eq(#Mock.clientEventsNamed('hospital:client:KillPlayer'), 0)
    end)
    it('the exports refuse a caller off the list and a "by" without the ACE', function()
        online(ADMIN, 'ADMINCID')
        Mock.invokingResource = 'some-resource'
        local r = exports['pf-ambulancejob']:Kill(PATIENT, {})
        assert_eq(r.error, 'not_allowed')
        Mock.invokingResource = 'pfm-adminmenu'
        r = exports['pf-ambulancejob']:Kill(PATIENT, { by = ADMIN })
        Mock.invokingResource = nil
        assert_eq(r.error, 'no_permission')
        assert_eq(level(), 'alert')
    end)
    it('an admin revive heals the record (bleeding injuries recovered, blood normal)', function()
        Engine.AddInjury('PATIENTCID', { mechanism = 'edged', type = 'laceration', subtype = 'arterial', structure = 'femoral_l', severity = 4 }, {})
        for _ = 1, 30 do advance(5); Engine.Tick(os.time()) end
        local p = Store.Peek('PATIENTCID')
        assert_true(p.blood_ml < 5000)
        Mock.aces[ADMIN] = { admin = true }
        online(ADMIN, 'ADMINCID')
        Mock.invokingResource = 'pfm-adminmenu'
        local r = exports['pf-ambulancejob']:Revive(PATIENT, { by = ADMIN })
        Mock.invokingResource = nil
        assert_true(r.ok)
        applyRevive(PATIENT, lastToken(PATIENT))
        assert_eq(p.blood_ml, 5000)
        assert_eq(Engine.Bleeding(p, os.time()).total, 0)
        assert_eq(level(), 'alert')
    end)
end)
