-- Traffic tools for officers (batch 18B). The client only picks what the officer means: the vehicle
-- in the radar beam, the person next to them, the violation, the incident kind and text. The server
-- (server/traffic.lua) reads every speed, plate and position itself and checks every request.

local lastReading -- the last radar reading with a speed event (its id can be cited)

local function Notify(msg, kind) QBCore.Functions.Notify(msg, kind or 'primary', 6000) end

local function IsOnDutyLeo()
    local job = PlayerJob or {}
    return ((Config.Traffic or {}).LeoJobTypes or { leo = true })[job.type] == true and job.onduty == true
end

-- GTA heading of the vector (dx, dy): 0 = north, counter-clockwise (the server uses the same).
local function Bearing(dx, dy) return math.deg(math.atan(-dx, dy)) % 360 end
local function AngleDiff(a, b)
    local d = math.abs((a - b) % 360)
    return d > 180 and 360 - d or d
end

-- The networked vehicle nearest to the beam: in range and inside the cone of the car's heading (and
-- behind it with the rear antenna), or of the officer's heading on foot.
local function VehicleInBeam()
    local cfg = (Config.Traffic or {}).Radar or {}
    local ped = PlayerPedId()
    local own = GetVehiclePedIsIn(ped, false)
    local origin = own ~= 0 and GetEntityCoords(own) or GetEntityCoords(ped)
    local heading = own ~= 0 and GetEntityHeading(own) or GetEntityHeading(ped)
    local half = (cfg.ConeDegrees or 12.0) / 2
    local range = cfg.Range or 150.0
    local best, bestDist
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if veh ~= own and NetworkGetEntityIsNetworked(veh) then
            local pos = GetEntityCoords(veh)
            local dist = #(pos - origin)
            if dist <= range then
                local b = Bearing(pos.x - origin.x, pos.y - origin.y)
                local inCone = AngleDiff(b, heading) <= half
                if not inCone and own ~= 0 and cfg.RearAntenna then inCone = AngleDiff(b, (heading + 180) % 360) <= half end
                if inCone and (not bestDist or dist < bestDist) then best, bestDist = veh, dist end
            end
        end
    end
    return best
end

local function ClosestPlayer(maxDist)
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player ~= -1 and distance <= maxDist then return GetPlayerServerId(player) end
    return nil
end

RegisterCommand('radar', function()
    if not IsOnDutyLeo() then return Notify('On-duty police only', 'error') end
    local veh = VehicleInBeam()
    if not veh then return Notify('No vehicle in the radar beam', 'error') end
    TriggerServerEvent('police:server:RadarMeasure', VehToNet(veh))
end, false)

RegisterNetEvent('police:client:RadarReading', function(r)
    if type(r) ~= 'table' or not tonumber(r.speed) then return end
    local plate = type(r.plate) == 'string' and r.plate or 'no plate'
    local speed, limit = math.floor(tonumber(r.speed)), math.floor(tonumber(r.limit) or 0)
    if tonumber(r.eventId) then
        lastReading = { id = math.floor(tonumber(r.eventId)), plate = plate, speed = speed, limit = limit }
        Notify(('Radar: %s at %d km/h in a %d zone (reading #%d saved)'):format(plate, speed, limit, lastReading.id), 'error')
    else
        Notify(('Radar: %s at %d km/h (limit %d)'):format(plate, speed, limit), 'success')
    end
end)

RegisterCommand('breath', function()
    if not IsOnDutyLeo() then return Notify('On-duty police only', 'error') end
    local target = ClosestPlayer(((Config.Traffic or {}).Breath or {}).Distance or 2.5)
    if not target then return Notify(Lang:t('error.none_nearby'), 'error') end
    TriggerServerEvent('police:server:Breathalyze', target)
end, false)

RegisterNetEvent('police:client:BreathResult', function() end) -- the server also notifies; kept for UIs

RegisterCommand('cite', function()
    if not IsOnDutyLeo() then return Notify('On-duty police only', 'error') end
    local cfg = (Config.Traffic or {}).Citations or {}
    local target = ClosestPlayer(cfg.Distance or 5.0)
    if not target then return Notify(Lang:t('error.none_nearby'), 'error') end
    local options = {}
    for code, v in pairs(cfg.Violations or {}) do
        local label = v.label or code
        if v.speed then
            if lastReading then
                options[#options + 1] = { value = code, text = ('%s: %s, %d in a %d zone'):format(label, lastReading.plate, lastReading.speed, lastReading.limit) }
            end
        else
            options[#options + 1] = { value = code, text = ('%s ($%d)'):format(label, tonumber(v.amount) or 0) }
        end
    end
    table.sort(options, function(a, b) return a.text < b.text end)
    if #options == 0 then return end
    local dialog = exports['pfm-input']:ShowInput({
        header = 'Traffic citation',
        submitText = 'Issue',
        inputs = { { text = 'Violation', name = 'code', type = 'select', options = options } },
    })
    if not dialog or type(dialog.code) ~= 'string' then return end
    local v = (cfg.Violations or {})[dialog.code]
    TriggerServerEvent('police:server:IssueCitation', target, dialog.code, v and v.speed and lastReading and lastReading.id or nil)
end, false)

RegisterCommand('tincident', function()
    if not IsOnDutyLeo() then return Notify('On-duty police only', 'error') end
    local cfg = (Config.Traffic or {}).Incidents or {}
    local kinds = {
        { value = 'stop', text = 'Traffic stop' }, { value = 'collision', text = 'Collision' },
        { value = 'pursuit_end', text = 'End of pursuit' }, { value = 'hazard', text = 'Road hazard' },
    }
    local dialog = exports['pfm-input']:ShowInput({
        header = 'Traffic incident',
        submitText = 'Log',
        inputs = {
            { text = 'Kind', name = 'kind', type = 'select', options = kinds },
            { text = 'Summary', name = 'summary', type = 'text', isRequired = true },
            { text = 'MDT incident number (optional)', name = 'mdt', type = 'text', isRequired = false },
        },
    })
    if not dialog then return end
    -- the vehicles and people around the officer; the server keeps only those it sees there too
    local radius = cfg.Radius or 30.0
    local pos = GetEntityCoords(PlayerPedId())
    local plates, people = {}, {}
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if #plates < (cfg.MaxPlates or 6) and #(GetEntityCoords(veh) - pos) <= radius then
            plates[#plates + 1] = QBCore.Functions.GetPlate(veh)
        end
    end
    for _, pl in ipairs(GetActivePlayers()) do
        local p = GetPlayerPed(pl)
        if pl ~= PlayerId() and #people < (cfg.MaxPeople or 8) and #(GetEntityCoords(p) - pos) <= radius then
            people[#people + 1] = GetPlayerServerId(pl)
        end
    end
    TriggerServerEvent('police:server:LogTrafficIncident', {
        kind = dialog.kind, summary = dialog.summary, mdtIncidentId = dialog.mdt ~= '' and dialog.mdt or nil,
        plates = plates, people = people,
    })
end, false)

CreateThread(function()
    TriggerEvent('chat:addSuggestion', '/radar', 'Measure the speed of the vehicle in the radar beam (Police Only)')
    TriggerEvent('chat:addSuggestion', '/breath', 'Breath test the closest person (Police Only)')
    TriggerEvent('chat:addSuggestion', '/cite', 'Issue a traffic citation to the closest person (Police Only)')
    TriggerEvent('chat:addSuggestion', '/tincident', 'Log a traffic incident at your position (Police Only)')
end)
