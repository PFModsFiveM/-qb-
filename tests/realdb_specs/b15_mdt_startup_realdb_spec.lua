-- pf-policemdt-DEV first boot on an empty database (batch 15): the roster defaults and the CCTV
-- start-up wait for server/schema.lua instead of querying tables that do not exist yet, and every
-- static camera from the config is saved with its own camera_key (before, only the first one
-- could be, because the key was left out). Batch-14 behaviour stays: a camera is switched off only
-- by an officer near it.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

RealDB.exec('pfm-core/qbcore.sql')
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

-- oxmysql's export API over the real database; an SQL error is answered with nil, like oxmysql
local sqlErrors, oxCalls = {}, 0
local function ox(kind)
    return function(_, sql, params, cb)
        oxCalls = oxCalls + 1
        if Mock.callable(params) then cb, params = params, nil end
        local ok, r = pcall(MySQL[kind].await, sql, params)
        if not ok then sqlErrors[#sqlErrors + 1] = tostring(r) r = nil end
        if cb then cb(r) end
        return r
    end
end
Mock.exportsByResource['oxmysql'] = { execute = ox('query'), query = ox('query'), fetch = ox('query'), insert = ox('insert'), update = ox('update'), scalar = ox('scalar'), single = ox('single') }

QBCoreMock.Shared.Jobs = { police = { label = 'Police', grades = { ['0'] = {}, ['4'] = { isboss = true } } } }
function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
Config.CCTV.Enabled = true
Config.CCTVStaticCameras = {
    { model_hash = 168901740, x = 100.0, y = 200.0, z = 30.0, heading = 90.0, label = 'Static A' },
    { model_hash = 168901740, x = 500.0, y = 600.0, z = 31.0, heading = 180.0, label = 'Static B' },
}
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/schema.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/roster.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/cctv.lua')

local function scalar(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) end

describe('first boot on an empty database', function()
    it('the roster defaults wait for the schema, then fill the empty roster', function()
        assert_eq(PFMdtSchema.state, 'idle', 'nothing ran the schema yet (threads do not run here)')
        assert_true(PFMdtRoster.StartupDefaults())
        assert_eq(PFMdtSchema.state, 'ready')
        assert_eq(#sqlErrors, 0, table.concat(sqlErrors, ' | '))
        assert_true(scalar('SELECT COUNT(*) FROM pf_mdt_roster') > 10)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_mdt_roster WHERE callsign = '1A-01'"), 1)
        -- a second start keeps the lines as they are
        local n = scalar('SELECT COUNT(*) FROM pf_mdt_roster')
        assert_true(PFMdtRoster.StartupDefaults())
        assert_eq(scalar('SELECT COUNT(*) FROM pf_mdt_roster'), n)
    end)

    it('the CCTV start loads the seeded cameras and saves every config camera with its own key', function()
        MySQL.query.await("UPDATE pf_mdt_cctv_cameras SET status = 'OFFLINE' WHERE camera_key = 'seed_0001'")
        assert_true(PFMdtCctv.Start())
        assert_eq(#sqlErrors, 0, table.concat(sqlErrors, ' | '))
        assert_eq(MySQL.scalar.await("SELECT status FROM pf_mdt_cctv_cameras WHERE camera_key = 'seed_0001'"), 'ONLINE', 'start-up resets cameras to ONLINE')
        assert_eq(scalar("SELECT COUNT(*) FROM pf_mdt_cctv_cameras WHERE location_label IN ('Static A', 'Static B')"), 2, 'both config cameras saved')
        assert_eq(scalar("SELECT COUNT(*) FROM pf_mdt_cctv_cameras WHERE camera_key = '' OR camera_key IS NULL"), 0)
        assert_eq(scalar("SELECT COUNT(DISTINCT camera_key) FROM pf_mdt_cctv_cameras WHERE location_label IN ('Static A', 'Static B')"), 2)
        local total = scalar('SELECT COUNT(*) FROM pf_mdt_cctv_cameras')
        assert_eq(total, 126)
        -- the next start finds them by key and saves nothing twice
        assert_true(PFMdtCctv.Start())
        assert_eq(scalar('SELECT COUNT(*) FROM pf_mdt_cctv_cameras'), total)
    end)

    it('a config camera can be reported offline, only by an officer near it', function()
        local id = scalar("SELECT id FROM pf_mdt_cctv_cameras WHERE location_label = 'Static B'")
        local cop = Mock.newPlayer(1, 'COP1')
        cop.PlayerData.job = { name = 'police', label = 'Police', onduty = true, grade = { level = 2 } }
        Mock.coords[1] = vector3(5000.0, 5000.0, 30.0)
        Mock.fireNet('pf_mdt:cctv:setCameraOffline', 1, { id = id })
        assert_eq(MySQL.scalar.await('SELECT status FROM pf_mdt_cctv_cameras WHERE id = ?', { id }), 'ONLINE', 'from across the map')
        Mock.coords[1] = vector3(505.0, 600.0, 31.0)
        Mock.gameTimer = Mock.gameTimer + 100000
        Mock.fireNet('pf_mdt:cctv:setCameraOffline', 1, { id = id })
        assert_eq(MySQL.scalar.await('SELECT status FROM pf_mdt_cctv_cameras WHERE id = ?', { id }), 'OFFLINE')
    end)

    it('a schema that failed keeps both start-ups away from the database', function()
        PFMdtSchema.state = 'failed'
        oxCalls = 0
        assert_false(PFMdtRoster.StartupDefaults())
        assert_false(PFMdtCctv.Start())
        assert_eq(oxCalls, 0)
        PFMdtSchema.state = 'ready'
    end)
end)
