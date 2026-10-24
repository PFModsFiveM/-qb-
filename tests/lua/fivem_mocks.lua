-- FiveM / QBCore mock environment for server-side resource tests.
-- Records client events, logs and DB calls so specs can assert on side effects.
Mock = {
    clientEvents = {},
    serverEvents = {},
    netHandlers = {},
    eventHandlers = {},
    callbacks = {},
    useables = {},
    exportsByResource = {},
    dbCalls = {},
    players = {},
    clock = 1700000000,
    gameTimer = 0,
    invokingResource = nil,
}

function Mock.reset()
    Mock.clientEvents = {}
    Mock.serverEvents = {}
    Mock.dbCalls = {}
end

-- ── json (enough for tests) ────────────────────────────────────────
json = {}
local function encode(v)
    local t = type(v)
    if t == 'nil' then return 'null' end
    if t == 'boolean' or t == 'number' then return tostring(v) end
    if t == 'string' then return string.format('%q', v) end
    -- sequences encode as JSON arrays, like FiveM's json.encode
    local n = #v
    if n > 0 then
        local count = 0
        for _ in pairs(v) do count = count + 1 end
        if count == n then
            local items = {}
            for i = 1, n do items[i] = encode(v[i]) end
            return '[' .. table.concat(items, ',') .. ']'
        end
    end
    local parts = {}
    for k, val in pairs(v) do parts[#parts + 1] = string.format('%q', tostring(k)) .. ':' .. encode(val) end
    table.sort(parts)
    return '{' .. table.concat(parts, ',') .. '}'
end
json.encode = encode
-- Minimal JSON decoder: objects, arrays, strings, numbers, booleans, null.
json.decode = function(s)
    if type(s) ~= 'string' then return nil end
    local pos = 1
    local function ws() pos = s:find('[^%s]', pos) or #s + 1 end
    local value
    local function str()
        local out, i = {}, pos + 1
        while true do
            local c = s:sub(i, i)
            if c == '"' then pos = i + 1 return table.concat(out) end
            if c == '\\' then i = i + 1; c = s:sub(i, i) end
            if c == '' then error('json: unterminated string') end
            out[#out + 1] = c
            i = i + 1
        end
    end
    function value()
        ws()
        local c = s:sub(pos, pos)
        if c == '{' then
            local t = {}
            pos = pos + 1; ws()
            if s:sub(pos, pos) == '}' then pos = pos + 1 return t end
            while true do
                ws(); local k = str(); ws(); pos = pos + 1
                t[k] = value(); ws()
                local d = s:sub(pos, pos); pos = pos + 1
                if d == '}' then return t end
            end
        elseif c == '[' then
            local t = {}
            pos = pos + 1; ws()
            if s:sub(pos, pos) == ']' then pos = pos + 1 return t end
            while true do
                t[#t + 1] = value(); ws()
                local d = s:sub(pos, pos); pos = pos + 1
                if d == ']' then return t end
            end
        elseif c == '"' then return str()
        elseif s:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
        else
            -- fengari mishandles '[-+]' classes, so the exponent is matched separately with escapes
            local rest = s:sub(pos)
            local num = rest:match('^%-?%d+%.?%d*')
            if num then num = num .. (rest:sub(#num + 1):match('^[eE][%+%-]?%d+') or '') end
            pos = pos + #num
            return tonumber(num)
        end
    end
    local ok, out = pcall(value)
    if ok then return out end
    return nil
end

-- FiveM's Lua adds table.type: 'empty', 'array' or 'hash'
table.type = table.type or function(t)
    if type(t) ~= 'table' then return nil end
    if next(t) == nil then return 'empty' end
    local n = #t
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then return 'hash' end
    end
    return 'array'
end

-- ── time ──────────────────────────────────────────────────────────
local realTime = os.time
os.time = function(t) if t then return realTime(t) end return Mock.clock end
function GetGameTimer() Mock.gameTimer = Mock.gameTimer + 1; return Mock.gameTimer end

-- ── events / threads ──────────────────────────────────────────────
function RegisterNetEvent(name, fn) if fn then Mock.netHandlers[name] = fn end end
RegisterServerEvent = RegisterNetEvent
function AddEventHandler(name, fn) Mock.eventHandlers[name] = fn end
function TriggerClientEvent(name, target, ...) Mock.clientEvents[#Mock.clientEvents + 1] = { name = name, target = target, args = { ... } } end
function TriggerEvent(name, ...)
    Mock.serverEvents[#Mock.serverEvents + 1] = { name = name, args = { ... } }
    -- server-local events reach AddEventHandler handlers, as in FiveM
    local handler = Mock.eventHandlers[name]
    if handler then handler(...) end
end
function CreateThread() end
Citizen = { CreateThread = CreateThread, Wait = function() end }
function SetTimeout() end
function Wait() end
function GetInvokingResource() return Mock.invokingResource end
function GetCurrentResourceName() return 'pfm-inventory' end
function GetConvar(_, default) return default end
function GetResourceState() return 'missing' end
function GetPlayerName(id) return 'Player' .. tostring(id) end
-- ACE permissions: Mock.aces[src] = { ['admin'] = true, ... }
Mock.aces = {}
function IsPlayerAceAllowed(src, ace) return Mock.aces[tonumber(src)] ~= nil and Mock.aces[tonumber(src)][ace] == true end
-- FiveM's model-name hash (Jenkins one-at-a-time, lower-cased, signed 32-bit like GetHashKey)
function GetHashKey(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    if h >= 0x80000000 then h = h - 0x100000000 end
    return h
end
function GetPlayerPed(id) return id end
function joaat(s) return GetHashKey(s) & 0xFFFFFFFF end
-- vehicles and models: Mock.models[entity] = hash, Mock.vehicleOf[ped] = vehicle, Mock.plates[vehicle] = text
Mock.models, Mock.vehicleOf, Mock.plates, Mock.deleted = {}, {}, {}, {}
function GetEntityModel(e) return Mock.models[e] or 0 end
function GetVehiclePedIsIn(ped) return Mock.vehicleOf[ped] or 0 end
function GetPedInVehicleSeat(veh, seat) for ped, v in pairs(Mock.vehicleOf) do if v == veh and seat == -1 then return ped end end return 0 end
function GetVehicleNumberPlateText(veh) return Mock.plates[veh] end
function GetSelectedPedWeapon() return 0 end
function RemoveWeaponFromPed() end
Mock.dropped = {}
function DropPlayer(src, reason) Mock.dropped[#Mock.dropped + 1] = { src = src, reason = reason } end
Mock.coords = {}
function GetEntityCoords(ped) return Mock.coords[ped] or vector3(0, 0, 0) end
Mock.nextNetId = 100
function CreateObjectNoOffset() Mock.nextNetId = Mock.nextNetId + 1; return Mock.nextNetId end
function NetworkGetNetworkIdFromEntity(e) return e end
function NetworkGetEntityFromNetworkId(n) return n end
function DoesEntityExist() return true end
function DeleteEntity(e) Mock.deleted[#Mock.deleted + 1] = e end
function SetEntityRoutingBucket() end
function GetPlayerRoutingBucket() return 0 end
function TaskPlayAnim() end

--- Invokes a registered QBCore server callback and returns what it passed to cb.
function Mock.callCallback(name, src, ...)
    local fn = Mock.callbacks[name]
    assert(fn, 'no callback registered for ' .. name)
    local result
    fn(src, function(...) result = { ... } end, ...)
    if not result then return nil end
    return table.unpack(result)
end

--- Invokes a registered net event as if `src` triggered it from a client.
function Mock.fireNet(name, src, ...)
    local handler = Mock.netHandlers[name]
    assert(handler, 'no net handler registered for ' .. name)
    source = src
    local ok, err = pcall(handler, ...)
    source = nil
    if not ok then error(err, 2) end
end

--- Invokes a server-side event handler (AddEventHandler) as if `src` caused it, e.g. playerDropped.
function Mock.fireEvent(name, src, ...)
    local handler = Mock.eventHandlers[name]
    assert(handler, 'no event handler registered for ' .. name)
    source = src
    local ok, err = pcall(handler, ...)
    source = nil
    if not ok then error(err, 2) end
end

function Mock.clientEventsNamed(name)
    local out = {}
    for _, e in ipairs(Mock.clientEvents) do if e.name == name then out[#out + 1] = e end end
    return out
end

-- ── vectors ───────────────────────────────────────────────────────
local vecMeta = {}
vecMeta.__index = function(v, k) if k == 'xyz' then return vector3(v.x, v.y, v.z) elseif k == 'xy' then return vector2(v.x, v.y) end end
vecMeta.__sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)) end
vecMeta.__add = function(a, b) return vector3(a.x + b.x, a.y + b.y, (a.z or 0) + (b.z or 0)) end
vecMeta.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + (a.z or 0) * (a.z or 0)) end
function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, vecMeta) end
function vector4(x, y, z, w) return setmetatable({ x = x, y = y, z = z, w = w }, vecMeta) end
function vec3(x, y, z) return vector3(x, y, z) end
function vector2(x, y) return setmetatable({ x = x, y = y }, vecMeta) end

-- ── state bags ────────────────────────────────────────────────────
local stateBags = {}
function Player(src)
    stateBags[src] = stateBags[src] or { state = {} }
    return stateBags[src]
end

-- ── database ──────────────────────────────────────────────────────
local function dbCall(kind)
    local fn = function(query, params, cb)
        Mock.dbCalls[#Mock.dbCalls + 1] = { kind = kind, query = query, params = params }
        if type(cb) == 'function' then cb({}) end
        return {}
    end
    return setmetatable({ await = function(query, params) return fn(query, params) end }, { __call = function(_, ...) return fn(...) end })
end
MySQL = {
    query = dbCall('query'),
    insert = dbCall('insert'),
    update = dbCall('update'),
    prepare = dbCall('prepare'),
    scalar = dbCall('scalar'),
    single = dbCall('single'),
    rawExecute = dbCall('rawExecute'),
}

-- ── locale ────────────────────────────────────────────────────────
Lang = { t = function(_, key) return key end }

-- ── QBCore ────────────────────────────────────────────────────────
QBCoreMock = {
    Shared = {
        Items = {
            sandwich = { name = 'sandwich', label = 'Sandwich', weight = 200, type = 'item', unique = false, useable = true, image = 'sandwich.png' },
            water_bottle = { name = 'water_bottle', label = 'Water', weight = 500, type = 'item', unique = false, useable = true, image = 'water_bottle.png' },
            lockpick = { name = 'lockpick', label = 'Lockpick', weight = 300, type = 'item', unique = false, useable = true, image = 'lockpick.png' },
            phone = { name = 'phone', label = 'Phone', weight = 700, type = 'item', unique = true, useable = true, image = 'phone.png' },
            weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', weight = 1000, type = 'weapon', unique = true, useable = false, image = 'weapon_pistol.png' },
            goldbar = { name = 'goldbar', label = 'Gold Bar', weight = 7000, type = 'item', unique = false, useable = false, image = 'goldbar.png' },
        },
        Weapons = {},
        RandomInt = function(n) return string.rep('1', n) end,
        RandomStr = function(n) return string.rep('A', n) end,
    },
    Functions = {
        GetPlayer = function(id) return Mock.players[id] end,
        GetPlayerByCitizenId = function(cid)
            for _, p in pairs(Mock.players) do
                if p.PlayerData.citizenid == cid then return p end
            end
        end,
        GetQBPlayers = function() return Mock.players end,
        CreateCallback = function(name, fn) Mock.callbacks[name] = fn end,
        CreateUseableItem = function(name, fn) Mock.useables[name] = fn end,
        AddPlayerMethod = function() end,
        Notify = function() end,
    },
    Commands = { Add = function() end },
}

function Mock.newPlayer(src, citizenid)
    local p = {
        PlayerData = { source = src, citizenid = citizenid or ('CID' .. src), items = {}, money = { cash = 0, bank = 0 }, metadata = { hunger = 50, thirst = 50 }, job = { name = 'unemployed' }, charinfo = { firstname = 'Test', lastname = 'Player' .. src } },
    }
    function p.SetPlayerData(key, value) p.PlayerData[key] = value end
    function p.SetMetaData(key, value) p.PlayerData.metadata[key] = value end
    function p.RemoveMoney(kind, amount)
        amount = tonumber(amount) or 0
        if amount < 0 or (p.PlayerData.money[kind] or 0) < amount then return false end
        p.PlayerData.money[kind] = p.PlayerData.money[kind] - amount
        return true
    end
    function p.AddMoney(kind, amount)
        amount = tonumber(amount) or 0
        if amount < 0 then return false end
        p.PlayerData.money[kind] = (p.PlayerData.money[kind] or 0) + amount
        return true
    end
    p.Functions = { SetPlayerData = p.SetPlayerData, SetMetaData = p.SetMetaData, RemoveMoney = p.RemoveMoney, AddMoney = p.AddMoney }
    Mock.players[src] = p
    return p
end

-- ── exports ───────────────────────────────────────────────────────
Mock.vehicleGrants = {}
Mock.exportsByResource['pfm-core'] = {
    GetCoreObject = function() return QBCoreMock end,
    GrantVehicleSpawn = function(_, src, model) Mock.vehicleGrants[#Mock.vehicleGrants + 1] = { src = src, model = model } return true end,
    RegisterJobVehicles = function() return true end,
    GetPlayer = function(_, id) return Mock.players[id] end,
    GetShared = function(_, key) return QBCoreMock.Shared[key] end,
    GetPlayerByCitizenId = function(_, cid)
        for _, p in pairs(Mock.players) do
            if p.PlayerData.citizenid == cid then return p end
        end
    end,
}
QBCoreMock.Shared.Jobs = {}
QBCoreMock.Shared.Gangs = {}
Mock.rawExports = setmetatable({}, { __mode = 'k' })
exports = setmetatable({}, {
    __call = function(_, name, fn)
        Mock.exportsByResource['__self'] = Mock.exportsByResource['__self'] or {}
        Mock.exportsByResource['__self'][name] = fn
        Mock.rawExports[fn] = true
    end,
    __index = function(_, resource)
        local res = Mock.exportsByResource[resource]
        if not res then return nil end
        return setmetatable({}, { __index = function(_, fnName)
            local f = res[fnName]
            if not f then return nil end
            -- exports a resource registers itself (exports('Name', fn)) get no self argument, like FiveM;
            -- the hand-written mocks above take one.
            if Mock.rawExports[f] then return function(_, ...) return f(...) end end
            return function(_, ...) return f(_, ...) end
        end })
    end,
})

-- Exports registered by the resource under test, callable directly in specs.
function Mock.selfExport(name)
    return Mock.exportsByResource['__self'] and Mock.exportsByResource['__self'][name]
end
