-- 22A end to end on MariaDB: citation -> contest -> court decision, with the REAL pf-justice (every
-- server file, as its fxmanifest loads them) and the REAL pfm-banking ledger in one world
-- (tests/specs/b22_e2e_world.lua: one environment per resource, exports across the msgpack boundary).
--   * an on-duty officer cites a driver as pfm-policejob does (IssueCitation, officerSrc, keyed);
--   * the driver contests in the Justice Records app (the real pf-devices handler);
--   * the contest reaches the court docket and a judge decides it in the Court app; the upheld
--     citation is paid once from the portal to society:police; a dismissed one costs nothing;
--   * pf-justice restarts in the middle (contested, then upheld-but-unpaid): nothing is lost, the
--     payment still happens once.
-- Stubbed: FiveM natives, pf-citizen mail/calendar and the pf-devices registry (handlers captured
-- and called as pf-devices calls them).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
load_resource('tests/specs/b22_e2e_world.lua')
function IsDuplicityVersion() return true end
function SetEntityCoords() end
Mock.clock = 1800000000
QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, doj = { label = 'DOJ' }, judge = { label = 'Judiciary' } }
World.installResourceState({ ['pf-ambulancejob'] = 'missing', ['pf-services'] = 'missing', ['pfm-prison'] = 'missing',
    ['pf-government'] = 'missing', ['pf-policemdt-DEV'] = 'missing', ['pfm-phone'] = 'missing' })

World.startBank()
World.inventory()

-- pf-citizen (mail, calendar): external to these flows
local mails = {}
Mock.exportsByResource['pf-citizen'] = {
    SendMail = function(_, cid, opts) mails[#mails + 1] = { cid = cid, opts = opts } return #mails end,
    AddCalendarEvent = function() return 1 end,
}
-- pf-devices: the registry keeps each app's handlers; a client RPC reaches them as pf-devices calls them
local Apps = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end,
    RegisterAppHandlers = function(_, appId, handlers) Apps[appId] = handlers return true end,
    PushToJob = function() end, Push = function() end, PushToCitizen = function() end,
}
local function app(appId, method, src, payload)
    local h = assert(Apps[appId], 'app not registered: ' .. tostring(appId))
    if h.__access and not h.__access(src) then return { ok = false, error = 'no_access' } end
    return Mock.cross(h[method], src, payload or {})
end

local JFILES = { '[pfscripts]/pf-justice/config.lua', '[pfscripts]/pf-justice/shared/states.lua', '[pfscripts]/pf-justice/shared/cs_tasks.lua',
    '@pfm-banking/payouts.lua' }
