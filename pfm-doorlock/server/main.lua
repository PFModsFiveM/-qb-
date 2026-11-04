local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })

-- Functions

local function showWarning(msg)
	print(('^3%s: %s^0'):format(Lang:t('general.warning'), msg))
end

local function removeItem(Player, item)
	if Config.Consumables[item.name] then
		Player.RemoveItem(item.name, item.amount >= Config.Consumables[item.name] and Config.Consumables[item.name] or 1)
	end
end

local function checkAndRemoveItem(Player, item, shouldRemove)
	if not item then return false end
	if shouldRemove then
		removeItem(Player, item)
	end
	return true
end

local function checkItems(Player, items, needsAll, shouldRemove)
	if needsAll == nil then needsAll = true end
	local isTable = type(items) == 'table'
	local isArray = isTable and table.type(items) == 'array' or false
	local totalItems = 0
	local count = 0
	if isTable then for _ in pairs(items) do totalItems += 1 end else totalItems = #items end
	local kvIndex
	if isArray then kvIndex = 2 else kvIndex = 1 end
	if isTable then
		for k, v in pairs(items) do
			local itemKV = { k, v }
			local item = Player.GetItemByName(itemKV[kvIndex])
			if needsAll then
				if checkAndRemoveItem(Player, item, false) then
					count += 1
				end
			else
				if checkAndRemoveItem(Player, item, shouldRemove) then
					return true
				end
			end
		end
		if count == totalItems then
			for k, v in pairs(items) do
				local itemKV = { k, v }
				local item = Player.GetItemByName(itemKV[kvIndex])
				checkAndRemoveItem(Player, item, shouldRemove)
			end
			return true
		end
	else -- Single item as string
		local item = Player.GetItemByName(items)
		return checkAndRemoveItem(Player, item, shouldRemove)
	end
	return false
end

local function isAuthorized(Player, door, usedLockpick)
	if door.allAuthorized then return true end

	if Config.AdminAccess and QBCore.Functions.HasPermission(Player.PlayerData.source, Config.AdminPermission) then
		if Config.Warnings then
			showWarning(Lang:t('general.warn_admin_privilege_used', { player = Player.PlayerData.name, license = Player.PlayerData.license }))
		end
		return true
	end

	if (door.pickable or door.lockpick) and usedLockpick then return true end

	if door.authorizedJobs then
		if door.authorizedJobs[Player.PlayerData.job.name] and Player.PlayerData.job.grade.level >= door.authorizedJobs[Player.PlayerData.job.name] then
			return true
		elseif type(door.authorizedJobs[1]) == 'string' then
			for _, job in pairs(door.authorizedJobs) do -- Support for old format
				if job == Player.PlayerData.job.name then return true end
			end
		end
	end

	if door.authorizedGangs then
		if door.authorizedGangs[Player.PlayerData.gang.name] and Player.PlayerData.gang.grade.level >= door.authorizedGangs[Player.PlayerData.gang.name] then
			return true
		elseif type(door.authorizedGangs[1]) == 'string' then
			for _, gang in pairs(door.authorizedGangs) do -- Support for old format
				if gang == Player.PlayerData.gang.name then return true end
			end
		end
	end

	if door.authorizedCitizenIDs then
		if door.authorizedCitizenIDs[Player.PlayerData.citizenid] then
			return true
		elseif type(door.authorizedCitizenIDs[1]) == 'string' then
			for _, id in pairs(door.authorizedCitizenIDs) do -- Support for old format
				if id == Player.PlayerData.citizenid then return true end
			end
		end
	end

	if door.items then return checkItems(Player, door.items, door.needsAllItems, true) end

	return false
end

local function SaveDoorStates()
	SaveResourceFile(GetCurrentResourceName(), './saves/doorstates.json', json.encode(Config.DoorStates), -1)
end

local function LoadDoorStates()
	local DoorStates = LoadResourceFile(GetCurrentResourceName(), './saves/doorstates.json')
	if DoorStates then
		DoorStates = json.decode(DoorStates)
		if not next(DoorStates) then return end

		for key, isLocked in pairs(DoorStates) do
			if Config.DoorList[key] ~= nil then
				Config.DoorList[key].locked = isLocked
			end
		end
		Config.DoorStates = DoorStates
	end
