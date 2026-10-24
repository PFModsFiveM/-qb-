-- qb-banking multi-account module: shared/business accounts, members, debit cards, IBAN transfers
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })

-- ── schema ───────────────────────────────────────────────────────────
MySQL.ready(function()
    MySQL.query([[CREATE TABLE IF NOT EXISTS bank_accounts_v2 (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        iban VARCHAR(24) NOT NULL UNIQUE,
        label VARCHAR(50) NOT NULL,
        type ENUM('shared','business') NOT NULL,
        owner VARCHAR(50) NOT NULL,
        balance BIGINT NOT NULL DEFAULT 0,
        color VARCHAR(16) NULL,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_owner (owner)
    )]])
    MySQL.query([[CREATE TABLE IF NOT EXISTS bank_account_members (
        account_id INT NOT NULL,
        citizenid VARCHAR(50) NOT NULL,
        name VARCHAR(80) NOT NULL DEFAULT '',
        can_withdraw TINYINT NOT NULL DEFAULT 0,
        can_deposit TINYINT NOT NULL DEFAULT 1,
        can_cards TINYINT NOT NULL DEFAULT 0,
        can_manage TINYINT NOT NULL DEFAULT 0,
        PRIMARY KEY (account_id, citizenid)
    )]])
    MySQL.query([[CREATE TABLE IF NOT EXISTS bank_account_cards (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        account_id INT NULL,
        citizenid VARCHAR(50) NOT NULL,
        holder_name VARCHAR(80) NOT NULL DEFAULT '',
        number VARCHAR(20) NOT NULL,
        cvv VARCHAR(4) NOT NULL,
        exp VARCHAR(5) NOT NULL,
        design VARCHAR(16) NOT NULL DEFAULT 'classic',
        locked TINYINT NOT NULL DEFAULT 0,
        cancelled TINYINT NOT NULL DEFAULT 0,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_holder (citizenid),
        INDEX idx_account (account_id)
    )]])
    MySQL.query([[CREATE TABLE IF NOT EXISTS bank_transactions (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        account_ref VARCHAR(32) NOT NULL,
        actor VARCHAR(50) NOT NULL,
        actor_name VARCHAR(80) NOT NULL DEFAULT '',
        type ENUM('deposit','withdraw','transfer_in','transfer_out','fee') NOT NULL,
        amount BIGINT NOT NULL,
        note VARCHAR(120) NULL,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_ref (account_ref, id)
    )]])
    MySQL.query([[CREATE TABLE IF NOT EXISTS bank_personal_iban (
        citizenid VARCHAR(50) NOT NULL PRIMARY KEY,
        iban VARCHAR(24) NOT NULL UNIQUE
    )]])
end)

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

-- credit a target player's bank balance whether they are online or not; returns success
local function creditPlayerBank(citizenid, amount, reason)
    local Target = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if Target then
        Target.Functions.AddMoney('bank', amount, reason)
        return true
    end
    local Offline = QBCore.Functions.GetOfflinePlayerByCitizenId and QBCore.Functions.GetOfflinePlayerByCitizenId(citizenid)
    if Offline and Offline.Functions then
        Offline.Functions.AddMoney('bank', amount, reason)
        Offline.Functions.Save()
        return true
    end
    return false
end

