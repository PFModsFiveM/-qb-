-- pfm-pause server: leaving with a reason, and Swap Character (back to the character screen).

local Cfg = Config.Pause

local lastInfo = {}   -- [src] = os.time() of the last answer (one a second is plenty)
local lastSwap = {}   -- [src] = os.time() of the last swap

--- Players online and the server's time (kept for anything that asks).
RegisterNetEvent('pfm-pause:server:info', function()
    local src = source
    local t = os.time()
    if lastInfo[src] and t - lastInfo[src] < 1 then return end
    lastInfo[src] = t
    TriggerClientEvent('pfm-pause:client:info', src, {
        online = #GetPlayers(),
        max = GetConvarInt and GetConvarInt('sv_maxclients', 48) or 48,
        time = os.date('%H:%M'),
    })
end)

--- Disconnect from the menu (asked and confirmed on the client first). DropPlayer is the server's
--- own clean way out: the player sees the reason, and the framework's playerDropped saves them.
RegisterNetEvent('pfm-pause:server:leave', function()
    local src = source
    if not src or src == 0 or src == '' then return end
    DropPlayer(src, Cfg.DisconnectReason or 'Disconnected.')
end)

local QBCore
local function core()
    if QBCore then return QBCore end
    if GetResourceState('pfm-core') ~= 'started' then return nil end
    local ok, obj = pcall(function() return exports['pfm-core']:GetCoreObject() end)
    if ok and type(obj) == 'table' then QBCore = obj end
    return QBCore
end

--- Why this player may not swap now, or nil. Checked here as well as on the client: a client can send anything.
function PfmPauseSwapRefusal(src, t)
    local S = Cfg.SwapCharacter
    if type(S) ~= 'table' or S.Enabled == false then return 'Swap Character is turned off.' end
    if GetResourceState(S.Resource or 'pfm-multicharacter') ~= 'started' then
        return S.DisabledNote or 'The character screen is not available right now.'
    end
    local cd = tonumber(S.CooldownSec) or 30
    if lastSwap[src] and t - lastSwap[src] < cd then
        return ('Please wait %d s before swapping again.'):format(cd - (t - lastSwap[src]))
    end
    local c = core()
    local player = c and c.Functions and c.Functions.GetPlayer and c.Functions.GetPlayer(src)
    if not player then return 'No character is loaded.' end
    local md = player.PlayerData and player.PlayerData.metadata or {}
    if S.AllowWhileDead ~= true and (md.isdead or md.inlaststand) then return 'Not while you are down.' end
    if S.AllowWhileCuffed ~= true and md.ishandcuffed then return 'Not while you are cuffed.' end
    return nil, player
end

--- Swap Character: the admin /logout's own path (pfm-multicharacter) — the character is saved and unloaded,
--- and the client goes back to the character screen.
RegisterNetEvent('pfm-pause:server:swap', function()
    local src = source
    if not src or src == 0 or src == '' then return end
    local t = os.time()
    local why, player = PfmPauseSwapRefusal(src, t)
    if why then
        TriggerClientEvent('pfm-pause:client:swapRefused', src, why)
        return
    end
    lastSwap[src] = t
    local c = core()
    local ok, err = pcall(function()
        if c.Player and c.Player.Logout then c.Player.Logout(src) else player.Functions.Logout() end
    end)
    if not ok then
        print(('[pfm-pause] swap for %s failed: %s'):format(tostring(src), tostring(err)))
        TriggerClientEvent('pfm-pause:client:swapRefused', src, 'Could not swap right now.')
        return
    end
    TriggerClientEvent('qb-multicharacter:client:chooseChar', src)
end)

AddEventHandler('playerDropped', function()
    lastInfo[source] = nil
    lastSwap[source] = nil
end)
