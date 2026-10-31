-- pf-devices on a real database: installed apps per citizen, paid installs on the real ledger.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
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

function GetCurrentResourceName() return 'pf-devices' end
Config = {}
load_resource('pfm-banking/payouts.lua')
load_resource('[pfscripts]/pf-devices/shared/config.lua')
load_resource('[pfscripts]/pf-devices/server/registry.lua')
load_resource('[pfscripts]/pf-devices/server/installs.lua')
load_resource('[pfscripts]/pf-devices/server/push.lua')
assert(RunMigrations('pf-devices', PFDevices.Migrations))

-- each test is a different citizen: a purchase key stays paid on the ledger for good
local testNo = 0
local CID
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    testNo = testNo + 1
    CID = 'CID' .. testNo
    PFDevices.__reset()
    PFDevices.__resetInstalls()
    PFDevices.RegisterApp({ id = 'news', entry = 'a.js', access = { installable = true } }, 'pf-news')
    PFDevices.RegisterApp({ id = 'pro', entry = 'a.js', access = { installable = true }, store = { price = 300 } }, 'pf-news')
    local p = Mock.newPlayer(1, CID)
    p.PlayerData.money = { cash = 0, bank = 1000 }
    p.PlayerData.source = 1
end

describe('installed apps', function()
    it('survive a restart (the cache is rebuilt from the table)', function()
        assert_true(PFDevices.InstallApp(1, 'news').ok)
        PFDevices.__resetInstalls()
        assert_true(PFDevices.IsAppInstalled(CID, 'news'))
        assert_eq(table.concat(PFDevices.GetInstalledApps(CID), ','), 'news')
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_device_apps WHERE citizenid = ?', { CID })), 1)
        assert_true(PFDevices.UninstallApp(1, 'news').ok)
        PFDevices.__resetInstalls()
        assert_false(PFDevices.IsAppInstalled(CID, 'news'))
    end)

    it('a paid app is charged once on the ledger, even if installed again', function()
        assert_true(PFDevices.InstallApp(1, 'pro').ok)
        assert_eq(Mock.players[1].PlayerData.money.bank, 700)
        assert_true(PFDevices.UninstallApp(1, 'pro').ok)
        assert_true(PFDevices.InstallApp(1, 'pro').ok)
        assert_eq(Mock.players[1].PlayerData.money.bank, 700, 'the purchase key is per citizen and app')
        local rows = MySQL.query.await("SELECT * FROM pf_transactions WHERE idempotency_key LIKE ? AND state = 'completed'", { 'pf-devices:install:' .. CID .. ':pro%' })
        assert_eq(#rows, 1)
        assert_eq(rows[1].to_account, 'system:pf-devices')
    end)

    it('is refused when the player cannot pay', function()
        Mock.players[1].PlayerData.money.bank = 10
        local res = PFDevices.InstallApp(1, 'pro')
        assert_false(res.ok)
        assert_eq(res.error, 'payment_failed')
        assert_false(PFDevices.IsAppInstalled(CID, 'pro'))
    end)
end)
