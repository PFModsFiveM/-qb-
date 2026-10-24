local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local zones = {}

local isPlayerInsideBankZone = false

-- Functions

local function GetNearestBrand()
    local coords = GetEntityCoords(PlayerPedId())
    local bestIdx, bestDist = nil, 999999.0
    for i = 1, #Config.locations do
        local dist = #(coords - Config.locations[i])
        if dist < bestDist then
            bestDist = dist
            bestIdx = i
        end
    end
    local brandId = (bestIdx and bestDist < 50.0 and Config.locationBrands[bestIdx]) or 'fleeca'
    local style = Config.brandStyles[brandId] or Config.brandStyles.fleeca
    return brandId, style
end

local function OpenBank()
    QBCore.Functions.TriggerCallback('qb-banking:server:openBank', function(accounts, statements, playerData)
        QBCore.Functions.TriggerCallback('qb-banking:server:getFinance', function(finance)
            QBCore.Functions.TriggerCallback('qb-banking:server:getAccountsData', function(accountsData)
                local brandId, brandStyle = GetNearestBrand()
                SetNuiFocus(true, true)
                SendNUIMessage({
                    action = 'openBank',
                    accounts = accounts,
                    statements = statements,
                    playerData = playerData,
                    finance = finance,
                    accountsData = accountsData,
                    brand = brandId,
                    brandStyle = brandStyle
                })
            end)
        end)
    end)
end

local function OpenATM()
    QBCore.Functions.Progressbar('accessing_atm', Lang:t('progress.atm'), 1500, false, true, {
        disableMovement = false,
        disableCarMovement = false,
        disableMouse = false,
        disableCombat = false,
    }, {
        animDict = 'amb@prop_human_atm@male@enter',
        anim = 'enter',
    }, {
        model = 'prop_cs_credit_card',
        bone = 28422,
        coords = vector3(0.1, 0.03, -0.05),
        rotation = vector3(0.0, 0.0, 180.0),
    }, {}, function()
        QBCore.Functions.TriggerCallback('qb-banking:server:openATM', function(accounts, playerData, acceptablePins)
            SetNuiFocus(true, true)
            SendNUIMessage({
                action = 'openATM',
                accounts = accounts,
                pinNumbers = acceptablePins,
                playerData = playerData
            })
        end)
    end)
end

local function NearATM()
    local playerCoords = GetEntityCoords(PlayerPedId())
    for _, v in pairs(Config.atmModels) do
        local hash = joaat(v)
        local atm = IsObjectNearPoint(hash, playerCoords.x, playerCoords.y, playerCoords.z, 1.5)
        if atm then
            return true
        end
    end
end

-- NUI Callback

RegisterNUICallback('closeApp', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('withdraw', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:withdraw', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('deposit', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:deposit', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('internalTransfer', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:internalTransfer', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('externalTransfer', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:externalTransfer', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('orderCard', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:orderCard', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('openAccount', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:openAccount', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('renameAccount', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:renameAccount', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('deleteAccount', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:deleteAccount', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('addUser', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:addUser', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('removeUser', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:removeUser', function(status)
        cb(status)
    end, data)
end)

-- Finance (loans / credit score / cards)

local financeEndpoints = { 'getFinance', 'applyLoan', 'payLoan', 'payoffLoan', 'orderCreditCard', 'cardAdvance', 'payCard' }
for _, endpoint in ipairs(financeEndpoints) do
    RegisterNUICallback(endpoint, function(data, cb)
        QBCore.Functions.TriggerCallback('qb-banking:server:' .. endpoint, function(result)
            cb(result)
        end, data)
    end)
end

-- Multi-account banking (shared/business accounts, members, debit cards)

local accountEndpoints = {
    'getAccountsData', 'createAccount', 'accountRename', 'accountColor', 'accountDelete',
    'accountDeposit', 'accountWithdraw', 'accountTransfer',
    'addMember', 'updateMember', 'removeMember',
    'createCard', 'cancelCard', 'toggleCardLock',
}
for _, endpoint in ipairs(accountEndpoints) do
    RegisterNUICallback(endpoint, function(data, cb)
        QBCore.Functions.TriggerCallback('qb-banking:server:' .. endpoint, function(result)
            cb(result)
        end, data)
    end)
end

-- PF global UI theme (players edit it in the pf-hud /hud menu)
local function pfApplyTheme(theme)
    if theme then SendNUIMessage({ action = 'theme', theme = theme }) end
end
AddEventHandler('pf-ui:themeUpdated', pfApplyTheme)
CreateThread(function()
    Wait(2000)
    if GetResourceState('pf-hud') == 'started' then
        local ok, theme = pcall(function() return exports['pf-hud']:GetTheme() end)
        if ok then pfApplyTheme(theme) end
    end
end)

-- Events

RegisterNetEvent('qb-banking:client:useCard', function()
    if NearATM() then OpenATM() end
end)

-- Threads

CreateThread(function()
    for i = 1, #Config.locations do
        local blip = AddBlipForCoord(Config.locations[i])
        SetBlipSprite(blip, Config.blipInfo.sprite)
        SetBlipDisplay(blip, 4)
        SetBlipScale(blip, Config.blipInfo.scale)
        SetBlipColour(blip, Config.blipInfo.color)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(tostring(Config.blipInfo.name))
        EndTextCommandSetBlipName(blip)
    end
end)

if Config.useTarget then
    CreateThread(function()
        for i = 1, #Config.locations do
            exports['pfm-target']:AddCircleZone('bank_' .. i, Config.locations[i], 1.0, {
                name = 'bank_' .. i,
                useZ = true,
                debugPoly = false,
            }, {
                options = {
                    {
                        icon = 'fas fa-university',
                        label = 'Open Bank',
                        action = function()
                            OpenBank()
                        end,
                    }
                },
                distance = 1.5
            })
        end
    end)

    CreateThread(function()
        for i = 1, #Config.atmModels do
            local atmModel = Config.atmModels[i]
            exports['pfm-target']:AddTargetModel(atmModel, {
                options = {
                    {
                        icon = 'fas fa-university',
                        label = 'Open ATM',
                        item = 'bank_card',
                        action = function()
                            OpenATM()
                        end,
                    }
                },
                distance = 1.5
            })
        end
    end)
end

if not Config.useTarget then
    CreateThread(function()
        for i = 1, #Config.locations do
            local zone = CircleZone:Create(Config.locations[i], 3.0, {
                name = 'bank_' .. i,
                debugPoly = false,
            })
            zones[#zones + 1] = zone
        end

        local combo = ComboZone:Create(zones, {
            name = 'bank_combo',
            debugPoly = false,
        })

        combo:onPlayerInOut(function(isPointInside)
            isPlayerInsideBankZone = isPointInside
            if isPlayerInsideBankZone then
                exports['pfm-core']:DrawText('Open Bank')
                CreateThread(function()
                    while isPlayerInsideBankZone do
                        Wait(0)
                        if IsControlJustPressed(0, 38) then
                            OpenBank()
                        end
                    end
                end)
            else
                exports['pfm-core']:HideText()
            end
        end)
    end)
end
