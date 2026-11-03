local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local Races = {}
local AvailableRaces = {}
local LastRaces = {}
local NotFinished = {}

-- Functions

--- m:ss.mmm of a time in milliseconds.
local function MsToClock(ms)
    ms = math.max(0, math.floor(tonumber(ms) or 0))
    return ('%d:%02d.%03d'):format(ms // 60000, (ms % 60000) // 1000, ms % 1000)
end

--- Whole seconds, for the phone's leaderboards (they show seconds as h:mm:ss).
local function ToSeconds(ms) return math.floor((tonumber(ms) or 0) / 1000) end

local function IsWhitelisted(CitizenId)
    local retval = false
    for _, cid in pairs(Config.WhitelistedCreators) do
        if cid == CitizenId then
            retval = true
            break
        end
    end
    local Player = QBCore.Functions.GetPlayerByCitizenId(CitizenId)
    local Perms = Player and QBCore.Functions.GetPermission(Player.PlayerData.source)
    if Perms == 'admin' or Perms == 'god' then
        retval = true
    end
    return retval
end

local function IsNameAvailable(RaceName)
    local retval = true
    for RaceId, _ in pairs(Races) do
        if Races[RaceId].RaceName == RaceName then
            retval = false
            break
        end
    end
    return retval
end

local function HasOpenedRace(CitizenId)
    local retval = false
    for _, v in pairs(AvailableRaces) do
        if v.SetupCitizenId == CitizenId then
            retval = true
        end
    end
    return retval
end

local function GetOpenedRaceKey(RaceId)
    local retval = nil
    for k, v in pairs(AvailableRaces) do
        if v.RaceId == RaceId then
            retval = k
            break
        end
    end
    return retval
end

local function GetCurrentRace(MyCitizenId)
    local retval = nil
    for RaceId, _ in pairs(Races) do
        for cid, _ in pairs(Races[RaceId].Racers) do
            if cid == MyCitizenId then
                retval = RaceId
                break
            end
        end
    end
    return retval
end

local function GetRaceId(name)
    local retval = nil
    for k, v in pairs(Races) do
        if v.RaceName == name then
            retval = k
            break
        end
    end
    return retval
end

-- Client events name a race; the player must actually be one of its racers (the handlers used to act
-- on any race id and crashed on unknown ones).
local function RacerOf(src, RaceId)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(RaceId) ~= 'string' or not Races[RaceId] then return nil end
    local racer = Races[RaceId].Racers[Player.PlayerData.citizenid]
    if not racer then return nil end
    return Player, racer
end

local MAX_LAPS = 50
local MAX_CHECKPOINTS = 100
local COUNTDOWN_MS = 10000 -- the racers' countdown (10 x 1 s on the client) between StartRace and GO

-- Race times are measured here: each checkpoint pass is stamped with the server clock when the racer
-- stands at that checkpoint (server position), in order, no sooner than the track allows; the finish
-- time and best lap come from those stamps. The client's race clock (UI ticks) and its checkpoint
-- numbers used to be taken, so any time became the track record.
local function CheckpointRadius() return tonumber(Config.CheckpointRadius) or 40.0 end
local function MaxSpeed() return math.max(1.0, tonumber(Config.MaxSpeed) or 90.0) end

local function CheckpointPoint(race, i)
    local cp = race.Checkpoints and race.Checkpoints[i]
    local c = type(cp) == 'table' and cp.coords
    if type(c) ~= 'table' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not x or not y then return nil end
    return vector3(x, y, z or 0.0)
end

--- The shortest time (ms) a car can need from checkpoint a to b: their distance less the reach of both
--- (a pass counts anywhere within it), at the top speed allowed.
local function MinSegmentMs(race, a, b)
    local pa, pb = CheckpointPoint(race, a), CheckpointPoint(race, b)
    if not pa or not pb then return 0 end
    local d = #(pa - pb) - 2 * CheckpointRadius()
    if d <= 0 then return 0 end
    return math.floor(d / MaxSpeed() * 1000)
end

--- The shortest a lap of this track can take: every segment, including the one back to the start.
local function MinLapMs(race)
    local n = #(race.Checkpoints or {})
    local total = 0
    for i = 1, n do total = total + MinSegmentMs(race, i, i % n + 1) end
    return total
end

local function GenerateRaceId()
    local RaceId = 'LR-' .. math.random(1111, 9999)
    while Races[RaceId] ~= nil do
        RaceId = 'LR-' .. math.random(1111, 9999)
    end
    return RaceId
end

-- City events (pf-services): the winner of a race with at least two racers is a news lead. The
-- finish order is the server's, but the race clock is the client's (UI ticks), so only results the
-- server can stand behind are reported: the first racer to finish, standing at the finish line by the
-- server's own position, with the server-measured race time.
local FINISH_RADIUS = 60.0

local function FinishLine(race, laps)
    local cps = race.Checkpoints or {}
    local cp = (tonumber(laps) or 0) > 0 and cps[1] or cps[#cps]
    local c = cp and cp.coords
    if type(c) ~= 'table' or not tonumber(c.x) or not tonumber(c.y) then return nil end
    return vector3(tonumber(c.x), tonumber(c.y), tonumber(c.z) or 0.0)
end

local function ReportWinner(src, Player, race, laps, racers, totalMs)
    if racers < 2 or GetResourceState('pf-services') ~= 'started' then return end
    local line = FinishLine(race, laps)
    if not line then return end
    local p = GetEntityCoords(GetPlayerPed(src))
    if #(vector3(p.x, p.y, p.z) - line) > FINISH_RADIUS then return end
    local svc = exports['pf-services']
    if not svc then return end
    local ci = Player.PlayerData.charinfo or {}
    local winner = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    local seconds = math.max(0, ToSeconds(totalMs))
    pcall(function()
        svc:Emit('race.finished', { race = race.RaceName, winner = winner, seconds = seconds, time = ('%d:%02d'):format(seconds // 60, seconds % 60),
            laps = tonumber(laps) or 0, racers = racers }, {
            title = ('%s wins %s'):format(winner ~= '' and winner or 'A driver', tostring(race.RaceName)), coords = line,
            actor = Player.PlayerData.citizenid, dedupe = tostring(race.RaceId) .. ':' .. tostring(race.StartedAt),
        })
    end)
end

-- Events

--- Counts the racer's next checkpoint, from the server's view: the racer stands within reach of it
--- (server position), the race has started (the countdown is over) and the time since the previous
--- checkpoint is not shorter than the track allows. Returns true, or false and why.
local function PassCheckpoint(src, race, racer)
    local now = GetGameTimer()
    if now < (race.StartMs or 0) then return false, 'early' end
    local n = #race.Checkpoints
    local e = racer.Next
    local point = CheckpointPoint(race, e)
    if not point then return false, 'track' end
    local pos = GetEntityCoords(GetPlayerPed(src))
    -- (written so that a NaN position fails too)
    if not (#(vector3(pos.x, pos.y, pos.z) - point) <= CheckpointRadius()) then return false, 'far' end
    local prev = e == 1 and n or e - 1
    if now - racer.LastPassAt < MinSegmentMs(race, prev, e) then return false, 'fast' end
    local laps = race.ActiveLaps or 0
    if e == 1 then
        -- a lap ends at the start line
        local lapMs = now - racer.LapStartAt
        if lapMs < (race.MinLapMs or 0) then return false, 'fast' end
        racer.BestLapMs = racer.BestLapMs and math.min(racer.BestLapMs, lapMs) or lapMs
        racer.LapStartAt = now
        if racer.Lap >= laps then
            racer.Completed, racer.FinishedAt = true, now
        else
            racer.Lap, racer.Next = racer.Lap + 1, 2
        end
    elseif laps == 0 and e == n then
        -- a sprint ends at its last checkpoint
        racer.Completed, racer.FinishedAt = true, now
    else
        racer.Next = e == n and 1 or e + 1
    end
    racer.LastPassAt, racer.Checkpoint = now, e
    return true
end

local function HolderOf(Player)
    local ci = Player.PlayerData.charinfo or {}
    return { [1] = ci.firstname, [2] = ci.lastname }
end

--- The racer passed their last checkpoint: their place, time and best lap (server-measured) are
--- recorded, a track record kept, and the race closed once everyone is done.
local function FinishRacer(src, Player, RaceId, racer)
    local race = Races[RaceId]
    local AvailableKey = GetOpenedRaceKey(RaceId)
    if not AvailableKey or racer.FinishSent then return end
    local totalMs = racer.FinishedAt - race.StartMs
    local bestMs = ((race.ActiveLaps or 0) >= 1 and racer.BestLapMs) or totalMs
    local first, racers = true, 0
    for _, r in pairs(race.Racers) do
        racers = racers + 1
        if r.FinishSent then first = false end
    end
    racer.FinishSent = true
    racer.Finished = true
    if first then ReportWinner(src, Player, race, race.ActiveLaps, racers, totalMs) end
    local PlayersFinished, AmountOfRacers = 0, 0
    for _, v in pairs(race.Racers) do
        if v.Finished then PlayersFinished = PlayersFinished + 1 end
        AmountOfRacers = AmountOfRacers + 1
    end
    LastRaces[RaceId] = LastRaces[RaceId] or {}
    LastRaces[RaceId][#LastRaces[RaceId] + 1] = {
        TotalTime = ToSeconds(totalMs), BestLap = ToSeconds(bestMs), TotalTimeMs = totalMs, BestLapMs = bestMs, Holder = HolderOf(Player),
    }
    -- a record from before server timing (no TimeMs: the client's tick count) does not count
    local record = race.Records
    if type(record) ~= 'table' or not tonumber(record.TimeMs) or bestMs < tonumber(record.TimeMs) then
        race.Records = { Time = ToSeconds(bestMs), TimeMs = bestMs, Holder = HolderOf(Player) }
        MySQL.update('UPDATE lapraces SET records = ? WHERE raceid = ?', { json.encode(race.Records), RaceId })
        TriggerClientEvent('qb-phone:client:RaceNotify', src, 'New track record on ' .. tostring(race.RaceName) .. ': ' .. MsToClock(bestMs) .. '!')
    end
    AvailableRaces[AvailableKey].RaceData = race
    TriggerClientEvent('qb-lapraces:client:RaceFinished', src, RaceId, totalMs, bestMs)
    -- the finisher's name only (the whole player object went to every client)
    TriggerClientEvent('qb-lapraces:client:PlayerFinishs', -1, RaceId, PlayersFinished, { PlayerData = { charinfo = { firstname = HolderOf(Player)[1], lastname = HolderOf(Player)[2] } } })
    if PlayersFinished == AmountOfRacers then
        for _, v in pairs(NotFinished[RaceId] or {}) do
            LastRaces[RaceId][#LastRaces[RaceId] + 1] = { TotalTime = v.TotalTime, BestLap = v.BestLap, Holder = { [1] = v.Holder[1], [2] = v.Holder[2] } }
        end
        race.LastLeaderboard = LastRaces[RaceId]
        race.Racers = {}
        race.Started = false
        race.Waiting = false
        table.remove(AvailableRaces, AvailableKey)
        LastRaces[RaceId] = nil
        NotFinished[RaceId] = nil
    end
    TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
end

RegisterNetEvent('qb-lapraces:server:CreateLapRace', function(RaceName)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)

    if IsWhitelisted(Player.PlayerData.citizenid) then
        if IsNameAvailable(RaceName) then
            TriggerClientEvent('qb-lapraces:client:StartRaceEditor', source, RaceName)
        else
            TriggerClientEvent('QBCore:Notify', source, 'There is already a race with this name.', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', source, 'You have not been authorized to race\'s to create.', 'error')
    end
end)

RegisterNetEvent('qb-lapraces:server:JoinRace', function(RaceData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(RaceData) ~= 'table' then return end
    local RaceId = RaceData.RaceId
    local AvailableKey = GetOpenedRaceKey(RaceId)
    -- only a race that is set up and has not started can be joined
    if not AvailableKey or not Races[RaceId] or Races[RaceId].Started then return end
    local CurrentRace = GetCurrentRace(Player.PlayerData.citizenid)
    if CurrentRace == RaceId then return end
    if CurrentRace ~= nil then
        local AmountOfRacers = 0
        local PreviousRaceKey = GetOpenedRaceKey(CurrentRace)
        for _, _ in pairs(Races[CurrentRace].Racers) do
            AmountOfRacers = AmountOfRacers + 1
        end
        Races[CurrentRace].Racers[Player.PlayerData.citizenid] = nil
        if (AmountOfRacers - 1) == 0 then
            Races[CurrentRace].Racers = {}
            Races[CurrentRace].Started = false
            Races[CurrentRace].Waiting = false
            table.remove(AvailableRaces, PreviousRaceKey)
            TriggerClientEvent('QBCore:Notify', src, 'You were the only one in the race, the race had ended', 'error')
            TriggerClientEvent('qb-lapraces:client:LeaveRace', src, Races[CurrentRace])
        else
            AvailableRaces[PreviousRaceKey].RaceData = Races[CurrentRace]
            TriggerClientEvent('qb-lapraces:client:LeaveRace', src, Races[CurrentRace])
        end
        TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
    end
    Races[RaceId].Waiting = true
    Races[RaceId].Racers[Player.PlayerData.citizenid] = {
        Checkpoint = 0,
        Lap = 1,
        Finished = false
    }
    AvailableRaces[AvailableKey].RaceData = Races[RaceId]
    TriggerClientEvent('qb-lapraces:client:JoinRace', src, Races[RaceId], AvailableRaces[AvailableKey].Laps)
    TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
    local creator = QBCore.Functions.GetPlayerByCitizenId(AvailableRaces[AvailableKey].SetupCitizenId)
    local creatorsource = creator and creator.PlayerData.source
    if creatorsource and creatorsource ~= Player.PlayerData.source then
        TriggerClientEvent('qb-phone:client:RaceNotify', creatorsource,
            string.sub(Player.PlayerData.charinfo.firstname, 1, 1) .. '. ' .. Player.PlayerData.charinfo.lastname ..
            ' the race has been joined!')
    end
end)

RegisterNetEvent('qb-lapraces:server:LeaveRace', function(RaceData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    -- the race left is the one the server has this player in (the client's race name and id could
    -- name two different races, and unknown ones crashed the handler)
    local RaceId = GetCurrentRace(Player.PlayerData.citizenid)
    local AvailableKey = RaceId and GetOpenedRaceKey(RaceId)
    if not AvailableKey then return end
    RaceData = { RaceId = RaceId }
    local creator = QBCore.Functions.GetPlayerByCitizenId(AvailableRaces[AvailableKey].SetupCitizenId)
    local creatorsource = creator and creator.PlayerData.source
    if creatorsource and creatorsource ~= Player.PlayerData.source then
        TriggerClientEvent('qb-phone:client:RaceNotify', creatorsource,
            string.sub(Player.PlayerData.charinfo.firstname, 1, 1) .. '. ' .. Player.PlayerData.charinfo.lastname ..
            ' the race has been delivered!')
    end
    local AmountOfRacers = 0
    for _, _ in pairs(Races[RaceData.RaceId].Racers) do
        AmountOfRacers = AmountOfRacers + 1
    end
    if NotFinished[RaceData.RaceId] ~= nil then
        NotFinished[RaceData.RaceId][#NotFinished[RaceData.RaceId] + 1] = {
            TotalTime = 'DNF',
            BestLap = 'DNF',
            Holder = {
                [1] = Player.PlayerData.charinfo.firstname,
                [2] = Player.PlayerData.charinfo.lastname
            }
        }
    else
        NotFinished[RaceData.RaceId] = {}
        NotFinished[RaceData.RaceId][#NotFinished[RaceData.RaceId] + 1] = {
            TotalTime = 'DNF',
            BestLap = 'DNF',
            Holder = {
                [1] = Player.PlayerData.charinfo.firstname,
                [2] = Player.PlayerData.charinfo.lastname
            }
        }
    end
    Races[RaceId].Racers[Player.PlayerData.citizenid] = nil
    if (AmountOfRacers - 1) == 0 then
        if NotFinished ~= nil and next(NotFinished) ~= nil and NotFinished[RaceId] ~= nil and next(NotFinished[RaceId]) ~=
            nil then
            for _, v in pairs(NotFinished[RaceId]) do
                if LastRaces[RaceId] ~= nil then
                    LastRaces[RaceId][#LastRaces[RaceId] + 1] = {
                        TotalTime = v.TotalTime,
                        BestLap = v.BestLap,
                        Holder = {
                            [1] = v.Holder[1],
                            [2] = v.Holder[2]
                        }
                    }
                else
                    LastRaces[RaceId] = {}
                    LastRaces[RaceId][#LastRaces[RaceId] + 1] = {
                        TotalTime = v.TotalTime,
                        BestLap = v.BestLap,
                        Holder = {
                            [1] = v.Holder[1],
                            [2] = v.Holder[2]
                        }
                    }
                end
            end
        end
        Races[RaceId].LastLeaderboard = LastRaces[RaceId]
        Races[RaceId].Racers = {}
        Races[RaceId].Started = false
        Races[RaceId].Waiting = false
        table.remove(AvailableRaces, AvailableKey)
        TriggerClientEvent('QBCore:Notify', src, 'You were the only one in the race.The race had ended.', 'error')
        TriggerClientEvent('qb-lapraces:client:LeaveRace', src, Races[RaceId])
        LastRaces[RaceId] = nil
        NotFinished[RaceId] = nil
    else
        AvailableRaces[AvailableKey].RaceData = Races[RaceId]
        TriggerClientEvent('qb-lapraces:client:LeaveRace', src, Races[RaceId])
    end
    TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
end)

RegisterNetEvent('qb-lapraces:server:SetupRace', function(RaceId, Laps)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or type(RaceId) ~= 'string' then return end
    -- the server enforces what the phone only showed: setup switched on, one open race per player,
    -- and a sane lap count (0 = sprint)
    if not Config.RaceSetupAllowed or HasOpenedRace(Player.PlayerData.citizenid) then return end
    Laps = tonumber(Laps)
    if not Laps or Laps ~= math.floor(Laps) or Laps < 0 or Laps > MAX_LAPS then return end
    if Races[RaceId] ~= nil then
        if not Races[RaceId].Waiting then
            if not Races[RaceId].Started then
                Races[RaceId].Waiting = true
                AvailableRaces[#AvailableRaces + 1] = {
                    RaceData = Races[RaceId],
                    Laps = Laps,
                    RaceId = RaceId,
                    SetupCitizenId = Player.PlayerData.citizenid
                }
                TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
                SetTimeout(5 * 60 * 1000, function()
                    if Races[RaceId].Waiting then
                        local AvailableKey = GetOpenedRaceKey(RaceId)
                        for cid, _ in pairs(Races[RaceId].Racers) do
                            local RacerData = QBCore.Functions.GetPlayerByCitizenId(cid)
                            if RacerData ~= nil then
                                TriggerClientEvent('qb-lapraces:client:LeaveRace', RacerData.PlayerData.source,
                                    Races[RaceId])
                            end
                        end
                        table.remove(AvailableRaces, AvailableKey)
                        Races[RaceId].LastLeaderboard = {}
                        Races[RaceId].Racers = {}
                        Races[RaceId].Started = false
                        Races[RaceId].Waiting = false
                        LastRaces[RaceId] = nil
                        TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
                    end
                end)
            else
                TriggerClientEvent('QBCore:Notify', source, 'The race is already running', 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', source, 'The race is already running', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', source, 'This race does not exist :(', 'error')
    end
end)

RegisterNetEvent('qb-lapraces:server:CancelRace', function(raceId)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or type(raceId) ~= 'string' then return end
    local AvailableKey = GetOpenedRaceKey(raceId)

    TriggerClientEvent('QBCore:Notify', src, 'Stopping the race: ' .. raceId, 'error')

    if AvailableKey ~= nil then
        if AvailableRaces[AvailableKey].SetupCitizenId == Player.PlayerData.citizenid then
            for cid, _ in pairs(Races[raceId].Racers) do
                local RacerData = QBCore.Functions.GetPlayerByCitizenId(cid)
                if RacerData ~= nil then
                    TriggerClientEvent('qb-lapraces:client:LeaveRace', RacerData.PlayerData.source, Races[raceId])
                end
            end

            table.remove(AvailableRaces, AvailableKey)
            Races[raceId].LastLeaderboard = {}
            Races[raceId].Racers = {}
            Races[raceId].Started = false
            Races[raceId].Waiting = false
            LastRaces[raceId] = nil
            TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, 'Race not open: ' .. raceId, 'error')
    end
end)

-- The server already sets these states (SetupRace/JoinRace: waiting, StartRace: started); a racer's
-- client echoing them is accepted, but no client can start or stop a race it is not in, or start one
-- its creator has not started.
RegisterNetEvent('qb-lapraces:server:UpdateRaceState', function(RaceId, Started, Waiting)
    if not RacerOf(source, RaceId) then return end
    local race = Races[RaceId]
    if race.Started then return end
    if Started == false and Waiting == true then race.Waiting = true end
end)

-- A racer's client reports it drove through its next checkpoint. Which checkpoint that is, and whether
-- it counts, is the server's (the checkpoint and lap numbers the client sends are not used); one that
-- does not count sends the client back to the checkpoint it missed. The last one finishes the racer.
RegisterNetEvent('qb-lapraces:server:UpdateRacerData', function(RaceId)
    local src = source
    local Player, racer = RacerOf(src, RaceId)
    if not Player then return end
    local race = Races[RaceId]
    if not race.Started or not race.StartMs or racer.Completed or not racer.Next then return end
    local ok, why = PassCheckpoint(src, race, racer)
    if not ok then
        TriggerClientEvent('qb-lapraces:client:CheckpointMissed', src, RaceId, racer.Next, racer.Lap, why)
        return
    end
    TriggerClientEvent('qb-lapraces:client:UpdateRaceRacerData', -1, RaceId, race)
    if racer.Completed then FinishRacer(src, Player, RaceId, racer) end
end)

RegisterNetEvent('qb-lapraces:server:StartRace', function(RaceId)
    local src = source
    local MyPlayer = exports['pfm-core']:GetPlayer(src)
    if not MyPlayer then return end
    local AvailableKey = GetOpenedRaceKey(RaceId)

    if RaceId ~= nil and AvailableKey ~= nil then
        if AvailableRaces[AvailableKey].SetupCitizenId == MyPlayer.PlayerData.citizenid then
            if AvailableRaces[AvailableKey].RaceData.Started then return end
            local race = Races[RaceId]
            race.Started = true
            race.Waiting = false
            race.StartedAt = os.time()
            -- the server's race clock: GO is when the racers' countdown ends
            race.StartMs = GetGameTimer() + COUNTDOWN_MS
            race.ActiveLaps = AvailableRaces[AvailableKey].Laps
            race.MinLapMs = MinLapMs(race)
            for _, racer in pairs(race.Racers) do
                racer.Next, racer.Lap, racer.Checkpoint = 2, 1, 1
                racer.LastPassAt, racer.LapStartAt = race.StartMs, race.StartMs
                racer.BestLapMs, racer.Completed, racer.FinishedAt = nil, false, nil
            end
            AvailableRaces[AvailableKey].RaceData = race
            for CitizenId, _ in pairs(Races[RaceId].Racers) do
                local Player = QBCore.Functions.GetPlayerByCitizenId(CitizenId)
                if Player ~= nil then
                    TriggerClientEvent('qb-lapraces:client:RaceCountdown', Player.PlayerData.source)
                end
            end
            TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
        else
            TriggerClientEvent('QBCore:Notify', src, 'You are not the creator of the race..', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, 'You are not in a race..', 'error')
    end
end)

RegisterNetEvent('qb-lapraces:server:SaveRace', function(RaceData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    -- only whitelisted creators save tracks (anyone could write tracks to the database before), with a
    -- free name of sane length and a bounded number of checkpoints
    if not Player or type(RaceData) ~= 'table' or not IsWhitelisted(Player.PlayerData.citizenid) then return end
    if type(RaceData.RaceName) ~= 'string' or #RaceData.RaceName < 1 or #RaceData.RaceName > 64 or not IsNameAvailable(RaceData.RaceName) then return end
    if type(RaceData.Checkpoints) ~= 'table' or #RaceData.Checkpoints < 2 or #RaceData.Checkpoints > MAX_CHECKPOINTS then return end
    -- every checkpoint needs a real position (the server times the race from them)
    local Checkpoints = {}
    for k, v in ipairs(RaceData.Checkpoints) do
        if type(v) ~= 'table' or type(v.coords) ~= 'table' then return end
        local x, y, z = tonumber(v.coords.x), tonumber(v.coords.y), tonumber(v.coords.z)
        if not x or not y or not z or x ~= x or y ~= y or z ~= z or math.abs(x) > 1e5 or math.abs(y) > 1e5 or math.abs(z) > 1e5 then return end
        Checkpoints[k] = {
            offset = type(v.offset) == 'table' and v.offset or {},
            coords = { x = x, y = y, z = z }
        }
    end
    -- the length is measured here too (the creator's client sent it)
    local distance = 0
    for k = 1, #Checkpoints - 1 do
        local a, b = Checkpoints[k].coords, Checkpoints[k + 1].coords
        distance = distance + #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
    end
    RaceData.RaceDistance = distance
    local RaceId = GenerateRaceId()
    Races[RaceId] = {
        RaceName = RaceData.RaceName,
        Checkpoints = Checkpoints,
        Records = {},
        Creator = Player.PlayerData.citizenid,
        RaceId = RaceId,
        Started = false,
        Waiting = false,
        Distance = math.ceil(RaceData.RaceDistance),
        Racers = {},
        LastLeaderboard = {}
    }
    MySQL.insert('INSERT INTO lapraces (name, checkpoints, creator, distance, raceid) VALUES (?, ?, ?, ?, ?)',
        { RaceData.RaceName, json.encode(Checkpoints), Player.PlayerData.citizenid, RaceData.RaceDistance,
            RaceId })
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-lapraces:server:GetRacingLeaderboards', function(_, cb)
    cb(Races)
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:GetRaces', function(_, cb)
    cb(AvailableRaces)
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:GetListedRaces', function(_, cb)
    cb(Races)
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:GetRacingData', function(_, cb, RaceId)
    cb(Races[RaceId])
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:HasCreatedRace', function(source, cb)
    cb(HasOpenedRace(exports['pfm-core']:GetPlayer(source).PlayerData.citizenid))
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:IsAuthorizedToCreateRaces', function(source, cb, TrackName)
    cb(IsWhitelisted(exports['pfm-core']:GetPlayer(source).PlayerData.citizenid), IsNameAvailable(TrackName))
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:CanRaceSetup', function(_, cb)
    cb(Config.RaceSetupAllowed)
end)

-- The phone shows the track creator's name; only that is sent. (The creator's whole players row -
-- money, inventory, metadata, license - went to any client asking.)
QBCore.Functions.CreateCallback('qb-lapraces:server:GetTrackData', function(_, cb, RaceId)
    if type(RaceId) ~= 'string' or not Races[RaceId] then return cb(nil) end
    local result = MySQL.query.await('SELECT charinfo FROM players WHERE citizenid = ?', { Races[RaceId].Creator }) or {}
    local charinfo = result[1] and json.decode(result[1].charinfo or '')
    if type(charinfo) == 'table' then
        cb(Races[RaceId], { charinfo = { firstname = charinfo.firstname, lastname = charinfo.lastname } })
    else
        cb(Races[RaceId], {
            charinfo = {
                firstname = 'Unknown',
                lastname = 'Unknown'
            }
        })
    end
end)

-- Commands

QBCore.Commands.Add('cancelrace', 'Cancel going race..', {}, false, function(source, args)
    local Player = exports['pfm-core']:GetPlayer(source)

    if IsWhitelisted(Player.PlayerData.citizenid) then
        local RaceName = table.concat(args, ' ')
        if RaceName ~= nil then
            local RaceId = GetRaceId(RaceName)
            if Races[RaceId].Started then
                local AvailableKey = GetOpenedRaceKey(RaceId)
                for cid, _ in pairs(Races[RaceId].Racers) do
                    local RacerData = QBCore.Functions.GetPlayerByCitizenId(cid)
                    if RacerData ~= nil then
                        TriggerClientEvent('qb-lapraces:client:LeaveRace', RacerData.PlayerData.source, Races[RaceId])
                    end
                end
                table.remove(AvailableRaces, AvailableKey)
                Races[RaceId].LastLeaderboard = {}
                Races[RaceId].Racers = {}
                Races[RaceId].Started = false
                Races[RaceId].Waiting = false
                LastRaces[RaceId] = nil
                TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
            else
                TriggerClientEvent('QBCore:Notify', source, 'This race has not started yet.', 'error')
            end
        end
    else
        TriggerClientEvent('QBCore:Notify', source, 'You have not been authorized to do this.', 'error')
    end
end)

QBCore.Commands.Add('togglesetup', 'Turn on / off racing setup', {}, false, function(source, _)
    local Player = exports['pfm-core']:GetPlayer(source)

    if IsWhitelisted(Player.PlayerData.citizenid) then
        Config.RaceSetupAllowed = not Config.RaceSetupAllowed
        if not Config.RaceSetupAllowed then
            TriggerClientEvent('QBCore:Notify', source, 'No more races can be created!', 'error')
        else
            TriggerClientEvent('QBCore:Notify', source, 'Races can be created again!', 'success')
        end
    else
        TriggerClientEvent('QBCore:Notify', source, 'You have not been authorized to do this.', 'error')
    end
end)

-- Threads

CreateThread(function()
    local races = MySQL.query.await('SELECT * FROM lapraces', {})
    if races[1] ~= nil then
        for _, v in pairs(races) do
            local Records = {}
            if v.records ~= nil then
                Records = json.decode(v.records)
            end
            -- a record from before server timing was the client's tick count: shown as no record,
            -- and replaced in the database by the first time the server measures on that track
            if type(Records) ~= 'table' or not tonumber(Records.TimeMs) then Records = {} end
            Races[v.raceid] = {
                RaceName = v.name,
                Checkpoints = json.decode(v.checkpoints),
                Records = Records,
                Creator = v.creator,
                RaceId = v.raceid,
                Started = false,
                Waiting = false,
                Distance = v.distance,
                LastLeaderboard = {},
                Racers = {}
            }
        end
    end
end)
