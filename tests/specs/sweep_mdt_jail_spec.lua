-- pf-policemdt-DEV built-in jail: the confiscated items are the server's inventory (the jailed
-- player's client used to send the list that was "restored" on release), and they come back only
-- when the sentence is over, not when the client says so.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

local CHARGES = { { code = 'J1', name = 'Robbery', fineAmount = 0, bailAmount = 0, prisonTime = 10 } }
local function answer(sql)
    if sql:find('FROM pf_mdt_charges', 1, true) then return CHARGES end
    if sql:find('information_schema', 1, true) then return { { COLUMN_NAME = 'fineAmount' }, { COLUMN_NAME = 'bailAmount' }, { COLUMN_NAME = 'prisonTime' } } end
    return {}
end
local function call(sql, params, cb)
    if type(params) == 'function' then cb = params end
    local r = answer(sql)
    if cb then cb(r) end
    return r
end
Mock.exportsByResource['oxmysql'] = {
    execute = function(_, sql, params, cb) return call(sql, params, cb) end,
    query = function(_, sql, params, cb) return call(sql, params, cb) end,
    fetch = function(_, sql, params, cb) return call(sql, params, cb) end,
    insert = function(_, sql, params, cb) if type(cb) == 'function' then cb(1) end return 1 end,
    update = function(_, sql, params, cb) if type(cb) == 'function' then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) if type(cb) == 'function' then cb(0) end return 0 end,
}

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')

-- A modified client answers the server's inventory snapshot request with items it never had.
local realTrigger = TriggerClientEvent
function TriggerClientEvent(name, target, ...)
    realTrigger(name, target, ...)
    if name == 'pf_mdt:client:SendInventorySnapshot' and Mock.netHandlers['pf_mdt:server:InventorySnapshot'] then
        local token = ...
        Mock.fireNet('pf_mdt:server:InventorySnapshot', target, token, { { name = 'goldbar', amount = 500, slot = 1 } })
    end
end

local OFFICER, PRISONER = 1, 2
local realTime = os.time
local now = realTime()
os.time = function(t) if t then return realTime(t) end return now end

local function inv() return Mock.players[PRISONER].PlayerData.items end
local function count(name)
    local n = 0
    for _, it in pairs(inv()) do if it.name == name then n = n + it.amount end end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    now = realTime()
    Mock.newPlayer(OFFICER).PlayerData.job = { name = 'police', onduty = true, grade = { level = 4 } }
    local p = Mock.newPlayer(PRISONER)
    p.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 } }
    p.Functions.ClearInventory = function() p.PlayerData.items = {} end
    p.Functions.RemoveItem = function() return true end
    p.Functions.AddItem = function(name, amount, slot)
        table.insert(p.PlayerData.items, { name = name, amount = amount, slot = slot })
        return true
    end
end

local function sentence()
    return Mock.callCallback('pf_mdt:createSentence', OFFICER, { citizenId = 'CID2', citizenName = 'Test Player2', title = 'Robbery', sentenceType = 'sentence', charges = { 'J1' } })
end

describe('MDT jail inventory', function()
    it('confiscates the server inventory and gives back only that, after the sentence', function()
        local res = sentence()
        assert_eq(res.success, true)
        assert_eq(#Mock.clientEventsNamed('pf_mdt:client:StartMdtSentence'), 1)
        assert_eq(count('phone'), 0)
        now = now + 11 * 60
        Mock.fireNet('pf_mdt:server:mdtSentenceReleased', PRISONER)
        assert_eq(count('phone'), 1)
        assert_eq(count('goldbar'), 0)
    end)
    it('the inventory snapshot from the client is no longer a net event', function()
        assert_eq(Mock.netHandlers['pf_mdt:server:InventorySnapshot'], nil)
    end)
    it('a release sent by the client before the sentence ends gives nothing back', function()
        sentence()
        Mock.fireNet('pf_mdt:server:mdtSentenceReleased', PRISONER)
        assert_eq(#inv(), 0)
    end)
end)
