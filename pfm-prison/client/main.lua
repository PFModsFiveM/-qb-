QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
inJail = false
jailTime = 0
currentJob = nil
-- true while the sentence is a pf-justice order: the time shown comes from pf-justice's own push
-- (pf-justice:client:Sentence); otherwise from this prison's server (the old runtime)
local justiceClock = false
CellsBlip = nil
TimeBlip = nil
ShopBlip = nil
local insidecanteen = false
local insidefreedom = false
local canteen_ped = 0
local freedom_ped = 0
local freedom
local canteen
-- the cell the server assigned (pfm-prison:client:Housing, batch 19D): where Enter places the inmate
local assignedCell = nil -- { id, block, coords = vector4 }
local enteredAt = 0

-- Functions

--- This will create the blips for the cells, time check and shop
--- @return nil
local function CreateCellsBlip()
	if CellsBlip then
		RemoveBlip(CellsBlip)
	end
	CellsBlip = AddBlipForCoord(Config.Locations['yard'].x, Config.Locations['yard'].y, Config.Locations['yard'].z)

	SetBlipSprite(CellsBlip, 238)
	SetBlipDisplay(CellsBlip, 4)
	SetBlipScale(CellsBlip, 0.8)
	SetBlipAsShortRange(CellsBlip, true)
	SetBlipColour(CellsBlip, 4)
	BeginTextCommandSetBlipName('STRING')
	AddTextComponentSubstringPlayerName(Lang:t('info.cells_blip'))
	EndTextCommandSetBlipName(CellsBlip)

	if TimeBlip then
		RemoveBlip(TimeBlip)
	end
	TimeBlip = AddBlipForCoord(Config.Locations['freedom'].x, Config.Locations['freedom'].y, Config.Locations['freedom'].z)

	SetBlipSprite(TimeBlip, 466)
	SetBlipDisplay(TimeBlip, 4)
	SetBlipScale(TimeBlip, 0.8)
	SetBlipAsShortRange(TimeBlip, true)
	SetBlipColour(TimeBlip, 4)
	BeginTextCommandSetBlipName('STRING')
	AddTextComponentSubstringPlayerName(Lang:t('info.freedom_blip'))
	EndTextCommandSetBlipName(TimeBlip)
end

-- Add clothes to prisioner

local function ApplyClothes()
	local playerPed = PlayerPedId()
	if DoesEntityExist(playerPed) then
		Citizen.CreateThread(function()
			SetPedArmour(playerPed, 0)
			ClearPedBloodDamage(playerPed)
			ResetPedVisibleDamage(playerPed)
			ClearPedLastWeaponDamage(playerPed)
			ResetPedMovementClipset(playerPed, 0)
			local gender = QBCore.Functions.GetPlayerData().charinfo.gender
			if gender == 0 then
				TriggerEvent('qb-clothing:client:loadOutfit', Config.Uniforms.male)
			else
				TriggerEvent('qb-clothing:client:loadOutfit', Config.Uniforms.female)
			end
		end)
	end
end


-- Events

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
	-- the server decides whether this character is serving here and sends the cell (metadata injail
	-- also counts station holding cells once pf-justice owns sentences, so it is not read here)
	TriggerServerEvent('prison:server:RequestState', true)

	QBCore.Functions.TriggerCallback('prison:server:IsAlarmActive', function(active)
		if active then
			TriggerEvent('prison:client:JailAlarm', true)
		end
	end)

	if DoesEntityExist(canteen_ped) or DoesEntityExist(freedom_ped) then return end

	local pedModel = `s_m_m_armoured_01`

	RequestModel(pedModel)
	while not HasModelLoaded(pedModel) do
		Wait(0)
	end

	freedom_ped = CreatePed(0, pedModel, Config.Locations['freedom'].x, Config.Locations['freedom'].y, Config.Locations['freedom'].z, Config.Locations['freedom'].w, false, true)
	FreezeEntityPosition(freedom_ped, true)
	SetEntityInvincible(freedom_ped, true)
	SetBlockingOfNonTemporaryEvents(freedom_ped, true)
	TaskStartScenarioInPlace(freedom_ped, 'WORLD_HUMAN_CLIPBOARD', 0, true)

	if not Config.UseTarget then return end

	exports['pfm-target']:AddTargetEntity(freedom_ped, {
		options = {
			{
				type = 'client',
				event = 'prison:client:Leave',
				icon = 'fas fa-clipboard',
				label = Lang:t('info.target_freedom_option'),
				canInteract = function()
					return inJail
				end
			}
		},
		distance = 2.5,
	})
