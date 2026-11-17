-- pf-ambulancejob batch 17B: medical items. Every treatment item exists in pfm-core shared items;
-- the usable items are registered in server/items.lua (no longer in server/main.lua); self-care items
-- (bandage, IFAK, painkillers and the field items) only start a server-checked action, and the item
-- is used up on the server before any effect (RemoveItem false -> no effect); the legacy remove
-- events do nothing; a first-aid kit starts the server-timed civilian first aid.
load_resource('tests/lua/ledger_env.lua')
function IsDuplicityVersion() return true end

function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
Bags = {}
function Player(src)
    Bags[src] = Bags[src] or {}
    local b = Bags[src]
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end
Health, Armour = {}, {}
function GetEntityHealth(ped) return Health[ped] or 200 end
function GetPedArmour(ped) return Armour[ped] or 0 end
function GetEntityAttachedTo() return 0 end
Items, RemoveFails, Removed = {}, false, {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, src, item, n)
        if RemoveFails then return false end
        local have = (Items[src] or {})[item] or 0
        if have < (n or 1) then return false end
        Items[src][item] = have - (n or 1)
        Removed[#Removed + 1] = { src = src, item = item }
        return true
    end,
    AddItem = function(_, src, item, n) Items[src] = Items[src] or {}; Items[src][item] = (Items[src][item] or 0) + (n or 1) return true end,
}
QBCoreMock.Functions.HasItem = function(src, item, n) return ((Items[src] or {})[item] or 0) >= (n or 1) end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.HasPermission = function() return false end
function GetPlayers() local out = {} for s in pairs(Mock.players) do out[#out + 1] = tostring(s) end return out end
function SetEntityCoords() end
Closes = {}
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function() return { ok = true, id = 1 } end,
    CloseByRef = function(_, t, id, status, reason) Closes[#Closes + 1] = { type = t, id = id, status = status, reason = reason } return { ok = true } end,
    Emit = function() return 1 end,
}
Quals = {}
local GOV = { HasQualification = function(_, cid, qual) return (Quals[cid] or {})[qual] == true, 'granted' end }
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

DB = { patients = {}, injuries = {}, events = {}, treatments = {}, nextId = 0 }
Findings, Diagnoses = {}, {}
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
    Q.ListFindings = function(cid) local out = {} for _, f in ipairs(Findings) do if f.citizenid == cid then out[#out + 1] = copy(f) end end return out end
    Q.ListDiagnoses = function(cid) local out = {} for _, d in ipairs(Diagnoses) do if d.citizenid == cid then out[#out + 1] = copy(d) end end return out end
    Q.InsertTreatment = function(r) DB.treatments[#DB.treatments + 1] = copy(r); return #DB.treatments end
end

local AJ = '[pfscripts]/pf-ambulancejob/'
local FILES = { AJ .. 'config.lua', AJ .. 'config_medical.lua', AJ .. 'shared/framework.lua' }
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'treatments' }) do FILES[#FILES + 1] = AJ .. 'shared/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/main.lua'
for _, f in ipairs({ 'schema', 'store', 'engine', 'downstate', 'effects', 'api', 'treatment' }) do FILES[#FILES + 1] = AJ .. 'server/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/items.lua'
FILES[#FILES + 1] = AJ .. 'server/treatment.lua'

local D, Store, Engine, TX
local function boot()
    Mock.eventHandlers, Mock.netHandlers, Mock.netHandlerList, Mock.callbacks, Mock.useables = {}, {}, {}, {}, {}
    PFMed, PFEmsRequests, PFMedItems = nil, nil, nil
    DB = { patients = {}, injuries = {}, events = {}, treatments = {}, nextId = 0 }
    LedgerEnv.load('pf-ambulancejob', FILES)
    installFakeSQL()
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    D, Store, Engine, TX = PFMed.Down, PFMed.Store, PFMed.Engine, PFMed.Treat
    assert(PFMed.Schema.Start(), 'schema ready')
end

local PATIENT, MEDIC, EMR, CIV, DOC = 1, 2, 3, 4, 5
local function online(src, cid, job)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = 5000 }
    p.PlayerData.metadata.injail = 0
    if job then p.PlayerData.job = job end
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function advance(s) Mock.clock = Mock.clock + s end
local function patient() return Store.Peek('PATIENTCID') end
local function level() return patient().consciousness end
local function injury(id) return patient().injuries[id] end
local function wound(spec)
    spec.mechanism = spec.mechanism or 'edged'
    local inj = assert(Engine.AddInjury('PATIENTCID', spec, {}), 'injury added')
    return inj.id
end
local function treat(src, data)
    data.target = data.target or PATIENT
    return Mock.callCallback('pf-ambulancejob:server:treat', src, data)
end
local function goDown()
    Health[PATIENT] = 0
    Mock.fireNet('pf-ambulancejob:server:ReportDown', PATIENT, { nonce = 'n1', kind = 'laststand' })
    Health[PATIENT] = 150
end
local function events(name)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do if e.name == name then out[#out + 1] = e end end
    return out
end
local function lastToken(src)
    local list = Mock.clientEventsNamed('pf-ambulancejob:client:Revive')
    for i = #list, 1, -1 do if list[i].target == src then return list[i].args[1], list[i].args[2] end end
end
local HOSPITAL

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords, Mock.aces, Mock.dropped, Mock.models, Mock.vehicleOf = {}, {}, {}, {}, {}, {}
    Mock.invokingResource = nil
    Health, Armour, Items, Bags, Closes, Findings, Diagnoses, Removed = {}, {}, {}, {}, {}, {}, {}, {}
    RemoveFails = false
    Mock.exportsByResource['pf-government'] = GOV
    Quals = {
        MEDICCID = { emr = true, emt = true, paramedic = true },
        EMRCID = { emr = true },
        DOCCID = { emr = true, emt = true, paramedic = true, nurse = true, physician = true },
    }
    GetAllVehicles = nil
    boot()
    Engine.Random = function() return 0.5 end
    TX.Random = function() return 0.99 end
    online(PATIENT, 'PATIENTCID')
    online(MEDIC, 'MEDICCID', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 1 } })
    online(EMR, 'EMRCID', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 0 } })
    online(CIV, 'CIVCID')
    online(DOC, 'DOCCID', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 2 } })
    Mock.coords[PATIENT] = vector3(100.0, 100.0, 30.0)
    Mock.coords[MEDIC] = vector3(101.0, 100.0, 30.0)
    Mock.coords[EMR] = vector3(100.0, 101.0, 30.0)
    Mock.coords[CIV] = vector3(99.0, 100.0, 30.0)
    Mock.coords[DOC] = vector3(100.0, 99.0, 30.0)
    HOSPITAL = Config.Locations['hospital'][1]['location']
