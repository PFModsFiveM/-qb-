-- Event Handler

-- Duty points registered by resources (RegisterDutyPoints below), and each player's last duty toggle
local DutyPoints = {}     -- [resource] = { [key] = { job, type, points = { vector3 }, radius } }
local lastDutyToggle = {} -- [src] = GetGameTimer()

AddEventHandler('chatMessage', function(_, _, message)
    if string.sub(message, 1, 1) == '/' then
        CancelEvent()
        return
    end
end)

AddEventHandler('playerDropped', function(reason)
    local src = source
    lastDutyToggle[src] = nil
    if not QBCore.Players[src] then return end
    local player = QBCore.Players[src]
    TriggerEvent('qb-log:server:CreateLog', 'joinleave', 'Dropped', 'red', '**' .. GetPlayerName(src) .. '** (' .. player.PlayerData.license .. ') left..' .. '\n **Reason:** ' .. reason)
    player.Functions.Save()
    TriggerEvent('QBCore:Server:PlayerDropped', src)
    TriggerEvent('QBCore:Server:OnPlayerUnload', src)
    QBCore.Player_Buckets[player.PlayerData.license] = nil
    QBCore.PlayersByCitizenId[player.PlayerData.citizenid] = nil
    QBCore.Players[src] = nil
end)

AddEventHandler('onResourceStop', function(resName)
    for i, v in pairs(QBCore.UsableItems) do
        if v.resource == resName then
            QBCore.UsableItems[i] = nil
        end
    end
    DutyPoints[resName] = nil -- a stopped resource's duty points go with it
end)

-- Player Connecting
local readyFunction = MySQL.ready
local databaseConnected, bansTableExists = readyFunction == nil, readyFunction == nil
if readyFunction ~= nil then
    MySQL.ready(function()
        databaseConnected = true

        local DatabaseInfo = QBCore.Functions.GetDatabaseInfo()
        if not DatabaseInfo or not DatabaseInfo.exists then return end

        local result = MySQL.query.await('SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = "bans";', { DatabaseInfo.database })
        if result and result[1] then
            bansTableExists = true
        end
    end)
end

local function onPlayerConnecting(name, _, deferrals)
    local src = source
    deferrals.defer()

    if QBCore.Config.Server.Closed and not IsPlayerAceAllowed(src, 'qbadmin.join') then
        return deferrals.done(QBCore.Config.Server.ClosedReason)
    end

    if not databaseConnected then
        return deferrals.done(Lang:t('error.connecting_database_error'))
    end

    if QBCore.Config.Server.Whitelist then
        Wait(0)
        deferrals.update(string.format(Lang:t('info.checking_whitelisted'), name))
        if not QBCore.Functions.IsWhitelisted(src) then
            return deferrals.done(Lang:t('error.not_whitelisted'))
        end
    end

    Wait(0)
    deferrals.update(string.format('Hello %s. Your license is being checked', name))
    local license = QBCore.Functions.GetIdentifier(src, 'license')

    if not license then
        return deferrals.done(Lang:t('error.no_valid_license'))
    elseif QBCore.Config.Server.CheckDuplicateLicense and QBCore.Functions.IsLicenseInUse(license) then
        return deferrals.done(Lang:t('error.duplicate_license'))
    end

    Wait(0)
    deferrals.update(string.format(Lang:t('info.checking_ban'), name))

    if not bansTableExists then
        return deferrals.done(Lang:t('error.ban_table_not_found'))
    end

    local success, isBanned, reason = pcall(QBCore.Functions.IsPlayerBanned, src)
    if not success then return deferrals.done(Lang:t('error.connecting_database_error')) end
    if isBanned then return deferrals.done(reason) end

    Wait(0)
    deferrals.update(string.format(Lang:t('info.join_server'), name))
    deferrals.done()

    TriggerClientEvent('QBCore:Client:SharedUpdate', src, QBCore.Shared)
end

AddEventHandler('playerConnecting', onPlayerConnecting)

-- Open & Close Server (prevents players from joining)

