-- pf-emsmdt start-up with the police MDT's pf_mdt_* tables present: nothing is copied out of them and
-- they are not altered (unless Config.MigrateLegacyPoliceTables is turned on).
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetConvar(_, default) return default end
function GetResourceState() return 'started' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen = Citizen or {}
Citizen.Await = Citizen.Await or function(p) return p.value end
CreateThread = function(fn) fn() end      -- run the start-up threads
Wait = function() end

local log = {}
local function respond(sql, cb, scalarValue)
    log[#log + 1] = sql
    if cb then cb(scalarValue) end
end
Mock.exportsByResource['oxmysql'] = {
    -- every table "exists" and the pf_emsmdt_* tables are empty: the case the copies ran in
    scalar = function(_, sql, params, cb)
        if type(params) == 'function' then cb, params = params, {} end
        respond(sql, cb, sql:find('information_schema', 1, true) and 1 or 0)
    end,
    execute = function(_, sql, params, cb)
        if type(params) == 'function' then cb, params = params, {} end
        respond(sql, cb, {})
    end,
    insert = function(_, sql, params, cb) respond(sql, type(cb) == 'function' and cb or nil, 1) end,
    query = function(_, sql, params, cb) if type(params) == 'function' then cb = params end respond(sql, cb, {}) end,
    fetch = function(_, sql, params, cb) if type(params) == 'function' then cb = params end respond(sql, cb, {}) end,
}

function GetCurrentResourceName() return 'pf-emsmdt' end
Config = nil
load_resource('[pfscripts]/pf-emsmdt/config.lua')
load_resource('[pfscripts]/pf-emsmdt/shared/framework.lua')

local function startUp()
    log = {}
    load_resource('[pfscripts]/pf-emsmdt/server/officers.lua')
    load_resource('[pfscripts]/pf-emsmdt/server/roster.lua')
    load_resource('[pfscripts]/pf-emsmdt/server/sop.lua')
    TriggerEvent('onResourceStart', 'pf-emsmdt')
end
local function touched()
    local n = 0
    for _, sql in ipairs(log) do
        if sql:find('FROM `pf_mdt_', 1, true) or sql:find('ALTER TABLE `pf_mdt_', 1, true) then n = n + 1 end
    end
    return n
end

describe('pf-emsmdt start-up beside the police MDT', function()
    it('copies nothing from the police tables and does not alter them', function()
        Config.MigrateLegacyPoliceTables = false
        startUp()
        assert_true(#log > 0, 'start-up ran')
        assert_eq(touched(), 0)
    end)
    it('the copy still exists for servers that opt in', function()
        Config.MigrateLegacyPoliceTables = true
        startUp()
        assert_true(touched() > 0)
        Config.MigrateLegacyPoliceTables = false
    end)
end)
