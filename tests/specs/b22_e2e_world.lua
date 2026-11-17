-- Batch 22 (22A) end-to-end helper: loads several REAL resources into one Lua state the way FiveM
-- runs them, so a flow can cross resource boundaries without stubbing the resources it crosses.
-- Not a spec (no _spec suffix); the b22_e2e_* specs load it after the mocks and the database.
--
--   * each resource gets its own global environment (its own Config, PFPayout, module tables),
--     falling back to the shared mocks (natives, MySQL, json, Mock) for everything else;
--   * exports a resource registers land in Mock.exportsByResource[<name>]; a call from resource A to
--     resource B goes through Mock.cross (msgpack copies, funcrefs) with GetInvokingResource() = A;
--   * AddEventHandler keeps every handler of every resource (FiveM runs all of them), per resource,
--     so a restart drops the old ones; World.fireNet raises a net event for RegisterNetEvent and
--     AddEventHandler handlers alike;
--   * World.restart(name) is a resource restart: memory gone (a fresh environment), same database.
-- Only FiveM natives and the resources a flow does not load are stubbed, by the spec itself.

World = { res = {}, handlers = {}, net = {}, states = {} }

local function eventDispatcher(name)
    return function(...)
        local list = World.handlers[name]
        if not list then return end
        -- a copy: a handler may register or drop handlers while this runs
        local snapshot = {}
        for i, h in ipairs(list) do snapshot[i] = h end
        for _, h in ipairs(snapshot) do h.fn(...) end
    end
end

local function addHandler(store, resName, name, fn)
    store[name] = store[name] or {}
    table.insert(store[name], { res = resName, fn = fn })
    if store == World.handlers then Mock.eventHandlers[name] = eventDispatcher(name) end
end

