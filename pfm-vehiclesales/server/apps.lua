-- Used Cars (pf-devices app, tablet and computer): every car on the player-to-player sales lot with
-- its asking price, the city's purchase tax, the seller's contact and a waypoint to the lot. A seller
-- may change the price of their own listing from here; buying and taking a car back stay at the lot
-- (the car is handed over there).

PFUsedCars = PFUsedCars or {}

local APP = 'usedcars'
local sharedVehicles = exports['pfm-core']:GetShared('Vehicles') or {}

local function started(res) return GetResourceState(res) == 'started' end

local function point(v)
    if not v or not tonumber(v.x) or not tonumber(v.y) then return nil end
    return { x = math.floor(v.x * 100 + 0.5) / 100, y = math.floor(v.y * 100 + 0.5) / 100 }
end

local function lots()
    local out = {}
    for id, zone in pairs(Config.Zones or {}) do
        out[#out + 1] = { id = id, label = (zone.BusinessName or id):gsub('^Vehicle Sales Contract %- ', ''), coords = point(zone.BuyVehicle) }
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

local function taxPercent()
    if not started('pf-government') then return 0 end
    local ok, v = pcall(function() return exports['pf-government']:CalculateTax(10000, 'vehicle_purchase') end)
    return ok and (tonumber(v) or 0) / 100 or 0
end

-- Sellers' names and phone numbers (the lot's contract shows the same), one query for all listings.
local function sellers(cids)
    local out = {}
    if #cids == 0 then return out end
    local marks = string.rep('?,', #cids):sub(1, -2)
    for _, r in ipairs(MySQL.query.await('SELECT citizenid, charinfo FROM players WHERE citizenid IN (' .. marks .. ')', cids) or {}) do
        local ok, info = pcall(json.decode, r.charinfo or '')
        if ok and type(info) == 'table' then
            out[r.citizenid] = { name = (('%s %s'):format(info.firstname or '', info.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')), phone = info.phone }
        end
    end
    return out
end

function PFUsedCars.List(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local cid = Player.PlayerData.citizenid
    local rows = MySQL.query.await('SELECT id, seller, price, description, plate, model, occasionid FROM occasion_vehicles ORDER BY id DESC LIMIT 200', {}) or {}
    local cids, seen = {}, {}
    for _, r in ipairs(rows) do
        if r.seller and not seen[r.seller] then seen[r.seller] = true cids[#cids + 1] = r.seller end
    end
    local who = sellers(cids)
    local rate = taxPercent()
    local listings = {}
    for _, r in ipairs(rows) do
        local v = sharedVehicles[r.model] or {}
        local price = math.floor(tonumber(r.price) or 0)
        local s = who[r.seller] or {}
        listings[#listings + 1] = {
            id = r.occasionid, plate = r.plate, model = r.model,
            label = (v.brand and v.brand ~= '' and (v.brand .. ' ' .. (v.name or r.model))) or v.name or r.model,
            category = v.category, newPrice = tonumber(v.price),
            price = price, tax = math.floor(price * rate + 0.5) / 100, description = r.description and tostring(r.description):sub(1, 250) or '',
            seller = s.name, phone = s.phone, mine = r.seller == cid,
        }
    end
    return { ok = true, listings = listings, lots = lots(), taxPercent = rate }
end

--- Open Used Cars apps reload (a car was listed, sold or taken back).
function PFUsedCars.Changed()
    if started('pf-devices') then pcall(function() exports['pf-devices']:Broadcast(APP, 'changed', {}) end) end
end

--- The seller changes the asking price of their own listing.
function PFUsedCars.Reprice(src, payload)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local id = type(payload.id) == 'string' and #payload.id <= 50 and payload.id or nil
    local price = payload.price
    if not id then return { ok = false, error = 'bad_request' } end
    if type(price) ~= 'number' or price ~= math.floor(price) or price < 1 or price > 50000000 then return { ok = false, error = 'bad_price' } end
    local n = MySQL.update.await('UPDATE occasion_vehicles SET price = ? WHERE occasionid = ? AND seller = ?', { price, id, Player.PlayerData.citizenid })
    if (tonumber(n) or 0) < 1 then return { ok = false, error = 'not_yours' } end
    TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
    PFUsedCars.Changed()
    return { ok = true, price = price }
end

function PFUsedCars.RegisterApps()
    if not started('pf-devices') then return end
    local devices = exports['pf-devices']
    devices:RegisterApp({
        id = APP, name = 'Used Cars', icon = '🏷️', entry = 'html/apps/usedcars.js', styles = { 'html/apps/usedcars.css' },
        devices = { 'tablet', 'computer' }, category = 'apps', order = 23, access = { anyone = true },
        window = { width = 880, height = 620 }, description = 'Cars for sale by other citizens',
    })
    devices:RegisterAppHandlers(APP, {
        list = function(src) return PFUsedCars.List(src) end,
        reprice = function(src, p) return PFUsedCars.Reprice(src, p) end,
    })
end

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() or resource == 'pf-devices' then PFUsedCars.RegisterApps() end
end)
AddEventHandler('pf-devices:server:ready', function() PFUsedCars.RegisterApps() end)

-- A deleted character's listings go with them: pfm-core deleted their cars, and a listed car is
-- their car (it would otherwise be sold for a seller who no longer exists).
AddEventHandler('pfm-core:server:characterDeleted', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 50 then return end
    local res = MySQL.query.await('DELETE FROM occasion_vehicles WHERE seller = ?', { citizenid })
    if res and (tonumber(res.affectedRows) or 0) > 0 then
        TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
        PFUsedCars.Changed()
    end
end)
