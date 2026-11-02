-- pfm-policejob fines and bills on the ledger (batch 14: X-7, 13B-POLICE).
--   * /fine is a stored record first; the charge is one ledger transfer from the player straight to
--     the department (no money parked in system:pfm-policejob, no second unchecked credit);
--   * a charge the bank has not settled sends no invoice; the sweep asks again under the same key
--     and finishes the record when the ledger settles it (never a new key for an unclear charge);
--   * the bank not running: recorded, charged once by the sweep when it is back;
--   * a clear refusal becomes a phone invoice; when the phone cannot take it, the sweep charges again
--     later under the next numbered key (a failed key is never reused);
--   * the bill menu moves the money in one step too and tells the officer about an unclear charge.
load_resource('tests/lua/ledger_env.lua')
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCore = QBCoreMock
Mock.exportsByResource['pfm-inventory'] = { AddItem = function() return true end, RemoveItem = function() return true end, OpenInventoryById = function() end }
local phoneInvoices, phoneAnswer = {}, 41
Mock.exportsByResource['pfm-phone'] = {
    CreateInvoice = function(_, data) phoneInvoices[#phoneInvoices + 1] = data if phoneAnswer then return phoneAnswer end return nil, 'db_error' end,
}
-- pfm_police_fines on the fake database (the real-DB spec runs the real SQL)
FineRows = {}
FakeDB.extraPatterns = {
    { 'INSERT INTO pfm_police_fines', function(p)
        local id = #FineRows + 1
        FineRows[id] = { id = id, citizenid = p[1], society = p[2], amount = p[3], officer_citizenid = p[4], officer_name = p[5],
            reason = p[6], state = 'charging', attempt = 1, checks = 0, next_at = p[7] }
        return id
    end },
    { 'UPDATE pfm_police_fines SET state = ?, paid_from', function(p)
        local row = FineRows[p[7]]
        if not row or row.state ~= p[8] or row.attempt ~= p[9] then return { affectedRows = 0 } end
        row.state, row.paid_from, row.invoice_id, row.last_error, row.next_at = p[1], p[2], p[3], p[4], p[5]
        row.checks = row.checks + p[6]
        return { affectedRows = 1 }
    end },
    { "UPDATE pfm_police_fines SET state = 'charging', attempt = attempt + 1", function(p)
        local row = FineRows[p[2]]
        if not row or row.state ~= 'retry' or row.attempt ~= p[3] then return { affectedRows = 0 } end
        row.state, row.attempt, row.next_at = 'charging', row.attempt + 1, p[1]
        return { affectedRows = 1 }
    end },
    { 'FROM pfm_police_fines WHERE state IN', function(p)
        local out = {}
        for _, row in ipairs(FineRows) do
            if (row.state == 'charging' or row.state == 'pending' or row.state == 'retry') and row.next_at <= p[1] then
                local copy = {}
                for k, v in pairs(row) do copy[k] = v end
                out[#out + 1] = copy
            end
        end
        return out
    end },
}

LedgerEnv.load('pfm-policejob', { 'pfm-policejob/config.lua', 'pfm-policejob/server/main.lua', 'pfm-policejob/server/fines.lua', 'pfm-policejob/server/commands.lua', 'pfm-policejob/server/interactions.lua' })

local COP, SUSPECT = 1, 2
local function money(src) return Mock.players[src].PlayerData.money end
local function police() return FakeDB.bank_accounts.police.account_balance end
local function told(src, fragment)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
        if e.target == src and tostring(e.args[1]):find(fragment, 1, true) then return true end
    end
    return false
end
local function txByKeyPrefix(prefix)
    local out = {}
    for _, tx in ipairs(FakeDB.transactions) do
        if tostring(tx.idempotency_key):sub(1, #prefix) == prefix then out[#out + 1] = tx end
    end
    return out
end
local function sweepLater(seconds)
    Mock.clock = Mock.clock + (seconds or 3600)
    return PFPoliceFines.Sweep()
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    phoneInvoices, phoneAnswer, FineRows = {}, 41, {}
    FakeDB.society('police', 0)
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.newPlayer(SUSPECT, 'SUSPECTCID').PlayerData.money = { cash = 300, bank = 1000 }
end

describe('/fine as a stored record (X-7, 13B)', function()
    it('moves the money from the player to the department in one ledger transfer', function()
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(money(SUSPECT).bank, 600)
        assert_eq(police(), 400)
        assert_eq(FineRows[1].state, 'paid')
        assert_eq(FineRows[1].paid_from, 'bank')
        local txs = txByKeyPrefix('pfm-policejob:fine:1:a1')
        assert_eq(#txs, 1)
        assert_eq(txs[1].from_account, 'player:SUSPECTCID:bank')
        assert_eq(txs[1].to_account, 'society:police')
        -- nothing parked in this resource's account, no second credit step
        for _, tx in ipairs(FakeDB.transactions) do assert_true(tx.to_account ~= 'system:pfm-policejob', 'no money in system:pfm-policejob') end
        assert_eq(#txByKeyPrefix('pfm-policejob:fine:1:a1:society'), 0)
    end)
    it('an unclear charge sends no invoice; the sweep finishes it under the same key once the ledger settles', function()
        FakeDB.failNext.creditSociety = true                 -- taken from the player, the credit broke off
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(FineRows[1].state, 'pending')
        assert_eq(#phoneInvoices, 0)
        assert_true(told(COP, 'still processing'))
        assert_eq(money(SUSPECT).bank, 600)
        assert_eq(sweepLater(10), 0)                         -- not due yet
        Mock.clock = Mock.clock + 120
        PFLedger.Recover()                                   -- the ledger's recovery settles it
        sweepLater(200)
        assert_eq(FineRows[1].state, 'paid')
        assert_eq(money(SUSPECT).bank, 600)
        assert_eq(police(), 400)
        assert_eq(#txByKeyPrefix('pfm-policejob:fine:1:a2'), 0, 'never a new key for an unclear charge')
        assert_eq(#phoneInvoices, 0)
    end)
    it('a charge left unverified by a crash is never charged again nor invoiced', function()
        FakeDB.failNext.setState = true                      -- debited in memory, the state write broke
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(FineRows[1].state, 'pending')
        Mock.clock = Mock.clock + 120
        PFLedger.Recover()                                   -- marks it interrupted_unverified
        for _ = 1, 4 do sweepLater() end
        assert_eq(FineRows[1].state, 'pending')
        assert_eq(FineRows[1].attempt, 1)
        assert_eq(#phoneInvoices, 0)
        assert_eq(money(SUSPECT).bank, 600)                  -- taken once, not again
        assert_eq(money(SUSPECT).cash, 300)
    end)
    it('with the bank down it is recorded and charged once when the bank is back', function()
        local realState = GetResourceState
        GetResourceState = function(name) if name == 'pfm-banking' then return 'stopped' end return 'started' end
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(FineRows[1].state, 'pending')
        assert_true(told(COP, 'not responding'))
        assert_eq(#phoneInvoices, 0)
        sweepLater()
        assert_eq(FineRows[1].state, 'pending')             -- still down: still waiting
        GetResourceState = realState
        sweepLater()
        sweepLater()
        assert_eq(FineRows[1].state, 'paid')
        assert_eq(money(SUSPECT).bank, 600)
        assert_eq(police(), 400)
    end)
    it('a fine they cannot pay becomes a phone invoice made by pfm-phone', function()
        Mock.players[SUSPECT].PlayerData.money = { cash = 10, bank = 10 }
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(FineRows[1].state, 'invoiced')
        assert_eq(FineRows[1].invoice_id, 41)
        assert_eq(#phoneInvoices, 1)
        assert_eq(phoneInvoices[1].society, 'police')
        assert_eq(police(), 0)
        sweepLater()
        assert_eq(#phoneInvoices, 1)                         -- final: not invoiced twice
    end)
    it('when the phone cannot take the invoice, the sweep charges again under the next numbered key', function()
        Mock.players[SUSPECT].PlayerData.money = { cash = 10, bank = 10 }
        phoneAnswer = nil
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(FineRows[1].state, 'retry')
        assert_true(told(COP, 'could not be sent as an invoice'))
        Mock.players[SUSPECT].PlayerData.money = { cash = 10, bank = 900 }  -- paid in later
        sweepLater()
        assert_eq(FineRows[1].state, 'paid')
        assert_eq(FineRows[1].attempt, 2)
        assert_eq(#txByKeyPrefix('pfm-policejob:fine:1:a2:bank'), 1)
        assert_eq(money(SUSPECT).bank, 500)
        assert_eq(police(), 400)
    end)
    it('a record that could not be written charges nothing', function()
        local patterns = FakeDB.extraPatterns
        FakeDB.extraPatterns = { { 'INSERT INTO pfm_police_fines', function() error('db down') end } }
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        FakeDB.extraPatterns = patterns
        assert_eq(money(SUSPECT).bank, 1000)
        assert_true(told(COP, 'could not be recorded'))
    end)
end)

describe('the bill menu (13B: unclear charges)', function()
    it('credits the department in one transfer and only when paid', function()
        Mock.fireNet('police:server:BillPlayer', COP, SUSPECT, 40)
        assert_eq(police(), 40)
        assert_eq(money(SUSPECT).bank, 960)
        for _, tx in ipairs(FakeDB.transactions) do assert_true(tx.to_account ~= 'system:pfm-policejob') end
    end)
    it('an unclear charge tells the officer not to bill again', function()
        FakeDB.failNext.setState = true
        Mock.fireNet('police:server:BillPlayer', COP, SUSPECT, 40)
        assert_true(told(COP, 'still processing'))
        assert_false(told(COP, 'cannot pay'))
    end)
end)