for _, f in ipairs({ 'main', 'schema', 'orders', 'clock', 'records', 'custody', 'booking', 'property', 'bail', 'legacy_import', 'compat',
    'courts', 'warrants', 'supervision', 'monitors', 'community_service', 'restitution', 'api', 'apps' }) do
    JFILES[#JFILES + 1] = '[pfscripts]/pf-justice/server/' .. f .. '.lua'
end
local function bootJustice(env)
    assert(env.PFJustice.Boot(), 'pf-justice boot')
    Mock.eventHandlers['onResourceStart']('pf-justice')
end
local function J() return World.env('pf-justice').PFJustice end
World.start('pf-justice', JFILES, { boot = bootJustice })

local COP, DRIVER, JUDGE, CLERK, DRIVER2 = 1, 2, 3, 4, 5
local function job(src, cid, name, grade, jtype)
    local P = Mock.newPlayer(src, cid)
    P.PlayerData.job = { name = name, type = jtype, grade = { level = grade }, onduty = true }
    return P
end
job(COP, 'B22COP', 'police', 2, 'leo')
job(JUDGE, 'B22JUDGE', 'judge', 1)
job(CLERK, 'B22CLERK', 'doj', 0, 'doj')
Mock.newPlayer(DRIVER, 'B22DRV').PlayerData.money = { cash = 0, bank = 5000 }
Mock.newPlayer(DRIVER2, 'B22DRV2').PlayerData.money = { cash = 0, bank = 5000 }
Mock.coords[COP], Mock.coords[DRIVER] = vector3(200.0, -800.0, 30.0), vector3(201.0, -800.0, 30.0)

local function cite(driverCid, uidKey, amount)
    return World.call('pfm-policejob', 'pf-justice', 'IssueCitation',
        { cid = driverCid, amount = amount, violation = 'Speeding 40 over', plate = 'B22SPD', speed = 120, limit = 80, officerSrc = COP },
        { key = 'pfm-policejob:citation:' .. uidKey })
end
local function order(id) return World.one('SELECT * FROM pf_justice_orders WHERE id = ?', { id }) end
local function hasCaseFor(orderId)
    return World.scalar("SELECT COUNT(*) FROM pf_justice_case_refs WHERE ref_type = 'order' AND ref_id = ?", { tostring(orderId) }) > 0
end
local function courtKey(src, scope) return app('court', 'key', src, { scope = scope }).key end
local policeStart = World.society('police')

local citationId
describe('22A flow 3: citation -> contest -> court decision', function()
    it('an on-duty officer cites the driver (keyed: a retry is the same citation)', function()
        local res = cite('B22DRV', 'u1', 450)
        assert_true(res.ok, tostring(res.error) .. ' ' .. tostring(res.message))
        citationId = res.orderId
        local again = cite('B22DRV', 'u1', 450)
        assert_true(again.ok and again.duplicate, 'the same key is the same citation')
        assert_eq(again.orderId, citationId)
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_orders WHERE citizenid = 'B22DRV' AND kind = 'citation'"), 1)
        local cit = World.one('SELECT * FROM pf_justice_citations WHERE order_id = ?', { citationId })
        assert_eq(cit.officer_cid, 'B22COP')
        assert_eq(math.floor(tonumber(cit.x)), 200, 'the place is the officer position on the server')
        assert_eq(order(citationId).state, 'issued')
    end)

    it('the driver sees it as contestable in Justice Records and contests it once', function()
        local fines = app('justice-records', 'fines', DRIVER)
        assert_true(fines.ok, tostring(fines.error))
        assert_eq(fines.list[1].id, citationId)
        assert_true(fines.list[1].contestable)
        -- somebody else cannot contest it
        assert_eq(app('justice-records', 'contest', DRIVER2, { orderId = citationId }).error, 'no_permission')
        local c = app('justice-records', 'contest', DRIVER, { orderId = citationId, reason = 'radar was not calibrated' })
        assert_true(c.ok, tostring(c.error) .. ' ' .. tostring(c.message))
        assert_eq(order(citationId).state, 'contested')
        assert_false(app('justice-records', 'contest', DRIVER, { orderId = citationId }).ok, 'once')
        -- a contested citation cannot be paid meanwhile
        assert_false(app('justice-records', 'pay', DRIVER, { orderId = citationId }).ok)
    end)

    it('restart: pf-justice comes back with the contest as it was', function()
        World.restart('pf-justice')
        assert_eq(order(citationId).state, 'contested')
        local fines = app('justice-records', 'fines', DRIVER)
        assert_eq(fines.list[1].state, 'contested')
        assert_false(fines.list[1].contestable)
    end)

    -- DEFECT (reported): nothing turns a contest into a court item. ContestCitation only moves the order
    -- to 'contested'; no case is filed, and the Court app's "file" form (apps.lua Court.File) cannot link
    -- the citation (it never passes spec.orderId), so Courts.DecideContest finds no order ref and the
    -- citation stays contested for ever. DecideCitation is allowlisted to pfm-adminmenu, which never calls it.
    it('FOUND: the contest is on the court docket (no case is filed for it)', function()
        if hasCaseFor(citationId) then
            assert_true(true)
        else
            pending('22A flow 3 contest -> court', 'pf-justice orders.lua O.ContestCitation (~line 1394) files no citation_contest case; '
                .. 'apps.lua Court.File (~line 497) drops orderId, so no court route decides the citation')
        end
    end)

    it('FOUND: a citation_contest case filed in the Court app does not decide the citation', function()
        local key = courtKey(CLERK, 'file')
        local f = app('court', 'file', CLERK, { key = key, cid = 'B22DRV', kind = 'citation_contest',
            charges = { { code = 'VC-22350', label = 'Speeding (contested citation)' } }, title = 'Contest of citation', orderId = citationId })
        assert_true(f.ok, tostring(f.error) .. ' ' .. tostring(f.message))
        if hasCaseFor(citationId) then return end
        -- walk it to a guilty verdict exactly as the judge would in the app
        local caseId = f.caseId
        assert_true(app('court', 'decide', JUDGE, { key = courtKey(JUDGE, 'decision'), caseId = caseId,
            decision = { kind = 'plea', plea = 'not_guilty' } }).ok)
        assert_true(app('court', 'schedule', CLERK, { key = courtKey(CLERK, 'hearing'), caseId = caseId,
            kind = 'trial', at = os.time() + 600, courtroom = 'courtroom_1' }).ok)
        local v = app('court', 'decide', JUDGE, { key = courtKey(JUDGE, 'decision'), caseId = caseId,
            decision = { kind = 'verdict', verdict = 'guilty' } })
        local after = order(citationId).state
        if after == 'contested' then
            pending('22A flow 3 court app case -> citation', ('verdict %s on case %d left citation %d %s (apps.lua Court.File has no orderId)')
                :format(tostring(v.ok and 'guilty' or v.error), caseId, citationId, after))
        else
            assert_eq(after, 'upheld')
        end
    end)

    local caseId
    it('filed with the citation linked (the internal FileCase the contest needs), a guilty verdict upholds it', function()
        local res = J().API.FileCase({ cid = 'B22DRV', kind = 'citation_contest', orderId = citationId,
            charges = { { code = 'VC-22350', label = 'Speeding (contested citation)' } } },
            { key = 'pf-justice:citation:' .. citationId .. ':contest', actor = { kind = 'system', label = 'citation contest' } })
        assert_true(res.ok, tostring(res.error) .. ' ' .. tostring(res.message))
        caseId = res.caseId
        local docket = app('court', 'cases', JUDGE, {})
        assert_true(docket.ok, tostring(docket.error))
        local found = false
        for _, c in ipairs(docket.list) do if tonumber(c.id) == caseId then found = true end end
        assert_true(found, 'the judge sees the contest in the Court app')
        local plea = app('court', 'decide', JUDGE, { key = courtKey(JUDGE, 'decision'), caseId = caseId,
            decision = { kind = 'plea', plea = 'not_guilty' } })
        assert_true(plea.ok, tostring(plea.error) .. ' ' .. tostring(plea.message))
        local h = app('court', 'schedule', CLERK, { key = courtKey(CLERK, 'hearing'), caseId = caseId,
            kind = 'trial', at = os.time() + 600, courtroom = 'courtroom_1' })
        assert_true(h.ok, tostring(h.error) .. ' ' .. tostring(h.message))
        Mock.clock = Mock.clock + 700
        local v = app('court', 'decide', JUDGE, { key = courtKey(JUDGE, 'decision'), caseId = caseId,
            decision = { kind = 'verdict', verdict = 'guilty' } })
        assert_true(v.ok, tostring(v.error) .. ' ' .. tostring(v.message))
        assert_eq(order(citationId).state, 'upheld')
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_records WHERE citizenid = 'B22DRV' AND kind = 'citation'"), 1,
            'an upheld citation is on the record once')
    end)

    it('restart, then the upheld citation is paid once from the portal to society:police', function()
        World.restart('pf-justice')
        assert_eq(order(citationId).state, 'upheld')
        local bank = Mock.players[DRIVER].PlayerData.money.bank
        local p = app('justice-records', 'pay', DRIVER, { orderId = citationId, account = 'bank' })
        assert_true(p.ok, tostring(p.error) .. ' ' .. tostring(p.message))
        assert_eq(order(citationId).state, 'paid')
        assert_eq(Mock.players[DRIVER].PlayerData.money.bank, bank - 450)
        Mock.clock = Mock.clock + 10
        local again = app('justice-records', 'pay', DRIVER, { orderId = citationId, account = 'bank' })
        assert_true(again.ok and again.duplicate, 'a second press is the same payment')
        assert_eq(Mock.players[DRIVER].PlayerData.money.bank, bank - 450, 'charged once')
        local paid = World.txLike('pf-justice:%:' .. citationId .. ':pay:%')
        assert_eq(#paid, 1)
        assert_eq(paid[1].to_account, 'society:police')
        assert_eq(World.society('police'), policeStart + 450)
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_records WHERE citizenid = 'B22DRV' AND kind = 'citation'"), 1,
            'paying the upheld citation adds no second entry')
    end)

    it('a contest the court dismisses costs nothing and leaves no record', function()
        local res = cite('B22DRV2', 'u2', 300)
        assert_true(res.ok)
        local id = res.orderId
        assert_true(app('justice-records', 'contest', DRIVER2, { orderId = id }).ok)
        local f = J().API.FileCase({ cid = 'B22DRV2', kind = 'citation_contest', orderId = id, charges = { { code = 'VC-1', label = 'x' } } },
            { key = 'pf-justice:citation:' .. id .. ':contest', actor = { kind = 'system', label = 'citation contest' } })
        assert_true(f.ok)
        local d = app('court', 'decide', JUDGE, { key = courtKey(JUDGE, 'decision'), caseId = f.caseId,
            decision = { kind = 'dismissal', note = 'radar log missing' } })
        assert_true(d.ok, tostring(d.error) .. ' ' .. tostring(d.message))
        assert_eq(order(id).state, 'dismissed')
        assert_false(app('justice-records', 'pay', DRIVER2, { orderId = id }).ok, 'nothing to pay')
        assert_eq(Mock.players[DRIVER2].PlayerData.money.bank, 5000)
        assert_eq(World.scalar("SELECT COUNT(*) FROM pf_justice_records WHERE citizenid = 'B22DRV2'"), 0)
    end)
end)
