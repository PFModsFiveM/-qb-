-- pfm-core /givemoney and /setmoney: bank and cash changes are journaled in the ledger (system:admin)
-- so reconciliation can account for them.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
load_resource('pfm-core/server/commands.lua')
local commands = Mock.rawCommands -- QBCore.Commands.Add registers each command with RegisterCommand

local ADMIN, P = 9, 1
local function money() return Mock.players[P].PlayerData.money end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players = {}
    Mock.newPlayer(ADMIN)
    Mock.newPlayer(P).PlayerData.money = { cash = 100, bank = 1000, crypto = 0 }
end

describe('admin money', function()
    it('/givemoney bank is a journaled ledger credit', function()
        commands.givemoney(ADMIN, { tostring(P), 'bank', '500' })
        assert_eq(money().bank, 1500)
        assert_eq(#LedgerEnv.paid('admin:'), 1)
    end)
    it('/setmoney moves the difference through the ledger, either way', function()
        commands.setmoney(ADMIN, { tostring(P), 'cash', '40' })
        assert_eq(money().cash, 40)
        commands.setmoney(ADMIN, { tostring(P), 'bank', '2500' })
        assert_eq(money().bank, 2500)
        assert_eq(#LedgerEnv.paid('admin:'), 2)
    end)
    it('refuses negative or missing amounts', function()
        commands.givemoney(ADMIN, { tostring(P), 'bank', '-500' })
        commands.givemoney(ADMIN, { tostring(P), 'bank' })
        commands.setmoney(ADMIN, { tostring(P), 'bank', '-1' })
        assert_eq(money().bank, 1000)
    end)
    it('other money types keep using the player functions', function()
        commands.givemoney(ADMIN, { tostring(P), 'crypto', '2' })
        assert_eq(money().crypto, 2)
        assert_eq(#LedgerEnv.paid('admin:'), 0)
    end)
end)