end

-- Callbacks

QBCore.Functions.CreateCallback('qb-doorlock:server:setupDoors', function(_, cb)
	cb(Config.DoorList)
end)

QBCore.Functions.CreateCallback('qb-doorlock:server:checkItems', function(source, cb, items, needsAll)
	local Player = exports['pfm-core']:GetPlayer(source)
	if not Player or (type(items) ~= 'table' and type(items) ~= 'string') then return cb(false) end
	cb(checkItems(Player, items, needsAll, false))
end)

-- Events

-- Door access granted by server scripts (e.g. a hack finished on the server): [src] = { [doorID] = expiry }
local doorGrants = {}

--- Lets one player unlock one door once, within `ms` (default 60 s), from beside it.
local function GrantDoorAccess(playerId, doorID, ms)
	playerId = tonumber(playerId)
	if not playerId or Config.DoorList[doorID] == nil then return false end
	doorGrants[playerId] = doorGrants[playerId] or {}
	doorGrants[playerId][doorID] = GetGameTimer() + (tonumber(ms) or 60000)
	return true
end
exports('GrantDoorAccess', GrantDoorAccess)

local function useDoorGrant(playerId, doorID)
	local grants = doorGrants[playerId]
	local expiry = grants and grants[doorID]
	if not expiry then return false end
	grants[doorID] = nil
	return GetGameTimer() <= expiry
end

-- Lockpick attempts (startPick / finishPick below): [src] = { doorID, at, challengeId, item }
local pickAttempts = {}
local lastPickStart = {}  -- [src] = GetGameTimer()

AddEventHandler('playerDropped', function()
	doorGrants[source] = nil
	pickAttempts[source] = nil
	lastPickStart[source] = nil
end)

local function doorCoords(door)
	local c = door.objCoords or (door.doors and door.doors[1] and door.doors[1].objCoords)
	if type(c) ~= 'table' and type(c) ~= 'vector3' then return nil end
	return vector3(c.x, c.y, c.z)
end

local function nearDoor(playerId, door)
	local c = doorCoords(door)
	if not c then return false end
	local doorDistance = tonumber(door.distance) or Config.FallbackDistance or 3.0
	local reach = math.max(doorDistance, 2.0) + 3.0
	if door.remoteTrigger then -- aimed at from up to RemoteTriggerDistance away
		reach = math.max(doorDistance, Config.RemoteTriggerMinDistance or 5.0) + (Config.RemoteTriggerDistance or 15.0) + 5.0
	end
	return #(GetEntityCoords(GetPlayerPed(playerId)) - c) <= reach
end

local function holds(Player, item)
	return item ~= nil and Player.GetItemByName(item) ~= nil
end

--- Sets a door's state and tells every client (also schedules the door's auto lock).
local function setDoorState(playerId, doorID, locked, src, enableSounds, enableAnimation)
	Config.DoorList[doorID].locked = locked
	if Config.DoorStates[doorID] == nil then Config.DoorStates[doorID] = locked elseif Config.DoorStates[doorID] ~= locked then Config.DoorStates[doorID] = nil end
	TriggerClientEvent('qb-doorlock:client:setState', -1, playerId, doorID, locked, src or false, enableSounds, enableAnimation)

	if not Config.DoorList[doorID].autoLock then return end
	SetTimeout(Config.DoorList[doorID].autoLock, function()
		if Config.DoorList[doorID].locked then return end
		Config.DoorList[doorID].locked = true
		if Config.DoorStates[doorID] == nil then Config.DoorStates[doorID] = locked elseif Config.DoorStates[doorID] ~= locked then Config.DoorStates[doorID] = nil end
		TriggerClientEvent('qb-doorlock:client:setState', -1, playerId, doorID, true, src or false, enableSounds, enableAnimation)
	end)
end

-- ── server-only door state (batch 15H) ──────────────────────────────────────────────────────────
-- SetDoorState / GetDoorState let server resources lock and unlock doors without an online player
-- (updateState's server path needs one as sentSource, so a gate could not be relocked with nobody
-- online). Only resources in Config.StateCallers may set a state; reads follow Config.StateReaders.
-- A door is named by its Config.DoorList key or by a Config.DoorAliases name.

