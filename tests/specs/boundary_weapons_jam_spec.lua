-- pfm-weapons gun oil (server/jamming.lua) across the FiveM boundary: the player from
-- exports['pfm-core']:GetPlayer is a copy. Cleaning takes the kit through pfm-inventory (which
-- changes the live inventory) and then writes the weapon's new quality back with SetInventory, so
-- the items written back must be read after the kit was taken: the copy from before still holds
-- the kit, and writing it back returned the kit (every clean was free).
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pfm-weapons' end
QBCoreMock.Shared.Items.gunoil = { name = 'gunoil', label = 'Gun oil', weight = 100, type = 'item' }
Config = nil
load_resource('pfm-weapons/config.lua')
Config.Jam = Config.Jam or {}
Config.Jam.Enabled = true
Config.Jam.CleanAmount = 40
load_resource('pfm-weapons/server/jamming.lua')

-- pfm-inventory acts on the live player (its own copy, then SetPlayerData in pfm-core)
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
local function items() return Mock.players[P].PlayerData.items end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    local p = Mock.newPlayer(P)
    -- the player methods pfm-inventory adds (AddPlayerMethod): they act on the live inventory
    p.SetInventory = function(list) p.PlayerData.items = list end
    p.GetItemByName = function(name)
        for _, it in pairs(p.PlayerData.items) do if it.name == name then return it end end
    end
    p.PlayerData.items[1] = { name = 'weapon_pistol', slot = 1, amount = 1, info = { quality = 30 } }
    p.PlayerData.items[2] = { name = 'gunoil', slot = 2, amount = 2, info = {} }
end

describe('cleaning a weapon with gun oil', function()
    it('uses up one kit and raises the quality', function()
        Mock.fireNet('qb-weapons:server:CleanWeapon', P, 1, 2)
        assert_eq(items()[1].info.quality, 70)
        assert_true(items()[2] ~= nil, 'one kit left')
        assert_eq(items()[2].amount, 1, 'the kit is used up, not handed back with the weapon')
        local sent = Mock.clientEventsNamed('qb-weapons:client:SetCleanedQuality')
        assert_eq(sent[#sent].args[1], 70)
    end)
    it('the last kit is gone after the clean', function()
        items()[2].amount = 1
        Mock.fireNet('qb-weapons:server:CleanWeapon', P, 1, 2)
        assert_eq(items()[2], nil, 'no kit left')
        assert_eq(items()[1].info.quality, 70)
        -- a second clean has no kit to use
        Mock.fireNet('qb-weapons:server:CleanWeapon', P, 1, 2)
        assert_eq(items()[1].info.quality, 70, 'nothing to clean with')
    end)
    it('without a kit nothing changes', function()
        items()[2] = nil
        Mock.fireNet('qb-weapons:server:CleanWeapon', P, 1, nil)
        assert_eq(items()[1].info.quality, 30)
    end)
end)
