-- Prison kitchen stock (batch 20C; architecture 2 PR, integration matrix "Inmate meals").
--
-- The kitchen cooks from the pantry: each finished kitchen shift (server/work.lua) turns units of
-- bulk food stock (prison_food_stock) from the pantry stash into meal portions in the canteen, at
-- PortionsPerUnit portions a unit. The corrections department buys that stock through pf-government
-- procurement (the pf-stores buyer kind 'facility', buyer corrections:bolingbroke_kitchen, paid from
-- society:corrections): a trucker brings the pallet to the prison, on-duty staff unpack it into the
-- pantry (/supplyroom at the pantry opens it). With an empty pantry a shift cooks nothing; inmates
-- still eat at meal times, because the routine (19D schedule.lua) serves its own fallback meal when
-- the canteen is empty (low population keeps working).
--
-- The stock is taken from the pantry before the meals are put in the canteen, and given back when
-- the canteen does not take them, so nothing is created or lost. Everything happens on the server.
--
-- prison_food_stock is in pfm-core's shared items; it is still registered at start through pfm-core
-- AddItems when missing (an older pfm-core).
--
-- The commissary sells from stock the same way (batch 22): its goods sit in the commissary stash
-- (pf-government procurement buyer corrections:bolingbroke_commissary delivers into it). A purchase
-- takes the goods out of the stash before any money moves (server/economy.lua buyLocked: sold out
-- refuses there), and a purchase the ledger clearly refused puts them back (E.ReturnStock).

PFPrison = PFPrison or {}
PFPrison.Supplies = PFPrison.Supplies or {}
local S = PFPrison.Supplies

-- Config.Supplies overrides any of these. The pantry id and size must match pf-government's buyer
-- corrections:bolingbroke_kitchen (Config.Procurement.Buyers), which delivers into it.
S.DEFAULTS = {
    Kitchen = {
        Enabled = true,
        RequireStock = true,       -- false: the 19E kitchen (meals without stock)
        Pantry = { id = 'pfm_prison_pantry', label = 'Prison pantry', slots = 20, maxweight = 600000 },
        StockItem = 'prison_food_stock',
        PortionsPerUnit = 4,
    },
    Commissary = {
        Enabled = true,
        RequireStock = true,       -- false: the 19E commissary (goods without stock)
        Stash = { id = 'pfm_prison_commissary', label = 'Prison commissary stock', slots = 30, maxweight = 300000 },
    },
    StockItemDef = {
        name = 'prison_food_stock', label = 'Bulk Food Stock', weight = 2000, type = 'item', image = 'sandwich.png',
        unique = false, useable = false, shouldClose = false, description = 'Catering-size food stock for the prison kitchen',
    },
}

local function kitchenCfg()
    local over = (Config.Supplies or {}).Kitchen
    if type(over) ~= 'table' then return S.DEFAULTS.Kitchen end
    local out = {}
    for k, v in pairs(S.DEFAULTS.Kitchen) do out[k] = v end
    for k, v in pairs(over) do out[k] = v end
    return out
end
S.KitchenCfg = kitchenCfg

local function commissaryCfg()
    local over = (Config.Supplies or {}).Commissary
    if type(over) ~= 'table' then return S.DEFAULTS.Commissary end
    local out = {}
    for k, v in pairs(S.DEFAULTS.Commissary) do out[k] = v end
    for k, v in pairs(over) do out[k] = v end
    return out
end
S.CommissaryCfg = commissaryCfg

local function inv(name, ...)
    local args, n = { ... }, select('#', ...)
    local ok, res = pcall(function()
        local e = exports['pfm-inventory']
        return e[name](e, table.unpack(args, 1, n))
    end)
    if not ok then return nil end
    return res
end

local function ensureStash(s)
    if not inv('GetInventory', s.id) then inv('CreateInventory', s.id, { label = s.label, maxweight = s.maxweight, slots = s.slots }) end
    return inv('GetInventory', s.id) ~= nil
end

local function count(stashId, item)
    local stash = inv('GetInventory', stashId)
    local n = 0
    for _, it in pairs(stash and stash.items or {}) do
        if type(it) == 'table' and it.name == item then n = n + (tonumber(it.amount) or 0) end
    end
    return n
end
S.Count = count

