-- pfm-policejob /paytow and /paylawyer: paid from the department's bank account through the ledger
-- (they used to create $500 each time).
load_resource('tests/lua/ledger_env.lua')
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCore = QBCoreMock
LedgerEnv.load('pfm-policejob', { 'pfm-policejob/config.lua', 'pfm-policejob/server/commands.lua' })

local COP, TOW = 1, 2
local function bank(src) return Mock.players[src].PlayerData.money.bank end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players = {}
    Mock.newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.newPlayer(TOW).PlayerData.job = { name = 'tow', type = 'none', onduty = true }
end

describe('police payments', function()
    it('/paytow comes out of the police account', function()
        FakeDB.society('police', 600)
        Commands.paytow(COP, { tostring(TOW) })
        assert_eq(bank(TOW), 500)
        assert_eq(FakeDB.bank_accounts.police.account_balance, 100)
    end)
    it('an empty police account pays nothing', function()
        FakeDB.society('police', 100)
        Commands.paytow(COP, { tostring(TOW) })
        assert_eq(bank(TOW), 0)
        assert_eq(FakeDB.bank_accounts.police.account_balance, 100)
    end)
end)
