QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
sharedItems = exports['pfm-core']:GetShared('Items')


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

-- ── deliveries ──────────────────────────────────────────────────────
-- A dealer fronts bricks for a delivery and pays on hand-over at the drop point. The server picks
-- the product (by reputation), the amount and the drop (the client only asks), keeps the run in
-- pfm_drug_deliveries so a restart or a reconnect does not forget it, and pays only for bricks it
-- takes back at the drop after a believable trip. A run that is never finished expires: the bricks
-- still held are taken back, the reputation drops and the missing bricks become a debt to the dealer,
-- paid in cash before the dealer fronts again. Runs have a cooldown and a daily limit, and the pay
-- grows with the police on duty only up to Config.MaxPoliceMultiplier.

PFDrugs = PFDrugs or {}
local D = PFDrugs

local DEALER_RANGE = 5.0
local DROP_RANGE = 6.0
local MAX_TRIP_SPEED = 45.0          -- m/s
local MIN_TRIP_SECONDS = 20
local ON_TIME_SECONDS = 15 * 60      -- the client timer (300 s) starts when the mail is opened

D.Migrations = {
    {
        version = 1,
        name = 'delivery runs, dealer debt and limits per citizen',
        up = {
            [[CREATE TABLE IF NOT EXISTS `pfm_drug_deliveries` (
                `citizenid` VARCHAR(50) NOT NULL,
                `state` VARCHAR(16) NOT NULL DEFAULT 'idle',
                `delivery_id` VARCHAR(64) NULL DEFAULT NULL,
                `dealer` VARCHAR(64) NULL DEFAULT NULL,
                `item_idx` INT NOT NULL DEFAULT 0,
                `amount` INT NOT NULL DEFAULT 0,
                `location` INT NOT NULL DEFAULT 0,
                `started_at` INT NOT NULL DEFAULT 0,
                `earliest` INT NOT NULL DEFAULT 0,
                `handed` INT NOT NULL DEFAULT 0,
                `pay_amount` INT NOT NULL DEFAULT 0,
                `outcome` VARCHAR(16) NULL DEFAULT NULL,
                `debt` INT NOT NULL DEFAULT 0,
                `debt_id` VARCHAR(64) NULL DEFAULT NULL,
                `debt_attempt` INT NOT NULL DEFAULT 0,
                `next_at` INT NOT NULL DEFAULT 0,
                `day` INT NOT NULL DEFAULT 0,
                `day_count` INT NOT NULL DEFAULT 0,
                `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`citizenid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        },
    },
}

local Runs = {}  -- [citizenid] = the citizen's row (loaded once)
local Busy = {}  -- [citizenid] while a request or hand-over runs (taken before the first wait)

local COLUMNS = { 'state', 'delivery_id', 'dealer', 'item_idx', 'amount', 'location', 'started_at', 'earliest',
    'handed', 'pay_amount', 'outcome', 'debt', 'debt_id', 'debt_attempt', 'next_at', 'day', 'day_count' }
local NUMERIC = { item_idx = true, amount = true, location = true, started_at = true, earliest = true, handed = true,
    pay_amount = true, debt = true, debt_attempt = true, next_at = true, day = true, day_count = true }
-- text columns are written as '' when empty (no nil holes in the parameter list)

local function blankRun(cid)
    local r = { citizenid = cid, state = 'idle' }
    for k in pairs(NUMERIC) do r[k] = 0 end
    return r
end

--- The citizen's run row, from the cache or the database; nil when the database could not be read.
local function loadRun(cid)
    if Runs[cid] then return Runs[cid] end
    local ok, row = pcall(MySQL.single.await, 'SELECT * FROM pfm_drug_deliveries WHERE citizenid = ?', { cid })
    if not ok then return nil end
    local r = blankRun(cid)
    if type(row) == 'table' and row.citizenid then
        for _, k in ipairs(COLUMNS) do
            if NUMERIC[k] then
                r[k] = tonumber(row[k]) or 0
            elseif type(row[k]) == 'string' and row[k] ~= '' then
                r[k] = row[k]
            end
        end
        r.state = r.state or 'idle'
    end
    Runs[cid] = r
    return r
end

--- Writes the row; false when the database refused (the caller then does not go on).
local function saveRun(r)
    local cols, marks, updates, params = { 'citizenid' }, { '?' }, {}, { r.citizenid }
    for i, k in ipairs(COLUMNS) do
        cols[i + 1] = ('`%s`'):format(k)
        marks[i + 1] = '?'
        updates[i] = ('`%s` = VALUES(`%s`)'):format(k, k)
        local v = r[k]
        if NUMERIC[k] then v = math.floor(tonumber(v) or 0) else v = v ~= nil and tostring(v) or '' end
        params[i + 1] = v
    end
    local sql = ('INSERT INTO pfm_drug_deliveries (%s) VALUES (%s) ON DUPLICATE KEY UPDATE %s'):format(
        table.concat(cols, ', '), table.concat(marks, ', '), table.concat(updates, ', '))
    return (pcall(MySQL.query.await, sql, params))
end

local function DistanceTo(src, c)
    local p = GetEntityCoords(GetPlayerPed(src))
    return #(vector3(p.x, p.y, p.z) - vector3(c.x, c.y, c.z))
end

local function countItem(src, item)
    local ok, n = pcall(function() return exports['pfm-inventory']:GetItemCount(src, item) end)
    return ok and (tonumber(n) or 0) or 0
end

local function giveItem(src, item, n, reason)
    if n <= 0 then return true end
    return exports['pfm-inventory']:AddItem(src, item, n, false, false, reason or 'qb-drugs:delivery') == true
end

-- Takes n of item from src, from as many slots as it takes (bricks may be spread over slots); all
-- or nothing.
local function takeItem(src, item, n)
    if n <= 0 then return true end
    if exports['pfm-inventory']:RemoveItem(src, item, n, false, 'qb-drugs:delivery') == true then return true end
    local taken = 0
    while taken < n and exports['pfm-inventory']:RemoveItem(src, item, 1, false, 'qb-drugs:delivery') == true do
        taken = taken + 1
    end
    if taken == n then return true end
    giveItem(src, item, taken, 'qb-drugs:delivery-restore')
    return false
end

-- What the dealer asks for a brick not brought back: its price, not the delivery pay (keeping a
-- brick must never pay better than delivering it).
local function brickPrice(itemCfg)
    return math.max(0, math.floor(tonumber(itemCfg and (itemCfg.debt or itemCfg.payout)) or 0))
end

-- Whether a dealer is open at the server's game time (pfm-weathersync). Without a time source the
-- hours are not enforced: they shape play, they do not move money.
function D.DealerOpen(dealer)
    local t = dealer and dealer.time
    local min, max = t and tonumber(t.min), t and tonumber(t.max)
    if not min or not max then return true end
    if GetResourceState('pfm-weathersync') ~= 'started' then return true end
    local ok, hour = pcall(function() return exports['pfm-weathersync']:getTime() end)
    hour = ok and tonumber(hour) or nil
    if not hour then return true end
    if max < min then return hour >= min or hour <= max end
    return hour >= min and hour <= max
end

--- The pay multiplier for the police on duty: 1 + PerCopBonus each, capped at MaxPoliceMultiplier.
function D.CopMultiplier(cops)
    cops = math.max(0, math.floor(tonumber(cops) or 0))
    local per = tonumber(Config.PerCopBonus) or 0.1
    local cap = tonumber(Config.MaxPoliceMultiplier) or 1.5
    return math.max(1.0, math.min(1.0 + cops * per, cap))
end

local function today() return os.time() // 86400 end

local function itemCfgOf(r) return Config.DeliveryItems[tonumber(r.item_idx) or 0] end

local function deliveryInfo(r)
    local itemCfg = itemCfgOf(r)
    local loc = Config.DeliveryLocations[tonumber(r.location) or 0]
    if not itemCfg or not loc then return nil end
    local shared = sharedItems[itemCfg.item]
    return {
        dealer = r.dealer, item = r.item_idx, itemName = itemCfg.item, itemLabel = shared and shared.label or itemCfg.item,
        amount = r.amount, coords = { x = loc.coords.x, y = loc.coords.y, z = loc.coords.z }, locationLabel = loc.label,
    }
end

local function notify(src, msg, kind) TriggerClientEvent('QBCore:Notify', src, msg, kind or 'primary') end

local function changeRep(src, delta)
    local P = exports['pfm-core']:GetPlayer(src)
    if not P or delta == 0 then return end
    if delta > 0 and P.AddRep then P.AddRep('dealer', delta)
    elseif delta < 0 and P.RemoveRep then P.RemoveRep('dealer', -delta) end
end

local function mail(src, kind, r)
    local dealer = r.dealer
    SetTimeout(math.random(5000, 10000), function()
        TriggerClientEvent('qb-drugs:client:sendDeliveryMail', src, kind, { dealer = dealer })
    end)
end

-- A run that was not finished in time: the bricks still held go back to the dealer, the reputation
-- drops and the missing bricks are owed at their delivery value. Persisted before anything is taken.
local function failRun(src, r)
    local itemCfg = itemCfgOf(r)
    local amount = math.max(0, tonumber(r.amount) or 0)
    local back = 0
    if itemCfg then
        back = math.min(countItem(src, itemCfg.item), amount)
        if back > 0 and not takeItem(src, itemCfg.item, back) then back = 0 end
    end
    local missing = amount - back
    local owed = missing * brickPrice(itemCfg)
    r.state, r.delivery_id, r.handed, r.pay_amount, r.outcome = 'idle', nil, 0, 0, nil
    if owed > 0 then
        if (r.debt or 0) <= 0 then r.debt_id, r.debt_attempt = PFPayout.NewId(), 0 end
        r.debt = (r.debt or 0) + owed
    end
    r.next_at = math.max(r.next_at or 0, os.time() + (tonumber(Config.FailedDeliveryCooldown) or 1800))
    if not saveRun(r) and back > 0 and itemCfg then giveItem(src, itemCfg.item, back, 'qb-drugs:delivery-restore') end
    changeRep(src, -(tonumber(Config.DeliveryRepLoss) or 1) * math.max(1, amount))
    notify(src, owed > 0 and ('The dealer wanted that delivery hours ago. You owe them $%d for the missing product.'):format(owed)
        or 'The dealer wanted that delivery hours ago. They took the product back.', 'error')
    return owed
end

-- A hand-over that was paid: the run is closed, the cooldown starts and the reputation moves.
local function finishRun(src, r)
    local outcome, missing = r.outcome, math.max(0, (tonumber(r.amount) or 0) - (tonumber(r.handed) or 0))
    local itemCfg = itemCfgOf(r)
    local owed = missing * brickPrice(itemCfg)
    if owed > 0 then
        if (r.debt or 0) <= 0 then r.debt_id, r.debt_attempt = PFPayout.NewId(), 0 end
        r.debt = (r.debt or 0) + owed
    end
    local finished = { dealer = r.dealer }
    r.state, r.delivery_id, r.handed, r.pay_amount, r.outcome = 'idle', nil, 0, 0, nil
    r.next_at = math.max(r.next_at or 0, os.time() + (tonumber(Config.DeliveryCooldown) or 300))
    saveRun(r)
    if itemCfg then TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[itemCfg.item], 'remove') end
    if outcome == 'perfect' then
        notify(src, Lang:t('success.order_delivered'), 'success')
        changeRep(src, tonumber(Config.DeliveryRepGain) or 1)
    else
        notify(src, outcome == 'late' and Lang:t('error.too_late') or Lang:t('error.order_not_right'), 'error')
        changeRep(src, -(tonumber(Config.DeliveryRepLoss) or 1))
    end
    if owed > 0 then notify(src, ('You owe the dealer $%d for the product you kept.'):format(owed), 'error') end
    mail(src, outcome or 'bad', finished)
end

-- Pays the hand-over of r (state 'paying') under its own key. A clear failure gives the bricks back
-- and reopens the run; an unclear result keeps them taken and the run waiting on the same key. On a
-- retry (the first answer was unclear) a bank that does not answer says nothing about that key: the
-- run keeps waiting. Returns 'paid', 'failed' or 'pending'.
local function payRun(src, r, retry)
    local itemCfg = itemCfgOf(r)
    local amount = math.floor(tonumber(r.pay_amount) or 0)
    if amount > 0 then
        local ok, res
        if Config.UseMarkedBills then
            ok = exports['pfm-inventory']:AddItem(src, 'markedbills', 1, false, { worth = amount }, 'qb-drugs:server:successDelivery') == true
            res = { ok = ok, error = ok and nil or 'inventory_refused' }
            if not ok then res.state = 'failed' end
        else
            ok, res = PFPayout.Pay(src, 'cash', amount, {
                key = ('pfm-drugs:delivery:%s'):format(r.delivery_id), reason = 'qb-drugs:server:successDelivery', kind = 'sale', quiet = true,
            })
        end
        if not ok then
            local silent = retry and type(res) == 'table' and (res.error == 'bank_unavailable' or res.error == 'ledger_unavailable')
            if Config.UseMarkedBills or (not silent and PFPayout.IsClearFailure(res)) then
                -- nothing was paid and nothing will be: the bricks go back, the run stays open
                if itemCfg then giveItem(src, itemCfg.item, tonumber(r.handed) or 0, 'qb-drugs:delivery-refund') end
                r.state, r.handed, r.pay_amount, r.outcome = 'active', 0, 0, nil
                saveRun(r)
                notify(src, 'The dealer could not pay right now. You still have the product.', 'error')
                return 'failed'
            end
            notify(src, 'The dealer\'s money is still on its way. Check back with them shortly.', 'primary')
            return 'pending'
        end
    end
    finishRun(src, r)
    return 'paid'
end

-- Pays the dealer debt in cash. Each attempt has its own numbered key (a refused key stays refused);
-- an unclear one keeps its key until the ledger settles it. Returns true when nothing is owed.
local function payDebt(src, r)
    if (r.debt or 0) <= 0 then return true end
    if not r.debt_id then r.debt_id = PFPayout.NewId() end
    local key = ('pfm-drugs:debt:%s:%d'):format(r.debt_id, r.debt_attempt or 0)
    local paid, res = PFPayout.Charge(src, { 'cash' }, r.debt, { key = key, reason = 'qb-drugs:dealer-debt', kind = 'fee', quiet = true })
    if paid then
        r.debt, r.debt_id, r.debt_attempt = 0, nil, 0
        saveRun(r)
        notify(src, 'You paid off your debt to the dealer.', 'success')
        return true
    end
    if PFPayout.IsClearFailure(res) then
        if res.error ~= 'bank_unavailable' and res.error ~= 'ledger_unavailable' then
            r.debt_attempt = (r.debt_attempt or 0) + 1 -- that key is spent
            saveRun(r)
        end
        return false, ('You owe the dealer $%d in cash. Bring it before they front you anything again.'):format(r.debt)
    end
    return false, 'Your payment to the dealer is still being settled. Try again shortly.'
end

-- Settles what is left of the last run before a new one or a hand-over: a payment still waiting is
-- asked again under its key; a run past its deadline fails. Returns nil when there is nothing left
-- in the way, or an error code.
local function settleOpen(src, r)
    if r.state == 'paying' then
        local res = payRun(src, r, true)
        if res == 'pending' then return 'settling' end
        if res == 'paid' then return 'just_paid' end
    end
    if r.state == 'active' then
        local expire = (tonumber(Config.DeliveryExpireMinutes) or 120) * 60
        if os.time() >= (r.started_at or 0) + expire then
            failRun(src, r)
            return 'expired'
        end
    end
    return nil
end

local MESSAGES = {
    unavailable = 'The dealer is not taking orders right now.',
    closed = 'Nobody answers the door.',
    too_far = 'You are not at the dealer.',
    pending_delivery = Lang:t('error.pending_delivery'),
    settling = 'The dealer\'s money for your last delivery is still on its way.',
    cooldown = 'The dealer has nothing for you yet. Come back later.',
    daily_limit = 'The dealer has given you enough work for today.',
    no_location = Lang:t('error.delivery_fail'),
    inventory_full = 'You cannot carry the product.',
    busy = 'One moment.',
}

local function withRunLock(cid, fn)
    if Busy[cid] then return { ok = false, error = 'busy' } end
    Busy[cid] = true
    local ok, res = pcall(fn)
    Busy[cid] = nil
    if not ok then
        print('^1[pfm-drugs]^7 delivery failed: ' .. tostring(res))
        return { ok = false, error = 'unavailable' }
    end
    return res
end

local function refuse(src, code, extra)
    notify(src, extra or MESSAGES[code] or code, 'error')
    return { ok = false, error = code, message = extra or MESSAGES[code] or code }
end

--- A delivery asked for at a dealer. Returns { ok, delivery } or { ok = false, error }.
function D.RequestDelivery(src, dealerName)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(dealerName) ~= 'string' or #dealerName > 64 then return { ok = false, error = 'bad_request' } end
    local dealer = Config.Dealers[dealerName]
    if not dealer then return { ok = false, error = 'bad_request' } end
    if not D.ready then return refuse(src, 'unavailable') end
    local cid = Player.PlayerData.citizenid
    return withRunLock(cid, function()
        if DistanceTo(src, dealer.coords) > DEALER_RANGE then return refuse(src, 'too_far') end
        if not D.DealerOpen(dealer) then return refuse(src, 'closed') end
        local r = loadRun(cid)
        if not r then return refuse(src, 'unavailable') end
        local open = settleOpen(src, r)
        if open == 'settling' then return refuse(src, 'settling') end
        if open == 'expired' then return { ok = false, error = 'expired' } end -- failRun told the player
        if r.state == 'active' then
            -- the run is still on: its drop is sent again (a reconnect or a restart lost the mail)
            local info = deliveryInfo(r)
            notify(src, MESSAGES.pending_delivery, 'error')
            return { ok = false, error = 'pending_delivery', delivery = info }
        end
        local paid, why = payDebt(src, r)
        if not paid then return refuse(src, 'debt', why) end
        local now = os.time()
        if now < (r.next_at or 0) then return refuse(src, 'cooldown') end
        if r.day ~= today() then r.day, r.day_count = today(), 0 end
        if r.day_count >= (tonumber(Config.MaxDeliveriesPerDay) or 10) then return refuse(src, 'daily_limit') end

        -- the product by reputation, the amount and the drop are the server's
        local rep = (Player.GetRep and Player.GetRep('dealer')) or 0
        local items = {}
        for idx, cfg in pairs(Config.DeliveryItems) do
            if (tonumber(cfg.minrep) or 0) <= rep then items[#items + 1] = idx end
        end
        table.sort(items)
        if #items == 0 then return refuse(src, 'unavailable') end
        local locations = {}
        for idx, loc in ipairs(Config.DeliveryLocations) do
            if not Config.NearbyDeliveries or #(vector3(loc.coords.x, loc.coords.y, loc.coords.z)
                - vector3(dealer.coords.x, dealer.coords.y, dealer.coords.z)) <= (tonumber(Config.DeliveryWithin) or 2000) then
                locations[#locations + 1] = idx
            end
        end
        if #locations == 0 then return refuse(src, 'no_location') end
        local itemIdx = items[math.random(1, #items)]
        local locIdx = locations[math.random(1, #locations)]
        local amount = math.random(1, math.max(1, math.floor(tonumber(Config.MaxDeliveryAmount) or 3)))
        local trip = DistanceTo(src, Config.DeliveryLocations[locIdx].coords)

        local before = { state = r.state, day_count = r.day_count }
        r.state, r.delivery_id, r.dealer, r.item_idx, r.amount, r.location = 'active', PFPayout.NewId(), dealerName, itemIdx, amount, locIdx
        r.started_at, r.earliest = now, now + math.max(MIN_TRIP_SECONDS, math.ceil(trip / MAX_TRIP_SPEED))
        r.handed, r.pay_amount, r.outcome = 0, 0, nil
        r.day_count = r.day_count + 1
        -- recorded before the bricks are handed out, so a crash cannot give them without a run
        if not saveRun(r) then
            r.state, r.delivery_id, r.day_count = before.state, nil, before.day_count
            return refuse(src, 'unavailable')
        end
        local item = Config.DeliveryItems[itemIdx].item
        if not giveItem(src, item, amount, 'qb-drugs:server:giveDeliveryItems') then
            r.state, r.delivery_id, r.day_count = 'idle', nil, before.day_count
            saveRun(r)
            return refuse(src, 'inventory_full')
        end
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'add')
        return { ok = true, delivery = deliveryInfo(r) }
    end)
end

--- The hand-over at the drop point. Returns { ok, outcome } or { ok = false, error }.
function D.HandOver(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return { ok = false, error = 'bad_request' } end
    if not D.ready then return refuse(src, 'unavailable') end
    local cid = Player.PlayerData.citizenid
    return withRunLock(cid, function()
        local r = loadRun(cid)
        if not r then return refuse(src, 'unavailable') end
        local open = settleOpen(src, r)
        if open == 'settling' then return refuse(src, 'settling') end
        if open == 'just_paid' then return { ok = true, outcome = 'paid' } end
        if r.state ~= 'active' then return { ok = false, error = open or 'no_delivery' } end
        local itemCfg, loc = itemCfgOf(r), Config.DeliveryLocations[tonumber(r.location) or 0]
        if not itemCfg or not loc then return { ok = false, error = 'no_delivery' } end
        -- handed over at the agreed drop point, not sooner than the trip takes
        if DistanceTo(src, loc.coords) > DROP_RANGE then return { ok = false, error = 'not_at_drop' } end
        if os.time() < (r.earliest or 0) then return { ok = false, error = 'too_soon' } end

        local held = math.min(countItem(src, itemCfg.item), r.amount)
        if held <= 0 then
            -- nothing to hand over: the run stays open (it expires into a debt if never finished)
            return refuse(src, 'nothing', Lang:t('error.order_not_right'))
        end
        local onTime = os.time() <= (r.started_at or 0) + ON_TIME_SECONDS
        local base = (tonumber(itemCfg.payout) or 0) * held
        local pay, outcome
        if held >= r.amount and onTime then
            pay, outcome = base * D.CopMultiplier(QBCore.Functions.GetDutyCount('police')), 'perfect'
        elseif onTime then
            pay, outcome = base / (tonumber(Config.WrongAmountFee) or 2), 'bad'
        else
            pay, outcome = base / (tonumber(Config.OverdueDeliveryFee) or 4), 'late'
        end
        if not takeItem(src, itemCfg.item, held) then return refuse(src, 'nothing', Lang:t('error.order_not_right')) end
        r.state, r.handed, r.pay_amount, r.outcome = 'paying', held, math.floor(pay), outcome
        -- recorded before paying, so a crash in between cannot lose the bricks or pay twice
        if not saveRun(r) then
            giveItem(src, itemCfg.item, held, 'qb-drugs:delivery-restore')
            r.state, r.handed, r.pay_amount, r.outcome = 'active', 0, 0, nil
            return refuse(src, 'unavailable')
        end
        local res = payRun(src, r)
        return { ok = res ~= 'failed', outcome = res == 'paid' and outcome or res }
    end)
end

-- The client asks; the server picks everything (the old giveDeliveryItems took the item, amount,
-- dealer and drop from the client and fronted fresh bricks every two hours).
QBCore.Functions.CreateCallback('qb-drugs:server:requestDelivery', function(source, cb, dealerName)
    local src = source
    if onCooldown(src, 'requestDelivery', 3000) then cb({ ok = false, error = 'busy' }) return end
    cb(D.RequestDelivery(src, dealerName))
end)

RegisterNetEvent('qb-drugs:server:successDelivery', function()
    local src = source
    if onCooldown(src, 'successDelivery', 5000) then return end
    D.HandOver(src)
end)

-- Starts the table, then marks the deliveries ready (requests are refused until then).
local function startDeliveries()
    local ok, res, err = pcall(function() return exports['pfm-core']:RunMigrations(GetCurrentResourceName(), D.Migrations) end)
    if ok and res then
        D.ready = true
    else
        print(('^1[pfm-drugs]^7 delivery table not ready: %s'):format(tostring(ok and err or res)))
    end
    return D.ready == true
end
D.Start = startDeliveries
CreateThread(function() startDeliveries() end)

AddEventHandler('pfm-core:server:characterDeleted', function(citizenid)
    if type(citizenid) ~= 'string' then return end
    Runs[citizenid], Busy[citizenid] = nil, nil
    pcall(MySQL.query.await, 'DELETE FROM pfm_drug_deliveries WHERE citizenid = ?', { citizenid })
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    local P = exports['pfm-core']:GetPlayer(tonumber(src) or -1)
    if P then Runs[P.PlayerData.citizenid] = nil end
end)

--- For tests: forget the cached rows (the database stays).
function D.__reset() Runs, Busy = {}, {} end

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
