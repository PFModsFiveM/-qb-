local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local Races = {}
local AvailableRaces = {}
local LastRaces = {}
local NotFinished = {}

-- Functions

local function SecondsToClock(seconds)
    seconds = tonumber(seconds)
    local retval
    if seconds <= 0 then
        retval = '00:00:00';
    else
        local hours = string.format('%02.f', math.floor(seconds / 3600));
        local mins = string.format('%02.f', math.floor(seconds / 60 - (hours * 60)));
        local secs = string.format('%02.f', math.floor(seconds - hours * 3600 - mins * 60));
        retval = hours .. ':' .. mins .. ':' .. secs
    end
    return retval
end

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
local START_SLACK = 15 -- seconds of countdown and network delay between StartRace and the racers' clocks
local MIN_TICKS_PER_SECOND = 5

local function GenerateRaceId()
    local RaceId = 'LR-' .. math.random(1111, 9999)
    while Races[RaceId] ~= nil do
        RaceId = 'LR-' .. math.random(1111, 9999)
    end
    return RaceId
end

-- Events

RegisterNetEvent('qb-lapraces:server:FinishPlayer', function(RaceData, TotalTime, TotalLaps, BestLap)
    local src = source
    if type(RaceData) ~= 'table' then return end
    -- Only a racer in a started race finishes it, once, with times the server's clock allows: a time
    -- shorter than the race has run is refused (records were any number a client sent).
    local Player, racer = RacerOf(src, RaceData.RaceId)
    if not Player or not Races[RaceData.RaceId].Started or racer.FinishSent then return end
    local AvailableKey = GetOpenedRaceKey(RaceData.RaceId)
    if not AvailableKey then return end
    TotalTime, TotalLaps, BestLap = tonumber(TotalTime), tonumber(TotalLaps), tonumber(BestLap)
    if not TotalTime or TotalTime ~= TotalTime or TotalTime <= 0 or not TotalLaps or TotalLaps < 0 then return end
    -- the client's race clock counts UI frames (one per 12 ms or more), so it can only be bounded below:
    -- at least MIN_TICKS_PER_SECOND for each second the race has run on the server
    local elapsed = os.time() - (Races[RaceData.RaceId].StartedAt or os.time())
    if TotalTime < (elapsed - START_SLACK) * MIN_TICKS_PER_SECOND then return end
    if TotalLaps >= 2 and (not BestLap or BestLap ~= BestLap or BestLap <= 0 or BestLap > TotalTime) then return end
    racer.FinishSent = true
    racer.Finished = true
    RaceData = { RaceId = RaceData.RaceId, RaceName = Races[RaceData.RaceId].RaceName }
    local PlayersFinished = 0
    local AmountOfRacers = 0
    for _, v in pairs(Races[RaceData.RaceId].Racers) do
        if v.Finished then
            PlayersFinished = PlayersFinished + 1
        end
        AmountOfRacers = AmountOfRacers + 1
    end
    local BLap
    if TotalLaps < 2 then
        BLap = TotalTime
    else
        BLap = BestLap
    end
    if LastRaces[RaceData.RaceId] ~= nil then
        LastRaces[RaceData.RaceId][#LastRaces[RaceData.RaceId] + 1] = {
            TotalTime = TotalTime,
            BestLap = BLap,
            Holder = {
                [1] = Player.PlayerData.charinfo.firstname,
                [2] = Player.PlayerData.charinfo.lastname
            }
        }
    else
        LastRaces[RaceData.RaceId] = {}
        LastRaces[RaceData.RaceId][#LastRaces[RaceData.RaceId] + 1] = {
            TotalTime = TotalTime,
            BestLap = BLap,
            Holder = {
                [1] = Player.PlayerData.charinfo.firstname,
                [2] = Player.PlayerData.charinfo.lastname
            }
        }
    end
    if Races[RaceData.RaceId].Records ~= nil and next(Races[RaceData.RaceId].Records) ~= nil then
        if BLap < Races[RaceData.RaceId].Records.Time then
            Races[RaceData.RaceId].Records = {
                Time = BLap,
                Holder = {
                    [1] = Player.PlayerData.charinfo.firstname,
                    [2] = Player.PlayerData.charinfo.lastname
                }
            }
            MySQL.update('UPDATE lapraces SET records = ? WHERE raceid = ?',
                { json.encode(Races[RaceData.RaceId].Records), RaceData.RaceId })
            TriggerClientEvent('qb-phone:client:RaceNotify', src, 'You have won the WR from ' .. RaceData.RaceName ..
                ' disconnected with a time of: ' .. SecondsToClock(BLap) .. '!')
        end
    else
        Races[RaceData.RaceId].Records = {
            Time = BLap,
            Holder = {
                [1] = Player.PlayerData.charinfo.firstname,
                [2] = Player.PlayerData.charinfo.lastname
            }
        }
        MySQL.update('UPDATE lapraces SET records = ? WHERE raceid = ?',
            { json.encode(Races[RaceData.RaceId].Records), RaceData.RaceId })
        TriggerClientEvent('qb-phone:client:RaceNotify', src, 'You have won the WR from ' .. RaceData.RaceName ..
            ' put down with a time of: ' .. SecondsToClock(BLap) .. '!')
    end
    AvailableRaces[AvailableKey].RaceData = Races[RaceData.RaceId]
    TriggerClientEvent('qb-lapraces:client:PlayerFinishs', -1, RaceData.RaceId, PlayersFinished, Player)
    if PlayersFinished == AmountOfRacers then
        if NotFinished ~= nil and next(NotFinished) ~= nil and NotFinished[RaceData.RaceId] ~= nil and
            next(NotFinished[RaceData.RaceId]) ~= nil then
            for _, v in pairs(NotFinished[RaceData.RaceId]) do
                LastRaces[RaceData.RaceId][#LastRaces[RaceData.RaceId] + 1] = {
                    TotalTime = v.TotalTime,
                    BestLap = v.BestLap,
                    Holder = {
                        [1] = v.Holder[1],
                        [2] = v.Holder[2]
                    }
                }
            end
        end
        Races[RaceData.RaceId].LastLeaderboard = LastRaces[RaceData.RaceId]
        Races[RaceData.RaceId].Racers = {}
        Races[RaceData.RaceId].Started = false
        Races[RaceData.RaceId].Waiting = false
        table.remove(AvailableRaces, AvailableKey)
        LastRaces[RaceData.RaceId] = nil
        NotFinished[RaceData.RaceId] = nil
    end
    TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
end)

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

