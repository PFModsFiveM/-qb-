-- pfm-banking's Bank app on pf-devices (server_app.lua) and branch closures after robberies
-- (server_branches.lua), on the fake database with the real ledger and the real pf-devices bridge:
-- who may use which account, the identity always comes from the server, payload validation, each
-- action moves money once per ref, cash never moves remotely, and robbed branches refuse service.
-- SQL filters, paging and character deletion run on a real database (bank_app_realdb_spec.lua).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')

local started = { ['pf-devices'] = true, ['pfm-banking'] = true, ['pfm-core'] = true, ['pf-services'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

-- pfm-banking's Config first: pf-devices' config adds its fields to the same table
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

-- pf-services as other resources see it
local cityEvents, kinds = {}, {}
Mock.exportsByResource['pf-services'] = {
    RegisterEventKind = function(_, kind, def) kinds[kind] = def return true end,
    Emit = function(_, kind, data, opts) cityEvents[#cityEvents + 1] = { kind = kind, data = data, opts = opts } return { id = #cityEvents } end,
}
Mock.exportsByResource['pfm-inventory'] = { GetItemsByName = function() return { { info = { cardPin = 1234 } } } end }

function GetCurrentResourceName() return 'pfm-banking' end
for _, f in ipairs({ 'pfm-core/server/migrations.lua', 'pfm-banking/server_ledger.lua', 'pfm-banking/server.lua', 'pfm-banking/server_finance.lua',
    'pfm-banking/server_accounts.lua', 'pfm-banking/server_shared_migration.lua', 'pfm-banking/server_branches.lua',
    'pfm-banking/server_characters.lua', 'pfm-banking/server_app.lua' }) do
    load_resource(f)
end
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
local L = PFLedger

-- statements the app adds on top of the bank's own (FakeDB knows those)
local function startsWith(s, prefix) return tostring(s):sub(1, #prefix) == prefix end
FakeDB.extraPatterns = {
    { 'SELECT COALESCE(SUM(amount), 0) FROM pf_transactions', function(p)
        local prefix = p[1]:gsub('%%$', '')
        local sum = 0
        for _, tx in ipairs(FakeDB.transactions) do
            if tx.state == 'completed' and startsWith(tx.idempotency_key, prefix) then sum = sum + tx.amount end
        end
        return sum
    end },
    { 'COALESCE(SUM(CASE WHEN to_account', function(p)
        local credits, debits, n = 0, 0, 0
        for _, tx in ipairs(FakeDB.transactions) do
            if tx.state == 'completed' and (tx.to_account == p[1] or tx.from_account == p[1]) then
                n = n + 1
                if tx.to_account == p[1] then credits = credits + tx.amount else debits = debits + tx.amount end
            end
        end
        return { { credits = credits, debits = debits, line_count = n } }
    end },
    { 'SELECT id, tx_id, kind, from_account, to_account, amount, reason, metadata', function(p)
        local out = {}
        for i = #FakeDB.transactions, 1, -1 do
            local tx = FakeDB.transactions[i]
            if tx.state == 'completed' and (tx.to_account == p[1] or tx.from_account == p[1]) then
                out[#out + 1] = { id = tx.id, tx_id = tx.tx_id, kind = tx.kind, from_account = tx.from_account, to_account = tx.to_account,
                    amount = tx.amount, reason = tx.reason, metadata = tx.metadata, at = tx.created_at }
            end
        end
        return out
    end },
    { 'SELECT citizenid, charinfo FROM players WHERE citizenid IN', function(p)
        local out = {}
        for _, cid in ipairs(p) do
            for _, pl in pairs(Mock.players) do
                if pl.PlayerData.citizenid == cid then out[#out + 1] = { citizenid = cid, charinfo = json.encode(pl.PlayerData.charinfo) } end
            end
        end
        return out
    end },
    { 'SELECT id, label, iban FROM bank_accounts_v2 WHERE id IN', function(p)
        local out = {}
        for _, id in ipairs(p) do if FakeDB.v2[id] then out[#out + 1] = FakeDB.v2[id] end end
        return out
    end },
    { 'SELECT 1 FROM players WHERE citizenid = ? LIMIT 1', function(p) return FakeDB.players[p[1]] and 1 or nil end },
    { 'SELECT iban FROM bank_personal_iban WHERE citizenid = ?', function(p) return FakeDB.personalIban[p[1]] end },
    { 'INSERT IGNORE INTO bank_personal_iban', function(p) FakeDB.personalIban[p[1]] = FakeDB.personalIban[p[1]] or p[2]; return 1 end },
    { 'WHERE owner = ? OR id IN', function(p)
        local out = {}
        for id, a in pairs(FakeDB.v2) do
            local member = a.owner == p[1]
            for _, m in ipairs(FakeDB.members) do if m.account_id == id and m.citizenid == p[2] then member = true end end
            if member then out[#out + 1] = a end
        end
        table.sort(out, function(x, y) return x.id < y.id end)
        return out
    end },
    { 'FROM bank_transactions WHERE account_ref = ?', function() return {} end },
    { 'SELECT citizenid, name, can_withdraw, can_deposit, can_cards, can_manage FROM bank_account_members WHERE account_id = ?', function(p)
        local out = {}
        for _, m in ipairs(FakeDB.members) do if m.account_id == p[1] then out[#out + 1] = m end end
        return out
    end },
    { 'FROM bank_account_cards', function() return {} end },
    { 'SELECT * FROM bank_accounts_v2 WHERE id = ?', function(p) return FakeDB.v2[tonumber(p[1])] end },
}

local ME, OTHER, BOSS = 1, 2, 3
local ACC, FOREIGN
local ALTA = Config.locations[2]

local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function rpc(src, method, payload) return PFDevices.HandleRpc(src, 'bank', method, payload) end
local function completed(prefix) local n = 0; for _, tx in pairs(FakeDB.byKey) do if tx.state == 'completed' and startsWith(tx.idempotency_key, prefix) then n = n + 1 end end; return n end
local refN = 0
local function ref() refN = refN + 1; return ('test-ref-%06d'):format(refN) end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    FakeDB.migrations = {}
    Mock.players, Mock.coords = {}, {}
    cityEvents, kinds = {}, {}
    Config.App.cooldownMs = 0
    Config.App.dailyTransferLimit = 1000000
    PFDevices.__reset()
    PFDevices.__resetRpc()
    PFBankApp.__reset()
    BankBranches.__reset()
    for k in pairs(BankingAccounts) do BankingAccounts[k] = nil end
    local function player(src, cid, b, job)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.money = { cash = 300, bank = b }
        p.PlayerData.job = job or { name = 'unemployed', grade = { level = 0 }, isboss = false }
        p.PlayerData.gang = { name = 'none', isboss = false, grade = { level = 0 } }
        return p
    end
    player(ME, 'ME001', 5000)
    player(OTHER, 'OT001', 100)
    player(BOSS, 'BS001', 5000, { name = 'mechanic', label = 'Mechanic', grade = { level = 4 }, isboss = true })
    QBCoreMock.Shared.Jobs.mechanic = { label = 'Mechanic', grades = {} }
    FakeDB.players.OFF1 = { money = { bank = 50, cash = 0 } }
    FakeDB.personalIban.OFF1 = 'PF00000001'
    FakeDB.society('mechanic', 1000, 'job')
    ACC = FakeDB.ibanAccount('ME001', 800, 'Family')
    FakeDB.member(ACC, 'OT001', { d = 1, w = 0 })
    FOREIGN = FakeDB.ibanAccount('ZZ999', 5000, 'Not yours')
    L.ready, L.failed = false, false
    assert(L.Start(), 'ledger start')
    BankingAccounts.mechanic = { account_name = 'mechanic', account_balance = 1000, account_type = 'job' }
    Mock.invokingResource = 'pfm-banking'
    PFBankApp.Register()
    Mock.invokingResource = nil
end

describe('the Bank app on pf-devices', function()
    it('is on the tablet and the computer for anyone, served by pfm-banking', function()
        local app = PFDevices.GetApp('bank')
        assert_true(app ~= nil)
        assert_eq(app.resource, 'pfm-banking')
        assert_eq(app.access.anyone, true)
        assert_eq(table.concat(app.devices, ','), 'computer,tablet')
        local seen = false
        for _, a in ipairs(PFDevices.GetAppsFor(OTHER, 'tablet').apps) do if a.id == 'bank' then seen = true end end
        assert_true(seen)
    end)
    it('the overview is the caller’s own: balances from the server, shared accounts by membership, societies for bosses', function()
        local res = rpc(ME, 'overview', { citizenid = 'BS001', balance = 999999 })
        assert_true(res.ok)
        assert_eq(res.me.citizenid, 'ME001')
        assert_eq(res.personal.balance, 5000)
        assert_eq(res.personal.cash, 300)
        assert_true(type(res.personal.iban) == 'string' and res.personal.iban:match('^PF%d+$') ~= nil)
        assert_eq(#res.accounts, 1)
        assert_eq(res.accounts[1].ref, 'acct:' .. ACC)
        assert_true(res.accounts[1].perms.manage)
        assert_eq(#res.societies, 0, 'not a boss')
        local other = rpc(OTHER, 'overview')
        assert_eq(#other.accounts, 1)
        assert_false(other.accounts[1].perms.withdraw)
        assert_eq(other.accounts[1].members, nil, 'members only for managers')
        local boss = rpc(BOSS, 'overview')
        assert_eq(#boss.societies, 1)
        assert_eq(boss.societies[1].ref, 'society:mechanic')
        assert_eq(boss.societies[1].balance, 1000)
        assert_eq(#boss.branches, #Config.locations)
    end)
end)

describe('transfers: identity and validation', function()
    local function send(src, p) p.ref = p.ref or ref(); return rpc(src, 'transfer', p) end
    it('a client cannot name someone else’s account as the source', function()
        assert_eq(send(ME, { from = 'player:OT001:bank', to = { type = 'iban', iban = 'PF00000001' }, amount = 10 }).error, 'bad_account')
        assert_eq(send(ME, { from = 'acct:' .. FOREIGN, to = { type = 'iban', iban = 'PF00000001' }, amount = 10 }).error, 'not_authorized')
        assert_eq(send(ME, { from = 'society:mechanic', to = { type = 'own', account = 'personal' }, amount = 10 }).error, 'not_authorized')
        assert_eq(send(OTHER, { from = 'acct:' .. ACC, to = { type = 'own', account = 'personal' }, amount = 10 }).error, 'not_authorized', 'no withdraw permission')
        assert_eq(FakeDB.v2[FOREIGN].balance, 5000)
        assert_eq(#FakeDB.transactions, 0)
    end)
    it('cash never moves from a device', function()
        assert_eq(send(ME, { from = 'cash', to = { type = 'own', account = 'personal' }, amount = 10 }).error, 'cash_at_counter')
        assert_eq(send(ME, { from = 'personal', to = { type = 'own', account = 'cash' }, amount = 10 }).error, 'cash_at_counter')
        assert_eq(Mock.players[ME].PlayerData.money.cash, 300)
    end)
    it('refuses bad payloads before anything moves', function()
        assert_eq(rpc(ME, 'transfer', { from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 10 }).error, 'bad_request', 'no ref')
        assert_eq(send(ME, { ref = 'bad ref!', from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 10 }).error, 'bad_request')
        for _, amount in ipairs({ -5, 0, 1.5, 'abc', 0 / 0 }) do
            assert_eq(send(ME, { from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = amount }).error, 'bad_amount', tostring(amount))
        end
        assert_eq(send(ME, { from = 'personal', to = 'PF00000001', amount = 10 }).error, 'bad_request')
        assert_eq(send(ME, { from = 'personal', to = { type = 'iban', iban = 'XX1' }, amount = 10 }).error, 'bad_iban')
        assert_eq(send(ME, { from = 'personal', to = { type = 'citizen', citizenid = "x' OR 1" }, amount = 10 }).error, 'bad_citizen')
        assert_eq(send(ME, { from = 'personal', to = { type = 'citizen', citizenid = 'NOBODY1' }, amount = 10 }).error, 'unknown_citizen')
        assert_eq(send(ME, { from = 'personal', to = { type = 'citizen', citizenid = 'ME001' }, amount = 10 }).error, 'same_account')
        assert_eq(send(ME, { from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = Config.App.maxTransfer + 1 }).error, 'over_limit')
        assert_eq(send(ME, { from = 'personal', to = { type = 'sideways' }, amount = 10 }).error, 'bad_request')
        assert_eq(bank(ME), 5000)
        assert_eq(#FakeDB.transactions, 0)
    end)
    it('a payload that is not a table never reaches the handler', function()
        assert_eq(rpc(ME, 'transfer', 'all my money').error, 'bad_request')
    end)
end)

describe('transfers: money moves once per ref', function()
    it('paying an offline citizen by IBAN twice with the same ref pays once', function()
        local r = ref()
        local first = rpc(ME, 'transfer', { ref = r, from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 200, note = 'rent' })
        assert_true(first.ok, tostring(first.error))
        local again = rpc(ME, 'transfer', { ref = r, from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 200, note = 'rent' })
        assert_true(again.ok)
        assert_true(again.duplicate)
        assert_eq(bank(ME), 4800)
        assert_eq(FakeDB.players.OFF1.money.bank, 250)
        assert_eq(completed('bankapp:ME001:x:'), 1)
        assert_eq(#FakeDB.bankTx, 2, 'history written once')
        local tx = FakeDB.transactions[#FakeDB.transactions]
        assert_eq(tx.actor, 'ME001', 'the actor is the server-side citizen')
    end)
    it('pays a citizen by citizen ID (their IBAN is resolved on the server)', function()
        local res = rpc(ME, 'transfer', { ref = ref(), from = 'personal', to = { type = 'citizen', citizenid = 'ot001' }, amount = 50 })
        assert_true(res.ok, tostring(res.error))
        assert_eq(bank(OTHER), 150)
        assert_eq(bank(ME), 4950)
    end)
    it('a payment the player cannot afford moves nothing and a new ref can try again', function()
        local res = rpc(OTHER, 'transfer', { ref = ref(), from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 5000 })
        assert_false(res.ok)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(bank(OTHER), 100)
        assert_true(rpc(OTHER, 'transfer', { ref = ref(), from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 60 }).ok)
    end)
    it('the daily limit counts what was already sent today', function()
        Config.App.dailyTransferLimit = 300
        assert_true(rpc(ME, 'transfer', { ref = ref(), from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 200 }).ok)
        assert_eq(rpc(ME, 'transfer', { ref = ref(), from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 200 }).error, 'daily_limit')
        assert_eq(bank(ME), 4800)
    end)
    it('two money actions too close together: the second waits', function()
        Config.App.cooldownMs = 60000
        assert_true(rpc(ME, 'transfer', { ref = ref(), from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 10 }).ok)
        assert_eq(rpc(ME, 'transfer', { ref = ref(), from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 10 }).error, 'slow_down')
    end)
    it('own moves: personal -> shared account by permission, shared -> personal only with withdraw', function()
        local dep = rpc(OTHER, 'transfer', { ref = ref(), from = 'personal', to = { type = 'own', account = 'acct:' .. ACC }, amount = 40 })
        assert_true(dep.ok, tostring(dep.error))
        assert_eq(FakeDB.v2[ACC].balance, 840)
        assert_eq(bank(OTHER), 60)
        local wd = rpc(ME, 'transfer', { ref = ref(), from = 'acct:' .. ACC, to = { type = 'own', account = 'personal' }, amount = 100 })
        assert_true(wd.ok)
        assert_eq(FakeDB.v2[ACC].balance, 740)
        assert_eq(bank(ME), 5100)
    end)
    it('money put into a shared account someone else owns counts toward the daily limit', function()
        Config.App.dailyTransferLimit = 50
        local res = rpc(OTHER, 'transfer', { ref = ref(), from = 'personal', to = { type = 'own', account = 'acct:' .. ACC }, amount = 60 })
        assert_eq(res.error, 'daily_limit')
        assert_true(rpc(OTHER, 'transfer', { ref = ref(), from = 'personal', to = { type = 'own', account = 'acct:' .. ACC }, amount = 40 }).ok)
        assert_eq(completed('bankapp:OT001:x:'), 1)
        assert_true(rpc(ME, 'transfer', { ref = ref(), from = 'personal', to = { type = 'own', account = 'acct:' .. ACC }, amount = 500 }).ok, 'the owner’s own account is not limited')
        assert_eq(completed('bankapp:ME001:i:'), 1)
    end)
    it('a boss moves society money to and from their own bank, once per ref', function()
        local r = ref()
        assert_true(rpc(BOSS, 'transfer', { ref = r, from = 'personal', to = { type = 'own', account = 'society:mechanic' }, amount = 500 }).ok)
        assert_true(rpc(BOSS, 'transfer', { ref = r, from = 'personal', to = { type = 'own', account = 'society:mechanic' }, amount = 500 }).duplicate)
        assert_eq(FakeDB.bank_accounts.mechanic.account_balance, 1500)
        assert_eq(bank(BOSS), 4500)
        assert_true(rpc(BOSS, 'transfer', { ref = ref(), from = 'society:mechanic', to = { type = 'own', account = 'personal' }, amount = 1500 }).ok)
        assert_eq(FakeDB.bank_accounts.mechanic.account_balance, 0)
        local over = rpc(BOSS, 'transfer', { ref = ref(), from = 'society:mechanic', to = { type = 'own', account = 'personal' }, amount = 1 })
        assert_eq(over.error, 'insufficient_funds', 'no money is created')
        assert_eq(bank(BOSS), 6000)
        assert_eq(rpc(BOSS, 'transfer', { ref = ref(), from = 'society:mechanic', to = { type = 'iban', iban = 'PF00000001' }, amount = 1 }).error, 'unsupported_route')
        local report = L.Reconcile()
        assert_eq(#report.mismatches, 0)
    end)
end)

describe('statements', function()
    it('shows the caller’s ledger lines with readable counterparties, never another account', function()
        rpc(ME, 'transfer', { ref = ref(), from = 'personal', to = { type = 'citizen', citizenid = 'OT001' }, amount = 25, note = 'pizza' })
        local st = rpc(ME, 'statement', { account = 'personal' })
        assert_true(st.ok)
        assert_eq(#st.rows, 1)
        assert_eq(st.rows[1].direction, 'out')
        assert_eq(st.rows[1].amount, 25)
        assert_eq(st.rows[1].note, 'pizza')
        assert_eq(st.rows[1].counterparty.label, 'Test Player2')
        assert_eq(st.summary.moneyOut, 25)
        local theirs = rpc(OTHER, 'statement', { account = 'personal' })
        assert_eq(theirs.rows[1].direction, 'in')
        assert_eq(rpc(ME, 'statement', { account = 'acct:' .. FOREIGN }).error, 'not_authorized')
        assert_eq(rpc(ME, 'statement', { account = 'society:mechanic' }).error, 'not_authorized')
        assert_eq(rpc(ME, 'statement', { account = 'player:OT001:bank' }).error, 'bad_account')
        assert_true(rpc(ME, 'statement', { account = 'cash' }).ok, 'the cash ledger can be viewed')
        assert_true(rpc(BOSS, 'statement', { account = 'society:mechanic' }).ok)
    end)
end)

describe('loans and cards through the app', function()
    it('uses the bank’s own handlers and validates ids', function()
        local res = rpc(ME, 'applyLoan', { tierIndex = 1, amount = 10000 })
        assert_true(res.ok, tostring(res.message))
        assert_eq(bank(ME), 15000)
        local fin = rpc(ME, 'finance')
        assert_true(fin.ok)
        assert_eq(#fin.loans, 1)
        assert_true(rpc(ME, 'payLoan', { loanId = fin.loans[1].id }).ok)
        assert_eq(rpc(ME, 'payLoan', { loanId = 'x' }).error, 'bad_request')
        assert_eq(rpc(ME, 'payCard', { cardId = 1, amount = -1 }).error, 'bad_request')
        assert_false(rpc(OTHER, 'payLoan', { loanId = fin.loans[1].id }).ok, 'someone else’s loan')
    end)
end)

describe('branches closed after a robbery', function()
    local function openBank(src) return Mock.callCallback('qb-banking:server:openBank', src) end
    local function notified(src)
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.target == src then return e.args[1] end end
    end
    it('is a server-only event: clients cannot close a branch', function()
        assert_eq(Mock.netHandlers['qb-banking:server:SetBankClosed'], nil)
        source = ME
        Mock.eventHandlers['qb-banking:server:SetBankClosed'](1, true)
        source = nil
        assert_false(BankBranches.IsClosed(2))
        TriggerEvent('qb-banking:server:SetBankClosed', 'nope', true)
        TriggerEvent('qb-banking:server:SetBankClosed', 99, true)
        TriggerEvent('qb-banking:server:SetBankClosed', 1, 'yes')
        for id = 1, #Config.locations do assert_false(BankBranches.IsClosed(id)) end
    end)
    it('a robbed Fleeca closes its branch: counter, ATM and cash refuse with a clear message', function()
        TriggerEvent('qb-banking:server:SetBankClosed', 1, true)   -- pfm-bankrobbery's Fleeca 1 is Alta
        assert_true(BankBranches.IsClosed(2))
        Mock.coords[ME] = vector3(ALTA.x + 2, ALTA.y, ALTA.z)
        assert_eq(openBank(ME), false)
        local msg = notified(ME)
        assert_true(msg and msg:find('closed after a robbery', 1, true) ~= nil, tostring(msg))
        assert_true(msg:find('reopens in 20 minutes', 1, true) ~= nil, msg)
        assert_eq(Mock.callCallback('qb-banking:server:openATM', ME), false)
        local wd = Mock.callCallback('qb-banking:server:withdraw', ME, { accountName = 'checking', amount = 100 })
        assert_false(wd.success)
        assert_true(wd.message:find('closed', 1, true) ~= nil)
        assert_eq(Mock.players[ME].PlayerData.money.cash, 300)
        -- elsewhere the bank works, and remote transfers keep working
        Mock.coords[OTHER] = vector3(0, 0, 0)
        assert_true(type(openBank(OTHER)) == 'table')
        assert_true(rpc(ME, 'transfer', { ref = ref(), from = 'personal', to = { type = 'iban', iban = 'PF00000001' }, amount = 5 }).ok)
    end)
    it('emits city events and reopens by itself after the configured time', function()
        TriggerEvent('qb-banking:server:SetBankClosed', 'paleto', true)
        assert_true(BankBranches.IsClosed(8))
        assert_eq(cityEvents[1].kind, 'bank.branch.closed')
        assert_eq(cityEvents[1].data.branch, 8)
        assert_true(cityEvents[1].opts.title:find('Paleto Bay', 1, true) ~= nil)
        Mock.clock = Mock.clock + Config.BranchClosure.minutes * 60 + 1
        assert_false(BankBranches.IsClosed(8))
        assert_eq(cityEvents[2].kind, 'bank.branch.reopened')
        Mock.coords[ME] = Config.locations[8]
        assert_true(type(openBank(ME)) == 'table')
    end)
    it('the robbery resource reopening the bank ends the closure early', function()
        TriggerEvent('qb-banking:server:SetBankClosed', 2, true)
        assert_true(BankBranches.IsClosed(1))
        TriggerEvent('qb-banking:server:SetBankClosed', 2, false)
        assert_false(BankBranches.IsClosed(1))
        local list = rpc(ME, 'branches').branches
        assert_false(list[1].closed)
    end)
    it('registers its city event kinds with pf-services', function()
        BankBranches.RegisterEventKinds()
        assert_true(kinds['bank.branch.closed'] ~= nil)
        assert_true(kinds['bank.branch.reopened'] ~= nil)
    end)
    it('the Bank app shows the closure and when it ends', function()
        TriggerEvent('qb-banking:server:SetBankClosed', 3, true)
        local b = rpc(ME, 'overview').branches[3]
        assert_true(b.closed)
        assert_eq(b.reason, 'robbery')
        assert_true(b.reopensIn > 0 and b.reopensIn <= Config.BranchClosure.minutes * 60)
    end)
end)
