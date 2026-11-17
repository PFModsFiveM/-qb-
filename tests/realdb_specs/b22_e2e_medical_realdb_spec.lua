-- 22A end to end on MariaDB: shooting -> injuries -> EMS exam/treat -> rig -> hospital admission ->
-- imaging -> surgery (projectile to the police lab) -> discharge -> one keyed bill paid once. REAL
-- resources in one world (tests/specs/b22_e2e_world.lua): pf-ambulancejob (every server file of its
-- fxmanifest), pfm-policejob's evidence modules (store, custody, scene, api, lab: the projectile
-- listener) and the pfm-banking ledger. The shot is the server's own observation (weaponDamageEvent
-- from the shooter, the health drop the sampler reads, the victim's capped bone hint); every later
-- step is the callback or net event the client would send. pf-ambulancejob restarts after the
-- admission and again after the surgery; pfm-policejob restarts after the projectile.
-- Stubbed: FiveM natives (entities, state bags, health), inventory (in memory), pf-services,
-- pfm-phone (invoice id), pf-government (absent: qualifications implied by grade).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
load_resource('tests/specs/b22_e2e_world.lua')
function IsDuplicityVersion() return true end
Mock.clock = 1800000000
Mock.nextNetId = 100
QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, ambulance = { label = 'EMS' } }
World.installResourceState({ ['pf-government'] = 'missing', ['pf-justice'] = 'missing', ['pfm-prison'] = 'missing',
    ['pf-emsmdt'] = 'missing', ['pf-stores'] = 'missing', ['pf-citizen'] = 'missing' })

-- natives: state bags, entities (props and vehicles), health, the shooter's weapon
Bags, EBags = {}, {}
function Player(src)
    Bags[src] = Bags[src] or {}
    local b = Bags[src]
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end
function Entity(e)
    EBags[e] = EBags[e] or {}
    local b = EBags[e]
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end
local Ents, Types, Headings, Seats, Health, Held = {}, {}, {}, {}, {}, {}
function CreateObjectNoOffset(model, x, y, z)
    Mock.nextNetId = Mock.nextNetId + 1
    local e = Mock.nextNetId
    Ents[e], Mock.coords[e], Mock.models[e] = true, vector3(x, y, z), model
    return e
