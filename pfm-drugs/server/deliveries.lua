QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
sharedItems = exports['pfm-core']:GetShared('Items')

local pendingDeliveries = {} -- [citizenid] = { item, amount } (server-side ledger: one delivery grant at a time)

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

-- Functions
exports('GetDealers', function()
    return Config.Dealers
end)

-- Callbacks
QBCore.Functions.CreateCallback('qb-drugs:server:RequestConfig', function(_, cb)
    cb(Config.Dealers)
end)

-- A delivery is fronted by a dealer and paid on hand-over at the drop point. The server records
-- where and when it started; the hand-over must happen at that drop point, after a believable trip,
-- and pays only for product the server actually takes back. (Before, the client could collect the
-- bricks anywhere and report an "on time" delivery from the same spot ten seconds later.)
local DEALER_RANGE = 5.0
local DROP_RANGE = 6.0
local MAX_TRIP_SPEED = 45.0          -- m/s
local MIN_TRIP_SECONDS = 20
local ON_TIME_SECONDS = 15 * 60      -- the client timer (300 s) starts when the mail is opened

local function DistanceTo(src, c)
    local p = GetEntityCoords(GetPlayerPed(src))
    return #(vector3(p.x, p.y, p.z) - vector3(c.x, c.y, c.z))
end

-- The configured delivery location the client picked (it chooses among them; the server checks it).
local function DeliveryLocationIndex(coords)
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' then return nil end
    local x, y = tonumber(coords.x), tonumber(coords.y)
    if not x or not y then return nil end
    for i, loc in ipairs(Config.DeliveryLocations) do
        if math.abs(loc.coords.x - x) < 0.5 and math.abs(loc.coords.y - y) < 0.5 then return i end
    end
    return nil
end

-- Events

-- 'qb-drugs:server:updateDealerItems' was removed: nothing on the server ever asked a client to send
-- it, and it paid cash for items it failed to remove (dealer stock drained, then free money).

RegisterNetEvent('qb-drugs:server:giveDeliveryItems', function(deliveryData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(deliveryData) ~= 'table' then return end
    if onCooldown(src, 'giveDelivery', 10000) then return end
    local itemCfg = Config.DeliveryItems[deliveryData.item]
    if not itemCfg then return end
    -- picked up from a real dealer, with the reputation this product needs
    local dealer = Config.Dealers[deliveryData.dealer]
    if not dealer or DistanceTo(src, dealer.coords) > DEALER_RANGE then return end
    if (Player.GetRep('dealer') or 0) < (itemCfg.minrep or 0) then return end
    local locIdx = DeliveryLocationIndex(deliveryData.coords)
    if not locIdx then return end
    local item = itemCfg.item
    local amount = math.floor(tonumber(deliveryData.amount) or 0)
    if amount < 1 or amount > 3 then return end -- the client requests 1-3
    local cid = Player.PlayerData.citizenid
    -- one active delivery at a time (stops free-brick farming); stale ones expire after 2h
    if pendingDeliveries[cid] and os.time() < pendingDeliveries[cid].startedAt + 7200 then return end
    local trip = DistanceTo(src, Config.DeliveryLocations[locIdx].coords)
    pendingDeliveries[cid] = {
        item = deliveryData.item, amount = amount, startedAt = os.time(), location = locIdx,
        earliest = os.time() + math.max(MIN_TRIP_SECONDS, trip / MAX_TRIP_SPEED),
    }
    exports['pfm-inventory']:AddItem(src, item, amount, false, false, 'qb-drugs:server:giveDeliveryItems')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'add')
end)