end


local MEDICAL = { 'tourniquet', 'pressure_dressing', 'hemostatic_gauze', 'chest_seal', 'decompression_needle', 'opa', 'npa', 'bvm',
    'et_tube', 'oxygen_tank', 'c_collar', 'backboard', 'splint', 'traction_splint', 'pelvic_binder', 'iv_kit', 'saline_bag',
    'blood_onegative', 'txa', 'morphine', 'fentanyl', 'naloxone', 'epinephrine', 'aed', 'burn_dressing', 'suture_kit', 'cast_kit',
    'antibiotics', 'bp_cuff', 'pulse_oximeter', 'stethoscope', 'penlight', 'glucometer', 'thermometer', 'crutches' }

local function sharedItems()
    local saved = QBCore
    QBCore = { Shared = {} }
    load_resource('pfm-core/shared/items.lua')
    local items = QBCore.Shared.Items
    QBCore = saved
    return items
end

local function use(src, name) Mock.useables[name](src, { name = name }) end
local function selfTreats(src)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('pf-ambulancejob:client:SelfTreat')) do if e.target == src then out[#out + 1] = e end end
    return out
end
local function lastNotify(src)
    local list = Mock.clientEventsNamed('QBCore:Notify')
    for i = #list, 1, -1 do if list[i].target == src then return list[i].args[1], list[i].args[2] end end
end
local function selfTreat(src, action, item)
    return Mock.callCallback('pf-ambulancejob:server:treat', src, { target = src, action = action, item = item, req = 'self-' .. action .. os.time() })
end

describe('medical items in pfm-core shared/items.lua', function()
    local items = sharedItems()
    it('every item of the unit exists with a valid definition', function()
        for _, name in ipairs(MEDICAL) do
            local def = items[name]
            assert_true(def ~= nil, name .. ' missing')
            assert_eq(def.name, name)
            assert_eq(def.type, 'item')
            assert_true(type(def.label) == 'string' and #def.label > 0)
            assert_true(type(def.weight) == 'number' and def.weight > 0, name .. ' weight')
            assert_eq(def.image, name .. '.png')
            assert_eq(def.unique, false)
        end
    end)
    it('every item a treatment uses or needs exists (no action can ask for an unknown item)', function()
        for name in pairs(PFMed.Treatments.ItemNames()) do assert_true(items[name] ~= nil, name .. ' unknown') end
        for name in pairs(PFMed.Treatments.SelfUse) do
            assert_true(items[name] ~= nil, name .. ' unknown')
            assert_eq(items[name].useable, true, name .. ' must be usable')
        end
    end)
    it('the legacy medical items stay', function()
        for _, name in ipairs({ 'bandage', 'ifaks', 'painkillers', 'firstaid' }) do assert_true(items[name] ~= nil) end
    end)
end)

describe('usable items are registered in server/items.lua', function()
    it('server/main.lua alone registers no medical item', function()
        Mock.useables = {}
        local files = {}
        for _, f in ipairs(FILES) do if not f:find('server/items.lua', 1, true) then files[#files + 1] = f end end
        PFMed, PFEmsRequests, PFMedItems = nil, nil, nil
        LedgerEnv.load('pf-ambulancejob', files)
        for _, name in ipairs({ 'bandage', 'ifaks', 'painkillers', 'firstaid' }) do assert_eq(Mock.useables[name], nil, name) end
        boot()
        for _, name in ipairs({ 'bandage', 'ifaks', 'painkillers', 'firstaid', 'tourniquet', 'splint' }) do
            assert_true(Mock.useables[name] ~= nil, name)
        end
    end)
end)

describe('self-care items', function()
    it('a bandage with nothing to bandage starts nothing and is kept', function()
        Items[PATIENT] = { bandage = 1 }
        use(PATIENT, 'bandage')
        assert_eq(#selfTreats(PATIENT), 0)
        assert_eq(Items[PATIENT].bandage, 1)
        local _, kind = lastNotify(PATIENT)
        assert_eq(kind, 'error')
    end)
    it('a bandage on a bleeding wound: the client is told to start, the server uses the bandage, then the dressing', function()
        local id = wound({ type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 2 })
        Items[PATIENT] = { bandage = 1, pressure_dressing = 1 }
        use(PATIENT, 'bandage')
        local st = selfTreats(PATIENT)
        assert_eq(#st, 1)
        assert_eq(st[1].args[1], 'pressure_dressing')
        assert_eq(st[1].args[2], 'bandage')
        assert_eq(Items[PATIENT].bandage, 1, 'nothing used before the server applies it')
        assert_eq(injury(id).treatments.pressure, nil)
        local res = selfTreat(PATIENT, 'pressure_dressing', 'bandage')
        assert_true(res.ok, tostring(res.message))
        assert_eq(Items[PATIENT].bandage, 0, 'the bandage that was used')
        assert_eq(Items[PATIENT].pressure_dressing, 1)
        assert_eq(injury(id).treatments.pressure, true)
        assert_eq(DB.treatments[1].by_cid, 'PATIENTCID')
    end)
    it('RemoveItem returning false: painkillers do nothing', function()
        Items[PATIENT] = { painkillers = 1 }
        wound({ type = 'bruising', region = 'thigh_l', severity = 3, mechanism = 'blunt' })
        RemoveFails = true
        local res = selfTreat(PATIENT, 'painkiller', 'painkillers')
        assert_eq(res.error, 'missing_item')
        assert_eq((patient().drugs or {}).analgesic_oral, nil)
    end)
    it('painkillers: analgesia on the server, no second dose while the first works', function()
        Items[PATIENT] = { painkillers = 2 }
        use(PATIENT, 'painkillers')
        assert_eq(#selfTreats(PATIENT), 1)
        assert_true(selfTreat(PATIENT, 'painkiller', 'painkillers').ok)
        assert_true(patient().drugs.analgesic_oral ~= nil)
        assert_eq(Items[PATIENT].painkillers, 1)
        assert_true(PFMed.Effects.Mods(patient(), os.time()).analgesia, 'the effect profile sees it')
        advance(10)
        local res = selfTreat(PATIENT, 'painkiller', 'painkillers')
        assert_eq(res.error, 'invalid_state')
        assert_eq(Items[PATIENT].painkillers, 1)
    end)
    it('an IFAK packs the worst bleeding wound and gives painkillers', function()
        local id = wound({ type = 'laceration', subtype = 'deep', region = 'thigh_r', severity = 3 })
        Items[PATIENT] = { ifaks = 1 }
        use(PATIENT, 'ifaks')
        assert_eq(selfTreats(PATIENT)[1].args[1], 'ifak')
        assert_true(selfTreat(PATIENT, 'ifak', 'ifaks').ok)
        assert_eq(injury(id).treatments.pressure, true)
        assert_eq(injury(id).treatments.hemostatic, true)
        assert_eq(injury(id).stage, 'stabilized')
        assert_true(patient().drugs.analgesic_oral ~= nil)
        assert_eq(Items[PATIENT].ifaks, 0)
    end)
    it('a splint on yourself goes on the injured limb; self-only items cannot be used on others', function()
        local id = wound({ type = 'fracture', subtype = 'closed', structure = 'forearm_r', severity = 2, mechanism = 'fall' })
        Items[PATIENT] = { splint = 1 }
        use(PATIENT, 'splint')
        assert_true(selfTreat(PATIENT, 'splint', 'splint').ok)
        assert_eq(injury(id).treatments.splinted, true)
        Items[CIV] = { ifaks = 1 }
        local res = Mock.callCallback('pf-ambulancejob:server:treat', CIV, { target = PATIENT, action = 'ifak' })
        assert_eq(res.error, 'bad_args')
        assert_eq(Items[CIV].ifaks, 1)
    end)
    it('the legacy remove events do nothing; a first-aid kit starts civilian first aid on the client', function()
        Items[PATIENT] = { bandage = 1, ifaks = 1, painkillers = 1 }
        Mock.fireNet('hospital:server:removeBandage', PATIENT)
        Mock.fireNet('hospital:server:removeIfaks', PATIENT)
        Mock.fireNet('hospital:server:removePainkillers', PATIENT)
        assert_eq(Items[PATIENT].bandage, 1)
        assert_eq(Items[PATIENT].ifaks, 1)
        assert_eq(Items[PATIENT].painkillers, 1)
        Items[CIV] = { firstaid = 1 }
        use(CIV, 'firstaid')
        assert_eq(#Mock.clientEventsNamed('hospital:client:UseFirstAid'), 1)
        assert_eq(Items[CIV].firstaid, 1, 'used up only when the revive happens')
    end)
end)

describe('honest EMS can get the supplies (pfm-shops ambulance armory)', function()
    local saved = Config
    Config = nil
    load_resource('pfm-shops/config.lua')
    local shops = Config
    Config = saved
    it('the ambulance armory stocks every item a medic treatment uses up or needs, for the ambulance job only', function()
        local loc = shops.Locations['ambulance']
        assert_eq(loc.requiredJob, 'ambulance')
        local stocked = {}
        for _, p in ipairs(loc.products) do stocked[p.name] = p end
        for name in pairs(PFMed.Treatments.ItemNames()) do
            if name ~= 'water_bottle' then
                assert_true(stocked[name] ~= nil, name .. ' is not in the ambulance armory')
                assert_true(stocked[name].amount > 0)
            end
        end
        for _, name in ipairs(MEDICAL) do assert_true(stocked[name] ~= nil, name .. ' is not in the ambulance armory') end
        -- controlled drugs and hospital kits follow the grades' scope of practice
        assert_eq(stocked.morphine.requiredGrade, 1)
        assert_eq(stocked.suture_kit.requiredGrade, 2)
        assert_eq(stocked.tourniquet.requiredGrade, nil)
    end)
end)

describe('legacy EMS MDT keys keep their old item', function()
    it('Apply Splint with a first-aid kit and Burn Dressing with an IFAK, through the legacy key only', function()
        local frac = wound({ type = 'fracture', subtype = 'closed', structure = 'tibia_l', severity = 2, mechanism = 'fall' })
        local burn = wound({ type = 'burn', subtype = 'second', region = 'forearm_r', severity = 2, mechanism = 'burn' })
        Items[MEDIC] = { firstaid = 1, ifaks = 1 }
        -- the new treat callback does not take the old items
        local res = Mock.callCallback('pf-ambulancejob:server:treat', MEDIC, { target = PATIENT, action = 'splint', region = 'lower_leg_l' })
        assert_eq(res.error, 'missing_item')
        Mock.fireNet('pf-ambulancejob:server:applyTreatment', MEDIC, PATIENT, 'splint')
        assert_eq(injury(frac).treatments.splinted, true)
        assert_eq(Items[MEDIC].firstaid, 0)
        advance(10)
        Mock.fireNet('pf-ambulancejob:server:applyTreatment', MEDIC, PATIENT, 'burn_dressing')
        assert_eq(injury(burn).treatments.dressed, true)
        assert_eq(Items[MEDIC].ifaks, 0)
    end)
end)
