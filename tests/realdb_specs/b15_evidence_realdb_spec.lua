-- pfm-policejob evidence core on a real database (batch 15, unit 15D): the resource's one schema
-- (fines v1 kept, evidence v2), persisted scene drops that survive a restart and decay into
-- 'unrecoverable' rows, bagging into evidence rows + evidence_bag items, the custody recorder for
-- inventory moves, transfers, seals, links, paging, idempotent CreateEvidence and court disposal.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local started = { ['pfm-inventory'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pfm-policejob' end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

-- ── a small pfm-inventory: players' items, stashes, listeners fired like the real one ─────────
local Inv = { stashes = {}, listeners = {}, full = {} }
local function itemsOf(id)
    if type(id) == 'number' then return Mock.players[id] and Mock.players[id].PlayerData.items end
    return Inv.stashes[id] and Inv.stashes[id].items
end
local function fire(kind, ...)
    for _, fn in ipairs(Inv.listeners[kind] or {}) do fn(...) end
end
local function firstFree(items)
    local s = 1
    while items[s] do s = s + 1 end
    return s
end
local function invType(id) return type(id) == 'number' and 'player' or 'inventory' end
Mock.exportsByResource['pfm-inventory'] = {
    AddListener = function(_, kind, fn)
        Inv.listeners[kind] = Inv.listeners[kind] or {}
        table.insert(Inv.listeners[kind], fn)
        return #Inv.listeners[kind]
    end,
    AddItem = function(_, id, name, amount, slot, info)
        local items = itemsOf(id)
        if not items or (Inv.full[id] and name == 'evidence_bag') then return false end
        slot = tonumber(slot) or firstFree(items)
        if items[slot] then
            if items[slot].name ~= name then return false end
            items[slot].amount = items[slot].amount + (amount or 1)
        else
            items[slot] = { name = name, amount = amount or 1, slot = slot, info = info or {} }
        end
        fire('ItemAdded', 'item', { toId = id, toType = invType(id), toSlot = slot, item = items[slot], amount = amount or 1, resource = 'pfm-policejob' })
        return true
    end,
    RemoveItem = function(_, id, name, amount, slot)
        local items = itemsOf(id)
        if not items then return false end
        local it
        if slot then it = items[slot] else for _, v in pairs(items) do if v.name == name then it = v break end end end
        if not it or it.name ~= name or it.amount < (amount or 1) then return false end
        it.amount = it.amount - (amount or 1)
        if it.amount <= 0 then items[it.slot] = nil end
        fire('ItemRemoved', 'item', { fromId = id, fromType = invType(id), fromSlot = it.slot, item = it, amount = amount or 1, resource = 'pfm-policejob' })
        return true
    end,
    GetInventory = function(_, id) return Inv.stashes[id] end,
    CreateInventory = function(_, id, data) Inv.stashes[id] = Inv.stashes[id] or { items = {}, isOpen = false, label = data and data.label } end,
    SetItemData = function(_, src, name, key, val, slot)
        local it = itemsOf(src)[slot]
        if not it or it.name ~= name then return false end
        it[key] = val
        return true
    end,
}

QBCoreMock.Shared.Items.evidence_bag = { name = 'evidence_bag', label = 'Evidence Bag', weight = 200, type = 'item', unique = true }
QBCoreMock.Shared.Items.empty_evidence_bag = { name = 'empty_evidence_bag', label = 'Empty Evidence Bag', weight = 0, type = 'item' }
QBCoreMock.Shared.Items.nitrile_gloves = { name = 'nitrile_gloves', label = 'Nitrile Gloves', weight = 10, type = 'item' }
QBCoreMock.Shared.Weapons[GetHashKey('weapon_pistol')] = { name = 'weapon_pistol', label = 'Pistol', ammotype = 'AMMO_PISTOL' }
QBCoreMock.Functions.GetPlayersByJob = function(job, onDuty)
    local out = {}
    for src, P in pairs(Mock.players) do
        local j = P.PlayerData.job
        if (j.name == job or j.type == job) and (not onDuty or j.onduty) then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end

QBCore = Mock.coreObject()
Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/config_evidence.lua')
load_resource('pfm-policejob/server/schema.lua')
load_resource('pfm-policejob/server/fines.lua')
load_resource('pfm-policejob/server/evidence/store.lua')
load_resource('pfm-policejob/server/evidence/custody.lua')
load_resource('pfm-policejob/server/evidence/scene.lua')
load_resource('pfm-policejob/server/evidence/api.lua')
load_resource('pfm-policejob/server/evidence.lua')
local E, Store, C, S, A = PFEvidence, PFEvidence.Store, PFEvidence.Custody, PFEvidence.Scene, PFEvidence.Api
local Schema = PFPoliceSchema
assert_true(Schema.Run(), 'schema')
assert_true(A.Start(), 'evidence start')
assert_true(C.RegisterListeners(), 'listeners')

local COP, COP2, CIV, FARCOP, SARGE = 1, 2, 3, 4, 5
local LOCKER = Config.Locations['evidence'][1]
local DRAWER = '1 | Drawer 7'

local function newCop(src, cid, grade, at)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = grade or 1 } }
    p.PlayerData.items = { [1] = { name = 'empty_evidence_bag', amount = 5, slot = 1, info = {} } }
    Mock.coords[src] = at or vector3(0, 0, 0)
    return p
