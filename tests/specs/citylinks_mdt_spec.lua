-- pf-policemdt-DEV → pf-services: a warrant on record and a carried-out sentence are court leads for
-- the newsroom, with public facts only (no narrative, witnesses or citizen ids).
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetResourceState(name) return name == 'pf-services' and 'started' or 'missing' end
Emits = {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, data = data, opts = opts or {} } return #Emits end,
}
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


BeforeEach = function()
    Mock.reset()
    Mock.players, Emits = {}, {}
    now = realTime()
    Mock.newPlayer(OFFICER, 'OFFCID').PlayerData.job = { name = 'police', onduty = true, grade = { level = 4 } }
    local p = Mock.newPlayer(PRISONER, 'CID2')
    p.PlayerData.charinfo = { firstname = 'Rob', lastname = 'Banks' }
    p.PlayerData.items = {}
    p.Functions.ClearInventory = function() p.PlayerData.items = {} end
    p.Functions.RemoveItem = function() return true end
    p.Functions.AddItem = function() return true end
end

local function events(kind)
    local out = {}
    for _, e in ipairs(Emits) do if e.kind == kind then out[#out + 1] = e end end
    return out
end

describe('MDT court leads', function()
    it('a warrant on record is one lead with the suspect and charge titles only', function()
        Mock.fireNet('pf_mdt:createWarrant', OFFICER, { warrantId = 'W12345', suspect = 'Rob Banks', charges = { 'Robbery', { name = 'Evading' } },
            narrative = 'secret notes', witnesses = { 'Witness A' }, officers = { 'Officer B' } })
        local ev = events('police.warrant')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.suspect, 'Rob Banks')
        assert_eq(ev[1].data.warrantId, 'W12345')
        assert_eq(table.concat(ev[1].data.charges, ','), 'Robbery,Evading')
        assert_eq(ev[1].data.narrative, nil)
        assert_eq(ev[1].data.witnesses, nil)
        assert_eq(ev[1].opts.actor, 'OFFCID')
    end)
    it('a civilian cannot issue one (no lead)', function()
        Mock.fireNet('pf_mdt:createWarrant', PRISONER, { warrantId = 'W1', suspect = 'Someone', charges = {} })
        Mock.fireNet('pf_mdt:createWarrant', OFFICER, 'junk')
        assert_eq(#Emits, 0)
    end)
    it('a carried-out sentence is one lead: name from the server, charges, months', function()
        local res = Mock.callCallback('pf_mdt:createSentence', OFFICER, { citizenId = 'CID2', citizenName = 'Fake Name', title = 'Robbery',
            description = 'officer narrative', sentenceType = 'sentence', charges = { 'J1' } })
        assert_eq(res.success, true)
        local ev = events('police.sentenced')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.name, 'Rob Banks')
        assert_eq(ev[1].data.months, 10)
        assert_eq(ev[1].data.charges[1], 'Robbery')
        assert_eq(ev[1].data.description, nil)
        assert_eq(ev[1].opts.actor, 'OFFCID')
    end)
    it('a civilian cannot sentence anyone (no lead)', function()
        Mock.callCallback('pf_mdt:createSentence', PRISONER, { citizenId = 'CID2', title = 'X', sentenceType = 'sentence', charges = { 'J1' } })
        assert_eq(#Emits, 0)
    end)
end)
