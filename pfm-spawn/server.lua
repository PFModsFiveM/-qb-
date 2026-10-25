local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })

QBCore.Functions.CreateCallback('qb-spawn:server:getOwnedHouses', function(source, cb, cid)
    -- only the caller's own character (any citizenid's houses used to be listed)
    local Player = exports['pfm-core']:GetPlayer(source)
    if cid ~= nil and Player and Player.PlayerData.citizenid == cid then
        local houses = MySQL.query.await('SELECT * FROM player_houses WHERE citizenid = ?', { cid })
        if houses[1] ~= nil then
            cb(houses)
        else
            cb({})
        end
    else
        cb({})
    end
end)
