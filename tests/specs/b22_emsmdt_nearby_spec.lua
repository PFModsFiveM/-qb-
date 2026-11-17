-- Batch 22 (22C) pf-emsmdt server: pf-emsmdt:server:getNearbyPatients(ids) answers the patient care
-- page's nearby list in ONE callback: only an on-duty medic; each listed server id is checked against
-- the server's positions (within 5 m of the caller), never the caller, no duplicates, at most 8 ids
-- looked at; every row carries its own target id, nearest first; a rate limit per caller.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetConvar(_, default) return default end
function GetResourceState() return 'started' end
QBCore = QBCoreMock
-- FiveM promises (the fake database answers at once, so a resolved value is all Await needs)
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen = Citizen or {}
Citizen.Await = Citizen.Await or function(p) return p.value end
QBCoreMock.Functions.GetPlayers = function() local out = {} for id in pairs(Mock.players) do out[#out + 1] = id end return out end

-- fake oxmysql: answers by SQL text, records every statement
local db = { log = {}, players = {}, roster = {}, profiles = {} }
local function answer(sql, params)
    db.log[#db.log + 1] = { sql = sql, params = params }
    if sql:find('SELECT job FROM players WHERE citizenid', 1, true) then
        local p = db.players[params[1]]
        return p and { { job = json.encode(p.job) } } or {}
    end
    if sql:find('SELECT 1 AS ok FROM players WHERE citizenid', 1, true) then
        return db.players[params[1]] and { { ok = 1 } } or {}
    end
    if sql:find('AS r, (SELECT COUNT(*)', 1, true) then
        return { { r = db.roster[params[1]] and 1 or 0, s = db.profiles[params[2]] and 1 or 0 } }
    end
    return {}
end
local function call(sql, params, cb)
    if type(params) == 'function' then cb, params = params, {} end
    local r = answer(sql, params or {})
    if cb then cb(r) end
    return r
end
Mock.exportsByResource['oxmysql'] = {
    execute = function(_, sql, params, cb) return call(sql, params, cb) end,
    query = function(_, sql, params, cb) return call(sql, params, cb) end,
    fetch = function(_, sql, params, cb) return call(sql, params, cb) end,
    insert = function(_, sql, params, cb) call(sql, params) if Mock.callable(cb) then cb(1) end return 1 end,
    update = function(_, sql, params, cb) call(sql, params) if Mock.callable(cb) then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) call(sql, params) if Mock.callable(cb) then cb(0) end return 0 end,
}
local function ran(fragment)
    local n = 0
    for _, e in ipairs(db.log) do if e.sql:find(fragment, 1, true) then n = n + 1 end end
    return n
end
local function lastParams(fragment)
    for i = #db.log, 1, -1 do if db.log[i].sql:find(fragment, 1, true) then return db.log[i].params end end
end

function GetCurrentResourceName() return 'pf-emsmdt' end
Config = nil
load_resource('[pfscripts]/pf-emsmdt/config.lua')
load_resource('[pfscripts]/pf-emsmdt/shared/framework.lua')
load_resource('[pfscripts]/pf-emsmdt/server/main.lua')
load_resource('[pfscripts]/pf-emsmdt/server/officers.lua')
load_resource('[pfscripts]/pf-emsmdt/server/roster.lua')
load_resource('[pfscripts]/pf-emsmdt/server/sop.lua')

local MEDIC, CIVIL = 1, 2
local HERE = vector3(300.0, -580.0, 43.0)
BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.gameTimer = (Mock.gameTimer or 0) + 100000
    Mock.newPlayer(MEDIC, 'MEDIC1').PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 1 } }
    Mock.newPlayer(CIVIL, 'CIVIL1')
    Mock.coords[MEDIC], Mock.coords[CIVIL] = HERE, HERE
    for src = 10, 22 do
        local p = Mock.newPlayer(src, 'PAT' .. src)
        p.PlayerData.charinfo = { firstname = 'Pat', lastname = tostring(src) }
        Mock.coords[src] = vector3(HERE.x + (src - 10) * 0.3, HERE.y, HERE.z)
    end
    PFEmsNearby.last = {}
end
local function near(src, ids)
    Mock.gameTimer = Mock.gameTimer + 1000
    return Mock.callCallback('pf-emsmdt:server:getNearbyPatients', src, ids)
end

describe('22C getNearbyPatients', function()
    it('names only the listed players within reach by server position, nearest first, each row with its id', function()
        Mock.coords[12] = vector3(HERE.x + 20.0, HERE.y, HERE.z) -- the client said near; the server sees it far
        local r = near(MEDIC, { 13, 12, 11, 11, MEDIC })
        assert_true(r.ok)
        assert_eq(#r.list, 2)
        assert_eq(r.list[1].target, 11)
        assert_eq(r.list[1].citizenid, 'PAT11')
        assert_eq(r.list[1].name, 'Pat 11')
        assert_eq(r.list[2].target, 13)
        assert_true(r.list[1].distance <= r.list[2].distance)
    end)

    it('looks at no more than 8 ids, ignores junk and offline ids', function()
        local ids = {}
        for src = 10, 22 do ids[#ids + 1] = src end
        local r = near(MEDIC, ids)
        assert_eq(#r.list, 8)
        local bad = near(MEDIC, { 'x', -1, 1.5, 999 })
        assert_true(bad.ok)
        assert_eq(#bad.list, 0)
    end)

    it('only an on-duty medic; a non-table list and bursts are refused', function()
        assert_eq(near(CIVIL, { 10 }).error, 'no_permission')
        Mock.players[MEDIC].PlayerData.job.onduty = false
        assert_eq(near(MEDIC, { 10 }).error, 'no_permission')
        Mock.players[MEDIC].PlayerData.job.onduty = true
        assert_eq(near(MEDIC, 10).error, 'bad_args')
        assert_true(near(MEDIC, { 10 }).ok)
        assert_eq(Mock.callCallback('pf-emsmdt:server:getNearbyPatients', MEDIC, { 10 }).error, 'rate_limited')
    end)
end)
