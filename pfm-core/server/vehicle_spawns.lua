-- Who may spawn which vehicle through 'QBCore:Server:SpawnVehicle' / 'QBCore:Server:CreateVehicle'.
-- Those callbacks used to spawn any model a client named, anywhere, as often as it liked. Now a
-- spawn needs one of:
--   * a job rule: the player's current job (on duty, unless the rule says otherwise) may spawn the
--     model. Job resources register their own garage lists with RegisterJobVehicles.
--   * a spawn ticket: a server flow (a paid deposit, a bought or returned car) grants the player one
--     spawn of one model with GrantVehicleSpawn, used up by the spawn.
-- The spawn point must be near the player, and spawns are rate limited per player.

PFVehicleSpawns = PFVehicleSpawns or { jobs = {}, tickets = {}, last = {} }
local V = PFVehicleSpawns

V.MAX_DISTANCE = 150.0     -- metres between the player and the spawn point
V.COOLDOWN_SECONDS = 3
V.TICKET_SECONDS = 120

local function modelHash(model)
    if type(model) == 'string' then return joaat(model) & 0xFFFFFFFF end
    if type(model) == 'number' then return math.floor(model) & 0xFFFFFFFF end
    return nil
end

--- Lets players with `job` spawn these models. opts.anyDuty: no on-duty requirement;
--- opts.catalog: also any model in the shared vehicle list (police impound returns owned cars).
function V.RegisterJobVehicles(job, models, opts)
    if type(job) ~= 'string' or type(models) ~= 'table' then return false end
    local rule = V.jobs[job] or { models = {}, anyDuty = false, catalog = false }
    for k, v in pairs(models) do
        -- accepts both lists of names and maps keyed by model name
        local name = type(k) == 'string' and k or v
        local hash = modelHash(name)
        if hash then rule.models[hash] = true end
    end
    if opts and opts.anyDuty then rule.anyDuty = true end
    if opts and opts.catalog then rule.catalog = true end
    V.jobs[job] = rule
    return true
end

--- One spawn of `model` for `source`, valid for a short time.
function V.GrantVehicleSpawn(source, model, seconds)
    local hash = modelHash(model)
    if not hash or not source then return false end
    V.tickets[source] = V.tickets[source] or {}
    V.tickets[source][hash] = os.time() + (tonumber(seconds) or V.TICKET_SECONDS)
    return true
end

local function inCatalog(hash)
    for name in pairs(QBCore.Shared.Vehicles or {}) do
        if modelHash(name) == hash then return true end
    end
    return false
end

--- Returns true when the spawn is allowed (and uses up a ticket if that is what allowed it).
function V.Authorize(source, model, coords)
    local hash = modelHash(model)
    if not hash then return false, 'invalid_model' end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false, 'no_player' end
    if coords ~= nil then
        local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
        if not (x and y and z) or x ~= x or y ~= y or z ~= z then return false, 'invalid_coords' end
        if #(GetEntityCoords(ped) - vector3(x, y, z)) > V.MAX_DISTANCE then return false, 'too_far' end
    end
    local now = os.time()
    if V.last[source] and now - V.last[source] < V.COOLDOWN_SECONDS then return false, 'cooldown' end

    local allowed = false
    local tickets = V.tickets[source]
    if tickets and tickets[hash] and tickets[hash] >= now then
        tickets[hash] = nil
        allowed = true
    else
        local Player = QBCore.Functions.GetPlayer(source)
        local job = Player and Player.PlayerData.job
        local rule = job and V.jobs[job.name]
        if rule and (rule.anyDuty or job.onduty) and (rule.models[hash] or (rule.catalog and inCatalog(hash))) then
            allowed = true
        end
    end
    if not allowed then return false, 'not_allowed' end
    V.last[source] = now
    return true
end

AddEventHandler('playerDropped', function()
    V.tickets[source] = nil
    V.last[source] = nil
end)

exports('RegisterJobVehicles', V.RegisterJobVehicles)
exports('GrantVehicleSpawn', V.GrantVehicleSpawn)
