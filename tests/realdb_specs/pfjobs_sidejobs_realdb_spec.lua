-- pf-jobs recycling plant and vineyard on a real database (their SQL and the real ledger): the
-- migrations, shift rows paid exactly once (at clock out, after a restart, after the bank was
-- down), the history the app shows, levels that add up, the wine barrel claimed and emptied once,
-- and a deleted character's rows removed.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
local bankUp = true
function GetResourceState(name)
    if name == 'pfm-banking' and not bankUp then return 'stopped' end
    return 'started'
end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

-- a simple inventory (the inventory has its own specs)
local Inv = {}
local function bag(src) Inv[src] = Inv[src] or {} return Inv[src] end
local function count(src, item) return bag(src)[item] or 0 end
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, item, n) bag(src)[item] = count(src, item) + n return true end,
    RemoveItem = function(_, src, item, n) if count(src, item) < n then return false end bag(src)[item] = count(src, item) - n return true end,
    GetItemCount = function(_, src, item) return count(src, item) end,
    GetItemsByName = function(_, src, item) return count(src, item) > 0 and { { name = item, slot = 1, amount = count(src, item) } } or {} end,
}
Mock.exportsByResource['pf-devices'] = { Push = function() return true end }

function GetCurrentResourceName() return 'pf-jobs' end
Config = {}
load_resource('pfm-banking/payouts.lua')
load_resource('[pfscripts]/pf-jobs/server/apps/recycle.lua')
local recycleHandlers = {
    deleted = Mock.eventHandlers['pfm-core:server:characterDeleted'],
    dropped = Mock.eventHandlers['playerDropped'],
}
load_resource('[pfscripts]/pf-jobs/server/apps/vineyard.lua')
local vineyardDeleted = Mock.eventHandlers['pfm-core:server:characterDeleted']

local R, V = PFRecycle, PFVineyard
local W, V1 = 1, 2

for _, cid in ipairs({ 'RCY1', 'VIN1' }) do
    MySQL.query.await("INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, 1, ?, ?, '{\"cash\":0,\"bank\":0}', '{}', '{}', '{}', '{}', '{}', '[]')", { cid, 'license:' .. cid, cid })
end

local function at(src, p) Mock.coords[src] = vector3(p.x, p.y, p.z) end
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function shiftRow(id) return MySQL.single.await('SELECT * FROM pf_recycle_shifts WHERE id = ?', { id }) end
local function package()
    local s = R.__shift(W)
    at(W, R.Config.Shelves[s.target])
    Mock.fireNet('pf-jobs:recycle:pickup', W)
    Mock.clock = Mock.clock + 10
    Mock.gameTimer = Mock.gameTimer + 10000
    at(W, R.Config.DropLocation)
    Mock.fireNet('pf-jobs:recycle:handIn', W)
    Mock.gameTimer = Mock.gameTimer + 10000
end
local function clockIn() at(W, R.Config.DutyLocation) Mock.fireNet('pf-jobs:recycle:clockIn', W) return R.__shift(W) end
local function paidKeys() return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'pf-jobs:recycle:shift:%' AND state = 'completed'")) or 0 end

BeforeEach = function()
    Mock.reset()
    bankUp = true
    Mock.players, Mock.coords, Inv = {}, {}, {}
    Mock.newPlayer(W, 'RCY1').PlayerData.money = { cash = 0, bank = 0 }
    local v = Mock.newPlayer(V1, 'VIN1')
    v.PlayerData.money = { cash = 0, bank = 0 }
    v.PlayerData.job = { name = 'vineyard', onduty = true, grade = { level = 0 } }
    Mock.clock = Mock.clock + 100
    Mock.gameTimer = Mock.gameTimer + 100000
end

describe('migrations', function()
    it('create the tables and are safe to run again', function()
        assert_true(R.Start())
        assert_true(V.Start())
        assert_true(R.Start(), 'second start')
        assert_true(V.Start())
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource IN ('pf-jobs:recycle', 'pf-jobs:vineyard')")), 2)
        for _, t in ipairs({ 'pf_recycle_stats', 'pf_recycle_shifts', 'pf_vineyard_stats' }) do
            assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t })), 1, t)
        end
    end)
end)

