-- Batch 19 (19E): prison work runs on the server (pfm-prison/server/work.lua).
--   * a shift starts at the work board, only for an inmate held here for a pf-justice order, not in
--     a lockdown, not with the work privilege suspended, not past the day's shifts;
--   * each station counts only in order, at the station (server position), after its minimum time;
--     a teleport or an impossible speed between stations voids the shift; the client names a step,
--     nothing else;
--   * a finished shift: one ticket, a capped pf-justice credit keyed pfm-prison:credit:<o>:<ticket>
--     (a busy pf-justice is asked again with the same key), a wage for the trust;
--   * real output: kitchen portions in the canteen stash serve the routine's meals; laundry linen
--     moves to the hospital linen stash in batches; maintenance is a pf-government work order unit
--     (claimed as 'cs', proved by ReportWorkUnit) and is not offered while pf-government refuses;
--   * the electrician round keeps main.lua's spot checks (dwell, teleport) and is recorded the same way.
-- The SQL is covered on MariaDB by b19_prison_economy_realdb_spec; here the tables are in memory.
load_resource('tests/lua/fivem_mocks.lua')
local states = { ['pf-justice'] = 'started', ['pf-government'] = 'started', ['pfm-banking'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end
function GetCurrentResourceName() return 'pfm-prison' end
Config = nil
load_resource('pfm-prison/config.lua')
load_resource('pfm-prison/config_work.lua')
local CW = Config.Work

-- ── the rest of pfm-prison, stubbed by what work.lua reads ──────────────────────────────────────
local JU = { calls = {}, down = false, refuse = nil }
local Earned, Events, Meals = {}, {}, {}
local Log = {}
local Revoked = {}
local function cidOf(src) return Mock.players[src] and Mock.players[src].PlayerData.citizenid end
PFPrison = {
    Bridge = {
        rows = {},
        Justice = function(name, orderId, change, opts)
            JU.calls[#JU.calls + 1] = { name = name, orderId = orderId, change = change, opts = opts }
            if JU.down then return nil end
            if JU.refuse then return { ok = false, error = JU.refuse } end
            return { ok = true, applied = change.seconds }
        end,
    },
    Internal = {
        getPlayer = function(src) return exports['pfm-core']:GetPlayer(src) end,
        pedPos = function(src) return Mock.coords[src] end,
        jobs = {}, track = {}, inmates = {}, lockdownUntil = function() return JU.lockdownUntil or 0 end,
        jobSpot = function(job) local s = Config.Locations.jobs[job.name][job.location].coords return vector3(s.x, s.y, s.z) end,
        assignJob = function(src, name, avoid)
            local loc = (avoid or 0) % #Config.Locations.jobs[name] + 1
            PFPrison.Internal.jobs[src] = { name = name, location = loc, assignedAt = os.time(), assignedPos = Mock.coords[src] }
            return PFPrison.Internal.jobs[src]
        end,
    },
    Regime = function(src) return JU.regime or 'justice' end,
    TimeLeft = function() return 30 end,
    Facility = { SetMealProvider = function(fn) Meals.provider = fn return true end },
}
PFPrison.Economy = {
    DayStart = function(t) return t - t % 86400 end,
    Revoked = function(cid, kind) return Revoked[kind] == true end,
    Earn = function(cid, orderId, ticket, wage) Earned[#Earned + 1] = { cid = cid, orderId = orderId, ticket = ticket, wage = wage } return { ok = true, state = 'completed' } end,
    Event = function(cid, kind, detail) Events[#Events + 1] = { cid = cid, kind = kind, detail = detail } end,
}
load_resource('pfm-prison/server/work.lua')
local W = PFPrison.Work
-- pf_prison_work_log in memory, answering work.lua's own statements
PFPrison.Economy.db = function(kind, sql, p)
    if sql == W.SQL.daySums then
        local r = { n = 0, credit = 0, wage = 0 }
        for _, l in ipairs(Log) do
            if l.cid == p[1] and l.at >= p[2] then r.n, r.credit, r.wage = r.n + 1, r.credit + math.abs(l.credit), r.wage + l.wage end
        end
        return r, true
    elseif sql == W.SQL.lastTicket then
        local m = 0
        for _, l in ipairs(Log) do if l.orderId == p[1] and l.ticket > m then m = l.ticket end end
        return m, true
    elseif sql == W.SQL.insert then
        for _, l in ipairs(Log) do if l.orderId == p[2] and l.ticket == p[4] then return nil, false end end
        Log[#Log + 1] = { cid = p[1], orderId = p[2], job = p[3], ticket = p[4], output = p[5], credit = p[6], wage = p[7], at = p[8] }
        return #Log, true
    elseif sql == W.SQL.setCredit then
        for _, l in ipairs(Log) do if l.orderId == p[2] and l.ticket == p[3] and l.credit < 0 then l.credit = p[1] return 1, true end end
        return 0, true
    elseif sql == W.SQL.pendingCredits then
        local out = {}
        for _, l in ipairs(Log) do if l.credit < 0 then out[#out + 1] = { citizenid = l.cid, order_id = l.orderId, ticket = l.ticket, credit_seconds = l.credit } end end
        return out, true
    end
    error('unexpected SQL in spec: ' .. tostring(sql))
end

-- inventory: players and stashes
local Stash, Given = {}, {}
local function count(id, item)
    local n = 0
    for _, it in ipairs((Stash[id] or { items = {} }).items) do if it.name == item then n = n + it.amount end end
    return n
end
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function(_, id) return Stash[id] end,
    CreateInventory = function(_, id) Stash[id] = Stash[id] or { items = {} } end,
    AddItem = function(_, id, name, amount)
        if type(id) == 'number' then Given[#Given + 1] = { src = id, name = name, amount = amount } return true end
        if not Stash[id] or Stash[id].refuse then return false end
        table.insert(Stash[id].items, { name = name, amount = amount })
        return true
    end,
    RemoveItem = function(_, id, name, amount)
        if count(id, name) < amount then return false end
        local left = amount
        for _, it in ipairs(Stash[id].items) do
            local take = math.min(left, it.amount)
            if it.name == name and take > 0 then it.amount, left = it.amount - take, left - take end
        end
        return true
    end,
}

-- pf-government work orders by contract
local GOV = { orders = {}, claims = {}, calls = {}, refuse = nil, report = nil }
local function gcall(name, a) GOV.calls[#GOV.calls + 1] = { name = name, args = a } end
Mock.exportsByResource['pf-government'] = {
    ListWorkOrders = function(_, filter)
        gcall('ListWorkOrders', filter)
        if GOV.refuse then return { ok = false, error = GOV.refuse } end
        local list = {}
        for _, o in ipairs(GOV.orders) do list[#list + 1] = o end
        return { ok = true, list = list }
    end,
    CreateWorkOrder = function(_, spec, opts)
        gcall('CreateWorkOrder', { spec = spec, opts = opts })
        if GOV.refuse then return { ok = false, error = GOV.refuse } end
        local o = { id = #GOV.orders + 1, status = 'open', label = spec.kind, unitsOpen = spec.units,
            site = { x = spec.site.x, y = spec.site.y, z = spec.site.z, r = spec.site.r, label = spec.site.label }, key = opts.key, spec = spec }
        GOV.orders[#GOV.orders + 1] = o
        return { ok = true, workOrderId = o.id }
    end,
    ClaimWorkOrder = function(_, id, claimant)
        gcall('ClaimWorkOrder', { id = id, claimant = claimant })
        local o = GOV.orders[id]
        o.unitsOpen = o.unitsOpen - 1
        GOV.claims[#GOV.claims + 1] = { id = #GOV.claims + 1, order = id, state = 'claimed' }
        return { ok = true, claimId = #GOV.claims, site = o.site, minSeconds = 60 }
    end,
    ReportWorkUnit = function(_, claimId, proof, opts)
        gcall('ReportWorkUnit', { claimId = claimId, proof = proof, opts = opts })
        if GOV.report then return GOV.report end
        GOV.claims[claimId].state = 'done'
        return { ok = true, unitsDone = 1 }
    end,
    ReleaseWorkClaim = function(_, claimId) gcall('ReleaseWorkClaim', { claimId = claimId }) GOV.claims[claimId].state = 'released' return { ok = true } end,
}

local INMATE, VISITOR = 1, 2
local CID, ORDER = 'INMATE1', 41
local K, L = CW.Jobs.kitchen, CW.Jobs.laundry
local function at(p) Mock.coords[INMATE] = vector3(p.x, p.y, p.z) end
local function advance(s) Mock.clock = Mock.clock + s end
local function sessionEvents()
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('pfm-prison:client:WorkSession')) do if e.target == INMATE then out[#out + 1] = e.args[1] end end
    return out
end
local function lastNotify()
    local n = Mock.clientEventsNamed('QBCore:Notify')
    return n[#n] and n[#n].args[1]
end
local function start(job)
    at(CW.Board)
    advance(CW.StartCooldown + 1)
    Mock.fireNet('pfm-prison:server:WorkStart', INMATE, job)
    return W.sessions[INMATE]
end
-- works every station of the shift as an honest client would
local function workAll(job)
    for i, st in ipairs(CW.Jobs[job].steps) do
        advance(math.max(st.minSeconds, 5) + 30)
        at(st.coords)
        Mock.fireNet('pfm-prison:server:WorkStep', INMATE, i)
    end
    advance(1)
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 86400
    Mock.players, Mock.coords = {}, {}
    Mock.newPlayer(INMATE, CID)
    Mock.newPlayer(VISITOR, 'VISITOR1')
    PFPrison.Bridge.rows = { [CID] = { citizenid = CID, order_id = ORDER, status = 'in_cell' } }
    PFPrison.Internal.jobs, PFPrison.Internal.track = {}, {}
    PFPrison.Internal.inmates = { [INMATE] = 'justice' }
    JU.calls, JU.down, JU.refuse, JU.regime, JU.lockdownUntil = {}, false, nil, nil, nil
    Earned, Events, Given, Log, Revoked = {}, {}, {}, {}, {}
    Stash = {}
    GOV.orders, GOV.claims, GOV.calls, GOV.refuse, GOV.report = {}, {}, {}, nil, nil
    W.sessions, W.lastStart, W.credits, W.locks = {}, {}, {}, {}
    W.maint = { unavailable = 'not_checked', nextAt = 0 }
end

describe('starting a shift', function()
    it('only at the work board, only for an inmate held here for a pf-justice order', function()
        Mock.coords[INMATE] = vector3(0, 0, 0)
        Mock.fireNet('pfm-prison:server:WorkStart', INMATE, 'kitchen')
        assert_eq(W.sessions[INMATE], nil)
        assert_eq(lastNotify(), 'Go to the work board')
        Mock.coords[VISITOR] = vector3(CW.Board.x, CW.Board.y, CW.Board.z)
        Mock.fireNet('pfm-prison:server:WorkStart', VISITOR, 'kitchen')
        assert_eq(W.sessions[VISITOR], nil)
        JU.regime = 'legacy'
        assert_eq(start('kitchen'), nil, 'the old metadata runtime has no order to credit')
        JU.regime = nil
        PFPrison.Bridge.rows[CID].status = 'escaped'
        assert_eq(start('kitchen'), nil)
        PFPrison.Bridge.rows[CID].status = 'in_cell'
        assert_eq(start('nonsense'), nil)
        assert_eq(start('electrician'), nil, 'the electrician round has its own spots')
        local s = start('kitchen')
        assert_true(s ~= nil)
        local ev = sessionEvents()
        assert_eq(ev[#ev].job, 'kitchen')
        assert_eq(#ev[#ev].steps, #K.steps)
        assert_eq(ev[#ev].steps[1].x, K.steps[1].coords.x, 'stations come from the server')
    end)
    it('not in a lockdown, not with the work privilege suspended, not past the day\'s shifts', function()
        JU.lockdownUntil = Mock.clock + 600
        assert_eq(start('kitchen'), nil)
        assert_eq(lastNotify(), 'The prison is in lockdown')
        JU.lockdownUntil = nil
        Revoked.work = true
        assert_eq(start('kitchen'), nil)
        assert_eq(lastNotify(), 'Your work privilege is suspended')
        Revoked.work = nil
        for i = 1, CW.MaxTicketsPerDay do Log[i] = { cid = CID, orderId = ORDER, ticket = i, credit = 0, wage = 0, at = Mock.clock } end
        assert_eq(start('kitchen'), nil)
        assert_eq(lastNotify(), 'You have worked enough shifts today')
    end)
end)

describe('stations', function()
    it('count only in order, at the station, after the station\'s minimum time', function()
        start('laundry')
        local s1 = L.steps[1]
        advance(s1.minSeconds + 1)
        at(L.steps[2].coords)
        Mock.fireNet('pfm-prison:server:WorkStep', INMATE, 2)
        assert_eq(W.sessions[INMATE].step, 0, 'out of order')
        Mock.coords[INMATE] = vector3(s1.coords.x + 10, s1.coords.y, s1.coords.z)
        advance(2)
        Mock.fireNet('pfm-prison:server:WorkStep', INMATE, 1)
        assert_eq(W.sessions[INMATE].step, 0, 'not at the station')
        at(s1.coords)
        advance(2)
        Mock.fireNet('pfm-prison:server:WorkStep', INMATE, 1)
        assert_eq(W.sessions[INMATE].step, 1)
        advance(2)
        at(L.steps[2].coords)
        Mock.fireNet('pfm-prison:server:WorkStep', INMATE, 2)
        assert_eq(W.sessions[INMATE].step, 1, 'too soon after the last station')
        advance(L.steps[2].minSeconds)
        Mock.fireNet('pfm-prison:server:WorkStep', INMATE, 2)
        assert_eq(W.sessions[INMATE].step, 2)
    end)
    it('a teleport (main.lua\'s sampler) or an impossible speed between stations voids the shift', function()
        start('kitchen')
        PFPrison.Internal.track[INMATE] = { teleportAt = Mock.clock + 1 }
        advance(K.steps[1].minSeconds + 30)
        at(K.steps[1].coords)
        Mock.fireNet('pfm-prison:server:WorkStep', INMATE, 1)
        assert_eq(W.sessions[INMATE], nil)
        PFPrison.Internal.track[INMATE] = nil
        start('kitchen')
        advance(K.steps[1].minSeconds)
        at(K.steps[1].coords)
        Mock.fireNet('pfm-prison:server:WorkStep', INMATE, 1)
        assert_eq(W.sessions[INMATE].step, 1)
        -- the next station is a few metres away, but a far detour in one second is not walking
        advance(1)
        W.sessions[INMATE].lastStepAt = Mock.clock - K.steps[2].minSeconds
        W.sessions[INMATE].lastPos = { x = K.steps[2].coords.x + 3000, y = K.steps[2].coords.y, z = K.steps[2].coords.z }
        at(K.steps[2].coords)
        Mock.fireNet('pfm-prison:server:WorkStep', INMATE, 2)
        assert_eq(W.sessions[INMATE], nil)
        assert_eq(#Log, 0)
    end)
end)

describe('finishing a shift', function()
    it('kitchen: one ticket, a keyed capped credit, a wage, and meals in the canteen that the routine serves', function()
        start('kitchen')
        W.sessions[INMATE].startedAt = Mock.clock - K.minSeconds - 1
        advance(1)
        Mock.fireNet('pfm-prison:server:WorkFinish', INMATE)
        assert_eq(#Log, 0, 'not before every station')
        W.sessions[INMATE].startedAt = Mock.clock
        workAll('kitchen')
        local s = W.sessions[INMATE]
        s.startedAt = Mock.clock - K.minSeconds + 5
        Mock.fireNet('pfm-prison:server:WorkFinish', INMATE)
        assert_eq(#Log, 0, 'not before the job\'s minimum time')
        advance(5)
        at(CW.Board)
        Mock.fireNet('pfm-prison:server:WorkFinish', INMATE)
        assert_eq(W.sessions[INMATE], nil)
        assert_eq(#Log, 1)
        assert_eq(Log[1].ticket, 1)
        assert_eq(Log[1].credit, K.creditSeconds)
        assert_eq(JU.calls[1].name, 'AdjustOrder')
        assert_eq(JU.calls[1].opts.key, ('pfm-prison:credit:%d:1'):format(ORDER))
        assert_eq(JU.calls[1].change.seconds, K.creditSeconds)
        assert_eq(#Earned, 1)
        assert_eq(Earned[1].wage, K.wage)
        assert_eq(Earned[1].ticket, 1)
        assert_eq(count(CW.Kitchen.Stash, CW.Kitchen.MealItem), CW.Kitchen.Portions)
        -- a second finish of the same shift does nothing
        Mock.fireNet('pfm-prison:server:WorkFinish', INMATE)
        assert_eq(#Log, 1)
        -- the routine's meal time (19D) serves from the canteen first
        W.Boot(Mock.clock)
        assert_true(Mock.callable(Meals.provider))
        assert_true(Meals.provider(CID, INMATE, 'lunch'))
        assert_eq(Given[#Given].name, CW.Kitchen.MealItem)
        assert_eq(count(CW.Kitchen.Stash, CW.Kitchen.MealItem), CW.Kitchen.Portions - 1)
        for _ = 1, CW.Kitchen.Portions - 1 do assert_true(W.ServeMeal(CID, INMATE)) end
        assert_false(W.ServeMeal(CID, INMATE), 'an empty canteen leaves the routine to its own meal')
    end)
    it('laundry: linen into the prison laundry; full batches move to the hospital linen stash', function()
        for n = 1, 3 do
            start('laundry')
            workAll('laundry')
            W.sessions[INMATE].startedAt = Mock.clock - L.minSeconds
            Mock.fireNet('pfm-prison:server:WorkFinish', INMATE)
            assert_eq(#Log, n)
        end
        local L2 = CW.Laundry
        assert_eq(count(L2.HospitalStash, L2.Item), L2.ShipBatch)
        assert_eq(count(L2.Stash, L2.Item), 3 * L2.BagsPerShift - L2.ShipBatch)
        -- the hospital stash refusing a batch puts it back
        Stash[L2.Stash].items = { { name = L2.Item, amount = L2.ShipBatch } }
        Stash[L2.HospitalStash].refuse = true
        assert_eq(W.ShipLinen(), 0)
        assert_eq(count(L2.Stash, L2.Item), L2.ShipBatch)
    end)
    it('a credit pf-justice cannot take now is asked again with the same key; a refusal stores 0', function()
        JU.down = true
        start('kitchen')
        workAll('kitchen')
        W.sessions[INMATE].startedAt = Mock.clock - K.minSeconds
        Mock.fireNet('pfm-prison:server:WorkFinish', INMATE)
        assert_eq(Log[1].credit, -K.creditSeconds, 'pending')
        JU.down = false
        W.Tick(Mock.clock)
        assert_eq(Log[1].credit, -K.creditSeconds, 'not before CreditRetrySeconds')
        advance(CW.CreditRetrySeconds)
        W.Tick(Mock.clock)
        assert_eq(Log[1].credit, K.creditSeconds)
        assert_eq(JU.calls[#JU.calls].opts.key, JU.calls[1].opts.key)
        JU.refuse = 'invalid_state'
        local rec = W.Complete(PFPrison.Inmate(INMATE), 'kitchen', {})
        assert_eq(rec.applied, 0)
        assert_eq(Log[2].credit, 0)
    end)
    it('credits and wages are capped per day', function()
        local credited, paid = 0, 0
        for _ = 1, CW.MaxTicketsPerDay + 1 do
            local rec = W.Complete(PFPrison.Inmate(INMATE), 'maintenance', {})
            if rec.ok then credited, paid = credited + rec.credit, paid + rec.wage end
        end
        assert_eq(#Log, CW.MaxTicketsPerDay)
        assert_eq(credited, CW.MaxCreditSecondsPerDay)
        assert_eq(paid, CW.MaxWagePerDay)
        for _, c in ipairs(JU.calls) do assert_true(c.change.seconds <= CW.Jobs.maintenance.creditSeconds) end
    end)
end)

describe('maintenance (pf-government work orders)', function()
    it('is not offered while pf-government refuses pfm-prison', function()
        GOV.refuse = 'not_allowed'
        W.EnsureMaintenance(Mock.clock)
        assert_eq(W.maint.unavailable, 'not_allowed')
        for _, j in ipairs(W.Offer(PFPrison.Inmate(INMATE))) do assert_true(j.name ~= 'maintenance') end
        assert_eq(start('maintenance'), nil)
        assert_eq(lastNotify(), 'There is no maintenance work right now')
    end)
    it('keeps prison orders open (keyed per site and day), claims a unit as cs and counts it only when the city does', function()
        W.EnsureMaintenance(Mock.clock)
        assert_eq(W.maint.unavailable, nil)
        assert_eq(#GOV.orders, CW.Maintenance.OpenOrders)
        assert_eq(GOV.orders[1].key, ('pfm-prison:wo:1:%d'):format(math.floor(Mock.clock / 86400)))
        assert_true(GOV.orders[1].spec.csEligible)
        W.EnsureMaintenance(Mock.clock)
        assert_eq(#GOV.orders, CW.Maintenance.OpenOrders, 'no more while enough are open')
        local found = false
        for _, j in ipairs(W.Offer(PFPrison.Inmate(INMATE))) do found = found or j.name == 'maintenance' end
        assert_true(found)
        start('maintenance')
        local claim
        for _, c in ipairs(GOV.calls) do if c.name == 'ClaimWorkOrder' then claim = c end end
        assert_eq(claim.args.claimant.kind, 'cs')
        assert_eq(claim.args.claimant.cid, CID)
        assert_true(sessionEvents()[1].site ~= nil)
        GOV.report = { ok = false, error = 'too_soon', remaining = 40 }
        Mock.fireNet('pfm-prison:server:WorkFinish', INMATE)
        assert_true(W.sessions[INMATE] ~= nil, 'kept while the city says too soon')
        assert_eq(#Log, 0)
        GOV.report = nil
        advance(2)
        Mock.fireNet('pfm-prison:server:WorkFinish', INMATE)
        assert_eq(#Log, 1)
        assert_eq(Log[1].job, 'maintenance')
        local rep
        for _, c in ipairs(GOV.calls) do if c.name == 'ReportWorkUnit' then rep = c end end
        assert_eq(rep.args.proof.src, INMATE)
        assert_eq(rep.args.opts.key, ('pf-government:wo:%d:1'):format(rep.args.claimId))
    end)
    it('a dropped shift gives its unit back', function()
        W.EnsureMaintenance(Mock.clock)
        start('maintenance')
        advance(2)
        Mock.fireNet('pfm-prison:server:WorkDrop', INMATE)
        assert_eq(W.sessions[INMATE], nil)
        assert_eq(GOV.claims[1].state, 'released')
        -- a shift of an inmate who left is dropped by the tick
        start('maintenance')
        PFPrison.Bridge.rows[CID] = nil
        W.Tick(Mock.clock)
        assert_eq(W.sessions[INMATE], nil)
        assert_eq(GOV.claims[2].state, 'released')
    end)
end)

describe('the electrician round', function()
    local function assign()
        Mock.coords[INMATE] = vector3(0, 0, 0)
        local job = PFPrison.Internal.assignJob(INMATE, 'electrician', 0)
        local spot = Config.Locations.jobs.electrician[job.location].coords
        return job, vector3(spot.x, spot.y, spot.z)
    end
    it('keeps main.lua\'s checks: at the spot, after the walk, after the dwell, no teleport', function()
        local job, spot = assign()
        Mock.coords[INMATE] = spot
        Mock.fireNet('pfm-prison:server:ElectricianDone', INMATE, job.location)
        assert_eq(#Log, 0, 'too soon after the spot was given')
        advance(600)
        Mock.fireNet('pfm-prison:server:ElectricianDone', INMATE, job.location)
        assert_eq(#Log, 0, 'never seen standing at the spot')
        job.onSpotSince = Mock.clock - 10
        PFPrison.Internal.track[INMATE] = { teleportAt = job.assignedAt + 1 }
        advance(2)
        Mock.fireNet('pfm-prison:server:ElectricianDone', INMATE, job.location)
        assert_eq(#Log, 0, 'teleported since the spot was given')
        assert_eq(Events[#Events].detail.what, 'job_teleport')
        PFPrison.Internal.track[INMATE] = nil
        job, spot = assign()
        advance(600)
        Mock.coords[INMATE] = spot
        job.onSpotSince = Mock.clock - 10
        Mock.fireNet('pfm-prison:server:ElectricianDone', INMATE, job.location + 1)
        assert_eq(#Log, 0, 'another spot')
        advance(2)
        Mock.fireNet('pfm-prison:server:ElectricianDone', INMATE, job.location)
        assert_eq(#Log, 1)
        assert_eq(Log[1].job, 'electrician')
        assert_eq(Earned[1].wage, CW.Jobs.electrician.wage)
        assert_eq(JU.calls[1].change.seconds, CW.Jobs.electrician.creditSeconds)
        local nextJob = Mock.clientEventsNamed('prison:client:SetJob')
        assert_eq(#nextJob, 2)
        assert_true(PFPrison.Internal.jobs[INMATE] ~= nil and PFPrison.Internal.jobs[INMATE] ~= job, 'a new spot')
        advance(2)
        Mock.fireNet('pfm-prison:server:ElectricianDone', INMATE, job.location)
        assert_eq(#Log, 1, 'a spot counts once')
    end)
end)
