-- pf-mechanicjob: the old client-built invoice handlers are gone. (The roadside service itself is
-- covered by fix14_mechanic_roadside_spec.lua: the server spawns the call's car and pays for a real
-- repair of it.)
describe('mechanic invoices', function()
    it('the client-built invoice handlers no longer exist', function()
        -- check the source: these must not come back
        local src = __readfile('[pfscripts]/pf-mechanicjob/server/main.lua')
        assert_eq(src:find("RegisterNetEvent('pos:customerPay'", 1, true), nil)
        assert_eq(src:find("RegisterNetEvent('pos:requestCharge'", 1, true), nil)
    end)
end)
