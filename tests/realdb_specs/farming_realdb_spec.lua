-- pf-farming on a real database: plots persist, growth follows watered time (offline and across a
-- restart), positions come from the server, each plot is harvested once, and market sales and seed
-- purchases go through the ledger.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
GetInvokingResource = GetInvokingResource or function() return nil end

local realTime = os.time
local clock = realTime()
os.time = function(t) if t then return realTime(t) end return clock end

-- the bank
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
assert(PFLedger.Start(), 'ledger start')

-- a small slot inventory with freshness states
local inv = {}   -- [src] = { {name, amount, info, slot} }
local fullFor = {}
local function count(src, name)
    local n = 0
    for _, it in ipairs(inv[src] or {}) do if it.name == name then n = n + it.amount end end
    return n
end
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, src, name, n, slot)
        for i, it in ipairs(inv[src] or {}) do
            if it.name == name and (not slot or it.slot == slot) and it.amount >= n then
                it.amount = it.amount - n
                if it.amount == 0 then table.remove(inv[src], i) end
                return true
            end
        end
        return false
    end,
    AddItem = function(_, src, name, n, _, info)
        if fullFor[src] then return false end
        inv[src] = inv[src] or {}
        inv[src][#inv[src] + 1] = { name = name, amount = n, info = info or { state = 'fresh' }, slot = #inv[src] + 1 }
        return true
    end,
    CanAddItem = function(_, src) return not fullFor[src] end,
    GetItemsByName = function(_, src, name)
        local out = {}
        for _, it in ipairs(inv[src] or {}) do if it.name == name then out[#out + 1] = it end end
        return out
    end,
    GetFreshness = function(_, _, info) return { state = (info or {}).state or 'fresh' } end,
    RegisterPerishables = function() return 0 end,
}

function GetCurrentResourceName() return 'pf-farming' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('[pfscripts]/pf-farming/config.lua')
load_resource('[pfscripts]/pf-farming/server/main.lua')
assert(PFFarm.Start(), 'farming start')

local FARMER, OTHER = 1, 2
local FIELD = Config.Farming.Fields.grapeseed.coords
local MARKET = Config.Farming.Market.coords
local tomato = Config.Farming.Crops.tomato

local function act() Mock.gameTimer = Mock.gameTimer + 5000 end
local function at(src, pos) Mock.coords[src] = pos end
local function plots() return MySQL.query.await('SELECT * FROM pf_farm_plots ORDER BY id') end
local function cash(src) return Mock.players[src].PlayerData.money.cash end
local function plant(src, crop) act() return PFFarm.Plant(src, crop or 'tomato') end
local function minutes(m) clock = clock + m * 60 end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, inv, fullFor = {}, {}, {}, {}
    MySQL.query.await('DELETE FROM pf_farm_plots')
    Mock.newPlayer(FARMER).PlayerData.money = { cash = 100, bank = 0 }
    Mock.newPlayer(OTHER, 'CID2').PlayerData.money = { cash = 100, bank = 0 }
    inv[FARMER] = { { name = 'seed_tomato', amount = 5, info = {}, slot = 1 }, { name = 'water_bottle', amount = 5, info = {}, slot = 2 } }
    at(FARMER, FIELD)
    at(OTHER, FIELD + vector3(1.0, 0.0, 0.0))
end

describe('planting', function()
    it('plants at the server position, uses one seed, and the table comes from the migration', function()
        local res = plant(FARMER)
        assert_true(res.ok, tostring(res.error))
        local p = plots()[1]
        assert_eq(p.citizenid, 'CID1')
        assert_eq(p.field, 'grapeseed')
        assert_true(math.abs(p.x - FIELD.x) < 0.01)
        assert_eq(count(FARMER, 'seed_tomato'), 4)
        assert_true(PFFarm.Start(), 'migrations rerun')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-farming'")), 1)
    end)
    it('refuses outside a field, without a seed, too close to another plot, and an unknown crop', function()
        at(FARMER, FIELD + vector3(500.0, 0.0, 0.0))
        assert_eq(plant(FARMER).error, 'not_in_field')
        at(FARMER, FIELD)
        assert_eq(plant(FARMER, 'cocaine').error, 'invalid_crop')
        assert_true(plant(FARMER).ok)
        assert_eq(plant(FARMER).error, 'too_close')
        assert_eq(plant(OTHER).error, 'too_close')    -- other player 1 m away
        at(OTHER, FIELD + vector3(10.0, 0.0, 0.0))
        assert_eq(plant(OTHER).error, 'no_seed')
        assert_eq(#plots(), 1)
    end)
    it('limits plots per player', function()
        Config.Farming.MaxPlotsPerPlayer = 2
        assert_true(plant(FARMER).ok)
        at(FARMER, FIELD + vector3(3.0, 0.0, 0.0))
        assert_true(plant(FARMER).ok)
        at(FARMER, FIELD + vector3(6.0, 0.0, 0.0))
        assert_eq(plant(FARMER).error, 'too_many_plots')
        Config.Farming.MaxPlotsPerPlayer = 12
    end)
end)

describe('growth', function()
    it('grows only while watered, keeps going offline, and survives a restart', function()
        assert_true(plant(FARMER).ok)
        local id = plots()[1].id
        minutes(30)                    -- the planting water lasts 30 minutes: half grown
        act()
        assert_true(PFFarm.Water(FARMER, id).ok)
        minutes(60)                    -- 30 more watered minutes, then 30 dry: ripe after 60 watered minutes
        load_resource('[pfscripts]/pf-farming/server/main.lua')   -- restart
        assert_true(PFFarm.Start())
        local status = PFFarm.Status(plots()[1], os.time())
        assert_eq(status, 'ripe')
    end)
    it('a dry plot stops growing and dies; a dead plot cannot be harvested', function()
        assert_true(plant(FARMER).ok)
        local id = plots()[1].id
        minutes(20)
        local status, progress = PFFarm.Status(plots()[1], os.time())
        assert_eq(status, 'growing')
        minutes(60)                     -- water ran out at 30 min: growth stuck at 30 of 60 minutes
        status, progress = PFFarm.Status(plots()[1], os.time())
        assert_true(math.abs(progress - 0.5) < 0.01, tostring(progress))
        minutes(Config.Farming.DieAfterDryMinutes)
        assert_eq(PFFarm.Status(plots()[1], os.time()), 'dead')
        act()
        assert_eq(PFFarm.Harvest(FARMER, id).error, 'dead')
        act()
        assert_eq(PFFarm.Water(FARMER, id).error, 'not_growing')
    end)
    it('a ripe crop rots if left too long', function()
        assert_true(plant(FARMER).ok)
        local id = plots()[1].id
        minutes(25) act() assert_true(PFFarm.Water(FARMER, id).ok)
        minutes(25) act() assert_true(PFFarm.Water(FARMER, id).ok)   -- 60 watered minutes need two waterings
        minutes(15)
        assert_eq(PFFarm.Status(plots()[1], os.time()), 'ripe')
        minutes(Config.Farming.RotAfterReadyMinutes + 1)
        assert_eq(PFFarm.Status(plots()[1], os.time()), 'dead')
    end)
end)

describe('harvest', function()
    local function ripePlot()
        assert_true(plant(FARMER).ok)
        local id = plots()[1].id
        minutes(25) act() assert_true(PFFarm.Water(FARMER, id).ok)
        minutes(25) act() assert_true(PFFarm.Water(FARMER, id).ok)   -- 60 watered minutes need two waterings
        minutes(15)
        return id
    end
    it('gives the stored yield once', function()
        local id = ripePlot()
        local yield = plots()[1].yield
        assert_true(yield >= tomato.yield[1] and yield <= tomato.yield[2])
        act()
        local res = PFFarm.Harvest(FARMER, id)
        assert_true(res.ok, tostring(res.error))
        assert_eq(count(FARMER, 'tomato'), yield)
        act()
        assert_eq(PFFarm.Harvest(FARMER, id).ok, false)
        assert_eq(count(FARMER, 'tomato'), yield)
    end)
    it("nobody else harvests, waters or clears your plot, and you must be next to it", function()
        local id = ripePlot()
        inv[OTHER] = { { name = 'water_bottle', amount = 1, info = {}, slot = 1 } }
        act()
        assert_eq(PFFarm.Harvest(OTHER, id).error, 'not_your_plot')
        act()
        assert_eq(PFFarm.Water(OTHER, id).error, 'not_your_plot')
        act()
        assert_eq(PFFarm.Clear(OTHER, id).error, 'not_your_plot')
        at(FARMER, FIELD + vector3(20.0, 0.0, 0.0))
        act()
        assert_eq(PFFarm.Harvest(FARMER, id).error, 'too_far')
        assert_eq(count(OTHER, 'tomato') + count(FARMER, 'tomato'), 0)
    end)
    it('a full inventory leaves the crop in the ground', function()
        local id = ripePlot()
        fullFor[FARMER] = true
        act()
        assert_eq(PFFarm.Harvest(FARMER, id).error, 'inventory_full')
        assert_eq(plots()[1].state, 'growing')
        fullFor[FARMER] = nil
        act()
        assert_true(PFFarm.Harvest(FARMER, id).ok)
    end)
    it('requests too close together are refused', function()
        local id = ripePlot()
        Mock.gameTimer = Mock.gameTimer + 5000
        PFFarm.Clear(FARMER, 99999)
        assert_eq(PFFarm.Harvest(FARMER, id).error, 'too_fast')
    end)
    it('the field view does not send owner ids', function()
        ripePlot()
        local view = PFFarm.FieldView('grapeseed', 'CID2')
        assert_eq(#view, 1)
        assert_eq(view[1].citizenid, nil)
        assert_eq(view[1].mine, nil)
        assert_eq(PFFarm.FieldView('grapeseed', 'CID1')[1].mine, true)
    end)
end)

describe('market', function()
    BeforeEach = function()
        Mock.reset()
        Mock.players, Mock.coords, inv, fullFor = {}, {}, {}, {}
        Mock.newPlayer(FARMER).PlayerData.money = { cash = 100, bank = 0 }
        at(FARMER, MARKET)
    end
    it('pays by freshness, refuses spoiled produce, and pays once per sale', function()
        inv[FARMER] = {
            { name = 'tomato', amount = 10, info = { state = 'fresh' }, slot = 1 },
            { name = 'tomato', amount = 10, info = { state = 'stale' }, slot = 2 },
            { name = 'tomato', amount = 5, info = { state = 'spoiled' }, slot = 3 },
        }
        act()
        local res = PFFarm.Sell(FARMER, 'tomato', 15)
        assert_true(res.ok, tostring(res.error))
        local price = Config.Farming.Market.Buys.tomato
        local expected = math.floor((10 * price + 5 * price * Config.Farming.Market.FreshnessPrice.stale) * 100 + 0.5) / 100
        assert_eq(res.data.total, expected)
        assert_eq(cash(FARMER), 100 + expected)
        act()
        assert_eq(PFFarm.Sell(FARMER, 'tomato', 6).error, 'not_enough_sellable')   -- 5 stale left + 5 spoiled
        assert_eq(count(FARMER, 'tomato'), 10)
    end)
    it('only at the market, only produce it buys, whole positive amounts', function()
        inv[FARMER] = { { name = 'tomato', amount = 10, info = {}, slot = 1 } }
        act() assert_eq(PFFarm.Sell(FARMER, 'goldbar', 1).error, 'not_bought_here')
        act() assert_eq(PFFarm.Sell(FARMER, 'tomato', -5).error, 'invalid_amount')
        act() assert_eq(PFFarm.Sell(FARMER, 'tomato', 1.5).error, 'invalid_amount')
        at(FARMER, FIELD)
        act() assert_eq(PFFarm.Sell(FARMER, 'tomato', 1).error, 'not_at_market')
        assert_eq(cash(FARMER), 100)
    end)
    it('seeds are charged, and refunded once if they do not fit', function()
        act()
        local res = PFFarm.BuySeeds(FARMER, 'tomato', 10)
        assert_true(res.ok, tostring(res.error))
        assert_eq(cash(FARMER), 100 - 10 * tomato.seedPrice)
        assert_eq(count(FARMER, 'seed_tomato'), 10)
        act()
        assert_eq(PFFarm.BuySeeds(FARMER, 'tomato', 1000).error, 'invalid_amount')
        Mock.players[FARMER].PlayerData.money.cash = 1
        act()
        assert_eq(PFFarm.BuySeeds(FARMER, 'tomato', 5).error, 'cannot_afford')
        assert_eq(count(FARMER, 'seed_tomato'), 10)
    end)
end)
