-- Batch 14, BANK-1 and X-9: who may change members and cards of a shared account, on a real database.
-- The owner may do anything. A manager who is not the owner cannot change their own row, cannot add,
-- change or remove another manager, cannot hand out management, and may hand out withdraw/cards only
-- when they hold them; any member may leave. Member changes run under the account lock (taken before
-- the first read) and are logged. A card is locked or cancelled by its holder, the owner, or a manager
-- (cards of members without management); can_cards alone covers only the member's own cards.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
local started = { ['pf-devices'] = true, ['pfm-banking'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')

local CIDS = {
    OWNER = 'OWN00001', BOOK = 'BOOK0001', MGR2 = 'MGRB0001', FULL = 'FULL0001',
    PLAIN = 'PLN00001', CARDS = 'CRD00001', ALT = 'ALT00001', NEWB = 'NEWB0001',
}
for key, cid in pairs(CIDS) do
    MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, ?, ?, '{}', '{}', '{}', '{}', '[]')]], { cid, 'license:' .. cid, key, json.encode({ cash = 0, bank = 1000 }),
        json.encode({ firstname = key:sub(1, 1) .. key:sub(2):lower(), lastname = 'Test' }) })
end

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
Config.App.cooldownMs = 0
Mock.invokingResource = 'pfm-banking'
PFBankApp.Register()
Mock.invokingResource = nil

local SRC = { OWNER = 1, BOOK = 2, MGR2 = 3, FULL = 4, PLAIN = 5, CARDS = 6, ALT = 7 }
for key, src in pairs(SRC) do
    local p = Mock.newPlayer(src, CIDS[key])
    p.PlayerData.money = { cash = 0, bank = 1000 }
    p.PlayerData.job = { name = 'unemployed', grade = { level = 0 }, isboss = false }
    p.PlayerData.gang = { name = 'none', isboss = false }
end

-- the shared account of OWNER, funded through the ledger
local ACC = MySQL.insert.await("INSERT INTO bank_accounts_v2 (iban, label, type, owner, balance) VALUES ('PF70000001', 'Bakery', 'business', ?, 0)", { CIDS.OWNER })
MySQL.insert.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, 0)', { 'acct:' .. ACC })
assert(L.Transfer({ from = 'system:test', to = 'acct:' .. ACC, amount = 20000, key = 'fix14-bank-fund' }).ok, 'fund the account')

-- w, d, c, m per member; the owner's row is full access as createAccount writes it
local START = {
    OWNER = { 1, 1, 1, 1 },
    BOOK = { 0, 1, 0, 1 },   -- bookkeeper: manages, may not withdraw, no cards
    MGR2 = { 1, 1, 1, 1 },   -- a second manager the owner trusts fully
    FULL = { 1, 1, 1, 1 },   -- replaced per test where needed
    PLAIN = { 0, 1, 0, 0 },
    CARDS = { 0, 1, 1, 0 },  -- may issue cards, no management
}
local function resetMembers(overrides)
    MySQL.update.await('DELETE FROM bank_account_members WHERE account_id = ?', { ACC })
    MySQL.update.await('DELETE FROM bank_account_cards WHERE account_id = ?', { ACC })
    for key, bits in pairs(START) do
        local b = bits
        if overrides and overrides[key] ~= nil then b = overrides[key] end
        if b ~= false then
            MySQL.insert.await('INSERT INTO bank_account_members (account_id, citizenid, name, can_withdraw, can_deposit, can_cards, can_manage) VALUES (?, ?, ?, ?, ?, ?, ?)',
                { ACC, CIDS[key], key, b[1], b[2], b[3], b[4] })
        end
    end
    Mock.serverEvents = {}
end

local function cb(name, src, data) return Mock.callCallback('qb-banking:server:' .. name, src, data) end
local function rpc(src, method, payload) PFDevices.__resetRpc() return PFDevices.HandleRpc(src, 'bank', method, payload) end
local function row(key)
    local r = MySQL.single.await('SELECT * FROM bank_account_members WHERE account_id = ? AND citizenid = ?', { ACC, CIDS[key] })
    if not r then return nil end
    return { tonumber(r.can_withdraw), tonumber(r.can_deposit), tonumber(r.can_cards), tonumber(r.can_manage) }
