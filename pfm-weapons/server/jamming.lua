-- PF gameplay pack (server): gun oil maintenance
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })

QBCore.Functions.CreateUseableItem('gunoil', function(source, item)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if not Player.GetItemByName('gunoil') then return end
    TriggerClientEvent('qb-weapons:client:UseGunOil', source, item)
end)

RegisterNetEvent('qb-weapons:server:CleanWeapon', function(weaponSlot, kitSlot)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if not Config.Jam or not Config.Jam.Enabled then return end

    weaponSlot = tonumber(weaponSlot)
    if not weaponSlot then return end
    local WeaponItem = Player.PlayerData.items[weaponSlot]
    if not WeaponItem or type(WeaponItem.name) ~= 'string' or not WeaponItem.name:find('weapon_') then return end

    -- consume the kit (server-side check, never trust the client slot blindly)
    local kit = kitSlot and Player.PlayerData.items[tonumber(kitSlot)] or nil
    if not kit or kit.name ~= 'gunoil' then
        kit = Player.GetItemByName('gunoil')
    end
    if not kit then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_gunoil'), 'error')
        return
    end
    if not exports['pfm-inventory']:RemoveItem(src, 'gunoil', 1, kit.slot, 'pfm-weapons:clean') then return end

    local current = tonumber(WeaponItem.info and WeaponItem.info.quality) or 100
    local newQuality = math.min(100, current + (Config.Jam.CleanAmount or 40))
    WeaponItem.info = WeaponItem.info or {}
    WeaponItem.info.quality = newQuality
    Player.SetInventory(Player.PlayerData.items, true)
    TriggerClientEvent('qb-weapons:client:SetCleanedQuality', src, newQuality)
end)
