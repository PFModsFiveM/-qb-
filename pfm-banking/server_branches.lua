-- Bank branches and robbery closures.
--
-- A branch is a Config.locations entry (index = branch id). pfm-bankrobbery fires the server-only
-- event 'qb-banking:server:SetBankClosed' (bankId, closed) when a vault is opened and when the robbery
-- timeout ends. The robbery's bank id is mapped to a branch with Config.RobberyBranches.
--
-- While a branch is closed, server.lua refuses the counter and every ATM within Config.BranchClosure.radius
-- of it (openBank, openATM, cash withdraw/deposit, card orders), judged by the player's position on the
-- server. A closure ends by itself after Config.BranchClosure.minutes, or earlier when the robbery
-- resource reports the bank back in order. Closures are kept in memory: a server restart reopens every
-- branch, as the robbery state resets too.
--
-- City events (pf-services, when running): 'bank.branch.closed' and 'bank.branch.reopened'.

BankBranches = BankBranches or {}
local B = BankBranches

local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })

local closures = {}  -- [branchId] = { since, untilAt, reason, token }
local tokenSeq = 0

local function branchCount() return #Config.locations end

local function validBranch(id)
    id = tonumber(id)
    if not id or id % 1 ~= 0 or id < 1 or id > branchCount() then return nil end
    return id
end

function B.Label(id)
    local brandId = Config.locationBrands and Config.locationBrands[id] or 'fleeca'
    local brand = Config.brandStyles and Config.brandStyles[brandId] or nil
    local name = Config.branchNames and Config.branchNames[id] or ('Branch ' .. tostring(id))
    return (brand and brand.label or 'Bank') .. ' ' .. name, brandId
end

function B.Coords(id)
    return Config.locations[id]
end

