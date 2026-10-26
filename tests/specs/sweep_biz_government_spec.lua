-- pf-government server entry points a modified client can reach: the NUI router
-- (pf-government:server:nuiCallback), the city hall events and the player-loaded hook.
load_resource('tests/lua/ledger_env.lua')
local resourceState = GetResourceState
GetResourceState = function(name) if name == 'pfm-cityhall' then return 'missing' end return resourceState(name) end
vec3 = vec3 or vector3
vec4 = vec4 or vector4 or function(x, y, z, w) return { x = x, y = y, z = z, w = w } end

local issued = {}
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, item) issued[#issued + 1] = { src = src, item = item } return true end,
}

LedgerEnv.load('pf-government', {
    '[pfscripts]/pf-government/config.lua',
    '[pfscripts]/pf-government/server/core.lua',
    '[pfscripts]/pf-government/server/bills.lua',
    '[pfscripts]/pf-government/server/licenses.lua',
    '[pfscripts]/pf-government/server/staff.lua',
    '[pfscripts]/pf-government/server/callbacks.lua',
    '[pfscripts]/pf-government/server/loans.lua',
    '[pfscripts]/pf-government/server/civil.lua',
    '[pfscripts]/pf-government/server/main.lua',
})
QBCore = QBCoreMock
QBCoreMock.Shared.Jobs = { police = { label = 'Police', grades = { ['0'] = { name = 'Cadet' } } }, trucker = { label = 'Trucker' } }
QBCoreMock.Shared.StarterItems = { phone = { item = 'phone' }, id_card = { item = 'id_card' } }

