-- Batch 14, pf-computer domain purchases on a real database with the real ledger:
--   C2  two buyers of one domain: the domain is locked before the first wait, so only one is charged;
--       a charge the bank cannot settle at once keeps the domain reserved for that buyer (also over a
--       restart), is never charged again and gives the domain once the ledger completes it;
--   X9  a refused payment no longer blocks the buyer for good: each try has its own ledger key.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
local states = { ['pf-mechanicjob'] = 'missing', ['pf-restaurants'] = 'missing', ['pf-stores'] = 'missing', ['pf-services'] = 'missing', ['pf-government'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
function GetCurrentResourceName() return 'pfm-banking' end
function SaveResourceFile() return true end
function LoadResourceFile() return nil end
function RegisterCommand() end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
local merged = {}
local function loadConfig(path)
    Config = nil
    load_resource(path)
    for k, v in pairs(Config or {}) do if merged[k] == nil then merged[k] = v end end
end
loadConfig('pfm-banking/config.lua')
loadConfig('[pfscripts]/pf-computer/config/config.lua')
Config = merged
QBCoreMock.Shared.Jobs = { unemployed = { label = 'Civilian', grades = { ['0'] = { name = 'Freelancer', payment = 10 } } } }

load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, m) return RunMigrations(res, m) end
assert(PFLedger.Start(), 'ledger start')
local bankX

local function loadComputer()
    function GetCurrentResourceName() return 'pf-computer' end
    load_resource('[pfscripts]/pf-computer/server/main.lua')
    bankX = Mock.exportsByResource['__self']
    Mock.exportsByResource['pfm-banking'] = bankX
    assert(PFComputerStorage.Init(), 'pf-computer storage')
end
loadComputer()

local A, B = 1, 2
local PRICE = tonumber(Config.Browser.DefaultDomainPrice) or 2500
local function player(src, cid, bank)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.charinfo = { firstname = 'Buyer', lastname = cid }
    p.PlayerData.job = { name = 'unemployed', label = 'Civilian', grade = { level = 0, name = 'Freelancer' } }
    p.PlayerData.money = { cash = 0, bank = bank }
    return p
end
local function call(src, action, payload)
    Mock.clientEvents = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.fireNet('pf-computer:server:callback', src, 7, action, payload or {})
    -- the last reply: a call made inside another (a second buyer during the first one's charge) adds its own first
    local evs = Mock.clientEventsNamed('pf-computer:client:callback')
    local ev = evs[#evs]
    return ev and ev.args[2]
end
local function buy(src, domain) return call(src, 'browser:domain:buy', { domain = domain }) end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end
local function charges(domain) return count("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ? AND state = 'completed' AND kind = 'purchase'", { 'pf-computer:domain:' .. domain .. ':%' }) end
local function owner(domain) return MySQL.scalar.await('SELECT owner_cid FROM pf_computer_domains WHERE domain = ?', { domain }) end
local function bank(src) return Mock.players[src].PlayerData.money.bank end

-- runs `during` inside the next bank transfer (where the real call waits on the database)
local function duringNextTransfer(during)
    local real = bankX.Transfer
    bankX.Transfer = function(_, opts)
        bankX.Transfer = real
        during()
        return real(opts)
    end
end
-- the bank moves the money, then the answer is lost (left 'debited', the caller is told nothing clear)
local function unclearNextTransfer()
    local real = bankX.Transfer
    bankX.Transfer = function(_, opts)
        bankX.Transfer = real
        local res = real(opts)
        MySQL.update.await("UPDATE pf_transactions SET state = 'debited' WHERE idempotency_key = ?", { opts.key })
        return { ok = false, state = 'debited', error = 'debited', txId = res.txId }
    end
end

local n = 0
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    n = n + 1
    player(A, 'BUYA' .. n, 10000)
    player(B, 'BUYB' .. n, 10000)
end

describe('C2: one domain, two buyers', function()
    it('the second buyer is told the domain is busy while the first is charged; one charge, one owner', function()
        local domain = 'news' .. n .. '.ls'
        local second
        duringNextTransfer(function() second = buy(B, domain) end)
        local first = buy(A, domain)
        assert_true(first.ok, tostring(first.error))
        assert_eq(second.error, 'domain_busy')
        assert_eq(charges(domain), 1)
        assert_eq(bank(A), 10000 - PRICE)
        assert_eq(bank(B), 10000, 'the second buyer paid nothing')
        assert_eq(owner(domain), 'BUYA' .. n)
        local listed = 0
        for _, d in ipairs(call(B, 'browser:domains:list').data) do if d.domain == domain then listed = listed + 1 end end
        assert_eq(listed, 1, 'one record')
        assert_eq(buy(B, domain).error, 'domain_taken')
    end)
    it('a double click gets "busy", never a second charge', function()
        local domain = 'click' .. n .. '.ls'
        local again
        duringNextTransfer(function() again = buy(A, 'other' .. n .. '.ls') end)
        assert_true(buy(A, domain).ok)
        assert_eq(again.error, 'busy')
        assert_eq(bank(A), 10000 - PRICE)
    end)
    it('a charge the bank cannot settle at once: reserved, never charged twice, given once it completes', function()
        local domain = 'slow' .. n .. '.ls'
        unclearNextTransfer()
        assert_eq(buy(A, domain).error, 'payment_pending', 'not "insufficient funds"')
        assert_eq(bank(A), 10000 - PRICE)
        assert_eq(owner(domain), nil)
        assert_eq(buy(B, domain).error, 'domain_busy', 'reserved for the first buyer')
        assert_eq(buy(A, domain).error, 'payment_pending')
        assert_eq(bank(A), 10000 - PRICE, 'no second charge')
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ?", { 'pf-computer:domain:' .. domain .. ':%' }), 1)
        -- the ledger's recovery completes the transfer; the settle loop gives the domain
        MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key LIKE ?", { 'pf-computer:domain:' .. domain .. ':%' })
        PFComputerSettleDomainPurchases()
        assert_eq(owner(domain), 'BUYA' .. n)
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_computer_domain_purchases WHERE domain = ?', { domain }), 'done')
        assert_eq(bank(A), 10000 - PRICE)
    end)
    it('the reservation survives a restart, and is released when the ledger says nothing was taken', function()
        local domain = 'crash' .. n .. '.ls'
        unclearNextTransfer()
        assert_eq(buy(A, domain).error, 'payment_pending')
        loadComputer()                                   -- a restart: a fresh copy reads the tables
        assert_eq(buy(B, domain).error, 'domain_busy', 'still reserved after the restart')
        -- the recovery decides the transfer failed (the money was not taken after all)
        MySQL.update.await("UPDATE pf_transactions SET state = 'failed', error = 'insufficient_funds' WHERE idempotency_key LIKE ?", { 'pf-computer:domain:' .. domain .. ':%' })
        Mock.players[A].PlayerData.money.bank = 10000
        PFComputerSettleDomainPurchases()
        local res = buy(B, domain)
        assert_true(res.ok, tostring(res.error))
        assert_eq(owner(domain), 'BUYB' .. n)
    end)
end)

describe('X9: a refused payment does not block the buyer', function()
    it('too little money once, then enough: the next try has a fresh key and goes through', function()
        local domain = 'mybiz' .. n .. '.ls'
        Mock.players[A].PlayerData.money.bank = 1000
        assert_eq(buy(A, domain).error, 'insufficient_funds')
        Mock.players[A].PlayerData.money.bank = 5000
        local res = buy(A, domain)
        assert_true(res.ok, 'refused forever: ' .. tostring(res.error))
        assert_eq(owner(domain), 'BUYA' .. n)
        assert_eq(bank(A), 5000 - PRICE)
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key = ? AND state = 'completed'", { ('pf-computer:domain:%s:%s:2'):format(domain, 'BUYA' .. n) }), 1)
    end)
    it('the purchases table exists (migration 4)', function()
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-computer' AND version = 4"), 1)
    end)
end)
