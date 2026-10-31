-- Real Estate apps (pf-devices, tablet and computer).
--   realestate          everyone: houses for sale (price, costs, waypoint), the houses they own or
--                       hold a key to, their apartment, and an agent's sale offer to answer.
--   realestate-agency   the realestate job: listings (reprice, create where the agent stands), sales
--                       to a customer next to the agent, sales record and commissions.
-- A sale is offered by the agent and accepted by the customer on their own screen (an in-game prompt
-- and the app); the money moves only then, through the pfm-banking ledger, under keys fixed for that
-- offer: buyer -> system:pfm-houses (price + broker fee + tax), then the tax to pf-government, the
-- agency's and the agent's commissions out of it. The house is registered with pf-government.

PFHouses = PFHouses or {}

local CITIZEN_APP, AGENCY_APP = 'realestate', 'realestate-agency'

local function cfg() return Config.AgentSales or {} end
local function started(res) return GetResourceState(res) == 'started' end
local function playerOf(src) return exports['pfm-core']:GetPlayer(tonumber(src)) end

local function nameOf(Player)
    local ci = Player and Player.PlayerData.charinfo or {}
    local n = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    return n ~= '' and n or 'Unknown'
end

local function round2(n) return math.floor((tonumber(n) or 0) * 100 + 0.5) / 100 end

local function point(c)
    if type(c) ~= 'table' or not tonumber(c.x) or not tonumber(c.y) then return nil end
    return { x = round2(c.x), y = round2(c.y) }
end

local function hasGarage(h)
    local g = h and h.garage
    return type(g) == 'table' and tonumber(g.x) ~= nil and (tonumber(g.x) ~= 0 or tonumber(g.y) ~= 0)
end

local function distance(a, b)
    local pa, pb = GetEntityCoords(GetPlayerPed(a)), GetEntityCoords(GetPlayerPed(b))
    return #(vector3(pa.x, pa.y, pa.z) - vector3(pb.x, pb.y, pb.z))
end

local function push(src, app, event, payload)
    if not started('pf-devices') then return end
    pcall(function() exports['pf-devices']:Push(src, app, event, payload or {}) end)
end

local function pushAgency(event, payload)
    if not started('pf-devices') then return end
    pcall(function() exports['pf-devices']:PushToJob('realestate', AGENCY_APP, event, payload or {}, false) end)
end

local function notify(src, msg, kind) TriggerClientEvent('QBCore:Notify', src, msg, kind or 'primary') end

-- An agent may act from the app: realestate job, on duty when the config asks for it.
local function agentOf(src)
    local Player = playerOf(src)
    if not Player then return nil, 'no_player' end
    if not PFHouses.IsRealEstate(Player) then return nil, 'not_agent' end
    if cfg().RequireDuty ~= false and not Player.PlayerData.job.onduty then return nil, 'off_duty' end
    return Player
end

local function houseId(v)
    if type(v) ~= 'string' or v == '' or #v > 64 then return nil end
    return Config.Houses[v] and v or nil
end

local function forSale(house)
    return Config.Houses[house] ~= nil and PFHouses.OwnerOf(house) == nil and not PFHouses.Locked(house)
end

