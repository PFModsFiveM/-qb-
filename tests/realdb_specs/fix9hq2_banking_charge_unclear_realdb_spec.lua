-- PFPayout.Charge on the real ledger and database. When a crash leaves the first account's transfer in
-- an unclear state, the next account is not charged; the ledger's recovery settles the first one and
-- the same key then reports what happened. A clear refusal (not enough cash) still moves on to the bank.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetCurrentResourceName() return 'pfm-banking' end
function GetResourceState() return 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
local L = PFLedger
assert(L.Start(), 'ledger started')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']

-- the helper as another resource includes it
function GetCurrentResourceName() return 'pf-test' end
load_resource('pfm-banking/payouts.lua')

-- makes the next execution of one ledger statement raise, like a crash at that point
local failNext = {}
local realUpdate = MySQL.update.await
MySQL.update.await = function(query, params)
    for name, sql in pairs(L.SQL) do
        if sql == query and failNext[name] then
            failNext[name] = nil
            error('simulated crash at ' .. name)
        end
    end
    return realUpdate(query, params)
end

local SRC = 1
local seq = 0
local P, CID

local function row(key) return MySQL.single.await('SELECT state, error FROM pf_transactions WHERE idempotency_key = ?', { key }) end
local function age(prefix)
    MySQL.update.await('UPDATE pf_transactions SET updated_at = NOW() - INTERVAL 600 SECOND WHERE idempotency_key LIKE ?', { prefix .. '%' })
end
local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) end
local function charge(key, opts)
    opts = opts or {}
    opts.key, opts.quiet = key, true
    return PFPayout.Charge(SRC, { 'cash', 'bank' }, 100, opts)
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    seq = seq + 1
    CID = ('CHGDB%03d'):format(seq)
    P = Mock.newPlayer(SRC, CID)
    P.PlayerData.money = { cash = 500, bank = 500 }
    MySQL.insert.await("INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, 1, ?, 'T', ?, '{}', '{}', '{}', '{}', '{}', '[]')",
        { CID, 'license:' .. CID, json.encode(P.PlayerData.money) })
end

describe('Charge on the real ledger', function()
    it('a crash after the cash debit: the bank is not charged; recovery completes the cash charge; the same key reports it', function()
        MySQL.insert.await("INSERT IGNORE INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('police', 0, 'job', '[]')")
        failNext.creditSociety = true
        local used, res = charge('rdb-crash', { to = 'society:police' })
        assert_eq(used, false)
        assert_eq(res.error, 'internal_error')
        assert_true(res.unclear)
        assert_eq(row('rdb-crash:cash').state, 'debited')
        assert_eq(row('rdb-crash:bank'), nil, 'no bank transfer was started')
        assert_eq(P.PlayerData.money.cash, 400)
        assert_eq(P.PlayerData.money.bank, 500)
        age('rdb-crash')
        L.Recover()
        assert_eq(row('rdb-crash:cash').state, 'completed')
        assert_eq(society('police'), 100)
        assert_eq(charge('rdb-crash', { to = 'society:police' }), 'cash', 'the retry learns it was paid')
        assert_eq(P.PlayerData.money.cash, 400)
        assert_eq(P.PlayerData.money.bank, 500)
        assert_eq(society('police'), 100, 'paid once')
    end)

    it('a crash before the debit was recorded: unverified after recovery, and the bank is still never charged', function()
        failNext.setState = true -- the pending -> debited write fails after the cash left memory
        local used, res = charge('rdb-unv')
        assert_eq(used, false)
        assert_true(res.unclear)
        assert_eq(row('rdb-unv:cash').state, 'pending')
        assert_eq(P.PlayerData.money.cash, 400)
        age('rdb-unv')
        L.Recover()
        local r = row('rdb-unv:cash')
        assert_eq(r.state, 'failed')
        assert_eq(r.error, 'interrupted_unverified')
        local again, res2 = charge('rdb-unv')
        assert_eq(again, false)
        assert_true(res2.duplicate and res2.unclear)
        assert_eq(row('rdb-unv:bank'), nil)
        assert_eq(P.PlayerData.money.bank, 500)
    end)

    it('not enough cash: the bank pays once; the same key again moves nothing', function()
        P.PlayerData.money.cash = 50
        assert_eq(charge('rdb-low'), 'bank')
        assert_eq(row('rdb-low:cash').state, 'failed')
        assert_eq(row('rdb-low:bank').state, 'completed')
        assert_eq(charge('rdb-low'), 'bank')
        assert_eq(P.PlayerData.money.cash, 50)
        assert_eq(P.PlayerData.money.bank, 400)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'rdb-low%'")), 2)
    end)
end)
