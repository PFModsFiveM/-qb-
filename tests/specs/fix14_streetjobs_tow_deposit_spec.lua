-- Batch 14 (TOW-DEP): a flatbed deposit is never taken twice across its cash and bank keys.
-- PFPayout.Charge keys each account key .. ':cash' / ':bank' and starts again from cash on every
-- call, so a retry after an unclear BANK charge (pending, debited, interrupted_unverified) could
-- charge ':cash' while ':bank' was still settling; once the bank charge settled as taken, the
-- deposit was gone twice and the refund covered one. The retry now looks up both keys first.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock

local alive = {}
function CreateVehicleServerSetter(hash, _, x, y, z)
    Mock.nextNetId = Mock.nextNetId + 1
    local id = Mock.nextNetId
    alive[id], Mock.models[id], Mock.coords[id] = true, hash, vector3(x, y, z)
    return id
end
function DoesEntityExist(e) return alive[e] == true end
function DeleteEntity(e) alive[e] = nil end
function GetAllVehicles() return {} end
function GetVehiclePedIsIn() return 0 end
function GetPedInVehicleSeat() return 0 end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end
function GetVehicleEngineHealth() return 1000.0 end
function GetVehicleBodyHealth() return 1000.0 end
SetTimeout = function(_, fn) fn() end
function GetResourceState(name) return name == 'pf-services' and 'missing' or 'started' end

LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/tow.lua' })
Config.Tow.UseDatabase = false

local DRIVER = 1
local C = Config.Tow
local BAY = vector3(C.FlatbedSpawn.x, C.FlatbedSpawn.y, C.FlatbedSpawn.z)
local DEPOSIT = C.Vehicles[1].deposit
local MODEL = C.Vehicles[1].model
local bankExports = Mock.exportsByResource['pfm-banking']
local realTransfer = bankExports.Transfer

local function money(kind) return Mock.players[DRIVER].PlayerData.money[kind] end
local function rent() return PFJobsTow.Rent(DRIVER, MODEL, true) end
local function charged() return LedgerEnv.paid('pf-jobs:tow:rent:') end

-- A first attempt the way the checker found it: cash refused before the ledger wrote anything,
-- then the bank charge left 'pending' (a crash between its steps). Returns the bank key.
local function unclearBankCharge(state, err)
    local bankKey
    bankExports.Transfer = function(_, opts)
        if opts.key:sub(-5) == ':cash' then return { ok = false, error = 'insufficient_funds' } end
        bankKey = opts.key
        local tx = { tx_id = 'TX-STUCK', idempotency_key = opts.key, kind = 'deposit', from_account = opts.from,
            to_account = opts.to, amount = opts.amount, state = state or 'pending', error = err }
        FakeDB.byKey[opts.key], FakeDB.byTxId[tx.tx_id] = tx, tx
        return { ok = false, txId = tx.tx_id, state = tx.state, error = err or tx.state }
    end
    local res = rent()
    bankExports.Transfer = realTransfer
    return res, bankKey
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    PFJobsTow.Dropped(DRIVER)
    PFJobsTow.ForgetCitizen('CID1')
    Mock.players, Mock.coords, Mock.models = {}, {}, {}
    alive = {}
    local d = Mock.newPlayer(DRIVER)
    d.PlayerData.job = { name = 'tow', grade = { level = 0 }, onduty = true }
    d.PlayerData.money = { cash = 0, bank = 1000 }
    Mock.coords[DRIVER] = BAY
end

describe('fix14 tow deposit: never charged twice across cash and bank', function()
    it('while the bank charge is settling, a retry charges no account, even with cash now on hand', function()
        local first, bankKey = unclearBankCharge()
        assert_eq(first.error, 'deposit_pending')
        Mock.players[DRIVER].PlayerData.money.cash = 1000 -- the player now has the deposit in cash
        local again = rent()
        assert_eq(again.error, 'deposit_pending', 'still settling: no new charge')
        assert_eq(money('cash'), 1000, 'the cash was not charged')
        assert_eq(#charged(), 0)
        -- the ledger's recovery completes the bank charge: the retry brings the truck out for it
        FakeDB.byKey[bankKey].state = 'completed'
        local done = rent()
        assert_eq(done.ok, true, 'the truck it paid for')
        assert_eq(money('cash'), 1000, 'still not charged in cash')
        assert_eq(PFJobsTow.View(DRIVER).rental.deposit, DEPOSIT, 'the deposit on record is the one taken')
    end)

    it('a bank charge that settles as failed lets the retry charge once', function()
        local _, bankKey = unclearBankCharge()
        Mock.players[DRIVER].PlayerData.money.cash = 1000
        FakeDB.byKey[bankKey].state, FakeDB.byKey[bankKey].error = 'failed', 'insufficient_funds'
        local res = rent()
        assert_eq(res.ok, true)
        assert_eq(money('cash'), 1000 - DEPOSIT, 'charged once, in cash')
        assert_eq(#charged(), 1)
    end)

    it('an interrupted bank charge that may have taken the money still blocks a new charge', function()
        unclearBankCharge('failed', 'interrupted_unverified')
        Mock.players[DRIVER].PlayerData.money.cash = 1000
        assert_eq(rent().error, 'deposit_pending')
        assert_eq(money('cash'), 1000)
    end)

    it('a bank that cannot be asked charges nothing', function()
        unclearBankCharge()
        Mock.players[DRIVER].PlayerData.money.cash = 1000
        local realGet = bankExports.GetTransaction
        bankExports.GetTransaction = function() error('bank stopped') end
        local res = rent()
        bankExports.GetTransaction = realGet
        assert_eq(res.error, 'bank_unavailable')
        assert_eq(money('cash'), 1000)
    end)
end)
