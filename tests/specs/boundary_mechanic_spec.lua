-- pf-mechanicjob with pfm-core's QBCore object as FiveM hands it over: a copy, functions as function
-- references, the shared item list a copy too.
--   * /admincustoms: QBCore.Functions.HasPermission is a funcref, so a type() == 'function' test
--     refused every QBCore admin;
--   * the engineering items: written into the resource's own copy they existed for pf-mechanicjob
--     only; they must reach pfm-core (AddItems), which pfm-inventory and every resource read. AddItems
--     adds all or nothing, so an item another resource added after the copy was taken must not keep
--     the others out (they then go one by one with AddItem).
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pf-mechanicjob' end
Config = {}

-- as in FiveM, the Shared part of the QBCore object is a copy as well (the default mock keeps it live)
local core = Mock.exportsByResource['pfm-core']
local realGetCore = core.GetCoreObject
local afterCopy = nil -- runs right after a copy is handed out (another resource acting meanwhile)
core.GetCoreObject = function(self, filters)
    local qb = realGetCore(self, filters)
    if qb.Shared then qb.Shared = Mock.pack(QBCoreMock.Shared) end
    if afterCopy then afterCopy() end
    return qb
end
Mock.passThrough[core.GetCoreObject] = true

local ADMIN, PLAYER = 3, 4
QBCoreMock.Functions.HasPermission = function(src, perm) return src == ADMIN and perm == 'admin' end

local rawRequire = require
function require(name)
    if name == 'config.engineering' then return load_resource('[pfscripts]/pf-mechanicjob/config/engineering.lua') end
    return rawRequire(name)
end

load_resource('[pfscripts]/pf-mechanicjob/server/admin_customs.lua')

describe('admin customs access', function()
    it('a QBCore admin is let in, a player is not', function()
        assert_eq(Mock.callCallback('pf-mechanicjob:server:adminCustoms:hasAccess', ADMIN), true)
        assert_eq(Mock.callCallback('pf-mechanicjob:server:adminCustoms:hasAccess', PLAYER), false)
    end)
end)

local ITEMS = load_resource('[pfscripts]/pf-mechanicjob/shared/engineering_items.lua')
-- pfm-core as it was before pf-mechanicjob started: none of the engineering items
local function freshCore()
    for name in pairs(ITEMS) do QBCoreMock.Shared.Items[name] = nil end
end

describe('engineering items', function()
    it('are registered with pfm-core, not only in this resource\'s copy', function()
        freshCore()
        local items = load_resource('[pfscripts]/pf-mechanicjob/shared/engineering_items.lua')
        assert_true(type(items) == 'table' and items.chop_kit ~= nil)
        local def = QBCoreMock.Shared.Items.chop_kit
        assert_true(def ~= nil, 'pfm-core knows the item')
        assert_eq(def.name, 'chop_kit')
        assert_eq(def.label, 'Chop Shop Kit')
        for name in pairs(items) do assert_true(QBCoreMock.Shared.Items[name] ~= nil, name) end
    end)
    it('an item pfm-core already has is left as it is', function()
        freshCore()
        QBCoreMock.Shared.Items.intake_filter = { name = 'intake_filter', label = 'Owner label' }
        load_resource('[pfscripts]/pf-mechanicjob/shared/engineering_items.lua')
        assert_eq(QBCoreMock.Shared.Items.intake_filter.label, 'Owner label')
        assert_true(QBCoreMock.Shared.Items.chop_kit ~= nil)
    end)
    it('an item another resource added after the copy was taken does not keep the others out', function()
        freshCore()
        -- not in this resource's copy, so it is in the batch, which pfm-core then refuses whole
        afterCopy = function() QBCoreMock.Shared.Items.intake_filter = { name = 'intake_filter', label = 'Owner label' } end
        load_resource('[pfscripts]/pf-mechanicjob/shared/engineering_items.lua')
        afterCopy = nil
        assert_eq(QBCoreMock.Shared.Items.intake_filter.label, 'Owner label', 'the other resource\'s item stays')
        assert_true(QBCoreMock.Shared.Items.chop_kit ~= nil, 'the rest are registered one by one')
        for name in pairs(ITEMS) do assert_true(QBCoreMock.Shared.Items[name] ~= nil, name) end
    end)
end)
