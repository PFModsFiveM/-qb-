-- Batch 14, pf-government bills on a real database with the real pfm-banking ledger:
--   G2  bill:create is server-only, and its target, amount, type, text and due date are the server's;
--   X6  a fine is collected at once only in person (server positions); a remote fine is an unpaid bill;
--       the client's due date is ignored; officials are limited per hour and per citizen per day;
--       waiving a collected fine refunds it through the ledger (from the treasury, once) and books it
--       once, also when the refund came back unclear and a later waiver finds it completed;
--   X7  a bill payment the bank cannot settle at once is "being processed", never "no money", is
--       never charged again under a new key, and is credited once the ledger completes it; a refund
--       the ledger refused moves to a new numbered key, an unclear one keeps its key.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
GetInvokingResource = GetInvokingResource or function() return nil end
local states = { ['pfm-cityhall'] = 'missing', ['pfm-phone'] = 'missing', ['pf-services'] = 'missing', ['pfm-houses'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4

-- the bank
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
local bankX = Mock.exportsByResource['__self']
Mock.exportsByResource['pfm-banking'] = bankX
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end, RegisterAppHandlers = function() return true end,
    Push = function() return true end, PushToJob = function() return 0 end, PushToCitizen = function() return true end,
}
local mails = {}
Mock.exportsByResource['pf-citizen'] = { SendMail = function(_, cid, m) mails[#mails + 1] = { cid = cid, mail = m } return 1 end }

-- pf-government
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government' } }
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/schema.lua', 'server/treasury.lua', 'server/taxes.lua',
    'server/utilities.lua', 'server/bills.lua', 'server/businesses.lua', 'server/audit.lua', 'server/licenses.lua',
    'server/staff.lua', 'server/callbacks.lua', 'server/main.lua', 'server/apps/common.lua', 'server/apps/fines.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
function DebugPrint() end
local govX = Mock.exportsByResource['__self']
Mock.exportsByResource['pf-government'] = govX
Mock.exportsByResource['__self'] = nil
assert(GovSchema.Ensure(), 'government migrations')
InitializeTreasury()

local CLERK, CIV, FAR, UTIL = 1, 2, 3, 4
local HALL = vector3(240.0, -1000.0, 29.0)
local function num(v) return tonumber(v) or 0 end
local function bill(id) return MySQL.single.await('SELECT * FROM pf_gov_bills WHERE id = ?', { id }) end
local function nui(src, action, data)
    local before = #Mock.clientEvents
    Mock.fireNet('pf-government:server:nuiCallback', src, 'cb1', action, data or {})
    for i = #Mock.clientEvents, before + 1, -1 do
        local e = Mock.clientEvents[i]
        if e.name == 'pf-government:client:nuiCallback' then return e.args[2] end
    end
end
local function treasury() return num(MySQL.scalar.await("SELECT account_balance FROM bank_accounts WHERE account_name = 'government'")) end
local function txCount(prefix)
    return num(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ?", { prefix .. '%' }))
end
local function offlineCitizen(cid, bank)
    MySQL.insert.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata)
        VALUES (?, 1, ?, 'x', ?, '{"firstname":"Off","lastname":"Line"}', '{}', '{}', '{}', '{}')]],
        { cid, 'license:' .. cid, json.encode({ bank = bank, cash = 0 }) })
end
local function offlineBank(cid)
    local m = json.decode(MySQL.scalar.await('SELECT money FROM players WHERE citizenid = ?', { cid }) or '{}') or {}
    return num(m.bank)
end

local seq = 0
BeforeEach = function()
    Mock.reset()
    mails = {}
    seq = seq + 1
    Mock.players, Mock.coords = {}, {}
    local clerk = Mock.newPlayer(CLERK, 'CLK' .. seq)
    clerk.PlayerData.job = { name = 'government', grade = { level = 1 }, onduty = true }
    local util = Mock.newPlayer(UTIL, 'UTL' .. seq)
    util.PlayerData.job = { name = 'government', grade = { level = 0 }, onduty = true }
    local civ = Mock.newPlayer(CIV, 'CIV' .. seq)
    civ.PlayerData.money = { cash = 100, bank = 5000 }
    local far = Mock.newPlayer(FAR, 'FAR' .. seq)
    far.PlayerData.money = { cash = 0, bank = 5000 }
    Mock.coords = { [CLERK] = HALL, [UTIL] = HALL, [CIV] = HALL + vector3(2.0, 0.0, 0.0), [FAR] = HALL + vector3(300.0, 0.0, 0.0) }
    Config.Bills.FinesPerHour, Config.Bills.FinesPerTargetPerDay = 10, 3