end
local function bits(r) return r and table.concat(r, '') or 'none' end
local function perms(w, d, c, m) return { can_withdraw = w == 1, can_deposit = d == 1, can_cards = c == 1, can_manage = m == 1 } end
local function balance() return tonumber(MySQL.scalar.await('SELECT balance FROM bank_accounts_v2 WHERE id = ?', { ACC })) end
local function logs(title)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do
        if e.name == 'qb-log:server:CreateLog' and e.args[2] == title then out[#out + 1] = e.args[4] end
    end
    return out
end
local function noMismatches()
    local report = L.Reconcile()
    for _, mm in ipairs(report.mismatches) do print('mismatch', mm.account, mm.expected, mm.actual) end
    return #report.mismatches == 0
end

describe('BANK-1: a manager who is not the owner', function()
    it('cannot give themselves withdraw, so cannot take the balance', function()
        resetMembers()
        local res = cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.BOOK, perms = perms(1, 1, 1, 1) })
        assert_false(res.success)
        assert_eq(bits(row('BOOK')), '0101', 'own row unchanged')
        local wd = cb('accountWithdraw', SRC.BOOK, { accountId = ACC, amount = 20000 })
        assert_false(wd.success)
        assert_eq(balance(), 20000)
        -- the app runs the same callback
        local app = rpc(SRC.BOOK, 'updateMember', { account = 'acct:' .. ACC, citizenid = CIDS.BOOK, perms = perms(1, 1, 1, 1) })
        assert_false(app.ok)
        assert_eq(bits(row('BOOK')), '0101')
    end)

    it('cannot hand out withdraw or cards they lack, to a member or to a new alt', function()
        resetMembers()
        assert_false(cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(1, 1, 0, 0) }).success)
        assert_false(cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(0, 1, 1, 0) }).success)
        assert_eq(bits(row('PLAIN')), '0100')
        local add = cb('addMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.ALT, perms = perms(1, 1, 0, 0) })
        assert_false(add.success)
        assert_eq(row('ALT'), nil, 'no alt with withdraw')
        assert_false(cb('addMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.ALT, perms = perms(0, 1, 1, 0) }).success)
        assert_eq(row('ALT'), nil)
        -- the alt cannot withdraw for the bookkeeper either
        assert_false(cb('accountWithdraw', SRC.ALT, { accountId = ACC, amount = 100 }).success)
        assert_eq(balance(), 20000)
    end)

    it('cannot take away a right they do not hold either', function()
        resetMembers({ PLAIN = { 1, 1, 1, 0 } })
        assert_false(cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(0, 1, 1, 0) }).success)
        assert_eq(bits(row('PLAIN')), '1110')
        -- keeping it as it is while changing deposit is fine
        assert_true(cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(1, 0, 1, 0) }).success)
        assert_eq(bits(row('PLAIN')), '1010')
    end)

    it('cannot grant management, nor change, strip or remove another manager', function()
        resetMembers()
        assert_false(cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(0, 1, 0, 1) }).success)
        assert_eq(bits(row('PLAIN')), '0100')
        assert_false(cb('addMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.ALT, perms = perms(0, 1, 0, 1) }).success)
        assert_eq(row('ALT'), nil)
        assert_false(cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.MGR2, perms = perms(0, 1, 0, 0) }).success)
        assert_eq(bits(row('MGR2')), '1111', 'the other manager keeps every right')
        assert_false(cb('removeMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.MGR2 }).success)
        assert_eq(bits(row('MGR2')), '1111', 'and stays a member')
        assert_false(cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.OWNER, perms = perms(0, 0, 0, 0) }).success)
        assert_false(cb('removeMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.OWNER }).success)
        assert_eq(bits(row('OWNER')), '1111')
    end)

    it('so a deleted owner\'s account still goes to a manager the owner chose', function()
        resetMembers({ FULL = false, CARDS = false })
        -- the bookkeeper tries to clear the way to the inheritance; nothing changes
        cb('removeMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.MGR2 })
        cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.MGR2, perms = perms(0, 0, 0, 0) })
        cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.BOOK, perms = perms(1, 1, 1, 1) })
        local heir = MySQL.scalar.await([[SELECT citizenid FROM bank_account_members WHERE account_id = ? AND citizenid <> ?
            ORDER BY can_manage DESC, can_withdraw DESC, can_deposit DESC, citizenid ASC LIMIT 1]], { ACC, CIDS.OWNER })
        assert_eq(heir, CIDS.MGR2)
    end)

    it('may hand out the rights they hold and manage plain members', function()
        resetMembers({ FULL = { 1, 1, 1, 1 } })
        -- FULL is a manager with withdraw and cards (not the owner)
        assert_true(cb('updateMember', SRC.FULL, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(1, 1, 1, 0) }).success)
        assert_eq(bits(row('PLAIN')), '1110')
        assert_false(cb('updateMember', SRC.FULL, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(1, 1, 1, 1) }).success, 'never management')
        local add = cb('addMember', SRC.FULL, { accountId = ACC, citizenid = CIDS.ALT, perms = perms(1, 1, 0, 0) })
        assert_true(add.success, tostring(add.message))
        assert_eq(bits(row('ALT')), '1100')
        -- the bookkeeper may still add deposit-only members and remove plain ones
        assert_true(cb('addMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.NEWB, perms = perms(0, 1, 0, 0) }).success)
        assert_eq(bits(row('NEWB')), '0100')
        assert_true(cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.NEWB, perms = perms(0, 0, 0, 0) }).success)
        assert_eq(bits(row('NEWB')), '0000')
        assert_true(cb('removeMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.NEWB }).success)
        assert_eq(row('NEWB'), nil)
        -- a manager cannot change another manager even when they hold every right
        assert_false(cb('updateMember', SRC.FULL, { accountId = ACC, citizenid = CIDS.BOOK, perms = perms(0, 1, 0, 0) }).success)
        assert_eq(bits(row('BOOK')), '0101')
    end)
end)

