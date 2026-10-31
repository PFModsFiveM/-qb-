-- pfm-banking's Bank app, society moves, branch closures and character deletion on a real database:
-- transfers happen exactly once per ref, statements page and filter with the real SQL, society deposit
-- and withdrawal go through the ledger and reconcile, and a deleted character leaves no usable rows.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
local started = { ['pf-devices'] = true, ['pfm-banking'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
local function addPlayer(cid, money, charinfo)
    MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, ?, ?, '{}', '{}', '{}', '{}', '[]')]], { cid, 'license:' .. cid, cid, json.encode(money), json.encode(charinfo) })
end
addPlayer('ME000001', { cash = 300, bank = 5000 }, { firstname = 'Mia', lastname = 'Evans' })
addPlayer('OT000001', { cash = 0, bank = 100 }, { firstname = 'Otto', lastname = 'Tran' })
addPlayer('OFF00001', { cash = 0, bank = 50 }, { firstname = 'Olga', lastname = 'Ford' })
addPlayer('BS000001', { cash = 0, bank = 5000 }, { firstname = 'Bea', lastname = 'Stone' })
addPlayer('GONE0001', { cash = 0, bank = 900 }, { firstname = 'Gus', lastname = 'Gone' })
MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('mechanic', 1000, 'job', '[]')")

function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('[pfscripts]/pf-devices/shared/config.lua')
function GetCurrentResourceName() return 'pf-devices' end
for _, f in ipairs({ 'registry', 'installs', 'rpc', 'push', 'sites', 'builtin_apps', 'main' }) do
    load_resource('[pfscripts]/pf-devices/server/' .. f .. '.lua')
end
Mock.exportsByResource['pf-devices'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
function GetCurrentResourceName() return 'pfm-banking' end
for _, f in ipairs({ 'pfm-core/server/migrations.lua', 'pfm-banking/server_ledger.lua', 'pfm-banking/server.lua', 'pfm-banking/server_finance.lua',
    'pfm-banking/server_accounts.lua', 'pfm-banking/server_shared_migration.lua', 'pfm-banking/server_branches.lua',
    'pfm-banking/server_characters.lua', 'pfm-banking/server_app.lua' }) do
    load_resource(f)
end
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
local L = PFLedger
assert(L.Start(), 'ledger start')
BankingAccounts.mechanic = MySQL.single.await("SELECT * FROM bank_accounts WHERE account_name = 'mechanic'")
QBCoreMock.Shared.Jobs.mechanic = { label = 'Mechanic', grades = {} }
Config.App.cooldownMs = 0
Mock.invokingResource = 'pfm-banking'
PFBankApp.Register()
Mock.invokingResource = nil

local ME, OTHER, BOSS = 1, 2, 3
local function online(src, cid, money, job)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = money
    p.PlayerData.job = job or { name = 'unemployed', grade = { level = 0 }, isboss = false }
    p.PlayerData.gang = { name = 'none', isboss = false }
    return p
end
online(ME, 'ME000001', { cash = 300, bank = 5000 })
online(OTHER, 'OT000001', { cash = 0, bank = 100 })
online(BOSS, 'BS000001', { cash = 0, bank = 5000 }, { name = 'mechanic', label = 'Mechanic', grade = { level = 4 }, isboss = true })

local function rpc(src, method, payload) PFDevices.__resetRpc() return PFDevices.HandleRpc(src, 'bank', method, payload) end
local function offlineBank(cid) return tonumber(json.decode(MySQL.scalar.await('SELECT money FROM players WHERE citizenid = ?', { cid })).bank) end
local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) end
local function noMismatches()
    local report = L.Reconcile()
    for _, m in ipairs(report.mismatches) do print('mismatch', m.account, m.expected, m.actual) end
    return #report.mismatches == 0
end

