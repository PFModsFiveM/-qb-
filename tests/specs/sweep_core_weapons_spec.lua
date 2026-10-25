-- pfm-weapons: a client-reported ammo count can only rise by the rounds of an ammo box the server
-- has taken from the player for that weapon's ammo type.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
local perms = {}
QBCoreMock.Functions.HasPermission = function(src, perm) return perms[src] == perm end
QBCoreMock.Shared.Weapons[GetHashKey('weapon_pistol')] = { name = 'weapon_pistol', label = 'Pistol', ammotype = 'AMMO_PISTOL' }
QBCoreMock.Shared.Weapons[GetHashKey('weapon_carbinerifle')] = { name = 'weapon_carbinerifle', label = 'Rifle', ammotype = 'AMMO_RIFLE' }
QBCoreMock.Shared.Items.pistol_ammo = { name = 'pistol_ammo', label = 'Pistol ammo', weight = 200, type = 'item' }
Config = nil
load_resource('pfm-weapons/config.lua')
load_resource('pfm-weapons/server/main.lua')

Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, src, item, amount, slot)
        local items = Mock.players[src].PlayerData.items
        local it = items[slot]
        if not it or it.name ~= item or it.amount < amount then return false end
        it.amount = it.amount - amount
        if it.amount == 0 then items[slot] = nil end
        return true
    end,
}

local P = 1
local PISTOL = { name = 'weapon_pistol', slot = 1 }

local function ammo() return Mock.players[P].PlayerData.items[1].info.ammo end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    perms = {}
    local p = Mock.newPlayer(P)
    p.SetInventory = function() end
    p.GetItemBySlot = function(slot) return p.PlayerData.items[slot] end
    p.PlayerData.items[1] = { name = 'weapon_pistol', slot = 1, amount = 1, info = { ammo = 10 } }
    p.PlayerData.items[2] = { name = 'pistol_ammo', slot = 2, amount = 2, info = {} }
end

describe('UpdateWeaponAmmo', function()
    it('a client cannot fill its weapon from nothing', function()
        Mock.fireNet('qb-weapons:server:UpdateWeaponAmmo', P, PISTOL, 250)
        assert_eq(ammo(), 10)
    end)
    it('shots fired lower the count', function()
        Mock.fireNet('qb-weapons:server:UpdateWeaponAmmo', P, PISTOL, 7)
        assert_eq(ammo(), 7)
    end)
    it('loading a box of ammo adds its rounds once', function()
        Mock.fireNet('qb-weapons:server:removeWeaponAmmoItem', P, { name = 'pistol_ammo', slot = 2 })
        Mock.fireNet('qb-weapons:server:UpdateWeaponAmmo', P, PISTOL, 40)
        assert_eq(ammo(), 40)
        assert_eq(Mock.players[P].PlayerData.items[2].amount, 1, 'one box used')
        Mock.fireNet('qb-weapons:server:UpdateWeaponAmmo', P, PISTOL, 200)
        assert_eq(ammo(), 40, 'the box is spent')
    end)
    it("a box's rounds count only for its own ammo type", function()
        Mock.players[P].PlayerData.items[3] = { name = 'weapon_carbinerifle', slot = 3, amount = 1, info = { ammo = 0 } }
        Mock.fireNet('qb-weapons:server:removeWeaponAmmoItem', P, { name = 'pistol_ammo', slot = 2 })
        Mock.fireNet('qb-weapons:server:UpdateWeaponAmmo', P, { name = 'weapon_carbinerifle', slot = 3 }, 30)
        assert_eq(Mock.players[P].PlayerData.items[3].info.ammo, 0)
    end)
    it('the old client order (count first, box second) still ends with the rounds', function()
        Mock.fireNet('qb-weapons:server:UpdateWeaponAmmo', P, PISTOL, 40)
        Mock.fireNet('qb-weapons:server:removeWeaponAmmoItem', P, { name = 'pistol_ammo', slot = 2 })
        Mock.fireNet('qb-weapons:server:UpdateWeaponAmmo', P, PISTOL, 39)
        assert_eq(ammo(), 39)
    end)
    it('removeWeaponAmmoItem takes only ammo items', function()
        Mock.fireNet('qb-weapons:server:removeWeaponAmmoItem', P, { name = 'weapon_pistol', slot = 1 })
        assert_true(Mock.players[P].PlayerData.items[1] ~= nil)
    end)
    it('an admin (/setammo) may raise it', function()
        perms[P] = 'admin'
        Mock.fireNet('qb-weapons:server:UpdateWeaponAmmo', P, PISTOL, 120)
        assert_eq(ammo(), 120)
    end)
end)

describe('GetWeaponAmmo', function()
    it('a missing payload answers 0 instead of crashing', function()
        assert_eq(Mock.callCallback('weapon:server:GetWeaponAmmo', P, nil), 0)
    end)
end)
