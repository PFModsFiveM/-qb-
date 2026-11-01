-- Staff rules shared by the boss menu (this file), the gang menu (sv_gang.lua), the Boss app
-- (sv_app.lua) and other resources (exports at the bottom). One place decides who may hire, rank and
-- fire whom:
--   * only a boss of a job (scope 'job') or gang (scope 'gang') acts, and only on their own group;
--   * never on someone ranked above them, never to a grade above their own, never on themselves;
--   * a grade must exist for that job/gang;
--   * hiring needs the person standing next to the boss (10 m, positions read on the server) and not
--     already in the group.
-- Every function reads the boss and the target on the server; callers pass ids only.

PFManagement = PFManagement or {}
local M = PFManagement
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Config' })

M.HIRE_RANGE = 10.0
M.OFFICE_RANGE = 3.0

local SCOPES = {
    job = { field = 'job', none = 'unemployed', set = 'SetJob', shared = 'Jobs', column = 'job', menus = 'BossMenus' },
    gang = { field = 'gang', none = 'none', set = 'SetGang', shared = 'Gangs', column = 'gang', menus = 'GangMenus' },
}
M.SCOPES = SCOPES

local function scopeOf(scope) return SCOPES[scope] end

function M.Player(src) return exports['pfm-core']:GetPlayer(tonumber(src)) end

local function level(group)
    local g = group and group.grade
    return tonumber(type(g) == 'table' and g.level or g) or 0
end
M.Level = level

