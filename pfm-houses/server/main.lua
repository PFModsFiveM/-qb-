local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands', 'Player' })
local houseowneridentifier = {}
local houseownercid = {}
local housekeyholders = {}
local housesLoaded = false

-- Threads

CreateThread(function()
    local HouseGarages = {}
    local result = MySQL.query.await('SELECT * FROM houselocations', {})
    if result[1] then
        for _, v in pairs(result) do
            local owned = false
            if tonumber(v.owned) == 1 then
                owned = true
            end
            local garage = json.decode(v.garage) or {}
            Config.Houses[v.name] = {
                coords = json.decode(v.coords),
                owned = owned,
                price = v.price,
                locked = true,
                adress = v.label,
                tier = v.tier,
                garage = garage,
                decorations = {}
            }
            HouseGarages[v.name] = {
                label = v.label,
                takeVehicle = garage
            }
        end
    end
    TriggerClientEvent('qb-garages:client:houseGarageConfig', -1, HouseGarages)
    TriggerClientEvent('qb-houses:client:setHouseConfig', -1, Config.Houses)
end)

CreateThread(function()
    while true do
        if not housesLoaded then
            MySQL.query('SELECT * FROM player_houses', {}, function(houses)
                if houses then
                    for _, house in pairs(houses) do
                        houseowneridentifier[house.house] = house.identifier
                        houseownercid[house.house] = house.citizenid
                        housekeyholders[house.house] = json.decode(house.keyholders)
                    end
                end
            end)
            housesLoaded = true
        end
        Wait(7)
    end
end)

-- Commands

QBCore.Commands.Add('decorate', Lang:t('info.decorate_interior'), {}, false, function(source)
    local src = source
    TriggerClientEvent('qb-houses:client:decorate', src)
end)

