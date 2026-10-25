local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })

function ExploitBan(id, reason)
	MySQL.insert('INSERT INTO bans (name, license, discord, ip, reason, expire, bannedby) VALUES (?, ?, ?, ?, ?, ?, ?)', {
		GetPlayerName(id),
		QBCore.Functions.GetIdentifier(id, 'license'),
		QBCore.Functions.GetIdentifier(id, 'discord'),
		QBCore.Functions.GetIdentifier(id, 'ip'),
		reason,
		2147483647,
		'qb-management'
	})
	TriggerEvent('qb-log:server:CreateLog', 'bans', 'Player Banned', 'red', string.format('%s was banned by %s for %s', GetPlayerName(id), 'qb-management', reason), true)
	DropPlayer(id, 'You were permanently banned by the server for: Exploiting')
end

-- Get Employees
-- Boss and target must be in the same job.
local function SameJob(Player, Employee)
	return Employee and Employee.PlayerData.job and Employee.PlayerData.job.name == Player.PlayerData.job.name
end

QBCore.Functions.CreateCallback('qb-bossmenu:server:GetEmployees', function(source, cb)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return cb({}) end

	if not Player.PlayerData.job.isboss then
		ExploitBan(src, 'GetEmployees Exploiting')
		return
	end

	local employees = {}

	-- always the boss's own job (the client-sent name was pasted into the SQL)
	local jobname = Player.PlayerData.job.name
	local players = MySQL.query.await('SELECT * FROM `players` WHERE `job` LIKE ?', { '%' .. jobname .. '%' })

	if players[1] ~= nil then
		for _, value in pairs(players) do
			local Target = QBCore.Functions.GetPlayerByCitizenId(value.citizenid) or QBCore.Functions.GetOfflinePlayerByCitizenId(value.citizenid)

			if Target and Target.PlayerData.job.name == jobname then
				local isOnline = Target.PlayerData.source
				employees[#employees + 1] = {
					empSource = Target.PlayerData.citizenid,
					grade = Target.PlayerData.job.grade,
					isboss = Target.PlayerData.job.isboss,
					name = (isOnline and '🟢 ' or '❌ ') .. Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname
				}
			end
		end
		table.sort(employees, function(a, b)
			return a.grade.level > b.grade.level
		end)
	end
	cb(employees)
end)

RegisterNetEvent('qb-bossmenu:server:stash', function()
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return end
	local playerJob = Player.PlayerData.job
	if not playerJob.isboss then return end
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	if not Config.BossMenus[playerJob.name] then return end
	local bossCoords = Config.BossMenus[playerJob.name]
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 2.5 then
			local stashName = 'boss_' .. playerJob.name
			exports['pfm-inventory']:OpenInventory(src, stashName, {
				maxweight = 4000000,
				slots = 25,
			})
			return
		end
	end
end)

-- Grade Change
RegisterNetEvent('qb-bossmenu:server:GradeUpdate', function(data)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return end

	if not Player.PlayerData.job.isboss then
		ExploitBan(src, 'GradeUpdate Exploiting')
		return
	end
	if type(data) ~= 'table' or type(data.cid) ~= 'string' then return end
	data.grade = tonumber(data.grade)
	if not data.grade or data.grade < 0 or data.grade % 1 ~= 0 then return end
	local Employee = QBCore.Functions.GetPlayerByCitizenId(data.cid) or QBCore.Functions.GetOfflinePlayerByCitizenId(data.cid)
	-- only members of the boss's own job, and not someone ranked above the boss
	if not SameJob(Player, Employee) or Employee.PlayerData.job.grade.level > Player.PlayerData.job.grade.level then
		TriggerClientEvent('QBCore:Notify', src, 'You cannot change this rank!', 'error')
		return
	end
	if data.grade > Player.PlayerData.job.grade.level then
		TriggerClientEvent('QBCore:Notify', src, 'You cannot promote to this rank!', 'error')
		return
	end

	if Employee then
		if Employee.Functions.SetJob(Player.PlayerData.job.name, data.grade) then
			TriggerClientEvent('QBCore:Notify', src, 'Sucessfully promoted!', 'success')
			Employee.Functions.Save()

			if Employee.PlayerData.source then -- Player is online
				TriggerClientEvent('QBCore:Notify', Employee.PlayerData.source, 'You have been promoted to ' .. tostring(Employee.PlayerData.job.grade.name or data.grade) .. '.', 'success')
			end
		else
			TriggerClientEvent('QBCore:Notify', src, 'Promotion grade does not exist.', 'error')
		end
	end
	TriggerClientEvent('qb-bossmenu:client:OpenMenu', src)
end)

