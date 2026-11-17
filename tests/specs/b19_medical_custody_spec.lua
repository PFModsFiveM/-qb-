-- pf-ambulancejob medical care in custody (batch 19G): the prison infirmary as a hospital
-- department (inmate visits, beds from the old jailbeds), intake and staff screening, prescriptions
-- dispensed from the infirmary stock stash, escorted hospital transfers with custody continuity
-- (pf-justice TransferCustody / ReturnCustody, escort officer within 15 m from server positions,
-- leaving the grounds / an absent escort / offline reported and never punished: no left AMA),
-- AdmitPatient with a custodyRef, SetCustodyCare and the privacy-safe status for corrections staff.
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
Health = {}
function GetEntityHealth(ped) return Health[ped] or 200 end
function GetPedArmour() return 0 end
function GetEntityAttachedTo() return 0 end
Placed = {}
function SetEntityCoords(ped, x, y, z) Placed[#Placed + 1] = { ped = ped, x = x, y = y, z = z } end
STARTED = { ['pf-justice'] = true }
function GetResourceState(res) return STARTED[res] and 'started' or 'missing' end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.HasItem = function() return true end
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

-- pf-justice as built (15C): custody records and incarceration orders, recording every call
JU = {}
local function juReset()
    JU = { custody = {}, orders = {}, calls = {}, refuse = {} }
end
local function juCall(name, args) JU.calls[#JU.calls + 1] = { name = name, args = args } end
function JuCalls(name)
    local out = {}
    for _, c in ipairs(JU.calls) do if c.name == name then out[#out + 1] = c end end
    return out
end
Mock.exportsByResource['pf-justice'] = {
    GetCustody = function(_, who)
        local c = JU.custody[who]
        if not c then return { ok = true } end
        return { ok = true, custody = { id = c.id, state = c.state, facility = c.facility, closedAt = c.closedAt } }
    end,
    IsIncarcerated = function(_, who)
        local o = JU.orders[who]
        if not o then return false end
        return true, o.id, o.facility
    end,
    TransferCustody = function(_, id, to, opts)
        juCall('TransferCustody', { id = id, to = to, opts = opts })
        if JU.refuse.TransferCustody then return { ok = false, error = 'invalid_state', message = 'refused' } end
        for _, c in pairs(JU.custody) do if c.id == id then c.prev, c.state = c.state, 'hospital' end end
        return { ok = true }
    end,
    ReturnCustody = function(_, id, opts)
        juCall('ReturnCustody', { id = id, opts = opts })
        if JU.refuse.ReturnCustody then return { ok = false, error = 'busy' } end
        for _, c in pairs(JU.custody) do if c.id == id and c.state == 'hospital' then c.state = c.prev end end
        return { ok = true }
    end,
    AddCustodyLog = function(_, id, kind, data, opts)
        juCall('AddCustodyLog', { id = id, kind = kind, data = data, opts = opts })
        return { ok = true, logId = #JU.calls }
    end,
}

-- pfm-inventory: the infirmary stash and the players' pockets
Stash, Pockets, Full, Opened = {}, {}, {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, id, item, amount)
        amount = amount or 1
        if type(id) == 'string' then
            local s = Stash[id] or {}
            if (s[item] or 0) < amount then return false end
            s[item] = s[item] - amount
            return true
        end
        return true
    end,
    AddItem = function(_, id, item, amount)
        amount = amount or 1
        if type(id) == 'string' then
            Stash[id] = Stash[id] or {}
            Stash[id][item] = (Stash[id][item] or 0) + amount
            return true
        end
        if Full[id] then return false end
        Pockets[id] = Pockets[id] or {}
        Pockets[id][item] = (Pockets[id][item] or 0) + amount
        return true
    end,
    CreateInventory = function(_, id) Stash[id] = Stash[id] or {} end,
    OpenInventory = function(_, src, id) Opened[#Opened + 1] = { src = src, id = id } end,
}

local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end

-- in-memory tables (the SQL itself runs in b19_medical_custody_realdb_spec)
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
    if Q.ReadRestrictions then Q.ReadRestrictions = function() return copy(DB.restrictions) end end

    local S = PFHospital.SQL
    S.InsertAdmission = function(r) DB.nextAdm = DB.nextAdm + 1; local row = copy(r); row.id = DB.nextAdm; DB.adm[row.id] = row; return row.id end
    S.FindAdmissionByKey = function(key) for _, r in pairs(DB.adm) do if r.idem_key == key then return copy(r) end end end
    S.GetAdmission = function(id) return copy(DB.adm[id]) end
    S.LoadOpenAdmissions = function()
        local out = {}
        for _, r in pairs(DB.adm) do if PFHospital.Admissions.OPEN[r.state] then out[#out + 1] = copy(r) end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    S.MoveAdmission = function(id, from, row)
        local r = DB.adm[id]
        if not r or r.state ~= from then return 0 end
        for k, v in pairs(row) do r[k] = v end
        for _, k in ipairs({ 'bed_id', 'triage', 'dept' }) do if row[k] == nil then r[k] = nil end end
        return 1
    end
    S.InsertRestriction = function(r) DB.restrictions[#DB.restrictions + 1] = copy(r) return #DB.restrictions end
    S.MarkStaff = function() return 1 end
    S.FindBillByAdmission = function(id) for _, b in pairs(DB.bills) do if b.admission_id == id then return copy(b) end end end
    S.InsertBill = function(r) DB.nextBill = DB.nextBill + 1; local b = copy(r); b.id = DB.nextBill; b.attempt = 0; DB.bills[b.id] = b; return b.id end
    S.InsertBillLines = function() return true end
    S.GetBill = function(id) return copy(DB.bills[id]) end
    S.MoveBill = function() return 0 end
    S.TreatmentsFor = function() return {} end

    -- 19G
    S.InsertCare = function(r)
        for _, c in pairs(DB.care) do if c.active_cid == r.citizenid then error('Duplicate entry for key uq_med_cc_active') end end
        DB.nextCare = DB.nextCare + 1
        local row = copy(r); row.id = DB.nextCare; row.active_cid = r.citizenid; row.state = 'active'
        DB.care[row.id] = row
        return row.id
    end
    S.FindCareByKey = function(key) for _, c in pairs(DB.care) do if key and c.idem_key == key then return copy(c) end end end
    S.ActiveCareOf = function(cid) for _, c in pairs(DB.care) do if c.active_cid == cid then return copy(c) end end end
    S.LoadActiveCare = function()
        local out = {}
        for _, c in pairs(DB.care) do if c.active_cid then out[#out + 1] = copy(c) end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    S.UpdateCare = function(id, r)
        local c = DB.care[id]
        if not c or not c.active_cid then return 0 end
        for _, k in ipairs({ 'kind', 'custody_id', 'order_id', 'facility', 'admission_id', 'hospital_id', 'escort_cid', 'ju_transfer' }) do c[k] = r[k] end
        return 1
    end
    S.CloseCare = function(id, state, reason, at)
        local c = DB.care[id]
        if not c or not c.active_cid then return 0 end
        c.state, c.close_reason, c.closed_at, c.active_cid = state, reason, at, nil
        return 1
    end
    S.SetAdmissionCustody = function(id, ref, escort)
        local r = DB.adm[id]
        if not r then return 0 end
        r.custody_ref, r.escort_cid = ref, escort
        return 1
    end
    S.InsertCareReport = function(r) DB.reports[#DB.reports + 1] = copy(r) return #DB.reports end
    S.InsertScreening = function(r)
        if r.idem_key then for _, s in ipairs(DB.scr) do if s.idem_key == r.idem_key then error('Duplicate entry') end end end
        local row = copy(r); row.id = #DB.scr + 1
        row.fit_for_work, row.infirmary_needed = r.fit_for_work and 1 or 0, r.infirmary_needed and 1 or 0
        DB.scr[#DB.scr + 1] = row
        return row.id
    end
    S.FindScreeningByKey = function(key) for _, s in ipairs(DB.scr) do if s.idem_key == key then return copy(s) end end end
    S.LatestScreening = function(cid, since)
        local best
        for _, s in ipairs(DB.scr) do if s.citizenid == cid and s.at >= since and (not best or s.at >= best.at) then best = s end end
        return copy(best)
    end
    S.InsertRx = function(r)
        local row = copy(r); row.id = #DB.rx + 1; row.state = 'active'; row.dispensed = 0
        DB.rx[#DB.rx + 1] = row
        return row.id
    end
    S.GetRx = function(id) return copy(DB.rx[id]) end
    S.ActiveRx = function(cid, at)
        local out = {}
        for _, r in ipairs(DB.rx) do if r.citizenid == cid and r.state == 'active' and r.expires_at > at then out[#out + 1] = copy(r) end end
        return out
    end
    S.ReserveDose = function(id, dispensed, at)
        local r = DB.rx[id]
        if not r or r.state ~= 'active' or r.dispensed ~= dispensed then return 0 end
        if r.dispensed + 1 >= r.qty then r.state = 'filled' end
        r.dispensed, r.last_dispensed_at = r.dispensed + 1, at
        return 1
    end
    S.UndoDose = function(id, after, prev)
        local r = DB.rx[id]
        if not r or r.dispensed ~= after then return 0 end
        r.state, r.dispensed, r.last_dispensed_at = 'active', r.dispensed - 1, prev
        return 1
    end
    S.InsertDispense = function(r)
        for _, d in pairs(DB.disp) do if d.idem_key == r.idem_key then error('Duplicate entry') end end
        DB.disp[r.idem_key] = copy(r)
        return 1
    end
    S.DeleteDispense = function(key) local had = DB.disp[key] ~= nil; DB.disp[key] = nil; return had and 1 or 0 end
    S.CancelRx = function(id) local r = DB.rx[id]; if r and r.state == 'active' then r.state = 'cancelled' return 1 end return 0 end
    S.ExpireRx = function() return 0 end
end

local AJ = '[pfscripts]/pf-ambulancejob/'
local FILES = { AJ .. 'config.lua', AJ .. 'config_medical.lua', AJ .. 'config_hospital.lua', AJ .. 'shared/framework.lua' }
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model' }) do FILES[#FILES + 1] = AJ .. 'shared/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/main.lua'
for _, f in ipairs({ 'schema', 'store', 'engine', 'downstate', 'effects', 'api' }) do FILES[#FILES + 1] = AJ .. 'server/medical/' .. f .. '.lua' end
for _, f in ipairs({ 'facility', 'beds', 'admissions', 'billing', 'ai_care', 'custody' }) do FILES[#FILES + 1] = AJ .. 'server/hospital/' .. f .. '.lua' end

local H, C
local function boot()
    Mock.eventHandlers, Mock.netHandlers, Mock.netHandlerList, Mock.callbacks = {}, {}, {}, {}
    PFMed, PFEmsRequests, PFHospital, RespawnPlayer = nil, nil, nil, nil
    LedgerEnv.load('pf-ambulancejob', FILES)
    installFakeSQL()
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    H = PFHospital
    C = H.Custody
    QBCore = QBCoreMock
    assert(PFMed.Schema.Start(), 'schema ready')
    assert(H.Admissions.Start(), 'hospital ready')
    assert(C.Start(), 'custody care ready')
end

local INMATE, MEDIC, OFFICER, CORR, DETAINEE, CIV, OFFICER2 = 1, 2, 3, 4, 5, 6, 7
local INFIRMARY = vector3(1766.9, 2594.8, 45.66)
local YARD = vector3(1700.0, 2560.0, 45.6)          -- inside the prison walls, outside the infirmary zone
local PILLBOX = vector3(330.0, -588.0, 43.3)
local STASH = 'pf_infirmary_bolingbroke'
local function online(src, cid)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = 5000 }
    p.PlayerData.metadata.injail = 0
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function job(src, name, grade, onduty, jtype)
    Mock.players[src].PlayerData.job = { name = name, type = jtype, onduty = onduty ~= false, grade = { level = grade or 0 } }
end
local function advance(s) Mock.clock = Mock.clock + s end
local function cb(name, src, ...) return Mock.callCallback('pf-ambulancejob:server:' .. name, src, ...) end
local function tick() H.Admissions.Tick(os.time()) end
local function reportsOf(kind)
    local out = {}
    for _, r in ipairs(DB.reports) do if r.kind == kind then out[#out + 1] = r end end
    return out
end
local function alerts(kind)
    local n = 0
    for _, e in ipairs(Mock.serverEvents) do
        if e.name == 'pf-ambulancejob:server:custodyCareAlert' and e.args[2] and e.args[2].kind == kind then n = n + 1 end
    end
    return n
end
local function careOf(cid) for _, c in pairs(DB.care) do if c.active_cid == cid then return c end end end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    Mock.invokingResource = nil
    Health, Bags, Placed, Stash, Pockets, Full, Opened = {}, {}, {}, {}, {}, {}, {}
    STARTED = { ['pf-justice'] = true }
    juReset()
    DB = { patients = {}, injuries = {}, events = {}, nextId = 0, adm = {}, nextAdm = 0, restrictions = {}, bills = {}, nextBill = 0,
        care = {}, nextCare = 0, reports = {}, scr = {}, rx = {}, disp = {} }
    FakeDB.society('ambulance', 0)
    boot()
    PFMed.Engine.Random = function() return 0.5 end
    H.AI.Random = function() return 0.99 end
    online(INMATE, 'INMATECID')
    online(MEDIC, 'MEDICCID')
    online(OFFICER, 'COPCID')
    online(CORR, 'CORRCID')
    online(DETAINEE, 'HELDCID')
    online(CIV, 'CIVCID')
    online(OFFICER2, 'COP2CID')
    job(MEDIC, 'ambulance', 2, true, 'ems')
    job(OFFICER, 'police', 1, true, 'leo')
    job(CORR, 'corrections', 1, true, 'corrections')
    job(OFFICER2, 'police', 1, true, 'leo')
    JU.orders.INMATECID = { id = 41, facility = 'bolingbroke' }
    JU.custody.HELDCID = { id = 77, state = 'held', facility = 'mrpd_holding' }
    for src = 1, 7 do Mock.coords[src] = vector3(0.0 + src * 100, 0.0, 0.0) end
end

describe('schema v7 (custody care)', function()
    it('is the next version after 17E\'s v6 and creates the custody tables', function()
        -- v8 (batch 20 hospital services) follows; v7 stays the custody version
        local last
        for _, m in ipairs(PFMed.Schema.Migrations) do if m.version == 7 then last = m end end
        assert_eq(PFMed.Schema.Migrations[#PFMed.Schema.Migrations].version, 8)
        assert_eq(last.version, 7)
        assert_eq(last.name, 'custody care')
        local sql = table.concat(last.up, '\n')
        for _, t in ipairs({ 'pf_med_screenings', 'pf_med_custody_care', 'pf_med_custody_reports', 'pf_hosp_prescriptions', 'pf_hosp_dispense_log' }) do
            assert_true(sql:find(t, 1, true) ~= nil, t)
        end
        assert_true(sql:find('custody_ref', 1, true) ~= nil and sql:find('escort_cid', 1, true) ~= nil)
    end)
end)

describe('prison infirmary', function()
    it('an inmate in the infirmary gets an infirmary admission and custody care; others are refused', function()
        Mock.coords[INMATE] = YARD
        assert_eq(cb('infirmaryVisit', INMATE).error, 'too_far')
        Mock.coords[CIV] = INFIRMARY
        assert_eq(cb('infirmaryVisit', CIV).error, 'no_permission', 'only inmates')
        Mock.coords[INMATE] = INFIRMARY
        advance(6)
        local res = cb('infirmaryVisit', INMATE)
        assert_true(res.ok, tostring(res.message))
        local a = DB.adm[res.admissionId]
        assert_eq(a.hospital_id, 'bolingbroke')
        assert_eq(a.custody_ref, 'order:41')
        local care = careOf('INMATECID')
        assert_eq(care.kind, 'infirmary')
        assert_eq(care.admission_id, res.admissionId)
        advance(6)
        assert_true(cb('infirmaryVisit', INMATE).duplicate)
    end)

    it('beds come from the old jailbeds and the staff admit works there', function()
        local beds = Config.Hospital.Facilities.bolingbroke.departments.infirmary.beds
        assert_eq(#beds, 4)
        Mock.coords[INMATE] = INFIRMARY
        local id = cb('infirmaryVisit', INMATE).admissionId
        Mock.coords[MEDIC] = INFIRMARY
        local res = cb('admit', MEDIC, id, 'infirmary')
        assert_true(res.ok, tostring(res.message))
        assert_eq(DB.adm[id].bed_id, 'i1')
    end)

    it('walking out of the infirmary is reported, never left AMA; the bed is freed later as a discharge', function()
        Mock.coords[INMATE] = INFIRMARY
        local id = cb('infirmaryVisit', INMATE).admissionId
        tick()
        Mock.coords[INMATE] = YARD
        tick()
        advance(Config.Hospital.Custody.LeaveGraceSeconds)
        tick()
        assert_eq(#reportsOf('left_infirmary'), 1)
        advance(120) -- past the 60 s left-AMA grace of the hospital
        tick()
        assert_eq(DB.adm[id].state, 'checked_in', 'still open: a custody patient cannot leave AMA')
        assert_eq(#reportsOf('left_infirmary'), 1, 'reported once per excursion')
        advance(Config.Hospital.Custody.InfirmaryLeaveCloseSeconds)
        tick()
        assert_eq(DB.adm[id].state, 'discharged')
        assert_eq(DB.adm[id].bed_id, nil)
        assert_eq(careOf('INMATECID'), nil, 'the care ended')
    end)

    it('care in custody is not billed to the inmate', function()
        Mock.coords[INMATE] = INFIRMARY
        local id = cb('infirmaryVisit', INMATE).admissionId
        Mock.coords[MEDIC] = INFIRMARY
        cb('admit', MEDIC, id, 'infirmary')
        advance(7200)
        assert_true(cb('discharge', MEDIC, id, {}).ok)
        assert_eq(DB.nextBill, 0)
    end)
end)

describe('escorted hospital transfer', function()
    local function transfer()
        Mock.coords[DETAINEE] = vector3(460.0, -995.0, 24.9)
        Mock.coords[OFFICER] = vector3(470.0, -995.0, 24.9) -- 10 m
        return cb('custodyTransfer', OFFICER, DETAINEE, 'pillbox')
    end

    it('needs an on-duty officer within 15 m (server positions) and moves the custody record first', function()
        Mock.coords[DETAINEE] = vector3(460.0, -995.0, 24.9)
        Mock.coords[OFFICER] = vector3(480.0, -995.0, 24.9) -- 20 m
        assert_eq(cb('custodyTransfer', OFFICER, DETAINEE, 'pillbox').error, 'too_far')
        advance(3)
        Mock.coords[CIV] = vector3(461.0, -995.0, 24.9)
        assert_eq(cb('custodyTransfer', CIV, DETAINEE, 'pillbox').error, 'no_permission')
        assert_eq(#JuCalls('TransferCustody'), 0)
        advance(3)
        local res = transfer()
        assert_true(res.ok, tostring(res.message))
        local t = JuCalls('TransferCustody')
        assert_eq(#t, 1)
        assert_eq(t[1].args.id, 77)
        assert_eq(t[1].args.to.kind, 'hospital')
        assert_eq(t[1].args.to.id, 'pillbox')
        assert_eq(t[1].args.opts.actor.src, OFFICER)
        local a = DB.adm[res.admissionId]
        assert_eq(a.hospital_id, 'pillbox')
        assert_eq(a.state, 'waiting')
        assert_eq(a.custody_ref, 'custody:77')
        assert_eq(a.escort_cid, 'COPCID')
        assert_eq(careOf('HELDCID').escort_cid, 'COPCID')
        assert_eq(JU.custody.HELDCID.state, 'hospital')
    end)

    it('a refused custody move creates no admission', function()
        JU.refuse.TransferCustody = true
        local res = transfer()
        assert_false(res.ok)
        assert_eq(DB.nextAdm, 0)
        assert_eq(careOf('HELDCID'), nil)
    end)

    it('an absent escort and leaving the grounds are reported, never punished; the admission stays open', function()
        local id = transfer().admissionId
        Mock.coords[DETAINEE] = PILLBOX
        Mock.coords[OFFICER] = PILLBOX
        tick()
        Mock.coords[OFFICER] = vector3(330.0, -560.0, 43.3) -- 28 m away
        tick()
        advance(Config.Hospital.Custody.EscortGraceSeconds)
        tick()
        assert_eq(#reportsOf('escort_away'), 1)
        assert_eq(alerts('escort_away'), 1)
        local logs = JuCalls('AddCustodyLog')
        assert_eq(logs[#logs].args.kind, 'note')
        assert_eq(logs[#logs].args.data.event, 'escort_away')
        Mock.coords[OFFICER] = PILLBOX
        tick()
        assert_eq(#reportsOf('escort_back'), 1)
        -- the patient walks off the grounds
        Mock.coords[DETAINEE] = vector3(500.0, -588.0, 43.3)
        Mock.coords[OFFICER] = vector3(505.0, -588.0, 43.3)
        tick()
        advance(Config.Hospital.Custody.LeaveGraceSeconds)
        tick()
        assert_eq(#reportsOf('left_zone'), 1)
        advance(600)
        tick()
        assert_eq(DB.adm[id].state, 'waiting', 'no left AMA for a custody patient')
        assert_eq(JU.custody.HELDCID.state, 'hospital', 'custody unchanged: reported only')
        assert_eq(#JuCalls('ReturnCustody'), 0)
        Mock.coords[DETAINEE] = PILLBOX
        tick()
        assert_eq(#reportsOf('returned_zone'), 1)
    end)

    it('another officer within 15 m takes over the escort', function()
        transfer()
        Mock.coords[DETAINEE] = PILLBOX
        Mock.coords[OFFICER2] = vector3(340.0, -588.0, 43.3)
        local res = cb('custodyEscort', OFFICER2, DETAINEE)
        assert_true(res.ok, tostring(res.message))
        assert_eq(careOf('HELDCID').escort_cid, 'COP2CID')
        Mock.coords[CORR] = vector3(390.0, -588.0, 43.3)
        assert_eq(cb('custodyEscort', CORR, DETAINEE).error, 'too_far')
    end)

    it('offline does not close the admission; a reconnect without a bed is placed at the hospital', function()
        local id = transfer().admissionId
        local p = Mock.players[DETAINEE]
        Mock.players[DETAINEE] = nil
        tick()
        advance(Config.Hospital.Intake.OfflineGraceSeconds + 60)
        tick()
        assert_eq(DB.adm[id].state, 'waiting')
        assert_eq(#reportsOf('patient_offline'), 1)
        Mock.players[DETAINEE] = p
        Placed = {}
        Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
        assert_eq(#Placed, 1)
        local rp = Config.Hospital.Facilities.pillbox.respawnPoint
        assert_near(Placed[1].x, rp.x, 0.01)
    end)

    it('a discharge returns the custody record (ReturnCustody with the escort) and ends the care', function()
        local id = transfer().admissionId
        Mock.coords[DETAINEE] = PILLBOX
        Mock.coords[OFFICER] = PILLBOX
        Mock.coords[MEDIC] = PILLBOX
        tick()
        local res = cb('discharge', MEDIC, id, {})
        assert_true(res.ok, tostring(res.message))
        local r = JuCalls('ReturnCustody')
        assert_eq(#r, 1)
        assert_eq(r[1].args.id, 77)
        assert_eq(r[1].args.opts.actor.src, OFFICER)
        assert_eq(JU.custody.HELDCID.state, 'held')
        assert_eq(careOf('HELDCID'), nil)
        assert_eq(DB.care[1].state, 'returned')
        assert_eq(#reportsOf('discharged_no_escort'), 0)
    end)

    it('a refused return keeps the care and the tick retries it', function()
        local id = transfer().admissionId
        Mock.coords[DETAINEE] = PILLBOX
        Mock.coords[MEDIC] = PILLBOX
        JU.refuse.ReturnCustody = true
        assert_true(cb('discharge', MEDIC, id, {}).ok)
        assert_true(careOf('HELDCID') ~= nil, 'still active')
        JU.refuse.ReturnCustody = false
        tick()
        assert_eq(careOf('HELDCID'), nil)
        assert_eq(JU.custody.HELDCID.state, 'held')
    end)

    it('the medic transfer of a custody patient needs an officer escort within 15 m', function()
        Mock.coords[INMATE] = INFIRMARY
        local id = cb('infirmaryVisit', INMATE).admissionId
        Mock.coords[MEDIC] = INFIRMARY
        Mock.coords[CORR] = vector3(1766.9, 2630.0, 45.66) -- 35 m
        local res = cb('transfer', MEDIC, id, { hospitalId = 'pillbox' })
        assert_eq(res.error, 'too_far')
        assert_eq(DB.adm[id].state, 'checked_in')
        Mock.coords[CORR] = vector3(1766.9, 2600.0, 45.66)
        advance(3)
        res = cb('transfer', MEDIC, id, { hospitalId = 'pillbox' })
        assert_true(res.ok, tostring(res.message))
        assert_eq(DB.adm[id].state, 'transferred')
        local new = DB.adm[res.admissionId]
        assert_eq(new.hospital_id, 'pillbox')
        assert_eq(new.escort_cid, 'CORRCID')
        local care = careOf('INMATECID')
        assert_eq(care.kind, 'transfer')
        assert_eq(care.admission_id, res.admissionId)
    end)

    it('a custody citizen admitted by another path (walk-in at reception) becomes a custody admission', function()
        Mock.coords[DETAINEE] = Config.Hospital.Facilities.pillbox.reception.coords
        local res = cb('checkIn', DETAINEE, 'pillbox')
        assert_true(res.ok, tostring(res.message))
        local t = JuCalls('TransferCustody')
        assert_eq(#t, 1)
        assert_eq(t[1].args.opts.actor, nil, 'system actor')
        assert_eq(DB.adm[res.admissionId].custody_ref, 'custody:77')
        assert_eq(careOf('HELDCID').kind, 'transfer')
    end)
end)

describe('exports', function()
    it('AdmitPatient accepts a custodyRef (17E refused it), with an escort for a public hospital', function()
        Mock.coords[DETAINEE] = vector3(460.0, -995.0, 24.9)
        Mock.coords[OFFICER] = vector3(465.0, -995.0, 24.9)
        Mock.invokingResource = 'pf-taxi'
        assert_eq(exports['pf-ambulancejob']:AdmitPatient('HELDCID', { hospitalId = 'pillbox', dept = 'ed', custodyRef = { custodyId = 77 } }, { key = 'k1' }).error, 'not_allowed')
        assert_eq(#JuCalls('TransferCustody'), 0, 'nothing moved for a refused caller')
        Mock.invokingResource = 'pf-justice'
        local res = exports['pf-ambulancejob']:AdmitPatient('HELDCID', { hospitalId = 'pillbox', dept = 'ed', custodyRef = { custodyId = 77 } }, { key = 'k1' })
        assert_eq(res.error, 'no_permission', 'no escort')
        res = exports['pf-ambulancejob']:AdmitPatient('HELDCID', { hospitalId = 'pillbox', dept = 'ed', custodyRef = { custodyId = 77 } }, { key = 'k1', escort = OFFICER })
        Mock.invokingResource = nil
        assert_true(res.ok, tostring(res.message))
        assert_eq(res.custodyRef, 'custody:77')
        assert_eq(DB.adm[res.admissionId].escort_cid, 'COPCID')
        assert_eq(JU.custody.HELDCID.state, 'hospital')
    end)

    it('AdmitPatient into the infirmary needs no escort', function()
        Mock.invokingResource = 'pfm-prison'
        local res = exports['pf-ambulancejob']:AdmitPatient('INMATECID', { hospitalId = 'bolingbroke', dept = 'infirmary', custodyRef = { orderId = 41, facility = 'bolingbroke' } },
            { key = 'pfm-prison:infirmary:1' })
        Mock.invokingResource = nil
        assert_true(res.ok, tostring(res.message))
        assert_eq(careOf('INMATECID').kind, 'infirmary')
        assert_eq(#JuCalls('TransferCustody'), 0)
    end)

    it('SetCustodyCare marks and clears; GetCustodyCare / IsInCustodyCare read it; callers are checked', function()
        Mock.invokingResource = 'pf-taxi'
        assert_eq(exports['pf-ambulancejob']:SetCustodyCare('HELDCID', { custodyId = 77 }).error, 'not_allowed')
        Mock.invokingResource = 'pf-justice'
        local res = exports['pf-ambulancejob']:SetCustodyCare('HELDCID', { custodyId = 77, facility = 'mrpd_holding' }, { key = 'ju:care:1' })
        assert_true(res.ok)
        assert_true(exports['pf-ambulancejob']:SetCustodyCare('HELDCID', { custodyId = 77 }, { key = 'ju:care:1' }).duplicate)
        local g = exports['pf-ambulancejob']:GetCustodyCare('HELDCID')
        assert_eq(g.care.custodyId, 77)
        assert_eq(g.care.kind, 'marked')
        Mock.invokingResource = 'pf-taxi'
        assert_true(exports['pf-ambulancejob']:IsInCustodyCare('HELDCID'))
        Mock.invokingResource = 'pf-justice'
        assert_true(exports['pf-ambulancejob']:SetCustodyCare('HELDCID', nil).ok)
        Mock.invokingResource = nil
        assert_false(exports['pf-ambulancejob']:IsInCustodyCare('HELDCID'))
        assert_eq(DB.care[1].state, 'cleared')
    end)
end)

describe('screening and privacy', function()
    it('an incarceration order at the prison screens the online inmate once (keyed)', function()
        Mock.fireEvent('pf-justice:server:orderCreated', nil, { id = 41, cid = 'INMATECID', kind = 'prison', facility = 'bolingbroke', state = 'pending' })
        Mock.fireEvent('pf-justice:server:orderCreated', nil, { id = 41, cid = 'INMATECID', kind = 'prison', facility = 'bolingbroke', state = 'pending' })
        assert_eq(#DB.scr, 1)
        assert_eq(DB.scr[1].context, 'prison_intake')
        assert_eq(DB.scr[1].idem_key, 'pf-ambulancejob:screen:intake:41')
        assert_eq(DB.scr[1].result, 'fit')
    end)

    it('staff screening hospital_required makes the inmate unfit and flags the infirmary; the note stays medical', function()
        Mock.coords[MEDIC] = vector3(100.0, 0.0, 0.0)
        Mock.coords[INMATE] = vector3(101.0, 0.0, 0.0)
        local res = cb('custodyScreen', MEDIC, INMATE, 'hospital_required', { { kind = 'no_heavy_work', hours = 24 } }, 'suspected fracture')
        assert_true(res.ok, tostring(res.message))
        assert_eq(DB.scr[1].note, 'suspected fracture')
        assert_eq(DB.restrictions[#DB.restrictions].kind, 'no_heavy_work')
        Mock.coords[CORR] = vector3(500.0, 0.0, 0.0)
        local v = cb('inmateMedical', CORR, INMATE)
        assert_true(v.ok)
        assert_false(v.fit_for_work)
        assert_true(v.infirmary_needed)
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        assert_eq(table.concat(keys, ','), 'cid,fit_for_work,infirmary_needed,ok,restrictions', 'nothing clinical')
    end)

    it('only on-duty officers see the safe status, and only for people in custody', function()
        assert_eq(cb('inmateMedical', CIV, INMATE).error, 'no_permission')
        job(CORR, 'corrections', 1, false, 'corrections')
        advance(2)
        assert_eq(cb('inmateMedical', CORR, INMATE).error, 'no_permission')
        advance(2)
        assert_eq(cb('inmateMedical', OFFICER, CIV).error, 'invalid_state')
        Mock.invokingResource = 'pfm-prison'
        local s = exports['pf-ambulancejob']:GetInmateMedicalStatus('INMATECID')
        Mock.invokingResource = 'pf-taxi'
        assert_eq(exports['pf-ambulancejob']:GetInmateMedicalStatus('INMATECID').error, 'not_allowed')
        Mock.invokingResource = nil
        assert_true(s.fit_for_work)
        assert_false(s.infirmary_needed)
    end)

    it('ScreenPatient export returns the disposition only and is keyed', function()
        Mock.invokingResource = 'pf-justice'
        local res = exports['pf-ambulancejob']:ScreenPatient('HELDCID', 'booking', { key = 'pf-justice:booking:9' })
        local again = exports['pf-ambulancejob']:ScreenPatient('HELDCID', 'booking', { key = 'pf-justice:booking:9' })
        local bad = exports['pf-ambulancejob']:ScreenPatient('HELDCID', 'spa', {})
        Mock.invokingResource = nil
        assert_true(res.ok)
        assert_eq(res.result, 'fit')
        assert_eq(res.note, nil)
        assert_true(again.duplicate)
        assert_eq(bad.error, 'bad_args')
        assert_eq(#DB.scr, 1)
    end)
end)

describe('prescriptions from the infirmary stock', function()
    local function prescribe(doses, hours)
        Mock.coords[MEDIC] = vector3(100.0, 0.0, 0.0)
        Mock.coords[INMATE] = vector3(101.0, 0.0, 0.0)
        return cb('custodyPrescribe', MEDIC, INMATE, 'painkillers', doses or 2, hours or 2, 'pain')
    end

    it('a physician prescribes for an inmate; scope and the formulary are checked', function()
        job(MEDIC, 'ambulance', 0, true, 'ems')
        assert_eq(prescribe().error, 'no_permission', 'tier 1 cannot prescribe')
        job(MEDIC, 'ambulance', 2, true, 'ems')
        advance(3)
        assert_eq(cb('custodyPrescribe', MEDIC, INMATE, 'cocaine', 1, 2).error, 'bad_args')
        advance(3)
        local res = prescribe()
        assert_true(res.ok, tostring(res.message))
        assert_eq(DB.rx[1].drug, 'painkillers')
        assert_eq(DB.rx[1].qty, 2)
        assert_eq(DB.rx[1].interval_seconds, 7200)
        assert_eq(DB.rx[1].custody_ref, 'order:41')
        advance(3)
        Mock.coords[CIV] = vector3(101.0, 0.0, 0.0)
        assert_eq(cb('custodyPrescribe', MEDIC, CIV, 'painkillers', 1, 2).error, 'invalid_state', 'inmates only')
    end)

    it('the inmate takes due doses from the stash in the infirmary only, at the interval, once per dose', function()
        prescribe(2, 2)
        Stash[STASH] = { painkillers = 5 }
        Mock.coords[INMATE] = YARD
        assert_eq(cb('custodyDose', INMATE).error, 'too_far')
        Mock.coords[INMATE] = INFIRMARY
        advance(4)
        local res = cb('custodyDose', INMATE)
        assert_true(res.ok, tostring(res.message))
        assert_eq(Stash[STASH].painkillers, 4)
        assert_eq(Pockets[INMATE].painkillers, 1)
        assert_true(DB.disp['pf-ambulancejob:rx:1:1'] ~= nil)
        advance(4)
        assert_eq(cb('custodyDose', INMATE).error, 'too_soon')
        assert_eq(Stash[STASH].painkillers, 4)
        advance(7200)
        assert_true(cb('custodyDose', INMATE).ok)
        assert_eq(DB.rx[1].state, 'filled')
        advance(7200)
        assert_eq(cb('custodyDose', INMATE).error, 'not_found')
        assert_eq(Pockets[INMATE].painkillers, 2)
    end)

    it('out of stock or full pockets give the dose back', function()
        prescribe(2, 2)
        Stash[STASH] = {}
        Mock.coords[INMATE] = INFIRMARY
        advance(4)
        assert_eq(cb('custodyDose', INMATE).error, 'conflict')
        assert_eq(DB.rx[1].dispensed, 0)
        assert_eq(DB.disp['pf-ambulancejob:rx:1:1'], nil)
        Stash[STASH] = { painkillers = 1 }
        Full[INMATE] = true
        advance(4)
        assert_eq(cb('custodyDose', INMATE).error, 'conflict')
        assert_eq(Stash[STASH].painkillers, 1, 'the item went back to the stash')
        assert_eq(DB.rx[1].dispensed, 0)
    end)

    it('a due prescription shows as infirmary_needed (no detail) to corrections', function()
        prescribe(2, 2)
        Mock.invokingResource = 'pfm-prison'
        local s = exports['pf-ambulancejob']:GetInmateMedicalStatus('INMATECID')
        Mock.invokingResource = nil
        assert_true(s.infirmary_needed)
        assert_eq(s.prescriptions, nil)
    end)

    it('staff in the infirmary open the stock stash; others cannot', function()
        Mock.coords[MEDIC] = INFIRMARY
        assert_true(cb('infirmaryStock', MEDIC).ok)
        assert_eq(Opened[1].id, STASH)
        Mock.coords[INMATE] = INFIRMARY
        assert_eq(cb('infirmaryStock', INMATE).error, 'no_permission')
    end)
end)
