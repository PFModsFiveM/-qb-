-- PF gameplay pack: weapon jamming + gun oil maintenance
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Shared' })

local weaponData = nil   -- mirror of the currently equipped weapon item
local shotsFired = 0
local jammed = false
local lastRoll = 0
local clearing = false

local function estimatedQuality()
    if not weaponData or not weaponData.info then return 100 end
    local base = tonumber(weaponData.info.quality) or 100
    local perShot = Config.DurabilityMultiplier and Config.DurabilityMultiplier[weaponData.name] or 0.15
    return math.max(0, base - shotsFired * perShot)
end

local function jamChance(quality)
    if not Config.Jam or not Config.Jam.Enabled then return 0 end
    for _, tier in ipairs(Config.Jam.Tiers or {}) do
        if quality >= tier.minQuality then
            return tier.chance or 0
        end
    end
    return 0
end

local function isJammable(weaponHash)
    local shared = QBCore.Shared.Weapons[weaponHash]
    if not shared then return false end
    local name = shared.name or ''
    if name == 'weapon_unarmed' or name == 'weapon_petrolcan' or name == 'weapon_fireextinguisher' or name == 'weapon_snowball' then return false end
    local group = GetWeapontypeGroup(weaponHash)
    if group == `GROUP_MELEE` or group == `GROUP_THROWN` or group == `GROUP_STUNGUN` or group == `GROUP_FIREEXTINGUISHER` then return false end
    return true
end

-- mirror the equipped weapon (same event client/main.lua consumes)
RegisterNetEvent('qb-weapons:client:SetCurrentWeapon', function(data, _)
    if data and data ~= false and next(data) then
        weaponData = data
    else
        weaponData = nil
    end
    shotsFired = 0
    if jammed then exports['pfm-core']:HideText() end
    jammed = false
    clearing = false
end)

local function clearJam()
    if clearing or not jammed then return end
    clearing = true
    QBCore.Functions.Progressbar('clear_jam', Lang:t('info.clearing_jam'), (Config.Jam and Config.Jam.ClearTimeMs) or 2500, false, true, {
        disableMovement = false,
        disableCarMovement = false,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'weapons@first_person@aim_rng@generic@projectile@sticky_bomb@',
        anim = 'plant_floor',
        flags = 48,
    }, {}, {}, function()
        clearing = false
        jammed = false
        exports['pfm-core']:HideText()
        MakePedReload(PlayerPedId())
        QBCore.Functions.Notify(Lang:t('success.jam_cleared'), 'success')
    end, function()
        clearing = false
        QBCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end

CreateThread(function()
    while true do
        local sleep = 500
        if weaponData then
            sleep = 0
            local ped = PlayerPedId()
            local weapon = GetSelectedPedWeapon(ped)

            if jammed then
                DisablePlayerFiring(PlayerId(), true)
                DisableControlAction(0, 24, true)
                DisableControlAction(0, 257, true)
                if IsControlJustPressed(0, 45) then -- R
                    clearJam()
                end
            elseif Config.Jam and Config.Jam.Enabled and IsPedShooting(ped) and isJammable(weapon) then
                shotsFired += 1
                local now = GetGameTimer()
                if now - lastRoll >= (Config.Jam.RollIntervalMs or 500) then
                    lastRoll = now
                    local chance = jamChance(estimatedQuality())
                    if chance > 0 and math.random(100) <= chance then
                        jammed = true
                        PlaySoundFrontend(-1, 'Faster_Click', 'RESPAWN_ONLINE_SOUNDSET', true)
                        exports['pfm-core']:DrawText(Lang:t('info.weapon_jammed'), 'left')
                        QBCore.Functions.Notify(Lang:t('error.weapon_jam'), 'error')
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

-- gun oil: clean the weapon in your hands
RegisterNetEvent('qb-weapons:client:UseGunOil', function(itemData)
    if not weaponData then
        QBCore.Functions.Notify(Lang:t('error.no_weapon_in_hand'), 'error')
        return
    end
    local ped = PlayerPedId()
    local weapon = GetSelectedPedWeapon(ped)
    if not isJammable(weapon) then
        QBCore.Functions.Notify(Lang:t('error.no_weapon_in_hand'), 'error')
        return
    end
    QBCore.Functions.Progressbar('gun_oil', Lang:t('info.cleaning_weapon'), (Config.Jam and Config.Jam.CleanTimeMs) or 8000, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'mini@repair',
        anim = 'fixing_a_ped',
        flags = 16,
    }, {}, {}, function()
        jammed = false
        TriggerServerEvent('qb-weapons:server:CleanWeapon', weaponData.slot, itemData and itemData.slot or nil)
        shotsFired = 0
    end, function()
        QBCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)

-- keep our mirror's quality fresh after a server-side clean
RegisterNetEvent('qb-weapons:client:SetCleanedQuality', function(quality)
    if weaponData and weaponData.info then
        weaponData.info.quality = quality
        shotsFired = 0
        QBCore.Functions.Notify(Lang:t('success.weapon_cleaned', { quality = math.floor(quality) }), 'success')
    end
end)