describe('BANK-1: leaving and the owner', function()
    it('a manager or a plain member may leave; the owner may not; a plain member removes nobody else', function()
        resetMembers()
        MySQL.insert.await("INSERT INTO bank_account_cards (account_id, citizenid, holder_name, number, cvv, exp, design) VALUES (?, ?, 'Plain', '4000000000000001', '123', '01/30', 'classic')", { ACC, CIDS.PLAIN })
        assert_false(cb('removeMember', SRC.PLAIN, { accountId = ACC, citizenid = CIDS.CARDS }).success)
        assert_true(row('CARDS') ~= nil)
        local left = cb('removeMember', SRC.PLAIN, { accountId = ACC, citizenid = CIDS.PLAIN })
        assert_true(left.success, tostring(left.message))
        assert_eq(row('PLAIN'), nil)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM bank_account_cards WHERE account_id = ? AND citizenid = ? AND cancelled = 0', { ACC, CIDS.PLAIN })), 0, 'their cards are cancelled')
        assert_eq(#logs('Member Left'), 1)
        assert_true(cb('removeMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.BOOK }).success)
        assert_eq(row('BOOK'), nil)
        assert_false(cb('removeMember', SRC.OWNER, { accountId = ACC, citizenid = CIDS.OWNER }).success)
        assert_eq(bits(row('OWNER')), '1111')
        -- a stranger cannot leave what they are not in
        assert_false(cb('removeMember', SRC.ALT, { accountId = ACC, citizenid = CIDS.ALT }).success)
    end)

    it('the owner may do anything to members but their own row', function()
        resetMembers()
        assert_true(cb('updateMember', SRC.OWNER, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(1, 1, 1, 1) }).success)
        assert_eq(bits(row('PLAIN')), '1111')
        assert_true(cb('updateMember', SRC.OWNER, { accountId = ACC, citizenid = CIDS.MGR2, perms = perms(0, 1, 0, 0) }).success)
        assert_eq(bits(row('MGR2')), '0100')
        assert_true(cb('removeMember', SRC.OWNER, { accountId = ACC, citizenid = CIDS.BOOK }).success)
        assert_eq(row('BOOK'), nil)
        assert_true(cb('addMember', SRC.OWNER, { accountId = ACC, citizenid = CIDS.ALT, perms = perms(1, 1, 1, 1) }).success)
        assert_eq(bits(row('ALT')), '1111')
        assert_false(cb('updateMember', SRC.OWNER, { accountId = ACC, citizenid = CIDS.OWNER, perms = perms(0, 0, 0, 0) }).success)
        assert_eq(bits(row('OWNER')), '1111')
    end)

    it('logs every member change with the rights before and after', function()
        resetMembers({ FULL = { 1, 1, 1, 1 } })
        assert_true(cb('updateMember', SRC.FULL, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(1, 1, 0, 0) }).success)
        local changed = logs('Member Rights Changed')
        assert_eq(#changed, 1)
        assert_true(changed[1]:find(CIDS.FULL, 1, true) ~= nil, 'who changed it')
        assert_true(changed[1]:find(CIDS.PLAIN, 1, true) ~= nil, 'whom')
        assert_true(changed[1]:find('deposit -> withdraw, deposit', 1, true) ~= nil, changed[1])
        assert_true(cb('addMember', SRC.FULL, { accountId = ACC, citizenid = CIDS.ALT, perms = perms(0, 1, 0, 0) }).success)
        assert_true((logs('Member Added')[1] or ''):find('rights: deposit', 1, true) ~= nil)
        assert_true(cb('removeMember', SRC.FULL, { accountId = ACC, citizenid = CIDS.ALT }).success)
        assert_eq(#logs('Member Removed'), 1)
        -- a refused change writes nothing
        cb('updateMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.BOOK, perms = perms(1, 1, 1, 1) })
        assert_eq(#logs('Member Rights Changed'), 1)
    end)
end)

describe('BANK-1: the account lock', function()
    -- runs `inner` the first time the account row is read, as a second request landing during that wait
    local function duringFirstRead(inner)
        local real = MySQL.single
        local fired, out = false, nil
        MySQL.single = setmetatable({ await = function(q, p)
            if not fired and q:find('FROM bank_accounts_v2 WHERE id = ?', 1, true) then
                fired = true
                out = inner()
            end
            return real.await(q, p)
        end }, { __call = function(_, q, p, c) return real(q, p, c) end })
        return function() MySQL.single = real; return out end
    end

    it('a second member change on the same account during the first one\'s reads is refused', function()
        resetMembers({ FULL = { 1, 1, 1, 1 } })
        local done = duringFirstRead(function()
            return cb('updateMember', SRC.FULL, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(1, 1, 1, 0) })
        end)
        local first = cb('updateMember', SRC.OWNER, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(0, 0, 0, 0) })
        local second = done()
        assert_true(first.success)
        assert_false(second.success, 'the overlapping change waits its turn')
        assert_true(second.message:find('in progress', 1, true) ~= nil, second.message)
        assert_eq(bits(row('PLAIN')), '0000')
        -- once the first is done the next one runs
        assert_true(cb('updateMember', SRC.OWNER, { accountId = ACC, citizenid = CIDS.PLAIN, perms = perms(0, 1, 0, 0) }).success)
    end)

    it('adding a member while the owner closes the account is refused, and the same for removing', function()
        resetMembers()
        local done = duringFirstRead(function()
            return cb('addMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.ALT, perms = perms(0, 1, 0, 0) })
        end)
        local close = cb('accountDelete', SRC.OWNER, { accountId = ACC })
        local add = done()
        assert_false(close.success, 'not empty: nothing closed')
        assert_false(add.success)
        assert_eq(row('ALT'), nil)
        done = duringFirstRead(function() return cb('removeMember', SRC.BOOK, { accountId = ACC, citizenid = CIDS.PLAIN }) end)
        assert_true(cb('updateMember', SRC.OWNER, { accountId = ACC, citizenid = CIDS.CARDS, perms = perms(0, 1, 0, 0) }).success)
        assert_false(done().success)
        assert_true(row('PLAIN') ~= nil)
    end)

    it('a double click cannot issue more cards than the limit', function()
        resetMembers()
        for i = 1, (Config.MaxCardsPerAccount or 4) - 1 do
            MySQL.insert.await("INSERT INTO bank_account_cards (account_id, citizenid, holder_name, number, cvv, exp, design) VALUES (?, ?, 'Owner', ?, '123', '01/30', 'classic')", { ACC, CIDS.OWNER, '40000000000001' .. i })
        end
        local real = MySQL.scalar
        local fired, inner = false, nil
        MySQL.scalar = setmetatable({ await = function(q, p)
            if not fired and q:find('SELECT COUNT(*) FROM bank_account_cards WHERE account_id = ?', 1, true) then
                fired = true
                inner = cb('createCard', SRC.OWNER, { accountRef = ACC, design = 'gold' })
            end
            return real.await(q, p)
        end }, { __call = function(_, q, p, c) return real(q, p, c) end })
        local first = cb('createCard', SRC.OWNER, { accountRef = ACC, design = 'gold' })
        MySQL.scalar = real
        assert_true(first.success)
        assert_false(inner.success)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM bank_account_cards WHERE account_id = ? AND cancelled = 0', { ACC })), Config.MaxCardsPerAccount or 4)
        -- personal cards keep working
        assert_true(cb('createCard', SRC.PLAIN, { accountRef = 'personal', design = 'classic' }).success)
    end)
end)

describe('X-9: account cards', function()
    local cards = {}
    local function seedCards()
        resetMembers()
        cards = {}
        for _, key in ipairs({ 'OWNER', 'MGR2', 'PLAIN', 'CARDS', 'BOOK' }) do
            cards[key] = MySQL.insert.await("INSERT INTO bank_account_cards (account_id, citizenid, holder_name, number, cvv, exp, design) VALUES (?, ?, ?, ?, '123', '01/30', 'classic')",
                { ACC, CIDS[key], key, '4999' .. CIDS[key]:sub(-4) .. '00000000' })
        end
    end
    local function card(key) return MySQL.single.await('SELECT locked, cancelled FROM bank_account_cards WHERE id = ?', { cards[key] }) end

    it('a member with card rights manages only their own cards', function()
        seedCards()
        assert_false(cb('toggleCardLock', SRC.CARDS, { cardId = cards.OWNER }).success)
        assert_false(cb('cancelCard', SRC.CARDS, { cardId = cards.OWNER }).success)
        assert_false(cb('cancelCard', SRC.CARDS, { cardId = cards.PLAIN }).success)
        assert_eq(tonumber(card('OWNER').locked), 0)
        assert_eq(tonumber(card('OWNER').cancelled), 0)
        assert_eq(tonumber(card('PLAIN').cancelled), 0)
        assert_true(cb('toggleCardLock', SRC.CARDS, { cardId = cards.CARDS }).success)
        assert_true(cb('cancelCard', SRC.CARDS, { cardId = cards.CARDS }).success)
        assert_eq(tonumber(card('CARDS').cancelled), 1)
        -- a member without card rights still manages their own card
        assert_true(cb('toggleCardLock', SRC.PLAIN, { cardId = cards.PLAIN }).success)
    end)

    it('a manager manages the cards of plain members, not those of the owner or another manager', function()
        seedCards()
        assert_true(cb('toggleCardLock', SRC.BOOK, { cardId = cards.PLAIN }).success)
        assert_eq(tonumber(card('PLAIN').locked), 1)
        assert_true(cb('cancelCard', SRC.BOOK, { cardId = cards.CARDS }).success)
        assert_false(cb('cancelCard', SRC.BOOK, { cardId = cards.OWNER }).success)
        assert_false(cb('toggleCardLock', SRC.BOOK, { cardId = cards.MGR2 }).success)
        assert_eq(tonumber(card('OWNER').cancelled), 0)
        assert_eq(tonumber(card('MGR2').locked), 0)
    end)

    it('the owner manages every card on the account', function()
        seedCards()
        assert_true(cb('cancelCard', SRC.OWNER, { cardId = cards.MGR2 }).success)
        assert_true(cb('toggleCardLock', SRC.OWNER, { cardId = cards.BOOK }).success)
        assert_eq(tonumber(card('MGR2').cancelled), 1)
        assert_eq(tonumber(card('BOOK').locked), 1)
        -- nobody manages a stranger's personal card
        local personal = MySQL.insert.await("INSERT INTO bank_account_cards (account_id, citizenid, holder_name, number, cvv, exp, design) VALUES (NULL, ?, 'Alt', '4111000000000009', '123', '01/30', 'classic')", { CIDS.ALT })
        assert_false(cb('cancelCard', SRC.OWNER, { cardId = personal }).success)
    end)
end)

describe('what the screens are told (the UI offers only what the server allows)', function()
    local function snapshot(src)
        local snap = cb('getAccountsData', src)
        for _, a in ipairs(snap.accounts) do if a.id == ACC then return a end end
    end
    local function memberOf(list, key)
        for _, m in ipairs(list or {}) do if m.citizenid == CIDS[key] then return m end end
    end

    it('the bank screen gets per-row rules for a manager who is not the owner', function()
        resetMembers()
        local a = snapshot(SRC.BOOK)
        local me, mgr, plain, owner = memberOf(a.members, 'BOOK'), memberOf(a.members, 'MGR2'), memberOf(a.members, 'PLAIN'), memberOf(a.members, 'OWNER')
        assert_false(me.canEdit, 'not their own row')
        assert_true(me.canRemove, 'but they may leave')
        assert_false(mgr.canEdit)
        assert_false(mgr.canRemove)
        assert_false(owner.canEdit)
        assert_true(plain.canEdit)
        assert_true(plain.canRemove)
        assert_true(plain.canSet.can_deposit)
        assert_false(plain.canSet.can_withdraw)
        assert_false(plain.canSet.can_cards)
        assert_false(plain.canSet.can_manage)
        assert_false(a.newMemberRights.can_withdraw)
        assert_true(a.newMemberRights.can_deposit)
        -- every card on the account, flagged
        local byHolder = {}
        MySQL.insert.await("INSERT INTO bank_account_cards (account_id, citizenid, holder_name, number, cvv, exp, design) VALUES (?, ?, 'Owner', '4000000000000099', '123', '01/30', 'classic'), (?, ?, 'Plain', '4000000000000098', '123', '01/30', 'classic')", { ACC, CIDS.OWNER, ACC, CIDS.PLAIN })
        a = snapshot(SRC.BOOK)
        for _, c in ipairs(a.cards) do byHolder[c.citizenid] = c end
        assert_false(byHolder[CIDS.OWNER].canManage)
        assert_true(byHolder[CIDS.PLAIN].canManage)
        -- a member with card rights only sees their own cards
        local c = snapshot(SRC.CARDS)
        assert_eq(c.members, nil)
        for _, cardRow in ipairs(c.cards) do assert_eq(cardRow.citizenid, CIDS.CARDS) end
        -- the owner may change everything but their own row
        local o = snapshot(SRC.OWNER)
        assert_true(memberOf(o.members, 'MGR2').canEdit)
        assert_true(memberOf(o.members, 'MGR2').canSet.can_manage)
        assert_false(memberOf(o.members, 'OWNER').canEdit)
    end)

    it('the Bank app gets the same rules', function()
        resetMembers()
        local ov = rpc(SRC.BOOK, 'overview', {})
        assert_true(ov.ok)
        local a
        for _, x in ipairs(ov.accounts) do if x.id == ACC then a = x end end
        local me, mgr, plain = memberOf(a.members, 'BOOK'), memberOf(a.members, 'MGR2'), memberOf(a.members, 'PLAIN')
        assert_true(me.self)
        assert_false(me.edit)
        assert_true(me.remove)
        assert_false(mgr.edit)
        assert_false(mgr.remove)
        assert_true(plain.edit)
        assert_true(plain.grant.deposit)
        assert_false(plain.grant.withdraw)
        assert_false(plain.grant.manage)
        assert_true(noMismatches())
    end)
end)