local function fullName(Player)
    local ci = Player and Player.PlayerData and Player.PlayerData.charinfo or {}
    return (((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', ''))
end
M.FullName = fullName

--- The boss's job or gang (PlayerData.job / .gang) when they are its boss, else nil.
function M.BossGroup(Player, scope)
    local sc = scopeOf(scope)
    if not sc or not Player or not Player.PlayerData then return nil end
    local group = Player.PlayerData[sc.field]
    if not group or group.isboss ~= true or not group.name or group.name == sc.none then return nil end
    return group
end

--- True when src is the boss of their job (scope 'job'), gang ('gang'), or either (nil).
function M.IsBoss(src, scope)
    local Player = M.Player(src)
    if not Player then return false end
    if scope then return M.BossGroup(Player, scope) ~= nil end
    return M.BossGroup(Player, 'job') ~= nil or M.BossGroup(Player, 'gang') ~= nil
end

--- The grade table of a job or gang ({ ['0'] = { name, payment, isboss }, ... }), or nil when unknown.
function M.Grades(scope, name)
    local sc = scopeOf(scope)
    local all = sc and exports['pfm-core']:GetShared(sc.shared) or nil
    local def = type(all) == 'table' and all[name] or nil
    return def and def.grades or nil, def
end

local function lookup(cid)
    return QBCore.Functions.GetPlayerByCitizenId(cid) or QBCore.Functions.GetOfflinePlayerByCitizenId(cid)
end

local function decode(v)
    if type(v) == 'table' then return v end
    local ok, out = pcall(json.decode, v or '')
    return ok and type(out) == 'table' and out or {}
end

--- The members of the boss's job or gang: online ones from live data, the others from their saved
--- character. nil, 'not_boss' when src is not a boss of that scope.
function M.ListMembers(src, scope)
    local sc = scopeOf(scope)
    local Player = M.Player(src)
    local group = M.BossGroup(Player, scope)
    if not group then return nil, 'not_boss' end
    local name = group.name
    -- always the boss's own group (the client-sent name was pasted into the SQL)
    local rows = MySQL.query.await(('SELECT * FROM `players` WHERE `%s` LIKE ?'):format(sc.column), { '%' .. name .. '%' }) or {}
    local list, seen = {}, {}
    for _, row in ipairs(rows) do
        local cid = row.citizenid
        local Online = cid and QBCore.Functions.GetPlayerByCitizenId(cid)
        local g, ci
        if Online then
            g, ci = Online.PlayerData[sc.field], Online.PlayerData.charinfo
        else
            local Offline = cid and QBCore.Functions.GetOfflinePlayerByCitizenId(cid)
            if Offline then g, ci = Offline.PlayerData[sc.field], Offline.PlayerData.charinfo
            else g, ci = decode(row[sc.column]), decode(row.charinfo) end
        end
        if cid and not seen[cid] and type(g) == 'table' and g.name == name then
            seen[cid] = true
            local grade = type(g.grade) == 'table' and g.grade or { level = tonumber(g.grade) or 0 }
            list[#list + 1] = {
                citizenid = cid,
                name = ((ci and ci.firstname or '') .. ' ' .. (ci and ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', ''),
                grade = { level = tonumber(grade.level) or 0, name = grade.name, payment = tonumber(grade.payment) },
                isboss = g.isboss == true or grade.isboss == true,
                online = Online ~= nil and Online.PlayerData.source ~= nil,
                onduty = Online ~= nil and g.onduty == true or false,
                me = cid == Player.PlayerData.citizenid,
            }
        end
    end
    table.sort(list, function(a, b)
        if a.grade.level ~= b.grade.level then return a.grade.level > b.grade.level end
        return a.name < b.name
    end)
    return list
end

-- The boss and a member of their own group they may act on.
local function bossAndMember(src, scope, cid)
    local sc = scopeOf(scope)
    if not sc then return nil, 'bad_request' end
    local Boss = M.Player(src)
    local group = M.BossGroup(Boss, scope)
    if not group then return nil, 'not_boss' end
    if type(cid) ~= 'string' or cid == '' or #cid > 50 then return nil, 'bad_request' end
    local Member = lookup(cid)
    local mg = Member and Member.PlayerData and Member.PlayerData[sc.field]
    if not mg or mg.name ~= group.name then return nil, 'not_member' end
    if level(mg) > level(group) then return nil, 'outranks_you' end
    return Boss, nil, Member, group, sc
end

local function notifyOnline(Player, message, kind)
    local s = Player and Player.PlayerData and Player.PlayerData.source
    if s and not Player.Offline then TriggerClientEvent('QBCore:Notify', s, message, kind or 'primary') end
end

--- Sets a member's grade. Returns true, member or false, error.
function M.SetGrade(src, scope, cid, grade)
    local Boss, err, Member, group, sc = bossAndMember(src, scope, cid)
    if not Boss then return false, err end
    grade = tonumber(grade)
    if not grade or grade < 0 or grade % 1 ~= 0 then return false, 'bad_grade' end
    if Member.PlayerData.citizenid == Boss.PlayerData.citizenid then return false, 'cannot_change_self' end
    if grade > level(group) then return false, 'grade_above_yours' end
    local grades = M.Grades(scope, group.name)
    if grades and not grades[tostring(grade)] then return false, 'unknown_grade' end
    if not Member.Functions[sc.set](group.name, grade) then return false, 'unknown_grade' end
    if Member.Functions.Save then Member.Functions.Save() end
    -- Member is pfm-core's copy from before the change (it came through the export): an online
    -- member is read again for the rank they have now; an offline one is not told anything
    local Now = not Member.Offline and QBCore.Functions.GetPlayerByCitizenId(Member.PlayerData.citizenid) or nil
    if Now then Member = Now end
    local g = Now and Now.PlayerData[sc.field]
    local def = grades and grades[tostring(grade)]
    notifyOnline(Member, 'Your rank is now ' .. tostring(g and g.grade and g.grade.name or def and def.name or grade) .. '.', 'success')
    TriggerEvent('qb-log:server:CreateLog', scope == 'job' and 'bossmenu' or 'gangmenu', 'Grade Change', 'yellow',
        ('%s set %s to grade %s (%s)'):format(fullName(Boss), fullName(Member), tostring(grade), group.name), false)
    return true, Member
end

--- Removes a member from the boss's group. Returns true, member or false, error.
function M.Fire(src, scope, cid)
    local Boss, err, Member, group, sc = bossAndMember(src, scope, cid)
    if not Boss then return false, err end
    if Member.PlayerData.citizenid == Boss.PlayerData.citizenid then return false, 'cannot_fire_self' end
    if not Member.Functions[sc.set](sc.none, '0') then return false, 'failed' end
    if Member.Functions.Save then Member.Functions.Save() end
    notifyOnline(Member, scope == 'job' and 'You have been fired! Good luck.' or 'You have been expelled from the gang!', 'error')
    TriggerEvent('qb-log:server:CreateLog', scope == 'job' and 'bossmenu' or 'gangmenu', scope == 'job' and 'Job Fire' or 'Gang Fire', 'red',
        ('%s successfully fired %s (%s)'):format(fullName(Boss), fullName(Member), group.name), false)
    if scope == 'job' and GetResourceState('pf-citizen') == 'started' then
        pcall(function()
            exports['pf-citizen']:SendMail(Member.PlayerData.citizenid, {
                sender = group.label or group.name, senderType = 'business', subject = 'Employment ended',
                message = ('Your employment at %s has ended.'):format(group.label or group.name),
            })
        end)
    end
    return true, Member
end

local function distance(a, b)
    local pa, pb = GetEntityCoords(GetPlayerPed(a)), GetEntityCoords(GetPlayerPed(b))
    return #(vector3(pa.x, pa.y, pa.z) - vector3(pb.x, pb.y, pb.z))
end

--- Hires the player with server id `targetSrc` into the boss's group at grade 0. They must stand next
--- to the boss and not be in the group already. Returns true, target or false, error.
function M.Hire(src, scope, targetSrc)
    local sc = scopeOf(scope)
    if not sc then return false, 'bad_request' end
    local Boss = M.Player(src)
    local group = M.BossGroup(Boss, scope)
    if not group then return false, 'not_boss' end
    targetSrc = tonumber(targetSrc)
    local Target = targetSrc and M.Player(targetSrc)
    if not Target then return false, 'no_player' end
    if Target.PlayerData.citizenid == Boss.PlayerData.citizenid then return false, 'cannot_hire_self' end
    -- the same 10 m as the hire list (anyone on the server could be hired from anywhere)
    if distance(src, Target.PlayerData.source or targetSrc) > M.HIRE_RANGE then return false, 'too_far' end
    local tg = Target.PlayerData[sc.field]
    if tg and tg.name == group.name then return false, 'already_member' end
    if not Target.Functions[sc.set](group.name, 0) then return false, 'failed' end
    if Target.Functions.Save then Target.Functions.Save() end
    TriggerEvent('qb-log:server:CreateLog', scope == 'job' and 'bossmenu' or 'gangmenu', 'Recruit', 'lightgreen',
        ('%s successfully recruited %s (%s)'):format(fullName(Boss), fullName(Target), group.name), false)
    return true, Target
end

--- Players next to the boss who could be hired (not already in the group).
function M.Nearby(src, scope)
    local sc = scopeOf(scope)
    local Boss = M.Player(src)
    local group = M.BossGroup(Boss, scope)
    if not sc or not group then return nil, 'not_boss' end
    local out = {}
    for _, id in pairs(QBCore.Functions.GetPlayers()) do
        id = tonumber(id)
        local P = id and id ~= tonumber(src) and M.Player(id)
        if P and distance(src, id) < M.HIRE_RANGE then
            local g = P.PlayerData[sc.field]
            if not (g and g.name == group.name) then out[#out + 1] = { id = id, name = fullName(P) } end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- True when src stands at one of their group's management desks (Config.BossMenus / GangMenus).
function M.AtOffice(src, scope)
    local sc = scopeOf(scope)
    local Player = M.Player(src)
    local group = M.BossGroup(Player, scope)
    if not sc or not group then return false end
    local spots = Config[sc.menus] and Config[sc.menus][group.name]
    if type(spots) ~= 'table' then return false end
    local p = GetEntityCoords(GetPlayerPed(src))
    for _, c in ipairs(spots) do
        if not (c.x == 0 and c.y == 0) and #(vector3(p.x, p.y, p.z) - c) <= M.OFFICE_RANGE then return true end
    end
    return false
end

function M.PaycheckInfo()
    local money = QBCore.Config and QBCore.Config.Money or {}
    return { minutes = tonumber(money.PayCheckTimeOut) or 10, fromSociety = money.PayCheckSociety == true }
end

-- ── exports for other resources (pf-computer's Business Manager uses the same rules) ──
exports('IsBoss', function(src, scope) return M.IsBoss(src, scope) end)
exports('ListEmployees', function(src, scope) return M.ListMembers(src, scope or 'job') end)
exports('SetEmployeeGrade', function(src, cid, grade, scope) return M.SetGrade(src, scope or 'job', cid, grade) end)
exports('FireEmployee', function(src, cid, scope) return M.Fire(src, scope or 'job', cid) end)
exports('HireEmployee', function(src, targetSrc, scope) return M.Hire(src, scope or 'job', targetSrc) end)

-- ── boss menu ───────────────────────────────────────────────────────

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

-- Get Employees (the rules above are shared with the gang menu and the Boss app)

QBCore.Functions.CreateCallback('qb-bossmenu:server:GetEmployees', function(source, cb)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return cb({}) end

	if not Player.PlayerData.job.isboss then
		ExploitBan(src, 'GetEmployees Exploiting')
		return
	end

	local employees = {}
	for _, m in ipairs(M.ListMembers(src, 'job') or {}) do
		employees[#employees + 1] = {
			empSource = m.citizenid,
			grade = m.grade,
			isboss = m.isboss,
			name = (m.online and '🟢 ' or '❌ ') .. m.name,
		}
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
local GRADE_MESSAGES = {
	not_member = 'You cannot change this rank!', outranks_you = 'You cannot change this rank!',
	cannot_change_self = 'You cannot change your own rank!', grade_above_yours = 'You cannot promote to this rank!',
	unknown_grade = 'Promotion grade does not exist.', bad_grade = 'Promotion grade does not exist.',
}

RegisterNetEvent('qb-bossmenu:server:GradeUpdate', function(data)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return end

	if not Player.PlayerData.job.isboss then
		ExploitBan(src, 'GradeUpdate Exploiting')
		return
	end
	if type(data) ~= 'table' or type(data.cid) ~= 'string' then return end
	local grade = tonumber(data.grade)
	if not grade or grade < 0 or grade % 1 ~= 0 then return end
	local ok, err = M.SetGrade(src, 'job', data.cid, grade)
	if not ok then
		TriggerClientEvent('QBCore:Notify', src, GRADE_MESSAGES[err] or 'Error..', 'error')
		if err ~= 'unknown_grade' then return end
	else
		TriggerClientEvent('QBCore:Notify', src, 'Sucessfully promoted!', 'success')
	end
	TriggerClientEvent('qb-bossmenu:client:OpenMenu', src)
end)

-- Fire Employee
local FIRE_MESSAGES = {
	not_member = 'You cannot fire this citizen!', outranks_you = 'You cannot fire this citizen!',
	cannot_fire_self = 'You can\'t fire yourself', failed = 'Error..',
}

RegisterNetEvent('qb-bossmenu:server:FireEmployee', function(target)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player or type(target) ~= 'string' then return end

	if not Player.PlayerData.job.isboss then
		ExploitBan(src, 'FireEmployee Exploiting')
		return
	end

	local ok, err = M.Fire(src, 'job', target)
	if ok then
		TriggerClientEvent('QBCore:Notify', src, 'Employee fired!', 'success')
	elseif FIRE_MESSAGES[err] then
		TriggerClientEvent('QBCore:Notify', src, FIRE_MESSAGES[err], 'error')
		if err == 'not_member' then return end
	end
	TriggerClientEvent('qb-bossmenu:client:OpenMenu', src)
end)

-- Recruit Player
RegisterNetEvent('qb-bossmenu:server:HireEmployee', function(recruit)
	local src = source
	local Player = exports['pfm-core']:GetPlayer(src)
	if not Player then return end

	if not Player.PlayerData.job.isboss then
		ExploitBan(src, 'HireEmployee Exploiting')
		return
	end
	-- next to the boss, not already on the staff, never the boss themselves (sv_staff.lua)
	local ok, res = M.Hire(src, 'job', recruit)
	local Target, err = ok and res or nil, not ok and res or nil
	if err == 'too_far' then return end
	if ok then
		TriggerClientEvent('QBCore:Notify', src, 'You hired ' .. M.FullName(Target) .. ' come ' .. Player.PlayerData.job.label .. '', 'success')
		TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, 'You were hired as ' .. Player.PlayerData.job.label .. '', 'success')
	elseif err == 'already_member' then
		TriggerClientEvent('QBCore:Notify', src, 'This citizen already works here', 'error')
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
