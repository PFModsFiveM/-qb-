-- A deleted character's half-paid phone invoices on a real database (batch 14, 13B-PAYING):
--   * pf-citizen's Bills lists a 'paying' invoice as Processing (nothing to pay or decline, not in
--     the total due) next to the open ones;
--   * pfm-core's character delete removes the open invoices and keeps the 'paying' ones;
--   * pfm-phone's sweep then credits the business and the biller from the money already taken
--     (it does not need the payer), deletes the row and names the payer 'a former resident', and
--     pf-citizen keeps no bill history for the deleted character;
--   * a kept 'paying' invoice whose charge never happened is removed by the sweep (nobody can pay it);
--   * a database without pay_state still deletes the character (the filter is left out).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-government'] = 'missing', ['pf-services'] = 'missing', ['pma-voice'] = 'missing', ['screenshot-basic'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-phone/qb-phone.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
RealDB.exec('pfm-apartments/qb-apartments.sql')
RealDB.exec('pfm-houses/qb-houses.sql')
-- illenium-appearance's tables (not in these repos)
MySQL.query.await('CREATE TABLE IF NOT EXISTS playerskins (id INT AUTO_INCREMENT PRIMARY KEY, citizenid VARCHAR(255) NOT NULL, model VARCHAR(255), skin TEXT, active TINYINT DEFAULT 1)')
MySQL.query.await('CREATE TABLE IF NOT EXISTS player_outfits (id INT AUTO_INCREMENT PRIMARY KEY, citizenid VARCHAR(50), outfitname VARCHAR(50), model VARCHAR(50), props TEXT, components TEXT)')

-- the ledger
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
local bankingConfig = Config
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')
-- the delete's bank check (pfm-banking/server_characters.lua is not under test here)
Mock.exportsByResource['pfm-banking'].CanDeleteCharacter = function() return true end
QBCoreMock.Functions.GetPlayerByPhone = function(number)
    for _, p in pairs(Mock.players) do if p.PlayerData.charinfo.phone == number then return p end end
end

-- the phone
function GetCurrentResourceName() return 'pfm-phone' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-phone/config.lua')
load_resource('pfm-phone/server/main.lua')
for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
Mock.exportsByResource['pfm-phone'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil

-- pf-citizen (its Bills app)
Mock.exportsByResource['pf-devices'] = {
    PushToCitizen = function() return true end, RegisterApp = function() return true end, RegisterAppHandlers = function() return true end,
}
function GetCurrentResourceName() return 'pf-citizen' end
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'shared/config.lua', 'server/schema.lua', 'server/util.lua', 'server/mail.lua', 'server/bills.lua',
    'server/documents.lua', 'server/calendar.lua', 'server/apps.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-citizen/' .. f)
end
assert(PFCitizen.Start(), 'pf-citizen start')
Mock.exportsByResource['pf-citizen'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
local Bills = PFCitizen.Bills

-- pfm-core's character delete (server/player.lua with the framework pieces it calls)
local phoneConfig = Config
function GetCurrentResourceName() return 'pfm-core' end
QBCore = { Functions = {}, Config = { Player = { PlayerDefaults = {} } }, Shared = {}, ShowSuccess = function() end, ShowError = function() end }
function PaycheckInterval() end
load_resource('pfm-core/server/player.lua')
Mock.exportsByResource['__self'] = nil
function QBCore.Functions.GetIdentifier(src, kind) return (kind or 'license') .. ':' .. tostring(src) end
function QBCore.Functions.GetPlayerByCitizenId(cid) return QBCore.PlayersByCitizenId[cid] end
-- oxmysql's transaction: every statement or none (here: in order, stop at the first error)
MySQL.transaction = setmetatable({ await = function(queries)
    for _, q in ipairs(queries) do
        local ok = pcall(MySQL.update.await, q.query, q.values)
        if not ok then return false end
    end
    return true
end }, { __call = function(_, queries, cb) local r = MySQL.transaction.await(queries) if cb then cb(r) end end })
Config = phoneConfig
GetCurrentResourceName = function() return 'pfm-phone' end

local PAYER_SRC, MECH = 9, 2
local function addCharacter(cid, license, bankMoney)
    MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, ?, '{"firstname":"Del","lastname":"Eted","phone":"5559990"}', '{}', '{}', '{}', '{}', '[]')]],
        { cid, license, cid, json.encode({ cash = 0, bank = bankMoney }) })
end
local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function invoice(cid, amount, candecline)
    return MySQL.insert.await('INSERT INTO phone_invoices (citizenid, amount, society, sender, sendercitizenid, candecline, reason) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { cid, amount, 'mechanic', 'Bob', 'CID2', candecline or 0, 'Brake repair' })
end
local function exists(id) return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM phone_invoices WHERE id = ?', { id })) > 0 end
local function charge(id, cid, amount)
    local token = MySQL.scalar.await('SELECT ledger_token FROM phone_invoices WHERE id = ?', { id })
    local res = PFLedger.Transfer({ from = ('player:%s:bank'):format(cid), to = 'system:pfm-phone', amount = amount,
        key = 'pfm-phone:invoice:tok:' .. token .. ':bank', kind = 'purchase' })
    assert(res.ok, 'charge: ' .. tostring(res.error))
    MySQL.update.await("UPDATE phone_invoices SET pay_state = 'paying' WHERE id = ?", { id })
end

MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('mechanic', 0, 'business', '[]') ON DUPLICATE KEY UPDATE account_balance = 0")
MySQL.query.await("INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES ('society:mechanic', 0)")
MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
    VALUES ('CID2', 1, 'license:2', 'Bob', '{"cash":0,"bank":0}', '{"firstname":"Bob","lastname":"Mech","phone":"5550002"}', '{"name":"mechanic"}', '{}', '{}', '{}', '[]')]])

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    PFCitizen.__resetLimits()
    local mech = Mock.newPlayer(MECH, 'CID2')
    mech.PlayerData.charinfo.phone = '5550002'
    mech.PlayerData.job = { name = 'mechanic', onduty = true }
    mech.PlayerData.metadata.phonedata = { InstalledApps = {} }
    mech.Functions.GetItemByName = function() return { name = 'phone' } end