-- ── snapshot callback ────────────────────────────────────────────────
QBCore.Functions.CreateCallback('qb-banking:server:getAccountsData', function(source, cb)
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
            if perms.isOwner or perm(perms, 'can_manage') then
                entry.members = MySQL.query.await('SELECT citizenid, name, can_withdraw, can_deposit, can_cards, can_manage FROM bank_account_members WHERE account_id = ?', { acc.id }) or {}
            end
            if perms.isOwner or perm(perms, 'can_cards') then
                entry.cards = MySQL.query.await('SELECT * FROM bank_account_cards WHERE account_id = ? AND cancelled = 0', { acc.id }) or {}
            else
                entry.cards = MySQL.query.await('SELECT * FROM bank_account_cards WHERE account_id = ? AND citizenid = ? AND cancelled = 0', { acc.id, citizenid }) or {}
            end
            accounts[#accounts + 1] = entry
        end
    end

    local myCards = MySQL.query.await('SELECT * FROM bank_account_cards WHERE account_id IS NULL AND citizenid = ? AND cancelled = 0', { citizenid }) or {}

    cb({ personal = personal, accounts = accounts, myCards = myCards, myName = myName, myCitizenid = citizenid })
end)

-- ── account lifecycle ────────────────────────────────────────────────
QBCore.Functions.CreateCallback('qb-banking:server:createAccount', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}

    local label = type(data.label) == 'string' and data.label:gsub('[\r\n]', ''):sub(1, 30) or ''
    if label == '' then return cb({ success = false, message = 'Enter an account name' }) end
    local accType = data.type == 'business' and 'business' or (data.type == 'shared' and 'shared' or nil)
    if not accType then return cb({ success = false, message = 'Invalid account type' }) end

    local owned = MySQL.scalar.await('SELECT COUNT(*) FROM bank_accounts_v2 WHERE owner = ?', { citizenid }) or 0
    if owned >= (Config.MaxOwnedAccounts or 3) then
        return cb({ success = false, message = ('You already own the maximum of %d accounts'):format(Config.MaxOwnedAccounts or 3) })
    end

    local fee = Config.AccountCreationFee or 500
    if Player.PlayerData.money.bank < fee then
        return cb({ success = false, message = ('You need $%d in your bank for the creation fee'):format(fee) })
    end

    local iban = generateIban()
    if not iban then return cb({ success = false, message = 'Could not allocate an account number, try again' }) end

    if not Player.Functions.RemoveMoney('bank', fee, 'account-creation-fee') then
        return cb({ success = false, message = 'Could not charge the creation fee' })
    end

    local accountId = MySQL.insert.await('INSERT INTO bank_accounts_v2 (iban, label, type, owner) VALUES (?, ?, ?, ?)', { iban, label, accType, citizenid })
    if not accountId then
        Player.Functions.AddMoney('bank', fee, 'account-creation-refund')
        return cb({ success = false, message = 'Error creating the account' })
    end
    MySQL.insert('INSERT INTO bank_account_members (account_id, citizenid, name, can_withdraw, can_deposit, can_cards, can_manage) VALUES (?, ?, ?, 1, 1, 1, 1)', {
        accountId, citizenid, playerName(Player),
    })
    logTx('personal:' .. citizenid, citizenid, playerName(Player), 'fee', fee, 'Account creation fee (' .. label .. ')')
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Account Created', 'green', ('**%s** opened %s account **%s** (%s)'):format(GetPlayerName(source), accType, label, iban))
    cb({ success = true, message = ('Account "%s" created — %s'):format(label, iban), accountId = accountId, iban = iban })
end)