local MAX_REASON = 128
local callerWarnedAt = {} -- [resource] = GetGameTimer() of its last refusal line

local function callerAllowed(list, invoker)
	if invoker == nil or invoker == '' or invoker == GetCurrentResourceName() then return true end
	if list == '*' then return true end
	return type(list) == 'table' and list[invoker] == true
end

local function refuseCaller(exportName, invoker)
	local now = GetGameTimer()
	local last = callerWarnedAt[invoker]
	if last and now - last < 60000 then return end
	callerWarnedAt[invoker] = now
	print(('^3[pfm-doorlock]^7 %s refused for resource %s (not in its caller list)'):format(exportName, tostring(invoker)))
end

-- [alias] = door key, resolved once from the alias coordinates (see Config.DoorAliases)
local aliasCache = {}

local function resolveAlias(name)
	if aliasCache[name] ~= nil and Config.DoorList[aliasCache[name]] then return aliasCache[name] end
	local at = (Config.DoorAliases or {})[name]
	if type(at) ~= 'table' and type(at) ~= 'vector3' then return nil end
	local target = vector3(at.x, at.y, at.z)
	local radius = tonumber(Config.DoorAliasRadius) or 1.0
	local best, bestDist
	for key, door in pairs(Config.DoorList) do
		local c = doorCoords(door)
		if c then
			local d = #(c - target)
			if d <= radius and (not bestDist or d < bestDist) then best, bestDist = key, d end
		end
	end
	aliasCache[name] = best
	return best
end

--- The Config.DoorList key for a door id, a numeric string of one, or an alias; nil when unknown.
local function resolveDoorId(doorId)
	if type(doorId) == 'number' then
		if doorId ~= doorId or doorId == math.huge or doorId == -math.huge then return nil end
		return Config.DoorList[doorId] ~= nil and doorId or nil
	end
	if type(doorId) ~= 'string' or doorId == '' or #doorId > 64 then return nil end
	if Config.DoorList[doorId] ~= nil then return doorId end
	local n = math.tointeger(tonumber(doorId))
	if n and Config.DoorList[n] ~= nil then return n end
	return resolveAlias(doorId)
end

local function cleanReason(reason)
	if type(reason) ~= 'string' then return nil end
	reason = reason:gsub('%c', ' '):match('^%s*(.-)%s*$')
	if reason == '' then return nil end
	return reason:sub(1, MAX_REASON)
end

--- Locks or unlocks a door for everyone. opts = { reason, sound = false to play no sound }.
--- Returns { ok = true, doorId, locked, changed } or { ok = false, error, message }.
local function SetDoorState(doorId, locked, opts)
	local invoker = GetInvokingResource()
	if not callerAllowed(Config.StateCallers, invoker) then
		refuseCaller('SetDoorState', invoker)
		return { ok = false, error = 'not_allowed', message = 'This resource may not set door states' }
	end
	if type(locked) ~= 'boolean' then
		return { ok = false, error = 'bad_args', message = 'locked must be true or false' }
	end
	opts = type(opts) == 'table' and opts or {}
	local id = resolveDoorId(doorId)
	if id == nil then return { ok = false, error = 'not_found', message = 'No such door' } end
	local door = Config.DoorList[id]
	if (door.locked == true) == locked then
		return { ok = true, doorId = id, locked = locked, changed = false }
	end
	-- no player: server id 0 plays no animation on anyone; the door itself plays its sound
	setDoorState(0, id, locked, false, opts.sound ~= false, false)
	print(('[pfm-doorlock] %s %s door %s%s'):format(invoker or GetCurrentResourceName(), locked and 'locked' or 'unlocked',
		tostring(id), cleanReason(opts.reason) and (' (' .. cleanReason(opts.reason) .. ')') or ''))
	return { ok = true, doorId = id, locked = locked, changed = true }
end
exports('SetDoorState', SetDoorState)

--- True (locked), false (unlocked) or nil (unknown door, or a caller not allowed to read).
local function GetDoorState(doorId)
	local invoker = GetInvokingResource()
	if not callerAllowed(Config.StateReaders, invoker) then
		refuseCaller('GetDoorState', invoker)
		return nil
	end
	local id = resolveDoorId(doorId)
	if id == nil then return nil end
	return Config.DoorList[id].locked == true