RegisterNetEvent('qb-lapraces:server:UpdateRacerData', function(RaceId, Checkpoint, Lap, Finished)
    local src = source
    local Player, racer = RacerOf(src, RaceId)
    if not Player or not Races[RaceId].Started then return end
    Checkpoint, Lap = tonumber(Checkpoint), tonumber(Lap)
    if not Checkpoint or not Lap or Checkpoint < 0 or Checkpoint > MAX_CHECKPOINTS or Lap < 0 or Lap > MAX_LAPS + 1 then return end

    racer.Checkpoint = math.floor(Checkpoint)
    racer.Lap = math.floor(Lap)
    racer.Finished = Finished == true

    TriggerClientEvent('qb-lapraces:client:UpdateRaceRacerData', -1, RaceId, Races[RaceId])
end)

RegisterNetEvent('qb-lapraces:server:StartRace', function(RaceId)
    local src = source
    local MyPlayer = exports['pfm-core']:GetPlayer(src)
    if not MyPlayer then return end
    local AvailableKey = GetOpenedRaceKey(RaceId)

    if RaceId ~= nil and AvailableKey ~= nil then
        if AvailableRaces[AvailableKey].SetupCitizenId == MyPlayer.PlayerData.citizenid then
            if AvailableRaces[AvailableKey].RaceData.Started then return end
            AvailableRaces[AvailableKey].RaceData.Started = true
            AvailableRaces[AvailableKey].RaceData.Waiting = false
            AvailableRaces[AvailableKey].RaceData.StartedAt = os.time()
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
    local distance = tonumber(RaceData.RaceDistance)
    if not distance or distance ~= distance or distance < 0 or distance > 1e6 then return end
    RaceData.RaceDistance = distance
    local RaceId = GenerateRaceId()
    local Checkpoints = {}
    for k, v in ipairs(RaceData.Checkpoints) do
        if type(v) ~= 'table' or type(v.coords) ~= 'table' then return end
        Checkpoints[k] = {
            offset = v.offset,
            coords = v.coords
        }
    end
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
