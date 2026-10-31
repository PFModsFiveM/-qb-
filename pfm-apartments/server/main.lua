local ApartmentObjects = {}
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local Invites = {}   -- [visitorSrc] = { apartmentId = ..., expires = os.time() } set when someone inside opens the door
local Rings = {}     -- [visitorSrc] = { apartmentId = ..., expires = os.time() } set when the visitor rings

-- Functions

local function CreateApartmentId(type)
    local UniqueFound = false
    local AparmentId = nil

    while not UniqueFound do
        AparmentId = tostring(math.random(1, 1000000))
        local result = MySQL.query.await('SELECT COUNT(*) as count FROM apartments WHERE name = ?', { tostring(type .. AparmentId) })
        if result[1].count == 0 then
            UniqueFound = true
            -- the stash of a deleted character's apartment outlives it (pfm-core deletes the
            -- apartments row, the stash is pfm-inventory's): never hand that id out again
            local ok, stash = pcall(function()
                return MySQL.query.await('SELECT COUNT(*) as count FROM inventories WHERE identifier = ?', { tostring(type .. AparmentId) })
            end)
            if ok and stash and stash[1] and (tonumber(stash[1].count) or 0) > 0 then UniqueFound = false end
        end
    end
    return AparmentId
end

local function GetApartmentInfo(apartmentId)
    local retval = nil
    local result = MySQL.query.await('SELECT * FROM apartments WHERE name = ?', { apartmentId })
    if result[1] ~= nil then
        retval = result[1]
    end
    return retval
end

