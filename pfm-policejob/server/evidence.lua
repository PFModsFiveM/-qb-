local sharedItems = exports['pfm-core']:GetShared('Items')
local sharedWeapons = exports['pfm-core']:GetShared('Weapons')

local Casings = {}
local BloodDrops = {}
local FingerDrops = {}
local PlayerStatus = {}

-- Functions

local function CreateBloodId()
    if BloodDrops then
        local bloodId = math.random(10000, 99999)
        while BloodDrops[bloodId] do
            bloodId = math.random(10000, 99999)
        end
        return bloodId
    else
        local bloodId = math.random(10000, 99999)
        return bloodId
    end
end

local function CreateFingerId()
    if FingerDrops then
        local fingerId = math.random(10000, 99999)
        while FingerDrops[fingerId] do
            fingerId = math.random(10000, 99999)
        end
        return fingerId
    else
        local fingerId = math.random(10000, 99999)
        return fingerId
    end
end

local function CreateCasingId()
    if Casings then
        local caseId = math.random(10000, 99999)
        while Casings[caseId] do
            caseId = math.random(10000, 99999)
        end
        return caseId
    else
        local caseId = math.random(10000, 99999)
        return caseId
    end
end

local function DnaHash(s)
    return (string.gsub(s, '.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

-- Evidence keeps where it was dropped; the bag contents are built here from the stored drop, not from
-- what the collecting client sends (a client could bag any DNA, fingerprint or serial number).
local function ValidCoords(src, coords)
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' then return nil end
    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y or not z then return nil end
    local v = vector3(x, y, z)
    if #(GetEntityCoords(GetPlayerPed(src)) - v) > 50.0 then return nil end
    return v
end

local function NearDrop(src, dropCoords)
    return dropCoords ~= nil and #(GetEntityCoords(GetPlayerPed(src)) - dropCoords) < 5.0
end

local function StreetLabel(info)
    local street = type(info) == 'table' and info.street
    if type(street) ~= 'string' then return '' end
    return street:gsub('%c', ''):sub(1, 128)
end

-- Callbacks

QBCore.Functions.CreateCallback('police:GetPlayerStatus', function(source, cb, playerId)
    local Player = exports['pfm-core']:GetPlayer(tonumber(playerId))
    local statList = {}
    local Officer = exports['pfm-core']:GetPlayer(source)
    if not Officer or Officer.PlayerData.job.type ~= 'leo' or not Officer.PlayerData.job.onduty then return cb(statList) end
    if Player and #(GetEntityCoords(GetPlayerPed(source)) - GetEntityCoords(GetPlayerPed(Player.PlayerData.source))) > 10.0 then return cb(statList) end
    if Player then
        if PlayerStatus[Player.PlayerData.source] and next(PlayerStatus[Player.PlayerData.source]) then
            for k in pairs(PlayerStatus[Player.PlayerData.source]) do
                statList[#statList + 1] = PlayerStatus[Player.PlayerData.source][k].text
            end
        end
    end
    cb(statList)
end)

-- Events

local function IsOnDutyLeo(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    return Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty
end

RegisterNetEvent('evidence:server:UpdateStatus', function(data)
    local src = source
    if type(data) ~= 'table' then return end
    local clean, count = {}, 0
    for k, v in pairs(data) do
        count = count + 1
        if count > 20 then break end
        if type(k) == 'string' and #k <= 32 and type(v) == 'table' and type(v.text) == 'string' then
            clean[k] = { text = v.text:sub(1, 100), time = tonumber(v.time) }
        end
    end
    PlayerStatus[src] = clean
end)

RegisterNetEvent('evidence:server:CreateBloodDrop', function(citizenid, bloodtype, coords)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    -- never trust the client for identity: use the sender's own citizenid/bloodtype
    citizenid = Player.PlayerData.citizenid
    bloodtype = Player.PlayerData.metadata['bloodtype'] or (type(bloodtype) == 'string' and bloodtype:sub(1, 8)) or nil
    coords = ValidCoords(src, coords)
    if not coords then return end
    local bloodId = CreateBloodId()
    BloodDrops[bloodId] = {
        dna = citizenid,
        bloodtype = bloodtype,
        coords = coords
    }
    TriggerClientEvent('evidence:client:AddBlooddrop', -1, bloodId, citizenid, bloodtype, coords)
end)

RegisterNetEvent('evidence:server:CreateFingerDrop', function(coords)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    coords = ValidCoords(src, coords)
    if not coords then return end
    local fingerId = CreateFingerId()
    FingerDrops[fingerId] = { fingerprint = Player.PlayerData.metadata['fingerprint'], coords = coords }
    TriggerClientEvent('evidence:client:AddFingerPrint', -1, fingerId, Player.PlayerData.metadata['fingerprint'], coords)
end)

RegisterNetEvent('evidence:server:ClearBlooddrops', function(blooddropList)
    if not IsOnDutyLeo(source) then return end
    if type(blooddropList) ~= 'table' then return end
    if blooddropList and next(blooddropList) then
        for _, v in pairs(blooddropList) do
            TriggerClientEvent('evidence:client:RemoveBlooddrop', -1, v)
            BloodDrops[v] = nil
        end
    end
end)

RegisterNetEvent('evidence:server:AddBlooddropToInventory', function(bloodId, bloodInfo)
    local src = source
    if not IsOnDutyLeo(src) then return end
    local drop = BloodDrops[bloodId]
    if not drop or not NearDrop(src, drop.coords) then return end
    bloodInfo = {
        label = Lang:t('info.blood'),
        type = 'blood',
        street = StreetLabel(bloodInfo),
        dnalabel = DnaHash(drop.dna),
        bloodtype = drop.bloodtype
    }
    if exports['pfm-inventory']:RemoveItem(src, 'empty_evidence_bag', 1, false, 'evidence:server:AddBlooddropToInventory') then
        if exports['pfm-inventory']:AddItem(src, 'filled_evidence_bag', 1, false, bloodInfo, 'evidence:server:AddBlooddropToInventory') then
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['filled_evidence_bag'], 'add')
            TriggerClientEvent('evidence:client:RemoveBlooddrop', -1, bloodId)
            BloodDrops[bloodId] = nil
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.have_evidence_bag'), 'error')
    end
end)

RegisterNetEvent('evidence:server:AddFingerprintToInventory', function(fingerId, fingerInfo)
    local src = source
    if not IsOnDutyLeo(src) then return end
    local drop = FingerDrops[fingerId]
    if not drop or not NearDrop(src, drop.coords) then return end
    fingerInfo = {
        label = Lang:t('info.fingerprint'),
        type = 'fingerprint',
        street = StreetLabel(fingerInfo),
        fingerprint = drop.fingerprint
    }
    if exports['pfm-inventory']:RemoveItem(src, 'empty_evidence_bag', 1, false, 'evidence:server:AddFingerprintToInventory') then
        if exports['pfm-inventory']:AddItem(src, 'filled_evidence_bag', 1, false, fingerInfo, 'evidence:server:AddFingerprintToInventory') then
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['filled_evidence_bag'], 'add')
            TriggerClientEvent('evidence:client:RemoveFingerprint', -1, fingerId)
            FingerDrops[fingerId] = nil
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.have_evidence_bag'), 'error')
    end
end)

RegisterNetEvent('evidence:server:CreateCasing', function(weapon, coords)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if not sharedWeapons[weapon] then return end
    coords = ValidCoords(src, coords)
    if not coords then return end
    local casingId = CreateCasingId()
    local weaponInfo = sharedWeapons[weapon]
    local serieNumber = nil
    if weaponInfo then
        local weaponItem = Player.GetItemByName(weaponInfo['name'])
        if weaponItem then
            if weaponItem.info and weaponItem.info ~= '' then
                serieNumber = weaponItem.info.serie
            end
        end
    end
    Casings[casingId] = { weapon = weapon, serie = serieNumber, coords = coords }
    TriggerClientEvent('evidence:client:AddCasing', -1, casingId, weapon, coords, serieNumber)
end)

RegisterNetEvent('evidence:server:ClearCasings', function(casingList)
    if not IsOnDutyLeo(source) then return end
    if type(casingList) ~= 'table' then return end
    if casingList and next(casingList) then
        for _, v in pairs(casingList) do
            TriggerClientEvent('evidence:client:RemoveCasing', -1, v)
            Casings[v] = nil
        end
    end
end)

RegisterNetEvent('evidence:server:AddCasingToInventory', function(casingId, casingInfo)
    local src = source
    if not IsOnDutyLeo(src) then return end
    local casing = Casings[casingId]
    if not casing or not NearDrop(src, casing.coords) then return end
    local ammotype = sharedWeapons[casing.weapon] and sharedWeapons[casing.weapon]['ammotype']
    casingInfo = {
        label = Lang:t('info.casing'),
        type = 'casing',
        street = StreetLabel(casingInfo),
        ammolabel = ammotype and Config.AmmoLabels[ammotype] or nil,
        ammotype = casing.weapon,
        serie = casing.serie
    }
    if exports['pfm-inventory']:RemoveItem(src, 'empty_evidence_bag', 1, false, 'evidence:server:AddCasingToInventory') then
        if exports['pfm-inventory']:AddItem(src, 'filled_evidence_bag', 1, false, casingInfo, 'evidence:server:AddCasingToInventory') then
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['filled_evidence_bag'], 'add')
            TriggerClientEvent('evidence:client:RemoveCasing', -1, casingId)
            Casings[casingId] = nil
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.have_evidence_bag'), 'error')
    end
end)
