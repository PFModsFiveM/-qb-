-- What a deleted character leaves behind, cleared on pfm-core's server-only
-- 'pfm-core:server:characterDeleted' (citizenid, deleted = { apartments, plates }):
--   pf-stores (store owner cleared, the store's money untouched), pf-government (staff role, registry
--   owner -> 'unowned', utility/property owner), pf-mechanicjob (vehicle_diagnostics), pfm-phone
--   (gallery, tweets), pfm-inventory (trunk/glovebox stashes of the plates), pf-news (pending
--   bonuses cancelled, ads anonymised). Each one: ignores players, is idempotent, and survives a
--   failing table.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')

local db, failing
local function resetDb()
    failing = {}
    db = {
        stores = {
            { store_id = 'ltd_1', owner_citizenid = 'GONE1', purchased_at = 5, balance = 900 },
            { store_id = 'ltd_2', owner_citizenid = 'KEEP1', purchased_at = 6, balance = 50 },
        },
        staff = { { citizenid = 'GONE1', role = 'mayor' }, { citizenid = 'KEEP1', role = 'clerk' } },
        businesses = {
            { business_id = 'store:ltd_1', owner_id = 'GONE1', owner_name = 'Gone Person' },
            { business_id = 'restaurant:bs', owner_id = 'KEEP1', owner_name = 'Keep' },
        },
        utilities = {
            { property_type = 'property', property_id = 'house7', owner_id = 'GONE1', owner_name = 'Gone Person' },
            { property_type = 'business', property_id = 'store:ltd_1', owner_id = 'GONE1', owner_name = 'Gone Person' },
            { property_type = 'property', property_id = 'house8', owner_id = 'KEEP1', owner_name = 'Keep' },
        },
        diagnostics = {
            { plate = 'GONE0001', citizenid = 'GONE1' },
            { plate = 'GONE0002', citizenid = nil },   -- no citizenid on the row: found by plate
            { plate = 'GO NE3', citizenid = nil },     -- (as player_vehicles has it)
            { plate = 'GONE3', citizenid = nil },      -- (as garage_sync writes it)
            { plate = 'KEEP0001', citizenid = 'KEEP1' },
            -- sold by GONE1 to KEEP1: the row still names the seller (a sale only updates player_vehicles)
            { plate = 'SOLD0001', citizenid = 'GONE1', nos = 3 },
        },
        gallery = { { citizenid = 'GONE1', image = 'a.png' }, { citizenid = 'KEEP1', image = 'b.png' } },
        tweets = { { citizenid = 'GONE1', tweetId = 'T1' }, { citizenid = 'KEEP1', tweetId = 'T2' } },
        inventories = {
            ['trunk-GONE0001'] = true, ['glovebox-GONE0001'] = true, ['trunk-GONE0002 '] = true,
            ['trunk-KEEP0001'] = true, ['apartment1234'] = true,
        },
        payouts = {
            { article_id = 1, citizenid = 'GONE1', state = 'pending' },
            { article_id = 2, citizenid = 'GONE1', state = 'paid' },
            { article_id = 3, citizenid = 'KEEP1', state = 'pending' },
        },
        ads = { { id = 1, buyer_cid = 'GONE1', buyer_name = 'Gone Person', business_id = 'store:ltd_1', status = 'active' },
            { id = 2, buyer_cid = 'KEEP1', buyer_name = 'Keep', business_id = 'restaurant:bs', status = 'active' } },
    }
end

local function guard(name) if failing[name] then error('table ' .. name .. " doesn't exist") end end

-- updates `rows` matching pred with fn; returns the count
local function each(rows, pred, fn)
    local n = 0
    for i = #rows, 1, -1 do
        if pred(rows[i]) then n = n + 1; if fn then fn(rows[i], i) end end
    end
    return n
end
local function remove(rows, pred) return each(rows, pred, function(_, i) table.remove(rows, i) end) end

