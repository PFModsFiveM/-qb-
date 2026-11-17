-- pfm-prison security (batch 19F): doors through pfm-doorlock SetDoorState, camera points, alarms and
-- restricted zones, contraband searches (pat, visitor, cell) whose finds go through pf-justice
-- forfeiture into evidence (or straight to evidence from a cell locker), lockdowns through the
-- facility, and escapes with persistent consequences (escape row, classification raised, warrant
-- request to the police MDT, recapture closes the row and forfeits credits). pf-justice, the police
-- MDT, pfm-policejob evidence, pfm-inventory and pfm-doorlock are stubbed by their contracts.
-- B19_PRISON_DIR runs the same spec against a scratch copy (fail-without-fix of main.lua).
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
vec2 = vector2
local DIR = B19_PRISON_DIR or 'pfm-prison'

local justiceConfigText = 'Config = Config or {}\nConfig.Compat = { LegacyRuntimes = { mdt = false, prison = false, policejob = false } }\n'
function LoadResourceFile(res, file)
    if res == 'pf-justice' and file == 'config.lua' then return justiceConfigText end
    return nil
end

-- deterministic randomness: math.random() (a detection roll) returns RNG; math.random(a, b) returns a
local RNG = 0.0
math.random = function(a, b)
    if a == nil then return RNG end
    if b == nil then return 1 end
    return a
end

local function copy(o) local t = {} for k, v in pairs(o) do t[k] = v end return t end

-- ── pf-justice stand-in (contract only) ────────────────────────────────────────────────────────
local JU = {}
local function resetJU()
    JU.orders, JU.n, JU.calls, JU.receipts, JU.busyAdjust, JU.adjustError = {}, 0, {}, {}, false, nil
    JU.noForfeit, JU.noSeize = false, false
