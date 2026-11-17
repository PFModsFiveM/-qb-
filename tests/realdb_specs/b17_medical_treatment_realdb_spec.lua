-- pf-ambulancejob batch 17B on a real database: the treatment engine writes its log rows into
-- pf_med_treatments (created by 17C's v5) with the statement it runs in game; a refused treatment
-- writes nothing; the stage change and the wound flags reach pf_med_injuries through the
-- write-behind; a CPR session writes one 'started' row, not one per tick.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState(res) return res == 'pf-government' and 'missing' or 'started' end
function GetCurrentResourceName() return 'pf-ambulancejob' end
function GetEntityHealth() return 200 end
function GetPedArmour() return 0 end
-- FiveM runs every handler of an event; the mock keeps one per name, so this spec chains them
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
local Items = {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, src, item, n)
        local have = (Items[src] or {})[item] or 0
        if have < (n or 1) then return false end
        Items[src][item] = have - (n or 1)
        return true
    end,
    AddItem = function() return true end,
}
QBCoreMock.Functions.HasItem = function(src, item, n) return ((Items[src] or {})[item] or 0) >= (n or 1) end
Mock.exportsByResource['pf-services'] = { CloseByRef = function() return { ok = true } end }

local AJ = '[pfscripts]/pf-ambulancejob/'
load_resource(AJ .. 'config.lua')
load_resource(AJ .. 'config_medical.lua')
load_resource(AJ .. 'shared/framework.lua')
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'treatments' }) do
    load_resource(AJ .. 'shared/medical/' .. f .. '.lua')
end
load_resource(AJ .. 'server/injury_database.lua')
for _, f in ipairs({ 'schema', 'store', 'engine', 'downstate', 'effects', 'api', 'treatment' }) do
    load_resource(AJ .. 'server/medical/' .. f .. '.lua')
end
PFMed.Engine.Random = function() return 0.5 end
PFMed.Treat.Random = function() return 0.99 end
Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
assert(PFMed.Schema.Start(), 'schema')

local PATIENT, MEDIC = 1, 2
local function online(src, cid, job)
    local p = Mock.newPlayer(src, cid)
    if job then p.PlayerData.job = job end
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function rows() return MySQL.query.await('SELECT * FROM pf_med_treatments ORDER BY id') end

describe('treatment log on a real database', function()
    Mock.clock = 1700000000
    online(PATIENT, 'RTPATIENT1')
    online(MEDIC, 'RTMEDIC1', { name = 'ambulance', onduty = true, grade = { level = 1 } })
    Mock.coords[PATIENT] = vector3(10.0, 10.0, 10.0)
    Mock.coords[MEDIC] = vector3(11.0, 10.0, 10.0)

    it('an applied treatment is one row with the server-side facts; a refused one writes nothing', function()
        local inj = assert(PFMed.Engine.AddInjury('RTPATIENT1', { mechanism = 'edged', type = 'laceration', subtype = 'arterial', region = 'thigh_l', severity = 3 }, {}))
        local res = Mock.callCallback('pf-ambulancejob:server:treat', MEDIC, { target = PATIENT, action = 'tourniquet', region = 'thigh_l', req = 'rt-1' })
        assert_false(res.ok, 'no tourniquet held')
        assert_eq(#rows(), 0)
        Items[MEDIC] = { tourniquet = 1 }
        Mock.clock = Mock.clock + 5
        res = Mock.callCallback('pf-ambulancejob:server:treat', MEDIC, { target = PATIENT, action = 'tourniquet', region = 'thigh_l', req = 'rt-2' })
        assert_true(res.ok, tostring(res.message))
        local list = rows()
        assert_eq(#list, 1)
        local r = list[1]
        assert_eq(r.citizenid, 'RTPATIENT1')
        assert_eq(tonumber(r.injury_id), inj.id)
        assert_eq(r.action, 'tourniquet')
        assert_eq(r.by_cid, 'RTMEDIC1')
        assert_eq(r.by_job, 'ambulance')
        assert_eq(r.location, 'field')
        assert_eq(r.req, 'rt-2')
        assert_eq(r.result, 'applied')
        assert_eq(tonumber(r.at), os.time())
        assert_eq(json.decode(r.items).tourniquet, 1)
        assert_eq(json.decode(r.params).region, 'thigh_l')
        assert_eq(tonumber(res.id), tonumber(r.id))
        -- the wound's new stage and flags are written behind
        PFMed.Store.Flush()
        local row = MySQL.single.await('SELECT stage, treatments FROM pf_med_injuries WHERE id = ?', { inj.id })
        assert_eq(row.stage, 'stabilized')
        assert_true(tonumber(json.decode(row.treatments).tourniquet) ~= nil)
        local ev = tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_med_events WHERE citizenid = 'RTPATIENT1' AND action = 'treatment'"))
        assert_eq(ev, 1)
    end)
    it('a hidden-injury action with nothing to find is logged as no_effect', function()
        Items[MEDIC] = { c_collar = 1 }
        Mock.clock = Mock.clock + 10
        local res = Mock.callCallback('pf-ambulancejob:server:treat', MEDIC, { target = PATIENT, action = 'c_collar' })
        assert_true(res.ok)
        local list = rows()
        assert_eq(list[#list].action, 'c_collar')
        assert_eq(list[#list].result, 'no_effect')
        assert_eq(list[#list].req, nil)
    end)
    it('a CPR session writes one started row however many ticks arrive', function()
        local p = PFMed.Store.Peek('RTPATIENT1')
        PFMed.Engine.SetConsciousness('RTPATIENT1', 'unconscious', 'report', 'test', { holdSeconds = 600 })
        p.blood_ml = 2300
        PFMed.Engine.Evaluate(p, os.time())
        assert_eq(p.consciousness, 'arrest')
        local before = #rows()
        for _ = 1, 5 do
            Mock.clock = Mock.clock + 5
            assert_true(Mock.callCallback('pf-ambulancejob:server:cprTick', MEDIC, PATIENT).ok)
        end
        local list = rows()
        assert_eq(#list, before + 1)
        assert_eq(list[#list].action, 'cpr')
        assert_eq(list[#list].result, 'started')
    end)
end)
