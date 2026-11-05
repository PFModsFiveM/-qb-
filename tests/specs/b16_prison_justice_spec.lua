-- pfm-prison driven by pf-justice (batch 16C). pf-justice is stubbed by its contract (exports and
-- server events as PF_ARCHITECTURE 4.7 / section 12.2 describe them); its own clock is covered by
-- b15_justice_clock_spec. Both values of pf-justice Config.Compat.LegacyRuntimes.prison are run:
--   * handed over (prison = false): JailPlayer/ReleasePlayer/GetJailTime forward to pf-justice; an
--     order made anywhere (MDT, field, the forwarder) takes an online player in (property into the
--     pf-justice locker, job kept and off duty, jail money once); IsInside answers the clock; the
--     release comes once from pf-justice (also an offline completion at the next login); work is a
--     keyed AdjustOrder credit; an escape suspends the order through AdjustOrder (never
--     SetOrderState) and forfeits nothing; a recapture resumes; the old jailitems restore at login
--     is off (no item comes back twice); a teleport between job spots earns nothing;
--   * old runtime (prison = true): JailPlayer still jails in metadata, imported shadows are left to
--     it, and an order pf-justice made itself is still taken in.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
vec2 = vector2
local DIR = B16_PRISON_DIR or 'pfm-prison'

-- pf-justice's config file as LoadResourceFile returns it
local justiceConfigText
function LoadResourceFile(res, file)
    if res == 'pf-justice' and file == 'config.lua' then return justiceConfigText end
    return nil
end
local function flags(prison, mdt)
    justiceConfigText = ('Config = Config or {}\nConfig.Compat = { LegacyRuntimes = { mdt = %s, prison = %s, policejob = false } }\nConfig.Pos = vector3(1, 2, 3)\n')
        :format(tostring(mdt ~= false), tostring(prison))
end

