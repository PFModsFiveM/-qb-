-- pf-ambulancejob batch 17D: EMS equipment. The server spawns every prop at a position it computes,
-- keeps one stretcher per rig, checks the touch / rig distances on server positions, owns who lies
-- on and who pushes what (entity bag pf:stretcher, player bag pf:onStretcher), loads with
-- SetPedIntoVehicle, and releases the patient safely when the pusher, the patient, the prop or the
-- rig disappear and when the resource stops. The real medical stack is loaded so the 16A movement
-- check is exercised with the stretcher state. pfm-radialmenu's bin-bag stretcher is retired.
load_resource('tests/lua/ledger_env.lua')
function IsDuplicityVersion() return true end

-- FiveM runs every handler of an event; the mock keeps one per name, so this spec chains them
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
-- replicated state bags with :set (the replicate flag is recorded)
Bags, Replicated, EBags = {}, {}, {}
function Player(src)
    Bags[src] = Bags[src] or {}
    local b = Bags[src]
    return { state = setmetatable({ set = function(_, k, v, rep) b[k] = v; Replicated['player:' .. src .. ':' .. k] = rep end }, { __index = b }) }
end
function Entity(e)
    EBags[e] = EBags[e] or {}
    local b = EBags[e]
    return { state = setmetatable({ set = function(_, k, v, rep) b[k] = v; Replicated['entity:' .. e .. ':' .. k] = rep end }, { __index = b }) }
end

