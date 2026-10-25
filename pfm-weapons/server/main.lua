local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local sharedWeapons = exports['pfm-core']:GetShared('Weapons')

local function SplitStr(str, delimiter)
    local result = {}
    local from = 1
    local delim_from, delim_to = string.find(str, delimiter, from)
    while delim_from do
        result[#result + 1] = string.sub(str, from, delim_from - 1)
        from = delim_to + 1
        delim_from, delim_to = string.find(str, delimiter, from)
    end
    result[#result + 1] = string.sub(str, from)
    return result
end

local function Round(value, numDecimalPlaces)
    local mult = 10 ^ (numDecimalPlaces or 0)
    return math.floor(value * mult + 0.5) / mult
end

-- Functions

local function IsWeaponBlocked(WeaponName)
    local retval = false
    for _, name in pairs(Config.DurabilityBlockedWeapons) do
        if name == WeaponName then
            retval = true
            break
        end
    end
    return retval
end

-- Callback

QBCore.Functions.CreateCallback('qb-weapons:server:GetConfig', function(_, cb)
    cb(Config.WeaponRepairPoints)
end)

QBCore.Functions.CreateCallback('weapon:server:GetWeaponAmmo', function(source, cb, WeaponData)
    local Player = exports['pfm-core']:GetPlayer(source)
    local retval = 0
    if type(WeaponData) ~= 'table' then return cb(0, nil) end
    if Player then
        local ItemData = Player.GetItemBySlot(WeaponData.slot)
        if ItemData and type(ItemData.info) == 'table' then
            retval = ItemData.info.ammo and ItemData.info.ammo or 0
        end
    end
    cb(retval, WeaponData.name)
end)

QBCore.Functions.CreateCallback('qb-weapons:server:RepairWeapon', function(source, cb, RepairPoint, data)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local minute = 60 * 1000
    local Timeout = math.random(5 * minute, 10 * minute)

    if not Player then
        cb(false)
        return
    end

    -- Validate the client-supplied repair point and weapon data
    if type(data) ~= 'table' or type(data.name) ~= 'string' or not data.slot then
        cb(false)
        return
    end
    local repairShop = Config.WeaponRepairPoints[RepairPoint]
    if not repairShop then
        cb(false)
        return
    end
    if repairShop.IsRepairing or (repairShop.RepairingData and next(repairShop.RepairingData)) then
        cb(false)
        return
    end
    local WeaponData = sharedWeapons[GetHashKey(data.name)]
    if not WeaponData or not WeaponData.ammotype then
        cb(false)
        return
    end
    local WeaponClass = (SplitStr(WeaponData.ammotype, '_')[2]):lower()
    local repairCost = Config.WeaponRepairCosts[WeaponClass]
    if not repairCost or repairCost <= 0 then
        cb(false)
        return
    end

    local slotItem = Player.PlayerData.items[data.slot]
    -- The player must actually hold the claimed weapon in the claimed slot
    if not slotItem or slotItem.name ~= data.name then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_weapon_in_hand'), 'error')
        TriggerClientEvent('qb-weapons:client:SetCurrentWeapon', src, {}, false)
        cb(false)
        return
    end

    if not slotItem.info.quality or slotItem.info.quality == 100 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_damage_on_weapon'), 'error')
        cb(false)
        return
    end

    -- Cost always comes from config; the client never supplies an amount
    local repairKey = ('pfm-weapons:repair:%s:%s'):format(Player.PlayerData.citizenid, PFPayout.NewId())
    if not PFPayout.Charge(Player, 'cash', repairCost, { key = repairKey, kind = 'purchase', reason = 'Weapon repair' }) then
        cb(false)
        return
    end

    Config.WeaponRepairPoints[RepairPoint].IsRepairing = true
    Config.WeaponRepairPoints[RepairPoint].RepairingData = {
        CitizenId = Player.PlayerData.citizenid,
        WeaponData = Player.PlayerData.items[data.slot],
        Ready = false,
    }

    if not exports['pfm-inventory']:RemoveItem(src, data.name, 1, data.slot, 'qb-weapons:server:RepairWeapon') then
        PFPayout.Pay(Player, 'cash', repairCost, { key = repairKey .. ':refund', kind = 'refund', reason = 'Weapon repair refunded' })
        Config.WeaponRepairPoints[RepairPoint].IsRepairing = false
        Config.WeaponRepairPoints[RepairPoint].RepairingData = {}
        cb(false)
        return
    end

    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[data.name], 'remove')
    TriggerClientEvent('qb-inventory:client:CheckWeapon', src, data.name)
    TriggerClientEvent('qb-weapons:client:SyncRepairShops', -1, Config.WeaponRepairPoints[RepairPoint], RepairPoint)

    SetTimeout(Timeout, function()
        Config.WeaponRepairPoints[RepairPoint].IsRepairing = false
        Config.WeaponRepairPoints[RepairPoint].RepairingData.Ready = true
        TriggerClientEvent('qb-weapons:client:SyncRepairShops', -1, Config.WeaponRepairPoints[RepairPoint], RepairPoint)
        exports['pfm-phone']:sendNewMailToOffline(Player.PlayerData.citizenid, {
            sender = Lang:t('mail.sender'),
            subject = Lang:t('mail.subject'),
            message = Lang:t('mail.message', { value = WeaponData.label })
        })

        SetTimeout(7 * 60000, function()
            if Config.WeaponRepairPoints[RepairPoint].RepairingData.Ready then
                Config.WeaponRepairPoints[RepairPoint].IsRepairing = false
                Config.WeaponRepairPoints[RepairPoint].RepairingData = {}
                TriggerClientEvent('qb-weapons:client:SyncRepairShops', -1, Config.WeaponRepairPoints[RepairPoint], RepairPoint)
            end
        end)
    end)

    cb(true)
end)

QBCore.Functions.CreateCallback('prison:server:checkThrowable', function(source, cb, weapon)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return cb(false) end
    if not weapon or not sharedWeapons[weapon] then return cb(false) end
    local throwable = false
    for _, v in pairs(Config.Throwables) do
        if sharedWeapons[weapon].name == 'weapon_' .. v then
            if not exports['pfm-inventory']:RemoveItem(source, 'weapon_' .. v, 1, false, 'prison:server:checkThrowable') then return cb(false) end
            throwable = true
            break
        end
    end
    cb(throwable)
end)

-- Events

-- Ammo a client reports can only go down (shots fired), except by the rounds of an ammo item the
-- server has taken from the player (removeWeaponAmmoItem) for that weapon's ammo type. Any client
-- could set any weapon to the cap before.
local ammoCredit = {} -- [src] = { [AMMO_TYPE] = rounds }

AddEventHandler('playerDropped', function()
    ammoCredit[source] = nil
end)

local function weaponAmmoType(weaponName)
    local weapon = type(weaponName) == 'string' and sharedWeapons[GetHashKey(weaponName)]
    return weapon and weapon.ammotype and tostring(weapon.ammotype):upper() or nil
end

RegisterNetEvent('qb-weapons:server:UpdateWeaponAmmo', function(CurrentWeaponData, amount)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount < 0 then return end
    amount = math.min(math.floor(amount), Config.MaxAmmoCount or 250)
    if type(CurrentWeaponData) == 'table' and CurrentWeaponData.slot then
        local slotItem = Player.PlayerData.items[tonumber(CurrentWeaponData.slot)]
        if slotItem and (not CurrentWeaponData.name or slotItem.name == CurrentWeaponData.name) then
            if type(slotItem.info) ~= 'table' then slotItem.info = {} end
            local current = math.max(0, math.floor(tonumber(slotItem.info.ammo) or 0))
            if amount > current and not QBCore.Functions.HasPermission(src, 'admin') then
                local ammoType = weaponAmmoType(slotItem.name)
                local credits = ammoCredit[src]
                local credit = ammoType and credits and credits[ammoType] or 0
                local raise = math.min(amount - current, credit)
                if raise > 0 then credits[ammoType] = credit - raise end
                amount = current + raise
            end
            slotItem.info.ammo = amount
        end
        Player.SetInventory(Player.PlayerData.items, true)
    end
end)

RegisterNetEvent('qb-weapons:server:TakeBackWeapon', function(k)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local repairShop = Config.WeaponRepairPoints[k]
    if not repairShop or not repairShop.RepairingData or not next(repairShop.RepairingData) then return end
    -- Only the owner can collect, and only once the repair has finished
    if repairShop.RepairingData.CitizenId ~= Player.PlayerData.citizenid then return end
    if not repairShop.RepairingData.Ready then return end
    local itemdata = repairShop.RepairingData.WeaponData
    if not itemdata or not itemdata.name then return end
    itemdata.info.quality = 100
    exports['pfm-inventory']:AddItem(src, itemdata.name, 1, false, itemdata.info, 'qb-weapons:server:TakeBackWeapon')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[itemdata.name], 'add')
    Config.WeaponRepairPoints[k].IsRepairing = false
    Config.WeaponRepairPoints[k].RepairingData = {}
    TriggerClientEvent('qb-weapons:client:SyncRepairShops', -1, Config.WeaponRepairPoints[k], k)
end)