RegisterNetEvent('QBCore:Server:CloseServer', function(reason)
    local src = source
    if QBCore.Functions.HasPermission(src, 'admin') then
        reason = reason or 'No reason specified'
        QBCore.Config.Server.Closed = true
        QBCore.Config.Server.ClosedReason = reason
        for k in pairs(QBCore.Players) do
            if not QBCore.Functions.HasPermission(k, QBCore.Config.Server.WhitelistPermission) then
                QBCore.Functions.Kick(k, reason, nil, nil)
            end
        end
    else
        QBCore.Functions.Kick(src, Lang:t('error.no_permission'), nil, nil)
    end
end)

RegisterNetEvent('QBCore:Server:OpenServer', function()
    local src = source
    if QBCore.Functions.HasPermission(src, 'admin') then
        QBCore.Config.Server.Closed = false
    else
        QBCore.Functions.Kick(src, Lang:t('error.no_permission'), nil, nil)
    end
end)

-- Callback Events --

-- Client Callback
RegisterNetEvent('QBCore:Server:TriggerClientCallback', function(name, ...)
    if type(name) ~= 'string' then return end
    -- only the player the callback was sent to can answer it (see QBCore.ClientCallbackKey)
    local key = QBCore.ClientCallbackKey(source, name)
    local ClientCallback = QBCore.ClientCallbacks[key]
    if ClientCallback then
        QBCore.ClientCallbacks[key] = nil
        ClientCallback.promise:resolve(...)

        if ClientCallback.callback then
            ClientCallback.callback(...)
        end
    end
end)

-- Server Callback
RegisterNetEvent('QBCore:Server:TriggerCallback', function(name, ...)
    if not QBCore.ServerCallbacks[name] then return end

    local src = source

    QBCore.ServerCallbacks[name](src, function(...)
        TriggerClientEvent('QBCore:Client:TriggerCallback', src, name, ...)
    end, ...)
end)

-- Player

local updateCooldowns = {}
RegisterNetEvent('QBCore:UpdatePlayer', function()
    local src = source
    local now = GetGameTimer()
    if updateCooldowns[src] and (now - updateCooldowns[src]) < 10000 then return end
    updateCooldowns[src] = now
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local newHunger = Player.PlayerData.metadata['hunger'] - QBCore.Config.Player.HungerRate
    local newThirst = Player.PlayerData.metadata['thirst'] - QBCore.Config.Player.ThirstRate
    if newHunger <= 0 then
        newHunger = 0
    end
    if newThirst <= 0 then
        newThirst = 0
    end
    Player.PlayerData.metadata['hunger'] = newHunger
    Player.PlayerData.metadata['thirst'] = newThirst
    Player.Functions.UpdateClient('metadata', Player.PlayerData.metadata)
    TriggerClientEvent('hud:client:UpdateNeeds', src, newHunger, newThirst)
    Player.Functions.Save()
end)

-- Duty points. Going on duty through QBCore:ToggleDuty needs the player's server position at a
-- duty point a resource registered for their job (by name) or job type, e.g. pfm-policejob for
-- every 'leo' job. Going off duty works anywhere. A job no resource registered points for cannot
-- clock in through this event (it keeps its defaultDuty, or a duty handler of its own on the
-- server, as pfm-newsjob has). Any client could fire the event from anywhere, which put an AFK
-- officer at home on duty: paid, counted as an available cop, given on-duty access.
local DUTY_SLACK = 2.0              -- metres on top of a point's radius (position sync lag)
local DUTY_COOLDOWN_MS = 3000       -- between two duty toggles of one player
local DUTY_MAX_POINTS = 64

local function dutyVector(p)
    if type(p) ~= 'table' and type(p) ~= 'vector3' and type(p) ~= 'vector4' then return nil end
    local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z)
    if not x or not y or not z or x ~= x or y ~= y or z ~= z then return nil end
    if math.abs(x) > 1e5 or math.abs(y) > 1e5 or math.abs(z) > 1e5 then return nil end
    return vector3(x, y, z)
end

local function dutyName(v)
    return type(v) == 'string' and v ~= '' and #v <= 50 and v or nil
end

