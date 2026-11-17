-- pf-emsmdt batch 21D: the hospital workstation's server handlers (server/hospital_app.lua) and its
-- registration on pf-devices (server/devices.lua). Every handler re-reads the player (on-duty
-- hospital staff; bills only for supervisors) before it asks pf-ambulancejob; actions go to
-- pf-ambulancejob's own server callbacks with the real player id, the patient resolved on the server
-- from the admission (never a client-sent id); the discharge goes through DischargePatient with
-- actor = { src } and a key per admission; queues are read from its exports with results left out;
-- bills and the counter queue are paged SELECTs (tests/realdb_specs/b21_hospital_app_realdb_spec.lua
-- runs them on MariaDB). pf-ambulancejob is mocked here by its contract (exports + callbacks).
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
local resState = { ['pf-ambulancejob'] = 'started', ['pf-devices'] = 'started' }
function GetResourceState(r) return resState[r] or 'missing' end
function GetCurrentResourceName() return 'pf-emsmdt' end
local moduleFile = 'PFApps.register("hospital", {})'
function LoadResourceFile(res, path)
    if res == 'pf-emsmdt' and path == 'html/apps/hospital.js' then return moduleFile end
    return nil
end
local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end
SetTimeout = function() end
QBCore = QBCoreMock
-- a promise that stays pending unless resolved (what a callback that never answers looks like)
promise = { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen = Citizen or {}
Citizen.Await = function(p) return p.value end

local DIR = '[pfscripts]/pf-emsmdt/'

-- ── pf-devices ──────────────────────────────────────────────────────────────────────────────────
local Dev
local function resetDev() Dev = { apps = {}, handlers = {}, pushes = {}, jobPushes = {} } end
resetDev()
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) Dev.apps[def.id] = def return true end,
    RegisterAppHandlers = function(_, id, map) Dev.handlers[id] = map return true end,
    Push = function(_, src, app, event, payload) Dev.pushes[#Dev.pushes + 1] = { src = src, app = app, event = event, payload = payload } end,
    PushToJob = function(_, job, app, event, payload, onduty) Dev.jobPushes[#Dev.jobPushes + 1] = { job = job, app = app, event = event, payload = payload, onduty = onduty } end,
}

-- ── pf-ambulancejob by contract ─────────────────────────────────────────────────────────────────
local AJ
local function resetAJ()
    AJ = {
        calls = {}, cb = {},
        facilities = { pillbox = 'Pillbox Medical Center', paleto = 'Paleto Bay Medical Center', bolingbroke = 'Bolingbroke Infirmary' },
        order = { 'pillbox', 'paleto' },
        admissions = {
            pillbox = {
                { id = 11, citizenid = 'PAT1', hospitalId = 'pillbox', state = 'checked_in', mode = 'staff', triage = 'orange', reason = 'checkin', arrivedAt = 1699999000, open = true },
                { id = 12, citizenid = 'OFF1', hospitalId = 'pillbox', state = 'admitted', mode = 'staff', triage = 'green', dept = 'ward', bedId = 'w1', arrivedAt = 1699990000, admittedAt = 1699991000, open = true },
            },
            paleto = { { id = 21, citizenid = 'PAT2', hospitalId = 'paleto', state = 'waiting', open = true } },
        },
        closed = { pillbox = { { id = 9, citizenid = 'OLD1', hospitalId = 'pillbox', state = 'discharged', dischargedAt = 1699000000, open = false } } },
        custody = { OFF1 = 'order' },
        orders = { { id = 70, citizenid = 'PAT1', admissionId = 11, hospitalId = 'pillbox', kind = 'lab', test = 'cbc', label = 'Complete blood count', state = 'resulted',
            result = { values = { hemoglobin = 9.1 } } }, { id = 71, citizenid = 'PAT1', admissionId = 11, hospitalId = 'pillbox', kind = 'imaging', test = 'ct', state = 'ordered' } },
        discharge = { ok = true, admissionId = 11 },
    }
end
resetAJ()
local function rec(name, ...) AJ.calls[#AJ.calls + 1] = { name = name, args = table.pack(...) } end
local function callsNamed(name)
    local out = {}
    for _, c in ipairs(AJ.calls) do if c.name == name then out[#out + 1] = c end end
    return out
end
Mock.exportsByResource['pf-ambulancejob'] = {
    GetHospitalStatus = function(_, id)
        rec('GetHospitalStatus', id)
        local key = type(id) == 'number' and AJ.order[id] or id
        if not AJ.facilities[key] then return { ok = false, error = 'not_found' } end
        return { ok = true, hospitalId = key, label = AJ.facilities[key], staffOnDuty = 3, aiActive = false,
            beds = { ward = { total = 3, free = 2 }, ed = { total = 5, free = 5 } } }
    end,
    ListAdmissions = function(_, id, filter)
        rec('ListAdmissions', id, filter)
        if filter and filter.open == false then
            local list = {}
            for _, a in ipairs(AJ.admissions[id] or {}) do list[#list + 1] = a end
            for _, a in ipairs(AJ.closed[id] or {}) do list[#list + 1] = a end
            return { ok = true, list = list }
        end
        return { ok = true, list = AJ.admissions[id] or {} }
    end,
    IsInCustodyCare = function(_, cid) if AJ.custody[cid] then return true, AJ.custody[cid], 'pillbox' end return false end,
    ListHospitalOrders = function(_, id, filter)
        rec('ListHospitalOrders', id, filter)
        local list = {}
        for _, o in ipairs(AJ.orders) do if o.hospitalId == id then list[#list + 1] = o end end
        return { ok = true, list = list }
    end,
    DischargePatient = function(_, id, opts) rec('DischargePatient', id, opts) return AJ.discharge end,
}
-- server callbacks as pfm-core holds them (funcrefs into pf-ambulancejob)
local function ajCallback(name, answer)
    return Mock.funcref(function(src, cb, ...)
        rec('cb:' .. name, src, ...)
        local res = answer and answer(src, ...)
        if res ~= false then cb(res or AJ.cb[name] or { ok = true }) end
    end)
end
QBCoreMock.ServerCallbacks = {}
for _, n in ipairs({ 'triage', 'admit', 'transfer', 'careLevel', 'labOrder', 'labDraw', 'imagingOrder', 'orderCancel', 'patientOrders',
    'rxPrescribe', 'rxCancel', 'pharmacyLog' }) do
    QBCoreMock.ServerCallbacks['pf-ambulancejob:server:' .. n] = ajCallback(n)
end
QBCoreMock.ServerCallbacks['pf-ambulancejob:server:imagingPerform'] = ajCallback('imagingPerform', function()
    return { ok = true, orderId = 71, findings = { { label = '<img src=x onerror=alert(1)>', structure = 'femur_l' } } }
end)

-- ── SQL (bills, bill lines, counter queue, offline names) ───────────────────────────────────────
local Sql
local function resetSql() Sql = { log = {}, rows = {}, single = nil } end
resetSql()
MySQL = {
    query = { await = function(sql, params)
        Sql.log[#Sql.log + 1] = { sql = sql, params = params }
        for key, rows in pairs(Sql.rows) do if sql:find(key, 1, true) then return rows end end
        return {}
    end },
    single = { await = function(sql, params) Sql.log[#Sql.log + 1] = { sql = sql, params = params } return Sql.single end },
}
local function sqlNamed(part)
    for _, s in ipairs(Sql.log) do if s.sql:find(part, 1, true) then return s end end
end

-- ── players ─────────────────────────────────────────────────────────────────────────────────────
local MED, PATIENT, CIV, CHIEF = 1, 5, 6, 7
local function setJob(src, name, onduty, grade) Mock.players[src].PlayerData.job = { name = name, onduty = onduty, grade = { level = grade or 1 } } end
local function setupPlayers()
    Mock.players = {}
    Mock.newPlayer(MED, 'MED1'); setJob(MED, 'ambulance', true, 1)
    Mock.newPlayer(PATIENT, 'PAT1')
    Mock.newPlayer(CIV, 'CIV1'); setJob(CIV, 'police', true, 4)
    Mock.newPlayer(CHIEF, 'CHIEF1'); setJob(CHIEF, 'ambulance', true, 4)
end

local function loadAll()
    Config, PFHospitalApp = nil, nil
    load_resource(DIR .. 'config.lua')
    load_resource(DIR .. 'server/hospital_app.lua')
    load_resource(DIR .. 'server/devices.lua')
end

BeforeEach = function()
    resetDev(); resetAJ(); resetSql(); setupPlayers()
    resState['pf-ambulancejob'], resState['pf-devices'] = 'started', 'started'
    moduleFile = 'PFApps.register("hospital", {})'
    threads = {}
    loadAll()
end

local function rpc(method, src, payload)
    return Mock.cross(function(s, p) return PFHospitalApp.Handlers[method](s, p) end, src, payload or {})
end

describe('b21 hospital app: registration', function()
    it('devices.lua registers the module app for on-duty staff with its handlers', function()
        Mock.fireEvent('onResourceStart', nil, 'pf-emsmdt')
        local app = Dev.apps.hospital
        assert_true(app ~= nil, 'registered')
        assert_eq(app.kind, 'module')
        assert_eq(app.entry, 'html/apps/hospital.js')
        assert_eq(app.styles[1], 'html/apps/hospital.css')
        assert_eq(app.access.jobs.ambulance, 0)
        assert_eq(app.access.onduty, true)
        assert_true(Dev.apps.emsmdt ~= nil, 'the MDT app is still registered')
        for _, m in ipairs({ 'init', 'board', 'history', 'triage', 'admit', 'transfer', 'careLevel', 'discharge', 'orders', 'labOrder', 'labDraw',
            'imagingOrder', 'imagingPerform', 'orderCancel', 'results', 'prescribe', 'rxCancel', 'controlledLog', 'pharmacy', 'bills', 'billLines' }) do
            assert_true(Mock.callable(Dev.handlers.hospital[m]), 'handler ' .. m)
        end
    end)
    it('no app while the module file is missing', function()
        moduleFile = nil
        Mock.fireEvent('onResourceStart', nil, 'pf-emsmdt')
        assert_true(Dev.apps.hospital == nil)
        assert_true(Dev.apps.emsmdt ~= nil)
    end)
end)

describe('b21 hospital app: who may use it (re-read on the server)', function()
    it('refuses off-duty staff and other jobs before asking pf-ambulancejob', function()
        setJob(MED, 'ambulance', false, 1)
        assert_eq(rpc('init', MED).error, 'not_on_duty')
        assert_eq(rpc('board', MED, { facility = 'pillbox' }).error, 'not_on_duty')
        assert_eq(rpc('triage', CIV, { facility = 'pillbox', admissionId = 11, level = 'red' }).error, 'not_staff')
        assert_eq(#callsNamed('cb:triage'), 0)
        assert_eq(#callsNamed('ListAdmissions'), 0)
    end)
    it('a duty change between calls is seen on the next call', function()
        assert_true(rpc('board', MED, { facility = 'pillbox' }).ok)
        setJob(MED, 'ambulance', false, 1)
        assert_eq(rpc('board', MED, { facility = 'pillbox' }).error, 'not_on_duty')
    end)
    it('init lists the facilities pf-ambulancejob knows and the pages; bills only for supervisors', function()
        local res = rpc('init', MED)
        assert_true(res.ok)
        assert_eq(#res.facilities, 3)
        assert_eq(res.facilities[1].id, 'pillbox')
        assert_eq(res.facilities[3].id, 'bolingbroke')
        assert_eq(res.facility, 'pillbox')
        local hasBills = false
        for _, p in ipairs(res.pages) do if p == 'bills' then hasBills = true end end
        assert_false(hasBills, 'grade 1 has no bills page')
        assert_eq(res.me.supervisor, false)
        local chief = rpc('init', CHIEF)
        assert_eq(chief.pages[#chief.pages], 'bills')
        assert_eq(chief.me.supervisor, true)
        assert_eq(#res.options.triage, 5)
    end)
    it('init remembers the facility last looked at', function()
        rpc('init', MED)
        rpc('board', MED, { facility = 'paleto' })
        assert_eq(rpc('init', MED).facility, 'paleto')
    end)
    it('pf-ambulancejob stopped: an honest offline answer', function()
        resState['pf-ambulancejob'] = 'missing'
        assert_eq(rpc('init', MED).error, 'hospital_offline')
    end)
end)

describe('b21 hospital app: board', function()
    it('beds, staff and admissions with names, online state and custody', function()
        rpc('init', MED)
        local res = rpc('board', MED, { facility = 'pillbox' })
        assert_true(res.ok)
        assert_eq(res.beds[1].dept, 'ed')
        assert_eq(res.beds[2].free, 2)
        assert_eq(res.staffOnDuty, 3)
        assert_eq(#res.admissions, 2)
        local a, b = res.admissions[1], res.admissions[2]
        assert_eq(a.name, 'Test Player5')
        assert_eq(a.online, true)
        assert_eq(b.online, false)
        assert_eq(b.custody, 'order')
        assert_true(a.custody == nil)
        assert_true(sqlNamed('FROM players WHERE citizenid IN') ~= nil, 'offline names from the players table')
    end)
    it('an unknown facility is refused', function()
        assert_eq(rpc('board', MED, { facility = 'nowhere' }).error, 'bad_args')
        assert_eq(rpc('board', MED, { facility = '../x' }).error, 'bad_args')
    end)
    it('history filters by state on the server', function()
        local res = rpc('history', MED, { facility = 'pillbox', state = 'discharged' })
        assert_true(res.ok)
        assert_eq(#res.admissions, 1)
        assert_eq(res.admissions[1].id, 9)
        assert_eq(rpc('history', MED, { facility = 'pillbox', state = 'bogus' }).error, 'bad_args')
        local call = callsNamed('ListAdmissions')
        assert_eq(call[#call].args[2].open, false)
    end)
end)

describe('b21 hospital app: actions relay to pf-ambulancejob as the player', function()
    it('triage: the patient id comes from the admission, never from the client', function()
        local res = rpc('triage', MED, { facility = 'pillbox', admissionId = 11, level = 'red', target = 99 })
        assert_true(res.ok)
        local c = callsNamed('cb:triage')[1]
        assert_eq(c.args[1], MED)
        assert_eq(c.args[2], PATIENT)
        assert_eq(c.args[3], 'red')
    end)
    it('the answer of pf-ambulancejob is returned as it is (refusals included)', function()
        AJ.cb.triage = { ok = false, error = 'too_far', message = 'Stand next to the patient.' }
        local res = rpc('triage', MED, { facility = 'pillbox', admissionId = 11, level = 'red' })
        assert_eq(res.ok, false)
        assert_eq(res.error, 'too_far')
        assert_eq(res.message, 'Stand next to the patient.')
    end)
    it('an admission of another facility or an offline patient is not relayed', function()
        assert_eq(rpc('triage', MED, { facility = 'pillbox', admissionId = 21, level = 'red' }).error, 'not_found')
        assert_eq(rpc('triage', MED, { facility = 'pillbox', admissionId = 12, level = 'red' }).error, 'patient_offline')
        assert_eq(#callsNamed('cb:triage'), 0)
    end)
    it('admit, transfer and care level pass the admission id from the server', function()
        assert_true(rpc('admit', MED, { facility = 'pillbox', admissionId = 11, dept = 'ward', bedId = 'w2' }).ok)
        local c = callsNamed('cb:admit')[1]
        assert_eq(c.args[2], 11); assert_eq(c.args[3], 'ward'); assert_eq(c.args[4], 'w2')
        assert_eq(rpc('admit', MED, { facility = 'pillbox', admissionId = 11, dept = 'ward', bedId = 'w 2;' }).error, 'bad_args')
        assert_true(rpc('transfer', MED, { facility = 'pillbox', admissionId = 12, to = 'paleto' }).ok)
        assert_eq(callsNamed('cb:transfer')[1].args[3].hospitalId, 'paleto')
        assert_eq(rpc('transfer', MED, { facility = 'pillbox', admissionId = 12, to = 'mars' }).error, 'bad_args')
        assert_true(rpc('careLevel', MED, { facility = 'pillbox', admissionId = 12, level = 'icu' }).ok)
        assert_eq(callsNamed('cb:careLevel')[1].args[3], 'icu')
    end)
    it('lab and imaging orders and prescriptions target the patient resolved on the server', function()
        assert_true(rpc('labOrder', MED, { facility = 'pillbox', admissionId = 11, test = 'cbc' }).ok)
        assert_eq(callsNamed('cb:labOrder')[1].args[2], PATIENT)
        assert_true(rpc('imagingOrder', MED, { facility = 'pillbox', admissionId = 11, test = 'ct' }).ok)
        assert_true(rpc('prescribe', MED, { facility = 'pillbox', admissionId = 11, drug = 'painkillers', units = 4, fills = 2, note = ' take with food ' }).ok)
        local rx = callsNamed('cb:rxPrescribe')[1]
        assert_eq(rx.args[2], PATIENT); assert_eq(rx.args[3], 'painkillers'); assert_eq(rx.args[4], 4); assert_eq(rx.args[5], 2)
        assert_eq(rx.args[6], 'take with food')
        assert_true(rpc('labDraw', MED, { orderId = 70 }).ok)
        assert_eq(callsNamed('cb:labDraw')[1].args[2], 70)
        assert_true(rpc('orderCancel', MED, { orderId = 71 }).ok)
        assert_true(rpc('rxCancel', MED, { rxId = 5 }).ok)
        assert_eq(rpc('labDraw', MED, { orderId = 'x' }).error, 'bad_args')
    end)
    it('results go through the chart check of patientOrders with the citizen id of the admission', function()
        assert_true(rpc('results', MED, { facility = 'pillbox', admissionId = 12 }).ok)
        assert_eq(callsNamed('cb:patientOrders')[1].args[2], 'OFF1')
    end)
    it('a callback that never answers is reported, not taken as done', function()
        QBCoreMock.ServerCallbacks['pf-ambulancejob:server:triage'] = ajCallback('triage', function() return false end)
        assert_eq(rpc('triage', MED, { facility = 'pillbox', admissionId = 11, level = 'red' }).error, 'no_answer')
    end)
    it('a callback that is missing or throws answers honestly', function()
        QBCoreMock.ServerCallbacks['pf-ambulancejob:server:labDraw'] = nil
        assert_eq(rpc('labDraw', MED, { orderId = 70 }).error, 'hospital_offline')
        QBCoreMock.ServerCallbacks['pf-ambulancejob:server:labDraw'] = Mock.funcref(function() error('boom') end)
        assert_eq(rpc('labDraw', MED, { orderId = 70 }).error, 'server_error')
    end)
end)

describe('b21 hospital app: discharge', function()
    it('DischargePatient with this player as the actor, a key per admission and cleaned orders', function()
        local orders = { restrictions = {}, followUpHours = '48', note = '  rest  ', prescriptions = { { drug = 'antibiotics', units = 2, fills = 1, extra = 'x' } } }
        for i = 1, 10 do orders.restrictions[i] = { kind = 'no_drive', hours = 24, reason = 'r', evil = true } end
        local res = rpc('discharge', MED, { facility = 'pillbox', admissionId = 11, orders = orders })
        assert_true(res.ok)
        local c = callsNamed('DischargePatient')[1]
        assert_eq(c.args[1], 11)
        local opts = c.args[2]
        assert_eq(opts.actor.src, MED)
        assert_eq(opts.key, 'pf-emsmdt:hospital:discharge:11')
        assert_eq(#opts.orders.restrictions, 8)
        assert_true(opts.orders.restrictions[1].evil == nil)
        assert_eq(opts.orders.followUpHours, 48)
        assert_eq(opts.orders.note, 'rest')
        assert_eq(opts.orders.prescriptions[1].drug, 'antibiotics')
        assert_true(opts.orders.prescriptions[1].extra == nil)
    end)
    it('no prescriptions key when none are given (a nurse may discharge)', function()
        rpc('discharge', MED, { facility = 'pillbox', admissionId = 11, orders = { prescriptions = {} } })
        assert_true(callsNamed('DischargePatient')[1].args[2].orders.prescriptions == nil)
    end)
    it('pf-ambulancejob refusals come back; non-staff never reach it', function()
        AJ.discharge = { ok = false, error = 'no_permission', message = 'Prescriptions need a physician as the actor.' }
        local res = rpc('discharge', MED, { facility = 'pillbox', admissionId = 11, orders = {} })
        assert_eq(res.error, 'no_permission')
        rpc('discharge', CIV, { facility = 'pillbox', admissionId = 11, orders = {} })
        assert_eq(#callsNamed('DischargePatient'), 1)
    end)
end)

describe('b21 hospital app: queues', function()
    it('the lab queue leaves results out and adds names', function()
        local res = rpc('orders', MED, { facility = 'pillbox', kind = 'lab' })
        assert_true(res.ok)
        assert_eq(#res.orders, 1)
        assert_eq(res.orders[1].hasResult, true)
        assert_true(res.orders[1].result == nil, 'results only through the chart check')
        assert_eq(res.orders[1].name, 'Test Player5')
        local c = callsNamed('ListHospitalOrders')[1]
        assert_eq(c.args[2].kind, 'lab'); assert_eq(c.args[2].open, true)
        assert_eq(rpc('orders', MED, { facility = 'pillbox', kind = 'surgery' }).error, 'bad_args')
    end)
    it('imaging: the scan runs off the RPC and its outcome is pushed to the player', function()
        local res = rpc('imagingPerform', MED, { orderId = 71 })
        assert_true(res.ok and res.started)
        assert_eq(#threads, 1)
        assert_eq(rpc('imagingPerform', MED, { orderId = 71 }).error, 'busy')
        threads[1]()
        assert_eq(callsNamed('cb:imagingPerform')[1].args[2], 71)
        local push = Dev.pushes[1]
        assert_eq(push.src, MED); assert_eq(push.app, 'hospital'); assert_eq(push.event, 'imaging')
        assert_eq(push.payload.ok, true)
        assert_eq(push.payload.findings[1].structure, 'femur_l')
        assert_true(PFHospitalApp.scanning[MED] == nil, 'free for the next scan')
    end)
    it('the controlled-substance log is relayed (tier and position checked there) with names', function()
        AJ.cb.pharmacyLog = { ok = true, hospitalId = 'pillbox', list = { { id = 1, drug = 'morphine', qty = 1, kind = 'withdraw', citizenid = 'PAT1', byCid = 'MED1', at = 1 } } }
        local res = rpc('controlledLog', MED)
        assert_true(res.ok)
        assert_eq(res.list[1].patient, 'Test Player5')
        assert_eq(res.list[1].by, 'Test Player1')
        assert_eq(callsNamed('cb:pharmacyLog')[1].args[1], MED)
    end)
    it('the counter queue is a paged SELECT of the facility with search', function()
        Sql.rows['FROM pf_hosp_prescriptions'] = { { id = 3, citizenid = 'ANN9', drug = 'painkillers', qty = 3, units_per_fill = 4, dispensed = 1, controlled = 0,
            created_at = 1, expires_at = 2000000000 } }
        Sql.rows['FROM players WHERE charinfo'] = { { citizenid = 'ANN9' } }
        Sql.rows['FROM players WHERE citizenid IN'] = { { citizenid = 'ANN9', charinfo = '{"firstname":"Ann","lastname":"Lee"}' } }
        local res = rpc('pharmacy', MED, { facility = 'pillbox', q = 'Ann', page = 2 })
        assert_true(res.ok)
        assert_eq(res.list[1].name, 'Ann Lee')
        assert_eq(res.list[1].label, 'Painkillers')
        assert_eq(res.list[1].filled, 1)
        assert_eq(sqlNamed('FROM players WHERE charinfo').params[1], '%Ann%')
        local s = sqlNamed('FROM pf_hosp_prescriptions')
        assert_true(not s.sql:find('JOIN', 1, true), 'no cross-table citizen id comparison')
        assert_eq(s.params[1], 'pillbox')
        assert_eq(s.params[3], 'Ann')
        assert_eq(s.params[4], 'ANN9')
        assert_eq(s.params[#s.params], 25, 'offset of page 2')
        assert_eq(s.params[#s.params - 1], 26, 'one more row than a page tells whether there is a next page')
    end)
    it('LIKE wildcards in a search are literal', function()
        rpc('pharmacy', MED, { facility = 'pillbox', q = '50%_x' })
        assert_eq(sqlNamed('FROM players WHERE charinfo').params[1], '%50\\%\\_x%')
    end)
end)

describe('b21 hospital app: bills (supervisors)', function()
    it('refused below supervisor grade without touching the database', function()
        assert_eq(rpc('bills', MED, { facility = 'pillbox' }).error, 'no_permission')
        assert_eq(rpc('billLines', MED, { billId = 1 }).error, 'no_permission')
        assert_eq(#Sql.log, 0)
    end)
    it('paged by state and search; the due amount is total minus coverage', function()
        Sql.rows['FROM pf_hosp_bills'] = { { id = 8, citizenid = 'ANN9', admission_id = 11, total = 900, discount = 450, state = 'invoiced', created_at = 5 } }
        Sql.rows['FROM players WHERE citizenid IN'] = { { citizenid = 'ANN9', charinfo = '{"firstname":"Ann","lastname":"Lee"}' } }
        local res = rpc('bills', CHIEF, { facility = 'pillbox', state = 'invoiced', q = 'PAT1' })
        assert_true(res.ok)
        assert_eq(res.list[1].due, 450)
        assert_eq(res.list[1].name, 'Ann Lee')
        assert_eq(res.more, false)
        local s = sqlNamed('FROM pf_hosp_bills WHERE hospital_id')
        assert_eq(s.params[1], 'pillbox'); assert_eq(s.params[2], 'invoiced'); assert_eq(s.params[3], 'PAT1')
        assert_eq(rpc('bills', CHIEF, { facility = 'pillbox', state = 'stolen' }).error, 'bad_args')
    end)
    it('lines only of a bill of a known facility', function()
        Sql.single = { id = 8, hospital_id = 'elsewhere', total = 1, discount = 0, state = 'paid' }
        assert_eq(rpc('billLines', CHIEF, { billId = 8 }).error, 'not_found')
        Sql.single = { id = 8, hospital_id = 'pillbox', total = 900, discount = 450, state = 'paid' }
        Sql.rows['FROM pf_hosp_bill_lines'] = { { kind = 'bed', label = 'Ward', qty = 3, unit_price = 100 } }
        local res = rpc('billLines', CHIEF, { billId = 8 })
        assert_true(res.ok)
        assert_eq(res.lines[1].amount, 300)
    end)
end)

describe('b21 hospital app: live boards', function()
    it('admission changes and results reach open apps of on-duty staff (ids and state only)', function()
        TriggerEvent('pf-ambulancejob:server:admissionChanged', { id = 11, hospitalId = 'pillbox', state = 'admitted', citizenid = 'PAT1', reason = 'x' }, 'triaged', 'admitted')
        local p = Dev.jobPushes[1]
        assert_eq(p.job, 'ambulance'); assert_eq(p.app, 'hospital'); assert_eq(p.event, 'changed'); assert_eq(p.onduty, true)
        assert_eq(p.payload.admissionId, 11); assert_eq(p.payload.state, 'admitted')
        assert_true(p.payload.citizenid == nil, 'no patient data in the push')
        TriggerEvent('pf-ambulancejob:server:orderResulted', { id = 70, hospitalId = 'pillbox', kind = 'lab', result = { values = {} } })
        assert_eq(Dev.jobPushes[2].event, 'orders')
        assert_true(Dev.jobPushes[2].payload.result == nil)
    end)
end)
