-- PF job payouts: a helper other resources include in their fxmanifest with
--   server_script '@pfm-banking/payouts.lua'
-- (it is not loaded by pfm-banking itself).
--
-- Every payment is one ledger Transfer between a player and the including resource's own system
-- account, system:<resource>, so each payout is journaled in pf_transactions. Every call needs a
-- stable idempotency key: a key that already paid is never paid again. When the bank is not running
-- nothing moves and the call reports failure (fail closed); the player is told the payment was not made.

PFPayout = PFPayout or {}
local P = PFPayout

P.SYSTEM = 'system:' .. GetCurrentResourceName()

local counter = 0
--- A unique id for a shift, route or mission, used to build its payment keys.
function P.NewId()
    counter = counter + 1
    return ('%d-%d-%d'):format(os.time(), counter, math.random(100000, 999999))
end

local function playerOf(who)
    if type(who) == 'table' and who.PlayerData then return who end
    if type(who) == 'number' then return exports['pfm-core']:GetPlayer(who) end
    if type(who) == 'string' then return exports['pfm-core']:GetPlayerByCitizenId(who) end
end

local function citizenIdOf(who)
    if type(who) == 'string' then return who end
    local Player = playerOf(who)
    return Player and Player.PlayerData.citizenid or nil
end

local function sourceOf(who)
    if type(who) == 'number' then return who end
    local Player = playerOf(who)
    return Player and Player.PlayerData.source or nil
end

--- Raw ledger call; never throws.
function P.Transfer(opts)
    if GetResourceState('pfm-banking') ~= 'started' then return { ok = false, error = 'bank_unavailable' } end
    local ok, res = pcall(function() return exports['pfm-banking']:Transfer(opts) end)
    if not ok or type(res) ~= 'table' then return { ok = false, error = 'bank_unavailable' } end
    return res
end

local function tellFailure(who, opts, message)
    if opts.quiet then return end
    local src = sourceOf(who)
    if src then TriggerClientEvent('QBCore:Notify', src, message, 'error') end
end

local function checkKey(key)
    assert(type(key) == 'string' and key ~= '', 'PFPayout needs a stable key')
end

--- Pays a player (source, Player object or citizenid) from system:<resource>.
--- account: 'cash' or 'bank'. opts: key (required), reason, kind ('wage'), from, metadata, quiet.
--- @return boolean ok, table result   (ok is also true for a key that was already paid)
function P.Pay(who, account, amount, opts)
    opts = opts or {}
    checkKey(opts.key)
    local cid = citizenIdOf(who)
    amount = tonumber(amount)
    if not cid or not amount or amount <= 0 or (account ~= 'cash' and account ~= 'bank') then
        return false, { ok = false, error = 'invalid_request' }
    end
    local res = P.Transfer({
        from = opts.from or P.SYSTEM, to = ('player:%s:%s'):format(cid, account), amount = amount,
        key = opts.key, kind = opts.kind or 'wage', reason = opts.reason, actor = cid, metadata = opts.metadata,
    })
    if not res.ok then tellFailure(who, opts, 'The bank did not respond. This payment was not made.') end
    return res.ok == true, res
end

--- Takes money from a player into system:<resource> (deposits, fees). Tries each account in order,
--- e.g. { 'cash', 'bank' }. opts: key (required; each account gets key .. ':' .. account), reason, kind.
--- @return string|false account used, table result
function P.Charge(who, accounts, amount, opts)
    opts = opts or {}
    checkKey(opts.key)
    if type(accounts) == 'string' then accounts = { accounts } end
    local cid = citizenIdOf(who)
    amount = tonumber(amount)
    if not cid or not amount or amount <= 0 then return false, { ok = false, error = 'invalid_request' } end
    local res = { ok = false, error = 'insufficient_funds' }
    for _, account in ipairs(accounts) do
        res = P.Transfer({
            from = ('player:%s:%s'):format(cid, account), to = opts.to or P.SYSTEM, amount = amount,
            key = opts.key .. ':' .. account, kind = opts.kind or 'deposit', reason = opts.reason, actor = cid,
            metadata = opts.metadata,
        })
        if res.ok then return account, res end
        if res.error == 'bank_unavailable' or res.error == 'ledger_unavailable' then break end
    end
    if res.error == 'bank_unavailable' or res.error == 'ledger_unavailable' then
        tellFailure(who, opts, 'The bank did not respond. Nothing was charged.')
    end
    return false, res
end

--- Pays a society (job) account from system:<resource>, with a statement line.
--- @return boolean ok, table result
function P.PaySociety(society, amount, opts)
    opts = opts or {}
    checkKey(opts.key)
    if GetResourceState('pfm-banking') ~= 'started' then return false, { ok = false, error = 'bank_unavailable' } end
    local ok, done, res = pcall(function() return exports['pfm-banking']:AddMoney(society, amount, opts.reason, opts.key) end)
    if not ok then return false, { ok = false, error = 'bank_unavailable' } end
    return done == true, res
end
