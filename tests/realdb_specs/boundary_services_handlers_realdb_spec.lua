-- pf-services request handlers registered through the RegisterRequestHandler export, as the worker
-- resources (pf-jobs, pf-mechanicjob, pf-government, pfm-policejob) do: their functions arrive as
-- function references. They must be kept and called: a dropped canComplete let a verified kind
-- complete (and pay) without the worker resource's proof.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
local invoking = nil
function GetInvokingResource() return invoking end

-- the bank
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
assert(PFLedger.Start(), 'ledger start')

Mock.exportsByResource['pf-devices'] = {
    PushToJob = function() return 1 end,
    PushToCitizen = function() return true end,
    RegisterApp = function() return true end,
    RegisterAppHandlers = function() return true end,
}

-- pf-services, with its own exports table
function GetCurrentResourceName() return 'pf-services' end
Mock.exportsByResource['__self'] = {}
Config = {}
load_resource('pfm-banking/payouts.lua')
load_resource('[pfscripts]/pf-services/shared/catalog.lua')
load_resource('[pfscripts]/pf-services/shared/config.lua')
load_resource('[pfscripts]/pf-services/server/schema.lua')
load_resource('[pfscripts]/pf-services/server/events.lua')
load_resource('[pfscripts]/pf-services/server/requests.lua')
load_resource('[pfscripts]/pf-services/server/apps.lua')
load_resource('[pfscripts]/pf-services/server/main.lua')
Mock.exportsByResource['pf-services'] = Mock.exportsByResource['__self']
assert(RunMigrations('pf-services', PFServices.Migrations))
local services = exports['pf-services']

local CITIZEN, TOW1 = 1, 2
local function bank(src) return Mock.players[src].PlayerData.money.bank end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    MySQL.query.await('DELETE FROM pf_service_requests')
    PFServices.__resetRequests()
    invoking = 'pf-jobs'
    Mock.newPlayer(CITIZEN, 'CIT1').PlayerData.money = { cash = 0, bank = 1000 }
    local t1 = Mock.newPlayer(TOW1, 'TOW1')
    t1.PlayerData.job = { name = 'tow', onduty = true, grade = { level = 0 } }
    t1.PlayerData.money = { cash = 0, bank = 0 }
    for src in pairs(Mock.players) do Mock.players[src].PlayerData.source = src end
    Mock.coords[CITIZEN] = vector3(100.0, 200.0, 30.0)
    Mock.vehicleOf[CITIZEN] = 500
    Mock.plates[500] = ' CAR1 '
end

describe('a request handler from another resource', function()
    it('its canComplete decides completion, and its hooks are called', function()
        local done, accepted, completed = false, {}, {}
        local ok, err = services:RegisterRequestHandler('tow.recovery', {
            canComplete = function(req, src, proof) return done and proof.atShop == true, 'not_at_shop' end,
            onAccepted = function(req, src) accepted[#accepted + 1] = { id = req.id, src = src } end,
            onCompleted = function(req) completed[#completed + 1] = req.id end,
        })
        assert_true(ok, tostring(err))
        local res = PFServices.CitizenRequest(CITIZEN, 'tow.recovery')
        assert_true(res.ok, res.error)
        assert_true(PFServices.AcceptRequest(TOW1, res.id).ok)
        assert_eq(#accepted, 1, 'onAccepted ran')
        assert_eq(accepted[1].src, TOW1)
        local c = PFServices.CompleteRequest(TOW1, res.id, { atShop = true })
        assert_false(c.ok, 'not completed before the worker resource says so')
        assert_eq(c.error, 'not_at_shop')
        assert_eq(bank(TOW1), 0)
        done = true
        assert_true(PFServices.CompleteRequest(TOW1, res.id, { atShop = true }).ok)
        assert_eq(bank(TOW1), 175)
        assert_eq(completed[1], res.id, 'onCompleted ran')
    end)

    it('a function given as the whole handler is refused', function()
        local ok, err = services:RegisterRequestHandler('tow.recovery', function() return true end)
        assert_false(ok)
        assert_eq(err, 'unknown kind')
    end)

    it('a handler of a resource that stopped is not called', function()
        local called = false
        assert_true(services:RegisterRequestHandler('tow.recovery', {
            canComplete = function() called = true return true end,
        }))
        local res = PFServices.CitizenRequest(CITIZEN, 'tow.recovery')
        PFServices.AcceptRequest(TOW1, res.id)
        local rawState = GetResourceState
        GetResourceState = function(name) if name == 'pf-jobs' then return 'stopped' end return 'started' end
        local c = PFServices.CompleteRequest(TOW1, res.id)
        GetResourceState = rawState
        assert_false(called)
        assert_false(c.ok)
    end)
end)
