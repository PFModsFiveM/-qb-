-- Persistent world objects: delivery pallets and boxes that stay where they were put, with their own
-- stash each. The server owns every object: it creates the record and the stash, spawns the entity,
-- decides where it stands (a move puts it in front of the player who moves it, never at a position a
-- client sends), and only lets authorized players open, unpack or move it.
--
-- pf_world_objects (one row per object):
--   id, kind, model, x/y/z + rx/ry/rz, owner_ref (e.g. store:corner), order_id, stash_id (worldobj-<id>),
--   state (sealed -> unpacked | removed), origin x/y/z, created_at, updated_at
--
-- A delivery's goods arrive sealed in its stash; they can be looked at but not taken out or added to.
-- Unpacking hands the order to its owner service (pf-stores' order service), which adds the goods to the
-- business's stock exactly once; then the stash is emptied and the object goes away.

PFWorldObjects = PFWorldObjects or { entities = {} }
local W = PFWorldObjects
local C = Config.WorldObjects

local function nowMs() return math.floor(os.time() * 1000.0) end   -- float math: no integer overflow on 32-bit Lua builds

W.Migrations = {
    {
        version = 1,
        name = 'world objects',
        up = {
            [[CREATE TABLE IF NOT EXISTS `pf_world_objects` (
                `id` VARCHAR(48) NOT NULL,
                `kind` VARCHAR(24) NOT NULL,
                `model` VARCHAR(64) NOT NULL,
                `x` DOUBLE NOT NULL, `y` DOUBLE NOT NULL, `z` DOUBLE NOT NULL,
                `rx` DOUBLE NOT NULL DEFAULT 0, `ry` DOUBLE NOT NULL DEFAULT 0, `rz` DOUBLE NOT NULL DEFAULT 0,
                `origin_x` DOUBLE NOT NULL, `origin_y` DOUBLE NOT NULL, `origin_z` DOUBLE NOT NULL,
                `owner_ref` VARCHAR(96) NOT NULL,
                `order_id` INT NULL,
                `stash_id` VARCHAR(64) NOT NULL,
                `state` VARCHAR(16) NOT NULL DEFAULT 'sealed',
                `created_at` BIGINT NOT NULL,
                `updated_at` BIGINT NOT NULL,
                PRIMARY KEY (`id`),
                UNIQUE KEY `uq_stash` (`stash_id`),
                UNIQUE KEY `uq_order` (`order_id`),
                INDEX `idx_state` (`state`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        },
    },
}

local allowedModels = {}
for _, m in ipairs(C.Models or {}) do allowedModels[m] = true end

local counter = 0
local function newId()
    counter = counter + 1
    return ('wo-%d-%d-%d'):format(os.time(), counter, math.random(1000, 9999))
end

function W.Get(id)
    if type(id) ~= 'string' then return nil end
    return MySQL.single.await('SELECT * FROM pf_world_objects WHERE id = ? LIMIT 1', { id })
end

local function publicObject(row)
    local entity = W.entities[row.id]
    return {
        id = row.id, kind = row.kind, model = row.model, state = row.state,
        coords = { x = row.x, y = row.y, z = row.z }, rotation = { x = row.rx, y = row.ry, z = row.rz },
        netId = entity and DoesEntityExist(entity) and NetworkGetNetworkIdFromEntity(entity) or nil,
    }
end

local function spawnEntity(row)
    local old = W.entities[row.id]
    if old and DoesEntityExist(old) then DeleteEntity(old) end
    local entity = CreateObjectNoOffset(joaat(row.model), row.x, row.y, row.z, true, true, false)
    if entity and entity ~= 0 then
        SetEntityRotation(entity, row.rx or 0.0, row.ry or 0.0, row.rz or 0.0, 2, true)
        FreezeEntityPosition(entity, true)
        W.entities[row.id] = entity
    end
    return entity
end

local function despawn(id)
    local entity = W.entities[id]
    if entity and DoesEntityExist(entity) then DeleteEntity(entity) end
    W.entities[id] = nil
    TriggerClientEvent('pfm-worldobjects:client:removed', -1, id)
end

local function stashLabel(row) return (row.kind == 'delivery' and 'Delivery #' .. tostring(row.order_id)) or 'Container' end

local function ensureStash(row)
    exports['pfm-inventory']:CreateInventory(row.stash_id, { label = stashLabel(row), maxweight = C.StashWeight, slots = C.StashSlots })
end

--- Creates a delivery object for an order, with the goods sealed in its own stash. Idempotent per order.
--- opts = { orderId, ownerRef, model, coords = {x,y,z[,w]}, heading, contents = {{ item, amount, info }} }
function W.CreateDeliveryObject(opts)
    if type(opts) ~= 'table' or not tonumber(opts.orderId) or type(opts.ownerRef) ~= 'string' then return nil end
    local existing = MySQL.single.await('SELECT * FROM pf_world_objects WHERE order_id = ? LIMIT 1', { tonumber(opts.orderId) })
    if existing then return existing.id end
    local model = allowedModels[opts.model] and opts.model or C.Models[1]
    local c = opts.coords or {}
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not (x and y and z) then return nil end
    local id = newId()
    local stashId = 'worldobj-' .. id
    local now = nowMs()
    local inserted = MySQL.insert.await([[INSERT INTO pf_world_objects
        (id, kind, model, x, y, z, rx, ry, rz, origin_x, origin_y, origin_z, owner_ref, order_id, stash_id, state, created_at, updated_at)
        VALUES (?, 'delivery', ?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?, ?, ?, 'sealed', ?, ?)]],
        { id, model, x, y, z, tonumber(opts.heading or c.w) or 0.0, x, y, z, opts.ownerRef, tonumber(opts.orderId), stashId, now, now })
    if inserted == nil then return nil end
    local row = W.Get(id)
    ensureStash(row)
    for _, it in ipairs(opts.contents or {}) do
        exports['pfm-inventory']:AddItem(stashId, it.item, tonumber(it.amount) or 1, false, it.info, 'pfm-worldobjects:delivery')
    end
    exports['pfm-inventory']:SaveStash(stashId)
    spawnEntity(row)
    TriggerClientEvent('pfm-worldobjects:client:upsert', -1, publicObject(row))
    return id
end

-- ── access ──────────────────────────────────────────────────────────────────

local function isAdmin(src) return IsPlayerAceAllowed(src, C.AdminAce or 'pfm-worldobjects.admin') end

local function canManage(src, row)
    if isAdmin(src) then return true end
    if row.order_id and GetResourceState('pf-stores') == 'started' then
        local ok, allowed = pcall(function() return exports['pf-stores']:CanManageOrderBuyer(src, row.order_id) end)
        return ok and allowed == true
    end
    return false
end

local function near(src, row, range)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    return #(GetEntityCoords(ped) - vector3(row.x, row.y, row.z)) <= (range or C.InteractDistance)
end

-- A sealed stash's contents only change by unpacking: moving items in or out is refused
local function registerStashHook()
    if W.hookRegistered then return end
    local ok = pcall(function()
        -- pfm-inventory calls hooks as (subtype, data)
        exports['pfm-inventory']:AddHook('ItemMoved', function(_, data)
            if type(data) ~= 'table' then return end
            for _, id in ipairs({ data.fromId, data.toId }) do
                if type(id) == 'string' and id:sub(1, 9) == 'worldobj-' then
                    local state = MySQL.scalar.await('SELECT state FROM pf_world_objects WHERE stash_id = ?', { id })
                    if state == 'sealed' then return false end
                end
            end
        end)
    end)
    W.hookRegistered = ok
end

-- open/unpack/move each read the database: one request a second per player is plenty
local actionAt = {}
local function throttled(src)
    local now = GetGameTimer()
    if actionAt[src] and now - actionAt[src] < 1000 then return true end
    actionAt[src] = now
    return false
end

RegisterNetEvent('pfm-worldobjects:server:open', function(id)
    local src = source
    if throttled(src) then return end
    local row = W.Get(id)
    if not row or row.state ~= 'sealed' or not near(src, row) or not canManage(src, row) then return end
    ensureStash(row)
    exports['pfm-inventory']:OpenInventory(src, row.stash_id, { label = stashLabel(row), maxweight = C.StashWeight, slots = C.StashSlots })
end)

--- Unpacks a delivery: the order service adds the goods to the business once, then the stash is
--- emptied and the object removed.
function W.Unpack(src, id)
    local row = W.Get(id)
    if not row then return { ok = false, error = 'not_found' } end
    if row.state ~= 'sealed' then return { ok = false, error = 'already_unpacked' } end
    if not near(src, row) then return { ok = false, error = 'too_far' } end
    if not canManage(src, row) then return { ok = false, error = 'not_authorized' } end
    local inv = exports['pfm-inventory']:GetInventory(row.stash_id)
    if inv and inv.isOpen then return { ok = false, error = 'in_use' } end
    local res = { ok = false, error = 'no_order' }
    if row.order_id and GetResourceState('pf-stores') == 'started' then
        local ok, r = pcall(function() return exports['pf-stores']:UnpackSupplyOrder(src, row.order_id) end)
        res = ok and r or { ok = false, error = 'order_service_error' }
        -- a crash between the order and this record: the order says it is unpacked, so finish here
        if not res.ok and res.error == 'not_unpackable' then
            local okO, order = pcall(function() return exports['pf-stores']:GetOrder(row.order_id) end)
            if okO and order and order.status == 'unpacked' then res = { ok = true } end
        end
    end
    if not res.ok then return res end
    local changed = MySQL.update.await("UPDATE pf_world_objects SET state = 'unpacked', updated_at = ? WHERE id = ? AND state = 'sealed'", { nowMs(), row.id })
    if not changed or changed < 1 then return { ok = false, error = 'already_unpacked' } end
    exports['pfm-inventory']:ClearStash(row.stash_id)
    exports['pfm-inventory']:RemoveInventory(row.stash_id)
    despawn(row.id)
    return { ok = true }
end

RegisterNetEvent('pfm-worldobjects:server:unpack', function(id)
    local src = source
    if throttled(src) then return end
    local res = W.Unpack(src, id)
    TriggerClientEvent('QBCore:Notify', src, res.ok and 'Delivery unpacked into stock' or ('Cannot unpack: ' .. tostring(res.error)), res.ok and 'success' or 'error')
end)

--- Moves an object to just in front of the player moving it (the client only asks; the server places).
function W.Move(src, id)
    local row = W.Get(id)
    if not row or row.state ~= 'sealed' then return { ok = false, error = 'not_found' } end
    if not near(src, row) or not canManage(src, row) then return { ok = false, error = 'not_authorized' } end
    local ped = GetPlayerPed(src)
    local pos = GetEntityCoords(ped)
    local heading = math.rad(GetEntityHeading(ped))
    local x, y, z = pos.x - math.sin(heading) * 1.5, pos.y + math.cos(heading) * 1.5, pos.z - 1.0
    if #(vector3(x, y, z) - vector3(row.origin_x, row.origin_y, row.origin_z)) > (C.MoveMaxDistance or 30.0) then
        return { ok = false, error = 'too_far_from_delivery_point' }
    end
    MySQL.update.await('UPDATE pf_world_objects SET x = ?, y = ?, z = ?, rz = ?, updated_at = ? WHERE id = ? AND state = ?',
        { x, y, z, GetEntityHeading(ped), nowMs(), row.id, 'sealed' })
    row = W.Get(id)
    spawnEntity(row)
    TriggerClientEvent('pfm-worldobjects:client:upsert', -1, publicObject(row))
    return { ok = true }
end

RegisterNetEvent('pfm-worldobjects:server:move', function(id)
    local src = source
    if throttled(src) then return end
    local res = W.Move(src, id)
    if not res.ok then TriggerClientEvent('QBCore:Notify', src, 'Cannot move: ' .. tostring(res.error), 'error') end
end)

-- players joining later get the objects around the map
local syncAt = {}
RegisterNetEvent('pfm-worldobjects:server:sync', function()
    local src = source
    if syncAt[src] and os.time() - syncAt[src] < 10 then return end
    syncAt[src] = os.time()
    local out = {}
    for _, row in ipairs(MySQL.query.await("SELECT * FROM pf_world_objects WHERE state = 'sealed'") or {}) do
        out[#out + 1] = publicObject(row)
    end
    TriggerClientEvent('pfm-worldobjects:client:all', src, out)
end)
AddEventHandler('playerDropped', function() syncAt[source] = nil; actionAt[source] = nil end)

-- ── start: migrations, then every sealed object back where it was saved ──────

function W.Start()
    local ok, err = RunMigrations('pfm-worldobjects', W.Migrations)
    if not ok then
        print('^1[pfm-worldobjects]^7 migrations failed: ' .. tostring(err))
        return false
    end
    local rows = MySQL.query.await("SELECT * FROM pf_world_objects WHERE state = 'sealed'") or {}
    for _, row in ipairs(rows) do
        ensureStash(row)
        spawnEntity(row)
    end
    registerStashHook()
    W.ready = true
    print(('[pfm-worldobjects] restored %d object(s)'):format(#rows))
    return true
end

CreateThread(function()
    Wait(1000)
    W.Start()
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    for id in pairs(W.entities) do
        local e = W.entities[id]
        if e and DoesEntityExist(e) then DeleteEntity(e) end
    end
end)

exports('CreateDeliveryObject', W.CreateDeliveryObject)
exports('GetObject', function(id) return W.Get(id) end)