end
exports('GetDoorState', GetDoorState)

PFDoorlock = { SetDoorState = SetDoorState, GetDoorState = GetDoorState, ResolveDoorId = resolveDoorId }

RegisterNetEvent('qb-doorlock:server:updateState', function(doorID, locked, src, usedLockpick, unlockAnyway, enableSounds, enableAnimation, sentSource)
	local fromClient = tonumber(source) ~= nil and tonumber(source) > 0
	-- A client acts only as itself, from beside the door. `unlockAnyway` from a client needs a grant from
	-- a server script. `usedLockpick` from a client counts for nothing: a lockpick opens a door only
	-- through a finished attempt (startPick / finishPick below). (A client could name another player's
	-- id as sentSource and use their access, pass unlockAnyway and open any door from anywhere, or pass
	-- usedLockpick and open or lock any pickable bank gate with no minigame.)
	local playerId = fromClient and tonumber(source) or (sentSource or source)
	local Player = exports['pfm-core']:GetPlayer(playerId)
	if not Player then return end
	if fromClient then
		local door = Config.DoorList[doorID]
		if not door or not nearDoor(playerId, door) then return end
		if unlockAnyway then
			unlockAnyway = locked == false and useDoorGrant(playerId, doorID)
		end
		usedLockpick = false
	end
	if type(doorID) ~= 'number' and type(doorID) ~= 'string' then
		if Config.Warnings then
			showWarning((Lang:t('general.warn_wrong_doorid_type', { player = Player.PlayerData.name, license = Player.PlayerData.license, doorID = doorID })))
		end
		return
	end

	if type(locked) ~= 'boolean' then
		if Config.Warnings then
			showWarning((Lang:t('general.warn_wrong_state', { player = Player.PlayerData.name, license = Player.PlayerData.license, state = locked })))
		end
		return
	end

	if not Config.DoorList[doorID] then
		if Config.Warnings then
			showWarning(Lang:t('general.warn_wrong_doorid', { player = Player.PlayerData.name, license = Player.PlayerData.license, doorID = doorID }))
		end
		return
	end

	if not unlockAnyway and not isAuthorized(Player, Config.DoorList[doorID], usedLockpick) then
		if Config.Warnings then
			showWarning(Lang:t('general.warn_no_authorisation', { player = Player.PlayerData.name, license = Player.PlayerData.license, doorID = doorID }))
		end
		return
	end

	setDoorState(playerId, doorID, locked, src, enableSounds, enableAnimation)
end)

-- Lockpicking a pickable door. startPick: the player is at a locked pickable door with a lockpick;
-- the server records the attempt and hands the client a skillbar challenge (pfm-minigames).
-- finishPick: the door opens only when that challenge passed, in time, with the player still at
-- the door holding the pick. A failed or abandoned attempt rolls the pick's breakage here.
local sharedItems
local function itemInfo(name)
	sharedItems = sharedItems or exports['pfm-core']:GetShared('Items') or {}
	return sharedItems[name]
end

local function pickItem(Player, wantAdvanced)
	if wantAdvanced and holds(Player, 'advancedlockpick') then return 'advancedlockpick' end
	if holds(Player, 'lockpick') then return 'lockpick' end
	if holds(Player, 'advancedlockpick') then return 'advancedlockpick' end
	return nil
end

local function cancelChallenge(src, id)
	pcall(function() exports['pfm-minigames']:Cancel(src, id) end)
end

--- A failed attempt: the pick may break (Config.LockpickBreakChance), removed on the server.
local function failPick(src, attempt)
	cancelChallenge(src, attempt.challengeId)
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player or not holds(Player, attempt.item) then return end
	local chance = (Config.LockpickBreakChance or {})[attempt.item] or 0
	if math.random(1, 100) > chance then return end
	if Player.RemoveItem(attempt.item, 1) then
		TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo(attempt.item), 'remove')
	end
end

local function pickMaxMs() return (Config.LockpickMaxSeconds or 60) * 1000 end

