-- Chain of custody: every change of who holds a piece of evidence is one pf_evidence_custody row.
--
-- Moves are recorded by the server, never typed: pfm-inventory listeners (ItemMoved, ItemAdded,
-- ItemRemoved, ItemDropped) report where an evidence bag went, and the exports below (transfer,
-- seal, links, disposal) do the physical move themselves and write the row. Listeners only queue
-- what they saw (no database wait inside another resource's call); C.Process() records the queue.
-- A bag that leaves an inventory and turns up nowhere within MissingAfterSeconds is flagged missing.

PFEvidence = PFEvidence or {}
local E = PFEvidence
E.Custody = E.Custody or {}
local C = E.Custody
local Store = E.Store

C.queue = C.queue or {}
C.pendingRemoval = C.pendingRemoval or {} -- [evidenceId] = { at, fromRef, actorSrc }
C.suppress = C.suppress or {}             -- [evidenceId] = true while this module moves the bag itself
C.viewers = C.viewers or {}               -- [searched src] = searching src (from InventoryOpened)

local MAX_QUEUE = 2000

-- ── holders ───────────────────────────────────────────────────────────────────────────────────
--- Holder kind and ref of an inventory (pfm-inventory type + identifier).
function C.Holder(invType, invId)
    if invType == 'player' or type(invId) == 'number' then
        local P = E.Player(invId)
        if not P then return 'unknown', 'unknown' end
        return E.IsLeo(P) and 'officer' or 'civilian', 'player:' .. P.PlayerData.citizenid, P
    end
    if type(invId) ~= 'string' or invId == '' then return 'unknown', 'unknown' end
    if invType == 'drop' or invId:find('^drop%-') then return 'ground', ('drop:' .. invId):sub(1, 64) end
    return Store.IsLockerStash(invId) and 'locker' or 'inventory', 'inv:' .. invId:sub(1, 60)
end

local function actorOf(src, note)
    local a = src and E.Actor({ src = src }) or nil
    if a then return a end
    return { kind = 'system', label = note or 'pfm-inventory' }
end

-- ── listeners (queue only) ────────────────────────────────────────────────────────────────────
local function enqueue(obs)
    if #C.queue >= MAX_QUEUE then table.remove(C.queue, 1) end
    C.queue[#C.queue + 1] = obs
    if not C.draining then
        C.draining = true
        CreateThread(function()
            C.Process()
            C.draining = false
        end)
    end
end

local function itemsAt(items, slot)
    slot = tonumber(slot)
    if type(items) ~= 'table' or not slot then return nil end
    local direct = items[slot] or items[tostring(slot)]
    if type(direct) == 'table' and tonumber(direct.slot) == slot then return direct end
    for _, it in pairs(items) do
        if type(it) == 'table' and tonumber(it.slot) == slot then return it end
    end
    return nil
end

local function moveActor(data)
    for _, side in ipairs({ 'fromInventory', 'toInventory' }) do
        local inv = data[side]
        if type(inv) == 'table' and tonumber(inv.isOpen) then return tonumber(inv.isOpen) end
    end
    local f, t = tonumber(data.fromId), tonumber(data.toId)
    if f and t then
        if C.viewers[f] == t then return t end
        if C.viewers[t] == f then return f end
        return t
    end
    return f or t
end

local function observeItem(item, invType, invId, actorSrc, how, extra)
    if not Store.IsBag(item) then return end
    local id = E.Int(item.info.evidenceId, 1)
    if C.suppress[id] then return end
    local kind, ref = C.Holder(invType, invId)
    local obs = { id = id, kind = kind, ref = ref, actorSrc = actorSrc, how = how, tries = 0 }
    if extra then for k, v in pairs(extra) do obs[k] = v end end
    enqueue(obs)
end

function C.OnItemMoved(moveType, data)
    if type(data) ~= 'table' then return end
    local actor = moveActor(data)
    local toItem = itemsAt(data.toInventory and data.toInventory.items, data.toSlot)
    if toItem then observeItem(toItem, data.toType, data.toId, actor, moveType) end
    if moveType == 'swapped' then
        local back = itemsAt(data.fromInventory and data.fromInventory.items, data.fromSlot)
        if back then observeItem(back, data.fromType, data.fromId, actor, moveType) end
    end
end

function C.OnItemAdded(_, data)
    if type(data) ~= 'table' or type(data.item) ~= 'table' then return end
    if not Store.IsBag(data.item) then return end
    local id = E.Int(data.item.info.evidenceId, 1)
    local pending = C.pendingRemoval[id]
    local actor = pending and pending.actorSrc or tonumber(data.toId)
    observeItem(data.item, data.toType, data.toId, actor, 'added', { resource = data.resource })
end

function C.OnItemRemoved(_, data)
    if type(data) ~= 'table' or not Store.IsBag(data.item) then return end
    local id = E.Int(data.item.info.evidenceId, 1)
    if C.suppress[id] then return end
    local _, ref = C.Holder(data.fromType, data.fromId)
    C.pendingRemoval[id] = { at = E.Now(), fromRef = ref, actorSrc = tonumber(data.fromId), resource = data.resource }
end

function C.OnItemDropped(_, data)
    if type(data) ~= 'table' or not Store.IsBag(data.item) then return end
    local id = E.Int(data.item.info.evidenceId, 1)
    local pos = tonumber(data.source) and E.Pos(tonumber(data.source)) or nil
    observeItem(data.item, 'drop', type(data.dropId) == 'string' and data.dropId or ('drop-' .. tostring(data.netId or '?')),
        tonumber(data.source), 'dropped', { pos = pos })
    C.pendingRemoval[id] = nil
end

function C.OnInventoryOpened(_, data)
    if type(data) ~= 'table' then return end
    local searcher, target = tonumber(data.source), tonumber(data.inventoryId)
    if searcher and target and searcher ~= target then C.viewers[target] = searcher end
end

-- ── recording ─────────────────────────────────────────────────────────────────────────────────
local function notifyCustody(row, event)
    TriggerEvent('pfm-policejob:server:evidenceCustody', Store.Public(row), event)
end

--- Writes one custody row and recomputes the integrity; the row is already moved.
function C.Record(row, event, fromRef, toRef, actor, note, pos)
    Store.AddCustody(row.id, event, fromRef, toRef, actor, note, pos)
    Store.Refresh(row)
    notifyCustody(row, { event = event, from = fromRef, to = toRef, actor = actor and (actor.cid or actor.label), note = note, at = E.Now() })
end

--- Records that the bag of `obs.id` is now at obs.ref (obs.kind). Returns 'moved', 'same', 'busy',
--- 'missing' (no such row) or 'db'.
function C.Observe(obs)
    local lockKey = 'ev:' .. obs.id
    if not E.Lock(lockKey) then return 'busy' end
    local ok, res = pcall(function()
        local row = Store.Get(obs.id)
        if not row then return 'missing' end
        C.pendingRemoval[obs.id] = obs.event == 'flagged_missing' and C.pendingRemoval[obs.id] or nil
        if row.holder_ref == obs.ref then return 'same' end
        local fromRef, fromKind = row.holder_ref, row.holder_kind
        local event, state, note = obs.event or 'moved', row.state, nil
        if not obs.event then
            if obs.kind == 'locker' and Store.CanMove(row.state, 'stored') and row.state ~= 'stored' then
                event, state = 'checked_in', 'stored'
            elseif obs.kind == 'locker' then
                event = 'checked_in'
            elseif fromKind == 'locker' and obs.kind == 'officer' and Store.CanMove(row.state, 'in_transit') then
                event, state = 'checked_out', 'in_transit'
            end
            if obs.kind == 'civilian' then note = Store.CIVILIAN_NOTE
            elseif obs.kind == 'ground' then note = 'left on the ground'
            end
            if Store.IsTerminal(row.state) then note = 'bag moved after ' .. row.state end
        end
        if obs.resource and obs.resource ~= 'pfm-inventory' and obs.resource ~= 'qb-inventory' then
            note = ((note and note .. '; ') or '') .. 'by ' .. tostring(obs.resource):sub(1, 40)
        end
        if not Store.Move(row, obs.kind, obs.ref, state) then return 'db' end
        local actor = actorOf(obs.actorSrc, obs.resource)
        local pos = obs.pos or (actor.src and E.Pos(actor.src)) or nil
        C.Record(row, event, fromRef, obs.ref, actor, note, pos)
        return 'moved'
    end)
    E.Unlock(lockKey)
    if not ok then
        print(('^1[pfm-policejob]^7 custody record %s failed: %s'):format(tostring(obs.id), tostring(res)))
        return 'db'
    end
    return res
end

--- Records the queued observations (in order). A busy row is retried on the next pass.
function C.Process()
    if not E.DbReady() then return 0 end
    local list = C.queue
    C.queue = {}
    local done, retry = 0, {}
    for _, obs in ipairs(list) do
        local res = C.Observe(obs)
        if res == 'busy' or res == 'db' then
            obs.tries = (obs.tries or 0) + 1
            if obs.tries < 20 then retry[#retry + 1] = obs end
        else
            done = done + 1
        end
    end
    for _, obs in ipairs(retry) do C.queue[#C.queue + 1] = obs end
    return done
end

--- Flags bags that left an inventory and were seen nowhere since.
function C.CheckRemovals(now)
    now = now or E.Now()
    C.Process()
    local after = E.Cfg().MissingAfterSeconds or 10
    for id, p in pairs(C.pendingRemoval) do
        if now - p.at >= after then
            local res = C.Observe({ id = id, kind = 'unknown', ref = 'unknown', actorSrc = p.actorSrc, event = 'flagged_missing',
                resource = p.resource })
            if res ~= 'busy' then C.pendingRemoval[id] = nil end
        end
    end
end

-- ── the physical bag ──────────────────────────────────────────────────────────────────────────
--- Where the bag of `row` is: inventory identifier (src or stash id), slot, item; or nil, error.
function C.FindBag(row)
    local ref = row.holder_ref or ''
    local function scan(items)
        for _, it in pairs(type(items) == 'table' and items or {}) do
            if Store.IsBag(it) and E.Int(it.info.evidenceId, 1) == row.id then return it end
        end
    end
    local cid = ref:match('^player:(.+)$')
    if cid then
        local P = exports['pfm-core']:GetPlayerByCitizenId(cid)
        if not P then return nil, 'offline' end
        local it = scan(P.PlayerData.items)
        if not it then return nil, 'not_found' end
        return P.PlayerData.source, tonumber(it.slot), it
    end
    local inv = ref:match('^inv:(.+)$')
    if inv then
        local data = exports['pfm-inventory']:GetInventory(inv)
        local it = data and scan(data.items)
        if not it then return nil, 'not_found' end
        return inv, tonumber(it.slot), it
    end
    return nil, 'not_found'
end

--- Takes the bag out of its inventory (no custody row; the caller writes it).
function C.TakeBag(row)
    local where, slot, item = C.FindBag(row)
    if not where then return nil, slot end
    C.suppress[row.id] = true
    local ok = exports['pfm-inventory']:RemoveItem(where, item.name, 1, slot, 'evidence custody ' .. tostring(row.tag))
    C.suppress[row.id] = nil
    if not ok then return nil, 'not_found' end
    return { where = where, slot = slot, name = item.name, info = item.info }
end

--- Puts a bag (taken, or rebuilt from the row) into an inventory. Returns true or false.
function C.PutBag(row, dest, taken)
    local name = taken and taken.name or Store.BagItemName()
    local info = Store.BagInfo(row)
    C.suppress[row.id] = true
    local ok = exports['pfm-inventory']:AddItem(dest, name, 1, false, info, 'evidence custody ' .. tostring(row.tag))
    C.suppress[row.id] = nil
    if ok and tonumber(dest) then
        TriggerClientEvent('qb-inventory:client:ItemBox', tonumber(dest), (E.sharedItems or {})[name], 'add')
    end
    return ok == true
end

local function restore(row, taken)
    if not taken then return end
    C.suppress[row.id] = true
    local ok = exports['pfm-inventory']:AddItem(taken.where, taken.name, 1, taken.slot, taken.info, 'evidence custody rollback')
    if not ok then ok = exports['pfm-inventory']:AddItem(taken.where, taken.name, 1, false, taken.info, 'evidence custody rollback') end
    C.suppress[row.id] = nil
    if not ok then print(('^1[pfm-policejob]^7 CRITICAL: evidence bag %s could not be put back into %s'):format(tostring(row.tag), tostring(taken.where))) end
end

--- Rewrites the bag's info after a seal change (the inventory tooltip shows it).
function C.RefreshBagInfo(row)
    local where, slot, item = C.FindBag(row)
    if not where then return false end
    if tonumber(where) then
        return exports['pfm-inventory']:SetItemData(where, item.name, 'info', Store.BagInfo(row), slot) == true
    end
    C.suppress[row.id] = true
    local ok = exports['pfm-inventory']:RemoveItem(where, item.name, 1, slot, 'evidence seal')
    if ok then ok = exports['pfm-inventory']:AddItem(where, item.name, 1, slot, Store.BagInfo(row), 'evidence seal') end
    C.suppress[row.id] = nil
    return ok == true
end

-- ── authorization helpers ─────────────────────────────────────────────────────────────────────
local function holds(actor, row)
    return actor.cid ~= nil and row.holder_ref == 'player:' .. actor.cid
end

--- Players need on-duty LEO; system callers passed the export allowlist already.
local function requireLeo(actor)
    if actor.kind == 'system' or actor.admin then return nil end
    if not actor.leo then return E.Err('no_permission', 'On-duty police only') end
    return nil
end

local function mayHandle(actor, row)
    if actor.kind == 'system' or actor.admin or actor.supervisor then return true end
    if holds(actor, row) then return true end
    -- whoever stands at the locker it is stored in may take it out; records (photos...) have no holder
    if row.holder_kind == 'locker' or row.holder_kind == 'record' then return true end
    return false
end

--- A player may only take a bag from their own pockets, from an officer next to them, or from the
--- evidence locker they stand at; system callers and evidence at a lab or court have no reach rule.
local function reachable(actor, row)
    if actor.kind ~= 'player' or actor.admin or holds(actor, row) then return true end
    local ref = row.holder_ref or ''
    local cid = ref:match('^player:(.+)$')
    if cid then
        local P = exports['pfm-core']:GetPlayerByCitizenId(cid)
        return P ~= nil and E.Dist(E.Pos(actor.src), E.Pos(P.PlayerData.source)) <= (E.Cfg().HandoverReach or 2.5)
    end
    local inv = ref:match('^inv:(.+)$')
    if inv then
        local at = Store.LockerLocation(inv)
        return at ~= nil and E.Dist(E.Pos(actor.src), at) <= (E.Cfg().LockerReach or 3.0)
    end
    return true
end

local function withRow(id, fn)
    id = E.Int(id, 1)
    if not id then return E.Err('bad_args', 'Unknown evidence id') end
    if not E.DbReady() then return E.Err('db_unavailable', 'Evidence storage is not ready') end
    local lockKey = 'ev:' .. id
    if not E.Lock(lockKey) then return E.Err('busy', 'This evidence is being handled; try again') end
    local ok, res = pcall(function()
        local row = Store.Get(id)
        if not row then return E.Err('not_found', 'No such evidence') end
        return fn(row)
    end)
    E.Unlock(lockKey)
    if not ok then
        print(('^1[pfm-policejob]^7 evidence %d: %s'):format(id, tostring(res)))
        return E.Err('db_unavailable', 'The evidence could not be updated')
    end
    return res
end
C.WithRow = withRow

-- ── transfers ─────────────────────────────────────────────────────────────────────────────────
local function isPhysical(row)
    local def = (E.Cfg().Kinds or {})[row.kind] or {}
    return def.physical == true
end
C.IsPhysical = isPhysical

--- TransferEvidence: to = { kind = 'officer', src } | { kind = 'locker', lockerId } | { kind = 'lab', labId }
--- | { kind = 'court', caseId } | { kind = 'release', cid } (release needs opts.courtOrderId).
function C.Transfer(id, to, opts, actor)
    opts = opts or {}
    if type(to) ~= 'table' then return E.Err('bad_args', 'Missing destination') end
    if to.kind == 'release' then
        return C.Dispose(id, 'release', { courtOrderId = opts.courtOrderId, cid = to.cid, note = opts.note }, actor)
    end
    local err = requireLeo(actor)
    if err then return err end
    local note = E.Str(opts.note, 200)

    -- destination first (no database wait for officer/lab/court)
    local dest = {}
    if to.kind == 'officer' then
        local target = E.Player(E.Int(to.src, 1, 65535))
        if not target then return E.Err('offline', 'That officer is not here') end
        if not E.IsLeo(target) then return E.Err('no_permission', 'Evidence can only be handed to an on-duty officer') end
        dest = { kind = 'officer', ref = 'player:' .. target.PlayerData.citizenid, inv = target.PlayerData.source, event = 'handed_over' }
        if actor.src and actor.src ~= target.PlayerData.source then
            if E.Dist(E.Pos(actor.src), E.Pos(target.PlayerData.source)) > (E.Cfg().HandoverReach or 2.5) then
                return E.Err('too_far', 'Stand next to the officer')
            end
        end
    elseif to.kind == 'lab' then
        local labId = E.Ref(to.labId or 'main', 32)
        if not labId then return E.Err('bad_args', 'Bad lab id') end
        dest = { kind = 'lab', ref = 'lab:' .. labId, state = 'at_lab', event = 'submitted_lab' }
    elseif to.kind == 'court' then
        local caseId = E.Ref(to.caseId, 48)
        if not caseId then return E.Err('bad_args', 'Bad court case id') end
        dest = { kind = 'court', ref = 'court:' .. caseId, state = 'in_court', event = 'presented_court' }
    elseif to.kind ~= 'locker' then
        return E.Err('bad_args', 'Unknown destination')
    end

    return withRow(id, function(row)
        if Store.IsTerminal(row.state) then return E.Err('invalid_state', 'Evidence is ' .. row.state) end
        if not mayHandle(actor, row) then return E.Err('no_permission', 'You do not hold this evidence') end
        if not reachable(actor, row) then return E.Err('too_far', 'You are not where the evidence is') end
        if to.kind == 'locker' then
            local locker = Store.ResolveLocker(to.lockerId)
            if not locker then return E.Err('not_found', 'No such evidence locker') end
            local at = Store.LockerLocation(locker.stash_id)
            if actor.src and at and E.Dist(E.Pos(actor.src), at) > (E.Cfg().LockerReach or 3.0) then
                return E.Err('too_far', 'Stand at the evidence locker')
            end
            exports['pfm-inventory']:CreateInventory(locker.stash_id, { label = locker.label, maxweight = 4000000, slots = 500 })
            dest = { kind = 'locker', ref = 'inv:' .. locker.stash_id, inv = locker.stash_id, state = 'stored', event = 'checked_in' }
        end
        if row.holder_ref == dest.ref then
            -- a retried transfer: already done
            return { ok = true, duplicate = true, evidenceId = row.id, tag = row.tag, state = row.state, holder = { kind = row.holder_kind, ref = row.holder_ref } }
        end
        local state = dest.state
        if not state then
            -- an officer carries it: stored or examined evidence is in transit, a fresh bag stays as it is
            state = (row.state == 'collected' or row.state == 'sealed' or row.state == 'in_transit') and row.state or 'in_transit'
            if row.holder_kind == 'locker' then dest.event = 'checked_out' end
        end
        if state ~= row.state and not Store.CanMove(row.state, state) then return E.Err('invalid_state', 'Evidence is ' .. row.state) end

        if not isPhysical(row) and dest.inv then return E.Err('invalid_state', 'This evidence is a record, not an item') end
        local taken
        if isPhysical(row) then
            local fromInventory = row.holder_ref and (row.holder_ref:find('^player:') or row.holder_ref:find('^inv:'))
            local offInventory = row.holder_kind == 'lab' or row.holder_kind == 'court'
            if fromInventory then
                local why
                taken, why = C.TakeBag(row)
                if not taken then
                    return E.Err(why == 'offline' and 'offline' or 'not_found',
                        why == 'offline' and 'Whoever holds it is not in the city' or 'The bag is not where the record says')
                end
            elseif not offInventory then
                -- on the ground or missing: a new bag here would be a second copy of the same item
                return E.Err('not_found', 'The bag is not in anyone\'s hands; pick it up first')
            end
            if dest.inv and not C.PutBag(row, dest.inv, taken) then
                restore(row, taken)
                return E.Err('invalid_state', 'There is no room for the bag')
            end
        end
        local fromRef = row.holder_ref
        if not Store.Move(row, dest.kind, dest.ref, state) then
            -- the record changed underneath: undo the physical move
            if dest.inv and isPhysical(row) then
                local back = { holder_ref = dest.ref, id = row.id, tag = row.tag }
                local again = C.TakeBag(back)
                if again then restore(row, taken) end
            else
                restore(row, taken)
            end
            return E.Err('busy', 'The evidence changed meanwhile; try again')
        end
        C.Record(row, dest.event, fromRef, dest.ref, actor, note, actor.src and E.Pos(actor.src) or nil)
        return { ok = true, evidenceId = row.id, tag = row.tag, state = row.state, holder = { kind = row.holder_kind, ref = row.holder_ref } }
    end)
end

-- ── seals ─────────────────────────────────────────────────────────────────────────────────────
function C.Seal(id, opts, actor)
    local err = requireLeo(actor)
    if err then return err end
    return withRow(id, function(row)
        if Store.IsTerminal(row.state) then return E.Err('invalid_state', 'Evidence is ' .. row.state) end
        if row.sealed then return { ok = true, duplicate = true, evidenceId = row.id, state = row.state } end
        if not mayHandle(actor, row) then return E.Err('no_permission', 'You do not hold this evidence') end
        local state = row.state == 'collected' and 'sealed' or row.state
        local res = Store.Query('update', Store.SQL.setSeal, { 1, state, row.id, row.state, 0 })
        if Store.Affected(res) ~= 1 then return E.Err('busy', 'The evidence changed meanwhile') end
        row.sealed, row.state = true, state
        C.Record(row, 'sealed', row.holder_ref, row.holder_ref, actor, E.Str(opts and opts.note, 200))
        if isPhysical(row) then C.RefreshBagInfo(row) end
        return { ok = true, evidenceId = row.id, state = row.state }
    end)
end

function C.BreakSeal(id, reason, opts, actor)
    local err = requireLeo(actor)
    if err then return err end
    reason = E.Str(reason, 200)
    if not reason then return E.Err('bad_args', 'Say why the seal is broken') end
    return withRow(id, function(row)
        if Store.IsTerminal(row.state) then return E.Err('invalid_state', 'Evidence is ' .. row.state) end
        if not row.sealed then return E.Err('invalid_state', 'The seal is already broken') end
        if not mayHandle(actor, row) and row.holder_kind ~= 'lab' and row.holder_kind ~= 'court' then
            return E.Err('no_permission', 'You do not hold this evidence')
        end
        local res = Store.Query('update', Store.SQL.setSeal, { 0, row.state, row.id, row.state, 1 })
        if Store.Affected(res) ~= 1 then return E.Err('busy', 'The evidence changed meanwhile') end
        row.sealed = false
        -- from_ref is where it was when the seal broke: a lab or court break costs no integrity
        C.Record(row, 'seal_broken', row.holder_ref, row.holder_ref, actor, reason)
        if isPhysical(row) then C.RefreshBagInfo(row) end
        return { ok = true, evidenceId = row.id, integrity = row.integrity }
    end)
end

-- ── case links ────────────────────────────────────────────────────────────────────────────────
function C.Link(id, caseRef, opts, actor, unlink)
    local err = requireLeo(actor)
    if err then return err end
    local ref = Store.CaseRef(caseRef)
    if not ref then return E.Err('bad_args', 'Bad case reference') end
    return withRow(id, function(row)
        local links = Store.DecodeLinks(row.case_refs)
        local at
        for i, s in ipairs(links) do if s == ref then at = i end end
        if unlink then
            if not at then return { ok = true, unchanged = true } end
            table.remove(links, at)
        else
            if at then return { ok = true, unchanged = true } end
            if #links >= (E.Cfg().MaxCaseLinks or 20) then return E.Err('conflict', 'Too many case links') end
            links[#links + 1] = ref
        end
        local encoded = json.encode(links)
        local _, ok = Store.Query('update', Store.SQL.setLinks, { encoded, row.id })
        if not ok then return E.Err('db_unavailable', 'The link could not be saved') end
        row.case_refs = encoded
        C.Record(row, unlink and 'unlinked' or 'linked', nil, nil, actor, ref)
        return { ok = true, evidenceId = row.id }
    end)
end

-- ── disposal ──────────────────────────────────────────────────────────────────────────────────
--- Release or destroy under a court order. A player needs the supervisor grade; pf-justice calls as
--- system. When pf-justice can check court orders (IsCourtOrderValid), a refused order stops it.
function C.Dispose(id, mode, opts, actor)
    opts = opts or {}
    if mode ~= 'release' and mode ~= 'destroy' then return E.Err('bad_args', 'Mode is release or destroy') end
    local order = E.Ref(opts.courtOrderId, 64)
    if not order then return E.Err('bad_args', 'A court order id is required') end
    if actor.kind == 'player' and not actor.admin and not actor.supervisor then
        return E.Err('no_permission', 'Only a supervisor may ' .. mode .. ' evidence')
    end
    local cid = mode == 'release' and E.Ref(opts.cid, 64) or nil
    if mode == 'release' and opts.cid ~= nil and not cid then return E.Err('bad_args', 'Bad citizen id') end
    if GetResourceState('pf-justice') == 'started' then
        local okCheck, valid = pcall(function() return exports['pf-justice']:IsCourtOrderValid(order, 'evidence_' .. mode, id) end)
        if okCheck and valid == false then return E.Err('no_permission', 'The court order does not allow this') end
    end
    return withRow(id, function(row)
        local state = mode == 'release' and 'released' or 'destroyed'
        if row.state == state then return { ok = true, duplicate = true, evidenceId = row.id, state = row.state } end
        if Store.IsTerminal(row.state) then return E.Err('invalid_state', 'Evidence is ' .. row.state) end
        if not reachable(actor, row) then return E.Err('too_far', 'You are not where the evidence is') end
        if not Store.CanMove(row.state, state) then return E.Err('invalid_state', 'Evidence is ' .. row.state) end
        local taken
        if isPhysical(row) and row.holder_ref and (row.holder_ref:find('^player:') or row.holder_ref:find('^inv:')) then
            local why
            taken, why = C.TakeBag(row)
            if not taken then
                return E.Err(why == 'offline' and 'offline' or 'not_found',
                    why == 'offline' and 'Whoever holds it is not in the city' or 'The bag is not where the record says')
            end
        elseif isPhysical(row) and row.holder_kind ~= 'lab' and row.holder_kind ~= 'court' then
            return E.Err('not_found', 'The bag is not in anyone\'s hands; pick it up first')
        end
        local fromRef = row.holder_ref
        local ref = mode == 'release' and ('released:' .. (cid or 'owner')) or 'destroyed'
        if not Store.Move(row, mode == 'release' and 'released' or 'destroyed', ref, state) then
            restore(row, taken)
            return E.Err('busy', 'The evidence changed meanwhile; try again')
        end
        C.Record(row, state, fromRef, ref, actor, ('court order %s%s'):format(order, opts.note and ('; ' .. tostring(E.Str(opts.note, 120))) or ''))
        return { ok = true, evidenceId = row.id, state = row.state }
    end)
end

-- ── registration with pfm-inventory ───────────────────────────────────────────────────────────
function C.RegisterListeners()
    if GetResourceState('pfm-inventory') ~= 'started' then return false end
    local inv = exports['pfm-inventory']
    local ok = pcall(function()
        inv:AddListener('ItemMoved', C.OnItemMoved)
        inv:AddListener('ItemAdded', C.OnItemAdded)
        inv:AddListener('ItemRemoved', C.OnItemRemoved)
        inv:AddListener('ItemDropped', C.OnItemDropped)
        inv:AddListener('InventoryOpened', C.OnInventoryOpened)
    end)
    return ok
end

function C.ForgetSource(src)
    src = tonumber(src)
    C.viewers[src] = nil
    for target, searcher in pairs(C.viewers) do
        if searcher == src then C.viewers[target] = nil end
    end
end
