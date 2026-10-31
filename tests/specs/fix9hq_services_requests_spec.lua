-- pf-services request lifecycle on an in-memory pf_service_requests table (statements parsed here,
-- so every SQL path of requests.lua runs) and a small keyed ledger:
--   (a) one open request per kind and ref; a police impound supersedes (cancels and refunds) an
--       open tow of the same car, and a tow cannot be ordered while the impound is open;
--   (c) mechanic.roadside pays only on proof: on-site mark (server position), requester confirm or
--       dispute, auto-pay after the window, refund on expiry without a visit;
--   (d) requester / creating job cancel only while open; the escrow sweep never keeps a charge on a
--       request that closed meanwhile; CreateRequest waits out an in_progress escrow key;
--   RPC results carry the public view, not the row.
load_resource('tests/lua/fivem_mocks.lua')

-- ── in-memory pf_service_requests ──────────────────────────────────
local DB = { rows = {}, nextId = 0, beforeUpdate = nil }

local function norm(q) return (q:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')) end

local function splitTop(s, sep)
    local out, depth, quote, cur, i = {}, 0, false, {}, 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "'" then quote = not quote end
        if not quote then
            if c == '(' then depth = depth + 1 elseif c == ')' then depth = depth - 1 end
        end
        if not quote and depth == 0 and s:sub(i, i + #sep - 1) == sep then
            out[#out + 1] = table.concat(cur); cur = {}; i = i + #sep
        else
            cur[#cur + 1] = c; i = i + 1
        end
    end
    out[#out + 1] = table.concat(cur)
    return out
end

local function eq(a, b)
    if a == nil or b == nil then return false end
    return tostring(a):upper() == tostring(b):upper()
end

-- evaluates one WHERE term; `take()` returns the next bound parameter
local function term(row, t, take)
    local col = t:match('^([%w_]+) = %?$')
    if col then return eq(row[col], take()) end
    local lit
    col, lit = t:match("^([%w_]+) = '(.-)'$")
    if col then return eq(row[col], lit) end
    local list
    col, list = t:match('^([%w_]+) IN %((.*)%)$')
    if col then
        local hit = false
        for _, item in ipairs(splitTop(list, ', ')) do
            local v = item == '?' and take() or item:match("^'(.-)'$")
            if eq(row[col], v) then hit = true end
        end
        return hit
    end
    col = t:match('^([%w_]+) IS NOT NULL$')
    if col then return row[col] ~= nil end
    col = t:match('^([%w_]+) < NOW%(%)$')
    if col then return row[col] ~= nil and row[col] < os.time() end
    local secs
    col, secs = t:match('^([%w_]+) < NOW%(%) %- INTERVAL (%d+) SECOND$')
    if col then return row[col] ~= nil and row[col] < os.time() - tonumber(secs) end
    col, secs = t:match('^([%w_]+) >= NOW%(%) %- INTERVAL (%d+) DAY$')
    if col then return row[col] ~= nil and row[col] >= os.time() - tonumber(secs) * 86400 end
    local inner = t:match('^%((.*)%)$')
    if inner then
        local ors = splitTop(inner, ' OR ')
        local any = false
        for _, o in ipairs(ors) do
            local all = true
            for _, a in ipairs(splitTop(o:match('^%((.*)%)$') or o, ' AND ')) do
                if not term(row, a, take) then all = false end
            end
            if all then any = true end
        end
        return any
    end
    error('fake db: unknown WHERE term: ' .. t)
end

local function matches(row, where, params, start)
    local i = start or 0
    local function take() i = i + 1 return params[i] end
    local all = true
    for _, t in ipairs(splitTop(where, ' AND ')) do
        if not term(row, t, take) then all = false end
    end
    return all
end

local function value(expr, take)
    if expr == '?' then return take() end
    if expr == 'NULL' then return nil end
    if expr == 'NOW()' then return os.time() end
    if expr == 'NOW() + INTERVAL ? SECOND' then return os.time() + tonumber(take()) end
    local lit = expr:match("^'(.-)'$")
    if lit then return lit end
    if tonumber(expr) then return tonumber(expr) end
    error('fake db: unknown value: ' .. expr)
end

local function out(row)
    return {
        id = row.id, kind = row.kind, job = row.job, status = row.status, title = row.title, details = row.details,
        x = row.x, y = row.y, z = row.z, plate = row.plate, ref_type = row.ref_type, ref_id = row.ref_id,
        from_type = row.from_type, from_id = row.from_id, from_name = row.from_name,
        requester_cid = row.requester_cid, assignee_cid = row.assignee_cid, assignee_name = row.assignee_name,
        payer = row.payer, reward = row.reward, escrow_state = row.escrow_state, meta = row.meta,
        created = row.created_at, accepted = row.accepted_at, closed = row.closed_at, expires = row.expires_at,
        close_reason = row.close_reason,
    }
end

local function sortedRows()
    local list = {}
    for _, r in pairs(DB.rows) do list[#list + 1] = r end
    table.sort(list, function(a, b) return a.id > b.id end)
    return list
end

local function run(kind, query, params)
    local q = norm(query)
    params = params or {}
    if q:find('^INSERT INTO pf_service_requests') then
        local cols, vals = q:match('%((.-)%) VALUES %((.*)%)$')
        local row = { status = 'open', created_at = os.time() }
        local i = 0
        local function take() i = i + 1 return params[i] end
        local colList, valList = splitTop(cols, ', '), splitTop(vals, ', ')
        for n, c in ipairs(colList) do row[c] = value(valList[n], take) end
        DB.nextId = DB.nextId + 1
        row.id = DB.nextId
        DB.rows[row.id] = row
        return row.id
    end
    if q:find('^SELECT COUNT%(%*%) FROM pf_service_requests WHERE ') then
        local where = q:match('WHERE (.*)$')
        local n = 0
        for _, r in ipairs(sortedRows()) do if matches(r, where, params) then n = n + 1 end end
        return n
    end
    if q:find('^SELECT .- FROM pf_service_requests WHERE ') then
        local where, limit = q:match('FROM pf_service_requests WHERE (.-) ORDER BY id DESC LIMIT (%d+)$')
        where = where or q:match('FROM pf_service_requests WHERE (.*)$')
        local res = {}
        for _, r in ipairs(sortedRows()) do
            if matches(r, where, params) then res[#res + 1] = out(r) end
            if limit and #res >= tonumber(limit) then break end
        end
        if kind == 'single' then return res[1] end
        return res
    end
    if q:find('^UPDATE pf_service_requests SET ') then
        if DB.beforeUpdate then DB.beforeUpdate(q, params) end
        local sets, where = q:match('^UPDATE pf_service_requests SET (.-) WHERE (.*)$')
        local assigns = splitTop(sets, ', ')
        -- the SET parameters come first, then the WHERE ones
        local setCount = 0
        for _, a in ipairs(assigns) do if a:find('%?') then setCount = setCount + 1 end end
        local n = 0
        for _, r in ipairs(sortedRows()) do
            if matches(r, where, params, setCount) then
                local i = 0
                local function take() i = i + 1 return params[i] end
                for _, a in ipairs(assigns) do
                    local c, e = a:match('^([%w_]+) = (.*)$')
                    r[c] = value(e, take)
                end
                n = n + 1
            end
        end
        return { affectedRows = n }
    end
    error('fake db: unhandled ' .. kind .. ': ' .. q:sub(1, 120))
end

local function op(kind)
    local function call(query, params, cb)
        if type(params) == 'function' then cb, params = params, nil end
        local res = run(kind, query, params)
        if cb then cb(res) end
        return res
    end
    return setmetatable({ await = function(q, p) return call(q, p) end }, { __call = function(_, q, p, cb) return call(q, p, cb) end })
end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), scalar = op('scalar'), single = op('single'), prepare = op('prepare') }

-- ── a keyed ledger (failed keys stay failed, completed keys return duplicate) ──
local Ledger = { bal = {}, keys = {}, calls = {}, hook = nil }
local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
local function ledgerTransfer(o)
    Ledger.calls[#Ledger.calls + 1] = o
    if Ledger.hook then
        local r = Ledger.hook(o)
        if r then return r end
    end
    local stored = Ledger.keys[o.key]
    if stored then local c = copy(stored); c.duplicate = true; return c end
    local res
    local unlimited = o.from:find('^system:') ~= nil
    if not unlimited and (Ledger.bal[o.from] or 0) < o.amount then
        res = { ok = false, error = 'insufficient_funds', state = 'failed' }
    else
        Ledger.bal[o.from] = (Ledger.bal[o.from] or 0) - o.amount
        Ledger.bal[o.to] = (Ledger.bal[o.to] or 0) + o.amount
        res = { ok = true, state = 'completed' }
    end
    Ledger.keys[o.key] = copy(res)
    return res
end
Mock.exportsByResource['pfm-banking'] = { Transfer = function(_, o) return ledgerTransfer(o) end }

local appHandlers = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end,
    RegisterAppHandlers = function(_, id, map) appHandlers[id] = map return true end,
    PushToJob = function() return 0 end,
    PushToCitizen = function() return true end,
}

Config = {}
load_resource('[pfscripts]/pf-services/shared/catalog.lua')
load_resource('[pfscripts]/pf-services/shared/config.lua')
function GetCurrentResourceName() return 'pf-services' end
local started = { ['pf-devices'] = true, ['pfm-core'] = true, ['pfm-banking'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
load_resource('[pfscripts]/pf-services/server/schema.lua')
load_resource('[pfscripts]/pf-services/server/events.lua')
load_resource('[pfscripts]/pf-services/server/requests.lua')
load_resource('[pfscripts]/pf-services/server/apps.lua')
load_resource('[pfscripts]/pf-services/server/main.lua')
PFServices.RegisterApps()

local CIT, TOW1, TOW2, COP, MECH, MECH2 = 1, 2, 3, 4, 5, 6
local SITE = vector3(100.0, 200.0, 30.0)

local function bank(cid) return Ledger.bal['player:' .. cid .. ':bank'] or 0 end
local function req(id) return PFServices.GetRequest(id) end
local function row(id) return DB.rows[id] end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates = {}, {}, {}, {}
    DB.rows, DB.nextId, DB.beforeUpdate = {}, 0, nil
    Ledger.bal, Ledger.keys, Ledger.calls, Ledger.hook = {}, {}, {}, nil
    Mock.clock = Mock.clock + 1000 -- past every citizen cooldown
    PFServices.__resetRequests()
    local function add(src, cid, job)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.source = src
        if job then p.PlayerData.job = { name = job, onduty = true, grade = { level = 0 } } end
        return p
    end
    add(CIT, 'CIT1')
    add(TOW1, 'TOW1', 'tow')
    add(TOW2, 'TOW2', 'tow')
    add(COP, 'COP1', 'police')
    add(MECH, 'MECH1', 'mechanic')
    add(MECH2, 'MECH2', 'mechanic')
    Ledger.bal['player:CIT1:bank'] = 1000
    Ledger.bal['society:government'] = 10000
    Ledger.bal['society:mechanic'] = 5000
    Mock.coords[CIT] = SITE
end

local function impound(plate)
    return PFServices.CreateRequest({ kind = 'tow.impound', title = 'Impound ' .. plate, plate = plate, coords = vector3(1, 2, 3),
        ref = { type = 'vehicle', id = plate }, from = { type = 'job', id = 'police', name = 'Officer' },
        meta = { officer = 'COP1', price = 100 } })
end

local function garageTow(plate)
    return PFServices.CreateRequest({ kind = 'tow.recovery', title = 'Tow ' .. plate, plate = plate, coords = vector3(5, 5, 5),
        ref = { type = 'vehicle', id = plate }, from = { type = 'citizen', id = 'CIT1', name = 'Cit' }, requester = 'CIT1',
        meta = { purpose = 'garage' } })
end

describe('(a) requests on the same vehicle', function()
    it('a police impound is created over an open (accepted) garage tow, which is cancelled and refunded', function()
        local tow = garageTow('ABC123')
        assert_true(tow.ok, tow.error)
        assert_eq(bank('CIT1'), 1000 - 175)
        assert_true(PFServices.AcceptRequest(TOW1, tow.id).ok)
        local imp = impound('ABC123')
        assert_true(imp.ok, imp.error)
        assert_true(imp.existing ~= true, 'not handed the tow back as if it were the impound')
        assert_eq(imp.request.kind, 'tow.impound')
        assert_true(imp.id ~= tow.id)
        assert_eq(req(tow.id).status, 'cancelled')
        assert_eq(req(tow.id).closeReason, 'superseded')
        assert_eq(req(tow.id).escrow, 'refunded')
        assert_eq(bank('CIT1'), 1000, 'the owner gets the tow fee back')
        assert_eq(bank('TOW1'), 0)
        assert_eq(Ledger.bal['society:government'], 10000 - 250, 'the impound is funded')
        -- the same impound again returns the open one
        local again = impound('ABC123')
        assert_true(again.existing)
        assert_eq(again.id, imp.id)
    end)

    it('a mechanic tow (society-paid) and a citizen tow with the plate are superseded too', function()
        local mech = PFServices.CreateRequest({ kind = 'tow.recovery', title = 'Tow XYZ', plate = 'XYZ', ref = { type = 'vehicle', id = 'XYZ' },
            from = { type = 'job', id = 'mechanic' }, payer = 'society:mechanic' })
        assert_true(mech.ok, mech.error)
        assert_eq(Ledger.bal['society:mechanic'], 5000 - 175)
        Mock.vehicleOf[CIT] = 77
        Mock.plates[77] = ' XYZ '
        local cit = PFServices.CitizenRequest(CIT, 'tow.recovery', 'Broken')
        assert_true(cit.ok, cit.error)
        assert_eq(req(cit.id).plate, 'XYZ')
        local imp = impound('XYZ')
        assert_true(imp.ok, imp.error)
        assert_eq(imp.request.kind, 'tow.impound')
        assert_eq(req(mech.id).status, 'cancelled')
        assert_eq(req(cit.id).status, 'cancelled')
        assert_eq(Ledger.bal['society:mechanic'], 5000)
        assert_eq(bank('CIT1'), 1000)
    end)

    it('no tow can be ordered for a car while its impound is open', function()
        assert_true(impound('Q1').ok)
        local tow = garageTow('Q1')
        assert_false(tow.ok)
        assert_eq(tow.error, 'superseded')
        assert_eq(bank('CIT1'), 1000, 'nothing charged')
    end)

    it('de-duplicates by kind: another kind on the same ref is its own request', function()
        assert_true(PFServices.RegisterRequestKind('test.inspect', { job = 'mechanic', label = 'Inspect' }))
        local a = PFServices.CreateRequest({ kind = 'test.inspect', ref = { type = 'vehicle', id = 'K9' } })
        local b = garageTow('K9')
        assert_true(a.ok and b.ok)
        assert_true(b.existing ~= true)
        assert_eq(b.request.kind, 'tow.recovery')
        assert_eq(PFServices.FindOpenByRef('vehicle', 'K9', 'test.inspect').id, a.id)
        assert_eq(PFServices.FindOpenByRef('vehicle', 'K9', 'tow.recovery').id, b.id)
    end)
end)

local function roadside()
    local res = PFServices.CitizenRequest(CIT, 'mechanic.roadside', 'Flat tyre')
    assert_true(res.ok, res.error)
    assert_eq(bank('CIT1'), 900, 'call-out fee held')
    assert_true(PFServices.AcceptRequest(MECH, res.id).ok)
    return res.id
end

describe('(c) roadside repair is paid on proof', function()
    it('the mechanic cannot complete from afar; on site it only records the visit; the requester confirms and pays', function()
        local id = roadside()
        Mock.coords[MECH] = vector3(600.0, 200.0, 30.0)
        local far = PFServices.CompleteRequest(MECH, id)
        assert_false(far.ok)
        assert_eq(far.error, 'too_far')
        assert_eq(bank('MECH1'), 0, 'nothing paid from anywhere')
        assert_eq(PFServices.DisputeRequest(CIT, id).error, 'not_marked_done')
        Mock.coords[MECH] = vector3(120.0, 200.0, 30.0) -- 20 m away
        local near = PFServices.CompleteRequest(MECH, id)
        assert_true(near.ok, near.error)
        assert_eq(near.pending, 'requester_confirmation')
        assert_eq(req(id).status, 'accepted')
        assert_eq(bank('MECH1'), 0, 'marking done does not pay')
        assert_eq(req(id).meta.onSite.cid, 'MECH1')
        local view = PFServices.PublicView(req(id), 'CIT1', nil)
        assert_true(view.confirm and view.onSite)
        assert_eq(view.meta.onSite, nil, 'the visit record stays on the server')
        assert_false(PFServices.ConfirmRequest(MECH, id).ok, 'only the requester confirms')
        assert_true(PFServices.ConfirmRequest(CIT, id).ok)
        assert_eq(bank('MECH1'), 100)
        assert_eq(req(id).status, 'completed')
        assert_false(PFServices.ConfirmRequest(CIT, id).ok)
        assert_eq(bank('MECH1'), 100)
    end)

    it('the requester disputes after the mark: refunded, the mechanic is not paid', function()
        local id = roadside()
        Mock.coords[MECH] = SITE
        assert_true(PFServices.CompleteRequest(MECH, id).ok)
        local d = PFServices.DisputeRequest(CIT, id)
        assert_true(d.ok, d.error)
        assert_eq(req(id).status, 'cancelled')
        assert_eq(req(id).closeReason, 'disputed')
        assert_eq(bank('CIT1'), 1000)
        assert_eq(bank('MECH1'), 0)
        assert_false(PFServices.ConfirmRequest(CIT, id).ok)
    end)

    it('no answer within the window after an on-site visit pays the mechanic', function()
        local id = roadside()
        Mock.coords[MECH] = SITE
        assert_true(PFServices.CompleteRequest(MECH, id).ok)
        Mock.clock = Mock.clock + 599
        PFServices.SweepRequests()
        assert_eq(bank('MECH1'), 0, 'still inside the window')
        Mock.clock = Mock.clock + 2
        PFServices.SweepRequests()
        assert_eq(bank('MECH1'), 100)
        assert_eq(req(id).status, 'completed')
        assert_eq(req(id).closeReason, 'auto_confirmed')
    end)

    it('expiry without an on-site visit refunds; expiry after a visit waits for the window and pays', function()
        local id = roadside()
        row(id).expires_at = os.time() - 1
        PFServices.SweepRequests()
        assert_eq(req(id).status, 'expired')
        assert_eq(bank('CIT1'), 1000)
        assert_eq(bank('MECH1'), 0)

        Mock.clock = Mock.clock + 1000
        local id2 = roadside()
        Mock.coords[MECH] = SITE
        assert_true(PFServices.CompleteRequest(MECH, id2).ok)
        row(id2).expires_at = os.time() - 1
        PFServices.SweepRequests()
        assert_eq(req(id2).status, 'accepted', 'a visited request does not expire into a refund')
        Mock.clock = Mock.clock + 700
        PFServices.SweepRequests()
        assert_eq(req(id2).status, 'completed')
        assert_eq(bank('MECH1'), 100)
    end)

    it('a visit belongs to the mechanic who made it: given back, it is dropped', function()
        local id = roadside()
        Mock.coords[MECH] = SITE
        assert_true(PFServices.CompleteRequest(MECH, id).ok)
        assert_true(PFServices.ReleaseRequest(MECH, id).ok)
        assert_true(PFServices.AcceptRequest(MECH2, id).ok)
        assert_false(PFServices.PublicView(req(id), 'CIT1', nil).onSite)
        Mock.clock = Mock.clock + 1000
        PFServices.SweepRequests()
        assert_eq(bank('MECH1'), 0)
        assert_eq(bank('MECH2'), 0)
        assert_eq(PFServices.DisputeRequest(CIT, id).error, 'not_marked_done')
    end)

    it('any kind can opt in through the catalog', function()
        assert_true(PFServices.RegisterRequestKind('test.paint', { job = 'mechanic', payer = 'requester', reward = 50, confirm = true, citizen = true }))
        local res = PFServices.CreateRequest({ kind = 'test.paint', coords = SITE, requester = 'CIT1', ref = { type = 'x', id = 1 } })
        assert_true(res.ok, res.error)
        assert_true(PFServices.AcceptRequest(MECH, res.id).ok)
        Mock.coords[MECH] = vector3(400, 400, 30)
        assert_eq(PFServices.CompleteRequest(MECH, res.id).error, 'too_far')
        Mock.coords[MECH] = SITE
        assert_true(PFServices.CompleteRequest(MECH, res.id).ok)
        assert_eq(bank('MECH1'), 0)
        assert_true(PFServices.ConfirmRequest(CIT, res.id).ok)
        assert_eq(bank('MECH1'), 50)
    end)
end)

describe('(d) cancelling', function()
    it('the requester cancels only while open; once accepted the escrow stays until the worker or expiry settles it', function()
        local open = garageTow('C1')
        assert_true(PFServices.CancelRequest(CIT, open.id).ok)
        assert_eq(bank('CIT1'), 1000)
        Mock.clock = Mock.clock + 1000
        local tow = garageTow('C2')
        assert_true(PFServices.AcceptRequest(TOW1, tow.id).ok)
        local c = PFServices.CancelRequest(CIT, tow.id, 'cancelled_by_requester')
        assert_false(c.ok)
        assert_eq(c.error, 'already_accepted')
        assert_eq(req(tow.id).status, 'accepted')
        assert_eq(bank('CIT1'), 825)
        -- a server resource still closes it
        assert_true(PFServices.CancelRequest(nil, tow.id, 'system').ok)
        assert_eq(bank('CIT1'), 1000)
    end)

    it('the creating job cannot cancel an accepted order either', function()
        local imp = impound('J1')
        assert_true(PFServices.AcceptRequest(TOW1, imp.id).ok)
        assert_eq(PFServices.CancelRequest(COP, imp.id).error, 'already_accepted')
        assert_eq(Ledger.bal['society:government'], 10000 - 250)
    end)

    it('a worker accepting while the cancel is in flight wins: no refund of accepted work', function()
        local tow = garageTow('C3')
        DB.beforeUpdate = function(q)
            if q:find('SET status = %?, closed_at') then
                DB.beforeUpdate = nil
                local r = DB.rows[tow.id]
                r.status, r.assignee_cid = 'accepted', 'TOW2'
            end
        end
        local c = PFServices.CancelRequest(CIT, tow.id)
        assert_false(c.ok)
        assert_eq(req(tow.id).status, 'accepted')
        assert_eq(bank('CIT1'), 825)
    end)
end)

describe('escrow sweep and CreateRequest', function()
    it('a pending request that closed while the sweep charged it is refunded, not kept', function()
        local id = run('insert', [[INSERT INTO pf_service_requests (kind, job, title, payer, reward, escrow_state, requester_cid, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, NOW() + INTERVAL ? SECOND)]], { 'tow.recovery', 'tow', 'Tow', 'requester', 175, 'pending', 'CIT1', 1800 })
        DB.rows[id].created_at = os.time() - 120
        Ledger.hook = function(o)
            if o.key == ('pf-services:req:%d:escrow'):format(id) then
                -- CreateRequest's own attempt cancels the row while the sweep's transfer runs
                Ledger.hook = nil
                DB.rows[id].status, DB.rows[id].escrow_state = 'cancelled', 'failed'
            end
        end
        PFServices.SweepRequests()
        assert_eq(DB.rows[id].status, 'cancelled')
        assert_eq(DB.rows[id].escrow_state, 'refunded')
        assert_eq(bank('CIT1'), 1000, 'charged and refunded')
    end)

    it('the sweep leaves a request it did not age out to CreateRequest', function()
        local id = run('insert', [[INSERT INTO pf_service_requests (kind, job, title, payer, reward, escrow_state, requester_cid, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, NOW() + INTERVAL ? SECOND)]], { 'tow.recovery', 'tow', 'Tow', 'requester', 175, 'pending', 'CIT1', 1800 })
        PFServices.SweepRequests()
        assert_eq(DB.rows[id].escrow_state, 'pending')
        assert_eq(#Ledger.calls, 0)
    end)

    it('CreateRequest does not cancel on an in_progress escrow key; it takes the stored result', function()
        local busy = 2
        Ledger.hook = function(o)
            if o.key:find(':escrow$') and busy > 0 then busy = busy - 1 return { ok = false, error = 'in_progress' } end
        end
        local tow = garageTow('IP1')
        assert_true(tow.ok, tow.error)
        assert_eq(req(tow.id).status, 'open')
        assert_eq(req(tow.id).escrow, 'held')
        assert_eq(bank('CIT1'), 825)
    end)
end)

describe('RPC results carry the public view', function()
    it('accept, complete, release and the citizen request return no requester id or internal meta', function()
        local imp = impound('V1')
        local a = appHandlers.dispatch.accept(TOW1, { id = imp.id })
        assert_true(a.ok, a.error)
        assert_eq(a.request.requester, nil)
        assert_eq(a.request.meta.officer, nil, 'internal meta stays on the server')
        assert_eq(a.request.meta.price, 100)
        assert_true(a.request.mine)
        local r = appHandlers.dispatch.release(TOW1, { id = imp.id })
        assert_true(r.ok)
        assert_eq(r.request.requester, nil)
        assert_eq(r.request.assignee, nil)

        local s = appHandlers.services.request(CIT, { kind = 'mechanic.roadside', details = 'x' })
        assert_true(s.ok, s.error)
        assert_eq(s.request.requester, nil)
        assert_true(s.request.requestedByMe)
        assert_true(PFServices.AcceptRequest(MECH, s.id).ok)
        Mock.coords[MECH] = SITE
        local c = appHandlers.dispatch.complete(MECH, { id = s.id })
        assert_true(c.ok, c.error)
        assert_eq(c.request.requester, nil)
        assert_eq(c.request.meta.onSite, nil)
        local d = appHandlers.services.dispute(CIT, { id = s.id })
        assert_true(d.ok, d.error)
        assert_eq(d.request.requester, nil)
    end)
end)