QBCore.Functions.CreateCallback('qb-banking:server:accountRename', function(source, cb, data)
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

QBCore.Functions.CreateCallback('qb-banking:server:accountColor', function(source, cb, data)
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

QBCore.Functions.CreateCallback('qb-banking:server:accountDelete', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perms or not perms.isOwner then return cb({ success = false, message = 'Only the owner can close an account' }) end
    if (tonumber(account.balance) or 0) ~= 0 then return cb({ success = false, message = 'The account must be empty first' }) end
    MySQL.update.await('UPDATE bank_account_cards SET cancelled = 1 WHERE account_id = ?', { account.id })
    MySQL.update.await('DELETE FROM bank_account_members WHERE account_id = ?', { account.id })
    MySQL.update.await('DELETE FROM bank_accounts_v2 WHERE id = ?', { account.id })
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Account Closed', 'red', ('**%s** closed account **%s** (%s)'):format(GetPlayerName(source), account.label, account.iban))
    cb({ success = true, message = 'Account closed' })
end)

-- ── money movement ───────────────────────────────────────────────────
QBCore.Functions.CreateCallback('qb-banking:server:accountDeposit', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local amount = sanitizeAmount(data.amount)
    if not amount then return cb({ success = false, message = 'Invalid amount' }) end
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perm(perms, 'can_deposit') then return cb({ success = false, message = 'No permission' }) end
    if Player.PlayerData.money.bank < amount then return cb({ success = false, message = 'Insufficient bank balance' }) end
    if not Player.Functions.RemoveMoney('bank', amount, 'account-deposit:' .. account.iban) then
        return cb({ success = false, message = 'Insufficient bank balance' })
    end
    local updated = MySQL.update.await('UPDATE bank_accounts_v2 SET balance = balance + ? WHERE id = ?', { amount, account.id })
    if not updated or updated < 1 then
        Player.Functions.AddMoney('bank', amount, 'account-deposit-refund')
        return cb({ success = false, message = 'Error — deposit refunded' })
    end
    local name = playerName(Player)
    logTx('personal:' .. citizenid, citizenid, name, 'withdraw', amount, 'Deposit to ' .. account.label)
    logTx('acc:' .. account.id, citizenid, name, 'deposit', amount, 'Deposit')
    cb({ success = true, message = ('Deposited $%s into %s'):format(amount, account.label) })
end)

QBCore.Functions.CreateCallback('qb-banking:server:accountWithdraw', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local amount = sanitizeAmount(data.amount)
    if not amount then return cb({ success = false, message = 'Invalid amount' }) end
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perm(perms, 'can_withdraw') then return cb({ success = false, message = 'No permission' }) end
    local updated = MySQL.update.await('UPDATE bank_accounts_v2 SET balance = balance - ? WHERE id = ? AND balance >= ?', { amount, account.id, amount })
    if not updated or updated < 1 then return cb({ success = false, message = 'Insufficient account balance' }) end
    Player.Functions.AddMoney('bank', amount, 'account-withdraw:' .. account.iban)
    local name = playerName(Player)
    logTx('acc:' .. account.id, citizenid, name, 'withdraw', amount, 'Withdrawal')
    logTx('personal:' .. citizenid, citizenid, name, 'deposit', amount, 'Withdrawal from ' .. account.label)
    cb({ success = true, message = ('Withdrew $%s from %s'):format(amount, account.label) })
end)

QBCore.Functions.CreateCallback('qb-banking:server:accountTransfer', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local amount = sanitizeAmount(data.amount)
    if not amount then return cb({ success = false, message = 'Invalid amount' }) end
    local note = sanitizeNote(data.note)
    local toIban = type(data.toIban) == 'string' and data.toIban:upper():gsub('%s', '') or ''
    if not toIban:match('^PF%d+$') or #toIban > 24 then return cb({ success = false, message = 'Invalid IBAN' }) end
    local name = playerName(Player)

    -- resolve destination first (no money moved yet)
    local destAccount = MySQL.single.await('SELECT id, label, iban FROM bank_accounts_v2 WHERE iban = ?', { toIban })
    local destCitizen = nil
    if not destAccount then
        destCitizen = MySQL.scalar.await('SELECT citizenid FROM bank_personal_iban WHERE iban = ?', { toIban })
        if not destCitizen then return cb({ success = false, message = 'No account found for that IBAN' }) end
    end

    -- debit source
    local fromRef = data.fromRef
    local sourceRefStr, sourceLabel
    if fromRef == 'personal' then
        if destCitizen == citizenid then return cb({ success = false, message = 'That is your own account' }) end
        if Player.PlayerData.money.bank < amount then return cb({ success = false, message = 'Insufficient bank balance' }) end
        if not Player.Functions.RemoveMoney('bank', amount, 'bank-transfer:' .. toIban) then
            return cb({ success = false, message = 'Insufficient bank balance' })
        end
        sourceRefStr = 'personal:' .. citizenid
        sourceLabel = name
    else
        local account, perms = getAccountAccess(fromRef, citizenid)
        if not account or not perm(perms, 'can_withdraw') then return cb({ success = false, message = 'No permission' }) end
        if destAccount and destAccount.id == account.id then return cb({ success = false, message = 'That is the same account' }) end
        local updated = MySQL.update.await('UPDATE bank_accounts_v2 SET balance = balance - ? WHERE id = ? AND balance >= ?', { amount, account.id, amount })
        if not updated or updated < 1 then return cb({ success = false, message = 'Insufficient account balance' }) end
        sourceRefStr = 'acc:' .. account.id
        sourceLabel = account.label
    end

    -- credit destination
    local destRefStr, destLabel
    if destAccount then
        MySQL.update.await('UPDATE bank_accounts_v2 SET balance = balance + ? WHERE id = ?', { amount, destAccount.id })
        destRefStr = 'acc:' .. destAccount.id
        destLabel = destAccount.label
    else
        if not creditPlayerBank(destCitizen, amount, 'bank-transfer-in') then
            -- refund the source
            if fromRef == 'personal' then
                Player.Functions.AddMoney('bank', amount, 'transfer-refund')
            else
                MySQL.update.await('UPDATE bank_accounts_v2 SET balance = balance + ? WHERE id = ?', { amount, tonumber(fromRef) })
            end
            return cb({ success = false, message = 'Recipient could not be credited — transfer refunded' })
        end
        destRefStr = 'personal:' .. destCitizen
        destLabel = toIban
        local Target = QBCore.Functions.GetPlayerByCitizenId(destCitizen)
        if Target and Target.PlayerData.source then
            TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, ('You received a transfer of $%s'):format(amount), 'success')
        end
    end

    logTx(sourceRefStr, citizenid, name, 'transfer_out', amount, note or ('To ' .. toIban))
    logTx(destRefStr, citizenid, name, 'transfer_in', amount, note or ('From ' .. sourceLabel))
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Transfer', 'green', ('**%s** transferred $%s from %s to %s'):format(GetPlayerName(source), amount, sourceLabel, destLabel))
    cb({ success = true, message = ('Transferred $%s to %s'):format(amount, toIban) })
end)

-- ── members & permissions ────────────────────────────────────────────
local function cleanPerms(perms)
    perms = type(perms) == 'table' and perms or {}
    local function bit(v) return (v == true or v == 1 or v == '1') and 1 or 0 end
    return bit(perms.can_withdraw), bit(perms.can_deposit), bit(perms.can_cards), bit(perms.can_manage)
end

QBCore.Functions.CreateCallback('qb-banking:server:addMember', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perm(perms, 'can_manage') then return cb({ success = false, message = 'No permission' }) end
    local target = type(data.citizenid) == 'string' and data.citizenid:gsub('%s', '') or ''
    if target == '' or #target > 50 then return cb({ success = false, message = 'Invalid citizen ID' }) end
    if target == account.owner then return cb({ success = false, message = 'That citizen already owns this account' }) end
    local existing = MySQL.scalar.await('SELECT 1 FROM bank_account_members WHERE account_id = ? AND citizenid = ?', { account.id, target })
    if existing then return cb({ success = false, message = 'Already a member' }) end
    local charinfo = MySQL.scalar.await('SELECT charinfo FROM players WHERE citizenid = ?', { target })
    if not charinfo then return cb({ success = false, message = 'No citizen found with that ID' }) end
    local okDecode, info = pcall(json.decode, charinfo)
    local targetName = okDecode and info and ((info.firstname or '') .. ' ' .. (info.lastname or '')) or target
    local w, d, c, m = cleanPerms(data.perms)
    MySQL.insert.await('INSERT INTO bank_account_members (account_id, citizenid, name, can_withdraw, can_deposit, can_cards, can_manage) VALUES (?, ?, ?, ?, ?, ?, ?)', {
        account.id, target, targetName, w, d, c, m,
    })
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Member Added', 'green', ('**%s** added **%s** to account **%s**'):format(GetPlayerName(source), target, account.label))
    cb({ success = true, message = ('%s added to %s'):format(targetName, account.label) })
end)

QBCore.Functions.CreateCallback('qb-banking:server:updateMember', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perm(perms, 'can_manage') then return cb({ success = false, message = 'No permission' }) end
    local target = type(data.citizenid) == 'string' and data.citizenid or ''
    if target == account.owner then return cb({ success = false, message = 'The owner cannot be modified' }) end
    local w, d, c, m = cleanPerms(data.perms)
    local updated = MySQL.update.await('UPDATE bank_account_members SET can_withdraw = ?, can_deposit = ?, can_cards = ?, can_manage = ? WHERE account_id = ? AND citizenid = ?', {
        w, d, c, m, account.id, target,
    })
    if not updated or updated < 1 then return cb({ success = false, message = 'Member not found' }) end
    cb({ success = true, message = 'Permissions updated' })
end)

QBCore.Functions.CreateCallback('qb-banking:server:removeMember', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perm(perms, 'can_manage') then return cb({ success = false, message = 'No permission' }) end
    local target = type(data.citizenid) == 'string' and data.citizenid or ''
    if target == account.owner then return cb({ success = false, message = 'The owner cannot be removed' }) end
    local updated = MySQL.update.await('DELETE FROM bank_account_members WHERE account_id = ? AND citizenid = ?', { account.id, target })
    if not updated or updated < 1 then return cb({ success = false, message = 'Member not found' }) end
    MySQL.update('UPDATE bank_account_cards SET cancelled = 1 WHERE account_id = ? AND citizenid = ?', { account.id, target })
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Member Removed', 'red', ('**%s** removed **%s** from account **%s**'):format(GetPlayerName(source), target, account.label))
    cb({ success = true, message = 'Member removed' })
end)

-- ── cards ────────────────────────────────────────────────────────────
local CARD_DESIGNS = { classic = true, midnight = true, gold = true, ruby = true, ocean = true }

QBCore.Functions.CreateCallback('qb-banking:server:createCard', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local design = CARD_DESIGNS[data.design] and data.design or 'classic'
    local accountId = nil
    if data.accountRef ~= 'personal' then
        local account, perms = getAccountAccess(data.accountRef, citizenid)
        if not account or not perm(perms, 'can_cards') then return cb({ success = false, message = 'No permission' }) end
        accountId = account.id
    end

    local maxCards = Config.MaxCardsPerAccount or 4
    local active
    if accountId then
        active = MySQL.scalar.await('SELECT COUNT(*) FROM bank_account_cards WHERE account_id = ? AND cancelled = 0', { accountId }) or 0
    else
        active = MySQL.scalar.await('SELECT COUNT(*) FROM bank_account_cards WHERE account_id IS NULL AND citizenid = ? AND cancelled = 0', { citizenid }) or 0
    end
    if active >= maxCards then return cb({ success = false, message = ('Maximum of %d active cards reached'):format(maxCards) }) end

    local number = '4' .. randomDigits(15)
    local cvv = randomDigits(3)
    local expTable = os.date('*t')
    local exp = ('%02d/%02d'):format(expTable.month, (expTable.year + 3) % 100)

    MySQL.insert.await('INSERT INTO bank_account_cards (account_id, citizenid, holder_name, number, cvv, exp, design) VALUES (?, ?, ?, ?, ?, ?, ?)', {
        accountId, citizenid, playerName(Player), number, cvv, exp, design,
    })
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Card Issued', 'green', ('**%s** issued a %s card'):format(GetPlayerName(source), accountId and 'account' or 'personal'))
    cb({ success = true, message = 'Card issued' })
end)

local function getCardAccess(cardId, citizenid)
    cardId = tonumber(cardId)
    if not cardId then return nil end
    local card = MySQL.single.await('SELECT * FROM bank_account_cards WHERE id = ? AND cancelled = 0', { cardId })
    if not card then return nil end
    if card.citizenid == citizenid then return card end
    if card.account_id then
        local account, perms = getAccountAccess(card.account_id, citizenid)
        if account and perm(perms, 'can_cards') then return card end
    end
    return nil
end

QBCore.Functions.CreateCallback('qb-banking:server:cancelCard', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    local card = getCardAccess(data and data.cardId, citizenid)
    if not card then return cb({ success = false, message = 'No permission' }) end
    MySQL.update.await('UPDATE bank_account_cards SET cancelled = 1 WHERE id = ?', { card.id })
    cb({ success = true, message = 'Card cancelled' })
end)

QBCore.Functions.CreateCallback('qb-banking:server:toggleCardLock', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    local card = getCardAccess(data and data.cardId, citizenid)
    if not card then return cb({ success = false, message = 'No permission' }) end
    local newLocked = (tonumber(card.locked) or 0) == 1 and 0 or 1
    MySQL.update('UPDATE bank_account_cards SET locked = ? WHERE id = ?', { newLocked, card.id })
    cb({ success = true, message = newLocked == 1 and 'Card locked' or 'Card unlocked', locked = newLocked })
end)
