-- Batch 20 unit 20C (mocked): supplies, restock and fleet maintenance.
--   pf-government server/departments/procurement.lua: the pf-stores buyer kind 'facility' (server
--     catalog prices, the department's linked society pays, delivery by trucking, unpack into the
--     facility stash all or nothing, the books once per purchase), purchases in
--     pf_gov_dept_procurements (manager only, one lock per facility, keys, pf-stores duplicates,
--     unclear charges held and never re-ordered, the reconcile), staff stash access, export
--     allowlists; fleet maintenance as the pf-services kind mechanic.fleet (the need and the proof
--     read on the server, pf-jobgarages SetServiceState due / in_service / ok / back to due).
--   pf-ambulancejob server/hospital/supplies.lua: rig restock at a hospital bay from the supply
--     room to the par levels (nothing created or lost), the usage log, deliveries logged.
--   pf-ambulancejob server/ems/fleet.lua: worn rigs (server health) are reported once per cooldown.
--   pfm-prison server/supplies.lua: the kitchen cooks from pantry stock (taken first, given back
--     when the canteen refuses), the stock item is registered when missing.
-- The SQL runs on a real database in b20_supplies_realdb_spec; here small emulations answer it.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
vec4 = vec4 or vector4
GlobalState = {}

STARTED = { ['pf-stores'] = true, ['pf-services'] = true, ['pf-jobgarages'] = true, ['pfm-banking'] = true, ['pfm-inventory'] = true, ['pf-government'] = true }
function GetResourceState(res) return STARTED[res] and 'started' or 'missing' end
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
for name, w in pairs({ bandage = 100, ifaks = 400, painkillers = 50, tourniquet = 200, pressure_dressing = 100, hemostatic_gauze = 100,
    chest_seal = 100, splint = 300, c_collar = 300, iv_kit = 200, saline_bag = 500, burn_dressing = 100, suture_kit = 200,
    nitrile_gloves = 10, pistol_ammo = 200, zipties = 50, empty_evidence_bag = 10 }) do
    QBCoreMock.Shared.Items[name] = { name = name, label = name, weight = w, type = 'item', image = name .. '.png' }
end

