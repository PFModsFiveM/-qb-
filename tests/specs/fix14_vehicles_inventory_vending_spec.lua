-- pfm-inventory vending machines (fix14 VEND-1). The machine position pfm-target sends is taken only
-- within reach of the player's own (server) position, the one vending shop has no position of its
-- own, and a purchase needs the player still where they stood when they opened a machine. The
-- client's position used to become the shared shop's coords: it opened anywhere, every open moved it
-- (players at a real machine elsewhere were then refused), and a malformed position broke every
-- vending purchase until someone opened again.
load_resource('tests/lua/ledger_env.lua')
QBCoreMock.Shared.Items.kurkakola = { name = 'kurkakola', label = 'Cola', weight = 500, type = 'item', unique = false, useable = true, image = 'cola.png' }
LedgerEnv.load('pfm-inventory', {
    'pfm-inventory/config/config.lua', 'pfm-inventory/config/freshness.lua', 'pfm-inventory/server/freshness.lua',
    'pfm-inventory/server/main.lua', 'pfm-inventory/server/functions.lua', 'pfm-inventory/server/hooks.lua',
})

local A, B = 1, 2
local MACHINE_A = vector3(100, 100, 30)
local MACHINE_B = vector3(-800, 400, 20)
local BUY = 'qb-inventory:server:attemptPurchase'

local function open(src, coords) Mock.fireNet('qb-inventory:server:openVending', src, { coords = coords }) end
local function opened(src)
    for _, e in ipairs(Mock.clientEventsNamed('qb-inventory:client:openInventory')) do
        if e.target == src and e.args[2] and e.args[2].name == 'shop-vending' then return e.args[2] end
    end
end
local function buy(src)
    local slot = 1
    for i, it in pairs(RegisteredShops.vending and RegisteredShops.vending.items or {}) do if it.name == 'water_bottle' then slot = i end end
    return Mock.callCallback(BUY, src, { shop = 'shop-vending', amount = 1, item = { name = 'water_bottle', slot = slot } })
end
local function cash(src) return Mock.players[src].PlayerData.money.cash end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    for _, src in ipairs({ A, B }) do
        Mock.newPlayer(src).PlayerData.money.cash = 100
        Player(src).state.inv_busy = false
    end
    -- each player stands next to a machine
    Mock.coords[A] = vector3(MACHINE_A.x + 1, MACHINE_A.y, MACHINE_A.z)
    Mock.coords[B] = vector3(MACHINE_B.x, MACHINE_B.y + 1, MACHINE_B.z)
    RegisteredShops.vending = nil
end

describe('fix14 VEND-1: opening a vending machine', function()
    it('opens for the machine the player stands at, and they can buy there', function()
        open(A, MACHINE_A)
        assert_true(opened(A) ~= nil)
        assert_eq(RegisteredShops.vending.coords, nil, 'the shop takes no position from a client')
        assert_true(buy(A))
        assert_true(cash(A) < 100, 'paid')
    end)

    it('a "machine" away from the player does not open', function()
        open(A, vector3(MACHINE_A.x + 50, MACHINE_A.y, MACHINE_A.z))
        assert_eq(opened(A), nil)
        assert_false(buy(A))
        assert_eq(cash(A), 100)
    end)

    it('another player opening a machine across the city does not stop my purchases', function()
        open(A, MACHINE_A)
        open(B, MACHINE_B)
        assert_true(opened(B) ~= nil)
        assert_true(buy(A), 'A still buys at their machine')
        assert_true(buy(B))
    end)

    it('no purchase without opening a machine, after walking away from it, or after closing it', function()
        assert_false(buy(A), 'never opened one')
        open(A, MACHINE_A)
        Mock.coords[A] = vector3(MACHINE_A.x + 20, MACHINE_A.y, MACHINE_A.z)
        assert_false(buy(A), 'walked away')
        Mock.coords[A] = vector3(MACHINE_A.x + 1, MACHINE_A.y, MACHINE_A.z)
        assert_true(buy(A), 'back at it')
        Mock.fireNet('qb-inventory:server:closeInventory', A, 'shop-vending')
        assert_false(buy(A), 'closed')
        assert_eq(cash(A) > 90, true)
    end)

    it('a player who left is forgotten', function()
        open(A, MACHINE_A)
        Mock.fireEvent('playerDropped', A)
        Mock.newPlayer(A).PlayerData.money.cash = 100
        assert_false(buy(A))
    end)

    it('bad payloads open nothing and do not break vending for anyone', function()
        open(B, MACHINE_B)
        Mock.fireNet('qb-inventory:server:openVending', A, nil)
        Mock.fireNet('qb-inventory:server:openVending', A, 'x')
        open(A, { x = 'a', y = 1, z = 1 })
        open(A, 'nope')
        open(A, { x = 0 / 0, y = MACHINE_A.y, z = MACHINE_A.z })
        open(A, { x = math.huge, y = MACHINE_A.y, z = MACHINE_A.z })
        assert_eq(opened(A), nil)
        assert_true(buy(B), 'B buys as before')
    end)
end)