-- Fire Employee
RegisterNetEvent('qb-bossmenu:server:FireEmployee', function(target)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player or type(target) ~= 'string' then return end

	if not Player.PlayerData.job.isboss then
		ExploitBan(src, 'FireEmployee Exploiting')
		return
	end

	local Employee = QBCore.Functions.GetPlayerByCitizenId(target) or QBCore.Functions.GetOfflinePlayerByCitizenId(target)
	-- any citizenid used to be accepted, firing people out of other jobs
	if Employee and not SameJob(Player, Employee) then
		TriggerClientEvent('QBCore:Notify', src, 'You cannot fire this citizen!', 'error')
		return
	end
	if Employee then
		if target == Player.PlayerData.citizenid then
			TriggerClientEvent('QBCore:Notify', src, 'You can\'t fire yourself', 'error')
			return
		elseif Employee.PlayerData.job.grade.level > Player.PlayerData.job.grade.level then
			TriggerClientEvent('QBCore:Notify', src, 'You cannot fire this citizen!', 'error')
			return
		end
		if Employee.Functions.SetJob('unemployed', '0') then
			Employee.Functions.Save()
			TriggerClientEvent('QBCore:Notify', src, 'Employee fired!', 'success')
			TriggerEvent('qb-log:server:CreateLog', 'bossmenu', 'Job Fire', 'red', Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname .. ' successfully fired ' .. Employee.PlayerData.charinfo.firstname .. ' ' .. Employee.PlayerData.charinfo.lastname .. ' (' .. Player.PlayerData.job.name .. ')', false)

			if Employee.PlayerData.source then -- Player is online
				TriggerClientEvent('QBCore:Notify', Employee.PlayerData.source, 'You have been fired! Good luck.', 'error')
			end
		else
			TriggerClientEvent('QBCore:Notify', src, 'Error..', 'error')
		end
	end
	TriggerClientEvent('qb-bossmenu:client:OpenMenu', src)
end)

-- Recruit Player
RegisterNetEvent('qb-bossmenu:server:HireEmployee', function(recruit)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return end
	local Target = exports['pfm-core']:GetPlayer(tonumber(recruit))

	if not Player.PlayerData.job.isboss then
		ExploitBan(src, 'HireEmployee Exploiting')
		return
	end
	-- same 10 m as the hire list (anyone on the server could be hired from anywhere)
	if Target and #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(Target.PlayerData.source))) > 10.0 then
		return
	end

	if Target and Target.Functions.SetJob(Player.PlayerData.job.name, 0) then
		TriggerClientEvent('QBCore:Notify', src, 'You hired ' .. (Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname) .. ' come ' .. Player.PlayerData.job.label .. '', 'success')
		TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, 'You were hired as ' .. Player.PlayerData.job.label .. '', 'success')
		TriggerEvent('qb-log:server:CreateLog', 'bossmenu', 'Recruit', 'lightgreen', (Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname) .. ' successfully recruited ' .. (Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname) .. ' (' .. Player.PlayerData.job.name .. ')', false)
	end
	TriggerClientEvent('qb-bossmenu:client:OpenMenu', src)
end)

-- Get closest player sv
QBCore.Functions.CreateCallback('qb-bossmenu:getplayers', function(source, cb)
	local src = source
	local players = {}
	local Boss = exports['pfm-core']:GetPlayer(src)
	if not Boss or not Boss.PlayerData.job.isboss then return cb(players) end
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

-- [PF compat] pf-mechanicjob triggers this server-side (TriggerEvent) to deposit society money.
-- Server-local on purpose: as a net event any client could mint money into any society.
AddEventHandler('qb-bossmenu:server:addMoney', function(society, amount)
    if type(society) ~= 'string' or type(amount) ~= 'number' or amount <= 0 then return end
    exports['pfm-banking']:AddMoney(society, amount, 'society-deposit')
end)
