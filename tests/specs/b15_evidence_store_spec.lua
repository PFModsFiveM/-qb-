-- pfm-policejob evidence records (batch 15, unit 15D): attrs are cleaned per kind, actors are read on
-- the server, exports check their caller allowlist, ListEvidence pages at most 100 rows, the bag
-- carries no identity, and the resource has one schema file that kept /fine's v1 and that the
-- fine sweep waits for.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pfm-policejob' end
function GetResourceState() return 'missing' end
local migrationRuns = {}
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, key, list) migrationRuns[#migrationRuns + 1] = { key = key, list = list } return true end
Mock.exportsByResource['pfm-inventory'] = { AddItem = function() return true end, RemoveItem = function() return true end }

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
local E, Store, A = PFEvidence, PFEvidence.Store, PFEvidence.Api

local COP, CIV = 1, 2

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    Mock.invokingResource = nil
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 3 } }
    Mock.newPlayer(CIV, 'CIVCID')
end

describe('schema', function()
    it('is one list under the resource key, v1 the unchanged fine table, v2 the evidence tables', function()
        local S = PFPoliceSchema
        assert_eq(S.Migrations[1].version, 1)
        assert_eq(S.Migrations[1].name, 'police fine records')
        assert_true(S.Migrations[1].up[1]:find('CREATE TABLE IF NOT EXISTS `pfm_police_fines`', 1, true) ~= nil)
        assert_eq(S.Migrations[2].version, 2)
        local v2 = table.concat(S.Migrations[2].up, '\n')
        for _, t in ipairs({ 'pf_evidence_items', 'pf_evidence_custody', 'pf_evidence_scene_drops', 'pf_evidence_lockers' }) do
            assert_true(v2:find('CREATE TABLE IF NOT EXISTS `' .. t .. '`', 1, true) ~= nil, t)
        end
        assert_eq(PFPoliceFines.Migrations, nil, 'fines.lua no longer has its own list')
        migrationRuns = {}
        S.state = 'idle'
        assert_true(S.Run())
        assert_true(S.Run())
        assert_eq(#migrationRuns, 1, 'applied once per start')
        assert_eq(migrationRuns[1].key, 'pfm-policejob')
        assert_true(PFPoliceFines.Migrate(), 'the old name forwards to the schema')
        assert_eq(#migrationRuns, 1)
        assert_true(S.WaitReady(0))
    end)
    it('a failed run is reported and the modules stay off', function()
        local real = Mock.exportsByResource['pfm-core'].RunMigrations
        Mock.exportsByResource['pfm-core'].RunMigrations = function() return false, 'boom' end
        PFPoliceSchema.state = 'idle'
        assert_false(PFPoliceSchema.Run())
        assert_false(E.DbReady())
        assert_eq(A.GetEvidence(1, {}).error, 'db_unavailable')
        assert_false(PFPoliceSchema.WaitReady(0))
        Mock.exportsByResource['pfm-core'].RunMigrations = real
        PFPoliceSchema.state = 'idle'
        assert_true(PFPoliceSchema.Run())
    end)
end)

describe('attrs', function()
    it('keep only the kind\'s fields, checked and clipped', function()
        local a = Store.CleanAttrs('casing', { caliber = ('x'):rep(80), weaponHash = '123', serial = 'S1', citizenid = 'LEAK', clientReported = true })
        assert_eq(#a.caliber, 32)
        assert_eq(a.weaponHash, 123)
        assert_eq(a.citizenid, nil)
        assert_true(a.clientReported)
        assert_eq(Store.CleanAttrs('nonsense', {}), nil)
        assert_eq(Store.CleanAttrs('blood', 'text'), nil)
        local d = Store.CleanAttrs('document', { title = 'Note', body = ('y'):rep(2500) })
        assert_eq(#d.body, 2000)
    end)
    it('photos need an allowed https host and are always marked client-supplied', function()
        local p = Store.CleanAttrs('photo', { url = 'https://i.imgur.com/abc.png', clientSupplied = false })
        assert_eq(p.url, 'https://i.imgur.com/abc.png')
        assert_true(p.clientSupplied)
        assert_eq(Store.CleanAttrs('photo', { url = 'http://i.imgur.com/abc.png' }), nil)
        assert_eq(Store.CleanAttrs('photo', { url = 'https://i.imgur.com.evil.com/a.png' }), nil)
        assert_eq(Store.CleanAttrs('photo', { url = 'javascript:alert(1)' }), nil)
    end)
    it('plates are normalised', function()
        assert_eq(Store.CleanAttrs('vehicle', { plate = ' ab-12 3 ' }).plate, 'AB12 3')
        assert_eq(Store.CleanAttrs('vehicle', { plate = '123456789' }), nil)
    end)
end)

describe('the bag', function()
    it('shows a sample id for blood and the print id for prints, never a citizenid', function()
        local blood = Store.BagInfo({ id = 4, tag = 'EV-2026-000004', kind = 'blood', label = 'Blood sample', sealed = true,
            attrs = json.encode({ sampleId = 'S-ABCDEF12', bloodtype = 'O+' }), scene_label = 'Main St' })
        assert_eq(blood.evidenceId, 4)
        assert_eq(blood.dnalabel, 'S-ABCDEF12')
        assert_eq(blood.street, 'Main St')
        assert_true(blood.sealed)
        assert_eq(blood.serie, nil, 'no weapon-serial key on a bag')
        local print = Store.BagInfo({ id = 5, tag = 'EV-2026-000005', kind = 'fingerprint', label = 'Print', sealed = false, attrs = json.encode({ printId = 'FP-1' }) })
        assert_eq(print.fingerprint, 'FP-1')
        assert_true(print.description:find('seal broken', 1, true) ~= nil)
    end)
    it('uses the new evidence_bag once it exists, the legacy bag before', function()
        E.sharedItems = {}
        assert_eq(Store.BagItemName(), 'filled_evidence_bag')
        E.sharedItems = { evidence_bag = { name = 'evidence_bag' } }
        assert_eq(Store.BagItemName(), 'evidence_bag')
        assert_true(Store.IsBag({ name = 'filled_evidence_bag', info = { evidenceId = 3 } }))
        assert_false(Store.IsBag({ name = 'filled_evidence_bag', info = { type = 'blood' } }))
        assert_false(Store.IsBag({ name = 'sandwich', info = { evidenceId = 3 } }))
    end)
    it('the glove rule only applies once the glove item exists', function()
        E.sharedItems = {}
        assert_false(Store.GloveRuleActive())
        E.sharedItems = { nitrile_gloves = { name = 'nitrile_gloves' } }
        assert_true(Store.GloveRuleActive())
        assert_false(Store.HasGloves(Mock.players[COP]))
        Mock.players[COP].PlayerData.items = { [2] = { name = 'nitrile_gloves', amount = 1, slot = 2 } }
        assert_true(Store.HasGloves(Mock.players[COP]))
    end)
end)

describe('evidence drawers', function()
    it('are recognised from the locale\'s drawer phrase, not only the English one', function()
        local realLang = Lang
        Lang = { t = function(_, key, p)
            if key == 'info.current_evidence' then return ('%s | Lade %s'):format(p.value, p.value2) end
            return key
        end }
        Store.drawerPatterns = nil
        local station, drawer = Store.DrawerOf('2 | Lade 14')
        assert_eq(station, 2)
        assert_eq(drawer, 14)
        assert_eq(Store.DrawerOf('1 | Drawer 3'), 1, 'English ids made before a locale change still count')
        assert_eq(Store.DrawerOf('9 | Lade 1'), nil, 'no such station')
        assert_eq(Store.DrawerOf('policestash_ABC'), nil)
        assert_true(Store.IsLockerStash('3 | Lade 2'))
        local at = Store.LockerLocation('3 | Lade 2')
        assert_eq(at.x, Config.Locations['evidence'][3].x)
        Lang = { t = function(_, key, p)
            if key == 'info.current_evidence' then return ('Gaveta (%s) %s'):format(p.value2, p.value) end
            return key
        end }
        Store.drawerPatterns = nil
        assert_eq(Store.DrawerOf('Gaveta (5) 1'), 1, 'any order and pattern characters')
        Config.Evidence.DrawerPatterns = { '^evlocker_(%d+)_(%d+)$' }
        Store.drawerPatterns = nil
        assert_eq(Store.DrawerOf('evlocker_2_8'), 2, 'operator patterns')
        Config.Evidence.DrawerPatterns = {}
        Lang = realLang
        Store.drawerPatterns = nil
    end)
    it('any stash with a locker row counts as a locker after start', function()
        E.lockerStashes = {}
        assert_false(Store.IsLockerStash('case_locker_12'))
        local realQuery = Store.Query
        Store.Query = function() return { { stash_id = 'case_locker_12' } }, true end
        Store.LoadLockers()
        Store.Query = realQuery
        assert_true(Store.IsLockerStash('case_locker_12'))
    end)
end)

describe('actors', function()
    it('job, grade and duty come from the server, not from opts.actor', function()
        local a = E.Actor({ src = CIV, job = 'police', leo = true, supervisor = true })
        assert_eq(a.job, 'unemployed')
        assert_false(a.leo)
        assert_false(a.supervisor)
        local cop = E.Actor({ src = COP })
        assert_true(cop.leo and cop.supervisor)
        assert_eq(cop.cid, 'COPCID')
        local _, err = E.Actor({ src = 77 })
        assert_eq(err, 'offline')
        _, err = E.Actor({ src = CIV, kind = 'admin' })
        assert_eq(err, 'no_permission')
        Mock.aces[CIV] = { admin = true }
        assert_true(E.Actor({ src = CIV, kind = 'admin' }).admin)
        _, err = E.Actor('me')
        assert_eq(err, 'bad_args')
    end)
end)

describe('exports', function()
    it('refuse resources that are not on the list, once a minute in the console', function()
        Mock.invokingResource = 'random-script'
        for _, name in ipairs({ 'CreateEvidence', 'GetEvidence', 'ListEvidence', 'TransferEvidence', 'SealEvidence', 'BreakSeal', 'LinkEvidence', 'UnlinkEvidence', 'DisposeEvidence' }) do
            assert_eq(Mock.selfExport(name)(1, {}, {}).error, 'not_allowed', name)
        end
        Mock.invokingResource = 'pf-policemdt-DEV'
        assert_eq(Mock.selfExport('SealEvidence')(1, {}).error, 'not_allowed', 'sealing is PJ only')
        assert_true(Mock.selfExport('GetEvidence')(1, {}).error ~= 'not_allowed')
    end)
    it('callers from other resources must pass an idempotency key', function()
        Mock.invokingResource = 'pf-justice'
        local res = Mock.selfExport('CreateEvidence')({ kind = 'item', attrs = { item = 'phone' } }, { giveTo = 'stash:x' })
        assert_eq(res.error, 'bad_args')
        res = Mock.selfExport('CreateEvidence')({ kind = 'item' }, { key = 'bad key with spaces' })
        assert_eq(res.error, 'bad_args')
    end)
    it('GetEvidence and ListEvidence are for on-duty police viewers', function()
        assert_eq(A.GetEvidence(1, { viewer = CIV }).error, 'no_permission')
        assert_eq(A.ListEvidence({ viewer = CIV }).error, 'no_permission')
        assert_eq(A.GetEvidence({}, {}).error, 'bad_args')
    end)
    it('players acting must be on-duty police', function()
        assert_eq(A.TransferEvidence(1, { kind = 'lab' }, { actor = { src = CIV } }).error, 'no_permission')
        assert_eq(A.CreateEvidence({ kind = 'vehicle', attrs = { plate = 'AB1' } }, { actor = { src = CIV } }).error, 'no_permission')
        assert_eq(A.DisposeEvidence(1, 'destroy', { actor = { src = COP } }).error, 'bad_args', 'a court order id is required')
        assert_eq(A.DisposeEvidence(1, 'burn', { courtOrderId = 'CO1', actor = { src = COP } }).error, 'bad_args')
        assert_eq(A.TransferEvidence(1, { kind = 'moon' }, { actor = { src = COP } }).error, 'bad_args')
        assert_eq(A.LinkEvidence(1, { type = 'case', id = 'has space' }, { actor = { src = COP } }).error, 'bad_args')
    end)
end)

describe('CreateEvidence specs', function()
    local system = { kind = 'system', label = 'test' }
    it('physical evidence needs somewhere to go; records do not', function()
        local f, give, code = A.BuildSpec({ kind = 'weapon', attrs = { item = 'weapon_pistol', serial = 'X1' } }, {}, system)
        assert_eq(f, nil)
        assert_eq(code, 'bad_args')
        f, give = A.BuildSpec({ kind = 'weapon', attrs = { item = 'weapon_pistol' } }, { giveTo = 'stash:locker_1' }, system)
        assert_eq(give.inv, 'locker_1')
        assert_eq(f.holder_ref, 'inv:locker_1')
        assert_eq(f.state, 'sealed')
        f, give = A.BuildSpec({ kind = 'vehicle', attrs = { plate = 'AB1' }, sealed = false }, {}, system)
        assert_eq(give, nil)
        assert_eq(f.holder_kind, 'record')
        assert_eq(f.state, 'collected')
    end)
    it('a collector must be on-duty police and gives the bag to them; bad refs are refused', function()
        local _, _, code = A.BuildSpec({ kind = 'drug', attrs = { item = 'meth', amount = 2 }, collectedBy = CIV }, {}, system)
        assert_eq(code, 'no_permission')
        local f, give = A.BuildSpec({ kind = 'drug', attrs = { item = 'meth', amount = 2 }, collectedBy = COP, caseRef = { type = 'case', id = 'C-1' } }, {}, system)
        assert_eq(give.inv, COP)
        assert_eq(f.collected_by, 'COPCID')
        assert_eq(f.case_refs[1], 'case:C-1')
        _, _, code = A.BuildSpec({ kind = 'drug', collectedBy = COP, caseRef = { type = 'case', id = 'x y' } }, {}, system)
        assert_eq(code, 'bad_args')
        _, _, code = A.BuildSpec({ kind = 'drug', collectedBy = COP, method = 'magic' }, {}, system)
        assert_eq(code, 'bad_args')
        _, _, code = A.BuildSpec({ kind = 'drug', collectedBy = COP, scene = { coords = { x = 'a' } } }, {}, system)
        assert_eq(code, 'bad_args')
        _, _, code = A.BuildSpec({ kind = 'drug' }, { giveTo = 'stash:bad"name' }, system)
        assert_eq(code, 'bad_args')
    end)
end)

describe('ListEvidence query', function()
    it('pages at most 100 rows, newest first, with a cursor', function()
        local sql, params, limit = A.ListQuery({ limit = 5000 })
        assert_eq(limit, 100)
        assert_eq(params[#params], 101)
        assert_true(sql:find('ORDER BY id DESC LIMIT ?', 1, true) ~= nil)
        _, params, limit = A.ListQuery({})
        assert_eq(limit, 25)
        sql, params = A.ListQuery({ after = 40, state = 'stored', kind = 'blood', holder = { kind = 'locker' } })
        assert_true(sql:find('id < ?', 1, true) ~= nil)
        assert_eq(params[1], 'locker')
    end)
    it('case filters escape LIKE wildcards; unknown filters are refused', function()
        local _, params = A.ListQuery({ caseRef = { type = 'case', id = 'A_1' } })
        assert_eq(params[1], '%"case:A!_1"%')
        assert_eq(A.ListQuery({ state = 'lost' }), nil)
        assert_eq(A.ListQuery({ kind = 'ufo' }), nil)
        assert_eq(A.ListQuery({ after = 'x' }), nil)
        assert_eq(A.ListQuery({ caseRef = { type = 'nope', id = '1' } }), nil)
    end)
end)

describe('player hooks', function()
    it('forget what they kept about a player who left', function()
        E.Rate('7:drop:blood', 5, 5)
        PFEvidence.Scene.lastCell[7] = '0:0'
        PFEvidence.Custody.viewers[8] = 7
        A.OnPlayerDropped(7)
        assert_eq(PFEvidence.Scene.lastCell[7], nil)
        assert_eq(PFEvidence.Custody.viewers[8], nil)
    end)
end)
