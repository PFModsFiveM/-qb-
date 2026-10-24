local sharedItems = exports['pfm-core']:GetShared('Items')
local Sessions = {}
local LastNpcPay = {}

local function applyStreakBonus(streak, amount)
    local sb = Config.StreakBonus
    if not sb or not sb.enabled or streak <= 0 then return amount end
    local mult = math.min(streak * (sb.perDelivery or 0.02), sb.cap or 0.25)
    return math.floor(amount * (1.0 + mult) + 0.5)
end

function NearTaxi(src)
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    for _, v in pairs(Config.NPCLocations.DeliverLocations) do
        local dist = #(coords - vector3(v.x, v.y, v.z))
        if dist < 20 then
            return true
        end
    end
end

-- Job session: started when a cab is taken out at the depot, cleared when it is parked or the player drops
RegisterNetEvent('qb-taxi:server:StartShift', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or Player.PlayerData.job.name ~= Config.jobRequired then return end
    local coords = GetEntityCoords(GetPlayerPed(src))
    if #(coords - Config.Location) > 60.0 then return end
    Sessions[src] = { startedAt = os.time(), streak = 0 }
end)

RegisterNetEvent('qb-taxi:server:EndShift', function()
    Sessions[source] = nil
end)

AddEventHandler('playerDropped', function()
    Sessions[source] = nil
    LastNpcPay[source] = nil
end)

RegisterNetEvent('qb-taxi:server:NpcPay', function(_, hasReceivedBonus)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.name == Config.jobRequired then
        if not Sessions[src] then
            DropPlayer(src, 'Attempting To Exploit')
            return
        end
        local now = os.time()
        if LastNpcPay[src] and (now - LastNpcPay[src]) < (Config.NpcPayCooldown or 30) then
            DropPlayer(src, 'Attempting To Exploit')
            return
        end
        if NearTaxi(src) then
            LastNpcPay[src] = now
            local payment = math.random(65, 105)
            local randomAmount = math.random(1, 5)
            local r1, r2 = math.random(1, 5), math.random(1, 5)
            if randomAmount == r1 or randomAmount == r2 then payment = payment + math.random(10, 20) end

            if Config.Advanced.Bonus.Enabled then
                local tipAmount = math.floor(payment * Config.Advanced.Bonus.Percentage / 100)

                payment += tipAmount
                if hasReceivedBonus then
                    TriggerClientEvent('QBCore:Notify', src, string.format(Lang:t('info.tip_received'), tipAmount), 'primary', 5000)
                else
                    TriggerClientEvent('QBCore:Notify', src, Lang:t('info.tip_not_received'), 'primary', 5000)
                end
            end

            payment = applyStreakBonus(Sessions[src].streak, payment)
            Sessions[src].streak = Sessions[src].streak + 1

            if Config.Management then
                exports['pfm-banking']:AddMoney('taxi', payment, 'Customer payment')
            else
                Player.AddMoney('cash', payment, 'Taxi payout')
            end

            local chance = math.random(1, 100)
            if chance < 26 then
                exports['pfm-inventory']:AddItem(src, Config.Rewards, 1, false, false, 'qb-taxi:server:NpcPay')
                TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[Config.Rewards], 'add')
            end
        else
            DropPlayer(src, 'Attempting To Exploit')
        end
    else
        DropPlayer(src, 'Attempting To Exploit')
    end
end)