RegisterNetEvent('qb-weapons:server:SetWeaponQuality', function(data, hp)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    -- Only the god-level /repairweapon command uses this path; never allow raising quality from the client
    if not QBCore.Functions.HasPermission(src, 'god') then return end
    if type(data) ~= 'table' or not data.slot then return end
    hp = tonumber(hp)
    if not hp then return end
    hp = math.max(0, math.min(hp, 100))
    local WeaponSlot = Player.PlayerData.items[data.slot]
    if not WeaponSlot then return end
    WeaponSlot.info.quality = hp
    Player.SetInventory(Player.PlayerData.items, true)
end)

RegisterNetEvent('qb-weapons:server:UpdateWeaponQuality', function(data, RepeatAmount)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if type(data) ~= 'table' or type(data.name) ~= 'string' or not data.slot then return end
    RepeatAmount = tonumber(RepeatAmount)
    if not RepeatAmount or RepeatAmount < 1 then return end
    RepeatAmount = math.min(math.floor(RepeatAmount), 100)
    local WeaponData = sharedWeapons[GetHashKey(data.name)]
    if not WeaponData then return end
    local WeaponSlot = Player.PlayerData.items[data.slot]
    local DecreaseAmount = Config.DurabilityMultiplier[data.name]
    if not DecreaseAmount then return end
    if WeaponSlot and WeaponSlot.name ~= data.name then return end
    if WeaponSlot then
        if not IsWeaponBlocked(WeaponData.name) then
            if WeaponSlot.info.quality then
                for _ = 1, RepeatAmount, 1 do
                    if WeaponSlot.info.quality - DecreaseAmount > 0 then
                        WeaponSlot.info.quality = Round(WeaponSlot.info.quality - DecreaseAmount, 2)
                    else
                        WeaponSlot.info.quality = 0
                        TriggerClientEvent('qb-weapons:client:UseWeapon', src, data, false)
                        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.weapon_broken_need_repair'), 'error')
                        break
                    end
                end
            else
                WeaponSlot.info.quality = 100
                for _ = 1, RepeatAmount, 1 do
                    if WeaponSlot.info.quality - DecreaseAmount > 0 then
                        WeaponSlot.info.quality = Round(WeaponSlot.info.quality - DecreaseAmount, 2)
                    else
                        WeaponSlot.info.quality = 0
                        TriggerClientEvent('qb-weapons:client:UseWeapon', src, data, false)
                        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.weapon_broken_need_repair'), 'error')
                        break
                    end
                end
            end
        end
    end
    Player.SetInventory(Player.PlayerData.items, true)
end)

