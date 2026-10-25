-- Parallel ledger test, step 2: run by several processes at the same time on one database. Every
-- worker sends the same shared keys (each must move money once in total) and its own unique keys.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetCurrentResourceName() return 'pfm-banking' end
function GetResourceState() return 'started' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')

local W = __TEST_WORKER ~= '' and __TEST_WORKER or 'solo'
local ROUNDS = 60
-- separate servers have different uptimes (the tx id random seed uses it); the mock starts every
-- process at the same game timer
Mock.gameTimer = (tonumber(W:match('%d+')) or 0) * 7919 * 1000

describe('parallel ledger worker ' .. W, function()
    it('every transfer returns a result and none raises', function()
        assert_true(PFLedger.Start())
        local errors = 0
        for i = 1, ROUNDS do
            local calls = {
                { from = 'society:parsoc', to = 'player:PARB0001:bank', amount = 10, key = 'par:shared:soc:' .. i, kind = 'test' },
                { from = 'player:PARA0001:bank', to = 'player:PARB0001:bank', amount = 5, key = 'par:shared:p2p:' .. i, kind = 'test' },
                { from = 'player:PARA0001:bank', to = 'society:parsoc', amount = 1, key = ('par:own:%s:%d'):format(W, i), kind = 'test' },
            }
            for _, opts in ipairs(calls) do
                local ok, res = pcall(PFLedger.Transfer, opts)
                if not ok or type(res) ~= 'table' then
                    errors = errors + 1
                    print('worker ' .. W .. ' error: ' .. tostring(res))
                elseif not res.ok then
                    print(('RESULT %s %s %s'):format(W, opts.key, tostring(res.error)))
                end
            end
        end
        assert_eq(errors, 0)
    end)
end)