end

describe('G2: manual bills', function()
    it('a client cannot reach bill:create, whatever its role', function()
        local res = nui(CLERK, 'bill:create', { targetType = 'citizen', targetId = 'CIV' .. seq, amount = 1, billType = 'utility', dueDate = '2000-01-01 00:00:00', description = 'x' })
        assert_eq(res.error, 'unknown_callback')
        assert_eq(num(MySQL.scalar.await("SELECT COUNT(*) FROM pf_gov_bills WHERE target_id = ?", { 'CIV' .. seq })), 0)
    end)
    it('on the server: a real target, a whole capped amount, a manual type, a reason and the server due date', function()
        MySQL.insert.await("INSERT INTO pf_gov_businesses (business_id, business_name, business_type, owner_id, owner_name) VALUES ('shop:one', 'Shop One', 'store', 'X', 'X')")
        local function create(d) return GovApps.CallNui('bill:create', CLERK, d) end
        local good = { targetType = 'business', targetId = 'shop:one', amount = 500, billType = 'fine', description = 'Blocking the road', dueDate = '2000-01-01 00:00:00' }
        local function with(k, v) local d = {} for a, b in pairs(good) do d[a] = b end d[k] = v return d end
        assert_eq(create(with('targetType', 'property')).error, 'invalid_target')
        assert_eq(create(with('targetId', 'shop:none')).error, 'target_not_found')
        assert_eq(create({ targetType = 'citizen', targetId = 'NOBODY1', amount = 5, billType = 'fine', description = 'x' }).error, 'target_not_found')
        for _, amount in ipairs({ 0, -5, 1.5, 0 / 0, 1e12, 50001, 'x' }) do assert_eq(create(with('amount', amount)).error, 'invalid_amount', tostring(amount)) end
        assert_eq(create(with('billType', 'utility')).error, 'invalid_type')
        assert_eq(create(with('billType', nil)).error, 'invalid_type')
        assert_eq(create(with('description', '   ')).error, 'description_required')
        assert_eq(GovApps.CallNui('bill:create', UTIL, good).error, 'no_permission')
        local res = create(good)
        assert_true(res.ok, tostring(res.error))
        local b = bill(res.billId)
        assert_eq(b.bill_type, 'fine')
        assert_eq(num(b.amount), 500)
        -- due in Config.Bills.DueDays, not the year 2000 the client sent (which made it delinquent within the hour)
        local due = num(MySQL.scalar.await('SELECT UNIX_TIMESTAMP(due_date) FROM pf_gov_bills WHERE id = ?', { res.billId }))
        assert_true(math.abs(due - (os.time() + 7 * 86400)) < 120, 'server due date: ' .. tostring(due - os.time()))
        assert_eq(ProcessBillEscalation(), 0, 'nothing escalates')
    end)
end)

