-- The Boss app on pf-devices (tablet and computer): staff, ranks, wages and the society account of the
-- job and/or gang the player is boss of.
--
-- Access is pfm-management's own boss check (PFManagement.IsBoss: job or gang boss). Staff changes use
-- the same rules as the boss menu (sv_boss.lua) and work from anywhere; hiring still needs the person
-- standing next to the boss. Society money moves through pfm-banking's SocietyTransfer (the ledger):
-- from or to the boss's bank account anywhere, cash only at the group's management desk. Nothing is
-- created: every deposit leaves the boss's balance and every withdrawal leaves the society's.

local M = PFManagement
local APP_ID = 'boss'

local ERRORS = {
    not_boss = 'You are not the boss here', not_member = 'That person is not on your staff', outranks_you = 'They outrank you',
    grade_above_yours = 'You cannot give a rank above your own', unknown_grade = 'That rank does not exist', bad_grade = 'Choose a rank',
    cannot_change_self = 'You cannot change your own rank', cannot_fire_self = 'You cannot fire yourself',
    cannot_hire_self = 'You cannot hire yourself', too_far = 'They must stand next to you', already_member = 'They are already on your staff',
    no_player = 'That person is not in the city', failed = 'That did not work',
}

local function scopeOf(p)
    local s = type(p) == 'table' and p.scope or nil
    return (s == 'job' or s == 'gang') and s or nil
end

local function requestRef(p)
    local r = p.ref
    if type(r) ~= 'string' or #r < 8 or #r > 40 or not r:match('^[%w%-]+$') then return nil end
    return r
end

local function bankUp() return GetResourceState('pfm-banking') == 'started' end

-- one money action per boss per 1.5 s
local lastMoney = {}
local function onCooldown(cid)
    local now = GetGameTimer()
    if lastMoney[cid] and now - lastMoney[cid] < 1500 then return true end
    lastMoney[cid] = now
    return false
end

local function result(ok, err, extra)
    if ok then
        local out = extra or {}
        out.ok = true
        return out
    end
    return { ok = false, error = err, message = ERRORS[err] }
end