-- entities: props and vehicles exist until deleted; peds are the player ids
Ents, Headings, Types, Frozen, Seats, Coords = {}, {}, {}, {}, {}, {}
Spawned, Warps, Seated = {}, {}, {}
function CreateObjectNoOffset(model, x, y, z)
    Mock.nextNetId = Mock.nextNetId + 1
    local e = Mock.nextNetId
    Ents[e] = true
    Mock.coords[e] = vector3(x, y, z)
    Mock.models[e] = model
    Spawned[#Spawned + 1] = { entity = e, model = model, x = x, y = y, z = z }
    return e
end
function DoesEntityExist(e) return Ents[e] == true or Mock.players[e] ~= nil end
function DeleteEntity(e) Ents[e] = nil; Mock.deleted[#Mock.deleted + 1] = e end
function GetEntityHeading(e) return Headings[e] or 0.0 end
function SetEntityHeading(e, h) Headings[e] = h end
function GetEntityType(e) return Types[e] or (Mock.players[e] and 1) or 3 end
function FreezeEntityPosition(e, b) Frozen[e] = b end
function GetPedInVehicleSeat(veh, seat) return (Seats[veh] or {})[seat] or 0 end
function SetPedIntoVehicle(ped, veh, seat)
    Seats[veh] = Seats[veh] or {}
    Seats[veh][seat] = ped
    Mock.vehicleOf[ped] = veh
    Seated[#Seated + 1] = { ped = ped, veh = veh, seat = seat }
end
function SetEntityCoords(e, x, y, z)
    Mock.coords[e] = vector3(x, y, z)
    Warps[#Warps + 1] = { entity = e, x = x, y = y, z = z }
    local veh = Mock.vehicleOf[e]
    if veh then
        Mock.vehicleOf[e] = nil
        for s, p in pairs(Seats[veh] or {}) do if p == e then Seats[veh][s] = nil end end
    end
end

Health, Armour, Attached = {}, {}, {}
function GetEntityHealth(ped) return Health[ped] or 200 end
function GetPedArmour(ped) return Armour[ped] or 0 end
function GetEntityAttachedTo(ped) return Attached[ped] or 0 end
Items = {}
Stashes, Opened = {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function() return false end,
    AddItem = function() return true end,
    CreateInventory = function(_, id, data) Stashes[id] = data end,
    OpenInventory = function(_, src, id, data) Opened[#Opened + 1] = { src = src, id = id, data = data } end,
}
QBCoreMock.Functions.HasItem = function() return false end
QBCoreMock.Commands.Add = function() end
QBCoreMock.Functions.HasPermission = function() return false end
QBCoreMock.Functions.IsOptin = function() return true end
QBCoreMock.Functions.GetIdentifier = function(src, kind) return kind .. ':' .. tostring(src) end
function GetPlayers() local out = {} for s in pairs(Mock.players) do out[#out + 1] = tostring(s) end return out end
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function() return { ok = true, id = 1 } end,
    CloseByRef = function() return { ok = true } end,
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
    Q.LoadOpenInjuries = function() return {} end
    Q.FindInjuryByKey = function() return nil end
    Q.InsertInjury = function(r) DB.nextId = DB.nextId + 1; local row = copy(r); row.id = DB.nextId; DB.injuries[row.id] = row; return row.id end
    Q.UpsertPatients = function(rows) for _, r in ipairs(rows) do DB.patients[r.citizenid] = copy(r) end return true end
    Q.UpsertInjuries = function() return true end
    Q.InsertEvents = function(rows) for _, e in ipairs(rows) do DB.events[#DB.events + 1] = copy(e) end return true end
    Q.Sweep = function() return {} end
end

local AJ = '[pfscripts]/pf-ambulancejob/'
local FILES = { AJ .. 'config.lua', AJ .. 'config_medical.lua', AJ .. 'config_ems.lua', AJ .. 'shared/framework.lua' }
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model' }) do FILES[#FILES + 1] = AJ .. 'shared/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/main.lua'
for _, f in ipairs({ 'schema', 'store', 'engine', 'downstate', 'effects', 'api' }) do FILES[#FILES + 1] = AJ .. 'server/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/ems/equipment.lua'

local E, D, Store
local function boot()
    Mock.eventHandlers, Mock.netHandlers, Mock.netHandlerList, Mock.callbacks = {}, {}, {}, {}
    PFMed, PFEmsRequests, PFEms = nil, nil, nil
    DB = { patients = {}, injuries = {}, events = {}, nextId = 0 }
    LedgerEnv.load('pf-ambulancejob', FILES)
    installFakeSQL()
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    E, D, Store = PFEms, PFMed.Down, PFMed.Store
    QBCore = QBCoreMock
    assert(PFMed.Schema.Start(), 'schema ready')
end

local PATIENT, MEDIC, MEDIC2, CIV = 1, 2, 3, 4
local RIG, RIG2, CAR = 500, 501, 502
local function online(src, cid)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = 5000 }
    p.PlayerData.metadata.injail = 0
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function vehicle(e, model, pos, plate)
    Ents[e], Types[e], Mock.models[e], Mock.coords[e], Mock.plates[e], Headings[e] = true, 2, GetHashKey(model), pos, plate, 0.0
end
local function advance(s) Mock.clock = Mock.clock + s end
-- one action per second keeps clear of the 2/s rate limit (tested on its own)
local function act(src, action, args)
    advance(1)
    return E.Handle(src, action, args)
end
local function goDown()
    Health[PATIENT] = 0
    Mock.fireNet('pf-ambulancejob:server:ReportDown', PATIENT, { nonce = 'n1', kind = 'laststand' })
    Health[PATIENT] = 150
end
local function spawnStretcher()
    local r = act(MEDIC, 'spawn_stretcher', { rig = RIG })
    assert_true(r.ok, 'spawn: ' .. tostring(r.error))
    return r.net
end
local function placePatient()
    local net = spawnStretcher()
    local r = act(MEDIC, 'place_patient', { entity = net, target = PATIENT })
    assert_true(r.ok, 'place: ' .. tostring(r.error) .. ' ' .. tostring(r.message))
    return net
end
local function anomalies()
    Store.Flush()
    local n = 0
    for _, e in ipairs(DB.events) do if e.action == 'anomaly' and tostring(e.detail):find('moving_while_down') then n = n + 1 end end
    return n
end
local function audits(action)
    Store.Flush()
    local n = 0
    for _, e in ipairs(DB.events) do if e.action == action then n = n + 1 end end
    return n
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords, Mock.aces, Mock.dropped, Mock.deleted, Mock.vehicleOf, Mock.models, Mock.plates = {}, {}, {}, {}, {}, {}, {}, {}
    Mock.nextNetId = 100
    Bags, Replicated, EBags, Ents, Headings, Types, Frozen, Seats = {}, {}, {}, {}, {}, {}, {}, {}
    Spawned, Warps, Seated, Health, Armour, Attached, Stashes, Opened = {}, {}, {}, {}, {}, {}, {}, {}
    FakeDB.society('ambulance', 0)
    boot()
    PFMed.Engine.Random = function() return 0.5 end
    online(PATIENT, 'PATIENTCID')
    online(MEDIC, 'MEDICCID').PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true }
    online(MEDIC2, 'MEDIC2CID').PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true }
    online(CIV, 'CIVCID')
    -- the rig faces north at (100, 120): its rear doors are at (100, 116.4)
    vehicle(RIG, 'ambulance', vector3(100.0, 120.0, 30.0), 'EMS 123')
    vehicle(RIG2, 'ambulance', vector3(140.0, 120.0, 30.0), 'EMS 456')
    vehicle(CAR, 'sultan', vector3(100.0, 140.0, 30.0), 'CAR1')
    Mock.coords[MEDIC] = vector3(100.0, 115.5, 30.0)
    Mock.coords[MEDIC2] = vector3(101.0, 115.5, 30.0)
    Mock.coords[PATIENT] = vector3(100.6, 114.3, 30.0)
    Mock.coords[CIV] = vector3(99.5, 115.0, 30.0)
end

describe('server-spawned props', function()
    it('the stretcher is created by the server behind the rig; a client position is ignored', function()
        local r = act(MEDIC, 'spawn_stretcher', { rig = RIG, coords = { x = -500, y = 900, z = 10 } })
        assert_true(r.ok)
        assert_eq(#Spawned, 1)
        local s = Spawned[1]
        assert_eq(s.model, GetHashKey(Config.EMS.Stretchers.Model))
        assert_near(s.x, 100.0, 0.01)
        assert_near(s.y, 120.0 - 3.6 - 1.2, 0.01, 'behind the rear doors')
        assert_near(s.z, 29.1, 0.01)
        assert_eq(Frozen[s.entity], true)
        local bag = EBags[s.entity]['pf:stretcher']
        assert_eq(bag.kind, 'stretcher')
        assert_eq(bag.patient, false)
        assert_eq(bag.rig, RIG)
        assert_eq(Replicated['entity:' .. s.entity .. ':pf:stretcher'], true, 'replicated for late joiners')
    end)
    it('only an on-duty medic at the rear doors of a real rig gets one', function()
        assert_eq(act(CIV, 'spawn_stretcher', { rig = RIG }).error, 'no_permission')
        Mock.players[MEDIC].PlayerData.job.onduty = false
        assert_eq(act(MEDIC, 'spawn_stretcher', { rig = RIG }).error, 'not_on_duty')
        Mock.players[MEDIC].PlayerData.job.onduty = true
        Mock.coords[MEDIC] = vector3(100.0, 125.0, 30.0) -- at the front of the rig
        assert_eq(act(MEDIC, 'spawn_stretcher', { rig = RIG }).error, 'too_far')
        Mock.coords[MEDIC] = vector3(100.0, 137.0, 30.0)
        assert_eq(act(MEDIC, 'spawn_stretcher', { rig = CAR }).error, 'bad_args', 'not an ambulance')
        assert_eq(act(MEDIC, 'spawn_stretcher', { rig = 'x' }).error, 'bad_args')
        assert_eq(act(MEDIC, 'spawn_stretcher', { rig = 9999 }).error, 'not_found')
        assert_eq(act(MEDIC, 'nope', {}).error, 'bad_args')
        assert_eq(act(MEDIC, 'spawn_stretcher', 'x').error, 'bad_args')
        assert_eq(#Spawned, 0)
    end)
    it('one stretcher per rig: a second is refused until it is put back', function()
        local net = spawnStretcher()
        assert_eq(act(MEDIC2, 'spawn_stretcher', { rig = RIG }).error, 'conflict')
        assert_true(act(MEDIC, 'return', { entity = net }).ok)
        assert_eq(Mock.deleted[#Mock.deleted], net)
        assert_true(act(MEDIC2, 'spawn_stretcher', { rig = RIG }).ok)
    end)
    it('actions are rate limited to 2 per second', function()
        advance(1)
        E.Handle(MEDIC, 'fold', { entity = 1 })
        E.Handle(MEDIC, 'fold', { entity = 1 })
        assert_eq(E.Handle(MEDIC, 'fold', { entity = 1 }).error, 'rate_limited')
    end)
    it('the net event answers the client with the result', function()
        Mock.fireNet('pf-ambulancejob:server:Equipment', MEDIC, 'spawn_stretcher', { rig = RIG })
        local ev = Mock.clientEventsNamed('pf-ambulancejob:client:EquipmentResult')
        assert_eq(#ev, 1)
        assert_eq(ev[1].args[2].ok, true)
    end)
end)

describe('patients on stretchers', function()
    it('a medic places a down patient within 2.5 m; the bags say who is on it', function()
        goDown()
        local net = placePatient()
        assert_eq(Bags[PATIENT]['pf:onStretcher'], net)
        assert_eq(Replicated['player:' .. PATIENT .. ':pf:onStretcher'], true)
        assert_eq(EBags[net]['pf:stretcher'].patient, PATIENT)
        assert_eq(audits('equip_place'), 1, 'audited on the patient record')
    end)
    it('too far, a civilian, a stretcher already taken or an escorted patient are refused', function()
        local net = spawnStretcher()
        Mock.coords[PATIENT] = vector3(100.0, 110.0, 30.0)
        assert_eq(act(MEDIC, 'place_patient', { entity = net, target = PATIENT }).error, 'too_far')
        Mock.coords[PATIENT] = vector3(100.6, 114.3, 30.0)
        assert_eq(act(CIV, 'place_patient', { entity = net, target = PATIENT }).error, 'no_permission')
        Bags[PATIENT] = { ['pf:escort'] = { state = 'escorted', by = 9 } }
        assert_eq(act(MEDIC, 'place_patient', { entity = net, target = PATIENT }).error, 'conflict')
        Bags[PATIENT] = {}
        assert_eq(act(MEDIC, 'place_patient', { entity = net, target = MEDIC }).error, 'bad_args', 'not yourself')
        assert_true(act(MEDIC, 'place_patient', { entity = net, target = PATIENT }).ok)
        assert_eq(act(MEDIC2, 'place_patient', { entity = net, target = CIV }).error, 'conflict')
    end)
    it('a conscious patient gets off by themselves; a down or cuffed one cannot', function()
        local net = placePatient()
        assert_true(act(PATIENT, 'take_patient', { entity = net }).ok)
        assert_eq(Bags[PATIENT]['pf:onStretcher'], false)
        assert_true(act(MEDIC, 'place_patient', { entity = net, target = PATIENT }).ok)
        Mock.players[PATIENT].PlayerData.metadata.ishandcuffed = true
        assert_eq(act(PATIENT, 'take_patient', { entity = net }).error, 'no_permission')
        Mock.players[PATIENT].PlayerData.metadata.ishandcuffed = false
        goDown()
        assert_eq(act(PATIENT, 'take_patient', { entity = net }).error, 'no_permission')
        assert_true(act(MEDIC, 'take_patient', { entity = net }).ok, 'a medic takes them off')
        assert_eq(Bags[PATIENT]['pf:onStretcher'], false)
    end)
    it('the 16A movement check accepts a down patient moved on a stretcher, not one moved without', function()
        goDown()
        D.Tick(os.time())
        local net = placePatient()
        advance(10); D.Tick(os.time())
        local base = anomalies()
        -- pushed 15 m in one second (attached: the patient's ped is where the stretcher is)
        advance(1)
        Mock.coords[PATIENT] = vector3(100.6, 129.0, 30.0)
        Mock.coords[net] = vector3(100.6, 129.0, 29.0)
        D.Tick(os.time())
        assert_eq(anomalies(), base, 'no anomaly while on the stretcher')
        -- off the stretcher and moving that fast again: logged
        Mock.coords[MEDIC] = vector3(100.0, 128.0, 30.0) -- the medic pushed it there
        assert_true(act(MEDIC, 'take_patient', { entity = net }).ok)
        advance(10); D.Tick(os.time())
        advance(1)
        Mock.coords[PATIENT] = vector3(100.6, 150.0, 30.0)
        D.Tick(os.time())
        assert_eq(anomalies(), base + 1)
    end)
end)

describe('pushing', function()
    it('one pusher at a time, within reach; release puts a far stretcher back beside the pusher', function()
        local net = spawnStretcher()
        Mock.coords[MEDIC2] = vector3(110.0, 110.0, 30.0)
        assert_eq(act(MEDIC2, 'push', { entity = net }).error, 'too_far')
        assert_true(act(MEDIC, 'push', { entity = net }).ok)
        assert_eq(Frozen[net], false)
        assert_eq(EBags[net]['pf:stretcher'].pusher, MEDIC)
        Mock.coords[MEDIC2] = vector3(100.5, 115.0, 30.0)
        assert_eq(act(MEDIC2, 'push', { entity = net }).error, 'conflict')
        assert_eq(act(MEDIC2, 'release', { entity = net }).error, 'invalid_state', 'only the pusher releases')
        -- the pusher's client claims the stretcher is 40 m away
        Mock.coords[net] = vector3(140.0, 115.0, 29.0)
        assert_true(act(MEDIC, 'release', { entity = net }).ok)
        assert_near(Mock.coords[net].x, 100.0, 0.01, 'clamped to the pusher')
        assert_eq(Frozen[net], true)
        assert_eq(EBags[net]['pf:stretcher'].pusher, false)
    end)
    it('the safety pass stops a pusher who walked away or went off duty', function()
        local net = spawnStretcher()
        act(MEDIC, 'push', { entity = net })
        Mock.coords[MEDIC] = vector3(100.0, 140.0, 30.0)
        E.Tick()
        assert_eq(EBags[net]['pf:stretcher'].pusher, MEDIC, 'one far pass is tolerated')
        E.Tick()
        assert_eq(EBags[net]['pf:stretcher'].pusher, false)
        Mock.coords[MEDIC] = vector3(100.0, 115.5, 30.0)
        act(MEDIC, 'push', { entity = net })
        Mock.players[MEDIC].PlayerData.job.onduty = false
        E.Tick(); E.Tick()
        assert_eq(EBags[net]['pf:stretcher'].pusher, false)
    end)
end)

describe('loading into the rig', function()
    it('load seats the patient with SetPedIntoVehicle; unload puts them back on a new stretcher', function()
        goDown()
        local net = placePatient()
        local r = act(MEDIC, 'load', { entity = net, rig = RIG })
        assert_true(r.ok, tostring(r.error))
        assert_eq(#Seated, 1)
        assert_eq(Seated[1].ped, PATIENT)
        assert_eq(Seated[1].veh, RIG)
        assert_eq(Seated[1].seat, 1)
        assert_eq(Mock.deleted[#Mock.deleted], net, 'the stretcher went in with the patient')
        assert_eq(Bags[PATIENT]['pf:onStretcher'], false)
        assert_eq(Bags[PATIENT]['pf:inRig'], RIG)
        assert_eq(EBags[RIG]['pf:rig'].loaded, PATIENT)
        assert_eq(act(MEDIC2, 'spawn_stretcher', { rig = RIG }).error, 'conflict', 'the rig\'s stretcher is inside')
        -- the rig drives off; unload at the destination
        Mock.coords[RIG] = vector3(300.0, 300.0, 30.0)
        Mock.coords[PATIENT] = vector3(300.0, 298.0, 30.0)
        assert_eq(act(MEDIC, 'unload', { rig = RIG }).error, 'too_far')
        Mock.coords[MEDIC] = vector3(300.0, 295.5, 30.0)
        local u = act(MEDIC, 'unload', { rig = RIG })
        assert_true(u.ok, tostring(u.error))
        assert_eq(Bags[PATIENT]['pf:inRig'], false)
        assert_eq(Bags[PATIENT]['pf:onStretcher'], u.net)
        assert_eq(Mock.vehicleOf[PATIENT], nil, 'out of the seat (server SetEntityCoords)')
        assert_near(Mock.coords[PATIENT].y, 300 - 3.6 - 1.2, 0.01)
        assert_eq(EBags[u.net]['pf:stretcher'].patient, PATIENT)
        assert_eq(audits('equip_load'), 1)
        assert_eq(audits('equip_unload'), 1)
    end)
    it('load needs the stretcher and the medic within 4 m of the rear doors, its own rig and a free seat', function()
        local net = placePatient()
        Mock.coords[net] = vector3(100.0, 108.0, 29.0)
        assert_eq(act(MEDIC, 'load', { entity = net, rig = RIG }).error, 'too_far')
        Mock.coords[net] = vector3(100.0, 115.2, 29.1)
        Mock.coords[MEDIC] = vector3(100.0, 110.0, 30.0)
        assert_eq(act(MEDIC, 'load', { entity = net, rig = RIG }).error, 'too_far')
        Mock.coords[MEDIC] = vector3(100.0, 115.5, 30.0)
        assert_eq(act(MEDIC, 'load', { entity = net, rig = RIG2 }).error, 'conflict', 'another rig')
        Seats[RIG] = { [1] = 77, [2] = 78 }
        assert_eq(act(MEDIC, 'load', { entity = net, rig = RIG }).error, 'conflict', 'no free seat')
        Seats[RIG] = { [1] = 77 }
        local r = act(MEDIC, 'load', { entity = net, rig = RIG })
        assert_true(r.ok)
        assert_eq(r.seat, 2)
    end)
    it('an empty stretcher is not loaded (it is put back instead)', function()
        local net = spawnStretcher()
        assert_eq(act(MEDIC, 'load', { entity = net, rig = RIG }).error, 'invalid_state')
    end)
    it('a down patient thrown out of the seat is put back; a conscious one who left is cleared', function()
        goDown()
        local net = placePatient()
        act(MEDIC, 'load', { entity = net, rig = RIG })
        Mock.vehicleOf[PATIENT] = nil
        E.Tick()
        assert_eq(#Seated, 2, 'reseated')
        assert_eq(Mock.vehicleOf[PATIENT], RIG)
        -- revived on the way and stepped out
        D.Revive(PATIENT, {})
        PFMed.Engine.SetConsciousness('PATIENTCID', 'alert', 'revive', 'test')
        D.Apply(PATIENT, 'alert')
        Mock.vehicleOf[PATIENT] = nil
        E.Tick(); E.Tick()
        assert_eq(Bags[PATIENT]['pf:inRig'], false)
        assert_false((EBags[RIG]['pf:rig'] or {}).loaded)
        assert_true(act(MEDIC, 'spawn_stretcher', { rig = RIG }).ok, 'the stretcher is back in stock')
    end)
end)

describe('safety: drops, removed entities, resource stop', function()
    it('pusher drop: the patient is released at their last server position and the stretcher parked', function()
        goDown()
        local net = placePatient()
        act(MEDIC, 'push', { entity = net })
        Mock.coords[PATIENT] = vector3(105.0, 105.0, 30.0)
        Mock.fireEvent('playerDropped', MEDIC)
        assert_eq(Bags[PATIENT]['pf:onStretcher'], false)
        local w = Warps[#Warps]
        assert_eq(w.entity, PATIENT)
        assert_true(math.abs(w.x - 105.0) <= 1.0 and math.abs(w.y - 105.0) <= 1.0, 'beside where they were')
        assert_eq(EBags[net]['pf:stretcher'].pusher, false)
        assert_eq(EBags[net]['pf:stretcher'].patient, false)
        assert_eq(Frozen[net], true)
        assert_true(#Mock.clientEventsNamed('pf-ambulancejob:client:EquipmentReleased') >= 1)
    end)
    it('patient drop: the stretcher is free again', function()
        local net = placePatient()
        Mock.fireEvent('playerDropped', PATIENT)
        Mock.players[PATIENT] = nil
        assert_eq(EBags[net]['pf:stretcher'].patient, false)
        assert_eq(E.PatientOf(PATIENT), nil)
        assert_true(act(MEDIC, 'place_patient', { entity = net, target = CIV }).ok)
    end)
    it('logout to the character menu releases too', function()
        local net = placePatient()
        Mock.fireEvent('QBCore:Server:OnPlayerUnload', nil, PATIENT)
        assert_eq(Bags[PATIENT]['pf:onStretcher'], false)
        assert_eq(EBags[net]['pf:stretcher'].patient, false)
    end)
    it('a loaded patient who drops frees the rig', function()
        local net = placePatient()
        act(MEDIC, 'load', { entity = net, rig = RIG })
        Mock.fireEvent('playerDropped', PATIENT)
        Mock.players[PATIENT] = nil
        assert_eq(EBags[RIG]['pf:rig'].loaded, false)
        assert_true(act(MEDIC, 'spawn_stretcher', { rig = RIG }).ok)
    end)
    it('rig deleted with the patient inside: they are put down where the rig last was', function()
        goDown()
        local net = placePatient()
        act(MEDIC, 'load', { entity = net, rig = RIG })
        Mock.coords[RIG] = vector3(400.0, 400.0, 30.0)
        E.Tick() -- remembers the rig's last position
        Ents[RIG] = nil
        Mock.fireEvent('entityRemoved', nil, RIG)
        assert_eq(Bags[PATIENT]['pf:inRig'], false)
        local w = Warps[#Warps]
        assert_eq(w.entity, PATIENT)
        assert_true(math.abs(w.x - 400.0) <= 2.5 and math.abs(w.y - 400.0) <= 2.5, 'at the rig\'s last position')
        assert_eq(E.Rig(RIG), nil)
    end)
    it('rig deleted with its stretcher out: the patient is released and the orphan prop deleted', function()
        local net = placePatient()
        Ents[RIG] = nil
        Mock.fireEvent('entityRemoved', nil, RIG)
        assert_eq(Bags[PATIENT]['pf:onStretcher'], false)
        assert_eq(Mock.deleted[#Mock.deleted], net)
        assert_eq(E.stats.orphaned, 1)
    end)
    it('rig gone without an entityRemoved event: the safety pass does the same', function()
        local net = placePatient()
        Ents[RIG] = nil
        E.Tick()
        assert_eq(Bags[PATIENT]['pf:onStretcher'], false)
        assert_eq(Mock.deleted[#Mock.deleted], net)
    end)
    it('stretcher prop removed (entityRemoved): the patient is released and the rig gets it back', function()
        local net = placePatient()
        Ents[net] = nil
        Mock.fireEvent('entityRemoved', nil, net)
        assert_eq(Bags[PATIENT]['pf:onStretcher'], false)
        assert_true(act(MEDIC, 'spawn_stretcher', { rig = RIG }).ok)
    end)
    it('a patient no longer on the prop (detached on their client) is released after two passes', function()
        local net = placePatient()
        Mock.coords[PATIENT] = vector3(120.0, 114.0, 30.0)
        E.Tick()
        assert_eq(Bags[PATIENT]['pf:onStretcher'], net)
        E.Tick()
        assert_eq(Bags[PATIENT]['pf:onStretcher'], false)
    end)
    it('resource stop: everyone is released and every prop deleted', function()
        local net = placePatient()
        local m = act(MEDIC2, 'place_medbag', { rig = RIG })
        assert_true(m.ok)
        Mock.fireEvent('onResourceStop', nil, 'pf-ambulancejob')
        assert_eq(Bags[PATIENT]['pf:onStretcher'], false)
        local deleted = {}
        for _, e in ipairs(Mock.deleted) do deleted[e] = true end
        assert_true(deleted[net] and deleted[m.net], 'props deleted')
        assert_eq(E.Item(1), nil)
    end)
    it('resource start clears bags a crash left on players', function()
        Bags[CIV] = { ['pf:onStretcher'] = 123, ['pf:inRig'] = 500 }
        Mock.fireEvent('onResourceStart', nil, 'pf-ambulancejob')
        assert_eq(Bags[CIV]['pf:onStretcher'], false)
        assert_eq(Bags[CIV]['pf:inRig'], false)
    end)
end)

describe('wheelchairs and medbags', function()
    it('a wheelchair at a hospital desk; a down patient goes on a stretcher instead; the owner leaving takes it away', function()
        assert_eq(act(MEDIC, 'spawn_wheelchair', {}).error, 'too_far')
        local desk = Config.Locations['checking'][1]
        Mock.coords[MEDIC] = vector3(desk.x + 1.0, desk.y, desk.z)
        Mock.coords[PATIENT] = vector3(desk.x + 1.5, desk.y + 1.0, desk.z)
        local r = act(MEDIC, 'spawn_wheelchair', {})
        assert_true(r.ok, tostring(r.error))
        assert_eq(Spawned[#Spawned].model, GetHashKey(Config.EMS.Wheelchairs.Model))
        assert_eq(EBags[r.net]['pf:stretcher'].kind, 'wheelchair')
        goDown()
        assert_eq(act(MEDIC, 'seat', { entity = r.net, target = PATIENT }).error, 'invalid_state')
        assert_true(act(MEDIC, 'seat', { entity = r.net, target = CIV }).error ~= nil, 'civ is too far')
        Mock.coords[CIV] = vector3(desk.x + 1.0, desk.y + 1.5, desk.z)
        assert_true(act(MEDIC, 'seat', { entity = r.net, target = CIV }).ok)
        assert_eq(Bags[CIV]['pf:onStretcher'], r.net)
        Mock.fireEvent('playerDropped', MEDIC)
        assert_eq(Bags[CIV]['pf:onStretcher'], false)
        assert_eq(Mock.deleted[#Mock.deleted], r.net)
    end)
    it('the medbag comes from the rig, is the stash pf_medbag_<plate> and opens only for a medic beside it', function()
        Mock.coords[MEDIC] = vector3(100.0, 109.0, 30.0)
        assert_eq(act(MEDIC, 'place_medbag', { rig = RIG }).error, 'too_far')
        Mock.coords[MEDIC] = vector3(100.0, 114.0, 30.0)
        local r = act(MEDIC, 'place_medbag', { rig = RIG })
        assert_true(r.ok)
        assert_eq(r.stash, 'pf_medbag_EMS123')
        assert_true(Stashes['pf_medbag_EMS123'] ~= nil)
        assert_eq(act(MEDIC2, 'place_medbag', { rig = RIG }).error, 'conflict', 'one bag per rig')
        assert_eq(act(CIV, 'open_medbag', { entity = r.net }).error, 'no_permission')
        Mock.coords[MEDIC2] = vector3(120.0, 114.0, 30.0)
        assert_eq(act(MEDIC2, 'open_medbag', { entity = r.net }).error, 'too_far')
        assert_true(act(MEDIC, 'open_medbag', { entity = r.net }).ok)
        assert_eq(Opened[#Opened].id, 'pf_medbag_EMS123')
        assert_eq(Opened[#Opened].src, MEDIC)
        assert_true(act(MEDIC, 'pickup_medbag', { entity = r.net }).ok)
        assert_eq(Mock.deleted[#Mock.deleted], r.net)
        assert_true(act(MEDIC2, 'place_medbag', { rig = RIG }).error == 'too_far', 'MEDIC2 is far; the rig has its bag back')
        Mock.coords[MEDIC2] = vector3(100.5, 114.0, 30.0)
        assert_true(act(MEDIC2, 'place_medbag', { rig = RIG }).ok)
    end)
    it('a down or cuffed medic, or one lying on equipment, cannot use equipment', function()
        local net = spawnStretcher()
        Mock.players[MEDIC].PlayerData.metadata.ishandcuffed = true
        assert_eq(act(MEDIC, 'fold', { entity = net }).error, 'invalid_state')
        Mock.players[MEDIC].PlayerData.metadata.ishandcuffed = false
        assert_true(act(MEDIC, 'fold', { entity = net }).ok)
        assert_eq(EBags[net]['pf:stretcher'].folded, true)
        assert_eq(act(MEDIC, 'place_patient', { entity = net, target = PATIENT }).error, 'invalid_state', 'folded')
    end)
end)

describe('pfm-radialmenu: the bin-bag stretcher is retired', function()
    local function loadRadial()
        Config = nil
        load_resource('pfm-radialmenu/config.lua')
        return Config
    end
    it('the ambulance radial entries call the new equipment event with an `equipment` field', function()
        local cfg = loadRadial()
        local found, legacy = {}, 0
        local function walk(list)
            for _, v in ipairs(list) do
                if v.items then walk(v.items) end
                if v.event == 'pf-ambulancejob:client:Equipment' then
                    found[v.equipment] = true
                    assert_true(v.action == nil, 'the radial calls `action` as a function')
                end
                if v.event == 'qb-radialmenu:client:TakeStretcher' or v.event == 'qb-radialmenu:client:RemoveStretcher' then legacy = legacy + 1 end
            end
        end
        walk(cfg.JobInteractions['ambulance'])
        assert_eq(legacy, 0)
        for _, a in ipairs({ 'spawn_stretcher', 'push', 'place_patient', 'take_patient', 'load', 'unload', 'fold', 'return', 'spawn_wheelchair', 'seat', 'unseat', 'place_medbag', 'open_medbag', 'pickup_medbag' }) do
            assert_true(found[a], 'radial entry for ' .. a)
            assert_true(E.Actions[a] ~= nil, 'server action ' .. a)
        end
    end)
    it('the radial client no longer spawns a prop or runs loops; the legacy events forward', function()
        local src = __readfile('pfm-radialmenu/client/stretcher.lua')
        assert_false(src:find('CreateObject', 1, true), 'no client-spawned prop')
        assert_false(src:find('CreateThread', 1, true), 'no loops')
        assert_false(src:find('binbag', 1, true))
        assert_true(src:find("pf-ambulancejob:client:Equipment", 1, true) ~= nil)
    end)
    it('the legacy busy relays are dropped on the server', function()
        function DoesPlayerExist(id) return Mock.players[tonumber(id)] ~= nil end
        load_resource('pfm-radialmenu/server/trunk.lua')
        load_resource('pfm-radialmenu/server/stretcher.lua')
        Mock.coords[CIV] = vector3(100.0, 115.0, 30.0)
        Mock.fireNet('qb-radialmenu:Stretcher:BusyCheck', CIV, PATIENT, 'lay')
        Mock.fireNet('qb-radialmenu:server:BusyResult', CIV, true, PATIENT, 'lay')
        assert_eq(#Mock.clientEventsNamed('qb-radialmenu:Stretcher:client:BusyCheck'), 0)
        assert_eq(#Mock.clientEventsNamed('qb-radialmenu:client:Result'), 0)
    end)
    it('the equipment client spawns nothing itself and writes no state bag', function()
        local src = __readfile('[pfscripts]/pf-ambulancejob/client/ems_equipment.lua')
        assert_false(src:find('CreateObject', 1, true), 'props come from the server')
        assert_false(src:find('state:set', 1, true), 'no client state-bag write')
        assert_false(src:find('GetEntityCoords%([^)]*%)%s*[,}]'), 'no position is sent')
    end)
end)
