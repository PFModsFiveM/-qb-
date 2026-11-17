-- pf-emsmdt batch 20 (20D): patient care reports charted on the server from pf-ambulancejob events
-- (treatments by AJ id, vitals snapshots, times), the narrative as the only typed part (capped), the
-- handover acknowledged only by on-duty receiving hospital staff with the patient, the unit board from
-- the server's duty state, the patient profile's Medical tab from GetMedicalRecord, and the police
-- MDT's crime callouts and auto calls gone from the EMS server. SQL runs against a small in-memory
-- table fake here; tests/realdb_specs/b20_emsmdt_pcr_realdb_spec.lua runs the same paths on MariaDB.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetConvar(_, default) return default end
local resState = {}
function GetResourceState(r) return resState[r] or 'missing' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen = Citizen or {}
Citizen.Await = Citizen.Await or function(p) return p.value end

local DIR = '[pfscripts]/pf-emsmdt/'

-- ── table fake: the statements server/pcr.lua and server/units.lua send ─────────────────────────
local db
local function resetDb() db = { pcr = {}, entries = {}, units = {}, nextPcr = 0, nextEntry = 0, log = {} } end
resetDb()
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
local function withCount(r)
    local o = copy(r)
    local n = 0
    for _, e in ipairs(db.entries) do if e.pcr_id == r.id then n = n + 1 end end
    o.entries = n
    return o
end
local function lit(v) if v == 'NULL' then return nil end return v:match("^'(.*)'$") end
-- UPDATE `pf_emsmdt_pcr` SET a = ?, b = 'x' WHERE ... (the WHERE forms pcr.lua uses)
local function update(sql, p)
    local set, where = sql:match('SET%s+(.-)%s+WHERE%s+(.*)$')
    local i, assigns = 1, {}
    for part in (set .. ','):gmatch('%s*(.-)%s*,') do
        local col, val = part:match('^`([%w_]+)`%s*' .. '=%s*(.+)$') -- split: the harness rewrites a star-equals
        if val == '?' then assigns[col] = { v = p[i] } i = i + 1 else assigns[col] = { v = lit(val) } end
    end
    local match
    if where:find('`id` = ?', 1, true) then
        local id = p[i]
        local st = where:match("`state` = '(%w+)'")
        local notSt = where:match("`state` <> '(%w+)'")
        match = function(r) return r.id == id and (not st or r.state == st) and (not notSt or r.state ~= notSt) end
    else
        local st = where:match("`state` = '([%w_]+)'")
        local before = p[i]
        match = function(r) return r.state == st and r.updated_at < before end
    end
    local n = 0
    for _, r in ipairs(db.pcr) do
        if match(r) then
            for col, a in pairs(assigns) do r[col] = a.v end
            n = n + 1
        end
    end
    return n
end
local function pcrById(id) for _, r in ipairs(db.pcr) do if r.id == id then return r end end end
local function isCrew(id, cid) for _, e in ipairs(db.entries) do if e.pcr_id == id and e.by_cid == cid then return true end end return false end
local function sortDesc(list) table.sort(list, function(a, b) return a.id > b.id end) return list end