--- Registers the duty points of the calling resource for one job (spec.job, a job name) or one job
--- type (spec.type, e.g. 'leo' or 'ems'): spec = { job | type, points = { vector3, ... }, radius = 3.0 }.
--- A second call for the same job or type replaces it. The points go when the resource stops.
--- @return boolean ok, string|number count or error
local function RegisterDutyPoints(spec)
    local resource = GetInvokingResource() or GetCurrentResourceName()
    if type(spec) ~= 'table' then return false, 'bad_request' end
    local job, jobType = dutyName(spec.job), dutyName(spec.type)
    if (job == nil) == (jobType == nil) then return false, 'job_or_type' end
    if type(spec.points) ~= 'table' then return false, 'no_points' end
    local points = {}
    for _, p in ipairs(spec.points) do
        local v = dutyVector(p)
        if not v then return false, 'bad_point' end
        points[#points + 1] = v
        if #points > DUTY_MAX_POINTS then return false, 'too_many_points' end
    end
    if #points == 0 then return false, 'no_points' end
    local radius = tonumber(spec.radius) or 3.0
    if radius ~= radius or radius < 0.5 then radius = 0.5 elseif radius > 25.0 then radius = 25.0 end
    DutyPoints[resource] = DutyPoints[resource] or {}
    DutyPoints[resource][job and ('job:' .. job) or ('type:' .. jobType)] = { job = job, type = jobType, points = points, radius = radius }
    return true, #points
end
exports('RegisterDutyPoints', RegisterDutyPoints)

--- Removes the calling resource's duty points (all of them, or those of one job or type).
exports('ClearDutyPoints', function(spec)
    local resource = GetInvokingResource() or GetCurrentResourceName()
    if type(spec) ~= 'table' then DutyPoints[resource] = nil return true end
    local own = DutyPoints[resource]
    if not own then return true end
    if dutyName(spec.job) then own['job:' .. spec.job] = nil end
    if dutyName(spec.type) then own['type:' .. spec.type] = nil end
    return true
end)

--- Whether the player stands at a duty point registered for their job; the second value is
--- whether their job has any point at all.
local function AtDutyPoint(src, job)
    if type(job) ~= 'table' then return false, false end
    local pos = GetEntityCoords(GetPlayerPed(src))
    local any = false
    for _, sets in pairs(DutyPoints) do
        for _, set in pairs(sets) do
            if (set.job and set.job == job.name) or (set.type and set.type == job.type) then
                any = true
                for _, p in ipairs(set.points) do
                    if #(pos - p) <= set.radius + DUTY_SLACK then return true, true end
                end
            end
        end
    end
    return false, any
end
exports('IsAtDutyPoint', function(src)
    local Player = QBCore.Functions.GetPlayer(tonumber(src))
    if not Player then return false end
    return (AtDutyPoint(Player.PlayerData.source, Player.PlayerData.job))
end)

RegisterNetEvent('QBCore:ToggleDuty', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local now = GetGameTimer()
    if lastDutyToggle[src] and now - lastDutyToggle[src] < DUTY_COOLDOWN_MS then return end
    lastDutyToggle[src] = now
    if Player.PlayerData.job.onduty then
        Player.Functions.SetJobDuty(false)
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.off_duty'))
    else
        local here, hasPoints = AtDutyPoint(src, Player.PlayerData.job)
        if not here then
            TriggerClientEvent('QBCore:Notify', src, hasPoints and 'Go to a duty point of your job to clock in' or 'Your job cannot clock in here', 'error')
            -- a client that flipped its own duty flag before asking is put back
            TriggerClientEvent('QBCore:Client:SetDuty', src, false)
            return
        end
        Player.Functions.SetJobDuty(true)
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.on_duty'))
    end

    TriggerEvent('QBCore:Server:SetDuty', src, Player.PlayerData.job.onduty)
    TriggerClientEvent('QBCore:Client:SetDuty', src, Player.PlayerData.job.onduty)
end)

RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    local src = source
    if not QBCore.Players[src] then return end
    TriggerClientEvent('QBCore:Client:OnPlayerLoaded', src)
end)

