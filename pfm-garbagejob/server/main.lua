local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local Routes = {}
local SrcToCid = {}

-- Truck deposits held between routes when the driver keeps working: [citizenid] = amount
local HeldDeposits = {}

local function CanPay(Player)
    return Player.PlayerData.money['bank'] >= Config.TruckPrice
end

local function OnGarbageJob(Player)
    return Player and Player.PlayerData.job and Player.PlayerData.job.name == Config.Jobname
end

local function applyStreakBonus(streak, amount)
    local sb = Config.StreakBonus
    if not sb or not sb.enabled or streak <= 0 then return amount end
    local mult = math.min(streak * (sb.perDelivery or 0.02), sb.cap or 0.25)
    return math.floor(amount * (1.0 + mult) + 0.5)
end

-- Pay for the bags at one stop (the streak bonus applies).
local function PayForStop(route, stopNum)
    local bagAmount = math.min(route.stops[stopNum].bags, Config.MaxBagsPerStop)
    local totalNewPay = 0
    for _ = 1, bagAmount do
        totalNewPay = totalNewPay + math.random(Config.BagLowerWorth, Config.BagUpperWorth)
    end
    totalNewPay = applyStreakBonus(route.streak, totalNewPay)
    route.actualPay = math.ceil(route.actualPay + totalNewPay)
    route.stopsCompleted = tonumber(route.stopsCompleted) + 1
    route.streak = route.streak + 1
end

