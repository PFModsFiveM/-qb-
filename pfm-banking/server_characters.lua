-- A deleted character's banking rows (pfm-core fires 'pfm-core:server:characterDeleted' after it removed
-- the character's players and bank_accounts rows).
--
--   * memberships in shared/business accounts and every card the character held are removed;
--   * an IBAN account the character owned passes to its strongest remaining member (managers first);
--     with no member left, its balance is closed out through the ledger to system:closed_accounts and
--     the account is deleted;
--   * the credit score row and the personal IBAN are removed, so nobody can pay into a character that
--     no longer exists;
--   * a player may not delete a character that still owes the bank (CanDeleteCharacter: an active loan,
--     a credit card balance, a negative bank balance), or they could borrow on an alt, move the money
--     to their main character and delete the alt. Only an admin delete (/deletechar) gets this far with
--     debt: its active loans and cards are written off (status 'written_off') and the write-off is logged;
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

local function validCitizenId(citizenid)
    return type(citizenid) == 'string' and citizenid ~= '' and #citizenid <= 50 and citizenid:match('^[%w]+$') ~= nil
end

--- What the character still owes the bank: { loans = n, loanBalance, cards = n, cardBalance, bank = balance
--- when it is negative or nil }.
function C.Debt(citizenid)
    local debt = { loans = 0, loanBalance = 0, cards = 0, cardBalance = 0 }
    local loan = MySQL.single.await("SELECT COUNT(*) AS n, COALESCE(SUM(balance), 0) AS owed FROM bank_loans WHERE citizenid = ? AND status = 'active'", { citizenid })
    debt.loans, debt.loanBalance = tonumber(loan and loan.n) or 0, tonumber(loan and loan.owed) or 0
    local card = MySQL.single.await("SELECT COUNT(*) AS n, COALESCE(SUM(balance), 0) AS owed FROM bank_cards WHERE citizenid = ? AND status = 'active' AND balance > 0", { citizenid })
    debt.cards, debt.cardBalance = tonumber(card and card.n) or 0, tonumber(card and card.owed) or 0
    -- pfm-core lets the bank balance go below zero (only cash and crypto may not)
    local money = MySQL.scalar.await('SELECT money FROM players WHERE citizenid = ? LIMIT 1', { citizenid })
    local decoded = type(money) == 'string' and json.decode(money) or nil
    local bank = type(decoded) == 'table' and tonumber(decoded.bank) or nil
    if bank and bank < 0 then debt.bank = bank end
    return debt
end

--- true when a player may delete the character, or false, 'unpaid_debt' (or 'invalid_character').
--- Errors are not caught: the caller (pfm-core) refuses the delete when this fails.
function C.CanDelete(citizenid)
    if not validCitizenId(citizenid) then return false, 'invalid_character' end
    local debt = C.Debt(citizenid)
    if debt.loans > 0 or debt.cards > 0 or debt.bank then return false, 'unpaid_debt' end
    return true
end

-- server only: exports are not reachable from clients
exports('CanDeleteCharacter', function(citizenid) return C.CanDelete(citizenid) end)

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
    -- only an admin delete reaches here with debt (a player's delete is refused by CanDeleteCharacter)
    local okDebt, owed = pcall(C.Debt, citizenid)
    if not okDebt then owed = { loans = 0, loanBalance = 0, cards = 0, cardBalance = 0 } end
    summary.loans = tonumber(MySQL.update.await("UPDATE bank_loans SET status = 'written_off' WHERE citizenid = ? AND status = 'active'", { citizenid })) or 0
    summary.cards = tonumber(MySQL.update.await("UPDATE bank_cards SET status = 'written_off' WHERE citizenid = ? AND status = 'active'", { citizenid })) or 0
    MySQL.update.await('DELETE FROM bank_transactions WHERE account_ref = ?', { 'personal:' .. citizenid })
    MySQL.update.await("DELETE FROM bank_statements WHERE citizenid = ? AND account_name = 'checking'", { citizenid })
    if BankingInternal and BankingInternal.forgetCitizen then BankingInternal.forgetCitizen(citizenid) end
    if summary.loans > 0 or owed.cardBalance > 0 then
        summary.writtenOff = owed.loanBalance + owed.cardBalance
        local msg = ('Deleted character %s: %d loan(s) ($%s) and %d credit card(s) ($%s) written off'):format(citizenid,
            summary.loans, tostring(owed.loanBalance), owed.cards, tostring(owed.cardBalance))
        print('^3[pfm-banking]^7 ' .. msg)
        TriggerEvent('qb-log:server:CreateLog', 'banking', 'Debt Written Off', 'red', msg)
    end
    return summary
end

-- server only (pfm-core raises it with TriggerEvent; a call from a player is ignored)
AddEventHandler('pfm-core:server:characterDeleted', function(citizenid)
    local src = tonumber(source)
    if src and src > 0 then return end
    if not validCitizenId(citizenid) then return end
    local ok, err = pcall(C.Remove, citizenid)
    if not ok then print(('^1[pfm-banking]^7 cleanup of deleted character %s failed: %s'):format(citizenid, tostring(err))) end
end)