end)

AddEventHandler('onResourceStart', function(resource)
	if resource ~= GetCurrentResourceName() then return end
	Wait(100)
	if LocalPlayer.state['isLoggedIn'] then
		TriggerServerEvent('prison:server:RequestState', true)
	end

	QBCore.Functions.TriggerCallback('prison:server:IsAlarmActive', function(active)
		if not active then return end
		TriggerEvent('prison:client:JailAlarm', true)
	end)

	if DoesEntityExist(canteen_ped) or DoesEntityExist(freedom_ped) then return end

	local pedModel = `s_m_m_armoured_01`

	RequestModel(pedModel)
	while not HasModelLoaded(pedModel) do
		Wait(0)
	end

	freedom_ped = CreatePed(0, pedModel, Config.Locations['freedom'].x, Config.Locations['freedom'].y, Config.Locations['freedom'].z, Config.Locations['freedom'].w, false, true)
	FreezeEntityPosition(freedom_ped, true)
	SetEntityInvincible(freedom_ped, true)
	SetBlockingOfNonTemporaryEvents(freedom_ped, true)
	TaskStartScenarioInPlace(freedom_ped, 'WORLD_HUMAN_CLIPBOARD', 0, true)

	if not Config.UseTarget then return end

	exports['pfm-target']:AddTargetEntity(freedom_ped, {
		options = {
			{
				type = 'client',
				event = 'prison:client:Leave',
				icon = 'fas fa-clipboard',
				label = Lang:t('info.target_freedom_option'),
				canInteract = function()
					return inJail
				end
			}
		},
		distance = 2.5,
	})
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
	assignedCell = nil
	inJail = false
	jailTime = 0
	currentJob = nil
	justiceClock = false
	RemoveBlip(currentBlip)
end)

local function ClearPrisonBlips()
	RemoveBlip(currentBlip)
	RemoveBlip(CellsBlip)
	CellsBlip = nil
	RemoveBlip(TimeBlip)
	TimeBlip = nil
	RemoveBlip(ShopBlip)
	ShopBlip = nil
end

