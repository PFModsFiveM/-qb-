-- pfm-houses: purchases, sales and furniture on the ledger; furniture, locks and raids checked by the server.
load_resource('tests/lua/ledger_env.lua')

local commands = {}
CancelEvent = CancelEvent or function() end
QBCoreMock.Commands.Add = function(name, _, _, _, fn) commands[name] = fn end
QBCoreMock.Player = QBCoreMock.Player or {}

local DOOR = vector3(100.0, 200.0, 30.0)
local HOUSE, houseNo = nil, 0  -- a fresh house per test (purchased furniture is remembered per house)
local houses = {}          -- houselocations: [name] = { owned = 0|1 }
local playerHouses = {}    -- player_houses: [house] = { decorations = json }

FakeDB.extraPatterns = {
    { 'SELECT owned FROM houselocations WHERE name = ?', function(p) local h = houses[p[1]]; return h and { { owned = h.owned } } or {} end },
    { 'UPDATE houselocations SET owned = ?', function(p) houses[p[2]] = houses[p[2]] or {}; houses[p[2]].owned = p[1]; return 1 end },
    { 'INSERT INTO player_houses', function(p) playerHouses[p[1]] = { decorations = '[]' }; return 1 end },
    { 'UPDATE player_houses SET identifier', function() return 1 end },
    { 'UPDATE player_houses SET decorations = ? WHERE house = ?', function(p) playerHouses[p[2]].decorations = p[1]; return 1 end },
    { 'SELECT decorations FROM player_houses WHERE house = ?', function(p) return playerHouses[p[1]] and playerHouses[p[1]].decorations end },
    { 'DELETE FROM player_houses WHERE house = ?', function(p) playerHouses[p[1]] = nil; return 1 end },
    { 'SELECT items FROM inventories WHERE identifier = ?', function() return nil end },
}

LedgerEnv.load('pfm-houses', { 'pfm-houses/config.lua', 'pfm-houses/server/main.lua' })

local OWNER, BUYER, STRANGER, COP = 1, 2, 3, 4
local function P(src) return Mock.players[src] end
local function bank(src) return P(src).PlayerData.money.bank end

local function newPlayer(src, money)
    local p = Mock.newPlayer(src)
    p.PlayerData.license = 'license:' .. src
    p.PlayerData.money = { cash = 0, bank = money or 0 }
    Mock.coords[src] = DOOR
    return p
end

local function ownHouse(src)
    Mock.fireNet('qb-houses:server:buyHouse', src, HOUSE)
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    houseNo = houseNo + 1
    HOUSE = 'testhouse' .. houseNo
    houses, playerHouses = { [HOUSE] = { owned = 0 } }, {}
    Config.MinZOffset = 0
    Config.Houses = { [HOUSE] = { coords = { enter = { x = DOOR.x, y = DOOR.y, z = DOOR.z, h = 0.0 } }, price = 100000, adress = 'Test Street 1', tier = 1, locked = true } }
    newPlayer(OWNER, 500000)
    newPlayer(BUYER, 500000)
    newPlayer(STRANGER, 500000)
    local cop = newPlayer(COP, 0)
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
end

describe('buying a house', function()
    it('takes the money first, through the ledger, and only once', function()
        ownHouse(OWNER)
        local paid = 500000 - bank(OWNER)
        assert_true(paid > 100000)                     -- price + broker + bank fees + tax
        assert_eq(houses[HOUSE].owned, 1)
        local charges = 0
        for _, row in ipairs(LedgerEnv.paid('pfm-houses:buy:')) do
            if tostring(row.idempotency_key):match(':bank$') then charges = charges + 1 end
        end
        assert_eq(charges, 1)
        ownHouse(STRANGER)                             -- already owned
        assert_eq(bank(STRANGER), 500000)
    end)
    it('a player who cannot pay does not get the house', function()
        P(OWNER).PlayerData.money.bank = 10
        ownHouse(OWNER)
        assert_eq(houses[HOUSE].owned, 0)
        assert_eq(bank(OWNER), 10)
    end)
    it('needs the buyer at the door and a real house', function()
        Mock.coords[OWNER] = vector3(0, 0, 0)
        ownHouse(OWNER)
        Mock.fireNet('qb-houses:server:buyHouse', BUYER, 'no-such-house')
        assert_eq(houses[HOUSE].owned, 0)
        assert_eq(bank(OWNER), 500000)
    end)
end)

