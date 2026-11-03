-- Commands

QBCore.Commands.Add('giveitem', 'Give An Item (Admin Only)', { { name = 'id', help = 'Player ID' }, { name = 'item', help = 'Name of the item (not a label)' }, { name = 'amount', help = 'Amount of items' } }, false, function(source, args)
    local id = tonumber(args[1])
    local player = exports['pfm-core']:GetPlayer(id)
    local amount = tonumber(args[3]) or 1
    local itemData = QBCore.Shared.Items[tostring(args[2]):lower()]
    if player then
        if itemData then
            -- check iteminfo
            local info = {}
            if itemData['name'] == 'id_card' then
                info.citizenid = player.PlayerData.citizenid
                info.firstname = player.PlayerData.charinfo.firstname
                info.lastname = player.PlayerData.charinfo.lastname
                info.birthdate = player.PlayerData.charinfo.birthdate
                info.gender = player.PlayerData.charinfo.gender
                info.nationality = player.PlayerData.charinfo.nationality
            elseif itemData['name'] == 'driver_license' then
                info.firstname = player.PlayerData.charinfo.firstname
                info.lastname = player.PlayerData.charinfo.lastname
                info.birthdate = player.PlayerData.charinfo.birthdate
                info.type = 'Class C Driver License'
            elseif itemData['type'] == 'weapon' then
                amount = 1
                info.serie = tostring(QBCore.Shared.RandomInt(2) .. QBCore.Shared.RandomStr(3) .. QBCore.Shared.RandomInt(1) .. QBCore.Shared.RandomStr(2) .. QBCore.Shared.RandomInt(3) .. QBCore.Shared.RandomStr(4))
                info.quality = 100
            elseif itemData['name'] == 'harness' then
                info.uses = 20
            elseif itemData['name'] == 'markedbills' then
                info.worth = math.random(5000, 10000)
            elseif itemData['name'] == 'printerdocument' then
                info.url = 'https://cdn.discordapp.com/attachments/870094209783308299/870104331142189126/Logo_-_Display_Picture_-_Stylized_-_Red.png'
            end

            if AddItem(id, itemData['name'], amount, false, info, 'give item command') then
                QBCore.Functions.Notify(source, Lang:t('notify.yhg') .. GetPlayerName(id) .. ' ' .. amount .. ' ' .. itemData['name'] .. '', 'success')
                TriggerClientEvent('qb-inventory:client:ItemBox', id, itemData, 'add', amount)
                if Player(id).state.inv_busy then TriggerClientEvent('qb-inventory:client:updateInventory', id) end
            else
                QBCore.Functions.Notify(source, Lang:t('notify.cgitem'), 'error')
            end
        else
            QBCore.Functions.Notify(source, Lang:t('notify.idne'), 'error')
        end
    else
        QBCore.Functions.Notify(source, Lang:t('notify.pdne'), 'error')
    end
end, 'admin')

