-- pfm-houses on the real database and ledger (review money-2 / trust-4): the price paid for a house
-- is recorded in player_houses.purchase_price (migration v2, filled for houses owned before it with
-- their listing price, rerun-safe); the state sell-back pays from it; an agent's reprice cannot run
-- during a door purchase, changes memory only when its guarded UPDATE changed the one unowned row,
-- and a buyer is never charged more than the contract they were shown.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-government'] = 'missing', ['pf-services'] = 'missing', ['pfm-apartments'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
CancelEvent = CancelEvent or function() end
local commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) commands[name] = fn end
QBCoreMock.Player = QBCoreMock.Player or {}

local DOOR = { x = 100.0, y = 200.0, z = 30.0 }
local COORDS = ('{"enter":{"x":%.1f,"y":%.1f,"z":%.1f,"h":0.0},"cam":{"x":%.1f,"y":%.1f,"z":%.1f,"h":0.0,"yaw":-10.0}}'):format(DOOR.x, DOOR.y, DOOR.z, DOOR.x, DOOR.y, DOOR.z)

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-houses/qb-houses.sql')
MySQL.query.await('CREATE TABLE IF NOT EXISTS inventories (identifier VARCHAR(100) PRIMARY KEY, items LONGTEXT)')

local function listing(name, price, owned)
    MySQL.insert.await("INSERT INTO houselocations (name, label, coords, owned, price, tier, garage) VALUES (?, ?, ?, ?, ?, 1, '{}')", { name, name, COORDS, owned and 1 or 0, price })
end
-- a house bought before the price paid was recorded (player_houses has no purchase_price yet)
listing('oldhouse1', 150000, true)
MySQL.insert.await([[INSERT INTO player_houses (house, identifier, citizenid, keyholders) VALUES ('oldhouse1', 'license:9', 'OLD1', '["OLD1"]')]])
listing('racehouse', 200000, false)
listing('ghosthouse', 200000, false)
listing('quotehouse', 200000, false)

function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')
assert(PFLedger.EnsureSociety('realestate', 'job'), 'agency account')
local handlers = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end,
    RegisterAppHandlers = function(_, id, map) handlers[id] = map return true end,
    Push = function() return true end, PushToJob = function() return 0 end,
}

-- the resource's threads are kept, so the start (houses and owners read from the database) can be run
local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end
Citizen.CreateThread = CreateThread
function GetCurrentResourceName() return 'pfm-houses' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-houses/config.lua')
load_resource('pfm-houses/server/main.lua')
load_resource('pfm-houses/server/apps.lua')
MySQL.Sync = { fetchSingle = function(q, p) return MySQL.single.await(q, p) end }
Config.MinZOffset = 0
PFHouses.Start()
assert(PFHouses.dbReady, 'pfm-houses migrations')
threads[1]()                                     -- houselocations into Config.Houses
do                                               -- player_houses into memory (the loop stops at its first Wait)
    local wait = Wait
    Wait = function() error('stop', 0) end
    pcall(threads[2])
    Wait = wait
end

-- a reprice can be run inside the purchase's first wait on the database
local queryAwait = MySQL.query.await
local duringOwnedCheck
MySQL.query.await = function(q, p)
    if duringOwnedCheck and q:find('SELECT owned FROM houselocations', 1, true) then
        local hook = duringOwnedCheck
        duringOwnedCheck = nil
        hook()
    end
    return queryAwait(q, p)
end

local AGENT, BUYER, OLD = 1, 2, 9
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function setPrice(house, price) return handlers['realestate-agency'].setPrice(AGENT, { house = house, price = price }) end
local function dbPrice(house) return tonumber(MySQL.scalar.await('SELECT price FROM houselocations WHERE name = ?', { house })) end
local function paidRow(house) return tonumber(MySQL.scalar.await('SELECT purchase_price FROM player_houses WHERE house = ?', { house })) end
local function completed(pattern) return MySQL.query.await("SELECT amount FROM pf_transactions WHERE idempotency_key LIKE ? AND state = 'completed'", { pattern }) or {} end
local function doorTotal(price) return price * 1.15 + price * 0.06 end   -- 5% broker, 10% bank, 6% tax (refunded: no government)

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    local agent = Mock.newPlayer(AGENT, 'PAGENT')
    agent.PlayerData.license = 'license:1'
    agent.PlayerData.job = { name = 'realestate', onduty = true, grade = { level = 0 } }
    local buyer = Mock.newPlayer(BUYER, 'PBUYER')
    buyer.PlayerData.money = { cash = 0, bank = 1000000 }
    buyer.PlayerData.license = 'license:2'
    local old = Mock.newPlayer(OLD, 'OLD1')
    old.PlayerData.money = { cash = 0, bank = 0 }
    old.PlayerData.license = 'license:9'
    Mock.coords[AGENT] = vector3(-700.0, 260.0, 83.0)
    Mock.coords[BUYER] = vector3(DOOR.x, DOOR.y, DOOR.z)
    Mock.coords[OLD] = vector3(DOOR.x, DOOR.y, DOOR.z)
end

