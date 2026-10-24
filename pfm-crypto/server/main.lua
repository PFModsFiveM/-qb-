-- Variables
local coin = Crypto.Coin
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local bannedCharacters = { '%', '$', ';' }

-- Per-source event cooldowns (anti-spam); cleared on disconnect
local eventCooldowns = {}
local function onCooldown(src, key, ms)
    local now = GetGameTimer()
    local t = eventCooldowns[src]
    if not t then
        t = {}
        eventCooldowns[src] = t
    end
    if t[key] and (now - t[key]) < ms then return true end
    t[key] = now
    return false
end
AddEventHandler('playerDropped', function()
    eventCooldowns[source] = nil
end)

-- Sanitize a client-sent coin amount: finite, positive, bounded, 4 decimal places
local function sanitizeCoins(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n * 10000) / 10000
    if n <= 0 or n > (Crypto.MaxTransaction or 10000) then return nil end
    return n
end

local function clampWorth(value)
    if value < Crypto.Lower then return Crypto.Lower end
    if value > Crypto.Upper then return Crypto.Upper end
    return value
end

-- Function
local function RefreshCrypto()
    local result = MySQL.query.await('SELECT * FROM crypto WHERE crypto = ?', { coin })
    if result ~= nil and result[1] ~= nil then
        Crypto.Worth[coin] = result[1].worth
        if result[1].history ~= nil then
            Crypto.History[coin] = json.decode(result[1].history)
            TriggerClientEvent('qb-crypto:client:UpdateCryptoWorth', -1, coin, result[1].worth, json.decode(result[1].history))
        else
            TriggerClientEvent('qb-crypto:client:UpdateCryptoWorth', -1, coin, result[1].worth, nil)
        end
    end
end

local function ErrorHandle(error)
    for k, v in pairs(Ticker.Error_handle) do
        if string.match(error, k) then
            return v
        end
    end
    return false
end

local function GetTickerPrice() -- Touch = no help
    local ticker_promise = promise.new()
    PerformHttpRequest('https://min-api.cryptocompare.com/data/price?fsym=' .. Ticker.coin .. '&tsyms=' .. Ticker.currency .. '&api_key=' .. Ticker.Api_key, function(Error, Result, _)
        local result_obj = json.decode(Result)
        if not result_obj['Response'] then
            local this_resolve = { error = Error, response_data = result_obj[string.upper(Ticker.currency)] }
            ticker_promise:resolve(this_resolve) --- Could resolve Error aswell for more accurate Error messages? Solved in else
        else
            local this_resolve = { error = result_obj['Message'] }
            ticker_promise:resolve(this_resolve)
        end
    end, 'GET')
    Citizen.Await(ticker_promise)
    if type(ticker_promise.value.error) ~= 'number' then
        local get_user_friendly_error = ErrorHandle(ticker_promise.value.error)
        if get_user_friendly_error then
            return get_user_friendly_error
        else
            return '\27[31m Unexpected error \27[0m' --- Raised an error which we did not expect, script should be capable of sticking with last recorded price and shutting down the sync logic
        end
    else
        return ticker_promise.value.response_data
    end
end

