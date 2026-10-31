-- pf-mechanicjob: a mechanic orders a tow for the car next to them; the request is built on the
-- server (plate checked against a real car beside the mechanic, server position), paid by the shop.
load_resource('tests/lua/ledger_env.lua')
local plates = {}
function GetVehicleNumberPlateText(v) return plates[v] end
function GetAllVehicles() local out = {} for v in pairs(plates) do out[#out + 1] = v end return out end
function GetVehicleEngineHealth() return 0.0 end
function GetVehicleBodyHealth() return 0.0 end

local requests = {}
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function(_, opts) requests[#requests + 1] = opts return { ok = true, id = #requests } end,
}
local started = { ['pf-services'] = true, ['pfm-banking'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

LedgerEnv.load('pf-mechanicjob', { '[pfscripts]/pf-mechanicjob/config.lua' })
load_resource('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')

local MECH, CIV, CAR = 1, 2, 500
local AT = vector3(300.0, 300.0, 30.0)

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, plates, requests = {}, {}, {}, {}
    local m = Mock.newPlayer(MECH, 'MECHCID')
    m.PlayerData.job = { name = 'mechanic', label = 'LS Customs', onduty = true }
    Mock.newPlayer(CIV).PlayerData.job = { name = 'unemployed', onduty = true }
    Mock.coords[MECH], Mock.coords[CIV] = AT, AT
    plates[CAR] = 'BROKE01'
    Mock.coords[CAR] = vector3(302.0, 300.0, 30.0)
end

local function ask(src, payload) Mock.fireNet('pf-mechanicjob:server:advanced:requestTow', src, payload) end

describe('mechanic tow order', function()
    it('creates a tow.recovery request for the car beside the mechanic, paid by the shop', function()
        ask(MECH, { plate = 'BROKE01', reason = 'critical_engine_failure', coords = { x = 0, y = 0, z = 0 } })
        assert_eq(#requests, 1)
        local r = requests[1]
        assert_eq(r.kind, 'tow.recovery')
        assert_eq(r.plate, 'BROKE01')
        assert_eq(r.payer, 'society:mechanic')
        assert_near(r.coords.x, 302.0, 0.01, 'position of the real car, not the client value')
        assert_eq(r.ref.id, 'BROKE01')
    end)

    it('refuses non-mechanics, off-duty mechanics, cars that are not next to them, and spam', function()
        ask(CIV, { plate = 'BROKE01' })
        Mock.players[MECH].PlayerData.job.onduty = false
        ask(MECH, { plate = 'BROKE01' })
        Mock.players[MECH].PlayerData.job.onduty = true
        ask(MECH, { plate = 'NOSUCH' })
        Mock.coords[CAR] = vector3(400.0, 300.0, 30.0)
        ask(MECH, { plate = 'BROKE01' })
        ask(MECH, 'not a table')
        assert_eq(#requests, 0)
        Mock.coords[CAR] = vector3(302.0, 300.0, 30.0)
        ask(MECH, { plate = 'BROKE01' })
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 1, 'one order a minute')
    end)
end)
