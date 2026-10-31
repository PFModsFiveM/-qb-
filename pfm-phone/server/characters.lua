-- A deleted character's phone photos and tweets. pfm-core raises the server-only event
-- 'pfm-core:server:characterDeleted' after it removed the character (its phone_messages, contacts,
-- mails and invoices go with the framework tables); a call from a player is ignored.
-- phone_gallery and phone_tweets come from qb-phone.sql; each is cleared on its own, so a missing
-- table does not stop the other. Running it twice changes nothing the second time.

PFPhoneCharacters = PFPhoneCharacters or {}
local C = PFPhoneCharacters

C.Steps = {
    { name = 'gallery', sql = 'DELETE FROM phone_gallery WHERE citizenid = ?' },
    { name = 'tweets', sql = 'DELETE FROM phone_tweets WHERE citizenid = ?' },
}

local function validCitizenId(citizenid)
    return type(citizenid) == 'string' and citizenid ~= '' and #citizenid <= 50 and citizenid:match('^[%w]+$') ~= nil
end

--- Returns { [step name] = rows removed or false when that step failed }.
function C.Remove(citizenid)
    local out = {}
    for _, step in ipairs(C.Steps) do
        local ok, n = pcall(MySQL.update.await, step.sql, { citizenid })
        if ok then
            out[step.name] = tonumber(n) or 0
        else
            out[step.name] = false
            print(('^1[pfm-phone]^7 cleanup (%s) of deleted character %s failed: %s'):format(step.name, citizenid, tostring(n)))
        end
    end
    return out
end

AddEventHandler('pfm-core:server:characterDeleted', function(citizenid)
    local src = tonumber(source)
    if src and src > 0 then return end
    if not validCitizenId(citizenid) then return end
    local removed = C.Remove(citizenid)
    if removed.tweets and removed.tweets > 0 and PFPhoneForgetTweets then PFPhoneForgetTweets() end
end)