RegisterNetEvent('qb-weapons:server:removeWeaponAmmoItem', function(item)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(item) ~= 'table' or not item.name or not item.slot then return end
    local ammo = Config.AmmoTypes[item.name]
    if not ammo then return end
    if not exports['pfm-inventory']:RemoveItem(src, item.name, 1, item.slot, 'qb-weapons:server:removeWeaponAmmoItem') then return end
    -- the rounds of the box just taken may now be added to a weapon of that ammo type
    local ammoType = tostring(ammo.ammoType):upper()
    ammoCredit[src] = ammoCredit[src] or {}
    ammoCredit[src][ammoType] = (ammoCredit[src][ammoType] or 0) + ammo.amount
end)

-- Commands

QBCore.Commands.Add('repairweapon', 'Repair Weapon (God Only)', { { name = 'hp', help = Lang:t('info.hp_of_weapon') } }, true, function(source, args)
    TriggerClientEvent('qb-weapons:client:SetWeaponQuality', source, tonumber(args[1]))
end, 'god')

-- Items

-- AMMO
for ammoItem, properties in pairs(Config.AmmoTypes) do
    QBCore.Functions.CreateUseableItem(ammoItem, function(source, item)
        TriggerClientEvent('qb-weapons:client:AddAmmo', source, properties.ammoType, properties.amount, item)
    end)