describe('transfers on a real database', function()
    it('pays an offline citizen by citizen ID exactly once for one ref', function()
        local payload = { ref = 'rt-once-000001', from = 'personal', to = { type = 'citizen', citizenid = 'OFF00001' }, amount = 200, note = 'for the car' }
        local first = rpc(ME, 'transfer', payload)
        assert_true(first.ok, tostring(first.error) .. ' ' .. tostring(first.message))
        local again = rpc(ME, 'transfer', payload)
        assert_true(again.ok and again.duplicate, 'the retry returns the first result')
        assert_eq(offlineBank('OFF00001'), 250)
        assert_eq(Mock.players[ME].PlayerData.money.bank, 4800)
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key = 'bankapp:ME000001:x:rt-once-000001' AND state = 'completed'"), 1)
        assert_eq(count("SELECT COUNT(*) FROM bank_transactions WHERE note = 'for the car'"), 2, 'one history line per side')
        assert_true(MySQL.scalar.await("SELECT iban FROM bank_personal_iban WHERE citizenid = 'OFF00001'") ~= nil, 'the recipient got an IBAN')
    end)
    it('the daily limit counts the last 24 hours only', function()
        Config.App.dailyTransferLimit = 450
        assert_eq(rpc(ME, 'transfer', { ref = 'rt-limit-00001', from = 'personal', to = { type = 'citizen', citizenid = 'OFF00001' }, amount = 300 }).error, 'daily_limit')
        MySQL.update.await("UPDATE pf_transactions SET created_at = NOW() - INTERVAL 2 DAY WHERE idempotency_key = 'bankapp:ME000001:x:rt-once-000001'")
        assert_true(rpc(ME, 'transfer', { ref = 'rt-limit-00002', from = 'personal', to = { type = 'citizen', citizenid = 'OFF00001' }, amount = 300 }).ok)
        Config.App.dailyTransferLimit = 1000000
        assert_eq(offlineBank('OFF00001'), 550)
    end)
    it('a transfer between two shared accounts of the player works by permission', function()
        local a = MySQL.insert.await("INSERT INTO bank_accounts_v2 (iban, label, type, owner, balance) VALUES ('PF70000001', 'Savings', 'shared', 'ME000001', 0)")
        local b = MySQL.insert.await("INSERT INTO bank_accounts_v2 (iban, label, type, owner, balance) VALUES ('PF70000002', 'Holiday', 'shared', 'ME000001', 0)")
        MySQL.insert.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, 0), (?, 0)', { 'acct:' .. a, 'acct:' .. b })
        assert_true(rpc(ME, 'transfer', { ref = 'rt-own-000001', from = 'personal', to = { type = 'own', account = 'acct:' .. a }, amount = 1000 }).ok)
        assert_true(rpc(ME, 'transfer', { ref = 'rt-own-000002', from = 'acct:' .. a, to = { type = 'own', account = 'acct:' .. b }, amount = 400 }).ok)
        assert_eq(tonumber(MySQL.scalar.await('SELECT balance FROM bank_accounts_v2 WHERE id = ?', { a })), 600)
        assert_eq(tonumber(MySQL.scalar.await('SELECT balance FROM bank_accounts_v2 WHERE id = ?', { b })), 400)
        assert_eq(rpc(OTHER, 'transfer', { ref = 'rt-own-000003', from = 'acct:' .. a, to = { type = 'own', account = 'personal' }, amount = 1 }).error, 'not_authorized')
        assert_true(noMismatches())
    end)
end)

