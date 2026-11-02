-- qb-banking multi-account module: shared/business accounts, members, debit cards, IBAN transfers.
-- Tables are created by the pfm-banking ledger migration (server_ledger.lua, v2). Every balance change
-- goes through PFLedger.Transfer: account refs are acct:<id> for these accounts and
-- player:<citizenid>:bank for personal balances. bank_transactions is the per-account history shown
-- in the UI; pf_transactions is the authoritative record.
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local L = PFLedger

-- Every callback is also kept in BankingCallbacks, so the Bank app (server_app.lua) runs the very same
-- code as the bank screen.
BankingCallbacks = BankingCallbacks or {}
local function callback(name, fn)
    BankingCallbacks[name] = fn
    QBCore.Functions.CreateCallback(name, fn)
end

-- ── helpers ──────────────────────────────────────────────────────────
local function getPlayer(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return nil, nil end
    return Player, Player.PlayerData.citizenid
end

local function playerName(Player)
    local ci = Player.PlayerData.charinfo
    return (ci.firstname or '') .. ' ' .. (ci.lastname or '')
end

local function sanitizeAmount(amount)
    local n = tonumber(amount)
    if not n then return nil end
    n = math.floor(n)
    if n < 1 or n > 1000000000000 then return nil end
    return n
end

local function sanitizeNote(note)
    if type(note) ~= 'string' then return nil end
    note = note:gsub('[\r\n]', ' ')
    if #note > 100 then note = note:sub(1, 100) end
    if note == '' then return nil end
    return note
end

local function randomDigits(count)
    local out = {}
    for i = 1, count do out[i] = tostring(math.random(0, 9)) end
    return table.concat(out)
end

local function generateIban()
    for _ = 1, 25 do
        local iban = 'PF' .. randomDigits(8)
        local existsAcc = MySQL.scalar.await('SELECT 1 FROM bank_accounts_v2 WHERE iban = ?', { iban })
        local existsPers = MySQL.scalar.await('SELECT 1 FROM bank_personal_iban WHERE iban = ?', { iban })
        if not existsAcc and not existsPers then return iban end
    end
    return nil
end

local function getPersonalIban(citizenid)
    local iban = MySQL.scalar.await('SELECT iban FROM bank_personal_iban WHERE citizenid = ?', { citizenid })
    if iban then return iban end
    iban = generateIban()
    if not iban then return nil end
    local ok = MySQL.insert.await('INSERT IGNORE INTO bank_personal_iban (citizenid, iban) VALUES (?, ?)', { citizenid, iban })
    if not ok then -- lost a race; read whatever won
        return MySQL.scalar.await('SELECT iban FROM bank_personal_iban WHERE citizenid = ?', { citizenid })
    end
    return MySQL.scalar.await('SELECT iban FROM bank_personal_iban WHERE citizenid = ?', { citizenid })
end

-- returns account row (or nil) plus the caller's effective permissions on it
local function getAccountAccess(accountId, citizenid)
    accountId = tonumber(accountId)
    if not accountId then return nil, nil end
    local account = MySQL.single.await('SELECT * FROM bank_accounts_v2 WHERE id = ?', { accountId })
    if not account then return nil, nil end
    if account.owner == citizenid then
        return account, { isOwner = true, can_withdraw = 1, can_deposit = 1, can_cards = 1, can_manage = 1 }
    end
    local member = MySQL.single.await('SELECT * FROM bank_account_members WHERE account_id = ? AND citizenid = ?', { accountId, citizenid })
    if not member then return account, nil end
    return account, {
        isOwner = false,
        can_withdraw = member.can_withdraw,
        can_deposit = member.can_deposit,
        can_cards = member.can_cards,
        can_manage = member.can_manage,
    }
end

local function logTx(accountRef, actor, actorName, txType, amount, note)
    MySQL.insert('INSERT INTO bank_transactions (account_ref, actor, actor_name, type, amount, note) VALUES (?, ?, ?, ?, ?, ?)', {
        accountRef, actor, actorName, txType, amount, note,
    })
end

local function getTransactions(accountRef)
    return MySQL.query.await([[SELECT id, account_ref, actor, actor_name, type, amount, note,
        UNIX_TIMESTAMP(created_at) * 1000 AS created_at
        FROM bank_transactions WHERE account_ref = ? ORDER BY id DESC LIMIT 20]], { accountRef }) or {}
end

local function perm(p, key)
    return p and (p.isOwner or (tonumber(p[key]) or 0) == 1) or false
end

local function personalRef(citizenid) return 'player:' .. citizenid .. ':bank' end
local function accountRef(id) return 'acct:' .. id end

-- Runs a money callback under the player's lock so a double-click cannot run it twice at once.
local function locked(citizenid, cb, fn)
    local status = L.WithLock('bank:' .. citizenid, fn)
    if status == 'busy' then cb({ success = false, message = 'Please wait for your last transaction' })
    elseif status == 'error' then cb({ success = false, message = 'Error' }) end
end

-- Member, card and close-account changes on one account run one at a time. The lock is taken before
-- the first database read: the checks read member rows, and a second change landing during those
-- reads (two managers at once, a double click) would be checked against rows about to change.
-- fn gets the account id as an integer.
local function accountLocked(accountId, cb, fn)
    local n = tonumber(accountId)
    local id = n and math.tointeger(n)
    if not id or id < 1 or id > 2147483647 then return cb({ success = false, message = 'No permission' }) end
    local status = L.WithLock('bankacct:' .. id, function() fn(id) end)
    if status == 'busy' then cb({ success = false, message = 'Another change to this account is in progress, try again' })
    elseif status == 'error' then cb({ success = false, message = 'Error' }) end
end

-- ── who may change whom ──────────────────────────────────────────────
-- The owner may do anything on their account (their own row always stays full access).
-- A member with can_manage who is not the owner:
--   * cannot change their own row (they may still leave the account);
--   * cannot add, change or remove a member who has can_manage;
--   * cannot grant or take away can_manage: only the owner hands out management;
--   * may set can_withdraw / can_cards only when they hold that right themselves, so a bookkeeper
--     without withdraw cannot pass it to a friend or an alt and take the balance that way.
-- can_deposit only brings money in, so any manager may set it. Any member may leave.
-- Managers come first when a deleted owner's account is handed on (server_characters.lua): one more
-- reason a manager may not strip or remove the other managers.
local RIGHTS = { 'can_withdraw', 'can_deposit', 'can_cards', 'can_manage' }

local function isSet(v) return (tonumber(v) or 0) == 1 end

local function rights(w, d, c, m)
    return { can_withdraw = w == true, can_deposit = d == true, can_cards = c == true, can_manage = m == true }
end

--- What the caller (perms from getAccountAccess) may do to one member row; target nil = a new member.
--- { edit, remove, grant }: edit is "may change this row" (or "may add" for a new member); grant says
--- which rights the caller may switch on that row.
local function memberRules(account, perms, callerCid, target)
    local none = { edit = false, remove = false, grant = rights() }
    if not account or not perms then return none end
    local targetCid = target and target.citizenid or nil
    if targetCid ~= nil and targetCid == account.owner then return none end
    if targetCid ~= nil and targetCid == callerCid and not perms.isOwner then
        return { edit = false, remove = true, grant = rights() }
    end
    if not perm(perms, 'can_manage') then return none end
    if perms.isOwner then return { edit = true, remove = true, grant = rights(true, true, true, true) } end
    if target and isSet(target.can_manage) then return none end
    return { edit = true, remove = true, grant = rights(isSet(perms.can_withdraw), true, isSet(perms.can_cards), false) }
end

local REFUSED_RIGHT = {
    can_manage = 'Only the account owner can grant or remove management rights',
    can_withdraw = 'You can only change withdraw rights you hold yourself',
    can_cards = 'You can only change card rights you hold yourself',
    can_deposit = 'No permission',
}

--- nil when every right in `want` is one the caller may switch or stays as it was (`current` = the
--- member row, nil for a new member: every right off); else the message for the first one that may not.
local function refusedRight(rules, current, want)
    for _, key in ipairs(RIGHTS) do
        local before = current and (tonumber(current[key]) or 0) or 0
        if want[key] ~= before and not rules.grant[key] then return REFUSED_RIGHT[key] end
    end
    return nil
end

local function rightsText(row)
    local out = {}
    for _, key in ipairs(RIGHTS) do if isSet(row[key]) then out[#out + 1] = key:sub(5) end end
    return #out > 0 and table.concat(out, ', ') or 'none'
end

-- Who may lock or cancel a card: its holder always; on an account also the owner (every card) and a
-- manager (cards of members without can_manage: the same line as for member changes). can_cards alone
-- lets a member issue and manage their own cards, not switch off other people's.
local function mayManageCard(card, account, perms, citizenid, holderIsManager)
    if card.citizenid == citizenid then return true end
    if not account or not perms then return false end
    if perms.isOwner then return true end
    if not perm(perms, 'can_manage') then return false end
    return card.citizenid ~= account.owner and not holderIsManager
end

-- ── snapshot callback ────────────────────────────────────────────────
callback('qb-banking:server:getAccountsData', function(source, cb)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb(nil) end
    local myName = playerName(Player)

    local personalIban = getPersonalIban(citizenid)
    local personal = {
        balance = Player.PlayerData.money.bank,
        iban = personalIban,
        transactions = getTransactions('personal:' .. citizenid),
    }

    local rows = MySQL.query.await([[SELECT * FROM bank_accounts_v2
        WHERE owner = ? OR id IN (SELECT account_id FROM bank_account_members WHERE citizenid = ?)
        ORDER BY id ASC]], { citizenid, citizenid }) or {}

    local accounts = {}
    for _, acc in ipairs(rows) do
        local _, perms = getAccountAccess(acc.id, citizenid)
        if perms then
            local entry = {
                id = acc.id,
                iban = acc.iban,
                label = acc.label,
                type = acc.type,
                balance = acc.balance,
                color = acc.color,
                owner = acc.owner,
                isOwner = perms.isOwner,
                myPerms = perms,
                transactions = getTransactions('acc:' .. acc.id),
            }
            local manager = perm(perms, 'can_manage')
            local managers = {}
            if manager then
                entry.members = MySQL.query.await('SELECT citizenid, name, can_withdraw, can_deposit, can_cards, can_manage FROM bank_account_members WHERE account_id = ?', { acc.id }) or {}
                -- what this viewer may change on each row, so the screen offers only what the server allows
                for _, m in ipairs(entry.members) do
                    local rules = memberRules(acc, perms, citizenid, m)
                    m.canEdit, m.canRemove, m.canSet = rules.edit, rules.remove, rules.grant
                    if isSet(m.can_manage) then managers[m.citizenid] = true end
                end
                entry.newMemberRights = memberRules(acc, perms, citizenid, nil).grant
            end
            -- managers see every card on the account; other members only their own
            if manager then
                entry.cards = MySQL.query.await('SELECT * FROM bank_account_cards WHERE account_id = ? AND cancelled = 0', { acc.id }) or {}
            else
                entry.cards = MySQL.query.await('SELECT * FROM bank_account_cards WHERE account_id = ? AND citizenid = ? AND cancelled = 0', { acc.id, citizenid }) or {}
            end
            for _, card in ipairs(entry.cards) do
                card.canManage = mayManageCard(card, acc, perms, citizenid, managers[card.citizenid] == true)
            end
            accounts[#accounts + 1] = entry
        end
    end

    local myCards = MySQL.query.await('SELECT * FROM bank_account_cards WHERE account_id IS NULL AND citizenid = ? AND cancelled = 0', { citizenid }) or {}
    for _, card in ipairs(myCards) do card.canManage = true end

    cb({ personal = personal, accounts = accounts, myCards = myCards, myName = myName, myCitizenid = citizenid })
end)

-- ── account lifecycle ────────────────────────────────────────────────
callback('qb-banking:server:createAccount', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}

    local label = type(data.label) == 'string' and data.label:gsub('[\r\n]', ''):sub(1, 30) or ''
    if label == '' then return cb({ success = false, message = 'Enter an account name' }) end
    local accType = data.type == 'business' and 'business' or (data.type == 'shared' and 'shared' or nil)
    if not accType then return cb({ success = false, message = 'Invalid account type' }) end

    locked(citizenid, cb, function()
        local owned = MySQL.scalar.await('SELECT COUNT(*) FROM bank_accounts_v2 WHERE owner = ?', { citizenid }) or 0
        if owned >= (Config.MaxOwnedAccounts or 3) then
            return cb({ success = false, message = ('You already own the maximum of %d accounts'):format(Config.MaxOwnedAccounts or 3) })
        end

        local iban = generateIban()
        if not iban then return cb({ success = false, message = 'Could not allocate an account number, try again' }) end

        local fee = tonumber(Config.AccountCreationFee or 500) or 0
        local feeTx
        if fee > 0 then
            feeTx = L.Transfer({
                from = personalRef(citizenid), to = 'system:bank_fees', amount = fee,
                key = L.AutoKey('acctfee'), kind = 'fee', reason = 'Account creation fee', actor = citizenid,
            })
            if not feeTx.ok then
                local msg = feeTx.error == 'insufficient_funds' and ('You need $%d in your bank for the creation fee'):format(fee) or L.Message(feeTx.error)
                return cb({ success = false, message = msg })
            end
        end

        local accountId = MySQL.insert.await('INSERT INTO bank_accounts_v2 (iban, label, type, owner) VALUES (?, ?, ?, ?)', { iban, label, accType, citizenid })
        if not accountId then
            if feeTx then
                L.Transfer({
                    from = 'system:bank_fees', to = personalRef(citizenid), amount = fee,
                    key = 'refund:' .. feeTx.txId, kind = 'refund', reason = 'Account creation refund', actor = citizenid,
                })
            end
            return cb({ success = false, message = 'Error creating the account' })
        end
        MySQL.insert.await(L.SQL.ensureBaseline, { accountRef(accountId), 0 })
        MySQL.insert('INSERT INTO bank_account_members (account_id, citizenid, name, can_withdraw, can_deposit, can_cards, can_manage) VALUES (?, ?, ?, 1, 1, 1, 1)', {
            accountId, citizenid, playerName(Player),
        })
        if fee > 0 then
            logTx('personal:' .. citizenid, citizenid, playerName(Player), 'fee', fee, 'Account creation fee (' .. label .. ')')
        end
        TriggerEvent('qb-log:server:CreateLog', 'banking', 'Account Created', 'green', ('**%s** opened %s account **%s** (%s)'):format(GetPlayerName(source), accType, label, iban))
        cb({ success = true, message = ('Account "%s" created — %s'):format(label, iban), accountId = accountId, iban = iban })
    end)
end)

callback('qb-banking:server:accountRename', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local label = type(data.label) == 'string' and data.label:gsub('[\r\n]', ''):sub(1, 30) or ''
    if label == '' then return cb({ success = false, message = 'Enter a name' }) end
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perm(perms, 'can_manage') then return cb({ success = false, message = 'No permission' }) end
    MySQL.update.await('UPDATE bank_accounts_v2 SET label = ? WHERE id = ?', { label, account.id })
    cb({ success = true, message = 'Account renamed' })
end)

callback('qb-banking:server:accountColor', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local color = type(data.color) == 'string' and data.color or ''
    if not color:match('^#%x%x%x%x%x%x$') then return cb({ success = false, message = 'Invalid color' }) end
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perm(perms, 'can_manage') then return cb({ success = false, message = 'No permission' }) end
    MySQL.update.await('UPDATE bank_accounts_v2 SET color = ? WHERE id = ?', { color, account.id })
    cb({ success = true, message = 'Color updated' })
end)

callback('qb-banking:server:accountDelete', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = type(data) == 'table' and data or {}
    -- under the account lock, so a member being added meanwhile cannot outlive the account
    accountLocked(data.accountId, cb, function(accountId)
        local account, perms = getAccountAccess(accountId, citizenid)
        if not account or not perms or not perms.isOwner then return cb({ success = false, message = 'Only the owner can close an account' }) end
        -- the balance check is part of the DELETE, so a deposit landing in between cannot be destroyed
        local deleted = MySQL.update.await('DELETE FROM bank_accounts_v2 WHERE id = ? AND balance = 0', { account.id })
        if not deleted or deleted < 1 then return cb({ success = false, message = 'The account must be empty first' }) end
        MySQL.update.await('UPDATE bank_account_cards SET cancelled = 1 WHERE account_id = ?', { account.id })
        MySQL.update.await('DELETE FROM bank_account_members WHERE account_id = ?', { account.id })
        TriggerEvent('qb-log:server:CreateLog', 'banking', 'Account Closed', 'red', ('**%s** closed account **%s** (%s)'):format(GetPlayerName(source), account.label, account.iban))
        cb({ success = true, message = 'Account closed' })
    end)
end)

-- ── money movement ───────────────────────────────────────────────────
-- Deposit, withdraw and IBAN transfer are shared by the bank screen (callbacks below, a fresh key per
-- click) and the Bank app (server_app.lua, a stable key per action so a retry never moves money twice).
-- Each returns { success, message, error, txId, duplicate }. A duplicate is the earlier result of the
-- same key: no money moves and no history line is written again.
BankingAccountOps = BankingAccountOps or {}
local Ops = BankingAccountOps

local function lockedResult(citizenid, fn)
    local out
    local status = L.WithLock('bank:' .. citizenid, function() out = fn() end)
    if status == 'busy' then return { success = false, error = 'busy', message = 'Please wait for your last transaction' } end
    if status == 'error' or out == nil then return { success = false, error = 'server_error', message = 'Error' } end
    return out
end

local function refused(err, message) return { success = false, error = err, message = message } end

local function ledgerRefusal(res, insufficientMessage)
    if res.duplicate then return refused('already_processed', 'This transaction was already processed') end
    if res.error == 'insufficient_funds' then return refused('insufficient_funds', insufficientMessage) end
    return refused(res.error or 'failed', L.Message(res.error))
end

function Ops.deposit(source, data, key)
    local Player, citizenid = getPlayer(source)
    if not Player then return refused('no_player', 'Error') end
    data = type(data) == 'table' and data or {}
    local amount = sanitizeAmount(data.amount)
    if not amount then return refused('bad_amount', 'Invalid amount') end
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perm(perms, 'can_deposit') then return refused('not_authorized', 'No permission') end
    return lockedResult(citizenid, function()
        local res = L.Transfer({
            from = personalRef(citizenid), to = accountRef(account.id), amount = amount,
            key = key or L.AutoKey('acctdep'), kind = 'deposit', reason = 'Deposit to ' .. account.iban, actor = citizenid,
        })
        if not res.ok then return ledgerRefusal(res, 'Insufficient bank balance') end
        if not res.duplicate then
            local name = playerName(Player)
            logTx('personal:' .. citizenid, citizenid, name, 'withdraw', amount, 'Deposit to ' .. account.label)
            logTx('acc:' .. account.id, citizenid, name, 'deposit', amount, 'Deposit')
        end
        return { success = true, message = ('Deposited $%s into %s'):format(amount, account.label), txId = res.txId, duplicate = res.duplicate, amount = amount }
    end)
end

function Ops.withdraw(source, data, key)
    local Player, citizenid = getPlayer(source)
    if not Player then return refused('no_player', 'Error') end
    data = type(data) == 'table' and data or {}
    local amount = sanitizeAmount(data.amount)
    if not amount then return refused('bad_amount', 'Invalid amount') end
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perm(perms, 'can_withdraw') then return refused('not_authorized', 'No permission') end
    return lockedResult(citizenid, function()
        local res = L.Transfer({
            from = accountRef(account.id), to = personalRef(citizenid), amount = amount,
            key = key or L.AutoKey('acctwd'), kind = 'withdraw', reason = 'Withdrawal from ' .. account.iban, actor = citizenid,
        })
        if not res.ok then return ledgerRefusal(res, 'Insufficient account balance') end
        if not res.duplicate then
            local name = playerName(Player)
            logTx('acc:' .. account.id, citizenid, name, 'withdraw', amount, 'Withdrawal')
            logTx('personal:' .. citizenid, citizenid, name, 'deposit', amount, 'Withdrawal from ' .. account.label)
        end
        return { success = true, message = ('Withdrew $%s from %s'):format(amount, account.label), txId = res.txId, duplicate = res.duplicate, amount = amount }
    end)
end

--- data = { fromRef = 'personal' | <account id>, toIban, amount, note }
function Ops.transfer(source, data, key)
    local Player, citizenid = getPlayer(source)
    if not Player then return refused('no_player', 'Error') end
    data = type(data) == 'table' and data or {}
    local amount = sanitizeAmount(data.amount)
    if not amount then return refused('bad_amount', 'Invalid amount') end
    local note = sanitizeNote(data.note)
    local toIban = type(data.toIban) == 'string' and data.toIban:upper():gsub('%s', '') or ''
    if not toIban:match('^PF%d+$') or #toIban > 24 then return refused('bad_iban', 'Invalid IBAN') end
    local name = playerName(Player)

    -- resolve destination first (no money moved yet)
    local destAccount = MySQL.single.await('SELECT id, label, iban FROM bank_accounts_v2 WHERE iban = ?', { toIban })
    local destCitizen = nil
    if not destAccount then
        destCitizen = MySQL.scalar.await('SELECT citizenid FROM bank_personal_iban WHERE iban = ?', { toIban })
        if not destCitizen then return refused('unknown_iban', 'No account found for that IBAN') end
    end

    -- resolve and authorise the source (no money moved yet)
    local fromRef = data.fromRef
    local fromLedger, sourceRefStr, sourceLabel
    if fromRef == 'personal' then
        if destCitizen == citizenid then return refused('same_account', 'That is your own account') end
        fromLedger = personalRef(citizenid)
        sourceRefStr = 'personal:' .. citizenid
        sourceLabel = name
    else
        local account, perms = getAccountAccess(fromRef, citizenid)
        if not account or not perm(perms, 'can_withdraw') then return refused('not_authorized', 'No permission') end
        if destAccount and destAccount.id == account.id then return refused('same_account', 'That is the same account') end
        fromLedger = accountRef(account.id)
        sourceRefStr = 'acc:' .. account.id
        sourceLabel = account.label
    end

    local toLedger, destRefStr, destLabel
    if destAccount then
        toLedger = accountRef(destAccount.id)
        destRefStr = 'acc:' .. destAccount.id
        destLabel = destAccount.label
    else
        toLedger = personalRef(destCitizen)
        destRefStr = 'personal:' .. destCitizen
        destLabel = toIban
    end

    return lockedResult(citizenid, function()
        -- one ledger transfer: the recipient may be offline; if they cannot be credited the source is refunded
        local res = L.Transfer({
            from = fromLedger, to = toLedger, amount = amount,
            key = key or L.AutoKey('ibantx'), kind = 'transfer', reason = 'Transfer to ' .. toIban, actor = citizenid,
            metadata = note and { note = note } or nil,
        })
        if not res.ok then
            if res.state == 'compensated' and not res.duplicate then
                return refused('recipient_unavailable', 'Recipient could not be credited — transfer refunded')
            end
            return ledgerRefusal(res, fromRef == 'personal' and 'Insufficient bank balance' or 'Insufficient account balance')
        end
        if not res.duplicate then
            if destCitizen then
                local Target = QBCore.Functions.GetPlayerByCitizenId(destCitizen)
                if Target and Target.PlayerData.source then
                    TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, ('You received a transfer of $%s'):format(amount), 'success')
                end
            end
            logTx(sourceRefStr, citizenid, name, 'transfer_out', amount, note or ('To ' .. toIban))
            logTx(destRefStr, citizenid, name, 'transfer_in', amount, note or ('From ' .. sourceLabel))
            TriggerEvent('qb-log:server:CreateLog', 'banking', 'Transfer', 'green', ('**%s** transferred $%s from %s to %s'):format(GetPlayerName(source), amount, sourceLabel, destLabel))
        end
        return { success = true, message = ('Transferred $%s to %s'):format(amount, toIban), txId = res.txId, duplicate = res.duplicate,
            amount = amount, recipient = destCitizen, toAccount = destAccount and destAccount.id or nil }
    end)
end

callback('qb-banking:server:accountDeposit', function(source, cb, data) cb(Ops.deposit(source, data)) end)
callback('qb-banking:server:accountWithdraw', function(source, cb, data) cb(Ops.withdraw(source, data)) end)
callback('qb-banking:server:accountTransfer', function(source, cb, data) cb(Ops.transfer(source, data)) end)

-- ── members & permissions ────────────────────────────────────────────
local function cleanPerms(perms)
    perms = type(perms) == 'table' and perms or {}
    local function bit(v) return (v == true or v == 1 or v == '1') and 1 or 0 end
    return { can_withdraw = bit(perms.can_withdraw), can_deposit = bit(perms.can_deposit), can_cards = bit(perms.can_cards), can_manage = bit(perms.can_manage) }
end

local function getMember(accountId, citizenid)
    return MySQL.single.await('SELECT * FROM bank_account_members WHERE account_id = ? AND citizenid = ?', { accountId, citizenid })
end

local function memberLog(source, citizenid, title, color, text)
    TriggerEvent('qb-log:server:CreateLog', 'banking', title, color, ('**%s** (%s) %s'):format(GetPlayerName(source), citizenid, text))
end

callback('qb-banking:server:addMember', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = type(data) == 'table' and data or {}
    local target = type(data.citizenid) == 'string' and data.citizenid:gsub('%s', '') or ''
    if target == '' or #target > 50 then return cb({ success = false, message = 'Invalid citizen ID' }) end
    accountLocked(data.accountId, cb, function(accountId)
        local account, perms = getAccountAccess(accountId, citizenid)
        if not account or not perm(perms, 'can_manage') then return cb({ success = false, message = 'No permission' }) end
        if target == account.owner then return cb({ success = false, message = 'That citizen already owns this account' }) end
        local want = cleanPerms(data.perms)
        local refusal = refusedRight(memberRules(account, perms, citizenid, nil), nil, want)
        if refusal then return cb({ success = false, message = refusal }) end
        if getMember(account.id, target) then return cb({ success = false, message = 'Already a member' }) end
        local charinfo = MySQL.scalar.await('SELECT charinfo FROM players WHERE citizenid = ?', { target })
        if not charinfo then return cb({ success = false, message = 'No citizen found with that ID' }) end
        local okDecode, info = pcall(json.decode, charinfo)
        local targetName = okDecode and type(info) == 'table' and ((info.firstname or '') .. ' ' .. (info.lastname or '')) or target
        local inserted = MySQL.insert.await('INSERT INTO bank_account_members (account_id, citizenid, name, can_withdraw, can_deposit, can_cards, can_manage) VALUES (?, ?, ?, ?, ?, ?, ?)', {
            account.id, target, targetName, want.can_withdraw, want.can_deposit, want.can_cards, want.can_manage,
        })
        if not inserted then return cb({ success = false, message = 'Error' }) end
        memberLog(source, citizenid, 'Member Added', 'green', ('added **%s** to account **%s** (%s) with rights: %s'):format(target, account.label, account.iban, rightsText(want)))
        cb({ success = true, message = ('%s added to %s'):format(targetName, account.label) })
    end)
end)

callback('qb-banking:server:updateMember', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = type(data) == 'table' and data or {}
    local target = type(data.citizenid) == 'string' and data.citizenid or ''
    if target == '' or #target > 50 then return cb({ success = false, message = 'Member not found' }) end
    accountLocked(data.accountId, cb, function(accountId)
        local account, perms = getAccountAccess(accountId, citizenid)
        if not account or not perm(perms, 'can_manage') then return cb({ success = false, message = 'No permission' }) end
        if target == account.owner then return cb({ success = false, message = 'The owner cannot be modified' }) end
        if target == citizenid and not perms.isOwner then return cb({ success = false, message = 'You cannot change your own permissions' }) end
        local row = getMember(account.id, target)
        if not row then return cb({ success = false, message = 'Member not found' }) end
        local rules = memberRules(account, perms, citizenid, row)
        if not rules.edit then return cb({ success = false, message = 'Only the account owner can change a manager' }) end
        local want = cleanPerms(data.perms)
        local refusal = refusedRight(rules, row, want)
        if refusal then return cb({ success = false, message = refusal }) end
        local changed = false
        for _, key in ipairs(RIGHTS) do if want[key] ~= (tonumber(row[key]) or 0) then changed = true end end
        if not changed then return cb({ success = true, message = 'No changes' }) end
        local updated = MySQL.update.await('UPDATE bank_account_members SET can_withdraw = ?, can_deposit = ?, can_cards = ?, can_manage = ? WHERE account_id = ? AND citizenid = ?', {
            want.can_withdraw, want.can_deposit, want.can_cards, want.can_manage, account.id, target,
        })
        if not updated or updated < 1 then return cb({ success = false, message = 'Member not found' }) end
        memberLog(source, citizenid, 'Member Rights Changed', 'orange', ('changed the rights of **%s** on account **%s** (%s): %s -> %s'):format(
            target, account.label, account.iban, rightsText(row), rightsText(want)))
        cb({ success = true, message = 'Permissions updated' })
    end)
end)

-- Removing a member, or leaving an account (target = the caller; any member but the owner may leave).
callback('qb-banking:server:removeMember', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = type(data) == 'table' and data or {}
    local target = type(data.citizenid) == 'string' and data.citizenid or ''
    if target == '' or #target > 50 then return cb({ success = false, message = 'Member not found' }) end
    accountLocked(data.accountId, cb, function(accountId)
        local account, perms = getAccountAccess(accountId, citizenid)
        if not account or not perms then return cb({ success = false, message = 'No permission' }) end
        if target == account.owner then return cb({ success = false, message = 'The owner cannot be removed' }) end
        local leaving = target == citizenid
        if not leaving and not perm(perms, 'can_manage') then return cb({ success = false, message = 'No permission' }) end
        local row = getMember(account.id, target)
        if not row then return cb({ success = false, message = 'Member not found' }) end
        if not memberRules(account, perms, citizenid, row).remove then
            return cb({ success = false, message = 'Only the account owner can remove a manager' })
        end
        local deleted = MySQL.update.await('DELETE FROM bank_account_members WHERE account_id = ? AND citizenid = ?', { account.id, target })
        if not deleted or deleted < 1 then return cb({ success = false, message = 'Member not found' }) end
        MySQL.update.await('UPDATE bank_account_cards SET cancelled = 1 WHERE account_id = ? AND citizenid = ?', { account.id, target })
        if leaving then
            memberLog(source, citizenid, 'Member Left', 'red', ('left account **%s** (%s)'):format(account.label, account.iban))
            return cb({ success = true, message = ('You left %s'):format(account.label) })
        end
        memberLog(source, citizenid, 'Member Removed', 'red', ('removed **%s** (rights: %s) from account **%s** (%s)'):format(target, rightsText(row), account.label, account.iban))
        cb({ success = true, message = 'Member removed' })
    end)
end)

-- ── cards ────────────────────────────────────────────────────────────
local CARD_DESIGNS = { classic = true, midnight = true, gold = true, ruby = true, ocean = true }

-- The card-count check and the insert run under a lock (the player's for a personal card, the
-- account's for an account card), so a double click cannot go over the card limit.
callback('qb-banking:server:createCard', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = type(data) == 'table' and data or {}
    local design = CARD_DESIGNS[data.design] and data.design or 'classic'

    local function issue(accountId)
        local maxCards = Config.MaxCardsPerAccount or 4
        local active
        if accountId then
            active = MySQL.scalar.await('SELECT COUNT(*) FROM bank_account_cards WHERE account_id = ? AND cancelled = 0', { accountId }) or 0
        else
            active = MySQL.scalar.await('SELECT COUNT(*) FROM bank_account_cards WHERE account_id IS NULL AND citizenid = ? AND cancelled = 0', { citizenid }) or 0
        end
        if (tonumber(active) or 0) >= maxCards then return cb({ success = false, message = ('Maximum of %d active cards reached'):format(maxCards) }) end

        local number = '4' .. randomDigits(15)
        local cvv = randomDigits(3)
        local expTable = os.date('*t')
        local exp = ('%02d/%02d'):format(expTable.month, (expTable.year + 3) % 100)

        MySQL.insert.await('INSERT INTO bank_account_cards (account_id, citizenid, holder_name, number, cvv, exp, design) VALUES (?, ?, ?, ?, ?, ?, ?)', {
            accountId, citizenid, playerName(Player), number, cvv, exp, design,
        })
        TriggerEvent('qb-log:server:CreateLog', 'banking', 'Card Issued', 'green', ('**%s** issued a %s card'):format(GetPlayerName(source), accountId and 'account' or 'personal'))
        cb({ success = true, message = 'Card issued' })
    end

    if data.accountRef == 'personal' then return locked(citizenid, cb, function() issue(nil) end) end
    accountLocked(data.accountRef, cb, function(accountId)
        local account, perms = getAccountAccess(accountId, citizenid)
        if not account or not perm(perms, 'can_cards') then return cb({ success = false, message = 'No permission' }) end
        issue(account.id)
    end)
end)

-- The card if the caller may lock or cancel it (see mayManageCard), else nil.
local function getCardAccess(cardId, citizenid)
    cardId = tonumber(cardId)
    if not cardId then return nil end
    local card = MySQL.single.await('SELECT * FROM bank_account_cards WHERE id = ? AND cancelled = 0', { cardId })
    if not card or not card.id then return nil end
    if card.citizenid == citizenid then return card end
    if not card.account_id then return nil end
    local account, perms = getAccountAccess(card.account_id, citizenid)
    if not account or not perm(perms, 'can_manage') then return nil end
    local holder = not perms.isOwner and getMember(account.id, card.citizenid) or nil
    return mayManageCard(card, account, perms, citizenid, holder ~= nil and isSet(holder.can_manage)) and card or nil
end

callback('qb-banking:server:cancelCard', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    local card = getCardAccess(type(data) == 'table' and data.cardId or nil, citizenid)
    if not card then return cb({ success = false, message = 'No permission' }) end
    MySQL.update.await('UPDATE bank_account_cards SET cancelled = 1 WHERE id = ?', { card.id })
    cb({ success = true, message = 'Card cancelled' })
end)

callback('qb-banking:server:toggleCardLock', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    local card = getCardAccess(type(data) == 'table' and data.cardId or nil, citizenid)
    if not card then return cb({ success = false, message = 'No permission' }) end
    local newLocked = (tonumber(card.locked) or 0) == 1 and 0 or 1
    MySQL.update('UPDATE bank_account_cards SET locked = ? WHERE id = ?', { newLocked, card.id })
    cb({ success = true, message = newLocked == 1 and 'Card locked' or 'Card unlocked', locked = newLocked })
end)

-- Shared with server_app.lua and server_characters.lua (same resource).
BankingAccountsInternal = {
    getAccountAccess = getAccountAccess,
    getPersonalIban = getPersonalIban,
    perm = perm,
    playerName = playerName,
}
