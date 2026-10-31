-- A deleted character's banking rows (pfm-core fires 'pfm-core:server:characterDeleted' after it removed
-- the character's players and bank_accounts rows).
--
--   * memberships in shared/business accounts and every card the character held are removed;
--   * an IBAN account the character owned passes to its strongest remaining member (managers first);
--     with no member left, its balance is closed out through the ledger to system:closed_accounts and
--     the account is deleted;
--   * active loans and credit card debt are written off (status 'written_off'), the credit score row and
--     the personal IBAN are removed, so nobody can pay into a character that no longer exists;
--   * the character's own history lines (bank_transactions 'personal:<cid>', legacy checking statements)
--     are removed. pf_transactions is the audit trail and is never touched.

BankingCharacters = BankingCharacters or {}
local C = BankingCharacters
local L = PFLedger

local function closeOrphanAccount(citizenid, acct)
    local balance = tonumber(acct.balance) or 0
    if balance > 0 then
        local res = L.Transfer({
            from = 'acct:' .. acct.id, to = 'system:closed_accounts', amount = balance,
            key = ('chardelete:%s:acct:%d'):format(citizenid, acct.id), kind = 'account_closed',
            reason = 'Account closed: owner deleted', actor = 'system',
        })
        if not res.ok then
            print(('^1[pfm-banking]^7 account %d of deleted character %s not closed: %s'):format(acct.id, citizenid, tostring(res.error)))
            return false
        end
    end
    -- conditional on an empty balance: a deposit that landed meanwhile keeps the account alive
    local deleted = tonumber(MySQL.update.await('DELETE FROM bank_accounts_v2 WHERE id = ? AND balance = 0', { acct.id })) or 0
    if deleted > 0 then
        MySQL.update.await('DELETE FROM bank_account_cards WHERE account_id = ?', { acct.id })
        MySQL.update.await('DELETE FROM bank_account_members WHERE account_id = ?', { acct.id })
    end
    return deleted > 0
end

--- Clears or hands over every banking row of a deleted character. Returns a summary for logs/tests.
function C.Remove(citizenid)
    local summary = { handedOver = 0, closed = 0, loans = 0, cards = 0 }
    local owned = MySQL.query.await('SELECT id, balance, label FROM bank_accounts_v2 WHERE owner = ?', { citizenid }) or {}
    for _, acct in ipairs(owned) do
        local heir = MySQL.scalar.await([[SELECT citizenid FROM bank_account_members WHERE account_id = ? AND citizenid <> ?
            ORDER BY can_manage DESC, can_withdraw DESC, can_deposit DESC, citizenid ASC LIMIT 1]], { acct.id, citizenid })
        if heir then
            MySQL.update.await('UPDATE bank_accounts_v2 SET owner = ? WHERE id = ? AND owner = ?', { heir, acct.id, citizenid })
            MySQL.update.await('UPDATE bank_account_members SET can_withdraw = 1, can_deposit = 1, can_cards = 1, can_manage = 1 WHERE account_id = ? AND citizenid = ?', { acct.id, heir })
            summary.handedOver = summary.handedOver + 1
        elseif closeOrphanAccount(citizenid, acct) then
            summary.closed = summary.closed + 1
        end
    end

    MySQL.update.await('DELETE FROM bank_account_members WHERE citizenid = ?', { citizenid })
    MySQL.update.await('DELETE FROM bank_account_cards WHERE citizenid = ?', { citizenid })
    MySQL.update.await('DELETE FROM bank_personal_iban WHERE citizenid = ?', { citizenid })
    MySQL.update.await('DELETE FROM bank_credit WHERE citizenid = ?', { citizenid })
    summary.loans = tonumber(MySQL.update.await("UPDATE bank_loans SET status = 'written_off' WHERE citizenid = ? AND status = 'active'", { citizenid })) or 0
    summary.cards = tonumber(MySQL.update.await("UPDATE bank_cards SET status = 'written_off' WHERE citizenid = ? AND status = 'active'", { citizenid })) or 0
    MySQL.update.await('DELETE FROM bank_transactions WHERE account_ref = ?', { 'personal:' .. citizenid })
    MySQL.update.await("DELETE FROM bank_statements WHERE citizenid = ? AND account_name = 'checking'", { citizenid })
    if BankingInternal and BankingInternal.forgetCitizen then BankingInternal.forgetCitizen(citizenid) end
    return summary
end

-- server only (pfm-core raises it with TriggerEvent; a call from a player is ignored)
AddEventHandler('pfm-core:server:characterDeleted', function(citizenid)
    local src = tonumber(source)
    if src and src > 0 then return end
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 50 or not citizenid:match('^[%w]+$') then return end
    local ok, err = pcall(C.Remove, citizenid)
    if not ok then print(('^1[pfm-banking]^7 cleanup of deleted character %s failed: %s'):format(citizenid, tostring(err))) end
end)