describe('statements on a real database', function()
    it('pages newest first and filters by direction, kind, text and period', function()
        for i = 1, 30 do
            local res = L.Transfer({ from = 'system:paycheck', to = 'player:OT000001:bank', amount = 10 + i, key = 'rt-wage-' .. i, kind = 'wage', reason = (i % 2 == 0) and 'Shift pay' or 'Bonus' })
            assert_true(res.ok)
        end
        assert_true(L.Transfer({ from = 'player:OT000001:bank', to = 'system:test', amount = 5, key = 'rt-out-1', kind = 'purchase', reason = 'Coffee' }).ok)
        MySQL.update.await("UPDATE pf_transactions SET created_at = NOW() - INTERVAL 10 DAY WHERE idempotency_key IN ('rt-wage-1', 'rt-wage-2', 'rt-wage-3')")

        local p1 = rpc(OTHER, 'statement', { account = 'personal' })
        assert_true(p1.ok)
        assert_eq(#p1.rows, Config.App.statementPageSize)
        assert_true(p1.hasMore)
        assert_eq(p1.rows[1].reason, 'Coffee', 'newest first')
        assert_eq(p1.rows[1].direction, 'out')
        assert_eq(p1.rows[2].counterparty.label, 'Paycheck')
        assert_eq(p1.summary.lines, 31)
        assert_eq(p1.summary.moneyOut, 5)
        local p2 = rpc(OTHER, 'statement', { account = 'personal', before = p1.nextBefore })
        assert_eq(#p2.rows, 6)
        assert_false(p2.hasMore)
        assert_true(p2.rows[1].id < p1.rows[#p1.rows].id)

        assert_eq(#rpc(OTHER, 'statement', { account = 'personal', direction = 'out' }).rows, 1)
        assert_eq(rpc(OTHER, 'statement', { account = 'personal', direction = 'in' }).summary.lines, 30)
        assert_eq(rpc(OTHER, 'statement', { account = 'personal', kind = 'purchase' }).summary.lines, 1)
        assert_eq(rpc(OTHER, 'statement', { account = 'personal', search = 'Shift' }).summary.lines, 15)
        assert_eq(rpc(OTHER, 'statement', { account = 'personal', search = '%' }).summary.lines, 0, 'LIKE wildcards are literal')
        assert_eq(rpc(OTHER, 'statement', { account = 'personal', days = 7 }).summary.lines, 28)
        assert_eq(rpc(OTHER, 'statement', { account = 'personal', days = 7, kind = "x' OR '1'='1" }).summary.lines, 28, 'a bad kind is ignored, never pasted')
        assert_eq(rpc(OTHER, 'statement', { account = 'personal', days = 3 }).summary.lines, 31, 'only the offered periods filter')
    end)
    it('names people and accounts on the other side', function()
        local st = rpc(ME, 'statement', { account = 'personal', direction = 'out' })
        local labels = {}
        for _, r in ipairs(st.rows) do labels[r.counterparty.label] = true end
        assert_true(labels['Olga Ford'], 'the recipient by name')
        assert_true(labels['Savings'], 'a shared account by label')
    end)
end)

describe('society accounts on a real database', function()
    it('a boss deposits and withdraws through the ledger; nothing is created', function()
        assert_true(rpc(BOSS, 'transfer', { ref = 'rt-soc-000001', from = 'personal', to = { type = 'own', account = 'society:mechanic' }, amount = 700 }).ok)
        assert_eq(society('mechanic'), 1700)
        assert_true(rpc(BOSS, 'transfer', { ref = 'rt-soc-000002', from = 'society:mechanic', to = { type = 'own', account = 'personal' }, amount = 1700 }).ok)
        assert_eq(society('mechanic'), 0)
        assert_eq(rpc(BOSS, 'transfer', { ref = 'rt-soc-000003', from = 'society:mechanic', to = { type = 'own', account = 'personal' }, amount = 1 }).error, 'insufficient_funds')
        assert_eq(Mock.players[BOSS].PlayerData.money.bank, 6000)
        assert_eq(count("SELECT COUNT(*) FROM bank_statements WHERE account_name = 'mechanic'"), 2, 'society statement lines')
        assert_eq(rpc(ME, 'transfer', { ref = 'rt-soc-000004', from = 'personal', to = { type = 'own', account = 'society:mechanic' }, amount = 10 }).error, 'not_authorized')
        local ex = exports['pfm-banking']:SocietyTransfer(BOSS, { society = 'mechanic', direction = 'deposit', account = 'cash', amount = 1, key = 'rt-soc-cash' })
        assert_eq(ex.error, 'insufficient_funds', 'the boss has no cash: nothing moves')
        assert_true(noMismatches())
        local st = rpc(BOSS, 'statement', { account = 'society:mechanic' })
        assert_eq(st.summary.moneyIn, 700)
        assert_eq(st.summary.moneyOut, 1700)
    end)
end)

describe('branch closures with the real bank', function()
    it('cash at a closed branch is refused, then works after it reopens', function()
        local legion = Config.locations[1]
        Mock.coords[ME] = vector3(legion.x, legion.y, legion.z)
        TriggerEvent('qb-banking:server:SetBankClosed', 2, true)
        local res = Mock.callCallback('qb-banking:server:withdraw', ME, { accountName = 'checking', amount = 50 })
        assert_false(res.success)
        assert_eq(Mock.players[ME].PlayerData.money.cash, 300)
        Mock.clock = Mock.clock + Config.BranchClosure.minutes * 60 + 5
        res = Mock.callCallback('qb-banking:server:withdraw', ME, { accountName = 'checking', amount = 50 })
        assert_true(res.success)
        assert_eq(Mock.players[ME].PlayerData.money.cash, 350)
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE from_account = 'player:ME000001:bank' AND to_account = 'player:ME000001:cash' AND state = 'completed'"), 1)
    end)
end)

describe('a deleted character', function()
    it('hands accounts to members, closes orphan accounts through the ledger and clears its rows', function()
        local shared = MySQL.insert.await("INSERT INTO bank_accounts_v2 (iban, label, type, owner, balance) VALUES ('PF80000001', 'Club', 'shared', 'GONE0001', 0)")
        local orphan = MySQL.insert.await("INSERT INTO bank_accounts_v2 (iban, label, type, owner, balance) VALUES ('PF80000002', 'Solo', 'business', 'GONE0001', 0)")
        MySQL.insert.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, 0), (?, 0)', { 'acct:' .. shared, 'acct:' .. orphan })
        assert_true(L.Transfer({ from = 'system:test', to = 'acct:' .. orphan, amount = 250, key = 'rt-orphan-fund' }).ok)
        MySQL.insert.await("INSERT INTO bank_account_members (account_id, citizenid, name, can_withdraw, can_deposit, can_cards, can_manage) VALUES (?, 'GONE0001', 'Gus', 1, 1, 1, 1), (?, 'OT000001', 'Otto', 0, 1, 0, 0), (?, 'GONE0001', 'Gus', 1, 1, 1, 1)", { shared, shared, orphan })
        MySQL.insert.await("INSERT INTO bank_account_cards (account_id, citizenid, holder_name, number, cvv, exp, design) VALUES (NULL, 'GONE0001', 'Gus', '4111', '123', '01/30', 'classic')")
        MySQL.insert.await("INSERT INTO bank_personal_iban (citizenid, iban) VALUES ('GONE0001', 'PF80000009')")
        MySQL.insert.await("INSERT INTO bank_credit (citizenid, score) VALUES ('GONE0001', 700)")
        MySQL.insert.await("INSERT INTO bank_loans (citizenid, tier, principal, balance, apr, payment_amount, payments_total, next_payment) VALUES ('GONE0001', 'Starter', 2500, 2950, 18, 246, 12, 0)")
        MySQL.insert.await("INSERT INTO bank_cards (citizenid, card_id, card_number, credit_limit, balance, apr) VALUES ('GONE0001', 'fleeca_green', '4000 1', 10000, 300, 24)")
        local ledgerRows = count('SELECT COUNT(*) FROM pf_transactions')

        TriggerEvent('pfm-core:server:characterDeleted', 'GONE0001')

        assert_eq(MySQL.scalar.await('SELECT owner FROM bank_accounts_v2 WHERE id = ?', { shared }), 'OT000001', 'the remaining member inherits')
        assert_eq(tonumber(MySQL.scalar.await("SELECT can_manage FROM bank_account_members WHERE account_id = ? AND citizenid = 'OT000001'", { shared })), 1)
        assert_eq(MySQL.scalar.await('SELECT id FROM bank_accounts_v2 WHERE id = ?', { orphan }), nil, 'the orphan account is closed')
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE from_account = ? AND to_account = 'system:closed_accounts' AND state = 'completed' AND amount = 250", { 'acct:' .. orphan }), 1)
        assert_eq(count("SELECT COUNT(*) FROM bank_account_members WHERE citizenid = 'GONE0001'"), 0)
        assert_eq(count("SELECT COUNT(*) FROM bank_account_cards WHERE citizenid = 'GONE0001'"), 0)
        assert_eq(count("SELECT COUNT(*) FROM bank_personal_iban WHERE citizenid = 'GONE0001'"), 0)
        assert_eq(count("SELECT COUNT(*) FROM bank_credit WHERE citizenid = 'GONE0001'"), 0)
        assert_eq(MySQL.scalar.await("SELECT status FROM bank_loans WHERE citizenid = 'GONE0001'"), 'written_off')
        assert_eq(MySQL.scalar.await("SELECT status FROM bank_cards WHERE citizenid = 'GONE0001'"), 'written_off')
        assert_eq(count('SELECT COUNT(*) FROM pf_transactions'), ledgerRows + 1, 'the ledger keeps every row and gains the close-out')
        assert_true(noMismatches())
        -- nobody can pay into the deleted character by IBAN any more
        local res = rpc(ME, 'transfer', { ref = 'rt-gone-00001', from = 'personal', to = { type = 'iban', iban = 'PF80000009' }, amount = 10 })
        assert_eq(res.error, 'unknown_iban')
    end)
    it('ignores a bad argument and calls from players', function()
        TriggerEvent('pfm-core:server:characterDeleted', '')
        TriggerEvent('pfm-core:server:characterDeleted', { 'x' })
        source = ME
        Mock.eventHandlers['pfm-core:server:characterDeleted']('OT000001')
        source = nil
        assert_true(MySQL.scalar.await("SELECT iban FROM bank_personal_iban WHERE citizenid = 'OFF00001'") ~= nil)
        assert_true(count("SELECT COUNT(*) FROM bank_account_members WHERE citizenid = 'OT000001'") > 0, 'nothing removed')
    end)
end)
