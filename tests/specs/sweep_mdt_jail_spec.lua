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
    insert = function(_, sql, params, cb) if Mock.callable(cb) then cb(1) end return 1 end,
    update = function(_, sql, params, cb) if Mock.callable(cb) then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) if Mock.callable(cb) then cb(0) end return 0 end,
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
    -- the MDT keeps the jail and the confiscated items in locals: end a sentence an earlier test left
    -- running (a stash already held is not taken again)
    now = realTime() + 3600
    Mock.fireNet('pf_mdt:server:mdtSentenceReleased', PRISONER)
    now = realTime()
    p.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 } }
    Mock.reset()
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
    -- P comes from pfm-core, so RemoveItem and ClearInventory are function references here: the two
    -- tests below fail if either step tests them with type() == 'function' (it is skipped).
    it('items a one-call clear leaves in the hotbar are taken one by one', function()
        local p = Mock.players[PRISONER]
        p.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 }, { name = 'lockpick', amount = 2, slot = 7 } }
        -- an inventory whose clear keeps the hotbar (slots 1-5)
        p.Functions.ClearInventory = function()
            local kept = {}
            for _, it in pairs(p.PlayerData.items) do if it.slot <= 5 then kept[#kept + 1] = it end end
            p.PlayerData.items = kept
        end
        p.Functions.RemoveItem = function(name, amount, slot)
            for i, it in pairs(p.PlayerData.items) do
                if it.name == name and (slot == nil or it.slot == slot) and it.amount >= amount then
                    it.amount = it.amount - amount
                    if it.amount == 0 then table.remove(p.PlayerData.items, i) end
                    return true
                end
            end
            return false
        end
        assert_eq(sentence().success, true)
        assert_eq(count('phone'), 0, 'the hotbar item was confiscated')
        assert_eq(count('lockpick'), 0)
        now = now + 11 * 60
        Mock.fireNet('pf_mdt:server:mdtSentenceReleased', PRISONER)
        assert_eq(count('phone'), 1)
        assert_eq(count('lockpick'), 2)
    end)
    it('the release clears what the prisoner holds before the confiscated items come back', function()
        sentence()
        assert_eq(count('phone'), 0)
        -- the inventory came back from the last save (a reconnect in jail), and a jail item
        local p = Mock.players[PRISONER]
        p.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 }, { name = 'prison_spoon', amount = 1, slot = 2 } }
        now = now + 11 * 60
        Mock.fireNet('pf_mdt:server:mdtSentenceReleased', PRISONER)
        assert_eq(count('phone'), 1, 'one phone, not two')
        assert_eq(count('prison_spoon'), 0)
    end)
end)