-- Owner of the apartment, or a visitor someone inside let in within the last minute.
-- (Any apartment id used to be accepted, so anyone could walk into anyone's apartment.)
local function CanEnter(src, Player, apartmentId)
    local invite = Invites[src]
    if invite and invite.apartmentId == apartmentId and os.time() <= invite.expires then return true end
    local apartment = GetApartmentInfo(apartmentId)
    return apartment ~= nil and apartment.citizenid == Player.PlayerData.citizenid
end

-- Events

RegisterNetEvent('qb-apartments:server:SetInsideMeta', function(house, insideId, bool, isVisiting)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local insideMeta = Player.PlayerData.metadata['inside']

    if bool then
        if type(insideId) ~= 'string' then return end
        local routeId = insideId:gsub('[^%-%d]', '')
        if not tonumber(routeId) then return end
        if not isVisiting then
            -- only the actual owner may mark an apartment as their own inside-location
            local apartment = GetApartmentInfo(insideId)
            if not apartment or apartment.citizenid ~= Player.PlayerData.citizenid then return end
        elseif not CanEnter(src, Player, insideId) then
            return
        end
        if not isVisiting then
            insideMeta.apartment.apartmentType = house
            insideMeta.apartment.apartmentId = insideId
            insideMeta.house = nil
            Player.SetMetaData('inside', insideMeta)
        end
        QBCore.Functions.SetPlayerBucket(src, tonumber(routeId))
    else
        insideMeta.apartment.apartmentType = nil
        insideMeta.apartment.apartmentId = nil
        insideMeta.house = nil


        Player.SetMetaData('inside', insideMeta)
        QBCore.Functions.SetPlayerBucket(src, 0)
    end
end)

RegisterNetEvent('qb-apartments:returnBucket', function()
    local src = source
    SetPlayerRoutingBucket(src, 0)
end)

RegisterNetEvent('apartments:server:openStash', function(CurrentApartment)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    local inside = Player.PlayerData.metadata and Player.PlayerData.metadata['inside']
    if not inside or not inside.apartment or inside.apartment.apartmentId ~= CurrentApartment then
        return
    end

    local apartment = GetApartmentInfo(CurrentApartment)
    if not apartment or apartment.citizenid ~= Player.PlayerData.citizenid then
        return
    end

    exports['pfm-inventory']:OpenInventory(src, CurrentApartment)
end)

RegisterNetEvent('apartments:server:CreateApartment', function(type, label, firstSpawn)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    -- note: the 'type' parameter shadows Lua's type(); use tostring-based checks here
    label = tostring(label or ''):gsub('%c', ''):sub(1, 64)
    if label == '' then return end
    if not Apartments.Locations[type] then return end
    -- one apartment per character
    local existing = MySQL.query.await('SELECT name FROM apartments WHERE citizenid = ?', { Player.PlayerData.citizenid })
    if existing[1] ~= nil then return end
    local num = CreateApartmentId(type)
    local apartmentId = tostring(type .. num)
    label = tostring(label .. ' ' .. num)
    MySQL.insert('INSERT INTO apartments (name, type, label, citizenid) VALUES (?, ?, ?, ?)', {
        apartmentId,
        type,
        label,
        Player.PlayerData.citizenid
    })
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.receive_apart') .. ' (' .. label .. ')')
    if firstSpawn then
        TriggerClientEvent('apartments:client:SpawnInApartment', src, apartmentId, type)
    end
    TriggerClientEvent('apartments:client:SetHomeBlip', src, type)
end)

RegisterNetEvent('apartments:server:UpdateApartment', function(type, label)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if not Apartments.Locations[type] then return end
    label = tostring(label or ''):gsub('%c', ''):sub(1, 64)
    if label == '' then return end
    MySQL.update('UPDATE apartments SET type = ?, label = ? WHERE citizenid = ?', { type, label, Player.PlayerData.citizenid })
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.changed_apart'))
    TriggerClientEvent('apartments:client:SetHomeBlip', src, type)
end)

RegisterNetEvent('apartments:server:RingDoor', function(apartmentId, apartment)
    local src = source
    if not ApartmentObjects[apartment] or not ApartmentObjects[apartment].apartments then return end
    if type(apartmentId) ~= 'string' then return end
    Rings[src] = { apartmentId = apartmentId, expires = os.time() + 120 }
    if ApartmentObjects[apartment].apartments[apartmentId] ~= nil and next(ApartmentObjects[apartment].apartments[apartmentId].players) ~= nil then
        for k, _ in pairs(ApartmentObjects[apartment].apartments[apartmentId].players) do
            TriggerClientEvent('apartments:client:RingDoor', k, src)
        end
    end
end)

RegisterNetEvent('apartments:server:OpenDoor', function(target, apartmentId, apartment)
    local src = source
    local OtherPlayer = exports['pfm-core']:GetPlayer(tonumber(target))
    if OtherPlayer == nil then return end
    target = OtherPlayer.PlayerData.source
    -- only someone who rang this apartment's bell (any player could be pulled in from anywhere)
    local ring = Rings[target]
    if not ring or ring.apartmentId ~= apartmentId or os.time() > ring.expires then return end
    -- the inviter must actually be inside this apartment to let someone in
    if not ApartmentObjects[apartment] or not ApartmentObjects[apartment].apartments
        or not ApartmentObjects[apartment].apartments[apartmentId]
        or not ApartmentObjects[apartment].apartments[apartmentId].players[src] then
        return
    end
    Rings[target] = nil
    Invites[target] = { apartmentId = apartmentId, expires = os.time() + 60 }
    TriggerClientEvent('apartments:client:SpawnInApartment', OtherPlayer.PlayerData.source, apartmentId, apartment)
end)

RegisterNetEvent('apartments:server:AddObject', function(apartmentId, apartment, offset)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if type(apartmentId) ~= 'string' or type(apartment) ~= 'string' or not tonumber(offset) then return end
    if not CanEnter(src, Player, apartmentId) then return end
    if ApartmentObjects[apartment] ~= nil and ApartmentObjects[apartment].apartments ~= nil and ApartmentObjects[apartment].apartments[apartmentId] ~= nil then
        ApartmentObjects[apartment].apartments[apartmentId].players[src] = Player.PlayerData.citizenid
    else
        if ApartmentObjects[apartment] ~= nil and ApartmentObjects[apartment].apartments ~= nil then
            ApartmentObjects[apartment].apartments[apartmentId] = {}
            ApartmentObjects[apartment].apartments[apartmentId].offset = offset
            ApartmentObjects[apartment].apartments[apartmentId].players = {}
            ApartmentObjects[apartment].apartments[apartmentId].players[src] = Player.PlayerData.citizenid
        else
            ApartmentObjects[apartment] = {}
            ApartmentObjects[apartment].apartments = {}
            ApartmentObjects[apartment].apartments[apartmentId] = {}
            ApartmentObjects[apartment].apartments[apartmentId].offset = offset
            ApartmentObjects[apartment].apartments[apartmentId].players = {}
            ApartmentObjects[apartment].apartments[apartmentId].players[src] = Player.PlayerData.citizenid
        end
    end
end)

RegisterNetEvent('apartments:server:RemoveObject', function(apartmentId, apartment)
    local src = source
    if not ApartmentObjects[apartment] or not ApartmentObjects[apartment].apartments or not ApartmentObjects[apartment].apartments[apartmentId] then return end
    if ApartmentObjects[apartment].apartments[apartmentId].players ~= nil then
        ApartmentObjects[apartment].apartments[apartmentId].players[src] = nil
        if next(ApartmentObjects[apartment].apartments[apartmentId].players) == nil then
            ApartmentObjects[apartment].apartments[apartmentId] = nil
        end
    end
end)

RegisterNetEvent('apartments:server:setCurrentApartment', function(ap)
    local Player = exports['pfm-core']:GetPlayer(source)

    if not Player then return end
    if ap ~= nil and type(ap) ~= 'string' then return end

    Player.SetMetaData('currentapartment', ap)
end)

-- Callbacks

QBCore.Functions.CreateCallback('apartments:GetAvailableApartments', function(_, cb, apartment)
    local apartments = {}
    if ApartmentObjects ~= nil and ApartmentObjects[apartment] ~= nil and ApartmentObjects[apartment].apartments ~= nil then
        for k, _ in pairs(ApartmentObjects[apartment].apartments) do
            if (ApartmentObjects[apartment].apartments[k] ~= nil and next(ApartmentObjects[apartment].apartments[k].players) ~= nil) then
                local apartmentInfo = GetApartmentInfo(k)
                if apartmentInfo then apartments[k] = apartmentInfo.label end
            end
        end
    end
    cb(apartments)
end)

QBCore.Functions.CreateCallback('apartments:GetApartmentOffset', function(_, cb, apartmentId)
    local retval = 0
    if ApartmentObjects ~= nil then
        for k, _ in pairs(ApartmentObjects) do
            if (ApartmentObjects[k].apartments[apartmentId] ~= nil and tonumber(ApartmentObjects[k].apartments[apartmentId].offset) ~= 0) then
                retval = tonumber(ApartmentObjects[k].apartments[apartmentId].offset)
            end
        end
    end
    cb(retval)
end)

QBCore.Functions.CreateCallback('apartments:GetApartmentOffsetNewOffset', function(_, cb, apartment)
    local retval = Apartments.SpawnOffset
    if ApartmentObjects ~= nil and ApartmentObjects[apartment] ~= nil and ApartmentObjects[apartment].apartments ~= nil then
        for k, _ in pairs(ApartmentObjects[apartment].apartments) do
            if (ApartmentObjects[apartment].apartments[k] ~= nil) then
                retval = ApartmentObjects[apartment].apartments[k].offset + Apartments.SpawnOffset
            end
        end
    end
    cb(retval)
end)

QBCore.Functions.CreateCallback('apartments:GetOwnedApartment', function(source, cb, cid)
    if cid ~= nil then
        -- only the caller's own character (any citizenid used to be looked up)
        local Self = exports['pfm-core']:GetPlayer(source)
        if not Self or Self.PlayerData.citizenid ~= cid then return cb(nil) end
        local result = MySQL.query.await('SELECT * FROM apartments WHERE citizenid = ?', { cid })
        if result[1] ~= nil then
            return cb(result[1])
        end
        return cb(nil)
    else
        local src = source
        local Player = exports['pfm-core']:GetPlayer(src)
        local result = MySQL.query.await('SELECT * FROM apartments WHERE citizenid = ?', { Player.PlayerData.citizenid })
        if result[1] ~= nil then
            return cb(result[1])
        end
        return cb(nil)
    end
end)

QBCore.Functions.CreateCallback('apartments:IsOwner', function(source, cb, apartment)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player ~= nil then
        local result = MySQL.query.await('SELECT * FROM apartments WHERE citizenid = ?', { Player.PlayerData.citizenid })
        if result[1] ~= nil then
            if result[1].type == apartment then
                cb(true)
            else
                cb(false)
            end
        else
            cb(false)
        end
    end
end)


AddEventHandler('playerDropped', function()
    Invites[source] = nil
    Rings[source] = nil
end)

QBCore.Functions.CreateCallback('apartments:GetOutfits', function(source, cb)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)

    if Player then
        local result = MySQL.query.await('SELECT * FROM player_outfits WHERE citizenid = ?', { Player.PlayerData.citizenid })
        if result[1] ~= nil then
            cb(result)
        else
            cb(nil)
        end
    end
end)

