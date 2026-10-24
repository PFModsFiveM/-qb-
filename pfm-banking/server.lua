local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands', 'Shared' })
local Accounts = {}
local Statements = {}
BankingAccounts = Accounts -- shared with server_ledger.lua, which refreshes balances after each transfer

-- Whether a player may move money out of a society/shared account: the boss of that exact job or
-- gang, or the owner/listed user of a shared account.
local function canUseAccount(Player, account)
    if not Player or not account then return false end
    local pd = Player.PlayerData
    if account.account_type == 'job' then
        return pd.job ~= nil and pd.job.name == account.account_name and pd.job.isboss == true
    elseif account.account_type == 'gang' then
        return pd.gang ~= nil and pd.gang.name == account.account_name and pd.gang.isboss == true
    elseif account.account_type == 'shared' then
        if account.citizenid == pd.citizenid then return true end
        local ok, users = pcall(json.decode, account.users or '[]')
        if ok and type(users) == 'table' then
            for _, cid in ipairs(users) do
                if cid == pd.citizenid then return true end
            end
        end
    end
    return false
end

-- Records a statement line for a society/shared account (history shown in the bank UI).
local function appendAccountStatement(accountName, amount, reason, statementType)
    reason = tostring(reason or ''):sub(1, 50)
    if not Statements[accountName] then Statements[accountName] = {} end
    Statements[accountName][#Statements[accountName] + 1] = {
        amount = amount, reason = reason, date = os.time() * 1000, statement_type = statementType,
    }
    MySQL.insert('INSERT INTO bank_statements (account_name, amount, reason, statement_type) VALUES (?, ?, ?, ?)', { accountName, amount, reason, statementType })
end

-- Maps a ledger result to the message shown in the bank UI.
local function ledgerError(res)
    if res and res.error == 'insufficient_funds' then return Lang:t('error.money') end
    if res and res.error == 'unknown_account' then return Lang:t('error.account') end
    return Lang:t('error.error')
end

local function bankTransfer(src, citizenid, from, to, amount, kind, reason)
    return PFLedger.Transfer({
        from = from, to = to, amount = amount, kind = kind, reason = reason,
        key = PFLedger.AutoKey('bank:' .. tostring(src)), actor = citizenid,
    })
end

-- Functions

local function getPlayerAndCitizenId(playerId)
    local Player = exports['pfm-core']:GetPlayer(playerId)
    if not Player then return nil, nil end
    return Player, Player.PlayerData.citizenid
end

local function GetNumberOfAccounts(citizenid)
    local numberOfAccounts = 0
    for _, account in pairs(Accounts) do
        if account.citizenid == citizenid then
            numberOfAccounts = numberOfAccounts + 1
        end
    end
    return numberOfAccounts
end

-- Exported Functions

local function CreatePlayerAccount(playerId, accountName, accountBalance, accountUsers)
    local Player, citizenid = getPlayerAndCitizenId(playerId)
    if not Player or not citizenid then return false end

    if Accounts[accountName] then
        return false
    end

    Accounts[accountName] = {
        citizenid = citizenid,
        account_name = accountName,
        account_balance = accountBalance,
        account_type = 'shared',
        users = accountUsers
    }

    local insertSuccess = MySQL.insert.await('INSERT INTO bank_accounts (citizenid, account_name, account_balance, account_type, users) VALUES (?, ?, ?, ?, ?)', { citizenid, accountName, accountBalance, 'shared', accountUsers })
    if insertSuccess then
        pcall(MySQL.insert.await, 'INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, ?)', { 'society:' .. accountName, tonumber(accountBalance) or 0 })
    end
    return insertSuccess
end
exports('CreatePlayerAccount', CreatePlayerAccount)

