-- pfm-banking: legacy-account callbacks answer bad payloads instead of raising errors.
load_resource('tests/lua/ledger_env.lua')

local P = 1
BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players = {}
    Mock.newPlayer(P).PlayerData.money = { cash = 0, bank = 100 }
end

describe('bad payloads', function()
    it('orderCard, addUser and removeUser without data fail cleanly', function()
        for _, name in ipairs({ 'qb-banking:server:orderCard', 'qb-banking:server:addUser', 'qb-banking:server:removeUser' }) do
            local res = Mock.callCallback(name, P, nil)
            assert_eq(type(res), 'table', name)
            assert_eq(res.success, false, name)
        end
    end)
    it('a user to add must be a citizen id', function()
        local res = Mock.callCallback('qb-banking:server:addUser', P, { userName = { 'x' }, accountName = 'acc' })
        assert_eq(res.success, false)
    end)
end)
