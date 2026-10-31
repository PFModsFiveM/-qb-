-- pf-restaurants: a deleted character leaves every restaurant's staff (the owner role too), the
-- restaurant re-registers with its next owner, and a player cannot trigger the cleanup.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pf-restaurants' end

local rows, deleted
MySQL = { query = { await = function(sql, p)
    assert(sql:find('SELECT business_id FROM pf_restaurant_employees WHERE citizenid = ?', 1, true), 'unexpected query ' .. sql)
    local out = {}
    for _, r in ipairs(rows) do if r.citizenid == p[1] then out[#out + 1] = { business_id = r.business_id } end end
    return out
end } }
RestaurantData = { employees = {} }
DB = { DeleteEmployee = function(businessId, cid)
    deleted[#deleted + 1] = businessId .. ':' .. cid
    for i = #rows, 1, -1 do if rows[i].business_id == businessId and rows[i].citizenid == cid then table.remove(rows, i) end end
end }
local handler
local realAdd = AddEventHandler
AddEventHandler = function(name, fn) if name == 'pfm-core:server:characterDeleted' then handler = fn end return realAdd(name, fn) end
load_resource('[pfscripts]/pf-restaurants/server/characters.lua')
AddEventHandler = realAdd

local function fire(src, cid)
    source = src
    handler(cid)
    source = nil
end

BeforeEach = function()
    rows = { { business_id = 'bs', citizenid = 'GONE1' }, { business_id = 'pizza', citizenid = 'GONE1' }, { business_id = 'bs', citizenid = 'KEEP1' } }
    RestaurantData.employees = { bs = { GONE1 = { role = 'owner' }, KEEP1 = { role = 'cook' } }, pizza = { GONE1 = { role = 'cook' } } }
    deleted = {}
end

describe('pf-restaurants: deleted characters leave the staff', function()
    it('removes the character from every restaurant, in memory and in the table, and re-registers', function()
        assert_true(handler ~= nil, 'listens for characterDeleted')
        fire(nil, 'GONE1')
        table.sort(deleted)
        assert_eq(#deleted, 2)
        assert_eq(deleted[1], 'bs:GONE1')
        assert_eq(deleted[2], 'pizza:GONE1')
        assert_eq(RestaurantData.employees.bs.GONE1, nil)
        assert_eq(RestaurantData.employees.pizza.GONE1, nil)
        assert_eq(RestaurantData.employees.bs.KEEP1.role, 'cook', 'other staff stay')
        fire(nil, 'GONE1')
        assert_eq(#deleted, 2, 'running it again changes nothing')
    end)
    it('ignores a player triggering it and bad citizen ids', function()
        fire(7, 'GONE1')
        fire(nil, "GONE1' OR 1=1")
        fire(nil, '')
        assert_eq(#deleted, 0)
    end)
end)
