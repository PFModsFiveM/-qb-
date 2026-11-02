-- Batch 14 (same rule as TOW-DEP, in the taxi rental): a cab rental is charged once. After an
-- unclear charge (the bank still settling it) the retry looks up that rental's cash and bank keys
-- and charges nothing new until it settles (it used to charge again under a fresh key), and two
-- requests at once rent one cab (the lock is taken before the first yield).
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
local onSpawn
function CreateVehicleServerSetter()
    if onSpawn then local f = onSpawn; onSpawn = nil; f() end -- what arrives while the spawn yields
    Mock.nextNetId = Mock.nextNetId + 1
    return Mock.nextNetId
end
function SetVehicleNumberPlateText() end
function SetVehicleDoorsLocked() end
function GetVehicleEngineHealth() return 1000.0 end
function GetVehicleBodyHealth() return 1000.0 end

LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/taxi.lua' })
Config.Taxi.UseDatabase = false

local DRIVER = 1
local bankExports = Mock.exportsByResource['pfm-banking']
local realTransfer = bankExports.Transfer
local COST = 420 -- the default cab: rental + deposit

local function money(kind) return Mock.players[DRIVER].PlayerData.money[kind] end
local function rent() Mock.fireNet('pf-taxi:server:rentVehicle', DRIVER, { spawnCode = 'taxi' }) end
local function spawned() return #Mock.clientEventsNamed('pf-taxi:client:vehicleSpawned') end
local function charged() return LedgerEnv.paid('pf-jobs:taxi:rental:') end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    local d = Mock.newPlayer(DRIVER)
    d.PlayerData.job = { name = 'taxi', onduty = true }
    d.PlayerData.money = { cash = 0, bank = 1000 }
    Mock.fireEvent('playerDropped', DRIVER)
    onSpawn = nil
end

describe('fix14 taxi rental: charged once', function()
    it('after an unclear bank charge the retry charges nothing until it settles', function()
        local bankKey
        bankExports.Transfer = function(_, opts)
            if opts.key:sub(-5) == ':cash' then return { ok = false, error = 'insufficient_funds' } end
            bankKey = opts.key
            local tx = { tx_id = 'TX-TAXI', idempotency_key = opts.key, amount = opts.amount, state = 'pending' }
            FakeDB.byKey[opts.key], FakeDB.byTxId[tx.tx_id] = tx, tx
            return { ok = false, txId = tx.tx_id, state = 'pending', error = 'pending' }
        end
        rent()
        bankExports.Transfer = realTransfer
        assert_eq(spawned(), 0)
        Mock.players[DRIVER].PlayerData.money.cash = 1000 -- cash on hand now
        rent()
        assert_eq(money('cash'), 1000, 'no new charge while the first one settles')
        assert_eq(spawned(), 0)
        FakeDB.byKey[bankKey].state = 'completed' -- the ledger's recovery completed it
        rent()
        assert_eq(spawned(), 1, 'the cab it paid for')
        assert_eq(money('cash'), 1000, 'still charged only once')
    end)

    it('a settled refusal lets the next try charge under a new key', function()
        bankExports.Transfer = function() return { ok = false, error = 'insufficient_funds' } end
        rent()
        bankExports.Transfer = realTransfer
        rent()
        assert_eq(spawned(), 1)
        assert_eq(#charged(), 1)
        assert_eq(money('bank'), 1000 - COST)
    end)

    it('two requests at once rent one cab and charge once', function()
        onSpawn = function() rent() end
        rent()
        assert_eq(spawned(), 1)
        assert_eq(#charged(), 1)
        assert_eq(money('bank'), 1000 - COST)
    end)
end)
