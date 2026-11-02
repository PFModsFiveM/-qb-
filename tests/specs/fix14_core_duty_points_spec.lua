-- pfm-core duty points (batch 14: DUTY-1). Going on duty through QBCore:ToggleDuty needs the
-- player's server position at a duty point a resource registered for their job or job type; going
-- off duty works anywhere; one toggle per 3 s; a job with no registered point cannot clock in through
-- the event. pfm-policejob registers its desks for every 'leo' job, pf-ambulancejob for 'ambulance'.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.ClientCallbacks = {}
QBCoreMock.ServerCallbacks = {}
QBCoreMock.Commands.List = {}
QBCoreMock.Players = {}
QBCoreMock.UsableItems = {}
QBCoreMock.Shared.IsFunction = function(v) return type(v) == 'function' end
promise = { new = function() local p = {} function p:resolve(...) self.value = ... end return p end }
Citizen.Await = function() end
load_resource('pfm-core/server/events.lua')
local core = Mock.exportsByResource['__self']

local COP, MEDIC, MECH = 1, 2, 3
local DESK = vector3(440.085, -974.924, 30.689)
local EMS_DESK = vector3(311.18, -599.25, 43.29)
local function register(resource, spec)
    Mock.invokingResource = resource
    local ok, n = core.RegisterDutyPoints(spec)
    Mock.invokingResource = nil
    return ok, n
end
local function duty(src) return Mock.players[src].PlayerData.job.onduty end
local function toggle(src)
    Mock.gameTimer = Mock.gameTimer + 5000
    Mock.fireNet('QBCore:ToggleDuty', src)
end
local function newWorker(src, job, jobType)
    local p = Mock.newPlayer(src)
    p.PlayerData.job = { name = job, type = jobType, onduty = false }
    p.Functions.SetJobDuty = function(on) p.PlayerData.job.onduty = on == true end
    return p
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.eventHandlers['onResourceStop']('pfm-policejob')
    Mock.eventHandlers['onResourceStop']('pf-ambulancejob')
    register('pfm-policejob', { type = 'leo', points = { DESK, vector3(-449.811, 6012.909, 31.815) }, radius = 2.5 })
    register('pf-ambulancejob', { job = 'ambulance', points = { EMS_DESK }, radius = 2.5 })
    newWorker(COP, 'police', 'leo')
    newWorker(MEDIC, 'ambulance', 'ems')
    newWorker(MECH, 'mechanic', 'mechanic')
    Mock.coords[COP] = vector3(-1000, 500, 60)    -- at home
    Mock.coords[MEDIC] = vector3(-1000, 500, 60)
    Mock.coords[MECH] = vector3(-1000, 500, 60)
end

describe('clocking in', function()
    it('from home is refused and the client\'s flag is put back', function()
        toggle(COP)
        assert_eq(duty(COP), false)
        local back = Mock.clientEventsNamed('QBCore:Client:SetDuty')
        assert_eq(#back, 1)
        assert_eq(back[1].args[1], false)
        assert_eq(#Mock.serverEvents, 0, 'no QBCore:Server:SetDuty for a refused toggle')
    end)
    it('at a registered desk of the job type works', function()
        Mock.coords[COP] = DESK + vector3(1.5, 0, 0)
        toggle(COP)
        assert_eq(duty(COP), true)
        Mock.coords[MEDIC] = EMS_DESK
        toggle(MEDIC)
        assert_eq(duty(MEDIC), true)
    end)
    it('a medic cannot clock in at a police desk', function()
        Mock.coords[MEDIC] = DESK
        toggle(MEDIC)
        assert_eq(duty(MEDIC), false)
    end)
    it('clocking out works anywhere', function()
        Mock.coords[COP] = DESK
        toggle(COP)
        Mock.coords[COP] = vector3(-1000, 500, 60)
        toggle(COP)
        assert_eq(duty(COP), false)
    end)
    it('one toggle per 3 seconds', function()
        Mock.coords[COP] = DESK
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('QBCore:ToggleDuty', COP)
        Mock.fireNet('QBCore:ToggleDuty', COP)
        assert_eq(duty(COP), true)
    end)
    it('a job no resource registered points for cannot clock in through the event', function()
        Mock.coords[MECH] = DESK
        toggle(MECH)
        assert_eq(duty(MECH), false)
    end)
    it('the points go when their resource stops', function()
        Mock.eventHandlers['onResourceStop']('pfm-policejob')
        Mock.coords[COP] = DESK
        toggle(COP)
        assert_eq(duty(COP), false)
    end)
    it('bad registrations are refused', function()
        assert_false((register('x', { points = { DESK } })))                       -- neither job nor type
        assert_false((register('x', { job = 'a', type = 'b', points = { DESK } })))
        assert_false((register('x', { job = 'police', points = { { x = 'a' } } })))
        assert_false((register('x', { job = 'police', points = {} })))
        assert_false((register('x', 'police')))
    end)
    it('IsAtDutyPoint answers for the player\'s own job', function()
        assert_false(core.IsAtDutyPoint(COP))
        Mock.coords[COP] = DESK
        assert_true(core.IsAtDutyPoint(COP))
    end)
end)

describe('the job resources register their desks', function()
    it('pfm-policejob for every leo job, pf-ambulancejob for the ambulance', function()
        local calls = {}
        Mock.exportsByResource['pfm-core'].RegisterDutyPoints = function(_, spec) calls[#calls + 1] = spec return true end
        local savedSelf = Mock.exportsByResource['__self']
        Mock.exportsByResource['__self'] = {}
        Config = nil
        QBCoreMock.Commands.Add = function() end
        load_resource('pfm-policejob/config.lua')
        load_resource('pfm-policejob/server/main.lua')
        assert_eq(#calls, 1)
        assert_eq(calls[1].type, 'leo')
        assert_eq(#calls[1].points, #Config.Locations['duty'])
        -- again when pfm-core restarts
        Mock.eventHandlers['onResourceStart']('pfm-core')
        assert_eq(#calls, 2)
        Mock.exportsByResource['__self'] = savedSelf
    end)
end)