--- The branch a pfm-bankrobbery bank id belongs to, or nil.
function B.FromRobbery(bankId)
    if type(bankId) ~= 'number' and type(bankId) ~= 'string' then return nil end
    if type(bankId) == 'string' and (#bankId > 16 or not bankId:match('^[%w_]+$')) then return nil end
    local key = tonumber(bankId) or bankId
    return validBranch(Config.RobberyBranches and Config.RobberyBranches[key])
end

local function secondsLeft(c)
    return math.max(0, c.untilAt - os.time())
end

--- { closed, reopensIn (seconds), reason } for one branch.
function B.Status(id)
    local c = closures[id]
    if c and secondsLeft(c) <= 0 then
        B.Open(id, 'timer')
        c = nil
    end
    if not c then return { closed = false } end
    return { closed = true, reopensIn = secondsLeft(c), reason = c.reason, since = c.since }
end

function B.IsClosed(id)
    id = validBranch(id)
    return id ~= nil and B.Status(id).closed
end

--- Every branch with its position and state (the Bank app's branch list).
function B.List()
    local out = {}
    for id = 1, branchCount() do
        local label, brand = B.Label(id)
        local c = B.Coords(id)
        local st = B.Status(id)
        out[#out + 1] = {
            id = id, label = label, brand = brand, x = c.x, y = c.y,
            closed = st.closed, reopensIn = st.reopensIn, reason = st.reason,
        }
    end
    return out
end

--- The closed branch whose radius contains these coordinates, or nil.
function B.ClosedAt(coords)
    if not coords then return nil end
    local radius = tonumber(Config.BranchClosure and Config.BranchClosure.radius) or 30.0
    for id in pairs(closures) do
        local c = B.Coords(id)
        if c and #(vector3(coords.x, coords.y, coords.z or 0.0) - c) <= radius and B.Status(id).closed then return id end
    end
    return nil
end

local function minutesText(seconds)
    local m = math.max(1, math.ceil(seconds / 60))
    return m == 1 and '1 minute' or (m .. ' minutes')
end

--- A player-facing refusal when `src` stands at a closed branch (counter or nearby ATM), else nil.
function B.ClosedMessageAt(src)
    if next(closures) == nil then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local id = B.ClosedAt(GetEntityCoords(ped))
    if not id then return nil end
    local label = B.Label(id)
    local st = B.Status(id)
    return ('%s is closed%s. It reopens in %s.'):format(label, st.reason == 'robbery' and ' after a robbery' or '', minutesText(st.reopensIn or 0))
end

-- ── city events ─────────────────────────────────────────────────────

local function servicesStarted() return GetResourceState('pf-services') == 'started' end

function B.RegisterEventKinds()
    if not servicesStarted() then return false end
    return pcall(function()
        local svc = exports['pf-services']
        svc:RegisterEventKind('bank.branch.closed', { label = 'Bank branch closed', news = 'none', category = 'business' })
        svc:RegisterEventKind('bank.branch.reopened', { label = 'Bank branch reopened', news = 'none', category = 'business' })
    end)
end

local function cityEvent(kind, id, data, title)
    if not servicesStarted() then return end
    local c = B.Coords(id)
    pcall(function()
        exports['pf-services']:Emit(kind, data, { title = title, coords = c, dedupe = ('branch:%d:%d'):format(id, data.token or 0) })
    end)
end

local function broadcast(id)
    local st = B.Status(id)
    TriggerClientEvent('qb-banking:client:branchState', -1, id, st.closed, st.reopensIn or 0)
end

-- ── open / close ───────────────────────────────────────────────────

--- Closes a branch for `minutes` (a later close extends it). reason: 'robbery' | 'staff'.
function B.Close(id, minutes, reason)
    id = validBranch(id)
    if not id then return false, 'unknown_branch' end
    local maxMinutes = tonumber(Config.BranchClosure and Config.BranchClosure.maxMinutes) or 180
    minutes = math.floor(tonumber(minutes) or tonumber(Config.BranchClosure and Config.BranchClosure.minutes) or 20)
    if minutes < 1 or minutes > maxMinutes then return false, 'bad_duration' end
    reason = (reason == 'staff') and 'staff' or 'robbery'
    local now = os.time()
    local existing = closures[id]
    local untilAt = now + minutes * 60
    if existing and existing.untilAt > untilAt then untilAt = existing.untilAt end
    tokenSeq = tokenSeq + 1
    local token = tokenSeq
    closures[id] = { since = existing and existing.since or now, untilAt = untilAt, reason = reason, token = token }
    -- reopen by itself; the token makes an earlier timer of an extended closure do nothing
    SetTimeout((untilAt - now) * 1000 + 500, function()
        local c = closures[id]
        if c and c.token == token and os.time() >= c.untilAt then B.Open(id, 'timer') end
    end)
    broadcast(id)
    if not existing then
        local label = B.Label(id)
        local title = reason == 'staff' and (label .. ' is temporarily closed') or (label .. ' closed after a robbery')
        cityEvent('bank.branch.closed', id, { branch = id, name = label, reason = reason, reopensAt = untilAt, minutes = minutes, token = token }, title)
    end
    return true, untilAt
end

--- Reopens a branch. how: 'timer' | 'robbery' | 'staff'.
function B.Open(id, how)
    id = validBranch(id)
    if not id then return false, 'unknown_branch' end
    local c = closures[id]
    if not c then return false, 'not_closed' end
    closures[id] = nil
    broadcast(id)
    local label = B.Label(id)
    cityEvent('bank.branch.reopened', id, { branch = id, name = label, how = how or 'timer', closedFor = os.time() - c.since, token = c.token },
        ('%s has reopened'):format(label))
    return true
end

-- pfm-bankrobbery (server only: never a net event; a call from a player is ignored)
AddEventHandler('qb-banking:server:SetBankClosed', function(bankId, closed)
    local src = tonumber(source)
    if src and src > 0 then return end
    if type(closed) ~= 'boolean' then return end
    local id = B.FromRobbery(bankId)
    if not id then return end
    if closed then B.Close(id, nil, 'robbery') else B.Open(id, 'robbery') end
end)

QBCore.Functions.CreateCallback('qb-banking:server:getBranchStates', function(_, cb)
    local out = {}
    for _, b in ipairs(B.List()) do
        if b.closed then out[#out + 1] = { id = b.id, reopensIn = b.reopensIn } end
    end
    cb(out)
end)

-- /bankbranch <id> <close|open> [minutes] (staff): close a branch for an incident, or reopen it.
QBCore.Commands.Add('bankbranch', 'Close or reopen a bank branch (admin)', {
    { name = 'id', help = 'Branch number (1-' .. branchCount() .. ')' },
    { name = 'action', help = 'close or open' },
    { name = 'minutes', help = 'Closure length (close only, optional)' },
}, false, function(source, args)
    local id, action = validBranch(args[1]), tostring(args[2] or ''):lower()
    local ok, err
    if not id then ok, err = false, 'unknown_branch'
    elseif action == 'close' then ok, err = B.Close(id, args[3] or Config.BranchClosure.minutes, 'staff')
    elseif action == 'open' then ok, err = B.Open(id, 'staff')
    else ok, err = false, 'use close or open' end
    local msg = ok and ('Branch %d (%s): %s'):format(id, B.Label(id), action == 'close' and 'closed' or 'reopened') or ('Not done: ' .. tostring(err))
    if source and source > 0 then TriggerClientEvent('QBCore:Notify', source, msg, ok and 'success' or 'error') else print(msg) end
end, 'admin')

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() or resource == 'pf-services' then B.RegisterEventKinds() end
end)

exports('IsBranchClosed', function(id) return B.IsClosed(id) end)
exports('GetBranches', function() return B.List() end)
exports('CloseBranch', function(id, minutes) return B.Close(id, minutes, 'staff') end)
exports('OpenBranch', function(id) return B.Open(id, 'staff') end)

-- Test hook
function B.__reset() closures, tokenSeq = {}, 0 end
