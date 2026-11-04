-- Scene drops: blood, fingerprints and bullet casings left at a scene, persisted in
-- pf_evidence_scene_drops so they survive a restart.
--
-- Clients report drops (only the shooter's or bleeder's client sees a shot that hits nothing or a
-- drop of blood); the server decides everything else: identity from the source, position from the
-- server ped (the client's position is only a hint within HintRadius), weapon checked against the
-- weapon in hand, serial from the server inventory. Reports are rate limited per player and type,
-- capped per 100 m cell, and sent only to on-duty police within SyncRadius (no broadcast). Officers
-- moving into a new cell, or going on duty, get a snapshot of the drops around them. New drops are
-- written in one multi-row insert every FlushMs (ids are assigned here, so the officers can be told
-- at once). A drop that gets too old is marked 'unrecoverable', never deleted on the spot.

PFEvidence = PFEvidence or {}
local E = PFEvidence
E.Scene = E.Scene or {}
local S = E.Scene
local Store = E.Store

S.drops = S.drops or {}       -- [id] = drop (present only)
S.cells = S.cells or {}       -- [cell] = { [id] = true }
S.cellCount = S.cellCount or {}
S.live = S.live or 0
S.pending = S.pending or {}   -- drops not written yet
S.lastCell = S.lastCell or {} -- [officer src] = cell of the last snapshot
S.owned = S.owned or {}       -- ['<cid>:<kind>'] = { [id] = true } live drops each player left
S.ownedCount = S.ownedCount or {}
S.loaded = S.loaded or false
S.nextId = S.nextId or 0

local KINDS = { blood = true, fingerprint = true, casing = true }
-- the legacy client events per kind
local ADD_EVENT = { blood = 'evidence:client:AddBlooddrop', fingerprint = 'evidence:client:AddFingerPrint', casing = 'evidence:client:AddCasing' }
local REMOVE_EVENT = { blood = 'evidence:client:RemoveBlooddrop', fingerprint = 'evidence:client:RemoveFingerprint', casing = 'evidence:client:RemoveCasing' }

local function sc(key, default)
    local v = E.SceneCfg()[key]
    if v == nil then return default end
    return v
end

function S.Cell(x, y)
    local size = sc('CellSize', 100)
    return ('%d:%d'):format(math.floor(x / size), math.floor(y / size))
end

local function minutesFor(tbl, kind, default)
    local t = sc(tbl, {})
    return tonumber(t[kind]) or default
end

-- ── memory index ──────────────────────────────────────────────────────────────────────────────
local function ownerKey(drop)
    return drop.sourceCid and (drop.sourceCid .. ':' .. drop.kind) or nil
end

local function index(drop)
    S.drops[drop.id] = drop
    local key = ownerKey(drop)
    if key then
        drop.ownerKey = key
        S.owned[key] = S.owned[key] or {}
        S.owned[key][drop.id] = true
        S.ownedCount[key] = (S.ownedCount[key] or 0) + 1
    end
    S.cells[drop.cell] = S.cells[drop.cell] or {}
    S.cells[drop.cell][drop.id] = true
    S.cellCount[drop.cell] = (S.cellCount[drop.cell] or 0) + 1
    S.live = S.live + 1
end

local function unindex(drop)
    if not S.drops[drop.id] then return end
    S.drops[drop.id] = nil
    local key = drop.ownerKey
    if key and S.owned[key] and S.owned[key][drop.id] then
        S.owned[key][drop.id] = nil
        S.ownedCount[key] = (S.ownedCount[key] or 1) - 1
        if S.ownedCount[key] <= 0 then S.owned[key], S.ownedCount[key] = nil, nil end
    end
    local cell = S.cells[drop.cell]
    if cell then
        cell[drop.id] = nil
        S.cellCount[drop.cell] = math.max(0, (S.cellCount[drop.cell] or 1) - 1)
        if S.cellCount[drop.cell] == 0 then S.cells[drop.cell], S.cellCount[drop.cell] = nil, nil end
    end
    S.live = math.max(0, S.live - 1)
end

-- what a client may know about a drop: never who left it
local function publicLabel(drop)
    if drop.kind == 'blood' then return drop.attrs.sampleId end
    if drop.kind == 'casing' then return drop.attrs.weaponHash end
    return nil
end

-- ── audience ──────────────────────────────────────────────────────────────────────────────────
function S.LeoSources()
    local ok, list = pcall(function() return QBCore.Functions.GetPlayersByJob('leo', true) end)
    if ok and type(list) == 'table' then return list end
    local out = {}
    for _, P in pairs(QBCore.Functions.GetQBPlayers() or {}) do
        if E.IsLeo(P) then out[#out + 1] = P.PlayerData.source end
    end
    return out
end

--- On-duty police within SyncRadius of `pos` (server positions).
function S.Audience(pos)
    local radius = sc('SyncRadius', 150.0)
    local out = {}
    for _, src in ipairs(S.LeoSources()) do
        src = tonumber(src)
        if src and E.Dist(E.Pos(src), pos) <= radius then out[#out + 1] = src end
    end
    return out
end

local function sendAdd(drop)
    local coords = vector3(drop.x, drop.y, drop.z)
    for _, src in ipairs(S.Audience(coords)) do
        if drop.kind == 'blood' then
            TriggerClientEvent(ADD_EVENT.blood, src, drop.id, publicLabel(drop), nil, coords)
        elseif drop.kind == 'fingerprint' then
            TriggerClientEvent(ADD_EVENT.fingerprint, src, drop.id, nil, coords)
        else
            TriggerClientEvent(ADD_EVENT.casing, src, drop.id, publicLabel(drop), coords, nil)
        end
    end
end

local function sendRemove(drops)
    -- one message per officer per kind
    local byOfficer = {}
    for _, drop in ipairs(drops) do
        for _, src in ipairs(S.Audience(vector3(drop.x, drop.y, drop.z))) do
            byOfficer[src] = byOfficer[src] or {}
            byOfficer[src][#byOfficer[src] + 1] = drop
        end
    end
    for src, list in pairs(byOfficer) do
        for _, drop in ipairs(list) do TriggerClientEvent(REMOVE_EVENT[drop.kind], src, drop.id) end
    end
end

--- Every present drop within SyncRadius of `pos` (at most 500).
function S.Around(pos)
    local radius, size = sc('SyncRadius', 150.0), sc('CellSize', 100)
    local reach = math.ceil(radius / size)
    local cx, cy = math.floor(pos.x / size), math.floor(pos.y / size)
    local out = {}
    for dx = -reach, reach do
        for dy = -reach, reach do
            local cell = S.cells[('%d:%d'):format(cx + dx, cy + dy)]
            for id in pairs(cell or {}) do
                local d = S.drops[id]
                if d and E.Dist(pos, d) <= radius then
                    out[#out + 1] = { id = d.id, kind = d.kind, x = d.x, y = d.y, z = d.z, label = publicLabel(d) }
                    if #out >= 500 then return out end
                end
            end
        end
    end
    return out
end

function S.SendSnapshot(src)
    src = tonumber(src)
    if not src then return end
    local pos = E.Pos(src)
    S.lastCell[src] = S.Cell(pos.x, pos.y)
    TriggerClientEvent('evidence:client:SceneSnapshot', src, S.Around(pos))
end

--- Officers who moved into another cell get a fresh snapshot; officers no longer on duty get an
--- empty one (their client forgets the drops).
function S.SyncTick()
    local seen = {}
    for _, src in ipairs(S.LeoSources()) do
        src = tonumber(src)
        if src then
            seen[src] = true
            local pos = E.Pos(src)
            local cell = S.Cell(pos.x, pos.y)
            if S.lastCell[src] ~= cell then S.SendSnapshot(src) end
        end
    end
    for src in pairs(S.lastCell) do
        if not seen[src] then
            S.lastCell[src] = nil
            TriggerClientEvent('evidence:client:SceneSnapshot', src, {})
        end
    end
end

--- A player at their own live cap for a kind loses their oldest drop of that kind (never anyone
--- else's), so one client cannot fill the server's or a cell's capacity. The row is kept as
--- 'unrecoverable' (a drop not yet written is simply forgotten).
function S.EvictOldest(key)
    local oldest
    for id in pairs(S.owned[key] or {}) do
        if not oldest or id < oldest then oldest = id end
    end
    local drop = oldest and S.drops[oldest]
    if not drop then return false end
    if drop.persisted then
        Store.Query('update', "UPDATE pf_evidence_scene_drops SET state = 'unrecoverable' WHERE id = ? AND state = 'present'", { drop.id })
    else
        for i = #S.pending, 1, -1 do
            if S.pending[i] == drop then table.remove(S.pending, i) end
        end
    end
    unindex(drop)
    sendRemove({ drop })
    return true
end

-- ── reports ───────────────────────────────────────────────────────────────────────────────────
local function weaponDef(hash)
    hash = E.Int(hash)
    if not hash then return nil end
    local weapons = E.sharedWeapons or {}
    if weapons[hash] then return weapons[hash], hash end
    local alt = hash >= 2147483648 and hash - 4294967296 or hash + 4294967296
    if weapons[alt] then return weapons[alt], alt end
    return nil
end
S.WeaponDef = weaponDef

local function sameHash(a, b) return (a - b) % 4294967296 == 0 end

--- Server position for a drop from the client's hint: refused when the hint is far from the ped.
local function dropPosition(src, hint)
    local ped = E.Pos(src)
    local c = E.Coords(hint)
    if not c then return nil end
    local d = E.Dist(ped, c)
    if d > sc('HintRadius', 10.0) then return nil end
    if d <= sc('ExactRadius', 3.0) then return c end
    return vector3(ped.x, ped.y, ped.z)
end

local function weaponSerial(P, weaponName)
    for _, item in pairs(P.PlayerData.items or {}) do
        if type(item) == 'table' and item.name == weaponName then
            local info = item.info
            if type(info) == 'table' and info.serie ~= nil then return E.Str(tostring(info.serie), 32) end
            return nil
        end
    end
    return nil
end

--- A client's report of a drop at its own position. Returns the drop, or nil and a reason.
function S.Report(src, kind, data)
    src = tonumber(src)
    if not src or src <= 0 or not KINDS[kind] then return nil, 'bad_args' end
    if not E.Rate(src .. ':drop:' .. kind, sc('RatePerSecond', 5), sc('RateBurst', 5)) then return nil, 'rate_limited' end
    if not S.loaded then return nil, 'db_unavailable' end
    local P = E.Player(src)
    if not P then return nil, 'offline' end
    local pos = dropPosition(src, data.coords)
    if not pos then return nil, 'too_far' end
    local cell = S.Cell(pos.x, pos.y)
    local key = P.PlayerData.citizenid .. ':' .. kind
    if (S.cellCount[cell] or 0) >= sc('MaxPerCell', 200) or S.live >= sc('MaxLive', 6000) then return nil, 'conflict' end
    if (S.ownedCount[key] or 0) >= sc('MaxPerPlayer', 50) then S.EvictOldest(key) end

    local attrs = { clientReported = true }
    if kind == 'blood' then
        -- a random sample id: the bag must not name whose blood it is (the lab does that, batch 18)
        attrs.sampleId = 'S-' .. E.RandomHex(8):upper()
        attrs.bloodtype = E.Str(P.PlayerData.metadata and P.PlayerData.metadata.bloodtype, 8)
    elseif kind == 'fingerprint' then
        attrs.printId = E.Str(P.PlayerData.metadata and P.PlayerData.metadata.fingerprint, 32)
        if not attrs.printId then return nil, 'bad_args' end
    else
        local def, hash = weaponDef(data.weapon)
        if not def then return nil, 'bad_args' end
        -- the weapon in hand as the server sees it (0 when it cannot tell) must be the reported one
        local seen = tonumber(GetSelectedPedWeapon(GetPlayerPed(src))) or 0
        if seen ~= 0 and not sameHash(seen, hash) then return nil, 'bad_args' end
        attrs.weaponHash = hash
        attrs.weapon = E.Str(def.label or def.name, 50)
        attrs.caliber = def.ammotype and Config.AmmoLabels and Config.AmmoLabels[def.ammotype] or nil
        attrs.serial = weaponSerial(P, def.name)
    end

    local now = E.Now()
    S.nextId = S.nextId + 1
    local drop = {
        id = S.nextId, kind = kind, x = math.floor(pos.x * 100 + 0.5) / 100, y = math.floor(pos.y * 100 + 0.5) / 100,
        z = math.floor(pos.z * 100 + 0.5) / 100, cell = cell, attrs = attrs, sourceCid = P.PlayerData.citizenid,
        createdAt = now, decayAt = now + minutesFor('LifetimeMinutes', kind, 240) * 60, persisted = false,
    }
    index(drop)
    S.pending[#S.pending + 1] = drop
    sendAdd(drop)
    return drop
end

-- ── persistence ───────────────────────────────────────────────────────────────────────────────
local INSERT_HEAD = 'INSERT IGNORE INTO pf_evidence_scene_drops (id, kind, x, y, z, cell, attrs, source_cid, state, created_at, decay_at) VALUES '

--- Writes the pending drops (100 per statement). Returns how many were written.
function S.Flush()
    if #S.pending == 0 or not E.DbReady() then return 0 end
    local written = 0
    while #S.pending > 0 do
        local batch, values, params = {}, {}, {}
        for i = 1, math.min(100, #S.pending) do
            local d = S.pending[i]
            batch[#batch + 1] = d
            values[#values + 1] = "(?, ?, ?, ?, ?, ?, ?, ?, 'present', ?, ?)"
            for _, v in ipairs({ d.id, d.kind, d.x, d.y, d.z, d.cell, json.encode(d.attrs), d.sourceCid, d.createdAt, d.decayAt }) do
                params[#params + 1] = v
            end
        end
        local _, ok = Store.Query('query', INSERT_HEAD .. table.concat(values, ', '), params)
        if not ok then break end -- kept for the next flush (INSERT IGNORE makes the retry safe)
        for i = #batch, 1, -1 do
            batch[i].persisted = true
            table.remove(S.pending, i)
        end
        written = written + #batch
    end
    return written
end

--- Loads the present drops after a restart.
function S.Load()
    if not E.DbReady() then return false end
    local maxId = Store.Query('scalar', 'SELECT COALESCE(MAX(id), 0) FROM pf_evidence_scene_drops', {})
    S.nextId = math.max(S.nextId, math.floor(tonumber(maxId) or 0))
    local now = E.Now()
    local rows = Store.Query('query', [[SELECT id, kind, x, y, z, cell, attrs, source_cid, created_at, decay_at
        FROM pf_evidence_scene_drops WHERE state = 'present' AND decay_at > ? ORDER BY id DESC LIMIT ?]], { now, sc('MaxLive', 6000) })
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local id = math.floor(tonumber(r.id))
        if not S.drops[id] and KINDS[r.kind] then
            index({
                id = id, kind = r.kind, x = tonumber(r.x), y = tonumber(r.y), z = tonumber(r.z), cell = r.cell,
                attrs = json.decode(r.attrs or '{}') or {}, sourceCid = r.source_cid, createdAt = tonumber(r.created_at),
                decayAt = tonumber(r.decay_at), persisted = true,
            })
        end
    end
    S.loaded = true
    S.Decay(now)
    return true
end

--- Marks old drops 'unrecoverable' (kept as rows) and tells nearby officers.
function S.Decay(now)
    now = now or E.Now()
    S.Flush()
    local expired = {}
    for _, d in pairs(S.drops) do
        if d.decayAt <= now then expired[#expired + 1] = d end
    end
    if E.DbReady() then
        Store.Query('update', "UPDATE pf_evidence_scene_drops SET state = 'unrecoverable' WHERE state = 'present' AND decay_at <= ?", { now })
    end
    for _, d in ipairs(expired) do unindex(d) end
    if #expired > 0 then sendRemove(expired) end
    return #expired
end

--- Deletes old unrecoverable/cleared rows in batches (collected rows stay: the lab needs them).
function S.SweepRetention(now)
    local days = sc('RetentionDays', 30)
    if not days or not E.DbReady() then return 0 end
    local res = Store.Query('query', [[DELETE FROM pf_evidence_scene_drops WHERE state IN ('unrecoverable', 'cleared')
        AND created_at < ? LIMIT 500]], { (now or E.Now()) - days * 86400 })
    return Store.Affected(res)
end

-- ── collecting and clearing (on-duty police) ──────────────────────────────────────────────────
local function notify(src, text, kind) TriggerClientEvent('QBCore:Notify', src, text, kind or 'error') end

--- Bags a drop: an evidence row and an evidence bag built from the stored drop (never from what
--- the collecting client sends). Returns the result table.
function S.Collect(src, kind, dropId, hint)
    src = tonumber(src)
    if not src or src <= 0 then return E.Err('bad_args') end
    local rate = (E.Cfg().Rates or {}).collect or {}
    if not E.Rate(src .. ':collect', rate.perSecond or 2, rate.burst or 4) then return E.Err('rate_limited') end
    local P = E.Player(src)
    if not P or not E.IsLeo(P) then return E.Err('no_permission', 'On-duty police only') end
    local drop = S.drops[E.Int(dropId, 1) or -1]
    if not drop or drop.kind ~= kind then return E.Err('not_found', 'It is gone') end
    if E.Dist(E.Pos(src), drop) > sc('CollectReach', 2.5) then return E.Err('too_far', 'Get closer') end
    if not E.DbReady() then
        notify(src, 'Evidence storage is not ready')
        return E.Err('db_unavailable')
    end
    local lockKey = 'drop:' .. drop.id
    if not E.Lock(lockKey) then return E.Err('busy') end
    local ok, res = pcall(S.CollectLocked, src, P, drop, hint)
    E.Unlock(lockKey)
    if not ok then
        print(('^1[pfm-policejob]^7 collecting drop %d failed: %s'):format(drop.id, tostring(res)))
        return E.Err('db_unavailable')
    end
    return res
end

function S.CollectLocked(src, P, drop, hint)
    local cfg = E.Cfg()
    if not drop.persisted then S.Flush() end
    if not drop.persisted then return E.Err('db_unavailable', 'Evidence storage is not ready') end
    local emptyBag = cfg.EmptyBagItem or 'empty_evidence_bag'
    if not exports['pfm-inventory']:RemoveItem(src, emptyBag, 1, false, 'evidence:collect') then
        notify(src, Lang:t('error.have_evidence_bag'))
        return E.Err('invalid_state', 'No empty evidence bag')
    end

    local now = E.Now()
    local def = (cfg.Kinds or {})[drop.kind] or {}
    local attrs = {}
    for k, v in pairs(drop.attrs) do attrs[k] = v end
    local quality = 100
    local degrade = minutesFor('DegradeMinutes', drop.kind, 0) * 60
    if def.biological and degrade > 0 and now - drop.createdAt > degrade then quality = sc('PartialQuality', 50) end
    if drop.kind == 'fingerprint' then attrs.quality = quality end
    local flags
    if def.contact and Store.GloveRuleActive() and not Store.HasGloves(P) then flags = 'contaminated' end
    local street = type(hint) == 'table' and E.Str(hint.street, 96) or nil
    local cid = P.PlayerData.citizenid
    local fields = {
        kind = drop.kind, label = def.label or drop.kind, attrs = attrs, state = 'sealed', sealed = true, quality = quality,
        flags = flags, holder_kind = 'officer', holder_ref = 'player:' .. cid,
        scene_coords = E.CoordsText(vector3(drop.x, drop.y, drop.z)), scene_label = street, collected_by = cid,
        collected_at = now, method = 'scene', origin_type = 'scene_drop', origin_id = tostring(drop.id),
        idem_key = 'pfm-policejob:drop:' .. drop.id,
    }
    fields.integrity = Store.ComputeIntegrity(fields, {}, now)
    local id, tag = Store.Insert(fields)
    if not id then
        exports['pfm-inventory']:AddItem(src, emptyBag, 1, false, nil, 'evidence:collect refund')
        if tag == 'duplicate' then
            -- an earlier attempt for this drop already made its row: the drop is spent
            S.MarkCollected(drop, nil)
        end
        return E.Err('db_unavailable', 'The evidence could not be recorded')
    end
    fields.id, fields.tag = id, tag
    local row = Store.Get(id) or fields
    local actor = E.Actor({ src = src }) or { kind = 'player', src = src, cid = cid }
    local here = E.Pos(src)
    Store.AddCustody(id, 'collected', 'scene:' .. drop.id, row.holder_ref, actor, nil, here)
    Store.AddCustody(id, 'sealed', row.holder_ref, row.holder_ref, actor, nil, here)
    if not E.Custody.PutBag(row, src) then
        Store.Rollback(id)
        exports['pfm-inventory']:AddItem(src, emptyBag, 1, false, nil, 'evidence:collect refund')
        notify(src, 'No room for the evidence bag')
        return E.Err('invalid_state', 'No room for the evidence bag')
    end
    S.MarkCollected(drop, id)
    TriggerEvent('pfm-policejob:server:evidenceCreated', Store.Public(row))
    return { ok = true, evidenceId = id, tag = tag }
end

function S.MarkCollected(drop, evidenceId)
    Store.Query('update', "UPDATE pf_evidence_scene_drops SET state = 'collected', collected_evidence_id = ? WHERE id = ? AND state = 'present'",
        { evidenceId, drop.id })
    unindex(drop)
    sendRemove({ drop })
end

--- Clean-up of the drops of one kind around the officer (only ids within ClearRadius count).
function S.Clear(src, kind, ids)
    src = tonumber(src)
    if not src or src <= 0 or not KINDS[kind] or type(ids) ~= 'table' then return 0 end
    local rate = (E.Cfg().Rates or {}).clear or {}
    if not E.Rate(src .. ':clear', rate.perSecond or 0.5, rate.burst or 1) then return 0 end
    local P = E.Player(src)
    if not P or not E.IsLeo(P) then return 0 end
    local pos, radius, cleared, n = E.Pos(src), sc('ClearRadius', 12.0), {}, 0
    for _, raw in pairs(ids) do
        n = n + 1
        if n > sc('ClearMaxIds', 200) then break end
        local d = S.drops[E.Int(raw, 1) or -1]
        if d and d.kind == kind and E.Dist(pos, d) <= radius then cleared[#cleared + 1] = d end
    end
    if #cleared == 0 then return 0 end
    S.Flush()
    local idList, marks = {}, {}
    for _, d in ipairs(cleared) do idList[#idList + 1] = d.id; marks[#marks + 1] = '?' end
    Store.Query('update', "UPDATE pf_evidence_scene_drops SET state = 'cleared' WHERE state = 'present' AND id IN (" .. table.concat(marks, ',') .. ')', idList)
    for _, d in ipairs(cleared) do unindex(d) end
    sendRemove(cleared)
    return #cleared
end

function S.ForgetCitizen(citizenid)
    for _, kind in ipairs({ 'blood', 'fingerprint', 'casing' }) do
        local key = citizenid .. ':' .. kind
        for id in pairs(S.owned[key] or {}) do
            local d = S.drops[id]
            if d then d.ownerKey, d.sourceCid = nil, nil end
        end
        S.owned[key], S.ownedCount[key] = nil, nil
    end
end

function S.ForgetSource(src)
    S.lastCell[tonumber(src)] = nil
end

E.sharedWeapons = exports['pfm-core']:GetShared('Weapons') or {}
