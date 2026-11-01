-- pfm-phone invoice ledger keys come from a per-invoice token, not from the invoice id: an invoice
-- under a reused id (truncated table, MySQL < 8.0 AUTO_INCREMENT reset) is charged, rows from before
-- the token keep their id key, and every new invoice gets its own token (the column and its UUID()
-- default are added once). Paying is exactly once across crashes: a pending or debited attempt is
-- never charged again, a failed or refunded one moves to the next attempt key without any cap, and
-- the business is paid before the row is deleted.
load_resource('tests/lua/ledger_env.lua')

local invoices = {}       -- [id] = row
local inserts = {}        -- { params, query } of every INSERT INTO phone_invoices
local hasColumn = true    -- phone_invoices.ledger_token exists
local uuidDefault = true  -- ... with DEFAULT (UUID())
local alters, defaultAlters, columnReads = 0, 0, 0
local nextId = 1
local uuids = 0
local onTx               -- runs once inside the next ledger key lookup (a database yield in FiveM)

local function addColumn()
    if hasColumn then error("Duplicate column name 'ledger_token'") end
    alters = alters + 1
    hasColumn = true
    return {}
end
local function setDefault()
    defaultAlters = defaultAlters + 1
    uuidDefault = true
    return {}
end
local ADD_COLUMN = 'ALTER TABLE `phone_invoices` ADD COLUMN `ledger_token`'
local SET_DEFAULT = 'ALTER TABLE `phone_invoices` ALTER COLUMN `ledger_token` SET DEFAULT (UUID())'

