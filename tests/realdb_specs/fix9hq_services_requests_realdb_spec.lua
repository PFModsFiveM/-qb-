-- pf-services review fixes on a real database and the real ledger: one open request per kind and
-- ref with a police impound superseding a tow, roadside repair paid on proof, cancel only while
-- open, and the escrow sweep's pending/age statements.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
GetInvokingResource = GetInvokingResource or function() return nil end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

Mock.exportsByResource['pf-devices'] = {
    PushToJob = function() return 1 end, PushToCitizen = function() return true end,
    RegisterApp = function() return true end, RegisterAppHandlers = function() return true end,
}

function GetCurrentResourceName() return 'pf-services' end
Config = {}
load_resource('pfm-banking/payouts.lua')
load_resource('[pfscripts]/pf-services/shared/catalog.lua')
load_resource('[pfscripts]/pf-services/shared/config.lua')
load_resource('[pfscripts]/pf-services/server/schema.lua')
load_resource('[pfscripts]/pf-services/server/events.lua')
load_resource('[pfscripts]/pf-services/server/requests.lua')
load_resource('[pfscripts]/pf-services/server/apps.lua')
load_resource('[pfscripts]/pf-services/server/main.lua')
assert(RunMigrations('pf-services', PFServices.Migrations))

local CITIZEN, TOW1, MECH, COP = 1, 2, 3, 4
local SITE = vector3(100.0, 200.0, 30.0)
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function req(id) return PFServices.GetRequest(id) end
local function gov() return exports['pfm-banking']:GetAccountBalance('government') end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    MySQL.query.await('DELETE FROM pf_service_requests')
    PFServices.__resetRequests()
    Mock.clock = Mock.clock + 1000
    Mock.newPlayer(CITIZEN, 'CIT1').PlayerData.money = { cash = 0, bank = 1000 }
    local t = Mock.newPlayer(TOW1, 'TOW1')
    t.PlayerData.job = { name = 'tow', onduty = true, grade = { level = 0 } }
    t.PlayerData.money = { cash = 0, bank = 0 }
    local m = Mock.newPlayer(MECH, 'MECH1')
    m.PlayerData.job = { name = 'mechanic', onduty = true, grade = { level = 0 } }
    m.PlayerData.money = { cash = 0, bank = 0 }
    local c = Mock.newPlayer(COP, 'COP1')
    c.PlayerData.job = { name = 'police', onduty = true, grade = { level = 2 } }
    for src in pairs(Mock.players) do Mock.players[src].PlayerData.source = src end
    Mock.coords[CITIZEN] = SITE
    exports['pfm-banking']:CreateJobAccount('government', 10000)
end

describe('a police impound over an open tow of the same car', function()
    it('cancels and refunds the tow and creates the impound; no new tow while it is open', function()
        local startGov = gov()
        local tow = PFServices.CreateRequest({ kind = 'tow.recovery', title = 'Tow G1', plate = 'G1', ref = { type = 'vehicle', id = 'G1' },
            from = { type = 'citizen', id = 'CIT1' }, requester = 'CIT1' })
        assert_true(tow.ok, tow.error)
        assert_eq(bank(CITIZEN), 825)
        assert_true(PFServices.AcceptRequest(TOW1, tow.id).ok)
        local imp = PFServices.CreateRequest({ kind = 'tow.impound', title = 'Impound G1', plate = 'G1', ref = { type = 'vehicle', id = 'G1' },
            from = { type = 'job', id = 'police' } })
        assert_true(imp.ok, imp.error)
        assert_eq(imp.request.kind, 'tow.impound')
        assert_true(imp.existing ~= true)
        assert_eq(req(tow.id).status, 'cancelled')
        assert_eq(req(tow.id).escrow, 'refunded')
        assert_eq(bank(CITIZEN), 1000)
        assert_eq(gov(), startGov - 250)
        assert_eq(PFServices.FindOpenByRef('vehicle', 'G1', 'tow.impound').id, imp.id)
        assert_eq(PFServices.FindOpenByRef('vehicle', 'G1', 'tow.recovery'), nil)
        local again = PFServices.CreateRequest({ kind = 'tow.recovery', title = 'Tow G1', plate = 'G1', ref = { type = 'vehicle', id = 'G1' }, requester = 'CIT1' })
        assert_eq(again.error, 'superseded')
        assert_eq(bank(CITIZEN), 1000)
    end)
end)