describe('X6: fines', function()
    it('in person: collected at once through the ledger; the due date the client sends is ignored', function()
        local res = nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'CIV' .. seq, amount = 300, description = 'Littering', dueDate = '2000-01-01 00:00:00' })
        assert_true(res.ok, tostring(res.error))
        assert_true(res.result.inPerson)
        assert_eq(res.result.collected, 300)
        assert_eq(Mock.players[CIV].PlayerData.money.bank, 4700)
        local b = bill(res.result.billId)
        assert_eq(b.status, 'paid')
        assert_eq(txCount('pf-government:fine:' .. res.result.billId .. ':bank'), 1)
        local due = num(MySQL.scalar.await('SELECT UNIX_TIMESTAMP(due_date) FROM pf_gov_bills WHERE id = ?', { b.id }))
        assert_true(due > os.time(), 'server due date')
    end)
    it('remote (online but far, or offline): an unpaid bill, nothing taken, the citizen is told', function()
        local res = nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'FAR' .. seq, amount = 400, description = 'Remote' })
        assert_true(res.ok, tostring(res.error))
        assert_false(res.result.inPerson)
        assert_eq(res.result.collected, 0)
        assert_eq(Mock.players[FAR].PlayerData.money.bank, 5000, 'no money taken from afar')
        assert_eq(bill(res.result.billId).status, 'unpaid')
        assert_eq(#mails, 1, 'a letter in the mail')
        offlineCitizen('OFF' .. seq, 9000)
        res = nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'OFF' .. seq, amount = 50000, description = 'Offline' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.result.status, 'unpaid')
        assert_eq(offlineBank('OFF' .. seq), 9000, 'an offline citizen keeps their money')
        assert_eq(txCount('pf-government:fine:' .. res.result.billId), 0)
        assert_eq(nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'NOPE' .. seq, amount = 10 }).error, 'target_not_found')
    end)
    it('the computer fines through IssueFineAs, with the same rules', function()
        local ok, res = govX.IssueFineAs(CLERK, { targetCitizenId = 'FAR' .. seq, amount = 100, description = 'From the computer', dueDate = '2000-01-01' })
        assert_true(ok, tostring(res))
        assert_eq(res.status, 'unpaid')
        assert_eq(Mock.players[FAR].PlayerData.money.bank, 5000)
        ok, res = govX.IssueFineAs(UTIL, { targetCitizenId = 'FAR' .. seq, amount = 100 })
        assert_false(ok)
        assert_eq(res, 'no_permission')
    end)
    it('per official per hour and per citizen per day', function()
        Config.Bills.FinesPerHour, Config.Bills.FinesPerTargetPerDay = 3, 2
        assert_true(nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'FAR' .. seq, amount = 10 }).ok)
        assert_true(nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'FAR' .. seq, amount = 10 }).ok)
        assert_eq(nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'FAR' .. seq, amount = 10 }).error, 'target_limit')
        assert_true(nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'CIV' .. seq, amount = 10 }).ok)
        assert_eq(nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'CIV' .. seq, amount = 10 }).error, 'rate_limited')
        assert_eq(num(MySQL.scalar.await('SELECT COUNT(*) FROM pf_gov_bills WHERE issued_by = ?', { 'CLK' .. seq })), 3)
    end)
    it('waiving a collected fine refunds it once, from the treasury, through the ledger', function()
        local res = nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'CIV' .. seq, amount = 800, description = 'By mistake' })
        assert_true(res.ok)
        local id = res.result.billId
        assert_eq(Mock.players[CIV].PlayerData.money.bank, 4200)
        local before = treasury()
        local w = nui(CLERK, 'bill:waive', { billId = id, reason = 'Issued in error' })
        assert_true(w.ok, tostring(w.message))
        assert_eq(w.refunded, 800)
        assert_eq(Mock.players[CIV].PlayerData.money.bank, 5000, 'the citizen has the money back')
        assert_eq(treasury(), before - 800, 'out of the treasury it went into')
        assert_eq(bill(id).status, 'waived')
        assert_eq(txCount(('pf-government:fine:%d:waive'):format(id)), 1)
        assert_false(nui(CLERK, 'bill:waive', { billId = id, reason = 'again' }).ok, 'waived once')
        assert_eq(Mock.players[CIV].PlayerData.money.bank, 5000)
        -- an unpaid fine is waived without any money moving
        local remote = nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'FAR' .. seq, amount = 50 })
        w = nui(CLERK, 'bill:waive', { billId = remote.result.billId, reason = 'x' })
        assert_true(w.ok)
        assert_eq(w.refunded, nil)
        assert_eq(txCount(('pf-government:fine:%d:waive'):format(remote.result.billId)), 0)
    end)
    it('treasury mirror mode: a refund that came back unclear and later completes is booked once', function()
        local mirrorBefore
        local saved = Config.Treasury.UseSocietyAccount
        Config.Treasury.UseSocietyAccount = false
        local ok, err = pcall(function()
            local res = nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'CIV' .. seq, amount = 600 })
            assert_true(res.ok, tostring(res.error))
            local id = res.result.billId
            assert_eq(Mock.players[CIV].PlayerData.money.bank, 4400)
            mirrorBefore = GetTreasuryBalance()
            -- the refund moves, its answer is lost
            local real = bankX.Transfer
            bankX.Transfer = function(_, opts)
                bankX.Transfer = real
                local r = real(opts)
                MySQL.update.await("UPDATE pf_transactions SET state = 'debited' WHERE idempotency_key = ?", { opts.key })
                return { ok = false, state = 'debited', error = 'debited', txId = r.txId }
            end
            local w = nui(CLERK, 'bill:waive', { billId = id, reason = 'Issued in error' })
            assert_eq(w.error, 'refund_pending')
            assert_eq(GetTreasuryBalance(), mirrorBefore, 'nothing booked while unclear')
            -- the ledger completes it; the official waives again
            MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key = ?", { ('pf-government:fine:%d:waive:1'):format(id) })
            w = nui(CLERK, 'bill:waive', { billId = id, reason = 'Issued in error' })
            assert_true(w.ok, tostring(w.error))
            assert_eq(bill(id).status, 'waived')
            assert_eq(Mock.players[CIV].PlayerData.money.bank, 5000, 'refunded once')
            assert_eq(GetTreasuryBalance(), mirrorBefore - 600, 'the mirror follows the completed refund')
            assert_eq(num(MySQL.scalar.await("SELECT COUNT(*) FROM pf_gov_transactions WHERE source_type = 'fine_refund' AND source_id = ?", { tostring(id) })), 1)
            assert_eq(num(MySQL.scalar.await("SELECT COUNT(*) FROM pf_gov_audit_log WHERE action_type = 'bill_refund' AND target_id = ?", { tostring(id) })), 1)
            assert_false(nui(CLERK, 'bill:waive', { billId = id, reason = 'again' }).ok)
            assert_eq(GetTreasuryBalance(), mirrorBefore - 600, 'booked once')
            assert_eq(txCount(('pf-government:fine:%d:waive'):format(id)), 1)
        end)
        Config.Treasury.UseSocietyAccount = saved
        if not ok then error(err, 0) end
    end)
    it('a waiver whose bill update missed after the refund is booked once when retried', function()
        local res = nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'CIV' .. seq, amount = 300 })
        local id = res.result.billId
        -- the refund goes through; the bill changes just before the waive is written
        local real = bankX.Transfer
        bankX.Transfer = function(_, opts)
            bankX.Transfer = real
            local r = real(opts)
            MySQL.update.await('UPDATE pf_gov_bills SET amount_paid = amount_paid + 0.5 WHERE id = ?', { id })
            return r
        end
        assert_eq(nui(CLERK, 'bill:waive', { billId = id, reason = 'x' }).error, 'changed')
        MySQL.update.await('UPDATE pf_gov_bills SET amount_paid = amount_paid - 0.5 WHERE id = ?', { id })
        assert_true(nui(CLERK, 'bill:waive', { billId = id, reason = 'x' }).ok)
        assert_eq(Mock.players[CIV].PlayerData.money.bank, 5000)
        assert_eq(num(MySQL.scalar.await("SELECT COUNT(*) FROM pf_gov_transactions WHERE source_type = 'fine_refund' AND source_id = ?", { tostring(id) })), 1, 'one booking')
        assert_eq(num(MySQL.scalar.await("SELECT COUNT(*) FROM pf_gov_audit_log WHERE action_type = 'bill_refund' AND target_id = ?", { tostring(id) })), 1)
    end)
    it('a refund the treasury cannot cover leaves the fine as it was, and a later waiver tries again', function()
        local res = nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'CIV' .. seq, amount = 600 })
        local id = res.result.billId
        local saved = treasury()
        MySQL.update.await("UPDATE bank_accounts SET account_balance = 100 WHERE account_name = 'government'")
        local w = nui(CLERK, 'bill:waive', { billId = id, reason = 'x' })
        assert_false(w.ok)
        assert_eq(w.error, 'refund_failed')
        assert_eq(bill(id).status, 'paid')
        MySQL.update.await("UPDATE bank_accounts SET account_balance = ? WHERE account_name = 'government'", { saved })
        w = nui(CLERK, 'bill:waive', { billId = id, reason = 'x' })
        assert_true(w.ok, tostring(w.error))
        assert_eq(Mock.players[CIV].PlayerData.money.bank, 5000)
        assert_eq(num(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key = ? AND state = 'completed'", { ('pf-government:fine:%d:waive:2'):format(id) })), 1, 'a fresh key after the refused try')
    end)
end)