MySQL = {
    insert = { await = function(sql, p)
        db.log[#db.log + 1] = sql
        if sql:find('INSERT INTO `pf_emsmdt_pcr`', 1, true) then
            db.nextPcr = db.nextPcr + 1
            db.pcr[#db.pcr + 1] = { id = db.nextPcr, citizenid = p[1], call_ref = p[2], unit = p[3], lead_cid = p[4], state = 'open',
                dispatch_at = p[5], arrive_at = p[6], created_at = p[7], updated_at = p[8] }
            return db.nextPcr
        elseif sql:find('INSERT IGNORE INTO `pf_emsmdt_pcr_entries`', 1, true) then
            if not pcrById(p[1]) then error('foreign key') end
            if p[3] ~= nil then
                for _, e in ipairs(db.entries) do if e.pcr_id == p[1] and e.kind == p[2] and e.ref_id == p[3] then return 0 end end
            end
            db.nextEntry = db.nextEntry + 1
            db.entries[#db.entries + 1] = { id = db.nextEntry, pcr_id = p[1], kind = p[2], ref_id = p[3], by_cid = p[4], summary = p[5], at = p[6] }
            return db.nextEntry
        end
        error('unexpected insert ' .. sql)
    end },
    update = { await = function(sql, p) db.log[#db.log + 1] = sql return update(sql, p) end },
    scalar = { await = function(sql, p)
        db.log[#db.log + 1] = sql
        if sql:find('`by_cid` = ?', 1, true) then return isCrew(p[1], p[2]) and 1 or nil end
        return nil
    end },
    query = { await = function(sql, p)
        db.log[#db.log + 1] = sql
        p = p or {}
        if sql:find('INSERT INTO `pf_emsmdt_units`', 1, true) then
            db.units[p[1]] = { unit = p[1], status = p[2], crew = p[3], rig_plate = p[4], call_ref = p[5], status_at = p[6], updated_at = p[7] }
            return {}
        elseif sql:find('DELETE FROM `pf_emsmdt_units`', 1, true) then
            db.units[p[1]] = nil
            return {}
        elseif sql:find('FROM `pf_emsmdt_units`', 1, true) then
            local out = {}
            for _, u in pairs(db.units) do out[#out + 1] = copy(u) end
            return out
        elseif sql:find('DELETE FROM `pf_emsmdt_pcr`', 1, true) then
            for i = #db.pcr, 1, -1 do
                if db.pcr[i].citizenid == p[1] then
                    local id = db.pcr[i].id
                    for j = #db.entries, 1, -1 do if db.entries[j].pcr_id == id then table.remove(db.entries, j) end end
                    table.remove(db.pcr, i)
                end
            end
            return {}
        elseif sql:find('FROM `pf_emsmdt_pcr_entries` WHERE `pcr_id` = ?', 1, true) then
            local out = {}
            for _, e in ipairs(db.entries) do if e.pcr_id == p[1] then out[#out + 1] = copy(e) end end
            return out
        elseif sql:find('p.`id` = ?', 1, true) then
            local r = pcrById(p[1])
            return r and { withCount(r) } or {}
        elseif sql:find("p.`state` = 'open'", 1, true) then
            local out = {}
            for _, r in ipairs(db.pcr) do if r.state == 'open' then out[#out + 1] = withCount(r) end end
            return out
        elseif sql:find('p.`lead_cid` = ? OR EXISTS', 1, true) then
            local out = {}
            for _, r in ipairs(db.pcr) do if r.lead_cid == p[1] or isCrew(r.id, p[2]) then out[#out + 1] = withCount(r) end end
            return sortDesc(out)
        elseif sql:find('p.`citizenid` = ?', 1, true) then
            local out = {}
            for _, r in ipairs(db.pcr) do if r.citizenid == p[1] then out[#out + 1] = withCount(r) end end
            return sortDesc(out)
        end
        return {}
    end },
}

-- oxmysql exports for server/main.lua (patient profile)
local function ox(_, sql, params, cb)
    if Mock.callable(params) then cb, params = params, nil end
    local rows = {}
    if sql:find('FROM players WHERE citizenid', 1, true) then
        rows = { { citizenid = params[1], charinfo = json.encode({ firstname = 'Pat', lastname = 'Ient', birthdate = '1990-01-01' }), metadata = json.encode({ bloodtype = 'O+' }) } }
    end
    if Mock.callable(cb) then cb(rows) end
    return rows
end
Mock.exportsByResource['oxmysql'] = { execute = ox, query = ox, fetch = ox,
    insert = function(_, _, _, cb) if Mock.callable(cb) then cb(1) end return 1 end }
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

-- ── pf-ambulancejob by contract ────────────────────────────────────────────────────────────────
local AJ
local function resetAJ()
    AJ = { admissions = {}, recordCalls = {}, recordDeny = false,
        vitals = { hr = 112.4, sbp = 98, dbp = 61, rr = 22, spo2 = 94, temp = 36.84, gcs = 14, pain = 6 } }
end
resetAJ()
Mock.exportsByResource['pf-ambulancejob'] = {
    GetPatientSummary = function(_, cid) return { ok = true, cid = cid, consciousness = 'altered', vitals = AJ.vitals } end,
    GetAdmission = function(_, cid) return { ok = true, admission = AJ.admissions[cid] } end,
    GetMedicalRecord = function(_, cid, opts)
        AJ.recordCalls[#AJ.recordCalls + 1] = { cid = cid, viewer = opts and opts.viewer, purpose = opts and opts.purpose }
        if AJ.recordDeny then return { ok = false, error = 'no_permission' } end
        return { ok = true, record = { cid = cid,
            injuries = { { id = 7, type = 'gsw', label = 'Gunshot wound', region = 'upper_arm_l', severity = 3, stage = 'stabilized' },
                { id = 8, type = 'fracture', label = 'Fracture', structure = 'radius_l', severity = 2, stage = 'recovered' } },
            treatments = { { id = 501, action = 'pressure_dressing', result = 'applied', at = 1700000000 } },
            admissions = { { id = 3, hospitalId = 'pillbox', state = 'discharged', arrivedAt = 1700000100 } },
            diagnoses = { { id = 2, label = 'Fracture', structure = 'radius_l', status = 'confirmed' } },
            prescriptions = { { label = 'Antibiotics', dose = '500 mg', state = 'active' } }, deathRecords = {} } }
    end,
}

local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end
SetTimeout = function() end
Wait = function() end

function GetCurrentResourceName() return 'pf-emsmdt' end

local MED1, MED2, NURSE, PAT, CIV, CHIEF = 1, 2, 3, 4, 5, 6
local function setJob(src, name, onduty, grade) Mock.players[src].PlayerData.job = { name = name, onduty = onduty, grade = { level = grade or 1 } } end
local function setupPlayers()
    Mock.players = {}
    Mock.newPlayer(MED1, 'MED1'); setJob(MED1, 'ambulance', true, 1)
    Mock.newPlayer(MED2, 'MED2'); setJob(MED2, 'ambulance', true, 1)
    Mock.newPlayer(NURSE, 'NURSE1'); setJob(NURSE, 'ambulance', true, 2)
    Mock.newPlayer(PAT, 'PAT1')
    Mock.newPlayer(CIV, 'CIV1')
    Mock.newPlayer(CHIEF, 'CHIEF1'); setJob(CHIEF, 'ambulance', true, 4)
    for src = 1, 6 do Mock.coords[src] = vector3(100.0, 100.0, 30.0) end
end

local function loadAll()
    Config, PFEmsSchema, PFEmsPcr, PFEmsUnits, PFEmsDispatch = nil, nil, nil, nil, nil
    threads = {}
    load_resource(DIR .. 'config.lua')
    load_resource(DIR .. 'shared/framework.lua')
    load_resource(DIR .. 'server/schema.lua')
    load_resource(DIR .. 'server/main.lua')
    load_resource(DIR .. 'server/units.lua')
    load_resource(DIR .. 'server/pcr.lua')
    threads = {} -- the start thread and the tick loops are run by hand
    assert_true(PFEmsSchema.Apply())
    local t = threads
    threads = {}
    for _, fn in ipairs(t) do fn() end -- the OnReady work: open PCRs and the unit board load
end

local function aj(name, ...)
    Mock.invokingResource = 'pf-ambulancejob'
    TriggerEvent('pf-ambulancejob:server:' .. name, ...)
    Mock.invokingResource = nil
end
local function treat(cid, id, by, action, at)
    aj('treatmentApplied', cid, { id = id, action = action or 'pressure_dressing', byCid = by, at = at or Mock.clock, result = 'applied' })
end
local function entriesOf(pcrId, kind)
    local out = {}
    for _, e in ipairs(db.entries) do if e.pcr_id == pcrId and (not kind or e.kind == kind) then out[#out + 1] = e end end
    return out
end
local function cb(name, src, data) Mock.gameTimer = Mock.gameTimer + 5000 return Mock.callCallback(name, src, data) end

BeforeEach = function()
    Mock.reset()
    resetDb()
    resetAJ()
    resState = { ['pf-ambulancejob'] = 'started' }
    Mock.clock = 1800000000
    Mock.invokingResource = nil
    Mock.vehicleOf, Mock.plates, Mock.models = {}, {}, {}
    setupPlayers()
    loadAll()
end

-- ── PCR charting ───────────────────────────────────────────────────────────────────────────────
describe('PCRs are charted from pf-ambulancejob events', function()
    it('a medic\'s first treatment opens a PCR with the treatment (AJ id), a vitals snapshot and the times', function()
        treat('PAT1', 501, 'MED1')
        assert_eq(#db.pcr, 1)
        local p = db.pcr[1]
        assert_eq(p.citizenid, 'PAT1')
        assert_eq(p.lead_cid, 'MED1')
        assert_eq(p.state, 'open')
        assert_eq(p.arrive_at, Mock.clock)
        local t = entriesOf(1, 'treatment')
        assert_eq(#t, 1)
        assert_eq(t[1].ref_id, 501)
        assert_eq(t[1].by_cid, 'MED1')
        assert_eq(t[1].summary, 'Pressure dressing by Test Player1 (Applied)')
        local v = entriesOf(1, 'vitals')
        assert_eq(#v, 1)
        assert_eq(v[1].summary, 'HR 112, BP 98/61, RR 22, SpO2 94%, Temp 36.8, GCS 14, Pain 6/10, Altered')
    end)

    it('the same AJ treatment is charted once; vitals at most once per window; others chart into the open PCR', function()
        treat('PAT1', 501, 'MED1')
        treat('PAT1', 501, 'MED1')
        assert_eq(#entriesOf(1, 'treatment'), 1)
        Mock.clock = Mock.clock + 10
        treat('PAT1', 502, 'MED2', 'splint')
        assert_eq(#db.pcr, 1, 'one PCR per patient and call')
        assert_eq(#entriesOf(1, 'treatment'), 2)
        assert_eq(#entriesOf(1, 'vitals'), 1, 'no second snapshot inside 60 s')
        Mock.clock = Mock.clock + 61
        treat('PAT1', 503, 'CIV1', 'bandage') -- a bystander's care is charted once the PCR is open
        assert_eq(#entriesOf(1, 'treatment'), 3)
        assert_eq(#entriesOf(1, 'vitals'), 2)
    end)

    it('only pf-ambulancejob\'s server events chart (another resource or a client cannot)', function()
        Mock.invokingResource = 'some-resource'
        TriggerEvent('pf-ambulancejob:server:treatmentApplied', 'PAT1', { id = 1, action = 'cpr', byCid = 'MED1', at = Mock.clock })
        Mock.invokingResource = 'pf-ambulancejob'
        Mock.fireEvent('pf-ambulancejob:server:treatmentApplied', MED1, 'PAT1', { id = 2, action = 'cpr', byCid = 'MED1', at = Mock.clock })
        Mock.invokingResource = nil
        assert_eq(#db.pcr, 0)
    end)

    it('self-care, bystander care, an off-duty medic and a patient in hospital care open no PCR', function()
        treat('PAT1', 1, 'PAT1')
        treat('PAT1', 2, 'CIV1')
        setJob(MED2, 'ambulance', false)
        treat('PAT1', 3, 'MED2')
        AJ.admissions['PAT1'] = { id = 9, hospitalId = 'pillbox', state = 'admitted', open = true }
        treat('PAT1', 4, 'MED1')
        assert_eq(#db.pcr, 0)
        assert_eq(#db.entries, 0)
    end)

    it('bad event data is refused (no PCR from a malformed payload)', function()
        aj('treatmentApplied', 'PAT1', 'x')
        aj('treatmentApplied', { 'PAT1' }, { id = 1, action = 'cpr', byCid = 'MED1' })
        aj('treatmentApplied', 'PAT1', { id = 1, byCid = 'MED1' })
        assert_eq(#db.pcr, 0)
    end)

    it('an open PCR idle past the call window is closed and the next treatment opens a new one', function()
        treat('PAT1', 501, 'MED1')
        Mock.clock = Mock.clock + Config.PCR.CallWindowSeconds + 5
        treat('PAT1', 601, 'MED2')
        assert_eq(#db.pcr, 2)
        assert_eq(db.pcr[1].state, 'closed')
        assert_eq(db.pcr[1].disposition, 'no_activity')
        assert_eq(db.pcr[2].lead_cid, 'MED2')
        assert_eq(db.pcr[2].state, 'open')
    end)

    it('the unit and its call are on the PCR; admission, revival, death and unit times are charted', function()
        assert_true(cb('pf_emsmdt:units:join', MED1, { unit = 'medic 1' }).ok)
        local call = Mock.selfExport('CreateDispatchCall')({ title = 'Person down', coords = { x = 1.0, y = 2.0, z = 3.0 }, createdAt = Mock.clock - 120 })
        Mock.fireNet('pf_emsmdt_dispatch:server:AcceptCall', MED1, call.id)
        assert_eq(PFEmsUnits.Get('MEDIC 1').status, 'en_route')
        assert_true(cb('pf_emsmdt:units:setStatus', MED1, { status = 'on_scene' }).ok)
        Mock.clock = Mock.clock + 30
        treat('PAT1', 501, 'MED1')
        local p = db.pcr[1]
        assert_eq(p.unit, 'MEDIC 1')
        assert_eq(p.call_ref, call.id)
        assert_eq(p.dispatch_at, Mock.clock - 150)
        assert_eq(p.arrive_at, Mock.clock - 30, 'arrival is the unit\'s on-scene time')
        Mock.clock = Mock.clock + 60
        assert_true(cb('pf_emsmdt:units:setStatus', MED1, { status = 'transporting' }).ok)
        assert_eq(p.depart_at, Mock.clock)
        aj('admissionChanged', { id = 9, citizenid = 'PAT1', hospitalId = 'pillbox', hospital = 'Pillbox Medical Center', state = 'checked_in', open = true }, nil, 'checked_in')
        assert_eq(p.hospital_id, 'pillbox')
        assert_eq(p.admission_id, 9)
        aj('patientRevived', PAT, 'PAT1', { cid = 'MED1' }, 'treatment')
        aj('patientDied', PAT, 'PAT1', 'bleeding')
        local notes = {}
        for _, e in ipairs(entriesOf(1, 'note')) do notes[#notes + 1] = e.summary end
        local all = table.concat(notes, '|')
        assert_true(all:find('Departed scene, transporting', 1, true) ~= nil, all)
        assert_true(all:find('Pillbox Medical Center: Checked in', 1, true) ~= nil, all)
        assert_true(all:find('Patient revived (Treatment)', 1, true) ~= nil, all)
        assert_true(all:find('Patient died', 1, true) ~= nil, all)
    end)

    it('an event that arrives while the patient is locked is charted after the holder, in order', function()
        treat('PAT1', 501, 'MED1')
        PFEmsPcr.Serial('PAT1', function()
            treat('PAT1', 502, 'MED1')
            assert_eq(#entriesOf(1, 'treatment'), 1, 'waits for the lock')
        end)
        assert_eq(#entriesOf(1, 'treatment'), 2)
    end)

    it('a restart reloads open PCRs and keeps charting the same one', function()
        treat('PAT1', 501, 'MED1')
        loadAll()
        Mock.clock = Mock.clock + 5
        treat('PAT1', 502, 'MED1')
        assert_eq(#db.pcr, 1)
        assert_eq(#entriesOf(1, 'treatment'), 2)
    end)
end)

-- ── narrative, handover, close ─────────────────────────────────────────────────────────────────
describe('narrative, handover and closing', function()
    local function open()
        treat('PAT1', 501, 'MED1')
        return db.pcr[1].id
    end

    it('the narrative is written by the crew only, capped, keeps line breaks, and not after closing', function()
        local id = open()
        assert_eq(cb('pf_emsmdt:pcr:saveNarrative', CIV, { id = id, text = 'x' }).error, 'not_on_duty')
        assert_eq(cb('pf_emsmdt:pcr:saveNarrative', MED2, { id = id, text = 'x' }).error, 'no_permission')
        local res = cb('pf_emsmdt:pcr:saveNarrative', MED1, { id = id, text = 'Found at scene.\nGSW left arm.\0' })
        assert_true(res.ok)
        assert_eq(db.pcr[1].narrative, 'Found at scene.\nGSW left arm. ')
        res = cb('pf_emsmdt:pcr:saveNarrative', MED1, { id = id, text = string.rep('a', 5000) })
        assert_true(res.ok)
        assert_true(res.clipped)
        assert_eq(#db.pcr[1].narrative, Config.PCR.NarrativeMax)
        assert_eq(cb('pf_emsmdt:pcr:saveNarrative', MED1, { id = id, text = 5 }).error, 'bad_args')
        assert_true(cb('pf_emsmdt:pcr:close', MED1, { id = id, disposition = 'treated_on_scene' }).ok)
        assert_eq(cb('pf_emsmdt:pcr:saveNarrative', MED1, { id = id, text = 'late' }).error, 'invalid_state')
    end)

    it('the handover is acknowledged only by on-duty hospital staff with the checked-in patient', function()
        local id = open()
        local function ack(src) return cb('pf_emsmdt:pcr:acknowledgeHandover', src, { id = id }) end
        assert_eq(ack(CIV).error, 'no_permission')
        setJob(NURSE, 'ambulance', false)
        assert_eq(ack(NURSE).error, 'not_on_duty')
        setJob(NURSE, 'ambulance', true, 2)
        assert_eq(ack(MED1).error, 'no_permission', 'the crew cannot accept their own handover')
        assert_eq(ack(NURSE).error, 'invalid_state', 'the patient is not checked in')
        AJ.admissions['PAT1'] = { id = 9, hospitalId = 'pillbox', hospital = 'Pillbox Medical Center', state = 'triaged', open = true }
        Mock.coords[NURSE] = vector3(130.0, 100.0, 30.0)
        assert_eq(ack(NURSE).error, 'too_far')
        Mock.coords[NURSE] = vector3(103.0, 100.0, 30.0)
        local res = ack(NURSE)
        assert_true(res.ok, tostring(res.error))
        local p = db.pcr[1]
        assert_eq(p.state, 'handed_over')
        assert_eq(p.handover_by, 'NURSE1')
        assert_eq(p.handover_at, Mock.clock)
        assert_eq(p.hospital_id, 'pillbox')
        assert_eq(p.admission_id, 9)
        assert_eq(PFEmsPcr.OpenByCid['PAT1'], nil, 'no longer charted')
        assert_eq(ack(NURSE).error, 'invalid_state', 'once')
        local last = entriesOf(id, 'note')
        assert_eq(last[#last].summary, 'Handed over to Test Player3 at Pillbox Medical Center')
        assert_eq(#entriesOf(id, 'vitals'), 2, 'a snapshot at handover')
        -- after the handover a treatment in hospital opens no new PCR (the patient is in care)
        treat('PAT1', 900, 'NURSE1')
        assert_eq(#db.pcr, 1)
    end)

    it('a unit partner who charted nothing cannot accept the handover (PCR unit or the lead\'s current unit)', function()
        assert_true(cb('pf_emsmdt:units:join', MED1, { unit = 'MEDIC 1' }).ok)
        assert_true(cb('pf_emsmdt:units:join', NURSE, { unit = 'MEDIC 1' }).ok) -- silent partner, same job as hospital staff
        local id = open()
        assert_eq(db.pcr[1].unit, 'MEDIC 1')
        AJ.admissions['PAT1'] = { id = 9, hospitalId = 'pillbox', hospital = 'Pillbox Medical Center', state = 'triaged', open = true }
        assert_eq(#entriesOf(id, 'treatment'), 1)
        assert_eq(cb('pf_emsmdt:pcr:acknowledgeHandover', NURSE, { id = id }).error, 'no_permission')
        assert_false(cb('pf_emsmdt:pcr:get', NURSE, { id = id }).pcr.can.acknowledge)
        -- the PCR's unit was empty at open; the lead's current unit counts too
        assert_true(cb('pf_emsmdt:units:leave', NURSE).ok)
        assert_true(cb('pf_emsmdt:units:leave', MED1).ok)
        db.pcr[1].unit = nil
        assert_true(cb('pf_emsmdt:units:join', MED1, { unit = 'MEDIC 9' }).ok)
        assert_true(cb('pf_emsmdt:units:join', NURSE, { unit = 'MEDIC 9' }).ok)
        assert_eq(cb('pf_emsmdt:pcr:acknowledgeHandover', NURSE, { id = id }).error, 'no_permission')
        -- off the unit, the same nurse is receiving staff
        assert_true(cb('pf_emsmdt:units:leave', NURSE).ok)
        assert_true(cb('pf_emsmdt:pcr:get', NURSE, { id = id }).pcr.can.acknowledge)
        assert_true(cb('pf_emsmdt:pcr:acknowledgeHandover', NURSE, { id = id }).ok)
    end)

    it('the patient offline or away blocks the handover', function()
        local id = open()
        AJ.admissions['PAT1'] = { id = 9, hospitalId = 'pillbox', state = 'triaged', open = true }
        Mock.players[PAT] = nil
        assert_eq(cb('pf_emsmdt:pcr:acknowledgeHandover', NURSE, { id = id }).error, 'offline')
    end)

    it('closing: lead or supervisor; transported only after the handover; a handed-over report only as transported', function()
        local id = open()
        assert_eq(cb('pf_emsmdt:pcr:close', MED2, { id = id, disposition = 'refused' }).error, 'no_permission')
        assert_eq(cb('pf_emsmdt:pcr:close', MED1, { id = id, disposition = 'transported' }).error, 'invalid_state')
        assert_eq(cb('pf_emsmdt:pcr:close', MED1, { id = id, disposition = 'made_up' }).error, 'bad_args')
        AJ.admissions['PAT1'] = { id = 9, hospitalId = 'pillbox', state = 'triaged', open = true }
        assert_true(cb('pf_emsmdt:pcr:acknowledgeHandover', NURSE, { id = id }).ok)
        assert_eq(cb('pf_emsmdt:pcr:close', MED1, { id = id, disposition = 'refused' }).error, 'invalid_state')
        local res = cb('pf_emsmdt:pcr:close', CHIEF, { id = id, disposition = 'transported' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(db.pcr[1].state, 'closed')
        assert_eq(db.pcr[1].disposition, 'transported')
        assert_eq(cb('pf_emsmdt:pcr:close', MED1, { id = id, disposition = 'transported' }).error, 'invalid_state')
    end)

    it('the sweep closes reports nobody touched (handed over: transported; open: no activity)', function()
        open()
        treat('PAT2', 700, 'MED2')
        AJ.admissions['PAT1'] = { id = 9, hospitalId = 'pillbox', state = 'triaged', open = true }
        Mock.newPlayer(7, 'PAT2')
        assert_true(cb('pf_emsmdt:pcr:acknowledgeHandover', NURSE, { id = 1 }).ok)
        Mock.clock = Mock.clock + Config.PCR.AutoCloseSeconds + 1
        assert_eq(PFEmsPcr.Tick(), 2)
        assert_eq(db.pcr[1].disposition, 'transported')
        assert_eq(db.pcr[2].disposition, 'no_activity')
    end)

    it('a busy report answers busy instead of racing', function()
        local id = open()
        local res
        PFEmsPcr.Serial('PAT1', function() res = cb('pf_emsmdt:pcr:saveNarrative', MED1, { id = id, text = 'x' }) end)
        assert_eq(res.error, 'busy')
    end)
end)

-- ── reading and privacy ────────────────────────────────────────────────────────────────────────
describe('reading PCRs', function()
    it('the crew reads its report; others need pf-ambulancejob\'s record access; lists are scoped', function()
        treat('PAT1', 501, 'MED1')
        local res = cb('pf_emsmdt:pcr:get', MED1, { id = 1 })
        assert_true(res.ok)
        assert_eq(res.pcr.lead.citizenid, 'MED1')
        assert_true(res.pcr.can.narrative)
        assert_true(res.pcr.can.close)
        assert_false(res.pcr.can.acknowledge)
        assert_eq(#res.pcr.entries, 3)
        AJ.recordDeny = true
        assert_eq(cb('pf_emsmdt:pcr:get', MED2, { id = 1 }).error, 'not_found')
        assert_eq(cb('pf_emsmdt:pcr:get', CIV, { id = 1 }).error, 'not_found')
        assert_eq(#cb('pf_emsmdt:pcr:list', MED2, { scope = 'patient', citizenId = 'PAT1' }).list, 0)
        assert_eq(#cb('pf_emsmdt:pcr:list', MED1, {}).list, 1, 'mine')
        AJ.recordDeny = false
        assert_true(cb('pf_emsmdt:pcr:get', MED2, { id = 1 }).ok)
        assert_eq(#cb('pf_emsmdt:pcr:list', MED2, { scope = 'patient', citizenId = 'PAT1' }).list, 1)
        assert_eq(cb('pf_emsmdt:pcr:list', CIV, {}).error, 'no_permission')
    end)

    it('exports: caller list, purposes (treatment, self, court order) and bad options', function()
        treat('PAT1', 501, 'MED1')
        local GetPcr, List = Mock.selfExport('GetPcr'), Mock.selfExport('ListPcrFor')
        Mock.invokingResource = 'pfm-prison'
        assert_eq(GetPcr(1, { viewer = MED1, purpose = 'treatment' }).error, 'not_allowed')
        Mock.invokingResource = 'pf-justice'
        assert_eq(GetPcr(1).error, 'bad_args')
        assert_eq(GetPcr(1, { purpose = 'court_order', courtOrderId = 'CO-1' }).error, 'no_permission')
        resState['pf-justice'] = 'started'
        local seen
        Mock.exportsByResource['pf-justice'] = { IsCourtOrderValid = function(_, ref, purpose, cid) seen = { ref, purpose, cid } return ref == 'CO-1' end }
        local res = GetPcr(1, { purpose = 'court_order', courtOrderId = 'CO-1' })
        assert_true(res.ok)
        assert_eq(seen[2], 'medical_records')
        assert_eq(seen[3], 'PAT1')
        assert_eq(#res.pcr.entries, 3)
        assert_true(GetPcr(1, { viewer = PAT, purpose = 'self' }).ok)
        assert_eq(GetPcr(1, { viewer = CIV, purpose = 'self' }).error, 'no_permission')
        AJ.recordDeny = true
        assert_eq(GetPcr(1, { viewer = MED2, purpose = 'treatment' }).error, 'not_found')
        assert_true(GetPcr(1, { viewer = MED1, purpose = 'treatment' }).ok, 'the crew')
        assert_eq(#List('PAT1', { viewer = MED2, purpose = 'treatment' }).list, 0)
        assert_eq(List('bad cid!', { viewer = MED1, purpose = 'treatment' }).error, 'bad_args')
        Mock.invokingResource = nil
    end)

    it('a deleted character takes their PCRs and lines with them', function()
        treat('PAT1', 501, 'MED1')
        TriggerEvent('pfm-core:server:characterDeleted', 'PAT1', {})
        assert_eq(#db.pcr, 0)
        assert_eq(#db.entries, 0)
        assert_eq(PFEmsPcr.OpenByCid['PAT1'], nil)
    end)
end)

-- ── unit board ─────────────────────────────────────────────────────────────────────────────────
describe('unit board from the server duty state', function()
    it('join, crew limit, one unit per medic, names checked, off duty refused', function()
        assert_eq(cb('pf_emsmdt:units:join', CIV, { unit = 'M1' }).error, 'not_on_duty')
        assert_eq(cb('pf_emsmdt:units:join', MED1, { unit = '<b>' }).error, 'bad_args')
        assert_true(cb('pf_emsmdt:units:join', MED1, { unit = 'medic 1' }).ok)
        assert_true(cb('pf_emsmdt:units:join', MED2, { unit = 'MEDIC 1' }).ok)
        Config.Units.MaxCrew = 2
        assert_eq(cb('pf_emsmdt:units:join', NURSE, { unit = 'MEDIC 1' }).error, 'conflict')
        assert_true(cb('pf_emsmdt:units:join', MED2, { unit = 'MEDIC 2' }).ok)
        assert_eq(PFEmsUnits.UnitOf('MED2'), 'MEDIC 2')
        assert_eq(#PFEmsUnits.Get('MEDIC 1').crew, 1)
        local board = cb('pf_emsmdt:units:list', MED1)
        assert_true(board.ok)
        assert_eq(#board.units, 2)
        assert_eq(board.units[1].crew[1].name, 'Test Player1')
        assert_eq(db.units['MEDIC 2'].crew, '["MED2"]')
        assert_true(#Mock.clientEventsNamed('pf_emsmdt:client:UnitBoard') > 0, 'pushed to medics')
    end)

    it('status by crew only; the dispatch units list shows the server status, not the medic\'s own metadata', function()
        assert_eq(cb('pf_emsmdt:units:setStatus', MED1, { status = 'on_scene' }).error, 'not_found')
        cb('pf_emsmdt:units:join', MED1, { unit = 'MEDIC 1' })
        assert_eq(cb('pf_emsmdt:units:setStatus', MED1, { status = 'napping' }).error, 'bad_args')
        assert_true(cb('pf_emsmdt:units:setStatus', MED1, { status = 'on_scene' }).ok)
        Mock.players[MED1].PlayerData.metadata.mdt_status = 'available'
        Mock.players[MED2].PlayerData.metadata.mdt_status = 'transporting'
        local units = Mock.callCallback('pf_emsmdt_dispatch:server:GetUnits', MED1)
        local by = {}
        for _, u in ipairs(units) do by[u.citizenid] = u end
        assert_eq(by['MED1'].status, 'on_scene')
        assert_eq(by['MED1'].unit, 'MEDIC 1')
        assert_eq(by['MED2'].status, 'available')
        setJob(MED2, 'ambulance', false)
        units = Mock.callCallback('pf_emsmdt_dispatch:server:GetUnits', MED1)
        for _, u in ipairs(units) do by[u.citizenid] = u end
        assert_eq(by['MED2'].status, 'off_duty')
    end)

    it('the rig plate is read from the vehicle the medic sits in (server side)', function()
        cb('pf_emsmdt:units:join', MED1, { unit = 'MEDIC 1' })
        assert_eq(cb('pf_emsmdt:units:setRig', MED1, { plate = 'FAKE' }).error, 'bad_args')
        Mock.vehicleOf[MED1] = 900
        Mock.plates[900] = ' EMS 01 '
        assert_true(cb('pf_emsmdt:units:setRig', MED1, { plate = 'FAKE' }).ok)
        assert_eq(PFEmsUnits.Get('MEDIC 1').rigPlate, 'EMS 01')
        cb('pf_emsmdt:units:join', MED2, { unit = 'MEDIC 2' })
        Mock.vehicleOf[MED2] = 900
        assert_eq(cb('pf_emsmdt:units:setRig', MED2, {}).error, 'conflict')
        Config.Units.RigModels = { 'ambulance' }
        Mock.models[901] = GetHashKey('police')
        Mock.vehicleOf[MED2] = 901
        Mock.plates[901] = 'LSPD 1'
        assert_eq(cb('pf_emsmdt:units:setRig', MED2, {}).error, 'no_permission')
        assert_true(cb('pf_emsmdt:units:setRig', MED1, { clear = true }).ok)
        assert_eq(PFEmsUnits.Get('MEDIC 1').rigPlate, nil)
    end)

    it('going off duty, a job change or leaving takes the medic off the unit; an empty unit goes', function()
        cb('pf_emsmdt:units:join', MED1, { unit = 'MEDIC 1' })
        cb('pf_emsmdt:units:join', MED2, { unit = 'MEDIC 1' })
        setJob(MED1, 'ambulance', false)
        TriggerEvent('QBCore:Server:SetDuty', MED1, false)
        assert_eq(PFEmsUnits.UnitOf('MED1'), nil)
        assert_eq(#PFEmsUnits.Get('MEDIC 1').crew, 1)
        Mock.fireEvent('playerDropped', MED2)
        assert_eq(PFEmsUnits.Get('MEDIC 1'), nil)
        assert_eq(db.units['MEDIC 1'], nil, 'removed from the table')
        cb('pf_emsmdt:units:join', NURSE, { unit = 'MEDIC 3' })
        setJob(NURSE, 'police', true)
        assert_eq(PFEmsUnits.Tick(), nil)
        assert_eq(PFEmsUnits.UnitOf('NURSE1'), nil, 'the timed sweep catches what no event announced')
    end)

    it('accepting a call puts the unit en route on it; completing it clears the call', function()
        cb('pf_emsmdt:units:join', MED1, { unit = 'MEDIC 1' })
        local call = Mock.selfExport('CreateDispatchCall')({ title = 'Fall', coords = { x = 1.0, y = 2.0, z = 3.0 } })
        Mock.fireNet('pf_emsmdt_dispatch:server:AcceptCall', MED1, call.id)
        local u = PFEmsUnits.Get('MEDIC 1')
        assert_eq(u.callRef, call.id)
        assert_eq(u.status, 'en_route')
        Mock.fireNet('pf_emsmdt_dispatch:server:CompleteCall', MED1, call.id)
        assert_eq(PFEmsUnits.Get('MEDIC 1').callRef, nil)
    end)

    it('the board survives a restart; crew who are gone are dropped', function()
        cb('pf_emsmdt:units:join', MED1, { unit = 'MEDIC 1' })
        cb('pf_emsmdt:units:join', MED2, { unit = 'MEDIC 2' })
        cb('pf_emsmdt:units:setStatus', MED1, { status = 'on_scene' })
        Mock.players[MED2] = nil
        loadAll()
        assert_eq(PFEmsUnits.Get('MEDIC 1').status, 'on_scene')
        assert_eq(PFEmsUnits.UnitOf('MED1'), 'MEDIC 1')
        assert_eq(PFEmsUnits.Get('MEDIC 2'), nil)
        assert_eq(db.units['MEDIC 2'], nil)
    end)

    it('GetUnitStatus answers allowed resources only', function()
        cb('pf_emsmdt:units:join', MED1, { unit = 'MEDIC 1' })
        local GetUnitStatus = Mock.selfExport('GetUnitStatus')
        Mock.invokingResource = 'pfm-prison'
        assert_eq(GetUnitStatus(MED1).error, 'not_allowed')
        Mock.invokingResource = 'pf-ambulancejob'
        local res = GetUnitStatus(MED1)
        assert_true(res.ok)
        assert_true(res.onDuty)
        assert_eq(res.unit.unit, 'MEDIC 1')
        assert_eq(GetUnitStatus(-1).error, 'bad_args')
        Mock.invokingResource = nil
    end)
end)

-- ── the patient profile's Medical tab ──────────────────────────────────────────────────────────
describe('patient profile Medical tab', function()
    local function profile(src) return Mock.callCallback('pf_emsmdt:getPatientProfile', src or MED1, { citizenId = 'PAT1' }) end

    it('reads GetMedicalRecord for the viewer and fills the tab with text lines', function()
        local res = profile()
        assert_true(res.success)
        local m = res.profile.medical
        assert_true(m.available)
        assert_eq(AJ.recordCalls[1].cid, 'PAT1')
        assert_eq(AJ.recordCalls[1].viewer, MED1)
        assert_eq(AJ.recordCalls[1].purpose, 'treatment')
        assert_eq(m.injuries[1], 'Gunshot wound, Upper arm l (severity 3) - Stabilized')
        assert_eq(m.injuries[2], 'Fracture, Radius l (severity 2) - Recovered')
        assert_eq(m.conditions[1], 'Fracture (Radius l)')
        assert_eq(m.medications[1], 'Antibiotics 500 mg (Active)')
        assert_eq(#m.treatments, 1)
        assert_eq(#m.admissions, 1)
        assert_eq(#m.allergies, 0, 'no allergy data exists; nothing is made up')
        for _, list in ipairs({ m.injuries, m.conditions, m.medications, m.treatments, m.admissions }) do
            for _, s in ipairs(list) do assert_eq(type(s), 'string') end
        end
        assert_eq(res.profile.medicalRecord.injuries[1].id, 7)
        assert_eq(res.profile.injuries[1], m.injuries[1])
    end)

    it('the patient viewing themselves asks with purpose self; a refusal leaves the tab empty with the reason', function()
        setJob(PAT, 'ambulance', true)
        profile(PAT)
        assert_eq(AJ.recordCalls[1].purpose, 'self')
        AJ.recordDeny = true
        local res = profile()
        assert_true(res.success)
        assert_false(res.profile.medical.available)
        assert_eq(res.profile.medical.error, 'no_permission')
        assert_eq(#res.profile.medical.injuries, 0)
        resState['pf-ambulancejob'] = 'missing'
        res = profile()
        assert_eq(res.profile.medical.error, 'unavailable')
    end)

    it('lists the patient\'s PCRs (all with record access, only crewed ones without)', function()
        treat('PAT1', 501, 'MED1')
        assert_eq(#profile(MED2).profile.pcrs, 1)
        AJ.recordDeny = true
        assert_eq(#profile(MED2).profile.pcrs, 0)
        assert_eq(#profile(MED1).profile.pcrs, 1, 'the crew still sees its own')
    end)
end)

-- ── police leftovers ───────────────────────────────────────────────────────────────────────────
describe('police leftovers are gone from the EMS server', function()
    it('no crime callouts or auto calls (events, export) and the manifest no longer loads their client side', function()
        for _, name in ipairs({ 'pf_emsmdt:dispatch:shotsFired', 'pf_emsmdt:dispatch:vehicleTheft', 'pf_emsmdt:dispatch:homicide',
            'pf_emsmdt_dispatch:server:CreateCallout' }) do
            assert_eq(Mock.netHandlers[name], nil, name)
        end
        assert_eq(Mock.selfExport('CreateDispatchCallout'), nil)
        local m = __readfile(DIR .. 'fxmanifest.lua')
        assert_eq(m:find("'client/dispatch_autocalls.lua'", 1, true), nil)
        assert_eq(m:find("'client/dispatch_callouts.lua'", 1, true), nil)
        assert_true(m:find("'server/units.lua'", 1, true) < m:find("'server/pcr.lua'", 1, true))
        assert_true(m:find("'server/schema.lua'", 1, true) < m:find("'server/units.lua'", 1, true))
    end)

    it('the config has no police providers, crime 911 types or CCTV; a police /911 about a theft makes no EMS call', function()
        for _, k in ipairs({ 'CCTV', 'CCTVModels', 'Banking', 'Garage', 'Housing', 'Prison', 'FTOReports', 'TestCallTemplates', 'DispatchAutoCalls' }) do
            assert_eq(Config[k], nil, k)
        end
        for _, k in ipairs({ 'robbery', 'theft', 'vehicle_theft' }) do assert_eq(Config.Dispatch911.Types[k], nil, k) end
        Mock.coords[CIV] = vector3(10.0, 10.0, 10.0)
        local before = #Mock.callCallback('pf_emsmdt_dispatch:server:GetCalls', MED1)
        Mock.fireNet('pf_mdt_dispatch:server:Create911Call', CIV, { description = 'someone stole my car, robbery', coords = { x = 10.0, y = 10.0, z = 10.0 } })
        assert_eq(#Mock.callCallback('pf_emsmdt_dispatch:server:GetCalls', MED1), before)
        Mock.fireNet('pf_mdt_dispatch:server:Create911Call', CIV, { description = 'shots fired, man down', coords = { x = 10.0, y = 10.0, z = 10.0 } })
        assert_true(#Mock.callCallback('pf_emsmdt_dispatch:server:GetCalls', MED1) > before)
    end)
end)
