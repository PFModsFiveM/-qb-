-- Batch 22 (22C) pf-emsmdt on MariaDB: PCR lists are paged and sorted by the server.
-- pf_emsmdt:pcr:list { scope, citizenId, sort = 'newest' | 'oldest', cursor } answers Config.PCR.ListLimit
-- rows and `next` (the cursor of the following page; none on the last page), for "my reports" (lead or
-- crew line) and a patient's reports; a page of a patient's reports keeps paging past rows the viewer
-- may not see (the cursor comes from the rows read). Bad sort or cursor values are refused.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetConvar(_, default) return default end
local resState = { ['pf-ambulancejob'] = 'started' }
function GetResourceState(r) return resState[r] or 'missing' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
Mock.exportsByResource['oxmysql'] = {}

local AJ = { admissions = {}, deny = false }
Mock.exportsByResource['pf-ambulancejob'] = {
    GetPatientSummary = function(_, cid) return { ok = true, cid = cid, consciousness = 'alert', vitals = { hr = 88, sbp = 120, dbp = 80, rr = 16, spo2 = 98, temp = 36.9, gcs = 15, pain = 2 } } end,
    GetAdmission = function(_, cid) return { ok = true, admission = AJ.admissions[cid] } end,
    GetMedicalRecord = function() if AJ.deny then return { ok = false, error = 'no_permission' } end return { ok = true, record = {} } end,
}

local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end
SetTimeout = function() end
Wait = function() end
function GetCurrentResourceName() return 'pf-emsmdt' end

local DIR = '[pfscripts]/pf-emsmdt/'
local function loadAll()
    Config, PFEmsSchema, PFEmsPcr, PFEmsUnits, PFEmsDispatch = nil, nil, nil, nil, nil
    load_resource(DIR .. 'config.lua')
    load_resource(DIR .. 'shared/framework.lua')
    load_resource(DIR .. 'server/schema.lua')
    load_resource(DIR .. 'server/main.lua')
    load_resource(DIR .. 'server/units.lua')
    load_resource(DIR .. 'server/pcr.lua')
    threads = {}
    local ok = PFEmsSchema.Apply()
    local t = threads
    threads = {}
    for _, fn in ipairs(t) do fn() end
    return ok
end

