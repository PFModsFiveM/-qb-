-- The static security cameras of Config.SecurityCameras (/cam <id>) are retired: police CCTV lives
-- on the police MDT CCTV page (pf-policemdt-DEV), which shows camera locations and states that no
-- recording exists. One camera system, not two. The events stay so old callers (the /cam command,
-- pfm-bankrobbery's camera on/off) do nothing harmful.

RegisterNetEvent('police:client:ActiveCamera', function()
    local text = (Config.Equipment and Config.Equipment.Text and Config.Equipment.Text.cam_retired) or 'Static cameras moved to the MDT CCTV page'
    QBCore.Functions.Notify(text, 'primary')
end)

RegisterNetEvent('police:client:DisableAllCameras', function() end)
RegisterNetEvent('police:client:EnableAllCameras', function() end)
RegisterNetEvent('police:client:SetCamera', function() end)
