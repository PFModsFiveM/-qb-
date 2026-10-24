-- oxmysql-shaped MySQL global backed by a real database (tests/realdb/run.js provides __sql).
-- Load after tests/lua/fivem_mocks.lua; it replaces the mock MySQL.
local function call(kind, query, params, cb)
    if type(params) == 'function' then cb, params = params, nil end
    local result = __sql(kind, query, params)
    if cb then cb(result) end
    return result
end

local function api(kind)
    return setmetatable({
        await = function(query, params) return call(kind, query, params) end,
    }, {
        __call = function(_, query, params, cb) return call(kind, query, params, cb) end,
    })
end

MySQL = {
    query = api('query'),
    single = api('single'),
    scalar = api('scalar'),
    insert = api('insert'),
    update = api('update'),
    rawExecute = api('query'),
    prepare = api('query'),
    ready = function(fn) fn() end,
}

RealDB = {
    exec = function(file) __sqlfile(file) end,
    reconnect = function() return __sqlreconnect() end,
    name = __TEST_DATABASE,
}
