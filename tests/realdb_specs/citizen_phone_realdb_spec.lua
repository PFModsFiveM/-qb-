-- pfm-phone and pf-citizen together on a real database: phone invoices are listed in the Bills app
-- and paid through the phone's own PayInvoice exactly once (also after a failed attempt), declined
-- through DeclineInvoice, kept in the bill history; the phone's mail goes through pf-citizen into the
-- one mailbox, the phone shows only the inbox, and deleting on the phone moves mail to the trash.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-government'] = 'missing', ['pf-services'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-phone/qb-phone.sql')
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
local phone = Mock.exportsByResource['__self']
Mock.exportsByResource['pfm-phone'] = phone
Mock.exportsByResource['__self'] = nil

local pushes = {}
Mock.exportsByResource['pf-devices'] = {
    PushToCitizen = function(_, cid, app, event, payload) pushes[#pushes + 1] = { cid = cid, app = app, event = event } return true end,
    RegisterApp = function() return true end, RegisterAppHandlers = function() return true end,
}

function GetCurrentResourceName() return 'pf-citizen' end
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'shared/config.lua', 'server/schema.lua', 'server/util.lua', 'server/mail.lua', 'server/bills.lua',
    'server/documents.lua', 'server/calendar.lua', 'server/apps.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-citizen/' .. f)
end
assert(PFCitizen.Start(), 'pf-citizen start')
Mock.exportsByResource['pf-citizen'] = Mock.exportsByResource['__self']
local B, M = PFCitizen.Bills, PFCitizen.Mail