QBCore.Commands.Add('randomitems', 'Receive random items', {}, false, function(source)
    local player = exports['pfm-core']:GetPlayer(source)
    local playerInventory = player.PlayerData.items
    local filteredItems = {}
    for k, v in pairs(QBCore.Shared.Items) do
        if QBCore.Shared.Items[k]['type'] ~= 'weapon' then
            filteredItems[#filteredItems + 1] = v
        end
    end
    for _ = 1, 10, 1 do
        local randitem = filteredItems[math.random(1, #filteredItems)]
        local amount = math.random(1, 10)
        if randitem['unique'] then
            amount = 1
        end
        local emptySlot = nil
        for i = 1, Config.MaxSlots do
            if not playerInventory[i] then
                emptySlot = i
                break
            end
        end
        if emptySlot then
            if AddItem(source, randitem.name, amount, emptySlot, false, 'random items command') then
                TriggerClientEvent('qb-inventory:client:ItemBox', source, QBCore.Shared.Items[randitem.name], 'add')
                player = exports['pfm-core']:GetPlayer(source)
                playerInventory = player.PlayerData.items
                if Player(source).state.inv_busy then TriggerClientEvent('qb-inventory:client:updateInventory', source) end
            end
            Wait(1000)
        end
    end
end, 'god')

QBCore.Commands.Add('clearinv', 'Clear Inventory (Admin Only)', { { name = 'id', help = 'Player ID' } }, false, function(source, args)
    local id = tonumber(args[1])
    if not id then
        ClearInventory(source)
        return
    end
    ClearInventory(id)
end, 'admin')

-- Keybindings

RegisterCommand('closeInv', function(source)
    CloseInventory(source)
end, false)

RegisterCommand('hotbar', function(source)
    IsBeingSearched(source) -- a stale search on this player ends here (see the inventory key below)
    if Player(source).state.inv_busy then return end
    local QBPlayer = exports['pfm-core']:GetPlayer(source)
    if not QBPlayer then return end
    if not QBPlayer or QBPlayer.PlayerData.metadata['isdead'] or QBPlayer.PlayerData.metadata['inlaststand'] or QBPlayer.PlayerData.metadata['ishandcuffed'] then return end
    local hotbarItems = {
        QBPlayer.PlayerData.items[1],
        QBPlayer.PlayerData.items[2],
        QBPlayer.PlayerData.items[3],
        QBPlayer.PlayerData.items[4],
        QBPlayer.PlayerData.items[5],
    }
    TriggerClientEvent('qb-inventory:client:hotbar', source, hotbarItems)
end, false)

-- The client only says which vehicle storage it is at; the server checks the player is in that
-- vehicle (glovebox) or beside it and it is unlocked (trunk). The client's name used to be opened as-is,
-- and the unanchored 'trunk%-' match opened any stash whose id contained it.
local VEHICLE_REACH = 10.0

local function trimPlate(plate)
    return (tostring(plate or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Returns the storage kind ('trunk' or 'glovebox') and the vehicle entity, or nil.
function CheckVehicleStorage(source, inventory)
    if type(inventory) ~= 'string' or #inventory > 64 then return nil end
    local kind, plate = inventory:match('^(%a+)%-(.+)$')
    if kind ~= 'trunk' and kind ~= 'glovebox' then return nil end
    plate = trimPlate(plate)
    if plate == '' then return nil end
    local ped = GetPlayerPed(source)
    if kind == 'glovebox' then
        local veh = GetVehiclePedIsIn(ped, false)
        if veh and veh ~= 0 and trimPlate(GetVehicleNumberPlateText(veh)) == plate then return kind, veh end
        return nil
    end
    local pos = GetEntityCoords(ped)
    for _, veh in ipairs(GetAllVehicles()) do
        if trimPlate(GetVehicleNumberPlateText(veh)) == plate and #(pos - GetEntityCoords(veh)) <= VEHICLE_REACH then
            if (GetVehicleDoorLockStatus(veh) or 0) >= 2 then return nil end
            return kind, veh
        end
    end
    return nil
end

-- The size of a trunk or glovebox comes from the car's model on the server: pfm-core's vehicle list
-- gives its category, and the category its class (the same table as pfm-garages). The class the
-- client named used to choose it, so a compact answered as a van got a van's trunk.
local CATEGORY_CLASS = {
    compacts = 0, sedans = 1, suvs = 2, coupes = 3, muscle = 4, sportsclassics = 5, sports = 6, super = 7,
    motorcycles = 8, offroad = 9, industrial = 10, utility = 11, vans = 12, cycles = 13, boats = 14,
    helicopters = 15, planes = 16, service = 17, emergency = 18, military = 19, commercial = 20, trains = 21,
    openwheel = 22,
}
local classByModel   -- [model hash, signed and unsigned] = class; built on first use

local function addModelClass(map, hash, class)
    hash = math.tointeger(tonumber(hash))
    if not hash then return end
    local unsigned = hash & 0xFFFFFFFF
    map[unsigned] = class
    map[unsigned >= 0x80000000 and unsigned - 0x100000000 or unsigned] = class
end

local function modelClass(veh)
    if not classByModel then
        local map = {}
        local ok, vehicles = pcall(function() return exports['pfm-core']:GetShared('Vehicles') end)
        for model, v in pairs(ok and type(vehicles) == 'table' and vehicles or {}) do
            local class = type(v) == 'table' and CATEGORY_CLASS[v.category]
            if class and type(model) == 'string' then addModelClass(map, v.hash or GetHashKey(model), class) end
        end
        -- kept once pfm-core gave the list (asked again while it cannot)
        if next(map) then classByModel = map else return nil end
    end
    local hash = math.tointeger(tonumber(GetEntityModel(veh)))
    return hash and classByModel[hash] or nil
end

--- slots, maxweight of the trunk or glovebox of `veh`. A model the list does not know (an ambient
--- car) gets the class its client names, but never more than the default size.
local function vehicleStorage(kind, veh, clientClass)
    local slotsKey = kind == 'trunk' and 'trunkSlots' or 'gloveboxSlots'
    local weightKey = kind == 'trunk' and 'trunkWeight' or 'gloveboxWeight'
    local default = VehicleStorage.default
    local class = modelClass(veh)
    if class then
        local size = VehicleStorage[class] or default
        return size[slotsKey], size[weightKey]
    end
    local size = VehicleStorage[clientClass] or default
    return math.min(size[slotsKey], default[slotsKey]), math.min(size[weightKey], default[weightKey])
end

RegisterCommand('inventory', function(source)
    -- a search on this player whose searcher left or walked away ends here, before the busy check
    -- below, so the inventory key frees them at once instead of at the next search check
    IsBeingSearched(source)
    if Player(source).state.inv_busy then return end
    local QBPlayer = exports['pfm-core']:GetPlayer(source)
    if not QBPlayer then return end
    if not QBPlayer or QBPlayer.PlayerData.metadata['isdead'] or QBPlayer.PlayerData.metadata['inlaststand'] or QBPlayer.PlayerData.metadata['ishandcuffed'] then return end
    QBCore.Functions.TriggerClientCallback('qb-inventory:client:vehicleCheck', source, function(inventory, class)
        if not inventory then return OpenInventory(source) end
        local kind, veh = CheckVehicleStorage(source, inventory)
        if not kind then return OpenInventory(source) end
        class = tonumber(class)
        if class and (class ~= math.floor(class) or class < 0 or class > 22) then class = nil end
        local slots, maxweight = vehicleStorage(kind, veh, class)
        OpenInventory(source, inventory, { slots = slots, maxweight = maxweight })
    end)
end, false)
