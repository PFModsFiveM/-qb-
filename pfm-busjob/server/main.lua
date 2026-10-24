local LastNpcPay = {}
local Sessions = {}

local function applyStreakBonus(streak, amount)
    local sb = Config.StreakBonus
    if not sb or not sb.enabled or streak <= 0 then return amount end
    local mult = math.min(streak * (sb.perDelivery or 0.02), sb.cap or 0.25)
    return math.floor(amount * (1.0 + mult) + 0.5)
end

-- The bus stop the player is at (index and position), or nil.
function NearBus(src)
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    for i, v in pairs(Config.NPCLocations.Locations) do
        local pos = vector3(v.x, v.y, v.z)
        if #(coords - pos) < 20 then
            return i, pos
        end
    end
end

-- Each payment must come from a different stop than the last paid one, a real drive away.
-- (Pay used to need only standing at any stop, so a parked bus was paid every 10 seconds.)
local MIN_STOP_DISTANCE = 100.0
local MAX_BUS_SPEED = 40.0 -- m/s

-- Job session: started when a bus is taken out at the depot, cleared when it is returned or the player drops
RegisterNetEvent('qb-busjob:server:StartShift', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or Player.PlayerData.job.name ~= 'bus' then return end
    local coords = GetEntityCoords(GetPlayerPed(src))
    if #(coords - vector3(Config.Location.x, Config.Location.y, Config.Location.z)) > 30.0 then return end
    Sessions[src] = { startedAt = os.time(), streak = 0 }
end)

RegisterNetEvent('qb-busjob:server:EndShift', function()
    Sessions[source] = nil
end)

RegisterNetEvent('qb-busjob:server:NpcPay', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local now = os.time()
    local cooldownSeconds = Config.NpcPayCooldown or 10
    local Payment = math.random(5, 30)
    if not Player then return end
    if Player.PlayerData.job.name == 'bus' then
        if not Sessions[src] then
            DropPlayer(src, Lang:t('error.exploit'))
            return
        end
        if LastNpcPay[src] and (now - LastNpcPay[src]) < cooldownSeconds then
            DropPlayer(src, Lang:t('error.exploit'))
            return
        end
        local stopIndex, stopPos = NearBus(src)
        if stopIndex then
            local last = Sessions[src].lastStop
            if last then
                local drive = #(stopPos - last.pos)
                if stopIndex == last.index or drive < MIN_STOP_DISTANCE or now - last.at < drive / MAX_BUS_SPEED then
                    return
                end
            end
            Sessions[src].lastStop = { index = stopIndex, pos = stopPos, at = now }
            local randomAmount = math.random(1, 5)
            local r1, r2 = math.random(1, 5), math.random(1, 5)
            if randomAmount == r1 or randomAmount == r2 then Payment = Payment + math.random(20, 40) end
            Payment = applyStreakBonus(Sessions[src].streak, Payment)
            Sessions[src].streak = Sessions[src].streak + 1
            LastNpcPay[src] = now
            Player.AddMoney('cash', Payment, 'Bus job')
        else
            DropPlayer(src, Lang:t('error.exploit'))
        end
    else
        DropPlayer(src, Lang:t('error.exploit'))
    end
end)

AddEventHandler('playerDropped', function()
    LastNpcPay[source] = nil
    Sessions[source] = nil
end)
