-- pfm-phone bank app and invoices on the ledger: exact account numbers, server-side invoice amounts,
-- each payment once.
load_resource('tests/lua/ledger_env.lua')

local accounts = {}   -- [account number] = citizenid
local invoices = {}   -- [id] = row

FakeDB.extraPatterns = {
    { 'SELECT citizenid FROM players WHERE charinfo LIKE ?', function(p)
        local wanted = p[1]:match('^%%"account":"(.-)"%%$')
        local out = {}
        for number, cid in pairs(accounts) do
            if number == wanted then out[#out + 1] = { citizenid = cid } end
        end
        return out
    end },
    -- the statements the old code used, so the old behaviour can be checked against these tests
    { 'SELECT * FROM players WHERE charinfo LIKE ?', function(p)
        local needle = p[1]:gsub('^%%', ''):gsub('%%$', '')
        local out = {}
        for number, cid in pairs(accounts) do
            if ('{"account":"' .. number .. '"}'):find(needle, 1, true) then
                local money = FakeDB.players[cid] and FakeDB.players[cid].money or { cash = 0, bank = 0 }
                out[#out + 1] = { citizenid = cid, money = json.encode(money) }
            end
        end
        table.sort(out, function(x, y) return x.citizenid < y.citizenid end)
        return out
    end },
    { 'UPDATE players SET money = ? WHERE citizenid = ?', function(p) FakeDB.players[p[2]] = { money = json.decode(p[1]) }; return 1 end },
    { 'select count(1) as count FROM phone_invoices WHERE id = ? and citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        return { { count = (row and row.citizenid == p[2]) and 1 or 0 } }
    end },
    { 'DELETE FROM phone_invoices WHERE id = ? and citizenid = ?', function(p) invoices[tonumber(p[1])] = nil; return 1 end },
    { 'SELECT * FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        return (row and row.citizenid == p[2]) and { row } or {}
    end },
    { 'DELETE FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        if row and row.citizenid == p[2] then invoices[tonumber(p[1])] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
}

LedgerEnv.load('pfm-phone', { 'pfm-phone/config.lua', 'pfm-phone/server/main.lua' })
local mails = {}
Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function(_, cid, mail) mails[#mails + 1] = { cid = cid, mail = mail } end }

local A, B, BILLER = 1, 2, 3
local function bank(src) return Mock.players[src].PlayerData.money.bank end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    mails = {}
    accounts = { ['PF100001'] = 'CID1', ['PF100002'] = 'CID2', ['PF200001'] = 'CIDOFF' }
    for src, money in pairs({ [A] = 1000, [B] = 0, [BILLER] = 0 }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = 0, bank = money }
        p.Functions.GetItemByName = function(name) return name == 'phone' and { name = 'phone' } or nil end
    end
    FakeDB.players['CIDOFF'] = { money = { cash = 0, bank = 50 } }
    FakeDB.society('police', 0)
    Config.BillingCommissions = { police = 0.10 }
    invoices = { [7] = { id = 7, citizenid = 'CID1', amount = 500, society = 'police', sender = 'Officer', sendercitizenid = 'CID3', candecline = 1 } }
end

describe('bank transfers', function()
    it('move money once from sender to receiver', function()
        assert_eq(Mock.callCallback('qb-phone:server:CanTransferMoney', A, 300, 'PF100002'), true)
        assert_eq(bank(A), 700)
        assert_eq(bank(B), 300)
        assert_eq(#LedgerEnv.paid('pfm-phone:transfer:'), 1)
    end)
    it('a partial account number matches nobody', function()
        assert_eq(Mock.callCallback('qb-phone:server:CanTransferMoney', A, 300, '1'), false)
        Mock.fireNet('qb-phone:server:TransferMoney', A, '100002', 300) -- part of PF100002
        assert_eq(bank(A), 1000)
        assert_eq(bank(B), 0)
    end)
    it('reaches an offline receiver through the ledger', function()
        Mock.fireNet('qb-phone:server:TransferMoney', A, 'PF200001', 200)
        assert_eq(bank(A), 800)
        assert_eq(FakeDB.players['CIDOFF'].money.bank, 250)
    end)
    it('refuses overdrafts, bad amounts and sending to yourself', function()
        assert_eq(Mock.callCallback('qb-phone:server:CanTransferMoney', A, 5000, 'PF100002'), false)
        assert_eq(Mock.callCallback('qb-phone:server:CanTransferMoney', A, -50, 'PF100002'), false)
        assert_eq(Mock.callCallback('qb-phone:server:CanTransferMoney', A, 10, 'PF100001'), false)
        assert_eq(bank(A), 1000)
        assert_eq(bank(B), 0)
    end)
end)

describe('invoices', function()
    it('are paid at the stored amount, to the stored business, whatever the client says', function()
        -- a forged call: $1, to another business, commission to someone else
        local ok = Mock.callCallback('qb-phone:server:PayInvoice', A, 'mechanic', 1, 7, 'CID2')
        assert_eq(ok, true)
        assert_eq(bank(A), 500)
        assert_eq(FakeDB.bank_accounts['police'].account_balance, 500)
        assert_eq(bank(BILLER), 50)            -- 10 % commission to the real biller
        assert_eq(bank(B), 0)
        assert_eq(invoices[7], nil)
    end)
    it('are paid once', function()
        Mock.callCallback('qb-phone:server:PayInvoice', A, 'police', 500, 7, 'CID3')
        invoices[7] = { id = 7, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = 'CID3' } -- a replayed row
        Mock.callCallback('qb-phone:server:PayInvoice', A, 'police', 500, 7, 'CID3')
        assert_eq(bank(A), 500)
        assert_eq(FakeDB.bank_accounts['police'].account_balance, 500)
        assert_eq(bank(BILLER), 50)
    end)
    it('nothing is paid without the money, and no commission either', function()
        Mock.players[A].PlayerData.money.bank = 100
        assert_eq(Mock.callCallback('qb-phone:server:PayInvoice', A, 'police', 500, 7, 'CID3'), false)
        assert_eq(bank(A), 100)
        assert_eq(bank(BILLER), 0)
        assert_true(invoices[7] ~= nil)
    end)
    it("someone else's invoice cannot be paid or seen", function()
        assert_eq(Mock.callCallback('qb-phone:server:PayInvoice', B, 'police', 500, 7, 'CID3'), false)
        assert_eq(FakeDB.bank_accounts['police'].account_balance, 0)
    end)
end)
