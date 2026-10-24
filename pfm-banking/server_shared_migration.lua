-- One model for player shared accounts.
--
-- Shared accounts existed twice: the legacy rows in bank_accounts (account_type 'shared', members in a
-- JSON `users` list, opened from the old account screen) and the IBAN accounts in bank_accounts_v2
-- (members with per-member permissions, cards, IBAN transfers). This moves every legacy shared account
-- into an IBAN account once, at start:
--   * the IBAN account is created with the legacy owner, and a row in pf_shared_account_migration
--     records which legacy account went where (so a restart never creates a second one)
--   * the owner becomes a full member; each listed user keeps what the legacy system allowed them
--     (deposit and withdraw)
--   * the balance moves through the ledger (society:<name> -> acct:<id>), keyed by account and amount,
--     so it is journaled and a retry never moves it twice
-- Legacy rows stay in bank_accounts (at a zero balance) for audit; once moved, the legacy account is
-- no longer offered by the legacy bank screens. Set Config.MigrateLegacySharedAccounts = false to skip.

local function newIban()
    for _ = 1, 20 do
        local iban = 'PF' .. tostring(math.random(10000000, 99999999))
        local taken = MySQL.scalar.await('SELECT 1 FROM bank_accounts_v2 WHERE iban = ?', { iban })
            or MySQL.scalar.await('SELECT 1 FROM bank_personal_iban WHERE iban = ?', { iban })
        if not taken then return iban end
    end
    return nil
end

local function decodeUsers(raw)
    local ok, users = pcall(json.decode, raw or '[]')
    if not ok or type(users) ~= 'table' then return {} end
    local out = {}
    for _, cid in ipairs(users) do
        if type(cid) == 'string' and cid ~= '' then out[#out + 1] = cid end
    end
    return out
end

local function migrateOne(account, mappedId)
    local name = account.account_name
    local id = mappedId
    if not id then
        local iban = newIban()
        if not iban then error('could not allocate an IBAN') end
        id = MySQL.insert.await('INSERT INTO bank_accounts_v2 (iban, label, type, owner) VALUES (?, ?, ?, ?)',
            { iban, tostring(name):sub(1, 50), 'shared', account.citizenid or 'unknown' })
        if not id then error('could not create the IBAN account') end
        MySQL.insert.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, 0)', { 'acct:' .. id })
        MySQL.insert.await('INSERT INTO pf_shared_account_migration (legacy_name, account_id) VALUES (?, ?)', { name, id })
    end

    if account.citizenid then
        MySQL.insert.await([[INSERT IGNORE INTO bank_account_members (account_id, citizenid, can_withdraw, can_deposit, can_cards, can_manage)
            VALUES (?, ?, 1, 1, 1, 1)]], { id, account.citizenid })
    end
    for _, cid in ipairs(decodeUsers(account.users)) do
        MySQL.insert.await([[INSERT IGNORE INTO bank_account_members (account_id, citizenid, can_withdraw, can_deposit, can_cards, can_manage)
            VALUES (?, ?, 1, 1, 0, 0)]], { id, cid })
    end

    local balance = tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0
    if balance > 0 then
        local res = PFLedger.Transfer({
            from = 'society:' .. name, to = 'acct:' .. id, amount = balance,
            key = ('migrate:shared:%s:%d'):format(name, math.floor(balance * 100 + 0.5)),
            kind = 'migration', reason = 'Shared account moved to IBAN accounts', actor = 'system',
        })
        if not res.ok then error('balance move failed: ' .. tostring(res.error)) end
    end
    return id
end

--- Moves legacy shared accounts; returns a set of the legacy names that are now IBAN accounts.
function MigrateLegacySharedAccounts(rows)
    local done = {}
    if Config.MigrateLegacySharedAccounts == false or not PFLedger.ready then return done end
    local mapped = {}
    for _, r in ipairs(MySQL.query.await('SELECT legacy_name, account_id FROM pf_shared_account_migration') or {}) do
        mapped[r.legacy_name] = tonumber(r.account_id)
    end
    for _, account in ipairs(rows or {}) do
        if account.account_type == 'shared' then
            local ok, err = pcall(migrateOne, account, mapped[account.account_name])
            if ok then
                done[account.account_name] = true
            else
                -- left as a legacy account (still usable) and retried on the next start
                print(('^1[pfm-banking]^7 shared account %s not moved: %s'):format(tostring(account.account_name), tostring(err)))
            end
        end
    end
    return done
end