QBCore.Functions.CreateCallback('qb-garbagejob:server:NewShift', function(source, cb, continue)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or not OnGarbageJob(Player) then cb(false, 0, 0, 0) return end
    local CitizenId = Player.PlayerData.citizenid
    local shouldContinue = false
    local nextStop = 0
    local totalNumberOfStops = 0
    local bagNum = 0
    -- "continue" means the driver already has the truck and a deposit held from the last route; the
    -- deposit itself is tracked here (the client's word used to skip it and still get it refunded)
    local held = HeldDeposits[CitizenId]
    HeldDeposits[CitizenId] = nil

    if CanPay(Player) or (continue and held) then
        math.randomseed(os.time())
        local MaxStops = math.random(Config.MinStops, #Config.Locations['trashcan'])
        local allStops = {}

        for _ = 1, MaxStops do
            local stop = math.random(#Config.Locations['trashcan'])
            local newBagAmount = math.random(Config.MinBagsPerStop, Config.MaxBagsPerStop)
            allStops[#allStops + 1] = { stop = stop, bags = newBagAmount }
        end

        Routes[CitizenId] = {
            id = PFPayout.NewId(), -- builds this route's ledger keys
            stops = allStops,
            currentStop = 1,
            started = true,
            currentDistance = 0,
            -- refunded at the end only if it was actually paid (payDeposit) or carried over
            depositPay = (continue and held) or 0,
            actualPay = 0,
            stopsCompleted = 0,
            totalNumberOfStops = #allStops,
            lastStopTime = 0,
            streak = 0
        }
        SrcToCid[source] = CitizenId

        nextStop = allStops[1].stop
        shouldContinue = true
        totalNumberOfStops = #allStops
        bagNum = allStops[1].bags
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.not_enough', { value = Config.TruckPrice }), 'error')
    end
    cb(shouldContinue, nextStop, bagNum, totalNumberOfStops)
end)

-- The client pays the truck deposit once the truck has spawned. It is recorded on the route only when
-- the money was really taken, so only a paid deposit is ever refunded.
RegisterNetEvent('qb-garbagejob:server:payDeposit', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    local route = Routes[Player.PlayerData.citizenid]
    if not route or route.depositPay > 0 then return end
    if not PFPayout.Charge(Player, 'bank', Config.TruckPrice, { key = ('pfm-garbagejob:%s:deposit'):format(route.id), reason = 'garbage-deposit' }) then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.not_enough', { value = Config.TruckPrice }), 'error')
        return
    end
    route.depositPay = Config.TruckPrice
end)

QBCore.Functions.CreateCallback('qb-garbagejob:server:NextStop', function(source, cb, currentStop, currentStopNum, _)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or not OnGarbageJob(Player) then cb(false, 0, 0) return end
    local CitizenId = Player.PlayerData.citizenid
    local route = Routes[CitizenId]
    local newStop = 0
    local shouldContinue = false
    local newBagAmount = 0

    -- Session validation: must have an active route and be on the stop the server expects
    if not route or not route.started then
        cb(false, 0, 0)
        return
    end
    currentStopNum = tonumber(currentStopNum) or 0
    if currentStopNum ~= route.currentStop or not route.stops[currentStopNum] or route.stops[currentStopNum].stop ~= currentStop then
        cb(false, 0, 0)
        return
    end

    -- Anti rapid-fire: enforce a minimum time between stops
    local now = os.time()
    if (now - route.lastStopTime) < (Config.StopCooldown or 0) then
        cb(false, 0, 0)
        return
    end

    -- Server-side proximity check (never trust client-sent coords)
    local currStopCoords = Config.Locations['trashcan'][currentStop].coords
    currStopCoords = vector3(currStopCoords.x, currStopCoords.y, currStopCoords.z)
    local distance = #(GetEntityCoords(GetPlayerPed(source)) - currStopCoords)

    if distance <= 20 then
        route.lastStopTime = now
        if (math.random(100) >= Config.CryptoStickChance) and Config.GiveCryptoStick then
            exports['pfm-inventory']:AddItem(source, 'cryptostick', 1, false, false, 'qb-garbagejob:server:NextStop')
            TriggerClientEvent('qb-inventory:client:ItemBox', source, sharedItems['cryptostick'], 'add')
            TriggerClientEvent('QBCore:Notify', source, Lang:t('info.found_crypto'))
        end

        -- every stop, the last one included, is paid once; afterwards the route accepts no more stops
        -- (the last stop used to stay open, so it could be "collected" again and again for cryptosticks)
        PayForStop(route, currentStopNum)
        route.currentStop = currentStopNum + 1
        if currentStopNum >= #route.stops then
            newStop = currentStop
        else
            newStop = route.stops[currentStopNum + 1].stop
            newBagAmount = route.stops[currentStopNum + 1].bags
            shouldContinue = true
        end
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.too_far'), 'error')
    end
    cb(shouldContinue, newStop, newBagAmount)
end)

QBCore.Functions.CreateCallback('qb-garbagejob:server:EndShift', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    local CitizenId = Player.PlayerData.citizenid
    local status = false
    if Routes[CitizenId] ~= nil then status = true end
    cb(status)
end)

RegisterNetEvent('qb-garbagejob:server:PayShift', function(continue)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local CitizenId = Player.PlayerData.citizenid
    -- Server-side proximity check to the payslip collection point
    local payCoords = Config.Locations['paycheck'].coords
    if #(GetEntityCoords(GetPlayerPed(src)) - vector3(payCoords.x, payCoords.y, payCoords.z)) > (Config.PayslipMaxDistance or 10.0) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.too_far'), 'error')
        return
    end
    local route = Routes[CitizenId]
    if route ~= nil then
        local depositPay = route.depositPay
        if tonumber(route.stopsCompleted) < tonumber(route.totalNumberOfStops) and not continue then
            depositPay = 0
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.early_finish', { completed = route.stopsCompleted, total = route.totalNumberOfStops }), 'error')
        end
        local heldOver = 0
        if continue then
            -- the driver keeps the truck: the deposit stays held for the next route instead of refunding
            heldOver = depositPay
            depositPay = 0
        end
        local totalToPay = depositPay + route.actualPay
        local payoutDeposit = Lang:t('info.payout_deposit', { value = depositPay })
        if depositPay == 0 then
            payoutDeposit = ''
        end

        -- paid through the bank ledger with this route's keys; the route stays open until both went
        -- through, and a retry reuses the keys, so nothing is paid twice
        if route.actualPay > 0 and not PFPayout.Pay(Player, 'bank', route.actualPay, { key = ('pfm-garbagejob:%s:pay'):format(route.id), reason = 'garbage-payslip' }) then return end
        if depositPay > 0 and not PFPayout.Pay(Player, 'bank', depositPay, { key = ('pfm-garbagejob:%s:deposit-refund'):format(route.id), reason = 'garbage-deposit-refund', kind = 'refund' }) then return end
        if heldOver > 0 then HeldDeposits[CitizenId] = heldOver end
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.pay_slip', { total = totalToPay, deposit = payoutDeposit }), 'success')
        Routes[CitizenId] = nil
        SrcToCid[src] = nil
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.never_clocked_on'), 'error')
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    if SrcToCid[src] then
        Routes[SrcToCid[src]] = nil
        SrcToCid[src] = nil
    end
end)

QBCore.Commands.Add('cleargarbroutes', 'Removes garbo routes for user (admin only)', { { name = 'id', help = 'Player ID (may be empty)' } }, false, function(source, args)
    local Player = exports['pfm-core']:GetPlayer(tonumber(args[1]))
    local CitizenId = Player.PlayerData.citizenid
    local count = 0
    for k, _ in pairs(Routes) do
        if k == CitizenId then
            count = count + 1
        end
    end

    TriggerClientEvent('QBCore:Notify', source, Lang:t('success.clear_routes', { value = count }), 'success')
    Routes[CitizenId] = nil
end, 'admin')
