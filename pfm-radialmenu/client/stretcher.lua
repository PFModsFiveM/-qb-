-- The stretcher moved to pf-ambulancejob (batch 17D: server-spawned props, server-owned patient
-- and loading, state bags). The old client-spawned bin-bag stretcher, its per-frame loops and the
-- start-up thread that deleted bin bags near the player are gone. The legacy radial events stay as
-- forwarders for old menu entries and other scripts that still trigger them.

RegisterNetEvent('qb-radialmenu:client:TakeStretcher', function()
    TriggerEvent('pf-ambulancejob:client:Equipment', { action = 'spawn_stretcher' })
end)

RegisterNetEvent('qb-radialmenu:client:RemoveStretcher', function()
    TriggerEvent('pf-ambulancejob:client:Equipment', { action = 'return' })
end)
