local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })

-- Get Employees (the staff rules are in sv_boss.lua, shared with the boss menu and the Boss app)
local M = PFManagement

QBCore.Functions.CreateCallback('qb-gangmenu:server:GetEmployees', function(source, cb)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return cb({}) end

	if not Player.PlayerData.gang.isboss then
		ExploitBan(src, 'GetEmployees Exploiting')
		return
	end

	local employees = {}
	for _, m in ipairs(M.ListMembers(src, 'gang') or {}) do
		employees[#employees + 1] = {
			empSource = m.citizenid,
			grade = m.grade,
			isboss = m.isboss,
			name = (m.online and '🟢 ' or '❌ ') .. m.name,
		}
	end
	cb(employees)
end)

RegisterNetEvent('qb-gangmenu:server:stash', function()
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return end
	local playerGang = Player.PlayerData.gang
	if not playerGang.isboss then return end
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	if not Config.GangMenus[playerGang.name] then return end
	local bossCoords = Config.GangMenus[playerGang.name]
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 2.5 then
			local stashName = 'boss_' .. playerGang.name
			exports['pfm-inventory']:OpenInventory(src, stashName, {
				maxweight = 4000000,
				slots = 25,
			})
			return
		end
	end
end)

-- Grade Change
local GRADE_MESSAGES = {
	not_member = 'You cannot change this rank!', outranks_you = 'You cannot change this rank!',
	cannot_change_self = 'You cannot change your own rank!', grade_above_yours = 'You cannot promote to this rank!',
	unknown_grade = 'Grade does not exist.', bad_grade = 'Grade does not exist.',
}

RegisterNetEvent('qb-gangmenu:server:GradeUpdate', function(data)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return end

	if not Player.PlayerData.gang.isboss then
		ExploitBan(src, 'GradeUpdate Exploiting')
		return
	end
	if type(data) ~= 'table' or type(data.cid) ~= 'string' then return end
	local grade = tonumber(data.grade)
	if not grade or grade < 0 or grade % 1 ~= 0 then return end
	local ok, err = M.SetGrade(src, 'gang', data.cid, grade)
	if not ok then
		TriggerClientEvent('QBCore:Notify', src, GRADE_MESSAGES[err] or 'Error.', 'error')
		if err ~= 'unknown_grade' then return end
	else
		TriggerClientEvent('QBCore:Notify', src, 'Successfully promoted!', 'success')
	end
	TriggerClientEvent('qb-gangmenu:client:OpenMenu', src)
end)

-- Fire Member
local FIRE_MESSAGES = {
	not_member = 'You cannot fire this citizen!', outranks_you = 'You cannot fire this citizen!',
	cannot_fire_self = 'You can\'t kick yourself out of the gang!', failed = 'Error.',
}

RegisterNetEvent('qb-gangmenu:server:FireMember', function(target)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player or type(target) ~= 'string' then return end

	if not Player.PlayerData.gang.isboss then
		ExploitBan(src, 'FireEmployee Exploiting')
		return
	end

	local ok, err = M.Fire(src, 'gang', target)
	if ok then
		TriggerClientEvent('QBCore:Notify', src, 'Gang Member fired!', 'success')
	elseif FIRE_MESSAGES[err] then
		TriggerClientEvent('QBCore:Notify', src, FIRE_MESSAGES[err], 'error')
		if err == 'not_member' then return end
	end
	TriggerClientEvent('qb-gangmenu:client:OpenMenu', src)
end)

-- Recruit Player
RegisterNetEvent('qb-gangmenu:server:HireMember', function(recruit)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return end

	if not Player.PlayerData.gang.isboss then
		ExploitBan(src, 'HireEmployee Exploiting')
		return
	end
	local ok, res = M.Hire(src, 'gang', recruit)
	local Target, err = ok and res or nil, not ok and res or nil
	if err == 'too_far' then return end
	if ok then
		TriggerClientEvent('QBCore:Notify', src, 'You hired ' .. M.FullName(Target) .. ' come ' .. Player.PlayerData.gang.label .. '', 'success')
		TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, 'You have been hired as ' .. Player.PlayerData.gang.label .. '', 'success')
	elseif err == 'already_member' then
		TriggerClientEvent('QBCore:Notify', src, 'This citizen is already in the gang', 'error')
	end
	TriggerClientEvent('qb-gangmenu:client:OpenMenu', src)
end)

-- Get closest player sv
QBCore.Functions.CreateCallback('qb-gangmenu:getplayers', function(source, cb)
	local src = source
	local players = {}
	local Boss = exports['pfm-core']:GetPlayer(src)
	if not Boss or not Boss.PlayerData.gang.isboss then return cb(players) end
	local PlayerPed = GetPlayerPed(src)
	local pCoords = GetEntityCoords(PlayerPed)
	for _, v in pairs(QBCore.Functions.GetPlayers()) do
		local targetped = GetPlayerPed(v)
		local tCoords = GetEntityCoords(targetped)
		local dist = #(pCoords - tCoords)
		local ped = exports['pfm-core']:GetPlayer(v)
		if PlayerPed ~= targetped and dist < 10 and ped then
			players[#players + 1] = {
				id = v,
				coords = GetEntityCoords(targetped),
				name = ped.PlayerData.charinfo.firstname .. ' ' .. ped.PlayerData.charinfo.lastname,
				citizenid = ped.PlayerData.citizenid,
				sources = GetPlayerPed(ped.PlayerData.source),
				sourceplayer = ped.PlayerData.source
			}
		end
	end
	table.sort(players, function(a, b)
		return a.name < b.name
	end)
	cb(players)
end)
