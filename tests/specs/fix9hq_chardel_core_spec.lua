-- Character deletion (pfm-core/server/player.lua) with pfm-banking's debt check
-- (pfm-banking/server_characters.lua), on the fake database:
--   * a character that is loaded (by anyone) or being loaded cannot be deleted, and a character being
--     deleted cannot be loaded (its loaded copy's next save would re-create it with its money);
--   * a player cannot delete a character that owes the bank (active loan, card balance, overdrawn
--     bank), so loans taken on an alt cannot be written off by deleting it; fail closed when the bank
--     check errors, allowed when pfm-banking is not running;
--   * the admin force delete still works with debt, writes it off and logs it;
--   * the cleanup event carries the plates the character owned (read before player_vehicles goes).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')

local bankState = 'started'
function GetResourceState(name)
    if name == 'pfm-banking' then return bankState end
    return 'missing'
end

-- ── the fake tables this spec needs ──────────────────────────────────────────
local db
local hooks = {}
local function resetDb()
    db = {
        players = {
            ALT1 = { license = 'license:1', money = '{"bank":5000,"cash":10}' },
            MAIN1 = { license = 'license:1', money = '{"bank":100,"cash":0}' },
            OTHER2 = { license = 'license:2', money = '{"bank":0,"cash":0}' },
        },
        vehicles = { { citizenid = 'ALT1', plate = 'ALT00001' }, { citizenid = 'ALT1', plate = 'ALT00002' }, { citizenid = 'MAIN1', plate = 'MAIN0001' } },
        apartments = { { citizenid = 'ALT1', name = 'apartment1234' } },
        deleted = {},
        transactions = 0,
    }
    FakeDB.loans, FakeDB.cards = {}, {}
    hooks = {}
end

local function countWhere(list, cid, pred)
    local n, sum = 0, 0
    for _, r in ipairs(list) do
        if r.citizenid == cid and pred(r) then n = n + 1; sum = sum + (r.balance or 0) end
    end
    return n, sum
end

local frameworkTables = { 'players', 'apartments', 'bank_accounts', 'crypto_transactions', 'phone_invoices', 'phone_messages',
    'playerskins', 'player_contacts', 'player_houses', 'player_mails', 'player_outfits', 'player_vehicles' }

FakeDB.extraPatterns = {
    -- players.citizenid has a case-insensitive collation: 'alt1' finds the row of 'ALT1'
    { 'SELECT citizenid, license FROM players WHERE citizenid = ? LIMIT 1', function(p)
        if hooks.onLicenseLookup then local h = hooks.onLicenseLookup; hooks.onLicenseLookup = nil; h() end
        local cid = type(p[1]) == 'string' and p[1]:upper() or p[1]
        local row = db.players[cid]
        return row and { citizenid = cid, license = row.license } or nil
    end },
    { 'SELECT * FROM players where citizenid = ?', function(p)
        local cid = type(p[1]) == 'string' and p[1]:upper() or p[1]
        local row = db.players[cid]
        if not row then return nil end
        return { citizenid = cid, license = row.license, money = row.money, job = 'null', gang = 'null', position = 'null', metadata = '{}', charinfo = '{}' }
    end },
    { 'SELECT money FROM players WHERE citizenid = ? LIMIT 1', function(p)
        if hooks.bankError then error('bank db down') end
        local row = db.players[p[1]]
        return row and row.money or nil
    end },
    { 'SELECT name FROM apartments WHERE citizenid = ?', function(p)
        local out = {}
        for _, r in ipairs(db.apartments) do if r.citizenid == p[1] then out[#out + 1] = { name = r.name } end end
        return out
    end },
    { 'SELECT plate FROM player_vehicles WHERE citizenid = ?', function(p)
        local out = {}
        for _, r in ipairs(db.vehicles) do if r.citizenid == p[1] then out[#out + 1] = { plate = r.plate } end end
        return out
    end },
    { "FROM bank_loans WHERE citizenid = ? AND status = 'active'", function(p)
        local n, sum = countWhere(FakeDB.loans, p[1], function(l) return l.status == 'active' end)
        return { { n = n, owed = sum } }
    end },
    { "FROM bank_cards WHERE citizenid = ? AND status = 'active' AND balance > 0", function(p)
        local n, sum = countWhere(FakeDB.cards, p[1], function(c) return c.status == 'active' and c.balance > 0 end)
        return { { n = n, owed = sum } }
    end },
    { "UPDATE bank_loans SET status = 'written_off'", function(p)
        local n = 0
        for _, l in ipairs(FakeDB.loans) do if l.citizenid == p[1] and l.status == 'active' then l.status = 'written_off'; n = n + 1 end end
        return n
    end },
    { "UPDATE bank_cards SET status = 'written_off'", function(p)
        local n = 0
        for _, c in ipairs(FakeDB.cards) do if c.citizenid == p[1] and c.status == 'active' then c.status = 'written_off'; n = n + 1 end end
        return n
    end },
    -- the rest of the bank's cleanup: nothing of it matters here
    { 'SELECT id, balance, label FROM bank_accounts_v2 WHERE owner = ?', function() return {} end },
    { 'DELETE FROM bank_account_members WHERE citizenid = ?', function() return 0 end },
    { 'DELETE FROM bank_account_cards WHERE citizenid = ?', function() return 0 end },
    { 'DELETE FROM bank_personal_iban WHERE citizenid = ?', function() return 0 end },
    { 'DELETE FROM bank_credit WHERE citizenid = ?', function() return 0 end },
    { 'DELETE FROM bank_transactions WHERE account_ref = ?', function() return 0 end },
    { 'DELETE FROM bank_statements WHERE citizenid = ?', function() return 0 end },
}
for _, t in ipairs(frameworkTables) do
    table.insert(FakeDB.extraPatterns, { 'DELETE FROM ' .. t .. ' WHERE citizenid = ?', function(p)
        db.deleted[#db.deleted + 1] = t .. ':' .. p[1]
        if t == 'players' then db.players[p[1]] = nil end
        if t == 'player_vehicles' then
            for i = #db.vehicles, 1, -1 do if db.vehicles[i].citizenid == p[1] then table.remove(db.vehicles, i) end end
        end
        return 1
    end })
end
-- oxmysql's transaction (all statements or none)
MySQL.transaction = setmetatable({ await = function(queries)
    db.transactions = db.transactions + 1
    for _, q in ipairs(queries) do MySQL.update.await(q.query, q.values) end
    return true
end }, { __call = function(_, queries, cb) local r = MySQL.transaction.await(queries) if cb then cb(r) end end })

-- ── pfm-banking (its exports as pfm-core sees them) ──────────────────────────
function GetCurrentResourceName() return 'pfm-banking' end
load_resource('pfm-banking/server_characters.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
local bankCleanup = Mock.eventHandlers['pfm-core:server:characterDeleted']

-- every server resource listening for the cleanup event: the bank, plus a recorder
local events = {}
Mock.eventHandlers['pfm-core:server:characterDeleted'] = function(cid, deleted)
    events[#events + 1] = { cid = cid, deleted = deleted }
    bankCleanup(cid, deleted)
end
local logs = {}
Mock.eventHandlers['qb-log:server:CreateLog'] = function(name, title, color, msg) logs[#logs + 1] = { name = name, title = title, msg = msg } end

-- ── pfm-core ─────────────────────────────────────────────────────────────────
function GetCurrentResourceName() return 'pfm-core' end
QBCore = { Functions = {}, Config = { Player = { PlayerDefaults = {} } }, Shared = {}, ShowSuccess = function() end, ShowError = function() end }
function PaycheckInterval() end -- (pfm-core/server/functions.lua; the paycheck loop is not under test)
load_resource('pfm-core/server/player.lua')
function QBCore.Functions.GetIdentifier(src, kind) return (kind or 'license') .. ':' .. tostring(src) end
function QBCore.Functions.GetPlayerByCitizenId(cid) return QBCore.PlayersByCitizenId[cid] end
-- a login that got past the checks registers the character (CheckPlayerData does that for real)
local logins = 0
function QBCore.Player.CheckPlayerData(src, data)
    logins = logins + 1
    local p = { PlayerData = { source = src, citizenid = data.citizenid } }
    QBCore.Players[src] = p
    QBCore.PlayersByCitizenId[data.citizenid] = p
    return p
end

local function load(src, cid)
    local p = { PlayerData = { source = src, citizenid = cid } }
    QBCore.Players[src] = p
    QBCore.PlayersByCitizenId[cid] = p
    return p
end

local function deletedTables(cid)
    local n = 0
    for _, d in ipairs(db.deleted) do if d:sub(-#cid - 1) == ':' .. cid then n = n + 1 end end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.dropped = {}
    resetDb()
    events, logs, logins = {}, {}, 0
    bankState = 'started'
    for k in pairs(QBCore.Players) do QBCore.Players[k] = nil end
    for k in pairs(QBCore.PlayersByCitizenId) do QBCore.PlayersByCitizenId[k] = nil end
end

describe('a player deletes their own character', function()
    it('deletes an unloaded, debt-free character and passes its apartments and plates to the cleanup', function()
        local ok, why = QBCore.Player.DeleteCharacter(1, 'ALT1')
        assert_true(ok, 'deleted (' .. tostring(why) .. ')')
        assert_eq(deletedTables('ALT1'), #frameworkTables)
        assert_eq(#events, 1)
        assert_eq(events[1].cid, 'ALT1')
        assert_eq(#events[1].deleted.plates, 2)
        assert_eq(events[1].deleted.plates[1], 'ALT00001')
        assert_eq(events[1].deleted.apartments[1], 'apartment1234')
        assert_eq(#Mock.dropped, 0)
    end)

    it('refuses the character the caller is playing (its next save would re-create it with its money)', function()
        load(1, 'ALT1')
        local ok, why = QBCore.Player.DeleteCharacter(1, 'ALT1')
        assert_false(ok)
        assert_eq(why, 'character_in_use')
        assert_eq(db.transactions, 0)
        assert_eq(#events, 0)
        assert_true(db.players.ALT1 ~= nil)
    end)

    it('refuses a character loaded on another server id', function()
        load(7, 'ALT1')
        local ok, why = QBCore.Player.DeleteCharacter(1, 'ALT1')
        assert_false(ok)
        assert_eq(why, 'character_in_use')
        assert_eq(db.transactions, 0)
    end)

    it('a login of the character while its delete waits on the database is refused', function()
        local loginResult
        hooks.onLicenseLookup = function() loginResult = QBCore.Player.Login(1, 'ALT1') end
        local ok = QBCore.Player.DeleteCharacter(1, 'ALT1')
        assert_true(ok)
        assert_eq(loginResult, false)
        assert_eq(logins, 0)
        assert_eq(QBCore.PlayersByCitizenId.ALT1, nil)
        -- the lock is released afterwards: the remaining character still logs in
        assert_true(QBCore.Player.Login(1, 'MAIN1'))
    end)

    it('a delete while the character is being loaded is refused', function()
        local result
        local realCheck = QBCore.Player.CheckPlayerData
        QBCore.Player.CheckPlayerData = function(src, data)
            -- still loading: the delete arrives now
            result = { QBCore.Player.DeleteCharacter(src, 'ALT1') }
            return realCheck(src, data)
        end
        assert_true(QBCore.Player.Login(1, 'ALT1'))
        QBCore.Player.CheckPlayerData = realCheck
        assert_false(result[1])
        assert_eq(result[2], 'character_in_use')
        assert_eq(db.transactions, 0)
    end)

    it('another license\'s character is not deleted and the caller is dropped', function()
        local ok, why = QBCore.Player.DeleteCharacter(1, 'OTHER2')
        assert_false(ok)
        assert_eq(why, 'not_owner')
        assert_eq(#Mock.dropped, 1)
        assert_eq(db.transactions, 0)
    end)

    it('rejects a citizenid that is not a string', function()
        local ok, why = QBCore.Player.DeleteCharacter(1, { 'ALT1' })
        assert_false(ok)
        assert_eq(why, 'invalid_character')
    end)
end)

describe('a citizenid in another case (the database matches it case-insensitively)', function()
    it('a lower-case id of the character the caller is playing is refused', function()
        load(1, 'ALT1')
        local ok, why = QBCore.Player.DeleteCharacter(1, 'alt1')
        assert_false(ok)
        assert_eq(why, 'character_in_use')
        assert_eq(db.transactions, 0)
        assert_eq(#events, 0)
        assert_true(db.players.ALT1 ~= nil)
    end)

    it('a lower-case id of an unloaded character is refused, not deleted', function()
        local ok, why = QBCore.Player.DeleteCharacter(1, 'alt1')
        assert_false(ok)
        assert_eq(why, 'invalid_character')
        assert_eq(db.transactions, 0)
        assert_eq(#Mock.dropped, 0)
    end)

    it('a login in another case while the delete waits on the database is refused', function()
        local loginResult
        hooks.onLicenseLookup = function() loginResult = QBCore.Player.Login(1, 'alt1') end
        assert_true(QBCore.Player.DeleteCharacter(1, 'ALT1'))
        assert_eq(loginResult, false)
        assert_eq(logins, 0)
    end)

    it('a delete in another case while the character is being loaded is refused', function()
        local result
        local realCheck = QBCore.Player.CheckPlayerData
        QBCore.Player.CheckPlayerData = function(src, data)
            result = { QBCore.Player.DeleteCharacter(src, 'alt1') }
            return realCheck(src, data)
        end
        assert_true(QBCore.Player.Login(1, 'ALT1'))
        QBCore.Player.CheckPlayerData = realCheck
        assert_false(result[1])
        assert_eq(result[2], 'character_in_use')
        assert_eq(db.transactions, 0)
    end)

    it('only the stored spelling logs in', function()
        assert_false(QBCore.Player.Login(1, 'alt1'))
        assert_eq(logins, 0)
        assert_eq(QBCore.Players[1], nil)
        assert_true(QBCore.Player.Login(1, 'ALT1'))
    end)

    it('an id that is not plain letters and digits is refused (trailing spaces match under the collation)', function()
        local ok, why = QBCore.Player.DeleteCharacter(1, 'ALT1 ')
        assert_false(ok)
        assert_eq(why, 'invalid_character')
        assert_false(QBCore.Player.Login(1, 'ALT1 '))
        local fok, fwhy = QBCore.Player.ForceDeleteCharacter('ALT1 ')
        assert_false(fok)
        assert_eq(fwhy, 'invalid_character')
        assert_eq(db.transactions, 0)
    end)

    it('an admin force delete typed in lower case drops the player using it and deletes the stored id', function()
        load(3, 'ALT1')
        local ok, why = QBCore.Player.ForceDeleteCharacter('alt1')
        assert_true(ok, 'force deleted (' .. tostring(why) .. ')')
        assert_eq(#Mock.dropped, 1)
        assert_eq(Mock.dropped[1].src, 3)
        assert_eq(QBCore.Players[3], nil)
        assert_eq(QBCore.PlayersByCitizenId.ALT1, nil)
        assert_eq(deletedTables('ALT1'), #frameworkTables)
        assert_eq(events[1].cid, 'ALT1')
    end)
end)

describe('unpaid bank debt blocks a player delete', function()
    it('refuses with an active loan (the alt-character loan exploit), and keeps the loan', function()
        FakeDB.loans[1] = { id = 1, citizenid = 'ALT1', status = 'active', balance = 25000 }
        local ok, why = QBCore.Player.DeleteCharacter(1, 'ALT1')
        assert_false(ok)
        assert_eq(why, 'unpaid_debt')
        assert_eq(db.transactions, 0)
        assert_eq(#events, 0)
        assert_eq(FakeDB.loans[1].status, 'active')
    end)

    it('refuses with a credit card balance; a paid-off card does not block', function()
        FakeDB.cards[1] = { id = 1, citizenid = 'ALT1', status = 'active', balance = 300 }
        local ok, why = QBCore.Player.DeleteCharacter(1, 'ALT1')
        assert_false(ok)
        assert_eq(why, 'unpaid_debt')
        FakeDB.cards[1].balance = 0
        assert_true(QBCore.Player.DeleteCharacter(1, 'ALT1'))
    end)

    it('refuses with an overdrawn bank balance', function()
        db.players.ALT1.money = '{"bank":-50,"cash":0}'
        local ok, why = QBCore.Player.DeleteCharacter(1, 'ALT1')
        assert_false(ok)
        assert_eq(why, 'unpaid_debt')
    end)

    it('a paid or written-off loan of the past does not block', function()
        FakeDB.loans[1] = { id = 1, citizenid = 'ALT1', status = 'paid', balance = 0 }
        assert_true(QBCore.Player.DeleteCharacter(1, 'ALT1'))
    end)

    it('fails closed when the bank check errors', function()
        hooks.bankError = true
        local ok, why = QBCore.Player.DeleteCharacter(1, 'ALT1')
        assert_false(ok)
        assert_eq(why, 'bank_unavailable')
        assert_eq(db.transactions, 0)
    end)

    it('fails closed while pfm-banking is starting', function()
        bankState = 'starting'
        local ok, why = QBCore.Player.DeleteCharacter(1, 'ALT1')
        assert_false(ok)
        assert_eq(why, 'bank_unavailable')
    end)

    it('allows the delete when pfm-banking is not running (nothing of the bank is written off then)', function()
        bankState = 'missing'
        FakeDB.loans[1] = { id = 1, citizenid = 'ALT1', status = 'active', balance = 25000 }
        Mock.eventHandlers['pfm-core:server:characterDeleted'] = function(cid, deleted) events[#events + 1] = { cid = cid } end
        local ok = QBCore.Player.DeleteCharacter(1, 'ALT1')
        Mock.eventHandlers['pfm-core:server:characterDeleted'] = function(cid, deleted)
            events[#events + 1] = { cid = cid, deleted = deleted }
            bankCleanup(cid, deleted)
        end
        assert_true(ok)
        assert_eq(FakeDB.loans[1].status, 'active')
    end)

    it('the export answers for other server code', function()
        FakeDB.loans[1] = { id = 1, citizenid = 'ALT1', status = 'active', balance = 25000 }
        local ok, why = exports['pfm-banking']:CanDeleteCharacter('ALT1')
        assert_false(ok)
        assert_eq(why, 'unpaid_debt')
        assert_true(exports['pfm-banking']:CanDeleteCharacter('MAIN1'))
        assert_false(exports['pfm-banking']:CanDeleteCharacter("x' OR 1=1"))
    end)
end)

describe('admin force delete', function()
    it('deletes a character with debt, writes the debt off and logs it', function()
        FakeDB.loans[1] = { id = 1, citizenid = 'ALT1', status = 'active', balance = 25000 }
        FakeDB.cards[1] = { id = 1, citizenid = 'ALT1', status = 'active', balance = 300 }
        local ok, why = QBCore.Player.ForceDeleteCharacter('ALT1')
        assert_true(ok, 'force deleted (' .. tostring(why) .. ')')
        assert_eq(deletedTables('ALT1'), #frameworkTables)
        assert_eq(FakeDB.loans[1].status, 'written_off')
        assert_eq(FakeDB.cards[1].status, 'written_off')
        local writeOff, forceLog
        for _, l in ipairs(logs) do
            if l.title == 'Debt Written Off' then writeOff = l end
            if l.title == 'Character Force Deleted' then forceLog = l end
        end
        assert_true(writeOff ~= nil, 'write-off logged')
        assert_true(writeOff.msg:find('ALT1', 1, true) ~= nil)
        assert_true(writeOff.msg:find('25000', 1, true) ~= nil)
        assert_true(forceLog ~= nil and forceLog.msg:find('unpaid_debt', 1, true) ~= nil, 'force delete log names the debt')
    end)

    it('drops the player using the character first and keeps it from being saved back', function()
        load(3, 'ALT1')
        assert_true(QBCore.Player.ForceDeleteCharacter('ALT1'))
        assert_eq(#Mock.dropped, 1)
        assert_eq(Mock.dropped[1].src, 3)
        assert_eq(QBCore.Players[3], nil)
        assert_eq(QBCore.PlayersByCitizenId.ALT1, nil)
        assert_eq(#events, 1)
        assert_eq(#events[1].deleted.plates, 2)
    end)

    it('an unknown character is reported, not deleted', function()
        local ok, why = QBCore.Player.ForceDeleteCharacter('NOPE1')
        assert_false(ok)
        assert_eq(why, 'not_found')
        assert_eq(db.transactions, 0)
    end)

    it('a normal delete has no write-off to log', function()
        assert_true(QBCore.Player.DeleteCharacter(1, 'ALT1'))
        for _, l in ipairs(logs) do assert_true(l.title ~= 'Debt Written Off') end
    end)
end)

describe('the bank cleanup event', function()
    it('ignores a call from a player', function()
        FakeDB.loans[1] = { id = 1, citizenid = 'ALT1', status = 'active', balance = 25000 }
        Mock.fireEvent('pfm-core:server:characterDeleted', 5, 'ALT1')
        assert_eq(FakeDB.loans[1].status, 'active')
    end)
end)
