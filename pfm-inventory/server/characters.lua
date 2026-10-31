-- A deleted character's car trunks and gloveboxes. pfm-core deletes player_vehicles and then raises the
-- server-only event 'pfm-core:server:characterDeleted' with the plates the character owned
-- (deleted.plates, read before the delete); a call from a player is ignored.
-- The stashes are 'trunk-<plate>' / 'glovebox-<plate>'. The client names them from the plate text the
-- game returns, which may carry padding spaces, so every cached stash whose trimmed plate matches is
-- removed, from memory and from the inventories table. A stash someone has open right now is emptied
-- instead (its viewer's close then saves it empty). Running it twice changes nothing the second time.

PFInvCharacters = PFInvCharacters or {}
local C = PFInvCharacters

local MAX_PLATES = 200
local KINDS = { trunk = true, glovebox = true }

local function validCitizenId(citizenid)
    return type(citizenid) == 'string' and citizenid ~= '' and #citizenid <= 50 and citizenid:match('^[%w]+$') ~= nil
end

local function trimPlate(plate)
    return (tostring(plate or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

--- The stash ids of these plates: the exact names, plus every cached stash whose trimmed plate matches.
function C.StashIds(plates)
    local wanted, ids, seen = {}, {}, {}
    local function add(id)
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    for i, plate in ipairs(type(plates) == 'table' and plates or {}) do
        if i > MAX_PLATES then break end
        if type(plate) == 'string' and #plate <= 16 then
            local p = trimPlate(plate)
            if p ~= '' then
                wanted[p] = true
                add('trunk-' .. p)
                add('glovebox-' .. p)
            end
        end
    end
    if next(wanted) == nil then return ids end
    for id in pairs(Inventories or {}) do
        if type(id) == 'string' then
            local kind, rest = id:match('^(%a+)%-(.+)$')
            if kind and KINDS[kind] and wanted[trimPlate(rest)] then add(id) end
        end
    end
    table.sort(ids)
    return ids
end

--- Returns the number of stashes cleared.
function C.Remove(plates)
    local ids = C.StashIds(plates)
    for _, id in ipairs(ids) do
        local inv = Inventories and Inventories[id]
        if inv and inv.isOpen then
            inv.items = {}
        elseif inv then
            Inventories[id] = nil
        end
        MySQL.query.await('DELETE FROM inventories WHERE identifier = ?', { id })
    end
    return #ids
end

AddEventHandler('pfm-core:server:characterDeleted', function(citizenid, deleted)
    local src = tonumber(source)
    if src and src > 0 then return end
    if not validCitizenId(citizenid) or type(deleted) ~= 'table' or type(deleted.plates) ~= 'table' then return end
    local ok, err = pcall(C.Remove, deleted.plates)
    if not ok then print(('^1[pfm-inventory]^7 vehicle stash cleanup of deleted character %s failed: %s'):format(citizenid, tostring(err))) end
end)