end
resetJU()
local function call(name, args) JU.calls[#JU.calls + 1] = { name = name, args = args } end
local function calls(name)
    local out = {}
    for _, c in ipairs(JU.calls) do if c.name == name then out[#out + 1] = c end end
    return out
end
local function cidOf(who)
    if type(who) == 'number' then return Mock.players[who] and Mock.players[who].PlayerData.citizenid end
    return who
end
local function openOf(cid)
    local out = {}
    for _, o in ipairs(JU.orders) do
        if o.cid == cid and (o.state == 'active' or o.state == 'pending' or o.state == 'suspended') then out[#out + 1] = o end
    end
    return out
end
local function emit(name, ...) TriggerEvent('pf-justice:server:' .. name, ...) end
function JU.add(cid, spec)
    JU.n = JU.n + 1
    local o = { id = JU.n, cid = cid, kind = 'prison', state = spec.state or 'active', facility = 'bolingbroke',
        requiredSeconds = (spec.minutes or 30) * 60, servedSeconds = 0, creditSeconds = 0, forfeitSeconds = 0, createdAt = Mock.clock }
    JU.orders[#JU.orders + 1] = o
    return o
end

local justiceExports = {
    GetOrders = function(_, cid)
        local list = {}
        for i = #JU.orders, 1, -1 do if JU.orders[i].cid == cid then list[#list + 1] = copy(JU.orders[i]) end end
        return { ok = true, list = list }
    end,
    GetJailMinutes = function() return 30 end,
    CreateOrder = function(_, spec, opts)
        call('CreateOrder', { spec = spec, opts = opts })
        local o = JU.add(spec.cid, { minutes = spec.minutes })
        emit('orderCreated', copy(o))
        return { ok = true, orderId = o.id, state = o.state }
    end,
    AdjustOrder = function(_, id, change, opts)
        call('AdjustOrder', { id = id, change = change, opts = opts })
        if JU.busyAdjust then return { ok = false, error = 'busy' } end
        local o = JU.orders[id]
        if change.kind == 'suspend' then
            if o.state ~= 'active' then return { ok = false, error = 'invalid_state' } end
            o.state = 'suspended'
        elseif change.kind == 'resume' then
            if o.state ~= 'suspended' then return { ok = false, error = 'invalid_state' } end
            o.state = 'active'
        elseif change.kind == 'forfeit' then
            if o.state ~= 'active' then return { ok = false, error = 'invalid_state' } end
            local applied = math.min(change.seconds, o.creditSeconds - o.forfeitSeconds)
            o.forfeitSeconds = o.forfeitSeconds + applied
            emit('orderChanged', copy(o), change)
            return { ok = true, order = copy(o), applied = applied }
        elseif change.kind == 'credit' then
            o.creditSeconds = o.creditSeconds + change.seconds
        end
        emit('orderChanged', copy(o), change)
        return { ok = true, order = copy(o), applied = change.seconds }
    end,
    SetOrderState = function(_, id, to) local o = JU.orders[id] o.state = to return { ok = true, order = copy(o) } end,
    ReleaseNow = function() return { ok = true, released = 0 } end,
    -- items 'all' (intake) or a list of { name, slot, amount } (a search): a receipt with one row each
    SeizeProperty = function(_, src, opts)
        call('SeizeProperty', { src = src, opts = opts })
        for _, r in pairs(JU.receipts) do
            if r.key == opts.key then return { ok = true, duplicate = true, receiptId = r.id } end
        end
        local P = Mock.players[src]
        local rows = {}
        if opts.items == 'all' then
            for _, it in ipairs(P.PlayerData.items) do rows[#rows + 1] = { name = it.name, amount = it.amount } end
            P.PlayerData.items = {}
        else
            for _, want in ipairs(opts.items) do
                local hit
                for i, it in ipairs(P.PlayerData.items) do if it.slot == want.slot and it.name == want.name then hit = i end end
                if not hit then return { ok = false, error = 'bad_args' } end
                table.remove(P.PlayerData.items, hit)
                rows[#rows + 1] = { name = want.name, amount = want.amount }
            end
        end
        local id = #JU.receipts + 1
        local r = { id = id, key = opts.key, items = {} }
        for n, row in ipairs(rows) do r.items[n] = { id = id * 100 + n, name = row.name, amount = row.amount, state = 'held' } end
        JU.receipts[id] = r
        return { ok = true, receiptId = id, items = #rows }
    end,
    ReturnProperty = function(_, id) call('ReturnProperty', { id = id }) return { ok = true, returned = 1 } end,
    GetPropertyReceipt = function(_, id)
        local r = JU.receipts[id]
        if not r then return { ok = false, error = 'not_found' } end
        local items = {}
        for _, it in ipairs(r.items) do items[#items + 1] = copy(it) end
        return { ok = true, receipt = { id = id, state = 'held', items = items } }
    end,
    ForfeitPropertyItems = function(_, id, items, opts)
        call('ForfeitPropertyItems', { id = id, items = items, opts = opts })
        local r = JU.receipts[id]
        local ids = {}
        for _, want in ipairs(items) do
            for _, it in ipairs(r.items) do
                if it.id == want.id and it.state == 'held' then
                    it.state, it.evidenceId = 'forfeited', 900 + it.id
                    ids[#ids + 1] = it.evidenceId
                end
            end
        end
        return { ok = true, evidenceIds = ids }
    end,
}
local function installJustice()
    local e = {}
    for k, v in pairs(justiceExports) do e[k] = v end
    if JU.noForfeit then e.ForfeitPropertyItems = nil end
    if JU.noSeize then e.SeizeProperty = nil end
    Mock.exportsByResource['pf-justice'] = e
end
installJustice()

-- ── pfm-inventory, pfm-policejob evidence, pfm-doorlock, the police MDT ───────────────────────
local stashes, opened = {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    ClearInventory = function(_, src) Mock.players[src].PlayerData.items = {} end,
    AddItem = function(_, where, name, amount, slot, info)
        if type(where) == 'string' then
            stashes[where] = stashes[where] or {}
            table.insert(stashes[where], { name = name, amount = amount, slot = slot or (#stashes[where] + 1), info = info })
        end
        return true
    end,
    RemoveItem = function(_, where, name, amount, slot)
        if type(where) ~= 'string' then return true end
        for i, it in ipairs(stashes[where] or {}) do
            if it.name == name and (slot == nil or it.slot == slot) then table.remove(stashes[where], i) return true end
        end
        return false
    end,
    HasItem = function() return true end,
    CreateInventory = function(_, id) stashes[id] = stashes[id] or {} end,
    GetInventory = function(_, id) return stashes[id] and { items = stashes[id] } or nil end,
    OpenInventory = function(_, src, id) opened[#opened + 1] = { src = src, id = id } end,
}
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function() return { id = 'ch1', kind = 'hacking', puzzle = {} } end,
    Verify = function() return true end,
    Cancel = function() end,
}
local evidence = { list = {}, fail = false }
Mock.exportsByResource['pfm-policejob'] = {
    CreateEvidence = function(_, spec, opts)
        if evidence.fail then return { ok = false, error = 'db_unavailable' } end
        evidence.list[#evidence.list + 1] = { spec = spec, opts = opts }
        return { ok = true, evidenceId = 500 + #evidence.list, tag = 'EV-' .. #evidence.list }
    end,
}
local doors = {}
Mock.exportsByResource['pfm-doorlock'] = {
    SetDoorState = function(_, id, locked) doors[#doors + 1] = { id = id, locked = locked } return { ok = true, doorId = 13, locked = locked, changed = true } end,
    GetDoorState = function() return true end,
}
local warrants = { list = {}, recalls = {}, missing = false, requestError = nil, recallError = nil }
local function installMdt()
    if warrants.missing then Mock.exportsByResource['pf-policemdt-DEV'] = {} return end
    Mock.exportsByResource['pf-policemdt-DEV'] = {
        RequestWarrant = function(_, spec, opts)
            warrants.list[#warrants.list + 1] = { spec = spec, opts = opts }
            if warrants.requestError then return { ok = false, error = warrants.requestError } end
            return { ok = true, warrantId = 'W2611170001' }
        end,
        RecallWarrant = function(_, id, reason, opts)
            warrants.recalls[#warrants.recalls + 1] = { id = id, reason = reason, opts = opts }
            if warrants.recallError then return { ok = false, error = warrants.recallError } end
            return { ok = true, warrantId = id }
        end,
    }
end
-- pf-ambulancejob custody care (19G IsInCustodyCare): [src] = 'transfer' | 'infirmary'
local care = {}
Mock.exportsByResource['pf-ambulancejob'] = {
    IsInCustodyCare = function(_, who) if care[who] then return true, care[who], 'pillbox' end return false end,
}
installMdt()
local infractions = {}
Mock.exportsByResource['pfm-prison'] = {
    RecordInfraction = function(_, cid, spec, opts) infractions[#infractions + 1] = { cid = cid, spec = spec, opts = opts } return { ok = true, infractionId = 7 } end,
}
Mock.exportsByResource['pf-services'] = { Emit = function() return 1 end }
function SetEntityCoords() end

-- pf_prison_* statements on the fake database
local Rows, Events, Searches, Escapes, VisitUpdates = {}, {}, {}, {}, {}
FakeDB.extraPatterns = {
    { 'INSERT INTO pf_prison_inmates', function(p)
        Rows[p[1]] = { citizenid = p[1], order_id = p[2], facility = p[3], status = p[4], cell_id = p[5], classification = p[6],
            admitted_at = p[7], status_at = p[8], job_ticket = p[9], receipt_ids = p[10] }
        return 1
    end },
    { 'DELETE FROM pf_prison_inmates', function(p) Rows[p[1]] = nil return 1 end },
    { 'SELECT * FROM pf_prison_inmates', function() return {} end },
    { 'INSERT INTO pf_prison_searches', function(p)
        Searches[#Searches + 1] = { facility = p[1], kind = p[2], target = p[3], by_cid = p[4], at = p[5] }
        return #Searches
    end },
    { 'UPDATE pf_prison_searches SET found', function(p) local s = Searches[p[3]] s.found, s.evidence_ids = p[1], p[2] return 1 end },
    { 'FROM pf_prison_searches WHERE facility', function()
        local out = {}
        for id, s in ipairs(Searches) do
            if s.found and s.found:find('forfeit_pending', 1, true) then out[#out + 1] = { id = id, target = s.target, found = s.found } end
        end
        return out
    end },
    { 'pf_prison_searches', function() return 0 end },
    { 'INSERT INTO pf_prison_escapes', function(p)
        Escapes[#Escapes + 1] = { citizenid = p[1], order_id = p[2], method = p[3], gate = p[4], escaped_at = p[5] }
        return #Escapes
    end },
    { 'UPDATE pf_prison_escapes SET warrant_id', function(p) local e = Escapes[p[2]] if e and not e.warrant_id then e.warrant_id = p[1] return 1 end return 0 end },
    { 'SET recaptured_at = ? WHERE id = ?', function(p) local e = Escapes[p[2]] if e and not e.recaptured_at then e.recaptured_at = p[1] return 1 end return 0 end },
    { 'SET recaptured_at = ? WHERE citizenid', function(p)
        for _, e in ipairs(Escapes) do if e.citizenid == p[2] and e.order_id == p[3] and not e.recaptured_at then e.recaptured_at = p[1] end end
        return 1
    end },
    { 'WHERE recaptured_at IS NULL AND escaped_at', function()
        local out = {}
        for id, e in ipairs(Escapes) do if not e.recaptured_at then local r = copy(e) r.id = id out[#out + 1] = r end end
        return out
    end },
    { 'pf_prison_escapes', function() return 0 end },
    { 'UPDATE pf_prison_visits', function(p) VisitUpdates[#VisitUpdates + 1] = p return 1 end },
    { 'INSERT INTO pf_prison_events', function(p) Events[#Events + 1] = { cid = p[1], kind = p[3], detail = p[4], actor = p[5] } return #Events end },
    { 'FROM pf_prison_events WHERE facility = ? AND kind = ? AND at', function(p)
        local out = {}
        for i = #Events, 1, -1 do if Events[i].kind == p[2] then out[#out + 1] = { citizenid = Events[i].cid, detail = Events[i].detail } end end
        return out
    end },
    { 'pf_prison_events', function() return 0 end },
}
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

LedgerEnv.load('pfm-prison', { DIR .. '/config.lua', DIR .. '/config_facility.lua', DIR .. '/server/main.lua', DIR .. '/server/schema.lua',
    DIR .. '/server/justice_bridge.lua', DIR .. '/server/security.lua' })
local B = PFPrison.Bridge
local Sec = PFPrison.Security

local INMATE, VISITOR, GUARD, COP = 1, 2, 3, 4
local MIDDLE = Config.Locations['middle']
local function at(dx, dy) return vector3(MIDDLE.x + dx, MIDDLE.y + dy, MIDDLE.z) end
local GATE = Config.Gates[1].coords
local GATEHOUSE = Config.Security.ControlPoints[1].coords
local CELL = vector3(1661.046, 2524.681, 45.564) -- config_facility.lua cell A101
local function events(name, target)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if target == nil or e.target == target then out[#out + 1] = e end end
    return out
end
local function advance(s) Mock.clock = Mock.clock + s end
local function eventsOf(kind)
    local out = {}
    for _, e in ipairs(Events) do if e.kind == kind then out[#out + 1] = e end end
    return out
end
local function staffPlayer(src, cid, job, grade)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, type = job == 'police' and 'leo' or 'corrections', onduty = true, grade = { level = grade or 0 } }
    return p
end
local function inmatePlayer(src, cid)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.charinfo = { firstname = 'John', lastname = 'Doe' .. src }
    p.PlayerData.job = { name = 'mechanic', onduty = false }
    p.SetJobDuty = function(on) p.PlayerData.job.onduty = on end
    p.Functions.SetJobDuty = p.SetJobDuty
    p.PlayerData.items = {}
    p.PlayerData.metadata.injail = 0
    return p
end
local function jail()
    Mock.invokingResource = 'pfm-policejob'
    Mock.selfExport('JailPlayer')(INMATE, 30)
    Mock.invokingResource = nil
    B.Pump()
end
local function give(src, items) Mock.players[src].PlayerData.items = items end

BeforeEach = function()
    PFPrison.EndAlarm()
    for _, src in ipairs({ 1, 2, 3, 4 }) do if Mock.players[src] then Mock.fireEvent('playerDropped', src) end end
    Mock.reset()
    LedgerEnv.reset()
    advance(5000)
    Mock.players, Mock.coords = {}, {}
    resetJU()
    installJustice()
    warrants.list, warrants.recalls, warrants.missing, warrants.requestError, warrants.recallError = {}, {}, false, nil, nil
    installMdt()
    for k in pairs(care) do care[k] = nil end
    PFPrison.Work = nil
    Sec.recalls = {}
    RNG = 0.0
    evidence.list, evidence.fail = {}, false
    doors, infractions, opened = {}, {}, {}
    for k in pairs(stashes) do stashes[k] = nil end
    for _, t in ipairs({ Rows, Events, Searches, Escapes, VisitUpdates }) do for k in pairs(t) do t[k] = nil end end
    for k in pairs(B.rows) do B.rows[k] = nil end
    B.queue, B.actions, B.credits, B.pending, B.escapees, B.needSeize, B.loadAt = {}, {}, {}, {}, {}, {}, {}
    Sec.alarms, Sec.escapes, Sec.forfeits, Sec.pending, Sec.busy = {}, {}, {}, {}, {}
    Sec.lastSearch, Sec.lastOfficer, Sec.zoneSeen, Sec.cameraSeen = {}, {}, {}, {}
    PFPrison.Facility = nil
    inmatePlayer(INMATE, 'INMATECID')
    inmatePlayer(VISITOR, 'VISITORCID')
    staffPlayer(GUARD, 'GUARDCID', 'corrections', 2)
    staffPlayer(COP, 'COPCID', 'police', 0)
    Mock.coords[INMATE], Mock.coords[VISITOR], Mock.coords[GUARD], Mock.coords[COP] = at(0, 0), vector3(0, 0, 0), at(1, 0), vector3(0, 0, 0)
    B.ResetMode()
    B.Boot()
end

describe('contraband rules', function()
    it('weapons, listed items and prefixes are contraband; everyday items are not', function()
        assert_eq(Sec.ContrabandClass('weapon_pistol'), 'weapon')
        assert_eq(Sec.ContrabandClass('phone'), 'phone')
        assert_eq(Sec.ContrabandClass('weed_skunk'), 'drug')
        assert_eq(Sec.ContrabandClass('contraband_shiv'), 'tool')
        assert_eq(Sec.ContrabandClass('sandwich'), nil)
        assert_near(Sec.DetectChance('pat', 'weapon'), 0.65)
        assert_near(Sec.DetectChance('pat', 'drug'), 0.65 * 0.7)
        assert_near(Sec.DetectChance('cell', 'phone'), 0.8 * 0.8)
    end)
end)

describe('pat search', function()
    it('what is found goes through pf-justice forfeiture into evidence, keyed by the search', function()
        jail()
        give(INMATE, { { name = 'phone', amount = 1, slot = 1 }, { name = 'sandwich', amount = 2, slot = 2 } })
        local res = Sec.Search(GUARD, 'pat', INMATE)
        assert_true(res.ok, tostring(res.error))
        assert_eq(#res.found, 1)
        assert_eq(res.found[1].name, 'phone')
        assert_eq(res.state, 'evidence')
        local seize = calls('SeizeProperty')
        local s = seize[#seize].args
        assert_eq(s.opts.key, ('pfm-prison:contraband:%d:seize'):format(res.searchId))
        assert_eq(s.opts.items[1].name, 'phone')
        assert_eq(s.opts.items[1].slot, 1)
        assert_eq(s.opts.actor.src, GUARD)
        assert_eq(s.opts.orderId, 1)
        local f = calls('ForfeitPropertyItems')[1].args
        assert_eq(f.opts.actor.kind, 'system', 'corrections staff cannot collect evidence: a system actor with a stash')
        assert_eq(f.opts.giveTo, 'stash:pfprison_evidence_bolingbroke')
        assert_eq(res.evidenceIds[1], 900 + f.items[1].id)
        -- the sandwich stays; the search row records the find and the evidence
        assert_eq(#Mock.players[INMATE].PlayerData.items, 1)
        assert_eq(Mock.players[INMATE].PlayerData.items[1].name, 'sandwich')
        local row = Searches[res.searchId]
        assert_eq(row.kind, 'pat')
        assert_eq(row.target, 'INMATECID')
        assert_eq(row.by_cid, 'GUARDCID')
        assert_eq(json.decode(row.found).state, 'evidence')
        assert_eq(row.evidence_ids, tostring(res.evidenceIds[1]))
        assert_eq(infractions[1].cid, 'INMATECID')
        assert_eq(infractions[1].spec.code, 'P-200')
        assert_eq(infractions[1].opts.actor.src, GUARD)
        assert_eq(#eventsOf('search'), 1)
    end)
    it('a failed roll finds nothing and seizes nothing', function()
        jail()
        give(INMATE, { { name = 'phone', amount = 1, slot = 1 } })
        RNG = 0.99
        local res = Sec.Search(GUARD, 'pat', INMATE)
        assert_true(res.ok)
        assert_eq(#res.found, 0)
        assert_eq(res.state, 'clean')
        assert_eq(#calls('SeizeProperty'), 0, 'nothing seized')
        assert_eq(#Mock.players[INMATE].PlayerData.items, 1)
        assert_eq(#infractions, 0)
    end)
    it('only on-duty staff within reach search an inmate, not too often', function()
        jail()
        give(INMATE, { { name = 'phone', amount = 1, slot = 1 } })
        local civ = inmatePlayer(5, 'CIVCID')
        Mock.coords[5] = at(1, 0)
        assert_eq(Sec.Search(5, 'pat', INMATE).error, 'no_permission')
        Mock.players[GUARD].PlayerData.job.onduty = false
        assert_eq(Sec.Search(GUARD, 'pat', INMATE).error, 'not_on_duty')
        Mock.players[GUARD].PlayerData.job.onduty = true
        Mock.coords[GUARD] = at(10, 0)
        assert_eq(Sec.Search(GUARD, 'pat', INMATE).error, 'too_far')
        Mock.coords[GUARD] = at(1, 0)
        Mock.coords[VISITOR] = at(0, 1)
        assert_eq(Sec.Search(GUARD, 'pat', VISITOR).error, 'invalid_state', 'a pat search is for inmates')
        RNG = 0.99
        assert_true(Sec.Search(GUARD, 'pat', INMATE).ok)
        advance(10)
        assert_eq(Sec.Search(GUARD, 'pat', INMATE).error, 'rate_limited')
        assert_eq(civ.PlayerData.citizenid, 'CIVCID')
    end)
    it('fails closed: no seizure export = nothing taken; no forfeiture yet = held in the locker and retried', function()
        jail()
        give(INMATE, { { name = 'phone', amount = 1, slot = 1 } })
        JU.noSeize = true
        installJustice()
        local res = Sec.Search(GUARD, 'pat', INMATE)
        assert_eq(res.state, 'not_seized')
        assert_eq(Mock.players[INMATE].PlayerData.items[1].name, 'phone', 'the item stays with the inmate')
        assert_eq(#infractions, 0)
        JU.noSeize, JU.noForfeit = false, true
        installJustice()
        advance(120)
        res = Sec.Search(GUARD, 'pat', INMATE)
        assert_eq(res.state, 'forfeit_pending')
        assert_eq(#Mock.players[INMATE].PlayerData.items, 0, 'taken into the pf-justice locker')
        assert_true(Sec.pending[res.searchId] ~= nil)
        JU.noForfeit = false
        installJustice()
        Sec.Tick(Mock.clock + 61)
        assert_eq(Sec.pending[res.searchId], nil)
        assert_eq(json.decode(Searches[res.searchId].found).state, 'evidence')
        assert_true(Searches[res.searchId].evidence_ids ~= nil)
    end)
    it('a pending forfeiture survives a restart (read back from the search rows)', function()
        jail()
        give(INMATE, { { name = 'phone', amount = 1, slot = 1 } })
        JU.noForfeit = true
        installJustice()
        local res = Sec.Search(GUARD, 'pat', INMATE)
        Sec.pending = {}
        Sec.LoadPending()
        assert_eq(Sec.pending[res.searchId].receiptId, res.receiptId)
    end)
end)

describe('visitor and cell searches', function()
    it('visitors are searched at the visitor entry; the visit is marked searched', function()
        give(VISITOR, { { name = 'weapon_pistol', amount = 1, slot = 3 } })
        Mock.coords[VISITOR], Mock.coords[GUARD] = at(0, 0), at(1, 0)
        assert_eq(Sec.Search(GUARD, 'visitor', VISITOR).error, 'too_far')
        Mock.coords[VISITOR], Mock.coords[GUARD] = GATEHOUSE, GATEHOUSE + vector3(1, 0, 0)
        local res = Sec.Search(GUARD, 'visitor', VISITOR)
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.state, 'evidence')
        assert_eq(#VisitUpdates, 1)
        assert_eq(VisitUpdates[1][1], 'VISITORCID')
    end)
    it('a cell locker find becomes evidence straight away (key pfm-prison:contraband:<id>:<n>)', function()
        local stash = Sec.CellStash('A101')
        stashes[stash] = { { name = 'weed_skunk', amount = 3, slot = 1 }, { name = 'sandwich', amount = 1, slot = 2 } }
        Mock.coords[GUARD] = at(50, 50)
        assert_eq(Sec.Search(GUARD, 'cell').error, 'too_far')
        Mock.coords[GUARD] = CELL
        local res = Sec.Search(GUARD, 'cell')
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.state, 'evidence')
        local e = evidence.list[1]
        assert_eq(e.opts.key, ('pfm-prison:contraband:%d:1'):format(res.searchId))
        assert_eq(e.opts.giveTo, 'stash:pfprison_evidence_bolingbroke')
        assert_eq(e.spec.kind, 'drug')
        assert_eq(e.spec.method, 'prison_search')
        assert_eq(e.spec.origin.id, 'A101')
        assert_eq(#stashes[stash], 1)
        assert_eq(stashes[stash][1].name, 'sandwich')
        assert_eq(Searches[res.searchId].target, 'cell:A101')
    end)
    it('a cell item whose evidence cannot be made goes back into the locker', function()
        local stash = Sec.CellStash('A101')
        stashes[stash] = { { name = 'phone', amount = 1, slot = 1 } }
        evidence.fail = true
        Mock.coords[GUARD] = CELL
        local res = Sec.Search(GUARD, 'cell')
        assert_eq(res.state, 'not_seized')
        assert_eq(#stashes[stash], 1)
        assert_eq(stashes[stash][1].name, 'phone')
    end)
    it('an inmate opens only the locker of their own cell, standing at it', function()
        jail()
        B.rows.INMATECID.cell_id = 'A101'
        Mock.coords[INMATE] = at(0, 0)
        assert_eq(Sec.OpenCellLocker(INMATE).error, 'too_far')
        Mock.coords[INMATE] = CELL
        assert_true(Sec.OpenCellLocker(INMATE).ok)
        assert_eq(opened[1].id, Sec.CellStash('A101'))
        assert_eq(Sec.OpenCellLocker(VISITOR).error, 'no_permission')
    end)
end)

describe('escapes and recapture', function()
    local function sampleAt(pos, s)
        Mock.coords[INMATE] = pos
        advance(s or 2)
        PFPrison.SampleTick()
    end
    local function beyondGate(m)
        local dx, dy = GATE.x - MIDDLE.x, GATE.y - MIDDLE.y
        local len = math.sqrt(dx * dx + dy * dy)
        return vector3(GATE.x + dx / len * m, GATE.y + dy / len * m, GATE.z)
    end
    local function escape()
        jail()
        advance(30)
        Mock.coords[INMATE] = GATE
        Mock.fireNet('prison:server:StartGateHack', INMATE, 1)
        local start = events('prison:client:GateHackStart', INMATE)[1]
        advance(6)
        Mock.fireNet('prison:server:GateHackResult', INMATE, start.args[2], true)
        sampleAt(GATE)
        sampleAt(beyondGate(20))
        sampleAt(beyondGate(60))
    end
    it('is recorded with its gate, raises the classification, alerts staff and asks for a warrant', function()
        escape()
        assert_eq(#Escapes, 1)
        assert_eq(Escapes[1].citizenid, 'INMATECID')
        assert_eq(Escapes[1].order_id, 1)
        assert_eq(Escapes[1].method, 'gate_hack')
        assert_eq(Escapes[1].gate, '1')
        assert_eq(B.rows.INMATECID.classification, 'max')
        assert_eq(Rows.INMATECID.classification, 'max', 'stored')
        local w = warrants.list[1]
        assert_eq(w.spec.type, 'arrest')
        assert_eq(w.spec.suspectCitizenId, 'INMATECID')
        assert_eq(w.opts.key, 'pfm-prison:escape:1:warrant')
        assert_eq(Escapes[1].warrant_id, 'W2611170001')
        assert_true(#events('prison:client:SecurityAlert', GUARD) >= 1)
        assert_true(#events('prison:client:SecurityAlert', COP) >= 1, 'police hear of an escape')
        -- batch-16 behaviour kept: only the suspension, no property moved
        local a = calls('AdjustOrder')
        assert_eq(#a, 1)
        assert_eq(a[1].args.change.kind, 'suspend')
        assert_eq(#calls('ReturnProperty'), 0)
    end)
    it('without the MDT export no warrant is invented; it is asked again later', function()
        warrants.missing = true
        installMdt()
        escape()
        assert_eq(Escapes[1].warrant_id, nil)
        assert_true(#eventsOf('anomaly') >= 1)
        warrants.missing = false
        installMdt()
        Sec.Tick(Mock.clock + 10)
        assert_eq(#warrants.list, 0, 'not before WarrantRetrySeconds')
        Mock.clock = Mock.clock + 130
        Sec.Tick()
        assert_eq(Escapes[1].warrant_id, 'W2611170001')
    end)
    it('a recapture closes the escape and forfeits credits with a stable key', function()
        escape()
        JU.orders[1].creditSeconds = 600
        local escapedAt = B.rows.INMATECID.status_at
        sampleAt(at(0, 0), 60)
        B.Pump()
        assert_eq(JU.orders[1].state, 'active')
        assert_eq(B.rows.INMATECID.status, 'in_cell')
        local a = calls('AdjustOrder')
        local last = a[#a].args
        assert_eq(last.change.kind, 'forfeit')
        assert_eq(last.change.seconds, 3600)
        assert_eq(last.opts.key, ('pfm-prison:escape:1:%d:forfeit'):format(escapedAt))
        assert_eq(JU.orders[1].forfeitSeconds, 600, 'pf-justice caps it at the credits')
        assert_true(Escapes[1].recaptured_at ~= nil)
        assert_eq(B.rows.INMATECID.classification, 'max', 'kept after the recapture')
        assert_eq(#eventsOf('recapture') >= 2, true)
    end)
    it('a busy pf-justice gets the same forfeit key again', function()
        escape()
        sampleAt(at(0, 0), 60)
        B.Pump()
        local a = calls('AdjustOrder')
        local key = a[#a].args.opts.key
        JU.busyAdjust = true
        -- run the forfeit once more as if the first had been refused
        Sec.forfeits[key] = { cid = 'INMATECID', orderId = 1, seconds = 3600, attempts = 0 }
        Sec.Tick()
        JU.busyAdjust = false
        Sec.Tick()
        a = calls('AdjustOrder')
        assert_eq(a[#a].args.opts.key, key)
        assert_eq(Sec.forfeits[key], nil)
    end)
    it('open escapes are read back at start', function()
        escape()
        Sec.escapes = {}
        Sec.LoadEscapes()
        assert_eq(Sec.escapes.INMATECID.id, 1)
        assert_eq(Sec.escapes.INMATECID.warrantId, 'W2611170001')
    end)
end)

describe('lockdown, doors, cameras, alarms', function()
    it('a facility lockdown stops gate hacks (main.lua reads it)', function()
        jail()
        advance(30)
        PFPrison.Facility = { lockdown = { on = true, untilAt = Mock.clock + 600 } }
        Mock.coords[INMATE] = GATE
        Mock.fireNet('prison:server:StartGateHack', INMATE, 1)
        assert_eq(#events('prison:client:GateHackStart', INMATE), 0)
        PFPrison.Facility.lockdown.untilAt = Mock.clock - 1
        Mock.fireNet('prison:server:StartGateHack', INMATE, 1)
        assert_eq(#events('prison:client:GateHackStart', INMATE), 1)
    end)
    it('a lockdown goes through the facility, then relocks hacked gates and every security door', function()
        assert_eq(Sec.SetLockdown(true, { actor = { src = GUARD } }).error, 'unavailable')
        local applied = {}
        PFPrison.Facility = {
            lockdown = { on = false },
            StaffLockdown = function(src, on) applied[#applied + 1] = { src = src, on = on } PFPrison.Facility.lockdown.on = on return { ok = true, lockdown = on } end,
            ApplyLockdown = function(on) applied[#applied + 1] = { on = on } return { ok = true, lockdown = on } end,
        }
        PFPrison.Internal.gateOpen[2] = { at = Mock.clock, by = INMATE }
        local res = Sec.SetLockdown(true, { actor = { src = GUARD }, reason = 'riot' })
        assert_true(res.ok)
        assert_eq(applied[1].src, GUARD)
        assert_eq(PFPrison.Internal.gateOpen[2], nil, 'the hacked gate relocked')
        assert_eq(res.doorsLocked, 3)
        local locked = 0
        for _, d in ipairs(doors) do if d.locked then locked = locked + 1 end end
        assert_true(locked >= 3)
        assert_eq(Sec.SetLockdown(true, { actor = { src = INMATE } }).error, 'no_permission')
    end)
    it('doors: control grade at a control point; no door opens in a lockdown', function()
        Mock.coords[GUARD] = at(0, 0)
        assert_eq(Sec.SetDoor(1, false, { actor = { src = GUARD } }).error, 'too_far')
        Mock.coords[GUARD] = GATEHOUSE
        local res = Sec.SetDoor(1, false, { actor = { src = GUARD } })
        assert_true(res.ok)
        assert_eq(doors[#doors].id, 'bolingbroke_gate_1')
        assert_eq(doors[#doors].locked, false)
        Mock.coords[COP] = GATEHOUSE
        assert_eq(Sec.SetDoor(1, true, { actor = { src = COP } }).error, 'no_permission', 'police grade 0 has no control')
        PFPrison.Facility = { lockdown = { on = true } }
        assert_eq(Sec.SetDoor(2, false, { actor = { src = GUARD } }).error, 'invalid_state')
        assert_true(Sec.SetDoor(2, true, { actor = { src = GUARD } }).ok)
        assert_eq(#eventsOf('door'), 2)
    end)
    it('cameras: staff at a control point get the camera point; views are audited', function()
        Mock.coords[GUARD] = at(0, 0)
        assert_eq(Sec.ViewCamera(GUARD, 1).error, 'too_far')
        Mock.coords[GUARD] = GATEHOUSE
        assert_true(Sec.ViewCamera(GUARD, 2).ok)
        local e = events('prison:client:ViewCamera', GUARD)[1].args[1]
        assert_eq(e.id, 'gate_inner')
        assert_eq(e.index, 2)
        assert_eq(e.count, #Config.Security.Cameras)
        assert_true(e.coords.x ~= nil and e.lookAt.x ~= nil)
        Sec.ViewCamera(GUARD, 2)
        assert_eq(#eventsOf('camera'), 1, 'one audit row per minute')
        Mock.coords[INMATE] = GATEHOUSE
        assert_eq(Sec.ViewCamera(INMATE, 1).error, 'no_permission')
        assert_eq(Mock.selfExport('ListCameras')().cameras[1].id, 'gate_front')
    end)
    it('an inmate in a restricted zone raises one alarm per cooldown to on-duty corrections', function()
        jail()
        advance(30)
        Mock.coords[INMATE] = at(0, 0)
        PFPrison.SampleTick()
        Mock.coords[INMATE] = GATEHOUSE
        advance(2)
        -- a walk, not a teleport: step there across samples
        local from = at(0, 0)
        for i = 1, 10 do
            Mock.coords[INMATE] = vector3(from.x + (GATEHOUSE.x - from.x) * i / 10, from.y + (GATEHOUSE.y - from.y) * i / 10, GATEHOUSE.z)
            advance(2)
            PFPrison.SampleTick()
        end
        advance(2)
        PFPrison.SampleTick()
        local alerts = events('prison:client:SecurityAlert', GUARD)
        assert_eq(#alerts, 1)
        assert_eq(alerts[1].args[1].kind, 'zone')
        assert_eq(#events('prison:client:SecurityAlert', COP), 0, 'a zone alarm is for corrections')
        assert_eq(#Sec.alarms, 1)
        Mock.coords[GUARD] = GATEHOUSE
        assert_true(Sec.ClearAlarm(Sec.alarms[1].id, { actor = { src = GUARD } }).ok)
        assert_eq(#Sec.alarms, 0)
    end)
    it('GetSecurityStatus reads doors, alarms and open escapes', function()
        local st = Mock.selfExport('GetSecurityStatus')()
        assert_true(st.ok)
        assert_eq(#st.doors, 3)
        assert_eq(st.lockdown, false)
    end)
end)

describe('follow-up: hospital transfer, warrant recall, the old work event', function()
    local function sampleAt(pos, s)
        Mock.coords[INMATE] = pos
        advance(s or 2)
        PFPrison.SampleTick()
    end
    local PILLBOX = vector3(298.0, -584.0, 43.0)
    it('an inmate on an escorted hospital transfer is neither sent back nor an escape', function()
        jail()
        advance(30)
        sampleAt(at(0, 0))
        care[INMATE] = 'transfer'
        sampleAt(PILLBOX, 120)
        sampleAt(PILLBOX, 60)
        assert_eq(#events('prison:client:Enter', INMATE), 1, 'not taken back to a cell')
        assert_eq(#events('prison:client:Escaped', INMATE), 0)
        assert_eq(#eventsOf('sendback'), 0)
        -- the prison infirmary is inside the walls; outside it, it is no transfer: back to a cell
        care[INMATE] = 'infirmary'
        sampleAt(PILLBOX, 60)
        assert_eq(#events('prison:client:Enter', INMATE), 2)
        -- without pf-ambulancejob the old rules apply
        care[INMATE] = 'transfer'
        local saved = Mock.exportsByResource['pf-ambulancejob']
        Mock.exportsByResource['pf-ambulancejob'] = nil
        sampleAt(PILLBOX, 60)
        Mock.exportsByResource['pf-ambulancejob'] = saved
        assert_eq(#events('prison:client:Enter', INMATE), 3)
    end)
    local function escape()
        jail()
        advance(30)
        Mock.coords[INMATE] = GATE
        Mock.fireNet('prison:server:StartGateHack', INMATE, 1)
        local start = events('prison:client:GateHackStart', INMATE)[1]
        advance(6)
        Mock.fireNet('prison:server:GateHackResult', INMATE, start.args[2], true)
        local dx, dy = GATE.x - MIDDLE.x, GATE.y - MIDDLE.y
        local len = math.sqrt(dx * dx + dy * dy)
        sampleAt(GATE)
        sampleAt(vector3(GATE.x + dx / len * 20, GATE.y + dy / len * 20, GATE.z))
        sampleAt(vector3(GATE.x + dx / len * 60, GATE.y + dy / len * 60, GATE.z))
    end
    it('the stored escape warrant is recalled at the recapture (keyed; busy retried; invalid_state is done)', function()
        escape()
        assert_eq(Escapes[1].warrant_id, 'W2611170001')
        warrants.recallError = 'busy'
        sampleAt(at(0, 0), 60)
        B.Pump()
        assert_eq(#warrants.recalls, 1)
        assert_eq(warrants.recalls[1].id, 'W2611170001')
        assert_eq(warrants.recalls[1].opts.key, 'pfm-prison:escape:1:recall')
        warrants.recallError = 'invalid_state'
        Sec.Tick()
        assert_eq(#warrants.recalls, 2)
        assert_eq(warrants.recalls[2].opts.key, 'pfm-prison:escape:1:recall')
        assert_eq(next(Sec.recalls), nil, 'invalid_state counts as done')
        Sec.Tick()
        assert_eq(#warrants.recalls, 2)
    end)
    it('a recall still due at a restart is asked again once after the boot, with the same key, then done', function()
        escape()
        warrants.recallError = 'busy'
        sampleAt(at(0, 0), 60)
        B.Pump()
        assert_eq(#warrants.recalls, 1)
        local due = eventsOf('warrant_recall')
        assert_eq(#due, 1)
        assert_eq(json.decode(due[1].detail).key, 'pfm-prison:escape:1:recall')
        assert_eq(json.decode(due[1].detail).warrantId, 'W2611170001')
        -- restart: memory is gone
        Sec.recalls, Sec.escapes = {}, {}
        warrants.recallError = nil
        assert_true(Sec.Boot())
        assert_eq(Sec.recalls['pfm-prison:escape:1:recall'].warrantId, 'W2611170001')
        Sec.Tick()
        assert_eq(#warrants.recalls, 2)
        assert_eq(warrants.recalls[2].id, 'W2611170001')
        assert_eq(warrants.recalls[2].opts.key, 'pfm-prison:escape:1:recall')
        assert_eq(#eventsOf('warrant_recalled'), 1)
        -- done: neither the queue nor a later reload asks again
        Sec.Tick()
        assert_eq(Sec.LoadRecalls(), 0)
        Sec.Boot()
        Sec.Tick()
        assert_eq(#warrants.recalls, 2)
    end)
    it('a clear refusal of the warrant request is not asked again', function()
        warrants.requestError = 'suspect_required'
        escape()
        assert_eq(#warrants.list, 1)
        Mock.clock = Mock.clock + 1000
        Sec.Tick()
        assert_eq(#warrants.list, 1)
        assert_eq(Escapes[1].warrant_id, nil)
    end)
    it('the old JobDone event gives a pf-justice inmate no random credit while the work module runs', function()
        jail()
        local job = PFPrison.Internal.jobs[INMATE]
        local spot = Config.Locations.jobs[job.name][job.location].coords
        local forwarded = {}
        PFPrison.Work = { Electrician = function(src, loc) forwarded[#forwarded + 1] = { src = src, loc = loc } return nil end }
        advance(30)
        Mock.coords[INMATE] = vector3(spot.x, spot.y, spot.z)
        PFPrison.SampleTick()
        advance(200)
        PFPrison.SampleTick()
        Mock.fireNet('prison:server:JobDone', INMATE, job.location)
        assert_eq(#forwarded, 1)
        assert_eq(forwarded[1].loc, job.location)
        for _, c in ipairs(calls('AdjustOrder')) do assert_true(c.args.change.kind ~= 'credit', 'no credit from the old event') end
    end)
end)
