-- Batch 14 (drugs-delivery-reyield) on a real database: the pfm_drug_deliveries migration, a run
-- that survives a restart (the cache is rebuilt from the row), an expired run's debt kept in the
-- row and paid in cash on the real ledger, a paid hand-over, and the row removed with the character.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pfm-weathersync'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
GetInvokingResource = GetInvokingResource or function() return nil end

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
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local inv = {}
local function count(src, item) return (inv[src] or {})[item] or 0 end
Mock.exportsByResource['pfm-inventory'] = {
    GetItemCount = function(_, src, item) return count(src, item) end,
    AddItem = function(_, src, item, n) inv[src] = inv[src] or {}; inv[src][item] = count(src, item) + (n or 1) return true end,
    RemoveItem = function(_, src, item, n)
        if count(src, item) < (n or 1) then return false end
        inv[src][item] = count(src, item) - (n or 1)
        return true
    end,
}
QBCoreMock.Functions.GetDutyCount = function() return 0 end
QBCoreMock.Shared.Items.weed_brick = { name = 'weed_brick', label = 'Weed Brick' }
QBCoreMock.Shared.Items.coke_brick = { name = 'coke_brick', label = 'Coke Brick' }

function GetCurrentResourceName() return 'pfm-drugs' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-drugs/config.lua')
load_resource('pfm-drugs/server/deliveries.lua')
assert(PFDrugs.Start(), 'migration ran')
local DEALER = 'RealDB Dealer'
Config.Dealers[DEALER] = { name = 'Shady', coords = { x = 0.0, y = 0.0, z = 0.0 }, time = { min = 0, max = 23 }, products = {} }

local P = 1
local testNo, CID = 0, nil
local function row() return MySQL.single.await('SELECT * FROM pfm_drug_deliveries WHERE citizenid = ?', { CID }) end
local function request() Mock.coords[P] = vector3(0.0, 0.0, 0.0) return PFDrugs.RequestDelivery(P, DEALER) end
local function itemOf(d) return Config.DeliveryItems[d.item].item end

BeforeEach = function()
    Mock.reset()
    testNo = testNo + 1
    CID = 'DRUGRT' .. testNo
    inv = {}
    PFDrugs.__reset()
    Mock.clock = Mock.clock + 86400
    Mock.players, Mock.coords = {}, {}
    local p = Mock.newPlayer(P, CID)
    p.PlayerData.money = { cash = 0, bank = 0 }
    p.PlayerData.metadata.rep = { dealer = 10 }
    function p.GetRep(kind) return p.PlayerData.metadata.rep[kind] or 0 end
    function p.AddRep(kind, n) p.PlayerData.metadata.rep[kind] = (p.PlayerData.metadata.rep[kind] or 0) + n end
    function p.RemoveRep(kind, n) p.PlayerData.metadata.rep[kind] = (p.PlayerData.metadata.rep[kind] or 0) - n end
end

describe('fix14 drugs deliveries on a real database', function()
    it('the migration is recorded and safe to run again', function()
        assert_true(RunMigrations('pfm-drugs', PFDrugs.Migrations))
        for _, m in ipairs(PFDrugs.Migrations) do
            for _, sql in ipairs(m.up) do MySQL.query.await(sql) end
        end
        local n = MySQL.scalar.await('SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = ?', { 'pfm-drugs' })
        assert_eq(tonumber(n), #PFDrugs.Migrations)
        local col = MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pfm_drug_deliveries' AND COLUMN_NAME = 'pay_attempt']])
        assert_eq(tonumber(col), 1)
    end)

    it('a run is kept in the table and survives a restart', function()
        local d = request().delivery
        local r = row()
        assert_eq(r.state, 'active')
        assert_eq(tonumber(r.amount), d.amount)
        assert_eq(r.dealer, DEALER)
        PFDrugs.__reset() -- a restart: the cache is gone, the row is not
        local again = request()
        assert_eq(again.error, 'pending_delivery')
        assert_eq(again.delivery.amount, d.amount)
        assert_eq(again.delivery.locationLabel, d.locationLabel)
        assert_eq(count(P, itemOf(d)), d.amount, 'no second set of bricks')
    end)

    it('an expired run leaves a debt in the row, paid in cash on the ledger before the next run', function()
        local d = request().delivery
        inv[P][itemOf(d)] = 0
        Mock.clock = Mock.clock + Config.DeliveryExpireMinutes * 60 + 1
        PFDrugs.__reset()
        request()
        local r = row()
        assert_eq(r.state, 'idle')
        local owed = tonumber(r.debt)
        assert_eq(owed, d.amount * Config.DeliveryItems[d.item].debt)
        Mock.clock = Mock.clock + Config.FailedDeliveryCooldown + 1
        assert_eq(request().error, 'debt')
        assert_eq(tonumber(row().debt_attempt), 1, 'the refused key is spent; the next try has its own')
        Mock.players[P].PlayerData.money.cash = owed
        assert_eq(request().ok, true)
        assert_eq(tonumber(row().debt), 0)
        local tx = MySQL.single.await('SELECT state, amount FROM pf_transactions WHERE idempotency_key = ?',
            { ('pfm-drugs:debt:%s:1:cash'):format(r.debt_id) })
        assert_eq(tx.state, 'completed')
        assert_eq(tonumber(tx.amount), owed)
    end)

    it('a hand-over is paid once on the ledger and closes the run', function()
        local d = request().delivery
        local id = row().delivery_id
        Mock.coords[P] = vector3(d.coords.x, d.coords.y, d.coords.z)
        Mock.clock = Mock.clock + 600
        assert_eq(PFDrugs.HandOver(P).outcome, 'perfect')
        local tx = MySQL.single.await('SELECT state, amount FROM pf_transactions WHERE idempotency_key = ?', { 'pfm-drugs:delivery:' .. id })
        assert_eq(tx.state, 'completed')
        assert_eq(tonumber(tx.amount), Config.DeliveryItems[d.item].payout * d.amount)
        local r = row()
        assert_eq(r.state, 'idle')
        assert_true(tonumber(r.next_at) > os.time(), 'the cooldown is stored')
    end)

    it('the row goes with the character', function()
        request()
        assert_true(row() ~= nil)
        TriggerEvent('pfm-core:server:characterDeleted', CID, { apartments = {}, plates = {} })
        assert_eq(row(), nil)
    end)
end)
