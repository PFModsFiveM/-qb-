-- qb-banking multi-account module: shared/business accounts, members, debit cards, IBAN transfers.
-- Tables are created by the pfm-banking ledger migration (server_ledger.lua, v2). Every balance change
-- goes through PFLedger.Transfer: account refs are acct:<id> for these accounts and
-- player:<citizenid>:bank for personal balances. bank_transactions is the per-account history shown
-- in the UI; pf_transactions is the authoritative record.
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local L = PFLedger

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
    -- the balance check is part of the DELETE, so a deposit landing in between cannot be destroyed
    local deleted = MySQL.update.await('DELETE FROM bank_accounts_v2 WHERE id = ? AND balance = 0', { account.id })
    if not deleted or deleted < 1 then return cb({ success = false, message = 'The account must be empty first' }) end
    MySQL.update.await('UPDATE bank_account_cards SET cancelled = 1 WHERE account_id = ?', { account.id })
    MySQL.update.await('DELETE FROM bank_account_members WHERE account_id = ?', { account.id })
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
    locked(citizenid, cb, function()
        local res = L.Transfer({
            from = personalRef(citizenid), to = accountRef(account.id), amount = amount,
            key = L.AutoKey('acctdep'), kind = 'deposit', reason = 'Deposit to ' .. account.iban, actor = citizenid,
        })
        if not res.ok then
            local msg = res.error == 'insufficient_funds' and 'Insufficient bank balance' or L.Message(res.error)
            return cb({ success = false, message = msg })
        end
        local name = playerName(Player)
        logTx('personal:' .. citizenid, citizenid, name, 'withdraw', amount, 'Deposit to ' .. account.label)
        logTx('acc:' .. account.id, citizenid, name, 'deposit', amount, 'Deposit')
        cb({ success = true, message = ('Deposited $%s into %s'):format(amount, account.label), txId = res.txId })
    end)
end)

QBCore.Functions.CreateCallback('qb-banking:server:accountWithdraw', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local amount = sanitizeAmount(data.amount)
    if not amount then return cb({ success = false, message = 'Invalid amount' }) end
    local account, perms = getAccountAccess(data.accountId, citizenid)
    if not account or not perm(perms, 'can_withdraw') then return cb({ success = false, message = 'No permission' }) end
    locked(citizenid, cb, function()
        local res = L.Transfer({
            from = accountRef(account.id), to = personalRef(citizenid), amount = amount,
            key = L.AutoKey('acctwd'), kind = 'withdraw', reason = 'Withdrawal from ' .. account.iban, actor = citizenid,
        })
        if not res.ok then
            local msg = res.error == 'insufficient_funds' and 'Insufficient account balance' or L.Message(res.error)
            return cb({ success = false, message = msg })
        end
        local name = playerName(Player)
        logTx('acc:' .. account.id, citizenid, name, 'withdraw', amount, 'Withdrawal')
        logTx('personal:' .. citizenid, citizenid, name, 'deposit', amount, 'Withdrawal from ' .. account.label)
        cb({ success = true, message = ('Withdrew $%s from %s'):format(amount, account.label), txId = res.txId })
    end)
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

    -- resolve and authorise the source (no money moved yet)
    local fromRef = data.fromRef
    local fromLedger, sourceRefStr, sourceLabel
    if fromRef == 'personal' then
        if destCitizen == citizenid then return cb({ success = false, message = 'That is your own account' }) end
        fromLedger = personalRef(citizenid)
        sourceRefStr = 'personal:' .. citizenid
        sourceLabel = name
    else
        local account, perms = getAccountAccess(fromRef, citizenid)
        if not account or not perm(perms, 'can_withdraw') then return cb({ success = false, message = 'No permission' }) end
        if destAccount and destAccount.id == account.id then return cb({ success = false, message = 'That is the same account' }) end
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

    locked(citizenid, cb, function()
        -- one ledger transfer: the recipient may be offline; if they cannot be credited the source is refunded
        local res = L.Transfer({
            from = fromLedger, to = toLedger, amount = amount,
            key = L.AutoKey('ibantx'), kind = 'transfer', reason = 'Transfer to ' .. toIban, actor = citizenid,
            metadata = note and { note = note } or nil,
        })
        if not res.ok then
            local msg
            if res.state == 'compensated' then msg = 'Recipient could not be credited — transfer refunded'
            elseif res.error == 'insufficient_funds' then msg = fromRef == 'personal' and 'Insufficient bank balance' or 'Insufficient account balance'
            else msg = L.Message(res.error) end
            return cb({ success = false, message = msg })
        end
        if destCitizen then
            local Target = QBCore.Functions.GetPlayerByCitizenId(destCitizen)
            if Target and Target.PlayerData.source then
                TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, ('You received a transfer of $%s'):format(amount), 'success')
            end
        end
        logTx(sourceRefStr, citizenid, name, 'transfer_out', amount, note or ('To ' .. toIban))
        logTx(destRefStr, citizenid, name, 'transfer_in', amount, note or ('From ' .. sourceLabel))
        TriggerEvent('qb-log:server:CreateLog', 'banking', 'Transfer', 'green', ('**%s** transferred $%s from %s to %s'):format(GetPlayerName(source), amount, sourceLabel, destLabel))
        cb({ success = true, message = ('Transferred $%s to %s'):format(amount, toIban), txId = res.txId })
    end)
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
