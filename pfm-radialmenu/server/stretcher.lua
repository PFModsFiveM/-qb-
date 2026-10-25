-- The stretcher is cleared around the sender, wherever the client says it is (any stretcher on the map
-- could be cleared before).
RegisterNetEvent('qb-radialmenu:server:RemoveStretcher', function(pos, stretcherObject)
    local src = source
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    TriggerClientEvent('qb-radialmenu:client:RemoveStretcherFromArea', -1, GetEntityCoords(ped), stretcherObject)
end)

RegisterNetEvent('qb-radialmenu:Stretcher:BusyCheck', function(target, type)
    local src = source
    if not IsCloseToTarget(src, target) then return end
    TriggerClientEvent('qb-radialmenu:Stretcher:client:BusyCheck', target, source, type)
end)

RegisterNetEvent('qb-radialmenu:server:BusyResult', function(isBusy, target, type)
    local src = source
    if not IsCloseToTarget(src, target) then return end
    TriggerClientEvent('qb-radialmenu:client:Result', target, isBusy, type)
end)
