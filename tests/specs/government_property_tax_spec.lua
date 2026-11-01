-- pf-government weekly property tax (mocked): the week key (Monday, UTC, by the calendar), the amount
-- (rate of the value, minimum, nothing while the tax is off), the housing export's rows checked, a
-- house listed twice billed once, the recurring key passed to CreateBill, no run without pfm-houses,
-- one run at a time, CreateBill refusing a malformed recurring key, and the scheduled task wiring.
-- The SQL side (unique key, reruns, restarts, delinquency, a house sold mid-week) is in
-- realdb_specs/government_property_tax_realdb_spec.lua.
load_resource('tests/lua/fivem_mocks.lua')

local started = { ['pfm-core'] = true, ['pfm-houses'] = true, ['pf-government'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-government' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4

Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
load_resource('[pfscripts]/pf-government/server/core.lua')
load_resource('[pfscripts]/pf-government/server/bills.lua')
load_resource('[pfscripts]/pf-government/server/property_tax.lua')
load_resource('[pfscripts]/pf-government/server/main.lua')
function DebugPrint() end
function LogAudit() end

-- the tax schedule (server/taxes.lua is covered on the real database): rate in percent, on/off
local tax = { rate = 0.5, enabled = true }
function GetTaxRate(t) if t == 'property' and tax.enabled then return tax.rate end return 0 end
function CalculateTax(amount, t)
    if t ~= 'property' or not tax.enabled or amount <= 0 then return 0 end
    return math.floor(amount * tax.rate) / 100
end
local schemaOk = true
GovSchema = { Ensure = function() return schemaOk end }

local houses = {}
Mock.exportsByResource['pfm-houses'] = { GetOwnedHouses = function() return houses end }

local createBill = CreateBill
local bills
local function recordBills()
    CreateBill = function(targetType, targetId, amount, billType, due, desc, by, byName, recurring)
        bills[#bills + 1] = { targetType = targetType, targetId = targetId, amount = amount, billType = billType, due = due,
            desc = desc, by = by, byName = byName, ref = recurring and recurring.ref, period = recurring and recurring.period }
        return true, 'Bill created successfully', #bills
    end
end

local WED = 1793793600     -- Wednesday 2026-11-04 12:00 UTC
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    bills, houses = {}, {}
    tax.rate, tax.enabled = 0.5, true
    schemaOk = true
    started['pfm-houses'] = true
    Config.Taxes.PropertyTax.Enabled = true
    recordBills()
end

describe('the week key', function()
    it('is the Monday of the week, from Monday 00:00 to Sunday 23:59:59 UTC', function()
        assert_eq(PropertyTax.Period(WED), '2026-11-02')
        local key, start = PropertyTax.Period(1793577600)          -- Monday 00:00
        assert_eq(key, '2026-11-02')
        assert_eq(start, 1793577600)
        assert_eq(PropertyTax.Period(1793577599), '2026-10-26')    -- Sunday 23:59:59 the week before
        assert_eq(PropertyTax.Period(1794182399), '2026-11-02')    -- Sunday 23:59:59
        assert_eq(PropertyTax.Period(1794182400), '2026-11-09')    -- next Monday
    end)
    it('follows the calendar across leap days and the year end', function()
        assert_eq(PropertyTax.Period(1708905600 + 3 * 86400), '2024-02-26')   -- Thursday 2024-02-29
        assert_eq(PropertyTax.Period(951696000 + 86400), '2000-02-28')        -- Tuesday 2000-02-29
        assert_eq(PropertyTax.Period(1735516800 + 2 * 86400), '2024-12-30')   -- Wednesday 2025-01-01
    end)
end)

describe('the amount', function()
    it('is the rate of the value, at least the minimum', function()
        assert_eq(PropertyTax.Amount(250000), 1250)
        assert_eq(PropertyTax.Amount(123457), 617.28)
        assert_eq(PropertyTax.Amount(5000), 50, 'minimum')
        assert_eq(PropertyTax.Amount(0), 50, 'no known value: the minimum')
        assert_eq(PropertyTax.Amount(-10), 50)
        assert_eq(PropertyTax.Amount(0 / 0), 50, 'not a number')
    end)
    it('is nothing while the tax is disabled or at 0%', function()
        tax.enabled = false
        assert_eq(PropertyTax.Amount(250000), 0)
        tax.enabled, tax.rate = true, 0
        assert_eq(PropertyTax.Amount(250000), 0)
    end)
end)

describe('a run', function()
    it('bills each owned house once to its owner, with the house and week as the recurring key', function()
        houses = {
            { house = 'grove1', citizenid = 'CIT1', value = 250000, label = '1 Grove Street' },
            { house = 'cheap', citizenid = 'CIT2', value = 4000 },
            { house = 'grove1', citizenid = 'CIT9', value = 999999 },   -- listed twice: billed once
        }
        local res = PropertyTax.Run(WED)
        assert_eq(res.billed, 2)
        assert_eq(res.period, '2026-11-02')
        assert_eq(#bills, 2)
        local b = bills[1]
        assert_eq(b.targetType, 'citizen')
        assert_eq(b.targetId, 'CIT1')
        assert_eq(b.billType, 'tax')
        assert_eq(b.amount, 1250)
        assert_eq(b.ref, 'house:grove1')
        assert_eq(b.period, '2026-11-02')
        assert_eq(b.by, 'system')
        assert_eq(b.due, os.date('%Y-%m-%d %H:%M:%S', WED + 7 * 86400))
        assert_true(b.desc:find('1 Grove Street', 1, true) and b.desc:find('2026-11-02', 1, true), b.desc)
        assert_eq(bills[2].amount, 50, 'minimum')
        assert_true(bills[2].desc:find('cheap', 1, true), 'no label: the house name')
    end)
    it('skips rows it cannot trust', function()
        houses = {
            'grove1', { house = '', citizenid = 'CIT1' }, { house = 'x', citizenid = 'bad cid;' },
            { house = string.rep('h', 65), citizenid = 'CIT1' }, { house = 'ok', citizenid = 'CIT1', value = 'lots' },
            { house = 'huge', citizenid = 'CIT3', value = math.huge },
        }
        local res = PropertyTax.Run(WED)
        assert_eq(res.skipped, 4)
        assert_eq(#bills, 2)
        assert_eq(bills[1].amount, 50, 'a value that is not a number: the minimum')
        assert_eq(bills[2].amount, 50, 'an impossible value: the minimum')
    end)
    it('counts a bill the database already holds as billed, and a failed one as failed', function()
        houses = { { house = 'a', citizenid = 'CIT1', value = 100000 }, { house = 'b', citizenid = 'CIT2', value = 100000 } }
        CreateBill = function(_, id) if id == 'CIT1' then return false, 'duplicate', 7 end return false, 'Database error' end
        local res = PropertyTax.Run(WED)
        assert_eq(res.billed, 0)
        assert_eq(res.existing, 1)
        assert_eq(res.failed, 1)
    end)
    it('does nothing without pfm-houses, with the tax off, disabled in the config or without the schema', function()
        houses = { { house = 'a', citizenid = 'CIT1', value = 100000 } }
        started['pfm-houses'] = nil
        assert_eq(PropertyTax.Run(WED).off, 'no_housing')
        started['pfm-houses'] = true
        tax.enabled = false
        assert_eq(PropertyTax.Run(WED).off, 'tax_off')
        tax.enabled = true
        Config.Taxes.PropertyTax.Enabled = false
        assert_eq(PropertyTax.Run(WED).off, 'disabled')
        Config.Taxes.PropertyTax.Enabled = true
        schemaOk = false
        assert_eq(PropertyTax.Run(WED).off, 'no_schema')
        assert_eq(#bills, 0)
    end)
    it('survives a failing housing export', function()
        Mock.exportsByResource['pfm-houses'].GetOwnedHouses = function() error('boom') end
        local res = PropertyTax.Run(WED)
        Mock.exportsByResource['pfm-houses'].GetOwnedHouses = function() return houses end
        assert_eq(res.off, 'no_housing')
    end)
    it('runs once at a time', function()
        houses = { { house = 'a', citizenid = 'CIT1', value = 100000 } }
        local inner
        CreateBill = function() inner = PropertyTax.Run(WED) return true, 'ok', 1 end
        local res = PropertyTax.Run(WED)
        assert_eq(res.billed, 1)
        assert_eq(inner.off, 'running')
        recordBills()
        assert_eq(PropertyTax.Run(WED).billed, 1, 'free again afterwards')
    end)
    it('tells an online owner', function()
        Mock.newPlayer(4, 'CIT1')
        houses = { { house = 'a', citizenid = 'CIT1', value = 100000, label = '4 Alta' } }
        PropertyTax.Run(WED)
        local notes = Mock.clientEventsNamed('QBCore:Notify')
        assert_eq(#notes, 1)
        assert_true(tostring(notes[1].args[1]):find('4 Alta', 1, true) ~= nil, 'names the house')
    end)
end)

describe('housing not ready', function()
    it('a housing resource still starting skips the run and asks for an early retry', function()
        houses = { { house = 'a', citizenid = 'CIT1', value = 100000 } }
        Mock.exportsByResource['pfm-houses'].GetOwnedHouses = function() return nil, 'not_ready' end
        local res = PropertyTax.Run(WED)
        Mock.exportsByResource['pfm-houses'].GetOwnedHouses = function() return houses end
        assert_eq(res.off, 'not_ready')
        assert_eq(res.retry, true)
        assert_eq(#bills, 0)
        assert_eq(PropertyTax.Run(WED).billed, 1, 'billed once it is ready')
    end)
    it('false alone means not ready: the reason may not cross the export boundary', function()
        houses = { { house = 'a', citizenid = 'CIT1', value = 100000 } }
        local said = {}
        local printOrig = print
        print = function(...) said[#said + 1] = table.concat({ ... }, ' ') end
        Mock.exportsByResource['pfm-houses'].GetOwnedHouses = function() return false end
        local res = PropertyTax.Run(WED)
        local res2 = PropertyTax.Run(WED)
        Mock.exportsByResource['pfm-houses'].GetOwnedHouses = function() return houses end
        print = printOrig
        assert_eq(res.off, 'not_ready')
        assert_eq(res.retry, true)
        assert_eq(res2.off, 'not_ready')
        local errors = 0
        for _, line in ipairs(said) do if line:find('returned no list', 1, true) then errors = errors + 1 end end
        assert_eq(errors, 0, 'reported as a failed export')
        assert_eq(#bills, 0)
    end)
    it('a failing export is retried early too; a stopped resource waits for the next interval', function()
        Mock.exportsByResource['pfm-houses'].GetOwnedHouses = function() error('boom') end
        local res = PropertyTax.Run(WED)
        Mock.exportsByResource['pfm-houses'].GetOwnedHouses = function() return houses end
        assert_eq(res.retry, true)
        started['pfm-houses'] = nil
        res = PropertyTax.Run(WED)
        assert_eq(res.off, 'no_housing')
        assert_true(not res.retry)
    end)
    it('the scheduled task waits RetrySeconds after a run asking for a retry, then the interval again', function()
        local threads, waits, n = {}, {}, 0
        local createThread, wait, run = CreateThread, Wait, PropertyTax.Run
        CreateThread = function(fn) threads[#threads + 1] = fn end
        PropertyTax.Run = function() n = n + 1 if n == 1 then return { off = 'not_ready', retry = true } end return { billed = 1 } end
        StartInfrastructureTasks = function() end
        StartBackgroundTasks()
        Wait = function(ms) waits[#waits + 1] = ms if #waits >= 3 then error('stop', 0) end end
        pcall(threads[1])
        CreateThread, Wait, PropertyTax.Run = createThread, wait, run
        assert_eq(waits[2], Config.Taxes.PropertyTax.RetrySeconds * 1000, 'retried after a whole interval')
        assert_eq(waits[3], Config.Taxes.AutoCollection.interval * 60000)
    end)
end)

describe('CreateBill with a recurring key', function()
    it('refuses a malformed key before touching the database', function()
        CreateBill = createBill
        for _, bad in ipairs({ 'x', { ref = 'house:a' }, { period = '2026-11-02' }, { ref = '', period = 'p' },
            { ref = string.rep('r', 101), period = 'p' }, { ref = 'r', period = string.rep('p', 17) } }) do
            local ok, msg = CreateBill('citizen', 'CIT1', 50, 'tax', nil, 'x', 'system', 'Tax Office', bad)
            assert_false(ok)
            assert_eq(msg, 'Invalid recurring bill')
        end
        schemaOk = false
        local ok, msg = CreateBill('citizen', 'CIT1', 50, 'tax', nil, 'x', 'system', 'Tax Office', { ref = 'house:a', period = '2026-11-02' })
        assert_false(ok, 'no unique key, no recurring bill')
        assert_eq(msg, 'Database error')
        assert_eq(#Mock.dbCalls, 0)
    end)
end)

describe('the background loops', function()
    -- oxmysql raises on a SQL error: one failed run must not end the loop for the rest of the session
    local function startLoops()
        local threads = {}
        local createThread = CreateThread
        CreateThread = function(fn) threads[#threads + 1] = fn end
        StartInfrastructureTasks = function() end
        StartBackgroundTasks()
        CreateThread = createThread
        return threads
    end
    it('the hourly late fee and escalation loop survives a run that raises', function()
        local fees, escalations = 0, 0
        local saved = { ProcessBillLateFees, ProcessBillEscalation, Wait, print }
        ProcessBillLateFees = function() fees = fees + 1 if fees == 1 then error('Deadlock found when trying to get lock') end end
        ProcessBillEscalation = function() escalations = escalations + 1 error('Lock wait timeout exceeded') end
        local threads = startLoops()
        local waits = 0
        Wait = function() waits = waits + 1 if waits > 3 then error('stop', 0) end end
        print = function() end
        local ok, err = pcall(threads[#threads])         -- the late fee loop is started last
        ProcessBillLateFees, ProcessBillEscalation, Wait, print = saved[1], saved[2], saved[3], saved[4]
        assert_eq(err, 'stop', 'the loop ended on an error: ' .. tostring(err))
        assert_eq(fees, 3)
        assert_eq(escalations, 3)
    end)
    it('the utility billing loop survives a run that raises', function()
        local runs = 0
        local saved = { ProcessUtilityBilling, Wait, print, Config.Utilities.EnablePower }
        Config.Utilities.EnablePower = true
        ProcessUtilityBilling = function() runs = runs + 1 if runs == 1 then error('Lost connection to MySQL server') end return { billed = 0 } end
        local threads = startLoops()
        local waits = 0
        Wait = function() waits = waits + 1 if waits > 3 then error('stop', 0) end end
        print = function() end
        local ok, err = pcall(threads[#threads - 1])     -- utilities come just before the late fees
        ProcessUtilityBilling, Wait, print, Config.Utilities.EnablePower = saved[1], saved[2], saved[3], saved[4]
        assert_eq(err, 'stop', 'the loop ended on an error: ' .. tostring(err))
        assert_eq(runs, 3)
    end)
end)

describe('the scheduled task', function()
    it('runs the property tax soon after the start and then every interval', function()
        local threads, waits, runs = {}, {}, 0
        local createThread, wait, run = CreateThread, Wait, PropertyTax.Run
        CreateThread = function(fn) threads[#threads + 1] = fn end
        PropertyTax.Run = function() runs = runs + 1 end
        StartInfrastructureTasks = function() end
        StartBackgroundTasks()
        -- the auto collection thread is the first one; stop it at its third wait
        Wait = function(ms) waits[#waits + 1] = ms if #waits >= 3 then error('stop', 0) end end
        pcall(threads[1])
        CreateThread, Wait, PropertyTax.Run = createThread, wait, run
        assert_eq(waits[1], 60000, 'first run a minute after the start')
        assert_eq(runs, 2)
        assert_eq(waits[2], Config.Taxes.AutoCollection.interval * 60000)
    end)
end)
