-- pfm-policejob fine records on a real database (batch 14: X-7, 13B-POLICE): the migration creates
-- pfm_police_fines (rerun-safe); /fine charges the player straight to the department in one ledger
-- transfer; the sweep picks due rows with the real SQL, finishes an unclear charge under the same key
-- once the ledger settles it (and never charges again meanwhile), charges a 'retry' row under the
-- next numbered key, and the state moves are compare-and-set (a stale copy of a row does nothing).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')

function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
local bankingConfig = Config
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')
MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('police', 0, 'job', '[]') ON DUPLICATE KEY UPDATE account_balance = 0")
MySQL.query.await("INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES ('society:police', 0)")

local phoneInvoices, phoneAnswer = {}, 77
Mock.exportsByResource['pfm-phone'] = {
    CreateInvoice = function(_, data) phoneInvoices[#phoneInvoices + 1] = data if phoneAnswer then return phoneAnswer end return nil, 'db_error' end,
}
Mock.exportsByResource['pfm-inventory'] = { AddItem = function() return true end, RemoveItem = function() return true end, OpenInventoryById = function() end }
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCore = QBCoreMock

function GetCurrentResourceName() return 'pfm-policejob' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/fines.lua')
load_resource('pfm-policejob/server/commands.lua')
for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
local F = PFPoliceFines
assert_true(F.Migrate(), 'migration')

local COP, SUSPECT = 1, 2
local function society() return tonumber(MySQL.scalar.await("SELECT account_balance FROM bank_accounts WHERE account_name = 'police'")) or 0 end
local function fine(id) return MySQL.single.await('SELECT * FROM pfm_police_fines WHERE id = ?', { id }) end
local function lastFine() return MySQL.single.await('SELECT * FROM pfm_police_fines ORDER BY id DESC LIMIT 1') end
local function txCount(prefix)
    return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE CONCAT(?, '%')", { prefix })) or 0
end
local function due(id) MySQL.update.await('UPDATE pfm_police_fines SET next_at = 0 WHERE id = ?', { id }) end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    phoneInvoices, phoneAnswer = {}, 77
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.newPlayer(SUSPECT, 'SUSPECTCID').PlayerData.money = { cash = 300, bank = 1000 }
    MySQL.update.await("UPDATE bank_accounts SET account_balance = 0 WHERE account_name = 'police'")
    MySQL.update.await("REPLACE INTO pf_ledger_baselines (account, balance) VALUES ('society:police', 0)")
    MySQL.update.await("UPDATE pfm_police_fines SET state = 'paid' WHERE state IN ('charging', 'pending', 'retry')")
end

describe('the fine table', function()
    it('is created by a rerun-safe migration', function()
        assert_true(F.Migrate())
        local cols = MySQL.query.await([[SELECT COLUMN_NAME AS c FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pfm_police_fines']])
        local have = {}
        for _, r in ipairs(cols) do have[r.c] = true end
        for _, c in ipairs({ 'id', 'citizenid', 'society', 'amount', 'state', 'attempt', 'checks', 'next_at', 'invoice_id' }) do
            assert_true(have[c], c)
        end
        local applied = tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-policejob'"))
        assert_eq(applied, 1)
    end)
end)

describe('/fine on the real ledger', function()
    it('is recorded and paid to the department in one transfer', function()
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        local row = lastFine()
        assert_eq(row.state, 'paid')
        assert_eq(row.paid_from, 'bank')
        assert_eq(tonumber(row.amount), 400)
        assert_eq(Mock.players[SUSPECT].PlayerData.money.bank, 600)
        assert_eq(society(), 400)
        local tx = MySQL.single.await('SELECT from_account, to_account, state FROM pf_transactions WHERE idempotency_key = ?', { F.Key({ id = tonumber(row.id), attempt = 1 }) .. ':bank' })
        assert_eq(tx.from_account, 'player:SUSPECTCID:bank')
        assert_eq(tx.to_account, 'society:police')
        assert_eq(tx.state, 'completed')
    end)
    it('a clear refusal becomes an invoice and the row says which', function()
        Mock.players[SUSPECT].PlayerData.money = { cash = 5, bank = 5 }
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        local row = lastFine()
        assert_eq(row.state, 'invoiced')
        assert_eq(tonumber(row.invoice_id), 77)
        assert_eq(#phoneInvoices, 1)
        assert_eq(society(), 0)
    end)
end)

describe('the sweep', function()
    it('finishes an unclear charge under the same key once the ledger settles it, and never charges meanwhile', function()
        local id = MySQL.insert.await([[INSERT INTO pfm_police_fines (citizenid, society, amount, officer_citizenid, officer_name, reason, state, attempt, next_at)
            VALUES ('SUSPECTCID', 'police', 250, 'COPCID', 'Cop', 'Police fine', 'pending', 1, 0)]])
        local key = F.Key({ id = id, attempt = 1 }) .. ':bank'
        -- the charge is still debited (not settled): money left the player, the credit did not land yet
        local txId = PFLedger.NewTxId and PFLedger.NewTxId() or ('tx-' .. id)
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state, reason, actor)
            VALUES (?, ?, 'fine', 'player:SUSPECTCID:bank', 'society:police', 250, 'debited', 'Police fine', 'SUSPECTCID')]], { txId, key })
        F.Sweep()
        assert_eq(fine(id).state, 'pending')
        assert_eq(Mock.players[SUSPECT].PlayerData.money.bank, 1000, 'not charged again while unclear')
        assert_eq(txCount(F.Key({ id = id, attempt = 1 }) .. ':cash'), 0)
        -- the ledger settles it
        MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key = ?", { key })
        due(id)
        F.Sweep()
        assert_eq(fine(id).state, 'paid')
        assert_eq(Mock.players[SUSPECT].PlayerData.money.bank, 1000)
        assert_eq(txCount(F.Key({ id = id, attempt = 2 })), 0)
    end)
    it('charges a retry row under the next numbered key, once', function()
        local id = MySQL.insert.await([[INSERT INTO pfm_police_fines (citizenid, society, amount, officer_citizenid, officer_name, reason, state, attempt, next_at)
            VALUES ('SUSPECTCID', 'police', 100, 'COPCID', 'Cop', 'Police fine', 'retry', 1, 0)]])
        F.Sweep()
        local row = fine(id)
        assert_eq(row.state, 'paid')
        assert_eq(tonumber(row.attempt), 2)
        assert_eq(txCount(F.Key({ id = id, attempt = 2 }) .. ':bank'), 1)
        assert_eq(txCount(F.Key({ id = id, attempt = 1 })), 0)
        assert_eq(society(), 100)
        due(id)
        F.Sweep()
        assert_eq(society(), 100)
    end)
    it('a stale copy of a row moves nothing (compare-and-set on state and attempt)', function()
        local id = MySQL.insert.await([[INSERT INTO pfm_police_fines (citizenid, society, amount, officer_citizenid, officer_name, reason, state, attempt, next_at)
            VALUES ('SUSPECTCID', 'police', 50, 'COPCID', 'Cop', 'Police fine', 'retry', 1, 0)]])
        local stale = fine(id)
        assert_eq(F.SweepOne(fine(id)), 'paid')
        assert_eq(F.SweepOne(stale), 'busy')
        assert_eq(society(), 50)
        assert_eq(tonumber(fine(id).attempt), 2)
    end)
    it('only due rows are picked', function()
        local id = MySQL.insert.await([[INSERT INTO pfm_police_fines (citizenid, society, amount, officer_citizenid, officer_name, reason, state, attempt, next_at)
            VALUES ('SUSPECTCID', 'police', 70, 'COPCID', 'Cop', 'Police fine', 'pending', 1, ?)]], { os.time() + 3600 })
        F.Sweep()
        assert_eq(fine(id).state, 'pending')
        assert_eq(society(), 0)
    end)
end)
