-- pf-services runs a worker resource's onClosed hook when a request closes without completion.
-- pf-jobs registers it through the RegisterRequestHandler export, so the hook arrives as a function
-- reference: pf-services must keep it (a type() == 'function' test dropped it). For a police
-- impound order (tow.impound) that hook is what writes the impound when no tow driver delivered
-- the car (pf-jobs tow_requests -> pfm-policejob FinalizeImpound); without it the car stayed out.
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

-- pfm-policejob stand-in: the impounds pf-jobs writes for orders that closed untowed
local impounds = {}
Mock.exportsByResource['pfm-policejob'] = {
    GetImpoundLots = function() return {} end,
    FinalizeImpound = function(_, plate, opts, id)
        impounds[#impounds + 1] = { plate = plate, opts = opts, id = id }
        return true
    end,
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

-- pf-jobs registers its tow handlers on start, through the export
Mock.exportsByResource['__self'] = {}
function GetCurrentResourceName() return 'pf-jobs' end
load_resource('[pfscripts]/pf-jobs/server/apps/tow_requests.lua')
invoking = 'pf-jobs'
Mock.fireEvent('onResourceStart', nil, 'pf-jobs')
invoking = nil
function GetCurrentResourceName() return 'pf-services' end

local TOW1 = 1

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    impounds = {}
    MySQL.query.await('DELETE FROM pf_service_requests')
    local t1 = Mock.newPlayer(TOW1, 'TOW1')
    t1.PlayerData.job = { name = 'tow', onduty = true, grade = { level = 0 } }
    t1.PlayerData.money = { cash = 0, bank = 0 }
    t1.PlayerData.source = TOW1
end

local function order(plate)
    local res = PFServices.CreateRequest({ kind = 'tow.impound', title = 'Impound ' .. plate, plate = plate,
        coords = vector3(1.0, 2.0, 3.0), ref = { type = 'vehicle', id = plate }, from = { type = 'job', id = 'police', name = 'Officer' },
        meta = { fullImpound = true, holdHours = 24 } })
    assert_true(res.ok, tostring(res.error))
    return res.id
end

describe('an impound order that closes without a delivery', function()
    it('cancelled by the police job: pf-jobs writes the impound', function()
        local id = order('IMP1')
        assert_true(PFServices.CloseByRef('vehicle', 'IMP1', 'cancelled', 'cancelled_by_job').ok)
        assert_eq(PFServices.GetRequest(id).status, 'cancelled')
        assert_eq(#impounds, 1, "pf-jobs' onClosed ran")
        assert_eq(impounds[1].plate, 'IMP1')
        assert_eq(impounds[1].id, id, 'applied once per order (the request id)')
        assert_eq(impounds[1].opts.fullImpound, true, 'with the order as the officer placed it')
        assert_eq(impounds[1].opts.holdHours, 24)
    end)

    it('expired, also after a driver took it and gave it back: pf-jobs writes the impound', function()
        local id = order('IMP2')
        assert_true(PFServices.AcceptRequest(TOW1, id).ok)
        assert_true(PFServices.ReleaseRequest(TOW1, id).ok)
        assert_eq(#impounds, 0, 'nothing while the order is open')
        MySQL.update.await('UPDATE pf_service_requests SET expires_at = NOW() - INTERVAL 1 MINUTE WHERE id = ?', { id })
        PFServices.SweepRequests()
        assert_eq(PFServices.GetRequest(id).status, 'expired')
        assert_eq(#impounds, 1, "pf-jobs' onClosed ran")
        assert_eq(impounds[1].plate, 'IMP2')
        assert_eq(impounds[1].id, id)
    end)

    it('closed by a server resource with CancelRequest: pf-jobs writes the impound', function()
        local id = order('IMP3')
        assert_true(PFServices.CancelRequest(nil, id, 'scene_cleared').ok)
        assert_eq(#impounds, 1)
        assert_eq(impounds[1].plate, 'IMP3')
    end)

    it('impounded by the officer on the spot: not impounded a second time', function()
        order('IMP4')
        assert_true(PFServices.CloseByRef('vehicle', 'IMP4', 'cancelled', 'impounded_on_site').ok)
        assert_eq(#impounds, 0)
    end)

    it('completed by a driver: onClosed is not the hook that runs', function()
        local id = order('IMP5')
        assert_true(PFServices.AcceptRequest(TOW1, id).ok)
        assert_true(PFServices.CloseByRef('vehicle', 'IMP5', 'completed', 'delivered').ok)
        -- onCompleted writes it once (pf-jobs), onClosed does not add a second one
        assert_eq(#impounds, 1)
        assert_eq(impounds[1].id, id)
    end)
end)
