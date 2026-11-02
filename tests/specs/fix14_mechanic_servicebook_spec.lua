-- pf-mechanicjob service book (server/main.lua):
--  MECH-6  one save handler and one read callback (the first copy of the save handler called an
--          undefined function and always errored, so books were never locked to a car);
--  MECH-X7 an entry needs a mechanic at the car and a service book that is free or locked to that
--          car (the first entry locks it); who serviced it, where and the mileage are the server's;
--          at most one entry per player every 10 s;
--  MECH-5  the history is read only by a mechanic at the car, its owner, or the holder of the book
--          locked to it.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local existing = {}
function DoesEntityExist(e) return existing[e] == true end
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end return out end

local entries, owners = {}, {}
MySQL.insert = { await = function(q, p)
    if q:find('INSERT INTO pf_service_book', 1, true) then
        entries[#entries + 1] = { plate = p[1], model = p[2], title = p[5], service = p[6], mileage = p[9], serviced_by = p[10], location = p[11] }
        return #entries
    end
end }
MySQL.scalar = { await = function(q, p)
    if q:find('SELECT citizenid FROM player_vehicles', 1, true) then return owners[p[1]] end
end }
MySQL.query = { await = function(q, p)
    if q:find('FROM pf_service_book WHERE plate = ?', 1, true) then
        local out = {}
        for _, e in ipairs(entries) do if e.plate == p[1] then out[#out + 1] = e end end
        return out
    end
    return {}
end }

-- pfm-inventory SetItemData: sets the info of the item in that slot
local setData = {}
Mock.exportsByResource['pfm-inventory'] = {
    SetItemData = function(_, src, item, key, value, slot)
        local p = Mock.players[src]
        local it = p and p.PlayerData.items[slot]
        if not it or it.name ~= item then return false end
        it[key] = value
        setData[#setData + 1] = { src = src, slot = slot }
        return true
    end,
}

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/shared/performance_parts.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')

local MECH, OWNER, STRANGER = 1, 2, 3
local CAR, OTHER_CAR = 500, 501
local HERE = vector3(10.0, 10.0, 10.0)
local FORM = { title = 'Oil change', service = 'Changed oil', serviced_by = 'Benny (Bennys)', location = 'Paleto', mileage = 12, model = 'Sultan' }

local function save(src, plate, slot, data) Mock.fireNet('pf_mech:service:addEntry', src, plate, data or FORM, slot) end
local function history(src, plate) return Mock.callCallback('pf_mech:service:get', src, plate) end
local function book(p, slot, info) p.PlayerData.items[slot] = { name = 'service_book', slot = slot, amount = 1, info = info or {} } end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100
    Mock.players, Mock.coords, Mock.plates = {}, {}, {}
    states, entries, setData = {}, {}, {}
    existing = { [CAR] = true, [OTHER_CAR] = true }
    owners = { MYCAR001 = 'OWN1' }
    local m = Mock.newPlayer(MECH, 'MECH1')
    m.PlayerData.job = { name = 'mechanic', label = 'Mechanic', onduty = true }
    m.PlayerData.charinfo = { firstname = 'Sam', lastname = 'Wrench' }
    Mock.newPlayer(OWNER, 'OWN1')
    Mock.newPlayer(STRANGER, 'STR1')
    for _, e in ipairs({ MECH, OWNER, STRANGER, CAR }) do Mock.coords[e] = HERE end
    Mock.coords[OTHER_CAR] = vector3(800.0, 800.0, 10.0)
    Mock.plates[CAR], Mock.plates[OTHER_CAR] = 'MYCAR001', 'OTHER001'
    Entity(CAR).state.mileage = 4321.7
    for _, src in ipairs({ MECH, OWNER, STRANGER }) do Mock.fireEvent('playerDropped', src) end
end

describe('MECH-6 one handler each', function()
    it('a single save handler and read callback, and a save no longer errors', function()
        assert_eq(#Mock.netHandlerList['pf_mech:service:addEntry'], 1)
        book(Mock.players[MECH], 3)
        save(MECH, 'MYCAR001', 3)              -- the old first handler raised 'attempt to call a nil value (isMechanic)'
        assert_eq(#entries, 1)
    end)
end)

describe('MECH-X7 writing an entry', function()
    it('needs the car right there and a service book', function()
        save(MECH, 'MYCAR001', 3)              -- no book
        book(Mock.players[MECH], 3)
        save(MECH, 'OTHER001', 3)              -- 800 m away
        save(MECH, 'NOSUCH01', 3)              -- no such car
        save(STRANGER, 'MYCAR001', 3)          -- not a mechanic
        assert_eq(#entries, 0)
    end)

    it('who, where and the mileage come from the server, and the book is locked to the car', function()
        book(Mock.players[MECH], 3)
        save(MECH, 'MYCAR001', 3)
        local e = entries[1]
        assert_eq(e.plate, 'MYCAR001')
        assert_eq(e.serviced_by, 'Sam Wrench (' .. Config.BusinessBranding.mechanic.name .. ')')
        assert_eq(e.location, Config.BusinessBranding.mechanic.name)
        assert_eq(e.mileage, 4321)
        assert_eq(e.title, 'Oil change')
        assert_eq(Mock.players[MECH].PlayerData.items[3].info.lockedPlate, 'MYCAR001')
        assert_eq(#setData, 1)
    end)

    it('a book locked to another car is refused; one entry per 10 s', function()
        book(Mock.players[MECH], 3, { lockedPlate = 'ELSE0001' })
        save(MECH, 'MYCAR001', 3)
        assert_eq(#entries, 0)
        book(Mock.players[MECH], 4)
        save(MECH, 'MYCAR001', 4)
        save(MECH, 'MYCAR001', 4)
        assert_eq(#entries, 1)
        Mock.clock = Mock.clock + 11
        save(MECH, 'MYCAR001', 4)
        assert_eq(#entries, 2)
        assert_eq(Mock.players[MECH].PlayerData.items[3].info.lockedPlate, 'ELSE0001', 'the other book is untouched')
    end)

    it('required text is still required', function()
        book(Mock.players[MECH], 3)
        save(MECH, 'MYCAR001', 3, { title = '  ', service = 'x' })
        save(MECH, 'MYCAR001', 3, { title = { 'x' }, service = 'x' })
        assert_eq(#entries, 0)
    end)
end)

describe('MECH-5 reading the history', function()
    local function writeOne()
        book(Mock.players[MECH], 3)
        save(MECH, 'MYCAR001', 3)
        Mock.clock = Mock.clock + 11
    end

    it('a stranger reads nothing; the owner, a mechanic at the car, and the book holder read it', function()
        writeOne()
        assert_eq(#history(STRANGER, 'MYCAR001'), 0)
        assert_eq(#history(OWNER, 'MYCAR001'), 1)
        assert_eq(#history(MECH, 'MYCAR001'), 1)
        Mock.coords[MECH] = vector3(500.0, 0.0, 10.0)
        assert_eq(#history(MECH, 'MYCAR001'), 1, 'holds the book locked to it')
        Mock.players[MECH].PlayerData.items[3] = nil
        assert_eq(#history(MECH, 'MYCAR001'), 0, 'away from the car without the book')
        book(Mock.players[STRANGER], 1, { lockedPlate = 'MYCAR001' })
        assert_eq(#history(STRANGER, 'MYCAR001'), 1)
    end)
end)