end

local function bagOf(src)
    for _, it in pairs(Mock.players[src].PlayerData.items) do
        if it.name == 'evidence_bag' then return it end
    end
end
local function bagsIn(id)
    local n = 0
    for _, it in pairs(itemsOf(id) or {}) do if it.name == 'evidence_bag' then n = n + 1 end end
    return n
end
local function row(id) return MySQL.single.await('SELECT * FROM pf_evidence_items WHERE id = ?', { id }) end
local function events(id)
    return MySQL.query.await('SELECT event, from_ref, to_ref, actor_cid FROM pf_evidence_custody WHERE evidence_id = ? ORDER BY id', { id })
end
local function eventNames(id)
    local out = {}
    for _, e in ipairs(events(id)) do out[#out + 1] = e.event end
    return table.concat(out, ',')
end

-- moves a bag between the mock inventories and tells the listeners, as pfm-inventory's move handler does
local function moveBag(fromId, toId, evidenceId, actorSrc)
    local from, to = itemsOf(fromId), itemsOf(toId)
    local bag
    for slot, it in pairs(from) do
        if it.name == 'evidence_bag' and it.info.evidenceId == evidenceId then bag = it; from[slot] = nil end
    end
    assert(bag, 'bag to move')
    local slot = firstFree(to)
    bag.slot = slot
    to[slot] = bag
    local function view(id) return { items = itemsOf(id), isOpen = type(id) == 'string' and actorSrc or nil } end
    fire('ItemMoved', 'moved', { fromType = invType(fromId), toType = invType(toId), fromId = fromId, toId = toId,
        fromSlot = 1, toSlot = slot, amount = 1, fromInventory = view(fromId), toInventory = view(toId) })
    C.Process()
end

local function collectBlood(src)
    Mock.gameTimer = Mock.gameTimer + 10000
    local drop = S.Report(CIV, 'blood', { coords = Mock.coords[CIV] })
    assert(drop, 'drop reported')
    local res = S.Collect(src, 'blood', drop.id, { street = 'Main St' })
    assert(res.ok, 'collected: ' .. tostring(res.error))
    return res.evidenceId, drop
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    Mock.clock = 1700000000
    Mock.gameTimer = Mock.gameTimer + 10000
    Inv.stashes, Inv.full = {}, {}
    newCop(COP, 'COPCID')
    newCop(COP2, 'COP2CID', 1, vector3(1, 0, 0))
    newCop(FARCOP, 'FARCID', 1, vector3(600, 0, 0))
    newCop(SARGE, 'SARGECID', 4, vector3(0, 1, 0))
    local civ = Mock.newPlayer(CIV, 'CIVCID')
    civ.PlayerData.metadata.bloodtype = 'O+'
    civ.PlayerData.metadata.fingerprint = 'FP-CIV-1'
    Mock.coords[CIV] = vector3(1, 1, 0)
end

describe('schema (key pfm-policejob)', function()
    it('applies v1 fines and v2 evidence once; a second run applies nothing', function()
        local versions = MySQL.query.await("SELECT version, name FROM pf_schema_migrations WHERE resource = 'pfm-policejob' ORDER BY version")
        assert_eq(#versions, 2)
        assert_eq(versions[1].name, 'police fine records')
        assert_eq(versions[2].name, 'evidence core')
        for _, t in ipairs({ 'pfm_police_fines', 'pf_evidence_items', 'pf_evidence_custody', 'pf_evidence_scene_drops', 'pf_evidence_lockers' }) do
            assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t })), 1, t)
        end
        Schema.state = 'idle'
        assert_true(Schema.Run())
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-policejob'")), 2)
    end)
    it('on a server that already has v1 (fines rows kept), only v2 is applied', function()
        MySQL.query.await("INSERT INTO pfm_police_fines (citizenid, society, amount, state) VALUES ('OLDCID', 'police', 50, 'paid')")
        for _, t in ipairs({ 'pf_evidence_items', 'pf_evidence_custody', 'pf_evidence_scene_drops', 'pf_evidence_lockers' }) do
            MySQL.query.await('DROP TABLE ' .. t)
        end
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pfm-policejob' AND version = 2")
        Schema.state = 'idle'
        assert_true(Schema.Run())
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pfm_police_fines WHERE citizenid = 'OLDCID'")), 1)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-policejob' AND version = 1")), 1)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-policejob' AND version = 2")), 1)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_evidence_items'")), 1)
        -- the memory index points at tables that were dropped above: start the scene afresh
        S.drops, S.cells, S.cellCount, S.live, S.pending, S.nextId = {}, {}, {}, 0, {}, 0
        assert_true(S.Load())
    end)
