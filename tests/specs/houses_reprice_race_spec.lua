-- pfm-houses: an agent's reprice cannot race a purchase (review money-2 / trust-4).
--   * the door purchase takes the house lock before its first wait and reads the price after it,
--     so a reprice sent during that wait is refused and the buyer pays the price they were shown;
--   * a purchase from a contract is refused when the price changed after the contract was shown;
--   * the reprice refuses owned houses and changes memory only when the guarded UPDATE changed the
--     one unowned row;
--   * the state sell-back pays from the price recorded at the purchase (door and agent sales), not
--     from the listing price, which an agent can change.
load_resource('tests/lua/ledger_env.lua')
local commands = {}
CancelEvent = CancelEvent or function() end
QBCoreMock.Commands.Add = function(name, _, _, _, fn) commands[name] = fn end
QBCoreMock.Player = QBCoreMock.Player or {}
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local DOOR = vector3(100.0, 200.0, 30.0)
local OFFICE = vector3(-700.0, 260.0, 83.0)
local houses, playerHouses, sales = {}, {}, {}
local duringOwnedCheck            -- run once inside the purchase's first database wait
local backfills = 0

FakeDB.extraPatterns = {
    { 'SELECT owned FROM houselocations WHERE name = ?', function(p)
        local hook = duringOwnedCheck
        duringOwnedCheck = nil
        if hook then hook() end
        local h = houses[p[1]]
        return h and { { owned = h.owned } } or {}
    end },
    { 'UPDATE houselocations SET owned = ?', function(p) houses[p[2]] = houses[p[2]] or {}; houses[p[2]].owned = p[1]; return 1 end },
    { 'UPDATE houselocations SET price = ?', function(p)
        local h = houses[p[2]]
        if h and h.owned ~= 1 then h.price = p[1] return 1 end
        return 0
    end },
    { 'INSERT INTO player_houses', function(p) playerHouses[p[1]] = { house = p[1], citizenid = p[3], keyholders = p[4], purchase_price = p[5] }; return 1 end },
    { 'SELECT purchase_price FROM player_houses', function(p) return playerHouses[p[1]] and playerHouses[p[1]].purchase_price or nil end },
    { 'UPDATE player_houses ph JOIN houselocations', function() backfills = backfills + 1 return 0 end },
    { 'DELETE FROM player_houses WHERE house = ?', function(p) playerHouses[p[1]] = nil; return 1 end },
    { 'UPDATE player_houses SET identifier', function(p)
        local row = playerHouses[p[4]]
        if row then row.citizenid = p[2] end
        return 1
    end },
    { 'SELECT items FROM inventories WHERE identifier = ?', function() return nil end },
    { 'INSERT IGNORE INTO pfm_house_sales', function(p) sales[#sales + 1] = { house = p[1], price = p[3] } return #sales end },
}

local handlers = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end,
    RegisterAppHandlers = function(_, id, map) handlers[id] = map return true end,
    Push = function() return true end,
    PushToJob = function() return 1 end,
}
Mock.exportsByResource['pf-government'] = {
    CalculateTax = function(_, amount, kind) return kind == 'property_transfer' and math.floor(amount * 5) / 100 or 0 end,
    CollectTaxAmount = function(_, amount) return amount end,
    RegisterProperty = function() return true end,
}

local AGENT, BUYER, FRIEND = 1, 2, 3
local HOUSE = 'grove1'
local function P(src) return Mock.players[src] end
local function bank(src) return P(src).PlayerData.money.bank end
local function setPrice(price, house) return handlers['realestate-agency'].setPrice(AGENT, { house = house or HOUSE, price = price }) end
local function view(src) Mock.fireNet('qb-houses:server:viewHouse', src, HOUSE) end
local function buy(src) Mock.fireNet('qb-houses:server:buyHouse', src, HOUSE) end
local function doorTotal(price) return price + price * 0.15 + price * 0.05 end   -- 5% broker, 10% bank, 5% tax

local function H(price, address) return { coords = { enter = { x = DOOR.x, y = DOOR.y, z = DOOR.z, h = 0.0 } }, price = price, adress = address, tier = 1, locked = true, garage = {}, owned = false } end

local function newPlayer(src, money, at)
    local p = Mock.newPlayer(src)
    p.PlayerData.license = 'license:' .. src
    p.PlayerData.money = { cash = 0, bank = money or 0 }
    p.PlayerData.metadata.inside = { apartment = {} }
    Mock.coords[src] = at or DOOR
    return p
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    houses = { grove1 = { owned = 0, price = 200000 }, vinewood1 = { owned = 0, price = 400000 } }
    playerHouses, sales, duringOwnedCheck, backfills = {}, {}, nil, 0
    LedgerEnv.load('pfm-houses', { 'pfm-houses/config.lua', 'pfm-houses/server/main.lua', 'pfm-houses/server/apps.lua' })
    MySQL.Sync = { fetchSingle = function(q, p) return MySQL.single.await(q, p) end }
    Config.MinZOffset = 0
    Config.Houses = { grove1 = H(200000, 'Grove Street 1'), vinewood1 = H(400000, 'Vinewood Hills 1') }
    FakeDB.society('realestate', 0)
    newPlayer(AGENT, 0, OFFICE).PlayerData.job = { name = 'realestate', label = 'Dynasty 8', onduty = true, grade = { level = 0 } }
    newPlayer(BUYER, 1000000)
    newPlayer(FRIEND, 1000000)
    PFHouses.Start()
    assert(PFHouses.dbReady, 'setup: migrations ran')
end

describe('a reprice during a door purchase', function()
    it('is refused while the purchase waits on the database, so the price paid and the listing stay the same', function()
        local res
        duringOwnedCheck = function() res = setPrice(100000000) end
        buy(BUYER)
        assert_true(res ~= nil, 'the reprice ran during the purchase')
        assert_false(res.ok, 'reprice during the purchase')
        assert_eq(res.error, 'not_for_sale')
        assert_eq(PFHouses.OwnerOf(HOUSE), 'CID2')
        assert_eq(bank(BUYER), 1000000 - doorTotal(200000))
        assert_eq(Config.Houses[HOUSE].price, 200000)
        assert_eq(houses.grove1.price, 200000)
        assert_false(PFHouses.Locked(HOUSE), 'the purchase released its lock')
    end)
    it('the state sell-back pays 70% of the price paid, whatever the listing price says later', function()
        buy(BUYER)
        assert_eq(playerHouses.grove1.purchase_price, 200000)
        Config.Houses[HOUSE].price = 100000000         -- the listing changed by any route
        local before = bank(BUYER)
        commands.sellhouse(BUYER, {})
        assert_eq(bank(BUYER) - before, 140000)
        assert_eq(PFHouses.OwnerOf(HOUSE), nil)
        assert_eq(LedgerEnv.paid('pfm-houses:sellback:')[1].amount, 140000)
    end)
    it('after a restart the recorded price is read from the database', function()
        buy(BUYER)
        -- a fresh copy of the resource: only the database remembers what was paid
        LedgerEnv.load('pfm-houses', { 'pfm-houses/config.lua', 'pfm-houses/server/main.lua', 'pfm-houses/server/apps.lua' })
        Config.MinZOffset = 0
        Config.Houses = { grove1 = H(5000000, 'Grove Street 1') }
        Config.Houses.grove1.owned = true
        PFHouses.Start()
        assert_eq(PFHouses.PricePaid(HOUSE), 200000)
        assert_eq(PFHouses.PricePaid('vinewood1'), nil)      -- nothing recorded
    end)
    it('a sale between players does not raise what the state pays back', function()
        buy(BUYER)
        Mock.coords[FRIEND] = DOOR
        commands.sellhouse(BUYER, { tostring(FRIEND), '900000' })
        Mock.fireNet('qb-houses:server:RespondHouseSale', FRIEND, true)
        assert_eq(PFHouses.OwnerOf(HOUSE), 'CID3')
        local before = bank(FRIEND)
        commands.sellhouse(FRIEND, {})
        assert_eq(bank(FRIEND) - before, 140000)       -- 70% of what the city was paid, not of $900k
    end)
end)

describe('the door contract', function()
    it('a purchase from a contract is refused when the price changed after it was shown', function()
        view(BUYER)
        assert_true(setPrice(600000).ok)                -- nobody is buying yet: the reprice goes through
        buy(BUYER)
        assert_eq(PFHouses.OwnerOf(HOUSE), nil)
        assert_eq(bank(BUYER), 1000000)
        assert_eq(FakeDB.bank_accounts.realestate.account_balance, 0)
        assert_eq(#LedgerEnv.paid('pfm-houses:buy:'), 0)
        assert_false(PFHouses.Locked(HOUSE))
        local resent = Mock.clientEventsNamed('qb-houses:client:setHouseConfig')
        assert_eq(resent[#resent].target, BUYER, 'the buyer is sent the house list again')
        -- a new look at the contract shows the new price, and buying from it works
        assert_true(setPrice(300000).ok)
        view(BUYER)
        buy(BUYER)
        assert_eq(PFHouses.OwnerOf(HOUSE), 'CID2')
        assert_eq(bank(BUYER), 1000000 - doorTotal(300000))
        assert_eq(playerHouses.grove1.purchase_price, 300000)
    end)
    it('a contract belongs to the house it was shown for, and a refused buy stays refused', function()
        view(BUYER)
        Mock.fireNet('qb-houses:server:buyHouse', BUYER, 'vinewood1')   -- another house: refused
        assert_eq(PFHouses.OwnerOf('vinewood1'), nil)
        assert_eq(bank(BUYER), 1000000)
        -- the price changes after the contract was shown: the first click and a second click
        -- (a double-click on the contract) are both refused
        assert_true(setPrice(600000).ok)
        buy(BUYER)
        buy(BUYER)
        assert_eq(PFHouses.OwnerOf(HOUSE), nil)
        assert_eq(bank(BUYER), 1000000, 'never charged a price the buyer was not shown')
        -- looking at the other house's contract, then buying it, works
        Mock.fireNet('qb-houses:server:viewHouse', BUYER, 'vinewood1')
        Mock.fireNet('qb-houses:server:buyHouse', BUYER, 'vinewood1')
        assert_eq(PFHouses.OwnerOf('vinewood1'), 'CID2')
        assert_eq(bank(BUYER), 1000000 - doorTotal(400000))
    end)
end)

describe('the purchase lock', function()
    it('is released on every refusal, and a lock held by another sale is left alone', function()
        P(BUYER).PlayerData.money.bank = 10
        buy(BUYER)
        assert_false(PFHouses.Locked(HOUSE), 'after not enough money')
        Config.Houses[HOUSE].price = 0
        buy(FRIEND)
        assert_false(PFHouses.Locked(HOUSE), 'after a house with no price')
        Config.Houses[HOUSE].price = 200000
        houses.grove1.owned = 1
        buy(FRIEND)
        assert_false(PFHouses.Locked(HOUSE), 'after an owned house')
        assert_eq(bank(FRIEND), 1000000)
        houses.grove1.owned = 0
        assert_true(PFHouses.Lock(HOUSE))              -- another sale in flight
        buy(FRIEND)
        assert_true(PFHouses.Locked(HOUSE), 'the other sale keeps its lock')
        assert_eq(bank(FRIEND), 1000000)
        PFHouses.Unlock(HOUSE)
        buy(FRIEND)
        assert_eq(PFHouses.OwnerOf(HOUSE), 'CID3')
    end)
end)

describe('the reprice', function()
    it('refuses a house marked owned even when its owner is not loaded, and leaves memory alone', function()
        Config.Houses[HOUSE].owned = true
        houses.grove1.owned = 1
        assert_eq(setPrice(100000000).error, 'not_for_sale')
        assert_eq(Config.Houses[HOUSE].price, 200000)
    end)
    it('changes memory only when the database changed the one unowned row', function()
        houses.grove1.owned = 1                          -- the database says sold, memory does not know
        local res = setPrice(100000000)
        assert_false(res.ok)
        assert_eq(Config.Houses[HOUSE].price, 200000)
        assert_false(PFHouses.Locked(HOUSE), 'the reprice released its lock')
        houses.grove1.owned = 0
        assert_true(setPrice(250000).ok)
        assert_eq(Config.Houses[HOUSE].price, 250000)
        assert_eq(houses.grove1.price, 250000)
        assert_true(setPrice(250000).ok, 'the same price again')
    end)
    it('is refused while a sale holds the lock', function()
        assert_true(PFHouses.Lock(HOUSE))
        assert_eq(setPrice(500000).error, 'not_for_sale')
        assert_true(PFHouses.Locked(HOUSE))
        PFHouses.Unlock(HOUSE)
    end)
end)

describe('an agent sale', function()
    it('records the price paid, and the sell-back pays from it', function()
        Mock.coords[BUYER] = OFFICE
        local offer = handlers['realestate-agency'].offer(AGENT, { house = HOUSE, target = BUYER })
        assert_true(offer.ok, tostring(offer.error))
        assert_true(PFHouses.AnswerAgentOffer(BUYER, offer.offer.id, true).ok)
        assert_eq(playerHouses.grove1.purchase_price, 200000)
        assert_eq(PFHouses.PricePaid(HOUSE), 200000)
        Config.Houses[HOUSE].price = 100000000
        Mock.coords[BUYER] = DOOR
        local before = bank(BUYER)
        commands.sellhouse(BUYER, {})
        assert_eq(bank(BUYER) - before, 140000)
    end)
end)

describe('the migration', function()
    it('adds the recorded price and fills it for houses owned before, once', function()
        assert_eq(backfills, 1)
        PFHouses.Start()                                 -- a restart: nothing runs twice
        assert_eq(backfills, 1)
    end)
end)
