local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands', 'Player' })
local sharedStarterItems = exports['pfm-core']:GetShared('StarterItems')
local hasDonePreloading = {}
local Countries = json.decode(LoadResourceFile(GetCurrentResourceName(), '/countries.json'))

-- Functions

local function GiveStarterItems(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    for _, v in pairs(sharedStarterItems) do
        local info = {}
        if v.item == 'id_card' then
            info.citizenid = Player.PlayerData.citizenid
            info.firstname = Player.PlayerData.charinfo.firstname
            info.lastname = Player.PlayerData.charinfo.lastname
            info.birthdate = Player.PlayerData.charinfo.birthdate
            info.gender = Player.PlayerData.charinfo.gender
            info.nationality = Player.PlayerData.charinfo.nationality
        elseif v.item == 'driver_license' then
            info.firstname = Player.PlayerData.charinfo.firstname
            info.lastname = Player.PlayerData.charinfo.lastname
            info.birthdate = Player.PlayerData.charinfo.birthdate
            info.type = 'Class C Driver License'
        end
        exports['pfm-inventory']:AddItem(src, v.item, v.amount, false, info, 'qb-multicharacter:GiveStarterItems')
    end
end

local function loadHouseData(src)
    local HouseGarages = {}
    local Houses = {}
    local result = MySQL.query.await('SELECT * FROM houselocations', {})
    if result[1] ~= nil then
        for _, v in pairs(result) do
            local owned = false
            if tonumber(v.owned) == 1 then
                owned = true
            end
            local garage = v.garage ~= nil and json.decode(v.garage) or {}
            Houses[v.name] = {
                coords = json.decode(v.coords),
                owned = owned,
                price = v.price,
                locked = true,
                adress = v.label,
                tier = v.tier,
                garage = garage,
                decorations = {},
            }
            HouseGarages[v.name] = {
                label = v.label,
                takeVehicle = garage,
            }
        end
    end
    TriggerClientEvent('qb-garages:client:houseGarageConfig', src, HouseGarages)
    TriggerClientEvent('qb-houses:client:setHouseConfig', src, Houses)
end

local function MaxCharacters(license)
    for _, v in pairs(Config.PlayersNumberOfCharacters or {}) do
        if v.license == license then return v.numberOfChars end
    end
    return Config.DefaultNumberOfCharacters
end

-- The rules for a character's identity, at creation and for the government's corrections
-- (pf-government civilian:updateIdentity, through the ValidateIdentityField export), so a value that
-- could not be chosen at creation cannot be given later either. Names and nationality: trimmed, not
-- empty, at most IDENTITY_MAX bytes (UTF-8 letters count twice), no control characters and no
-- markup characters (these names are shown in every MDT, phone and government screen). Birthdate:
-- a real date written YYYY-MM-DD (what the creation form's date field sends), from 1900.
-- 64 for nationality: the country list's longest name is 52 bytes (48 dropped it at creation).
local IDENTITY_MAX = { firstname = 32, lastname = 32, nationality = 64 }

local function ValidateIdentityField(field, v)
    if type(v) ~= 'string' then return nil, 'invalid_' .. tostring(field) end
    v = v:gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' or v:find('%c') or v:find('[<>"`\\{}%[%]|]') then return nil, 'invalid_' .. field end
    if field == 'birthdate' then
        local y, m, d = v:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
        y, m, d = tonumber(y), tonumber(m), tonumber(d)
        if not y or y < 1900 or m < 1 or m > 12 or d < 1 then return nil, 'invalid_birthdate' end
        local leap = y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
        if d > ({ 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m] then return nil, 'invalid_birthdate' end
        return v
    end
    local max = IDENTITY_MAX[field]
    if not max then return nil, 'invalid_field' end
    if #v > max then return nil, 'invalid_' .. field end
    return v
end

exports('ValidateIdentityField', function(field, value)
    return ValidateIdentityField(field, value)
end)

-- Only the fields the creation form fills in; phone, account and the rest are made by pfm-core.
-- (A client could send someone else's bank account or phone number, or any other field.)
local function CleanCharinfo(data)
    local nationality
    if data.nationality ~= nil then
        nationality = ValidateIdentityField('nationality', data.nationality)
        if not nationality then return nil end
    end
    local charinfo = {
        firstname = ValidateIdentityField('firstname', data.firstname),
        lastname = ValidateIdentityField('lastname', data.lastname),
        birthdate = ValidateIdentityField('birthdate', data.birthdate),
        nationality = nationality,
        gender = tonumber(data.gender) == 1 and 1 or 0,
    }
    if not charinfo.firstname or not charinfo.lastname or not charinfo.birthdate then return nil end
    return charinfo
end

-- Commands

QBCore.Commands.Add('logout', Lang:t('commands.logout_description'), {}, false, function(source)
    local src = source
    QBCore.Player.Logout(src)
    TriggerClientEvent('qb-multicharacter:client:chooseChar', src)
end, 'admin')

QBCore.Commands.Add('closeNUI', Lang:t('commands.closeNUI_description'), {}, false, function(source)
    local src = source
    TriggerClientEvent('qb-multicharacter:client:closeNUI', src)
end)

-- Events

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    Wait(1000) -- 1 second should be enough to do the preloading in other resources
    hasDonePreloading[Player.PlayerData.source] = true
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    hasDonePreloading[src] = false
end)

RegisterNetEvent('qb-multicharacter:server:disconnect', function()
    local src = source
    DropPlayer(src, Lang:t('commands.droppedplayer'))
end)

RegisterNetEvent('qb-multicharacter:server:loadUserData', function(cData)
    local src = source
    -- a missing citizenid made Login create a blank new character; loading over a live character
    -- replaced it without saving
    if type(cData) ~= 'table' or type(cData.citizenid) ~= 'string' then return end
    if QBCore.Functions.GetPlayer(src) then return end
    if QBCore.Player.Login(src, cData.citizenid) then
        repeat
            Wait(10)
        until hasDonePreloading[src]
        print('^2[qb-core]^7 ' .. GetPlayerName(src) .. ' (Citizen ID: ' .. cData.citizenid .. ') has successfully loaded!')
        QBCore.Commands.Refresh(src)
        loadHouseData(src)
        if Config.SkipSelection then
            -- the saved position, not the one the client sends
            local Player = QBCore.Functions.GetPlayer(src)
            local coords = Player and Player.PlayerData.position
            TriggerClientEvent('qb-multicharacter:client:spawnLastLocation', src, coords, cData)
        else
            if GetResourceState('pfm-apartments') == 'started' then
                TriggerClientEvent('apartments:client:setupSpawnUI', src, cData)
            else
                TriggerClientEvent('qb-spawn:client:setupSpawns', src, cData, false, nil)
                TriggerClientEvent('qb-spawn:client:openUI', src, true)
            end
        end
        TriggerEvent('qb-log:server:CreateLog', 'joinleave', 'Loaded', 'green', '**' .. GetPlayerName(src) .. '** (<@' .. (QBCore.Functions.GetIdentifier(src, 'discord'):gsub('discord:', '') or 'unknown') .. '> |  ||' .. (QBCore.Functions.GetIdentifier(src, 'ip') or 'undefined') .. '|| | ' .. (QBCore.Functions.GetIdentifier(src, 'license') or 'undefined') .. ' | ' .. cData.citizenid .. ' | ' .. src .. ') loaded..')
    end
end)

RegisterNetEvent('qb-multicharacter:server:createCharacter', function(data)
    local src = source
    if type(data) ~= 'table' or QBCore.Functions.GetPlayer(src) then return end
    local charinfo = CleanCharinfo(data)
    local slot = tonumber(data.cid)
    if not charinfo or not slot or slot < 1 or slot % 1 ~= 0 then return end
    -- the character limit was only enforced by the UI
    local license = QBCore.Functions.GetIdentifier(src, 'license')
    local owned = MySQL.query.await('SELECT citizenid FROM players WHERE license = ?', { license }) or {}
    local max = MaxCharacters(license)
    if #owned >= max or slot > max then return end
    local newData = {}
    newData.cid = slot
    newData.charinfo = charinfo
    if QBCore.Player.Login(src, false, newData) then
        repeat
            Wait(10)
        until hasDonePreloading[src]
        if GetResourceState('pfm-apartments') == 'started' and Apartments.Starting then
            local randbucket = (GetPlayerPed(src) .. math.random(1, 999))
            SetPlayerRoutingBucket(src, randbucket)
            print('^2[qb-core]^7 ' .. GetPlayerName(src) .. ' has successfully loaded!')
            QBCore.Commands.Refresh(src)
            loadHouseData(src)
            TriggerClientEvent('qb-multicharacter:client:closeNUI', src)
            TriggerClientEvent('apartments:client:setupSpawnUI', src, newData)
            GiveStarterItems(src)
        else
            print('^2[qb-core]^7 ' .. GetPlayerName(src) .. ' has successfully loaded!')
            QBCore.Commands.Refresh(src)
            loadHouseData(src)
            TriggerClientEvent('qb-multicharacter:client:closeNUIdefault', src)
            GiveStarterItems(src)
            TriggerEvent('apartments:client:SetHomeBlip', nil)
        end
    end
end)

-- why a delete was refused -> the message the character menu shows
local deleteRefusals = {
    unpaid_debt = 'notifications.char_unpaid_debt',
    character_in_use = 'notifications.char_in_use',
}

RegisterNetEvent('qb-multicharacter:server:deleteCharacter', function(citizenid)
    local src = source
    if not Config.EnableDeleteButton then return end
    if type(citizenid) ~= 'string' then return end
    -- only from the character menu: with a character loaded (possibly this very one, whose next
    -- save would re-create it) the delete is refused
    if QBCore.Functions.GetPlayer(src) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('notifications.char_in_use'), 'error')
        return
    end
    local ok, reason = QBCore.Player.DeleteCharacter(src, citizenid)
    if ok then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('notifications.char_deleted'), 'success')
    elseif reason ~= 'not_owner' then -- (a foreign character: the caller was dropped)
        TriggerClientEvent('QBCore:Notify', src, Lang:t(deleteRefusals[reason] or 'notifications.char_delete_failed'), 'error')
    end
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-multicharacter:server:GetUserCharacters', function(source, cb)
    local src = source
    local license = QBCore.Functions.GetIdentifier(src, 'license')

    MySQL.query('SELECT * FROM players WHERE license = ?', { license }, function(result)
        cb(result)
    end)
end)

QBCore.Functions.CreateCallback('qb-multicharacter:server:GetServerLogs', function(source, cb)
    -- staff only (any client could read the whole server log table)
    if not (QBCore.Functions.HasPermission(source, 'admin') or IsPlayerAceAllowed(source, 'command')) then return cb({}) end
    MySQL.query('SELECT * FROM server_logs', {}, function(result)
        cb(result)
    end)
end)

QBCore.Functions.CreateCallback('qb-multicharacter:server:GetNumberOfCharacters', function(source, cb)
    local src = source
    local license = QBCore.Functions.GetIdentifier(src, 'license')
    local numOfChars = 0

    if next(Config.PlayersNumberOfCharacters) then
        for _, v in pairs(Config.PlayersNumberOfCharacters) do
            if v.license == license then
                numOfChars = v.numberOfChars
                break
            else
                numOfChars = Config.DefaultNumberOfCharacters
            end
        end
    else
        numOfChars = Config.DefaultNumberOfCharacters
    end
    cb(numOfChars, Countries)
end)

QBCore.Functions.CreateCallback('qb-multicharacter:server:setupCharacters', function(source, cb)
    local license = QBCore.Functions.GetIdentifier(source, 'license')
    local plyChars = {}
    MySQL.query('SELECT * FROM players WHERE license = ?', { license }, function(result)
        for i = 1, (#result), 1 do
            result[i].charinfo = json.decode(result[i].charinfo)
            result[i].money = json.decode(result[i].money)
            result[i].job = json.decode(result[i].job)
            plyChars[#plyChars + 1] = result[i]
        end
        cb(plyChars)
    end)
end)

QBCore.Functions.CreateCallback('qb-multicharacter:server:getSkin', function(source, cb, cid)
    -- only the requesting license's own characters
    local license = QBCore.Functions.GetIdentifier(source, 'license')
    if type(cid) ~= 'string' or not license or MySQL.scalar.await('SELECT license FROM players WHERE citizenid = ?', { cid }) ~= license then
        return cb(nil)
    end
    local result = MySQL.query.await('SELECT * FROM playerskins WHERE citizenid = ? AND active = ?', { cid, 1 })
    if result[1] ~= nil then
        cb(result[1].model, result[1].skin)
    else
        cb(nil)
    end
end)

QBCore.Commands.Add('deletechar', Lang:t('commands.deletechar_description'), { { name = Lang:t('commands.citizenid'), help = Lang:t('commands.citizenid_help') } }, false, function(source, args)
    if args and args[1] then
        local ok = QBCore.Player.ForceDeleteCharacter(tostring(args[1]))
        if ok then
            TriggerClientEvent('QBCore:Notify', source, Lang:t('notifications.deleted_other_char', { citizenid = tostring(args[1]) }))
        else
            TriggerClientEvent('QBCore:Notify', source, Lang:t('notifications.char_delete_failed'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('notifications.forgot_citizenid'), 'error')
    end
end, 'god')
