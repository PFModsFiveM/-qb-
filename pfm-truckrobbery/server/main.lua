local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local ActiveMission = 0
local MissionPlayer = nil  -- source of the player who accepted the current mission
-- The current mission, all decided here: { id, pending (fee not settled yet), cid, spawn
-- (Config.VehicleSpawn index), truck, guards, entities (server-spawned handles), truckAt, plantedAt }.
-- The server spawns the truck and its guards, plants the charge only when every guard is dead, the
-- truck has stopped and the robber is at its back doors, and pays only after the charge went off.
-- (The client used to spawn them, and nothing checked the guards or the bomb.)
local Mission = nil
local missionCounter = 0
local LOOT_RANGE = 8.0
local REAR_OFFSET, REAR_RANGE = 3.6, 3.5 -- the back doors are about 3.6 m behind the truck's centre
local STOPPED_SPEED = 1.0                -- m/s
local DEAD_HEALTH = 100                  -- GTA peds die at 100 health or less (dead ones read 0)
local GUARD_SEATS = { -1, 0, 1 }
local SETTLE_RETRY_MS, SETTLE_TRIES = 15000, 20 -- an unclear fee is asked again under its own key
local FOLLOW_RETRY_MS, FOLLOW_TRIES = 60000, 120 -- after the job is freed: once a minute for two hours
local RewardCooldowns = {} -- per-player cooldown to prevent rapid re-triggering

local function Notify(src, text, kind)
	TriggerClientEvent('QBCore:Notify', src, text, kind)
end

local function DeleteEntities(list)
	for _, e in ipairs(list or {}) do
		if e and e ~= 0 and DoesEntityExist(e) then DeleteEntity(e) end
	end
end

-- Ends the mission `id` (if it is still the current one) and frees the job for the next crew.
local function EndMission(id, keepEntitiesMs)
	if not Mission or Mission.id ~= id then return end
	local entities = Mission.entities
	ActiveMission = 0
	MissionPlayer = nil
	Mission = nil
	if keepEntitiesMs then
		SetTimeout(keepEntitiesMs, function() DeleteEntities(entities) end)
	else
		DeleteEntities(entities)
	end
end

local function CopsOnDuty()
	local copsOnDuty = 0
	for _, v in pairs(QBCore.Functions.GetPlayers()) do
		local Player = exports['pfm-core']:GetPlayer(v)
		if Player ~= nil then
			if (Player.PlayerData.job.name == 'police' or Player.PlayerData.job.type == 'leo') and Player.PlayerData.job.onduty then
				copsOnDuty = copsOnDuty + 1
			end
		end
	end
	return copsOnDuty
end