describe('X7: bill payments the bank settles late', function()
    local function remoteFine(amount)
        local res = nui(CLERK, 'fine:issueImmediate', { targetCitizenId = 'FAR' .. seq, amount = amount })
        assert_true(res.ok)
        return res.result.billId
    end
    -- the bank moves the money, then the answer is lost: the transfer is left 'debited' and the
    -- caller gets an unclear result (as after a crash between the debit and the credit)
    local function unclearOnce()
        local real = bankX.Transfer
        bankX.Transfer = function(_, opts)   -- (a hand-written export: called with self)
            bankX.Transfer = real
            local res = real(opts)
            MySQL.update.await("UPDATE pf_transactions SET state = 'debited' WHERE idempotency_key = ?", { opts.key })
            return { ok = false, state = 'debited', error = 'debited', txId = res.txId }
        end
    end
    it('is "being processed", not "no money"; no second charge; credited once the ledger completes it', function()
        local id = remoteFine(1000)
        unclearOnce()
        local ok, msg, _, code = govX.PayBillFromPlayer(FAR, id, 1000)
        assert_false(ok)
        assert_eq(code, 'payment_pending', tostring(msg))
        assert_eq(Mock.players[FAR].PlayerData.money.bank, 4000, 'the money left once')
        assert_eq(bill(id).status, 'unpaid')
        -- the player tries again: refused, nothing more charged
        ok, msg, _, code = govX.PayBillFromPlayer(FAR, id, 1000)
        assert_eq(code, 'payment_pending')
        assert_eq(Mock.players[FAR].PlayerData.money.bank, 4000)
        assert_eq(txCount('pf-government:billpay:' .. id .. ':'), 1, 'one charge')
        -- the ledger's recovery finishes the transfer; the reconcile loop credits the bill
        MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key LIKE ?", { 'pf-government:billpay:' .. id .. ':%' })
        MySQL.update.await("UPDATE pf_gov_bill_payments SET created_at = NOW() - INTERVAL 5 MINUTE WHERE bill_id = ?", { id })
        local before = treasury()
        ReconcileBillPayments()
        assert_eq(bill(id).status, 'paid')
        assert_eq(num(bill(id).amount_paid), 1000)
        assert_eq(treasury(), before + 1000, 'deposited')
        ReconcileBillPayments()
        assert_eq(treasury(), before + 1000, 'once')
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_gov_bill_payments WHERE bill_id = ?', { id }), 'applied')
        ok = govX.PayBillFromPlayer(FAR, id, 1000)
        assert_false(ok, 'paid')
        assert_eq(Mock.players[FAR].PlayerData.money.bank, 4000, 'never paid twice')
    end)
    it('a charge the ledger refused is dropped and the next payment gets a fresh key', function()
        local id = remoteFine(700)
        Mock.players[FAR].PlayerData.money.bank = 100
        local ok, _, _, code = govX.PayBillFromPlayer(FAR, id, 700)
        assert_false(ok)
        assert_eq(code, 'insufficient_funds')
        Mock.players[FAR].PlayerData.money.bank = 1000
        ok = govX.PayBillFromPlayer(FAR, id, 700)
        assert_true(ok)
        assert_eq(bill(id).status, 'paid')
        assert_eq(Mock.players[FAR].PlayerData.money.bank, 300)
        assert_eq(num(MySQL.scalar.await("SELECT COUNT(*) FROM pf_gov_bill_payments WHERE bill_id = ? AND state = 'failed'", { id })), 1)
    end)
    it('a late charge for a bill paid meanwhile goes back to the payer', function()
        local id = remoteFine(500)
        unclearOnce()
        govX.PayBillFromPlayer(FAR, id, 500)
        -- the citizen's business partner pays it in full meanwhile
        local civ = Mock.players[CIV]
        assert_true((govX.PayBillFromPlayer(CIV, id, 500)))
        assert_eq(civ.PlayerData.money.bank, 4500)
        MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key LIKE ?", { 'pf-government:billpay:' .. id .. ':%' })
        MySQL.update.await("UPDATE pf_gov_bill_payments SET created_at = NOW() - INTERVAL 5 MINUTE WHERE bill_id = ?", { id })
        ReconcileBillPayments()
        assert_eq(Mock.players[FAR].PlayerData.money.bank, 5000, 'refunded in full')
        assert_eq(num(bill(id).amount_paid), 500)
    end)
    it('a refund of a late charge the ledger refused moves to the next numbered key', function()
        local id = remoteFine(500)
        unclearOnce()
        govX.PayBillFromPlayer(FAR, id, 500)
        assert_true((govX.PayBillFromPlayer(CIV, id, 500)))
        local payKey = MySQL.scalar.await('SELECT pay_key FROM pf_gov_bill_payments WHERE bill_id = ? AND citizenid = ?', { id, 'FAR' .. seq })
        MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key LIKE ?", { 'pf-government:billpay:' .. id .. ':%' })
        MySQL.update.await("UPDATE pf_gov_bill_payments SET created_at = NOW() - INTERVAL 5 MINUTE WHERE bill_id = ?", { id })
        -- the first refund key was refused by the ledger (it stays failed)
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state, error)
            VALUES (?, ?, 'refund', 'system:pf-government-fines', ?, 500, 'failed', 'insufficient_funds')]],
            { 'govrefundfail' .. seq, payKey .. ':refund', ('player:%s:bank'):format('FAR' .. seq) })
        ReconcileBillPayments()
        assert_eq(Mock.players[FAR].PlayerData.money.bank, 5000, 'refunded under a fresh key')
        assert_eq(num(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key = ? AND state = 'completed'", { payKey .. ':refund:2' })), 1)
        assert_eq(num(MySQL.scalar.await('SELECT refunded FROM pf_gov_bill_payments WHERE pay_key = ?', { payKey })), 500)
        ReconcileBillPayments()
        assert_eq(Mock.players[FAR].PlayerData.money.bank, 5000, 'once')
    end)
    it('an unclear refund of a late charge keeps its key until the ledger settles it', function()
        local id = remoteFine(400)
        unclearOnce()
        govX.PayBillFromPlayer(FAR, id, 400)
        assert_true((govX.PayBillFromPlayer(CIV, id, 400)))
        local payKey = MySQL.scalar.await('SELECT pay_key FROM pf_gov_bill_payments WHERE bill_id = ? AND citizenid = ?', { id, 'FAR' .. seq })
        MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key LIKE ?", { 'pf-government:billpay:' .. id .. ':%' })
        MySQL.update.await("UPDATE pf_gov_bill_payments SET created_at = NOW() - INTERVAL 5 MINUTE WHERE bill_id = ?", { id })
        unclearOnce()                                    -- the refund moves, its answer is lost
        ReconcileBillPayments()
        ReconcileBillPayments()
        assert_eq(txCount(payKey .. ':refund'), 1, 'no second refund while unclear')
        assert_eq(MySQL.scalar.await('SELECT refunded FROM pf_gov_bill_payments WHERE pay_key = ?', { payKey }), nil)
        MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key = ?", { payKey .. ':refund' })
        ReconcileBillPayments()
        assert_eq(num(MySQL.scalar.await('SELECT refunded FROM pf_gov_bill_payments WHERE pay_key = ?', { payKey })), 400)
        assert_eq(Mock.players[FAR].PlayerData.money.bank, 5000)
    end)
    it('has its table (migration 4, safe to run again)', function()
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-government' AND version = 4")
        GovSchema.__reset()
        assert_true(GovSchema.Ensure(), 'rerun')
        assert_eq(num(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-government' AND version = 4")), 1)
    end)
end)
