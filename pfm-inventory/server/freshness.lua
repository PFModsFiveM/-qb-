-- Server-authoritative food freshness for pfm-inventory.
--
-- Perishable items carry info.fresh = {
--     v = 1, batch = 'B<time>-<n>-<rand>', cat = <category>, life = <seconds>,
--     used = <seconds of shelf life already consumed>, at = <unix time used was last settled>,
--     storage = <storage type the item has been in since `at`>
-- }
-- Shelf life accrues lazily: current used = used + (now - at) * rate(storage). Nothing is
-- written while an item sits still; the value is settled whenever the item changes storage.

PFFreshness = PFFreshness or {}
local F = PFFreshness

F.StorageOverrides = F.StorageOverrides or {}
local batchCounter = 0

local function cfg()
    return Config and Config.Freshness
end

function F.now()
    return os.time()
end

function F.Enabled()
    local c = cfg()
    return c ~= nil and c.Enabled ~= false
end

local function deepCopy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do
        out[deepCopy(k, seen)] = deepCopy(v, seen)
    end
    return out
end
F.CopyInfo = deepCopy

-- Items other resources register at runtime (RegisterPerishables), e.g. pf-restaurants' ingredients.
-- The config file's Items win when both name an item.
F.ExtraItems = F.ExtraItems or {}

--- Registers item -> freshness category pairs. Unknown categories are ignored. Returns how many.
function F.RegisterItems(map)
    local c = cfg()
    if type(map) ~= 'table' or not c or not c.Categories then return 0 end
    local n = 0
    for item, category in pairs(map) do
        if type(item) == 'string' and c.Categories[category] then
            F.ExtraItems[item:lower()] = category
            n = n + 1
        end
    end
    return n
end

function F.CategoryOf(itemName)
    if not F.Enabled() or type(itemName) ~= 'string' then return nil end
    local c = cfg()
    local category = (c.Items and c.Items[itemName:lower()]) or F.ExtraItems[itemName:lower()]
    if category and c.Categories and c.Categories[category] then return category end
    return nil
end

function F.IsPerishable(itemName)
    return F.CategoryOf(itemName) ~= nil
end

function F.ShelfLife(itemName)
    local category = F.CategoryOf(itemName)
    if not category then return nil end
    local life = tonumber(cfg().Categories[category].shelfLife)
    if not life or life <= 0 then return nil end
    return life
end

local function knownStorage(storage)
    return type(storage) == 'string' and cfg().Storage[storage] ~= nil
end

function F.Rate(storage)
    local c = cfg()
    local rate = c and c.Storage and tonumber(c.Storage[storage or 'normal'])
    if not rate or rate < 0 then return 1.0 end
    return rate
end

--- Runtime storage condition for an inventory (business fridges, failed equipment...).
--- Pass nil to clear the override. Returns false for unknown storage types.
function F.SetStorageOverride(identifier, storage)
    if identifier == nil then return false end
    if storage ~= nil and not knownStorage(storage) then return false end
    F.StorageOverrides[tostring(identifier)] = storage
    return true
end

function F.StorageFor(identifier)
    if type(identifier) == 'number' then return 'person' end
    identifier = tostring(identifier or '')
    local override = F.StorageOverrides[identifier]
    if override then return override end
    for _, rule in ipairs(cfg().StorageRules or {}) do
        if identifier:find(rule[1]) then return rule[2] end
    end
    return cfg().DefaultStashStorage or 'normal'
end

function F.NewBatchId(now)
    batchCounter = batchCounter + 1
    return ('B%d-%d-%04d'):format(math.floor(now or F.now()), batchCounter, math.random(0, 9999))
end

--- Shelf-life seconds consumed as of `now`, without mutating the record.
function F.CurrentUsed(fresh, now)
    now = now or F.now()
    local at = tonumber(fresh.at) or now
    local elapsed = now - at
    if elapsed < 0 then elapsed = 0 end
    local used = (tonumber(fresh.used) or 0) + elapsed * F.Rate(fresh.storage)
    local life = tonumber(fresh.life) or 0
    if used > life then used = life end
    if used < 0 then used = 0 end
    return used
end

function F.Percent(fresh, now)
    if type(fresh) ~= 'table' then return 100 end
    local life = tonumber(fresh.life)
    if not life or life <= 0 then return 100 end
    local pct = 100 * (1 - F.CurrentUsed(fresh, now) / life)
    if pct < 0 then pct = 0 end
    return pct
end

