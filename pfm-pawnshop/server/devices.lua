-- Pawn Shop app (pf-devices, tablet + computer, installed from the App Store): what the pawn shop
-- pays today, where it is and when it is open, and the player's melting job. Read-only: the prices
-- and the melt come from server/main.lua (PawnshopState); selling and melting stay at the counter.

local QBCore = exports['pfm-core']:GetCoreObject()
local APP = 'pawnshop'

local function items() return (QBCore.Shared and QBCore.Shared.Items) or {} end
local function label(name) local d = items()[name] return d and d.label or name end

local function counts(Player)
    local out = {}
    for _, it in pairs(Player.PlayerData.items or {}) do
        if type(it) == 'table' and it.name then out[it.name] = (out[it.name] or 0) + (tonumber(it.amount) or 0) end
    end
    return out
end

local function rewardsOf(meltCfg, amount)
    local out = {}
    for _, r in ipairs(meltCfg and meltCfg.rewards or {}) do
        out[#out + 1] = { item = r.item, label = label(r.item), amount = r.amount * (amount or 1) }
    end
    return out
end

-- an unclaimed melt can be replaced 2 hours after it was ready (server/main.lua meltItemRemove)
local FORFEIT_SECONDS = 7200

function PawnshopView(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local have = counts(Player)
    local prices = {}
    for _, v in pairs(Config.PawnItems or {}) do
        local price = PawnshopState.price(v.item)
        if price then prices[#prices + 1] = { item = v.item, label = label(v.item), price = price, have = have[v.item] or 0 } end
    end
    table.sort(prices, function(a, b) return a.price > b.price end)

    local meltable = {}
    for _, m in pairs(Config.MeltingItems or {}) do
        meltable[#meltable + 1] = { item = m.item, label = label(m.item), minutesEach = m.meltTime, rewards = rewardsOf(m, 1), have = have[m.item] or 0 }
    end
    table.sort(meltable, function(a, b) return a.label < b.label end)

    local melting = nil
    local melt = PawnshopState.meltOf(Player.PlayerData.citizenid)
    if melt then
        local now = os.time()
        melting = {
            item = melt.item, label = label(melt.item), amount = melt.amount, readyAt = melt.readyAt,
            readyIn = math.max(0, melt.readyAt - now), ready = now >= melt.readyAt,
            forfeitIn = math.max(0, melt.readyAt + FORFEIT_SECONDS - now),
            rewards = rewardsOf(PawnshopState.meltConfig(melt.item), melt.amount),
        }
    end

    local locations = {}
    for i, loc in pairs(Config.PawnLocation or {}) do
        locations[#locations + 1] = { id = i, label = ('Pawn Shop %d'):format(i), x = loc.coords.x, y = loc.coords.y }
    end
    table.sort(locations, function(a, b) return a.id < b.id end)
    if #locations == 1 then locations[1].label = 'Pawn Shop' end

    local hour, minute = PawnshopState.gameTime()
    return {
        ok = true,
        prices = prices, fluctuating = Config.FluctuatingPrices == true, paysTo = Config.BankMoney and 'bank' or 'cash',
        meltable = meltable, melting = melting,
        locations = locations,
        hours = {
            limited = Config.UseTimes == true, open = Config.TimeOpen, close = Config.TimeClosed,
            hour = hour, minute = minute, openNow = PawnshopState.isOpen(),
        },
    }
end

local function register()
    if GetResourceState('pf-devices') ~= 'started' then return end
    exports['pf-devices']:RegisterApp({
        id = APP, name = 'Pawn Shop', icon = '💍', devices = { 'tablet', 'computer' },
        entry = 'html/pawnshop.js', styles = { 'html/pawnshop.css' },
        category = 'apps', order = 70,
        access = { installable = true },
        store = { description = 'What the pawn shop pays today, its opening hours and location, and how your melting job is coming along.', publisher = 'Vinewood Pawn' },
        window = { width = 820, height = 600 },
        description = 'Pawn prices, hours and melting',
    })
    exports['pf-devices']:RegisterAppHandlers(APP, {
        getInit = function(src) return PawnshopView(src) end,
    })
end

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() or resource == 'pf-devices' then register() end
end)
AddEventHandler('pf-devices:server:ready', register)
