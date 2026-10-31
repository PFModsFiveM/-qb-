local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local GotItems = {}
local AlarmActivated = false

local JailResourceAllowlist = Config.JailResourceAllowlist or {
    ['pfm-policejob'] = true,
    ['pfm-adminmenu'] = true,
}
local MaxJailTime = Config.MaxJailTime or 1440
local JailMoneyPaid = {}   -- [citizenid] = true once the jail money was paid for the current sentence
local CheckChanceAt = {}   -- [src] = os.time() of the last phone search
local LastBreakAt = 0      -- os.time() of the last escape or lockdown by an inmate

-- City events (pf-services). A confirmed escape (the inmate's sentence dropped to 0 while the server
-- sees them far outside the walls) is reported once: news bulletin + police dispatch request
-- (crime.prison.escape has police = true) at the spot the inmate was seen, with their public name.
local function CityEvent(kind, data, opts)
    if GetResourceState('pf-services') ~= 'started' then return nil end
    local svc = exports['pf-services']
    if not svc then return nil end
    local ok, id = pcall(function() return svc:Emit(kind, data, opts) end)
    return ok and id or nil
end

local function ReportEscape(Player, coords)
    local ci = Player.PlayerData.charinfo or {}
    local name = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then name = 'An inmate' end
    local cid = Player.PlayerData.citizenid
    CityEvent('crime.prison.escape', { name = name, count = 1, location = 'Bolingbroke Penitentiary', place = 'Bolingbroke Penitentiary', ref = 'escape:' .. tostring(cid),
        details = name .. ' escaped from Bolingbroke Penitentiary' }, {
        title = name .. ' escaped from Bolingbroke Penitentiary', coords = vector3(coords.x, coords.y, coords.z),
        actor = cid, dedupe = cid,
    })
end

RegisterNetEvent('prison:server:SetJailStatus', function(jailTime)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    jailTime = tonumber(jailTime)
    if not jailTime or jailTime ~= jailTime or jailTime == math.huge then return end
    jailTime = math.floor(jailTime)
    if jailTime < 0 then jailTime = 0 end
    if jailTime > MaxJailTime then jailTime = MaxJailTime end

    local invoker = GetInvokingResource()
    local allowed = invoker ~= nil and JailResourceAllowlist[invoker] == true
    local current = Player.PlayerData.metadata['injail'] or 0

    if not allowed then
        -- clients may only count their own sentence down, never raise it
        if jailTime > current then jailTime = current end
        -- an early jump to 0 from the client is only valid as an escape (far outside the prison);
        -- legitimate releases (unjail/time served) have injail set to <= 1 server-side first
        if jailTime == 0 and current > 1 then
            local coords = GetEntityCoords(GetPlayerPed(src))
            local middle = vec2(Config.Locations['middle'].x, Config.Locations['middle'].y)
            if #(coords.xy - middle) <= 195.0 then return end
            -- an escapee forfeits the stored items (the client could ask for them back afterwards)
            Player.SetMetaData('jailitems', {})
            LastBreakAt = os.time()
            ReportEscape(Player, coords)
        end
    end

    Player.SetMetaData('injail', jailTime)
    if jailTime > 0 then
        if Player.PlayerData.job.name ~= 'unemployed' then
            Player.SetJob('unemployed')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.lost_job'))
        end
    else
        GotItems[src] = nil
        JailMoneyPaid[Player.PlayerData.citizenid] = nil
    end
end)

RegisterNetEvent('prison:server:SaveJailItems', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if (Player.PlayerData.metadata.injail or 0) <= 0 then return end
    if not Player.PlayerData.metadata['jailitems'] or table.type(Player.PlayerData.metadata['jailitems']) == 'empty' then
        Player.SetMetaData('jailitems', Player.PlayerData.items)
        -- through the bank ledger, once per jailing (with an empty inventory the jailitems check
        -- above passes every time, so the payment is tracked on its own)
        if JailMoneyPaid[Player.PlayerData.citizenid] then return end
        JailMoneyPaid[Player.PlayerData.citizenid] = true
        PFPayout.Pay(Player, 'cash', 80, { key = ('pfm-prison:jailmoney:%s:%s'):format(Player.PlayerData.citizenid, PFPayout.NewId()), reason = 'jail money', quiet = true })
        Wait(2000)
        Player.ClearInventory()
    end
end)