function F.StateFor(pct)
    local states = cfg().States
    for _, s in ipairs(states) do
        if pct >= s.min then return s end
    end
    return states[#states]
end

function F.EffectsFor(pct)
    local state = F.StateFor(pct)
    local effects = cfg().Effects and cfg().Effects[state.state]
    return {
        state = state.state,
        label = state.label,
        pct = pct,
        benefit = (effects and tonumber(effects.benefit)) or 1.0,
        illness = (effects and tonumber(effects.illness)) or 0,
    }
end

--- Normalises an item's freshness for insertion into `storage`: settles shelf life used in the
--- storage it came from, then switches it to the new storage. Shelf life is always recomputed
--- from config, so stored or supplied durations can never extend it. Items without a valid
--- record (new or legacy) get a fresh server-assigned batch.
--- Mutates and returns `info`; callers pass a private copy.
function F.Prepare(itemName, info, storage, now)
    now = now or F.now()
    local life = F.ShelfLife(itemName)
    if not life then return info end
    info = info or {}
    if not knownStorage(storage) then storage = 'normal' end

    local f = info.fresh
    if type(f) ~= 'table' or type(f.batch) ~= 'string' or f.batch == '' then
        info.fresh = {
            v = 1,
            batch = F.NewBatchId(now),
            cat = F.CategoryOf(itemName),
            life = life,
            used = 0,
            at = now,
            storage = storage,
        }
        return info
    end

    local used = tonumber(f.used) or 0
    if used < 0 then used = 0 end
    if used > life then used = life end
    local at = tonumber(f.at) or now
    if at > now then at = now end

    local record = {
        v = 1,
        batch = f.batch:sub(1, 48),
        cat = F.CategoryOf(itemName),
        life = life,
        used = used,
        at = at,
        storage = knownStorage(f.storage) and f.storage or storage,
    }
    record.used = F.CurrentUsed(record, now)
    record.at = now
    record.storage = storage
    info.fresh = record
    return info
end

--- Freshness for goods unpacked from a delivery. Goods age at the grace storage rate (normal) for
--- the first DeliveryGraceSeconds after delivery (30 minutes), then at the faster DeliveryStorage
--- rate (outdoor) for as long as the delivery stayed packed. Returns an info table, or nil for
--- non-perishables.
function F.DeliveredInfo(itemName, deliveredAt, now)
    local life = F.ShelfLife(itemName)
    if not life then return nil end
    local c = cfg() or {}
    now = now or F.now()
    local elapsed = math.max(0, now - (tonumber(deliveredAt) or now))
    local grace = tonumber(c.DeliveryGraceSeconds) or 1800
    local used = math.min(elapsed, grace) * F.Rate(c.DeliveryGraceStorage or 'normal')
        + math.max(0, elapsed - grace) * F.Rate(c.DeliveryStorage or 'outdoor')
    return {
        fresh = {
            v = 1, batch = F.NewBatchId(now), cat = F.CategoryOf(itemName), life = life,
            used = math.min(life, math.floor(used)), at = now, storage = 'normal',
        },
    }
end

--- Whether an incoming item may merge into an existing stack. Non-perishables keep the
--- framework's original behaviour (same name stacks); perishables need the same batch and
--- matching freshness so no item loses its individual state.
function F.CanStack(itemName, incomingInfo, existingInfo, now)
    if not F.IsPerishable(itemName) then return true end
    local a = type(incomingInfo) == 'table' and incomingInfo.fresh
    local b = type(existingInfo) == 'table' and existingInfo.fresh
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    if a.batch ~= b.batch then return false end
    local tolerance = tonumber(cfg().StackTolerancePct) or 1.0
    return math.abs(F.Percent(a, now) - F.Percent(b, now)) <= tolerance
end

--- Merges an incoming record into an existing stack's record. The stack keeps the worse
--- freshness, so stacking can never make food fresher.
function F.MergeInto(existing, incoming, now)
    now = now or F.now()
    local worst = math.max(F.CurrentUsed(existing, now), F.CurrentUsed(incoming, now))
    existing.used = worst
    existing.at = now
end

--- Assigns freshness to perishables that predate the system (one batch per slot) and
--- re-anchors records to the inventory's storage. Returns true when anything changed.
function F.EnsureItems(items, identifier, now)
    if type(items) ~= 'table' or not F.Enabled() then return false end
    now = now or F.now()
    local storage = F.StorageFor(identifier)
    local changed = false
    for _, item in pairs(items) do
        if type(item) == 'table' and F.IsPerishable(item.name) then
            local f = type(item.info) == 'table' and item.info.fresh
            if type(f) ~= 'table' or f.storage ~= storage or type(f.batch) ~= 'string' then
                item.info = F.Prepare(item.name, type(item.info) == 'table' and item.info or {}, storage, now)
                changed = true
            end
        end
    end
    return changed
end

--- Copies of `items` for sending to a client, with a display-only freshness summary.
--- The server never reads info back from clients, so this cannot influence real state.
function F.DecorateForClient(items, now)
    if type(items) ~= 'table' or not F.Enabled() then return items end
    now = now or F.now()
    local out = {}
    for key, item in pairs(items) do
        if type(item) == 'table' and F.IsPerishable(item.name) and type(item.info) == 'table' and type(item.info.fresh) == 'table' then
            local copy = {}
            for k, v in pairs(item) do copy[k] = v end
            copy.info = {}
            for k, v in pairs(item.info) do copy.info[k] = v end
            local pct = F.Percent(item.info.fresh, now)
            local state = F.StateFor(pct)
            copy.info.freshDisplay = {
                pct = math.floor(pct + 0.5),
                state = state.state,
                label = state.label,
                storage = item.info.fresh.storage,
            }
            out[key] = copy
        else
            out[key] = item
        end
    end
    return out
end

return F
