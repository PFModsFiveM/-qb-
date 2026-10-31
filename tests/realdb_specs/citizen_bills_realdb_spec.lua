-- pf-citizen Bills with the real pf-government bills and the real ledger: a citizen sees their own
-- city bills and those of businesses they manage, pays them through pf-government's own path
-- (ledger charge into system:pf-government-fines, then PayBill) exactly once, part payments, no
-- money without the bill, a payment that lost a race is refunded, and new bills are mailed once.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
GetInvokingResource = GetInvokingResource or function() return nil end
local states = { ['pfm-cityhall'] = 'missing', ['pfm-phone'] = 'missing', ['pf-services'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government' } }
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/treasury.lua', 'server/taxes.lua', 'server/utilities.lua',
    'server/bills.lua', 'server/businesses.lua', 'server/audit.lua', 'server/licenses.lua', 'server/integrations.lua',
    'server/staff.lua', 'server/callbacks.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
function IsGovernmentEmployee() return false end
function DebugPrint() end
local govX = Mock.exportsByResource['__self']
Mock.exportsByResource['pf-government'] = govX
Mock.exportsByResource['__self'] = nil
InitializeTreasury()
InitializeTaxes()
InitializeBusinesses()
-- the registry's ManagesBusiness rule lives in the field apps (not loaded here)
local manages = {}
govX.ManagesBusiness = function(_, src, id) return manages[src] ~= nil and manages[src][id] == true end
govX.GetBusinessEmployees = function() return { ok = true, employees = {} } end
-- exported by pf-government's server/main.lua, which this spec does not load
govX.PayBill = function(_, billId, amount, paidBy) return PayBill(billId, amount, paidBy) end

local pushes = {}
Mock.exportsByResource['pf-devices'] = {
    PushToCitizen = function(_, cid, app, event, payload) pushes[#pushes + 1] = { cid = cid, app = app, event = event, payload = payload } return true end,
    RegisterApp = function() return true end, RegisterAppHandlers = function() return true end,
}

function GetCurrentResourceName() return 'pf-citizen' end
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'shared/config.lua', 'server/schema.lua', 'server/util.lua', 'server/mail.lua', 'server/bills.lua',
    'server/documents.lua', 'server/calendar.lua', 'server/apps.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-citizen/' .. f)
end
assert(PFCitizen.Start(), 'pf-citizen start')
local B = PFCitizen.Bills

local A, OTHER = 1, 2
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function bill(id) return MySQL.single.await('SELECT * FROM pf_gov_bills WHERE id = ?', { id }) end
local function newBill(target, amount, opts)
    opts = opts or {}
    local ok, _, id = CreateBill(opts.type or 'citizen', target, amount, opts.kind or 'fine', opts.due, opts.desc or 'Speeding', 'GOV1', 'Officer Smith')
    assert(ok, 'bill not created')
    return id
end
local function findOpen(list, key) for _, b in ipairs(list.open) do if b.key == key then return b end end end
local function finesBalance()
    return tonumber(MySQL.scalar.await("SELECT COALESCE(SUM(amount), 0) FROM pf_transactions WHERE to_account = 'system:pf-government-fines' AND state = 'completed'")) or 0
end

BeforeEach = function()
    Mock.reset()
    Mock.players, pushes, manages = {}, {}, {}
    PFCitizen.__resetLimits()
    local a = Mock.newPlayer(A, 'CIT1')
    a.PlayerData.money = { cash = 0, bank = 1000 }
    local o = Mock.newPlayer(OTHER, 'CIT2')
    o.PlayerData.money = { cash = 0, bank = 1000 }
    for src in pairs(Mock.players) do Mock.players[src].PlayerData.source = src end
end

describe('government bills in the Bills app', function()
    it('are listed for their citizen only, and paid once through the ledger', function()
        local id = newBill('CIT1', 500)
        local key = 'gov:' .. id
        local mine = B.List(A)
        local b = findOpen(mine, key)
        assert_true(b ~= nil, 'bill not listed')
        assert_eq(b.remaining, 500)
        assert_eq(b.canPay, true)
        assert_eq(b.status, 'open')
        assert_eq(findOpen(B.List(OTHER), key), nil)

        assert_eq(B.Pay(OTHER, { key = key }).error, 'not_found')
        assert_eq(bank(OTHER), 1000)

        local before = finesBalance()
        local res = B.Pay(A, { key = key, amount = 99999 })   -- capped at what is owed
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(res.paid, 500)
        assert_eq(bank(A), 500)
        assert_eq(bill(id).status, 'paid')
        assert_eq(finesBalance() - before, 500)
        assert_eq(B.Pay(A, { key = key }).error, 'not_open')
        assert_eq(bank(A), 500)
        assert_eq(finesBalance() - before, 500)
        -- now in the history
        local found = false
        for _, h in ipairs(B.List(A).history) do if h.key == key and h.status == 'paid' then found = true end end
        assert_true(found, 'not in the history')
    end)
    it('can be paid in part', function()
        local id = newBill('CIT1', 300, { desc = 'Parking' })
        assert_eq(B.Pay(A, { key = 'gov:' .. id, amount = 100 }).ok, true)
        assert_eq(bank(A), 900)
        local b = findOpen(B.List(A), 'gov:' .. id)
        assert_eq(b.status, 'partial')
        assert_eq(b.remaining, 200)
        assert_eq(B.Pay(A, { key = 'gov:' .. id }).paid, 200)
        assert_eq(bank(A), 700)
        assert_eq(bill(id).status, 'paid')
    end)
    it('nothing changes without the money', function()
        local id = newBill('CIT1', 5000)
        local before = finesBalance()
        assert_eq(B.Pay(A, { key = 'gov:' .. id }).error, 'insufficient_funds')
        assert_eq(bank(A), 1000)
        assert_eq(bill(id).status, 'unpaid')
        assert_eq(finesBalance(), before)
    end)
    it('a payment that lost a race to the city hall terminal is refunded', function()
        local id = newBill('CIT1', 400)
        local charge = PFPayout.Charge
        PFPayout.Charge = function(...)
            local account, res = charge(...)
            -- the bill is paid elsewhere between the charge and the update
            MySQL.update.await("UPDATE pf_gov_bills SET status = 'paid', amount_paid = amount WHERE id = ?", { id })
            return account, res
        end
        local ok, res = pcall(B.Pay, A, { key = 'gov:' .. id })
        PFPayout.Charge = charge
        assert_true(ok, tostring(res))
        assert_eq(res.ok, false)
        assert_eq(res.error, 'not_open')
        assert_eq(bank(A), 1000)
    end)
    it('overdue bills say so; waived bills are history', function()
        local late = newBill('CIT1', 50, { due = '2020-01-01 00:00:00' })
        local waived = newBill('CIT1', 60)
        MySQL.update.await("UPDATE pf_gov_bills SET status = 'waived' WHERE id = ?", { waived })
        local list = B.List(A)
        assert_eq(findOpen(list, 'gov:' .. late).status, 'overdue')
        assert_true(list.overdue >= 1)
        assert_eq(findOpen(list, 'gov:' .. waived), nil)
        local seen
        for _, h in ipairs(list.history) do if h.key == 'gov:' .. waived then seen = h end end
        assert_eq(seen.status, 'waived')
    end)
    it("a business's bills are shown to and payable by those who manage it", function()
        MySQL.query.await("INSERT INTO pf_gov_businesses (business_id, business_name, owner_id, owner_name) VALUES ('store:mall', 'Mall Store', 'CIT1', 'A')")
        local id = newBill('store:mall', 200, { type = 'business', kind = 'tax', desc = 'Sales tax' })
        assert_eq(findOpen(B.List(A), 'gov:' .. id), nil)
        assert_eq(B.Pay(A, { key = 'gov:' .. id }).error, 'not_found')
        manages[A] = { ['store:mall'] = true }
        local b = findOpen(B.List(A), 'gov:' .. id)
        assert_eq(b.business, 'Mall Store')
        assert_eq(B.Pay(A, { key = 'gov:' .. id }).ok, true)
        assert_eq(bank(A), 800)
    end)
    it('new bills are mailed (with the bill attached) and pushed once', function()
        B.InitWatch()
        local id = newBill('CIT2', 75, { desc = 'Littering' })
        B.Watch()
        B.Watch()
        local mails = MySQL.query.await("SELECT * FROM player_mails WHERE citizenid = 'CIT2' AND ref = ?", { 'bill:gov:' .. id })
        assert_eq(#mails, 1)
        assert_true(mails[1].attachments:find('gov:' .. id, 1, true) ~= nil)
        assert_eq(mails[1].sender_type, 'government')
        local n = 0
        for _, p in ipairs(pushes) do if p.app == 'bills' and p.event == 'new' and p.cid == 'CIT2' then n = n + 1 end end
        assert_eq(n, 1)
    end)
end)
