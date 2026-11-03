-- Hot dog stand (server). Everything that earns is decided here:
--   * the deposit is charged on the bank ledger under a lock taken before the ledger wait, so a
--     double click cannot charge it twice; an unclear charge keeps its key until the bank settles it;
--   * the stand the client spawned is registered by its network id (right model, at the depot), and
--     cooking and selling happen only next to it;
--   * a hot dog is cooked through a pfm-minigames challenge the server issues and judges: the
--     server counts the faults, so it decides the quality; the stock lives in the server session,
--     capped by the level the server reads from the player's reputation, and the reputation is
--     granted only for a hot dog actually made (the free 'UpdateReputation' event is gone);
--   * a sale names only the customer ped: the server checks it (exists, not a player, close, not
--     served in the last 30 minutes), picks the best quality in stock, the amount and the price for
--     the player's level, and pays once on the ledger per sale number. No inventory item is needed
--     (the old 'hotdog' item never existed, so no stand could ever earn).
-- An unclear sale payment keeps the hot dogs sold and is asked again under the same key; only a
-- clear failure puts them back in stock.

local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local Bail = {}     -- [citizenid] = { id, amount } stand out; { pending, id } while charging; { unclear, id } while the bank settles
local Sessions = {} -- [src] = the stand's shift (stock, cook, offer, sales)
local SrcToCid = {}
local Served = {}   -- [customer net id] = os.time() of their last purchase (any stand)
local PendingSales = {} -- [citizenid] = { sale, ... } whose pay the bank had not settled
local SettlingSales = {} -- [citizenid] while a settle run waits on the bank

local STAND_MODEL = 'prop_hotdogstand_01'
local STAND_REGISTER_RANGE = 15.0 -- metres from the depot spawn point (and the player) a new stand may be
local STAND_RANGE = 3.5           -- metres from the stand to cook or sell (the client prompts at 1 m)
local CUSTOMER_RANGE = 5.0        -- metres between the seller and the customer
local CUSTOMER_MEMORY = 30 * 60   -- a customer buys once in this many seconds
local OFFER_TTL = 90              -- seconds an offer stays open
local COOK_TTL = 60               -- seconds a cook may take before another can start
local COOK_KEYS = 10
local SALE_RETRY_MS, SALE_RETRIES = 30000, 20
local QUALITIES = { 'exotic', 'rare', 'common' } -- best first
local REP_GAIN = { exotic = 3, rare = 2, common = 1 }

local function notify(src, msg, kind) TriggerClientEvent('QBCore:Notify', src, msg, kind or 'primary') end

local function applyStreakBonus(streak, amount)
    local sb = Config.StreakBonus
    if not sb or not sb.enabled or streak <= 0 then return amount end
    local mult = math.min(streak * (sb.perDelivery or 0.02), sb.cap or 0.25)
    return math.floor(amount * (1.0 + mult) + 0.5)
end

--- The stand level for a reputation (the same steps the client shows).
local function levelOf(rep)
    rep = tonumber(rep) or 0
    if rep >= 200 then return 4 elseif rep >= 100 then return 3 elseif rep >= 50 then return 2 end
    return 1
end

local function repOf(Player) return (Player and Player.GetRep and tonumber(Player.GetRep('hotdog'))) or 0 end

local function newSession(id)
    return { id = id, startedAt = os.time(), streak = 0, lastSale = 0, sales = 0, earned = 0, sold = 0,
        stock = { exotic = 0, rare = 0, common = 0 } }
end

local function stockCopy(session)
    local out = {}
    for _, q in ipairs(QUALITIES) do out[q] = session.stock[q] or 0 end
    return out
end

local function pushStock(src, session)
    TriggerClientEvent('qb-hotdogjob:client:UpdateStock', src, stockCopy(session))
end

local function pushApp(src, session)
    if GetResourceState('pf-devices') ~= 'started' then return end
    pcall(function() exports['pf-devices']:Push(src, 'hotdogstand', 'sale', { sold = session.sold, earned = session.earned }) end)
end

