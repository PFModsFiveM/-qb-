-- pfm-policejob server events a modified client could abuse: evidence lockers, impound, radar alerts,
-- evidence bags, jail time and crashing callbacks.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
Lang = { t = function(_, key, p)
    if key == 'info.current_evidence' then return ('%s | Drawer %s'):format(p.value, p.value2) end
    return key
end }

local vehicles = {}
function GetAllVehicles() return vehicles end
local opened, added = {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    OpenInventory = function(_, src, name) opened[#opened + 1] = { src = src, name = name } end,
    OpenInventoryById = function() end,
    AddItem = function(_, src, name, amount, slot, info) added[#added + 1] = { src = src, name = name, info = info } return true end,
    RemoveItem = function() return true end,
}
QBCoreMock.Shared.Weapons[GetHashKey('weapon_pistol')] = { name = 'weapon_pistol', ammotype = 'AMMO_PISTOL' }

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/interactions.lua')
load_resource('pfm-policejob/server/evidence.lua')
load_resource('pfm-policejob/server/vehicle.lua')

local COP, CIV = 1, 2
local LOCKER = Config.Locations['evidence'][1]

local function updates(fragment)
    local out = {}
    for _, c in ipairs(Mock.dbCalls) do
        if c.query:find(fragment, 1, true) then out[#out + 1] = c end
    end
    return out
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.plates, Mock.dropped = {}, {}, {}, {}
    vehicles, opened, added = {}, {}, {}
    local cop = Mock.newPlayer(COP)
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 2 } }
    cop.GetItemByName = function() return nil end
    local civ = Mock.newPlayer(CIV, 'CIVCID')
    civ.PlayerData.metadata.fingerprint = 'FP-CIV'
    civ.GetItemByName = function() return nil end
end

describe('evidence locker', function()
    it('opens a drawer of the locker the officer stands at', function()
        Mock.coords[COP] = LOCKER
        Mock.fireNet('qb-policejob:server:evidence', COP, '1 | Drawer 12')
        assert_eq(#opened, 1)
        assert_eq(opened[1].name, '1 | Drawer 12')
    end)
    it('refuses any other stash name, or a drawer away from the locker', function()
        Mock.coords[COP] = LOCKER
        Mock.fireNet('qb-policejob:server:evidence', COP, 'policestash_CIVCID')
        Mock.fireNet('qb-policejob:server:evidence', COP, 'apartment112345')
        Mock.fireNet('qb-policejob:server:evidence', COP, '2 | Drawer 12')   -- locker 2 is elsewhere
        Mock.coords[COP] = vector3(0, 0, 0)
        Mock.fireNet('qb-policejob:server:evidence', COP, '1 | Drawer 12')
        assert_eq(#opened, 0)
    end)
end)

describe('impound', function()
    it('only officers get the impound list', function()
        local list = Mock.callCallback('police:GetImpoundedVehicles', CIV)
        assert_eq(#list, 0)
        assert_eq(#updates('state = ?'), 0)
    end)
    it('cannot impound a plate that is not next to the officer', function()
        Mock.fireNet('police:server:Impound', COP, 'FARAWAY1', true, 0, 1000, 1000, 100)
        assert_eq(#updates('UPDATE player_vehicles'), 0)
    end)
    it('impounds the car next to the officer and caps the depot price', function()
        vehicles = { 500 }
        Mock.plates[500] = ' NEAR123 '
        Mock.coords[500] = vector3(3, 0, 0)
        Mock.fireNet('police:server:Impound', COP, 'NEAR123', false, 1e9, 1000, 1000, 100)
        local u = updates('UPDATE player_vehicles')
        assert_eq(#u, 1)
        assert_eq(u[1].params[2], Config.MaxFine)
    end)
    it('taking a car out of the impound only touches impounded rows', function()
        Mock.coords[COP] = Config.Locations['impound'][1]
        Mock.fireNet('police:server:TakeOutImpound', COP, 'ABC123', 1)
        local u = updates('UPDATE player_vehicles')
        assert_eq(#u, 1)
        assert_true(u[1].query:find('state = ?', 1, true) ~= nil and u[1].params[3] == 2)
    end)
end)

describe('radar alert', function()
    it('needs a flagged plate and is placed at the radar the driver is at', function()
        Mock.coords[CIV] = Config.Radars[1]
        Mock.fireNet('police:server:FlaggedPlateTriggered', CIV, { x = 1, y = 2, z = 3 }, 'NOTFLAG')
        assert_eq(#Mock.clientEventsNamed('police:client:policeAlert'), 0)
        Commands.flagplate(COP, { 'FLAG123', 'stolen' })
        Mock.coords[CIV] = vector3(4000, 4000, 0)              -- nowhere near a radar
        Mock.fireNet('police:server:FlaggedPlateTriggered', CIV, Config.Radars[1], 'FLAG123')
        assert_eq(#Mock.clientEventsNamed('police:client:policeAlert'), 0)
        Mock.coords[CIV] = Config.Radars[2]
        Mock.fireNet('police:server:FlaggedPlateTriggered', CIV, { x = 1, y = 2, z = 3 }, 'FLAG123')
        local alerts = Mock.clientEventsNamed('police:client:policeAlert')
        assert_eq(#alerts, 1)
        assert_eq(alerts[1].args[1].x, Config.Radars[2].x)
    end)
end)

describe('evidence bags', function()
    it('a fingerprint bag carries the stored print, not what the client sends', function()
        Mock.fireNet('evidence:server:CreateFingerDrop', CIV, vector3(1, 1, 0))
        local fingerId = Mock.clientEventsNamed('evidence:client:AddFingerPrint')[1].args[1]
        Mock.fireNet('evidence:server:AddFingerprintToInventory', COP, fingerId, { fingerprint = 'FORGED', street = 'Main St' })
        assert_eq(#added, 1)
        assert_eq(added[1].info.fingerprint, 'FP-CIV')
        assert_eq(added[1].info.street, 'Main St')
    end)
    it('a blood bag carries the DNA of whoever bled', function()
        Mock.fireNet('evidence:server:CreateBloodDrop', CIV, 'SOMEONEELSE', 'A+', vector3(1, 1, 0))
        local bloodId = Mock.clientEventsNamed('evidence:client:AddBlooddrop')[1].args[1]
        Mock.fireNet('evidence:server:AddBlooddropToInventory', COP, bloodId, { dnalabel = 'FORGED' })
        assert_eq(added[1].info.dnalabel, (('CIVCID'):gsub('.', function(c) return string.format('%02x', c:byte()) end)))
    end)
    it('evidence cannot be bagged from across the map', function()
        Mock.fireNet('evidence:server:CreateCasing', CIV, GetHashKey('weapon_pistol'), vector3(1, 1, 0))
        local casingId = Mock.clientEventsNamed('evidence:client:AddCasing')[1].args[1]
        Mock.coords[COP] = vector3(4000, 0, 0)
        Mock.fireNet('evidence:server:AddCasingToInventory', COP, casingId, {})
        assert_eq(#added, 0)
        Mock.coords[COP] = vector3(0, 0, 0)
        Mock.fireNet('evidence:server:AddCasingToInventory', COP, casingId, {})
        assert_eq(#added, 1)
        assert_eq(added[1].info.ammotype, GetHashKey('weapon_pistol'))
    end)
    it('drops far from the player who made them are ignored', function()
        Mock.fireNet('evidence:server:CreateFingerDrop', CIV, vector3(3000, 0, 0))
        assert_eq(#Mock.clientEventsNamed('evidence:client:AddFingerPrint'), 0)
    end)
end)

describe('jail and status', function()
    it('jail time is capped', function()
        Mock.fireNet('police:server:JailPlayer', COP, CIV, 1e9)
        assert_eq(Mock.players[CIV].PlayerData.metadata.injail, Config.MaxJailTime)
    end)
    it('only officers can read status, and bad ids do not crash', function()
        local list = Mock.callCallback('police:GetPlayerStatus', CIV, COP)
        assert_eq(#list, 0)
        assert_eq(Mock.callCallback('police:server:isPlayerDead', COP, 999), false)
        assert_eq(Mock.callCallback('police:IsSilencedWeapon', COP, 12345), false)
    end)
    it('policeAlert ignores non-text payloads', function()
        Mock.fireNet('police:server:policeAlert', CIV, { 'x' })
        assert_eq(#Mock.clientEventsNamed('police:client:policeAlert'), 0)
    end)
end)
