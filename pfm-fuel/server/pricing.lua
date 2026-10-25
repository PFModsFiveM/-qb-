-- PF gameplay pack: per-station dynamic fuel prices + city sales tax

local stationMults = {}

local function round2(n) return math.floor(n * 100 + 0.5) / 100 end

local function refreshPrices()
    local cfg = Config.DynamicPricing or {}
    local minM, maxM = cfg.MinMult or 0.85, cfg.MaxMult or 1.25
    for i = 1, #Config.GasStations do
        if cfg.Enabled then
            stationMults[i] = round2(minM + math.random() * (maxM - minM))
        else
            stationMults[i] = 1.0
        end
    end
    TriggerClientEvent('qb-fuel:client:syncPrices', -1, stationMults)
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    math.randomseed(os.time())
    refreshPrices()
    local hours = (Config.DynamicPricing and Config.DynamicPricing.RefreshHours) or 6
    if hours > 0 then
        CreateThread(function()
            while true do
                Wait(hours * 3600 * 1000)
                refreshPrices()
            end
        end)
    end
end)

-- server-only: pfm-core raises it with TriggerEvent (as a net event any client could fake a player
-- object and send the prices to any player id)
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if Player and Player.PlayerData and Player.PlayerData.source then
        TriggerClientEvent('qb-fuel:client:syncPrices', Player.PlayerData.source, stationMults)
    end
end)

-- nearest station to given coords, nil when too far from any pump area
function GetStationIndexForCoords(coords)
    local best, bestDist = nil, 60.0
    for i = 1, #Config.GasStations do
        local dist = #(coords - Config.GasStations[i])
        if dist < bestDist then
            best, bestDist = i, dist
        end
    end
    return best
end

function GetStationFuelPrice(index)
    local mult = (index and stationMults[index]) or 1.0
    return round2(Config.FuelPrice * mult)
end

function GetFuelTaxRate()
    if not Config.FuelSalesTax or GetResourceState('pf-government') ~= 'started' then return 0 end
    local ok, rate = pcall(function() return exports['pf-government']:GetSalesTaxRate() end)
    if not ok then return 0 end
    rate = tonumber(rate) or 0
    if rate > 1 then rate = rate / 100 end -- accept either percent or decimal
    if rate < 0 or rate > 0.5 then return 0 end
    return rate
end

--- Hands the tax already inside the pump price to pf-government by its exact amount (keyed by the
--- purchase), so the treasury gets what the driver paid, once.
function CollectFuelTax(subtotal, citizenid, tax, key)
    if subtotal <= 0 or not Config.FuelSalesTax or GetResourceState('pf-government') ~= 'started' then return 0 end
    tax = tonumber(tax) or 0
    if tax <= 0 then return 0 end
    local ok, value = pcall(function()
        return exports['pf-government']:CollectTaxAmount(tax, 'sales', 'player', citizenid, 'fuel-pump', key and (key .. ':tax') or nil, subtotal)
    end)
    if not ok then return 0 end
    return tonumber(value) or 0
end

-- all-in per-litre price at the pump the player is standing at
QBCore.Functions.CreateCallback('qb-fuel:server:getPumpPrice', function(src, cb)
    local coords = GetEntityCoords(GetPlayerPed(src))
    local index = GetStationIndexForCoords(coords)
    local perLitre = GetStationFuelPrice(index)
    local taxRate = GetFuelTaxRate()
    cb(round2(perLitre * (1 + taxRate)), perLitre, taxRate * 100)
end)
