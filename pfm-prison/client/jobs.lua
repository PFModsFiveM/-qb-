currentLocation = 1 -- the electrician spot the server gave (prison:client:SetJob)
currentBlip = 0
local isWorking = false
-- true while the stay is a pf-justice order (prison:client:Enter); the old metadata runtime keeps
-- the old electrician event
local justiceStay = true
local session = nil      -- the shift the server started (pfm-prison:client:WorkSession)
local sessionBlip = 0

-- Functions

local function notify(text, kind) QBCore.Functions.Notify(text, kind or 'primary') end

--- Shows the blip of the job spot the server gave
--- @return nil
function CreateJobBlip() -- Used globally
    if DoesBlipExist(currentBlip) then
        RemoveBlip(currentBlip)
    end
    local spots = currentJob and Config.Locations.jobs[currentJob]
    local spot = spots and spots[currentLocation]
    if not spot then return end
    local coords = spot.coords.xyz
    currentBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(currentBlip, 402)
    SetBlipDisplay(currentBlip, 4)
    SetBlipScale(currentBlip, 0.8)
    SetBlipAsShortRange(currentBlip, true)
    SetBlipColour(currentBlip, 1)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(Lang:t('info.work_blip'))
    EndTextCommandSetBlipName(currentBlip)
end

--- The electrician round is done: the server checks the spot and records the shift (time credit,
--- wage into the trust) and gives the next spot. The old runtime keeps its own event.
--- @return nil
local function JobDone()
    if justiceStay then
        TriggerServerEvent('pfm-prison:server:ElectricianDone', currentLocation)
    else
        TriggerServerEvent('prison:server:JobDone', currentLocation)
    end
end

--- This will be triggered once you interact with a job location to perform your job at
--- @return nil
local function StartWork()
    if isWorking or not currentJob then return end
    isWorking = true
    -- at least 6 s: the server must have seen the inmate at the spot for Config.Prison.JobDwellSeconds
    QBCore.Functions.Progressbar('work_electric', Lang:t('info.working_electricity'), math.random(6000, 10000), false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'anim@gangops@facility@servers@',
        anim = 'hotwire',
        flags = 16,
    }, {}, {}, function() -- Done
        isWorking = false
        StopAnimTask(PlayerPedId(), 'anim@gangops@facility@servers@', 'hotwire', 1.0)
        JobDone()
    end, function() -- Cancel
        isWorking = false
        StopAnimTask(PlayerPedId(), 'anim@gangops@facility@servers@', 'hotwire', 1.0)
        QBCore.Functions.Notify(Lang:t('error.cancelled'), 'error')
    end)
end

-- ── shifts (kitchen, laundry, maintenance) ─────────────────────────────────────────────────────

local function clearSessionBlip()
    if DoesBlipExist(sessionBlip) then RemoveBlip(sessionBlip) end
    sessionBlip = 0
end

--- Where the shift goes next: the next station, the work site, or back to the board to hand it in.
local function sessionTarget()
    if not session then return nil end
    if session.site then
        return vector3(session.site.x, session.site.y, session.site.z), 'Report the work unit', 'finish', math.max(3.0, (session.site.r or 10) * 0.8)
    end
    local st = session.steps and session.steps[session.next]
    if st then return vector3(st.x, st.y, st.z), st.label, session.next, 2.0 end
    return Config.Work.Board, 'Hand in the shift', 'finish', 2.0
end

