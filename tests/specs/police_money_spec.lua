-- pfm-policejob fines, bills, cash seizure, evidence bags and robbery on the ledger.
load_resource('tests/lua/ledger_env.lua')
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCore = QBCoreMock
QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Items = QBCoreMock.Shared.Items or {}

local bags = {}           -- moneybags handed out: { src, info }
local inventoryFull = false
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, name, amount, slot, info)
        if inventoryFull then return false end
        if name == 'moneybag' then bags[#bags + 1] = { src = src, info = info } end
        return true
    end,
    RemoveItem = function() return true end,
    OpenInventoryById = function() end,
}
local directInserts = 0    -- the old /fine wrote phone_invoices itself (no ledger token)
-- pfm_police_fines (server/fines.lua) on the fake database: just the statements fines.lua sends
FineRows = {}
local function fineMove(p)
    local row = FineRows[p[7]]
    if not row or row.state ~= p[8] or row.attempt ~= p[9] then return { affectedRows = 0 } end
    row.state, row.paid_from, row.invoice_id, row.last_error, row.next_at = p[1], p[2], p[3], p[4], p[5]
    row.checks = row.checks + p[6]
    return { affectedRows = 1 }
end
FakeDB.extraPatterns = {
    { 'INSERT INTO phone_invoices', function() directInserts = directInserts + 1 return 1 end },
    { 'INSERT INTO pfm_police_fines', function(p)
        local id = #FineRows + 1
        FineRows[id] = { id = id, citizenid = p[1], society = p[2], amount = p[3], officer_citizenid = p[4], officer_name = p[5],
            reason = p[6], state = 'charging', attempt = 1, checks = 0, next_at = p[7] }
        return id
    end },
    { 'UPDATE pfm_police_fines SET state = ?, paid_from', fineMove },
    { "UPDATE pfm_police_fines SET state = 'charging', attempt = attempt + 1", function(p)
        local row = FineRows[p[2]]
        if not row or row.state ~= 'retry' or row.attempt ~= p[3] then return { affectedRows = 0 } end
        row.state, row.attempt, row.next_at = 'charging', row.attempt + 1, p[1]
        return { affectedRows = 1 }
    end },
    { 'FROM pfm_police_fines WHERE state IN', function(p)
        local out = {}
        for _, row in ipairs(FineRows) do
            if (row.state == 'charging' or row.state == 'pending' or row.state == 'retry') and row.next_at <= p[1] then
                local copy = {}
                for k, v in pairs(row) do copy[k] = v end
                out[#out + 1] = copy
            end
        end
        return out
    end },
}
-- pfm-phone's CreateInvoice export; nil answer = the phone is not running / refused it
local phoneInvoices, phoneAnswer = {}, 41
Mock.exportsByResource['pfm-phone'] = {
    CreateInvoice = function(_, data) phoneInvoices[#phoneInvoices + 1] = data return phoneAnswer end,
}

LedgerEnv.load('pfm-policejob', { 'pfm-policejob/config.lua', 'pfm-policejob/server/main.lua', 'pfm-policejob/server/fines.lua', 'pfm-policejob/server/commands.lua', 'pfm-policejob/server/interactions.lua' })

local COP, SUSPECT, ROBBER = 1, 2, 3
local function money(src) return Mock.players[src].PlayerData.money end
local function police() return FakeDB.bank_accounts.police.account_balance end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    bags, inventoryFull = {}, false
    directInserts, phoneInvoices, phoneAnswer = 0, {}, 41
    FineRows = {}
    FakeDB.society('police', 0)
    local cop = Mock.newPlayer(COP)
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    cop.GetItemByName = function() return { name = 'moneybag' } end
    Mock.newPlayer(SUSPECT).PlayerData.money = { cash = 300, bank = 1000 }
    Mock.newPlayer(ROBBER).PlayerData.money = { cash = 0, bank = 0 }
end

describe('/fine', function()
    it('takes the fine once and credits the department', function()
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(money(SUSPECT).bank, 600)
        assert_eq(police(), 400)
    end)
    it('falls back to cash, then to an invoice', function()
        Mock.players[SUSPECT].PlayerData.money = { cash = 500, bank = 10 }
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(money(SUSPECT).cash, 100)
        Commands.fine(COP, { tostring(SUSPECT), '400' })   -- cannot pay: invoice, nothing taken
        assert_eq(money(SUSPECT).cash, 100)
        assert_eq(police(), 400)
    end)
    it('one they cannot pay becomes a phone invoice made by pfm-phone, not a row written here', function()
        Mock.players[SUSPECT].PlayerData.money = { cash = 10, bank = 10 }
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(directInserts, 0)
        assert_eq(#phoneInvoices, 1)
        local inv = phoneInvoices[1]
        assert_eq(inv.citizenid, 'CID2')
        assert_eq(inv.amount, 400)
        assert_eq(inv.society, 'police')
        assert_eq(inv.sendercitizenid, 'CID1')
        assert_eq(#Mock.clientEventsNamed('qb-phone:RefreshPhone'), 1)
        assert_eq(money(SUSPECT).bank, 10)
        assert_eq(police(), 0)
    end)
    it('the officer is told when the phone could not create the invoice', function()
        Mock.players[SUSPECT].PlayerData.money = { cash = 0, bank = 0 }
        phoneAnswer = nil
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        local told = false
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
            if e.target == COP and tostring(e.args[1]):find('could not be sent', 1, true) then told = true end
        end
        assert_true(told)
        assert_eq(directInserts, 0)
    end)
    it('a charge the bank has not settled sends no invoice on top of it', function()
        -- the debit left the online player's money, then the state write broke: the charge is unclear
        FakeDB.failNext.setState = true
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(money(SUSPECT).bank, 600)
        assert_eq(#phoneInvoices, 0)
        assert_eq(directInserts, 0)
        assert_eq(police(), 0)
        local told = false
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
            if e.target == COP and tostring(e.args[1]):find('still processing', 1, true) then told = true end
        end
        assert_true(told)
    end)
    it('refuses missing, oversized and off-duty fines', function()
        Commands.fine(COP, { tostring(SUSPECT) })
        Commands.fine(COP, { tostring(SUSPECT), tostring(Config.MaxFine + 1) })
        Mock.players[COP].PlayerData.job.onduty = false
        Commands.fine(COP, { tostring(SUSPECT), '100' })
        assert_eq(money(SUSPECT).bank, 1000)
        assert_eq(police(), 0)
    end)
end)

describe('the bill menu', function()
    it('credits the police only when the bill was paid', function()
        Mock.players[SUSPECT].PlayerData.money.bank = 50
        Mock.fireNet('police:server:BillPlayer', COP, SUSPECT, 500)
        assert_eq(police(), 0)
        assert_eq(money(SUSPECT).bank, 50)
        Mock.fireNet('police:server:BillPlayer', COP, SUSPECT, 40)
        assert_eq(police(), 40)
        assert_eq(money(SUSPECT).bank, 10)
    end)
end)

describe('seized cash', function()
    it('goes into an evidence bag that pays out once', function()
        Mock.fireNet('police:server:SeizeCash', COP, SUSPECT)
        assert_eq(money(SUSPECT).cash, 0)
        assert_eq(#bags, 1)
        local bag = bags[1].info
        Mock.useables['moneybag'](COP, { info = bag, slot = 1 })
        Mock.useables['moneybag'](COP, { info = bag, slot = 2 }) -- a duplicated bag
        assert_eq(money(COP).cash, 300)
    end)
    it('is given back when the officer cannot carry the bag', function()
        inventoryFull = true
        Mock.fireNet('police:server:SeizeCash', COP, SUSPECT)
        assert_eq(money(SUSPECT).cash, 300)
    end)
    it('nothing to seize makes no bag', function()
        Mock.players[SUSPECT].PlayerData.money.cash = 0
        Mock.fireNet('police:server:SeizeCash', COP, SUSPECT)
        assert_eq(#bags, 0)
    end)
end)

describe('robbing a cuffed player', function()
    it('moves the cash once, from the victim to the robber', function()
        Mock.players[SUSPECT].PlayerData.metadata.ishandcuffed = true
        Mock.fireNet('police:server:RobPlayer', ROBBER, SUSPECT)
        Mock.fireNet('police:server:RobPlayer', ROBBER, SUSPECT)
        assert_eq(money(ROBBER).cash, 300)
        assert_eq(money(SUSPECT).cash, 0)
    end)
end)