end

describe('a database without pay_state', function()
    it('still deletes the character (the filter is left out, not the delete)', function()
        MySQL.query.await('ALTER TABLE phone_invoices DROP COLUMN pay_state')
        addCharacter('DELOLD01', 'license:' .. PAYER_SRC, 0)
        local id = invoice('DELOLD01', 50)
        local ok, why = QBCore.Player.DeleteCharacter(PAYER_SRC, 'DELOLD01')
        assert_true(ok, 'not deleted: ' .. tostring(why))
        assert_false(exists(id))
        MySQL.query.await("ALTER TABLE phone_invoices ADD COLUMN pay_state VARCHAR(16) NULL DEFAULT NULL")
    end)
end)

describe("a deleted character's half-paid invoice", function()
    it('is shown as Processing in Bills, kept by the delete and settled by the sweep', function()
        addCharacter('DELPAY01', 'license:' .. PAYER_SRC, 1000)
        local payer = Mock.newPlayer(PAYER_SRC, 'DELPAY01')
        payer.PlayerData.money = { cash = 0, bank = 1000 }
        local open = invoice('DELPAY01', 40, 1)
        local paying = invoice('DELPAY01', 120, 1)
        -- charged before a crash, the business not credited yet
        charge(paying, 'DELPAY01', 120)
        local list = Bills.List(PAYER_SRC)
        local seen = {}
        for _, b in ipairs(list.open) do seen[b.key] = b end
        local p, o = seen['phone:' .. paying], seen['phone:' .. open]
        assert_true(p ~= nil and o ~= nil, 'both listed')
        assert_eq(p.status, 'processing')
        assert_eq(p.canPay, false)
        assert_eq(p.canDecline, false)
        assert_eq(o.status, 'open')
        assert_eq(o.canPay, true)
        assert_eq(list.totalDue, 40)
        -- the player deletes the character (logged out)
        Mock.players[PAYER_SRC] = nil
        local ok, why = QBCore.Player.DeleteCharacter(PAYER_SRC, 'DELPAY01')
        assert_true(ok, 'not deleted: ' .. tostring(why))
        assert_false(exists(open))
        assert_true(exists(paying), 'the half-paid invoice was deleted with the character')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM players WHERE citizenid = 'DELPAY01'")), 0)
        -- the sweep finishes it from the money already taken
        local before = society('mechanic')
        PFPhoneInvoices.Sweep()
        assert_false(exists(paying))
        assert_eq(society('mechanic'), before + 120)
        local commission = tonumber(MySQL.scalar.await("SELECT COALESCE(SUM(amount), 0) FROM pf_transactions WHERE to_account = 'player:CID2:bank' AND state = 'completed'"))
        assert_eq(commission, 12)
        local mail = MySQL.single.await("SELECT message FROM player_mails WHERE citizenid = 'CID2' AND subject = 'Invoice Paid' ORDER BY id DESC LIMIT 1")
        assert_true(mail ~= nil and mail.message:find('a former resident', 1, true) ~= nil, 'paid mail: ' .. tostring(mail and mail.message))
        -- no bill history is left behind for the deleted character
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_citizen_bill_history WHERE citizenid = 'DELPAY01'")), 0)
        -- nothing more on the next sweep
        PFPhoneInvoices.Sweep()
        assert_eq(society('mechanic'), before + 120)
    end)

    it('is removed by the sweep when its charge never took money', function()
        addCharacter('DELNOC01', 'license:' .. PAYER_SRC, 0)
        local id = invoice('DELNOC01', 75)
        MySQL.update.await("UPDATE phone_invoices SET pay_state = 'paying' WHERE id = ?", { id })
        local ok = QBCore.Player.DeleteCharacter(PAYER_SRC, 'DELNOC01')
        assert_true(ok)
        assert_true(exists(id))
        local before = society('mechanic')
        PFPhoneInvoices.Sweep()
        assert_false(exists(id))
        assert_eq(society('mechanic'), before)
    end)

    it('an open invoice of a living character opened again by the sweep stays', function()
        addCharacter('LIVE0001', 'license:77', 0)
        local id = invoice('LIVE0001', 30)
        MySQL.update.await("UPDATE phone_invoices SET pay_state = 'paying' WHERE id = ?", { id })
        PFPhoneInvoices.Sweep()
        assert_true(exists(id))
        assert_eq(MySQL.scalar.await('SELECT pay_state FROM phone_invoices WHERE id = ?', { id }), nil)
    end)
end)
