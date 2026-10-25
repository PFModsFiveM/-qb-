-- pf-computer dispatcher actions and commands not covered before (wage-cap command, stash placement,
-- dark web and job board writes), and pf-rentals' admin command and rental length.
load_resource('tests/lua/ledger_env.lua')

-- ── pf-computer ───────────────────────────────────────────────────
local saved = {}
function LoadResourceFile() return nil end
function SaveResourceFile(_, path, content) saved[path] = content return true end
QBCoreMock.Shared.Jobs = { burgershot = { label = 'Burger Shot', grades = {} }, police = { label = 'Police', grades = {} } }
local govPerms = {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm) return govPerms[src] ~= nil and govPerms[src][perm] == true end,
}
Config = nil
load_resource('[pfscripts]/pf-computer/config/config.lua')
local pcConfig = Config
load_resource('[pfscripts]/pf-computer/server/main.lua')

-- ── pf-rentals ────────────────────────────────────────────────────
function IsModelInCdimage() return true end
function IsModelAVehicle() return true end
function CreateVehicleServerSetter() return 7000 end
function SetVehicleOnGroundProperly() end
function SetVehicleEngineHealth() end
function SetVehicleBodyHealth() end
function SetVehicleDirtLevel() end
function SetVehicleEngineOn() end
Mock.exportsByResource['oxmysql'] = { execute = function() end }
LedgerEnv.load('pf-rentals', { '[pfscripts]/pf-rentals/config.lua', '[pfscripts]/pf-rentals/server/integration.lua' })
local rentalsConfig = Config
rentalsConfig.Debug, rentalsConfig.UseQBVehicleKeys = false, false

local BOSS, COP, MAYOR, P = 1, 2, 3, 4
local function call(src, action, payload)
    Mock.gameTimer = Mock.gameTimer + 100000
    local before = #Mock.clientEvents
    Mock.fireNet('pf-computer:server:callback', src, 'id1', action, payload or {})
    for i = #Mock.clientEvents, before + 1, -1 do
        local e = Mock.clientEvents[i]
        if e.name == 'pf-computer:client:callback' then return e.args[2] end
    end
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Config = pcConfig
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    govPerms = {}
    local boss = Mock.newPlayer(BOSS, 'BOSS1')
    boss.PlayerData.job = { name = 'burgershot', label = 'Burger Shot', grade = { level = 4 }, isboss = true }
    local cop = Mock.newPlayer(COP, 'COP1')
    cop.PlayerData.job = { name = 'police', grade = { level = 0 }, isboss = false }
    local mayor = Mock.newPlayer(MAYOR, 'MAYOR1')
    mayor.PlayerData.job = { name = 'government', grade = { level = 4 }, isboss = true }
    govPerms[MAYOR] = { budgets = true, audit = true }
    Mock.newPlayer(P, 'RENT1').PlayerData.money = { cash = 0, bank = 100000 }
end

describe('pf-computer', function()
    it('the wage-cap command needs the government budgets permission, not any government job', function()
        Mock.rawCommands['pc_setwagecap'](COP, { '0', '99999' })
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 1)
        assert_eq(Mock.clientEventsNamed('QBCore:Notify')[1].args[1], 'Not authorized.')
        Mock.reset()
        Mock.rawCommands['pc_setwagecap'](MAYOR, { '0', '120' })
        assert_eq(Mock.clientEventsNamed('QBCore:Notify')[1].args[2], 'success')
    end)
    it('a business stash is placed where the boss stands, and only so many', function()
        Mock.coords[BOSS] = vector3(10.0, 10.0, 10.0)
        local res = call(BOSS, 'business:stash:place', { coords = { x = 900.0, y = 900.0, z = 10.0 } })
        assert_eq(res.error, 'invalid_coords')
        for i = 1, 10 do
            assert_true(call(BOSS, 'business:stash:place', { coords = { x = 10.0, y = 10.0, z = 10.0 } }).ok)
        end
        assert_eq(call(BOSS, 'business:stash:place', { coords = { x = 10.0, y = 10.0, z = 10.0 } }).error, 'too_many_stashes')
    end)
    it('dark web rooms are short names and limited in number; messages are bounded', function()
        assert_eq(call(P, 'darkweb:chat:join', { room = string.rep('x', 500) }).error, 'invalid_room')
        assert_eq(call(P, 'darkweb:chat:post', { room = { 'x' }, message = 'hi' }).error, 'invalid_room')
        local res = call(P, 'darkweb:chat:post', { room = 'market', message = string.rep('m', 5000) })
        assert_true(res.ok)
        assert_eq(#res.data.message, 500)
        local made = 0
        for i = 1, 60 do if call(P, 'darkweb:chat:join', { room = 'room' .. i }).ok then made = made + 1 end end
        assert_true(made < 60, 'room count capped')
    end)
    it('job applications need a real post and are bounded', function()
        assert_eq(call(P, 'jobs:apply', { jobId = 999, name = 'Sam' }).error, 'job_not_found')
        local job = call(BOSS, 'jobs:create', { title = 'Cook' }).data
        local res = call(P, 'jobs:apply', { jobId = job.id, name = string.rep('n', 900), message = { 'x' } })
        assert_true(res.ok)
        assert_eq(#res.data.name, 60)
        assert_eq(res.data.message, '')
    end)
end)

describe('pf-rentals', function()
    it('expiring everyone\'s rentals is for server admins, not any boss', function()
        Mock.rawCommands['expirerentals'](BOSS, {}, '')
        assert_eq(Mock.clientEvents[1].args[1].args[1], 'Error')
        Mock.reset()
        Mock.aces[BOSS] = { command = true }
        Mock.rawCommands['expirerentals'](BOSS, {}, '')
        assert_eq(Mock.clientEvents[1].args[1].args[1], 'Admin')
    end)
    it('a fractional day is not rented for free', function()
        Config = rentalsConfig
        Mock.coords[P] = rentalsConfig.RentalLocations[1].coords
        local car = rentalsConfig.RentalVehicles[1]
        Mock.fireNet('pf-rentals:confirmRental', P, { vehicleId = car.id, duration = '1.9' })
        local rented = Mock.clientEventsNamed('pf-rentals:rentedVehicle')[1].args[1]
        assert_eq(rented.duration, 1)
        assert_eq(rented.expirationTime, Mock.clock + 86400)
    end)
end)