RegisterNetEvent('qb-drugs:server:successDelivery', function(deliveryData, inTime)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(deliveryData) ~= 'table' then return end
    if onCooldown(src, 'successDelivery', 10000) then return end
    local itemCfg = Config.DeliveryItems[deliveryData.item]
    if not itemCfg then return end
    -- the delivery must match the server-side ledger created by giveDeliveryItems
    local cid = Player.PlayerData.citizenid
    local pending = pendingDeliveries[cid]
    if not pending or pending.item ~= deliveryData.item then return end
    -- handed over at the agreed drop point, not sooner than the trip takes
    if DistanceTo(src, Config.DeliveryLocations[pending.location].coords) > DROP_RANGE then return end
    if os.time() < pending.earliest then return end
    pendingDeliveries[cid] = nil
    -- "on time" is decided here; the client can only make it late
    inTime = inTime == true and os.time() <= pending.startedAt + ON_TIME_SECONDS
    local item = itemCfg.item
    local itemAmount = pending.amount
    local payout = itemCfg.payout * itemAmount -- recomputed from config; client-sent itemData is ignored
    local copsOnline = QBCore.Functions.GetDutyCount('police')
    local invItem = Player.GetItemByName(item)
    if inTime then
        if invItem and invItem.amount >= itemAmount then -- on time correct amount
            if not exports['pfm-inventory']:RemoveItem(src, item, itemAmount, false, 'qb-drugs:server:successDelivery') then return end
            if copsOnline > 0 then
                local copModifier = copsOnline * Config.PoliceDeliveryModifier
                if Config.UseMarkedBills then
                    local info = { worth = math.floor(payout * copModifier) }
                    exports['pfm-inventory']:AddItem(src, 'markedbills', 1, false, info, 'qb-drugs:server:successDelivery')
                else
                    Player.AddMoney('cash', math.floor(payout * copModifier), 'qb-drugs:server:successDelivery')
                end
            else
                if Config.UseMarkedBills then
                    local info = { worth = payout }
                    exports['pfm-inventory']:AddItem(src, 'markedbills', 1, false, info, 'qb-drugs:server:successDelivery')
                else
                    Player.AddMoney('cash', payout, 'qb-drugs:server:successDelivery')
                end
            end
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'remove')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.order_delivered'), 'success')
            SetTimeout(math.random(5000, 10000), function()
                TriggerClientEvent('qb-drugs:client:sendDeliveryMail', src, 'perfect', deliveryData)
                Player.AddRep('dealer', Config.DeliveryRepGain)
            end)
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.order_not_right'), 'error') -- on time incorrect amount
            if invItem then
                -- paid for what is handed over, never more than the order
                local newItemAmount = math.min(invItem.amount, itemAmount)
                local modifiedPayout = itemCfg.payout * newItemAmount
                if exports['pfm-inventory']:RemoveItem(src, item, newItemAmount, false, 'qb-drugs:server:successDelivery') then
                    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'remove')
                    Player.AddMoney('cash', math.floor(modifiedPayout / Config.WrongAmountFee), 'qb-drugs:server:successDelivery')
                end
            end
            SetTimeout(math.random(5000, 10000), function()
                TriggerClientEvent('qb-drugs:client:sendDeliveryMail', src, 'bad', deliveryData)
                Player.RemoveRep('dealer', Config.DeliveryRepLoss)
            end)
        end
    else
        if invItem and invItem.amount >= itemAmount then -- late correct amount
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.too_late'), 'error')
            if not exports['pfm-inventory']:RemoveItem(src, item, itemAmount, false, 'qb-drugs:server:successDelivery') then return end
            Player.AddMoney('cash', math.floor(payout / Config.OverdueDeliveryFee), 'qb-drugs:server:successDelivery')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'remove')
            SetTimeout(math.random(5000, 10000), function()
                TriggerClientEvent('qb-drugs:client:sendDeliveryMail', src, 'late', deliveryData)
                Player.RemoveRep('dealer', Config.DeliveryRepLoss)
            end)
        else
            if invItem then -- late incorrect amount
                -- removes exactly what it pays for (it used to remove the full order, fail, and pay anyway)
                local newItemAmount = math.min(invItem.amount, itemAmount)
                local modifiedPayout = itemCfg.payout * newItemAmount
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.too_late'), 'error')
                if not exports['pfm-inventory']:RemoveItem(src, item, newItemAmount, false, 'qb-drugs:server:successDelivery') then return end
                Player.AddMoney('cash', math.floor(modifiedPayout / Config.OverdueDeliveryFee), 'qb-drugs:server:successDelivery')
                TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'remove')
                SetTimeout(math.random(5000, 10000), function()
                    TriggerClientEvent('qb-drugs:client:sendDeliveryMail', src, 'late', deliveryData)
                    Player.RemoveRep('dealer', Config.DeliveryRepLoss)
                end)
            end
        end
    end
end)

RegisterNetEvent('qb-drugs:server:dealerShop', function(currentDealer)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local dealerData = Config.Dealers[currentDealer]
    if not dealerData then return end
    local dist = #(playerCoords - vector3(dealerData.coords.x, dealerData.coords.y, dealerData.coords.z))
    if dist > 5.0 then return end
    local curRep = Player.GetRep('dealer')
    local repItems = {}
    for k in pairs(dealerData.products) do
        if curRep >= dealerData['products'][k].minrep then
            repItems[#repItems + 1] = dealerData['products'][k]
        end
    end
    -- one shop per player: the item list depends on this player's reputation (a shared shop name let
    -- whoever opened it last decide what everyone could buy)
    local shopName = ('%s:%d'):format(dealerData.name, src)
    exports['pfm-inventory']:CreateShop({
        name = shopName,
        label = dealerData.name,
        slots = #repItems,
        coords = dealerData.coords,
        items = repItems,
    })
    exports['pfm-inventory']:OpenShop(src, shopName)
end)

-- Commands