end
function DoesEntityExist(e) return Ents[e] == true or Mock.players[e] ~= nil end
function DeleteEntity(e) Ents[e] = nil Mock.deleted[#Mock.deleted + 1] = e end
function GetEntityHeading(e) return Headings[e] or 0.0 end
function SetEntityHeading(e, h) Headings[e] = h end
function GetEntityType(e) return Types[e] or (Mock.players[e] and 1) or 3 end
function FreezeEntityPosition() end
function GetPedInVehicleSeat(veh, seat) return (Seats[veh] or {})[seat] or 0 end
function SetPedIntoVehicle(ped, veh, seat)
    Seats[veh] = Seats[veh] or {}
    Seats[veh][seat] = ped
    Mock.vehicleOf[ped] = veh
end
function SetEntityCoords(e, x, y, z)
    Mock.coords[e] = vector3(x, y, z)
    local veh = Mock.vehicleOf[e]
    if veh then
        Mock.vehicleOf[e] = nil
        for s, p in pairs(Seats[veh] or {}) do if p == e then Seats[veh][s] = nil end end
    end
end
function GetEntityHealth(ped) return Health[ped] or 200 end
function GetPedArmour() return 0 end
function GetEntityAttachedTo() return 0 end
function GetEntityVelocity() return vector3(0, 0, 0) end
function NetworkGetEntityOwner(e) return e end
function GetSelectedPedWeapon(p) return Held[p] or 0 end
function CancelEvent() end
function GetPlayers()
    local out = {}
    for src in pairs(Mock.players) do out[#out + 1] = tostring(src) end
    table.sort(out)
    return out
end
QBCoreMock.Commands.Add = function() end
QBCoreMock.Functions.HasPermission = function() return false end
QBCoreMock.Functions.GetPlayersByJob = function(job, onDuty)
    local out = {}
    for src, P in pairs(Mock.players) do
        local j = P.PlayerData.job or {}
        if (j.name == job or j.type == job) and (not onDuty or j.onduty) then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end

World.startBank()
MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('ambulance', 0, 'job', '[]') ON DUPLICATE KEY UPDATE account_balance = 0")
MySQL.query.await("INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES ('society:ambulance', 0)")
local Inv = World.inventory()
Mock.exportsByResource['pfm-inventory'].AddListener = function() return 1 end
Mock.exportsByResource['pfm-inventory'].SetItemData = function() return true end
QBCoreMock.Functions.HasItem = function(src, item, n) return Inv.count(src, item) >= (n or 1) end
Mock.exportsByResource['pfm-phone'] = { CreateInvoice = function() return 901 end, CancelInvoice = function() return true end }
Mock.exportsByResource['pf-services'] = { CreateRequest = function() return { ok = true, id = 1 } end, CloseByRef = function() return { ok = true } end,
    Emit = function() return 1 end, RegisterRequestHandler = function() return true end, RegisterRequestKind = function() return true end }

-- pfm-policejob: the evidence modules (the lab listens for projectiles recovered in surgery)
local PJ = { 'pfm-policejob/config.lua', 'pfm-policejob/config_evidence.lua', '@pfm-banking/payouts.lua', 'pfm-policejob/server/schema.lua',
    'pfm-policejob/server/commands.lua', 'pfm-policejob/server/evidence/store.lua', 'pfm-policejob/server/evidence/custody.lua',
    'pfm-policejob/server/evidence/scene.lua', 'pfm-policejob/server/evidence/api.lua', 'pfm-policejob/server/evidence/lab.lua' }
World.start('pfm-policejob', PJ, {
    before = function(env) env.QBCore = Mock.coreObject() end,
    boot = function(env)
        assert(env.PFPoliceSchema.Run(), 'police schema')
        assert(env.PFEvidence.Api.Start(), 'evidence start')
        env.PFEvidence.Custody.RegisterListeners()
    end,
})

-- pf-ambulancejob as its fxmanifest loads it
local AJ = '[pfscripts]/pf-ambulancejob/'
local AFILES = { AJ .. 'config.lua', AJ .. 'config_medical.lua', AJ .. 'config_ems.lua', AJ .. 'config_hospital.lua', AJ .. 'shared/framework.lua' }
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'mechanisms', 'findings', 'treatments' }) do
    AFILES[#AFILES + 1] = AJ .. 'shared/medical/' .. f .. '.lua'
end
AFILES[#AFILES + 1] = '@pfm-banking/payouts.lua'
AFILES[#AFILES + 1] = '@pfm-core/server/migrations.lua'
for _, f in ipairs({ 'main', 'injury_database', 'medical/schema', 'medical/store', 'medical/engine', 'medical/downstate', 'medical/ingest',
    'medical/legacy_import', 'medical/effects', 'medical/api', 'medical/diagnosis', 'medical/exam', 'medical/treatment', 'medical/recovery',
    'items', 'ems/equipment', 'ems/monitor', 'hospital/facility', 'hospital/admissions', 'hospital/beds', 'hospital/billing', 'hospital/ai_care',
    'hospital/custody', 'hospital/pharmacy', 'hospital/lab', 'hospital/imaging', 'hospital/surgery', 'hospital/morgue', 'hospital/supplies',
    'ems/fleet', 'injury_handler', 'treatment' }) do
    AFILES[#AFILES + 1] = AJ .. 'server/' .. f .. '.lua'
end
World.start('pf-ambulancejob', AFILES, {
    before = function(env) env.Lang = Lang end,
    boot = function(env)
        env.Config.WipeInventoryOnRespawn = false
        local M, H = env.PFMed, env.PFHospital
        -- determinism (the rolls), not behaviour: every roll in the middle
        M.Engine.Random = function() return 0.5 end
        M.Ingest.Random = function() return 0.5 end
        M.Diagnosis.Random = function() return 0 end   -- every sign that can be found is found
        M.Treat.Random = function() return 0.99 end
        assert(M.Schema.Start(), 'medical tables')
        assert(H.Admissions.Start(), 'hospital ready')
        H.Pharmacy.Start()
        assert(H.Stays.Start(os.time()), 'stays ready')
        H.Imaging.WaitFor = function() end
        H.Surgery.WaitFor = function() end
        H.Orders.Recover()
        env.PFEms.Boot()
    end,
})
local function AJenv() return World.env('pf-ambulancejob') end
local function M() return AJenv().PFMed end
local function H() return AJenv().PFHospital end
local HC = AJenv().Config.Hospital

local PATIENT, SHOOTER, MEDIC, DOC = 1, 2, 3, 4
local PAT = 'B22PAT'
local RIG = 500
local PISTOL = joaat('WEAPON_PISTOL')
local function person(src, cid, job)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = 50000 }
    p.PlayerData.metadata.injail = 0
    p.PlayerData.metadata.bloodtype = 'O+'
    if job then p.PlayerData.job = job end
    TriggerEvent('QBCore:Server:PlayerLoaded', p)
    return p
end
person(PATIENT, PAT)
person(SHOOTER, 'B22SHOOT')
person(MEDIC, 'B22MEDIC', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 1 } })
person(DOC, 'B22DOC', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 3 } })
local STREET = vector3(150.0, -1000.0, 29.3)
Mock.coords[PATIENT], Mock.coords[SHOOTER], Mock.coords[MEDIC], Mock.coords[DOC] = STREET, vector3(160.0, -1000.0, 29.3),
    vector3(151.0, -1000.0, 29.3), vector3(HC.Facilities.pillbox.reception.coords.x, HC.Facilities.pillbox.reception.coords.y, HC.Facilities.pillbox.reception.coords.z)