describe('recycling shifts', function()
    local firstId
    it('a shift is stored as it goes and paid once when it ends', function()
        local s = clockIn()
        firstId = s.id
        assert_eq(shiftRow(s.id).status, 'open')
        package()
        package()
        package()
        local row = shiftRow(s.id)
        assert_eq(tonumber(row.packages), 3)
        assert_eq(tonumber(row.wage), 3 * R.Config.Levels[1].wage)
        Mock.fireNet('pf-jobs:recycle:clockOut', W, false)
        Mock.fireNet('pf-jobs:recycle:clockOut', W, false)
        assert_eq(bank(W), 3 * R.Config.Levels[1].wage)
        assert_eq(shiftRow(s.id).status, 'paid')
        assert_true(tonumber(shiftRow(s.id).ended_at) ~= nil)
        assert_eq(paidKeys(), 1)
        local st = MySQL.single.await('SELECT * FROM pf_recycle_stats WHERE citizenid = ?', { 'RCY1' })
        assert_eq(tonumber(st.packages), 3)
        assert_eq(tonumber(st.xp), 3 * R.Config.XPPerPackage)
        assert_eq(tonumber(st.wages), 3 * R.Config.Levels[1].wage)
        assert_eq(tonumber(st.shifts), 1)
    end)
    it('a restart pays an interrupted shift once, under the same key', function()
        local s = clockIn()
        package()
        R.__reset()           -- the server went down mid-shift
        assert_eq(R.Recover(), 1)
        assert_eq(shiftRow(s.id).status, 'paid')
        assert_eq(R.Recover(), 0)
        assert_eq(bank(W), R.Config.Levels[1].wage)
        assert_eq(paidKeys(), 2)
    end)
    it('a shift the bank could not pay waits, and is paid once at the next clock in', function()
        local s = clockIn()
        package()
        bankUp = false
        source = W; recycleHandlers.dropped(); source = nil   -- leaving ends the shift
        assert_eq(shiftRow(s.id).status, 'unpaid')
        assert_eq(bank(W), 0)
        bankUp = true
        local again = clockIn()
        assert_eq(shiftRow(s.id).status, 'paid')
        assert_eq(bank(W), R.Config.Levels[1].wage)
        Mock.fireNet('pf-jobs:recycle:clockOut', W, false)
        assert_eq(shiftRow(again.id).status, 'paid', 'an empty shift is closed with nothing to pay')
        assert_eq(bank(W), R.Config.Levels[1].wage)
        assert_eq(paidKeys(), 3)
    end)
    it('the app shows the latest shifts first and the lifetime totals', function()
        local view = R.View(W)
        assert_eq(#view.history, 4)
        assert_true(view.history[1].startedAt >= view.history[#view.history].startedAt)
        assert_eq(view.history[#view.history].packages, 3)
        assert_eq(view.stats.packages, 5)
        assert_eq(view.stats.wages, 5 * R.Config.Levels[1].wage)
        assert_eq(view.owed, 0)
        assert_eq(view.history[#view.history].status, 'paid')
        assert_true(firstId ~= nil)
    end)
end)

describe('vineyard barrels and totals', function()
    it('a barrel is claimed once and emptied once, also across two calls at the same time', function()
        assert_eq(V.DB.fillBarrel('VIN1', Mock.clock + 180), 1)
        assert_eq(V.DB.fillBarrel('VIN1', Mock.clock + 200), 0, 'already fermenting')
        assert_eq(V.DB.emptyBarrel('VIN1', Mock.clock + 200), 0, 'not that barrel')
        assert_eq(V.DB.emptyBarrel('VIN1', Mock.clock + 180), 1)
        assert_eq(V.DB.emptyBarrel('VIN1', Mock.clock + 180), 0, 'emptied once')
    end)
    it('the wine flow keeps the barrel in the database until it is bottled', function()
        bag(V1).grapejuice = 30
        at(V1, V.Config.Winery.coords)
        assert_true(Mock.callCallback('pf-jobs:vineyard:loadWine', V1))
        local ready = tonumber(MySQL.scalar.await('SELECT barrel_ready_at FROM pf_vineyard_stats WHERE citizenid = ?', { 'VIN1' }))
        assert_eq(ready, Mock.clock + V.Config.WineSeconds)
        V.__reset()           -- restart: the barrel comes back from the database
        Mock.clock = Mock.clock + V.Config.WineSeconds
        Mock.fireNet('pf-jobs:vineyard:collectWine', V1)
        local wine = count(V1, 'wine')
        assert_true(wine >= V.Config.WinePerBarrel[1])
        assert_eq(MySQL.scalar.await('SELECT barrel_ready_at FROM pf_vineyard_stats WHERE citizenid = ?', { 'VIN1' }), nil)
        local st = MySQL.single.await('SELECT xp, wine FROM pf_vineyard_stats WHERE citizenid = ?', { 'VIN1' })
        assert_eq(tonumber(st.wine), wine)
        assert_eq(tonumber(st.xp), V.Config.XP.wine)
    end)
    it('sales are counted on the ledger and in the totals', function()
        bag(V1).wine = 4
        at(V1, V.Config.Sell.coords)
        Mock.fireNet('pf-jobs:vineyard:sell', V1)
        assert_eq(Mock.players[V1].PlayerData.money.cash, 4 * V.Config.Sell.prices.wine)
        assert_eq(tonumber(MySQL.scalar.await('SELECT sold FROM pf_vineyard_stats WHERE citizenid = ?', { 'VIN1' })), 4 * V.Config.Sell.prices.wine)
        local tx = MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'pf-jobs:vineyard:sell:VIN1:%' AND state = 'completed'")
        assert_eq(tonumber(tx), 1)
    end)
end)

describe('deleted characters', function()
    it('lose their recycling and vineyard rows; other characters keep theirs', function()
        MySQL.query.await("INSERT INTO pf_recycle_stats (citizenid, xp) VALUES ('KEEP1', 5)")
        recycleHandlers.deleted('RCY1')
        vineyardDeleted('VIN1')
        recycleHandlers.deleted(nil)
        vineyardDeleted({})
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_recycle_shifts WHERE citizenid = 'RCY1'")), 0)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_recycle_stats WHERE citizenid = 'RCY1'")), 0)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_vineyard_stats WHERE citizenid = 'VIN1'")), 0)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_recycle_stats WHERE citizenid = 'KEEP1'")), 1)
    end)
end)