-- ── vehicles and positions (server natives) ─────────────────────────────
Veh, InVeh = {}, {}
function GetAllVehicles() local out = {} for e in pairs(Veh) do out[#out + 1] = e end table.sort(out) return out end
function DoesEntityExist(e) return Veh[e] ~= nil or Mock.players[e] ~= nil end
function GetEntityModel(e) return Veh[e] and Veh[e].model or 0 end
function GetVehicleNumberPlateText(e) return Veh[e] and Veh[e].plate end
function GetVehicleBodyHealth(e) return Veh[e] and Veh[e].body or 0 end
function GetVehicleEngineHealth(e) return Veh[e] and Veh[e].engine or 0 end
function GetVehiclePedIsIn(ped) return InVeh[ped] or 0 end
function GetEntityCoords(e) if Veh[e] then return Veh[e].pos end return Mock.coords[e] or vector3(0, 0, 0) end
local function car(ent, model, plate, pos, body, engine)
    Veh[ent] = { model = GetHashKey(model), plate = plate, pos = pos, body = body or 1000, engine = engine or 1000 }
    return ent
end

-- ── pfm-inventory: stashes by id ────────────────────────────────────────
Stash, RefuseAdd, Opened, Created = {}, {}, {}, {}
local function stashItems(id)
    local items = {}
    for name, n in pairs(Stash[id] or {}) do if n > 0 then items[#items + 1] = { name = name, amount = n } end end
    return items
end
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function(_, id) if not Stash[id] then return nil end return { items = stashItems(id) } end,
    CreateInventory = function(_, id, data) Stash[id] = Stash[id] or {} Created[id] = data end,
    AddItem = function(_, id, item, n)
        if RefuseAdd[id] or RefuseAdd[tostring(id) .. ':' .. tostring(item)] then return false end
        Stash[id] = Stash[id] or {}
        Stash[id][item] = (Stash[id][item] or 0) + n
        return true
    end,
    RemoveItem = function(_, id, item, n)
        local s = Stash[id]
        if not s or (s[item] or 0) < n then return false end
        s[item] = s[item] - n
        return true
    end,
    SaveStash = function() return true end,
    OpenInventory = function(_, src, id) Opened[#Opened + 1] = { src = src, id = id } end,
    DeliveredInfo = function() return nil end,
}
local function have(id, item) return (Stash[id] or {})[item] or 0 end

-- ── the ledger's record of supply charges ───────────────────────────────
Ledger = {}
Mock.exportsByResource['pfm-banking'] = {
    GetTransaction = function(_, key) return Ledger[key] end,
    EnsureSocietyAccount = function() return true end,
}

-- ── pf-stores as built: the adapter it was given and the orders it made ──
Stores = { adapter = nil, kind = nil, orders = {}, nextId = 500, mode = 'ok', calls = {} }
Mock.exportsByResource['pf-stores'] = {
    RegisterBuyerKind = function(_, kind, adapter) Stores.kind, Stores.adapter = kind, adapter end,
    CreateOrder = function(_, src, payload)
        Stores.calls[#Stores.calls + 1] = { src = src, payload = payload }
        local a = Stores.adapter
        if not a.canManage(src, payload.buyerId) then return { ok = false, error = 'not_owner' } end
        local lines, subtotal = a.price(payload.buyerId, payload.cart)
        if type(lines) ~= 'table' or #lines == 0 then return { ok = false, error = 'invalid_items' } end
        if Stores.mode == 'duplicate' and Stores.last then
            return { ok = true, duplicate = true, data = { orderId = Stores.last.id, total = Stores.last.total, items = lines } }
        end
        local P = Mock.players[src]
        Stores.nextId = Stores.nextId + 1
        local o = { id = Stores.nextId, buyer_kind = payload.kind, store_id = payload.buyerId, owner_citizenid = P.PlayerData.citizenid,
            created_at = os.time() * 1000, total = subtotal + 200.5, account = a.account(payload.buyerId), status = 'awaiting_supplier', lines = lines }
        Stores.orders[o.id], Stores.last = o, o
        if Stores.mode == 'insufficient' then
            o.status = 'failed'
            Ledger[('supply:%d:charge'):format(o.id)] = { state = 'failed', error = 'insufficient_funds' }
            return { ok = false, error = 'insufficient_funds' }
        elseif Stores.mode == 'lost' then
            -- the order went through but the answer never came back (an error on the way)
            Ledger[('supply:%d:charge'):format(o.id)] = { state = 'completed' }
            error('connection lost')
        elseif Stores.mode == 'unclear' then
            -- pf-stores fails the order on any refusal; the ledger has the charge pending
            o.status = 'failed'
            Ledger[('supply:%d:charge'):format(o.id)] = { state = 'pending' }
            return { ok = false, error = 'payment_failed' }
        end
        Ledger[('supply:%d:charge'):format(o.id)] = { state = 'completed' }
        return { ok = true, data = { orderId = o.id, total = o.total, items = lines, contractId = 'SUP-' .. o.id } }
    end,
    CancelOrder = function(_, src, kind, buyerId, orderId)
        if not Stores.adapter.canManage(src, buyerId) then return { ok = false, error = 'not_owner' } end
        local o = Stores.orders[orderId]
        if not o or o.status ~= 'awaiting_supplier' then return { ok = false, error = 'not_cancellable' } end
        o.status = 'cancelled'
        return { ok = true }
    end,
}

-- ── pf-jobgarages fleet ─────────────────────────────────────────────────
Fleet, FleetCalls, FleetFail = {}, {}, false
Mock.exportsByResource['pf-jobgarages'] = {
    GetFleetVehicle = function(_, plate)
        local v = Fleet[plate]
        if not v then return { ok = false, error = 'not_found', message = 'No fleet vehicle has this plate' } end
        return { ok = true, plate = plate, job = v.job, garageId = v.garageId, model = v.model, label = v.label, serviceState = v.serviceState }
    end,
    SetServiceState = function(_, plate, state, opts)
        FleetCalls[#FleetCalls + 1] = { plate = plate, state = state, opts = opts }
        if FleetFail then return { ok = false, error = 'busy', message = 'busy' } end
        local v = Fleet[plate]
        if not v then return { ok = false, error = 'not_found' } end
        local prev = v.serviceState
        v.serviceState = state
        return { ok = true, plate = plate, previous = prev, serviceState = state, changed = prev ~= state }
    end,
}

-- ── pf-services requests ────────────────────────────────────────────────
Svc = { kinds = {}, handler = nil, requests = {}, nextId = 0 }
Mock.exportsByResource['pf-services'] = {
    GetRequestKind = function(_, kind)
        if kind == 'mechanic.roadside' then return { job = { 'mechanic', 'bennys', 'beeker' } } end
        return Svc.kinds[kind]
    end,
    RegisterRequestKind = function(_, kind, def) Svc.kinds[kind] = def return true end,
    RegisterRequestHandler = function(_, kind, h) Svc.handlerKind, Svc.handler = kind, h return true end,
    FindOpenByRef = function(_, t, id, kind)
        for _, r in pairs(Svc.requests) do
            if r.ref.type == t and r.ref.id == id and r.kind == kind and (r.status == 'open' or r.status == 'accepted') then return r end
        end
        return nil
    end,
    CreateRequest = function(_, opts)
        Svc.nextId = Svc.nextId + 1
        local r = { id = Svc.nextId, status = 'open' }
        for k, v in pairs(opts) do r[k] = v end
        Svc.requests[r.id] = r
        return { ok = true, id = r.id, request = r }
    end,
}

-- ═══════════════════════════════════════════════════════════════════════
-- pf-government
-- ═══════════════════════════════════════════════════════════════════════

-- ── an in-memory pf_gov_dept_procurements / audit / the pf-stores orders it reads ──
DB = { proc = {}, audit = {}, usage = {}, nextId = 0 }
local function nid() DB.nextId = DB.nextId + 1 return DB.nextId end
local function has(q, s) return q:find(s, 1, true) ~= nil end
local function copyRow(r) local o = {} for k, v in pairs(r) do o[k] = v end return o end
local function procBy(field, value) for _, r in ipairs(DB.proc) do if r[field] == value then return r end end end

local function run(kind, q, p)
    p = p or {}
    if has(q, 'INSERT INTO pf_gov_dept_procurements') then
        if p[7] ~= nil and procBy('idem_key', p[7]) then error('Duplicate entry') end
        local r = { id = nid(), dept = p[1], buyer_id = p[2], store_order_id = nil, method = 'trucking', items = p[3], total = 0,
            state = 'created', by_cid = p[4], note = nil, at = p[5], updated_at = p[6], idem_key = p[7] }
        DB.proc[#DB.proc + 1] = r
        return r.id
    end
    if has(q, 'DELETE FROM pf_gov_dept_procurements WHERE id = ? AND store_order_id IS NULL') then
        for i, r in ipairs(DB.proc) do if r.id == p[1] and r.store_order_id == nil then table.remove(DB.proc, i) return 1 end end
        return 0
    end
    if has(q, 'FROM pf_gov_dept_procurements WHERE idem_key = ?') then local r = procBy('idem_key', p[1]) return r and copyRow(r) end
    if has(q, 'FROM pf_gov_dept_procurements WHERE id = ?') then local r = procBy('id', p[1]) return r and copyRow(r) end
    if has(q, 'FROM pf_gov_dept_procurements WHERE store_order_id = ?') then local r = procBy('store_order_id', p[1]) return r and copyRow(r) end
    if has(q, "SELECT COUNT(*) FROM pf_gov_dept_procurements WHERE buyer_id = ? AND state = 'payment_pending'") then
        local n = 0
        for _, r in ipairs(DB.proc) do if r.buyer_id == p[1] and r.state == 'payment_pending' then n = n + 1 end end
        return n
    end
    if has(q, "UPDATE pf_gov_dept_procurements SET state = 'delivered'") then
        local r = procBy('id', p[2])
        if r and (r.state == 'created' or r.state == 'paid' or r.state == 'payment_pending') then r.state, r.updated_at = 'delivered', p[1] return 1 end
        return 0
    end
    if has(q, 'UPDATE pf_gov_dept_procurements SET state = ?, updated_at = ?') then
        local cols = {}
        for col in q:gmatch('`([%w_]+)` = %?') do cols[#cols + 1] = col end
        local r = procBy('id', p[#p])
        if not r then return 0 end
        r.state, r.updated_at = p[1], p[2]
        for i, col in ipairs(cols) do r[col] = p[2 + i] end
        return 1
    end
    if has(q, 'FROM pf_gov_dept_procurements WHERE dept = ?') then
        local out = {}
        for i = #DB.proc, 1, -1 do if DB.proc[i].dept == p[1] then out[#out + 1] = copyRow(DB.proc[i]) end end
        return out
    end
    if has(q, "WHERE state = 'payment_pending' ORDER BY id") then
        local out = {}
        for _, r in ipairs(DB.proc) do if r.state == 'payment_pending' then out[#out + 1] = copyRow(r) end end
        return out
    end
    if has(q, "WHERE state = 'created' AND at <= ?") then
        local out = {}
        for _, r in ipairs(DB.proc) do if r.state == 'created' and r.at <= p[1] then out[#out + 1] = copyRow(r) end end
        return out
    end
    if has(q, 'JOIN pf_store_supply_orders o ON o.id = p.store_order_id') then
        local out = {}
        for _, r in ipairs(DB.proc) do
            local o = r.state == 'paid' and Stores.orders[r.store_order_id]
            if o and (o.status == 'unpacked' or o.status == 'cancelled' or o.status == 'failed') then
                out[#out + 1] = { id = r.id, dept = r.dept, total = r.total, buyer_id = r.buyer_id, status = o.status }
            end
        end
        return out
    end
    if has(q, 'SELECT id, status, total FROM pf_store_supply_orders WHERE id = ?') then
        local o = Stores.orders[p[1]]
        return o and { id = o.id, status = o.status, total = o.total } or nil
    end
    if has(q, 'FROM pf_store_supply_orders o') then
        local best
        for _, o in pairs(Stores.orders) do
            if o.buyer_kind == p[1] and o.store_id == p[2] and o.owner_citizenid == p[3] and o.created_at >= p[4]
                and not procBy('store_order_id', o.id) and (not best or o.id > best.id) then best = o end
        end
        return best and { id = best.id, status = best.status, total = best.total } or nil
    end
    if has(q, 'INSERT INTO pf_gov_dept_audit') then
        DB.audit[#DB.audit + 1] = { dept = p[1], action = p[2], actor_cid = p[3], target = p[5], detail = p[6] }
        return nid()
    end
    if has(q, 'INTO pf_hosp_supply_usage') then
        if p[7] ~= nil then for _, u in ipairs(DB.usage) do if u.idem_key == p[7] then return 0 end end end
        DB.usage[#DB.usage + 1] = { facility = p[1], item = p[2], qty = p[3], reason = p[4], ref_id = p[5], at = p[6], idem_key = p[7] }
        return nid()
    end
    error('unexpected statement: ' .. q)
end
local function op(kind)
    local function call(q, p, cb)
        if type(p) == 'function' then cb, p = p, nil end
        local out = run(kind, q, p)
        if cb then cb(out) end
        return out
    end
    return setmetatable({ await = function(q, p) return call(q, p) end }, { __call = function(_, q, p, cb) return call(q, p, cb) end })
end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), scalar = op('scalar'), single = op('single'), prepare = op('query') }

Books = {}
function BudgetRecordSocietyPayout(dept, amount, category, reason, key)
    for _, b in ipairs(Books) do if b.key == key then return false end end
    Books[#Books + 1] = { dept = dept, amount = amount, category = category, reason = reason, key = key }
    return true
end

Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
for _, f in ipairs({ 'server/core.lua', 'server/departments/core.lua', 'server/departments/procurement.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
GovSchema = { Ensure = function() return true end }
GOVCFG = Config
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
local gov = exports['pf-government']
local P, F, D = GovDept.Procurement, GovDept.Procurement.Fleet, GovDept

local function employ(src, cid, job, grade, onduty, isboss)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, grade = { level = grade, isboss = isboss or false }, isboss = isboss or false, onduty = onduty ~= false }
    return p
end
local function auditOf(action)
    local out = {}
    for _, a in ipairs(DB.audit) do if a.action == action then out[#out + 1] = a end end
    return out
end

local MEDIC, EMSMGR, COP, CHIEF, MECH, CO = 1, 2, 3, 4, 5, 6
local PILLBOX_POINT = vector3(339.6, -583.9, 43.28)
local function govReset()
    Config = GOVCFG
    Mock.reset()
    Mock.clock = 1800000000
    Mock.players, Mock.coords = {}, {}
    Mock.invokingResource = nil
    DB.proc, DB.audit, DB.usage = {}, {}, {}
    Books = {}
    Stash, RefuseAdd, Opened, Created = {}, {}, {}, {}
    Ledger = {}
    Stores.orders, Stores.mode, Stores.calls, Stores.last = {}, 'ok', {}, nil
    Veh, InVeh = {}, {}
    Fleet, FleetCalls, FleetFail = {}, {}, false
    Svc.requests, Svc.nextId = {}, 0
    for k in pairs(D.locks) do D.locks[k] = nil end
    for k in pairs(P.placing) do P.placing[k] = nil end
    for k in pairs(P.ordering) do P.ordering[k] = nil end
    P.registered, F.registered = false, false
    employ(MEDIC, 'MED1', 'ambulance', 1, true)
    employ(EMSMGR, 'EMG1', 'ambulance', 3, true)
    employ(COP, 'COP1', 'police', 1, true)
    employ(CHIEF, 'CHF1', 'police', 4, true, true)
    employ(MECH, 'MCH1', 'mechanic', 1, true)
    employ(CO, 'CO1', 'corrections', 2, true)
    assert(P.Register(), 'buyer kind registered')
end
BeforeEach = govReset

describe('20C procurement: the facility buyer kind', function()
    it('registers the facility buyer kind with pf-stores and creates the facility stashes', function()
        assert_eq(Stores.kind, 'facility')
        assert_true(Mock.callable(Stores.adapter.canManage) and Mock.callable(Stores.adapter.unpack), 'adapter functions arrive as funcrefs')
        assert_true(Created['pf_hosp_supply_pillbox'] ~= nil and Created['pfm_prison_pantry'] ~= nil and Created['pf_police_supply_mrpd'] ~= nil)
    end)

    it('prices only from the facility catalog and only while a manager order is being placed', function()
        local a = Stores.adapter
        local lines = a.price('ems:pillbox', { { name = 'bandage', quantity = 2, cost = 1 } })
        assert_eq(lines, nil, 'a cart outside P.Create is not priced')
        P.ordering['ems:pillbox'] = true
        local l2, sub = a.price('ems:pillbox', { { name = 'bandage', quantity = 2, cost = 1, price = 0 } })
        assert_eq(sub, 120, 'catalog price per case x cases; the client cost is ignored')
        assert_eq(l2[1].caseSize, 10)
        assert_eq((a.price('ems:pillbox', { { name = 'pistol_ammo', quantity = 1 } })), nil, 'not in the hospital catalog')
        assert_eq((a.price('ems:pillbox', { { name = 'bandage', quantity = 0 } })), nil, 'quantity below 1')
        assert_eq((a.price('ems:pillbox', { { name = 'bandage', quantity = 1 }, { name = 'bandage', quantity = 1 } })), nil, 'a line twice')
        P.ordering['ems:pillbox'] = nil
    end)

    it('charges the department linked society and routes to the facility dock', function()
        local a = Stores.adapter
        assert_eq(a.account('ems:pillbox'), 'society:ambulance')
        assert_eq(a.account('corrections:bolingbroke_kitchen'), 'society:corrections')
        assert_eq(a.account('police:mrpd_armory'), 'society:police')
        local r = a.route('ems:pillbox')
        assert_near(r.dropoff.coords.x, 294.3, 0.01)
        assert_eq(r.trucking.title, 'Public service supplies')
        assert_eq(a.route('nope:x'), false)
    end)

    it('canManage: on-duty staff of the facility department (unpack, list); a placing mark is for that facility only', function()
        local a = Stores.adapter
        assert_true(a.canManage(MEDIC, 'ems:pillbox'))
        assert_false(a.canManage(COP, 'ems:pillbox'), 'another department')
        Mock.players[MEDIC].PlayerData.job.onduty = false
        assert_false(a.canManage(MEDIC, 'ems:pillbox'), 'off duty')
        P.placing[EMSMGR] = 'ems:paleto'
        assert_false(a.canManage(EMSMGR, 'ems:pillbox'))
        assert_true(a.canManage(EMSMGR, 'ems:paleto'))
    end)
end)

describe('20C procurement: purchases', function()
    it('only an on-duty manager orders; the order is placed by trucking, paid once, recorded paid', function()
        local res = P.Create(MEDIC, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        assert_eq(res.error, 'no_permission')
        assert_eq(#Stores.calls, 0)
        res = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 }, { name = 'ifaks', quantity = 2 } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(#Stores.calls, 1)
        assert_eq(Stores.calls[1].payload.kind, 'facility')
        assert_eq(Stores.calls[1].payload.method, 'trucking')
        local o = Stores.orders[res.procurement.orderId]
        assert_eq(o.account, 'society:ambulance')
        assert_eq(res.procurement.state, 'paid')
        assert_eq(res.procurement.total, 821, '620 goods + 200.5 rounded')
        assert_eq(#auditOf('procure_order'), 1)
        assert_eq(P.placing[EMSMGR], nil, 'the placing mark is cleared')
        assert_eq(P.ordering['ems:pillbox'], nil)
    end)

    it('a cop cannot order hospital supplies, and the police chief orders the police supply room', function()
        assert_eq(P.Create(COP, 'police:mrpd_armory', { { name = 'zipties', quantity = 1 } }).error, 'no_permission')
        assert_eq(P.Create(CHIEF, 'ems:pillbox', { { name = 'bandage', quantity = 1 } }).error, 'no_permission')
        assert_true(P.Create(CHIEF, 'police:mrpd_armory', { { name = 'zipties', quantity = 10 } }).ok)
    end)

    it('the facility is locked while an order is placed', function()
        D.locks['procure:ems:pillbox'] = true
        assert_eq(P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } }).error, 'busy')
    end)

    it('insufficient funds: failed, nothing held', function()
        Stores.mode = 'insufficient'
        local res = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(DB.proc[1].state, 'failed')
        Stores.mode = 'ok'
        assert_true(P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } }).ok, 'a clear failure may be ordered again (new order, new ledger key)')
    end)

    it('an unclear charge is held: nothing is ordered for the facility until the ledger answers', function()
        Stores.mode = 'unclear'
        local res = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        assert_eq(res.error, 'payment_pending')
        local row = DB.proc[1]
        assert_eq(row.state, 'payment_pending')
        assert_true(row.store_order_id ~= nil)
        Stores.mode = 'ok'
        local again = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        assert_eq(again.error, 'payment_pending')
        assert_eq(#Stores.calls, 1, 'no second order (no new charge key) while unclear')
        -- the ledger completes the charge of the order pf-stores failed: held for staff, never charged again
        Ledger[('supply:%d:charge'):format(row.store_order_id)] = { state = 'completed' }
        assert_eq(P.ReconcileTick(), 1)
        assert_eq(row.state, 'charge_held')
        assert_eq(#auditOf('procure_held'), 2)
        assert_true(P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } }).ok)
    end)

    it('an answer lost on the way back: the order pf-stores made is found and the purchase is paid', function()
        Stores.mode = 'lost'
        local res = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(DB.proc[1].state, 'paid')
        assert_eq(DB.proc[1].store_order_id, Stores.last.id)
    end)

    it('an order pf-stores is still being paid for stays held', function()
        Stores.mode = 'unclear'
        P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        Stores.last.status = 'created'
        Ledger[('supply:%d:charge'):format(Stores.last.id)] = { state = 'completed' }
        P.ReconcileTick()
        assert_eq(DB.proc[1].state, 'payment_pending')
        Stores.last.status = 'awaiting_supplier' -- pf-stores recovered it as paid
        P.ReconcileTick()
        assert_eq(DB.proc[1].state, 'paid')
    end)

    it('an unclear charge the ledger then refuses becomes failed', function()
        Stores.mode = 'unclear'
        P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        Ledger[('supply:%d:charge'):format(DB.proc[1].store_order_id)] = { state = 'failed', error = 'insufficient_funds' }
        P.ReconcileTick()
        assert_eq(DB.proc[1].state, 'failed')
    end)

    it('an interrupted_unverified ledger failure is still unclear', function()
        Stores.mode = 'unclear'
        P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        Ledger[('supply:%d:charge'):format(DB.proc[1].store_order_id)] = { state = 'failed', error = 'interrupted_unverified' }
        P.ReconcileTick()
        assert_eq(DB.proc[1].state, 'payment_pending')
    end)

    it('a pf-stores duplicate returns the first purchase; keys repeat or refuse', function()
        local first = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        Stores.mode = 'duplicate'
        local dup = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        assert_true(dup.ok and dup.duplicate)
        assert_eq(dup.procurement.id, first.procurement.id)
        assert_eq(#DB.proc, 1, 'the second row is removed')
        Stores.mode = 'ok'
        local k1 = P.Create(EMSMGR, 'ems:paleto', { { name = 'ifaks', quantity = 1 } }, { key = 'test:proc:1' })
        local k2 = P.Create(EMSMGR, 'ems:paleto', { { name = 'ifaks', quantity = 1 } }, { key = 'test:proc:1' })
        assert_true(k2.duplicate)
        assert_eq(k2.procurement.id, k1.procurement.id)
        assert_eq(P.Create(EMSMGR, 'ems:paleto', { { name = 'ifaks', quantity = 2 } }, { key = 'test:proc:1' }).error, 'key_reused')
        assert_eq(P.Create(EMSMGR, 'ems:paleto', { { name = 'ifaks', quantity = 2 } }, { key = 'bad key!' }).error, 'bad_args')
    end)

    it('unpack puts quantity x case size into the facility stash once, books it once and tells listeners', function()
        local res = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 2 }, { name = 'ifaks', quantity = 1 } })
        local o = Stores.orders[res.procurement.orderId]
        assert_true(Stores.adapter.unpack('ems:pillbox', o.lines, o.id, os.time()))
        assert_eq(have('pf_hosp_supply_pillbox', 'bandage'), 20)
        assert_eq(have('pf_hosp_supply_pillbox', 'ifaks'), 4)
        assert_eq(DB.proc[1].state, 'delivered')
        assert_eq(#Books, 1)
        assert_eq(Books[1].key, ('pf-government:dept:ems:procurement:%d'):format(DB.proc[1].id))
        assert_eq(Books[1].dept, 'ems')
        local ev
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-government:server:facilityStockDelivered' then ev = e.args[1] end end
        assert_eq(ev.stash, 'pf_hosp_supply_pillbox')
        assert_eq(ev.orderId, o.id)
        P.Book(DB.proc[1])
        assert_eq(#Books, 1, 'booked once')
    end)

    it('unpack is all or nothing', function()
        local res = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 2 }, { name = 'ifaks', quantity = 1 } })
        local o = Stores.orders[res.procurement.orderId]
        RefuseAdd['pf_hosp_supply_pillbox:ifaks'] = true
        assert_false(Stores.adapter.unpack('ems:pillbox', o.lines, o.id, os.time()))
        assert_eq(have('pf_hosp_supply_pillbox', 'bandage'), 0, 'the bandages went back out')
        assert_eq(DB.proc[1].state, 'paid')
        assert_eq(#Books, 0)
    end)

    it('a manager cancels a purchase not yet on the road; staff cannot', function()
        local res = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        assert_eq(P.Cancel(MEDIC, res.procurement.id).error, 'no_permission')
        local c = P.Cancel(EMSMGR, res.procurement.id)
        assert_true(c.ok, tostring(c.error))
        assert_eq(c.procurement.state, 'cancelled')
        assert_eq(Stores.orders[res.procurement.orderId].status, 'cancelled')
        assert_eq(P.Cancel(EMSMGR, res.procurement.id).error, 'invalid_state')
    end)

    it('the reconcile settles rows a crash left created, and paid rows whose order ended', function()
        local res = P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        Stores.orders[res.procurement.orderId].status = 'unpacked'
        DB.proc[#DB.proc + 1] = { id = nid(), dept = 'ems', buyer_id = 'ems:paleto', state = 'created', by_cid = 'EMG1', at = os.time() - 600, total = 0 }
        Mock.clock = Mock.clock + 1
        P.ReconcileTick()
        assert_eq(DB.proc[1].state, 'delivered')
        assert_eq(#Books, 1)
        assert_eq(DB.proc[2].state, 'failed', 'never placed')
    end)

    it('lists and the catalog are for the caller department only', function()
        P.Create(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } })
        assert_eq(#P.List(MEDIC).list, 1)
        assert_eq(#P.List(COP).list, 0)
        local cat = P.Catalog(MEDIC)
        assert_eq(cat.dept, 'ems')
        assert_false(cat.mayOrder)
        assert_true(P.Catalog(EMSMGR).mayOrder)
        assert_eq(#cat.facilities, 2)
    end)

    it('exports refuse resources outside the allowlist', function()
        Mock.invokingResource = 'some-resource'
        assert_eq(gov:CreateProcurement(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } }).error, 'not_allowed')
        assert_eq(gov:RequestFleetService('AMB01', {}).error, 'not_allowed')
        Mock.invokingResource = 'pf-ambulancejob'
        assert_true(gov:CreateProcurement(EMSMGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } }).ok)
    end)

    it('/supplyroom opens the stash of the point the staff member stands at', function()
        Mock.coords[MEDIC] = PILLBOX_POINT
        local res = P.OpenStash(MEDIC)
        assert_true(res.ok)
        assert_eq(Opened[1].id, 'pf_hosp_supply_pillbox')
        Mock.coords[COP] = PILLBOX_POINT
        assert_eq(P.OpenStash(COP).error, 'no_permission')
        Mock.coords[MEDIC] = vector3(0, 0, 0)
        assert_eq(P.OpenStash(MEDIC).error, 'too_far')
    end)
end)

describe('20C fleet maintenance (mechanic.fleet)', function()
    local RIG = 1001
    local function rig(body, engine)
        Fleet['AMB01'] = { job = 'ambulance', garageId = 'ambulance_main', model = 'ambulance', label = 'Ambulance', serviceState = 'ok' }
        car(RIG, 'ambulance', 'AMB01', vector3(300, -577, 43), body, engine)
        Mock.coords[MEDIC] = vector3(302, -577, 43)
    end

    it('registers the kind for the mechanic shops with its handler', function()
        assert_true(F.Register())
        local def = Svc.kinds['mechanic.fleet']
        assert_eq(def.job[1], 'mechanic')
        assert_true(def.verify)
        assert_eq(Svc.handlerKind, 'mechanic.fleet')
        assert_true(Mock.callable(Svc.handler.canComplete))
    end)

    it('a medic next to a worn rig asks for service: due, request paid from the department society', function()
        rig(600, 900)
        local res = F.Request('AMB01', { actor = { src = MEDIC }, body = 1000 })
        assert_true(res.ok, tostring(res.error))
        assert_eq(FleetCalls[1].state, 'due')
        assert_eq(FleetCalls[1].opts.body, 600, 'the server reading, not a client value')
        local req = Svc.requests[res.requestId]
        assert_eq(req.kind, 'mechanic.fleet')
        assert_eq(req.payer, 'society:ambulance')
        assert_eq(req.reward, 150)
        assert_eq(req.ref.type, 'fleet')
        assert_eq(req.plate, 'AMB01')
        local again = F.Request('AMB01', { actor = { src = MEDIC } })
        assert_true(again.existing, 'one open request per vehicle')
    end)

    it('refuses a healthy vehicle, another department, a distant reporter and a stored vehicle', function()
        rig(990, 990)
        assert_eq(F.Request('AMB01', { actor = { src = MEDIC } }).error, 'invalid_state')
        Veh[RIG].body = 500
        Mock.coords[COP] = vector3(302, -577, 43)
        assert_eq(F.Request('AMB01', { actor = { src = COP } }).error, 'no_permission')
        Mock.coords[MEDIC] = vector3(400, -577, 43)
        assert_eq(F.Request('AMB01', { actor = { src = MEDIC } }).error, 'too_far')
        Veh[RIG] = nil
        assert_eq(F.Request('AMB01', { actor = { src = MEDIC } }).error, 'not_found')
        assert_eq(F.Request('XX99', { actor = { src = MEDIC } }).error, 'not_found')
    end)

    it('a fleet owner resource reports only its own fleet without an actor', function()
        rig(500, 500)
        Fleet['PD01'] = { job = 'police', garageId = 'police_main', model = 'police', serviceState = 'ok' }
        car(1002, 'police', 'PD01', vector3(0, 0, 0), 500, 500)
        Mock.invokingResource = 'pf-ambulancejob'
        assert_true(gov:RequestFleetService('AMB01', { actor = { kind = 'system', label = 'x' } }).ok)
        assert_eq(gov:RequestFleetService('PD01', {}).error, 'not_allowed')
    end)

    it('accepted: in_service; completion is proved by the server reading and SetServiceState ok', function()
        rig(600, 600)
        F.Register()
        local res = F.Request('AMB01', { actor = { src = MEDIC } })
        local req = Svc.requests[res.requestId]
        Svc.handler.onAccepted(req, MECH)
        assert_eq(Fleet['AMB01'].serviceState, 'in_service')
        Mock.coords[MECH] = vector3(305, -577, 43)
        local ok, why = Svc.handler.canComplete(req, MECH, { body = 1000, engine = 1000, repaired = true })
        assert_false(ok, 'a client proof is ignored')
        assert_eq(why, 'not_repaired')
        Veh[RIG].body, Veh[RIG].engine = 1000, 990
        Mock.coords[MECH] = vector3(350, -577, 43)
        ok, why = Svc.handler.canComplete(req, MECH, {})
        assert_eq(why, 'too_far')
        Mock.coords[MECH] = vector3(305, -577, 43)
        FleetFail = true
        ok, why = Svc.handler.canComplete(req, MECH, {})
        assert_false(ok, 'no proof without the fleet record')
        FleetFail = false
        ok = Svc.handler.canComplete(req, MECH, {})
        assert_true(ok)
        local last = FleetCalls[#FleetCalls]
        assert_eq(last.state, 'ok')
        assert_eq(last.opts.body, 1000)
        assert_eq(last.opts.engine, 990)
        assert_eq(Fleet['AMB01'].serviceState, 'ok')
    end)

    it('a request closed without the work puts an in-service vehicle back to due', function()
        rig(600, 600)
        F.Register()
        local res = F.Request('AMB01', { actor = { src = MEDIC } })
        local req = Svc.requests[res.requestId]
        Svc.handler.onAccepted(req, MECH)
        Svc.handler.onClosed(req, 'expired')
        assert_eq(Fleet['AMB01'].serviceState, 'due')
    end)

    it('/fleetservice reports the vehicle the player sits in', function()
        rig(600, 600)
        InVeh[MEDIC] = RIG
        assert_true(F.Report(MEDIC).ok)
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════
-- pf-ambulancejob
-- ═══════════════════════════════════════════════════════════════════════
Config = nil
load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/config_ems.lua')
load_resource('[pfscripts]/pf-ambulancejob/config_hospital.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/framework.lua')
load_resource('[pfscripts]/pf-ambulancejob/server/hospital/facility.lua')
load_resource('[pfscripts]/pf-ambulancejob/server/hospital/supplies.lua')
load_resource('[pfscripts]/pf-ambulancejob/server/ems/fleet.lua')
AJCFG = Config
local S, Fl = PFHospital.Supplies, PFEms.Fleet
local SUP, RIGBAY = 'pf_hosp_supply_pillbox', vector3(299.84, -577.28, 43.26)

local GovCalls = {}
local function ajReset()
    govReset()
    Config = AJCFG
    GovCalls = {}
    Mock.exportsByResource['pf-government'] = {
        RequestFleetService = function(_, plate, opts) GovCalls[#GovCalls + 1] = { plate = plate, opts = opts } return { ok = true, requestId = #GovCalls } end,
        HasQualification = function() return false end,
    }
    STARTED['pf-government'] = false -- tiers come from the grade (this spec does not need them)
    Fl.asked = {}
    for src = 1, 10 do PFHospital.ForgetSource(src) end
end
BeforeEach = ajReset

describe('20C rig restock at a hospital bay', function()
    local RIG = 2001
    local function setup()
        car(RIG, 'ambulance', 'AB 12', vector3(300, -579, 43))
        Mock.coords[MEDIC] = vector3(301, -579, 43)
        Stash[SUP] = { bandage = 30, ifaks = 1, painkillers = 6 }
        Stash['pf_medbag_AB12'] = { bandage = 4 }
    end

    it('tops the rig medbag up to par from the supply room, moving (not creating) stock, and logs it', function()
        setup()
        local res = S.RestockRig(MEDIC)
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.plate, 'AB12')
        assert_eq(have('pf_medbag_AB12', 'bandage'), 10, 'par 10')
        assert_eq(have(SUP, 'bandage'), 24, '6 left the supply room')
        assert_eq(have('pf_medbag_AB12', 'ifaks'), 1)
        assert_eq(have(SUP, 'ifaks'), 0)
        assert_eq(have('pf_medbag_AB12', 'painkillers'), 6)
        local short = {}
        for _, s in ipairs(res.short) do short[s.item] = s.qty end
        assert_eq(short.ifaks, 3, 'the room ran short of ifaks')
        local logged = 0
        for _, u in ipairs(DB.usage) do
            assert_eq(u.facility, 'pillbox')
            assert_eq(u.reason, 'rig_restock')
            logged = logged + u.qty
        end
        assert_eq(logged, 13)
    end)

    it('only on-duty hospital staff, at a bay, with the rig in the bay', function()
        setup()
        Mock.players[MEDIC].PlayerData.job.onduty = false
        assert_eq(S.RestockRig(MEDIC).error, 'no_permission')
        Mock.players[MEDIC].PlayerData.job.onduty = true
        Mock.coords[COP] = vector3(301, -579, 43)
        assert_eq(S.RestockRig(COP).error, 'no_permission')
        Mock.coords[MEDIC] = vector3(0, 0, 0)
        assert_eq(S.RestockRig(MEDIC).error, 'too_far')
        Mock.coords[MEDIC] = vector3(301, -579, 43)
        Veh[RIG].model = GetHashKey('police')
        PFHospital.ForgetSource(MEDIC)
        assert_eq(S.RestockRig(MEDIC).error, 'not_found', 'not an ambulance')
        assert_eq(S.RestockRig(MEDIC).error, 'rate_limited', 'one restock every few seconds')
        assert_eq(have(SUP, 'bandage'), 30)
    end)

    it('stock the rig cannot take goes back to the supply room', function()
        setup()
        RefuseAdd['pf_medbag_AB12:bandage'] = true
        local res = S.RestockRig(MEDIC)
        assert_true(res.ok)
        assert_eq(have(SUP, 'bandage'), 30)
        assert_eq(have('pf_medbag_AB12', 'bandage'), 4)
    end)

    it('a rig being restocked is locked', function()
        setup()
        local ok, busy = PFHospital.WithLock('rigstock:AB12', function() return S.RestockRig(MEDIC) end)
        assert_eq(ok.error, 'busy')
    end)

    it('deliveries into hospital stashes are logged with the supply order id; others are ignored', function()
        assert_eq(S.OnDelivered({ stash = SUP, orderId = 77, items = { { item = 'bandage', qty = 20 }, { item = 'ifaks', qty = 4 } } }), 2)
        assert_eq(S.OnDelivered({ stash = 'pf_infirmary_bolingbroke', orderId = 78, items = { { item = 'painkillers', qty = 10 } } }), 1)
        assert_eq(S.OnDelivered({ stash = 'pf_police_supply_mrpd', orderId = 79, items = { { item = 'zipties', qty = 10 } } }), 0)
        assert_eq(DB.usage[1].reason, 'delivery')
        assert_eq(DB.usage[1].ref_id, 77)
        assert_eq(DB.usage[3].facility, 'bolingbroke')
        S.OnDelivered({ stash = SUP, orderId = 77, items = { { item = 'bandage', qty = 20 } } })
        assert_eq(#DB.usage, 3, 'a repeated notice is logged once (key)')
        Mock.fireEvent('pf-government:server:facilityStockDelivered', 5, { stash = SUP, orderId = 80, items = { { item = 'bandage', qty = 1 } } })
        assert_eq(#DB.usage, 3, 'a player source is ignored')
    end)
end)

describe('20C rig wear reports', function()
    it('a worn rig (server health) is reported once per cooldown; healthy rigs and other vehicles are not', function()
        STARTED['pf-government'] = true
        car(3001, 'ambulance', 'AMB01', vector3(0, 0, 0), 700, 1000)
        car(3002, 'ambulance', 'AMB02', vector3(0, 0, 0), 1000, 1000)
        car(3003, 'police', 'PD01', vector3(0, 0, 0), 100, 100)
        assert_eq(Fl.Tick(1000), 1)
        assert_eq(GovCalls[1].plate, 'AMB01')
        assert_eq(Fl.Tick(1100), 0, 'cooldown')
        assert_eq(Fl.Tick(1000 + 601), 1)
    end)

    it('does nothing while pf-government is not running', function()
        car(3001, 'ambulance', 'AMB01', vector3(0, 0, 0), 100, 100)
        assert_eq(Fl.Tick(1000), 0)
        assert_eq(#GovCalls, 0)
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════
-- pfm-prison
-- ═══════════════════════════════════════════════════════════════════════
Config = { Justice = {} }
load_resource('pfm-prison/config_work.lua')
PFPrison = PFPrison or {}
load_resource('pfm-prison/server/work.lua')
local W = PFPrison.Work
local baseAddMeals = W.AddMeals
load_resource('pfm-prison/server/supplies.lua')
PRCFG = Config
local PS = PFPrison.Supplies
local PANTRY, CANTEEN = 'pfm_prison_pantry', 'pfm_prison_canteen'

BeforeEach = function()
    govReset()
    Config = PRCFG
    Config.Supplies = nil
end

describe('20C prison kitchen cooks from pantry stock', function()
    it('wraps the 19E kitchen output once', function()
        assert_true(W.AddMeals ~= baseAddMeals)
        local wrapped = W.AddMeals
        PS.Install()
        assert_eq(W.AddMeals, wrapped)
    end)

    it('a shift turns pantry stock into canteen meals (4 a unit, rounded up)', function()
        Stash[PANTRY] = { prison_food_stock = 3 }
        QBCoreMock.Shared.Items.prison_food_stock = { name = 'prison_food_stock' }
        assert_eq(W.AddMeals(4), 4)
        assert_eq(have(CANTEEN, 'sandwich'), 4)
        assert_eq(have(PANTRY, 'prison_food_stock'), 2)
        assert_eq(W.AddMeals(6), 6)
        assert_eq(have(PANTRY, 'prison_food_stock'), 0, 'two units for six portions')
    end)

    it('an empty pantry cooks nothing and takes nothing', function()
        assert_eq(W.AddMeals(4), 0)
        assert_eq(have(CANTEEN, 'sandwich'), 0)
    end)

    it('the canteen cap limits what is cooked and what is taken', function()
        Stash[PANTRY] = { prison_food_stock = 10 }
        Stash[CANTEEN] = { sandwich = 58 }
        assert_eq(W.AddMeals(4), 2)
        assert_eq(have(PANTRY, 'prison_food_stock'), 9)
    end)

    it('stock comes back when the canteen refuses the meals', function()
        Stash[PANTRY] = { prison_food_stock = 2 }
        RefuseAdd[CANTEEN] = true
        assert_eq(W.AddMeals(4), 0)
        assert_eq(have(PANTRY, 'prison_food_stock'), 2)
    end)

    it('RequireStock = false keeps the 19E kitchen', function()
        Config.Supplies = { Kitchen = { RequireStock = false } }
        assert_eq(W.AddMeals(4), 4)
        assert_eq(have(CANTEEN, 'sandwich'), 4)
    end)

    it('registers the stock item with pfm-core when it is missing', function()
        QBCoreMock.Shared.Items.prison_food_stock = nil
        assert_true(PS.EnsureItem())
        assert_eq(QBCoreMock.Shared.Items.prison_food_stock.label, 'Bulk Food Stock')
        assert_true(PS.EnsureItem(), 'already there')
    end)
end)