describe('the price paid (migration v2)', function()
    it('adds purchase_price and fills it for a house owned before, with its listing price', function()
        assert_true(MigrationColumnExists('player_houses', 'purchase_price'))
        assert_eq(paidRow('oldhouse1'), 150000)
        assert_eq(PFHouses.OwnerOf('oldhouse1'), 'OLD1')
        assert_eq(PFHouses.PricePaid('oldhouse1'), 150000)
    end)
    it('is safe to run again: a recorded price is kept, a missing one is filled', function()
        listing('oldhouse2', 80000, true)
        MySQL.insert.await([[INSERT INTO player_houses (house, identifier, citizenid, keyholders) VALUES ('oldhouse2', 'license:8', 'OLD2', '["OLD2"]')]])
        MySQL.update.await("UPDATE houselocations SET price = 999999 WHERE name = 'oldhouse1'")
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pfm-houses' AND version = 2")
        PFHouses.Start()
        assert_true(PFHouses.dbReady)
        assert_eq(paidRow('oldhouse1'), 150000)
        assert_eq(paidRow('oldhouse2'), 80000)
        MySQL.update.await("UPDATE houselocations SET price = 150000 WHERE name = 'oldhouse1'")
    end)
    it('works when the two tables use different collations (a plain join fails on every start)', function()
        MySQL.query.await('ALTER TABLE houselocations MODIFY name VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci')
        MySQL.query.await('ALTER TABLE player_houses MODIFY house VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci')
        listing('oldhouse3', 70000, true)
        MySQL.insert.await([[INSERT INTO player_houses (house, identifier, citizenid, keyholders) VALUES ('oldhouse3', 'license:9', 'OLD3', '["OLD3"]')]])
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pfm-houses' AND version = 2")
        PFHouses.Start()
        assert_true(PFHouses.dbReady, 'migrations ran')
        assert_eq(paidRow('oldhouse3'), 70000)
    end)
    it('a house owned before sells back for 70% of that price, not of a listing raised since', function()
        Config.Houses.oldhouse1.price = 5000000
        MySQL.update.await("UPDATE houselocations SET price = 5000000 WHERE name = 'oldhouse1'")
        commands.sellhouse(OLD, {})
        assert_eq(bank(OLD), 105000)
        local rows = completed('pfm-houses:sellback:oldhouse1:%')
        assert_eq(#rows, 1)
        assert_eq(tonumber(rows[1].amount), 105000)
        assert_eq(PFHouses.OwnerOf('oldhouse1'), nil)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM player_houses WHERE house = 'oldhouse1'")), 0)
    end)
end)

describe('a reprice during a door purchase', function()
    it('is refused, the buyer pays the price read under the lock, and that price is recorded', function()
        local res
        duringOwnedCheck = function() res = setPrice('racehouse', 100000000) end
        Mock.fireNet('qb-houses:server:buyHouse', BUYER, 'racehouse')
        assert_true(res ~= nil, 'the reprice ran during the purchase')
        assert_eq(res.error, 'not_for_sale')
        assert_eq(PFHouses.OwnerOf('racehouse'), 'PBUYER')
        assert_eq(dbPrice('racehouse'), 200000)
        assert_eq(Config.Houses.racehouse.price, 200000)
        assert_eq(paidRow('racehouse'), 200000)
        assert_eq(bank(BUYER), 1000000 - doorTotal(200000) + 12000)
        assert_false(PFHouses.Locked('racehouse'))
        -- owned now: the reprice is refused and changes nothing
        assert_eq(setPrice('racehouse', 100000000).error, 'not_for_sale')
        assert_eq(dbPrice('racehouse'), 200000)
        -- even if the listing changes by another route, the state pays from the price paid
        Config.Houses.racehouse.price = 100000000
        local before = bank(BUYER)
        commands.sellhouse(BUYER, {})
        assert_eq(bank(BUYER) - before, 140000)
    end)
end)

describe('the guarded reprice', function()
    it('changes memory only when the database changed the one unowned row', function()
        MySQL.update.await("UPDATE houselocations SET owned = 1 WHERE name = 'ghosthouse'")   -- sold, memory does not know
        assert_eq(setPrice('ghosthouse', 100000000).error, 'not_for_sale')
        assert_eq(Config.Houses.ghosthouse.price, 200000)
        assert_eq(dbPrice('ghosthouse'), 200000)
        assert_false(PFHouses.Locked('ghosthouse'))
        MySQL.update.await("UPDATE houselocations SET owned = 0 WHERE name = 'ghosthouse'")
        assert_true(setPrice('ghosthouse', 250000).ok)
        assert_eq(Config.Houses.ghosthouse.price, 250000)
        assert_eq(dbPrice('ghosthouse'), 250000)
        assert_true(setPrice('ghosthouse', 250000).ok, 'the same price again')
    end)
end)

describe('the door contract', function()
    it('a buyer is not charged a price raised after the contract was shown', function()
        Mock.fireNet('qb-houses:server:viewHouse', BUYER, 'quotehouse')
        assert_true(setPrice('quotehouse', 600000).ok)
        Mock.fireNet('qb-houses:server:buyHouse', BUYER, 'quotehouse')
        assert_eq(PFHouses.OwnerOf('quotehouse'), nil)
        assert_eq(bank(BUYER), 1000000)
        assert_eq(#completed('pfm-houses:buy:quotehouse:%'), 0)
        -- the new contract shows the new price, and buying from it works
        Mock.fireNet('qb-houses:server:viewHouse', BUYER, 'quotehouse')
        Mock.fireNet('qb-houses:server:buyHouse', BUYER, 'quotehouse')
        assert_eq(PFHouses.OwnerOf('quotehouse'), 'PBUYER')
        assert_eq(paidRow('quotehouse'), 600000)
        assert_eq(bank(BUYER), 1000000 - doorTotal(600000) + 36000)
    end)
end)