--- Registers the stock item with pfm-core when the server does not know it yet.
function S.EnsureItem()
    local def = S.DEFAULTS.StockItemDef
    local ok, core = pcall(function() return exports['pfm-core']:GetCoreObject({ 'Shared' }) end)
    local items = ok and type(core) == 'table' and core.Shared and core.Shared.Items or nil
    if items and items[def.name] then return true end
    local okAdd, added = pcall(function() return exports['pfm-core']:AddItems({ [def.name] = def }) end)
    if not okAdd or added ~= true then
        print('^3[pfm-prison]^7 could not register ' .. def.name .. ': the kitchen pantry cannot be stocked')
        return false
    end
    return true
end

--- A kitchen shift's cooking: up to `n` portions, limited by the canteen's room (Kitchen.MaxStock of
--- config_work.lua) and by the pantry stock. `put(meals)` is the 19E canteen add; returns portions made.
function S.Cook(n, put)
    local k = kitchenCfg()
    if not k.Enabled or not k.RequireStock then return put(n) end
    local K = (Config.Work or {}).Kitchen or {}
    n = math.floor(tonumber(n) or 0)
    local room = math.max(0, (tonumber(K.MaxStock) or 60) - (K.Stash and count(K.Stash, K.MealItem) or 0))
    local want = math.min(n, room)
    if want < 1 then return 0 end
    if not ensureStash(k.Pantry) then return 0 end
    local per = math.max(1, math.floor(tonumber(k.PortionsPerUnit) or 4))
    local units = math.min(count(k.Pantry.id, k.StockItem), math.ceil(want / per))
    if units < 1 then return 0 end
    local meals = math.min(want, units * per)
    -- the stock leaves the pantry first; it goes back when the canteen does not take the meals
    if inv('RemoveItem', k.Pantry.id, k.StockItem, units, false, 'pfm-prison:kitchen-stock') ~= true then return 0 end
    local made = math.floor(tonumber(put(meals)) or 0)
    if made < 1 then
        inv('AddItem', k.Pantry.id, k.StockItem, units, false, false, 'pfm-prison:kitchen-stock-undo')
        return 0
    end
    local used = math.ceil(made / per)
    if used < units then inv('AddItem', k.Pantry.id, k.StockItem, units - used, false, false, 'pfm-prison:kitchen-stock-rest') end
    return made
end

-- ── commissary stock ─────────────────────────────────────────────────────────────────────────

--- Whether commissary sales draw from the stash.
function S.CommissaryStocked()
    local c = commissaryCfg()
    return c.Enabled ~= false and c.RequireStock ~= false
end

--- Units of an item in the commissary stash (0 when the stash cannot be read).
function S.CommissaryStock(item)
    local c = commissaryCfg()
    if not ensureStash(c.Stash) then return 0 end
    return count(c.Stash.id, item)
end

--- Takes qty of an item out of the commissary stash. True only when all of it left the stash.
--- The count and the removal follow each other with no wait between them.
function S.TakeCommissary(item, qty)
    local c = commissaryCfg()
    qty = math.floor(tonumber(qty) or 0)
    if type(item) ~= 'string' or qty < 1 or not ensureStash(c.Stash) then return false end
    if count(c.Stash.id, item) < qty then return false end
    return inv('RemoveItem', c.Stash.id, item, qty, false, 'pfm-prison:commissary-sale') == true
end

--- Puts qty of an item back into the commissary stash (a sale that did not go through).
function S.ReturnCommissary(item, qty)
    local c = commissaryCfg()
    qty = math.floor(tonumber(qty) or 0)
    if type(item) ~= 'string' or qty < 1 or not ensureStash(c.Stash) then return false end
    return inv('AddItem', c.Stash.id, item, qty, false, false, 'pfm-prison:commissary-return') == true
end

--- Puts the cooking step in front of the 19E kitchen output (W.AddMeals), once.
function S.Install()
    local W = PFPrison.Work
    if not W or not W.AddMeals then return false end
    if S.installed and W.AddMeals == S.wrapped then return true end
    local put = W.AddMeals
    S.wrapped = function(n) return S.Cook(n, put) end
    W.AddMeals = S.wrapped
    S.installed = true
    return true
end

S.Install()

CreateThread(function()
    Wait(1000)
    S.EnsureItem()
    ensureStash(kitchenCfg().Pantry)
    if S.CommissaryStocked() then ensureStash(commissaryCfg().Stash) end
end)
