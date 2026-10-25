local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })

-- Every event acts on the sender's own character only. Payloads are size-checked and outfit saves are
-- limited, so a client cannot fill the database with huge or endless rows.
local MAX_SKIN_LENGTH = 16000
local MAX_NAME_LENGTH = 64
local MAX_OUTFITS = 50
local SAVE_COOLDOWN = 2 -- seconds between skin/outfit writes per player
local lastWrite = {}

AddEventHandler('playerDropped', function()
    lastWrite[source] = nil
end)

local function canWrite(src, kind)
    local now = os.time()
    lastWrite[src] = lastWrite[src] or {}
    if lastWrite[src][kind] and now - lastWrite[src][kind] < SAVE_COOLDOWN then return false end
    lastWrite[src][kind] = now
    return true
end

local function validModel(model)
    return (type(model) == 'string' and #model > 0 and #model <= 64) or (type(model) == 'number' and model == math.floor(model))
end

RegisterServerEvent('qb-clothing:saveSkin', function(model, skin)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if validModel(model) and type(skin) == 'string' and #skin <= MAX_SKIN_LENGTH then
        if not canWrite(src, 'skin') then return end
        -- TODO: Update primary key to be citizenid so this can be an insert on duplicate update query
        MySQL.query('DELETE FROM playerskins WHERE citizenid = ?', { Player.PlayerData.citizenid }, function()
            MySQL.insert('INSERT INTO playerskins (citizenid, model, skin, active) VALUES (?, ?, ?, ?)', {
                Player.PlayerData.citizenid,
                model,
                skin,
                1
            })
        end)
    end
end)

RegisterServerEvent('qb-clothes:loadPlayerSkin', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local result = MySQL.query.await('SELECT * FROM playerskins WHERE citizenid = ? AND active = ?', { Player.PlayerData.citizenid, 1 })
    if result and result[1] ~= nil then
        TriggerClientEvent('qb-clothes:loadSkin', src, false, result[1].model, result[1].skin)
    else
        TriggerClientEvent('qb-clothes:loadSkin', src, true)
    end
end)

RegisterServerEvent('qb-clothes:saveOutfit', function(outfitName, model, skinData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if type(outfitName) ~= 'string' or #outfitName < 1 or #outfitName > MAX_NAME_LENGTH then return end
    if validModel(model) and type(skinData) == 'table' then
        local encoded = json.encode(skinData)
        if #encoded > MAX_SKIN_LENGTH then return end
        if not canWrite(src, 'outfit') then return end
        local count = MySQL.scalar.await('SELECT COUNT(*) FROM player_outfits WHERE citizenid = ?', { Player.PlayerData.citizenid })
        if (tonumber(count) or 0) >= MAX_OUTFITS then
            TriggerClientEvent('QBCore:Notify', src, 'You have too many saved outfits.', 'error')
            return
        end
        local outfitId = 'outfit-' .. math.random(1, 10) .. '-' .. math.random(1111, 9999)
        MySQL.insert('INSERT INTO player_outfits (citizenid, outfitname, model, skin, outfitId) VALUES (?, ?, ?, ?, ?)', {
            Player.PlayerData.citizenid,
            outfitName,
            model,
            encoded,
            outfitId
        }, function()
            local result = MySQL.query.await('SELECT * FROM player_outfits WHERE citizenid = ?', { Player.PlayerData.citizenid })
            if result and result[1] ~= nil then
                TriggerClientEvent('qb-clothing:client:reloadOutfits', src, result)
            else
                TriggerClientEvent('qb-clothing:client:reloadOutfits', src, nil)
            end
        end)
    end
end)

RegisterServerEvent('qb-clothing:server:removeOutfit', function(outfitName, outfitId)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    MySQL.query('DELETE FROM player_outfits WHERE citizenid = ? AND outfitname = ? AND outfitId = ?', {
        Player.PlayerData.citizenid,
        tostring(outfitName),
        tostring(outfitId)
    }, function()
        local result = MySQL.query.await('SELECT * FROM player_outfits WHERE citizenid = ?', { Player.PlayerData.citizenid })
        if result and result[1] ~= nil then
            TriggerClientEvent('qb-clothing:client:reloadOutfits', src, result)
        else
            TriggerClientEvent('qb-clothing:client:reloadOutfits', src, nil)
        end
    end)
end)

QBCore.Functions.CreateCallback('qb-clothing:server:getOutfits', function(source, cb)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return cb({}) end
    local anusVal = {}

    local result = MySQL.query.await('SELECT * FROM player_outfits WHERE citizenid = ?', { Player.PlayerData.citizenid })
    if result and result[1] ~= nil then
        for k, v in pairs(result) do
            result[k].skin = json.decode(result[k].skin)
            anusVal[k] = v
        end
    end
    cb(anusVal)
end)