RegisterNetEvent('qb-doorlock:server:startPick', function(doorID, wantAdvanced)
	local src = source
	if type(doorID) ~= 'number' and type(doorID) ~= 'string' then return end
	local door = Config.DoorList[doorID]
	if not door or not (door.pickable or door.lockpick) or not door.locked then return end
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player or not nearDoor(src, door) then return end
	local meta = Player.PlayerData.metadata or {}
	if meta.isdead or meta.inlaststand or meta.ishandcuffed then return end
	local now = GetGameTimer()
	if lastPickStart[src] and now - lastPickStart[src] < (Config.LockpickCooldownSeconds or 2) * 1000 then return end
	local item = pickItem(Player, wantAdvanced == true)
	if not item then return end
	lastPickStart[src] = now

	-- a new attempt ends the open one as failed (it cannot be restarted to dodge the breakage)
	if pickAttempts[src] then
		local old = pickAttempts[src]
		pickAttempts[src] = nil
		failPick(src, old)
	end

	local ok, challenge = pcall(function()
		return exports['pfm-minigames']:IssueChallenge(src, 'skillbar', {
			difficulty = item == 'advancedlockpick' and 'easy' or 'medium', tag = 'doorlock:' .. tostring(doorID),
		})
	end)
	if not ok or type(challenge) ~= 'table' or type(challenge.id) ~= 'string' then return end

	local attempt = { doorID = doorID, at = now, challengeId = challenge.id, item = item }
	pickAttempts[src] = attempt
	SetTimeout(pickMaxMs() + 1000, function()
		if pickAttempts[src] ~= attempt then return end
		pickAttempts[src] = nil
		failPick(src, attempt)
	end)
	TriggerClientEvent('qb-doorlock:client:pickChallenge', src, doorID, challenge)
end)

RegisterNetEvent('qb-doorlock:server:finishPick', function(doorID)
	local src = source
	local attempt = pickAttempts[src]
	if not attempt or attempt.doorID ~= doorID then return end
	pickAttempts[src] = nil -- one finish per attempt

	local ok, passed = pcall(function() return exports['pfm-minigames']:Verify(src, attempt.challengeId) end)
	passed = ok and passed == true
	local elapsed = GetGameTimer() - attempt.at
	local door = Config.DoorList[doorID]
	local Player = exports['pfm-core']:GetPlayer(src)
	if not door or not Player then return end
	if not door.locked then return end -- opened meanwhile by someone else: nothing to pick
	local inTime = elapsed >= (Config.LockpickMinSeconds or 2) * 1000 and elapsed <= pickMaxMs()
	if passed and inTime and nearDoor(src, door) and holds(Player, attempt.item) then
		setDoorState(src, doorID, false, false)
		return
	end
	failPick(src, attempt)
end)

