-- Police armory (batch 20, unit 20F): equipment checkout and return against the department asset
-- register of pf-government (server/departments/assets.lua, 20E).
--
-- Every armory item is a real, serial-tracked asset: the officer takes an in-stock asset of the
-- right kind, pf-government records it as issued to them (IssueAsset, keyed), and the item lands in
-- the inventory carrying the serial (info.assetSerial; weapons also info.serie, the weapon serial the
-- inventory and evidence code read). A return removes exactly that item and books the asset back in
-- stock (ReturnAsset, keyed on the issue time so a retry finds the first return); equipment a manager marked lost while
-- the officer held it is handed in the same way, which lifts pf-government's block on new draws (a
-- draw while it is open answers conflict with the serial to hand in). Nothing comes from
-- thin air: no stock in the register = nothing to take, and with pf-government stopped the armory is
-- closed (fails closed).
--
-- Checkout needs, read on the server: an on-duty LEO of a department in Config.Armory.Depts, within
-- Config.Armory.Radius of an armory point (server position), the item on the whitelist
-- (Config.ArmoryWhitelist, the old unused setting, now enforced; built-in defaults when empty), the
-- item's minimum grade and qualification (pf-government HasQualification), at most MaxOut assets
-- held, one of each item, and room in the inventory. pf-government re-checks duty and department.
-- Only unique items (one per slot) are issued: a stacking item would merge two serials.
--
-- Config.ArmoryWhitelist accepts { item = minGrade } or { item = { grade, kind, qual, default } } or a list of
-- item names (grade 0). `kind` is the asset kind in pf-government Config.Departments.Assets.Kinds.
-- An asset registered without an item stands for the default item of its kind (A.ItemOf).

PFArmory = PFArmory or {}
local A = PFArmory

-- Defaults (Config.Armory in config.lua overrides any of them).
local DEFAULTS = {
    Depts = { police = true },
    Radius = 3.0,
    MaxOut = 6,
    RateMs = 1500,
    Ref = 'armory', -- issue_ref of armory equipment (pf-government Config.Departments.Assets.ArmoryRef)
    -- armory counters at Mission Row and Paleto (server-checked; the client draws the prompt)
    Locations = {
        vector3(452.30, -982.50, 30.69),
        vector3(-449.40, 6016.30, 31.72),
    },
}

-- Asset kind of each default item; the whitelist may name others with an explicit kind.
local DEFAULT_ITEMS = {
    weapon_pistol = { grade = 0, kind = 'sidearm', default = true },
    weapon_combatpistol = { grade = 0, kind = 'sidearm' },
    weapon_stungun = { grade = 0, kind = 'taser' },
    weapon_pumpshotgun = { grade = 1, kind = 'shotgun' },
    weapon_carbinerifle = { grade = 2, kind = 'rifle' },
    radio = { grade = 0, kind = 'radio' },
}
A.DefaultItems = DEFAULT_ITEMS

function A.Cfg()
    local c = type(Config.Armory) == 'table' and Config.Armory or {}
    local out = {}
    for k, v in pairs(DEFAULTS) do out[k] = c[k] ~= nil and c[k] or v end
    return out
end

local function now() return os.time() end
local function getPlayer(src) return exports['pfm-core']:GetPlayer(src) end
local function started(res) return GetResourceState(res) == 'started' end

local function fail(code, message, extra)
    local out = { ok = false, error = code, message = message or code }
    for k, v in pairs(extra or {}) do out[k] = v end
    return out
end

local function sharedItem(name)
    local items = exports['pfm-core']:GetShared('Items') or {}
    return items[name]
end

--- The whitelist as { item = { grade, kind, qual } }: Config.ArmoryWhitelist when it has entries,
--- else the defaults. Entries without a known kind, or for items that stack, are left out.
function A.Whitelist()
    local src = Config.ArmoryWhitelist
    local raw = {}
    if type(src) == 'table' and next(src) ~= nil then
        for k, v in pairs(src) do
            if type(k) == 'number' and type(v) == 'string' then raw[v] = { grade = 0 }
            elseif type(k) == 'string' and type(v) == 'number' then raw[k] = { grade = v }
            elseif type(k) == 'string' and type(v) == 'table' then raw[k] = v
            elseif type(k) == 'string' and v == true then raw[k] = { grade = 0 } end
        end
    else
        raw = DEFAULT_ITEMS
    end
    local out = {}
    for name, e in pairs(raw) do
        local item = type(name) == 'string' and name:lower() or nil
        local kind = e.kind or (DEFAULT_ITEMS[item or ''] or {}).kind
        local def = item and sharedItem(item)
        if item and type(kind) == 'string' and def and def.unique == true then
            out[item] = { grade = math.max(0, math.floor(tonumber(e.grade) or 0)), kind = kind,
                qual = type(e.qual) == 'string' and e.qual or nil, label = def.label or item, default = e.default == true }
        end
    end
    return out
