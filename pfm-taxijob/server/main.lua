local sharedItems = exports['pfm-core']:GetShared('Items')
local Sessions = {}
local LastNpcPay = {}

local function applyStreakBonus(streak, amount)
    local sb = Config.StreakBonus
    if not sb or not sb.enabled or streak <= 0 then return amount end
    local mult = math.min(streak * (sb.perDelivery or 0.02), sb.cap or 0.25)
    return math.floor(amount * (1.0 + mult) + 0.5)
end

-- The drop-off point the player is at, or nil.
function NearTaxi(src)
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    for _, v in pairs(Config.NPCLocations.DeliverLocations) do
        local dist = #(coords - vector3(v.x, v.y, v.z))
        if dist < 20 then
            return v
        end
    end
end

-- A fare starts when the server sees the passenger picked up at a pickup point and ends with one
-- payment at a drop-off point a real drive away. (Payment used to need only standing near any
-- drop-off point, so a parked cab earned a fare every 30 seconds.)
local PICKUP_RANGE = 15.0
local MIN_FARE_DISTANCE = 150.0
local MAX_FARE_SPEED = 45.0 -- m/s

RegisterNetEvent('qb-taxi:server:PickupNpc', function(npcIndex)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or Player.PlayerData.job.name ~= Config.jobRequired or not Sessions[src] then return end
    local pickup = Config.NPCLocations.TakeLocations[tonumber(npcIndex) or 0]
    if not pickup then return end
    local coords = GetEntityCoords(GetPlayerPed(src))
    if #(coords - vector3(pickup.x, pickup.y, pickup.z)) > PICKUP_RANGE then return end
    Sessions[src].fares = Sessions[src].fares + 1
    Sessions[src].fare = { n = Sessions[src].fares, from = vector3(pickup.x, pickup.y, pickup.z), at = os.time() }
end)

-- Job session: started when a cab is taken out at the depot, cleared when it is parked or the player drops
RegisterNetEvent('qb-taxi:server:StartShift', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or Player.PlayerData.job.name ~= Config.jobRequired then return end
    local coords = GetEntityCoords(GetPlayerPed(src))
    if #(coords - Config.Location) > 60.0 then return end
    Sessions[src] = { id = PFPayout.NewId(), startedAt = os.time(), streak = 0, fares = 0 }
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
        local dropoff = NearTaxi(src)
        local fare = Sessions[src].fare
        if dropoff and not fare then
            return -- no passenger on board: nothing to pay (an honest client can get here after a restart)
        end
        if dropoff then
            local drive = #(vector3(dropoff.x, dropoff.y, dropoff.z) - fare.from)
            if drive < MIN_FARE_DISTANCE or now - fare.at < drive / MAX_FARE_SPEED then return end
            Sessions[src].fare = nil -- one payment per passenger
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

            -- paid through the bank ledger; the key is this shift's fare number, so it pays once
            local key = ('pfm-taxijob:%s:fare:%d'):format(Sessions[src].id, fare.n)
            local paid
            if Config.Management then
                paid = PFPayout.PaySociety('taxi', payment, { key = key, reason = 'Customer payment' })
            else
                paid = PFPayout.Pay(Player, 'cash', payment, { key = key, reason = 'Taxi payout' })
            end
            if not paid then Sessions[src].fare = fare return end -- keep the fare: a retry uses the same key
            Sessions[src].streak = Sessions[src].streak + 1

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

-- Vehicles this job may spawn through pfm-core (QBCore:Server:SpawnVehicle only spawns registered
-- job vehicles or vehicles the server granted a ticket for)
CreateThread(function()
    local models = {}
    for _, v in pairs(Config.AllowedVehicles or {}) do models[#models + 1] = v.model end
    pcall(function() exports['pfm-core']:RegisterJobVehicles(Config.jobRequired or 'taxi', models) end)
end)