--- Raises a net event as a client `src` would (every handler, net and local, of every resource).
function World.fireNet(name, src, ...)
    local list = {}
    for _, h in ipairs(World.net[name] or {}) do list[#list + 1] = h end
    for _, h in ipairs(World.handlers[name] or {}) do list[#list + 1] = h end
    assert(#list > 0, 'no handler for net event ' .. name)
    local args = Mock.pack({ n = select('#', ...), ... })
    for _, h in ipairs(list) do
        source = src
        local ok, err = pcall(h.fn, table.unpack(args, 1, args.n))
        source = nil
        if not ok then error(err, 2) end
    end
end

--- Calls `fn` with GetInvokingResource() = invoker (restored afterwards, also on an error).
function World.as(invoker, fn, ...)
    local saved = Mock.invokingResource
    Mock.invokingResource = invoker
    local res = table.pack(pcall(fn, ...))
    Mock.invokingResource = saved
    if not res[1] then error(res[2], 2) end
    return table.unpack(res, 2, res.n)
end

--- A call of export `fnName` of `target` made by resource `caller` (nil = a server console / test).
function World.call(caller, target, fnName, ...)
    local exp = Mock.exportsByResource[target]
    assert(exp and exp[fnName], ('no export %s.%s'):format(tostring(target), tostring(fnName)))
    local f = exp[fnName]
    local n, args = select('#', ...), { ... }
    return World.as(caller, function()
        if Mock.rawExports[f] then return Mock.cross(f, table.unpack(args, 1, n)) end
        return Mock.cross(function(...) return f(exp, ...) end, table.unpack(args, 1, n))
    end)
end

local function exportsFor(resName)
    return setmetatable({}, {
        __call = function(_, name, fn)
            local t = Mock.exportsByResource[resName]
            t[name] = fn
            Mock.rawExports[fn] = true
        end,
        __index = function(_, target)
            local exp = Mock.exportsByResource[target]
            if not exp or World.states[target] == 'stopped' then return nil end
            return setmetatable({}, { __index = function(_, fnName)
                local f = exp[fnName]
                if not f then return nil end
                return function(self, ...)
                    local n, args = select('#', ...), { ... }
                    return World.as(resName, function()
                        if Mock.rawExports[f] then return Mock.cross(f, table.unpack(args, 1, n)) end
                        if Mock.passThrough[f] then return f(self, table.unpack(args, 1, n)) end
                        return Mock.cross(function(...) return f(exp, ...) end, table.unpack(args, 1, n))
                    end)
                end
            end })
        end,
    })
end

local function newEnv(resName)
    local env = setmetatable({}, { __index = _G })
    env.GetCurrentResourceName = function() return resName end
    env.exports = exportsFor(resName)
    env.AddEventHandler = function(name, fn) addHandler(World.handlers, resName, name, fn) end
    env.RegisterNetEvent = function(name, fn) if fn then addHandler(World.net, resName, name, fn) end end
    env.RegisterServerEvent = env.RegisterNetEvent
    -- inside a handler, GetInvokingResource() names the resource that raised the event (as in FiveM)
    env.TriggerEvent = function(name, ...) return World.as(resName, TriggerEvent, name, ...) end
    return env
end

local function loadInto(env, file)
    local path = file:gsub('^@', '')
    local src = __readfile(path)
    local chunk, err = load(src, '@' .. path, 't', env)
    if not chunk then error(err, 2) end
    return chunk()
end

--- Starts resource `name` from `files` (paths as load_resource takes them; '@res/file.lua' as an
--- fxmanifest include). opts.boot(env) runs after the files, as the resource's start thread would.
--- opts.before(env) runs before the files (natives or helpers the resource reads at load time).
function World.start(name, files, opts)
    opts = opts or {}
    local r = World.res[name] or { name = name }
    r.files, r.opts = files, opts
    World.res[name] = r
    World.states[name] = 'started'
    Mock.exportsByResource[name] = {}
    r.env = newEnv(name)
    if opts.before then opts.before(r.env) end
    for _, f in ipairs(files) do loadInto(r.env, f) end
    if opts.boot then opts.boot(r.env) end
    return r.env
end

--- Stops a resource: its handlers and exports are gone (onResourceStop runs first, as in FiveM).
function World.stop(name)
    local stopHandlers = World.handlers['onResourceStop']
    if stopHandlers then
        for _, h in ipairs(stopHandlers) do
            if h.res == name then pcall(h.fn, name) end
        end
    end
    for _, store in ipairs({ World.handlers, World.net }) do
        for ev, list in pairs(store) do
            for i = #list, 1, -1 do if list[i].res == name then table.remove(list, i) end end
        end
    end
    Mock.exportsByResource[name] = nil
    World.states[name] = 'stopped'
end

--- A resource restart: memory is lost (a fresh environment), the database stays.
function World.restart(name)
    local r = assert(World.res[name], 'not started: ' .. tostring(name))
    World.stop(name)
    return World.start(name, r.files, r.opts)
end

--- The environment (globals) of a started resource.
function World.env(name) return World.res[name] and World.res[name].env end

--- GetResourceState for the loaded world: started resources, hand-written mocks, else missing.
function World.installResourceState(extra)
    extra = extra or {}
    GetResourceState = function(name)
        if extra[name] ~= nil then return extra[name] end
        if World.states[name] then return World.states[name] end
        if Mock.exportsByResource[name] then return 'started' end
        return 'missing'
    end
end

--- The real bank: pfm-core's migrations and pfm-banking's ledger on the real database.
function World.startBank()
    RealDB.exec('pfm-core/qbcore.sql')
    RealDB.exec('pfm-banking/banking.sql')
    load_resource('pfm-core/server/migrations.lua')
    Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
    local env = World.start('pfm-banking', { 'pfm-banking/config.lua', 'pfm-banking/server_ledger.lua', 'pfm-banking/server.lua' })
    assert(env.PFLedger.Start(), 'ledger start')
    return env
end

--- Ledger helpers on the real tables.
function World.tx(key) return MySQL.single.await('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { key }) end
function World.txLike(pattern)
    return MySQL.query.await("SELECT * FROM pf_transactions WHERE idempotency_key LIKE ? AND state = 'completed' ORDER BY id", { pattern }) or {}
end
function World.society(name)
    return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0
end
function World.scalar(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
function World.one(sql, p) return MySQL.single.await(sql, p or {}) end
function World.rows(sql, p) return MySQL.query.await(sql, p or {}) or {} end

--- Server-side inventory with real semantics (pfm-inventory is not part of these flows): player
--- pockets (PlayerData.items, as pfm-core keeps them) and named stashes, counted per item.
function World.inventory()
    local Inv = { stashes = {} }
    local function list(id)
        if type(id) == 'number' then
            local P = Mock.players[id]
            if not P then return nil end
            P.PlayerData.items = P.PlayerData.items or {}
            return P.PlayerData.items
        end
        Inv.stashes[id] = Inv.stashes[id] or {}
        return Inv.stashes[id]
    end
    local function compact(items)
        local out = {}
        for _, it in pairs(items) do if it and (it.amount or 0) > 0 then out[#out + 1] = it end end
        for i = #items, 1, -1 do items[i] = nil end
        for k in pairs(items) do items[k] = nil end
        for i, it in ipairs(out) do it.slot = i items[i] = it end
    end
    function Inv.count(id, name)
        local n = 0
        for _, it in pairs(list(id) or {}) do if it.name == name then n = n + (it.amount or 0) end end
        return n
    end
    function Inv.total(id)
        local n = 0
        for _, it in pairs(list(id) or {}) do n = n + (it.amount or 0) end
        return n
    end
    function Inv.add(id, name, amount, info)
        local items = list(id)
        if not items then return false end
        items[#items + 1] = { name = name, amount = amount or 1, info = info, slot = #items + 1, type = 'item' }
        compact(items)
        return true
    end
    function Inv.remove(id, name, amount)
        local items = list(id)
        amount = amount or 1
        if not items or Inv.count(id, name) < amount then return false end
        for _, it in ipairs(items) do
            if amount <= 0 then break end
            if it.name == name then
                local take = math.min(it.amount, amount)
                it.amount, amount = it.amount - take, amount - take
            end
        end
        compact(items)
        return true
    end
    Mock.exportsByResource['pfm-inventory'] = {
        CreateInventory = function(_, id) list(id) return true end,
        GetInventory = function(_, id)
            local items = list(id)
            if not items then return nil end
            return { items = items }
        end,
        GetItemsByName = function(_, id, name)
            local out = {}
            for _, it in ipairs(list(id) or {}) do if it.name == name then out[#out + 1] = it end end
            return out
        end,
        GetItemCount = function(_, id, name) return Inv.count(id, name) end,
        HasItem = function(_, id, name, amount) return Inv.count(id, name) >= (amount or 1) end,
        SaveStash = function() end,
        ClearStash = function(_, id) Inv.stashes[id] = {} end,
        ClearInventory = function(_, src) local items = list(src) if items then for k in pairs(items) do items[k] = nil end end end,
        CanAddItem = function() return true end,
        AddItem = function(_, id, name, amount, slot, info) return Inv.add(id, name, amount, info) end,
        RemoveItem = function(_, id, name, amount) return Inv.remove(id, name, amount) end,
        OpenInventory = function() end,
    }
    return Inv
end

--- `pending` for a flow that found a real defect: the flow is reported as skipped (it neither passes
--- nor fails the run) with the reason, so the lead can assign the fix.
World.pendingList = {}
function pending(name, reason)
    World.pendingList[#World.pendingList + 1] = name .. ' -- ' .. reason
    print('PENDING  ' .. name .. ' -- ' .. reason)
end
