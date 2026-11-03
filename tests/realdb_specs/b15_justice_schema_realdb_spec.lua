-- pf-justice on a real database (batch 15B, acceptance 7 and the SQL of 2-6, 8): migration v1 creates
-- every table of 15B and 15C and is rerun-safe (also over an events table from the plan's first
-- draft); v2 waits for the 15C import code and applies once; unique idem_key / legacy_ref / citation
-- uid are enforced by the database; every pf-justice statement runs for real: orders, chains, the
-- clock's writes, adjustments, payments on the real ledger (paid, invoice, settled by the phone,
-- crash recovery by the sweep), deadlines, citations, records, expungement, audit retention and the
-- deleted-character anonymisation.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end

-- the bank
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
for _, soc in ipairs({ 'police', 'doj' }) do
    MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES (?, 0, 'job', '[]') ON DUPLICATE KEY UPDATE account_balance = 0", { soc })
    MySQL.query.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, 0)', { 'society:' .. soc })
end

local invoices = {}
Mock.exportsByResource['pfm-phone'] = {
    CreateInvoice = function(_, data) invoices[#invoices + 1] = data return 900 + #invoices end,
}

-- pf-justice
function GetCurrentResourceName() return 'pf-justice' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('[pfscripts]/pf-justice/config.lua')
load_resource('[pfscripts]/pf-justice/shared/states.lua')
load_resource('[pfscripts]/pf-justice/server/main.lua')
load_resource('[pfscripts]/pf-justice/server/schema.lua')
load_resource('[pfscripts]/pf-justice/server/orders.lua')
load_resource('[pfscripts]/pf-justice/server/clock.lua')
load_resource('[pfscripts]/pf-justice/server/records.lua')
load_resource('[pfscripts]/pf-justice/server/api.lua')
for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
Mock.exportsByResource['pf-justice'] = Mock.exportsByResource['__self']
local J = PFJustice
local api = exports['pf-justice']

local COP, SUSPECT, JUDGE = 1, 2, 3
local TABLES = { 'pf_justice_orders', 'pf_justice_order_events', 'pf_justice_citations', 'pf_justice_records', 'pf_justice_custody',
    'pf_justice_custody_log', 'pf_justice_bookings', 'pf_justice_property', 'pf_justice_property_items', 'pf_justice_bail', 'pf_justice_audit' }

local function scalar(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local function row(id) return MySQL.single.await('SELECT * FROM pf_justice_orders WHERE id = ?', { id }) end
local function balance(name) return scalar('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name }) end
local function as(res) Mock.invokingResource = res end
local function emitted(name)
    local n = 0
    for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-justice:server:' .. name then n = n + 1 end end
    return n
end
local function tableExists(t)
    return scalar('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }) == 1
end

local keyN = 0
local function key(prefix) keyN = keyN + 1 return (prefix or 'k') .. ':' .. keyN end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.clock = os.time()
    invoices = {}
    J.Rate.Forget('')
    for k in pairs(J.Clock.inmates) do J.Clock.inmates[k] = nil end
    for k in pairs(J.Clock.srcOf) do J.Clock.srcOf[k] = nil end
    for k in pairs(J.Orders.activeIndex) do J.Orders.activeIndex[k] = nil end
    -- each test starts with no open order (the database is shared by the tests of this file)
    pcall(MySQL.update.await, "UPDATE pf_justice_orders SET state = 'vacated' WHERE state IN ('pending', 'active', 'suspended')")
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.newPlayer(SUSPECT, 'SUSPECTCID').PlayerData.money = { cash = 300, bank = 1000 }
    local judge = Mock.newPlayer(JUDGE, 'JUDGECID')
    judge.PlayerData.job = { name = 'judge', onduty = true }
    Mock.coords = { [COP] = vector3(10.0, 20.0, 30.0), [SUSPECT] = vector3(1693.33, 2569.51, 45.56) }
    as('pf-policemdt-DEV')
end

describe('migrations', function()
    it('v1 upgrades an events table from the first draft (no idem_key) and creates every table', function()
        MySQL.query.await([[CREATE TABLE `pf_justice_order_events` (
            `id` BIGINT NOT NULL AUTO_INCREMENT, `order_id` INT NOT NULL, `action` VARCHAR(20) NOT NULL,
            `detail` LONGTEXT NULL, `actor_cid` VARCHAR(64) NULL, `actor_kind` VARCHAR(8) NULL, `actor_resource` VARCHAR(48) NULL, `at` BIGINT NOT NULL,
            PRIMARY KEY (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
        assert_true(J.Boot(), 'boot')
        for _, t in ipairs(TABLES) do assert_true(tableExists(t), t) end
        assert_eq(scalar([[SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = 'pf_justice_order_events' AND COLUMN_NAME = 'idem_key']]), 1)
        assert_eq(scalar([[SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = 'pf_justice_order_events' AND INDEX_NAME = 'uq_joe_key' AND NON_UNIQUE = 0]]), 1)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-justice' AND version = 1"), 1)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-justice' AND version = 2"), 0,
            'v2 waits for the 15C import code')
    end)

    it('is rerun-safe: every step again changes nothing (and v2 applies once with the import code)', function()
        -- the version row removed: all v1 steps run a second time over the existing tables
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-justice'")
        assert_true(J.Schema.Run())
        local runs = 0
        PFJustice.LegacyImport = { Run = function() runs = runs + 1 return { ok = true } end }
        assert_true(J.Schema.Run())
        assert_true(J.Schema.Run())
        assert_eq(runs, 1)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-justice'"), 2)
        PFJustice.LegacyImport = nil
    end)

    it('the database enforces unique idem_key, legacy_ref, citation uid and event keys (NULLs do not collide)', function()
        local function insert(keyValue, legacy)
            return pcall(MySQL.insert.await, [[INSERT INTO pf_justice_orders (citizenid, kind, state, idem_key, legacy_ref, created_at, updated_at)
                VALUES ('X1', 'fine', 'issued', ?, ?, 1, 1)]], { keyValue, legacy })
        end
        assert_true(insert('uq:1', nil))
        assert_false(insert('uq:1', nil), 'second idem_key refused')
        assert_true(insert(nil, nil))
        assert_true(insert(nil, nil), 'NULL keys do not collide')
        assert_true(insert(nil, 'mdt_jail:1'))
        assert_false(insert(nil, 'mdt_jail:1'), 'second legacy_ref refused')
        local cit = 'INSERT INTO pf_justice_citations (order_id, uid, violation, officer_cid, at) VALUES (1, ?, ?, ?, 1)'
        assert_true(pcall(MySQL.insert.await, cit, { 'CTUQ', 'Speeding', 'C' }))
        assert_false(pcall(MySQL.insert.await, cit, { 'CTUQ', 'Speeding', 'C' }))
        local ev = "INSERT INTO pf_justice_order_events (order_id, action, idem_key, at) VALUES (1, 'x', ?, 1)"
        assert_true(pcall(MySQL.insert.await, ev, { 'ek:1' }))
        assert_false(pcall(MySQL.insert.await, ev, { 'ek:1' }))
        MySQL.query.await("DELETE FROM pf_justice_orders WHERE citizenid = 'X1'")
    end)

    it('the property items receipt cascades with its property row', function()
        local pid = MySQL.insert.await([[INSERT INTO pf_justice_property (citizenid, stash_id, state, seized_at) VALUES ('X2', 'pf_justice_property_t', 'held', 1)]])
        MySQL.insert.await('INSERT INTO pf_justice_property_items (property_id, item, amount) VALUES (?, ?, 1)', { pid, 'phone' })
        MySQL.query.await('DELETE FROM pf_justice_property WHERE id = ?', { pid })
        assert_eq(scalar('SELECT COUNT(*) FROM pf_justice_property_items WHERE property_id = ?', { pid }), 0)
    end)
end)

describe('orders on the real database', function()
    it('CreateOrder: one row per key, a created event, duplicate and key_reused', function()
        local k = key('mdt')
        local spec = { cid = 'SUSPECTCID', kind = 'prison', minutes = 20, charges = { { code = 'P-1', label = 'Theft' } },
            sourceRef = { type = 'mdt_sentence', id = '44' } }
        local a = api:CreateOrder(spec, { key = k, actor = { src = COP } })
        assert_true(a.ok)
        local b = api:CreateOrder(spec, { key = k, actor = { src = COP } })
        assert_true(b.duplicate)
        assert_eq(b.orderId, a.orderId)
        spec.minutes = 25
        assert_eq(api:CreateOrder(spec, { key = k, actor = { src = COP } }).error, 'key_reused')
        assert_eq(scalar('SELECT COUNT(*) FROM pf_justice_orders WHERE idem_key = ?', { k }), 1)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_order_events WHERE order_id = ? AND action = 'created'", { a.orderId }), 1)
        local r = row(a.orderId)
        assert_eq(r.state, 'active')
        assert_eq(tonumber(r.required_seconds), 1200)
        assert_eq(r.clock, 'online')
        assert_eq(r.created_by, 'COPCID')
        assert_eq(emitted('orderCreated'), 1)
        local list = api:GetOrders('SUSPECTCID', { kinds = { 'prison' }, states = { 'active' } })
        assert_eq(list.list[1].id, a.orderId)
        assert_eq(list.list[1].charges[1].code, 'P-1')
    end)

    it('the clock writes, credits, chain promotion and release use the real statements', function()
        local a = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'jail', minutes = 1 }, { key = key(), actor = { src = COP } }).orderId
        local b = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'jail', minutes = 2 }, { key = key(), actor = { src = COP } }).orderId
        assert_eq(row(b).state, 'pending')
        assert_eq(tonumber(row(b).parent_order_id), a)
        -- pfm-prison is "started" but has no IsInside here: the fallback radius decides (the suspect stands at the centre)
        for _ = 1, 4 do Mock.clock = Mock.clock + 15 J.Clock.Tick(Mock.clock) end
        assert_eq(row(a).state, 'completed')
        assert_eq(row(b).state, 'active')
        assert_eq(tonumber(row(b).served_seconds), 60)
        assert_eq(tonumber(row(b).last_tick_at), Mock.clock)
        as('pfm-prison')
        local c = api:AdjustOrder(b, { kind = 'credit', seconds = 30 }, { key = 'pfm-prison:credit:' .. b .. ':1' })
        assert_eq(c.applied, 30)
        assert_true(api:AdjustOrder(b, { kind = 'credit', seconds = 30 }, { key = 'pfm-prison:credit:' .. b .. ':1' }).duplicate)
        assert_eq(tonumber(row(b).credit_seconds), 30)
        for _ = 1, 2 do Mock.clock = Mock.clock + 15 J.Clock.Tick(Mock.clock) end
        assert_eq(row(b).state, 'completed')
        assert_eq(emitted('releaseOrdered'), 1)
        assert_eq(scalar([[SELECT COUNT(*) FROM pf_justice_orders WHERE citizenid = 'SUSPECTCID' AND kind IN ('jail','prison','remand') AND state = 'active']]), 0)
        -- the conviction entries of both served orders
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_records WHERE citizenid = 'SUSPECTCID' AND kind = 'conviction' AND ref_type = 'order' AND ref_id IN (?, ?)",
            { tostring(a), tostring(b) }), 2)
    end)

    it('ReleaseNow and suspend/resume on the real table', function()
        local a = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'prison', minutes = 30 }, { key = key(), actor = { src = COP } }).orderId
        as('pfm-prison')
        assert_true(api:AdjustOrder(a, { kind = 'suspend' }, { key = key('esc') }).ok)
        assert_eq(row(a).state, 'suspended')
        assert_true(api:AdjustOrder(a, { kind = 'resume' }, { key = key('back') }).ok)
        assert_eq(row(a).state, 'active')
        as('pfm-policejob')
        local res = api:ReleaseNow(SUSPECT, '/unjail', { actor = { src = COP } })
        assert_eq(res.released, 1)
        assert_eq(row(a).state, 'vacated')
        assert_true(tonumber(row(a).ends_at) ~= nil)
    end)

    it('PayOrder: the real ledger pays society:police once under the order key', function()
        local f = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'fine', amount = 400, sourceRef = { type = 'mdt_sentence', id = '1' } },
            { key = key(), actor = { src = COP } }).orderId
        local before = balance('police')
        local res = api:PayOrder(f, { payerSrc = SUSPECT, account = 'bank', key = key('pay') })
        assert_true(res.ok)
        assert_eq(row(f).state, 'paid')
        assert_eq(tonumber(row(f).paid_amount), 400)
        assert_eq(row(f).pay_key, 'pf-justice:order:' .. f .. ':pay:1')
        assert_eq(balance('police'), before + 400)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key = ? AND state = 'completed'", { 'pf-justice:order:' .. f .. ':pay:1' }), 1)
        assert_eq(Mock.players[SUSPECT].PlayerData.money.bank, 600)
    end)

    it('a refusal becomes an invoice matched by invoice_id; the phone settles it', function()
        local f = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'fine', amount = 50000, sourceRef = { type = 'court_decision', id = 'c' } },
            { key = key(), actor = { src = COP } }).orderId
        local res = api:PayOrder(f, { payerSrc = SUSPECT, key = key('pay') })
        assert_eq(res.state, 'invoiced')
        assert_eq(invoices[#invoices].society, 'doj')
        assert_eq(tonumber(row(f).invoice_id), res.invoiceId)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key = ? AND state = 'failed'", { 'pf-justice:order:' .. f .. ':pay:1' }), 1)
        Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { id = res.invoiceId }, 'paid')
        assert_eq(row(f).state, 'paid')
    end)

    it('the sweep settles a payment the crash left behind, from the ledger key', function()
        local f = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'fine', amount = 120, sourceRef = { type = 'mdt_sentence', id = '2' } },
            { key = key(), actor = { src = COP } }).orderId
        local ledgerKey = 'pf-justice:order:' .. f .. ':pay:1'
        -- the money moved, then the server stopped before the order was marked paid
        assert_true(PFPayout.Transfer({ from = 'player:SUSPECTCID:bank', to = 'society:police', amount = 120, key = ledgerKey }).ok)
        MySQL.update.await("UPDATE pf_justice_orders SET state = 'payment_pending', pay_attempt = 1, pay_key = ?, updated_at = 0 WHERE id = ?", { ledgerKey, f })
        local g = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'fine', amount = 80, sourceRef = { type = 'mdt_sentence', id = '3' } },
            { key = key(), actor = { src = COP } }).orderId
        MySQL.update.await("UPDATE pf_justice_orders SET state = 'payment_pending', pay_attempt = 1, pay_key = ?, updated_at = 0 WHERE id = ?",
            { 'pf-justice:order:' .. g .. ':pay:1', g })
        J.Orders.Sweep(Mock.clock)
        assert_eq(row(f).state, 'paid', 'completed in the ledger')
        assert_eq(row(g).state, 'issued', 'never reached the ledger: nothing moved')
        assert_eq(scalar('SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key = ?', { ledgerKey }), 1)
    end)

    it('deadlines and supervision ends are swept with the real queries', function()
        local f = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'fine', amount = 10, sourceRef = { type = 'mdt_sentence', id = '4' } },
            { key = key(), actor = { src = COP } }).orderId
        local p = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'parole', days = 1 }, { key = key(), actor = { src = COP } }).orderId
        local cs = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'community_service', units = 3 }, { key = key(), actor = { src = COP } }).orderId
        Mock.clock = Mock.clock + 40 * 86400
        J.Orders.Sweep(Mock.clock)
        assert_eq(row(f).state, 'overdue')
        assert_eq(row(cs).state, 'overdue')
        assert_eq(row(p).state, 'completed')
    end)

    it('citations: order + citation row, contest window', function()
        as('pfm-policejob')
        local res = api:IssueCitation({ cid = 'SUSPECTCID', amount = 75, violation = 'Red light', officerSrc = COP, plate = 'pf123' },
            { key = 'pfm-policejob:citation:' .. key() })
        assert_true(res.ok)
        local c = MySQL.single.await('SELECT * FROM pf_justice_citations WHERE id = ?', { res.citationId })
        assert_eq(tonumber(c.order_id), res.orderId)
        assert_eq(c.officer_cid, 'COPCID')
        assert_eq(c.plate, 'PF123')
        assert_eq(tonumber(c.x), 10)
        assert_eq(row(res.orderId).source_id, c.uid)
        as('pf-policemdt-DEV')
        assert_true(api:ContestCitation(res.orderId, { actor = { src = SUSPECT } }).ok)
        assert_eq(api:ContestCitation(res.orderId, { actor = { src = SUSPECT } }).error, 'invalid_state')
        assert_eq(row(res.orderId).state, 'contested')
    end)

    it('records: dedupe by ref, filtered reads, audited soft expunge, audit retention', function()
        local e = api:AddRecordEntry('SUSPECTCID', { kind = 'arrest', ref = 'custody:77', summary = 'Arrested' }, {})
        assert_true(api:AddRecordEntry('SUSPECTCID', { kind = 'arrest', ref = 'custody:77', summary = 'Again' }, {}).duplicate)
        as('pf-government')
        local x = api:Expunge('SUSPECTCID', { e.entryId }, { actor = { src = JUDGE }, courtOrderId = 'CO-1' })
        assert_eq(x.n, 1)
        local r = MySQL.single.await('SELECT * FROM pf_justice_records WHERE id = ?', { e.entryId })
        assert_true(tonumber(r.expunged_at) ~= nil)
        assert_eq(r.expunged_by, 'JUDGECID')
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_audit WHERE entity = 'record' AND action = 'expunge' AND entity_id = 'SUSPECTCID'"), 1)
        for _, entry in ipairs(api:GetRecord('SUSPECTCID', {}).entries) do assert_true(entry.id ~= e.entryId, 'expunged entries are hidden') end
        -- retention: rows older than RetentionDays go, newer stay
        MySQL.insert.await("INSERT INTO pf_justice_audit (entity, entity_id, action, at) VALUES ('test', 'old', 'x', 1)")
        local n = J.Audit.Sweep(Mock.clock)
        assert_true(n >= 1)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_audit WHERE entity_id = 'old'"), 0)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_audit WHERE entity = 'record' AND action = 'expunge'"), 1)
    end)

    it('a deleted character: open orders vacated / waived, history anonymised under one token', function()
        Mock.newPlayer(9, 'GONECID')
        local a = api:CreateOrder({ cid = 'GONECID', kind = 'prison', minutes = 30 }, { key = key(), actor = { src = COP } }).orderId
        local f = api:CreateOrder({ cid = 'GONECID', kind = 'fine', amount = 30, sourceRef = { type = 'mdt_sentence', id = '9' } },
            { key = key(), actor = { src = COP } }).orderId
        local r = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'restitution', amount = 30, victimCid = 'GONECID' }, { key = key(), actor = { src = COP } }).orderId
        local e = api:AddRecordEntry('GONECID', { kind = 'note', summary = 'history' }, {}).entryId
        Mock.players[9] = nil
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'GONECID')
        assert_eq(row(a).state, 'vacated')
        assert_eq(row(f).state, 'waived')
        local token = row(a).citizenid
        assert_eq(token:sub(1, 5), 'anon-')
        assert_eq(row(f).citizenid, token)
        assert_eq(row(r).victim_cid, token)
        assert_eq(MySQL.single.await('SELECT citizenid FROM pf_justice_records WHERE id = ?', { e }).citizenid, token)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_orders WHERE citizenid = 'GONECID'"), 0)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_audit WHERE entity = 'character' AND entity_id = ?", { token }), 1)
    end)
end)