end

--- The item an asset stands for: its registered item, or for an asset registered without one, the
--- default item of its kind (the whitelist entry marked default = true, else the first by name).
--- Checkout, the held check and the menu all use this, so a kind-only asset is one item everywhere.
function A.ItemOf(asset, whitelist)
    if type(asset) ~= 'table' then return nil end
    if asset.item ~= nil then return asset.item end
    local pick, pickDefault
    for name, e in pairs(whitelist or A.Whitelist()) do
        if e.kind == asset.kind then
            if e.default and (not pickDefault or name < pick) then pick, pickDefault = name, true
            elseif not pickDefault and (not pick or name < pick) then pick = name end
        end
    end
    return pick
end

local function gradeOf(P)
    local g = P.PlayerData.job and P.PlayerData.job.grade
    return type(g) == 'table' and (tonumber(g.level) or 0) or (tonumber(g) or 0)
end

local function isLeo(P) return P ~= nil and P.PlayerData.job ~= nil and P.PlayerData.job.type == 'leo' end

--- The armory point within Radius of the player's server position, or nil.
function A.NearPoint(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local pos = GetEntityCoords(ped)
    local c = A.Cfg()
    for i, p in ipairs(c.Locations or {}) do
        if #(pos - vector3(p.x, p.y, p.z)) <= (tonumber(c.Radius) or 3.0) then return i end
    end
    return nil
end

-- One call into pf-government; nil, 'unavailable' when it is not running or the call broke off.
local function gov(name, ...)
    if not started('pf-government') then return nil, 'unavailable' end
    local n, args = select('#', ...), { ... }
    local ok, res = pcall(function()
        local e = exports['pf-government']
        return e[name](e, table.unpack(args, 1, n))
    end)
    if not ok then
        print(('^3[pfm-policejob]^7 armory: pf-government %s failed: %s'):format(name, tostring(res)))
        return nil, 'unavailable'
    end
    if type(res) ~= 'table' and name ~= 'GetDepartmentOf' and name ~= 'HasQualification' then return nil, 'unavailable' end
    return res, nil
end

-- A keyed write: one retry with the SAME key when the call broke off (the key makes it safe).
local function govWrite(name, ...)
    local res, why = gov(name, ...)
    if why == 'unavailable' and started('pf-government') then res, why = gov(name, ...) end
    return res, why
end

local function hasQual(cid, qual)
    if not qual then return true end
    local res = gov('HasQualification', cid, qual)
    return res == true
end

local function deptOf(src)
    local d = gov('GetDepartmentOf', src)
    return type(d) == 'string' and d or nil
end

-- Per-officer lock, taken before the first wait (the register lookups) of a checkout or return.
local locks = {}
local function withLock(key, fn)
    if locks[key] then return fail('busy', 'The armory is still handling your last request') end
    locks[key] = true
    local ok, res = pcall(fn)
    locks[key] = nil
    if not ok then
        print(('^1[pfm-policejob]^7 armory: %s'):format(tostring(res)))
        return fail('unavailable', 'The armory failed; check your equipment before trying again')
    end
    return res
end
A.Locks = locks

local lastAt = {}
local function rateOk(src)
    local t = GetGameTimer()
    if lastAt[src] and t - lastAt[src] < (tonumber(A.Cfg().RateMs) or 1500) then return false end
    lastAt[src] = t
    return true
end
AddEventHandler('playerDropped', function() lastAt[source] = nil end)

local function mark(src, data)
    if PFTelemetry and PFTelemetry.Mark then pcall(PFTelemetry.Mark, src, 'note', data) end
end

local function itemWithSerial(P, serial)
    for slot, it in pairs(P.PlayerData.items or {}) do
        if type(it) == 'table' and type(it.info) == 'table' and it.info.assetSerial == serial then
            return it, tonumber(it.slot) or tonumber(slot)
        end
    end
    return nil
end

local function normSerial(s)
    if type(s) ~= 'string' or #s < 1 or #s > 32 or not s:match('^[%w%-]+$') then return nil end
    return s:upper()
end

-- The checks every armory action shares: online, at an armory point, a department the armory serves.
local function context(src, needDuty)
    src = tonumber(src)
    local P = src and getPlayer(src)
    if not P then return nil, fail('offline') end
    if needDuty and not (isLeo(P) and P.PlayerData.job.onduty == true) then return nil, fail('not_on_duty', 'On-duty police only') end
    if not A.NearPoint(src) then return nil, fail('too_far', 'Go to the armory counter') end
    return P
end

--- What this officer may take (stock counts from the register) and what they hold.
function A.Menu(src)
    local P, e = context(src, true)
    if not P then return e end
    local dept = deptOf(src)
    if not dept or not A.Cfg().Depts[dept] then return fail('unavailable', 'The armory is closed (department records unavailable)') end
    local cid = P.PlayerData.citizenid
    local grade = gradeOf(P)
    local stockByKind = {}
    local items = {}
    local wl = A.Whitelist()
    for name, entry in pairs(wl) do
        if not stockByKind[entry.kind] then
            local res = gov('ListAssets', dept, { state = 'in_stock', kind = entry.kind, limit = 100 })
            stockByKind[entry.kind] = type(res) == 'table' and res.ok and res.list or {}
        end
        local n = 0
        for _, a in ipairs(stockByKind[entry.kind]) do
            if A.ItemOf(a, wl) == name then n = n + 1 end
        end
        local reason
        if grade < entry.grade then reason = 'rank'
        elseif entry.qual and not hasQual(cid, entry.qual) then reason = 'qualification' end
        items[#items + 1] = { item = name, label = entry.label, kind = entry.kind, inStock = n, allowed = reason == nil, reason = reason }
    end
    table.sort(items, function(a, b) return a.label < b.label end)
    -- held: issued to the officer, and armory equipment a manager marked lost while they held it
    -- (it blocks new draws until it is handed in here or written off)
    local held = {}
    for _, state in ipairs({ 'issued', 'lost' }) do
        local res = gov('ListAssets', dept, { holder = cid, state = state, limit = 100 })
        for _, a in ipairs(type(res) == 'table' and res.ok and res.list or {}) do
            if state == 'issued' or a.ref == A.Cfg().Ref then
                local it = itemWithSerial(P, a.serial)
                held[#held + 1] = { serial = a.serial, kind = a.kind, item = it and it.name or a.item, label = a.label or a.kind,
                    carried = it ~= nil, lost = state == 'lost' or nil }
            end
        end
    end
    return { ok = true, items = items, held = held, maxOut = A.Cfg().MaxOut }
end

--- Takes one in-stock asset of the item's kind and puts it in the officer's inventory.
function A.Checkout(src, itemName)
    src = tonumber(src)
    if type(itemName) ~= 'string' or #itemName > 48 or not itemName:match('^[%w_]+$') then return fail('bad_args') end
    itemName = itemName:lower()
    local P, e = context(src, true)
    if not P then return e end
    local wl = A.Whitelist()
    local entry = wl[itemName]
    if not entry then return fail('no_permission', 'The armory does not issue that') end
    if gradeOf(P) < entry.grade then return fail('no_permission', 'Your rank cannot draw that') end
    if not rateOk(src) then return fail('rate_limited', 'Slow down') end
    local cid = P.PlayerData.citizenid
    return withLock(cid, function()
        local dept = deptOf(src)
        if not dept or not A.Cfg().Depts[dept] then return fail('unavailable', 'The armory is closed (department records unavailable)') end
        if not hasQual(cid, entry.qual) then return fail('no_permission', 'You are not qualified for that') end
        local held, why = gov('ListAssets', dept, { holder = cid, state = 'issued', limit = 100 })
        if why or not held.ok then return fail('unavailable', 'The asset register did not answer') end
        local heldList = type(held.list) == 'table' and held.list or {}
        if #heldList >= (tonumber(A.Cfg().MaxOut) or 6) then return fail('conflict', 'Return equipment before drawing more') end
        for _, a in ipairs(heldList) do
            -- one of each item: compared by kind, and by the item the asset stands for
            if a.kind == entry.kind and A.ItemOf(a, wl) == itemName then
                return fail('conflict', 'You already hold one: ' .. tostring(a.serial))
            end
        end
        local canAdd = exports['pfm-inventory']:CanAddItem(src, itemName, 1)
        if not canAdd then return fail('inventory_full', 'No room in your inventory') end
        local stock, why2 = gov('ListAssets', dept, { state = 'in_stock', kind = entry.kind, limit = 100 })
        if why2 or not stock.ok then return fail('unavailable', 'The asset register did not answer') end
        local asset
        local stockList = type(stock.list) == 'table' and stock.list or {}
        for i = #stockList, 1, -1 do -- oldest first (the list is newest first)
            local a = stockList[i]
            if A.ItemOf(a, wl) == itemName then asset = a break end
        end
        if not asset then return fail('out_of_stock', 'None in stock') end
        local key = ('pfm-policejob:armory:%s:issue:%d:%d'):format(asset.serial, now(), math.random(1000, 9999))
        local res, why3 = govWrite('IssueAsset', asset.serial, cid, { key = key, actor = { src = src }, ref = A.Cfg().Ref, note = itemName })
        if why3 then return fail('unavailable', 'The asset register did not answer; nothing was issued') end
        if not res.ok then
            -- pf-government blocks new armory draws while equipment marked lost is still held by them
            if res.error == 'conflict' and type(res.serial) == 'string' then
                return fail('conflict', ('Hand in %s at the armory first (reported lost while you held it)'):format(res.serial), { serial = res.serial })
            end
            return fail(res.error or 'unavailable', res.message)
        end
        local info = { assetSerial = asset.serial, dept = dept }
        local def = sharedItem(itemName)
        if def and def.type == 'weapon' then info.serie = asset.serial end
        local added = exports['pfm-inventory']:AddItem(src, itemName, 1, nil, info, 'armory checkout ' .. asset.serial)
        if not added then
            -- the item could not be handed over: book the asset back in (its own key)
            local undo = govWrite('ReturnAsset', asset.serial, { key = key .. ':undo', actor = { src = src }, note = 'checkout not completed' })
            if not (type(undo) == 'table' and undo.ok) then
                print(('^1[pfm-policejob]^7 armory: %s stays issued to %s after a failed hand-over'):format(asset.serial, cid))
            end
            return fail('inventory_full', 'No room in your inventory')
        end
        TriggerClientEvent('qb-inventory:client:ItemBox', src, def, 'add')
        mark(src, { action = 'armory_out', item = itemName, serial = asset.serial })
        return { ok = true, serial = asset.serial, item = itemName }
    end)
end

--- Hands one issued asset back: the inventory item carrying its serial is removed, then the register
--- books it in. A register failure gives the item back, so nothing is lost on either side.
function A.Return(src, serial)
    src = tonumber(src)
    serial = normSerial(serial)
    if not serial then return fail('bad_args') end
    -- returning needs no duty: an officer may hand gear in after their shift (the register checks
    -- that they are the holder)
    local P, e = context(src, false)
    if not P then return e end
    if not rateOk(src) then return fail('rate_limited', 'Slow down') end
    local cid = P.PlayerData.citizenid
    return withLock(cid, function()
        local got, why = gov('GetAsset', serial)
        if why then return fail('unavailable', 'The asset register did not answer') end
        if not got.ok then return fail(got.error or 'not_found', got.message) end
        local asset = got.asset
        -- issued to them, or armory equipment a manager marked lost while they held it (handing it in
        -- here books it back in and lifts the block on new draws)
        local lostHeld = asset.state == 'lost' and asset.ref == A.Cfg().Ref
        if (asset.state ~= 'issued' and not lostHeld) or asset.holder ~= cid then return fail('not_found', 'That equipment is not issued to you') end
        P = getPlayer(src)
        local it, slot = itemWithSerial(P, serial)
        if not it then return fail('not_carried', 'You do not carry that equipment') end
        if not exports['pfm-inventory']:RemoveItem(src, it.name, 1, slot, 'armory return ' .. serial) then
            return fail('unavailable', 'The item could not be taken')
        end
        local key = ('pfm-policejob:armory:%s:return:%s'):format(serial, tostring(asset.issuedAt or 0))
        local res, why2 = govWrite('ReturnAsset', serial, { key = key, actor = { src = src }, note = 'armory return' })
        if why2 or not (type(res) == 'table' and res.ok) then
            exports['pfm-inventory']:AddItem(src, it.name, 1, slot, it.info, 'armory return failed ' .. serial)
            return fail(type(res) == 'table' and res.error or 'unavailable', 'The register did not take it back; you keep it')
        end
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItem(it.name), 'remove')
        mark(src, { action = 'armory_in', item = it.name, serial = serial })
        return { ok = true, serial = serial, item = it.name }
    end)
end

-- ── client paths ──────────────────────────────────────────────────────────────────────────────

QBCore.Functions.CreateCallback('police:server:armoryPoints', function(source, cb)
    local P = getPlayer(source)
    if not isLeo(P) then return cb({ points = {} }) end
    local pts = {}
    for _, p in ipairs(A.Cfg().Locations or {}) do pts[#pts + 1] = { x = p.x, y = p.y, z = p.z } end
    cb({ points = pts })
end)

QBCore.Functions.CreateCallback('police:server:armoryMenu', function(source, cb)
    cb(A.Menu(source))
end)

QBCore.Functions.CreateCallback('police:server:armoryCheckout', function(source, cb, data)
    cb(A.Checkout(source, type(data) == 'table' and data.item or nil))
end)

QBCore.Functions.CreateCallback('police:server:armoryReturn', function(source, cb, data)
    cb(A.Return(source, type(data) == 'table' and data.serial or nil))
end)
