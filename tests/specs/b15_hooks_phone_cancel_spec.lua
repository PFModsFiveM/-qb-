-- Batch 15H platform hooks, pfm-phone CancelInvoice(idOrRef, opts) (lead request): a server-only,
-- allowlisted export that withdraws an invoice which is not being paid, raises
-- pfm-phone:server:invoiceSettled(invoice, 'cancelled') once, never runs alongside a payment of the
-- same invoice (it takes the payer's invoice lock), and never cancels an invoice whose payer was
-- charged (that one is finished as paid). The real-DB side (ref lookups, the DELETE's pay_state
-- condition) is in tests/realdb_specs/b15_hooks_phone_ref_realdb_spec.lua.
load_resource('tests/lua/ledger_env.lua')

local invoices = {}   -- [id] = row
local onSelect        -- runs once inside the payer's invoice SELECT (a database yield in FiveM)

FakeDB.extraPatterns = {
    { 'INSERT INTO player_mails', function() return 1 end },
    { 'SELECT * FROM phone_invoices WHERE id = ? LIMIT 1', function(p)
        local row = invoices[tonumber(p[1])]
        return row and { row } or {}
    end },
    { 'SELECT * FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local hook = onSelect
        onSelect = nil
        if hook then hook() end
        local row = invoices[tonumber(p[1])]
        return (row and row.citizenid == p[2]) and { row } or {}
    end },
    { 'DELETE FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        if row and row.citizenid == p[2] then invoices[tonumber(p[1])] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
}

local FILES = { 'pfm-phone/config.lua', 'pfm-phone/server/main.lua' }
LedgerEnv.load('pfm-phone', FILES)
Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function() end }

local A = 1
local KEY1 = 'pfm-phone:invoice:7:bank'

local function cancel(resource, idOrRef, opts)
    Mock.invokingResource = resource
    local ok, res = pcall(Mock.selfExport('CancelInvoice'), idOrRef, opts)
    Mock.invokingResource = nil
    if not ok then error(res, 2) end
    return res
end
local function settled(outcome)
    local n = 0
    for _, e in ipairs(Mock.serverEvents) do
        if e.name == 'pfm-phone:server:invoiceSettled' and e.args[2] == outcome then n = n + 1 end
    end
    return n
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.load('pfm-phone', FILES)
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players = {}
    Mock.invokingResource = nil
    onSelect = nil
    local p = Mock.newPlayer(A)
    p.PlayerData.money = { cash = 0, bank = 1000 }
    FakeDB.society('police', 0)
    Config.BillingCommissions = {}
    invoices = { [7] = { id = 7, citizenid = 'CID1', amount = 500, society = 'police', sender = 'Officer', sendercitizenid = '', candecline = 0 } }
end

describe('CancelInvoice', function()
    it('is not a net event or callback a client could reach', function()
        assert_eq(Mock.netHandlers['pfm-phone:server:CancelInvoice'], nil)
        assert_eq(Mock.callbacks['qb-phone:server:CancelInvoice'], nil)
    end)
    it('refuses resources that are not on its caller list', function()
        local res = cancel('pfm-houserobbery', 7)
        assert_eq(res.ok, false)
        assert_eq(res.error, 'not_allowed')
        assert_true(invoices[7] ~= nil)
        for _, r in ipairs({ 'pf-justice', 'pf-government', 'pfm-policejob' }) do
            assert_true(cancel(r, 99).error == 'not_found', r .. ' is allowed')
        end
    end)
    it('cancels an open invoice (also one that cannot be declined) and reports it cancelled once', function()
        local res = cancel('pf-justice', 7, { reason = 'order vacated' })
        assert_true(res.ok)
        assert_eq(res.id, 7)
        assert_eq(invoices[7], nil)
        assert_eq(settled('cancelled'), 1)
        assert_eq(cancel('pf-justice', 7).error, 'not_found')
        assert_eq(settled('cancelled'), 1)
        assert_eq(Mock.players[A].PlayerData.money.bank, 1000)
    end)
    it('is busy while a payment of the same invoice runs, and the payment goes through', function()
        local during
        onSelect = function() during = cancel('pf-justice', 7) end
        assert_eq(Mock.selfExport('PayInvoice')(A, 7), true)
        assert_eq(during.error, 'busy')
        assert_eq(settled('cancelled'), 0)
        assert_eq(settled('paid'), 1)
        assert_eq(Mock.players[A].PlayerData.money.bank, 500)
    end)
    it('an invoice already charged is finished as paid, never cancelled', function()
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = KEY1, kind = 'purchase' }).ok, true)
        local res = cancel('pf-justice', 7)
        assert_eq(res.error, 'invalid_state')
        assert_eq(invoices[7], nil)
        assert_eq(settled('cancelled'), 0)
        assert_eq(settled('paid'), 1)
        assert_eq(FakeDB.bank_accounts['police'].account_balance, 500)
    end)
    it('a charge the ledger has not settled keeps the invoice (busy)', function()
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = KEY1, kind = 'purchase' }).ok, true)
        FakeDB.byKey[KEY1].state = 'debited'
        assert_eq(cancel('pf-justice', 7).error, 'busy')
        assert_true(invoices[7] ~= nil)
        assert_eq(settled('cancelled'), 0)
    end)
    it('validates its arguments; a ref needs the ref column (db_unavailable without it)', function()
        assert_eq(cancel('pf-justice', nil).error, 'bad_args')
        assert_eq(cancel('pf-justice', 0).error, 'bad_args')
        assert_eq(cancel('pf-justice', 'no spaces allowed').error, 'bad_args')
        assert_eq(cancel('pf-justice', 7, 'opts').error, 'bad_args')
        assert_eq(cancel('pf-justice', 7, { citizenid = 5 }).error, 'bad_args')
        assert_eq(cancel('pf-justice', 7, { citizenid = 'CID2' }).error, 'not_found')
        assert_eq(cancel('pf-justice', 'pf-justice:order:7').error, 'db_unavailable')
        assert_true(invoices[7] ~= nil)
    end)
end)
