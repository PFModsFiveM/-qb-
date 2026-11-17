-- The stretcher moved to pf-ambulancejob (batch 17D: pf-ambulancejob:server:Equipment). What is left
-- here are the legacy server events, kept so old clients do not error.

-- Legacy: clears an old client-side stretcher around the sender (the server position, never one the
-- client sends). Current clients no longer create such stretchers, so this only reaches old ones.
local lastRemove = {}
RegisterNetEvent('qb-radialmenu:server:RemoveStretcher', function()
    local src = source
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local t = os.time()
    if lastRemove[src] and t - lastRemove[src] < 2 then return end
    lastRemove[src] = t
    TriggerClientEvent('qb-radialmenu:client:RemoveStretcherFromArea', -1, GetEntityCoords(ped), 0)
end)

AddEventHandler('playerDropped', function() lastRemove[source] = nil end)

-- Legacy busy checks between two clients: accepted and dropped (the server now knows who lies on and
-- who pushes every stretcher).
RegisterNetEvent('qb-radialmenu:Stretcher:BusyCheck', function() end)
RegisterNetEvent('qb-radialmenu:server:BusyResult', function() end)