end

-- TINTS

local function GetWeaponSlotByName(items, weaponName)
    for index, item in pairs(items) do
        if item.name == weaponName then
            return item, index
        end
    end
    return nil, nil
end

local function IsMK2Weapon(weaponHash)
    local weaponName = sharedWeapons[weaponHash]['name']
    return string.find(weaponName, 'mk2') ~= nil
end

local function EquipWeaponTint(source, tintIndex, item, isMK2)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end

    local ped = GetPlayerPed(source)
    local selectedWeaponHash = GetSelectedPedWeapon(ped)

    if selectedWeaponHash == `WEAPON_UNARMED` then
        TriggerClientEvent('QBCore:Notify', source, 'You have no weapon selected.', 'error')
        return
    end

    local weaponName = sharedWeapons[selectedWeaponHash].name
    if not weaponName then return end

    if isMK2 and not IsMK2Weapon(selectedWeaponHash) then
        TriggerClientEvent('QBCore:Notify', source, 'This tint is only for MK2 weapons', 'error')
        return
    end

    local weaponSlot, weaponSlotIndex = GetWeaponSlotByName(Player.PlayerData.items, weaponName)
    if not weaponSlot then return end

    if weaponSlot.info.tint == tintIndex then
        TriggerClientEvent('QBCore:Notify', source, 'This tint is already applied to your weapon.', 'error')
        return
    end

    weaponSlot.info.tint = tintIndex
    Player.PlayerData.items[weaponSlotIndex] = weaponSlot
    Player.SetInventory(Player.PlayerData.items, true)
    exports['pfm-inventory']:RemoveItem(source, item, 1, false, 'qb-weapon:EquipWeaponTint')
    TriggerClientEvent('qb-inventory:client:ItemBox', source, sharedItems[item], 'remove')
    TriggerClientEvent('qb-weapons:client:EquipTint', source, selectedWeaponHash, tintIndex)
end

for i = 0, 7 do
    QBCore.Functions.CreateUseableItem('weapontint_' .. i, function(source, item)
        EquipWeaponTint(source, i, item.name, false)
    end)
end

for i = 0, 32 do
    QBCore.Functions.CreateUseableItem('weapontint_mk2_' .. i, function(source, item)
        EquipWeaponTint(source, i, item.name, true)
    end)
end

-- Attachments

local function HasAttachment(component, attachments)
    for k, v in pairs(attachments) do
        if v.component == component then
            return true, k
        end
    end
    return false, nil
end

