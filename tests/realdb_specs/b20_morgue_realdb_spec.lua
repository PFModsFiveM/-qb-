-- pf-ambulancejob morgue (batch 20B) on a real database: pf_med_death_records as 20A's v8 creates
-- it, and every statement of server/hospital/morgue.lua: the keyed intake (one record per
-- citizen), examine once, release once, the case link set once / cleared, revoke of an intake only,
-- character deletion keeping case-linked records, the deceased set, the injuries present at death,
-- the logged level changes and the care in the fatal window; then the whole flow on real rows
-- (engine death -> /markdeceased -> autopsy -> case link -> release) and a restart that rebuilds the
-- deceased set and re-sends the case link.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
STARTED = { ['pf-policemdt-DEV'] = true }
function GetResourceState(res) return STARTED[res] and 'started' or 'missing' end
function GetEntityHealth() return 200 end
function GetPedArmour() return 0 end
function GetEntityAttachedTo() return 0 end
function SetEntityCoords() end
Bags = {}
function Player(src)
    Bags[src] = Bags[src] or {}
    local b = Bags[src]
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

-- pf-policemdt-DEV AttachExternalRecord by its 18E contract (keyed by target + record)
MDT = { links = {}, calls = 0 }
Mock.exportsByResource['pf-policemdt-DEV'] = {
    AttachExternalRecord = function(_, target, ref)
        MDT.calls = MDT.calls + 1
        if not target.caseId or target.caseId ~= 77 then return { ok = false, error = 'not_found' } end
        local key = target.caseId .. ':' .. ref.type .. ':' .. tostring(ref.id)
        if MDT.links[key] then return { ok = true, duplicate = true } end
        MDT.links[key] = true
        return { ok = true, linkId = MDT.calls }
    end,
}

function GetCurrentResourceName() return 'pf-ambulancejob' end
Config = nil
load_resource('pfm-banking/payouts.lua')
local AJ = '[pfscripts]/pf-ambulancejob/'
for _, f in ipairs({ 'config.lua', 'config_medical.lua', 'config_hospital.lua', 'shared/framework.lua', 'shared/medical/anatomy.lua',
    'shared/medical/injuries.lua', 'shared/medical/physiology_model.lua', 'shared/medical/effects_model.lua', 'server/main.lua' }) do
    load_resource(AJ .. f)
end

MySQL.query.await([[CREATE TABLE IF NOT EXISTS players (citizenid VARCHAR(50) NOT NULL PRIMARY KEY, charinfo LONGTEXT NULL)]])

local function restart()
    Mock.eventHandlers['QBCore:Server:PlayerLoaded'] = nil
    Mock.eventHandlers['pfm-core:server:characterDeleted'] = nil
    PFHospital = nil
    for _, f in ipairs({ 'server/medical/schema.lua', 'server/medical/store.lua', 'server/medical/engine.lua', 'server/medical/downstate.lua',
        'server/medical/effects.lua', 'server/medical/api.lua', 'server/hospital/facility.lua', 'server/hospital/beds.lua',
        'server/hospital/admissions.lua', 'server/hospital/billing.lua', 'server/hospital/ai_care.lua', 'server/hospital/morgue.lua' }) do
        load_resource(AJ .. f)
    end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    PFMed.Engine.Random = function() return 0.5 end
    assert(PFMed.Schema.Start(), 'medical tables')
    assert(PFHospital.Admissions.Start(), 'hospital ready')
    assert(PFHospital.Morgue.Start(), 'morgue ready')
    PFHospital.Morgue.RegisterCommands()
    return PFHospital
end

local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end
local function one(sql, params) return MySQL.single.await(sql, params) end

local H = restart()
local Q, M = H.SQL, H.Morgue

local function char(cid, first, last)
    MySQL.query.await('INSERT IGNORE INTO players (citizenid, charinfo) VALUES (?, ?)', { cid, json.encode({ firstname = first, lastname = last }) })
end
local function insert(cid, at, extra)
    extra = extra or {}
    return Q.MorgueInsert({ citizenid = cid, cause = M.PENDING_CAUSE, tod_from = extra.from or at, tod_to = extra.to or at, findings = extra.findings,
        created_at = at, hospital_id = 'pillbox', idem_key = M.KeyOf(cid) })
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    Mock.invokingResource = nil
end

