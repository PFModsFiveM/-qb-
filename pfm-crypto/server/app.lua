-- The Crypto app on pf-devices (tablet and computer): the Qbit market (price and its history), the
-- player's wallet, buying and selling for bank money and sending coins to another wallet.
--
-- Trades run through CryptoTrade (server/main.lua), the same code as the phone: the server's price,
-- the bank side on the pfm-banking ledger, and the app's per-action id (`ref`) in the ledger key so a
-- retried request never trades twice. Exchanging a cryptostick stays at the physical terminal.

CryptoApp = CryptoApp or {}
local A = CryptoApp
local APP_ID = 'crypto'
local COIN = Crypto.Coin

A.ready = false

A.Migrations = {
    {
        version = 1,
        name = 'price history, wallet transfers, the crypto table itself',
        up = {
            -- the stock table (qb-crypto.sql), for servers that never imported it
            [[CREATE TABLE IF NOT EXISTS `crypto` (
                `crypto` VARCHAR(50) NOT NULL DEFAULT 'qbit',
                `worth` INT(11) NOT NULL DEFAULT 0,
                `history` TEXT DEFAULT NULL,
                PRIMARY KEY (`crypto`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[INSERT IGNORE INTO `crypto` (crypto, worth, history) VALUES ('qbit', 1000, '[{"NewWorth":1000,"PreviousWorth":1000}]')]],
            [[CREATE TABLE IF NOT EXISTS `pf_crypto_prices` (
                `id` BIGINT NOT NULL AUTO_INCREMENT,
                `coin` VARCHAR(50) NOT NULL,
                `worth` INT NOT NULL,
                `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_coin_id` (`coin`, `id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
            [[CREATE TABLE IF NOT EXISTS `pf_crypto_transfers` (
                `id` BIGINT NOT NULL AUTO_INCREMENT,
                `transfer_key` VARCHAR(128) NOT NULL,
                `from_cid` VARCHAR(50) NOT NULL,
                `to_cid` VARCHAR(50) NOT NULL,
                `coin` VARCHAR(50) NOT NULL DEFAULT 'qbit',
                `coins` DECIMAL(20,6) NOT NULL,
                `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                UNIQUE KEY `uq_transfer_key` (`transfer_key`),
                KEY `idx_from` (`from_cid`),
                KEY `idx_to` (`to_cid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        },
    },
}

-- ── prices ──────────────────────────────────────────────────────────

--- Called by main.lua on every price change: one history point, and the open apps get the new price.
function A.OnPrice(name, worth)
    worth = tonumber(worth)
    if not worth then return end
    if A.ready then
        pcall(function() MySQL.insert('INSERT INTO pf_crypto_prices (coin, worth) VALUES (?, ?)', { name, math.floor(worth) }) end)
    end
    if GetResourceState('pf-devices') == 'started' then
        pcall(function() exports['pf-devices']:Broadcast(APP_ID, 'price', { coin = name, price = worth, at = os.time() }) end)
    end
end

--- Up to `limit` recent price points, oldest first: { { at, price } }.
function A.PriceHistory(name, limit)
    limit = math.max(2, math.min(500, math.floor(tonumber(limit) or 96)))
    local rows = A.ready and MySQL.query.await(('SELECT worth, UNIX_TIMESTAMP(created_at) AS at FROM pf_crypto_prices WHERE coin = ? ORDER BY id DESC LIMIT %d'):format(limit), { name }) or {}
    local out = {}
    for i = #rows, 1, -1 do out[#out + 1] = { at = tonumber(rows[i].at), price = tonumber(rows[i].worth) } end
    if #out == 0 then
        -- before any point was recorded: the four in-memory steps
        for _, step in ipairs(Crypto.History[name] or {}) do out[#out + 1] = { price = tonumber(step.NewWorth) } end
    end
    return out
end

local function dayAgoPrice(name, history)
    local row = A.ready and MySQL.scalar.await('SELECT worth FROM pf_crypto_prices WHERE coin = ? AND created_at <= (NOW() - INTERVAL 1 DAY) ORDER BY id DESC LIMIT 1', { name }) or nil
    if row then return tonumber(row) end
    return history[1] and history[1].price or nil
end

-- ── helpers ─────────────────────────────────────────────────────────

local function playerOf(src) return exports['pfm-core']:GetPlayer(src) end

-- one trade per player per second from the app (the phone has its own limits)
local last = {}
local function onCooldown(cid)
    local now = GetGameTimer()
    if last[cid] and now - last[cid] < 1000 then return true end
    last[cid] = now
    return false
end

local function trade(src, fn)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    if onCooldown(Player.PlayerData.citizenid) then return { ok = false, error = 'slow_down' } end
    local res = fn(Player)
    if res.ok then
        res.wallet = { coins = tonumber(Player.PlayerData.money.crypto) or 0, bank = tonumber(Player.PlayerData.money.bank) or 0 }
    end
    return res
end

-- ── handlers ────────────────────────────────────────────────────────

function A.Market(src)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local price = tonumber(Crypto.Worth[COIN]) or 0
    local history = A.PriceHistory(COIN, 96)
    local dayAgo = dayAgoPrice(COIN, history)
    local coins = tonumber(Player.PlayerData.money.crypto) or 0
    local ex = Crypto.Exchange.coords
    return {
        ok = true, coin = COIN, label = Crypto.Labels[COIN] or COIN, price = price, history = history,
        change = dayAgo and dayAgo > 0 and { from = dayAgo, abs = price - dayAgo, pct = math.floor(((price - dayAgo) / dayAgo) * 10000 + 0.5) / 100 } or nil,
        lower = Crypto.Lower, upper = Crypto.Upper, refreshMinutes = math.max(1, tonumber(Crypto.RefreshTimer) or 10),
        maxCoins = Crypto.MaxTransaction or 10000,
        wallet = { coins = coins, value = math.floor(coins * price), walletId = Player.PlayerData.metadata and Player.PlayerData.metadata.walletid or nil },
        bank = tonumber(Player.PlayerData.money.bank) or 0,
        exchange = { x = ex.x, y = ex.y, rebooting = Crypto.Exchange.RebootInfo.state == true },
    }
end

function A.History(src)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local cid = Player.PlayerData.citizenid
    local trades = {}
    for _, r in ipairs(MySQL.query.await([[SELECT kind, amount, metadata, UNIX_TIMESTAMP(created_at) AS at FROM pf_transactions
        WHERE (idempotency_key LIKE ? OR idempotency_key LIKE ?) AND state = 'completed' ORDER BY id DESC LIMIT 30]],
        { ('pfm-crypto:buy:%s:%%'):format(cid), ('pfm-crypto:sell:%s:%%'):format(cid) }) or {}) do
        local meta = {}
        if type(r.metadata) == 'string' and r.metadata ~= '' then
            local ok, m = pcall(json.decode, r.metadata)
            if ok and type(m) == 'table' then meta = m end
        end
        trades[#trades + 1] = { side = r.kind == 'sale' and 'sell' or 'buy', total = tonumber(r.amount), coins = tonumber(meta.coins), price = tonumber(meta.price), at = tonumber(r.at) }
    end
    local transfers = {}
    if A.ready then
        for _, r in ipairs(MySQL.query.await([[SELECT from_cid, coins, UNIX_TIMESTAMP(created_at) AS at FROM pf_crypto_transfers
            WHERE from_cid = ? OR to_cid = ? ORDER BY id DESC LIMIT 30]], { cid, cid }) or {}) do
            -- wallets are pseudonymous: the other side is not named
            transfers[#transfers + 1] = { direction = r.from_cid == cid and 'out' or 'in', coins = tonumber(r.coins), at = tonumber(r.at) }
        end
    end
    return { ok = true, trades = trades, transfers = transfers }
end

local handlers = {
    market = function(src) return A.Market(src) end,
    history = function(src) return A.History(src) end,
    buy = function(src, p)
        return trade(src, function() return CryptoTrade.Buy(src, p.coins, p.ref) end)
    end,
    sell = function(src, p)
        return trade(src, function() return CryptoTrade.Sell(src, p.coins, p.ref) end)
    end,
    send = function(src, p)
        if type(p.walletId) ~= 'string' or type(p.ref) ~= 'string' then return { ok = false, error = 'bad_request' } end
        return trade(src, function() return CryptoTrade.Send(src, p.walletId, p.coins, p.ref) end)
    end,
}
A.Handlers = handlers

function A.Register()
    if GetResourceState('pf-devices') ~= 'started' then return false end
    local devices = exports['pf-devices']
    devices:RegisterApp({
        id = APP_ID, name = 'Crypto', icon = '🪙', entry = 'html/apps/crypto.js', styles = { 'html/apps/crypto.css' },
        devices = { 'tablet', 'computer' }, category = 'apps', order = 7, access = { anyone = true },
        window = { width = 900, height = 620 },
        description = 'The Qbit market: price, wallet, buy, sell and send',
    })
    devices:RegisterAppHandlers(APP_ID, handlers)
    return true
end

function A.Start()
    local ok, res = pcall(function() return exports['pfm-core']:RunMigrations(GetCurrentResourceName(), A.Migrations) end)
    A.ready = ok and res ~= false
    if A.ready then
        -- keep two weeks of price points
        pcall(function() MySQL.query.await('DELETE FROM pf_crypto_prices WHERE created_at < (NOW() - INTERVAL 14 DAY)') end)
    else
        print('^1[pfm-crypto]^7 migrations failed, price history and app transfers disabled: ' .. tostring(res))
    end
    A.Register()
    return A.ready
end

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then CreateThread(A.Start)
    elseif resource == 'pf-devices' then A.Register() end
end)
AddEventHandler('pf-devices:server:ready', function() A.Register() end)

function A.__reset() last = {} end
