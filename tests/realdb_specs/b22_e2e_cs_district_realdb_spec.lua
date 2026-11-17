-- 22A end to end on MariaDB: community-service order -> government work order -> unit reported ->
-- district state improves, with the REAL pf-justice (every server file), the REAL pf-government
-- (infrastructure + work orders) and the REAL pfm-banking ledger in one world (tests/specs/b22_e2e_world.lua).
--   * a court sentences community service (MDT FileCase, guilty plea, sentence in the Court app);
--   * a district over its backlog threshold gets a cs-eligible work order from the infrastructure tick;
--   * the citizen signs in at the City Hall desk (Community Service app), claims a unit, walks the task
--     steps (net events), works on site, reports: pf-government counts the unit and saves the district;
--   * pf-justice and pf-government restart in the middle of a task: the steps, the claim and the units
--     are kept; no unit is counted twice and the district is not improved twice;
--   * the order completes with its units (the work order keeps its third unit open); nobody is paid for community service.
-- Stubbed: FiveM natives, pf-citizen mail, pf-devices registry, pf-services.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
load_resource('tests/specs/b22_e2e_world.lua')
function IsDuplicityVersion() return true end
function SetEntityCoords() end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
GlobalState = {}
Mock.clock = 1800000000
function GetPlayers()
    local out = {}
    for src in pairs(Mock.players) do out[#out + 1] = tostring(src) end
    table.sort(out)
    return out
end
QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, doj = { label = 'DOJ' }, judge = { label = 'Judiciary' },
    government = { label = 'Government', grades = {} } }
World.installResourceState({ ['pf-ambulancejob'] = 'missing', ['pfm-prison'] = 'missing', ['pfm-phone'] = 'missing',
    ['pf-services'] = 'missing', ['pfm-houses'] = 'missing', ['pf-policemdt-DEV'] = 'missing' })

World.startBank()
World.inventory()
Mock.exportsByResource['pf-citizen'] = { SendMail = function() return 1 end, AddCalendarEvent = function() return 1 end }
local Apps = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end,
    RegisterAppHandlers = function(_, appId, handlers) Apps[appId] = handlers return true end,
    PushToJob = function() end, Push = function() end, PushToCitizen = function() end, PushToApp = function() end,
}
local function app(appId, method, src, payload)
    local h = assert(Apps[appId], 'app not registered: ' .. tostring(appId))
    if h.__access and not h.__access(src) then return { ok = false, error = 'no_access' } end
    return Mock.cross(h[method], src, payload or {})
end

