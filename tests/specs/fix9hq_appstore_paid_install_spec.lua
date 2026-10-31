-- pf-devices App Store paid installs on the real ledger (fake database):
--   * a failed purchase (not enough money) does not block a later one: every attempt has its own
--     ledger key, so the stored failure of the first key is never replayed;
--   * the citizen's lock is taken before the first wait, so a second install sent while the first
--     is still paying is refused (busy) and nothing is charged twice;
--   * one charge per app: the purchase is recorded and a reinstall after an uninstall is free;
--   * when the purchase cannot be recorded the charge is refunded through the ledger.
load_resource('tests/lua/ledger_env.lua')
GetInvokingResource = GetInvokingResource or function() return nil end

local installed, purchases = {}, {}   -- [cid] = { [app] = true }, [cid .. '|' .. app] = row
local failPurchaseInsert = false
local yieldOnLoad = false
local function key(cid, app) return cid .. '|' .. app end

FakeDB.extraPatterns = {
    { 'SELECT app_id FROM pf_device_app_purchases WHERE citizenid = ? AND app_id = ?', function(p)
        return purchases[key(p[1], p[2])] and { { app_id = p[2] } } or {}
    end },
    { 'INSERT INTO pf_device_app_purchases', function(p)
        if failPurchaseInsert then failPurchaseInsert = false error('injected: purchases insert') end
        if purchases[key(p[1], p[2])] then error('Duplicate entry for key PRIMARY') end
        purchases[key(p[1], p[2])] = { citizenid = p[1], app_id = p[2], price = p[3], tx_key = p[4] }
        return 0
    end },
    { 'DELETE FROM pf_device_app_purchases WHERE citizenid = ?', function(p)
        for k, row in pairs(purchases) do if row.citizenid == p[1] then purchases[k] = nil end end
        return 1
    end },
    { 'SELECT app_id FROM pf_device_apps WHERE citizenid = ?', function(p)
        if yieldOnLoad and coroutine.isyieldable() then yieldOnLoad = false coroutine.yield() end
        local out = {}
        for app in pairs(installed[p[1]] or {}) do out[#out + 1] = { app_id = app } end
        return out
    end },
    { 'INSERT IGNORE INTO pf_device_apps', function(p)
        installed[p[1]] = installed[p[1]] or {}
        installed[p[1]][p[2]] = true
        return 0
    end },
    { 'DELETE FROM pf_device_apps WHERE citizenid = ? AND app_id = ?', function(p)
        if installed[p[1]] then installed[p[1]][p[2]] = nil end
        return 1
    end },
    { 'DELETE FROM pf_device_apps WHERE citizenid = ?', function(p) installed[p[1]] = nil return 1 end },
}

LedgerEnv.load('pf-devices', {
    '[pfscripts]/pf-devices/shared/config.lua',
    '[pfscripts]/pf-devices/server/registry.lua',
    '[pfscripts]/pf-devices/server/installs.lua',
    '[pfscripts]/pf-devices/server/push.lua',
})

local SRC = 1
local CID
local realCharge = PFPayout.Charge
local charges

local function money() return Mock.players[SRC].PlayerData.money end
local PREFIX = function() return 'pf-devices:install:' .. CID .. ':paid:' end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players = {}
    installed, purchases = {}, {}
    failPurchaseInsert, yieldOnLoad = false, false
    PFDevices.__reset()
    PFDevices.__resetInstalls()
    PFDevices.__resetPush()
    charges = {}
    PFPayout.Charge = function(...)
        local opts = select(4, ...)
        charges[#charges + 1] = opts and opts.key
        return realCharge(...)
    end
    PFDevices.RegisterApp({ id = 'paid', name = 'Paid', entry = 'a.js', access = { installable = true }, store = { price = 250 } }, 'pf-news')
    PFDevices.RegisterApp({ id = 'free', name = 'Free', entry = 'a.js', access = { installable = true } }, 'pf-news')
    local p = Mock.newPlayer(SRC)
    p.PlayerData.money = { cash = 0, bank = 0 }
    CID = p.PlayerData.citizenid
end

describe('App Store paid install: a failed purchase can be retried', function()
    it('charges on a later attempt after an attempt without enough money', function()
        local res = PFDevices.InstallApp(SRC, 'paid')
        assert_eq(res.error, 'payment_failed')
        assert_false(PFDevices.IsAppInstalled(CID, 'paid'))
        money().bank = 1000
        res = PFDevices.InstallApp(SRC, 'paid')
        assert_true(res.ok, 'the retry is not refused by the stored failure: ' .. tostring(res.error))
        assert_eq(money().bank, 750)
        assert_true(PFDevices.IsAppInstalled(CID, 'paid'))
        assert_eq(#LedgerEnv.paid(PREFIX()), 1, 'one completed purchase on the ledger')
        assert_true(charges[1] ~= charges[2], 'each attempt has its own ledger key')
        assert_true(purchases[key(CID, 'paid')] ~= nil, 'purchase recorded')
    end)

    it('charges once per app: a reinstall after an uninstall is free', function()
        money().bank = 1000
        assert_true(PFDevices.InstallApp(SRC, 'paid').ok)
        assert_true(PFDevices.UninstallApp(SRC, 'paid').ok)
        local res = PFDevices.InstallApp(SRC, 'paid')
        assert_true(res.ok, res.error)
        assert_eq(money().bank, 750, 'not charged again')
        assert_eq(#charges, 1, 'no second charge attempted')
        assert_eq(#LedgerEnv.paid(PREFIX()), 1)
    end)

    it('does not charge a citizen who already owns the app', function()
        money().bank = 1000
        purchases[key(CID, 'paid')] = { citizenid = CID, app_id = 'paid', price = 250, tx_key = 'old' }
        assert_true(PFDevices.InstallApp(SRC, 'paid').ok)
        assert_eq(#charges, 0)
        assert_eq(money().bank, 1000)
    end)
end)

describe('App Store paid install: two installs at once', function()
    it('refuses the second while the first is still waiting, so only one charge is made', function()
        money().bank = 1000
        money().cash = 1000
        yieldOnLoad = true
        local first
        local co = coroutine.create(function() first = PFDevices.InstallApp(SRC, 'paid') end)
        assert_true(coroutine.resume(co))
        assert_eq(coroutine.status(co), 'suspended', 'the first install is waiting on the database')
        local second = PFDevices.InstallApp(SRC, 'paid')
        assert_eq(second.error, 'busy', 'the second install is refused while the first holds the lock')
        assert_true(coroutine.resume(co))
        assert_true(first and first.ok, first and first.error)
        assert_eq(#charges, 1, 'one charge attempt')
        assert_eq(money().bank + money().cash, 1750, 'charged once, from one account')
        -- the lock is released afterwards
        assert_true(PFDevices.InstallApp(SRC, 'paid').already)
        assert_true(PFDevices.InstallApp(SRC, 'free').ok)
    end)

    it('releases the lock when the install fails', function()
        local res = PFDevices.InstallApp(SRC, 'paid')
        assert_eq(res.error, 'payment_failed')
        assert_true(PFDevices.InstallApp(SRC, 'free').ok, 'not left busy')
    end)
end)

describe('App Store paid install: recording the purchase fails', function()
    it('refunds the charge through the ledger and lets a later attempt buy it', function()
        money().bank = 1000
        failPurchaseInsert = true
        local res = PFDevices.InstallApp(SRC, 'paid')
        assert_false(res.ok)
        assert_eq(res.error, 'db_error')
        assert_eq(res.refunded, true)
        assert_eq(money().bank, 1000, 'money returned')
        assert_false(PFDevices.IsAppInstalled(CID, 'paid'))
        local refunds = 0
        for _, row in ipairs(LedgerEnv.paid(PREFIX())) do
            if tostring(row.idempotency_key):find(':refund', 1, true) then refunds = refunds + 1 end
        end
        assert_eq(refunds, 1, 'one refund on the ledger')
        res = PFDevices.InstallApp(SRC, 'paid')
        assert_true(res.ok, res.error)
        assert_eq(money().bank, 750)
    end)
end)

describe('App Store purchases when a character is deleted', function()
    it('are removed with the character', function()
        money().bank = 1000
        assert_true(PFDevices.InstallApp(SRC, 'paid').ok)
        Mock.eventHandlers['pfm-core:server:characterDeleted'](CID)
        assert_eq(purchases[key(CID, 'paid')], nil)
    end)
end)