FakeDB.extraPatterns = {
    { 'INSERT INTO player_mails', function() return 1 end },
    { 'information_schema.COLUMNS', function()
        columnReads = columnReads + 1
        return { { n = hasColumn and 1 or 0, def = hasColumn and (uuidDefault and 'uuid()' or 'NULL') or nil } }
    end },
    { ADD_COLUMN, function() return addColumn() end },
    { SET_DEFAULT, function() return setDefault() end },
    { 'INSERT INTO phone_invoices', function(p, q)
        inserts[#inserts + 1] = p
        local id = nextId
        nextId = nextId + 1
        local token = p[8]
        if token == nil and hasColumn and uuidDefault then
            uuids = uuids + 1
            token = ('00000000-0000-0000-0000-%012d'):format(uuids) -- what the UUID() default stores
        end
        invoices[id] = { id = id, citizenid = p[1], amount = p[2], society = p[3], sender = p[4], sendercitizenid = p[5],
            candecline = p[6] or 1, reason = p[7], ledger_token = token }
        return id
    end },
    { 'SELECT * FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        return (row and row.citizenid == p[2]) and { row } or {}
    end },
    { 'DELETE FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        if row and row.citizenid == p[2] then invoices[tonumber(p[1])] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
    { 'SELECT amount, society FROM phone_invoices WHERE id = ? and citizenid = ? and candecline = ?', function(p)
        local row = invoices[tonumber(p[1])]
        return (row and row.citizenid == p[2] and row.candecline == p[3]) and { { amount = row.amount, society = row.society } } or {}
    end },
    { 'DELETE FROM phone_invoices WHERE id = ? and citizenid = ? and candecline = ?', function(p)
        local row = invoices[tonumber(p[1])]
        if row and row.citizenid == p[2] and row.candecline == p[3] then invoices[tonumber(p[1])] = nil return 1 end
        return 0
    end },
}

local FILES = { 'pfm-phone/config.lua', 'pfm-phone/server/main.lua' }

-- the /bill command, captured while the resource loads (the shared mock drops commands)
local commands = {}
local function load()
    local add = QBCoreMock.Commands.Add
    QBCoreMock.Commands.Add = function(name, _, _, _, fn) commands[name] = fn end
    local ok, err = pcall(LedgerEnv.load, 'pfm-phone', FILES)
    QBCoreMock.Commands.Add = add
    assert(ok, err)
    Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function() end }
    Config.BillingCommissions = {}
    -- the ledger's key lookups, with a hook a test can run "while the payment waits on the database"
    local bank = Mock.exportsByResource['pfm-banking']
    local get = PFLedger.GetTransaction
    bank.GetTransaction = function(_, key)
        local hook = onTx
        onTx = nil
        if hook then hook() end
        return get(key)
    end
end
load()

local A, BILLER = 1, 2
local function bank() return Mock.players[A].PlayerData.money.bank end
local function pay(id) return Mock.selfExport('PayInvoice')(A, id) end
local function decline(id) return Mock.selfExport('DeclineInvoice')(A, id) end
local function police() return FakeDB.bank_accounts['police'].account_balance end
local function create(amount)
    return Mock.selfExport('CreateInvoice')({ citizenid = 'CID1', amount = amount or 500, society = 'police', sender = 'Officer', sendercitizenid = 'CID2' })
end
local function base(id) return 'pfm-phone:invoice:tok:' .. invoices[id].ledger_token end
local function settled(outcome)
    local n = 0
    for _, e in ipairs(Mock.serverEvents) do
        if e.name == 'pfm-phone:server:invoiceSettled' and e.args[2] == outcome then n = n + 1 end
    end
    return n
end
-- completed charges (':bank' keys) under a key base
local function charges(prefix)
    local n = 0
    for _, row in ipairs(LedgerEnv.paid(prefix)) do
        if tostring(row.idempotency_key):sub(-5) == ':bank' then n = n + 1 end
    end
    return n
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    hasColumn, uuidDefault, alters, defaultAlters, columnReads, nextId, uuids = true, true, 0, 0, 0, 1, 0
    invoices, inserts, onTx = {}, {}, nil
    FakeDB.extraPatterns[3] = { ADD_COLUMN, function() return addColumn() end }
    FakeDB.extraPatterns[4] = { SET_DEFAULT, function() return setDefault() end }
    load()
    Mock.clock = Mock.clock + 1000
    Mock.players = {}
    local p = Mock.newPlayer(A)
    p.PlayerData.money = { cash = 0, bank = 2000 }
    local b = Mock.newPlayer(BILLER)
    b.PlayerData.job = { name = 'police' }
    FakeDB.society('police', 0)
end

describe('a reused invoice id', function()
    it('rows with different tokens under one id are each charged', function()
        invoices[7] = { id = 7, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1, ledger_token = '1700000000-1-111111' }
        assert_eq(pay(7), true)
        assert_eq(bank(), 1500)
        invoices[7] = { id = 7, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1, ledger_token = '1800000000-1-222222' }
        assert_eq(pay(7), true)
        assert_eq(bank(), 1000)               -- the new invoice under id 7 is not free
        assert_eq(police(), 1000)
        assert_eq(settled('paid'), 2)
    end)
    it('a malformed token falls back to the id key', function()
        invoices[8] = { id = 8, citizenid = 'CID1', amount = 100, society = 'police', sendercitizenid = '', candecline = 1, ledger_token = 'bad token:with:colons' }
        assert_eq(pay(8), true)
        assert_true(FakeDB.byKey['pfm-phone:invoice:8:bank'].state == 'completed')
    end)
    it('is charged again: the new invoice does not find the old invoice paid', function()
        local id = create()
        assert_eq(id, 1)
        assert_eq(pay(id), true)
        assert_eq(bank(), 1500)
        assert_eq(police(), 500)
        -- the table is truncated (or AUTO_INCREMENT resets): the next invoice gets id 1 again
        nextId = 1
        assert_eq(create(), 1)
        assert_eq(pay(1), true)
        assert_eq(bank(), 1000)               -- charged for the new invoice
        assert_eq(police(), 1000)             -- and the business is paid for it
        assert_eq(invoices[1], nil)
    end)
    it('the society credit of the new invoice is not taken for the old one either', function()
        assert_eq(pay(create()), true)
        nextId = 1
        local id = create()
        local token = invoices[id].ledger_token
        assert_eq(pay(id), true)
        assert_true(FakeDB.byKey['pfm-phone:invoice:tok:' .. token .. ':bank'].state == 'completed')
        assert_true(FakeDB.byKey['pfm-phone:invoice:tok:' .. token .. ':society'].state == 'completed')
    end)
    it('an invoice another resource inserts directly gets its token from the column default', function()
        -- what pfm-policejob's /bill does (no ledger_token in the statement)
        MySQL.insert.await('INSERT INTO phone_invoices (citizenid, amount, society, sender, sendercitizenid) VALUES (?, ?, ?, ?, ?)', { 'CID1', 200, 'police', 'Cop', 'CID2' })
        local token = invoices[1].ledger_token
        assert_true(type(token) == 'string' and token ~= '')
        assert_eq(pay(1), true)
        assert_true(FakeDB.byKey['pfm-phone:invoice:tok:' .. token .. ':bank'].state == 'completed')
        assert_true(FakeDB.byKey['pfm-phone:invoice:1:bank'] == nil, 'charged on the id key')
    end)
end)

describe('an invoice from before the token', function()
    it('keeps its id key, so a charge it already made still counts as paid', function()
        -- charged before the change (crash between charge and delete), stored without a token
        local res = PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = 'pfm-phone:invoice:42:bank', kind = 'purchase' })
        assert_eq(res.ok, true)
        assert_eq(bank(), 1500)
        invoices[42] = { id = 42, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(pay(42), true)
        assert_eq(bank(), 1500)               -- not charged a second time
        assert_eq(police(), 500)
        assert_eq(invoices[42], nil)
        assert_eq(settled('paid'), 1)         -- the business was credited now: reported once
    end)
    it('without a charge yet is charged on its id key', function()
        invoices[43] = { id = 43, citizenid = 'CID1', amount = 300, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(pay(43), true)
        assert_eq(bank(), 1700)
        assert_true(FakeDB.byKey['pfm-phone:invoice:43:bank'].state == 'completed')
    end)
    it('a reused pre-token row whose old invoice was fully paid reports nothing again', function()
        invoices[44] = { id = 44, citizenid = 'CID1', amount = 300, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(pay(44), true)
        assert_eq(settled('paid'), 1)
        invoices[44] = { id = 44, citizenid = 'CID1', amount = 300, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(pay(44), true)
        assert_eq(bank(), 1700)
        assert_eq(police(), 300)
        assert_eq(settled('paid'), 1)
    end)
end)

describe('paying exactly once across a crash', function()
    it('a debited attempt is not failed: no new key, then paid once when the ledger completes it', function()
        local id = create()
        local key = base(id)
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = key .. ':bank', kind = 'purchase' }).ok, true)
        FakeDB.byKey[key .. ':bank'].state = 'debited'
        local ok, err = pay(id)
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_true(FakeDB.byKey[key .. ':retry2:bank'] == nil, 'charged again on the next key')
        assert_eq(bank(), 1500)
        assert_true(invoices[id] ~= nil)
        FakeDB.byKey[key .. ':bank'].state = 'completed' -- recovery finishes the credit
        assert_eq(pay(id), true)
        assert_eq(bank(), 1500)
        assert_eq(police(), 500)
        assert_eq(charges(key), 1)
        assert_eq(settled('paid'), 1)
    end)
    it('a pending attempt waits; once recovery fails it, the next key charges once', function()
        local id = create()
        local key = base(id)
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = key .. ':bank', kind = 'purchase' }).ok, true)
        -- interrupted before the debit counted: the money is still the player's
        FakeDB.byKey[key .. ':bank'].state = 'pending'
        Mock.players[A].PlayerData.money.bank = 2000
        local ok, err = pay(id)
        assert_eq(err, 'in_progress')
        assert_eq(bank(), 2000)
        local stalePending, staleDebited = PFLedger.STALE_PENDING_SECONDS, PFLedger.STALE_DEBITED_SECONDS
        PFLedger.STALE_PENDING_SECONDS, PFLedger.STALE_DEBITED_SECONDS = -1, -1
        PFLedger.Recover()
        PFLedger.STALE_PENDING_SECONDS, PFLedger.STALE_DEBITED_SECONDS = stalePending, staleDebited
        assert_eq(FakeDB.byKey[key .. ':bank'].state, 'failed')
        assert_eq(pay(id), true)
        assert_eq(bank(), 1500)
        assert_eq(police(), 500)
        assert_eq(FakeDB.byKey[key .. ':retry2:bank'].state, 'completed')
        assert_eq(charges(key), 1)
    end)
    it('a refunded (compensated) attempt moves to the next key', function()
        local id = create()
        local key = base(id)
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = key .. ':bank', kind = 'purchase' }).ok, true)
        FakeDB.byKey[key .. ':bank'].state = 'compensated'
        Mock.players[A].PlayerData.money.bank = 2000 -- the refund
        assert_eq(pay(id), true)
        assert_eq(bank(), 1500)
        assert_eq(FakeDB.byKey[key .. ':retry2:bank'].state, 'completed')
    end)
    it('failed attempts never make an invoice unpayable', function()
        local id = create()
        local key = base(id)
        Mock.players[A].PlayerData.money.bank = 100
        for i = 1, 30 do
            local ok, err = pay(id)
            assert_eq(ok, false, 'attempt ' .. i)
            assert_eq(err, 'insufficient_funds', 'attempt ' .. i)
        end
        Mock.players[A].PlayerData.money.bank = 1000
        load() -- a restart forgets the attempt numbers: the failed keys are walked past again
        assert_eq(pay(id), true)
        assert_eq(bank(), 500)
        assert_eq(FakeDB.byKey[key .. ':retry31:bank'].state, 'completed')
        assert_eq(charges(key), 1)
    end)
    it('a crash after the charge leaves the invoice: paying again credits the business once', function()
        local id = create()
        local key = base(id)
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = key .. ':bank', kind = 'purchase' }).ok, true)
        assert_eq(pay(id), true)
        assert_eq(bank(), 1500)
        assert_eq(police(), 500)
        assert_eq(invoices[id], nil)
        assert_eq(settled('paid'), 1)
    end)
    it('a crash after the business was paid leaves the invoice: paying again moves no money', function()
        local id = create()
        local key = base(id)
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = key .. ':bank', kind = 'purchase' }).ok, true)
        assert_eq(PFPayout.PaySociety('police', 500, { key = key .. ':society' }), true)
        assert_eq(pay(id), true)
        assert_eq(bank(), 1500)
        assert_eq(police(), 500)
        assert_eq(invoices[id], nil)
    end)
    it('the business is credited before the invoice row goes', function()
        local id = create()
        local order = {}
        local del = FakeDB.extraPatterns[7][2]
        FakeDB.extraPatterns[7][2] = function(p) order[#order + 1] = police(); return del(p) end
        local ok, err = pcall(function() assert_eq(pay(id), true) end)
        FakeDB.extraPatterns[7][2] = del
        assert(ok, err)
        assert_eq(order[1], 500)
    end)
end)

