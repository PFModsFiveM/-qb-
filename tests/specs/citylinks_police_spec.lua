-- pfm-policejob → pf-services: a jail sentence is a court lead with public facts only, /911p reaches
-- the police Dispatch app, and drugs an officer takes from a searched suspect are one drug-bust lead.
load_resource('tests/lua/fivem_mocks.lua')
Emits, Requests = {}, {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, data = data, opts = opts or {} } return #Emits end,
    CreateRequest = function(_, opts) Requests[#Requests + 1] = opts return { ok = true, id = #Requests } end,
}
local listeners = {}
Mock.exportsByResource['pfm-inventory'] = {
    AddListener = function(_, kind, fn) listeners[#listeners + 1] = { kind = kind, fn = fn } return #listeners end,
    OpenInventory = function() end, OpenInventoryById = function() end,
    AddItem = function() return true end, RemoveItem = function() return true end,
}
function GetResourceState(name) return (name == 'pf-services' or name == 'pfm-inventory') and 'started' or 'missing' end
local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = fn end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Shared.Items.cokebaggy = { name = 'cokebaggy', label = 'Bag of Coke' }
QBCoreMock.Shared.Items.meth = { name = 'meth', label = 'Meth' }

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/interactions.lua')
load_resource('pfm-policejob/server/commands.lua')
load_resource('pfm-policejob/server/evidence.lua')

local COP, CIV = 1, 2
local function move(from, to, slot, name, amount)
    local items = {}
    items[slot] = { name = name, amount = amount, slot = slot }
    PoliceOnItemMoved('moved', { fromType = 'player', toType = 'player', fromId = from, toId = to, fromSlot = 3, toSlot = slot,
        amount = amount, toInventory = { items = items } })
end
local function flush() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Emits, Requests, timers = {}, {}, {}, {}, {}
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 2 } }
    local civ = Mock.newPlayer(CIV, 'CIVCID')
    civ.PlayerData.charinfo = { firstname = 'Jane', lastname = 'Doe' }
    Mock.coords[COP] = vector3(10, 10, 10)
    Mock.coords[CIV] = vector3(11, 10, 10)
end

describe('jail sentence', function()
    it('is one court lead with the public facts only', function()
        Mock.fireNet('police:server:JailPlayer', COP, CIV, 30)
        assert_eq(#Emits, 1)
        local e = Emits[1]
        assert_eq(e.kind, 'police.sentenced')
        assert_eq(e.data.name, 'Jane Doe')
        assert_eq(e.data.months, 30)
        assert_eq(e.data.citizenid, nil)
        assert_eq(e.opts.actor, 'COPCID')
        assert_eq(e.opts.dedupe, 'CIVCID')
    end)
    it('no lead when the jailing is refused', function()
        Mock.players[COP].PlayerData.job.onduty = false
        Mock.fireNet('police:server:JailPlayer', COP, CIV, 30)
        assert_eq(#Emits, 0)
    end)
end)

describe('/911p', function()
    it('becomes the caller\'s one police dispatch request at the server position', function()
        Commands['911p'](CIV, { 'shots', 'fired' })
        assert_eq(#Requests, 1)
        local r = Requests[1]
        assert_eq(r.kind, 'police.assist')
        assert_eq(r.ref.type, 'citizen:police.assist')
        assert_eq(r.ref.id, 'CIVCID')
        assert_eq(r.requester, 'CIVCID')
        assert_eq(r.details, 'shots fired')
        assert_near(r.coords.x, 11, 0.01)
    end)
end)

describe('drug seizure', function()
    it('the seizure listener is registered with the inventory', function()
        local found = false
        for _, l in ipairs(listeners) do if l.kind == 'ItemMoved' and l.fn == PoliceOnItemMoved then found = true end end
        assert_true(found)
    end)
    it('drugs an officer takes from a suspect are one lead with the totals', function()
        move(CIV, COP, 5, 'cokebaggy', 4)
        move(CIV, COP, 6, 'meth', 2)
        move(CIV, COP, 7, 'cokebaggy', 1)
        assert_eq(#Emits, 0)                                                 -- collected for the window
        flush()
        assert_eq(#Emits, 1)
        local e = Emits[1]
        assert_eq(e.kind, 'crime.drugs.bust')
        assert_eq(e.data.total, 7)
        assert_eq(e.data.items[1].label, 'Bag of Coke')
        assert_eq(e.data.items[1].amount, 5)
        assert_eq(e.opts.actor, 'COPCID')
        assert_near(e.opts.coords.x, 10, 0.01)
    end)
    it('no lead for other items, off-duty officers, civilians or an officer\'s own items', function()
        move(CIV, COP, 5, 'sandwich', 4)                                    -- not a drug
        move(COP, COP, 5, 'cokebaggy', 4)                                   -- inside own pockets
        move(COP, CIV, 5, 'cokebaggy', 4)                                   -- a civilian taking from a cop
        Mock.players[COP].PlayerData.job.onduty = false
        move(CIV, COP, 5, 'cokebaggy', 4)
        flush()
        assert_eq(#Emits, 0)
    end)
end)