-- the parts of the government the tested handlers call into
local treasury, audits = {}, {}
function DepositToTreasury(amount, src, description) treasury[#treasury + 1] = amount return true end
function LogAudit(action) audits[#audits + 1] = action end
function DebugPrint() end

-- government tables on the fake database
local G = {}
local function resetTables()
    G.bills = {
        [1] = { id = 1, bill_type = 'fine', target_type = 'citizen', target_id = 'CIV1', amount = 500, amount_paid = 0, status = 'unpaid' },
        [2] = { id = 2, bill_type = 'fine', target_type = 'citizen', target_id = 'OTHER', amount = 900, amount_paid = 0, status = 'unpaid' },
        [3] = { id = 3, bill_type = 'fine', target_type = 'citizen', target_id = 'CIV1', amount = 100, amount_paid = 0, status = 'waived' },
    }
    G.licenses = {
        { id = 1, owner_type = 'citizen', owner_id = 'CIV1', license_type = 'drivers_license' },
        { id = 2, owner_type = 'citizen', owner_id = 'OTHER', license_type = 'firearms_license' },
    }
    G.loans, G.staffInserts, G.metadataWrites, G.jobWrites = {}, 0, {}, {}
end
local function filtered(list, query, params)
    local out, i = {}, 1
    local cols = {}
    for col in query:gmatch('AND ([%w_]+) = %?') do cols[#cols + 1] = col end
    for _, row in pairs(list) do
        local match = true
        for n, col in ipairs(cols) do if tostring(row[col]) ~= tostring(params[n]) then match = false end end
        if match then out[#out + 1] = row end
    end
    return out
end
FakeDB.extraPatterns = {
    { 'SELECT * FROM pf_gov_bills WHERE id = ?', function(p) local b = G.bills[tonumber(p[1])] return b and { b } or {} end },
    { 'SELECT * FROM pf_gov_bills WHERE 1=1', function(p) return filtered(G.bills, FakeDB.log[#FakeDB.log], p) end },
    { 'UPDATE pf_gov_bills SET amount_paid = ?, status = ?', function(p)
        local b = G.bills[tonumber(p[3])]
        if b then b.amount_paid, b.status = p[1], p[2] end
        return 1
    end },
    { 'SELECT * FROM pf_gov_licenses WHERE 1=1', function(p) return filtered(G.licenses, FakeDB.log[#FakeDB.log], p) end },
    { 'SELECT * FROM pf_gov_staff', function() return {} end },
    { 'INSERT INTO pf_gov_staff', function() G.staffInserts = G.staffInserts + 1 return 1 end },
    { 'CREATE TABLE IF NOT EXISTS', function() return {} end },
    { 'ALTER TABLE', function() return {} end },
    { 'INSERT INTO pf_gov_business_loans', function(p)
        G.loans[#G.loans + 1] = { id = #G.loans + 1, business_id = p[1], remaining_amount = p[3], status = 'active' }
        return #G.loans
    end },
    { 'DELETE FROM pf_gov_business_loans', function(p) G.loans[tonumber(p[1])] = nil return 1 end },
    { 'SELECT * FROM pf_gov_business_loans WHERE id = ?', function(p) return { G.loans[tonumber(p[1])] } end },
    { 'UPDATE pf_gov_business_loans SET remaining_amount', function(p)
        -- remaining, amount_due, missed_payments, status, id
        local l = G.loans[tonumber(p[#p])]
        l.remaining_amount, l.status = p[1], p[#p - 1]
        return 1
    end },
    -- the business's account on the registry (loans move money to and from it)
    { 'SELECT account_ref FROM pf_gov_businesses', function(p) return { { account_ref = 'society:' .. p[1] } } end },
    { 'information_schema', function() return { { c = 1 } } end },
    { 'SELECT metadata FROM ', function() return { { metadata = '{}' } } end },
    { ' SET metadata = ?', function(p) G.metadataWrites[#G.metadataWrites + 1] = p return 1 end },
    { ' SET job = ?', function(p) G.jobWrites[#G.jobWrites + 1] = p return 1 end },
}

local CIV, CLERK, MAYOR, UTIL = 1, 2, 3, 4
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function nui(src, action, data)
    local before = #Mock.clientEvents
    Mock.fireNet('pf-government:server:nuiCallback', src, 'cb1', action, data or {})
    for i = #Mock.clientEvents, before + 1, -1 do
        local e = Mock.clientEvents[i]
        if e.name == 'pf-government:client:nuiCallback' then return e.args[2] end
    end
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    resetTables()
    treasury, audits, issued = {}, {}, {}
    Mock.players, Mock.coords = {}, {}
    local function gov(src, cid, grade)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.job = { name = 'government', grade = { level = grade }, onduty = true }
        p.PlayerData.money = { cash = 0, bank = 10000 }
        return p
    end
    Mock.newPlayer(CIV, 'CIV1').PlayerData.money = { cash = 0, bank = 10000 }
    Mock.players[CIV].PlayerData.job = { name = 'unemployed', grade = { level = 0 } }
    Mock.players[CIV].PlayerData.charinfo.phone = '5550100'
    gov(CLERK, 'CLERK1', 1)
    gov(MAYOR, 'MAYOR1', 4)
    gov(UTIL, 'UTIL1', 0)
end

describe('bill payment', function()
    it('charges the payer the amount that is applied to the bill', function()
        local res = nui(CIV, 'bill:pay', { billId = 1, amount = 500 })
        assert_true(res.ok, tostring(res.message))
        assert_eq(bank(CIV), 9500)
        assert_eq(G.bills[1].status, 'paid')
        assert_eq(treasury[1], 500)
        assert_eq(#LedgerEnv.paid('pf-government:billpay:1:'), 1)
    end)
    it('without the money the bill stays unpaid and nothing reaches the treasury', function()
        Mock.players[CIV].PlayerData.money.bank = 20
        local res = nui(CIV, 'bill:pay', { billId = 1, amount = 500 })
        assert_false(res.ok)
        assert_eq(G.bills[1].status, 'unpaid')
        assert_eq(#treasury, 0)
        assert_eq(bank(CIV), 20)
    end)
    it('pays at most what is owed, and never a waived or paid bill', function()
        assert_true(nui(CIV, 'bill:pay', { billId = 1, amount = 99999 }).ok)
        assert_eq(bank(CIV), 9500)
        assert_false(nui(CIV, 'bill:pay', { billId = 1, amount = 10 }).ok)
        assert_false(nui(CIV, 'bill:pay', { billId = 3, amount = 10 }).ok)
        assert_eq(bank(CIV), 9500)
        assert_false(nui(CIV, 'bill:pay', { billId = 1, amount = 0/0 }).ok)
        assert_false(nui(CIV, 'bill:pay', { billId = 1, amount = -50 }).ok)
    end)
end)

describe('records only government staff may read', function()
    it('a citizen listing bills or licenses gets only their own', function()
        local res = nui(CIV, 'bill:getAll', { targetType = 'citizen', targetId = 'OTHER' })
        assert_true(res.ok)
        for _, b in ipairs(res.bills) do assert_eq(b.target_id, 'CIV1') end
        assert_eq(#res.bills, 2)
        res = nui(CIV, 'license:getAll', {})
        assert_eq(#res.licenses, 1)
        assert_eq(res.licenses[1].owner_id, 'CIV1')
    end)
    it('staff still list everyone', function()
        assert_eq(#nui(CLERK, 'bill:getAll', {}).bills, 3)
        assert_eq(#nui(CLERK, 'license:getAll', {}).licenses, 2)
    end)
    it('the staff list is not given to citizens', function()
        assert_eq(nui(CIV, 'staff:getAll', {}).error, 'no_permission')
        assert_true(nui(CLERK, 'staff:getAll', {}).ok)
    end)
    it('a payload that is not a table is ignored', function()
        Mock.fireNet('pf-government:server:nuiCallback', CIV, 'cb1', 'bill:getAll', 'x')
        assert_eq(#Mock.clientEventsNamed('pf-government:client:nuiCallback'), 0)
    end)
end)

describe('civilian records', function()
    it('a grade-0 government employee cannot change jobs, records or licenses', function()
        assert_eq(nui(UTIL, 'civilian:updateJob', { citizenId = 'CIV1', jobName = 'police' }).error, 'no_permission')
        assert_eq(nui(UTIL, 'civilian:toggleLicense', { citizenId = 'CIV1', licenseKey = 'weapon', enabled = true }).error, 'no_permission')
        assert_eq(nui(UTIL, 'civilian:clearConvictions', { citizenId = 'CIV1' }).error, 'no_permission')
        assert_eq(#G.jobWrites + #G.metadataWrites, 0)
    end)
    it('a clerk issues licenses but cannot change jobs; the mayor can', function()
        assert_true(nui(CLERK, 'civilian:toggleLicense', { citizenId = 'CIV1', licenseKey = 'driver', enabled = true }).ok)
        assert_eq(nui(CLERK, 'civilian:updateJob', { citizenId = 'CIV1', jobName = 'police' }).error, 'no_permission')
        assert_true(nui(MAYOR, 'civilian:updateJob', { citizenId = 'CIV1', jobName = 'police' }).ok)
    end)
end)

describe('business loans', function()
    it('are paid out of the treasury, not created', function()
        FakeDB.society('government', 1000, 'job')
        FakeDB.society('burgershot', 0, 'job')
        local r = nui(MAYOR, 'business:loans:grant', { businessId = 'burgershot', amount = 5000 })
        assert_false(r.ok)
        assert_eq(r.error, 'insufficient_treasury_funds')
        assert_eq(FakeDB.bank_accounts.burgershot.account_balance, 0)
        assert_eq(#G.loans, 0)
        assert_true(nui(MAYOR, 'business:loans:grant', { businessId = 'burgershot', amount = 800 }).ok)
        assert_eq(FakeDB.bank_accounts.burgershot.account_balance, 800)
        assert_eq(FakeDB.bank_accounts.government.account_balance, 200)
    end)
    it('repayments move money from the business to the treasury', function()
        FakeDB.society('government', 1000, 'job')
        FakeDB.society('burgershot', 0, 'job')
        assert_true(nui(MAYOR, 'business:loans:grant', { businessId = 'burgershot', amount = 800 }).ok)
        assert_true(nui(MAYOR, 'business:loans:pay', { loanId = 1, paymentAmount = 5000 }).ok)
        assert_eq(G.loans[1].status, 'paid')
        assert_eq(FakeDB.bank_accounts.burgershot.account_balance, 0)
        assert_eq(FakeDB.bank_accounts.government.account_balance, 1000)
        assert_false(nui(MAYOR, 'business:loans:pay', { loanId = 1, paymentAmount = 5 }).ok)
    end)
end)

describe('city hall events', function()
    it('starter items cannot be requested by a client', function()
        assert_eq(Mock.netHandlers['qb-cityhall:server:getIDs'], nil)
        assert_eq(Mock.netHandlers['pf-government:server:getIDs'], nil)
        TriggerEvent('qb-cityhall:server:getIDs', CIV)            -- a server script can still give them
        assert_eq(#issued, 2)
    end)
    it('applying for a job needs the player at a city hall, not coordinates the client sends', function()
        local hall = Config.CivilServices.Cityhalls[1].coords
        Mock.players[CIV].Functions.SetJob = function(job) Mock.players[CIV].PlayerData.job = { name = job, grade = { level = 0 } } end
        Mock.coords[CIV] = vector3(2000.0, 2000.0, 0.0)
        Mock.fireNet('qb-cityhall:server:ApplyJob', CIV, 'trucker', vector3(2000.0, 2000.0, 0.0))
        assert_eq(Mock.players[CIV].PlayerData.job.name, 'unemployed')
        Mock.coords[CIV] = vector3(hall.x, hall.y, hall.z)
        Mock.fireNet('qb-cityhall:server:ApplyJob', CIV, 'trucker')
        assert_eq(Mock.players[CIV].PlayerData.job.name, 'trucker')
    end)
    it('lesson requests only mail the configured instructors', function()
        local mailed = {}
        Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function(_, cid) mailed[#mailed + 1] = cid end }
        Mock.fireNet('qb-cityhall:server:sendDriverTest', CIV, { 'OTHER', 'OTHER', 'CIV1', Config.CivilServices.DrivingSchools[1].instructors[1] })
        assert_eq(#mailed, 1)
        assert_eq(mailed[1], Config.CivilServices.DrivingSchools[1].instructors[1])
        Mock.fireNet('qb-cityhall:server:sendDriverTest', CIV, { Config.CivilServices.DrivingSchools[1].instructors[1] })
        assert_eq(#mailed, 1, 'once a minute')
    end)
    it('the player-loaded hook is not a network event', function()
        assert_eq(Mock.netHandlers['QBCore:Server:PlayerLoaded'], nil)
    end)
end)