QBCore.Commands.Add('newdealer', Lang:t('info.newdealer_command_desc'), { {
    name = Lang:t('info.newdealer_command_help1_name'),
    help = Lang:t('info.newdealer_command_help1_help')
}, {
    name = Lang:t('info.newdealer_command_help2_name'),
    help = Lang:t('info.newdealer_command_help2_help')
}, {
    name = Lang:t('info.newdealer_command_help3_name'),
    help = Lang:t('info.newdealer_command_help3_help')
} }, true, function(source, args)
    local ped = GetPlayerPed(source)
    local coords = GetEntityCoords(ped)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    local dealerName = args[1]
    local minTime = tonumber(args[2])
    local maxTime = tonumber(args[3])
    local time = json.encode({ min = minTime, max = maxTime })
    local pos = json.encode({ x = coords.x, y = coords.y, z = coords.z })
    local result = MySQL.scalar.await('SELECT name FROM dealers WHERE name = ?', { dealerName })
    if result then return TriggerClientEvent('QBCore:Notify', source, Lang:t('error.dealer_already_exists'), 'error') end
    MySQL.insert('INSERT INTO dealers (name, coords, time, createdby) VALUES (?, ?, ?, ?)', { dealerName, pos, time, Player.PlayerData.citizenid }, function()
        Config.Dealers[dealerName] = {
            ['name'] = dealerName,
            ['coords'] = {
                ['x'] = coords.x,
                ['y'] = coords.y,
                ['z'] = coords.z
            },
            ['time'] = {
                ['min'] = minTime,
                ['max'] = maxTime
            },
            ['products'] = Config.Products
        }
        TriggerClientEvent('qb-drugs:client:RefreshDealers', -1, Config.Dealers)
    end)
end, 'admin')

QBCore.Commands.Add('deletedealer', Lang:t('info.deletedealer_command_desc'), { {
    name = Lang:t('info.deletedealer_command_help1_name'),
    help = Lang:t('info.deletedealer_command_help1_help')
} }, true, function(source, args)
    local dealerName = args[1]
    local result = MySQL.scalar.await('SELECT * FROM dealers WHERE name = ?', { dealerName })
    if result then
        MySQL.query('DELETE FROM dealers WHERE name = ?', { dealerName })
        Config.Dealers[dealerName] = nil
        TriggerClientEvent('qb-drugs:client:RefreshDealers', -1, Config.Dealers)
        TriggerClientEvent('QBCore:Notify', source, Lang:t('success.dealer_deleted', { dealerName = dealerName }), 'success')
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.dealer_not_exists_command', { dealerName = dealerName }), 'error')
    end
end, 'admin')

QBCore.Commands.Add('dealers', Lang:t('info.dealers_command_desc'), {}, false, function(source, _)
    local DealersText = ''
    if Config.Dealers ~= nil and next(Config.Dealers) ~= nil then
        for _, v in pairs(Config.Dealers) do
            DealersText = DealersText .. Lang:t('info.list_dealers_name_prefix') .. v['name'] .. '<br>'
        end
        TriggerClientEvent('chat:addMessage', source, {
            template = '<div class="chat-message advert"><div class="chat-message-body"><strong>' .. Lang:t('info.list_dealers_title') .. '</strong><br><br> ' .. DealersText .. '</div></div>',
            args = {}
        })
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.no_dealers'), 'error')
    end
end, 'admin')

QBCore.Commands.Add('dealergoto', Lang:t('info.dealergoto_command_desc'), { {
    name = Lang:t('info.dealergoto_command_help1_name'),
    help = Lang:t('info.dealergoto_command_help1_help')
} }, true, function(source, args)
    local DealerName = tostring(args[1])
    if Config.Dealers[DealerName] then
        local ped = GetPlayerPed(source)
        SetEntityCoords(ped, Config.Dealers[DealerName]['coords']['x'], Config.Dealers[DealerName]['coords']['y'], Config.Dealers[DealerName]['coords']['z'])
        TriggerClientEvent('QBCore:Notify', source, Lang:t('success.teleported_to_dealer', { dealerName = DealerName }), 'success')
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.dealer_not_exists'), 'error')
    end
end, 'admin')

CreateThread(function()
    Wait(500)
    local dealers = MySQL.query.await('SELECT * FROM dealers', {})
    if dealers[1] then
        for _, v in pairs(dealers) do
            local coords = json.decode(v.coords)
            local time = json.decode(v.time)

            Config.Dealers[v.name] = {
                ['name'] = v.name,
                ['coords'] = {
                    ['x'] = coords.x,
                    ['y'] = coords.y,
                    ['z'] = coords.z
                },
                ['time'] = {
                    ['min'] = time.min,
                    ['max'] = time.max
                },
                ['products'] = Config.Products
            }
        end
    end
    TriggerClientEvent('qb-drugs:client:RefreshDealers', -1, Config.Dealers)
end)