--- The citizen's apartment for other resources (the Real Estate app): { id, label, building,
--- coords = { x, y } } or nil. Server-only export; the caller passes a citizen id it verified.
exports('GetCitizenApartment', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    local row = MySQL.query.await('SELECT name, type, label FROM apartments WHERE citizenid = ? LIMIT 1', { citizenid })
    row = row and row[1]
    if not row then return nil end
    local loc = Apartments.Locations[row.type]
    local enter = loc and loc.coords and loc.coords.enter
    return {
        id = row.name, label = row.label, building = loc and loc.label or row.type,
        coords = enter and { x = math.floor(enter.x * 100 + 0.5) / 100, y = math.floor(enter.y * 100 + 0.5) / 100 } or nil,
    }
end)

-- A deleted character: pfm-core deleted their apartments row and passes the apartment names it had
-- (read before the delete). Each apartment's stash (pfm-inventory, id = the apartment name) is
-- emptied so nobody inherits it; CreateApartmentId also never hands out an id that still has a stash.
local function isApartmentName(name)
    if type(name) ~= 'string' or #name < 2 or #name > 64 or not name:match('^[%w_%-]+$') then return false end
    for kind in pairs(Apartments.Locations) do
        local rest = name:sub(#kind + 1)
        if name:sub(1, #kind) == kind and rest:match('^%d+$') then return true end
    end
    return false
end

AddEventHandler('pfm-core:server:characterDeleted', function(citizenid, deleted)
    if type(citizenid) ~= 'string' or citizenid == '' or type(deleted) ~= 'table' or type(deleted.apartments) ~= 'table' then return end
    local n = 0
    for _, name in ipairs(deleted.apartments) do
        n = n + 1
        if n > 16 then break end
        if isApartmentName(name) then
            if GetResourceState('pfm-inventory') == 'started' then
                pcall(function() exports['pfm-inventory']:ClearStash(name) end)
            end
            MySQL.query.await('DELETE FROM inventories WHERE identifier = ?', { name })
        end
    end
end)