local function count(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local function tableExists(name) return count('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { name }) > 0 end
local function versions()
    local out = {}
    for _, r in ipairs(MySQL.query.await("SELECT version FROM pf_schema_migrations WHERE resource = 'pf-emsmdt' ORDER BY version") or {}) do out[#out + 1] = tonumber(r.version) end
    return table.concat(out, ',')
end
local function wipe()
    for _, t in ipairs({ 'pf_emsmdt_pcr_entries', 'pf_emsmdt_pcr', 'pf_emsmdt_units' }) do MySQL.query.await(('DROP TABLE IF EXISTS `%s`'):format(t)) end
    MySQL.query.await('DROP TABLE IF EXISTS pf_schema_migrations')
end

local MED1, MED2, NURSE, PAT = 1, 2, 3, 4
local function setJob(src, name, onduty, grade) Mock.players[src].PlayerData.job = { name = name, onduty = onduty, grade = { level = grade or 1 } } end
local function players()
    Mock.players = {}
    Mock.newPlayer(MED1, 'MED1'); setJob(MED1, 'ambulance', true)
    Mock.newPlayer(MED2, 'MED2'); setJob(MED2, 'ambulance', true)
    Mock.newPlayer(NURSE, 'NURSE1'); setJob(NURSE, 'ambulance', true, 2)
    Mock.newPlayer(PAT, 'PAT1')
    for s = 1, 4 do Mock.coords[s] = vector3(1.0, 1.0, 1.0) end
end
local function treat(cid, id, by, at)
    Mock.invokingResource = 'pf-ambulancejob'
    TriggerEvent('pf-ambulancejob:server:treatmentApplied', cid, { id = id, action = 'chest_seal', byCid = by, at = at or Mock.clock, result = 'applied' })
    Mock.invokingResource = nil
end
local function cb(name, src, data) Mock.gameTimer = Mock.gameTimer + 5000 return Mock.callCallback(name, src, data) end

BeforeEach = function()
    Mock.reset()
    Mock.clock = 1800000000
    AJ.admissions, AJ.deny = {}, false
    players()
end


local function pcr(cid, lead, at)
    return tonumber(MySQL.insert.await([[INSERT INTO pf_emsmdt_pcr (citizenid, lead_cid, state, created_at, updated_at)
        VALUES (?, ?, 'closed', ?, ?)]], { cid, lead, at, at }))
end
local function ids(list)
    local out = {}
    for _, p in ipairs(list or {}) do out[#out + 1] = tostring(p.id) end
    return table.concat(out, ',')
end

local made = {}
describe('22C PCR list paging and sort (MariaDB)', function()
    it('pages "my reports" newest first with the server cursor, and oldest first', function()
        assert_true(loadAll())
        Config.PCR.ListLimit = 3
        MySQL.query.await('DELETE FROM pf_emsmdt_pcr')
        for i = 1, 7 do made[i] = pcr('PAT1', 'MED1', Mock.clock + i) end
        -- MED2 is crew on one report of MED1 (a charted line), and leads none
        MySQL.insert.await("INSERT INTO pf_emsmdt_pcr_entries (pcr_id, kind, ref_id, by_cid, summary, at) VALUES (?, 'note', 1, 'MED2', 'x', ?)", { made[2], Mock.clock })
        local p1 = cb('pf_emsmdt:pcr:list', MED1, {})
        assert_true(p1.ok, tostring(p1.error))
        assert_eq(ids(p1.list), table.concat({ made[7], made[6], made[5] }, ','))
        assert_eq(p1.next, made[5])
        assert_eq(p1.sort, 'newest')
        local p2 = cb('pf_emsmdt:pcr:list', MED1, { cursor = p1.next })
        assert_eq(ids(p2.list), table.concat({ made[4], made[3], made[2] }, ','))
        local p3 = cb('pf_emsmdt:pcr:list', MED1, { cursor = p2.next })
        assert_eq(ids(p3.list), tostring(made[1]))
        assert_eq(p3.next, nil, 'last page')
        local o1 = cb('pf_emsmdt:pcr:list', MED1, { sort = 'oldest' })
        assert_eq(ids(o1.list), table.concat({ made[1], made[2], made[3] }, ','))
        local o2 = cb('pf_emsmdt:pcr:list', MED1, { sort = 'oldest', cursor = o1.next })
        assert_eq(ids(o2.list), table.concat({ made[4], made[5], made[6] }, ','))
        local crew = cb('pf_emsmdt:pcr:list', MED2, {})
        assert_eq(ids(crew.list), tostring(made[2]))
        assert_eq(crew.next, nil)
    end)

    it('pages a patient\'s reports; hidden rows do not stop the paging', function()
        -- NURSE may not see the record: only reports they crewed (none) -> empty pages that still page
        AJ.deny = true
        local n1 = cb('pf_emsmdt:pcr:list', NURSE, { scope = 'patient', citizenId = 'PAT1' })
        assert_true(n1.ok)
        assert_eq(#n1.list, 0)
        assert_eq(n1.next, made[5], 'the cursor of the rows read')
        AJ.deny = false
        local a1 = cb('pf_emsmdt:pcr:list', NURSE, { scope = 'patient', citizenId = 'PAT1', sort = 'oldest' })
        assert_eq(ids(a1.list), table.concat({ made[1], made[2], made[3] }, ','))
        local a2 = cb('pf_emsmdt:pcr:list', NURSE, { scope = 'patient', citizenId = 'PAT1', sort = 'oldest', cursor = a1.next })
        assert_eq(ids(a2.list), table.concat({ made[4], made[5], made[6] }, ','))
    end)

    it('refuses an unknown sort and a bad cursor', function()
        assert_eq(cb('pf_emsmdt:pcr:list', MED1, { sort = 'random' }).error, 'bad_args')
        assert_eq(cb('pf_emsmdt:pcr:list', MED1, { cursor = 'x' }).error, 'bad_args')
        assert_eq(cb('pf_emsmdt:pcr:list', MED1, { cursor = -4 }).error, 'bad_args')
        Config.PCR.ListLimit = 25
    end)
end)
