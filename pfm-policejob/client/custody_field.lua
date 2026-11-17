-- Field custody on the client (batch 18A). The server decides everything (server/custody_field.lua);
-- this file only picks the nearest player as a hint, asks, and plays what the server says: hands up,
-- detained controls, the escort attachment, the seat the server chose and the pat-down list.

local fieldState = 'free' -- this player's own state, as the server last told it

local function nearestPlayer(maxDistance)
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player ~= -1 and distance < (maxDistance or 2.5) then return GetPlayerServerId(player), player end
    QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
    return nil
end

local function ask(event, maxDistance)
    if isHandcuffed or isEscorted then return end
    local target = nearestPlayer(maxDistance)
    if target then TriggerServerEvent(event, target) end
end

local function loadDict(dict)
    RequestAnimDict(dict)
    local tries = 0
    while not HasAnimDictLoaded(dict) and tries < 200 do Wait(10) tries = tries + 1 end
end

-- ── what the server tells this player ─────────────────────────────────────────────────────────

-- Hands up while surrendered; the controls a detained player may not use. The loop only runs while
-- one of the two states is active.
local function stateLoop()
    CreateThread(function()
        while fieldState == 'surrendered' or fieldState == 'detained' do
            local ped = PlayerPedId()
            if fieldState == 'surrendered' and not isHandcuffed and not IsEntityPlayingAnim(ped, 'missminuteman_1ig_2', 'handsup_base', 3) then
                loadDict('missminuteman_1ig_2')
                TaskPlayAnim(ped, 'missminuteman_1ig_2', 'handsup_base', 8.0, 8.0, -1, 50, 0, false, false, false)
            end
            DisableControlAction(0, 21, true)  -- sprint
            DisableControlAction(0, 22, true)  -- jump
            DisableControlAction(0, 24, true)  -- attack
            DisableControlAction(0, 25, true)  -- aim
            DisableControlAction(0, 23, true)  -- enter vehicle
            DisableControlAction(0, 140, true) -- melee
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            Wait(0)
        end
    end)
end

RegisterNetEvent('police:client:FieldState', function(state, _by)
    local was = fieldState
    fieldState = type(state) == 'string' and state or 'free'
    if was == 'surrendered' and fieldState ~= 'surrendered' and not isHandcuffed then
        StopAnimTask(PlayerPedId(), 'missminuteman_1ig_2', 'handsup_base', 1.0)
    end
    if (fieldState == 'surrendered' or fieldState == 'detained') and was ~= 'surrendered' and was ~= 'detained' then stateLoop() end
end)

