-- pfm-vehiclesales Used Cars app (pf-devices): every listing with price, tax and the seller's name
-- and phone (not their other data), marks the player's own; only the seller reprices their listing,
-- within bounds; listing changes refresh open apps; a deleted character's listings are removed.
load_resource('tests/lua/fivem_mocks.lua')
function GetResourceState(name) return (name == 'pf-devices' or name == 'pf-government') and 'started' or 'missing' end
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', brand = 'Karin', price = 20000, category = 'sports' } }

local listings = {
    { id = 2, seller = 'CID3', price = 10000, description = '<b>Clean</b>', plate = 'USED1', model = 'sultan', occasionid = 'OC1001' },
    { id = 1, seller = 'CID1', price = 5000, description = 'mine', plate = 'USED2', model = 'sultan', occasionid = 'OC1002' },
}
local deleted = {}
MySQL.query = setmetatable({ await = function(sql, params)
    if sql:find('FROM occasion_vehicles ORDER BY id DESC', 1, true) then return listings end
    if sql:find('SELECT citizenid, charinfo FROM players WHERE citizenid IN', 1, true) then
        local out = {}
        for _, cid in ipairs(params) do
            out[#out + 1] = { citizenid = cid, charinfo = json.encode({ firstname = 'Sam', lastname = cid, phone = '555' .. cid:sub(-1), account = 'SECRET', birthdate = 'x' }) }
        end
        return out
    end
    if sql:find('DELETE FROM occasion_vehicles WHERE seller = ?', 1, true) then
        local n = 0
        for i = #listings, 1, -1 do if listings[i].seller == params[1] then table.remove(listings, i) n = n + 1 end end
        deleted[#deleted + 1] = params[1]
        return { affectedRows = n }
    end
    return {}
end }, { __call = function() return {} end })
MySQL.update = setmetatable({ await = function(sql, params)
    if sql:find('UPDATE occasion_vehicles SET price = ? WHERE occasionid = ? AND seller = ?', 1, true) then
        for _, l in ipairs(listings) do if l.occasionid == params[2] and l.seller == params[3] then l.price = params[1] return 1 end end
        return 0
    end
    return 0
end }, { __call = function() return 0 end })

local registered, handlers, broadcasts = {}, {}, 0
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) registered[def.id] = def return true end,
    RegisterAppHandlers = function(_, id, map) handlers[id] = map return true end,
    Broadcast = function() broadcasts = broadcasts + 1 return true end,
}
Mock.exportsByResource['pf-government'] = { CalculateTax = function(_, amount) return amount * 8 / 100 end }

function GetCurrentResourceName() return 'pfm-vehiclesales' end
Config = nil
load_resource('pfm-vehiclesales/config.lua')
load_resource('pfm-vehiclesales/server/apps.lua')

local ME, OTHER = 1, 3
local function app(method, src, payload) return handlers.usedcars[method](src, payload or {}) end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(ME)
    Mock.newPlayer(OTHER)
    broadcasts = 0
end

describe('Used Cars app', function()
    it('is registered for everyone on both devices, on start and when pf-devices is ready', function()
        Mock.eventHandlers['onResourceStart']('pfm-vehiclesales')
        assert_true(registered.usedcars.access.anyone)
        assert_eq(registered.usedcars.devices[2], 'computer')
        registered = {}
        Mock.eventHandlers['pf-devices:server:ready']()
        assert_true(registered.usedcars ~= nil)
    end)
    it('lists every car with price, tax and the seller contact only, and marks my own', function()
        local res = app('list', ME)
        assert_true(res.ok)
        assert_eq(#res.listings, 2)
        local theirs, mine = res.listings[1], res.listings[2]
        assert_eq(theirs.label, 'Karin Sultan')
        assert_eq(theirs.price, 10000)
        assert_eq(theirs.tax, 800)
        assert_eq(theirs.seller, 'Sam CID3')
        assert_eq(theirs.phone, '5553')
        assert_eq(theirs.account, nil)
        assert_false(theirs.mine)
        assert_true(mine.mine)
        assert_eq(res.lots[1].coords.x, math.floor(Config.Zones.SandyOccasions.BuyVehicle.x * 100 + 0.5) / 100)
    end)
    it('only the seller changes the price of a listing, within bounds', function()
        assert_eq(app('reprice', ME, { id = 'OC1001', price = 1 }).error, 'not_yours')
        assert_eq(listings[1].price, 10000)
        assert_true(app('reprice', ME, { id = 'OC1002', price = 4500 }).ok)
        assert_eq(listings[2].price, 4500)
        assert_eq(broadcasts, 1)
        assert_eq(#Mock.clientEventsNamed('qb-occasion:client:refreshVehicles'), 1)
        assert_eq(app('reprice', ME, { id = 'OC1002', price = 0 }).error, 'bad_price')
        assert_eq(app('reprice', ME, { id = 'OC1002', price = 10.5 }).error, 'bad_price')
        assert_eq(app('reprice', ME, { id = 'OC1002', price = '99' }).error, 'bad_price')
        assert_eq(app('reprice', ME, { id = 'OC1002', price = 60000000 }).error, 'bad_price')
        assert_eq(app('reprice', ME, { price = 100 }).error, 'bad_request')
        assert_eq(listings[2].price, 4500)
    end)
    it("a deleted character's listings are removed; a bad id removes nothing", function()
        Mock.eventHandlers['pfm-core:server:characterDeleted']('')
        Mock.eventHandlers['pfm-core:server:characterDeleted'](false)
        assert_eq(#deleted, 0)
        Mock.eventHandlers['pfm-core:server:characterDeleted']('CID3')
        assert_eq(deleted[1], 'CID3')
        assert_eq(#listings, 1)
        assert_eq(listings[1].seller, 'CID1')
        assert_eq(broadcasts, 1)
    end)
end)