local function showSessionBlip()
    clearSessionBlip()
    local at = sessionTarget()
    if not at then return end
    sessionBlip = AddBlipForCoord(at.x, at.y, at.z)
    SetBlipSprite(sessionBlip, 402)
    SetBlipColour(sessionBlip, 5)
    SetBlipScale(sessionBlip, 0.8)
    SetBlipRoute(sessionBlip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(session.label or 'Prison work')
    EndTextCommandSetBlipName(sessionBlip)
end

RegisterNetEvent('pfm-prison:client:WorkSession', function(data, why)
    if GetInvokingResource() then return end
    session = type(data) == 'table' and data or nil
    if session then showSessionBlip() else clearSessionBlip() end
    if not session and type(why) == 'string' then notify(why, 'error') end
end)

--- One station: a short animation, then the server decides whether it counted.
local function doStep(index, label)
    if isWorking then return end
    isWorking = true
    local st = session and session.steps and session.steps[index]
    -- the server wants each station's own minimum time since the previous one
    local ms = math.max(5000, ((st and st.minSeconds) or 8) * 1000)
    QBCore.Functions.Progressbar('prison_work_step', label, ms, false, true, {
        disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true,
    }, { animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@', anim = 'machinic_loop_mechandplayer', flags = 16 }, {}, {}, function()
        isWorking = false
        ClearPedTasks(PlayerPedId())
        TriggerServerEvent('pfm-prison:server:WorkStep', index)
    end, function()
        isWorking = false
        ClearPedTasks(PlayerPedId())
        notify(Lang:t('error.cancelled'), 'error')
    end)
end

-- ── the work board and the trust window (pfm-menu / pfm-input: the shared look; text only) ─────

AddEventHandler('pfm-prison:client:OpenBoard', function()
    QBCore.Functions.TriggerCallback('pfm-prison:server:workState', function(state)
        if type(state) ~= 'table' then return notify('Only inmates can use the work board', 'error') end
        local menu = { {
            header = 'Work board', isMenuHeader = true,
            txt = ('Shifts today %d/%d · credit %d/%d min · wages $%d/$%d'):format(state.shifts or 0, state.maxShifts or 0,
                state.creditMinutes or 0, state.maxCreditMinutes or 0, state.wage or 0, state.maxWage or 0),
        } }
        if state.session then
            menu[#menu + 1] = { header = 'Drop the ' .. tostring(state.session.label) .. ' shift', txt = 'Nothing is earned for it',
                params = { event = 'pfm-prison:server:WorkDrop', isServer = true } }
        else
            for _, job in ipairs(state.jobs or {}) do
                menu[#menu + 1] = { header = tostring(job.label), txt = ('$%d to your trust · up to %d min off'):format(job.wage or 0, job.minutes or 0),
                    params = { event = 'pfm-prison:server:WorkStart', isServer = true, args = job.name } }
            end
        end
        exports['pfm-menu']:openMenu(menu)
    end)
end)

local catalog = {}

AddEventHandler('pfm-prison:client:OpenKiosk', function()
    QBCore.Functions.TriggerCallback('pfm-prison:server:trustState', function(state)
        if type(state) ~= 'table' then return notify('Only inmates can use the trust window', 'error') end
        if not state.ok then return notify(state.message or 'The trust office is unavailable', 'error') end
        catalog = state.catalog or {}
        local menu = { {
            header = ('Trust account: $%d'):format(state.balance or 0), isMenuHeader = true,
            txt = (state.incoming or 0) > 0 and ('$%d incoming · $%d left to spend today'):format(state.incoming, state.spendLeft or 0)
                or ('$%d left to spend today'):format(state.spendLeft or 0),
        } }
        menu[#menu + 1] = { header = 'Deposit from my bank', txt = ('Up to $%d today'):format(state.depositLeft or 0),
            params = { event = 'pfm-prison:client:AskDeposit', args = state.maxDeposit } }
        if state.revoked then
            menu[#menu + 1] = { header = 'Commissary', txt = 'Your commissary privilege is suspended', disabled = true }
        else
            for _, entry in ipairs(catalog) do
                menu[#menu + 1] = { header = ('%s · $%d'):format(tostring(entry.label), entry.price or 0),
                    txt = ('%d left today'):format(entry.left or 0), disabled = (entry.left or 0) < 1,
                    params = { event = 'pfm-prison:client:AskBuy', args = entry.index } }
            end
        end
        exports['pfm-menu']:openMenu(menu)
    end)
end)

AddEventHandler('pfm-prison:client:AskDeposit', function(max)
    local input = exports['pfm-input']:ShowInput({
        header = 'Deposit to your trust', submitText = 'Deposit',
        inputs = { { text = ('Amount (1-%d)'):format(tonumber(max) or 0), name = 'amount', type = 'number', isRequired = true } },
    })
    local amount = input and tonumber(input.amount)
    if amount then TriggerServerEvent('pfm-prison:server:TrustDeposit', math.floor(amount)) end
end)

AddEventHandler('pfm-prison:client:AskBuy', function(index)
    local entry
    for _, e in ipairs(catalog) do if e.index == index then entry = e end end
    if not entry then return end
    local input = exports['pfm-input']:ShowInput({
        header = tostring(entry.label), submitText = 'Buy',
        inputs = { { text = ('How many (1-%d)'):format(math.min(10, entry.left or 0)), name = 'qty', type = 'number', isRequired = true } },
    })
    local qty = input and tonumber(input.qty)
    if qty then TriggerServerEvent('pfm-prison:server:CommissaryBuy', index, math.floor(qty)) end
end)

-- The stay's regime and the end of a stay (client/main.lua keeps the rest of the state).
RegisterNetEvent('prison:client:Enter', function(_, _, _, _, justice)
    if GetInvokingResource() then return end
    justiceStay = justice == true
end)
local function endStay()
    session = nil
    clearSessionBlip()
end
RegisterNetEvent('prison:client:Released', function() if not GetInvokingResource() then endStay() end end)
RegisterNetEvent('prison:client:Escaped', function() if not GetInvokingResource() then endStay() end end)

-- Threads

CreateThread(function()
    local isInside = false
    for k in pairs(Config.Locations.jobs) do
        for i = 1, #Config.Locations.jobs[k] do
            local current = Config.Locations.jobs[k][i]
            if Config.UseTarget then
                exports['pfm-target']:AddBoxZone('work_' .. k .. '_' .. i, current.coords.xyz, 1.5, 1.6, {
                    name = 'work_' .. k .. '_' .. i,
                    heading = 12.0,
                    debugPoly = false,
                    minZ = 19,
                    maxZ = 219
                }, {
                    options = {
                        {
                            icon = 'fa-solid fa-bolt',
                            label = Lang:t('info.job_interaction_target', { job = Config.Jobs[k] }),
                            canInteract = function()
                                return inJail and currentJob == k and not isWorking and i == currentLocation
                            end,
                            action = function()
                                StartWork()
                            end
                        }
                    },
                    distance = 2.5
                })
            else
                local jobZone = BoxZone:Create(current.coords.xyz, 3.0, 5.0, {
                    name = 'work_' .. k .. '_' .. i,
                    debugPoly = false,
                })
                jobZone:onPlayerInOut(function(isPointInside)
                    isInside = isPointInside and inJail and currentJob == k and i == currentLocation and not isWorking
                    if isInside then
                        exports['pfm-core']:DrawText(Lang:t('info.job_interaction'), 'left')
                    else
                        exports['pfm-core']:HideText()
                    end
                end)
            end
        end
    end
    if not Config.UseTarget then
        while true do
            local sleep = 1000
            if isInside and not isWorking then
                sleep = 0
                if IsControlJustReleased(0, 38) then
                    exports['pfm-core']:HideText()
                    isInside = false
                    StartWork()
                    sleep = 1000
                end
            end
            Wait(sleep)
        end
    end
end)

-- The work board, the trust window and the shift's next point: looked up twice a second while in
-- prison; a per-frame wait for the key only while standing at one of them.
CreateThread(function()
    local shown = nil
    while true do
        local sleep = 500
        local near = nil
        if inJail and not isWorking then
            local pos = GetEntityCoords(PlayerPedId())
            local at, label, action, reach = sessionTarget()
            if at and #(pos - at) <= reach then
                near = { text = '[E] ' .. tostring(label), act = action }
            elseif Config.Work and Config.Work.Board and #(pos - Config.Work.Board) <= 2.0 then
                near = { text = '[E] Work board', act = 'board' }
            elseif Config.Economy and Config.Economy.Kiosk and #(pos - Config.Economy.Kiosk) <= 2.0 then
                near = { text = '[E] Trust window and commissary', act = 'kiosk' }
            end
        end
        if near then
            sleep = 0
            if shown ~= near.text then exports['pfm-core']:DrawText(near.text, 'left') shown = near.text end
            if IsControlJustReleased(0, 38) then
                exports['pfm-core']:HideText()
                shown = nil
                if near.act == 'board' then TriggerEvent('pfm-prison:client:OpenBoard')
                elseif near.act == 'kiosk' then TriggerEvent('pfm-prison:client:OpenKiosk')
                elseif near.act == 'finish' then TriggerServerEvent('pfm-prison:server:WorkFinish')
                else doStep(near.act, near.text:sub(5)) end
                sleep = 500
            end
        elseif shown then
            exports['pfm-core']:HideText()
            shown = nil
        end
        Wait(sleep)
    end
end)
