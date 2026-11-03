local sharedItems = exports['pfm-core']:GetShared('Items')

-- Legacy evidence net events. The work is done by the evidence module (server/evidence/*): drops
-- are rate limited, persisted and sent only to on-duty police nearby; bagging creates an evidence
-- record and a bag built from the stored drop; every move of the bag is in the chain of custody.
-- The event names and arguments stay as they were so existing clients and scripts keep working.

local PlayerStatus = {}

local function Scene() return PFEvidence and PFEvidence.Scene end

local function StreetHint(info)
    local street = type(info) == 'table' and info.street
    if type(street) ~= 'string' then return nil end
    return { street = street:gsub('%c', ''):sub(1, 96) }
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

AddEventHandler('playerDropped', function() PlayerStatus[source] = nil end)

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

-- identity and position are the server's; the client's citizenid/bloodtype arguments are ignored
RegisterNetEvent('evidence:server:CreateBloodDrop', function(_, _, coords)
    local scene = Scene()
    if scene then scene.Report(source, 'blood', { coords = coords }) end
end)

RegisterNetEvent('evidence:server:CreateFingerDrop', function(coords)
    local scene = Scene()
    if scene then scene.Report(source, 'fingerprint', { coords = coords }) end
end)

RegisterNetEvent('evidence:server:CreateCasing', function(weapon, coords)
    local scene = Scene()
    if scene then scene.Report(source, 'casing', { weapon = weapon, coords = coords }) end
end)

-- bagging: the bag is built from the stored drop; the client only names the drop (and a street hint)
RegisterNetEvent('evidence:server:AddBlooddropToInventory', function(bloodId, info)
    local scene = Scene()
    if scene then scene.Collect(source, 'blood', bloodId, StreetHint(info)) end
end)

RegisterNetEvent('evidence:server:AddFingerprintToInventory', function(fingerId, info)
    local scene = Scene()
    if scene then scene.Collect(source, 'fingerprint', fingerId, StreetHint(info)) end
end)

RegisterNetEvent('evidence:server:AddCasingToInventory', function(casingId, info)
    local scene = Scene()
    if scene then scene.Collect(source, 'casing', casingId, StreetHint(info)) end
end)

RegisterNetEvent('evidence:server:ClearBlooddrops', function(list)
    local scene = Scene()
    if scene then scene.Clear(source, 'blood', list) end
end)

RegisterNetEvent('evidence:server:ClearCasings', function(list)
    local scene = Scene()
    if scene then scene.Clear(source, 'casing', list) end
end)

-- ══ Drug seizures → city timeline ═══════════════════════════════════
-- An on-duty officer moving drugs out of another player's inventory (the search menu opens it as
-- otherplayer-<id>) into their own is a seizure. pfm-inventory tells us after the move happened
-- (ItemMoved listener), so only real moves count. Moves by the same officer from the same suspect
-- within Config.DrugBustWindow are one bust: one 'crime.drugs.bust' news lead with the totals and
-- the officer's position. The suspect is not named.
local function CityEvent(kind, data, opts)
    if GetResourceState('pf-services') ~= 'started' then return nil end
    local svc = exports['pf-services']
    if not svc then return nil end
    local ok, id = pcall(function() return svc:Emit(kind, data, opts) end)
    return ok and id or nil
end

local busts = {} -- ['<officer>:<suspect>'] = { officer cid, coords, items = { [label] = amount } }

local function FlushBust(key)
    local bust = busts[key]
    busts[key] = nil
    if not bust then return end
    local list, total = {}, 0
    for label, amount in pairs(bust.items) do
        list[#list + 1] = { label = label, amount = amount }
        total = total + amount
    end
    table.sort(list, function(a, b) return a.amount > b.amount end)
    CityEvent('crime.drugs.bust', { items = list, total = total }, {
        title = ('Police seize %d units of drugs'):format(total), coords = bust.coords, actor = bust.officer,
        dedupe = key .. ':' .. tostring(bust.at),
    })
end

function PoliceOnItemMoved(moveType, data)
    if type(data) ~= 'table' or data.fromType ~= 'player' or data.toType ~= 'player' then return end
    local officerSrc, suspectSrc = tonumber(data.toId), tonumber(data.fromId)
    if not officerSrc or not suspectSrc or officerSrc == suspectSrc then return end
    local Officer = exports['pfm-core']:GetPlayer(officerSrc)
    local Suspect = exports['pfm-core']:GetPlayer(suspectSrc)
    if not Officer or not Suspect then return end
    if Officer.PlayerData.job.type ~= 'leo' or not Officer.PlayerData.job.onduty then return end
    if Suspect.PlayerData.job and Suspect.PlayerData.job.type == 'leo' and Suspect.PlayerData.job.onduty then return end
    local items = data.toInventory and data.toInventory.items
    local item = items and (items[tonumber(data.toSlot)] or items[tostring(data.toSlot)])
    if type(item) ~= 'table' or not (Config.SeizableDrugs or {})[item.name] then return end
    local amount = math.floor(tonumber(data.amount) or 0)
    if amount < 1 then return end
    local key = Officer.PlayerData.citizenid .. ':' .. Suspect.PlayerData.citizenid
    local bust = busts[key]
    if not bust then
        local p = GetEntityCoords(GetPlayerPed(officerSrc))
        bust = { officer = Officer.PlayerData.citizenid, coords = vector3(p.x, p.y, p.z), items = {}, at = os.time() }
        busts[key] = bust
        SetTimeout((Config.DrugBustWindow or 60) * 1000, function() FlushBust(key) end)
    end
    local shared = sharedItems[item.name]
    local label = (shared and shared.label) or item.label or item.name
    bust.items[label] = (bust.items[label] or 0) + amount
end

local function RegisterSeizureListener()
    if GetResourceState('pfm-inventory') ~= 'started' then return end
    pcall(function() exports['pfm-inventory']:AddListener('ItemMoved', PoliceOnItemMoved) end)
    -- the chain-of-custody recorder (server/evidence/custody.lua) listens to the same inventory
    if PFEvidence and PFEvidence.Custody then PFEvidence.Custody.RegisterListeners() end
end

-- registered once now if the inventory is already running, and again each time it (re)starts (it
-- forgets listeners when it stops); never both for the same inventory start
RegisterSeizureListener()
AddEventHandler('onResourceStart', function(resource)
    if resource == 'pfm-inventory' then RegisterSeizureListener() end
end)