local function StartMission(src, id)
	if not Mission or Mission.id ~= id then return end
	Mission.pending = nil
	Mission.spawn = math.random(1, #Config.VehicleSpawn)
	TriggerClientEvent('AttackTransport:Pozwolwykonac', src, Mission.spawn)
	-- the mission ends after Config.ResetTimer whatever happened (only this mission: an older timer
	-- never ends a newer one)
	SetTimeout(Config.ResetTimer * 1000, function()
		if not Mission or Mission.id ~= id then return end
		EndMission(id)
		TriggerClientEvent('AttackTransport:CleanUp', -1)
	end)
end

-- The activation fee, through the ledger under one key per mission. A clear refusal frees the job; an
-- unclear result keeps it locked and asks the same key again until it settles (never a new key).
-- An activation fee that was still unsettled when the job was freed: asked again under the SAME key
-- (the ledger answers with the key's final result once it settles) and refunded if it turns out paid,
-- since the mission it paid for no longer runs.
local function FollowUnsettledFee(cid, key, tries)
	SetTimeout(FOLLOW_RETRY_MS, function()
		local account, res = PFPayout.Charge(cid, 'bank', Config.ActivationCost, { key = key, kind = 'fee', reason = 'Armored truck job', quiet = true })
		if account then
			PFPayout.Pay(cid, 'bank', Config.ActivationCost, { key = key .. ':refund', reason = 'Armored truck job cancelled', quiet = true })
			return
		end
		local outage = type(res) == 'table' and (res.error == 'bank_unavailable' or res.error == 'ledger_unavailable')
		if not outage and PFPayout.IsClearFailure(res) then return end -- nothing was taken
		if tries < FOLLOW_TRIES then return FollowUnsettledFee(cid, key, tries + 1) end
		print(('^1[pfm-truckrobbery]^7 activation fee %s for %s never settled; check the ledger journal'):format(key, cid))
	end)
end

local function ChargeActivation(src, id, key, tries)
	if not Mission or Mission.id ~= id then return end
	local cid = Mission.cid
	local account, res = PFPayout.Charge(cid, 'bank', Config.ActivationCost, { key = key, kind = 'fee', reason = 'Armored truck job', quiet = tries > 0 })
	if not Mission or Mission.id ~= id then
		-- the job ended while this call waited: a fee taken now goes back
		if account then PFPayout.Pay(cid, 'bank', Config.ActivationCost, { key = key .. ':refund', reason = 'Armored truck job cancelled', quiet = true }) end
		return
	end
	if account then
		if GetPlayerName(src) and MissionPlayer == src then return StartMission(src, id) end
		-- paid, but the player left while it settled: the fee goes back (stable key, paid once)
		PFPayout.Pay(cid, 'bank', Config.ActivationCost, { key = key .. ':refund', reason = 'Armored truck job cancelled' })
		return EndMission(id)
	end
	-- on a retry, a bank that does not answer says nothing about this key (its first answer was unclear)
	local outage = type(res) == 'table' and (res.error == 'bank_unavailable' or res.error == 'ledger_unavailable')
	if PFPayout.IsClearFailure(res) and not (tries > 0 and outage) then return EndMission(id) end
	if tries >= SETTLE_TRIES then
		print(('[pfm-truckrobbery] activation fee %s still unsettled; the job is freed and the fee is followed (refunded if it settles paid)'):format(key))
		EndMission(id)
		return FollowUnsettledFee(cid, key, 0)
	end
	SetTimeout(SETTLE_RETRY_MS, function() ChargeActivation(src, id, key, tries + 1) end)
end

RegisterServerEvent('AttackTransport:akceptujto', function()
	local _source = source
	local xPlayer = exports['pfm-core']:GetPlayer(_source)
	if not xPlayer then return end
	if ActiveMission ~= 0 then
		return Notify(_source, 'Someone is already carrying out this mission')
	end
	if xPlayer.PlayerData.money['bank'] < Config.ActivationCost then
		return Notify(_source, 'You need ' .. Config.Currency .. '' .. Config.ActivationCost .. ' in the bank to accept the mission')
	end
	if CopsOnDuty() < Config.ActivePolice then
		return Notify(_source, 'Need at least ' .. Config.ActivePolice .. ' police to activate the mission.')
	end
	-- the job is locked before the ledger wait: a second accept (another player, or a double tap) is
	-- turned away instead of paying for a mission that then overwrites the first
	ActiveMission = 1
	missionCounter = missionCounter + 1
	local id = missionCounter
	Mission = { id = id, pending = true, cid = xPlayer.PlayerData.citizenid }
	MissionPlayer = _source
	local key = ('pfm-truckrobbery:activate:%s:%s'):format(xPlayer.PlayerData.citizenid, PFPayout.NewId())
	ChargeActivation(_source, id, key, 0)
end)

-- The mission player nears the spawn point: the server spawns the armored truck and its armed guards
-- there and keeps their handles; the client gets the network ids to drive the guards' AI.
RegisterNetEvent('AttackTransport:requestTruck', function()
	local src = source
	if ActiveMission ~= 1 or not Mission or Mission.pending or MissionPlayer ~= src then return end
	if Mission.truck or Mission.spawning then return end
	local spawn = Config.VehicleSpawn[Mission.spawn]
	local at = vector3(spawn.x, spawn.y, spawn.z)
	if #(GetEntityCoords(GetPlayerPed(src)) - at) > (Config.SpawnDistance or 250.0) then return end
	local m = Mission
	m.spawning = true
	local truck = CreateVehicleServerSetter(Config.TruckModel, 'automobile', at.x, at.y, at.z, 52.0)
	for _ = 1, 100 do
		if truck and truck ~= 0 and DoesEntityExist(truck) then break end
		Wait(10)
	end
	m.spawning = nil
	if Mission ~= m then return DeleteEntities({ truck }) end -- the mission ended meanwhile
	if not truck or truck == 0 or not DoesEntityExist(truck) then return end
	m.truck, m.entities, m.guards = truck, { truck }, {}
	local guardNets = {}
	for _, seat in ipairs(GUARD_SEATS) do
		local ped = CreatePedInsideVehicle(truck, 26, Config.GuardModel, seat, true, false)
		if ped and ped ~= 0 then
			m.guards[#m.guards + 1] = ped
			m.entities[#m.entities + 1] = ped
			GiveWeaponToPed(ped, seat == -1 and Config.DriverWeap or Config.NavWeap, 250, false, true)
			guardNets[#guardNets + 1] = NetworkGetNetworkIdFromEntity(ped)
		end
	end
	m.truckAt = os.time()
	TriggerClientEvent('AttackTransport:truckReady', src, NetworkGetNetworkIdFromEntity(truck), guardNets)
end)

-- Police alerts come only from the player on the current mission, at most every 30 s, placed at the
-- mission truck (or the player), never at a client-chosen spot. They used to relay any client's text
-- and coordinates to every player.
local alertCooldowns = {} -- [eventName] = os.time()

local function MissionAlertCoords(src, eventName)
	if ActiveMission ~= 1 or not Mission or MissionPlayer ~= src then return nil end
	local now = os.time()
	if alertCooldowns[eventName] and now - alertCooldowns[eventName] < 30 then return nil end
	alertCooldowns[eventName] = now
	local truck = Mission.truck
	if truck and truck ~= 0 and DoesEntityExist(truck) then return GetEntityCoords(truck) end
	return GetEntityCoords(GetPlayerPed(src))
end

-- City events (pf-services): one 'crime.robbery.truck' per mission, at the server's position of the
-- mission truck. Raised when the guards spot the robber (the mission player's own alert, checked by
-- MissionAlertCoords) and, if that alert never came, when the cash is taken: a robber who skips the
-- client alert is still reported. (police = true: pf-services also opens a police dispatch request.)
local function CityEvent(kind, data, opts)
	if GetResourceState('pf-services') ~= 'started' then return nil end
	local svc = exports['pf-services']
	if not svc then return nil end
	local ok, id = pcall(function() return svc:Emit(kind, data, opts) end)
	return ok and id or nil
end

local function ReportTruckRobbery(coords)
	if not Mission or Mission.reported or not coords then return end
	Mission.reported = true
	CityEvent('crime.robbery.truck', { location = 'Armored cash transport', place = 'Armored cash transport', ref = 'robbery:truck:' .. tostring(Mission.id),
		details = 'Armored truck under attack' }, {
		title = 'Armored truck attacked', coords = vector3(coords.x, coords.y, coords.z), dedupe = 'mission:' .. tostring(Mission.id),
	})
end

RegisterServerEvent('qb-armoredtruckheist:server:callCops', function(streetLabel)
	local c = MissionAlertCoords(source, 'callCops')
	if not c then return end
	-- plain text only: the label is shown in every officer's alert UI
	streetLabel = tostring(streetLabel or ''):gsub('[<>]', ''):sub(1, 60)
	TriggerClientEvent('qb-armoredtruckheist:client:robberyCall', -1, streetLabel, vector3(c.x, c.y, c.z))
end)

-- The robber plants the charge on the back doors. Checked here: every guard dead (or gone), the truck
-- stopped, the robber at its back, and (Config.ChargeItem) the charge used up. The loot opens
-- Config.TimeToBlow after this.
RegisterNetEvent('AttackTransport:plantBomb', function()
	local src = source
	if ActiveMission ~= 1 or not Mission or Mission.pending or MissionPlayer ~= src then return end
	local truck = Mission.truck
	if Mission.plantedAt or not truck or not DoesEntityExist(truck) then return end
	for _, ped in ipairs(Mission.guards or {}) do
		if DoesEntityExist(ped) and GetEntityHealth(ped) > DEAD_HEALTH then
			return Notify(src, 'Get rid of the guards before you place the bomb.', 'error')
		end
	end
	local v = GetEntityVelocity(truck)
	if v and #(vector3(v.x, v.y, v.z)) > STOPPED_SPEED then
		return Notify(src, 'You can not rob a vehicle that is moving.', 'error')
	end
	local tc = GetEntityCoords(truck)
	local h = math.rad(GetEntityHeading(truck) or 0.0)
	local rear = vector3(tc.x + math.sin(h) * REAR_OFFSET, tc.y - math.cos(h) * REAR_OFFSET, tc.z)
	if #(GetEntityCoords(GetPlayerPed(src)) - rear) > REAR_RANGE then
		return Notify(src, 'Stand at the back doors to place the charge.', 'error')
	end
	if Config.ChargeItem then
		if not exports['pfm-inventory']:RemoveItem(src, Config.ChargeItem, 1, false, 'AttackTransport:plantBomb') then
			return Notify(src, 'You need something to blow the doors with.', 'error')
		end
		TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[Config.ChargeItem], 'remove')
	end
	Mission.plantedAt = os.time()
	ReportTruckRobbery(tc)
	TriggerClientEvent('AttackTransport:bombPlanted', src, Config.TimeToBlow)
end)

RegisterServerEvent('AttackTransport:zawiadompsy', function()
	local c = MissionAlertCoords(source, 'zawiadompsy')
	if not c then return end
	TriggerClientEvent('AttackTransport:InfoForLspd', -1, c.x, c.y, c.z)
	ReportTruckRobbery(c)
end)

RegisterServerEvent('AttackTransport:graczZrobilnapad', function()
	local _source = source

	-- Must be the active mission of the player who accepted it
	if ActiveMission ~= 1 or not Mission or Mission.pending or MissionPlayer ~= _source then return end

	-- The charge must have been planted (server-checked) and gone off, and the player must be at the truck
	local now = os.time()
	if not Mission.plantedAt or now - Mission.plantedAt < (Config.TimeToBlow or 30) then return end
	local truck = Mission.truck
	if not truck or truck == 0 or not DoesEntityExist(truck) then return end
	if #(GetEntityCoords(GetPlayerPed(_source)) - GetEntityCoords(truck)) > LOOT_RANGE then return end
	ReportTruckRobbery(GetEntityCoords(truck))

	-- Per-player cooldown: prevent duplicate reward calls within the mission window
	if RewardCooldowns[_source] and now - RewardCooldowns[_source] < Config.ResetTimer then return end

	local xPlayer = exports['pfm-core']:GetPlayer(_source)
	if not xPlayer then return end
	RewardCooldowns[_source] = now
	-- Mission is complete: the job is free again; the wreck and the bodies go a minute later
	EndMission(Mission.id, 60000)

	local bags = math.random(1, 3)
	local info = {
		worth = math.random(Config.Payout.Min, Config.Payout.Max)
	}
	exports['pfm-inventory']:AddItem(_source, 'markedbills', bags, false, info, 'AttackTransport:graczZrobilnapad')
	TriggerClientEvent('qb-inventory:client:ItemBox', _source, sharedItems['markedbills'], 'add')
	TriggerClientEvent('QBCore:Notify', _source, 'You took ' .. bags .. ' bags of cash from the van')

	if math.random(1, 100) >= 95 then
		exports['pfm-inventory']:AddItem(_source, 'security_card_01', 1, false, false, 'AttackTransport:graczZrobilnapad')
		TriggerClientEvent('qb-inventory:client:ItemBox', _source, sharedItems['security_card_01'], 'add')
	end
end)

-- The mission player leaving ends a running mission (a pending fee settles on its own above).
AddEventHandler('playerDropped', function()
	local src = source
	RewardCooldowns[src] = nil
	if Mission and not Mission.pending and MissionPlayer == src then
		EndMission(Mission.id)
		TriggerClientEvent('AttackTransport:CleanUp', -1)
	end
end)

AddEventHandler('onResourceStop', function(resource)
	if resource ~= GetCurrentResourceName() or not Mission then return end
	DeleteEntities(Mission.entities)
end)
