local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local ActiveMission = 0
local MissionPlayer = nil  -- source of the player who accepted the current mission
-- The current mission: { id, spawn (Config.VehicleSpawn index), truck (net id), truckAt }. The payout
-- needs the mission's own truck, the player at it, and time for the guards and the bomb; it used to be
-- claimable the moment the mission was accepted.
local Mission = nil
local missionCounter = 0
local MIN_TRUCK_TO_LOOT = (Config.TimeToBlow or 30) + 15
local LOOT_RANGE = 8.0
local RewardCooldowns = {} -- per-player cooldown to prevent rapid re-triggering

RegisterServerEvent('AttackTransport:akceptujto', function()
	local copsOnDuty = 0
	local _source = source
	local xPlayer = exports['pfm-core']:GetPlayer(_source)
	if not xPlayer then return end
	local accountMoney = xPlayer.PlayerData.money['bank']
	if ActiveMission == 0 then
		if accountMoney < Config.ActivationCost then
			TriggerClientEvent('QBCore:Notify', _source, 'You need ' .. Config.Currency .. '' .. Config.ActivationCost .. ' in the bank to accept the mission')
		else
			for _, v in pairs(QBCore.Functions.GetPlayers()) do
				local Player = exports['pfm-core']:GetPlayer(v)
				if Player ~= nil then
					if (Player.PlayerData.job.name == 'police' or Player.PlayerData.job.type == 'leo') and Player.PlayerData.job.onduty then
						copsOnDuty = copsOnDuty + 1
					end
				end
			end
			if copsOnDuty >= Config.ActivePolice then
				if not PFPayout.Charge(xPlayer, 'bank', Config.ActivationCost, { key = ('pfm-truckrobbery:activate:%s:%s'):format(xPlayer.PlayerData.citizenid, PFPayout.NewId()), kind = 'fee', reason = 'Armored truck job' }) then return end
				missionCounter = missionCounter + 1
				Mission = { id = missionCounter, spawn = math.random(1, #Config.VehicleSpawn) }
				MissionPlayer = _source
				TriggerClientEvent('AttackTransport:Pozwolwykonac', _source, Mission.spawn)
				OdpalTimer(Mission.id)
			else
				TriggerClientEvent('QBCore:Notify', _source, 'Need at least ' .. Config.ActivePolice .. ' police to activate the mission.')
			end
		end
	else
		TriggerClientEvent('QBCore:Notify', _source, 'Someone is already carrying out this mission')
	end
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
	local truck = Mission.truck and NetworkGetEntityFromNetworkId(Mission.truck)
	if truck and truck ~= 0 and DoesEntityExist(truck) then return GetEntityCoords(truck) end
	return GetEntityCoords(GetPlayerPed(src))
end

RegisterServerEvent('qb-armoredtruckheist:server:callCops', function(streetLabel)
	local c = MissionAlertCoords(source, 'callCops')
	if not c then return end
	-- plain text only: the label is shown in every officer's alert UI
	streetLabel = tostring(streetLabel or ''):gsub('[<>]', ''):sub(1, 60)
	TriggerClientEvent('qb-armoredtruckheist:client:robberyCall', -1, streetLabel, vector3(c.x, c.y, c.z))
end)

function OdpalTimer(id)
	ActiveMission = 1
	Wait(Config.ResetTimer * 1000)
	-- only reset the mission this timer belongs to (an older timer used to end a newer mission early)
	if not Mission or Mission.id ~= id then return end
	ActiveMission = 0
	MissionPlayer = nil
	Mission = nil
	TriggerClientEvent('AttackTransport:CleanUp', -1)
end

-- The mission player reports the armored truck it spawned at the server-chosen point.
RegisterNetEvent('AttackTransport:truckSpawned', function(netId)
	local src = source
	if not Mission or MissionPlayer ~= src or Mission.truck then return end
	local truck = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
	if not truck or truck == 0 or not DoesEntityExist(truck) then return end
	if (GetEntityModel(truck) & 0xFFFFFFFF) ~= (joaat('stockade') & 0xFFFFFFFF) then return end
	local spawn = Config.VehicleSpawn[Mission.spawn]
	if #(GetEntityCoords(truck) - vector3(spawn.x, spawn.y, spawn.z)) > 30.0 then return end
	Mission.truck = tonumber(netId)
	Mission.truckAt = os.time()
end)

RegisterServerEvent('AttackTransport:zawiadompsy', function()
	local c = MissionAlertCoords(source, 'zawiadompsy')
	if not c then return end
	TriggerClientEvent('AttackTransport:InfoForLspd', -1, c.x, c.y, c.z)
end)

RegisterServerEvent('AttackTransport:graczZrobilnapad', function(lootTime)
	local _source = source

	-- Must be an active mission
	if ActiveMission ~= 1 then
		print('[qb-truckrobbery] Reward rejected for source ' .. _source .. ': no active mission')
		return
	end

	-- Must be the player who accepted the mission
	if MissionPlayer ~= _source then
		print('[qb-truckrobbery] Reward rejected for source ' .. _source .. ': did not start the mission')
		return
	end

	-- lootTime must be a positive number (client sends elapsed milliseconds)
	if type(lootTime) ~= 'number' or lootTime <= 0 then
		print('[qb-truckrobbery] Reward rejected for source ' .. _source .. ': invalid lootTime (' .. tostring(lootTime) .. ')')
		return
	end

	-- The mission's truck must exist, the player must be at it, and the attack must have had time
	local now = os.time()
	if not Mission or not Mission.truck or now - Mission.truckAt < MIN_TRUCK_TO_LOOT then return end
	local truck = NetworkGetEntityFromNetworkId(Mission.truck)
	if not truck or truck == 0 or not DoesEntityExist(truck) then return end
	if #(GetEntityCoords(GetPlayerPed(_source)) - GetEntityCoords(truck)) > LOOT_RANGE then return end

	-- Per-player cooldown: prevent duplicate reward calls within the mission window
	if RewardCooldowns[_source] and now - RewardCooldowns[_source] < Config.ResetTimer then
		print('[qb-truckrobbery] Reward rejected for source ' .. _source .. ': cooldown active')
		return
	end
	RewardCooldowns[_source] = now

	local xPlayer = exports['pfm-core']:GetPlayer(_source)
	if not xPlayer then return end

	local bags = math.random(1, 3)
	local info = {
		worth = math.random(Config.Payout.Min, Config.Payout.Max)
	}
	exports['pfm-inventory']:AddItem(_source, 'markedbills', bags, false, info, 'AttackTransport:graczZrobilnapad')
	TriggerClientEvent('qb-inventory:client:ItemBox', _source, sharedItems['markedbills'], 'add')

	local chance = math.random(1, 100)
	TriggerClientEvent('QBCore:Notify', _source, 'You took ' .. bags .. ' bags of cash from the van')

	if chance >= 95 then
		exports['pfm-inventory']:AddItem(_source, 'security_card_01', 1, false, false, 'AttackTransport:graczZrobilnapad')
		TriggerClientEvent('qb-inventory:client:ItemBox', _source, sharedItems['security_card_01'], 'add')
	end

	-- Mission is now complete; reset state so a new mission can start
	ActiveMission = 0
	MissionPlayer = nil
	Mission = nil
	Wait(2500)
end)