--- What the boss runs: { name, label, grade, grades (with wages), society, office }.
local function scopeView(src, Player, scope)
    local group = M.BossGroup(Player, scope)
    if not group then return nil end
    local grades, def = M.Grades(scope, group.name)
    local list = {}
    for lvl, g in pairs(grades or {}) do
        list[#list + 1] = { level = tonumber(lvl) or 0, name = g.name, payment = tonumber(g.payment), isboss = g.isboss == true }
    end
    table.sort(list, function(a, b) return a.level < b.level end)
    local balance
    if bankUp() then
        local ok, b = pcall(function() return exports['pfm-banking']:GetAccountBalance(group.name) end)
        balance = ok and tonumber(b) or nil
    end
    local spot = Config[scope == 'job' and 'BossMenus' or 'GangMenus'] and Config[scope == 'job' and 'BossMenus' or 'GangMenus'][group.name]
    local first = type(spot) == 'table' and spot[1] or nil
    return {
        scope = scope, name = group.name, label = group.label or (def and def.label) or group.name,
        grade = { level = M.Level(group), name = group.grade and group.grade.name },
        grades = list, balance = balance, atOffice = M.AtOffice(src, scope),
        office = first and not (first.x == 0 and first.y == 0) and { x = first.x, y = first.y } or nil,
    }
end

local App = {}

function App.Overview(src)
    local Player = M.Player(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local cash = tonumber(Player.PlayerData.money and Player.PlayerData.money.cash) or 0
    local bank = tonumber(Player.PlayerData.money and Player.PlayerData.money.bank) or 0
    return {
        ok = true, job = scopeView(src, Player, 'job'), gang = scopeView(src, Player, 'gang'),
        paycheck = M.PaycheckInfo(), me = { bank = bank, cash = cash },
    }
end

function App.Society(src, p)
    local scope = scopeOf(p)
    local Player = M.Player(src)
    local group = scope and M.BossGroup(Player, scope)
    if not group then return result(false, 'not_boss') end
    if not bankUp() then return { ok = false, error = 'bank_unavailable' } end
    local st = exports['pfm-banking']:GetAccountStatement(src, 'society:' .. group.name, { limit = 15 })
    local balance = tonumber(exports['pfm-banking']:GetAccountBalance(group.name)) or 0
    return { ok = true, balance = balance, rows = st and st.ok and st.rows or {}, summary = st and st.summary or nil, atOffice = M.AtOffice(src, scope) }
end

local SOCIETY_ERRORS = {
    insufficient_funds = 'Not enough money for that', not_authorized = 'You may not use this account', bad_amount = 'Enter a valid amount',
    already_processed = 'This transaction was already processed', unknown_account = 'The account was not found',
    in_progress = 'That transaction is still being processed',
}

--- deposit / withdraw: payload { scope, amount, account = 'bank'|'cash', ref }
function App.Money(src, p, direction)
    local scope = scopeOf(p)
    local Player = M.Player(src)
    local group = scope and M.BossGroup(Player, scope)
    if not group then return result(false, 'not_boss') end
    local ref = requestRef(p)
    if not ref then return { ok = false, error = 'bad_request' } end
    local amount = tonumber(p.amount)
    if not amount or amount ~= amount or amount < 1 or amount % 1 ~= 0 or amount > 100000000 then return { ok = false, error = 'bad_amount', message = SOCIETY_ERRORS.bad_amount } end
    local account = p.account == 'cash' and 'cash' or 'bank'
    -- cash is physical: only at the group's own management desk
    if account == 'cash' and not M.AtOffice(src, scope) then
        return { ok = false, error = 'not_at_office', message = 'Cash is handled at your office desk; use your bank account from here' }
    end
    if not bankUp() then return { ok = false, error = 'bank_unavailable', message = 'The bank is not responding' } end
    local cid = Player.PlayerData.citizenid
    -- the direction is part of the action: a ref reused for the other direction is a new move, and
    -- SocietyTransfer refuses a reused key whose society or amount differs
    local key = ('boss:%s:%s:%s'):format(cid, direction, ref)
    if onCooldown(cid) then return { ok = false, error = 'slow_down', message = 'Wait a moment between two transactions' } end
    local res = exports['pfm-banking']:SocietyTransfer(src, {
        society = group.name, direction = direction, account = account, amount = amount, key = key,
        reason = (direction == 'deposit' and 'Deposit by ' or 'Withdrawal by ') .. M.FullName(Player),
    })
    if type(res) ~= 'table' or not res.ok then
        local err = type(res) == 'table' and res.error or 'failed'
        return { ok = false, error = err, message = SOCIETY_ERRORS[err] }
    end
    return { ok = true, balance = res.balance, duplicate = res.duplicate, amount = res.amount }
end

local handlers = {
    __access = function(src) return M.IsBoss(src) end,
    overview = function(src) return App.Overview(src) end,
    members = function(src, p)
        local scope = scopeOf(p)
        if not scope then return { ok = false, error = 'bad_request' } end
        local list, err = M.ListMembers(src, scope)
        if not list then return result(false, err) end
        return { ok = true, members = list }
    end,
    setGrade = function(src, p)
        local scope = scopeOf(p)
        if not scope or type(p.citizenid) ~= 'string' then return { ok = false, error = 'bad_request' } end
        local ok, res = M.SetGrade(src, scope, p.citizenid, p.grade)
        return result(ok, not ok and res or nil)
    end,
    fire = function(src, p)
        local scope = scopeOf(p)
        if not scope or type(p.citizenid) ~= 'string' then return { ok = false, error = 'bad_request' } end
        local ok, res = M.Fire(src, scope, p.citizenid)
        return result(ok, not ok and res or nil)
    end,
    nearby = function(src, p)
        local scope = scopeOf(p)
        if not scope then return { ok = false, error = 'bad_request' } end
        local list, err = M.Nearby(src, scope)
        if not list then return result(false, err) end
        return { ok = true, players = list }
    end,
    hire = function(src, p)
        local scope = scopeOf(p)
        local target = tonumber(p.id)
        if not scope or not target or target % 1 ~= 0 then return { ok = false, error = 'bad_request' } end
        local ok, res = M.Hire(src, scope, target)
        if ok then
            local label = (M.BossGroup(M.Player(src), scope) or {}).label or 'the team'
            TriggerClientEvent('QBCore:Notify', res.PlayerData.source, 'You were hired by ' .. label, 'success')
            return { ok = true, name = M.FullName(res) }
        end
        return result(false, res)
    end,
    society = function(src, p) return App.Society(src, p) end,
    deposit = function(src, p) return App.Money(src, p, 'deposit') end,
    withdraw = function(src, p) return App.Money(src, p, 'withdraw') end,
}
PFManagementApp = { Handlers = handlers, Overview = App.Overview }

function PFManagementApp.Register()
    if GetResourceState('pf-devices') ~= 'started' then return false end
    local devices = exports['pf-devices']
    devices:RegisterApp({
        id = APP_ID, name = 'Management', icon = '💼', entry = 'html/apps/boss.js', styles = { 'html/apps/boss.css' },
        devices = { 'tablet', 'computer' }, category = 'business', order = 3, access = { handler = true },
        window = { width = 940, height = 640 },
        description = 'Your staff, ranks, wages and society account',
    })
    devices:RegisterAppHandlers(APP_ID, handlers)
    return true
end

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() or resource == 'pf-devices' then PFManagementApp.Register() end
end)
AddEventHandler('pf-devices:server:ready', function() PFManagementApp.Register() end)

-- becoming or stopping being a boss changes the player's app list (pf-devices refreshes on job
-- updates; gang changes are announced here)
AddEventHandler('QBCore:Server:OnGangUpdate', function(src)
    if tonumber(src) and GetResourceState('pf-devices') == 'started' then
        pcall(function() exports['pf-devices']:NotifyAppsChanged(tonumber(src)) end)
    end
end)

function PFManagementApp.__reset() lastMoney = {} end
