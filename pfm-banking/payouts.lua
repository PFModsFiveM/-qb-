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

-- Errors the ledger returns before it writes anything (no transaction row, so nothing moved).
local REFUSED_BEFORE_WRITE = {
    insufficient_funds = true, invalid_request = true, invalid_account = true, same_account = true,
    invalid_amount = true, invalid_key = true,
}

-- Whether the ledger clearly refused this transfer with no money taken, so another account may be
-- tried: a 'failed' transfer (new, or stored under the same key), or a request refused before
-- anything was written. A pending transfer the ledger's recovery marked 'interrupted_unverified'
-- is not clear: the player's money may have left before the crash.
local function clearRefusal(res)
    if res.ok then return false end
    if res.state == 'failed' then return res.error ~= 'interrupted_unverified' end
    if res.state == nil and res.txId == nil then return REFUSED_BEFORE_WRITE[res.error] == true end
    return false
end

--- Whether a Pay / Transfer / Charge result failed for certain, with no money moved now or later:
--- the bank or ledger was not running, the ledger refused before writing, the transfer is 'failed'
--- (not 'interrupted_unverified'), or it was reversed ('compensated'). Only then may a caller undo
--- its side of the deal (hand goods back, free a lock, try a new key). Anything else (pending,
--- debited, in_progress, internal_error, ledger_write_failed, res.unclear) may still complete
--- through the ledger's recovery: keep the goods taken and retry or settle under the same key.
--- On such a retry, bank_unavailable / ledger_unavailable describe that call only, not the key that
--- came back unclear before: keep waiting then.
function P.IsClearFailure(res)
    if type(res) ~= 'table' or res.ok then return false end
    if res.unclear then return false end
    if res.error == 'bank_unavailable' or res.error == 'ledger_unavailable' then return true end
    if res.state == 'compensated' then return true end
    return clearRefusal(res)
end

--- Takes money from a player into system:<resource> (deposits, fees). Tries each account in order,
--- e.g. { 'cash', 'bank' }. opts: key (required; each account gets key .. ':' .. account), reason, kind,
--- to, metadata, quiet.
--- The next account is only tried after a clear refusal of the previous one (insufficient_funds, or
--- 'failed' with no money taken). On any other outcome (pending, debited, compensated, in_progress,
--- ledger_write_failed, internal_error, a stored duplicate that is not completed or failed, bank not
--- running) Charge stops there and returns false with that result, so one payment is never taken from
--- two accounts. When the outcome is not known yet, result.unclear is true: do not charge again under
--- a new key; the ledger's recovery settles it, and the same key later returns its final result.
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
        if res.error == 'bank_unavailable' or res.error == 'ledger_unavailable' then
            tellFailure(who, opts, 'The bank did not respond. Nothing was charged.')
            return false, res
        end
        if not clearRefusal(res) then
            res.unclear = res.state ~= 'compensated' -- a compensated transfer was refunded: settled
            tellFailure(who, opts, res.unclear and 'The bank is still processing this payment. Nothing more was charged.'
                or 'The payment did not go through. Nothing was charged.')
            return false, res
        end
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