describe('declining while a payment runs', function()
    it('is refused, so a paid invoice is never reported declined', function()
        local id = create()
        local during
        onTx = function() during = { decline(id) } end
        assert_eq(pay(id), true)
        assert_eq(during[1], false)
        assert_eq(during[2], 'in_progress')
        assert_eq(settled('declined'), 0)
        assert_eq(settled('paid'), 1)
        assert_eq(bank(), 1500)
    end)
    it('declines a declinable invoice once', function()
        local id = create()
        assert_eq(decline(id), true)
        assert_eq(invoices[id], nil)
        assert_eq(select(2, decline(id)), 'not_declinable')
        assert_eq(settled('declined'), 1)
        assert_eq(bank(), 2000)
    end)
end)

describe('creating invoices', function()
    it('stores a distinct ledger token with every invoice', function()
        create()
        create()
        assert_eq(#inserts, 2)
        local t1, t2 = inserts[1][8], inserts[2][8]
        assert_true(type(t1) == 'string' and t1 ~= '' and #t1 <= 40)
        assert_true(type(t2) == 'string' and t2 ~= '' and #t2 <= 40)
        assert_true(t1 ~= t2)
    end)
    it('the /bill command stores a token too', function()
        assert_true(commands.bill ~= nil)
        commands.bill(BILLER, { tostring(A), '250' })
        assert_eq(#inserts, 1)
        assert_true(type(inserts[1][8]) == 'string' and inserts[1][8] ~= '')
        assert_eq(invoices[1].amount, 250)
        assert_eq(invoices[1].society, 'police')
    end)
    it('refuses a bad invoice', function()
        assert_eq(create(0), nil)
        assert_eq(create(0.5), nil)
        assert_eq(create(-5), nil)
        assert_eq(create(1e12), nil)
        assert_eq(Mock.selfExport('CreateInvoice')({ citizenid = 'CID1', amount = 10, society = '' }), nil)
        assert_eq(Mock.selfExport('CreateInvoice')({ citizenid = 'CID1', amount = 10, society = string.rep('x', 51) }), nil)
        assert_eq(#inserts, 0)
    end)
    it('the phone never sends the token to the client', function()
        create()
        local got
        local cb = Mock.callbacks and Mock.callbacks['qb-phone:server:GetInvoices']
        assert_true(cb ~= nil, 'GetInvoices callback')
        FakeDB.extraPatterns[#FakeDB.extraPatterns + 1] = { 'SELECT * FROM phone_invoices WHERE citizenid = ?', function()
            local out = {}
            for _, r in pairs(invoices) do local c = {} for k, v in pairs(r) do c[k] = v end out[#out + 1] = c end
            return out
        end }
        FakeDB.extraPatterns[#FakeDB.extraPatterns + 1] = { 'SELECT * FROM players WHERE citizenid = ?', function() return {} end }
        cb(A, function(list) got = list end)
        FakeDB.extraPatterns[#FakeDB.extraPatterns] = nil
        FakeDB.extraPatterns[#FakeDB.extraPatterns] = nil
        assert_eq(#got, 1)
        assert_eq(got[1].ledger_token, nil)
        assert_eq(got[1].amount, 500)
    end)
end)

describe('the ledger_token column', function()
    it('is added once with its UUID() default when missing, and not touched when present', function()
        hasColumn, uuidDefault = false, false
        load()
        create()
        assert_eq(alters, 1)
        assert_eq(defaultAlters, 1)
        assert_true(type(inserts[1][8]) == 'string')
        create()
        assert_eq(alters, 1)
        load() -- a restart finds the column and its default, and leaves them
        create()
        assert_eq(alters, 1)
        assert_eq(defaultAlters, 1)
    end)
    it('a column without the default gets the default only', function()
        uuidDefault = false
        load()
        create()
        assert_eq(alters, 0)
        assert_eq(defaultAlters, 1)
    end)
    it('a database that refuses the default still stores tokens with every phone invoice', function()
        uuidDefault = false
        FakeDB.extraPatterns[4] = { SET_DEFAULT, function() error('You have an error in your SQL syntax') end }
        load()
        create()
        assert_eq(alters, 0)
        assert_true(type(inserts[1][8]) == 'string' and inserts[1][8] ~= '')
    end)
    it('when it cannot be added, invoices are still created (id keys, as before), and it is not retried on every invoice', function()
        hasColumn, uuidDefault = false, false
        FakeDB.extraPatterns[3] = { ADD_COLUMN, function() error('ALTER command denied') end }
        load()
        local id = create()
        assert_true(id ~= nil)
        assert_eq(inserts[1][8], nil)
        assert_eq(pay(id), true)
        assert_true(FakeDB.byKey['pfm-phone:invoice:' .. id .. ':bank'].state == 'completed')
        local reads = columnReads
        create()
        create()
        assert_eq(columnReads, reads, 'checked again for every invoice')
        -- a minute later it is tried again, and works once the column can be added
        FakeDB.extraPatterns[3] = { ADD_COLUMN, function() return addColumn() end }
        Mock.gameTimer = Mock.gameTimer + 61000
        create()
        assert_eq(alters, 1)
        assert_true(type(inserts[#inserts][8]) == 'string')
    end)
end)