-- ── pf-justice stand-in (contract only) ────────────────────────────────────────────────────────
local JU = {}
local function resetJU() JU.orders, JU.n, JU.calls, JU.receipts, JU.busyAdjust = {}, 0, {}, 0, false end
resetJU()
local function call(name, args) JU.calls[#JU.calls + 1] = { name = name, args = args } end
local function calls(name)
    local out = {}
    for _, c in ipairs(JU.calls) do if c.name == name then out[#out + 1] = c end end
    return out
end
local function copy(o) local t = {} for k, v in pairs(o) do t[k] = v end return t end
local function cidOf(who)
    if type(who) == 'number' then return Mock.players[who] and Mock.players[who].PlayerData.citizenid end
    return who
end
local function remaining(o) return math.max(0, o.requiredSeconds - o.servedSeconds - o.creditSeconds) end
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
    local o = { id = JU.n, cid = cid, kind = spec.kind or 'prison', state = spec.state or 'active', facility = spec.facility or 'bolingbroke',
        requiredSeconds = (spec.minutes or 30) * 60, servedSeconds = 0, creditSeconds = 0, createdAt = Mock.clock,
        legacyRef = spec.legacyRef, parentOrderId = spec.parentOrderId }
    JU.orders[#JU.orders + 1] = o
    return o
end
-- an order reaches its end inside pf-justice (served, vacated): the release event follows once
function JU.finish(o, to)
    o.state = to or 'completed'
    emit('orderChanged', copy(o), { action = 'state', to = o.state })
    if #openOf(o.cid) == 0 then emit('releaseOrdered', o.cid, o.id, o.state) end
end
Mock.exportsByResource['pf-justice'] = {
    GetOrders = function(_, cid, filter)
        call('GetOrders', { cid })
        local list = {}
        for i = #JU.orders, 1, -1 do
            local o = JU.orders[i]
            if o.cid == cid then list[#list + 1] = copy(o) end
        end
        return { ok = true, list = list }
    end,
    GetJailMinutes = function(_, who)
        local cid = cidOf(who)
        for _, o in ipairs(openOf(cid)) do if o.state == 'active' then return math.ceil(remaining(o) / 60) end end
        return 0
    end,
    CreateOrder = function(_, spec, opts)
        call('CreateOrder', { spec = spec, opts = opts })
        local parent
        for _, o in ipairs(openOf(spec.cid)) do parent = parent or o.id end
        local o = JU.add(spec.cid, { kind = spec.kind, minutes = spec.minutes, facility = spec.facility,
            state = parent and 'pending' or 'active', parentOrderId = parent })
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
        elseif change.kind == 'credit' then
            o.creditSeconds = o.creditSeconds + change.seconds
        end
        emit('orderChanged', copy(o), change)
        return { ok = true, order = copy(o), applied = change.seconds }
    end,
    SetOrderState = function(_, id, to, opts)
        call('SetOrderState', { id = id, to = to })
        local o = JU.orders[id]
        o.state = to
        emit('orderChanged', copy(o), { action = 'state', to = to })
        return { ok = true, order = copy(o) }
    end,
    ReleaseNow = function(_, who, reason, opts)
        call('ReleaseNow', { who = who, reason = reason })
        local cid = cidOf(who)
        local n, last = 0, nil
        for _, o in ipairs(openOf(cid)) do o.state = 'vacated' n = n + 1 last = o.id end
        if n > 0 then emit('releaseOrdered', cid, last, reason) end
        return { ok = true, released = n }
    end,
    SeizeProperty = function(_, src, opts)
        call('SeizeProperty', { src = src, opts = opts })
        for _, c in ipairs(calls('SeizeProperty')) do
            if c ~= JU.calls[#JU.calls] and c.args.opts.key == opts.key then return { ok = true, duplicate = true, receiptId = c.receipt } end
        end
        JU.receipts = JU.receipts + 1
        JU.calls[#JU.calls].receipt = JU.receipts
        Mock.players[src].PlayerData.items = {}
        return { ok = true, receiptId = JU.receipts, items = 1 }
    end,
    ReturnProperty = function(_, id, opts)
        call('ReturnProperty', { id = id, opts = opts })
        return { ok = true, returned = 1 }
    end,
}

local inv = { adds = {}, has = {} }
Mock.exportsByResource['pfm-inventory'] = {
    ClearInventory = function(_, src) Mock.players[src].PlayerData.items = {} end,
    AddItem = function(_, src, name, amount) inv.adds[#inv.adds + 1] = { src = src, name = name, amount = amount } return true end,
    RemoveItem = function() return true end,
    HasItem = function(_, src, name) return inv.has[name] == true end,
}
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function() return { id = 'ch1', kind = 'hacking', puzzle = {} } end,
    Verify = function() return true end,
    Cancel = function() end,
}
local doors = {}
Mock.exportsByResource['pfm-doorlock'] = {
    SetDoorState = function(_, id, locked, opts) doors[#doors + 1] = { id = id, locked = locked } return { ok = true, doorId = 13, locked = locked, changed = true } end,
}
local Emits = {}
Mock.exportsByResource['pf-services'] = { Emit = function(_, kind, data) Emits[#Emits + 1] = { kind = kind, data = data } return #Emits end }
function SetEntityCoords() end

-- pf_prison_* statements on the fake database
local Rows, Events = {}, {}
FakeDB.extraPatterns = {
    { 'INSERT INTO pf_prison_inmates', function(p)
        Rows[p[1]] = { citizenid = p[1], order_id = p[2], facility = p[3], status = p[4], cell_id = p[5], classification = p[6],
            admitted_at = p[7], status_at = p[8], job_ticket = p[9], receipt_ids = p[10] }
        return 1
    end },
    { 'DELETE FROM pf_prison_inmates', function(p) Rows[p[1]] = nil return 1 end },
    { 'SELECT * FROM pf_prison_inmates', function() local out = {} for _, r in pairs(Rows) do out[#out + 1] = copy(r) end return out end },
    { 'INSERT INTO pf_prison_events', function(p) Events[#Events + 1] = { cid = p[1], kind = p[3], detail = p[4] } return #Events end },
    { 'pf_prison_events', function() return 0 end },
}
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

flags(false)
LedgerEnv.load('pfm-prison', { DIR .. '/config.lua', DIR .. '/server/main.lua', DIR .. '/server/schema.lua', DIR .. '/server/justice_bridge.lua' })
local B = PFPrison.Bridge

local INMATE, OTHER, COP = 1, 2, 3
local MIDDLE = Config.Locations['middle']
local function at(dx, dy) return vector3(MIDDLE.x + dx, MIDDLE.y + dy, MIDDLE.z) end
local GATE = Config.Gates[1].coords
local function meta(src) return Mock.players[src].PlayerData.metadata end
local function events(name, target)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if target == nil or e.target == target then out[#out + 1] = e end end
    return out
end
local function advance(s) Mock.clock = Mock.clock + s end
local function as(res, fn, ...)
    Mock.invokingResource = res
    local a, b = Mock.selfExport(fn)(...)
    Mock.invokingResource = nil
    return a, b
end
local function eventsOf(kind)
    local out = {}
    for _, e in ipairs(Events) do if e.kind == kind then out[#out + 1] = e end end
    return out
end
local function newPlayer(src, cid)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.charinfo = { firstname = 'John', lastname = 'Doe' .. src }
    p.PlayerData.job = { name = 'mechanic', onduty = true }
    p.SetJobDuty = function(on) p.PlayerData.job.onduty = on end
    p.Functions.SetJobDuty = p.SetJobDuty
    p.SetJob = function(name) p.PlayerData.job = { name = name } end
    p.Functions.SetJob = p.SetJob
    p.PlayerData.items = { { name = 'weapon_pistol', amount = 1, slot = 1 }, { name = 'goldbar', amount = 2, slot = 2 } }
    p.PlayerData.metadata.injail = 0
    return p
end
local function login(src)
    Mock.eventHandlers['QBCore:Server:PlayerLoaded'](Mock.pack(Mock.players[src]))
    advance(5)
    B.Pump()
end

local function boot(prison, mdt)
    flags(prison, mdt)
    B.ResetMode()
    B.Boot()
end

BeforeEach = function()
    PFPrison.EndAlarm()
    for _, src in ipairs({ 1, 2, 3 }) do if Mock.players[src] then Mock.fireEvent('playerDropped', src) end end
    Mock.reset()
    LedgerEnv.reset()
    FakeDB.extraPatterns = FakeDB.extraPatterns
    advance(5000)
    Mock.players, Mock.coords = {}, {}
    resetJU()
    inv.adds, inv.has = {}, { gatecrack = true, electronickit = true }
    doors, Emits, Events = {}, {}, {}
    for k in pairs(Rows) do Rows[k] = nil end
    for k in pairs(B.rows) do B.rows[k] = nil end
    B.queue, B.actions, B.credits, B.pending, B.escapees, B.needSeize, B.loadAt = {}, {}, {}, {}, {}, {}, {}
    newPlayer(INMATE, 'INMATECID')
    newPlayer(OTHER, 'OTHERCID')
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.coords[INMATE], Mock.coords[OTHER], Mock.coords[COP] = at(0, 0), at(5, 0), vector3(0, 0, 0)
    boot(false)
end

describe('which runtime owns the sentences', function()
    it('follows pf-justice Config.Compat.LegacyRuntimes.prison; unreadable means the old runtime', function()
        boot(false)
        assert_false(PFPrison.LegacyRuntime())
        boot(true)
        assert_true(PFPrison.LegacyRuntime())
        justiceConfigText = nil
        B.ResetMode()
        assert_true(PFPrison.LegacyRuntime())
        justiceConfigText = 'Config.Compat = { LegacyRuntimes = { prison = false } } error("x")'
        B.ResetMode()
        assert_true(PFPrison.LegacyRuntime(), 'a config that does not run is not read as handed over')
    end)
    it('Config.Justice.Runtime forces it either way', function()
        Config.Justice.Runtime = 'justice'
        boot(true)
        assert_false(PFPrison.LegacyRuntime())
        Config.Justice.Runtime = 'legacy'
        boot(false)
        assert_true(PFPrison.LegacyRuntime())
        Config.Justice.Runtime = 'auto'
    end)
end)

describe('handed over: an order puts an online player in the prison', function()
    it('JailPlayer forwards to CreateOrder and the intake follows from the order (property, job, money, cell)', function()
        local ok = as('pfm-policejob', 'JailPlayer', INMATE, 30, { officer = COP })
        assert_true(ok)
        local c = calls('CreateOrder')
        assert_eq(#c, 1)
        assert_eq(c[1].args.spec.kind, 'prison')
        assert_eq(c[1].args.spec.facility, 'bolingbroke')
        assert_eq(c[1].args.spec.minutes, 30)
        assert_eq(c[1].args.spec.sourceRef.type, 'field')
        assert_eq(c[1].args.opts.actor.src, COP)
        assert_true(c[1].args.opts.key:find('^pfm%-prison:jail:INMATECID:') ~= nil)
        B.Pump()
        local s = calls('SeizeProperty')
        assert_eq(#s, 1)
        assert_eq(s[1].args.opts.key, 'pfm-prison:intake:1')
        assert_eq(s[1].args.opts.items, 'all')
        assert_eq(next(Mock.players[INMATE].PlayerData.items), nil)
        -- the old runtime writes nothing: injail is pf-justice's mirror, the items are in its locker
        assert_eq(meta(INMATE).injail, 0)
        assert_eq(meta(INMATE).jailitems, nil)
        assert_eq(Mock.players[INMATE].PlayerData.job.name, 'mechanic')
        assert_eq(Mock.players[INMATE].PlayerData.job.onduty, false)
        assert_eq(Mock.players[INMATE].PlayerData.money.cash, 80)
        local enter = events('prison:client:Enter', INMATE)
        assert_eq(#enter, 1)
        assert_eq(enter[1].args[1], 30)
        assert_eq(enter[1].args[5], true)
        assert_eq(B.rows.INMATECID.status, 'in_cell')
        assert_eq(Rows.INMATECID.order_id, 1)
        assert_eq(#eventsOf('intake'), 1)
        -- more events about the same order take nobody in twice and pay nothing twice
        Mock.eventHandlers['pf-justice:server:orderChanged'](copy(JU.orders[1]))
        B.Pump()
        assert_eq(#calls('SeizeProperty'), 1)
        assert_eq(#events('prison:client:Enter', INMATE), 1)
        assert_eq(Mock.players[INMATE].PlayerData.money.cash, 80)
    end)
    it('an order made elsewhere (the MDT) takes the player in from the pf-justice event', function()
        local o = JU.add('INMATECID', { kind = 'jail', minutes = 20 })
        Mock.eventHandlers['pf-justice:server:orderCreated'](copy(o))
        B.Pump()
        assert_eq(#events('prison:client:Enter', INMATE), 1)
        assert_eq(B.rows.INMATECID.order_id, o.id)
    end)
    it('a forged event without an order at pf-justice takes nobody in', function()
        Mock.eventHandlers['pf-justice:server:orderCreated']({ id = 99, cid = 'INMATECID', kind = 'prison', state = 'active', facility = 'bolingbroke' })
        B.Pump()
        assert_eq(#events('prison:client:Enter', INMATE), 0)
        assert_eq(#calls('SeizeProperty'), 0)
    end)
    it('an order at a station holding cell is not this prison\'s', function()
        local o = JU.add('INMATECID', { kind = 'jail', facility = 'mrpd_holding' })
        Mock.eventHandlers['pf-justice:server:orderCreated'](copy(o))
        B.Pump()
        assert_eq(#events('prison:client:Enter', INMATE), 0)
    end)
    it('only allowlisted resources may jail; pf-policemdt-DEV and pf-justice now may', function()
        local ok, err = as('some-resource', 'JailPlayer', INMATE, 10)
        assert_false(ok)
        assert_eq(err, 'not_allowed')
        assert_true(as('pf-policemdt-DEV', 'JailPlayer', INMATE, 10))
        assert_eq(calls('CreateOrder')[1].args.spec.sourceRef.type, 'mdt_sentence')
        assert_true(as('pf-justice', 'JailPlayer', OTHER, 10))
    end)
    it('GetJailTime and ReleasePlayer forward to GetJailMinutes and ReleaseNow', function()
        as('pfm-policejob', 'JailPlayer', INMATE, 30)
        B.Pump()
        JU.orders[1].servedSeconds = 610
        assert_eq(Mock.selfExport('GetJailTime')(INMATE), 20)
        assert_true(as('pfm-policejob', 'ReleasePlayer', INMATE, 'unjail'))
        assert_eq(#calls('ReleaseNow'), 1)
        local ok, err = as('pfm-policejob', 'ReleasePlayer', INMATE, 'unjail')
        assert_false(ok)
        assert_eq(err, 'not_jailed')
    end)
end)

describe('handed over: the clock counts only inside (IsInside)', function()
    it('is the server position against the walls; an escapee is never inside', function()
        as('pfm-policejob', 'JailPlayer', INMATE, 30)
        B.Pump()
        local IsInside = Mock.selfExport('IsInside')
        assert_true(IsInside(INMATE))
        Mock.coords[INMATE] = at(400, 0)
        assert_false(IsInside(INMATE))
        assert_false(IsInside(77))
        Mock.coords[INMATE] = at(0, 0)
        B.rows.INMATECID.status = 'escaped'
        assert_false(IsInside(INMATE))
    end)
end)

describe('handed over: the release comes once from pf-justice', function()
    it('releaseOrdered lets the inmate out once and returns the locker', function()
        as('pfm-policejob', 'JailPlayer', INMATE, 30)
        B.Pump()
        JU.finish(JU.orders[1], 'completed')
        B.Pump()
        assert_eq(#events('prison:client:Released', INMATE), 1)
        local r = calls('ReturnProperty')
        assert_eq(#r, 1)
        assert_eq(r[1].args.id, 1)
        assert_eq(r[1].args.opts.toSrc, INMATE)
        assert_eq(B.rows.INMATECID, nil)
        assert_eq(Rows.INMATECID, nil)
        Mock.eventHandlers['pf-justice:server:releaseOrdered']('INMATECID', 1, 'completed')
        B.Pump()
        assert_eq(#events('prison:client:Released', INMATE), 1)
        assert_eq(#calls('ReturnProperty'), 1)
        assert_eq(#inv.adds, 0, 'pfm-prison gives no items itself')
    end)
    it('an offline completion finishes at the next login, once', function()
        as('pfm-policejob', 'JailPlayer', INMATE, 30)
        B.Pump()
        local p = Mock.players[INMATE]
        Mock.fireEvent('playerDropped', INMATE)
        Mock.players[INMATE] = nil
        JU.finish(JU.orders[1], 'vacated')
        B.Pump()
        assert_eq(B.rows.INMATECID.status, 'releasing')
        assert_eq(#events('prison:client:Released'), 0)
        Mock.players[INMATE] = p
        login(INMATE)
        assert_eq(#events('prison:client:Released', INMATE), 1)
        assert_eq(B.rows.INMATECID, nil)
        login(INMATE)
        assert_eq(#events('prison:client:Released', INMATE), 1)
    end)
    it('a login while serving puts the inmate back in a cell without a second intake', function()
        as('pfm-policejob', 'JailPlayer', INMATE, 30)
        B.Pump()
        local p = Mock.players[INMATE]
        Mock.fireEvent('playerDropped', INMATE)
        Mock.players[INMATE] = p
        login(INMATE)
        Mock.fireNet('prison:server:RequestState', INMATE, true)
        assert_eq(#calls('SeizeProperty'), 1)
        local enter = events('prison:client:Enter', INMATE)
        assert_eq(#enter, 2)
        assert_eq(Mock.players[INMATE].PlayerData.money.cash, 80)
    end)
    it('a restart keeps who is inside (the row is stored)', function()
        as('pfm-policejob', 'JailPlayer', INMATE, 30)
        B.Pump()
        for k in pairs(B.rows) do B.rows[k] = nil end
        B.LoadRows()
        assert_eq(B.rows.INMATECID.status, 'in_cell')
        assert_eq(B.rows.INMATECID.receipt_ids[1], 1)
    end)
end)

describe('handed over: the old jailitems restore at login is off', function()
    it('stored jailitems are not handed out by pfm-prison (pf-justice moves them into a locker)', function()
        meta(INMATE).jailitems = { { name = 'goldbar', amount = 2 } }
        meta(INMATE).jailid = 'J-1'
        login(INMATE)
        assert_eq(#inv.adds, 0)
        assert_eq(#events('prison:client:Released', INMATE), 0)
        -- the old runtime still does it while it owns sentences
        boot(true)
        login(INMATE)
        assert_true(#inv.adds > 0 or #events('prison:client:Released', INMATE) == 1)
    end)
end)

describe('handed over: escapes (D12) and recapture', function()
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
        as('pfm-policejob', 'JailPlayer', INMATE, 30)
        B.Pump()
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
    it('the gate opens through SetDoorState with its alias', function()
        escape()
        assert_eq(doors[1].id, 'bolingbroke_gate_1')
        assert_eq(doors[1].locked, false)
    end)
    it('an escape suspends the order through AdjustOrder, never SetOrderState, and forfeits nothing', function()
        escape()
        local a = calls('AdjustOrder')
        assert_eq(#a, 1)
        assert_eq(a[1].args.change.kind, 'suspend')
        assert_true(a[1].args.opts.key:find('^pfm%-prison:escape:1:') ~= nil)
        assert_eq(#calls('SetOrderState'), 0)
        assert_eq(JU.orders[1].state, 'suspended')
        assert_eq(#calls('ReturnProperty'), 0, 'the property stays in the locker')
        assert_eq(B.rows.INMATECID.status, 'escaped')
        assert_eq(events('prison:client:Escaped', INMATE)[1].args[1].suspended, true)
        assert_eq(#Emits, 1)
        assert_eq(Emits[1].kind, 'crime.prison.escape')
        assert_false(Mock.selfExport('IsInside')(INMATE))
        B.Pump()
        assert_eq(#events('prison:client:Enter', INMATE), 1, 'not taken back in')
    end)
    it('a busy pf-justice is asked again with the same key', function()
        JU.busyAdjust = true
        escape()
        JU.busyAdjust = false
        B.Pump()
        local a = calls('AdjustOrder')
        assert_eq(#a, 2)
        assert_eq(a[1].args.opts.key, a[2].args.opts.key)
        assert_eq(JU.orders[1].state, 'suspended')
    end)
    it('a noclip over the wall is no escape: back to a cell, the order keeps running', function()
        as('pfm-policejob', 'JailPlayer', INMATE, 30)
        B.Pump()
        advance(30)
        sampleAt(at(10, 0))
        sampleAt(at(800, 0))
        assert_eq(#calls('AdjustOrder'), 0)
        assert_eq(#events('prison:client:Enter', INMATE), 2)
        assert_eq(#eventsOf('sendback'), 1)
    end)
    it('an escapee brought back inside the walls serves on (resume, back in a cell)', function()
        escape()
        sampleAt(at(0, 0), 60)
        B.Pump()
        local a = calls('AdjustOrder')
        assert_eq(a[#a].args.change.kind, 'resume')
        assert_eq(JU.orders[1].state, 'active')
        B.Pump()
        assert_eq(B.rows.INMATECID.status, 'in_cell')
        assert_eq(#events('prison:client:Enter', INMATE), 2)
        assert_eq(#eventsOf('recapture'), 1)
    end)
    it('a new sentence for an escapee resumes the old one', function()
        escape()
        advance(60)
        local o = JU.add('INMATECID', { minutes = 10, state = 'pending', parentOrderId = 1 })
        Mock.eventHandlers['pf-justice:server:orderCreated'](copy(o))
        B.Pump()
        B.Pump()
        assert_eq(JU.orders[1].state, 'active')
        assert_eq(B.rows.INMATECID.status, 'in_cell')
    end)
end)

describe('handed over: prison work is a keyed pf-justice credit', function()
    local function jobOf()
        local e = events('prison:client:Enter', INMATE)
        return e[#e].args[2], e[#e].args[3]
    end
    it('credits the order with pfm-prison:credit:<orderId>:<ticket>, never metadata', function()
        as('pfm-policejob', 'JailPlayer', INMATE, 100)
        B.Pump()
        local job, loc = jobOf()
        local spot = Config.Locations.jobs[job][loc].coords
        local realRandom = math.random
        math.random = function(a, b) if a == 1 and b == 100 then return 1 end return a end
        advance(60)
        Mock.coords[INMATE] = vector3(spot.x, spot.y, spot.z)
        PFPrison.SampleTick()
        advance(4)
        PFPrison.SampleTick()
        Mock.fireNet('prison:server:JobDone', INMATE, loc)
        math.random = realRandom
        local a = calls('AdjustOrder')
        assert_eq(#a, 1)
        assert_eq(a[1].args.change.kind, 'credit')
        assert_eq(a[1].args.change.seconds, 60)
        assert_true(a[1].args.opts.key:find('^pfm%-prison:credit:1:%d+%-%d+$') ~= nil)
        assert_eq(meta(INMATE).injail, 0)
        assert_eq(#eventsOf('credit'), 1)
        local nextJob = events('prison:client:SetJob', INMATE)
        assert_eq(nextJob[#nextJob].args[3], 99)
    end)
    it('a teleport from where the job was given to the spot earns nothing (carry-over c)', function()
        as('pfm-policejob', 'JailPlayer', INMATE, 100)
        B.Pump()
        local job, loc = jobOf()
        local spot = Config.Locations.jobs[job][loc].coords
        advance(60)
        PFPrison.SampleTick()                                    -- seen in the yard
        Mock.coords[INMATE] = vector3(spot.x, spot.y, spot.z)
        advance(1)
        PFPrison.SampleTick()                                    -- at the spot 1 s later: a jump
        advance(4)
        PFPrison.SampleTick()
        Mock.fireNet('prison:server:JobDone', INMATE, loc)
        assert_eq(#calls('AdjustOrder'), 0)
        assert_eq(#eventsOf('anomaly'), 1)
    end)
end)

describe('handed over: transport intake', function()
    it('a pending order starts when the prisoner is brought to the intake point', function()
        local o = JU.add('INMATECID', { state = 'pending' })
        Mock.eventHandlers['pf-justice:server:orderCreated'](copy(o))
        B.Pump()
        assert_eq(#events('prison:client:Enter', INMATE), 0)
        Mock.coords[INMATE] = Config.Justice.Intake.coords
        B.Pump()
        assert_eq(calls('SetOrderState')[1].args.to, 'active')
        B.Pump()
        assert_eq(#events('prison:client:Enter', INMATE), 1)
    end)
end)

describe('facility reads', function()
    it('GetInmate and GetFacilityStatus', function()
        as('pfm-policejob', 'JailPlayer', INMATE, 30)
        B.Pump()
        local res = Mock.selfExport('GetInmate')('INMATECID')
        assert_eq(res.inmate.orderId, 1)
        assert_eq(res.inmate.status, 'in_cell')
        assert_eq(Mock.selfExport('GetInmate')(OTHER).inmate, nil)
        local st = Mock.selfExport('GetFacilityStatus')('bolingbroke')
        assert_eq(st.population, 1)
        assert_eq(st.lockdown, false)
        assert_eq(Mock.selfExport('GetFacilityStatus')('nowhere').error, 'not_found')
    end)
end)

describe('old runtime still owns sentences (LegacyRuntimes.prison = true)', function()
    it('JailPlayer jails in metadata as before and creates no order', function()
        boot(true)
        assert_true(as('pfm-policejob', 'JailPlayer', INMATE, 30))
        assert_eq(#calls('CreateOrder'), 0)
        assert_eq(meta(INMATE).injail, 30)
        assert_eq(#meta(INMATE).jailitems, 2)
        assert_eq(Mock.selfExport('GetJailTime')(INMATE), 30)
    end)
    it('orders imported from the old jail are its shadows; an order pf-justice made itself is taken in', function()
        boot(true)
        local shadow = JU.add('INMATECID', { legacyRef = 'meta_injail:INMATECID:J-1' })
        Mock.eventHandlers['pf-justice:server:legacyImported']('INMATECID')
        B.Pump()
        assert_eq(#events('prison:client:Enter', INMATE), 0)
        local real = JU.add('OTHERCID', { kind = 'jail' })
        Mock.eventHandlers['pf-justice:server:orderCreated'](copy(real))
        B.Pump()
        assert_eq(#events('prison:client:Enter', OTHER), 1)
        -- after the hand-over the shadow is a real order and is taken in at the next look
        boot(false)
        B.Touch('INMATECID')
        B.Pump()
        assert_eq(#events('prison:client:Enter', INMATE), 1)
        assert_eq(shadow.state, 'active')
    end)
    it('an MDT shadow stays the MDT\'s while pf-justice lists the MDT jail as running', function()
        boot(false, true)
        JU.add('INMATECID', { legacyRef = 'mdt_jail:7' })
        B.Touch('INMATECID')
        B.Pump()
        assert_eq(#events('prison:client:Enter', INMATE), 0)
        boot(false, false)
        B.Touch('INMATECID')
        B.Pump()
        assert_eq(#events('prison:client:Enter', INMATE), 1)
    end)
end)