FakeDB.extraPatterns = {
    -- pf-stores
    { 'SELECT store_id FROM pf_stores WHERE owner_citizenid = ?', function(p)
        guard('pf_stores')
        local out = {}
        for _, s in ipairs(db.stores) do if s.owner_citizenid == p[1] then out[#out + 1] = { store_id = s.store_id } end end
        return out
    end },
    { 'UPDATE pf_stores SET owner_citizenid = NULL, purchased_at = NULL WHERE store_id = ? AND owner_citizenid = ?', function(p)
        return each(db.stores, function(s) return s.store_id == p[1] and s.owner_citizenid == p[2] end,
            function(s) s.owner_citizenid, s.purchased_at = nil, nil end)
    end },
    -- pf-government
    { 'DELETE FROM pf_gov_staff WHERE citizenid = ?', function(p)
        guard('pf_gov_staff')
        return remove(db.staff, function(r) return r.citizenid == p[1] end)
    end },
    { "UPDATE pf_gov_businesses SET owner_id = 'unowned', owner_name = 'Unassigned', updated_at = NOW() WHERE owner_id = ?", function(p)
        guard('pf_gov_businesses')
        return each(db.businesses, function(r) return r.owner_id == p[1] end, function(r) r.owner_id, r.owner_name = 'unowned', 'Unassigned' end)
    end },
    { 'UPDATE pf_gov_utilities SET owner_id = NULL, owner_name = NULL WHERE owner_id = ?', function(p)
        guard('pf_gov_utilities')
        return each(db.utilities, function(r) return r.owner_id == p[1] end, function(r) r.owner_id, r.owner_name = nil, nil end)
    end },
    -- pf-mechanicjob
    { 'DELETE FROM vehicle_diagnostics WHERE citizenid = ?', function(p)
        return remove(db.diagnostics, function(r) return r.citizenid == p[1] end)
    end },
    { 'DELETE FROM vehicle_diagnostics WHERE plate = ?', function(p)
        guard('vehicle_diagnostics')
        return remove(db.diagnostics, function(r) return r.plate == p[1] end)
    end },
    -- pfm-phone
    { 'DELETE FROM phone_gallery WHERE citizenid = ?', function(p)
        guard('phone_gallery')
        return remove(db.gallery, function(r) return r.citizenid == p[1] end)
    end },
    { 'DELETE FROM phone_tweets WHERE citizenid = ?', function(p)
        guard('phone_tweets')
        return remove(db.tweets, function(r) return r.citizenid == p[1] end)
    end },
    -- pfm-inventory
    { 'DELETE FROM inventories WHERE identifier = ?', function(p)
        local had = db.inventories[p[1]] and 1 or 0
        db.inventories[p[1]] = nil
        return { affectedRows = had }
    end },
    -- pf-news
    { "UPDATE pf_news_payouts SET state = 'cancelled', error = 'character_deleted' WHERE citizenid = ? AND state = 'pending'", function(p)
        guard('pf_news_payouts')
        return each(db.payouts, function(r) return r.citizenid == p[1] and r.state == 'pending' end, function(r) r.state = 'cancelled' end)
    end },
    { "UPDATE pf_news_ads SET buyer_cid = '', buyer_name = NULL WHERE buyer_cid = ?", function(p)
        guard('pf_news_ads')
        return each(db.ads, function(r) return r.buyer_cid == p[1] end, function(r) r.buyer_cid, r.buyer_name = '', nil end)
    end },
}

-- load each resource's listener and keep its handler (the mock keeps one handler per event name)
local EV = 'pfm-core:server:characterDeleted'
local handlers = {}
local function loadHandler(name, file)
    Mock.eventHandlers[EV] = nil
    load_resource(file)
    handlers[name] = Mock.eventHandlers[EV]
    assert(handlers[name], name .. ' registers no cleanup handler')
end
loadHandler('stores', '[pfscripts]/pf-stores/server_characters.lua')
loadHandler('gov', '[pfscripts]/pf-government/server/characters.lua')
loadHandler('mech', '[pfscripts]/pf-mechanicjob/server/characters.lua')
loadHandler('phone', 'pfm-phone/server/characters.lua')
Inventories = {}
loadHandler('inventory', 'pfm-inventory/server/characters.lua')
loadHandler('news', '[pfscripts]/pf-news/server/characters.lua')
local order = { 'stores', 'gov', 'mech', 'phone', 'inventory', 'news' }

local DELETED = { apartments = { 'apartment1234' }, plates = { 'GONE0001', 'GONE0002', 'GO NE3' } }

-- as FiveM runs every resource's handler for one TriggerEvent (server side: no player source)
local function fire(src, ...)
    for _, name in ipairs(order) do
        source = src
        local ok, err = pcall(handlers[name], ...)
        source = nil
        if not ok then error(name .. ': ' .. tostring(err), 2) end
    end
end

local function loadInventories()
    Inventories = {}
    for id in pairs(db.inventories) do Inventories[id] = { items = { { name = 'goldbar', amount = 1, slot = 1 } }, isOpen = false } end
end

local function snapshot()
    local parts = {}
    for _, s in ipairs(db.stores) do parts[#parts + 1] = s.store_id .. '=' .. tostring(s.owner_citizenid) end
    parts[#parts + 1] = 'staff' .. #db.staff
    for _, b in ipairs(db.businesses) do parts[#parts + 1] = b.business_id .. '=' .. b.owner_id end
    for _, u in ipairs(db.utilities) do parts[#parts + 1] = u.property_id .. '=' .. tostring(u.owner_id) end
    parts[#parts + 1] = 'diag' .. #db.diagnostics .. ' gal' .. #db.gallery .. ' tw' .. #db.tweets
    local inv = {}
    for id in pairs(db.inventories) do inv[#inv + 1] = id end
    table.sort(inv)
    parts[#parts + 1] = table.concat(inv, ',')
    for _, p in ipairs(db.payouts) do parts[#parts + 1] = p.article_id .. '=' .. p.state end
    for _, a in ipairs(db.ads) do parts[#parts + 1] = 'ad' .. a.id .. '=' .. a.buyer_cid end
    return table.concat(parts, ' ')
end

BeforeEach = function()
    Mock.reset()
    resetDb()
    FakeDB.log = {}
    loadInventories()
end

describe('a deleted character', function()
    it('pf-stores: the store is unowned again and its money stays with the store', function()
        fire(nil, 'GONE1', DELETED)
        assert_eq(db.stores[1].owner_citizenid, nil)
        assert_eq(db.stores[1].purchased_at, nil)
        assert_eq(db.stores[1].balance, 900)
        assert_eq(db.stores[2].owner_citizenid, 'KEEP1')
        local refresh = Mock.clientEventsNamed('pf-stores:client:onStorePurchased')
        assert_eq(#refresh, 1)
        assert_eq(refresh[1].args[1], 'ltd_1')
        for _, c in ipairs(FakeDB.log) do
            assert_true(not c:find('bank_accounts', 1, true) and not c:find('pf_transactions', 1, true), 'no money statement: ' .. c)
        end
    end)

    it('pf-government: staff role, registry owner and property records', function()
        fire(nil, 'GONE1', DELETED)
        assert_eq(#db.staff, 1)
        assert_eq(db.staff[1].citizenid, 'KEEP1')
        assert_eq(db.businesses[1].owner_id, 'unowned')
        assert_eq(db.businesses[1].owner_name, 'Unassigned')
        assert_eq(db.businesses[2].owner_id, 'KEEP1')
        assert_eq(db.utilities[1].owner_id, nil)
        assert_eq(db.utilities[2].owner_id, nil)
        assert_eq(db.utilities[3].owner_id, 'KEEP1')
    end)

    it('pf-mechanicjob: diagnostics of the plates the character owned', function()
        fire(nil, 'GONE1', DELETED)
        assert_eq(#db.diagnostics, 2)
        assert_eq(db.diagnostics[1].plate, 'KEEP0001')
    end)

    it('pf-mechanicjob: a car the character sold keeps its diagnostics (its row still names the seller)', function()
        fire(nil, 'GONE1', DELETED)
        local sold
        for _, r in ipairs(db.diagnostics) do if r.plate == 'SOLD0001' then sold = r end end
        assert_true(sold ~= nil, 'the new owner\'s row survives')
        assert_eq(sold.nos, 3)
    end)

    it('pfm-phone: gallery photos and tweets', function()
        fire(nil, 'GONE1', DELETED)
        assert_eq(#db.gallery, 1)
        assert_eq(db.gallery[1].citizenid, 'KEEP1')
        assert_eq(#db.tweets, 1)
        assert_eq(db.tweets[1].tweetId, 'T2')
    end)

    it('pfm-inventory: trunk and glovebox of every plate (also a padded stash name), nothing else', function()
        fire(nil, 'GONE1', DELETED)
        assert_eq(db.inventories['trunk-GONE0001'], nil)
        assert_eq(db.inventories['glovebox-GONE0001'], nil)
        assert_eq(db.inventories['trunk-GONE0002 '], nil)
        assert_eq(Inventories['trunk-GONE0001'], nil)
        assert_eq(Inventories['trunk-GONE0002 '], nil)
        assert_true(db.inventories['trunk-KEEP0001'] ~= nil)
        assert_true(Inventories['trunk-KEEP0001'] ~= nil)
        assert_true(db.inventories['apartment1234'] ~= nil, 'apartments are pfm-apartments\' job')
    end)

    it('pfm-inventory: a trunk someone has open is emptied, not pulled from under them', function()
        Inventories['trunk-GONE0001'].isOpen = 4
        fire(nil, 'GONE1', DELETED)
        assert_true(Inventories['trunk-GONE0001'] ~= nil)
        assert_eq(next(Inventories['trunk-GONE0001'].items), nil)
    end)

    it('pf-news: pending bonuses cancelled, paid ones kept, ads anonymised', function()
        fire(nil, 'GONE1', DELETED)
        assert_eq(db.payouts[1].state, 'cancelled')
        assert_eq(db.payouts[2].state, 'paid')
        assert_eq(db.payouts[3].state, 'pending')
        assert_eq(db.ads[1].buyer_cid, '')
        assert_eq(db.ads[1].buyer_name, nil)
        assert_eq(db.ads[1].status, 'active')
        assert_eq(db.ads[2].buyer_cid, 'KEEP1')
    end)

    it('running it twice changes nothing more', function()
        fire(nil, 'GONE1', DELETED)
        local after = snapshot()
        Mock.reset()
        fire(nil, 'GONE1', DELETED)
        assert_eq(snapshot(), after)
        assert_eq(#Mock.clientEventsNamed('pf-stores:client:onStorePurchased'), 0)
    end)

    it('one failing table does not stop the others', function()
        failing = { pf_stores = true, pf_gov_staff = true, vehicle_diagnostics = true, phone_gallery = true, pf_news_payouts = true }
        fire(nil, 'GONE1', DELETED)
        assert_eq(db.stores[1].owner_citizenid, 'GONE1')
        assert_eq(#db.staff, 2)
        assert_eq(db.businesses[1].owner_id, 'unowned')
        assert_eq(db.utilities[1].owner_id, nil)
        assert_eq(#db.tweets, 1)
        assert_eq(db.inventories['trunk-GONE0001'], nil)
        assert_eq(db.ads[1].buyer_cid, '')
    end)

    it('works without plates (an older pfm-core) for everything not keyed by plate', function()
        fire(nil, 'GONE1')
        assert_eq(db.stores[1].owner_citizenid, nil)
        assert_eq(#db.gallery, 1)
        assert_true(db.inventories['trunk-GONE0001'] ~= nil)
    end)
end)

describe('the cleanup event', function()
    it('ignores a call from a player', function()
        local before = snapshot()
        fire(3, 'KEEP1', { plates = { 'KEEP0001' } })
        assert_eq(snapshot(), before)
        assert_eq(#FakeDB.log, 0)
    end)

    it('ignores a bad citizenid', function()
        local before = snapshot()
        for _, bad in ipairs({ '', 12, { 'GONE1' }, "GONE1' OR 1=1", string.rep('A', 51) }) do
            fire(nil, bad, DELETED)
        end
        assert_eq(snapshot(), before)
    end)

    it('ignores plates that are not strings or too long', function()
        fire(nil, 'GONE1', { plates = { 5, { 'KEEP0001' }, string.rep('K', 40) } })
        assert_true(db.inventories['trunk-KEEP0001'] ~= nil)
    end)
end)
