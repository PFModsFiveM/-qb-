-- Batch 19 (19E) on MariaDB with the real pfm-banking ledger: prison work and the inmate trust.
--   * a finished shift is one pf_prison_work_log row (ticket numbered per order), a capped pf-justice
--     credit under pfm-prison:credit:<orderId>:<ticket> and a wage society:corrections -> trust;
--   * the daily caps hold (shifts, credit seconds, wages);
--   * an empty corrections budget is a clear refusal: the next numbered key later, never the same;
--   * deposits, commissary purchases (goods only after the money moved), restitution shares to the
--     victim (pf-justice:restitution:<orderId>:<n>) and the release payout are keyed ledger moves;
--   * an unclear move is held as 'pending' and settled from the ledger's own record;
--   * the trust reconciles: the completed rows sum to the net ledger flow of system:pfm-prison-trust.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pfm-banking'] = 'started', ['pf-justice'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end
Mock.clock = 1800000000

-- the bank (corrections is a real job since 15H, so its society account exists in game)
QBCoreMock.Shared.Jobs = { corrections = { label = 'Corrections', grades = {} } }
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

-- pf-justice by contract
local JU = { calls = {}, restitution = {}, open = {}, record = true }
local function jcall(name, args) JU.calls[#JU.calls + 1] = { name = name, args = args } end
local function jcalls(name)
    local out = {}
    for _, c in ipairs(JU.calls) do if c.name == name then out[#out + 1] = c end end
    return out
end
local Justice = {
    AdjustOrder = function(orderId, change, opts)
        jcall('AdjustOrder', { orderId = orderId, change = change, opts = opts })
        if JU.adjustDown then return nil end
        return { ok = true, applied = math.min(change.seconds, JU.room or change.seconds) }
    end,
    GetOrders = function(cid, filter)
        local list = {}
        for _, o in ipairs(JU.restitution) do if o.cid == cid then list[#list + 1] = o end end
        return { ok = true, list = list }
    end,
    RecordRestitution = function(orderId, pay, opts)
        jcall('RecordRestitution', { orderId = orderId, pay = pay, opts = opts })
        if not JU.record then return { ok = false, error = 'busy' } end
        for _, o in ipairs(JU.restitution) do if o.id == orderId then o.paidAmount = o.paidAmount + pay.amount end end
        return { ok = true }
    end,
}
Mock.exportsByResource['pf-justice'] = {
    RecordRestitution = function(_, orderId) if orderId == 0 then return { ok = false, error = 'bad_args' } end end,
}

-- inventory: stashes and items in memory
local Stash, Given = {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    CanAddItem = function() return not JU.full end,
    AddItem = function(_, id, name, amount)
        if type(id) == 'number' then
            if JU.full then return false end
            Given[#Given + 1] = { src = id, name = name, amount = amount }
            return true
        end
        Stash[id] = Stash[id] or { items = {} }
        Stash[id].items[#Stash[id].items + 1] = { name = name, amount = amount }
        return true
    end,
    RemoveItem = function() return true end,
    GetInventory = function(_, id) return Stash[id] end,
    CreateInventory = function(_, id) Stash[id] = Stash[id] or { items = {} } end,
}
QBCoreMock.Shared.Items = QBCoreMock.Shared.Items or {}

-- pfm-prison: its config, schema, and the two 19E modules; the rest of the resource is stubbed
function GetCurrentResourceName() return 'pfm-prison' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-prison/config.lua')
load_resource('pfm-prison/config_work.lua')
load_resource('pfm-prison/server/schema.lua')
PFPrison = PFPrison or {}
PFPrison.Bridge = {
    rows = {},
    Justice = function(name, ...) return Justice[name](...) end,
    OpenOrders = function(cid) return JU.open[cid] or {} end,
}
PFPrison.Internal = {
    getPlayer = function(src) return exports['pfm-core']:GetPlayer(src) end,
    pedPos = function(src) return Mock.coords[src] end,
    jobs = {}, track = {}, inmates = {}, lockdownUntil = function() return 0 end,
}
PFPrison.Regime = function() return 'justice' end
load_resource('pfm-prison/server/work.lua')
load_resource('pfm-prison/server/economy.lua')
local W, E = PFPrison.Work, PFPrison.Economy
local CW, EC = Config.Work, Config.Economy

local function scalar(q, p) return tonumber(MySQL.scalar.await(q, p or {})) end
local function rows(q, p) return MySQL.query.await(q, p or {}) or {} end
local function fund(name, amount, key) assert_true((exports['pfm-banking']:AddMoney(name, amount, 'test funding', key)), 'funded ' .. name) end
local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function tx(key) return MySQL.single.await('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { key }) end
local function reconciled()
    local r = E.Reconcile()
    assert_true(r.ok, ('trust reconciles (rows %s, ledger %s)'):format(tostring(r.rows), tostring(r.ledger)))
    return r
end

local INMATE, OTHER = 1, 2
local seq, CID, ORDER = 0, nil, nil
local function admit(src, cid, orderId)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money.bank = 1000
    PFPrison.Bridge.rows[cid] = { citizenid = cid, order_id = orderId, status = 'in_cell' }
    Mock.coords[src] = vector3(EC.Kiosk.x, EC.Kiosk.y, EC.Kiosk.z)
end
local function inmate(src) return PFPrison.Inmate(src) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    seq = seq + 1
    Mock.clock = Mock.clock + 86400 -- a new day: fresh daily limits
    CID, ORDER = 'INM' .. seq, 100 + seq
    JU.calls, JU.restitution, JU.open, JU.record, JU.room, JU.adjustDown, JU.full = {}, {}, {}, true, nil, false, false
    Given = {}
    E.restProbe = { at = -math.huge, ok = false }
    for k in pairs(PFPrison.Bridge.rows) do PFPrison.Bridge.rows[k] = nil end
    for k in pairs(W.credits) do W.credits[k] = nil end
    admit(INMATE, CID, ORDER)
end

describe('schema v3 (19D) as 19E uses it', function()
    it('the economy tables exist and every step is rerun-safe', function()
        assert_true(PFPrisonSchema.Run())
        for _, t in ipairs({ 'pf_prison_account_tx', 'pf_prison_work_log', 'pf_prison_privileges', 'pf_prison_events' }) do
            assert_eq(scalar('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }), 1, t)
        end
        for _, sql in ipairs(PFPrisonSchema.V3) do MySQL.query.await(sql) end
    end)
end)

describe('a finished shift', function()
    it('writes ticket 1, credits pf-justice under the contract key and pays the wage into the trust', function()
        fund('corrections', 10000, 'b19e:fund:' .. seq)
        local rec = W.Complete(inmate(INMATE), 'kitchen', { meals = 4 })
        assert_true(rec.ok)
        assert_eq(rec.ticket, 1)
        local adj = jcalls('AdjustOrder')
        assert_eq(#adj, 1)
        assert_eq(adj[1].args.opts.key, ('pfm-prison:credit:%d:1'):format(ORDER))
        assert_eq(adj[1].args.change.kind, 'credit')
        assert_eq(adj[1].args.change.seconds, CW.Jobs.kitchen.creditSeconds)
        local log = MySQL.single.await('SELECT * FROM pf_prison_work_log WHERE order_id = ? AND ticket = 1', { ORDER })
        assert_eq(tonumber(log.credit_seconds), CW.Jobs.kitchen.creditSeconds)
        assert_eq(tonumber(log.wage), CW.Jobs.kitchen.wage)
        local key = ('pfm-prison:trust:%s:e%d.1.1'):format(CID, ORDER)
        assert_eq(tx(key).state, 'completed')
        assert_eq(tx(key).from_account, 'society:corrections')
        assert_eq(tx(key).to_account, 'system:pfm-prison-trust')
        assert_eq(E.Balance(CID).available, CW.Jobs.kitchen.wage)
        assert_eq(society('corrections'), 10000 - CW.Jobs.kitchen.wage)
        local rec2 = W.Complete(inmate(INMATE), 'laundry', {})
        assert_eq(rec2.ticket, 2, 'tickets are numbered per order')
        reconciled()
    end)
    it('a credit pf-justice could not take is retried with the same key and stored when applied', function()
        fund('corrections', 1000, 'b19e:fund:' .. seq)
        JU.adjustDown = true
        local rec = W.Complete(inmate(INMATE), 'laundry', {})
        assert_eq(rec.applied, nil)
        assert_eq(scalar('SELECT credit_seconds FROM pf_prison_work_log WHERE order_id = ? AND ticket = 1', { ORDER }), -CW.Jobs.laundry.creditSeconds)
        -- a restart reloads the pending credit from the table
        for k in pairs(W.credits) do W.credits[k] = nil end
        assert_eq(W.Boot(Mock.clock), 1)
        JU.adjustDown, JU.room = false, 100
        W.Tick(Mock.clock)
        local adj = jcalls('AdjustOrder')
        assert_eq(adj[#adj].args.opts.key, adj[1].args.opts.key, 'the same key on the retry')
        assert_eq(scalar('SELECT credit_seconds FROM pf_prison_work_log WHERE order_id = ? AND ticket = 1', { ORDER }), 100, 'what pf-justice applied (its MaxShare cap)')
        assert_eq(next(W.credits), nil)
    end)
end)

describe('caps', function()
    it('credits, wages and shifts stop at the daily limits', function()
        fund('corrections', 100000, 'b19e:fund:' .. seq)
        local credited, paid, n = 0, 0, 0
        for _ = 1, CW.MaxTicketsPerDay + 2 do
            local rec = W.Complete(inmate(INMATE), 'maintenance', {})
            if rec.ok then
                n = n + 1
                credited, paid = credited + rec.credit, paid + rec.wage
                assert_true(rec.credit <= CW.Jobs.maintenance.creditSeconds)
            else
                assert_eq(rec.error, 'limit')
            end
        end
        assert_eq(n, CW.MaxTicketsPerDay)
        assert_eq(credited, CW.MaxCreditSecondsPerDay)
        assert_eq(paid, CW.MaxWagePerDay)
        assert_eq(scalar('SELECT SUM(credit_seconds) FROM pf_prison_work_log WHERE citizenid = ?', { CID }), CW.MaxCreditSecondsPerDay)
        for _, c in ipairs(jcalls('AdjustOrder')) do assert_true(c.args.change.seconds <= CW.Jobs.maintenance.creditSeconds) end
        assert_eq(E.Balance(CID).available, CW.MaxWagePerDay)
        reconciled()
    end)
end)

describe('an empty corrections budget', function()
    it('is a clear refusal: nothing moves; a later retry uses the next numbered key', function()
        MySQL.update.await("UPDATE bank_accounts SET account_balance = 0 WHERE account_name = 'corrections'")
        local rec = W.Complete(inmate(INMATE), 'kitchen', {})
        assert_eq(rec.wageState, 'failed')
        local k1 = ('pfm-prison:trust:%s:e%d.1.1'):format(CID, ORDER)
        assert_eq(tx(k1).state, 'failed')
        assert_eq(E.Balance(CID).available, 0)
        assert_eq(E.RetryTick(Mock.clock), 0, 'not before EarningRetrySeconds')
        fund('corrections', 500, 'b19e:fund:' .. seq)
        Mock.clock = Mock.clock + EC.EarningRetrySeconds
        assert_eq(E.RetryTick(Mock.clock), 1)
        local k2 = ('pfm-prison:trust:%s:e%d.1.2'):format(CID, ORDER)
        assert_eq(tx(k2).state, 'completed')
        assert_eq(tx(k1).state, 'failed', 'the failed key stays failed')
        assert_eq(E.Balance(CID).available, CW.Jobs.kitchen.wage)
        assert_eq(E.RetryTick(Mock.clock + 1000), 0, 'paid once')
        reconciled()
    end)
end)

describe('deposits and the commissary', function()
    it('a deposit moves the inmate\'s own bank money; a purchase gives goods only after it is paid', function()
        Mock.fireNet('pfm-prison:server:TrustDeposit', INMATE, 30)
        assert_eq(Mock.players[INMATE].PlayerData.money.bank, 970)
        assert_eq(E.Balance(CID).available, 30)
        assert_eq(tx(MySQL.scalar.await("SELECT ledger_key FROM pf_prison_account_tx WHERE citizenid = ? AND kind = 'deposit'", { CID })).from_account,
            ('player:%s:bank'):format(CID))
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pfm-prison:server:CommissaryBuy', INMATE, 1, 2) -- 2 x noodles at 12
        assert_eq(#Given, 1)
        assert_eq(Given[1].name, EC.Commissary[1].item)
        assert_eq(Given[1].amount, 2)
        assert_eq(E.Balance(CID).available, 30 - 2 * EC.Commissary[1].price)
        local row = MySQL.single.await("SELECT * FROM pf_prison_account_tx WHERE citizenid = ? AND kind = 'purchase'", { CID })
        assert_eq(row.ref, ('buy:%s:2:given'):format(EC.Commissary[1].item))
        assert_eq(tx(row.ledger_key).to_account, 'society:corrections')
        -- more than the balance, more than the item's daily limit: refused, nothing written
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pfm-prison:server:CommissaryBuy', INMATE, 5, 1)
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pfm-prison:server:CommissaryBuy', INMATE, 1, 3)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_prison_account_tx WHERE citizenid = ? AND kind = 'purchase'", { CID }), 1)
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pfm-prison:server:CommissaryBuy', INMATE, 2, 1) -- a soda at 6: exactly what is left
        assert_eq(#Given, 2)
        assert_eq(E.Balance(CID).available, 0)
        reconciled()
    end)
    it('away from the window or with the privilege suspended nothing is sold; a client price is never read', function()
        Mock.fireNet('pfm-prison:server:TrustDeposit', INMATE, 50)
        Mock.clock = Mock.clock + 5
        MySQL.insert.await("INSERT INTO pf_prison_privileges (citizenid, kind, until_at) VALUES (?, 'commissary', ?)", { CID, Mock.clock + 3600 })
        Mock.fireNet('pfm-prison:server:CommissaryBuy', INMATE, 1, 1)
        assert_eq(#Given, 0)
        MySQL.update.await('DELETE FROM pf_prison_privileges WHERE citizenid = ?', { CID })
        Mock.coords[INMATE] = vector3(0, 0, 0)
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pfm-prison:server:CommissaryBuy', INMATE, 1, 1)
        assert_eq(#Given, 0)
        assert_eq(E.Balance(CID).available, 50)
    end)
    it('goods that do not fit stay owed and are handed over at the window later, once', function()
        Mock.fireNet('pfm-prison:server:TrustDeposit', INMATE, 50)
        Mock.clock = Mock.clock + 5
        -- CanAddItem passes, AddItem then fails (the inventory filled meanwhile)
        local add = Mock.exportsByResource['pfm-inventory'].AddItem
        Mock.exportsByResource['pfm-inventory'].AddItem = function(self, id, ...) if type(id) == 'number' then return false end return add(self, id, ...) end
        Mock.fireNet('pfm-prison:server:CommissaryBuy', INMATE, 2, 1)
        Mock.exportsByResource['pfm-inventory'].AddItem = add
        assert_eq(#Given, 0)
        assert_eq(E.Balance(CID).available, 50 - EC.Commissary[2].price, 'paid')
        Mock.clock = Mock.clock + 5
        Mock.callCallback('pfm-prison:server:trustState', INMATE)
        assert_eq(#Given, 1)
        Mock.clock = Mock.clock + 5
        Mock.callCallback('pfm-prison:server:trustState', INMATE)
        assert_eq(#Given, 1, 'given once')
    end)
end)

describe('unclear ledger results', function()
    it('are held as pending (not spendable twice) and settled from the ledger record', function()
        Mock.fireNet('pfm-prison:server:TrustDeposit', INMATE, 100)
        -- the bank answers nothing clear for one purchase, but the transfer did happen
        local realTransfer = PFPayout.Transfer
        PFPayout.Transfer = function(opts)
            realTransfer(opts)
            return { ok = false, state = 'debited', error = 'interrupted' }
        end
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pfm-prison:server:CommissaryBuy', INMATE, 1, 1)
        -- and nothing for another: the key never reached the ledger
        PFPayout.Transfer = function() return { ok = false, unclear = true, error = 'internal_error' } end
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pfm-prison:server:CommissaryBuy', INMATE, 2, 1)
        PFPayout.Transfer = realTransfer
        assert_eq(#Given, 0, 'no goods while unclear')
        assert_eq(scalar("SELECT COUNT(*) FROM pf_prison_account_tx WHERE citizenid = ? AND ledger_state = 'pending'", { CID }), 2)
        local bal = E.Balance(CID)
        assert_eq(bal.available, 100 - EC.Commissary[1].price - EC.Commissary[2].price, 'pending spends are not spendable')
        Mock.clock = Mock.clock + EC.SettleAfterSeconds
        E.SettleTick(Mock.clock)
        assert_eq(#Given, 1, 'the one the ledger completed is delivered')
        assert_eq(scalar("SELECT COUNT(*) FROM pf_prison_account_tx WHERE citizenid = ? AND ledger_state = 'pending'", { CID }), 1, 'the unwritten one waits')
        Mock.clock = Mock.clock + EC.NotWrittenGraceSeconds
        E.SettleTick(Mock.clock)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_prison_account_tx WHERE citizenid = ? AND ledger_state = 'failed'", { CID }), 1)
        assert_eq(E.Balance(CID).available, 100 - EC.Commissary[1].price)
        assert_eq(#Given, 1)
        reconciled()
    end)
end)

describe('restitution', function()
    it('takes the share of each wage for the victim, keyed per order and numbered, and pf-justice records it', function()
        fund('corrections', 5000, 'b19e:fund:' .. seq)
        local victim = 'VIC' .. seq
        MySQL.insert.await([[INSERT INTO players (citizenid, license, name, money, job, position, metadata)
            VALUES (?, 'lic', 'Victim', '{"cash":0,"bank":0}', '{}', '{}', '{}')]], { victim })
        Mock.exportsByResource['pf-justice'].RecordRestitution = function(_, id, pay, opts)
            if id == 0 then return { ok = false, error = 'bad_args' } end
            return Justice.RecordRestitution(id, pay, opts)
        end
        JU.restitution = { { id = 900 + seq, kind = 'restitution', cid = CID, victimCid = victim, amount = 20, paidAmount = 0, state = 'issued' } }
        local share = math.floor(CW.Jobs.kitchen.wage * EC.RestitutionShare)
        W.Complete(inmate(INMATE), 'kitchen', {})
        local k1 = ('pf-justice:restitution:%d:1'):format(900 + seq)
        assert_eq(tx(k1).state, 'completed')
        assert_eq(tx(k1).to_account, ('player:%s:bank'):format(victim))
        assert_eq(tonumber(tx(k1).amount), share)
        assert_eq(jcalls('RecordRestitution')[1].args.pay.ledgerKey, k1)
        -- the second wage pays only what is still owed
        JU.record = false
        W.Complete(inmate(INMATE), 'kitchen', {})
        local k2 = ('pf-justice:restitution:%d:2'):format(900 + seq)
        assert_eq(tonumber(tx(k2).amount), 20 - share)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_prison_account_tx WHERE ref = ?", { ('rest:%d:due'):format(900 + seq) }), 1, 'unrecorded')
        JU.record = true
        assert_eq(E.RecordTick(), 1)
        assert_eq(JU.restitution[1].paidAmount, 20)
        W.Complete(inmate(INMATE), 'kitchen', {})
        assert_eq(tx(('pf-justice:restitution:%d:3'):format(900 + seq)), nil, 'nothing more is owed')
        local victimBank = MySQL.scalar.await("SELECT JSON_EXTRACT(money, '$.bank') FROM players WHERE citizenid = ?", { victim })
        assert_eq(tonumber(victimBank), 20)
        assert_eq(E.Balance(CID).available, 3 * CW.Jobs.kitchen.wage - 20)
        reconciled()
        Mock.exportsByResource['pf-justice'].RecordRestitution = function(_, orderId) if orderId == 0 then return { ok = false, error = 'bad_args' } end end
    end)
    it('without pf-justice\'s RecordRestitution no share is taken (it could be paid twice)', function()
        fund('corrections', 5000, 'b19e:fund:' .. seq)
        Mock.exportsByResource['pf-justice'].RecordRestitution = nil
        JU.restitution = { { id = 950 + seq, kind = 'restitution', cid = CID, victimCid = 'VICX', amount = 500, paidAmount = 0, state = 'issued' } }
        W.Complete(inmate(INMATE), 'kitchen', {})
        assert_eq(E.Balance(CID).available, CW.Jobs.kitchen.wage)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_prison_account_tx WHERE kind = 'restitution' AND citizenid = ?", { CID }), 0)
        Mock.exportsByResource['pf-justice'].RecordRestitution = function(_, orderId) if orderId == 0 then return { ok = false, error = 'bad_args' } end end
    end)
end)

describe('release', function()
    it('pays the trust out to the bank once the citizen has left, and never while held or escaped', function()
        fund('corrections', 5000, 'b19e:fund:' .. seq)
        W.Complete(inmate(INMATE), 'laundry', {})
        Mock.fireNet('pfm-prison:server:TrustDeposit', INMATE, 60)
        local bal = E.Balance(CID).available
        assert_eq(bal, CW.Jobs.laundry.wage + 60)
        E.PayoutTick(Mock.clock)
        assert_eq(E.Balance(CID).available, bal, 'held: nothing paid')
        PFPrison.Bridge.rows[CID].status = 'escaped'
        E.PayoutTick(Mock.clock)
        assert_eq(E.Balance(CID).available, bal, 'escaped: nothing paid')
        PFPrison.Bridge.rows[CID] = nil
        JU.open[CID] = { { id = ORDER, state = 'suspended' } }
        E.PayoutTick(Mock.clock)
        assert_eq(E.Balance(CID).available, bal, 'an open order: nothing paid')
        JU.open[CID] = {}
        local bank = Mock.players[INMATE].PlayerData.money.bank
        E.PayoutTick(Mock.clock)
        assert_eq(E.Balance(CID).available, 0)
        assert_eq(Mock.players[INMATE].PlayerData.money.bank, bank + bal)
        assert_eq(tx(('pfm-prison:trust:%s:r1'):format(CID)).state, 'completed')
        E.PayoutTick(Mock.clock + 1000)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_prison_account_tx WHERE citizenid = ? AND kind = 'release_payout'", { CID }), 1, 'paid once')
        reconciled()
    end)
end)

describe('reconciliation', function()
    it('every trust row of every inmate matches the ledger account', function()
        local r = reconciled()
        assert_true(r.rows > 0)
        -- a row the ledger never moved breaks it: the check would show it
        MySQL.insert.await("INSERT INTO pf_prison_account_tx (citizenid, kind, amount, ledger_key, ledger_state, ref, at) VALUES ('FAKE', 'adjustment', 5, NULL, 'completed', NULL, 1)")
        assert_false(E.Reconcile().ok)
        MySQL.update.await("DELETE FROM pf_prison_account_tx WHERE citizenid = 'FAKE'")
        reconciled()
    end)
end)