-- pf-government (its own install SQL, then its schema, budgets, infrastructure and work orders)
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
local GFILES = { '[pfscripts]/pf-government/config.lua', '@pfm-banking/payouts.lua' }
for _, f in ipairs({ 'core', 'schema', 'treasury', 'budgets', 'bills', 'audit', 'infrastructure', 'workorders', 'main' }) do
    GFILES[#GFILES + 1] = '[pfscripts]/pf-government/server/' .. f .. '.lua'
end
World.start('pf-government', GFILES, {
    before = function(env) env.NotifyGovernment = function() end env.DebugPrint = function() end end,
    boot = function(env)
        assert(env.GovSchema.Ensure(), 'gov schema')
        env.InitializeBudgets()
        env.InitializeInfrastructure()
        assert(env.InitializeWorkOrders(), 'work orders')
    end,
})
local function G() return World.env('pf-government') end

local JFILES = { '[pfscripts]/pf-justice/config.lua', '[pfscripts]/pf-justice/shared/states.lua', '[pfscripts]/pf-justice/shared/cs_tasks.lua',
    '@pfm-banking/payouts.lua' }
for _, f in ipairs({ 'main', 'schema', 'orders', 'clock', 'records', 'custody', 'booking', 'property', 'bail', 'legacy_import', 'compat',
    'courts', 'warrants', 'supervision', 'monitors', 'community_service', 'restitution', 'api', 'apps' }) do
    JFILES[#JFILES + 1] = '[pfscripts]/pf-justice/server/' .. f .. '.lua'
end
World.start('pf-justice', JFILES, { boot = function(env)
    assert(env.PFJustice.Boot(), 'pf-justice boot')
    env.PFJustice.Custody.LoadOnline()
    env.PFJustice.CS.LoadOnline() -- its start thread: resume online shifts
    Mock.eventHandlers['onResourceStart']('pf-justice')
end })
local function J() return World.env('pf-justice').PFJustice end

local CIT, JUDGE = 1, 2
local DESK = vector3(-544.67, -204.25, 38.22)
local DISTRICT = 'businesses'
Mock.newPlayer(CIT, 'B22CS').PlayerData.money = { cash = 0, bank = 500 }
Mock.newPlayer(JUDGE, 'B22JDG').PlayerData.job = { name = 'judge', grade = { level = 1 }, onduty = true }
for _, src in ipairs({ CIT, JUDGE }) do TriggerEvent('QBCore:Server:PlayerLoaded', Mock.players[src]) end
Mock.coords[CIT] = DESK

local function courtKey(src, scope) return app('court', 'key', src, { scope = scope }).key end
local function order(id) return World.one('SELECT * FROM pf_justice_orders WHERE id = ?', { id }) end
local function backlog() return tonumber(World.one('SELECT maintenance_backlog FROM pf_gov_infra_district_state WHERE district_name = ?', { DISTRICT }).maintenance_backlog) end
local function at(p) Mock.coords[CIT] = vector3(p.x, p.y, p.z) end
local function steps(taskId, upto)
    local e = J().CS.live[taskId]
    for i = e.stepsDone + 1, upto or e.stepsNeeded do
        Mock.clock = Mock.clock + 21
        at(e.points[i])
        World.fireNet('pf-justice:server:CsTaskStep', CIT, taskId, i)
        assert_eq(tonumber(World.one('SELECT steps_done FROM pf_justice_cs_tasks WHERE id = ?', { taskId }).steps_done), i, 'step ' .. i)
    end
end
local function workOnSite(taskId)
    local e = J().CS.live[taskId]
    at(e.site)
    J().CS.Sample(Mock.clock)
    G().WorkOrders.SampleClaims(Mock.clock)
    Mock.clock = Mock.clock + e.minSeconds + 1
    J().CS.Sample(Mock.clock)
    G().WorkOrders.SampleClaims(Mock.clock)
end

local csOrder, workOrderId, before
describe('22A flow 4: community service order -> government work order -> unit -> district improves', function()
    it('the court sentences community service (2 units)', function()
        local f = World.call('pf-policemdt-DEV', 'pf-justice', 'FileCase', { cid = 'B22CS', charges = { { code = 'PC-594', name = 'Vandalism' } },
            mdtCaseId = 601, title = 'Graffiti' }, { key = 'pf-policemdt:case:601:court:1', actor = { kind = 'system', label = 'pf-policemdt' }, filedBy = 'B22COP' })
        assert_true(f.ok, tostring(f.error) .. ' ' .. tostring(f.message))
        assert_true(app('court', 'decide', JUDGE, { key = courtKey(JUDGE, 'decision'), caseId = f.caseId, decision = { kind = 'plea', plea = 'guilty' } }).ok)
        local s = app('court', 'decide', JUDGE, { key = courtKey(JUDGE, 'decision'), caseId = f.caseId,
            decision = { kind = 'sentence', orders = { { kind = 'community_service', units = 2 } } } })
        assert_true(s.ok, tostring(s.error) .. ' ' .. tostring(s.message))
        csOrder = s.orders[1]
        assert_eq(order(csOrder).kind, 'community_service')
        assert_eq(order(csOrder).state, 'assigned')
    end)

    it('the district over its backlog threshold gets a cs-eligible work order from the infrastructure tick', function()
        -- the backlog grew (as the simulation's DOT stages do over time); the next simulation tick reads it
        MySQL.update.await('UPDATE pf_gov_infra_district_state SET maintenance_backlog = 1500 WHERE district_name = ?', { DISTRICT })
        World.restart('pf-government')
        G().RecalculateInfrastructureState()
        local wo = World.one("SELECT * FROM pf_gov_work_orders WHERE district = ? AND status = 'open' AND cs_eligible = 1", { DISTRICT })
        assert_true(wo ~= nil, 'a cs-eligible order in the district')
        workOrderId = tonumber(wo.id)
        before = backlog()
        assert_true(before >= 1500, 'backlog ' .. tostring(before))
    end)

    local taskId
    it('sign in at the City Hall desk, list the work, claim one unit, two steps', function()
        local s = app('community-service', 'startShift', CIT, {})
        assert_true(s.ok, tostring(s.error) .. ' ' .. tostring(s.message))
        assert_eq(order(csOrder).state, 'active')
        local l = app('community-service', 'listWork', CIT, {})
        assert_true(l.ok, tostring(l.error) .. ' ' .. tostring(l.message))
        local found = false
        for _, w in ipairs(l.list) do if w.id == workOrderId then found = true end end
        assert_true(found, 'the district work order is listed near the desk')
        local c = app('community-service', 'claim', CIT, { workOrderId = workOrderId })
        assert_true(c.ok, tostring(c.error) .. ' ' .. tostring(c.message))
        taskId = c.taskId
        steps(taskId, 2)
    end)

    it('pf-justice and pf-government restart mid-task: the steps and the claim are kept', function()
        World.restart('pf-government')
        World.restart('pf-justice')
        local t = World.one('SELECT * FROM pf_justice_cs_tasks WHERE id = ?', { taskId })
        assert_eq(t.state, 'active')
        assert_eq(tonumber(t.steps_done), 2)
        assert_true(J().CS.live[taskId] ~= nil, 'resumed for the online citizen')
        assert_eq(J().CS.live[taskId].stepsDone, 2)
        assert_eq(World.one('SELECT state FROM pf_gov_work_claims WHERE id = ?', { t.claim_id }).state, 'claimed')
        assert_eq(tonumber(World.one('SELECT units_done FROM pf_gov_work_orders WHERE id = ?', { workOrderId }).units_done), 0, 'nothing counted yet')
    end)

    it('the rest of the steps, on site: GOV counts the unit and saves the district once', function()
        steps(taskId)
        workOnSite(taskId)
        -- (the simulation itself moves the backlog every tick, a restart runs one tick: the unit's effect
        -- is measured around the report)
        before = backlog()
        local r = app('community-service', 'complete', CIT, { taskId = taskId })
        assert_true(r.ok, tostring(r.error) .. ' ' .. tostring(r.message))
        assert_eq(tonumber(order(csOrder).units_done), 1)
        local wo = World.one('SELECT * FROM pf_gov_work_orders WHERE id = ?', { workOrderId })
        assert_eq(tonumber(wo.units_done), 1)
        local per = G().WorkOrders.UnitDelta(tonumber(wo.effect_delta), tonumber(wo.units), 1)
        assert_true(per < 0, 'an improvement')
        assert_eq(backlog(), before + per, 'the district row improved by one unit')
        assert_eq(G().GetDistrictInfrastructureState(DISTRICT).maintenance_backlog, before + per)
        -- the same completion again (a lost answer): nothing more
        Mock.clock = Mock.clock + 5
        local again = app('community-service', 'complete', CIT, { taskId = taskId })
        assert_false(again.ok and not again.duplicate, 'never a second unit')
        assert_eq(tonumber(order(csOrder).units_done), 1)
        assert_eq(backlog(), before + per)
        -- restarts after the unit: the district value is read back from its row (then the boot tick drifts it)
        World.restart('pf-government')
        assert_eq(G().GetDistrictInfrastructureState(DISTRICT).maintenance_backlog, backlog())
    end)

    it('the second unit completes the order (conviction once); nobody is paid for community service', function()
        Mock.clock = Mock.clock + 30
        local c = app('community-service', 'claim', CIT, { workOrderId = workOrderId })
        assert_true(c.ok, tostring(c.error) .. ' ' .. tostring(c.message))
        steps(c.taskId)
        workOnSite(c.taskId)
        before = backlog()
        local r = app('community-service', 'complete', CIT, { taskId = c.taskId })
        assert_true(r.ok and r.completed, tostring(r.error) .. ' ' .. tostring(r.message))
        assert_eq(order(csOrder).state, 'completed')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_records WHERE citizenid = 'B22CS' AND kind = 'conviction'"), 1)
        local wo = World.one('SELECT * FROM pf_gov_work_orders WHERE id = ?', { workOrderId })
        assert_eq(tonumber(wo.units_done), 2)
        local d2 = G().WorkOrders.UnitDelta(tonumber(wo.effect_delta), tonumber(wo.units), 2)
        assert_eq(backlog(), before + d2, 'the second unit improved the district')
        assert_eq(World.scalar('SELECT COUNT(*) FROM pf_gov_work_payments WHERE work_order_id = ?', { workOrderId }), 0, 'community service is unpaid')
        assert_eq(Mock.players[CIT].PlayerData.money.bank, 500)
        -- after the order is done the shift is over and further claims are refused
        World.restart('pf-justice')
        local more = app('community-service', 'claim', CIT, { workOrderId = workOrderId })
        assert_false(more.ok, 'no open order left to work on')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_cs_tasks WHERE order_id = ? AND state = 'done'", { csOrder }), 2)
    end)
end)