end)

describe('scene drops', function()
    it('are written by the flush with the server-known source and sent to nearby on-duty police only', function()
        local drop = S.Report(CIV, 'blood', { coords = vector3(2, 1, 0) })
        assert_true(drop ~= nil)
        local adds = Mock.clientEventsNamed('evidence:client:AddBlooddrop')
        local targets = {}
        for _, e in ipairs(adds) do targets[e.target] = true end
        assert_true(targets[COP] and targets[COP2] and targets[SARGE])
        assert_eq(targets[FARCOP], nil, 'officer 600 m away')
        assert_eq(targets[CIV], nil, 'not to civilians')
        assert_eq(targets[-1], nil, 'never a broadcast')
        assert_eq(tostring(adds[1].args[2]):sub(1, 2), 'S-', 'clients see a sample id')
        assert_eq(S.Flush(), 1)
        local r = MySQL.single.await('SELECT * FROM pf_evidence_scene_drops WHERE id = ?', { drop.id })
        assert_eq(r.state, 'present')
        assert_eq(r.source_cid, 'CIVCID')
        assert_eq(r.kind, 'blood')
    end)
    it('survive a restart', function()
        local drop = S.Report(CIV, 'fingerprint', { coords = vector3(1, 1, 0) })
        S.Flush()
        local id = drop.id
        S.drops, S.cells, S.cellCount, S.live, S.pending, S.loaded = {}, {}, {}, 0, {}, false
        assert_true(S.Load())
        assert_true(S.drops[id] ~= nil, 'loaded back')
        assert_eq(S.drops[id].attrs.printId, 'FP-CIV-1')
        Mock.gameTimer = Mock.gameTimer + 10000
        local after = S.Report(CIV, 'fingerprint', { coords = vector3(1, 1, 0) })
        assert_true(after.id > id, 'ids continue after the restart')
    end)
    it('decay into unrecoverable rows instead of being deleted', function()
        local drop = S.Report(CIV, 'blood', { coords = vector3(1, 1, 0) })
        S.Flush()
        Mock.clock = Mock.clock + 241 * 60
        Mock.reset()
        assert_true(S.Decay() >= 1)
        assert_eq(S.drops[drop.id], nil)
        assert_eq(MySQL.single.await('SELECT state FROM pf_evidence_scene_drops WHERE id = ?', { drop.id }).state, 'unrecoverable')
        assert_true(#Mock.clientEventsNamed('evidence:client:RemoveBlooddrop') >= 1)
    end)
    it('clean-up marks rows cleared, only near the officer', function()
        local near = S.Report(CIV, 'casing', { weapon = GetHashKey('weapon_pistol'), coords = vector3(1, 1, 0) })
        Mock.coords[CIV] = vector3(50, 0, 0)
        Mock.gameTimer = Mock.gameTimer + 10000
        local far = S.Report(CIV, 'casing', { weapon = GetHashKey('weapon_pistol'), coords = vector3(50, 0, 0) })
        assert_eq(S.Clear(COP, 'casing', { near.id, far.id }), 1)
        assert_eq(MySQL.single.await('SELECT state FROM pf_evidence_scene_drops WHERE id = ?', { near.id }).state, 'cleared')
        assert_eq(MySQL.single.await('SELECT state FROM pf_evidence_scene_drops WHERE id = ?', { far.id }).state, 'present')
    end)
end)

describe('bagging', function()
    it('makes an evidence row and an evidence_bag from the stored drop, with a sample id as label', function()
        local id, drop = collectBlood(COP)
        local r = row(id)
        assert_eq(r.kind, 'blood')
        assert_eq(r.state, 'sealed')
        assert_eq(r.holder_kind, 'officer')
        assert_eq(r.holder_ref, 'player:COPCID')
        assert_true(r.tag:match('^EV%-%d%d%d%d%-%d+$') ~= nil, r.tag)
        local bag = bagOf(COP)
        assert_eq(bag.info.evidenceId, id)
        assert_eq(bag.info.tag, r.tag)
        assert_eq(bag.info.street, 'Main St')
        local hex = (('CIVCID'):gsub('.', function(c) return ('%02x'):format(c:byte()) end))
        assert_true(bag.info.dnalabel ~= hex and tostring(bag.info.dnalabel):find('CIVCID', 1, true) == nil, 'no identity on the bag')
        assert_eq(bag.info.dnalabel, drop.attrs.sampleId)
        assert_eq(Mock.players[COP].PlayerData.items[1].amount, 4, 'one empty bag used')
        local d = MySQL.single.await('SELECT state, collected_evidence_id FROM pf_evidence_scene_drops WHERE id = ?', { drop.id })
        assert_eq(d.state, 'collected')
        assert_eq(tonumber(d.collected_evidence_id), id)
        assert_eq(eventNames(id), 'collected,sealed')
        assert_true(#Mock.clientEventsNamed('evidence:client:RemoveBlooddrop') >= 1)
        -- the same drop cannot be bagged twice
        assert_eq(S.Collect(COP2, 'blood', drop.id, {}).error, 'not_found')
    end)
    it('without gloves prints and DNA lose integrity; with gloves they do not', function()
        local id = collectBlood(COP)
        assert_eq(tonumber(row(id).integrity), 90)
        assert_true(tostring(row(id).flags):find('contaminated') ~= nil)
        Mock.players[COP2].PlayerData.items[2] = { name = 'nitrile_gloves', amount = 1, slot = 2, info = {} }
        local id2 = collectBlood(COP2)
        assert_eq(tonumber(row(id2).integrity), 100)
    end)
    it('needs an empty bag and the officer next to the drop', function()
        local drop = S.Report(CIV, 'blood', { coords = vector3(1, 1, 0) })
        Mock.coords[COP] = vector3(10, 0, 0)
        assert_eq(S.Collect(COP, 'blood', drop.id, {}).error, 'too_far')
        Mock.coords[COP] = vector3(0, 0, 0)
        Mock.players[COP].PlayerData.items = {}
        Mock.gameTimer = Mock.gameTimer + 10000
        assert_eq(S.Collect(COP, 'blood', drop.id, {}).error, 'invalid_state')
        assert_true(S.drops[drop.id] ~= nil, 'still there')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_evidence_items WHERE origin_id = ?", { tostring(drop.id) })), 0)
    end)
    it('a bag that does not fit leaves no record and gives the empty bag back', function()
        local drop = S.Report(CIV, 'blood', { coords = vector3(1, 1, 0) })
        Inv.full[COP] = true
        local res = S.Collect(COP, 'blood', drop.id, {})
        Inv.full[COP] = nil
        assert_false(res.ok)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_evidence_items WHERE origin_id = ?", { tostring(drop.id) })), 0)
        assert_true(S.drops[drop.id] ~= nil)
        local empty = 0
        for _, it in pairs(Mock.players[COP].PlayerData.items) do if it.name == 'empty_evidence_bag' then empty = empty + it.amount end end
        assert_eq(empty, 5, 'the empty bag came back')
    end)
end)

describe('custody recorder (pfm-inventory moves)', function()
    it('records a check-in to a locker drawer and the check-out, with actor and both inventory ids', function()
        local id = collectBlood(COP)
        Inv.stashes[DRAWER] = { items = {}, isOpen = false }
        moveBag(COP, DRAWER, id, COP)
        local r = row(id)
        assert_eq(r.state, 'stored')
        assert_eq(r.holder_kind, 'locker')
        assert_eq(r.holder_ref, 'inv:' .. DRAWER)
        local evs = events(id)
        assert_eq(evs[#evs].event, 'checked_in')
        assert_eq(evs[#evs].from_ref, 'player:COPCID')
        assert_eq(evs[#evs].to_ref, 'inv:' .. DRAWER)
        assert_eq(evs[#evs].actor_cid, 'COPCID')
        moveBag(DRAWER, COP2, id, COP2)
        r = row(id)
        assert_eq(r.state, 'in_transit')
        assert_eq(events(id)[#events(id)].event, 'checked_out')
        assert_eq(events(id)[#events(id)].actor_cid, 'COP2CID')
    end)
    it('a hand-over (removed then added) is one move, not a missing bag', function()
        local id = collectBlood(COP)
        local bag = bagOf(COP)
        exports['pfm-inventory']:RemoveItem(COP, 'evidence_bag', 1, bag.slot)
        exports['pfm-inventory']:AddItem(COP2, 'evidence_bag', 1, false, bag.info)
        C.Process()
        Mock.clock = Mock.clock + 60
        C.CheckRemovals()
        assert_eq(row(id).holder_ref, 'player:COP2CID')
        assert_eq(eventNames(id), 'collected,sealed,moved')
        assert_eq(events(id)[3].actor_cid, 'COPCID', 'the giver acted')
    end)
    it('a bag that vanishes is flagged missing, and a long gap costs integrity', function()
        Mock.players[COP].PlayerData.items[2] = { name = 'nitrile_gloves', amount = 1, slot = 2, info = {} }
        local id = collectBlood(COP)
        exports['pfm-inventory']:RemoveItem(COP, 'evidence_bag', 1, bagOf(COP).slot)
        Mock.clock = Mock.clock + 30
        C.CheckRemovals()
        local r = row(id)
        assert_eq(r.holder_ref, 'unknown')
        assert_eq(events(id)[#events(id)].event, 'flagged_missing')
        Mock.clock = Mock.clock + 31 * 60
        local got = A.GetEvidence(id, {})
        assert_true(got.ok)
        assert_eq(got.integrity.score, 80)
        local flags = table.concat(got.integrity.flags, ',')
        assert_true(flags:find('gap') ~= nil and flags:find('missing') ~= nil, flags)
    end)
end)

describe('transfers, seals and links', function()
    it('hands a bag to an officer next to the holder, not across the room or to a civilian', function()
        local id = collectBlood(COP)
        Mock.coords[COP2] = vector3(10, 0, 0)
        assert_eq(A.TransferEvidence(id, { kind = 'officer', src = COP2 }, { actor = { src = COP } }).error, 'too_far')
        assert_eq(A.TransferEvidence(id, { kind = 'officer', src = CIV }, { actor = { src = COP } }).error, 'no_permission')
        Mock.coords[COP2] = vector3(1, 0, 0)
        assert_eq(A.TransferEvidence(id, { kind = 'officer', src = COP2 }, { actor = { src = COP2 } }).error, 'no_permission', 'only the holder hands it over')
        local res = A.TransferEvidence(id, { kind = 'officer', src = COP2 }, { actor = { src = COP } })
        assert_true(res.ok, tostring(res.error) .. ' ' .. tostring(res.message))
        assert_eq(bagOf(COP), nil)
        assert_eq(bagOf(COP2).info.evidenceId, id)
        assert_eq(row(id).holder_ref, 'player:COP2CID')
        assert_eq(events(id)[#events(id)].event, 'handed_over')
        assert_true(A.TransferEvidence(id, { kind = 'officer', src = COP2 }, { actor = { src = COP2 } }).duplicate)
    end)
    it('checks into a locker drawer at the locker only, then out to the lab and back with the same id', function()
        local id = collectBlood(COP)
        assert_eq(A.TransferEvidence(id, { kind = 'locker', lockerId = DRAWER }, { actor = { src = COP } }).error, 'too_far')
        Mock.coords[COP] = vector3(LOCKER.x, LOCKER.y, LOCKER.z)
        local res = A.TransferEvidence(id, { kind = 'locker', lockerId = DRAWER }, { actor = { src = COP } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(row(id).state, 'stored')
        assert_eq(bagsIn(DRAWER), 1)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_evidence_lockers WHERE stash_id = ?', { DRAWER })), 1)
        res = A.TransferEvidence(id, { kind = 'lab', labId = 'main' }, { actor = { src = COP } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(bagsIn(DRAWER), 0)
        assert_eq(row(id).state, 'at_lab')
        assert_eq(A.TransferEvidence(id, { kind = 'officer', src = COP }, { actor = { src = COP } }).error, 'no_permission')
        res = A.TransferEvidence(id, { kind = 'officer', src = SARGE }, { actor = { src = SARGE } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(bagOf(SARGE).info.evidenceId, id)
        assert_eq(eventNames(id), 'collected,sealed,checked_in,submitted_lab,handed_over')
    end)
    it('a broken seal costs integrity outside a lab and nothing inside one', function()
        Mock.players[COP].PlayerData.items[2] = { name = 'nitrile_gloves', amount = 1, slot = 2, info = {} }
        local id = collectBlood(COP)
        assert_eq(A.BreakSeal(id, nil, { actor = { src = COP } }).error, 'bad_args')
        assert_true(A.BreakSeal(id, 'opened in the field', { actor = { src = COP } }).ok)
        assert_eq(tonumber(row(id).integrity), 88)
        assert_eq(bagOf(COP).info.sealed, false)
        assert_true(A.SealEvidence(id, { actor = { src = COP } }).ok)
        assert_true(A.TransferEvidence(id, { kind = 'lab', labId = 'main' }, { actor = { src = COP } }).ok)
        assert_true(A.BreakSeal(id, 'lab examination', { actor = { kind = 'system', label = 'lab' } }).ok)
        assert_eq(A.GetEvidence(id, {}).integrity.score, 88)
    end)
    it('links to cases, lists by case with paging, and unlinks', function()
        local ids = {}
        for i = 1, 3 do ids[i] = collectBlood(COP) end
        for _, id in ipairs(ids) do
            assert_true(A.LinkEvidence(id, { type = 'case', id = 'C-77' }, { actor = { src = COP } }).ok)
        end
        assert_eq(A.LinkEvidence(ids[1], { type = 'nonsense', id = 'x' }, { actor = { src = COP } }).error, 'bad_args')
        local page = A.ListEvidence({ caseRef = { type = 'case', id = 'C-77' }, limit = 2 })
        assert_true(page.ok)
        assert_eq(#page.list, 2)
        assert_eq(page.list[1].id, ids[3])
        assert_true(page.next ~= nil)
        local rest = A.ListEvidence({ caseRef = { type = 'case', id = 'C-77' }, limit = 2, after = page.next })
        assert_eq(#rest.list, 1)
        assert_eq(rest.next, nil)
        assert_true(A.UnlinkEvidence(ids[1], { type = 'case', id = 'C-77' }, { actor = { src = COP } }).ok)
        assert_eq(#A.ListEvidence({ caseRef = { type = 'case', id = 'C-77' } }).list, 2)
        assert_true(eventNames(ids[1]):find('linked,unlinked') ~= nil)
        local all = A.ListEvidence({ holder = { ref = 'player:COPCID' }, kind = 'blood', state = 'sealed', limit = 1000 })
        assert_true(all.ok and #all.list >= 3 and #all.list <= 100)
        for _, item in ipairs(all.list) do assert_eq(item.holder.ref, 'player:COPCID') end
    end)
end)

describe('CreateEvidence, GetEvidence and disposal', function()
    it('is idempotent per key, refuses a reused key and unknown callers', function()
        Mock.invokingResource = 'pfm-prison'
        Inv.stashes['prison_contraband'] = { items = {}, isOpen = false }
        local spec = { kind = 'item', label = 'Shiv', attrs = { item = 'weapon_knife', amount = 1, owner = 'dropped' }, method = 'prison_search' }
        local opts = { key = 'pfm-prison:contraband:9:1', giveTo = 'stash:prison_contraband', actor = { kind = 'system', label = 'prison search' } }
        local first = Mock.selfExport('CreateEvidence')(spec, opts)
        assert_true(first.ok, tostring(first.error))
        assert_eq(bagsIn('prison_contraband'), 1)
        local again = Mock.selfExport('CreateEvidence')(spec, opts)
        assert_true(again.duplicate)
        assert_eq(again.evidenceId, first.evidenceId)
        assert_eq(bagsIn('prison_contraband'), 1)
        spec.label = 'Other'
        assert_eq(Mock.selfExport('CreateEvidence')(spec, opts).error, 'key_reused')
        Mock.invokingResource = 'some-script'
        assert_eq(Mock.selfExport('CreateEvidence')(spec, opts).error, 'not_allowed')
        Mock.invokingResource = nil
        local attrs = json.decode(row(first.evidenceId).attrs)
        assert_eq(attrs.owner, nil, 'unknown attrs are dropped')
        assert_eq(row(first.evidenceId).holder_ref, 'inv:prison_contraband')
    end)
    it('GetEvidence returns the item, custody and integrity to on-duty police only', function()
        local id = collectBlood(COP)
        assert_eq(A.GetEvidence(id, { viewer = CIV }).error, 'no_permission')
        local got = A.GetEvidence(id, { viewer = COP })
        assert_true(got.ok)
        assert_eq(got.item.id, id)
        assert_eq(got.item.identification, 'awaiting_lab')
        assert_eq(#got.custody, 2)
        assert_eq(got.integrity.score, 90)
        assert_eq(A.GetEvidence(got.item.tag, {}).item.id, id, 'by tag')
    end)
    it('records without a bag (vehicle, photo) need no inventory', function()
        local res = A.CreateEvidence({ kind = 'vehicle', label = 'Getaway car', attrs = { plate = 'ab 123' } }, { actor = { src = COP } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(json.decode(row(res.evidenceId).attrs).plate, 'AB 123')
        assert_eq(row(res.evidenceId).holder_kind, 'record')
        local photo = A.CreateEvidence({ kind = 'photo', attrs = { url = 'https://evil.example.com/x.png' } }, { actor = { src = COP } })
        assert_eq(photo.error, 'bad_args')
    end)
    it('disposal needs a court order and a supervisor, and removes the bag', function()
        local id = collectBlood(COP)
        assert_eq(A.DisposeEvidence(id, 'destroy', { actor = { src = SARGE } }).error, 'bad_args')
        assert_eq(A.DisposeEvidence(id, 'destroy', { courtOrderId = 'CO-1', actor = { src = COP } }).error, 'no_permission')
        Mock.coords[SARGE] = vector3(100, 0, 0)
        assert_eq(A.DisposeEvidence(id, 'destroy', { courtOrderId = 'CO-1', actor = { src = SARGE } }).error, 'too_far', 'no remote seizure from an officer')
        assert_eq(A.TransferEvidence(id, { kind = 'lab' }, { actor = { src = SARGE } }).error, 'too_far')
        Mock.coords[SARGE] = vector3(0, 1, 0)
        local res = A.DisposeEvidence(id, 'destroy', { courtOrderId = 'CO-1', actor = { src = SARGE } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(row(id).state, 'destroyed')
        assert_eq(bagOf(COP), nil)
        assert_eq(events(id)[#events(id)].event, 'destroyed')
        assert_eq(A.TransferEvidence(id, { kind = 'lab' }, { actor = { src = SARGE } }).error, 'invalid_state')
        assert_true(A.DisposeEvidence(id, 'destroy', { courtOrderId = 'CO-1', actor = { src = SARGE } }).duplicate)
    end)
end)
