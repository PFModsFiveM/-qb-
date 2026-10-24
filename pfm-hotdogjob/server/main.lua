local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local Bail = {}
local Sessions = {}
local SrcToCid = {}

local function applyStreakBonus(streak, amount)
    local sb = Config.StreakBonus
    if not sb or not sb.enabled or streak <= 0 then return amount end
    local mult = math.min(streak * (sb.perDelivery or 0.02), sb.cap or 0.25)
    return math.floor(amount * (1.0 + mult) + 0.5)
end

-- Highest unit price any quality/level combination can legitimately produce
local function getMaxUnitPrice()
    local maxPrice = 0
    for _, stock in pairs(Config.Stock) do
        if type(stock.Price) == 'table' then
            if stock.Price.max then
                if stock.Price.max > maxPrice then maxPrice = stock.Price.max end
            else
                for _, level in pairs(stock.Price) do
                    if type(level) == 'table' and level.max and level.max > maxPrice then maxPrice = level.max end
                end
            end
        end
    end
    return maxPrice
end

-- Callbacks

QBCore.Functions.CreateCallback('qb-hotdogjob:server:HasMoney', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then cb(false) return end

    if Player.PlayerData.money.bank >= Config.StandDeposit then
        Player.RemoveMoney('bank', Config.StandDeposit, 'hot dog deposit')
        Bail[Player.PlayerData.citizenid] = true
        Sessions[source] = { startedAt = os.time(), streak = 0, lastSale = 0 }
        SrcToCid[source] = Player.PlayerData.citizenid
        cb(true)
    else
        Bail[Player.PlayerData.citizenid] = false
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-hotdogjob:server:BringBack', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then cb(false) return end

    if Bail[Player.PlayerData.citizenid] then
        Bail[Player.PlayerData.citizenid] = nil
        Sessions[source] = nil
        Player.AddMoney('bank', Config.StandDeposit, 'hot dog deposit')
        cb(true)
    else
        cb(false)
    end
end)

-- Events

RegisterNetEvent('qb-hotdogjob:server:Sell', function(coords, amount, price)
    local src = source
    local pCoords = GetEntityCoords(GetPlayerPed(src))
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if #(pCoords - coords) > 4 then exports['pfm-core']:ExploitBan(src, 'hotdog job') end

    -- Session validation: must have an active stand (deposit paid, not returned)
    local session = Sessions[src]
    if not session or not Bail[Player.PlayerData.citizenid] then return end

    -- Per-sale cooldown scaled to the customer loop
    local now = os.time()
    if (now - session.lastSale) < (Config.SaleCooldown or 5) then return end

    -- Clamp client-sent values to config limits
    local sellAmount = math.floor(tonumber(amount) or 0)
    local sellPrice = tonumber(price) or 0
    if sellAmount <= 0 or sellPrice <= 0 then return end
    sellAmount = math.min(sellAmount, Config.MaxSalePerCustomer or 3)
    sellPrice = math.min(sellPrice, getMaxUnitPrice())

    local hotdogItem = Player.Functions.GetItemByName('hotdog')
    if not hotdogItem or not hotdogItem.amount or hotdogItem.amount < sellAmount then return end

    local removed = Player.Functions.RemoveItem('hotdog', sellAmount)
    if not removed then return end

    session.lastSale = now
    local payout = applyStreakBonus(session.streak, sellAmount * sellPrice)
    session.streak = session.streak + 1

    Player.AddMoney('cash', payout, 'sold hotdog')
end)

AddEventHandler('playerDropped', function()
    local src = source
    Sessions[src] = nil
    if SrcToCid[src] then
        Bail[SrcToCid[src]] = nil
        SrcToCid[src] = nil
    end
end)

RegisterNetEvent('qb-hotdogjob:server:UpdateReputation', function(quality)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    -- Only players with an active stand session can gain reputation, at most once per cook cycle
    local session = Sessions[src]
    if not session or not Bail[Player.PlayerData.citizenid] then return end
    local now = os.time()
    if session.lastRep and (now - session.lastRep) < (Config.RepCooldown or 3) then return end
    session.lastRep = now
    if quality == 'exotic' then
        if Player.GetRep('hotdog') + 3 > Config.MaxReputation then
            Player.AddRep('hotdog', Config.MaxReputation - Player.GetRep('hotdog'))
        else
            Player.AddRep('hotdog', 3)
        end
    elseif quality == 'rare' then
        if Player.GetRep('hotdog') + 2 > Config.MaxReputation then
            Player.AddRep('hotdog', Config.MaxReputation - Player.GetRep('hotdog'))
        else
            Player.AddRep('hotdog', 2)
        end
    elseif quality == 'common' then
        if Player.GetRep('hotdog') + 1 > Config.MaxReputation then
            Player.AddRep('hotdog', Config.MaxReputation - Player.GetRep('hotdog'))
        else
            Player.AddRep('hotdog', 1)
        end
    end

    TriggerClientEvent('qb-hotdogjob:client:UpdateReputation', src, Player.PlayerData.metadata['rep'])
end)

-- Commands

QBCore.Commands.Add('removestand', Lang:t('info.command'), {}, false, function(source, _)
    TriggerClientEvent('qb-hotdogjob:staff:DeletStand', source)
end, 'admin')
