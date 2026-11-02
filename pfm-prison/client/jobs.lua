currentLocation = 1 -- the job spot the server gave (prison:client:SetJob)
currentBlip = 0
local isWorking = false

-- Functions

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

--- The work is done: the server checks the spot, may cut the sentence and gives the next spot
--- @return nil
local function JobDone()
    TriggerServerEvent('prison:server:JobDone', currentLocation)
end

--- This will be triggered once you interact with a job location to perform your job at
--- @return nil
local function StartWork()
    if isWorking or not currentJob then return end
    isWorking = true
    QBCore.Functions.Progressbar('work_electric', Lang:t('info.working_electricity'), math.random(5000, 10000), false, true, {
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