QBCore.Commands.Add('createhouse', Lang:t('info.create_house'), { { name = 'price', help = Lang:t('info.price_of_house') }, { name = 'tier', help = Lang:t('info.tier_number') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local price = tonumber(args[1])
    local tier = tonumber(args[2])
    if Player.PlayerData.job.name == 'realestate' then
        TriggerClientEvent('qb-houses:client:createHouses', src, price, tier)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.realestate_only'), 'error')
    end
end)

QBCore.Commands.Add('addgarage', Lang:t('info.add_garage'), {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.name == 'realestate' then
        TriggerClientEvent('qb-houses:client:addGarage', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.realestate_only'), 'error')
    end
end)

QBCore.Commands.Add('ring', Lang:t('info.ring_doorbell'), {}, false, function(source)
    local src = source
    TriggerClientEvent('qb-houses:client:RequestRing', src)
end)

-- Item

QBCore.Functions.CreateUseableItem('police_stormram', function(source, _)
    local Player = exports['pfm-core']:GetPlayer(source)
    if (Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty) then
        TriggerClientEvent('qb-houses:client:HomeInvasion', source)
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.emergency_services'), 'error')
    end
end)

-- Functions
local function isHouseOwner(identifier, cid, house)
    if houseowneridentifier[house] and houseownercid[house] then
        if houseowneridentifier[house] == identifier and houseownercid[house] == cid then
            return true
        end
    end
    return false
end

local function hasKey(identifier, cid, house)
    if houseowneridentifier[house] and houseownercid[house] then
        if houseowneridentifier[house] == identifier and houseownercid[house] == cid then
            return true
        else
            if housekeyholders[house] then
                for i = 1, #housekeyholders[house], 1 do
                    if housekeyholders[house][i] == cid then
                        return true
                    end
                end
            end
        end
    end
    return false
end

exports('hasKey', hasKey)

-- Money in this resource moves through the pfm-banking ledger (PFPayout, '@pfm-banking/payouts.lua'):
-- purchases are paid into system:pfm-houses and every payment has a fixed key, so a repeated or
-- interrupted request never charges or pays twice.

local function nearHouse(src, house, maxDist)
    local h = Config.Houses[house]
    local e = h and h.coords and h.coords.enter
    if not e then return false end
    return #(GetEntityCoords(GetPlayerPed(src)) - vector3(e.x, e.y, e.z)) <= (maxDist or 5.0)
end

local function isOnDutyPolice(Player)
    local job = Player and Player.PlayerData.job
    return job and job.type == 'leo' and job.onduty == true
end

-- server-side furniture prices (the client used to send the price)
local FurniturePrice = {}
for _, category in pairs(Config.Furniture or {}) do
    for _, item in ipairs(category.items or {}) do
        if type(item.object) == 'string' and tonumber(item.price) then FurniturePrice[item.object] = tonumber(item.price) end
    end
end
-- furniture bought but not yet saved into a house: [house][model] = count
local furnitureCredit = {}
local buyingHouse = {}   -- [house] = true while a purchase is being paid

--- Hands the property tax already paid into system:pfm-houses to pf-government; whatever the
--- government does not take goes back to the buyer's bank. Returns the tax collected.
local function settlePropertyTax(tax, cid, key, subtotal)
    tax = tonumber(tax) or 0
    if tax <= 0 then return 0 end
    local collected = 0
    if GetResourceState('pf-government') == 'started' then
        local ok, value = pcall(function()
            return exports['pf-government']:CollectTaxAmount(tax, 'property_transfer', 'citizen', cid, 'pfm-houses', key .. ':tax', subtotal)
        end)
        collected = ok and (tonumber(value) or 0) or 0
    end
    local uncollected = math.floor((tax - collected) * 100 + 0.5) / 100
    if uncollected > 0 then
        PFPayout.Pay(cid, 'bank', uncollected, { key = key .. ':tax-refund', kind = 'refund', reason = 'Uncollected property tax', quiet = true })
    end
    return collected
end

local function GetHouseStreetCount(street)
    local count = 0
    local query = '%' .. street .. '%'
    local result = MySQL.Sync.fetchSingle('SELECT * FROM houselocations WHERE name LIKE ? ORDER BY LENGTH(`name`) desc, `name` DESC', { query })
    if result then
        local houseAddress = result.name
        count = tonumber(string.match(houseAddress, '%d[%d.,]*'))
    end
    return (count + 1)
end

local function isHouseOwned(house)
    local result = MySQL.query.await('SELECT owned FROM houselocations WHERE name = ?', { house })
    if result[1] then
        if result[1].owned == 1 then
            return true
        end
    end
    return false
end

local function escape_sqli(source)
    local replacements = {
        ['"'] = '\\"',
        ["'"] = "\\'"
    }
    return source:gsub("['\"]", replacements)
end

-- Events

RegisterNetEvent('qb-houses:server:setHouses', function()
    local src = source
    TriggerClientEvent('qb-houses:client:setHouseConfig', src, Config.Houses)
end)

RegisterNetEvent('qb-houses:server:createBlip', function()
    local src = source
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    TriggerClientEvent('qb-houses:client:createBlip', -1, coords)
end)

RegisterNetEvent('qb-houses:server:addNewHouse', function(street, coords, price, tier)
    local src = source
    street = street:gsub("%'", '')
    price = tonumber(price)
    tier = tonumber(tier)
    local houseCount = GetHouseStreetCount(street)
    local name = street:lower() .. tostring(houseCount)
    local label = street .. ' ' .. tostring(houseCount)
    MySQL.insert('INSERT INTO houselocations (name, label, coords, owned, price, tier) VALUES (?, ?, ?, ?, ?, ?)',
        { name, label, json.encode(coords), 0, price, tier })
    Config.Houses[name] = {
        coords = coords,
        owned = false,
        price = price,
        locked = true,
        adress = label,
        tier = tier,
        garage = {},
        decorations = {}
    }
    TriggerClientEvent('qb-houses:client:setHouseConfig', -1, Config.Houses)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('info.added_house', { value = label }))
    TriggerEvent('qb-log:server:CreateLog', 'house', Lang:t('log.house_created'), 'green', Lang:t('log.house_address', { label = label, price = price, tier = tier, agent = GetPlayerName(src) }))
end)

RegisterNetEvent('qb-houses:server:addGarage', function(house, coords)
    local src = source
    MySQL.update('UPDATE houselocations SET garage = ? WHERE name = ?', { json.encode(coords), house })
    local garageInfo = {
        label = Config.Houses[house].adress,
        takeVehicle = coords
    }
    TriggerClientEvent('qb-garages:client:addHouseGarage', -1, house, garageInfo)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('info.added_garage', { value = garageInfo.label }))
end)

RegisterNetEvent('qb-houses:server:viewHouse', function(house)
    local src = source
    local pData = exports['pfm-core']:GetPlayer(src)
    local houseprice = Config.Houses[house].price
    local brokerfee = (houseprice / 100 * 5)
    local bankfee = (houseprice / 100 * 10)
    local taxes = (houseprice / 100 * 6)

    if GetResourceState('pf-government') == 'started' then
        local okTax, calcTax = pcall(function()
            return exports['pf-government']:CalculateTax(houseprice, 'property_transfer')
        end)
        if okTax then
            taxes = tonumber(calcTax) or taxes
        end
    end

    TriggerClientEvent('qb-houses:client:viewHouse', src, houseprice, brokerfee, bankfee, taxes, pData.PlayerData.charinfo.firstname, pData.PlayerData.charinfo.lastname)
end)

RegisterNetEvent('qb-houses:server:openStash', function(CurrentHouse)
    local src = source
    local houseData = Config.Houses[CurrentHouse]
    if not houseData then return end
    local houseTier = houseData.tier
    local stashSlots = Config.StashWeights[houseTier].slots
    local stashWeight = Config.StashWeights[houseTier].maxweight
    if stashSlots and stashWeight then
        exports['pfm-inventory']:OpenInventory(src, CurrentHouse, {
            maxweight = stashWeight,
            slots = stashSlots,
            label = houseData.adress
        })
    else
        exports['pfm-inventory']:OpenInventory(src, CurrentHouse)
    end
end)

RegisterNetEvent('qb-houses:server:buyHouse', function(house)
    local src = source
    local pData = exports['pfm-core']:GetPlayer(src)
    if not pData or type(house) ~= 'string' or not Config.Houses[house] then return end
    if not nearHouse(src, house, 10.0) then return end
    local price = tonumber(Config.Houses[house].price) or 0
    if price <= 0 then return end
    local brokerfee = (price / 100 * 5)
    local bankfee = (price / 100 * 10)
    local propertyTax = (price / 100 * 6)

    if price > 0 and GetResourceState('pf-government') == 'started' then
        local okTax, calcTax = pcall(function()
            return exports['pf-government']:CalculateTax(price, 'property_transfer')
        end)
        if okTax then
            propertyTax = tonumber(calcTax) or propertyTax
        end
    end

    local HousePrice = math.floor(((price + brokerfee + bankfee + propertyTax) * 100) + 0.5) / 100
    local bankBalance = pData.PlayerData.money['bank']

    local isOwned = isHouseOwned(house)
    if isOwned or buyingHouse[house] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.already_owned'), 'error')
        CancelEvent()
        return
    end

    if (bankBalance >= HousePrice) then
        -- pay first (the house used to be handed over before the money was taken, unchecked);
        -- the lock stops a second buyer while this payment is in flight
        buyingHouse[house] = true
        local cid = pData.PlayerData.citizenid
        local key = ('pfm-houses:buy:%s:%s:%s'):format(house, cid, PFPayout.NewId())
        local paid = PFPayout.Charge(src, 'bank', HousePrice, { key = key, kind = 'purchase', reason = 'House purchase ' .. house })
        if not paid then
            buyingHouse[house] = nil
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_enough_money'), 'error')
            return
        end
        if isHouseOwned(house) then -- owned meanwhile by another route: give the money back
            buyingHouse[house] = nil
            PFPayout.Pay(cid, 'bank', HousePrice, { key = key .. ':refund', kind = 'refund', reason = 'House no longer for sale' })
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.already_owned'), 'error')
            return
        end
        houseowneridentifier[house] = pData.PlayerData.license
        houseownercid[house] = pData.PlayerData.citizenid
        housekeyholders[house] = {
            [1] = pData.PlayerData.citizenid
        }
        MySQL.insert('INSERT INTO player_houses (house, identifier, citizenid, keyholders) VALUES (?, ?, ?, ?)', { house, pData.PlayerData.license, pData.PlayerData.citizenid, json.encode(housekeyholders[house]) })
        MySQL.update('UPDATE houselocations SET owned = ? WHERE name = ?', { 1, house })
        TriggerClientEvent('qb-houses:client:SetClosestHouse', src)
        TriggerClientEvent('qb-house:client:RefreshHouseTargets', src)
        buyingHouse[house] = nil

        settlePropertyTax(propertyTax, cid, key, price)

        if GetResourceState('pf-government') == 'started' then
            pcall(function()
                exports['pf-government']:RegisterProperty(house, Config.Houses[house].adress, pData.PlayerData.citizenid, ('%s %s'):format(pData.PlayerData.charinfo.firstname, pData.PlayerData.charinfo.lastname))
            end)
        end

        -- the agency's commission, from the purchase money held by this resource
        local commission = math.floor(HousePrice * math.random(18, 25)) / 100
        PFPayout.PaySociety('realestate', commission, { key = key .. ':commission', reason = 'House purchase commission' })
        TriggerEvent('qb-log:server:CreateLog', 'house', Lang:t('log.house_purchased'), 'green', Lang:t('log.house_purchased_by', { house = house:upper(), price = HousePrice, firstname = pData.PlayerData.charinfo.firstname, lastname = pData.PlayerData.charinfo.lastname }))
        TriggerClientEvent('QBCore:Notify', src, ('House purchased. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(price, propertyTax, HousePrice), 'success', 5000)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_enough_money'), 'error')
    end
end)

-- Locking and unlocking: a key holder at the door, or on-duty police at the door (raid / re-lock).
-- (Any client could unlock any house for everyone before.)
RegisterNetEvent('qb-houses:server:lockHouse', function(bool, house)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(house) ~= 'string' or not Config.Houses[house] then return end
    if not nearHouse(src, house, 5.0) then return end
    if not hasKey(Player.PlayerData.license, Player.PlayerData.citizenid, house) and not isOnDutyPolice(Player) then return end
    Config.Houses[house].locked = bool == true
    TriggerClientEvent('qb-houses:client:lockHouse', -1, bool == true, house)
end)

RegisterNetEvent('qb-houses:server:SetRamState', function(bool, house)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if type(house) ~= 'string' or not Config.Houses[house] or not isOnDutyPolice(Player) or not nearHouse(src, house, 5.0) then return end
    Config.Houses[house].IsRaming = bool == true
    -- (this was sent to 'qb-houses:server:SetRamState', which no client listens to)
    TriggerClientEvent('qb-houses:client:SetRamState', -1, bool == true, house)
end)

RegisterNetEvent('qb-houses:server:giveKey', function(house, target)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local pData = exports['pfm-core']:GetPlayer(target)
    if not Player or not pData then return end
    if not isHouseOwner(Player.PlayerData.license, Player.PlayerData.citizenid, house) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_owner'), 'error')
        return
    end
    housekeyholders[house][#housekeyholders[house] + 1] = pData.PlayerData.citizenid
    MySQL.update('UPDATE player_houses SET keyholders = ? WHERE house = ?',
        { json.encode(housekeyholders[house]), house })
end)

RegisterNetEvent('qb-houses:server:removeHouseKey', function(house, citizenData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if not isHouseOwner(Player.PlayerData.license, Player.PlayerData.citizenid, house) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_owner'), 'error')
        return
    end
    local newHolders = {}
    if housekeyholders[house] then
        for k, _ in pairs(housekeyholders[house]) do
            if housekeyholders[house][k] ~= citizenData.citizenid then
                newHolders[#newHolders + 1] = housekeyholders[house][k]
            end
        end
    end
    housekeyholders[house] = newHolders
    TriggerClientEvent('QBCore:Notify', src, Lang:t('error.remove_key_from', { firstname = citizenData.firstname, lastname = citizenData.lastname }), 'error')
    MySQL.update('UPDATE player_houses SET keyholders = ? WHERE house = ?', { json.encode(housekeyholders[house]), house })
end)

RegisterNetEvent('qb-houses:server:OpenDoor', function(target, house)
    local OtherPlayer = exports['pfm-core']:GetPlayer(target)
    if OtherPlayer then
        TriggerClientEvent('qb-houses:client:SpawnInApartment', OtherPlayer.PlayerData.source, house)
    end
end)

RegisterNetEvent('qb-houses:server:RingDoor', function(house)
    local src = source
    TriggerClientEvent('qb-houses:client:RingDoor', -1, src, house)
end)

-- Saving a house's furniture: a key holder inside that house, known furniture models only, placed
-- inside the house, and no more pieces of a model than the house had plus what was just bought.
-- (Any client could rewrite any house's furniture, with any model, for every player, for free.)
local MAX_DECORATIONS = 250
local DECOR_RADIUS = 60.0

local function countModels(list)
    local counts = {}
    for _, d in pairs(list or {}) do
        if type(d) == 'table' and type(d.hashname) == 'string' then counts[d.hashname] = (counts[d.hashname] or 0) + 1 end
    end
    return counts
end

RegisterNetEvent('qb-houses:server:savedecorations', function(house, decorations)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(house) ~= 'string' or not Config.Houses[house] or type(decorations) ~= 'table' then return end
    if not hasKey(Player.PlayerData.license, Player.PlayerData.citizenid, house) then return end
    local e = Config.Houses[house].coords and Config.Houses[house].coords.enter
    if not e then return end
    local shell = vector3(e.x, e.y, e.z - (Config.MinZOffset or 0))
    if #(GetEntityCoords(GetPlayerPed(src)) - shell) > DECOR_RADIUS then return end

    local clean, n = {}, 0
    for _, d in pairs(decorations) do
        if type(d) == 'table' and FurniturePrice[d.hashname] then
            local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
            if x and y and z and x == x and y == y and z == z and #(vector3(x, y, z) - shell) <= DECOR_RADIUS then
                n = n + 1
                if n > MAX_DECORATIONS then return end
                clean[n] = {
                    hashname = d.hashname, x = x, y = y, z = z,
                    rotx = tonumber(d.rotx) or 0.0, roty = tonumber(d.roty) or 0.0, rotz = tonumber(d.rotz) or 0.0,
                    objectId = n,
                }
            end
        end
    end

    local stored = MySQL.scalar.await('SELECT decorations FROM player_houses WHERE house = ?', { house })
    local ok, previous = pcall(json.decode, stored or '[]')
    local had = countModels(ok and previous or {})
    local credit = furnitureCredit[house] or {}
    local wanted = countModels(clean)
    for model, count in pairs(wanted) do
        if count > (had[model] or 0) + (credit[model] or 0) then return end -- placed without buying
    end
    for model, count in pairs(wanted) do
        local used = count - (had[model] or 0)
        if used > 0 then credit[model] = credit[model] - used end
    end

    MySQL.update('UPDATE player_houses SET decorations = ? WHERE house = ?', { json.encode(clean), house })
    TriggerClientEvent('qb-houses:server:sethousedecorations', -1, house, clean)
end)

RegisterNetEvent('qb-houses:server:LogoutLocation', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local MyItems = Player.PlayerData.items
    MySQL.update('UPDATE players SET inventory = ? WHERE citizenid = ?',
        { json.encode(MyItems), Player.PlayerData.citizenid })
    QBCore.Player.Logout(src)
    TriggerClientEvent('qb-multicharacter:client:chooseChar', src)
end)

RegisterNetEvent('qb-houses:server:giveHouseKey', function(target, house)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local tPlayer = exports['pfm-core']:GetPlayer(target)
    if not tPlayer or not Player then return end
    if not isHouseOwner(Player.PlayerData.license, Player.PlayerData.citizenid, house) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_owner'), 'error')
        return
    end
    if housekeyholders[house] then
        for _, cid in pairs(housekeyholders[house]) do
            if cid == tPlayer.PlayerData.citizenid then
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.already_keys'), 'error', 3500)
                return
            end
        end
        housekeyholders[house][#housekeyholders[house] + 1] = tPlayer.PlayerData.citizenid
        MySQL.update('UPDATE player_houses SET keyholders = ? WHERE house = ?', { json.encode(housekeyholders[house]), house })
        TriggerClientEvent('qb-houses:client:refreshHouse', tPlayer.PlayerData.source)

        TriggerClientEvent('QBCore:Notify', tPlayer.PlayerData.source, Lang:t('success.recieved_key', { value = Config.Houses[house].adress }), 'success', 2500)
    else
        local sourceTarget = exports['pfm-core']:GetPlayer(src)
        housekeyholders[house] = {
            [1] = sourceTarget.PlayerData.citizenid
        }
        housekeyholders[house][#housekeyholders[house] + 1] = tPlayer.PlayerData.citizenid
        MySQL.update('UPDATE player_houses SET keyholders = ? WHERE house = ?', { json.encode(housekeyholders[house]), house })
        TriggerClientEvent('qb-houses:client:refreshHouse', tPlayer.PlayerData.source)
        TriggerClientEvent('QBCore:Notify', tPlayer.PlayerData.source, Lang:t('success.recieved_key', { value = Config.Houses[house].adress }), 'success', 2500)
    end
end)

RegisterNetEvent('qb-houses:server:setLocation', function(coords, house, type)
    if type == 1 then
        MySQL.update('UPDATE player_houses SET stash = ? WHERE house = ?', { json.encode(coords), house })
    elseif type == 2 then
        MySQL.update('UPDATE player_houses SET outfit = ? WHERE house = ?', { json.encode(coords), house })
    elseif type == 3 then
        MySQL.update('UPDATE player_houses SET logout = ? WHERE house = ?', { json.encode(coords), house })
    end
    TriggerClientEvent('qb-houses:client:refreshLocations', -1, house, json.encode(coords), type)
end)

RegisterNetEvent('qb-houses:server:SetHouseRammed', function(bool, house)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if type(house) ~= 'string' or not Config.Houses[house] or not isOnDutyPolice(Player) or not nearHouse(src, house, 5.0) then return end
    bool = bool == true
    Config.Houses[house].IsRammed = bool
    TriggerClientEvent('qb-houses:client:SetHouseRammed', -1, bool, house)
end)

RegisterNetEvent('qb-houses:server:SetInsideMeta', function(insideId, bool)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local insideMeta = Player.PlayerData.metadata['inside']
    if bool then
        insideMeta.apartment.apartmentType = nil
        insideMeta.apartment.apartmentId = nil
        insideMeta.house = insideId
        Player.SetMetaData('inside', insideMeta)
    else
        insideMeta.apartment.apartmentType = nil
        insideMeta.apartment.apartmentId = nil
        insideMeta.house = nil
        Player.SetMetaData('inside', insideMeta)
    end
end)

-- Callbacks

-- Furniture is priced by the server from Config.Furniture (the client used to send the price, so
-- 0 or a negative amount bought anything). The purchase lets the house save one more of that model.
QBCore.Functions.CreateCallback('qb-houses:server:buyFurniture', function(source, cb, model, house)
    local src = source
    local pData = exports['pfm-core']:GetPlayer(src)
    local price = type(model) == 'string' and FurniturePrice[model]
    if not pData or not price or type(house) ~= 'string' or not Config.Houses[house]
        or not hasKey(pData.PlayerData.license, pData.PlayerData.citizenid, house) then
        cb(false)
        return
    end
    local key = ('pfm-houses:furniture:%s:%s:%s'):format(house, pData.PlayerData.citizenid, PFPayout.NewId())
    if price > 0 and not PFPayout.Charge(src, 'bank', price, { key = key, kind = 'purchase', reason = 'Furniture: ' .. model }) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_enough_money'), 'error')
        cb(false)
        return
    end
    furnitureCredit[house] = furnitureCredit[house] or {}
    furnitureCredit[house][model] = (furnitureCredit[house][model] or 0) + 1
    cb(true)
end)

QBCore.Functions.CreateCallback('qb-houses:server:ProximityKO', function(source, cb, house)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local retvalK = false
    local retvalO

    if Player then
        local identifier = Player.PlayerData.license
        local CharId = Player.PlayerData.citizenid
        if hasKey(identifier, CharId, house) then
            retvalK = true
        elseif Player.PlayerData.job.name == 'realestate' then
            retvalK = true
        else
            retvalK = false
        end
    end

    if houseowneridentifier[house] and houseownercid[house] then
        retvalO = true
    else
        retvalO = false
    end

    cb(retvalK, retvalO)
end)

QBCore.Functions.CreateCallback('qb-houses:server:hasKey', function(source, cb, house)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local retval = false
    if Player then
        local identifier = Player.PlayerData.license
        local CharId = Player.PlayerData.citizenid
        if hasKey(identifier, CharId, house) then
            retval = true
        elseif Player.PlayerData.job.name == 'realestate' then
            retval = true
        else
            retval = false
        end
    end

    cb(retval)
end)

QBCore.Functions.CreateCallback('qb-houses:server:isOwned', function(source, cb, house)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player and Player.PlayerData and Player.PlayerData.job and Player.PlayerData.job.name == 'realestate' then
        cb(true)
    elseif houseowneridentifier[house] and houseownercid[house] then
        cb(true)
    else
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-houses:server:getHouseOwner', function(_, cb, house)
    cb(houseownercid[house])
end)

QBCore.Functions.CreateCallback('qb-houses:server:getHouseKeyHolders', function(source, cb, house)
    local retval = {}
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if housekeyholders[house] then
        for i = 1, #housekeyholders[house], 1 do
            if Player.PlayerData.citizenid ~= housekeyholders[house][i] then
                local result = MySQL.query.await('SELECT charinfo FROM players WHERE citizenid = ?', { housekeyholders[house][i] })
                if result[1] then
                    local charinfo = json.decode(result[1].charinfo)
                    retval[#retval + 1] = {
                        firstname = charinfo.firstname,
                        lastname = charinfo.lastname,
                        citizenid = housekeyholders[house][i]
                    }
                end
            end
        end
        cb(retval)
    else
        cb(nil)
    end
end)

QBCore.Functions.CreateCallback('qb-phone:server:TransferCid', function(_, cb, NewCid, house)
    local result = MySQL.query.await('SELECT * FROM players WHERE citizenid = ?', { NewCid })
    if result[1] then
        local HouseName = house.name
        housekeyholders[HouseName] = {}
        housekeyholders[HouseName][1] = NewCid
        houseownercid[HouseName] = NewCid
        houseowneridentifier[HouseName] = result[1].license
        MySQL.update(
            'UPDATE player_houses SET citizenid = ?, keyholders = ?, identifier = ? WHERE house = ?',
            { NewCid, json.encode(housekeyholders[HouseName]), result[1].license, HouseName })
        cb(true)
    else
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-houses:server:getHouseDecorations', function(_, cb, house)
    local retval = nil
    local result = MySQL.query.await('SELECT * FROM player_houses WHERE house = ?', { house })
    if result[1] then
        if result[1].decorations then
            retval = json.decode(result[1].decorations)
        end
    end
    cb(retval)
end)

QBCore.Functions.CreateCallback('qb-houses:server:getHouseLocations', function(_, cb, house)
    local retval = nil
    local result = MySQL.query.await('SELECT * FROM player_houses WHERE house = ?', { house })
    if result[1] then
        retval = result[1]
    end
    cb(retval)
end)

QBCore.Functions.CreateCallback('qb-houses:server:getOwnedHouses', function(source, cb)
    local src = source
    local pData = exports['pfm-core']:GetPlayer(src)
    if pData then
        MySQL.query('SELECT * FROM player_houses WHERE identifier = ? AND citizenid = ?', { pData.PlayerData.license, pData.PlayerData.citizenid }, function(houses)
            local ownedHouses = {}
            for i = 1, #houses, 1 do
                ownedHouses[#ownedHouses + 1] = houses[i].house
            end
            if houses then
                cb(ownedHouses)
            else
                cb(nil)
            end
        end)
    end
end)

QBCore.Functions.CreateCallback('qb-houses:server:getSavedOutfits', function(source, cb)
    local src = source
    local pData = exports['pfm-core']:GetPlayer(src)

    if pData then
        MySQL.query('SELECT * FROM player_outfits WHERE citizenid = ?', { pData.PlayerData.citizenid },
            function(result)
                if result[1] then
                    cb(result)
                else
                    cb(nil)
                end
            end)
    end
end)

QBCore.Functions.CreateCallback('qb-phone:server:GetPlayerHouses', function(source, cb)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local MyHouses = {}
    local result = MySQL.query.await('SELECT * FROM player_houses WHERE citizenid = ?',
        { Player.PlayerData.citizenid })
    if result and result[1] then
        for k, v in pairs(result) do
            MyHouses[#MyHouses + 1] = {
                name = v.house,
                keyholders = {},
                owner = Player.PlayerData.citizenid,
                price = Config.Houses[v.house].price,
                label = Config.Houses[v.house].adress,
                tier = Config.Houses[v.house].tier,
                garage = Config.Houses[v.house].garage
            }

            if v.keyholders ~= 'null' then
                v.keyholders = json.decode(v.keyholders)
                if v.keyholders then
                    for _, data in pairs(v.keyholders) do
                        local keyholderdata = MySQL.query.await('SELECT * FROM players WHERE citizenid = ?',
                            { data })
                        if keyholderdata[1] then
                            keyholderdata[1].charinfo = json.decode(keyholderdata[1].charinfo)

                            local userKeyHolderData = {
                                charinfo = {
                                    firstname = keyholderdata[1].charinfo.firstname,
                                    lastname = keyholderdata[1].charinfo.lastname
                                },
                                citizenid = keyholderdata[1].citizenid,
                                name = keyholderdata[1].name
                            }
                            MyHouses[k].keyholders[#MyHouses[k].keyholders + 1] = userKeyHolderData
                        end
                    end
                else
                    MyHouses[k].keyholders[1] = {
                        charinfo = {
                            firstname = Player.PlayerData.charinfo.firstname,
                            lastname = Player.PlayerData.charinfo.lastname
                        },
                        citizenid = Player.PlayerData.citizenid,
                        name = Player.PlayerData.name
                    }
                end
            else
                MyHouses[k].keyholders[1] = {
                    charinfo = {
                        firstname = Player.PlayerData.charinfo.firstname,
                        lastname = Player.PlayerData.charinfo.lastname
                    },
                    citizenid = Player.PlayerData.citizenid,
                    name = Player.PlayerData.name
                }
            end
        end

        SetTimeout(100, function()
            cb(MyHouses)
        end)
    else
        cb({})
    end
end)

QBCore.Functions.CreateCallback('qb-phone:server:GetHouseKeys', function(source, cb)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local MyKeys = {}

    local result = MySQL.query.await('SELECT * FROM player_houses', {})
    for _, v in pairs(result) do
        if v.keyholders ~= 'null' then
            v.keyholders = json.decode(v.keyholders)
            for _, p in pairs(v.keyholders) do
                if p == Player.PlayerData.citizenid and (v.citizenid ~= Player.PlayerData.citizenid) then
                    MyKeys[#MyKeys + 1] = {
                        HouseData = Config.Houses[v.house]
                    }
                end
            end
        end

        if v.citizenid == Player.PlayerData.citizenid then
            MyKeys[#MyKeys + 1] = {
                HouseData = Config.Houses[v.house]
            }
        end
    end
    cb(MyKeys)
end)

QBCore.Functions.CreateCallback('qb-phone:server:MeosGetPlayerHouses', function(_, cb, input)
    if input then
        local search = escape_sqli(input)
        local searchData = {}
        local query = '%' .. search .. '%'
        local result = MySQL.query.await('SELECT * FROM players WHERE citizenid = ? OR charinfo LIKE ?',
            { search, query })
        if result[1] then
            local houses = MySQL.query.await('SELECT * FROM player_houses WHERE citizenid = ?',
                { result[1].citizenid })
            if houses[1] then
                for _, v in pairs(houses) do
                    searchData[#searchData + 1] = {
                        name = v.house,
                        keyholders = v.keyholders,
                        owner = v.citizenid,
                        price = Config.Houses[v.house].price,
                        label = Config.Houses[v.house].adress,
                        tier = Config.Houses[v.house].tier,
                        garage = Config.Houses[v.house].garage,
                        charinfo = json.decode(result[1].charinfo),
                        coords = {
                            x = Config.Houses[v.house].coords.enter.x,
                            y = Config.Houses[v.house].coords.enter.y,
                            z = Config.Houses[v.house].coords.enter.z
                        }
                    }
                end
                cb(searchData)
            end
        else
            cb(nil)
        end
    else
        cb(nil)
    end
end)

local function getKeyHolderData()
    return housekeyholders
end

exports('getKeyHolderData', getKeyHolderData)

-- ══════════════════════════════════════════════════════════════════
-- PF gameplay pack: house selling (back to the state, or to a player)
-- ══════════════════════════════════════════════════════════════════

local pendingHouseSales = {} -- [buyerSrc] = { house, price, sellerSrc, sellerCid, expires }

local function GetOwnedHouseNear(Player, maxDist)
    local cid = Player.PlayerData.citizenid
    local pCoords = GetEntityCoords(GetPlayerPed(Player.PlayerData.source))
    for house, ownerCid in pairs(houseownercid) do
        if ownerCid == cid and Config.Houses[house] and Config.Houses[house].coords and Config.Houses[house].coords.enter then
            local e = Config.Houses[house].coords.enter
            if #(pCoords - vector3(e.x, e.y, e.z)) <= (maxDist or 20.0) then
                return house
            end
        end
    end
    return nil
end

local function IsHouseStashEmpty(house)
    local items = MySQL.scalar.await('SELECT items FROM inventories WHERE identifier = ? LIMIT 1', { house })
    if not items then return true end
    local ok, decoded = pcall(json.decode, items)
    if not ok or type(decoded) ~= 'table' then return true end
    return next(decoded) == nil
end

local function PropertyTransferTax(price)
    local tax = math.floor(price * 0.06)
    if GetResourceState('pf-government') == 'started' then
        local ok, calc = pcall(function() return exports['pf-government']:CalculateTax(price, 'property_transfer') end)
        if ok and tonumber(calc) then tax = math.floor(tonumber(calc)) end
    end
    return tax
end

local function TransferHouseOwnership(house, Buyer)
    houseowneridentifier[house] = Buyer.PlayerData.license
    houseownercid[house] = Buyer.PlayerData.citizenid
    housekeyholders[house] = { [1] = Buyer.PlayerData.citizenid }
    MySQL.update('UPDATE player_houses SET identifier = ?, citizenid = ?, keyholders = ? WHERE house = ?',
        { Buyer.PlayerData.license, Buyer.PlayerData.citizenid, json.encode(housekeyholders[house]), house })
    if GetResourceState('pf-government') == 'started' then
        pcall(function()
            exports['pf-government']:RegisterProperty(house, Config.Houses[house].adress, Buyer.PlayerData.citizenid, ('%s %s'):format(Buyer.PlayerData.charinfo.firstname, Buyer.PlayerData.charinfo.lastname))
        end)
    end
end

QBCore.Commands.Add('sellhouse', Lang:t('info.sellhouse_cmd'), { { name = 'id', help = Lang:t('info.sellhouse_id_help') }, { name = 'price', help = Lang:t('info.sellhouse_price_help') } }, false, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    local house = GetOwnedHouseNear(Player, 20.0)
    if not house then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.sell_not_near'), 'error')
        return
    end

    -- player-to-player offer: /sellhouse [id] [price]
    if args[1] then
        local targetId = tonumber(args[1])
        local price = math.floor(tonumber(args[2]) or 0)
        local Buyer = targetId and exports['pfm-core']:GetPlayer(targetId) or nil
        if not Buyer or Buyer.PlayerData.source == src then
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.sell_bad_buyer'), 'error')
            return
        end
        if price <= 0 or price > (Config.PlayerSaleMaxPrice or 10000000) then
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.sell_bad_price'), 'error')
            return
        end
        local sellerCoords = GetEntityCoords(GetPlayerPed(src))
        local buyerCoords = GetEntityCoords(GetPlayerPed(Buyer.PlayerData.source))
        if #(sellerCoords - buyerCoords) > 10.0 then
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.sell_buyer_far'), 'error')
            return
        end

        local tax = PropertyTransferTax(price)
        pendingHouseSales[Buyer.PlayerData.source] = {
            id = PFPayout.NewId(), -- the ledger keys of this sale
            house = house,
            price = price,
            tax = tax,             -- the tax shown to the buyer is the tax charged
            sellerSrc = src,
            sellerCid = Player.PlayerData.citizenid,
            expires = os.time() + 60,
        }
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.sell_offer_sent', { price = price }), 'primary', 5000)
        TriggerClientEvent('qb-houses:client:ConfirmHouseSale', Buyer.PlayerData.source, {
            adress = Config.Houses[house].adress,
            price = price,
            tax = tax,
            seller = ('%s %s'):format(Player.PlayerData.charinfo.firstname, Player.PlayerData.charinfo.lastname),
        })
        return
    end

    -- sell back to the state (one sale at a time per house: two quick /sellhouse used to pay twice)
    if buyingHouse[house] then return end
    buyingHouse[house] = true
    if not IsHouseStashEmpty(house) then
        buyingHouse[house] = nil
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.sell_stash_full'), 'error', 6000)
        return
    end
    local basePrice = tonumber(Config.Houses[house].price) or 0
    local payout = math.floor(basePrice * (Config.HouseSellBackPercent or 70) / 100)
    if houseownercid[house] ~= Player.PlayerData.citizenid then buyingHouse[house] = nil return end

    -- paid before the house is given up; nothing changes hands if the bank does not answer
    local key = ('pfm-houses:sellback:%s:%s:%s'):format(house, Player.PlayerData.citizenid, PFPayout.NewId())
    if payout > 0 and not PFPayout.Pay(src, 'bank', payout, { key = key, kind = 'sale', reason = 'House sold to the state' }) then
        buyingHouse[house] = nil
        return
    end

    houseowneridentifier[house] = nil
    houseownercid[house] = nil
    housekeyholders[house] = nil
    MySQL.query('DELETE FROM player_houses WHERE house = ?', { house })
    MySQL.update('UPDATE houselocations SET owned = ? WHERE name = ?', { 0, house })
    furnitureCredit[house] = nil
    buyingHouse[house] = nil
    TriggerClientEvent('qb-houses:client:SetClosestHouse', -1)
    TriggerClientEvent('qb-house:client:RefreshHouseTargets', -1)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.sold_to_state', { house = Config.Houses[house].adress, payout = payout }), 'success', 6000)
    TriggerEvent('qb-log:server:CreateLog', 'house', Lang:t('log.house_sold'), 'orange',
        ('%s %s sold %s back to the state for $%s'):format(Player.PlayerData.charinfo.firstname, Player.PlayerData.charinfo.lastname, house, payout))
end)

RegisterNetEvent('qb-houses:server:RespondHouseSale', function(accepted)
    local src = source
    local offer = pendingHouseSales[src]
    pendingHouseSales[src] = nil
    if not offer then return end
    if os.time() > offer.expires then return end

    local Buyer = exports['pfm-core']:GetPlayer(src)
    local Seller = exports['pfm-core']:GetPlayer(offer.sellerSrc)
    if not Buyer or not Seller then return end
    if Seller.PlayerData.citizenid ~= offer.sellerCid then return end
    if houseownercid[offer.house] ~= offer.sellerCid then return end -- seller must still own it

    if not accepted then
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('error.sell_declined'), 'error')
        return
    end

    local buyerCoords = GetEntityCoords(GetPlayerPed(src))
    local sellerCoords = GetEntityCoords(GetPlayerPed(offer.sellerSrc))
    if #(buyerCoords - sellerCoords) > 20.0 then return end

    local tax = tonumber(offer.tax) or PropertyTransferTax(offer.price)
    local total = offer.price + tax
    if Buyer.PlayerData.money['bank'] < total then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_enough_money'), 'error')
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('error.sell_buyer_broke'), 'error')
        return
    end
    if buyingHouse[offer.house] then return end

    -- One debit of price + tax into system:pfm-houses, then the seller is paid from it, under keys
    -- fixed for this offer. (RemoveMoney then AddMoney lost or created money if the server stopped
    -- between them, and the tax was taken from the buyer but credited to the treasury separately.)
    buyingHouse[offer.house] = true
    local buyerCid = Buyer.PlayerData.citizenid
    local key = ('pfm-houses:sale:%s:%s'):format(offer.house, offer.id)
    if not PFPayout.Charge(src, 'bank', total, { key = key .. ':charge', kind = 'purchase', reason = 'House purchase ' .. offer.house }) then
        buyingHouse[offer.house] = nil
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_enough_money'), 'error')
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('error.sell_buyer_broke'), 'error')
        return
    end
    if houseownercid[offer.house] ~= offer.sellerCid then -- sold or given up meanwhile: refund
        buyingHouse[offer.house] = nil
        PFPayout.Pay(buyerCid, 'bank', total, { key = key .. ':refund', kind = 'refund', reason = 'House sale cancelled' })
        return
    end
    -- the seller is paid by citizen id, so this also works if they logged off a moment ago
    PFPayout.Pay(offer.sellerCid, 'bank', offer.price, { key = key .. ':seller', kind = 'sale', reason = 'House sold: ' .. offer.house, quiet = true })
    settlePropertyTax(tax, buyerCid, key, offer.price)

    TransferHouseOwnership(offer.house, Buyer)
    buyingHouse[offer.house] = nil
    TriggerClientEvent('qb-houses:client:SetClosestHouse', -1)
    TriggerClientEvent('qb-house:client:RefreshHouseTargets', -1)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.house_bought_private', { house = Config.Houses[offer.house].adress, total = total }), 'success', 6000)
    TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('success.house_sold_private', { house = Config.Houses[offer.house].adress, price = offer.price }), 'success', 6000)
    TriggerEvent('qb-log:server:CreateLog', 'house', Lang:t('log.house_sold'), 'green',
        ('%s sold to %s %s for $%s (+$%s tax)'):format(offer.house, Buyer.PlayerData.charinfo.firstname, Buyer.PlayerData.charinfo.lastname, offer.price, tax))
end)

AddEventHandler('playerDropped', function()
    pendingHouseSales[source] = nil
end)