RegisterNetEvent('qb-doorlock:server:saveNewDoor', function(data, doubleDoor)
	local src = source
	if not QBCore.Functions.HasPermission(src, Config.CommandPermission) and not IsPlayerAceAllowed(src, 'command') then
		if Config.Warnings then
			showWarning(Lang:t('general.warn_no_permission_newdoor', { player = GetPlayerName(src), license = QBCore.Functions.GetIdentifier(src, 'license'), source = src }))
		end
		return
	end
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return end
	local configData = {}
	local jobs, jobGrade, gangs, gangGrade, cids, items, doorType, identifier
	if data.job then
		jobGrade = tonumber(data.jobGrade) or 0
		configData.authorizedJobs = { [data.job] = jobGrade }
		jobs = "['" .. data.job .. "'] = " .. jobGrade
	end
	if data.gang then
		gangGrade = tonumber(data.gangGrade) or 0
		configData.authorizedGangs = { [data.gang] = gangGrade }
		gangs = "['" .. data.gang .. "'] = " .. gangGrade
	end
	if data.cid then
		configData.authorizedCitizenIDs = { [data.cid] = true }
		cids = "['" .. data.cid .. "'] = true"
	end
	if data.item then
		configData.items = { [data.item] = 1 }
		items = "['" .. data.item .. "'] = 1"
	end
	configData.locked = data.locked
	configData.pickable = data.pickable
	configData.cantUnlock = data.cantunlock
	configData.hideLabel = data.hidelabel
	configData.distance = data.distance
	configData.doorType = data.doortype
	configData.doorRate = 1.0
	configData.doorLabel = data.doorlabel
	doorType = "'" .. data.doortype .. "'"
	identifier = data.configfile .. '-' .. data.dooridentifier
	if doubleDoor then
		configData.doors = {
			{ objName = data.model[1], objYaw = data.heading[1], objCoords = data.coords[1] },
			{ objName = data.model[2], objYaw = data.heading[2], objCoords = data.coords[2] }
		}
	else
		configData.objName = data.model
		configData.objYaw = data.heading
		configData.objCoords = data.coords
		configData.fixText = false
	end

	local path = GetResourcePath(GetCurrentResourceName())

	if data.configfile then
		local tempfile, err = io.open(path:gsub('//', '/') .. '/configs/' .. string.gsub(data.configfile, '.lua', '') .. '.lua', 'a+')
		if tempfile then
			tempfile:close()
			path = path:gsub('//', '/') .. '/configs/' .. string.gsub(data.configfile, '.lua', '') .. '.lua'
		else
			return error(err)
		end
	else
		path = path:gsub('//', '/') .. '/config.lua'
	end

	local file = io.open(path, 'a+')
	local label = '\n\n-- ' .. data.dooridentifier .. ' ' .. Lang:t('general.created_by') .. ' ' .. Player.PlayerData.name .. "\nConfig.DoorList['" .. identifier .. "'] = {"
	file:write(label)
	for k, v in pairs(configData) do
		if k == 'authorizedJobs' or k == 'authorizedGangs' or k == 'authorizedCitizenIDs' or k == 'items' then
			local auth = jobs
			if k == 'authorizedGangs' then
				auth = gangs
			elseif k == 'authorizedCitizenIDs' then
				auth = cids
			elseif k == 'items' then
				auth = items
			end
			local str = ('\n    %s = { %s },'):format(k, auth)
			file:write(str)
		elseif k == 'doors' then
			local doors = {}
			for i = 1, 2 do
				doors[i] = ('    {objName = %s, objYaw = %s, objCoords = %s}'):format(configData.doors[i].objName, configData.doors[i].objYaw, configData.doors[i].objCoords)
			end
			local str = ('\n    %s = {\n    %s,\n    %s\n    },'):format(k, doors[1], doors[2])
			file:write(str)
		elseif k == 'doorType' then
			local str = ('\n    %s = %s,'):format(k, doorType)
			file:write(str)
		elseif k == 'doorLabel' then
			local str = ("\n    %s = '%s',"):format(k, v)
			file:write(str)
		else
			local str = ('\n    %s = %s,'):format(k, v)
			file:write(str)
		end
	end
	file:write('\n}')
	file:close()

	Config.DoorList[identifier] = configData
	TriggerClientEvent('qb-doorlock:client:newDoorAdded', -1, configData, identifier, src)
end)

AddEventHandler('onResourceStart', function(resource)
	if GetCurrentResourceName() == resource and Config.PersistentDoorStates then
		CreateThread(function()
			LoadDoorStates()
			Wait(1000)
			while true do
				Wait(Config.PersistentSaveInternal)
				SaveDoorStates()
			end
		end)
	end
end)

AddEventHandler('onResourceStop', function(resource)
	if GetCurrentResourceName() == resource and Config.PersistentDoorStates then
		SaveDoorStates()
	end
end)

RegisterNetEvent('txAdmin:events:scheduledRestart', function(eventData)
	if tonumber(source) and tonumber(source) > 0 then return end -- txAdmin only, not clients
	if type(eventData) ~= 'table' then return end
	if eventData.secondsRemaining == 60 then
		CreateThread(function()
			Wait(45000)
			SaveDoorStates()
		end)
	else
		SaveDoorStates()
	end
end)

-- Kept for old clients and does nothing: the pick's breakage is rolled on the server when an
-- attempt fails (failPick). (A client that never sent this kept its lockpick forever.)
RegisterNetEvent('qb-doorlock:server:removeLockpick', function() end)

-- Commands

QBCore.Commands.Add('newdoor', Lang:t('general.newdoor_command_description'), {}, false, function(source)
	TriggerClientEvent('qb-doorlock:client:addNewDoor', source)
end, Config.CommandPermission)

QBCore.Commands.Add('doordebug', Lang:t('general.doordebug_command_description'), {}, false, function(source)
	TriggerClientEvent('qb-doorlock:client:ToggleDoorDebug', source)
end, Config.CommandPermission)