local A, MECH = 1, 2
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function invoice(amount, candecline, id)
    return MySQL.insert.await('INSERT INTO phone_invoices (id, citizenid, amount, society, sender, sendercitizenid, candecline, reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { id or 0, 'CID1', amount, 'mechanic', 'Bob', 'CID2', candecline or 0, 'Brake repair' })
end
local function findOpen(list, key) for _, b in ipairs(list.open) do if b.key == key then return b end end end

MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('mechanic', 0, 'business', '[]') ON DUPLICATE KEY UPDATE account_balance = 0")
MySQL.query.await("INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES ('society:mechanic', 0)")

BeforeEach = function()
    Mock.reset()
    Mock.players, pushes = {}, {}
    PFCitizen.__resetLimits()
    for src, phoneNo in pairs({ [A] = '5550001', [MECH] = '5550002' }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.charinfo.phone = phoneNo
        p.PlayerData.money = { cash = 0, bank = src == A and 1000 or 0 }
        p.PlayerData.metadata.phonedata = { InstalledApps = {} }
        p.PlayerData.job = { name = src == MECH and 'mechanic' or 'unemployed', onduty = true }
        p.Functions.GetItemByName = function() return { name = 'phone' } end
    end
end

describe('phone invoices in the Bills app', function()
    it('are listed and paid once, through the phone, with the business and the biller paid', function()
        local id = invoice(250, 1)
        local key = 'phone:' .. id
        local b = findOpen(B.List(A), key)
        assert_true(b ~= nil, 'not listed')
        assert_eq(b.amount, 250)
        assert_eq(b.canDecline, true)
        assert_eq(b.title, 'Brake repair')
        assert_eq(B.Pay(MECH, { key = key }).ok, false)          -- not their invoice
        local res = B.Pay(A, { key = key })
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(bank(A), 750)
        assert_eq(society('mechanic'), 250)
        assert_eq(bank(MECH), 25)                               -- 10 % commission to the biller
        assert_eq(MySQL.scalar.await('SELECT COUNT(*) FROM phone_invoices WHERE id = ?', { id }), 0)
        -- paid again, or the same invoice replayed: no money moves
        assert_eq(B.Pay(A, { key = key }).ok, false)
        invoice(250, 1, id)
        assert_eq(B.Pay(A, { key = key }).ok, true)
        assert_eq(bank(A), 750)
        assert_eq(society('mechanic'), 250)
        -- history and the business's mail
        local hist = MySQL.query.await("SELECT * FROM pf_citizen_bill_history WHERE citizenid = 'CID1' AND source = 'phone' AND ref = ?", { tostring(id) })
        assert_eq(#hist, 1)
        assert_eq(hist[1].outcome, 'paid')
        local paidMail = MySQL.query.await("SELECT * FROM player_mails WHERE citizenid = 'CID2' AND subject = 'Invoice Paid'")
        assert_eq(#paidMail, 1)
    end)
    it('a failed attempt (no money) does not block paying later', function()
        local id = invoice(5000, 0)
        assert_eq(B.Pay(A, { key = 'phone:' .. id }).error, 'insufficient_funds')
        assert_eq(bank(A), 1000)
        Mock.players[A].PlayerData.money.bank = 6000
        assert_eq(B.Pay(A, { key = 'phone:' .. id }).ok, true)
        assert_eq(bank(A), 1000)
        assert_eq(Mock.callCallback('qb-phone:server:PayInvoice', A, nil, nil, id), false)   -- gone
    end)
    it('the phone pays the same way', function()
        local id = invoice(100, 0)
        assert_eq(Mock.callCallback('qb-phone:server:PayInvoice', A, 'police', 1, id), true)
        assert_eq(bank(A), 900)
        assert_eq(findOpen(B.List(A), 'phone:' .. id), nil)
    end)
    it('can be declined when the invoice allows it', function()
        local fixed = invoice(80, 0)
        assert_eq(B.Decline(A, { key = 'phone:' .. fixed }).ok, false)
        local id = invoice(80, 1)
        assert_eq(B.Decline(A, { key = 'phone:' .. id }).ok, true)
        assert_eq(MySQL.scalar.await('SELECT COUNT(*) FROM phone_invoices WHERE id = ?', { id }), 0)
        local hist = B.List(A).history
        local seen
        for _, h in ipairs(hist) do if h.key == 'phone:' .. id then seen = h end end
        assert_eq(seen.status, 'declined')
        assert_eq(bank(A), 1000)
    end)
end)

describe('phone mail through pf-citizen', function()
    it("the phone's export stores mail in the one mailbox and tells the phone", function()
        phone.sendNewMailToOffline('CID2', { sender = 'Garage', subject = 'Your car', message = 'Fixed' })
        local rows = MySQL.query.await("SELECT * FROM player_mails WHERE citizenid = 'CID2' AND subject = 'Your car'")
        assert_eq(#rows, 1)
        assert_eq(rows[1].folder, 'inbox')
        assert_true(rows[1].thread ~= nil, 'stored by pf-citizen')
        local notes = Mock.clientEventsNamed('qb-phone:client:NewMailNotify')
        assert_eq(notes[#notes].target, MECH)
        local p = pushes[#pushes]
        assert_eq(p.app, 'mail')
        assert_eq(p.cid, 'CID2')
    end)
    it('a client script mail to its own phone goes to its own inbox only', function()
        Mock.fireNet('qb-phone:server:sendNewMail', A, { sender = 'Dealer', subject = 'Job', message = 'Meet at the docks', button = { enabled = true, buttonEvent = 'x' } })
        local rows = MySQL.query.await("SELECT * FROM player_mails WHERE subject = 'Job'")
        assert_eq(#rows, 1)
        assert_eq(rows[1].citizenid, 'CID1')
        assert_eq(rows[1].sender_type, 'system')
    end)
    it('the phone shows the inbox only, and its delete goes to the trash', function()
        M.SendFromPlayer(A, { to = '5550002', subject = 'Hello', message = 'From the tablet' })
        M.SaveDraft(A, { to = '5550002', subject = 'Unsent', message = 'x' })
        local data = Mock.callCallback('qb-phone:server:GetPhoneData', A)
        for _, m in ipairs(data.Mails) do assert_eq(m.folder, 'inbox', m.subject) end
        local got = MySQL.single.await("SELECT * FROM player_mails WHERE citizenid = 'CID2' AND subject = 'Hello'")
        Mock.fireNet('qb-phone:server:RemoveMail', MECH, got.mailid)
        assert_eq(MySQL.scalar.await('SELECT folder FROM player_mails WHERE id = ?', { got.id }), 'trash')
        assert_eq(M.Restore(MECH, { id = got.id }).folder, 'inbox')
        Mock.fireNet('qb-phone:server:RemoveMail', A, got.mailid)            -- not A's mail
        assert_eq(MySQL.scalar.await('SELECT folder FROM player_mails WHERE id = ?', { got.id }), 'inbox')
    end)
end)