local function DoesWeaponTakeWeaponComponent(item, weaponName)
    if WeaponAttachments[item] and WeaponAttachments[item][weaponName] then
        return WeaponAttachments[item][weaponName]
    end
    return false
end

local function EquipWeaponAttachment(src, item)
    local shouldRemove = false
    local ped = GetPlayerPed(src)
    local selectedWeaponHash = GetSelectedPedWeapon(ped)
    if selectedWeaponHash == `WEAPON_UNARMED` then return end
    local weaponName = sharedWeapons[selectedWeaponHash].name
    if not weaponName then return end
    local attachmentComponent = DoesWeaponTakeWeaponComponent(item, weaponName)
    if not attachmentComponent then
        TriggerClientEvent('QBCore:Notify', src, 'This attachment is not valid for the selected weapon.', 'error')
        return
    end
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local weaponSlot, weaponSlotIndex = GetWeaponSlotByName(Player.PlayerData.items, weaponName)
    if not weaponSlot then return end
    weaponSlot.info.attachments = weaponSlot.info.attachments or {}
    local hasAttach, attachIndex = HasAttachment(attachmentComponent, weaponSlot.info.attachments)
    if hasAttach then
        RemoveWeaponComponentFromPed(ped, selectedWeaponHash, attachmentComponent)
        table.remove(weaponSlot.info.attachments, attachIndex)
    else
        weaponSlot.info.attachments[#weaponSlot.info.attachments + 1] = {
            component = attachmentComponent,
        }
        GiveWeaponComponentToPed(ped, selectedWeaponHash, attachmentComponent)
        shouldRemove = true
    end
    Player.PlayerData.items[weaponSlotIndex] = weaponSlot
    Player.SetInventory(Player.PlayerData.items, true)
    if shouldRemove then
        exports['pfm-inventory']:RemoveItem(src, item, 1, false, 'qb-weapons:EquipWeaponAttachment')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'remove')
    end
end

for attachmentItem in pairs(WeaponAttachments) do
    QBCore.Functions.CreateUseableItem(attachmentItem, function(source, item)
        EquipWeaponAttachment(source, item.name)
    end)
end

QBCore.Functions.CreateCallback('qb-weapons:server:RemoveAttachment', function(source, cb, AttachmentData, WeaponData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return cb(false) end
    if type(AttachmentData) ~= 'table' or type(WeaponData) ~= 'table' or not WeaponData.slot or type(WeaponData.name) ~= 'string' then return cb(false) end
    local Inventory = Player.PlayerData.items
    local allAttachments = WeaponAttachments
    if not AttachmentData.attachment or not allAttachments[AttachmentData.attachment] then return cb(false) end
    local AttachmentComponent = allAttachments[AttachmentData.attachment][WeaponData.name]
    if not AttachmentComponent then return cb(false) end
    -- The claimed slot must actually hold the claimed weapon
    if Inventory[WeaponData.slot] and Inventory[WeaponData.slot].name ~= WeaponData.name then return cb(false) end
    if Inventory[WeaponData.slot] then
        if Inventory[WeaponData.slot].info.attachments and next(Inventory[WeaponData.slot].info.attachments) then
            local HasAttach, key = HasAttachment(AttachmentComponent, Inventory[WeaponData.slot].info.attachments)
            if HasAttach then
                table.remove(Inventory[WeaponData.slot].info.attachments, key)
                Player.SetInventory(Player.PlayerData.items, true)
                exports['pfm-inventory']:AddItem(src, AttachmentData.attachment, 1, false, false, 'qb-weapons:server:RemoveAttachment')
                TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[AttachmentData.attachment], 'add')
                TriggerClientEvent('QBCore:Notify', src, Lang:t('info.removed_attachment', { value = sharedItems[AttachmentData.attachment].label }), 'error')
                cb(Inventory[WeaponData.slot].info.attachments)
            else
                cb(false)
            end
        else
            cb(false)
        end
    else
        cb(false)
    end
end)
