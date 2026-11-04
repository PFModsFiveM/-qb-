-- pf-justice property lockers (unit 15C acceptance 4):
--   * seizure moves the items into pf_justice_property_<receiptId> and the receipt lists every item;
--     kept items stay; a failed clear or a locker that refuses an item rolls everything back (the
--     player keeps everything, no receipt is left); a change of the inventory while the receipt is
--     written is caught, so the receipt matches what was taken; keys are idempotent;
--   * return adds the items back without clearing what the player holds; what does not fit stays
--     in the locker and comes back at the next load; an offline owner gets it at the next load;
--     a second return gives nothing twice;
--   * a released custody returns its receipts; a custody that went to prison keeps them for the
--     order, which returns them on releaseOrdered;
--   * forfeiture moves rows into pfm-policejob evidence (CreateEvidence, keyed); when no evidence
--     record can be made the item stays in the locker;
--   * receipts are visible to the owner and officers only; a deleted character's lockers close.
load_resource('tests/lua/fivem_mocks.lua')
local ROOT = __JU_ROOT or '[pfscripts]/pf-justice/'
local started = { ['pfm-inventory'] = true, ['pfm-policejob'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-justice' end

-- pfm-inventory stand-in (players = PlayerData.items, stashes here); switches to inject failures
local Stashes, fail = {}, {}
local function itemsOf(id)
    if type(id) == 'number' then return Mock.players[id] and Mock.players[id].PlayerData.items end
    return Stashes[id] and Stashes[id].items
end
Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function(_, id) Stashes[id] = Stashes[id] or { items = {} } return true end,
    GetInventory = function(_, id) return Stashes[id] end,
    SaveStash = function() end,
    ClearStash = function(_, id) if Stashes[id] then Stashes[id].items = {} end end,
    ClearInventory = function(_, src)
        if fail.clear then error('inventory crashed') end
        Mock.players[src].PlayerData.items = {}
    end,
    CanAddItem = function(_, id, name) return not (fail.full and fail.full[name]) end,
    AddItem = function(_, id, name, amount, slot, info)
        if type(id) == 'string' and fail.lockerRefuses == name then return false end
        local items = itemsOf(id)
        if not items then return false end
        items[#items + 1] = { name = name, amount = amount, slot = slot or (#items + 1), info = info }
        return true
    end,
    RemoveItem = function(_, id, name, amount, slot)
        local items = itemsOf(id)
        for k, it in pairs(items or {}) do
            if it.name == name and (slot == nil or it.slot == slot) and it.amount >= amount then
                it.amount = it.amount - amount
                if it.amount == 0 then items[k] = nil end
                return true
            end
        end
        return false
    end,
}
-- pfm-policejob's real evidence config (15D): CreateEvidence refuses methods and kinds it does not list
local RealEvidence
do
    local saved = Config
    Config = {}
    load_resource('pfm-policejob/config_evidence.lua')
    RealEvidence = Config.Evidence
    Config = saved
end
local evidence, evidenceFails = {}, false
Mock.exportsByResource['pfm-policejob'] = {
    IsCuffed = function() return false end, SetCuffed = function() return true end,
    CreateEvidence = function(_, spec, opts)
        if evidenceFails then return { ok = false, error = 'db_unavailable' } end
        -- the checks pfm-policejob server/evidence/api.lua BuildSpec makes with that config
        if not RealEvidence.Methods[spec.method == nil and 'manual' or spec.method] then return { ok = false, error = 'bad_args', message = 'unknown method' } end
        local def = RealEvidence.Kinds[spec.kind]
        if not def then return { ok = false, error = 'bad_args', message = 'unknown kind' } end
        if def.physical and opts.giveTo == nil and spec.collectedBy == nil then return { ok = false, error = 'bad_args', message = 'physical evidence needs giveTo' } end
        if not (opts and opts.key) then return { ok = false, error = 'bad_args', message = 'opts.key is required' } end
        evidence[#evidence + 1] = { spec = spec, opts = opts }
        return { ok = true, evidenceId = 900 + #evidence, tag = 'EV-' .. #evidence }
    end,
}

Config = nil
load_resource(ROOT .. 'config.lua')
load_resource(ROOT .. 'shared/states.lua')
load_resource(ROOT .. 'server/main.lua')
load_resource(ROOT .. 'server/custody.lua')
load_resource(ROOT .. 'server/property.lua')
load_resource(ROOT .. 'server/legacy_import.lua')
Mock.exportsByResource['pf-justice'] = Mock.exportsByResource['__self']
local J = PFJustice
local K = J.CustodyKit
J.API = { AddRecordEntry = function() return { ok = true } end }
J.Clock = { SetHospitalCustody = function() end }

-- in-memory stores with the semantics of the SQL ones
local DB
local function copy(r) local o = {} for k, v in pairs(r) do o[k] = v end return o end
local function apply(r, fields) for k, v in pairs(fields) do if v == K.NULL then r[k] = nil else r[k] = v end end end
local function inSet(v, list) for _, x in ipairs(list) do if x == v then return true end end return false end
local function nextId() DB.n = DB.n + 1 return DB.n end
local onAddItem
J.Custody.Store = {
    openOf = function(cid) for _, r in pairs(DB.custody) do if r.citizenid == cid and not r.closed_at then return copy(r) end end end,
    get = function(id) return DB.custody[id] and copy(DB.custody[id]) end,
    byKey = function() end, latestOf = function() end,
    insert = function(row) local r = copy(row) r.id = nextId() DB.custody[r.id] = r return r.id end,
    cas = function(id, from, fields) local r = DB.custody[id] if not r or r.state ~= from or r.closed_at then return false end apply(r, fields) return true end,
    log = function(cid, kind) DB.log[#DB.log + 1] = { custody_id = cid, kind = kind } return #DB.log end,
    listLog = function() return {} end, dueHolds = function() return {} end, openAllOf = function() return {} end,
}
J.Property.Store = {
    insert = function(row)
        if row.idem_key then for _, r in pairs(DB.property) do if r.idem_key == row.idem_key then return nil end end end
        local r = copy(row) r.id = nextId() DB.property[r.id] = r return r.id
    end,
    setStash = function(id, s) DB.property[id].stash_id = s return true end,
    get = function(id) return DB.property[id] and copy(DB.property[id]) end,
    byKey = function(key) for _, r in pairs(DB.property) do if r.idem_key == key then return copy(r) end end end,
    byLegacy = function() end,
    delete = function(id) DB.property[id] = nil end,
    addItem = function(pid, item, amount, info, state)
        if onAddItem then local f = onAddItem onAddItem = nil f() end
        local id = nextId() DB.items[id] = { id = id, property_id = pid, item = item, amount = amount, info = K.encode(info), state = state } return id
    end,
    items = function(pid) local out = {} for _, it in pairs(DB.items) do if it.property_id == pid then out[#out + 1] = copy(it) end end table.sort(out, function(a, b) return a.id < b.id end) return out end,
    deleteItems = function(pid) for id, it in pairs(DB.items) do if it.property_id == pid then DB.items[id] = nil end end return true end,
    setItemState = function(id, from, to, ev) local it = DB.items[id] if not it or it.state ~= from then return false end it.state, it.evidence_id = to, ev return true end,
    cas = function(id, from, fields) local r = DB.property[id] if not r or not inSet(r.state, from) then return false end apply(r, fields) return true end,
    forField = function(field, value, states) local out = {} for _, r in pairs(DB.property) do if r[field] == value and inSet(r.state, states) then out[#out + 1] = copy(r) end end table.sort(out, function(a, b) return a.id < b.id end) return out end,
    linkOrder = function(cid, oid) for _, r in pairs(DB.property) do if r.custody_id == cid and not r.order_id and r.state == 'held' then r.order_id = oid end end end,
}
function J.Property.Store.forCustody(id, s) return J.Property.Store.forField('custody_id', id, s) end
function J.Property.Store.forOrder(id, s) return J.Property.Store.forField('order_id', id, s) end
function J.Property.Store.forCitizen(cid, s) return J.Property.Store.forField('citizenid', cid, s) end

local COP, SUSPECT, OTHER = 1, 2, 3
local HERE = vector3(441.0, -981.0, 30.7)
local P = J.Property

local function holding(src)
    local out = {}
    for _, it in pairs(Mock.players[src].PlayerData.items) do out[it.name] = (out[it.name] or 0) + it.amount end
    return out
end
local function lockerOf(id)
    local out = {}
    for _, it in pairs((Stashes[P.StashId(id)] or { items = {} }).items) do out[it.name] = (out[it.name] or 0) + it.amount end
    return out
end
local function seize(extra)
    local opts = { reason = 'arrest', actor = { src = COP } }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return P.Seize(SUSPECT, opts)
end
local function receiptCount() local n = 0 for _ in pairs(DB.property) do n = n + 1 end return n end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.invokingResource = nil
    DB = { custody = {}, log = {}, property = {}, items = {}, n = 0 }
    Stashes, fail, evidence, evidenceFails, onAddItem = {}, {}, {}, false, nil
    J.Custody.bySrc, J.Custody.srcByCid = {}, {}
    local c = Mock.newPlayer(COP, 'COP1')
    c.PlayerData.job = { name = 'police', type = 'leo', grade = { level = 1 }, onduty = true }
    local s = Mock.newPlayer(SUSPECT, 'SUS2')
    s.PlayerData.items = {
        { name = 'phone', amount = 1, slot = 1 },
        { name = 'lockpick', amount = 3, slot = 2, info = { uses = 1 } },
        { name = 'weapon_pistol', amount = 1, slot = 3, info = { serie = 'SER123' } },
    }
    Mock.coords[COP], Mock.coords[SUSPECT] = HERE, HERE
end

describe('seizure', function()
    it('moves every item into pf_justice_property_<id>; the receipt lists them all', function()
        local res = seize({ key = 'pf-justice:booking:1:property' })
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(res.items, 3)
        local r = P.GetReceipt(res.receiptId).receipt
        assert_eq(r.lockerStash, 'pf_justice_property_' .. res.receiptId)
        assert_eq(#r.items, 3)
        assert_eq(r.items[2].name, 'lockpick')
        assert_eq(r.items[2].info.uses, 1)
        assert_eq(r.state, 'held')
        assert_eq(next(Mock.players[SUSPECT].PlayerData.items), nil, 'inventory cleared')
        local locker = lockerOf(res.receiptId)
        assert_eq(locker.phone, 1)
        assert_eq(locker.lockpick, 3)
        assert_eq(locker.weapon_pistol, 1)
        -- a retry with the same key returns the same receipt
        local again = seize({ key = 'pf-justice:booking:1:property' })
        assert_eq(again.duplicate, true)
        assert_eq(again.receiptId, res.receiptId)
        Mock.players[OTHER] = nil
        local o = Mock.newPlayer(OTHER, 'OTH3')
        Mock.coords[OTHER] = HERE
        assert_eq(P.Seize(OTHER, { key = 'pf-justice:booking:1:property', actor = { src = COP } }).error, 'key_reused')
        assert_true(o ~= nil)
    end)

    it('keeps the named items (and Config.Property.Keep)', function()
        Config.Property.Keep = { 'weapon_pistol' }
        local res = seize({ keep = { 'phone' } })
        Config.Property.Keep = {}
        assert_eq(res.items, 1)
        local held = holding(SUSPECT)
        assert_eq(held.phone, 1)
        assert_eq(held.weapon_pistol, 1)
        assert_eq(held.lockpick, nil)
        assert_eq(lockerOf(res.receiptId).lockpick, 3)
    end)

    it('takes only listed slots, never more than held; a wrong listing is refused', function()
        local res = seize({ items = { { name = 'lockpick', slot = 2, amount = 2 } } })
        assert_eq(res.ok, true)
        assert_eq(holding(SUSPECT).lockpick, 1)
        assert_eq(lockerOf(res.receiptId).lockpick, 2)
        assert_eq(seize({ items = { { name = 'lockpick', slot = 2, amount = 9 } } }).error, 'bad_args')
        assert_eq(seize({ items = { { name = 'goldbar', slot = 2 } } }).error, 'bad_args')
    end)

    it('rolls back when the inventory clear fails: the player keeps everything, no receipt is left', function()
        fail.clear = true
        local res = seize()
        assert_eq(res.ok, false)
        assert_eq(holding(SUSPECT).lockpick, 3)
        assert_eq(receiptCount(), 0)
        for _, stash in pairs(Stashes) do assert_eq(next(stash.items), nil, 'locker emptied again') end
    end)

    it('rolls back when the locker refuses an item', function()
        fail.lockerRefuses = 'weapon_pistol'
        local res = seize()
        assert_eq(res.ok, false)
        assert_eq(holding(SUSPECT).weapon_pistol, 1)
        assert_eq(holding(SUSPECT).phone, 1)
        assert_eq(receiptCount(), 0)
        for _, stash in pairs(Stashes) do assert_eq(next(stash.items), nil) end
    end)

    it('an inventory change while the receipt is written is caught: the receipt is what was taken', function()
        -- the player drops the phone while the first receipt row is written (a database wait)
        onAddItem = function() table.remove(Mock.players[SUSPECT].PlayerData.items, 1) end
        local res = seize()
        assert_eq(res.ok, true)
        local r = P.GetReceipt(res.receiptId).receipt
        assert_eq(#r.items, 2)
        for _, it in ipairs(r.items) do assert_true(it.name ~= 'phone', 'the dropped phone is not on the receipt') end
        assert_eq(lockerOf(res.receiptId).phone, nil)
    end)

    it('needs an on-duty officer next to the citizen', function()
        Mock.coords[SUSPECT] = vector3(HERE.x + 500.0, HERE.y, HERE.z) -- outside the booking zone too
        assert_eq(seize().error, 'too_far')
        Mock.coords[SUSPECT] = HERE
        Mock.players[COP].PlayerData.job.onduty = false
        assert_eq(seize().error, 'not_on_duty')
    end)
end)

describe('return', function()
    it('adds the items back without clearing what the player holds now', function()
        local id = seize().receiptId
        Mock.players[SUSPECT].PlayerData.items = { { name = 'water_bottle', amount = 2, slot = 1 } }
        local res = P.Return(id, { toSrc = SUSPECT })
        assert_eq(res.ok, true)
        assert_eq(res.returned, 3)
        local held = holding(SUSPECT)
        assert_eq(held.water_bottle, 2, 'current items kept')
        assert_eq(held.lockpick, 3)
        assert_eq(held.weapon_pistol, 1)
        assert_eq(DB.property[id].state, 'returned')
        local again = P.Return(id, { toSrc = SUSPECT })
        assert_eq(again.duplicate, true)
        assert_eq(holding(SUSPECT).lockpick, 3, 'nothing given twice')
    end)

    it('what does not fit stays in the locker and comes back at the next load', function()
        local id = seize().receiptId
        fail.full = { weapon_pistol = true }
        local res = P.Return(id, { toSrc = SUSPECT })
        assert_eq(res.returned, 2)
        assert_eq(#res.kept, 1)
        assert_eq(res.kept[1].name, 'weapon_pistol')
        assert_eq(DB.property[id].state, 'partially_returned')
        assert_eq(lockerOf(id).weapon_pistol, 1)
        fail.full = nil
        P.OnPlayerLoaded(SUSPECT)
        assert_eq(holding(SUSPECT).weapon_pistol, 1)
        assert_eq(DB.property[id].state, 'returned')
        assert_eq(next(lockerOf(id)), nil)
    end)

    it('an offline owner gets the locker at the next load', function()
        local id = seize().receiptId
        local saved = Mock.players[SUSPECT]
        Mock.players[SUSPECT] = nil
        local res = P.Return(id, {})
        assert_eq(res.pending, true)
        assert_eq(DB.property[id].state, 'returning')
        Mock.players[SUSPECT] = saved
        assert_eq(P.OnPlayerLoaded(SUSPECT), 3)
        assert_eq(DB.property[id].state, 'returned')
    end)

    it('only to the owner', function()
        local id = seize().receiptId
        Mock.newPlayer(OTHER, 'OTH3')
        assert_eq(P.Return(id, { toSrc = OTHER }).error, 'bad_args')
        assert_eq(DB.property[id].state, 'held')
    end)

    it('a released custody returns its receipts; one that went to prison keeps them for the order', function()
        local custodyId = J.Custody.Open(SUSPECT, { reason = 'x', actor = { src = COP } }).custodyId
        local id = seize({ custodyId = custodyId }).receiptId
        J.Custody.Release(custodyId, 'no_charges', { actor = { src = COP } })
        assert_eq(DB.property[id].state, 'returned')
        assert_eq(holding(SUSPECT).lockpick, 3)
        -- second arrest: this time a prison order starts
        local c2 = J.Custody.Open(SUSPECT, { reason = 'y', actor = { src = COP } }).custodyId
        local id2 = seize({ custodyId = c2 }).receiptId
        J.Custody.OnOrderCreated({ id = 41, cid = 'SUS2', kind = 'prison', state = 'active', facility = 'bolingbroke' })
        assert_eq(DB.property[id2].state, 'held', 'kept for the sentence')
        assert_eq(DB.property[id2].order_id, 41)
        P.OnReleaseOrdered('SUS2', 41, 'completed')
        assert_eq(DB.property[id2].state, 'returned')
        assert_eq(holding(SUSPECT).lockpick, 3)
    end)
end)

describe('forfeiture into evidence', function()
    it('moves a row into evidence (keyed) and leaves the rest of the locker', function()
        local id = seize().receiptId
        local rows = J.Property.Store.items(id)
        local res = P.Forfeit(id, { { id = rows[3].id } }, { actor = { src = COP } })
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(#res.evidenceIds, 1)
        assert_eq(evidence[1].spec.kind, 'weapon')
        assert_eq(evidence[1].spec.attrs.serial, 'SER123')
        assert_eq(evidence[1].opts.key, ('pf-justice:property:%d:%d'):format(id, rows[3].id))
        assert_eq(DB.items[rows[3].id].state, 'forfeited')
        assert_eq(DB.items[rows[3].id].evidence_id, res.evidenceIds[1])
        assert_eq(lockerOf(id).weapon_pistol, nil)
        assert_eq(lockerOf(id).lockpick, 3)
        assert_eq(DB.property[id].state, 'held')
        -- the rest comes back on return; the forfeited weapon does not
        P.Return(id, { toSrc = SUSPECT })
        assert_eq(holding(SUSPECT).weapon_pistol, nil)
        assert_eq(holding(SUSPECT).lockpick, 3)
    end)

    it('without an evidence record the item stays in the locker', function()
        local id = seize().receiptId
        evidenceFails = true
        local res = P.Forfeit(id, { { name = 'lockpick' } }, { actor = { src = COP } })
        assert_eq(res.ok, false)
        assert_eq(lockerOf(id).lockpick, 3)
        assert_eq(J.Property.Store.items(id)[2].state, 'held')
        assert_eq(P.Forfeit(id, { { name = 'goldbar' } }, { actor = { src = COP } }).error, 'not_found')
        Mock.newPlayer(OTHER, 'OTH3')
        assert_eq(P.Forfeit(id, { { name = 'lockpick' } }, { actor = { src = OTHER } }).error, 'no_permission')
    end)
end)

describe('visibility, callers, deleted characters, legacy helpers', function()
    it('the owner and officers see a receipt; other citizens do not', function()
        local id = seize().receiptId
        assert_eq(P.GetReceipt(id, { viewer = SUSPECT }).ok, true)
        assert_eq(P.GetReceipt(id, { viewer = COP }).ok, true)
        Mock.newPlayer(OTHER, 'OTH3')
        assert_eq(P.GetReceipt(id, { viewer = OTHER }).error, 'not_found')
        Mock.invokingResource = 'pf-jobs'
        assert_eq(Mock.exportsByResource['pf-justice'].SeizeProperty(SUSPECT, { actor = { src = COP } }).error, 'not_allowed')
        Mock.invokingResource = nil
    end)

    it("a deleted character's lockers are emptied and closed", function()
        local id = seize().receiptId
        P.OnCharacterDeleted('SUS2')
        assert_eq(DB.property[id].state, 'forfeited')
        assert_eq(next(lockerOf(id)), nil)
    end)

    it('legacy refs stay within 64 characters without cutting ids; legacy item lists are cleaned', function()
        assert_eq(J.LegacyImport.Ref('meta_injail', 'ABC123', 'J1'), 'meta_injail:ABC123:J1')
        assert_eq(J.LegacyImport.Ref('meta_injail', 'ABC123', nil), 'meta_injail:ABC123:none')
        local long = J.LegacyImport.Ref('meta_jailitems', 'ABC123', string.rep('9', 80))
        assert_true(#long <= 64, 'short enough')
        assert_true(long ~= J.LegacyImport.Ref('meta_jailitems', 'ABC123', string.rep('9', 79) .. '8'), 'distinct ids stay distinct')
        local list = J.LegacyImport.Items({ ['1'] = { name = 'phone', amount = 1 }, ['2'] = { name = 'x', amount = 0 }, { name = 5 } })
        assert_eq(#list, 1)
        assert_eq(list[1].name, 'phone')
        assert_eq(#J.LegacyImport.Items('[{"name":"lockpick","amount":2}]'), 1)
    end)
end)

describe('rework: forfeiture against the real evidence config; return needs an officer', function()
    it("uses a method pfm-policejob's config lists, and each kind's own attrs", function()
        assert_true(RealEvidence.Methods[J.Property.EVIDENCE_METHOD] == true, 'method listed in config_evidence.lua')
        local id = seize().receiptId
        local rows = J.Property.Store.items(id)
        local res = P.Forfeit(id, { { id = rows[2].id }, { id = rows[3].id } }, { actor = { src = COP } })
        assert_eq(res.ok, true, tostring(res.error) .. ' ' .. tostring(res.message))
        for _, e in ipairs(evidence) do
            assert_eq(e.spec.method, 'seizure')
            for field in pairs(e.spec.attrs) do
                assert_true(RealEvidence.Kinds[e.spec.kind].attrs[field] ~= nil, e.spec.kind .. ' attr ' .. field)
            end
        end
    end)

    it('a system caller (pfm-prison) must name where the evidence goes', function()
        local id = seize().receiptId
        local rows = J.Property.Store.items(id)
        assert_eq(P.Forfeit(id, { { id = rows[2].id } }, {}).error, 'bad_args')
        assert_eq(lockerOf(id).lockpick, 3)
        local res = P.Forfeit(id, { { id = rows[2].id } }, { giveTo = 'stash:prison_evidence' })
        assert_eq(res.ok, true, tostring(res.message))
        assert_eq(evidence[1].opts.giveTo, 'stash:prison_evidence')
    end)

    it('ReturnProperty refuses a player actor who is not an on-duty officer', function()
        local id = seize().receiptId
        Mock.newPlayer(OTHER, 'OTH3')
        assert_eq(P.Return(id, { actor = { src = OTHER } }).error, 'no_permission')
        Mock.players[COP].PlayerData.job.onduty = false
        assert_eq(P.Return(id, { actor = { src = COP } }).error, 'not_on_duty')
        assert_eq(DB.property[id].state, 'held')
        Mock.players[COP].PlayerData.job.onduty = true
        assert_eq(P.Return(id, { actor = { src = COP }, toSrc = SUSPECT }).ok, true)
        assert_eq(DB.property[id].state, 'returned')
    end)
end)