local function HandlePriceChance()
    local currentValue = Crypto.Worth[coin]
    local prevValue = Crypto.Worth[coin]
    local trend = math.random(0, 100)
    local event = math.random(0, 100)
    local chance = event - Crypto.ChanceOfCrashOrLuck

    if event > chance then
        if trend <= Crypto.ChanceOfDown then
            currentValue = currentValue - math.random(Crypto.CasualDown[1], Crypto.CasualDown[2])
        elseif trend >= Crypto.ChanceOfUp then
            currentValue = currentValue + math.random(Crypto.CasualUp[1], Crypto.CasualUp[2])
        end
    else
        if math.random(0, 1) == 1 then
            currentValue = currentValue + math.random(Crypto.Luck[1], Crypto.Luck[2])
        else
            currentValue = currentValue - math.random(Crypto.Crash[1], Crypto.Crash[2])
        end
    end

    if currentValue <= Crypto.Lower then
        currentValue = Crypto.Lower
    elseif currentValue >= Crypto.Upper then
        currentValue = Crypto.Upper
    end

    if Crypto.History[coin][4] then
        -- Shift array index 1 to 3
        for k = 3, 1, -1 do
            Crypto.History[coin][k] = Crypto.History[coin][k + 1]
        end
        -- Assign array index 4 to the latest result
        Crypto.History[coin][4] = { PreviousWorth = prevValue, NewWorth = currentValue }
    else
        Crypto.History[coin][#Crypto.History[coin] + 1] = { PreviousWorth = prevValue, NewWorth = currentValue }
    end

    Crypto.Worth[coin] = currentValue

    local history = json.encode(Crypto.History[coin])
    local props = {
        ['worth'] = currentValue,
        ['history'] = history,
        ['crypto'] = coin
    }
    MySQL.update(
        'UPDATE crypto set worth = :worth, history = :history where crypto = :crypto',
        props,
        function(affectedRows)
            if affectedRows < 1 then
                print('Crypto not found, inserting new record for ' .. coin)
                MySQL.insert('INSERT INTO crypto (crypto, worth, history) VALUES (:crypto, :worth, :history)', props)
            end
            RefreshCrypto()
        end
    )
end

-- Commands

QBCore.Commands.Add('setcryptoworth', 'Set crypto value', { { name = 'crypto', help = 'Name of the crypto currency' }, { name = 'Value', help = 'New value of the crypto currency' } }, false, function(source, args)
    local src = source
    local crypto = tostring(args[1])

    if crypto ~= nil then
        if Crypto.Worth[crypto] ~= nil then
            local NewWorth = tonumber(args[2])
            if NewWorth then NewWorth = clampWorth(math.ceil(NewWorth)) end -- keep admin-set values within configured bounds

            if NewWorth ~= nil then
                local PercentageChange = math.ceil(((NewWorth - Crypto.Worth[crypto]) / Crypto.Worth[crypto]) * 100)
                local ChangeLabel = '+'

                if PercentageChange < 0 then
                    ChangeLabel = '-'
                    PercentageChange = (PercentageChange * -1)
                end

                if Crypto.Worth[crypto] == 0 then
                    PercentageChange = 0
                    ChangeLabel = ''
                end

                Crypto.History[crypto][#Crypto.History[crypto] + 1] = {
                    PreviousWorth = Crypto.Worth[crypto],
                    NewWorth = NewWorth
                }

                TriggerClientEvent('QBCore:Notify', src, 'You have changed the value of ' .. Crypto.Labels[crypto] .. ' from: $' .. Crypto.Worth[crypto] .. ' to: $' .. NewWorth .. ' (' .. ChangeLabel .. ' ' .. PercentageChange .. '%)')
                Crypto.Worth[crypto] = NewWorth
                TriggerClientEvent('qb-crypto:client:UpdateCryptoWorth', -1, crypto, NewWorth)
                MySQL.insert('INSERT INTO crypto (worth, history) VALUES (:worth, :history) ON DUPLICATE KEY UPDATE worth = :worth, history = :history', {
                    ['worth'] = NewWorth,
                    ['history'] = json.encode(Crypto.History[crypto]),
                })
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('text.you_have_not_given_a_new_value', { crypto = Crypto.Worth[crypto] }))
            end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('text.this_crypto_does_not_exist'))
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('text.you_have_not_provided_crypto_available_qbit'))
    end
end, 'admin')

QBCore.Commands.Add('checkcryptoworth', '', {}, false, function(source)
    local src = source
    TriggerClientEvent('QBCore:Notify', src, Lang:t('text.the_qbit_has_a_value_of', { crypto = Crypto.Worth['qbit'] }))
end)

QBCore.Commands.Add('crypto', '', {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local MyPocket = math.ceil(Player.PlayerData.money.crypto * Crypto.Worth['qbit'])

    TriggerClientEvent('QBCore:Notify', src, Lang:t('text.you_have_with_a_value_of', { playerPlayerDataMoneyCrypto = Player.PlayerData.money.crypto, mypocket = MyPocket }))
end)

-- Events

RegisterServerEvent('qb-crypto:server:FetchWorth', function()
    local src = source
    if src and src > 0 and onCooldown(src, 'fetchWorth', 10000) then return end -- DB query + global broadcast, keep it slow
    for name, _ in pairs(Crypto.Worth) do
        local result = MySQL.query.await('SELECT * FROM crypto WHERE crypto = ?', { name })
        if result[1] ~= nil then
            Crypto.Worth[name] = result[1].worth
            if result[1].history ~= nil then
                Crypto.History[name] = json.decode(result[1].history)
                TriggerClientEvent('qb-crypto:client:UpdateCryptoWorth', -1, name, result[1].worth, json.decode(result[1].history))
            else
                TriggerClientEvent('qb-crypto:client:UpdateCryptoWorth', -1, name, result[1].worth, nil)
            end
        end
    end
end)

-- The exchange terminal. Exchanges happen at it, and only while it is online; its reboot after a
-- failed exchange is run by the server (clients used to set the reboot state for everyone, and could
-- exchange from anywhere).
local EXCHANGE_RANGE = 3.0
local REBOOT_SECONDS = 120

local function atExchange(src)
    local p = GetEntityCoords(GetPlayerPed(src))
    return #(vector3(p.x, p.y, p.z) - Crypto.Exchange.coords) <= EXCHANGE_RANGE
end

local function StartReboot()
    if Crypto.Exchange.RebootInfo.state then return end
    Crypto.Exchange.RebootInfo.state = true
    Crypto.Exchange.RebootInfo.percentage = 0
    TriggerClientEvent('qb-crypto:client:SyncReboot', -1)
    CreateThread(function()
        local step = REBOOT_SECONDS * 10 -- ms per percent
        while Crypto.Exchange.RebootInfo.percentage < 100 do
            Wait(step)
            Crypto.Exchange.RebootInfo.percentage = Crypto.Exchange.RebootInfo.percentage + 1
        end
        Crypto.Exchange.RebootInfo.state = false
        Crypto.Exchange.RebootInfo.percentage = 0
        TriggerClientEvent('qb-crypto:client:GetRebootState', -1, Crypto.Exchange.RebootInfo)
    end)
end

RegisterServerEvent('qb-crypto:server:ExchangeFail', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if onCooldown(src, 'exchange', 5000) then return end
    if not atExchange(src) or Crypto.Exchange.RebootInfo.state then return end
    if exports['pfm-inventory']:RemoveItem(src, 'cryptostick', 1, false, 'qb-crypto:server:ExchangeFail') then
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['cryptostick'], 'remove')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.cryptostick_malfunctioned'), 'error')
        StartReboot()
    end
end)