describe('roadside repair on proof', function()
    it('far away refused; on site recorded; the requester confirms and the mechanic is paid', function()
        local res = PFServices.CitizenRequest(CITIZEN, 'mechanic.roadside', 'Flat')
        assert_true(res.ok, res.error)
        assert_eq(bank(CITIZEN), 900)
        assert_true(PFServices.AcceptRequest(MECH, res.id).ok)
        Mock.coords[MECH] = vector3(500.0, 200.0, 30.0)
        assert_eq(PFServices.CompleteRequest(MECH, res.id).error, 'too_far')
        Mock.coords[MECH] = vector3(110.0, 200.0, 30.0)
        assert_true(PFServices.CompleteRequest(MECH, res.id).ok)
        assert_eq(bank(MECH), 0)
        assert_eq(req(res.id).meta.onSite.cid, 'MECH1')
        assert_eq(PFServices.CancelRequest(CITIZEN, res.id).error, 'already_accepted')
        assert_true(PFServices.ConfirmRequest(CITIZEN, res.id).ok)
        assert_eq(bank(MECH), 100)
    end)

    it('a dispute refunds; the window pays a visited mechanic; expiry without a visit refunds', function()
        local a = PFServices.CitizenRequest(CITIZEN, 'mechanic.roadside')
        assert_true(PFServices.AcceptRequest(MECH, a.id).ok)
        Mock.coords[MECH] = SITE
        assert_true(PFServices.CompleteRequest(MECH, a.id).ok)
        assert_true(PFServices.DisputeRequest(CITIZEN, a.id).ok)
        assert_eq(bank(CITIZEN), 1000)
        assert_eq(bank(MECH), 0)

        Mock.clock = Mock.clock + 1000
        local b = PFServices.CitizenRequest(CITIZEN, 'mechanic.roadside')
        assert_true(PFServices.AcceptRequest(MECH, b.id).ok)
        assert_true(PFServices.CompleteRequest(MECH, b.id).ok)
        Mock.clock = Mock.clock + 601
        PFServices.SweepRequests()
        assert_eq(req(b.id).status, 'completed')
        assert_eq(bank(MECH), 100)

        Mock.clock = Mock.clock + 1000
        local c = PFServices.CitizenRequest(CITIZEN, 'mechanic.roadside')
        assert_true(PFServices.AcceptRequest(MECH, c.id).ok)
        MySQL.update.await('UPDATE pf_service_requests SET expires_at = NOW() - INTERVAL 1 MINUTE WHERE id = ?', { c.id })
        PFServices.SweepRequests()
        assert_eq(req(c.id).status, 'expired')
        assert_eq(bank(CITIZEN), 900, 'the earlier paid call-out stays paid; this one is refunded')
        assert_eq(bank(MECH), 100)
    end)
end)

describe('the escrow sweep', function()
    it('settles only pending rows older than a minute', function()
        local id = MySQL.insert.await([[INSERT INTO pf_service_requests (kind, job, status, title, payer, reward, escrow_state, requester_cid, expires_at)
            VALUES ('tow.recovery', 'tow', 'open', 'Tow', 'requester', 175, 'pending', 'CIT1', NOW() + INTERVAL 1800 SECOND)]])
        PFServices.SweepRequests()
        assert_eq(req(id).escrow, 'pending')
        MySQL.update.await('UPDATE pf_service_requests SET created_at = NOW() - INTERVAL 5 MINUTE WHERE id = ?', { id })
        PFServices.SweepRequests()
        assert_eq(req(id).escrow, 'held')
        assert_eq(bank(CITIZEN), 825)
    end)
end)