describe('selling a house to another player', function()
    it('charges the buyer price + tax once and pays the seller once', function()
        ownHouse(OWNER)
        local sellerBefore = bank(OWNER)
        commands.sellhouse(OWNER, { tostring(BUYER), '50000' })
        Mock.fireNet('qb-houses:server:RespondHouseSale', BUYER, true)
        Mock.fireNet('qb-houses:server:RespondHouseSale', BUYER, true) -- a repeated accept
        assert_eq(bank(OWNER), sellerBefore + 50000)
        -- pf-government is not answering in tests, so the tax comes back to the buyer
        assert_eq(bank(BUYER), 500000 - 50000)
        assert_eq(#LedgerEnv.paid('pfm-houses:sale:'), 3) -- charge, seller, tax refund
        -- the buyer owns it now: the old owner can no longer sell it
        commands.sellhouse(OWNER, {})
        assert_eq(bank(OWNER), sellerBefore + 50000)
    end)
    it('a buyer who cannot pay gets nothing and pays nothing', function()
        ownHouse(OWNER)
        local sellerBefore = bank(OWNER)
        P(BUYER).PlayerData.money.bank = 100
        commands.sellhouse(OWNER, { tostring(BUYER), '50000' })
        Mock.fireNet('qb-houses:server:RespondHouseSale', BUYER, true)
        assert_eq(bank(OWNER), sellerBefore)
        assert_eq(bank(BUYER), 100)
    end)
    it('selling back to the state pays once', function()
        ownHouse(OWNER)
        local before = bank(OWNER)
        commands.sellhouse(OWNER, {})
        commands.sellhouse(OWNER, {})
        assert_eq(bank(OWNER), before + math.floor(100000 * Config.HouseSellBackPercent / 100))
        assert_eq(houses[HOUSE].owned, 0)
    end)
end)

describe('furniture', function()
    local MODEL = 'miss_rub_couch_01' -- $300 in Config.Furniture
    local function save(src, list) Mock.fireNet('qb-houses:server:savedecorations', src, HOUSE, list) end
    local function couch(x) return { hashname = MODEL, x = DOOR.x + (x or 0), y = DOOR.y, z = DOOR.z, rotx = 0, roty = 0, rotz = 0 } end
    local function saved() return json.decode(playerHouses[HOUSE].decorations) end

    it('is priced by the server; a client price is not accepted', function()
        ownHouse(OWNER)
        local before = bank(OWNER)
        local ok = Mock.callCallback('qb-houses:server:buyFurniture', OWNER, 0)  -- the old call sent a price
        assert_eq(ok, false)
        ok = Mock.callCallback('qb-houses:server:buyFurniture', OWNER, MODEL, HOUSE)
        assert_eq(ok, true)
        assert_eq(bank(OWNER), before - 300)
    end)
    it('only key holders buy for a house', function()
        ownHouse(OWNER)
        assert_eq(Mock.callCallback('qb-houses:server:buyFurniture', STRANGER, MODEL, HOUSE), false)
        assert_eq(bank(STRANGER), 500000)
    end)
    it('a house can only show furniture it bought', function()
        ownHouse(OWNER)
        save(OWNER, { couch() })                                  -- not bought
        assert_eq(#saved(), 0)
        Mock.callCallback('qb-houses:server:buyFurniture', OWNER, MODEL, HOUSE)
        save(OWNER, { couch(), couch(1) })                        -- two placed, one bought
        assert_eq(#saved(), 0)
        save(OWNER, { couch() })
        assert_eq(#saved(), 1)
        save(OWNER, { couch(2) })                                 -- moving it is fine
        assert_eq(saved()[1].x, DOOR.x + 2)
        save(OWNER, { couch(), couch(1) })                        -- the credit was used up
        assert_eq(#saved(), 1)
    end)
    it('strangers, unknown models and far-away objects are refused', function()
        ownHouse(OWNER)
        Mock.callCallback('qb-houses:server:buyFurniture', OWNER, MODEL, HOUSE)
        save(STRANGER, { couch() })
        assert_eq(#saved(), 0)
        save(OWNER, { { hashname = 'prop_big_crash_model', x = DOOR.x, y = DOOR.y, z = DOOR.z } })
        assert_eq(#saved(), 0)
        save(OWNER, { couch(500) })                               -- outside the house: dropped
        assert_eq(#saved(), 0)
    end)
end)

describe('locks and raids', function()
    local function locked() return Config.Houses[HOUSE].locked end
    it('a stranger cannot unlock a house', function()
        ownHouse(OWNER)
        Mock.fireNet('qb-houses:server:lockHouse', STRANGER, false, HOUSE)
        assert_eq(locked(), true)
        assert_eq(#Mock.clientEventsNamed('qb-houses:client:lockHouse'), 0) -- nothing sent to players
    end)
    it('the owner at the door can', function()
        ownHouse(OWNER)
        Mock.fireNet('qb-houses:server:lockHouse', OWNER, false, HOUSE)
        assert_eq(locked(), false)
        Mock.coords[OWNER] = vector3(0, 0, 0)
        Mock.fireNet('qb-houses:server:lockHouse', OWNER, true, HOUSE)
        assert_eq(locked(), false)                               -- not from afar
    end)
    it('only on-duty police at the door may ram', function()
        ownHouse(OWNER)
        Mock.fireNet('qb-houses:server:SetRamState', STRANGER, true, HOUSE)
        assert_true(not Config.Houses[HOUSE].IsRaming)
        Mock.fireNet('qb-houses:server:SetRamState', COP, true, HOUSE)
        assert_eq(Config.Houses[HOUSE].IsRaming, true)
        assert_eq(#Mock.clientEventsNamed('qb-houses:client:SetRamState'), 1)
        Mock.fireNet('qb-houses:server:lockHouse', COP, false, HOUSE)
        assert_eq(locked(), false)
    end)
end)
