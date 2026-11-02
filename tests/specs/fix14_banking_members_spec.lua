-- Batch 14, BANK-1 / X-9 on the fake database (the full matrix runs on a real database in
-- realdb_specs/fix14_banking_members_realdb_spec.lua): a manager who is not the owner cannot raise their
-- own rights or hand out rights they lack, member changes on one account run one at a time from before
-- the first read, and a member with card rights cannot switch off the owner's card.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetCurrentResourceName() return 'pfm-banking' end

Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
load_resource('pfm-banking/server_accounts.lua')
load_resource('pfm-banking/server_finance.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
local L = PFLedger

local OWNER, BOOK, PLAIN = 1, 2, 3
local ACC
local cards = {}
local onAccountRead -- set by a test: runs inside the first account read, like a request landing during that wait

local function findMember(id, cid)
    for i, m in ipairs(FakeDB.members) do if m.account_id == tonumber(id) and m.citizenid == cid then return m, i end end
end
FakeDB.extraPatterns = {
    { 'SELECT * FROM bank_accounts_v2 WHERE id = ?', function(p)
        local hook = onAccountRead
        if hook then onAccountRead = nil; hook() end
        return FakeDB.v2[tonumber(p[1])]
    end },
    { 'UPDATE bank_account_members SET can_withdraw = ?', function(p)
        local m = findMember(p[5], p[6])
        if not m then return 0 end
        m.can_withdraw, m.can_deposit, m.can_cards, m.can_manage = p[1], p[2], p[3], p[4]
        return 1
    end },
    { 'INSERT INTO bank_account_members (account_id, citizenid, name, can_withdraw, can_deposit, can_cards, can_manage) VALUES (?, ?, ?, ?', function(p)
        FakeDB.members[#FakeDB.members + 1] = { account_id = p[1], citizenid = p[2], name = p[3], can_withdraw = p[4], can_deposit = p[5], can_cards = p[6], can_manage = p[7] }
        return 1
    end },
    { 'SELECT charinfo FROM players WHERE citizenid = ?', function(p) return p[1] == 'ALT1' and '{"firstname":"Al","lastname":"Alt"}' or nil end },
    { 'SELECT * FROM bank_account_cards WHERE id = ? AND cancelled = 0', function(p)
        for _, c in pairs(cards) do if c.id == tonumber(p[1]) and c.cancelled == 0 then return c end end
    end },
    { 'UPDATE bank_account_cards SET cancelled = 1 WHERE id = ?', function(p)
        for _, c in pairs(cards) do if c.id == tonumber(p[1]) then c.cancelled = 1 end end
        return 1
    end },
    { 'UPDATE bank_account_cards SET locked = ?', function(p)
        for _, c in pairs(cards) do if c.id == tonumber(p[2]) then c.locked = p[1] end end
        return 1
    end },
}

local function cb(name, src, data) return Mock.callCallback('qb-banking:server:' .. name, src, data) end
local function bitsOf(cid)
    local m = findMember(ACC, cid)
    return m and (m.can_withdraw .. m.can_deposit .. m.can_cards .. m.can_manage) or 'none'
end
local function perms(w, d, c, m) return { can_withdraw = w == 1, can_deposit = d == 1, can_cards = c == 1, can_manage = m == 1 } end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    FakeDB.migrations = {}
    Mock.players = {}
    onAccountRead = nil
    for src, cid in pairs({ [OWNER] = 'OW1', [BOOK] = 'BK1', [PLAIN] = 'PL1' }) do
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.money = { cash = 0, bank = 1000 }
    end
    ACC = FakeDB.ibanAccount('OW1', 5000, 'Bakery')
    FakeDB.member(ACC, 'BK1', { d = 1, w = 0 })
    findMember(ACC, 'BK1').can_manage = 1 -- a bookkeeper: manages, may not withdraw
    FakeDB.member(ACC, 'PL1', { d = 1, w = 0 })
    findMember(ACC, 'PL1').can_cards = 1
    cards = {
        owner = { id = 1, account_id = ACC, citizenid = 'OW1', locked = 0, cancelled = 0 },
        plain = { id = 2, account_id = ACC, citizenid = 'PL1', locked = 0, cancelled = 0 },
    }
    L.ready, L.failed = false, false
    assert(L.Start(), 'ledger start')
end

describe('BANK-1 on the fake database', function()
    it('a bookkeeper cannot give themselves withdraw, nor withdraw the balance', function()
        assert_false(cb('updateMember', BOOK, { accountId = ACC, citizenid = 'BK1', perms = perms(1, 1, 1, 1) }).success)
        assert_eq(bitsOf('BK1'), '0101')
        assert_false(cb('accountWithdraw', BOOK, { accountId = ACC, amount = 5000 }).success)
        assert_eq(FakeDB.v2[ACC].balance, 5000)
    end)

    it('a bookkeeper cannot add an alt with withdraw or management, but may add a depositor', function()
        assert_false(cb('addMember', BOOK, { accountId = ACC, citizenid = 'ALT1', perms = perms(1, 1, 0, 0) }).success)
        assert_false(cb('addMember', BOOK, { accountId = ACC, citizenid = 'ALT1', perms = perms(0, 1, 0, 1) }).success)
        assert_eq(bitsOf('ALT1'), 'none')
        assert_true(cb('addMember', BOOK, { accountId = ACC, citizenid = 'ALT1', perms = perms(0, 1, 0, 0) }).success)
        assert_eq(bitsOf('ALT1'), '0100')
    end)

    it('the owner may grant every right', function()
        assert_true(cb('updateMember', OWNER, { accountId = ACC, citizenid = 'BK1', perms = perms(1, 1, 1, 1) }).success)
        assert_eq(bitsOf('BK1'), '1111')
        assert_true(cb('accountWithdraw', BOOK, { accountId = ACC, amount = 100 }).success, 'then the bookkeeper may withdraw')
    end)

    it('a second change landing during the first one\'s account read is refused', function()
        local second
        onAccountRead = function()
            second = cb('updateMember', OWNER, { accountId = ACC, citizenid = 'PL1', perms = perms(1, 1, 1, 0) })
        end
        assert_true(cb('updateMember', OWNER, { accountId = ACC, citizenid = 'PL1', perms = perms(0, 0, 0, 0) }).success)
        assert_false(second.success)
        assert_eq(bitsOf('PL1'), '0000')
    end)

    it('a rights change is logged with before and after', function()
        assert_true(cb('updateMember', OWNER, { accountId = ACC, citizenid = 'PL1', perms = perms(1, 1, 1, 0) }).success)
        local found
        for _, e in ipairs(Mock.serverEvents) do
            if e.name == 'qb-log:server:CreateLog' and e.args[2] == 'Member Rights Changed' then found = e.args[4] end
        end
        assert_true(found ~= nil and found:find('deposit, cards -> withdraw, deposit, cards', 1, true) ~= nil, tostring(found))
    end)
end)

describe('X-9 on the fake database', function()
    it('a member with card rights cannot lock or cancel the owner\'s card, only their own', function()
        assert_false(cb('toggleCardLock', PLAIN, { cardId = 1 }).success)
        assert_false(cb('cancelCard', PLAIN, { cardId = 1 }).success)
        assert_eq(cards.owner.locked, 0)
        assert_eq(cards.owner.cancelled, 0)
        assert_true(cb('cancelCard', PLAIN, { cardId = 2 }).success)
        assert_eq(cards.plain.cancelled, 1)
    end)

    it('a manager may lock a plain member\'s card but not the owner\'s', function()
        assert_true(cb('toggleCardLock', BOOK, { cardId = 2 }).success)
        assert_false(cb('toggleCardLock', BOOK, { cardId = 1 }).success)
        assert_true(cb('cancelCard', OWNER, { cardId = 2 }).success, 'the owner may')
    end)
end)