-- The property transfer tax rate in percent (pf-government's, else the 6% the purchase falls back to).
local function taxRate()
    if started('pf-government') then
        local ok, v = pcall(function() return exports['pf-government']:CalculateTax(10000, 'property_transfer') end)
        if ok and tonumber(v) then return tonumber(v) / 100 end
    end
    return 6
end

-- ── agent offers ────────────────────────────────────────────────────────────────────────────────

local offers = {}       -- [buyer src] = offer
local offerBy = {}      -- [agent src] = buyer src
local nextOffer = 0

local function offerView(o)
    return {
        id = o.id, house = o.house, address = o.address, price = o.price, broker = o.broker, tax = o.tax, total = o.total,
        agent = o.agentName, buyer = o.buyerName, expiresIn = math.max(0, o.expires - os.time()),
    }
end

local function dropOffer(buyerSrc)
    local o = offers[buyerSrc]
    if not o then return nil end
    offers[buyerSrc] = nil
    if offerBy[o.agentSrc] == buyerSrc then offerBy[o.agentSrc] = nil end
    return o
end

local function dropExpired()
    local now = os.time()
    for buyer, o in pairs(offers) do
        if now > o.expires then
            dropOffer(buyer)
            notify(o.agentSrc, 'The customer did not answer the offer', 'error')
            push(o.agentSrc, AGENCY_APP, 'changed')
            push(buyer, CITIZEN_APP, 'offerClosed', { id = o.id })
        end
    end
end

local function pendingFor(buyerSrc)
    dropExpired()
    local o = offers[buyerSrc]
    return o and offerView(o) or nil
end

--- An agent offers an unowned house to the customer next to them, at the listed price.
function PFHouses.AgentOffer(src, payload)
    local agent, err = agentOf(src)
    if not agent then return { ok = false, error = err } end
    if type(payload) ~= 'table' then return { ok = false, error = 'bad_request' } end
    local house = houseId(payload.house)
    if not house then return { ok = false, error = 'unknown_house' } end
    if not forSale(house) then return { ok = false, error = 'not_for_sale' } end
    local target = tonumber(payload.target)
    if not target or target ~= math.floor(target) then return { ok = false, error = 'bad_buyer' } end
    local buyer = playerOf(target)
    if not buyer or buyer.PlayerData.source == src then return { ok = false, error = 'bad_buyer' } end
    if distance(src, buyer.PlayerData.source) > (cfg().MaxDistance or 10.0) then return { ok = false, error = 'too_far' } end
    dropExpired()
    if offerBy[src] then return { ok = false, error = 'offer_pending' } end
    if offers[buyer.PlayerData.source] then return { ok = false, error = 'buyer_busy' } end
    for _, o in pairs(offers) do if o.house == house then return { ok = false, error = 'house_offered' } end end

    local price = math.floor(tonumber(Config.Houses[house].price) or 0)
    if price <= 0 then return { ok = false, error = 'not_for_sale' } end
    local broker = math.floor(price * (cfg().BrokerFeePercent or 5) / 100)
    local tax = round2(PFHouses.PurchaseCost(price).tax)
    nextOffer = nextOffer + 1
    local o = {
        id = ('%d-%d-%d'):format(os.time(), nextOffer, math.random(1000, 9999)),
        house = house, address = Config.Houses[house].adress or house,
        price = price, broker = broker, tax = tax, total = round2(price + broker + tax),
        agentSrc = src, agentCid = agent.PlayerData.citizenid, agentName = nameOf(agent),
        buyerSrc = buyer.PlayerData.source, buyerCid = buyer.PlayerData.citizenid, buyerName = nameOf(buyer),
        expires = os.time() + (cfg().OfferSeconds or 60),
    }
    offers[o.buyerSrc] = o
    offerBy[src] = o.buyerSrc
    local view = offerView(o)
    TriggerClientEvent('qb-houses:client:ConfirmAgentSale', o.buyerSrc, view)
    push(o.buyerSrc, CITIZEN_APP, 'offer', view)
    notify(src, ('Offer for %s sent to %s; waiting for their answer'):format(o.address, o.buyerName), 'primary')
    return { ok = true, offer = view }
end

function PFHouses.CancelAgentOffer(src)
    local buyer = offerBy[src]
    if not buyer then return { ok = false, error = 'not_found' } end
    local o = dropOffer(buyer)
    if o then
        notify(buyer, 'The agent withdrew the offer', 'error')
        push(buyer, CITIZEN_APP, 'offerClosed', { id = o.id })
    end
    return { ok = true }
end

local function recordSale(o, agencyCut, agentCut, key)
    if not PFHouses.dbReady then return end
    MySQL.insert.await([[INSERT IGNORE INTO pfm_house_sales (house, address, kind, price, broker_fee, tax, total, buyer_cid, buyer_name,
        agent_cid, agent_name, agent_commission, agency_commission, ledger_key) VALUES (?, ?, 'agent', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
        o.house, o.address, o.price, o.broker, o.tax, o.total, o.buyerCid, o.buyerName, o.agentCid, o.agentName, agentCut, agencyCut, key,
    })
end

local function completeSale(o)
    local agent, buyer = playerOf(o.agentSrc), playerOf(o.buyerSrc)
    if not agent or agent.PlayerData.citizenid ~= o.agentCid or not buyer or buyer.PlayerData.citizenid ~= o.buyerCid then
        return { ok = false, error = 'party_left' }
    end
    if not PFHouses.IsRealEstate(agent) or (cfg().RequireDuty ~= false and not agent.PlayerData.job.onduty) then
        return { ok = false, error = 'agent_unavailable' }
    end
    if distance(o.agentSrc, o.buyerSrc) > (cfg().MaxDistance or 10.0) then return { ok = false, error = 'too_far' } end
    if PFHouses.OwnerOf(o.house) or not PFHouses.Lock(o.house) then return { ok = false, error = 'not_for_sale' } end

    local key = 'pfm-houses:agent:' .. o.id
    local ok, res = pcall(function()
        if PFHouses.IsHouseOwned(o.house) then return { ok = false, error = 'not_for_sale' } end
        if not PFPayout.Charge(o.buyerSrc, 'bank', o.total, { key = key .. ':charge', kind = 'purchase', reason = 'House purchase ' .. o.address, quiet = true }) then
            return { ok = false, error = 'insufficient_funds' }
        end
        -- the house may have been sold by another route while the money moved: give it back
        if PFHouses.OwnerOf(o.house) or PFHouses.IsHouseOwned(o.house) then
            PFPayout.Pay(o.buyerCid, 'bank', o.total, { key = key .. ':refund', kind = 'refund', reason = 'House no longer for sale' })
            return { ok = false, error = 'not_for_sale' }
        end
        PFHouses.GiveHouse(o.house, buyer, o.price)   -- the price paid, for the state sell-back
        PFHouses.SettlePropertyTax(o.tax, o.buyerCid, key, o.price)
        local agencyCut = math.floor(o.price * (cfg().AgencyCommissionPercent or 0) / 100)
        local agentCut = math.floor(o.price * (cfg().AgentCommissionPercent or 0) / 100)
        if agencyCut > 0 then
            if not PFPayout.PaySociety(cfg().Society or 'realestate', agencyCut, { key = key .. ':agency', reason = 'House sale commission: ' .. o.address }) then
                print(('^1[pfm-houses]^7 agency commission %d for %s not paid, key %s:agency'):format(agencyCut, o.house, key))
                agencyCut = 0
            end
        end
        if agentCut > 0 then
            if not PFPayout.Pay(o.agentCid, 'bank', agentCut, { key = key .. ':agent', kind = 'wage', reason = 'House sale commission: ' .. o.address, quiet = true }) then
                agentCut = 0
            end
        end
        recordSale(o, agencyCut, agentCut, key)
        return { ok = true, agencyCut = agencyCut, agentCut = agentCut }
    end)
    PFHouses.Unlock(o.house)
    if not ok then
        print(('^1[pfm-houses]^7 agent sale %s failed: %s'):format(o.id, tostring(res)))
        return { ok = false, error = 'server_error' }
    end
    if not res.ok then return res end

    TriggerClientEvent('qb-houses:client:SetClosestHouse', -1)
    TriggerClientEvent('qb-house:client:RefreshHouseTargets', -1)
    TriggerClientEvent('qb-houses:client:setHouseConfig', -1, Config.Houses)
    notify(o.buyerSrc, ('You bought %s for $%.2f'):format(o.address, o.total), 'success')
    notify(o.agentSrc, ('%s sold to %s. Your commission: $%d'):format(o.address, o.buyerName, res.agentCut), 'success')
    push(o.buyerSrc, CITIZEN_APP, 'changed')
    pushAgency('changed')
    TriggerEvent('qb-log:server:CreateLog', 'house', 'House sold by an agent', 'green',
        ('%s sold %s to %s for $%.2f (agency $%d, agent $%d)'):format(o.agentName, o.house, o.buyerName, o.total, res.agencyCut, res.agentCut))
    return { ok = true, house = o.house, total = o.total }
end

--- The customer answers an offer (the in-game prompt or the app). Single use, before it expires.
function PFHouses.AnswerAgentOffer(src, id, accept)
    if type(id) ~= 'string' or #id > 40 then return { ok = false, error = 'bad_request' } end
    local o = offers[src]
    if not o or o.id ~= id then return { ok = false, error = 'not_found' } end
    dropOffer(src)
    push(o.agentSrc, AGENCY_APP, 'changed')
    if os.time() > o.expires then return { ok = false, error = 'expired' } end
    if accept ~= true then
        notify(o.agentSrc, ('%s declined the offer for %s'):format(o.buyerName, o.address), 'error')
        return { ok = true, declined = true }
    end
    local res = completeSale(o)
    if not res.ok then
        local why = res.error == 'insufficient_funds' and 'The customer could not pay' or 'The sale did not go through'
        notify(o.agentSrc, why, 'error')
        notify(src, res.error == 'insufficient_funds' and 'Not enough money in your bank account' or 'The sale did not go through', 'error')
    end
    return res
end

RegisterNetEvent('qb-houses:server:RespondAgentSale', function(id, accepted)
    PFHouses.AnswerAgentOffer(source, id, accepted == true)
end)

function PFHouses.OnPlayerDropped(src)
    if offers[src] then
        local o = dropOffer(src)
        if o then push(o.agentSrc, AGENCY_APP, 'changed') end
    end
    if offerBy[src] then dropOffer(offerBy[src]) end
end

function PFHouses.OnCharacterDeleted(cid)
    for buyer, o in pairs(offers) do
        if o.buyerCid == cid or o.agentCid == cid then dropOffer(buyer) end
    end
    if PFHouses.dbReady then
        -- the sales record stays (it is the agency's history), without the deleted character's id
        MySQL.update('UPDATE pfm_house_sales SET buyer_cid = NULL WHERE buyer_cid = ?', { cid })
        MySQL.update('UPDATE pfm_house_sales SET agent_cid = NULL WHERE agent_cid = ?', { cid })
    end
end

-- ── citizen app ─────────────────────────────────────────────────────────────────────────────────

function PFHouses.CitizenList(src)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local cid = Player.PlayerData.citizenid
    local rate = taxRate()
    local brokerPct = cfg().BrokerFeePercent or 5
    local sale = {}
    for house, h in pairs(Config.Houses) do
        if forSale(house) then
            local price = math.floor(tonumber(h.price) or 0)
            if price > 0 then
                local tax = round2(price * rate / 100)
                sale[#sale + 1] = {
                    id = house, address = h.adress or house, price = price, tier = tonumber(h.tier) or 1, garage = hasGarage(h),
                    coords = point(h.coords and h.coords.enter),
                    tax = tax,
                    doorTotal = round2(price * 1.15 + tax),               -- bought at the door: 5% broker and 10% bank fees
                    agentTotal = round2(price + math.floor(price * brokerPct / 100) + tax),
                }
            end
        end
    end
    table.sort(sale, function(a, b) if a.price ~= b.price then return a.price < b.price end return a.id < b.id end)

    local mine = {}
    for house, role in pairs(PFHouses.HousesOf(cid)) do
        local h = Config.Houses[house]
        if h then
            local holders = PFHouses.KeyHolders(house) or {}
            mine[#mine + 1] = {
                id = house, address = h.adress or house, tier = tonumber(h.tier) or 1, role = role,
                locked = h.locked ~= false, garage = hasGarage(h), coords = point(h.coords and h.coords.enter),
                keys = role == 'owner' and math.max(0, #holders - 1) or nil,
            }
        end
    end
    table.sort(mine, function(a, b) if a.role ~= b.role then return a.role == 'owner' end return a.address < b.address end)

    local apartment
    if started('pfm-apartments') then
        local ok, apt = pcall(function() return exports['pfm-apartments']:GetCitizenApartment(cid) end)
        if ok and type(apt) == 'table' then apartment = apt end
    end
    return {
        ok = true, forSale = sale, mine = mine, apartment = apartment, offer = pendingFor(src),
        taxRate = rate, brokerPercent = brokerPct, isAgent = PFHouses.IsRealEstate(Player) == true,
    }
end

-- ── agency app ──────────────────────────────────────────────────────────────────────────────────

function PFHouses.AgencyData(src)
    local Player = playerOf(src)
    if not Player or not PFHouses.IsRealEstate(Player) then return { ok = false, error = 'not_agent' } end
    dropExpired()
    local offered = {}
    for _, o in pairs(offers) do offered[o.house] = true end
    local listings = {}
    for house, h in pairs(Config.Houses) do
        local status = PFHouses.OwnerOf(house) and 'sold' or ((offered[house] or PFHouses.Locked(house)) and 'pending' or 'available')
        listings[#listings + 1] = {
            id = house, address = h.adress or house, price = math.floor(tonumber(h.price) or 0), tier = tonumber(h.tier) or 1,
            status = status, garage = hasGarage(h), coords = point(h.coords and h.coords.enter),
        }
    end
    table.sort(listings, function(a, b) if a.status ~= b.status then return a.status < b.status end return a.address < b.address end)

    local sales, stats = {}, { mine = 0, agency = 0, count = 0 }
    if PFHouses.dbReady then
        for _, r in ipairs(MySQL.query.await('SELECT id, house, address, price, total, buyer_name, agent_name, agent_cid, agent_commission, agency_commission, UNIX_TIMESTAMP(created_at) AS at FROM pfm_house_sales ORDER BY id DESC LIMIT 25') or {}) do
            sales[#sales + 1] = {
                id = tonumber(r.id), house = r.house, address = r.address, price = tonumber(r.price), total = tonumber(r.total),
                buyer = r.buyer_name, agent = r.agent_name, mine = r.agent_cid == Player.PlayerData.citizenid,
                commission = r.agent_cid == Player.PlayerData.citizenid and tonumber(r.agent_commission) or nil, at = tonumber(r.at),
            }
        end
        local row = MySQL.single.await([[SELECT COUNT(*) AS n, COALESCE(SUM(agency_commission), 0) AS agency,
            COALESCE(SUM(CASE WHEN agent_cid = ? THEN agent_commission ELSE 0 END), 0) AS mine
            FROM pfm_house_sales WHERE created_at >= NOW() - INTERVAL 7 DAY]], { Player.PlayerData.citizenid }) or {}
        stats = { mine = tonumber(row.mine) or 0, agency = tonumber(row.agency) or 0, count = tonumber(row.n) or 0 }
    end
    local outgoing = offerBy[src] and offers[offerBy[src]]
    return {
        ok = true, listings = listings, sales = sales, stats = stats, offer = outgoing and offerView(outgoing) or nil,
        onDuty = Player.PlayerData.job.onduty == true, requireDuty = cfg().RequireDuty ~= false,
        commission = { agency = cfg().AgencyCommissionPercent or 0, agent = cfg().AgentCommissionPercent or 0, broker = cfg().BrokerFeePercent or 5 },
        priceRange = { min = cfg().MinPrice or 1000, max = cfg().MaxPrice or 100000000 },
    }
end

--- Customers the agent can make an offer to: players standing next to them (server positions).
function PFHouses.NearbyCustomers(src)
    local agent, err = agentOf(src)
    if not agent then return { ok = false, error = err } end
    local out = {}
    for _, P in pairs(exports['pfm-core']:GetCoreObject({ 'Functions' }).Functions.GetQBPlayers() or {}) do
        local other = P.PlayerData.source
        if other ~= src and distance(src, other) <= (cfg().MaxDistance or 10.0) then
            out[#out + 1] = { id = other, name = nameOf(P) }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return { ok = true, players = out }
end

function PFHouses.SetListingPrice(src, payload)
    local agent, err = agentOf(src)
    if not agent then return { ok = false, error = err } end
    if type(payload) ~= 'table' then return { ok = false, error = 'bad_request' } end
    local house = houseId(payload.house)
    if not house then return { ok = false, error = 'unknown_house' } end
    local price = tonumber(payload.price)
    if not price or price ~= math.floor(price) or price < (cfg().MinPrice or 1000) or price > (cfg().MaxPrice or 100000000) then
        return { ok = false, error = 'bad_price' }
    end
    -- an owned house keeps its price (the owned flag also covers an owner row not loaded yet)
    if not forSale(house) or Config.Houses[house].owned == true then return { ok = false, error = 'not_for_sale' } end
    for _, o in pairs(offers) do if o.house == house then return { ok = false, error = 'house_offered' } end end
    if price == math.floor(tonumber(Config.Houses[house].price) or 0) then return { ok = true, price = price } end
    -- The purchase lock: a door or agent sale cannot read the price while it changes, and none is
    -- paying now. Memory follows only when the database changed that one unowned row.
    if not PFHouses.Lock(house) then return { ok = false, error = 'not_for_sale' } end
    local ok, changed = pcall(MySQL.update.await, 'UPDATE houselocations SET price = ? WHERE name = ? AND (owned = 0 OR owned IS NULL)', { price, house })
    local applied = ok and tonumber(changed) == 1
    if applied then Config.Houses[house].price = price end
    PFHouses.Unlock(house)
    if not ok then print(('^1[pfm-houses]^7 reprice of %s failed: %s'):format(house, tostring(changed))) end
    if not applied then return { ok = false, error = ok and 'not_for_sale' or 'server_error' } end
    TriggerClientEvent('qb-houses:client:setHouseConfig', -1, Config.Houses)
    pushAgency('changed')
    TriggerEvent('qb-log:server:CreateLog', 'house', 'House repriced', 'orange', ('%s set %s to $%d'):format(nameOf(agent), house, price))
    return { ok = true, price = price }
end

function PFHouses.AppCreateListing(src, payload)
    local agent, err = agentOf(src)
    if not agent then return { ok = false, error = err } end
    if type(payload) ~= 'table' then return { ok = false, error = 'bad_request' } end
    local street = type(payload.street) == 'string' and payload.street:gsub('^%s+', ''):gsub('%s+$', '') or ''
    if street == '' or #street > 48 or not street:match("^[%w%s%.%-']+$") then return { ok = false, error = 'bad_street' } end
    local price, tier = tonumber(payload.price), tonumber(payload.tier)
    if not price or price ~= math.floor(price) or price < (cfg().MinPrice or 1000) or price > (cfg().MaxPrice or 100000000) then
        return { ok = false, error = 'bad_price' }
    end
    if not tier or tier ~= math.floor(tier) or tier < 1 or tier > 20 then return { ok = false, error = 'bad_tier' } end
    -- the entrance is where the agent stands, read on the server
    local ped = GetPlayerPed(src)
    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading and tonumber(GetEntityHeading(ped)) or 0.0
    local coords = {
        enter = { x = pos.x, y = pos.y, z = pos.z, h = heading },
        cam = { x = pos.x, y = pos.y, z = pos.z, h = heading, yaw = -10.00 },
    }
    local name, why = PFHouses.CreateListing(src, street, coords, price, tier)
    if not name then return { ok = false, error = why or 'bad_request' } end
    pushAgency('changed')
    return { ok = true, house = name }
end

-- ── registration ────────────────────────────────────────────────────────────────────────────────

function PFHouses.RegisterApps()
    if not started('pf-devices') then return end
    local devices = exports['pf-devices']
    devices:RegisterApp({
        id = CITIZEN_APP, name = 'Real Estate', icon = '🏠', entry = 'html/apps/realestate.js', styles = { 'html/apps/realestate.css' },
        devices = { 'tablet', 'computer' }, category = 'apps', order = 21, access = { anyone = true },
        window = { width = 900, height = 640 }, description = 'Houses for sale and your properties',
    })
    devices:RegisterApp({
        id = AGENCY_APP, name = 'Dynasty 8', icon = '🏢', entry = 'html/apps/realestate.js', styles = { 'html/apps/realestate.css' },
        devices = { 'tablet', 'computer' }, category = 'jobs', order = 40, access = { jobs = { realestate = 0 } },
        window = { width = 960, height = 660 }, description = 'Listings, sales and commissions of the agency',
    })
    devices:RegisterAppHandlers(CITIZEN_APP, {
        list = function(src) return PFHouses.CitizenList(src) end,
        answerOffer = function(src, p) return PFHouses.AnswerAgentOffer(src, p.id, p.accept == true) end,
    })
    devices:RegisterAppHandlers(AGENCY_APP, {
        agency = function(src) return PFHouses.AgencyData(src) end,
        nearby = function(src) return PFHouses.NearbyCustomers(src) end,
        offer = function(src, p) return PFHouses.AgentOffer(src, p) end,
        cancelOffer = function(src) return PFHouses.CancelAgentOffer(src) end,
        setPrice = function(src, p) return PFHouses.SetListingPrice(src, p) end,
        createListing = function(src, p) return PFHouses.AppCreateListing(src, p) end,
    })
end

function PFHouses.Start()
    local ok, done, err = pcall(function() return exports['pfm-core']:RunMigrations(GetCurrentResourceName(), PFHouses.Migrations) end)
    PFHouses.dbReady = ok and done == true
    if not PFHouses.dbReady then print('^1[pfm-houses]^7 migrations failed, agency sales are not recorded: ' .. tostring(ok and err or done)) end
    PFHouses.RegisterApps()
end

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then PFHouses.Start()
    elseif resource == 'pf-devices' then PFHouses.RegisterApps() end
end)
AddEventHandler('pf-devices:server:ready', function() PFHouses.RegisterApps() end)

CreateThread(function()
    while true do
        Wait(10000)
        dropExpired()
    end
end)