-- Creates a society account. A starting balance is money entering the economy, so it is recorded as
-- the account's reconciliation baseline.
local function createSocietyAccount(accountName, accountBalance, accountType)
    if type(accountName) ~= 'string' or accountName == '' or Accounts[accountName] then return false end
    accountBalance = tonumber(accountBalance) or 0
    if accountBalance ~= accountBalance or accountBalance < 0 then accountBalance = 0 end
    local insertSuccess = MySQL.insert.await('INSERT IGNORE INTO bank_accounts (account_name, account_balance, account_type) VALUES (?, ?, ?)', { accountName, accountBalance, accountType })
    if insertSuccess then
        pcall(MySQL.insert.await, 'INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, ?)', { 'society:' .. accountName, accountBalance })
        Accounts[accountName] = { account_name = accountName, account_balance = accountBalance, account_type = accountType }
    end
    return insertSuccess
end

local function CreateJobAccount(accountName, accountBalance)
    return createSocietyAccount(accountName, accountBalance, 'job')
end
exports('CreateJobAccount', CreateJobAccount)

local function CreateGangAccount(accountName, accountBalance)
    return createSocietyAccount(accountName, accountBalance, 'gang')
end
exports('CreateGangAccount', CreateGangAccount)

local function CreateBankStatement(playerId, account, amount, reason, statementType, accountType)
    local Player, citizenid = getPlayerAndCitizenId(playerId)
    if not Player or not citizenid then return false end

    local newStatement = {
        citizenid = citizenid,
        amount = amount,
        reason = reason,
        date = os.time() * 1000,
        statement_type = statementType
    }
    if accountType == 'player' or accountType == 'shared' then
        if accountType == 'player' then account = 'checking' end
        if not Statements[citizenid] then Statements[citizenid] = {} end
        if not Statements[citizenid][account] then Statements[citizenid][account] = {} end
        Statements[citizenid][account][#Statements[citizenid][account] + 1] = newStatement
    else
        if not Statements[account] then Statements[account] = {} end
        Statements[account][#Statements[account] + 1] = newStatement
    end

    local insertSuccess = MySQL.insert.await('INSERT INTO bank_statements (citizenid, account_name, amount, reason, statement_type) VALUES (?, ?, ?, ?, ?)', { citizenid, account, amount, reason, statementType })
    if not insertSuccess then return false end
    return true
end
exports('CreateBankStatement', CreateBankStatement)

--- Adds money to a society account from outside the economy (NPC payments, fines, sales).
--- Goes through the ledger: validated amount, unknown accounts refused (known jobs/gangs are
--- created on demand), recorded with a transaction id. Pass `key` to make retries safe.
--- @return boolean ok, table result { ok, txId, state, error, duplicate }
local function AddMoney(accountName, amount, reason, key)
    if type(accountName) ~= 'string' then return false, { ok = false, error = 'invalid_account' } end
    reason = reason or 'External Deposit'
    local res = PFLedger.Transfer({
        from = 'system:' .. (GetInvokingResource() or GetCurrentResourceName()),
        to = 'society:' .. accountName,
        amount = amount,
        key = key or PFLedger.AutoKey('deposit'),
        kind = 'deposit',
        reason = reason,
    })
    if res.ok and not res.duplicate then appendAccountStatement(accountName, PFLedger.Amount(amount), reason, 'deposit') end
    return res.ok, res
end
exports('AddMoney', AddMoney)
exports('AddGangMoney', AddMoney)

--- Removes money from a society account to outside the economy. Refuses to overdraw.
--- @return boolean ok, table result
local function RemoveMoney(accountName, amount, reason, key)
    if type(accountName) ~= 'string' then return false, { ok = false, error = 'invalid_account' } end
    reason = reason or 'External Withdrawal'
    local res = PFLedger.Transfer({
        from = 'society:' .. accountName,
        to = 'system:' .. (GetInvokingResource() or GetCurrentResourceName()),
        amount = amount,
        key = key or PFLedger.AutoKey('withdraw'),
        kind = 'withdraw',
        reason = reason,
    })
    if res.ok and not res.duplicate then appendAccountStatement(accountName, PFLedger.Amount(amount), reason, 'withdraw') end
    return res.ok, res
end
exports('RemoveMoney', RemoveMoney)
exports('RemoveGangMoney', RemoveMoney)

local function GetAccount(accountName)
    if Accounts[accountName] then
        return Accounts[accountName]
    end
    return nil
end
exports('GetAccount', GetAccount)
exports('GetGangAccount', GetAccount)

local function GetAccountBalance(accountName)
    local account = GetAccount(accountName)
    return account and account.account_balance or 0
end
exports('GetAccountBalance', GetAccountBalance)

-- Callbacks

QBCore.Functions.CreateCallback('qb-banking:server:openBank', function(source, cb)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return end
    local job = Player.PlayerData.job
    local gang = Player.PlayerData.gang
    local accounts = {}
    local statements = {}
    if job.name ~= 'unemployed' and not Accounts[job.name] then CreateJobAccount(job.name, 0) end
    if gang.name ~= 'none' and not Accounts[gang.name] then CreateGangAccount(gang.name, 0) end
    accounts[#accounts + 1] = { account_name = 'checking', account_type = 'checking', account_balance = Player.PlayerData.money.bank }
    statements['checking'] = Statements[citizenid] and Statements[citizenid]['checking'] or {}
    for accountName, accountInfo in pairs(Accounts) do
        if accountInfo.citizenid == citizenid then
            accounts[#accounts + 1] = accountInfo
            if Statements[accountName] then statements[accountName] = Statements[accountName] end
        end
        if accountInfo.users and string.find(accountInfo.users, citizenid) then
            accounts[#accounts + 1] = accountInfo
            if Statements[accountName] then statements[accountName] = Statements[accountName] end
        end
        if (accountName == job.name and job.isboss) or (accountName == gang.name and gang.isboss) then
            accounts[#accounts + 1] = accountInfo
            if Statements[accountName] then statements[accountName] = Statements[accountName] end
        end
    end
    cb(accounts, statements, Player.PlayerData)
end)

QBCore.Functions.CreateCallback('qb-banking:server:openATM', function(source, cb)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return end
    local bankCards = exports['pfm-inventory']:GetItemsByName(src, 'bank_card') -- inventory method, not on Player API
    if not bankCards then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.card'), 'error') end
    local acceptablePins = {}
    for _, bankCard in ipairs(bankCards) do acceptablePins[#acceptablePins + 1] = bankCard.info.cardPin end
    local job = Player.PlayerData.job
    local gang = Player.PlayerData.gang
    local accounts = {}
    accounts[#accounts + 1] = { account_name = 'checking', account_type = 'checking', account_balance = Player.PlayerData.money.bank }
    for accountName, accountInfo in pairs(Accounts) do
        if accountInfo.citizenid == citizenid then
            accounts[#accounts + 1] = accountInfo
        end
        if accountInfo.users and string.find(accountInfo.users, citizenid) then
            accounts[#accounts + 1] = accountInfo
        end
        if (accountName == job.name and job.isboss) or (accountName == gang.name and gang.isboss) then
            accounts[#accounts + 1] = accountInfo
        end
    end
    cb(accounts, Player.PlayerData, acceptablePins)
end)

QBCore.Functions.CreateCallback('qb-banking:server:withdraw', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    if type(data) ~= 'table' then return cb({ success = false, message = Lang:t('error.error') }) end
    local accountName = data.accountName
    local withdrawAmount = PFLedger.Amount(data.amount)
    if not withdrawAmount then return cb({ success = false, message = Lang:t('error.amount') }) end
    local reason = (type(data.reason) == 'string' and data.reason ~= '' and data.reason:sub(1, 50)) or 'Bank Withdrawal'
    if accountName == 'checking' then
        local res = bankTransfer(src, citizenid, 'player:' .. citizenid .. ':bank', 'player:' .. citizenid .. ':cash', withdrawAmount, 'withdraw', reason)
        if not res.ok then return cb({ success = false, message = ledgerError(res) }) end
        CreateBankStatement(src, 'checking', withdrawAmount, reason, 'withdraw', 'player')
        return cb({ success = true, message = Lang:t('success.withdraw') })
    end
    local account = Accounts[accountName]
    if not account then return cb({ success = false, message = Lang:t('error.account') }) end
    if not canUseAccount(Player, account) then return cb({ success = false, message = Lang:t('error.access') }) end
    local res = bankTransfer(src, citizenid, 'society:' .. accountName, 'player:' .. citizenid .. ':cash', withdrawAmount, 'withdraw', reason)
    if not res.ok then return cb({ success = false, message = ledgerError(res) }) end
    appendAccountStatement(accountName, withdrawAmount, reason, 'withdraw')
    cb({ success = true, message = Lang:t('success.withdraw') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:deposit', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    if type(data) ~= 'table' then return cb({ success = false, message = Lang:t('error.error') }) end
    local accountName = data.accountName
    local depositAmount = PFLedger.Amount(data.amount)
    if not depositAmount then return cb({ success = false, message = Lang:t('error.amount') }) end
    local reason = (type(data.reason) == 'string' and data.reason ~= '' and data.reason:sub(1, 50)) or 'Bank Deposit'
    if accountName == 'checking' then
        local res = bankTransfer(src, citizenid, 'player:' .. citizenid .. ':cash', 'player:' .. citizenid .. ':bank', depositAmount, 'deposit', reason)
        if not res.ok then return cb({ success = false, message = ledgerError(res) }) end
        CreateBankStatement(src, 'checking', depositAmount, reason, 'deposit', 'player')
        return cb({ success = true, message = Lang:t('success.deposit') })
    end
    local account = Accounts[accountName]
    if not account then return cb({ success = false, message = Lang:t('error.account') }) end
    if not canUseAccount(Player, account) then return cb({ success = false, message = Lang:t('error.access') }) end
    local res = bankTransfer(src, citizenid, 'player:' .. citizenid .. ':cash', 'society:' .. accountName, depositAmount, 'deposit', reason)
    if not res.ok then return cb({ success = false, message = ledgerError(res) }) end
    appendAccountStatement(accountName, depositAmount, reason, 'deposit')
    cb({ success = true, message = Lang:t('success.deposit') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:internalTransfer', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    if type(data) ~= 'table' then return cb({ success = false, message = Lang:t('error.error') }) end
    local fromAccountName = data.fromAccountName
    local toAccountName = data.toAccountName
    local transferAmount = PFLedger.Amount(data.amount)
    if not transferAmount then return cb({ success = false, message = Lang:t('error.amount') }) end
    local reason = (type(data.reason) == 'string' and data.reason ~= '' and data.reason:sub(1, 50)) or 'Internal transfer'
    if fromAccountName == toAccountName then return cb({ success = false, message = Lang:t('error.error') }) end

    local fromRef, toRef
    if fromAccountName == 'checking' then
        fromRef = 'player:' .. citizenid .. ':bank'
    else
        local account = Accounts[fromAccountName]
        if not account then return cb({ success = false, message = Lang:t('error.account') }) end
        if not canUseAccount(Player, account) then return cb({ success = false, message = Lang:t('error.access') }) end
        fromRef = 'society:' .. fromAccountName
    end
    if toAccountName == 'checking' then
        toRef = 'player:' .. citizenid .. ':bank'
    else
        if not Accounts[toAccountName] then return cb({ success = false, message = Lang:t('error.account') }) end
        toRef = 'society:' .. toAccountName
    end

    local res = bankTransfer(src, citizenid, fromRef, toRef, transferAmount, 'transfer', reason)
    if not res.ok then return cb({ success = false, message = ledgerError(res) }) end
    if fromAccountName == 'checking' then
        CreateBankStatement(src, 'checking', transferAmount, reason, 'withdraw', 'player')
    else
        appendAccountStatement(fromAccountName, transferAmount, reason, 'withdraw')
    end
    if toAccountName == 'checking' then
        CreateBankStatement(src, 'checking', transferAmount, reason, 'deposit', 'player')
    else
        appendAccountStatement(toAccountName, transferAmount, reason, 'deposit')
    end
    cb({ success = true, message = Lang:t('success.transfer') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:externalTransfer', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    if type(data) ~= 'table' or type(data.toAccountNumber) ~= 'string' then return cb({ success = false, message = Lang:t('error.error') }) end
    local toCitizenId = data.toAccountNumber
    if toCitizenId == citizenid or not toCitizenId:match('^[%w]+$') then return cb({ success = false, message = Lang:t('error.error') }) end
    local fromAccountName = data.fromAccountName
    local transferAmount = PFLedger.Amount(data.amount)
    if not transferAmount then return cb({ success = false, message = Lang:t('error.amount') }) end
    local reason = (type(data.reason) == 'string' and data.reason ~= '' and data.reason:sub(1, 50)) or 'External transfer'

    local fromRef
    if fromAccountName == 'checking' then
        fromRef = 'player:' .. citizenid .. ':bank'
    else
        local account = Accounts[fromAccountName]
        if not account then return cb({ success = false, message = Lang:t('error.account') }) end
        if not canUseAccount(Player, account) then return cb({ success = false, message = Lang:t('error.access') }) end
        fromRef = 'society:' .. fromAccountName
    end

    -- the recipient may be offline: the ledger credits offline players atomically
    local res = bankTransfer(src, citizenid, fromRef, 'player:' .. toCitizenId .. ':bank', transferAmount, 'transfer', reason)
    if not res.ok then return cb({ success = false, message = ledgerError(res) }) end
    if fromAccountName == 'checking' then
        CreateBankStatement(src, 'checking', transferAmount, reason, 'withdraw', 'player')
    else
        appendAccountStatement(fromAccountName, transferAmount, reason, 'withdraw')
    end
    local toPlayer = exports['pfm-core']:GetPlayerByCitizenId(toCitizenId)
    if toPlayer then CreateBankStatement(toPlayer.PlayerData.source, 'checking', transferAmount, reason, 'deposit', 'player') end
    cb({ success = true, message = Lang:t('success.transfer') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:orderCard', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local cardNumber = math.random(1000000000000000, 9999999999999999)
    local pinNumber = tonumber(data.pin)
    if not pinNumber then return cb({ success = false, message = Lang:t('error.pin') }) end
    local info = {
        citizenid = citizenid,
        name = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname,
        cardNumber = cardNumber,
        cardPin = pinNumber,
    }
    exports['pfm-inventory']:AddItem(src, 'bank_card', 1, false, info, 'qb-banking:server:orderCard')
    cb({ success = true, message = Lang:t('success.card') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:openAccount', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    if type(data) ~= 'table' then return cb({ success = false, message = Lang:t('error.error') }) end
    local accountName = data.accountName
    if type(accountName) ~= 'string' or not accountName:match('^[%w_%-]+$') or #accountName > 50 or accountName == 'checking' then
        return cb({ success = false, message = Lang:t('error.error') })
    end
    if Accounts[accountName] then return cb({ success = false, message = Lang:t('error.error') }) end
    local initialAmount = 0
    if data.amount ~= nil and data.amount ~= '' and tonumber(data.amount) ~= 0 then
        initialAmount = PFLedger.Amount(data.amount)
        if not initialAmount then return cb({ success = false, message = Lang:t('error.amount') }) end
    end
    if GetNumberOfAccounts(citizenid) >= Config.maxAccounts then return cb({ success = false, message = Lang:t('error.accounts') }) end
    if Player.PlayerData.money.bank < initialAmount then return cb({ success = false, message = Lang:t('error.money') }) end
    -- the account opens empty; the initial deposit is a normal ledger transfer
    if not CreatePlayerAccount(src, accountName, 0, json.encode({})) then return cb({ success = false, message = Lang:t('error.error') }) end
    pcall(MySQL.insert.await, 'INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, 0)', { 'society:' .. accountName })
    if initialAmount > 0 then
        local res = bankTransfer(src, citizenid, 'player:' .. citizenid .. ':bank', 'society:' .. accountName, initialAmount, 'deposit', 'Initial deposit')
        if not res.ok then return cb({ success = false, message = ledgerError(res) }) end
        CreateBankStatement(src, accountName, initialAmount, 'Initial deposit', 'deposit', 'shared')
        CreateBankStatement(src, 'checking', initialAmount, 'Initial deposit for ' .. accountName, 'withdraw', 'player')
    end
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Account Opened', 'green', string.format('**%s** opened account **%s** with an initial deposit of **$%s**', GetPlayerName(src), accountName, initialAmount))
    cb({ success = true, message = Lang:t('success.account') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:renameAccount', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    if type(data) ~= 'table' then return cb({ success = false, message = Lang:t('error.error') }) end
    local oldName = data.oldName
    local newName = data.newName
    if type(newName) ~= 'string' or not newName:match('^[%w_%-]+$') or #newName > 50 or newName == 'checking' then return cb({ success = false, message = Lang:t('error.error') }) end
    if not Accounts[oldName] then return cb({ success = false, message = Lang:t('error.error') }) end
    if Accounts[newName] then return cb({ success = false, message = Lang:t('error.error') }) end
    if Accounts[oldName].citizenid ~= citizenid then return cb({ success = false, message = Lang:t('error.access') }) end
    local result = MySQL.update.await('UPDATE bank_accounts SET account_name = ? WHERE account_name = ? AND citizenid = ?', { newName, oldName, citizenid })
    if not result or result < 1 then return cb({ success = false, message = Lang:t('error.error') }) end
    Accounts[newName] = Accounts[oldName]
    Accounts[newName].account_name = newName
    Accounts[oldName] = nil
    -- ledger history stays under the old name; reconciliation restarts from the current balance
    pcall(MySQL.query.await, 'DELETE FROM pf_ledger_baselines WHERE account = ?', { 'society:' .. oldName })
    pcall(MySQL.insert.await, 'REPLACE INTO pf_ledger_baselines (account, balance) SELECT CONCAT(\'society:\', account_name), account_balance FROM bank_accounts WHERE account_name = ?', { newName })
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Account Renamed', 'red', string.format('**%s** renamed **%s** to **%s**', GetPlayerName(src), oldName, newName))
    cb({ success = true, message = Lang:t('success.rename') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:deleteAccount', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    if type(data) ~= 'table' then return cb({ success = false, message = Lang:t('error.error') }) end
    local accountName = data.accountName
    if not Accounts[accountName] then return cb({ success = false, message = Lang:t('error.error') }) end
    if Accounts[accountName].citizenid ~= citizenid then return cb({ success = false, message = Lang:t('error.access') }) end
    -- closing an account pays any remaining balance back to the owner instead of destroying it
    local remaining = tonumber(GetAccountBalance(accountName)) or 0
    if remaining > 0 then
        local res = bankTransfer(src, citizenid, 'society:' .. accountName, 'player:' .. citizenid .. ':bank', remaining, 'close_account', 'Account closed: ' .. accountName)
        if not res.ok then return cb({ success = false, message = ledgerError(res) }) end
        CreateBankStatement(src, 'checking', remaining, 'Closed ' .. accountName, 'deposit', 'player')
    end
    local result = MySQL.rawExecute.await('DELETE FROM bank_accounts WHERE account_name = ? AND citizenid = ? AND account_balance = 0', { accountName, citizenid })
    if not result then return cb({ success = false, message = Lang:t('error.error') }) end
    Accounts[accountName] = nil
    pcall(MySQL.query.await, 'DELETE FROM pf_ledger_baselines WHERE account = ?', { 'society:' .. accountName })
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Account Deleted', 'red', string.format('**%s** deleted account **%s**', GetPlayerName(src), accountName))
    cb({ success = true, message = Lang:t('success.delete') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:addUser', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local userToAdd = data.userName
    local accountName = data.accountName
    if not Accounts[accountName] then return cb({ success = false, message = Lang:t('error.account') }) end
    if Accounts[accountName].citizenid ~= citizenid then return cb({ success = false, message = Lang:t('error.access') }) end
    local account = Accounts[accountName]
    local users = json.decode(account.users)
    for _, cid in ipairs(users) do
        if cid == userToAdd then return cb({ success = false, message = Lang:t('error.user') }) end
    end
    users[#users + 1] = userToAdd
    local usersData = json.encode(users)
    Accounts[accountName].users = usersData
    local result = MySQL.update.await('UPDATE bank_accounts SET users = ? WHERE account_name = ? AND citizenid = ?', { usersData, accountName, citizenid })
    if not result then cb({ success = false, message = Lang:t('error.error') }) end
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'User Added', 'green', string.format('**%s** added **%s** to **%s**', GetPlayerName(src), userToAdd, accountName))
    cb({ success = true, message = Lang:t('success.userAdd') })
end)

QBCore.Functions.CreateCallback('qb-banking:server:removeUser', function(source, cb, data)
    local src = source
    local Player, citizenid = getPlayerAndCitizenId(src)
    if not Player or not citizenid then return cb({ success = false, message = Lang:t('error.error') }) end
    local userToRemove = data.userName
    local accountName = data.accountName
    if not Accounts[accountName] then return cb({ success = false, message = Lang:t('error.account') }) end
    if Accounts[accountName].citizenid ~= citizenid then return cb({ success = false, message = Lang:t('error.access') }) end
    local account = Accounts[accountName]
    local users = json.decode(account.users)
    local userFound = false
    for i = #users, 1, -1 do
        if users[i] == userToRemove then
            table.remove(users, i)
            userFound = true
            break
        end
    end
    if not userFound then return cb({ success = false, message = Lang:t('error.noUser') }) end
    local usersData = json.encode(users)
    Accounts[accountName].users = usersData
    local result = MySQL.update.await('UPDATE bank_accounts SET users = ? WHERE account_name = ? AND citizenid = ?', { usersData, accountName, citizenid })
    if not result then cb({ success = false, message = Lang:t('error.error') }) end
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'User Removed', 'red', string.format('**%s** removed **%s** from **%s**', GetPlayerName(src), userToRemove, accountName))
    cb({ success = true, message = Lang:t('success.userRemove') })
end)

-- Items

QBCore.Functions.CreateUseableItem('bank_card', function(source, item)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if exports['pfm-inventory']:GetItemByName(source, item.name) then -- inventory method, not on Player API
        TriggerClientEvent('qb-banking:client:useCard', source)
    end
end)

-- Threads

CreateThread(function()
    -- the ledger migration widens bank_accounts and creates the baseline table first
    while not PFLedger.ready and not PFLedger.failed do Wait(100) end
    local accounts = MySQL.query.await('SELECT * FROM bank_accounts')

    for _, account in ipairs(accounts) do
        Accounts[account.account_name] = account
    end

    for job in pairs(QBCore.Shared.Jobs) do
        if Accounts[job] == nil then
            CreateJobAccount(job, 0)
        end
    end
end)

CreateThread(function()
    local statements = MySQL.query.await('SELECT * FROM bank_statements')
    for _, statement in ipairs(statements) do
        if statement.account_name == 'checking' then
            if not Statements[statement.citizenid] then Statements[statement.citizenid] = {} end
            if not Statements[statement.citizenid][statement.account_name] then Statements[statement.citizenid][statement.account_name] = {} end
            Statements[statement.citizenid][statement.account_name][#Statements[statement.citizenid][statement.account_name] + 1] = statement
        else
            if not Statements[statement.account_name] then Statements[statement.account_name] = {} end
            Statements[statement.account_name][#Statements[statement.account_name] + 1] = statement
        end
    end
end)

-- Commands

QBCore.Commands.Add('givecash', 'Give Cash', { { name = 'id', help = 'Player ID' }, { name = 'amount', help = 'Amount' } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local target = exports['pfm-core']:GetPlayer(tonumber(args[1]))
    if not target then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.noUser'), 'error') end
    local targetPed = GetPlayerPed(tonumber(args[1]))
    local targetCoords = GetEntityCoords(targetPed)
    local amount = PFLedger.Amount(args[2])
    if not amount then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.amount'), 'error') end
    if target.PlayerData.source == src then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.noUser'), 'error') end
    if #(playerCoords - targetCoords) > 5 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.toofar'), 'error') end
    local res = bankTransfer(src, Player.PlayerData.citizenid, 'player:' .. Player.PlayerData.citizenid .. ':cash', 'player:' .. target.PlayerData.citizenid .. ':cash', amount, 'cash_transfer', 'cash transfer')
    if not res.ok then return TriggerClientEvent('QBCore:Notify', src, ledgerError(res), 'error') end
    TriggerClientEvent('QBCore:Notify', src, string.format(Lang:t('success.give'), amount), 'success')
    TriggerClientEvent('QBCore:Notify', target.PlayerData.source, string.format(Lang:t('success.receive'), amount), 'success')
end)