-- Clients still report reboot progress; the server keeps its own state and ignores these.
RegisterServerEvent('qb-crypto:server:Rebooting', function() end)
RegisterServerEvent('qb-crypto:server:SyncReboot', function() end)

RegisterServerEvent('qb-crypto:server:GetRebootState', function()
    local src = source
    TriggerClientEvent('qb-crypto:client:GetRebootState', src, Crypto.Exchange.RebootInfo)
end)

RegisterServerEvent('qb-crypto:server:ExchangeSuccess', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if onCooldown(src, 'exchange', 5000) then return end
    if not atExchange(src) or Crypto.Exchange.RebootInfo.state then return end
    local ItemData = Player.GetItemByName('cryptostick')
    if ItemData ~= nil then
        local DeelNumber = 1000000
        local Amount = (math.random(611111, 1599999) / DeelNumber)
        if math.random(1, 10) == 1 then -- the lucky roll is the server's own
            Amount = (math.random(1599999, 2599999) / DeelNumber)
        end
        -- the stick is used up before the coins are credited
        if not exports['pfm-inventory']:RemoveItem(src, 'cryptostick', 1, false, 'qb-crypto:server:ExchangeSuccess') then return end
        Player.AddMoney('crypto', Amount, 'qb-crypto:server:ExchangeSuccess')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.you_have_exchanged_your_cryptostick_for', { amount = Amount }), 'success', 3500)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['cryptostick'], 'remove')
        TriggerClientEvent('qb-phone:client:AddTransaction', src, Player, {}, Lang:t('credit.there_are_amount_credited', { amount = Amount }), 'Credit')
    end
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-crypto:server:HasSticky', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    local Item = Player.GetItemByName('cryptostick')

    if Item ~= nil then
        cb(true)
    else
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-crypto:server:GetCryptoData', function(source, cb, name)
    local Player = exports['pfm-core']:GetPlayer(source)
    local CryptoData = {
        History = Crypto.History[name],
        Worth = Crypto.Worth[name],
        Portfolio = Player.PlayerData.money.crypto,
        WalletId = Player.PlayerData.metadata['walletid'],
    }

    cb(CryptoData)
end)

