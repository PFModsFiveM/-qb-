-- Batch 16 (16D) on MariaDB: the MDT statements the pf-justice hand-over added
-- (pf-policemdt-DEV server/sentencing.lua), on the MDT's own migrated tables and the real ledger:
--   * a sentence row is written 'ju_pending', then 'done' with the fine order's key; pf-justice
--     (a contract stub here) gets the keyed orders; a cut-off 'ju_pending' row is settled from
--     pf-justice's orders; a later payment / bail updates the row;
--   * a legacy MDT bail whose own key paid into society:police after pf-justice took it over moves
--     once to society:doj on the real ledger (pf-policemdt:bailmove:<jailId>:<n>), the legacy row
--     untouched.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-services'] = 'missing', ['pf-devices'] = 'missing', ['ox_inventory'] = 'missing', ['pfm-inventory'] = 'missing',
    ['lj-inventory'] = 'missing', ['ps-inventory'] = 'missing', ['qs-inventory'] = 'missing', ['rcore_prison'] = 'missing', ['pfm-policejob'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
MySQL.query.await([[CREATE TABLE IF NOT EXISTS `pf_mdt_charges` (
  `id` INT NOT NULL AUTO_INCREMENT, `code` VARCHAR(16) NOT NULL UNIQUE, `name` VARCHAR(128) NOT NULL, `description` LONGTEXT NULL,
  `fineAmount` INT NOT NULL DEFAULT 0, `bailAmount` INT NOT NULL DEFAULT 0, `prisonTime` INT NOT NULL DEFAULT 0, `category` VARCHAR(64) NULL,
  PRIMARY KEY (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
MySQL.query.await([[INSERT INTO pf_mdt_charges (code, name, fineAmount, bailAmount, prisonTime) VALUES
  ('F1', 'Speeding', 300, 0, 0), ('J1', 'Robbery', 0, 500, 10)]])

QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, doj = { label = 'DOJ' } }
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
local function ox(kind)
    return function(_, sql, params, cb)
        if Mock.callable(params) then cb, params = params, nil end
        local r = MySQL[kind].await(sql, params)
        if cb then cb(r) end
        return r
    end
end
Mock.exportsByResource['oxmysql'] = { execute = ox('query'), query = ox('query'), fetch = ox('query'), insert = ox('insert'), update = ox('update'), scalar = ox('scalar'), single = ox('single') }

-- pf-justice by contract: keyed orders in memory
local JU = { orders = {}, n = 0, calls = {} }
Mock.exportsByResource['pf-justice'] = {
    IsIncarcerated = function() return false end,
    GetCustody = function() return { ok = true } end,
    GetOrders = function(_, cid, filter)
        local list = {}
        for _, o in pairs(JU.orders) do
            if o.cid == cid and not (filter and filter.states) then list[#list + 1] = o end
        end
        return { ok = true, list = list }
    end,
    CreateOrder = function(_, spec, opts)
        JU.calls[#JU.calls + 1] = opts.key
        for _, o in pairs(JU.orders) do if o.key == opts.key then return { ok = true, duplicate = true, orderId = o.id } end end
        JU.n = JU.n + 1
        JU.orders[JU.n] = { id = JU.n, key = opts.key, cid = spec.cid, kind = spec.kind, state = spec.kind == 'fine' and 'issued' or 'active',
            sourceRef = spec.sourceRef }
        return { ok = true, orderId = JU.n, state = JU.orders[JU.n].state }
    end,
    PayOrder = function() return { ok = false, error = 'insufficient_funds', state = 'invoiced' } end,
    GetActiveIncarceration = function() return { ok = true, remainingSeconds = 600 } end,
    GetOrder = function(_, id) return { ok = true, order = JU.orders[id] } end,
}
function LoadResourceFile(res, file)
    if res == 'pf-justice' and file == 'config.lua' then
        return "Config = Config or {}\nConfig.Bail = { Account = 'doj' }\nConfig.Compat = { LegacyRuntimes = { mdt = false, prison = false, policejob = false } }"
    end
end

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/schema.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/sentencing.lua')
local S = PFMdtSentencing
assert(S.Start(), 'pf-policemdt migrations')
assert(S.HandedOver(), 'pf-justice runs the MDT jails')

local OFFICER, CITIZEN = 1, 2
local STREET = vector3(100.0, 100.0, 30.0)
local function one(sql, p) return MySQL.single.await(sql, p or {}) end
local function n(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local function balance(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.clock = Mock.clock + 1000
    Mock.gameTimer = Mock.gameTimer + 1000000
    local o = Mock.newPlayer(OFFICER, 'OFF1')
    o.PlayerData.job = { name = 'police', type = 'leo', label = 'Police', grade = { level = 2 }, onduty = true }
    local c = Mock.newPlayer(CITIZEN, 'CIT2')
    c.PlayerData.metadata.ishandcuffed = true
    Mock.coords[OFFICER], Mock.coords[CITIZEN] = STREET, STREET
end

describe('MDT sentence rows after the hand-over (MariaDB)', function()
    local id
    it('a fine+sentence is one row: ju_pending, then done with the fine order key; the orders are keyed by it', function()
        local res = Mock.callCallback('pf_mdt:createSentence', OFFICER, { citizenId = 'CIT2', title = 'Robbery', sentenceType = 'fine+sentence', charges = { 'F1', 'J1' } })
        assert_eq(res.success, true, tostring(res.error))
        id = res.id
        local row = one('SELECT * FROM pf_mdt_sentences WHERE id = ?', { id })
        assert_eq(row.status, 'done')
        assert_eq(tonumber(row.fineAmount), 300)
        assert_eq(tonumber(row.prisonTime), 10)
        assert_eq(tonumber(row.bailAmount), 500)
        assert_eq(tonumber(row.fineSuccess), 0, 'invoiced, not paid')
        assert_eq(tonumber(row.jailSuccess), 1)
        assert_eq(row.fine_key, ('pf-policemdt:sentence:%d:fine'):format(id))
        assert_eq(JU.calls[1], ('pf-policemdt:sentence:%d:fine'):format(id))
        assert_eq(JU.calls[2], ('pf-policemdt:sentence:%d:jail'):format(id))
        assert_eq(n('SELECT COUNT(*) FROM pf_mdt_active_jails'), 0)
        assert_eq(n("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'pf-policemdt:%'"), 0, 'the MDT moved no money')
    end)
    it('the fine paid later through the invoice marks the row; posted bail records the payer', function()
        TriggerEvent('pf-justice:server:paymentSettled', { kind = 'fine', sourceRef = { type = 'mdt_sentence', id = tostring(id) } }, 'paid')
        assert_eq(tonumber(one('SELECT fineSuccess FROM pf_mdt_sentences WHERE id = ?', { id }).fineSuccess), 1)
        TriggerEvent('pf-justice:server:bailChanged', { orderId = 2, payerCid = 'PAY3', payerName = 'Pay Er' }, { to = 'posted' })
        local row = one('SELECT * FROM pf_mdt_sentences WHERE id = ?', { id })
        assert_eq(tonumber(row.bailed), 1)
        assert_eq(row.bailPaidByCitizenId, 'PAY3')
    end)
    it('a cut-off ju_pending row older than 10 minutes is settled from pf-justice; a fresh one is left alone', function()
        local old = MySQL.insert.await([[INSERT INTO pf_mdt_sentences (citizenId, title, sentenceType, fineAmount, prisonTime, status, createdAt)
            VALUES ('CIT2', 'Cut off', 'sentence', 0, 10, 'ju_pending', NOW() - INTERVAL 20 MINUTE)]])
        local fresh = MySQL.insert.await([[INSERT INTO pf_mdt_sentences (citizenId, title, sentenceType, fineAmount, prisonTime, status)
            VALUES ('CIT2', 'Running', 'sentence', 0, 10, 'ju_pending')]])
        JU.n = JU.n + 1
        JU.orders[JU.n] = { id = JU.n, cid = 'CIT2', kind = 'jail', state = 'active', sourceRef = { type = 'mdt_sentence', id = tostring(old) } }
        S.RecoverJusticeSentences()
        local r = one('SELECT * FROM pf_mdt_sentences WHERE id = ?', { old })
        assert_eq(r.status, 'done')
        assert_eq(tonumber(r.jailSuccess), 1)
        assert_eq(one('SELECT status FROM pf_mdt_sentences WHERE id = ?', { fresh }).status, 'ju_pending')
    end)
end)

describe('legacy MDT bail on the real ledger', function()
    it('a bail the old key paid into society:police moves once to society:doj; the legacy row is untouched', function()
        MySQL.query.await("DELETE FROM pf_transactions WHERE idempotency_key LIKE 'pf-policemdt:%'")
        exports['pfm-banking']:EnsureSocietyAccount('police', 'job')
        exports['pfm-banking']:EnsureSocietyAccount('doj', 'job')
        MySQL.update.await("UPDATE bank_accounts SET account_balance = 0 WHERE account_name IN ('police', 'doj')")
        local payer = Mock.newPlayer(3, 'PAYC')
        payer.PlayerData.money = { cash = 0, bank = 1000 }
        local key = 'pf-policemdt:bail:13:1-1'
        local res = exports['pfm-banking']:Transfer({ from = 'player:PAYC:bank', to = 'society:police', amount = 700, key = key, kind = 'bail' })
        assert_eq(res.ok, true, tostring(res.error))
        MySQL.insert.await([[INSERT INTO pf_mdt_active_jails (id, citizenid, sentence_id, remaining_seconds, total_seconds, bail_amount, bail_key, bail_payer_cid, reason, items, provider)
            VALUES (13, 'MDTC', 503, 1200, 1800, 700, ?, 'PAYC', 'Assault', '[]', 'qb-inventory')]], { key })
        local before = one('SELECT * FROM pf_mdt_active_jails WHERE id = 13')
        S.SettleLegacyBailMoves()
        assert_eq(balance('police'), 0)
        assert_eq(balance('doj'), 700)
        local tx = one('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { 'pf-policemdt:bailmove:13:1' })
        assert_eq(tx.state, 'completed')
        S.ResetJusticeConfig()
        S.SettleLegacyBailMoves()
        assert_eq(balance('doj'), 700, 'once')
        assert_eq(n("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'pf-policemdt:bailmove:%'"), 1)
        local after = one('SELECT * FROM pf_mdt_active_jails WHERE id = 13')
        assert_eq(after.bail_key, before.bail_key)
        assert_eq(tonumber(after.remaining_seconds), tonumber(before.remaining_seconds))
    end)
end)