-- The player and their stand shift, when they have a stand out.
local function standSession(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return nil end
    local session = Sessions[src]
    local bail = Bail[Player.PlayerData.citizenid]
    if not session or not bail or not bail.amount then return nil end
    return Player, session
end

local function sameModel(entity, name)
    local ok, model = pcall(GetEntityModel, entity)
    return ok and ((tonumber(model) or 0) & 0xFFFFFFFF) == (GetHashKey(name) & 0xFFFFFFFF)
end

local function exists(e) return e ~= nil and e ~= 0 and DoesEntityExist(e) end

local function standEntity(session)
    local e = session.standNet and NetworkGetEntityFromNetworkId(session.standNet)
    return exists(e) and e or nil
end

local function nearStand(src, session)
    local e = standEntity(session)
    if not e then return false end
    return #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(e)) <= STAND_RANGE
end

local function intId(v)
    v = tonumber(v)
    if not v or v <= 0 or v ~= math.floor(v) then return nil end
    return v
end

-- The customer ped a client names: it must exist, be an NPC, stand next to the seller and not have
-- bought in the last CUSTOMER_MEMORY seconds.
local function customerOf(src, netId)
    netId = intId(netId)
    if not netId then return nil end
    local ped = NetworkGetEntityFromNetworkId(netId)
    if not exists(ped) then return nil end
    local seller = GetPlayerPed(src)
    if ped == seller or (IsPedAPlayer and IsPedAPlayer(ped)) then return nil end
    if GetEntityType and GetEntityType(ped) ~= 1 then return nil end -- 1 = a ped
    if Served[netId] and os.time() - Served[netId] < CUSTOMER_MEMORY then return nil end
    if #(GetEntityCoords(seller) - GetEntityCoords(ped)) > CUSTOMER_RANGE then return nil end
    return ped, netId
end

-- ── the deposit ─────────────────────────────────────────────────────

QBCore.Functions.CreateCallback('qb-hotdogjob:server:HasMoney', function(source, cb)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then cb(false) return end
    local cid = Player.PlayerData.citizenid
    local bail = Bail[cid]
    if bail and bail.pending then cb(false) return end -- a deposit is being charged right now
    if bail and bail.amount then
        -- already has a stand: never charged twice (a lost session is opened again for the same stand)
        Sessions[src] = Sessions[src] or newSession(bail.id)
        SrcToCid[src] = cid
        cb(true)
        return
    end
    local retry = bail and bail.unclear
    if not retry and (tonumber(Player.PlayerData.money.bank) or 0) < Config.StandDeposit then cb(false) return end
    -- locked before the ledger wait: a second callback in the same moment finds it busy. An unclear
    -- charge is asked again under its own key (the ledger returns its final result for it).
    local standId = retry and bail.id or PFPayout.NewId()
    Bail[cid] = { pending = true, id = standId }
    SrcToCid[src] = cid
    local paid, res = PFPayout.Charge(Player, 'bank', Config.StandDeposit, {
        key = ('pfm-hotdogjob:stand:%s'):format(standId), reason = 'hot dog deposit', quiet = true,
    })
    if paid then
        Bail[cid] = { id = standId, amount = Config.StandDeposit }
        Sessions[src] = newSession(standId)
        cb(true)
        return
    end
    res = type(res) == 'table' and res or {}
    local outage = res.error == 'bank_unavailable' or res.error == 'ledger_unavailable'
    if res.unclear or (retry and outage) then
        -- the money may have left: keep the key until the ledger settles it
        Bail[cid] = { unclear = true, id = standId }
        notify(src, 'The bank is still processing your deposit. Try again in a moment: it will not be taken twice.', 'error')
    else
        Bail[cid] = nil
        if outage then notify(src, 'The bank did not respond. Nothing was charged.', 'error') end
    end
    cb(false)
end)

QBCore.Functions.CreateCallback('qb-hotdogjob:server:BringBack', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then cb(false) return end
    local cid = Player.PlayerData.citizenid
    local bail = Bail[cid]
    if not bail or not bail.amount or bail.returning then cb(false) return end
    bail.returning = true -- one refund at a time
    local ok = PFPayout.Pay(Player, 'bank', bail.amount, { key = ('pfm-hotdogjob:stand:%s:refund'):format(bail.id), reason = 'hot dog deposit', kind = 'refund' })
    bail.returning = nil
    if not ok then cb(false) return end
    Bail[cid] = nil
    Sessions[source] = nil
    cb(true)
end)

-- The stand the client spawned at the depot: registered once per shift (again only when the first
-- one no longer exists), by its network id, if it is a hot dog stand at the depot next to the player.
RegisterNetEvent('qb-hotdogjob:server:standPlaced', function(netId)
    local src = source
    local _, session = standSession(src)
    if not session then return end
    netId = intId(netId)
    if not netId then return end
    if standEntity(session) then return end
    local e = NetworkGetEntityFromNetworkId(netId)
    if not exists(e) or not sameModel(e, STAND_MODEL) then return end
    local spawn = Config.Locations['spawn'].coords
    local at = GetEntityCoords(e)
    if #(at - vector3(spawn.x, spawn.y, spawn.z)) > STAND_REGISTER_RANGE then return end
    if #(at - GetEntityCoords(GetPlayerPed(src))) > STAND_REGISTER_RANGE then return end
    session.standNet = netId
end)

-- ── cooking ─────────────────────────────────────────────────────────

QBCore.Functions.CreateCallback('qb-hotdogjob:server:startCook', function(source, cb)
    local src = source
    local _, session = standSession(src)
    if not session then cb(nil, 'no_stand') return end
    if not nearStand(src, session) then cb(nil, 'too_far') return end
    local now = os.time()
    if session.cook and now - session.cook.at < COOK_TTL then cb(nil, 'busy') return end
    if session.cook then pcall(function() exports['pfm-minigames']:Cancel(src, session.cook.id) end) end
    session.cook = nil
    if GetResourceState('pfm-minigames') ~= 'started' then cb(nil, 'grill') return end
    -- every fault is counted (the quality comes from them), so no fault limit fails the cook
    local ok, ch = pcall(function()
        return exports['pfm-minigames']:IssueChallenge(src, 'keys', { amount = COOK_KEYS, maxFaults = COOK_KEYS, tag = 'pfm-hotdogjob:cook' })
    end)
    if not ok or type(ch) ~= 'table' or type(ch.id) ~= 'string' then cb(nil, 'grill') return end
    session.cook = { id = ch.id, at = now }
    cb(ch)
end)

RegisterNetEvent('qb-hotdogjob:server:finishCook', function(id)
    local src = source
    local Player, session = standSession(src)
    if not session or not session.cook or type(id) ~= 'string' or session.cook.id ~= id then return end
    session.cook = nil
    local ok, passed, faults = pcall(function() return exports['pfm-minigames']:Verify(src, id) end)
    if not ok or passed ~= true then
        notify(src, 'The hot dog did not come out right.', 'error')
        return
    end
    if not nearStand(src, session) then notify(src, Lang:t('error.too_far'), 'error') return end
    faults = math.max(0, math.floor(tonumber(faults) or 0))
    local quality = faults == 0 and 'exotic' or (faults == 1 and 'rare' or 'common')
    local def = Config.Stock[quality]
    local rep = repOf(Player)
    local level = levelOf(rep)
    local cap = tonumber(def.Max[level]) or 0
    local have = session.stock[quality] or 0
    if have >= cap then
        notify(src, Lang:t('error.no_more', { value = def.Label }), 'error')
        return
    end
    -- from level 2 a cook sometimes makes several (as before)
    local made = 1
    if level > 1 and math.random(1, 2) == 1 then made = math.random(1, level) end
    made = math.min(made, cap - have)
    session.stock[quality] = have + made
    -- reputation only for a hot dog actually made, capped
    local gain = math.min(REP_GAIN[quality], math.max(0, (Config.MaxReputation or 200) - rep))
    if gain > 0 and Player.AddRep then Player.AddRep('hotdog', gain) end
    if made > 1 then
        notify(src, Lang:t('success.made_luck_hotdog', { value = made, value2 = def.Label }), 'success')
    else
        notify(src, Lang:t('success.made_hotdog', { value = def.Label }), 'success')
    end
    pushStock(src, session)
    -- the player came through the export as a copy from before AddRep: read the reputation again
    local Fresh = exports['pfm-core']:GetPlayer(src) or Player
    TriggerClientEvent('qb-hotdogjob:client:UpdateReputation', src, Fresh.PlayerData.metadata['rep'])
end)

-- ── selling ─────────────────────────────────────────────────────────

local function paySale(src, sale, retry)
    local ok, res = PFPayout.Pay(src, 'cash', sale.amount, { key = sale.key, reason = 'sold hotdog', kind = 'sale', quiet = true })
    if ok then return 'paid' end
    -- on a retry a bank that does not answer says nothing about the key that came back unclear
    if retry and (res.error == 'bank_unavailable' or res.error == 'ledger_unavailable') then return 'pending' end
    if PFPayout.IsClearFailure(res) then return 'failed' end
    return 'pending'
end

local function salePaid(src, session, sale)
    if not session then return end
    session.earned = session.earned + sale.amount
    pushApp(src, session)
end

-- Asks again for the waiting sales of src's character; a failed one goes back into the same
-- stand's stock (if that shift is still out).
local function settleSales(src)
    local cid = SrcToCid[src]
    -- one run per character at a time; the list is taken out first, so a sale added while this run
    -- waits on the bank goes into a fresh list and is merged back at the end
    if not cid or SettlingSales[cid] then return end
    local list = PendingSales[cid]
    if not list then return end
    SettlingSales[cid], PendingSales[cid] = true, nil
    local keep = {}
    local ok, err = pcall(function()
        for i, sale in ipairs(list) do
            local res = paySale(src, sale, true)
            list[i] = nil
            local session = Sessions[src]
            local same = session and session.id == sale.stand and session or nil
            if res == 'paid' then
                salePaid(src, same, sale)
            elseif res == 'failed' then
                if same then
                    same.stock[sale.quality] = (same.stock[sale.quality] or 0) + sale.count
                    same.sold = math.max(0, same.sold - sale.count)
                    pushStock(src, same)
                end
                notify(src, 'A customer\'s payment did not go through.', 'error')
            else
                keep[#keep + 1] = sale
            end
        end
    end)
    for _, sale in pairs(list) do keep[#keep + 1] = sale end -- not reached because of an error: kept
    for _, sale in ipairs(PendingSales[cid] or {}) do keep[#keep + 1] = sale end
    PendingSales[cid] = #keep > 0 and keep or nil
    SettlingSales[cid] = nil
    if not ok then print(('^1[pfm-hotdogjob]^7 settling sales failed: %s'):format(tostring(err))) end
end

local function retrySales(src, cid, left)
    SetTimeout(SALE_RETRY_MS, function()
        if SrcToCid[src] ~= cid or not (PendingSales[cid] or SettlingSales[cid]) then return end
        settleSales(src)
        if (PendingSales[cid] or SettlingSales[cid]) and left > 1 then retrySales(src, cid, left - 1) end
    end)
end

-- What a customer at the stand will buy: the best quality in stock, 1 to MaxSalePerCustomer of it,
-- at a price for the player's level. Kept on the session until the sale or OFFER_TTL.
QBCore.Functions.CreateCallback('qb-hotdogjob:server:offer', function(source, cb, pedNetId)
    local src = source
    local Player, session = standSession(src)
    if not session or not nearStand(src, session) then cb(nil) return end
    settleSales(src)
    local _, netId = customerOf(src, pedNetId)
    if not netId then cb(nil) return end
    local quality
    for _, q in ipairs(QUALITIES) do
        if (session.stock[q] or 0) > 0 then quality = q break end
    end
    if not quality then session.offer = nil cb({ empty = true }) return end
    local amount = math.min(math.random(1, Config.MaxSalePerCustomer or 3), session.stock[quality])
    local band = Config.Stock[quality].Price[levelOf(repOf(Player))]
    local unit = math.random(band.min, band.max)
    session.offer = { netId = netId, quality = quality, amount = amount, unit = unit, at = os.time() }
    cb({ amount = amount, total = applyStreakBonus(session.streak, amount * unit), quality = quality, label = Config.Stock[quality].Label })
end)

RegisterNetEvent('qb-hotdogjob:server:Sell', function(pedNetId)
    local src = source
    local Player, session = standSession(src)
    if not session then return end
    local offer = session.offer
    local now = os.time()
    if not offer or offer.netId ~= intId(pedNetId) or now - offer.at > OFFER_TTL then return end
    if (now - session.lastSale) < (Config.SaleCooldown or 5) then return end
    session.offer = nil
    if not nearStand(src, session) or not customerOf(src, offer.netId) then return end
    if (session.stock[offer.quality] or 0) < offer.amount then return end

    session.stock[offer.quality] = session.stock[offer.quality] - offer.amount
    Served[offer.netId] = now
    local payout = applyStreakBonus(session.streak, offer.amount * offer.unit)
    -- every sale has its own number, used up whatever the bank answers (a spent key never pays)
    session.sales = session.sales + 1
    local cid = Player.PlayerData.citizenid
    local sale = { key = ('pfm-hotdogjob:stand:%s:sale:%d'):format(session.id, session.sales), amount = payout,
        quality = offer.quality, count = offer.amount, stand = session.id }
    local res = paySale(src, sale, false)
    if res == 'failed' then
        session.stock[offer.quality] = session.stock[offer.quality] + offer.amount
        Served[offer.netId] = nil
        pushStock(src, session)
        notify(src, 'The bank did not respond. The customer did not pay.', 'error')
        return
    end
    session.lastSale = now
    session.streak = session.streak + 1
    session.sold = session.sold + offer.amount
    pushStock(src, session)
    if res == 'pending' then
        PendingSales[cid] = PendingSales[cid] or {}
        table.insert(PendingSales[cid], sale)
        retrySales(src, cid, SALE_RETRIES)
        notify(src, 'The customer\'s payment is still being settled.', 'primary')
        return
    end
    salePaid(src, session, sale)
    notify(src, Lang:t('success.sold_hotdogs', { value = offer.amount, value2 = payout }), 'success')
end)

RegisterNetEvent('qb-hotdogjob:server:decline', function()
    local session = Sessions[source]
    if session then session.offer = nil end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local session = Sessions[src]
    if session and session.cook then pcall(function() exports['pfm-minigames']:Cancel(src, session.cook.id) end) end
    Sessions[src] = nil
    local cid = SrcToCid[src]
    if cid then
        -- a deposit the bank is still settling keeps its key for the next login
        local bail = Bail[cid]
        if bail and not bail.unclear and not bail.pending then Bail[cid] = nil end
        SrcToCid[src] = nil
    end
end)

-- Commands

QBCore.Commands.Add('removestand', Lang:t('info.command'), {}, false, function(source, _)
    TriggerClientEvent('qb-hotdogjob:staff:DeletStand', source)
end, 'admin')

-- Hot Dog Stand app (pf-devices, tablet + computer, for the hotdog job): the stand's shift (sales,
-- earnings, streak, stock), reputation and its levels, the deposit and the depot. Selling stays at the stand.
local function standStatus(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local session = Sessions[src]
    local bail = Bail[Player.PlayerData.citizenid]
    local rep = repOf(Player)
    return {
        ok = true,
        standOut = session ~= nil and bail ~= nil and bail.amount ~= nil,
        sold = session and session.sold or 0,
        sales = session and session.sales or 0,
        earned = session and session.earned or 0,
        streak = session and session.streak or 0,
        stock = session and stockCopy(session) or { exotic = 0, rare = 0, common = 0 },
        level = levelOf(rep),
        reputation = rep, maxReputation = Config.MaxReputation,
        deposit = Config.StandDeposit,
    }
end

local function registerApp()
    if GetResourceState('pf-devices') ~= 'started' then return end
    exports['pf-devices']:RegisterApp({
        id = 'hotdogstand', name = 'Hot Dog Stand', icon = '🌭',
        entry = 'html/stand_app.js', category = 'jobs', order = 62,
        access = { jobs = { hotdog = 0 } },
        description = 'Your stand: sales, earnings and reputation',
    })
    exports['pf-devices']:RegisterAppHandlers('hotdogstand', {
        status = function(src) return standStatus(src) end,
        waypoint = function(src)
            local loc = Config.Locations and (Config.Locations['take'] or Config.Locations[1])
            local c = loc and (loc.coords or loc)
            if not c or not c.x then return { ok = false, error = 'no_location' } end
            TriggerClientEvent('qb-hotdogjob:client:waypoint', src, c.x, c.y)
            return { ok = true }
        end,
    })
end
AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() or resource == 'pf-devices' then registerApp() end
end)
AddEventHandler('pf-devices:server:ready', registerApp)