local function cb(name, src, ...) return Mock.callCallback('pf-ambulancejob:server:' .. name, src, ...) end
local function equip(src, action, args)
    Mock.clock = Mock.clock + 1
    return AJenv().PFEms.Handle(src, action, args)
end
local function bedPos(id)
    for _, d in pairs(HC.Facilities.pillbox.departments) do for _, b in ipairs(d.beds) do if b.id == id then return vector3(b.coords.x, b.coords.y, b.coords.z) end end end
end
local function vec(c) return vector3(c.x, c.y, c.z) end
local T = 500000 -- game timer (ms) the ingest samplers read

local gsw, admissionId
describe('22A flow 1: shooting -> injuries -> EMS -> rig -> hospital -> surgery -> discharge -> bill', function()
    it('the server sees the shot (attacker event + health drop + capped bone hint): a retained gunshot in the left thigh', function()
        local Ing = M().Ingest
        Ing.SampleBody(T)
        Held[SHOOTER] = PISTOL
        Ing.OnWeaponDamage(SHOOTER, { weaponType = PISTOL, hitGlobalId = PATIENT }, T)
        Health[PATIENT] = 150
        Ing.SampleBody(T + 50)
        Ing.OnHint(PATIENT, { seq = 1, weapon = PISTOL, bone = 58271 }, T + 60)
        Ing.ResolveDue(T + 3000)
        local open = {}
        for _, inj in pairs(M().Store.Peek(PAT).injuries) do if inj.stage ~= 'recovered' then open[#open + 1] = inj end end
        assert_eq(#open, 1)
        gsw = open[1]
        assert_eq(gsw.type, 'gunshot')
        assert_eq(gsw.subtype, 'retained')
        assert_eq(gsw.region, 'thigh_l')
        assert_eq(gsw.source_attacker_cid, 'B22SHOOT', 'the shooter the server saw holding the pistol')
        -- the same episode again changes nothing (its key)
        Ing.ResolveDue(T + 6000)
        local n = 0
        for _ in pairs(M().Store.Peek(PAT).injuries) do n = n + 1 end
        assert_eq(n, 1)
    end)

    it('the medic examines (server findings only) and dresses the wound with a dressing taken from the pockets', function()
        local ex = cb('exam', MEDIC, PATIENT, 'look')
        assert_true(ex.ok, tostring(ex.error) .. ' ' .. tostring(ex.message))
        assert_true(#ex.findings >= 1, 'the wound is seen')
        assert_false(cb('treat', MEDIC, { target = PATIENT, action = 'pressure_dressing', region = 'thigh_l', req = 'b22-t0' }).ok, 'no dressing held')
        Inv.add(MEDIC, 'pressure_dressing', 2)
        Mock.clock = Mock.clock + 5
        local tx = cb('treat', MEDIC, { target = PATIENT, action = 'pressure_dressing', region = 'thigh_l', req = 'b22-t1' })
        assert_true(tx.ok, tostring(tx.error) .. ' ' .. tostring(tx.message))
        assert_eq(Inv.count(MEDIC, 'pressure_dressing'), 1, 'one used, on the server')
        Mock.clock = Mock.clock + 5
        local again = cb('treat', MEDIC, { target = PATIENT, action = 'pressure_dressing', region = 'thigh_l', req = 'b22-t1' })
        assert_eq(Inv.count(MEDIC, 'pressure_dressing'), 1, 'the same request id is not a second dressing (' .. tostring(again.error) .. ')')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_med_treatments WHERE citizenid = ? AND action = 'pressure_dressing'", { PAT }), 1)
    end)

    it('stretcher, rig, drive, unload at Pillbox (server-spawned, server-seated)', function()
        Ents[RIG], Types[RIG], Mock.models[RIG], Mock.plates[RIG] = true, 2, GetHashKey('ambulance'), 'EMS 22'
        Mock.coords[RIG] = vector3(STREET.x, STREET.y + 6.0, STREET.z)
        Mock.coords[MEDIC] = vector3(STREET.x, STREET.y + 1.5, STREET.z)
        Mock.coords[PATIENT] = vector3(STREET.x + 0.5, STREET.y + 0.5, STREET.z)
        local s = equip(MEDIC, 'spawn_stretcher', { rig = RIG })
        assert_true(s.ok, 'spawn: ' .. tostring(s.error) .. ' ' .. tostring(s.message))
        Mock.coords[s.net] = Mock.coords[PATIENT]
        local p = equip(MEDIC, 'place_patient', { entity = s.net, target = PATIENT })
        assert_true(p.ok, 'place: ' .. tostring(p.error) .. ' ' .. tostring(p.message))
        local l = equip(MEDIC, 'load', { entity = s.net, rig = RIG })
        assert_true(l.ok, 'load: ' .. tostring(l.error) .. ' ' .. tostring(l.message))
        assert_eq(Mock.vehicleOf[PATIENT], RIG)
        -- the drive to Pillbox
        local front = HC.Facilities.pillbox.reception.coords
        Mock.coords[RIG] = vector3(front.x, front.y + 8.0, front.z)
        Mock.coords[MEDIC] = vector3(front.x, front.y + 3.5, front.z)
        local u = equip(MEDIC, 'unload', { rig = RIG })
        assert_true(u.ok, 'unload: ' .. tostring(u.error) .. ' ' .. tostring(u.message))
        assert_eq(Mock.vehicleOf[PATIENT], nil)
        assert_eq(Bags[PATIENT]['pf:onStretcher'], u.net)
        Mock.coords[MEDIC] = Mock.coords[PATIENT]
        local off = equip(MEDIC, 'take_patient', { entity = u.net })
        assert_true(off.ok, 'off the stretcher: ' .. tostring(off.error) .. ' ' .. tostring(off.message))
        M().Store.Flush()
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_med_events WHERE citizenid = ? AND action = 'equip_load'", { PAT }), 1, 'loaded once')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_med_events WHERE citizenid = ? AND action = 'equip_unload'", { PAT }), 1, 'unloaded once')
    end)

    it('check-in at reception, triage and admission to the ward imaging bed; pf-ambulancejob restarts', function()
        Mock.coords[PATIENT] = vec(HC.Facilities.pillbox.reception.coords)
        local ci = cb('checkIn', PATIENT, 'pillbox')
        assert_true(ci.ok, 'check-in: ' .. tostring(ci.message))
        admissionId = ci.admissionId
        Mock.clock = Mock.clock + 5
        assert_true(cb('triage', DOC, admissionId, 'orange').ok)
        Mock.coords[DOC], Mock.coords[PATIENT] = bedPos('w3'), bedPos('w3')
        Mock.clock = Mock.clock + 5
        local ad = cb('admit', DOC, admissionId, 'ward', 'w3')
        assert_true(ad.ok, 'admit: ' .. tostring(ad.message))
        World.restart('pf-ambulancejob')
        local row = World.one('SELECT * FROM pf_hosp_admissions WHERE id = ?', { admissionId })
        assert_eq(row.state, 'admitted')
        assert_eq(row.bed_id, 'w3')
        assert_eq(World.scalar('SELECT COUNT(*) FROM pf_hosp_admissions WHERE citizenid = ?', { PAT }), 1)
        -- the injury and its dressing are still there after the restart
        local inj = M().Store.Peek(PAT) and M().Store.Peek(PAT).injuries[gsw.id]
        if not inj then M().Store.Get(PAT) inj = M().Store.Peek(PAT).injuries[gsw.id] end
        assert_true(inj ~= nil and inj.treatments ~= nil and inj.treatments.pressure_dressing ~= nil, 'dressing kept')
    end)

    it('the x-ray confirms the retained projectile; surgery in the OR recovers it into the police surgery locker once', function()
        Mock.clock = Mock.clock + 10
        local img = cb('imagingOrder', DOC, PATIENT, 'xray')
        assert_true(img.ok, 'imaging order: ' .. tostring(img.message))
        Mock.clock = Mock.clock + 3
        local scan = cb('imagingPerform', DOC, img.orderId)
        assert_true(scan.ok, 'imaging: ' .. tostring(scan.message))
        Mock.coords[DOC], Mock.coords[PATIENT] = bedPos('ed1'), bedPos('ed1')
        Mock.clock = Mock.clock + 3
        assert_true(cb('admit', DOC, admissionId, 'ed', 'ed1').ok, 'to the trauma bay')
        Mock.coords[DOC] = AJenv().Config.Hospital.Surgery.Rooms[1].coords
        Mock.clock = Mock.clock + 3
        local op = cb('surgery', DOC, PATIENT, gsw.id, 'surgery_trauma')
        assert_true(op.ok, 'surgery: ' .. tostring(op.error) .. ' ' .. tostring(op.message))
        assert_true(op.projectileRecovered)
        local key = 'pf-ambulancejob:projectile:' .. tostring(gsw.id)
        local ev = World.one('SELECT * FROM pf_evidence_items WHERE idem_key = ?', { key })
        assert_true(ev ~= nil, 'pfm-policejob recorded the projectile as evidence')
        assert_eq(ev.kind, 'projectile')
        local attrs = json.decode(ev.attrs or '{}') or {}
        assert_eq(attrs.caliber, 'SMALL_CALIBER')
        assert_eq(tonumber(attrs.weaponHash), PISTOL)
        assert_true(World.scalar('SELECT COUNT(*) FROM pf_evidence_custody WHERE evidence_id = ?', { ev.id }) >= 1, 'a custody row from the start')
        assert_eq(Inv.count('evl:pillbox:surgery', 'evidence_bag') + Inv.total('evl:pillbox:surgery') > 0, true, 'sealed into the surgery locker')
    end)

    it('restarts after the surgery: no second operation, no second projectile', function()
        World.restart('pfm-policejob')
        World.restart('pf-ambulancejob')
        Mock.clock = Mock.clock + 5
        assert_eq(cb('surgery', DOC, PATIENT, gsw.id, 'surgery_trauma').error, 'invalid_state', 'operated once')
        assert_eq(World.scalar('SELECT COUNT(*) FROM pf_evidence_items WHERE idem_key = ?', { 'pf-ambulancejob:projectile:' .. tostring(gsw.id) }), 1)
        -- the event raised again (a retry anywhere) is the same evidence
        World.as('pf-ambulancejob', TriggerEvent, 'pf-ambulancejob:server:projectileRecovered', PAT,
            { injuryId = gsw.id, caliber = 'SMALL_CALIBER', weaponHash = PISTOL })
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_evidence_items WHERE kind = 'projectile'"), 1)
    end)

    it('discharge makes one keyed bill, paid once from the bank to society:ambulance; a restart charges nothing more', function()
        local bank0 = Mock.players[PATIENT].PlayerData.money.bank
        local soc0 = World.society('ambulance')
        Mock.clock = Mock.clock + 1800
        Mock.coords[DOC] = bedPos('ed1')
        local d = cb('discharge', DOC, admissionId, {})
        assert_true(d.ok, 'discharge: ' .. tostring(d.message))
        local bill = World.one('SELECT * FROM pf_hosp_bills WHERE admission_id = ?', { admissionId })
        assert_true(bill ~= nil, 'a bill')
        assert_eq(bill.state, 'paid')
        local due = tonumber(bill.total) - tonumber(bill.discount)
        assert_true(due > 0)
        local txs = World.txLike('pf-ambulancejob:bill:' .. bill.id .. ':%')
        assert_eq(#txs, 1)
        assert_eq(txs[1].to_account, 'society:ambulance')
        assert_eq(Mock.players[PATIENT].PlayerData.money.bank, bank0 - due)
        assert_eq(World.society('ambulance'), soc0 + due)
        -- the surgery, the x-ray and the check-in are on that one bill
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_hosp_orders WHERE admission_id = ? AND bill_id = ?", { admissionId, bill.id }), 2)
        Mock.clock = Mock.clock + 10
        assert_false(cb('discharge', DOC, admissionId, {}).ok, 'a closed admission is not discharged again')
        World.restart('pf-ambulancejob')
        Mock.clock = Mock.clock + 600
        if H().Billing and H().Billing.Tick then H().Billing.Tick(os.time()) end
        assert_eq(World.scalar('SELECT COUNT(*) FROM pf_hosp_bills WHERE admission_id = ?', { admissionId }), 1)
        assert_eq(#World.txLike('pf-ambulancejob:bill:%'), 1)
        assert_eq(Mock.players[PATIENT].PlayerData.money.bank, bank0 - due, 'charged once')
    end)
end)
