-- Crafting app (pf-devices, tablet + computer, installed from the App Store): every recipe of every
-- bench with what it needs, what the player carries, the crafting level it needs and how many the
-- player could make now, and where the player's own bench stands. Read-only: crafting still
-- happens at the bench (server.lua checks the bench, the materials and the XP again).

local QBCore = exports['pfm-core']:GetCoreObject()
local APP = 'crafting'

local function items() return (QBCore.Shared and QBCore.Shared.Items) or {} end
local function label(name) local d = items()[name] return d and d.label or name end

local function counts(Player)
    local out = {}
    for _, it in pairs(Player.PlayerData.items or {}) do
        if type(it) == 'table' and it.name then out[it.name] = (out[it.name] or 0) + (tonumber(it.amount) or 0) end
    end
    return out
end

-- crafting XP is kept under metadata.rep (server.lua uses Player.GetRep)
local function repOf(Player, xpType)
    if type(Player.GetRep) == 'function' then return tonumber(Player.GetRep(xpType)) or 0 end
    local rep = Player.PlayerData.metadata and Player.PlayerData.metadata.rep
    return tonumber(type(rep) == 'table' and rep[xpType]) or 0
end

local function benchTypes()
    local list = {}
    for key, v in pairs(Config) do
        if type(v) == 'table' and type(v.recipes) == 'table' then list[#list + 1] = key end
    end
    table.sort(list, function(a, b)
        if a == 'item_bench' then return true elseif b == 'item_bench' then return false end
        return a < b
    end)
    return list
end

function CraftingView(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local have = counts(Player)
    local placed = CraftingState.benchOf(src)
    local maxAmount = CraftingState.maxAmount or 50
    local benches = {}
    for _, benchType in ipairs(benchTypes()) do
        local bench = Config[benchType]
        local xpType = bench.xpType or 'craftingrep'
        local xp = repOf(Player, xpType)
        local recipes = {}
        for _, r in ipairs(bench.recipes) do
            local reqs, canMake = {}, maxAmount
            for _, req in ipairs(r.requiredItems or {}) do
                local n = have[req.item] or 0
                reqs[#reqs + 1] = { item = req.item, label = label(req.item), amount = req.amount, have = n }
                canMake = math.min(canMake, math.floor(n / math.max(1, req.amount)))
            end
            local unlocked = xp >= (r.xpRequired or 0)
            recipes[#recipes + 1] = {
                item = r.item, label = label(r.item), xpRequired = r.xpRequired or 0, xpGain = r.xpGain or 0,
                unlocked = unlocked, canMake = unlocked and canMake or 0, requirements = reqs,
            }
        end
        local here = placed and placed.type == benchType and placed.coords or nil
        benches[#benches + 1] = {
            type = benchType, label = label(benchType), xpType = xpType, xp = xp, owned = have[benchType] or 0,
            placed = here and { x = here.x, y = here.y, z = here.z } or nil, recipes = recipes,
        }
    end
    return { ok = true, benches = benches, maxAmount = maxAmount }
end

local function register()
    if GetResourceState('pf-devices') ~= 'started' then return end
    exports['pf-devices']:RegisterApp({
        id = APP, name = 'Crafting', icon = '🛠️', devices = { 'tablet', 'computer' },
        entry = 'html/crafting.js', styles = { 'html/crafting.css' },
        category = 'apps', order = 71,
        access = { installable = true },
        store = { description = 'Every crafting recipe, what it needs, what you carry and how many you can make, and where your bench stands.', publisher = 'PF Workshop' },
        window = { width = 900, height = 640 },
        description = 'Recipes, materials and your bench',
    })
    exports['pf-devices']:RegisterAppHandlers(APP, {
        getInit = function(src) return CraftingView(src) end,
    })
end

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() or resource == 'pf-devices' then register() end
end)
AddEventHandler('pf-devices:server:ready', register)
