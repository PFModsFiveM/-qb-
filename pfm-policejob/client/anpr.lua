-- ALPR display. The server reads plates itself (fixed readers and the unit of a police car switched
-- on with /alpr, server/traffic.lua); this client only shows what the server sends. The old loop
-- that asked the server whether this player's own plate was flagged is gone.

local alprOn = false
local hitBlips = {}

local function Notify(msg, kind) QBCore.Functions.Notify(msg, kind or 'primary', 6000) end

local function ClearOldBlips()
    local now = GetGameTimer()
    for i = #hitBlips, 1, -1 do
        if now - hitBlips[i].at > 60000 then
            if DoesBlipExist(hitBlips[i].blip) then RemoveBlip(hitBlips[i].blip) end
            table.remove(hitBlips, i)
        end
    end
end

RegisterNetEvent('police:client:AlprState', function(on)
    alprOn = on == true
    Notify(alprOn and 'ALPR unit on' or 'ALPR unit off', alprOn and 'success' or 'primary')
end)

-- A flagged plate read by this officer's unit: { plate, flags, boloIds, field, speed, coords }
RegisterNetEvent('police:client:AlprHit', function(hit)
    if type(hit) ~= 'table' or type(hit.plate) ~= 'string' then return end
    local flags = {}
    for _, f in ipairs(type(hit.flags) == 'table' and hit.flags or {}) do flags[#flags + 1] = tostring(f) end
    local text = ('ALPR hit %s [%s]'):format(hit.plate, table.concat(flags, ', '))
    if type(hit.field) == 'string' then text = text .. ' - ' .. hit.field end
    if tonumber(hit.speed) then text = text .. (' (%d km/h)'):format(math.floor(tonumber(hit.speed))) end
    Notify(text, 'error')
    PlaySoundFrontend(-1, 'Event_Start_Text', 'GTAO_FM_Events_Soundset', false)
    local c = hit.coords
    if type(c) == 'table' and tonumber(c.x) and tonumber(c.y) then
        ClearOldBlips()
        local blip = AddBlipForCoord(tonumber(c.x) + 0.0, tonumber(c.y) + 0.0, (tonumber(c.z) or 0.0) + 0.0)
        SetBlipSprite(blip, 225)
        SetBlipColour(blip, 1)
        SetBlipScale(blip, 0.9)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName('ALPR ' .. hit.plate)
        EndTextCommandSetBlipName(blip)
        hitBlips[#hitBlips + 1] = { blip = blip, at = GetGameTimer() }
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, b in ipairs(hitBlips) do if DoesBlipExist(b.blip) then RemoveBlip(b.blip) end end
end)