-- The escort attachment (escort = walk beside, carry = over the shoulder). on = false lets go.
RegisterNetEvent('police:client:SetEscorted', function(on, by, kind)
    local ped = PlayerPedId()
    if on then
        local dragger = GetPlayerPed(GetPlayerFromServerId(tonumber(by) or -1))
        if dragger == 0 or not DoesEntityExist(dragger) then return end
        isEscorted = true
        if kind == 'carry' then
            loadDict('nm')
            AttachEntityToEntity(ped, dragger, 0, 0.27, 0.15, 0.63, 0.5, 0.5, 0.0, false, false, false, false, 2, false)
            TaskPlayAnim(ped, 'nm', 'firemans_carry', 8.0, -8.0, 100000, 33, 0, false, false, false)
        else
            SetEntityCoords(ped, GetOffsetFromEntityInWorldCoords(dragger, 0.0, 0.45, 0.0))
            AttachEntityToEntity(ped, dragger, 11816, 0.45, 0.45, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
        end
    else
        isEscorted = false
        DetachEntity(ped, true, false)
        if kind == 'carry' then ClearPedTasksImmediately(ped) end
    end
    TriggerEvent('hospital:client:isEscorted', isEscorted)
end)

-- The pat-down result: the weapons the server found; picking one asks the server to seize it.
RegisterNetEvent('police:client:FriskResult', function(target, list)
    if type(list) ~= 'table' or #list == 0 then
        QBCore.Functions.Notify(Lang:t('field.frisk_none'), 'primary')
        return
    end
    local menu = { { header = Lang:t('field.frisk_header'), isMenuHeader = true } }
    for _, w in ipairs(list) do
        menu[#menu + 1] = {
            header = tostring(w.label or w.name),
            txt = w.serial and (Lang:t('field.serial') .. ' ' .. tostring(w.serial)) or Lang:t('field.no_serial'),
            params = { event = 'police:client:FriskSeize', args = { target = target, slot = w.slot } },
        }
    end
    menu[#menu + 1] = { header = Lang:t('menu.close'), txt = '', params = { event = 'qb-menu:client:closeMenu' } }
    exports['pfm-menu']:openMenu(menu)
end)

RegisterNetEvent('police:client:FriskSeize', function(data)
    if type(data) ~= 'table' then return end
    TriggerServerEvent('police:server:FriskSeize', data.target, data.slot)
end)

-- ── what this player asks (radial menu entries, target options and commands use these) ────────

RegisterNetEvent('police:client:Surrender', function()
    if isHandcuffed or isEscorted then return end
    TriggerServerEvent('police:server:Surrender')
end)
RegisterNetEvent('police:client:Detain', function() ask('police:server:Detain') end)
RegisterNetEvent('police:client:Frisk', function() ask('police:server:Frisk') end)
RegisterNetEvent('police:client:Ziptie', function() ask('police:server:Ziptie') end)
RegisterNetEvent('police:client:CutZiptie', function() ask('police:server:CutZiptie') end)
RegisterNetEvent('police:client:Arrest', function() ask('police:server:Arrest') end)
RegisterNetEvent('police:client:ReleaseAtScene', function() ask('police:server:ReleaseAtScene') end)
RegisterNetEvent('police:client:SeizeProperty', function() ask('police:server:SeizeProperty') end)

RegisterCommand('surrender', function() TriggerEvent('police:client:Surrender') end, false)
RegisterCommand('detain', function() TriggerEvent('police:client:Detain') end, false)
RegisterCommand('frisk', function() TriggerEvent('police:client:Frisk') end, false)
RegisterCommand('ziptie', function() TriggerEvent('police:client:Ziptie') end, false)
RegisterCommand('cutziptie', function() TriggerEvent('police:client:CutZiptie') end, false)
RegisterCommand('arrest', function() TriggerEvent('police:client:Arrest') end, false)
RegisterCommand('releasescene', function() TriggerEvent('police:client:ReleaseAtScene') end, false)
RegisterCommand('seizeproperty', function() TriggerEvent('police:client:SeizeProperty') end, false)

-- /handover <officer id>: the suspect nearest to you goes to that officer (both must stand with them).
RegisterCommand('handover', function(_, args)
    local to = tonumber(args and args[1])
    if not to then QBCore.Functions.Notify(Lang:t('field.handover_usage'), 'error') return end
    local target = nearestPlayer()
    if target then TriggerServerEvent('police:server:HandOver', target, to) end
end, false)

-- /cell <cell id>, e.g. /cell mrpd_cell_1: the booked suspect nearest to you goes into that holding cell.
RegisterCommand('cell', function(_, args)
    local cellId = args and args[1]
    if type(cellId) ~= 'string' or cellId == '' then QBCore.Functions.Notify(Lang:t('field.cell_usage'), 'error') return end
    local target = nearestPlayer()
    if target then TriggerServerEvent('police:server:PlaceInCell', target, cellId) end
end, false)

TriggerEvent('chat:addSuggestion', '/surrender', Lang:t('field.cmd_surrender'))
TriggerEvent('chat:addSuggestion', '/handover', Lang:t('field.cmd_handover'), { { name = 'id', help = Lang:t('info.player_id') } })
TriggerEvent('chat:addSuggestion', '/cell', Lang:t('field.cmd_cell'), { { name = 'cell', help = 'mrpd_cell_1' } })
