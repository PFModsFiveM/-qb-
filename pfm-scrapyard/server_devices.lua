-- Scrap List app (pf-devices, tablet + computer, installed from the App Store): the cars the
-- scrapyard is buying right now and where to bring them. The list is the server's own
-- Config.CurrentVehicles (regenerated every hour); scrapping itself stays at the yard.

local sharedVehicles = exports['pfm-core']:GetShared('Vehicles') or {}

local function wantedList()
    local out = {}
    for key, model in pairs(Config.CurrentVehicles or {}) do
        local def = sharedVehicles[model]
        out[#out + 1] = {
            key = key, model = model,
            label = def and ((def.brand and (def.brand .. ' ') or '') .. (def.name or model)) or model,
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

local function register()
    if GetResourceState('pf-devices') ~= 'started' then return end
    exports['pf-devices']:RegisterApp({
        id = 'scraplist', name = 'Scrap List', icon = '🔩',
        entry = 'html/scraplist.js', category = 'jobs', order = 60,
        access = { installable = true },
        store = { description = 'The cars the scrapyard is buying right now and where to bring them.', publisher = 'Sandy Shores Scrap' },
        description = 'Cars the scrapyard wants',
    })
    exports['pf-devices']:RegisterAppHandlers('scraplist', {
        list = function()
            local yards = {}
            for i, loc in ipairs(Config.Locations or {}) do
                if loc.deliver then yards[#yards + 1] = { id = i, label = ('Scrapyard %d'):format(i) } end
            end
            return { ok = true, vehicles = wantedList(), yards = yards }
        end,
        waypoint = function(src, p)
            local loc = Config.Locations and Config.Locations[tonumber(p.id) or 0]
            if not loc or not loc.deliver then return { ok = false, error = 'unknown_yard' } end
            TriggerClientEvent('qb-scrapyard:client:waypoint', src, loc.deliver.coords.x, loc.deliver.coords.y)
            return { ok = true }
        end,
    })
end

-- open Scrap List apps refresh when the list changes (a car was scrapped, or the hourly reset)
AddEventHandler('pfm-scrapyard:server:listChanged', function()
    if GetResourceState('pf-devices') == 'started' then
        pcall(function() exports['pf-devices']:Broadcast('scraplist', 'changed', {}) end)
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() or resource == 'pf-devices' then register() end
end)
AddEventHandler('pf-devices:server:ready', register)