RegisterNetEvent('prison:server:GiveJailItems', function(escaped)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    -- items only come back once actually released, and only if some were stored
    if (Player.PlayerData.metadata.injail or 0) > 0 then return end
    local jailItems = Player.PlayerData.metadata['jailitems']
    if not jailItems or table.type(jailItems) == 'empty' then return end
    if escaped then
        Player.SetMetaData('jailitems', {})
        return
    end
    for _, v in pairs(jailItems) do
        exports['pfm-inventory']:AddItem(src, v.name, v.amount, false, v.info, 'prison:server:GiveJailItems')
    end
    Player.SetMetaData('jailitems', {})
end)

RegisterNetEvent('prison:server:ResetJailItems', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    Player.SetMetaData('jailitems', {})
end)

RegisterNetEvent('prison:server:SecurityLockdown', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or (Player.PlayerData.metadata['injail'] or 0) <= 0 then return end
    LastBreakAt = os.time()
    TriggerClientEvent('prison:client:SetLockDown', -1, true)
    for _, v in pairs(QBCore.Functions.GetPlayers()) do
        local Player = exports['pfm-core']:GetPlayer(v)
        if Player then
            if Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty then
                TriggerClientEvent('prison:client:PrisonBreakAlert', v)
            end
        end
    end
end)

RegisterNetEvent('prison:server:SetGateHit', function(key)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or (Player.PlayerData.metadata['injail'] or 0) <= 0 then return end
    if type(key) ~= 'string' and type(key) ~= 'number' then return end
    LastBreakAt = os.time()
    TriggerClientEvent('prison:client:SetGateHit', -1, key, true)
    if math.random(1, 100) <= 50 then
        for _, v in pairs(QBCore.Functions.GetPlayers()) do
            local Player = exports['pfm-core']:GetPlayer(v)
            if Player then
                if Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty then
                    TriggerClientEvent('prison:client:PrisonBreakAlert', v)
                end
            end
        end
    end
end)

RegisterNetEvent('prison:server:CheckRecordStatus', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local CriminalRecord = Player.PlayerData.metadata['criminalrecord']
    local currentDate = os.date('*t')
    if type(CriminalRecord) ~= 'table' or type(CriminalRecord['date']) ~= 'table' or not CriminalRecord['date'].month then return end

    if (CriminalRecord['date'].month + 1) == 13 then
        CriminalRecord['date'].month = 0
    end

    if CriminalRecord['hasRecord'] then
        if currentDate.month == (CriminalRecord['date'].month + 1) or currentDate.day == (CriminalRecord['date'].day - 1) then
            CriminalRecord['hasRecord'] = false
            CriminalRecord['date'] = nil
        end
    end
end)

RegisterNetEvent('prison:server:JailAlarm', function()
    if AlarmActivated then return end
    -- only after a real escape or lockdown (any client far from the prison could ring it server-wide)
    if os.time() - LastBreakAt > 600 then return end
    local playerPed = GetPlayerPed(source)
    local coords = GetEntityCoords(playerPed)
    local middle = vec2(Config.Locations['middle'].x, Config.Locations['middle'].y)
    if #(coords.xy - middle) < 200 then return error('"prison:server:JailAlarm" triggered whilst the player was too close to the prison, cancelled event') end
    AlarmActivated = true
    TriggerClientEvent('prison:client:JailAlarm', -1, true)
    SetTimeout(5 * 60000, function()
        AlarmActivated = false
        TriggerClientEvent('prison:client:JailAlarm', -1, false)
    end)
end)

RegisterNetEvent('prison:server:CheckChance', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or (Player.PlayerData.metadata.injail or 0) <= 0 or GotItems[src] then return end
    -- one search per finished prison job at most (spamming the event made the phone a sure thing)
    local now = os.time()
    if CheckChanceAt[src] and now - CheckChanceAt[src] < 10 then return end
    CheckChanceAt[src] = now
    local chance = math.random(100)
    local odd = math.random(100)
    if chance ~= odd then return end
    if not exports['pfm-inventory']:AddItem(src, 'phone', 1, false, false, 'prison:server:CheckChance') then return end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['phone'], 'add')
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.found_phone'), 'success')
    GotItems[src] = true
end)

AddEventHandler('playerDropped', function()
    CheckChanceAt[source] = nil
end)

QBCore.Functions.CreateCallback('prison:server:IsAlarmActive', function(_, cb)
    cb(AlarmActivated)
end)