-- Taken to a cell. Sent by the server (jailed, brought back, a login). Another resource on this
-- client (a respawn in the prison infirmary) only asks the server, which sends the cell when the
-- character is serving here. It only shows the sentence: the server (or pf-justice) keeps the time.
local EnterAllowed = { ['pfm-policejob'] = true, ['pf-ambulancejob'] = true, ['qb-policejob'] = true, ['qb-ambulancejob'] = true }
RegisterNetEvent('prison:client:Enter', function(time, job, location, returned, justice)
	local invokingResource = GetInvokingResource()
	if invokingResource and invokingResource ~= GetCurrentResourceName() then
		if EnterAllowed[invokingResource] then TriggerServerEvent('prison:server:RequestState', true) end
		return
	end
	time = tonumber(time) or 0
	if time <= 0 then return end
	local firstEntry = not inJail
	justiceClock = justice == true

	if not returned then
		QBCore.Functions.Notify(Lang:t('error.injail', { Time = time }), 'error')
		if firstEntry then
			TriggerEvent('chat:addMessage', {
				color = { 3, 132, 252 },
				multiline = true,
				args = { 'SYSTEM', Lang:t('info.seized_property') }
			})
		end
	end
	DoScreenFadeOut(500)
	while not IsScreenFadedOut() do
		Wait(10)
	end
	-- the assigned cell when the server sent one, else a spawn point (the old runtime has no cells)
	local spot = assignedCell and assignedCell.coords or Config.Locations.spawns[math.random(1, #Config.Locations.spawns)].coords
	SetEntityCoords(PlayerPedId(), spot.x, spot.y, spot.z - 0.9, 0, 0, 0, false)
	SetEntityHeading(PlayerPedId(), spot.w)
	enteredAt = GetGameTimer()
	Wait(500)

	inJail = true
	jailTime = time
	if job and Config.Locations.jobs[job] and tonumber(location) then
		currentJob, currentLocation = job, tonumber(location)
	end
	if currentJob and Config.Locations.jobs[currentJob] then
		CreateJobBlip(true)
	else
		TriggerServerEvent('prison:server:RequestState')
	end
	if firstEntry then
		ApplyClothes()
		TriggerServerEvent('InteractSound_SV:PlayOnSource', 'jail', 0.5)
	end
	CreateCellsBlip()
	Wait(2000)
	DoScreenFadeIn(1000)
	if firstEntry and currentJob then
		QBCore.Functions.Notify(Lang:t('error.do_some_work', { currentjob = Config.Jobs[currentJob] }), 'error')
	end
end)

-- The server's job spot and time left.
RegisterNetEvent('prison:client:SetJob', function(job, location, left)
	if job and Config.Locations.jobs[job] and tonumber(location) then
		currentJob, currentLocation = job, tonumber(location)
		if inJail then CreateJobBlip(true) end
	end
	if tonumber(left) then jailTime = tonumber(left) end
end)

RegisterNetEvent('prison:client:UpdateTime', function(left)
	if tonumber(left) then jailTime = tonumber(left) end
end)

-- pf-justice's own push to the inmate on each whole-minute change (display only)
RegisterNetEvent('pf-justice:client:Sentence', function(summary)
	if not inJail or not justiceClock then return end
	if type(summary) == 'table' and tonumber(summary.minutes) then jailTime = tonumber(summary.minutes) end
end)

-- The desk: the time left is the server's; a served sentence is released by the server.
RegisterNetEvent('prison:client:Leave', function()
	if jailTime > 0 then
		QBCore.Functions.Notify(Lang:t('info.timeleft', { JAILTIME = jailTime }))
	end
	TriggerServerEvent('prison:server:RequestState')
end)

-- Released by the server (time served, unjailed): the belongings are back; out of the gate.
RegisterNetEvent('prison:client:Released', function()
	assignedCell = nil
	local wasInJail = inJail
	jailTime = 0
	inJail = false
	currentJob = nil
	justiceClock = false
	ClearPrisonBlips()
	TriggerEvent('chat:addMessage', {
		color = { 3, 132, 252 },
		multiline = true,
		args = { 'SYSTEM', Lang:t('info.received_property') }
	})
	QBCore.Functions.Notify(Lang:t('success.free_'))
	if not wasInJail then return end
	DoScreenFadeOut(500)
	while not IsScreenFadedOut() do
		Wait(10)
	end
	TriggerServerEvent('qb-clothes:loadPlayerSkin')
	SetEntityCoords(PlayerPedId(), Config.Locations['outside'].x, Config.Locations['outside'].y, Config.Locations['outside'].z, false, false, false, false)
	SetEntityHeading(PlayerPedId(), Config.Locations['outside'].w)
	Wait(500)
	DoScreenFadeIn(1000)
end)

-- The server saw a real escape (through a hacked gate). Old runtime: the sentence ended and the
-- belongings are lost. pf-justice: the sentence is suspended and the belongings stay in the locker.
RegisterNetEvent('prison:client:Escaped', function(info)
	inJail = false
	jailTime = 0
	currentJob = nil
	justiceClock = false
	ClearPrisonBlips()
	local suspended = type(info) == 'table' and info.suspended == true
	QBCore.Functions.Notify(Lang:t(suspended and 'error.escaped_suspended' or 'error.escaped'), 'error')
end)

-- Threads

CreateThread(function()
	TriggerEvent('prison:client:JailAlarm', false)
end)

CreateThread(function()
	if not Config.UseTarget then
		freedom = BoxZone:Create(vector3(Config.Locations['freedom'].x, Config.Locations['freedom'].y, Config.Locations['freedom'].z), 2.75, 2.75, {
			name = 'freedom',
			debugPoly = false,
		})
		freedom:onPlayerInOut(function(isPointInside)
			insidefreedom = isPointInside
			if isPointInside then
				CreateThread(function()
					while insidefreedom do
						if IsControlJustReleased(0, 38) then
							exports['pfm-core']:KeyPressed()
							exports['pfm-core']:HideText()
							TriggerEvent('prison:client:Leave')
							break
						end
						Wait(0)
					end
				end)
				exports['pfm-core']:DrawText('[E] Check Time', 'left')
			else
				exports['pfm-core']:HideText()
			end
		end)
	end
end)

-- ── housing and routine (batch 19D server/facility.lua, schedule.lua) ──────────────────────────
-- Display only: the server decides the cell and the routine; positions are still the server's.

-- plain text for the notification (no markup can come through a label)
local function plain(v, max)
	if type(v) ~= 'string' then return '' end
	return (v:gsub('[%c<>&"\']', ''):sub(1, max or 64))
end

local function validCellCoords(c)
	if type(c) ~= 'table' then return nil end
	local x, y, z, w = tonumber(c.x), tonumber(c.y), tonumber(c.z), tonumber(c.w) or 0.0
	if not x or not y or not z or x ~= x or y ~= y or z ~= z then return nil end
	local m = Config.Locations['middle']
	local radius = (Config.Prison and tonumber(Config.Prison.InsideRadius)) or 200.0
	-- a cell is inside the walls; anything else is ignored
	if #(vector2(x, y) - vector2(m.x, m.y)) > radius then return nil end
	return vector4(x, y, z, w)
end

-- payload { cellId, block, classification, coords = { x, y, z, w } }
RegisterNetEvent('pfm-prison:client:Housing', function(data)
	local invoker = GetInvokingResource()
	if invoker and invoker ~= GetCurrentResourceName() then return end
	if type(data) ~= 'table' then return end
	local coords = validCellCoords(data.coords)
	if not coords then return end
	assignedCell = { id = plain(data.cellId, 16), block = plain(data.block, 8), coords = coords }
	-- housed right after being taken in (Enter came first): walk them to the cell now
	if inJail and GetGameTimer() - enteredAt < 15000 then
		SetEntityCoords(PlayerPedId(), coords.x, coords.y, coords.z - 0.9, 0, 0, 0, false)
		SetEntityHeading(PlayerPedId(), coords.w)
	end
end)

local PHASES = { count = true, meal = true, work = true, yard = true, lockin = true, lock_in = true }
local STATUS = { intake = 'Intake', in_cell = 'In your cell', yard = 'Yard', work = 'Work', meal = 'Meal', infirmary = 'Infirmary',
	visitation = 'Visitation', solitary = 'Solitary', transfer = 'Hospital transfer' }

-- payload { phase, label, endsAt, status }: one line when the inmate's routine status changes
RegisterNetEvent('pfm-prison:client:Routine', function(data)
	local invoker = GetInvokingResource()
	if invoker and invoker ~= GetCurrentResourceName() then return end
	if type(data) ~= 'table' or not inJail then return end
	local label = plain(data.label, 48)
	if label == '' and PHASES[data.phase] then label = data.phase end
	local status = STATUS[data.status] or ''
	local text = label ~= '' and ('Routine: ' .. label) or 'Routine'
	if status ~= '' then text = text .. ' - ' .. status end
	local endsAt, nowAt = tonumber(data.endsAt), GetCloudTimeAsInt and GetCloudTimeAsInt() or nil
	if endsAt and nowAt and endsAt > nowAt then
		text = text .. (' (%d min)'):format(math.ceil((endsAt - nowAt) / 60))
	end
	QBCore.Functions.Notify(text, 'primary', 6000)
end)
