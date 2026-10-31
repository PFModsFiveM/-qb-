local QBCore = exports['pfm-core']:GetCoreObject({ 'Commands' })
local Races = {}

-- Races are built and judged on the server. The client used to send the whole race table (stake,
-- pot, entrant list, "started") and then claim the win, so one forged event paid any amount, and a
-- forged entrant list multiplied refunds. Now the client only chooses the finish line.
--
-- Stakes and winnings move through the pfm-banking ledger (player cash <-> system:pfm-streetraces)
-- under keys tied to the race, so each stake, refund and pot moves exactly once.

local START_RANGE = 15.0      -- metres from the start line to join
local FINISH_RANGE = 20.0     -- metres from the finish to claim the win
local MAX_RACE_SPEED = 70.0   -- m/s: a finish faster than distance / this is not believable
local CREATE_WINDOW = 60      -- seconds between /createrace and the client placing the race
local POT_ACCOUNT = 'system:pfm-streetraces'

local pendingCreate = {}      -- [src] = { amount, at }
local nextUid = 0

-- Functions

local function citizenId(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    return Player and Player.PlayerData.citizenid or nil
end

local function ledger(opts)
    if GetResourceState('pfm-banking') ~= 'started' then return { ok = false, error = 'bank_unavailable' } end
    local ok, res = pcall(function() return exports['pfm-banking']:Transfer(opts) end)
    if not ok or type(res) ~= 'table' then return { ok = false, error = 'bank_unavailable' } end
    return res
end

local function takeStake(src, race)
    local cid = citizenId(src)
    if not cid then return false end
    local res = ledger({
        from = ('player:%s:cash'):format(cid), to = POT_ACCOUNT, amount = race.amount,
        key = ('streetrace:%s:stake:%s'):format(race.uid, cid), kind = 'stake', reason = 'Street race stake', actor = cid,
    })
    return res.ok
end

local function refundStake(src, race, why)
    local cid = race.citizenIds[src] or citizenId(src)
    if not cid then return false end
    local res = ledger({
        from = POT_ACCOUNT, to = ('player:%s:cash'):format(cid), amount = race.amount,
        key = ('streetrace:%s:refund:%s'):format(race.uid, cid), kind = 'refund', reason = why or 'Street race refund', actor = cid,
    })
    return res.ok
end

local function finiteNumber(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge or math.abs(v) > 100000 then return nil end
    return v
end

local function playerPos(src)
    local p = GetEntityCoords(GetPlayerPed(src))
    return vector3(p.x, p.y, p.z)
end

local function flatDistance(a, bx, by)
    local dx, dy = a.x - bx, a.y - by
    return math.sqrt(dx * dx + dy * dy)
end

local function GetCreatedRace(identifier)
    for key in pairs(Races) do
        if Races[key] ~= nil and Races[key].creator == identifier and not Races[key].started then
            return key
        end
    end
    return 0
end

local function GetJoinedRace(identifier)
    for key in pairs(Races) do
        if Races[key] ~= nil and not Races[key].started then
            for _, iden in pairs(Races[key].joined) do
                if iden == identifier then
                    return key
                end
            end
        end
    end
    return 0
end

-- in any race, started or not
local function InAnyRace(identifier)
    for _, race in pairs(Races) do
        for _, iden in pairs(race.joined) do
            if iden == identifier then return true end
        end
    end
    return false
end

-- What clients may see about the races (no internals).
local function PublicRaces()
    local out = {}
    for id, r in pairs(Races) do
        out[id] = {
            creator = r.creator, started = r.started, amount = r.amount, pot = r.pot,
            startx = r.startx, starty = r.starty, startz = r.startz,
            endx = r.endx, endy = r.endy, endz = r.endz, joined = r.joined,
        }
    end
    return out
end

local function SyncRaces()
    TriggerClientEvent('qb-streetraces:SetRace', -1, PublicRaces())
end

local function UpdateRaceInfo(race)
    for _, src in pairs(race.joined) do
        TriggerClientEvent('qb-streetraces:UpdateRaceInfo', src, #race.joined, race.pot)
    end
end

-- Cancels a race that has not started and gives every entrant their stake back.
local function EndUnstartedRace(RaceId, reason)
    local race = Races[RaceId]
    if not race or race.started then return end
    Races[RaceId] = nil
    for _, iden in pairs(race.joined) do
        if refundStake(iden, race, 'Street race cancelled') then
            TriggerClientEvent('QBCore:Notify', iden, ('%s, You Got Back %s%s'):format(reason or 'Race Has Ended', Config.Currency, race.amount), 'error')
        end
        TriggerClientEvent('qb-streetraces:StopRace', iden)
    end
    SyncRaces()
end

local function CancelRace(source)
    local RaceId = GetCreatedRace(source)
    if RaceId ~= 0 then
        EndUnstartedRace(RaceId, 'Race Has Ended')
        TriggerClientEvent('QBCore:Notify', source, 'Race Stopped!', 'error')
    else
        for _, race in pairs(Races) do
            if race.creator == source and race.started then
                return TriggerClientEvent('QBCore:Notify', source, 'The Race Has Already Started', 'error')
            end
        end
        TriggerClientEvent('QBCore:Notify', source, 'You Have Not Started A Race!', 'error')
    end
end

function RemoveFromRace(identifier)
    for key in pairs(Races) do
        if Races[key] ~= nil and not Races[key].started then
            for i = #Races[key].joined, 1, -1 do
                if Races[key].joined[i] == identifier then
                    table.remove(Races[key].joined, i)
                end
            end
        end
    end
end

-- City events (pf-services): a street race the server judged (entrant at the finish after a
-- believable drive, see RaceWon) with at least two racers is a news lead: winner, time, field, pot.
local function ReportRaceResult(src, race)
    if #race.joined < 2 or GetResourceState('pf-services') ~= 'started' then return end
    local svc = exports['pf-services']
    if not svc then return end
    local Player = exports['pfm-core']:GetPlayer(src)
    local ci = Player and Player.PlayerData.charinfo or {}
    local winner = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    if winner == '' then winner = 'An unknown driver' end
    local seconds = math.max(0, os.time() - (race.startedAt or os.time()))
    pcall(function()
        svc:Emit('race.finished', { race = 'Street race', winner = winner, seconds = seconds, racers = #race.joined, pot = race.pot }, {
            title = ('%s wins a street race'):format(winner), coords = vector3(race.endx, race.endy, race.endz),
            actor = Player and Player.PlayerData.citizenid or nil, dedupe = race.uid,
        })
    end)
end

-- Events

-- The creator's client places the race after /createrace: only the finish line is taken from it.
RegisterNetEvent('qb-streetraces:NewRace', function(RaceTable)
    local src = source
    local pending = pendingCreate[src]
    pendingCreate[src] = nil -- single use
    if not pending or os.time() - pending.at > CREATE_WINDOW then return end
    if type(RaceTable) ~= 'table' or InAnyRace(src) then return end
    local endx, endy, endz = finiteNumber(RaceTable.endx), finiteNumber(RaceTable.endy), finiteNumber(RaceTable.endz)
    if not (endx and endy and endz) then return end
    local start = playerPos(src)
    if flatDistance(start, endx, endy) < Config.MinimumRaceDistance then
        return TriggerClientEvent('QBCore:Notify', src, 'End Position Is Too Close', 'error')
    end

    local RaceId
    repeat RaceId = math.random(1000, 9999) until Races[RaceId] == nil
    nextUid = nextUid + 1
    local race = {
        uid = ('%d-%d-%d'):format(os.time(), RaceId, nextUid),
        creator = src,
        started = false,
        startx = start.x, starty = start.y, startz = start.z,
        endx = endx, endy = endy, endz = endz,
        amount = pending.amount,
        pot = pending.amount,
        joined = { src },
        citizenIds = { [src] = citizenId(src) },
    }
    if not takeStake(src, race) then
        return TriggerClientEvent('QBCore:Notify', src, 'You do not have ' .. Config.Currency .. pending.amount .. '.', 'error')
    end
    Races[RaceId] = race
    SyncRaces()
    TriggerClientEvent('qb-streetraces:SetRaceId', src, RaceId)
    TriggerClientEvent('QBCore:Notify', src, 'You joined the race for ' .. Config.Currency .. race.amount .. '.', 'success')
    UpdateRaceInfo(race)
end)

RegisterNetEvent('qb-streetraces:RaceWon', function(RaceId)
    local src = source
    local race = Races[RaceId]
    -- only an entrant of a started race, at the finish, after a believable drive
    if not race or not race.started then return end
    local entered = false
    for _, iden in pairs(race.joined) do if iden == src then entered = true end end
    if not entered then return end
    local pos = playerPos(src)
    if flatDistance(pos, race.endx, race.endy) > FINISH_RANGE then return end
    local length = flatDistance(vector3(race.startx, race.starty, race.startz), race.endx, race.endy)
    if os.time() - race.startedAt < math.max(10, length / MAX_RACE_SPEED) then return end

    -- the race is over before anyone is paid, so the pot can be won once
    Races[RaceId] = nil
    local cid = citizenId(src)
    local res = cid and ledger({
        from = POT_ACCOUNT, to = ('player:%s:cash'):format(cid), amount = race.pot,
        key = ('streetrace:%s:pot'):format(race.uid), kind = 'winnings', reason = 'Street race won', actor = cid,
    }) or { ok = false }
    if res.ok then
        TriggerClientEvent('QBCore:Notify', src, 'You won the race and ' .. Config.Currency .. race.pot .. ',- recieved', 'success')
    else
        print(('^1[pfm-streetraces]^7 pot %s for race %s not paid (%s)'):format(tostring(race.pot), race.uid, tostring(res.error)))
    end
    SyncRaces()
    TriggerClientEvent('qb-streetraces:RaceDone', -1, RaceId, GetPlayerName(src))
    ReportRaceResult(src, race)
end)

RegisterNetEvent('qb-streetraces:JoinRace', function(RaceId)
    local src = source
    local race = Races[RaceId]
    if not race or race.started then return end
    if InAnyRace(src) then
        return TriggerClientEvent('QBCore:Notify', src, 'You Are Already In A Race', 'error')
    end
    if flatDistance(playerPos(src), race.startx, race.starty) > START_RANGE then return end
    if not exports['pfm-core']:GetPlayer(race.creator) then
        TriggerClientEvent('QBCore:Notify', src, 'The person wo made the race is offline!', 'error')
        return EndUnstartedRace(RaceId, 'The race creator left')
    end
    race.citizenIds[src] = citizenId(src)
    if takeStake(src, race) then
        race.pot = race.pot + race.amount
        race.joined[#race.joined + 1] = src
        SyncRaces()
        TriggerClientEvent('qb-streetraces:SetRaceId', src, RaceId)
        TriggerClientEvent('QBCore:Notify', src, 'You joined the race', 'primary')
        TriggerClientEvent('QBCore:Notify', race.creator, GetPlayerName(src) .. ' Joined the race', 'primary')
        UpdateRaceInfo(race)
    else
        race.citizenIds[src] = nil
        TriggerClientEvent('QBCore:Notify', src, 'You dont have enough cash', 'error')
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    pendingCreate[src] = nil
    local created = GetCreatedRace(src)
    if created ~= 0 then
        EndUnstartedRace(created, 'The race creator left')
        return
    end
    -- a racer who leaves before the start gets their stake back
    local joined = GetJoinedRace(src)
    if joined ~= 0 then
        local race = Races[joined]
        if refundStake(src, race, 'Left street race') then race.pot = race.pot - race.amount end
        RemoveFromRace(src)
        UpdateRaceInfo(race)
        SyncRaces()
    end
end)

-- Commands

QBCore.Commands.Add(Config.Commands.CreateRace, 'Start A Street Race', { { name = 'amount', help = 'The Stake Amount For The Race.' } }, false, function(source, args)
    local src = source
    local amount = tonumber(args[1])

    if not amount or amount ~= amount then return TriggerClientEvent('QBCore:Notify', src, 'Usage: /' .. Config.Commands.CreateRace .. ' [AMOUNT]', 'error') end
    amount = math.floor(amount)
    if amount < Config.MinimumStake then
        return TriggerClientEvent('QBCore:Notify', src, 'The minimum stake is ' .. Config.Currency .. Config.MinimumStake, 'error')
    end
    if amount > Config.MaximumStake then
        return TriggerClientEvent('QBCore:Notify', src, 'The maximum stake is ' .. Config.Currency .. Config.MaximumStake, 'error')
    end

    if not InAnyRace(src) then
        pendingCreate[src] = { amount = amount, at = os.time() }
        TriggerClientEvent('qb-streetraces:CreateRace', src, amount)
    else
        TriggerClientEvent('QBCore:Notify', src, 'You Are Already In A Race', 'error')
    end
end)

QBCore.Commands.Add(Config.Commands.CancelRace, 'Stop The Race You Created', {}, false, function(source, _)
    CancelRace(source)
end)

QBCore.Commands.Add(Config.Commands.QuitRace, 'Leave A Race', {}, false, function(source, _)
    local src = source
    local RaceId = GetJoinedRace(src)
    if RaceId ~= 0 then
        if GetCreatedRace(src) ~= RaceId then
            local race = Races[RaceId]
            if refundStake(src, race, 'Race Quit') then
                race.pot = race.pot - race.amount
            end
            RemoveFromRace(src)
            SyncRaces()
            TriggerClientEvent('qb-streetraces:StopRace', src)
            TriggerClientEvent('QBCore:Notify', src, 'You Have Stepped Out Of The Race!', 'error')
            UpdateRaceInfo(race)
        else
            TriggerClientEvent('QBCore:Notify', src, '/' .. Config.Commands.CancelRace .. ' To Stop The Race', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, 'You Are Not In A Race ', 'error')
    end
end)

QBCore.Commands.Add(Config.Commands.StartRace, 'Start The Race', {}, false, function(source)
    local src = source
    local RaceId = GetCreatedRace(src)

    if RaceId ~= 0 then
        Races[RaceId].started = true
        Races[RaceId].startedAt = os.time()
        SyncRaces()
        TriggerClientEvent('qb-streetraces:StartRace', -1, RaceId)
    else
        TriggerClientEvent('QBCore:Notify', src, 'You Have Not Started A Race', 'error')
    end
end)