QBCore.Functions.CreateCallback('qb-crypto:server:BuyCrypto', function(source, cb, data)
    local Player = exports['pfm-core']:GetPlayer(source)
    local coins = sanitizeCoins(data and data.Coins)
    if not Player or not coins then return cb(false) end
    if onCooldown(source, 'buy', 1000) then return cb(false) end
    -- rounded up: rounding down let tiny buys cost less than they were worth, over and over
    local total_price = math.ceil(coins * tonumber(Crypto.Worth['qbit']))
    if total_price > 0 and Player.PlayerData.money.bank >= total_price then
        local CryptoData = {
            History = Crypto.History['qbit'],
            Worth = Crypto.Worth['qbit'],
            Portfolio = Player.PlayerData.money.crypto + coins,
            WalletId = Player.PlayerData.metadata['walletid'],
        }
        if not Player.RemoveMoney('bank', total_price, 'bought crypto') then return cb(false) end
        TriggerClientEvent('qb-phone:client:AddTransaction', source, Player, data, Lang:t('credit.you_have_qbit_purchased', { dataCoins = coins }), 'Credit')
        Player.AddMoney('crypto', coins, 'bought crypto')
        cb(CryptoData)
    else
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-crypto:server:SellCrypto', function(source, cb, data)
    local Player = exports['pfm-core']:GetPlayer(source)
    local coins = sanitizeCoins(data and data.Coins)
    if not Player or not coins then return cb(false) end

    if Player.PlayerData.money.crypto >= coins then
        local CryptoData = {
            History = Crypto.History['qbit'],
            Worth = Crypto.Worth['qbit'],
            Portfolio = Player.PlayerData.money.crypto - coins,
            WalletId = Player.PlayerData.metadata['walletid'],
        }
        Player.RemoveMoney('crypto', coins, 'sold crypto')
        local amount = math.floor(coins * tonumber(Crypto.Worth['qbit']))
        TriggerClientEvent('qb-phone:client:AddTransaction', source, Player, data, Lang:t('debit.you_have_sold', { dataCoins = coins }), 'Debit')
        Player.AddMoney('bank', amount, 'sold crypto')
        cb(CryptoData)
    else
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-crypto:server:TransferCrypto', function(source, cb, data)
    if type(data) ~= 'table' then return cb('notvalid') end
    if onCooldown(source, 'transfer', 2000) then return cb('notvalid') end
    local newCoin = tostring(data.Coins)
    local newWalletId = tostring(data.WalletId)
    for _, v in pairs(bannedCharacters) do
        newCoin = string.gsub(newCoin, '%' .. v, '')
        newWalletId = string.gsub(newWalletId, '%' .. v, '')
    end
    data.WalletId = newWalletId
    data.Coins = sanitizeCoins(newCoin)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or not data.Coins then return cb('notvalid') end
    if data.WalletId == '' or #data.WalletId > 64 or data.WalletId == Player.PlayerData.metadata['walletid'] then return cb('notvalid') end
    if Player.PlayerData.money.crypto >= tonumber(data.Coins) then
        -- exact wallet match (a LIKE pattern let '_' and '%' match other people's wallets)
        local result = MySQL.query.await("SELECT * FROM `players` WHERE JSON_UNQUOTE(JSON_EXTRACT(`metadata`, '$.walletid')) = ? LIMIT 1", { data.WalletId })
        if result[1] ~= nil then
            local CryptoData = {
                History = Crypto.History['qbit'],
                Worth = Crypto.Worth['qbit'],
                Portfolio = Player.PlayerData.money.crypto - tonumber(data.Coins),
                WalletId = Player.PlayerData.metadata['walletid'],
            }
            if not Player.RemoveMoney('crypto', tonumber(data.Coins), 'transfer crypto') then return cb('notenough') end
            TriggerClientEvent('qb-phone:client:AddTransaction', source, Player, data, 'You have ' .. tonumber(data.Coins) .. " Qbit('s) transferred!", 'Debit')
            local Target = QBCore.Functions.GetPlayerByCitizenId(result[1].citizenid)

            if Target ~= nil then
                Target.Functions.AddMoney('crypto', tonumber(data.Coins), 'transfer crypto')
                TriggerClientEvent('qb-phone:client:AddTransaction', Target.PlayerData.source, Player, data, 'There are ' .. tonumber(data.Coins) .. " Qbit('s) credited!", 'Credit')
            else
                -- one atomic update (read-then-write could lose coins if the player logged in meanwhile)
                MySQL.update([[UPDATE players SET money = JSON_SET(money, '$.crypto',
                    COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(money, '$.crypto')) AS DECIMAL(20,6)), 0) + ?) WHERE citizenid = ?]],
                    { tonumber(data.Coins), result[1].citizenid })
            end
            cb(CryptoData)
        else
            cb('notvalid')
        end
    else
        cb('notenough')
    end
end)

-- Threads

CreateThread(function()
    -- configurable update interval, floored at 1 minute so a bad config can't hot-loop price changes
    local interval = math.max(1, tonumber(Crypto.RefreshTimer) or 10)
    while true do
        Wait(interval * 60000)
        HandlePriceChance()
    end
end)

-- You touch = you break
if Ticker.Enabled then
    Citizen.CreateThread(function()
        local Interval = Ticker.tick_time * 60000
        if Ticker.tick_time < 2 then
            Interval = 120000
        end
        while (true) do
            local get_coin_price = GetTickerPrice()
            if type(get_coin_price) == 'number' then
                Crypto.Worth['qbit'] = clampWorth(get_coin_price) -- external API value can't push worth outside configured bounds
            else
                print('\27[31m' .. get_coin_price .. '\27[0m')
                Ticker.Enabled = false
                break
            end
            Citizen.Wait(Interval)
        end
    end)
end
