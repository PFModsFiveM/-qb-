-- pf-services on a real database: the city events timeline and service requests between jobs,
-- with rewards escrowed and paid on the real ledger (pfm-banking).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
GetInvokingResource = GetInvokingResource or function() return nil end

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
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

-- pf-devices stand-in: pushes are recorded
local pushes = {}
Mock.exportsByResource['pf-devices'] = {
    PushToJob = function(_, job, app, event, payload) pushes[#pushes + 1] = { job = job, app = app, event = event, payload = payload } return 1 end,
    PushToCitizen = function(_, cid, app, event, payload) pushes[#pushes + 1] = { cid = cid, app = app, event = event, payload = payload } return true end,
    RegisterApp = function() return true end,
    RegisterAppHandlers = function() return true end,
}

-- pf-services
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

local CITIZEN, TOW1, TOW2, COP = 1, 2, 3, 4

local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function req(id) return PFServices.GetRequest(id) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, pushes = {}, {}, {}
    MySQL.query.await('DELETE FROM pf_service_requests')
    MySQL.query.await('DELETE FROM pf_city_events')
    PFServices.__resetRequests()
    PFServices.__resetEvents()
    PFServices.OnEvent(function(event)
        if not event.police then return end
        PFServices.CreateRequest({ kind = 'police.assist', title = event.title or event.kind, coords = event.coords,
            ref = { type = 'event', id = tostring(event.data and event.data.ref or event.id) }, from = { type = 'system', id = event.kind } })
    end)
    Mock.newPlayer(CITIZEN, 'CIT1').PlayerData.money = { cash = 0, bank = 1000 }
    local t1 = Mock.newPlayer(TOW1, 'TOW1')
    t1.PlayerData.job = { name = 'tow', onduty = true, grade = { level = 0 } }
    t1.PlayerData.money = { cash = 0, bank = 0 }
    local t2 = Mock.newPlayer(TOW2, 'TOW2')
    t2.PlayerData.job = { name = 'tow', onduty = true, grade = { level = 0 } }
    t2.PlayerData.money = { cash = 0, bank = 0 }
    local cop = Mock.newPlayer(COP, 'COP1')
    cop.PlayerData.job = { name = 'police', onduty = true, grade = { level = 2 } }
    for src in pairs(Mock.players) do Mock.players[src].PlayerData.source = src end
    Mock.coords[CITIZEN] = vector3(100.0, 200.0, 30.0)
end

describe('city events', function()
    it('are stored on the timeline and read back newest first', function()
        PFServices.Emit('gov.tax.changed', { tax = 'sales', oldRate = 5, newRate = 7 }, { title = 'Sales tax rises to 7%' })
        PFServices.Emit('gov.business.registered', { name = 'Burger Shot' })
        local rows = PFServices.GetRecentEvents({ limit = 10 })
        assert_eq(#rows, 2)
        assert_eq(rows[1].kind, 'gov.business.registered')
        assert_eq(rows[2].data.newRate, 7)
        assert_eq(rows[2].news, 'auto')
        assert_eq(#PFServices.GetRecentEvents({ kind = 'gov.tax.%' }), 1)
        assert_eq(#PFServices.GetRecentEvents({ category = 'business' }), 1)
    end)

    it('an event marked police raises one police dispatch request per incident', function()
        PFServices.Emit('crime.robbery.store', { ref = 'store-7', store = 'Ltd Grove St' }, { title = 'Robbery at Ltd Grove St', coords = vector3(10, 20, 30) })
        PFServices.Emit('crime.robbery.store', { ref = 'store-7', store = 'Ltd Grove St' }, { title = 'Robbery at Ltd Grove St', coords = vector3(10, 20, 30) })
        local rows = MySQL.query.await("SELECT * FROM pf_service_requests WHERE kind = 'police.assist'")
        assert_eq(#rows, 1)
        assert_eq(rows[1].job, 'police')
        assert_near(tonumber(rows[1].x), 10, 0.01)
    end)
end)

describe('a citizen calls a tow truck', function()
    it('escrows the call-out fee, one worker takes it, and confirming pays the worker', function()
        local res = PFServices.CitizenRequest(CITIZEN, 'tow.recovery', 'Flat tyre')
        assert_true(res.ok, res.error)
        assert_eq(bank(CITIZEN), 1000 - 175, 'fee held')
        local r = req(res.id)
        assert_eq(r.escrow, 'held')
        assert_near(r.coords.x, 100, 0.01, 'server position used')
        assert_eq(r.requester, 'CIT1')
        -- the job was told
        local told = false
        for _, p in ipairs(pushes) do if p.job == 'tow' and p.event == 'request:new' then told = true end end
        assert_true(told)

        -- two workers race for it: one wins
        local a = PFServices.AcceptRequest(TOW1, res.id)
        local b = PFServices.AcceptRequest(TOW2, res.id)
        assert_true(a.ok)
        assert_false(b.ok)
        assert_eq(b.error, 'not_open')

        -- paid work nobody can check yet needs the customer to confirm
        local c = PFServices.CompleteRequest(TOW1, res.id)
        assert_false(c.ok)
        assert_eq(c.error, 'needs_requester_confirmation')
        assert_false(PFServices.ConfirmRequest(TOW2, res.id).ok, 'only the customer confirms')
        assert_true(PFServices.ConfirmRequest(CITIZEN, res.id).ok)
        assert_eq(bank(TOW1), 175)
        assert_eq(req(res.id).status, 'completed')
        assert_eq(req(res.id).escrow, 'paid')
        -- confirming twice does not pay twice
        assert_false(PFServices.ConfirmRequest(CITIZEN, res.id).ok)
        assert_eq(bank(TOW1), 175)
    end)

    it('a verifier registered by the tow job completes it instead', function()
        local done = false
        PFServices.RegisterRequestHandler('tow.recovery', { canComplete = function(r) return done, 'not_at_shop' end }, 'pf-services')
        local res = PFServices.CitizenRequest(CITIZEN, 'tow.recovery')
        PFServices.AcceptRequest(TOW1, res.id)
        local c = PFServices.CompleteRequest(TOW1, res.id)
        assert_eq(c.error, 'not_at_shop')
        done = true
        assert_true(PFServices.CompleteRequest(TOW1, res.id).ok)
        assert_eq(bank(TOW1), 175)
    end)

    it('cannot be made without the money, and a second call returns the open one', function()
        Mock.players[CITIZEN].PlayerData.money.bank = 50
        local res = PFServices.CitizenRequest(CITIZEN, 'tow.recovery')
        assert_false(res.ok)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(bank(CITIZEN), 50)
        Mock.players[CITIZEN].PlayerData.money.bank = 1000
        local first = PFServices.CitizenRequest(CITIZEN, 'tow.recovery')
        assert_true(first.ok)
        local second = PFServices.CitizenRequest(CITIZEN, 'tow.recovery')
        assert_false(second.ok, 'cooldown')
    end)

    it('cancelling refunds the fee once', function()
        local res = PFServices.CitizenRequest(CITIZEN, 'tow.recovery')
        assert_eq(bank(CITIZEN), 825)
        assert_false(PFServices.CancelRequest(TOW1, res.id).ok, 'a worker cannot cancel a citizen call')
        assert_true(PFServices.CancelRequest(CITIZEN, res.id).ok)
        assert_eq(bank(CITIZEN), 1000)
        assert_false(PFServices.CancelRequest(CITIZEN, res.id).ok)
        assert_eq(bank(CITIZEN), 1000)
        assert_eq(req(res.id).escrow, 'refunded')
    end)

    it('expires and refunds when nobody takes it', function()
        local res = PFServices.CitizenRequest(CITIZEN, 'tow.recovery')
        MySQL.update.await('UPDATE pf_service_requests SET expires_at = NOW() - INTERVAL 1 MINUTE WHERE id = ?', { res.id })
        assert_eq(PFServices.SweepRequests(), 1)
        assert_eq(req(res.id).status, 'expired')
        assert_eq(bank(CITIZEN), 1000)
    end)
end)

describe('a job asks another job', function()
    it('the city funds an impound tow; off-duty or wrong-job workers cannot take it', function()
        exports['pfm-banking']:CreateJobAccount('government', 10000)
        local res = PFServices.CreateRequest({ kind = 'tow.impound', title = 'Impound ABC123', plate = 'ABC123',
            coords = vector3(1, 2, 3), ref = { type = 'vehicle', id = 'ABC123' }, from = { type = 'job', id = 'police', name = 'Officer' } })
        assert_true(res.ok, res.error)
        assert_eq(req(res.id).escrow, 'held')
        assert_eq(exports['pfm-banking']:GetAccountBalance('government'), 10000 - 250)
        -- the same vehicle is not ordered twice
        local again = PFServices.CreateRequest({ kind = 'tow.impound', ref = { type = 'vehicle', id = 'ABC123' } })
        assert_eq(again.id, res.id)
        assert_true(again.existing)
        assert_eq(PFServices.AcceptRequest(COP, res.id).error, 'wrong_job')
        Mock.players[TOW1].PlayerData.job.onduty = false
        assert_eq(PFServices.AcceptRequest(TOW1, res.id).error, 'off_duty')
        Mock.players[TOW1].PlayerData.job.onduty = true
        assert_true(PFServices.AcceptRequest(TOW1, res.id).ok)
        -- the officer's job may cancel its own order; the city gets its money back
        assert_true(PFServices.CancelRequest(COP, res.id).ok)
        assert_eq(exports['pfm-banking']:GetAccountBalance('government'), 10000)
    end)

    it('closing by reference pays whoever took it', function()
        local res = PFServices.CreateRequest({ kind = 'tow.impound', title = 'Impound XYZ', plate = 'XYZ', ref = { type = 'vehicle', id = 'XYZ' }, from = { type = 'job', id = 'police' } })
        PFServices.AcceptRequest(TOW2, res.id)
        local before = bank(TOW2)
        assert_true(PFServices.CloseByRef('vehicle', 'XYZ', 'completed', 'impounded').ok)
        assert_eq(bank(TOW2), before + 250)
        assert_eq(PFServices.FindOpenByRef('vehicle', 'XYZ'), nil)
    end)

    it('the worker list shows the job its requests, and positions only to the job and the requester', function()
        local res = PFServices.CitizenRequest(CITIZEN, 'tow.recovery')
        local list = PFServices.ListForJob('tow')
        assert_eq(#list, 1)
        local workerView = PFServices.PublicView(list[1], 'TOW1', 'tow')
        assert_true(workerView.coords ~= nil)
        local strangerView = PFServices.PublicView(list[1], 'COP1', 'police')
        assert_eq(strangerView.coords, nil)
        assert_eq(#PFServices.ListForJob('police'), 0)
        assert_eq(#PFServices.ListForCitizen('CIT1'), 1)
        assert_eq(PFServices.GetRequest(res.id).job, 'tow')
    end)

    it('a worker can hold only so many requests and can give one back', function()
        local ids = {}
        for i = 1, 3 do
            ids[i] = PFServices.CreateRequest({ kind = 'tow.impound', title = 'Impound ' .. i, ref = { type = 'vehicle', id = 'P' .. i }, from = { type = 'job', id = 'police' } }).id
        end
        assert_true(PFServices.AcceptRequest(TOW1, ids[1]).ok)
        assert_true(PFServices.AcceptRequest(TOW1, ids[2]).ok)
        assert_eq(PFServices.AcceptRequest(TOW1, ids[3]).error, 'too_many_active')
        assert_true(PFServices.ReleaseRequest(TOW1, ids[1]).ok)
        assert_eq(req(ids[1]).status, 'open')
        assert_true(PFServices.AcceptRequest(TOW1, ids[3]).ok)
    end)
end)