-- Central server-side data change handler — re-fires legacy events for backward compat
AddEventHandler('QBCore:Server:OnPlayerUpdated', function(src, key, val)
    if key == 'job' then
        TriggerEvent('QBCore:Server:OnJobUpdate', src, val)
    elseif key == 'gang' then
        TriggerEvent('QBCore:Server:OnGangUpdate', src, val)
    elseif key == 'all' then
        TriggerEvent('QBCore:Server:OnJobUpdate', src, val.job)
        TriggerEvent('QBCore:Server:OnGangUpdate', src, val.gang)
    end
end)

-- BaseEvents

-- Vehicles
RegisterServerEvent('baseevents:enteringVehicle', function(veh, seat, modelName)
    local src = source
    local data = {
        vehicle = veh,
        seat = seat,
        name = modelName,
        event = 'Entering'
    }
    TriggerClientEvent('QBCore:Client:VehicleInfo', src, data)
end)

RegisterServerEvent('baseevents:enteredVehicle', function(veh, seat, modelName)
    local src = source
    local data = {
        vehicle = veh,
        seat = seat,
        name = modelName,
        event = 'Entered'
    }
    TriggerClientEvent('QBCore:Client:VehicleInfo', src, data)
end)

RegisterServerEvent('baseevents:enteringAborted', function()
    local src = source
    TriggerClientEvent('QBCore:Client:AbortVehicleEntering', src)
end)

RegisterServerEvent('baseevents:leftVehicle', function(veh, seat, modelName)
    local src = source
    local data = {
        vehicle = veh,
        seat = seat,
        name = modelName,
        event = 'Left'
    }
    TriggerClientEvent('QBCore:Client:VehicleInfo', src, data)
end)

-- Non-Chat Command Calling (ex: qb-adminmenu)

RegisterNetEvent('QBCore:CallCommand', function(command, args)
    local src = source
    if type(command) ~= 'string' or not QBCore.Commands.List[command] then return end
    if type(args) ~= 'table' then args = {} end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local hasPerm = QBCore.Functions.HasPermission(src, 'command.' .. QBCore.Commands.List[command].name)
    if hasPerm then
        if QBCore.Commands.List[command].argsrequired and #QBCore.Commands.List[command].arguments ~= 0 and not args[#QBCore.Commands.List[command].arguments] then
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.missing_args2'), 'error')
        else
            QBCore.Commands.List[command].callback(src, args)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_access'), 'error')
    end
end)

-- Use this for player vehicle spawning
-- Vehicle server-side spawning callback (netId)
-- use the netid on the client with the NetworkGetEntityFromNetworkId native
-- convert it to a vehicle via the NetToVeh native
QBCore.Functions.CreateCallback('QBCore:Server:SpawnVehicle', function(source, cb, model, coords, warp)
    -- only models the player's job or a server-granted ticket allows, near the player (vehicle_spawns.lua)
    local ok, why = PFVehicleSpawns.Authorize(source, model, coords)
    if not ok then
        print(('[pfm-core] vehicle spawn refused for %s (%s): %s'):format(source, tostring(model), why))
        cb(nil)
        return
    end
    local veh = QBCore.Functions.SpawnVehicle(source, model, coords, warp)
    cb(DoesEntityExist(veh) and NetworkGetNetworkIdFromEntity(veh) or nil)
end)

-- Use this for long distance vehicle spawning
-- vehicle server-side spawning callback (netId)
-- use the netid on the client with the NetworkGetEntityFromNetworkId native
-- convert it to a vehicle via the NetToVeh native
QBCore.Functions.CreateCallback('QBCore:Server:CreateVehicle', function(source, cb, model, coords, warp)
    local ok, why = PFVehicleSpawns.Authorize(source, model, coords)
    if not ok then
        print(('[pfm-core] vehicle spawn refused for %s (%s): %s'):format(source, tostring(model), why))
        cb(nil)
        return
    end
    local veh = QBCore.Functions.CreateAutomobile(source, model, coords, warp)
    cb(DoesEntityExist(veh) and NetworkGetNetworkIdFromEntity(veh) or nil)
end)

--QBCore.Functions.CreateCallback('QBCore:HasItem', function(source, cb, items, amount)
-- https://github.com/qbcore-framework/qb-inventory/blob/e4ef156d93dd1727234d388c3f25110c350b3bcf/server/main.lua#L2066
--end)