describe('pf_med_death_records (v8)', function()
    it('exists with the columns the morgue uses and the per-citizen key', function()
        for _, c in ipairs({ 'id', 'citizenid', 'cause', 'manner', 'tod_from', 'tod_to', 'examiner_cid', 'findings', 'case_ref', 'state', 'created_at',
            'released_at', 'hospital_id', 'idem_key' }) do
            assert_eq(count('SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
                { 'pf_med_death_records', c }), 1, c)
        end
        assert_eq(count([[SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_med_death_records'
            AND COLUMN_NAME = 'idem_key' AND NON_UNIQUE = 0]]), 1)
    end)
end)

describe('statements', function()
    it('intake once per citizen; get, latest, list, open, deceased set', function()
        local t = os.time()
        local id = insert('RDBD1', t, { from = t - 300, to = t - 60 })
        assert_true(id > 0)
        assert_false((pcall(insert, 'RDBD1', t)), 'the key allows one record per citizen')
        local r = Q.MorgueByKey(M.KeyOf('RDBD1'))
        assert_eq(tonumber(r.id), id)
        assert_eq(r.state, 'intake')
        assert_eq(r.manner, 'pending')
        assert_eq(tonumber(r.tod_from), t - 300)
        assert_eq(tonumber(Q.MorgueGet(id).tod_to), t - 60)
        assert_eq(tonumber(Q.MorgueLatestOf('RDBD1').id), id)
        assert_eq(#Q.MorgueListOf('RDBD1', 10), 1)
        local open = Q.MorgueOpen(50)
        assert_true(#open >= 1)
        local found = false
        for _, d in ipairs(Q.MorgueDeceased(5000)) do if d.citizenid == 'RDBD1' and tonumber(d.id) == id then found = true end end
        assert_true(found)
    end)
    it('examine once, release once (only after the exam)', function()
        local t = os.time()
        local id = insert('RDBD2', t)
        assert_eq(Q.MorgueRelease(id, t), 0, 'not examined yet')
        assert_eq(Q.MorgueExamine(id, 'Cause', 'homicide', 'RDBME', '{"autopsy":{}}'), 1)
        assert_eq(Q.MorgueExamine(id, 'Other', 'accident', 'RDBME', '{}'), 0)
        local r = Q.MorgueGet(id)
        assert_eq(r.state, 'examined')
        assert_eq(r.cause, 'Cause')
        assert_eq(r.manner, 'homicide')
        assert_eq(r.examiner_cid, 'RDBME')
        assert_eq(Q.MorgueRelease(id, t + 5), 1)
        assert_eq(Q.MorgueRelease(id, t + 6), 0)
        assert_eq(tonumber(Q.MorgueGet(id).released_at), t + 5)
        for _, d in ipairs(Q.MorgueOpen(50)) do assert_true(tonumber(d.id) ~= id, 'released bodies leave the register') end
    end)
    it('case link set once (same value again is fine), cleared only while it holds that ref; linked rows listed', function()
        local t = os.time()
        local id = insert('RDBD3', t)
        assert_eq(Q.MorgueSetCase(id, 'case:77'), 1)
        assert_eq(Q.MorgueSetCase(id, 'case:77'), 1)
        assert_eq(Q.MorgueSetCase(id, 'case:78'), 0)
        local listed = false
        for _, r in ipairs(Q.MorgueLinked(t - 1, 200)) do if tonumber(r.id) == id and r.case_ref == 'case:77' then listed = true end end
        assert_true(listed)
        assert_eq(#Q.MorgueLinked(t + 1, 200) > 0 and 1 or 0, 0)
        assert_eq(Q.MorgueClearCase(id, 'case:78'), 0)
        assert_eq(Q.MorgueClearCase(id, 'case:77'), 1)
        assert_eq(Q.MorgueGet(id).case_ref, nil)
    end)
    it('revoke: an unexamined, unlinked intake only; character deletion keeps case-linked records', function()
        local t = os.time()
        local a = insert('RDBD4', t)
        local b = insert('RDBD5', t)
        Q.MorgueSetCase(b, 'case:77')
        local c = insert('RDBD6', t)
        Q.MorgueExamine(c, 'x', 'natural', 'RDBME', '{}')
        assert_eq(Q.MorgueDeleteIntake(b), 0, 'linked')
        assert_eq(Q.MorgueDeleteIntake(c), 0, 'examined')
        assert_eq(Q.MorgueDeleteIntake(a), 1)
        assert_eq(Q.MorgueDeleteCharacter('RDBD5'), 0)
        assert_true(Q.MorgueGet(b) ~= nil)
        assert_eq(Q.MorgueDeleteCharacter('RDBD6'), 1)
        assert_eq(Q.MorgueGet(c), nil)
    end)
    it('injuries present at death, level changes and care in a window, names', function()
        local t = os.time()
        local function inj(sev, created, recovered, stage)
            return MySQL.insert.await([[INSERT INTO pf_med_injuries (citizenid, type, subtype, region, structure, severity, stage, mechanism, created_at, recovered_at)
                VALUES ('RDBINJ', 'gunshot', 'penetrating', 'chest_l', 'heart', ?, ?, 'firearm', ?, ?)]], { sev, stage or 'injured', created, recovered })
        end
        local open = inj(4, t - 100, nil)
        local healedLater = inj(2, t - 5000, t + 100, 'recovered')
        inj(3, t - 9000, t - 4000, 'recovered') -- healed before the death
        inj(5, t + 50, nil)                       -- after the death
        local rows = Q.MorgueInjuriesAt('RDBINJ', t, 40)
        assert_eq(#rows, 2)
        assert_eq(tonumber(rows[1].id), open, 'most severe first')
        assert_eq(tonumber(rows[2].id), healedLater)
        MySQL.insert.await("INSERT INTO pf_med_events (citizenid, action, detail, at) VALUES ('RDBINJ', 'state', ?, ?)", { '{"from":"alert","to":"unconscious","cause":"gcs"}', t - 90 })
        MySQL.insert.await("INSERT INTO pf_med_events (citizenid, action, detail, at) VALUES ('RDBINJ', 'state', ?, ?)", { '{"from":"unconscious","to":"arrest","cause":"hemorrhage"}', t - 60 })
        MySQL.insert.await("INSERT INTO pf_med_events (citizenid, action, detail, at) VALUES ('RDBINJ', 'injury', '{}', ?)", { t - 80 })
        MySQL.insert.await("INSERT INTO pf_med_events (citizenid, action, detail, at) VALUES ('RDBINJ', 'state', ?, ?)", { '{"from":"arrest","to":"dead","cause":"arrest_timeout"}', t })
        local ev = Q.MorgueStateEvents('RDBINJ', t - 1000, t, 200)
        assert_eq(#ev, 3)
        local ep = M.EpisodeFromEvents(ev)
        assert_eq(ep.deathAt, t)
        assert_eq(ep.onset, t - 90)
        assert_eq(ep.physCause, 'hemorrhage')
        MySQL.insert.await("INSERT INTO pf_med_treatments (citizenid, action, location, result, at) VALUES ('RDBINJ', 'cpr', 'field', 'ok', ?)", { t - 30 })
        MySQL.insert.await("INSERT INTO pf_med_treatments (citizenid, action, location, result, at) VALUES ('RDBINJ', 'sutures', 'hospital', 'ok', ?)", { t - 90000 })
        local care = Q.MorgueTreatments('RDBINJ', t - 1800, t + 60, 20)
        assert_eq(#care, 1)
        assert_eq(care[1].action, 'cpr')
        char('RDBNAME1', 'Jane', 'Roe')
        char('RDBNAME2', 'Max', 'Moe')
        assert_eq(#Q.MorgueNames({ 'RDBNAME1', 'RDBNAME2', 'RDBNONE' }), 2)
        assert_eq(#Q.MorgueNames({}), 0)
        assert_eq(Q.MorgueCharacter('RDBNONE'), nil)
        assert_true(Q.MorgueCharacter('RDBNAME1') ~= nil)
    end)
end)

describe('the flow on real rows', function()
    it('engine death -> character kill -> autopsy -> case link -> release; restart keeps the deceased set and re-sends the link', function()
        local VICTIM, ME, ADMIN = 1, 2, 3
        local v = Mock.newPlayer(VICTIM, 'RDBVIC')
        v.PlayerData.charinfo = { firstname = 'Rob', lastname = 'Real' }
        v.Functions.Logout = function() v.loggedOut = true end
        char('RDBVIC', 'Rob', 'Real')
        Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, v)
        local me = Mock.newPlayer(ME, 'RDBME')
        me.PlayerData.job = { name = 'ambulance', onduty = true, grade = { level = 2 } }
        Mock.newPlayer(ADMIN, 'RDBADM')
        Mock.aces[ADMIN] = { admin = true }
        Mock.coords[ME] = vector3(275.45, -1361.11, 24.54)
        Mock.coords[VICTIM] = vector3(0, 0, 0)
        local inj = PFMed.Engine.AddInjury('RDBVIC', { mechanism = 'firearm', type = 'gunshot', subtype = 'penetrating', structure = 'brain', severity = 4,
            attackerCid = 'RDBKILLER' }, { key = 'rdb:gsw:1' })
        assert_true(inj ~= nil)
        for _ = 1, 200 do
            Mock.clock = Mock.clock + 5
            PFMed.Engine.Tick(os.time()); PFMed.Down.Tick(os.time())
            local p = PFMed.Store.Peek('RDBVIC')
            if p and p.consciousness == 'dead' then break end
        end
        assert_eq(PFMed.Store.Peek('RDBVIC').consciousness, 'dead')
        local deadAt = PFMed.Store.Peek('RDBVIC').dead_at
        Commands.markdeceased(ADMIN, { tostring(VICTIM), 'killed', 'in', 'rp' })
        Commands.markdeceased(ADMIN, { 'confirm' })
        assert_true(v.loggedOut)
        local row = one('SELECT * FROM pf_med_death_records WHERE citizenid = ?', { 'RDBVIC' })
        assert_eq(row.state, 'intake')
        assert_eq(tonumber(row.tod_to), deadAt)
        assert_eq(json.decode(row.findings).intake.physCause, 'head_trauma')
        local id = tonumber(row.id)
        local cb = function(name, ...) return Mock.callCallback('pf-ambulancejob:server:' .. name, ME, ...) end
        assert_true(cb('morgueAutopsyStart', id).ok)
        Mock.clock = Mock.clock + M.Cfg().ExamSeconds
        local res = cb('morgueAutopsy', id)
        assert_true(res.ok, tostring(res.message))
        row = one('SELECT * FROM pf_med_death_records WHERE id = ?', { id })
        assert_eq(row.state, 'examined')
        assert_eq(row.manner, 'homicide')
        assert_eq(row.cause, 'Traumatic brain injury due to gunshot wound (penetrating) of the brain')
        assert_eq(row.examiner_cid, 'RDBME')
        Mock.clock = Mock.clock + 2
        assert_eq(cb('morgueLinkCase', id, '5').error, 'not_found')
        Mock.clock = Mock.clock + 2
        assert_true(cb('morgueLinkCase', id, '77').ok)
        assert_eq(one('SELECT case_ref FROM pf_med_death_records WHERE id = ?', { id }).case_ref, 'case:77')
        assert_true(cb('morgueRelease', id, 'Family').ok)
        assert_eq(one('SELECT state FROM pf_med_death_records WHERE id = ?', { id }).state, 'released')
        -- restart: the deceased set comes back from the rows and the case link is re-sent (duplicate)
        H = restart()
        Q, M = H.SQL, H.Morgue
        assert_true((M.IsDeceased('RDBVIC')))
        assert_true(M.pending[id] ~= nil)
        M.RetryTick()
        assert_eq(M.pending[id], nil)
        -- character deletion keeps the case-linked record
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'RDBVIC')
        assert_eq(count('SELECT COUNT(*) FROM pf_med_death_records WHERE citizenid = ?', { 'RDBVIC' }), 1)
    end)
end)
