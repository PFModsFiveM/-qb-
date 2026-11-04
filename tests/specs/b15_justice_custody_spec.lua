-- pf-justice custody and booking (unit 15C acceptance 1-3) plus the metadata mirrors (compat.lua):
--   * the custody machine (architecture 5.4) is enforced: listed moves work, others are refused with
--     invalid_state; booking needs the citizen in a booking zone with the officer; remand is the
--     court's; one open custody per citizen (conflict); keys are idempotent (duplicate, key_reused);
--     callers outside Config.Callers get not_allowed; off-duty officers not_on_duty;
--   * hospital transfer remembers the previous state and returns to it; the clock is told;
--   * reconnect while arrested / in transport / booking / held puts the player back at the facility
--     (server SetEntityCoords) and re-cuffs arrested / in transport, logged as 'reconnect';
--   * an incarceration order at another facility closes the custody as transferred;
--   * booking: BK-<yyyymmdd>-<seq>, fingerprint and blood type from server metadata, a random DNA
--     sample id, client_supplied mugshot, and medical screening that keeps down / red / orange
--     patients out of a holding cell;
--   * compat: injail is mirrored only after the pfm-prison hand-over; a PJ criminal-record flag is
--     never turned back to false while PJ still writes it.
-- 15B's orders, records and clock are stubbed (consumed by contract); its main.lua helpers and
-- shared/states.lua are the resource's shared kit and are loaded as they are.
load_resource('tests/lua/fivem_mocks.lua')
local ROOT = __JU_ROOT or '[pfscripts]/pf-justice/'
local started = { ['pfm-inventory'] = true, ['pfm-policejob'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-justice' end

-- ── stubs of other resources ──────────────────────────────────────────────────────────────────
local cuffs, cuffCalls, cuffResult, samples = {}, {}, true, {}
Mock.exportsByResource['pfm-policejob'] = {
    SetCuffed = function(_, src, on, reason)
        cuffCalls[#cuffCalls + 1] = { src = src, on = on, reason = reason }
        if cuffResult then cuffs[src] = on end
        return cuffResult
    end,
    IsCuffed = function(_, src) return cuffs[src] == true end,
    RegisterReferenceSample = function(_, cid, kind, source, opts) samples[#samples + 1] = { cid = cid, kind = kind, source = source, opts = opts } return { ok = true } end,
}
local Stashes = {}
Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function(_, id) Stashes[id] = Stashes[id] or { items = {} } return true end,
    GetInventory = function(_, id) return Stashes[id] end,
    SaveStash = function() end,
    ClearInventory = function(_, src) Mock.players[src].PlayerData.items = {} end,
    CanAddItem = function() return true end,
    AddItem = function(_, id, name, amount, slot, info)
        local items = type(id) == 'number' and Mock.players[id].PlayerData.items or Stashes[id].items
        items[#items + 1] = { name = name, amount = amount, slot = slot or (#items + 1), info = info }
        return true
    end,
    RemoveItem = function(_, id, name, amount)
        local items = type(id) == 'number' and Mock.players[id].PlayerData.items or Stashes[id].items
        for k, it in pairs(items) do if it.name == name and it.amount >= amount then it.amount = it.amount - amount if it.amount == 0 then items[k] = nil end return true end end
        return false
    end,
}
local summary = nil
Mock.exportsByResource['pf-ambulancejob'] = { GetPatientSummary = function(_, cid) return summary end }
local teleports = {}
function SetEntityCoords(ped, x, y, z) teleports[#teleports + 1] = { ped = ped, x = x, y = y, z = z } end

-- ── pf-justice ────────────────────────────────────────────────────────────────────────────────
Config = nil
load_resource(ROOT .. 'config.lua')
load_resource(ROOT .. 'shared/states.lua')
load_resource(ROOT .. 'server/main.lua')
load_resource(ROOT .. 'server/compat.lua')   -- before custody.lua: the mock keeps one handler per event
load_resource(ROOT .. 'server/custody.lua')
load_resource(ROOT .. 'server/booking.lua')
load_resource(ROOT .. 'server/property.lua')
Mock.exportsByResource['pf-justice'] = Mock.exportsByResource['__self']
local J = PFJustice
local K = J.CustodyKit

-- 15B by contract
local records, jailMinutes, hospitalFlags, orderStates = {}, {}, {}, {}
J.API = {
    AddRecordEntry = function(cid, entry) records[#records + 1] = { cid = cid, entry = entry } return { ok = true, entryId = #records } end,
    GetRecord = function(cid)
        local list = {}
        for _, r in ipairs(records) do if r.cid == cid then list[#list + 1] = { kind = r.entry.kind, at = r.entry.at or Mock.clock } end end
        return { ok = true, entries = list }
    end,
    GetJailMinutes = function(cid) return jailMinutes[cid] or 0 end,
    GetOrders = function() return { ok = true, list = {} } end,
}
J.Clock = { SetHospitalCustody = function(cid, on) hospitalFlags[cid] = on end, srcOf = {} }
J.Orders = { IncarcerationRows = function(cid) return orderStates[cid] or {} end }

-- in-memory stores with the semantics of the SQL ones (compare-and-set, unique keys)
local DB
local function copy(r) local o = {} for k, v in pairs(r) do o[k] = v end return o end
local function apply(r, fields) for k, v in pairs(fields) do if v == K.NULL then r[k] = nil else r[k] = v end end end
local function newDb() return { custody = {}, log = {}, bookings = {}, property = {}, items = {}, n = 0 } end
local function nextId() DB.n = DB.n + 1 return DB.n end
J.Custody.Store = {
    openOf = function(cid) local best for _, r in pairs(DB.custody) do if r.citizenid == cid and not r.closed_at and (not best or r.id > best.id) then best = r end end return best and copy(best) end,
    get = function(id) return DB.custody[id] and copy(DB.custody[id]) end,
    byKey = function(key) for _, r in pairs(DB.custody) do if r.idem_key == key then return copy(r) end end end,
    latestOf = function(cid) local best for _, r in pairs(DB.custody) do if r.citizenid == cid and (not best or r.id > best.id) then best = r end end return best and copy(best) end,
    insert = function(row) local r = copy(row) r.id = nextId() DB.custody[r.id] = r return r.id end,
    cas = function(id, from, fields) local r = DB.custody[id] if not r or r.state ~= from or r.closed_at then return false end apply(r, fields) return true end,
    log = function(cid, kind, data, actor, at) local id = nextId() DB.log[#DB.log + 1] = { id = id, custody_id = cid, kind = kind, data = data, actor_cid = actor, at = at } return id end,
    listLog = function(cid) local out = {} for i = #DB.log, 1, -1 do if DB.log[i].custody_id == cid then out[#out + 1] = DB.log[i] end end return out end,
    dueHolds = function(now) local out = {} for _, r in pairs(DB.custody) do if not r.closed_at and r.hold_until and r.hold_until < now then out[#out + 1] = copy(r) end end return out end,
    openAllOf = function(cid) local out = {} for _, r in pairs(DB.custody) do if r.citizenid == cid and not r.closed_at then out[#out + 1] = copy(r) end end return out end,
}
J.Booking.Store = {
    insert = function(row)
        for _, b in pairs(DB.bookings) do if b.booking_no == row.booking_no or b.custody_id == row.custody_id then return nil, 'duplicate' end end
        local r = copy(row) r.id = nextId() r.client_supplied = 1 DB.bookings[r.id] = r return r.id
    end,
    byCustody = function(cid) for _, b in pairs(DB.bookings) do if b.custody_id == cid then return copy(b) end end end,
    maxNo = function(prefix) local best for _, b in pairs(DB.bookings) do if b.booking_no:sub(1, #prefix) == prefix and (not best or b.booking_no > best) then best = b.booking_no end end return best end,
    anonymise = function() end,
}
local function inSet(v, list) for _, x in ipairs(list) do if x == v then return true end end return false end
J.Property.Store = {
    insert = function(row) local r = copy(row) r.id = nextId() DB.property[r.id] = r return r.id end,
    setStash = function(id, s) DB.property[id].stash_id = s return true end,
    get = function(id) return DB.property[id] and copy(DB.property[id]) end,
    byKey = function(key) for _, r in pairs(DB.property) do if r.idem_key == key then return copy(r) end end end,
    byLegacy = function() return nil end,
    delete = function(id) DB.property[id] = nil end,
    addItem = function(pid, item, amount, info, state) local id = nextId() DB.items[id] = { id = id, property_id = pid, item = item, amount = amount, info = K.encode(info), state = state } return id end,
    items = function(pid) local out = {} for _, it in pairs(DB.items) do if it.property_id == pid then out[#out + 1] = copy(it) end end table.sort(out, function(a, b) return a.id < b.id end) return out end,
    deleteItems = function(pid) for id, it in pairs(DB.items) do if it.property_id == pid then DB.items[id] = nil end end return true end,
    setItemState = function(id, from, to, ev) local it = DB.items[id] if not it or it.state ~= from then return false end it.state, it.evidence_id = to, ev return true end,
    cas = function(id, from, fields) local r = DB.property[id] if not r or not inSet(r.state, from) then return false end apply(r, fields) return true end,
    forField = function(field, value, states) local out = {} for _, r in pairs(DB.property) do if r[field] == value and inSet(r.state, states) then out[#out + 1] = copy(r) end end return out end,
    linkOrder = function(cid, oid) for _, r in pairs(DB.property) do if r.custody_id == cid and not r.order_id and r.state == 'held' then r.order_id = oid end end end,
}
function J.Property.Store.forCustody(id, s) return J.Property.Store.forField('custody_id', id, s) end
function J.Property.Store.forOrder(id, s) return J.Property.Store.forField('order_id', id, s) end
function J.Property.Store.forCitizen(cid, s) return J.Property.Store.forField('citizenid', cid, s) end

-- ── helpers ───────────────────────────────────────────────────────────────────────────────────
local COP, SUSPECT, OTHER, MEDIC = 1, 2, 3, 4
local STREET = vector3(100.0, 100.0, 30.0)
local DESK = vector3(441.0, -981.0, 30.7)        -- inside the Mission Row booking zone
local CELL = Config.Custody.HoldingCells.mrpd_holding[1]

local function officer(src, onduty)
    local p = Mock.newPlayer(src, 'COP' .. src)
    p.PlayerData.job = { name = 'police', type = 'leo', grade = { level = 2 }, onduty = onduty ~= false }
    return p
end
local function logsOf(id, kind)
    local n = 0
    for _, l in ipairs(DB.log) do if l.custody_id == id and (kind == nil or l.kind == kind) then n = n + 1 end end
    return n
end
local function call(name, ...) return Mock.exportsByResource['pf-justice'][name](...) end
local function open(extra)
    local opts = { reason = 'Robbery', actor = { src = COP } }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return J.Custody.Open(SUSPECT, opts)
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.invokingResource = nil
    DB = newDb()
    J.Custody.bySrc, J.Custody.srcByCid, J.Custody.flagged = {}, {}, {}
    cuffs, cuffCalls, teleports, records, jailMinutes, hospitalFlags, orderStates, Stashes = {}, {}, {}, {}, {}, {}, {}, {}
    cuffResult, samples = true, {}
    summary = nil
    started['pf-ambulancejob'] = nil
    Config.Compat = nil
    officer(COP)
    local s = Mock.newPlayer(SUSPECT, 'SUS2')
    s.PlayerData.metadata = { fingerprint = 'FP-SERVER', bloodtype = 'AB-', isdead = false }
    s.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 }, { name = 'lockpick', amount = 2, slot = 2 } }
    Mock.coords[COP], Mock.coords[SUSPECT] = STREET, STREET
end

describe('custody machine (architecture 5.4)', function()
    it('walks arrested -> in_transport -> booking -> booked -> held -> remanded -> transferred', function()
        local res = open()
        assert_eq(res.ok, true, tostring(res.error))
        local id = res.custodyId
        assert_eq(J.Custody.Get(SUSPECT).custody.state, 'arrested')
        assert_eq(J.Custody.SetState(id, 'in_transport', { actor = { src = COP } }).ok, true)
        -- booking needs the citizen inside a booking zone
        local far = J.Custody.SetState(id, 'booking', { actor = { src = COP } })
        assert_eq(far.error, 'too_far')
        Mock.coords[COP], Mock.coords[SUSPECT] = DESK, DESK
        assert_eq(J.Custody.SetState(id, 'booking', { actor = { src = COP } }).ok, true)
        local booked = J.Booking.Book(id, { seize = false }, { actor = { src = COP } })
        assert_eq(booked.ok, true, tostring(booked.error))
        Mock.coords[SUSPECT] = CELL.center
        Mock.coords[COP] = vector3(CELL.center.x + 2.0, CELL.center.y, CELL.center.z)
        assert_eq(J.Custody.AssignCell(id, CELL.id, { actor = { src = COP } }).ok, true)
        assert_true(J.Custody.IsInHoldingCell(SUSPECT), 'standing in the cell')
        Mock.coords[SUSPECT] = DESK
        assert_false(J.Custody.IsInHoldingCell(SUSPECT), 'out of the cell')
        -- remand is the court's
        assert_eq(J.Custody.SetState(id, 'remanded', { actor = { src = COP } }).error, 'no_permission')
        local judge = Mock.newPlayer(9, 'JUDGE9')
        judge.PlayerData.job = { name = 'judge', grade = { level = 1 }, onduty = true }
        assert_eq(J.Custody.SetState(id, 'remanded', { actor = { src = 9 } }).ok, true)
        J.Custody.OnOrderCreated({ id = 77, cid = 'SUS2', kind = 'prison', state = 'active', facility = 'bolingbroke' })
        local c = DB.custody[id]
        assert_eq(c.state, 'transferred')
        assert_true(c.closed_at ~= nil, 'closed')
        assert_eq(J.Custody.Get(SUSPECT).custody, nil, 'no open custody')
        assert_true(logsOf(id) >= 7, 'every step logged')
    end)

    it('refuses moves the machine does not list and states that need their own export', function()
        local id = open().custodyId
        assert_eq(J.Custody.SetState(id, 'held', { actor = { src = COP } }).error, 'invalid_state')
        assert_eq(J.Custody.SetState(id, 'booked', { actor = { src = COP } }).error, 'invalid_state')
        assert_eq(J.Custody.AssignCell(id, CELL.id, { actor = { src = COP } }).error, 'invalid_state', 'arrested -> held is not listed')
        assert_eq(J.Custody.SetState(id, 'detained', { actor = { src = COP } }).error, 'invalid_state')
        assert_eq(J.Custody.SetState(id, 'bogus', { actor = { src = COP } }).error, 'invalid_state')
        assert_eq(J.Custody.Release(id, 'no_charges', { actor = { src = COP } }).ok, true)
        assert_eq(J.Custody.SetState(id, 'in_transport', { actor = { src = COP } }).error, 'invalid_state', 'closed')
    end)

    it('one open custody per citizen; keys are idempotent; a reused key with other arguments is refused', function()
        local a = open({ key = 'pfm-policejob:custody:1' })
        assert_eq(a.ok, true)
        local dup = open({ key = 'pfm-policejob:custody:1' })
        assert_eq(dup.duplicate, true)
        assert_eq(dup.custodyId, a.custodyId)
        local second = open({ key = 'pfm-policejob:custody:2' })
        assert_eq(second.error, 'conflict')
        assert_eq(second.custodyId, a.custodyId)
        J.Custody.Release(a.custodyId, 'no_charges', { actor = { src = COP } })
        local reused = open({ key = 'pfm-policejob:custody:1', reason = 'Different' })
        assert_eq(reused.error, 'key_reused')
        assert_eq(open({ key = 'bad key!' }).error, 'bad_args')
    end)

    it('checks the officer on the server: on duty, nearby, not themselves; callers on the allowlist', function()
        officer(COP, false)
        assert_eq(open().error, 'not_on_duty')
        officer(COP)
        Mock.coords[SUSPECT] = vector3(STREET.x + 30.0, STREET.y, STREET.z)
        assert_eq(open().error, 'too_far')
        Mock.coords[SUSPECT] = STREET
        local civ = Mock.newPlayer(OTHER, 'CIV3')
        Mock.coords[OTHER] = STREET
        assert_eq(J.Custody.Open(SUSPECT, { actor = { src = OTHER } }).error, 'no_permission')
        Mock.invokingResource = 'pf-jobs'
        assert_eq(call('OpenCustody', SUSPECT, { actor = { src = COP } }).error, 'not_allowed')
        assert_eq(call('IsInHoldingCell', SUSPECT), false)
        Mock.invokingResource = 'pfm-policejob'
        assert_eq(call('OpenCustody', SUSPECT, { actor = { src = COP } }).ok, true)
        Mock.invokingResource = 'pf-jobs'
        assert_eq(call('GetCustody', 'SUS2').custody.state, 'arrested', 'GetCustody is open')
        assert_true(civ ~= nil)
    end)

    it('hospital transfer keeps the previous state, tells the clock, and ReturnCustody restores it', function()
        local id = open().custodyId
        Mock.coords[COP], Mock.coords[SUSPECT] = DESK, DESK
        J.Custody.SetState(id, 'booking', { actor = { src = COP } })
        local medic = Mock.newPlayer(MEDIC, 'EMS4')
        medic.PlayerData.job = { name = 'ambulance', type = 'ems', grade = { level = 1 }, onduty = true }
        assert_eq(J.Custody.Transfer(id, { kind = 'hospital', id = 'pillbox' }, { actor = { src = MEDIC } }).ok, true)
        assert_eq(DB.custody[id].state, 'hospital')
        assert_eq(DB.custody[id].prev_state, 'booking')
        assert_eq(hospitalFlags.SUS2, true)
        assert_eq(J.Custody.Return(id, { actor = { src = MEDIC } }).ok, true)
        assert_eq(DB.custody[id].state, 'booking')
        assert_eq(hospitalFlags.SUS2, false)
        assert_eq(J.Custody.Return(id, { actor = { src = MEDIC } }).error, 'invalid_state')
    end)

    it('a jail served in the same facility keeps the custody open until the order releases it', function()
        local id = open({ facility = 'mrpd_holding' }).custodyId
        J.Custody.OnOrderCreated({ id = 5, cid = 'SUS2', kind = 'jail', state = 'active', facility = 'mrpd_holding' })
        assert_eq(DB.custody[id].closed_at, nil)
        J.Custody.OnReleaseOrdered('SUS2', 5, 'completed')
        assert_eq(DB.custody[id].state, 'released')
        assert_eq(DB.custody[id].release_reason, 'sentence_complete')
        -- a legacy shadow order never touches custody
        local id2 = open().custodyId
        J.Custody.OnOrderCreated({ id = 6, cid = 'SUS2', kind = 'jail', state = 'active', facility = 'bolingbroke', legacyRef = 'mdt_jail:1' })
        assert_eq(DB.custody[id2].closed_at, nil)
    end)

    it('a hold past MaxHoldSeconds is flagged once, nobody is released automatically', function()
        local id = open().custodyId
        DB.custody[id].state, DB.custody[id].hold_until = 'held', Mock.clock - 1
        assert_eq(J.Custody.Tick(Mock.clock), 1)
        assert_eq(J.Custody.Tick(Mock.clock), 0)
        assert_eq(DB.custody[id].closed_at, nil)
        assert_eq(logsOf(id, 'hold_expired'), 1)
    end)
end)

describe('reconnect (acceptance 2)', function()
    local function reconnect()
        teleports, cuffCalls = {}, {}
        J.Custody.bySrc, J.Custody.srcByCid = {}, {}
        Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, { PlayerData = { source = SUSPECT, citizenid = 'SUS2' } })
    end
    it('arrested: back to the facility return point and re-cuffed, logged', function()
        local id = open({ facility = 'mrpd_holding' }).custodyId
        reconnect()
        local rp = Config.Custody.ReturnPoint.mrpd_holding
        assert_eq(#teleports, 1)
        assert_near(teleports[1].x, rp.x, 0.01)
        assert_near(teleports[1].y, rp.y, 0.01)
        assert_eq(#cuffCalls, 1)
        assert_eq(cuffCalls[1].on, true)
        assert_eq(cuffCalls[1].reason, 'custody')
        assert_eq(logsOf(id, 'reconnect'), 1)
        assert_true(J.Custody.bySrc[SUSPECT] ~= nil, 'memory rebuilt')
    end)
    it('in transport: re-cuffed too; booking: placed back, no cuffs', function()
        local id = open({ facility = 'mrpd_holding' }).custodyId
        J.Custody.SetState(id, 'in_transport', { actor = { src = COP } })
        reconnect()
        assert_eq(#teleports, 1)
        assert_eq(#cuffCalls, 1)
        Mock.coords[COP], Mock.coords[SUSPECT] = DESK, DESK
        J.Custody.SetState(id, 'booking', { actor = { src = COP } })
        reconnect()
        assert_eq(#teleports, 1)
        assert_eq(#cuffCalls, 0)
    end)
    it('held: back into the cell; detained or released: nothing', function()
        local id = open().custodyId
        Mock.coords[COP], Mock.coords[SUSPECT] = DESK, DESK
        J.Custody.SetState(id, 'booking', { actor = { src = COP } })
        J.Booking.Book(id, { seize = false }, { actor = { src = COP } })
        Mock.coords[SUSPECT] = CELL.center
        J.Custody.AssignCell(id, CELL.id, {})
        reconnect()
        assert_eq(#teleports, 1)
        assert_near(teleports[1].x, CELL.center.x, 0.01)
        assert_eq(#cuffCalls, 0)
        J.Custody.Release(id, 'no_charges', {})
        reconnect()
        assert_eq(#teleports, 0)
        local d = open({ state = 'detained' })
        assert_eq(d.ok, true)
        reconnect()
        assert_eq(#teleports, 0, 'detained is not placed back')
    end)
end)

describe('booking (acceptance 3)', function()
    local function atDesk()
        local id = open().custodyId
        Mock.coords[COP], Mock.coords[SUSPECT] = DESK, DESK
        return id
    end
    it('numbers BK-<yyyymmdd>-<seq>, reads fingerprint and blood type on the server, random DNA id', function()
        local id = atDesk()
        local res = J.Booking.Book(id, { mugshotUrl = 'https://i.example.com/a.png', height = 182, marks = 'tattoo', fingerprint = 'FAKE' },
            { actor = { src = COP } })
        assert_eq(res.ok, true, tostring(res.error))
        local day = os.date('%Y%m%d', Mock.clock)
        assert_eq(res.bookingNo, 'BK-' .. day .. '-0001')
        local b = J.Booking.Get(id).booking
        assert_eq(b.fingerprint, 'FP-SERVER', 'never the client value')
        assert_eq(b.bloodtype, 'AB-')
        assert_eq(b.clientSupplied, true)
        assert_eq(b.mugshotUrl, 'https://i.example.com/a.png')
        assert_true(b.dnaSampleRef:match('^DNA%-[0-9A-Z]+$') ~= nil and not b.dnaSampleRef:find('SUS2'), 'random DNA id')
        assert_eq(DB.custody[id].state, 'booked')
        assert_eq(DB.custody[id].booking_no, res.bookingNo)
        assert_eq(records[1].entry.kind, 'arrest')
        assert_eq(J.Booking.Book(id, {}, { actor = { src = COP } }).duplicate, true)
        -- the next citizen gets the next number; their DNA id differs
        local o = Mock.newPlayer(OTHER, 'OTH3')
        o.PlayerData.metadata = { fingerprint = 'FP-O' }
        Mock.coords[OTHER] = DESK
        local id2 = J.Custody.Open(OTHER, { actor = { src = COP } }).custodyId
        local res2 = J.Booking.Book(id2, { seize = false }, { actor = { src = COP } })
        assert_eq(res2.bookingNo, 'BK-' .. day .. '-0002')
        assert_true(J.Booking.Get(id2).booking.dnaSampleRef ~= b.dnaSampleRef)
    end)
    it('steps arrested -> booking at a desk; refuses outside a booking zone and non-https mugshots', function()
        local id = open().custodyId
        assert_eq(J.Booking.Book(id, {}, { actor = { src = COP } }).error, 'too_far')
        Mock.coords[COP], Mock.coords[SUSPECT] = DESK, DESK
        assert_eq(J.Booking.Book(id, { mugshotUrl = 'http://x.example/a.png' }, { actor = { src = COP } }).error, 'bad_args')
        assert_eq(J.Booking.Book(id, { mugshotUrl = 'javascript:alert(1)' }, { actor = { src = COP } }).error, 'bad_args')
        assert_eq(J.Booking.Book(id, { height = 9000 }, { actor = { src = COP } }).error, 'bad_args')
        assert_eq(J.Booking.Book(id, {}, { actor = { src = COP } }).ok, true)
    end)
    it('booking seizes the property into a locker with a receipt', function()
        local id = atDesk()
        local res = J.Booking.Book(id, { keep = { 'phone' } }, { actor = { src = COP } })
        assert_eq(res.ok, true)
        assert_true(res.receiptId ~= nil, 'receipt')
        local r = J.Property.GetReceipt(res.receiptId).receipt
        assert_eq(#r.items, 1)
        assert_eq(r.items[1].name, 'lockpick')
        assert_eq(r.lockerStash, 'pf_justice_property_' .. res.receiptId)
        local left = Mock.players[SUSPECT].PlayerData.items
        assert_eq(#left, 1)
        assert_eq(left[1].name, 'phone', 'the kept item stays')
    end)
    it('medical screening: down, red and orange patients go to hospital before a cell', function()
        started['pf-ambulancejob'] = true
        for _, s in ipairs({ { down = true }, { triage = 'red' }, { triage = 'orange' } }) do
            DB = newDb()
            J.Custody.bySrc, J.Custody.srcByCid = {}, {}
            summary = s
            local id = atDesk()
            local res = J.Booking.Book(id, { seize = false }, { actor = { src = COP } })
            assert_eq(res.ok, true)
            assert_eq(res.screening, 'hospital_required')
            Mock.coords[SUSPECT] = CELL.center
            local cell = J.Custody.AssignCell(id, CELL.id, {})
            assert_eq(cell.error, 'invalid_state')
            assert_true(tostring(cell.message):find('hospital') ~= nil)
        end
        DB = newDb()
        J.Custody.bySrc, J.Custody.srcByCid = {}, {}
        summary = { triage = 'yellow', down = false }
        local id = atDesk()
        assert_eq(J.Booking.Book(id, { seize = false }, { actor = { src = COP } }).screening, 'clear')
        Mock.coords[SUSPECT] = CELL.center
        assert_eq(J.Custody.AssignCell(id, CELL.id, {}).ok, true)
    end)
    it('without the medical engine a dead / last-stand citizen is still kept out of a cell', function()
        local id = atDesk()
        J.Booking.Book(id, { seize = false }, { actor = { src = COP } })
        Mock.players[SUSPECT].PlayerData.metadata.inlaststand = true
        Mock.coords[SUSPECT] = CELL.center
        assert_eq(J.Custody.AssignCell(id, CELL.id, {}).error, 'invalid_state')
        Mock.players[SUSPECT].PlayerData.metadata.inlaststand = false
        assert_eq(J.Custody.AssignCell(id, CELL.id, {}).ok, true)
    end)
end)

describe('metadata mirrors (compat.lua)', function()
    it('injail is left to pfm-prison until the hand-over, then mirrors the JU minutes', function()
        jailMinutes.SUS2 = 12
        Mock.players[SUSPECT].PlayerData.metadata.injail = 0
        J.Compat.Refresh('SUS2', { injail = true })
        assert_eq(Mock.players[SUSPECT].PlayerData.metadata.injail, 0, 'batch 15: pfm-prison owns injail')
        Config.Compat = { LegacyRuntimes = { prison = false, mdt = false } }
        J.Compat.Refresh('SUS2', { injail = true })
        assert_eq(Mock.players[SUSPECT].PlayerData.metadata.injail, 12)
        -- a chain holding a live MDT shadow is never mirrored (the MDT still jails them itself)
        Config.Compat = { LegacyRuntimes = { prison = false } }
        orderStates.SUS2 = { { id = 1, state = 'active', legacy_ref = 'mdt_jail:4' } }
        jailMinutes.SUS2 = 30
        J.Compat.Refresh('SUS2', { injail = true })
        assert_eq(Mock.players[SUSPECT].PlayerData.metadata.injail, 12)
    end)
    it('criminalrecord follows convictions with expiry, never undoing a PJ flag while PJ still writes it', function()
        Mock.players[SUSPECT].PlayerData.metadata.criminalrecord = { hasRecord = true, date = { year = 2026, month = 1, day = 1 } }
        J.Compat.Refresh('SUS2', { record = true })
        assert_eq(Mock.players[SUSPECT].PlayerData.metadata.criminalrecord.hasRecord, true, 'PJ flag kept')
        Config.Compat = { LegacyRuntimes = { policejob = false }, RecordExpiryDays = 30 }
        J.Compat.Refresh('SUS2', { record = true })
        assert_eq(Mock.players[SUSPECT].PlayerData.metadata.criminalrecord.hasRecord, false, 'JU is the writer after the hand-over')
        records[#records + 1] = { cid = 'SUS2', entry = { kind = 'conviction', at = Mock.clock - 86400 } }
        J.Compat.Refresh('SUS2', { record = true })
        local rec = Mock.players[SUSPECT].PlayerData.metadata.criminalrecord
        assert_eq(rec.hasRecord, true)
        assert_eq(rec.date.year, tonumber(os.date('%Y', Mock.clock - 86400)))
        records[#records].entry.at = Mock.clock - 31 * 86400
        J.Compat.Refresh('SUS2', { record = true })
        assert_eq(Mock.players[SUSPECT].PlayerData.metadata.criminalrecord.hasRecord, false, 'expired')
    end)
end)

describe('rework: transfers follow the machine; medics never release (checker P3, P4)', function()
    local MED = 4
    local function medic()
        local m = Mock.newPlayer(MED, 'EMS4')
        m.PlayerData.job = { name = 'ambulance', type = 'ems', grade = { level = 1 }, onduty = true }
    end
    local function bookAndSeize()
        local id = open().custodyId
        Mock.coords[COP], Mock.coords[SUSPECT] = DESK, DESK
        local b = J.Booking.Book(id, {}, { actor = { src = COP } })
        assert_eq(b.ok, true)
        return id, b.receiptId
    end

    it('a medic cannot release a prisoner with any reason, but moves them to and from hospital', function()
        medic()
        local id = open().custodyId
        assert_eq(J.Custody.Transfer(id, { kind = 'hospital', id = 'pillbox' }, { actor = { src = MED } }).ok, true)
        for _, reason in ipairs({ 'transferred', 'no_charges', 'sentence_complete' }) do
            local res = J.Custody.Release(id, reason, { actor = { src = MED } })
            assert_eq(res.ok, false, reason)
            assert_eq(res.error, 'no_permission', reason)
        end
        assert_eq(DB.custody[id].state, 'hospital')
        assert_eq(DB.custody[id].closed_at, nil)
        assert_eq(J.Custody.Return(id, { actor = { src = MED } }).ok, true)
        assert_eq(DB.custody[id].state, 'arrested')
    end)

    it('a prison transfer from arrested / in transport / booking / detained / hospital is refused, nothing released', function()
        for _, state in ipairs({ 'arrested', 'in_transport', 'booking', 'detained', 'hospital' }) do
            DB = newDb()
            J.Custody.bySrc, J.Custody.srcByCid = {}, {}
            cuffs[SUSPECT], cuffCalls = true, {}
            Mock.players[SUSPECT].PlayerData.items = { { name = 'lockpick', amount = 2, slot = 1 } }
            local id = open().custodyId
            local rid = J.Property.Seize(SUSPECT, { custodyId = id, actor = { src = COP } }).receiptId
            DB.custody[id].state, DB.custody[id].prev_state = state, 'arrested'
            local res = J.Custody.Transfer(id, { kind = 'prison', id = 'bolingbroke' }, { actor = { src = COP } })
            assert_eq(res.error, 'invalid_state', state)
            assert_eq(DB.custody[id].state, state, state .. ' unchanged')
            assert_eq(DB.custody[id].closed_at, nil, state)
            assert_eq(#cuffCalls, 0, state .. ': cuffs untouched')
            assert_eq(DB.property[rid].state, 'held', state .. ': property kept')
            assert_eq(J.Custody.Release(id, 'transferred', { actor = { src = COP } }).error, 'invalid_state', state)
        end
    end)

    it('from held the transfer closes as transferred and keeps the property for prison', function()
        local id, rid = bookAndSeize()
        Mock.coords[SUSPECT] = CELL.center
        assert_eq(J.Custody.AssignCell(id, CELL.id, {}).ok, true)
        cuffs[SUSPECT], cuffCalls = true, {}
        assert_eq(J.Custody.Transfer(id, { kind = 'prison', id = 'bolingbroke' }, { actor = { src = COP } }).ok, true)
        assert_eq(DB.custody[id].state, 'transferred')
        assert_eq(DB.property[rid].state, 'held')
        assert_eq(#cuffCalls, 0)
    end)

    it('an order that takes a citizen straight from arrest closes the custody without release effects', function()
        local id = open().custodyId
        local rid = J.Property.Seize(SUSPECT, { custodyId = id, actor = { src = COP } }).receiptId
        cuffs[SUSPECT], cuffCalls = true, {}
        J.Custody.OnOrderCreated({ id = 31, cid = 'SUS2', kind = 'jail', state = 'active', facility = 'bolingbroke' })
        assert_true(DB.custody[id].closed_at ~= nil, 'closed')
        assert_eq(DB.custody[id].release_reason, 'transferred')
        assert_eq(DB.property[rid].state, 'held', 'property follows the order')
        assert_eq(DB.property[rid].order_id, 31)
        assert_eq(#cuffCalls, 0, 'cuffs are the jail owner\'s business')
    end)
end)

describe('rework: reconnect cuff flag and the lab reference sample', function()
    it('the reconnect log says cuffed only when SetCuffed did it', function()
        local id = open({ facility = 'mrpd_holding' }).custodyId
        cuffResult = false
        J.Custody.bySrc, J.Custody.srcByCid = {}, {}
        Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, { PlayerData = { source = SUSPECT, citizenid = 'SUS2' } })
        local data
        for _, l in ipairs(DB.log) do if l.custody_id == id and l.kind == 'reconnect' then data = json.decode(l.data) end end
        assert_eq(data.cuffed, false)
        cuffResult = true
        J.Custody.bySrc, J.Custody.srcByCid = {}, {}
        Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, { PlayerData = { source = SUSPECT, citizenid = 'SUS2' } })
        for _, l in ipairs(DB.log) do if l.custody_id == id and l.kind == 'reconnect' then data = json.decode(l.data) end end
        assert_eq(data.cuffed, true)
    end)

    it('booking hands the random DNA token to the lab registration', function()
        local id = open().custodyId
        Mock.coords[COP], Mock.coords[SUSPECT] = DESK, DESK
        local res = J.Booking.Book(id, { seize = false }, { actor = { src = COP } })
        assert_eq(#samples, 1)
        assert_eq(samples[1].kind, 'dna')
        assert_eq(samples[1].source.sampleRef, J.Booking.Get(id).booking.dnaSampleRef)
        assert_eq(samples[1].source.bookingNo, res.bookingNo)
    end)
end)
