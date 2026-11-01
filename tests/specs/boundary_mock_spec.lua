-- The test mocks emulate FiveM's resource boundary (msgpack): what crosses an export, a function
-- reference, the QBCore object, a server callback, TriggerEvent or TriggerClientEvent is a copy, and
-- a function arrives as a callable table (funcref) that cannot be indexed. If this spec fails, the
-- other specs no longer catch code that only works when both sides share Lua values.
load_resource('tests/lua/fivem_mocks.lua')

local got = {}
Mock.exportsByResource['x-hand'] = {
    Take = function(self, fn, t)
        got.self, got.fn, got.t = self, fn, t
        t.changed = true
        return t, fn
    end,
}
-- an export registered by resource code (exports('Name', fn)) gets no self argument
exports('Keep', function(t, fn) got.kept, got.keptFn = t, fn return t end)
Mock.exportsByResource['x-raw'] = Mock.exportsByResource['__self']

BeforeEach = function()
    Mock.reset()
    got = {}
end

describe('the export boundary in the mocks', function()
    it('copies tables both ways: a change on one side never reaches the other', function()
        local mine = { a = 1, nested = { b = 2 } }
        local back = exports['x-hand']:Take(print, mine)
        assert_eq(mine.changed, nil, 'the callee changed its copy only')
        assert_true(got.t ~= mine)
        assert_true(back ~= got.t, 'the result is a copy again')
        assert_eq(back.changed, true)
        back.nested.b = 9
        assert_eq(mine.nested.b, 2)
        local kept = exports['x-raw']:Keep(mine)
        assert_true(got.kept ~= mine and kept ~= mine and kept ~= got.kept)
    end)

    it('a function arrives as a funcref: callable, type table, not indexable', function()
        local calls = 0
        local _, fnBack = exports['x-raw']:Keep({}, function(x) calls = calls + 1 return { x = x } end)
        local ref = got.keptFn
        assert_eq(type(ref), 'table')
        assert_eq(type(rawget(ref, '__cfx_functionReference')), 'string')
        assert_true(Mock.callable(ref))
        assert_eq(ref(5).x, 5)
        assert_eq(calls, 1)
        local ok, err = pcall(function() return ref.anything end)
        assert_false(ok)
        assert_true(tostring(err):find('Cannot index a funcref', 1, true) ~= nil, tostring(err))
        -- ipairs/pairs-style access over a funcref errors too (a function given where a list was expected)
        assert_false(pcall(function() for _ in ipairs(ref) do end end))
        assert_eq(fnBack, nil, 'Keep returned only the table')
    end)

    it('functions nested in tables become funcrefs, and a funcref passed on still calls the function', function()
        local inner = function() return 'hi' end
        exports['x-raw']:Keep({ handlers = { ping = inner } })
        local h = got.kept.handlers.ping
        assert_true(type(h) == 'table' and Mock.callable(h))
        assert_eq(h(), 'hi')
        assert_eq(Mock.funcrefTarget(h), inner)
        local _, again = exports['x-hand']:Take(h, {})
        assert_true(again ~= h, 'a new reference each time it crosses')
        assert_eq(again(), 'hi')
    end)

    it('a table that contains itself cannot cross', function()
        local t = {}
        t.self = t
        local ok, err = pcall(function() return exports['x-raw']:Keep(t) end)
        assert_false(ok)
        assert_true(tostring(err):find('circular', 1, true) ~= nil, tostring(err))
        -- the same table twice is fine: it arrives as two tables
        local shared = { v = 1 }
        exports['x-raw']:Keep({ a = shared, b = shared })
        assert_true(got.kept.a ~= got.kept.b)
        assert_eq(got.kept.b.v, 1)
    end)

    it('metatables are dropped, vectors survive', function()
        local proxy = setmetatable({}, { __index = function() return 'virtual' end })
        exports['x-raw']:Keep({ p = proxy, v = vector3(1, 2, 3) })
        assert_eq(got.kept.p.anything, nil)
        assert_eq(#(got.kept.v - vector3(1, 2, 0)), 3)
    end)

    it('the QBCore object is a copy whose functions are funcrefs; a player from it is a snapshot', function()
        local QB = exports['pfm-core']:GetCoreObject()
        assert_eq(type(QB.Functions.GetPlayer), 'table')
        assert_true(Mock.callable(QB.Functions.GetPlayer))
        local p = Mock.newPlayer(7)
        local copy = QB.Functions.GetPlayer(7)
        assert_true(copy ~= p)
        assert_true(Mock.callable(copy.Functions.AddMoney))
        copy.Functions.AddMoney('bank', 50)
        assert_eq(p.PlayerData.money.bank, 50, 'the method changed the live player')
        assert_eq(copy.PlayerData.money.bank, 0, 'the snapshot keeps what it had')
        -- a resource wrapping one of its QBCore functions changes its own copy only
        QB.Functions.GetPlayer = function() return nil end
        assert_true(exports['pfm-core']:GetCoreObject().Functions.GetPlayer(7) ~= nil)
    end)

    it('a server callback gets cb as a funcref, and a callback registered through QBCore arrives as one', function()
        local QB = exports['pfm-core']:GetCoreObject()
        local seenCb
        QB.Functions.CreateCallback('x:cb', function(src, cb, data)
            seenCb = cb
            data.touched = true
            cb({ src = src, n = data.n })
        end)
        assert_true(Mock.isFuncref(Mock.callbacks['x:cb']))
        local payload = { n = 3 }
        local res = Mock.callCallback('x:cb', 4, payload)
        assert_true(Mock.isFuncref(seenCb))
        assert_eq(res.src, 4)
        assert_eq(res.n, 3)
        assert_eq(payload.touched, nil)
    end)

    it('TriggerEvent hands handlers copies; TriggerClientEvent records what was sent', function()
        local seen
        AddEventHandler('x:local', function(t, fn) seen = { t = t, fn = fn } t.x = 2 end)
        local mine = { x = 1 }
        TriggerEvent('x:local', mine, function() return 1 end)
        assert_eq(mine.x, 1)
        assert_true(Mock.isFuncref(seen.fn))
        local msg = { text = 'before' }
        TriggerClientEvent('x:client', 1, msg)
        msg.text = 'after'
        assert_eq(Mock.clientEventsNamed('x:client')[1].args[1].text, 'before')
    end)
end)
