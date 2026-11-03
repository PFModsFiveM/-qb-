-- pfm-policejob scene drops (batch 15, unit 15D): reports are rate limited per player and type,
-- capped per cell, placed by the server, sent only to on-duty police within 150 m (never -1),
-- written by one multi-row insert, given to officers as snapshots when they move or go on duty,
-- decayed into 'unrecoverable' rows, and the legacy net events forward to the module.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pfm-policejob' end
local started = {}
function GetResourceState(name) return started[name] and 'started' or 'missing' end
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end
local added, removed = {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    AddListener = function() return 1 end,
    AddItem = function(_, src, name, amount, slot, info) added[#added + 1] = { src = src, name = name, info = info } return true end,
    RemoveItem = function(_, src, name) removed[#removed + 1] = { src = src, name = name } return true end,
    GetInventory = function() return nil end,
}
local PISTOL = GetHashKey('weapon_pistol')
QBCoreMock.Shared.Weapons[PISTOL] = { name = 'weapon_pistol', label = 'Pistol', ammotype = 'AMMO_PISTOL' }
QBCoreMock.Shared.Items.evidence_bag = { name = 'evidence_bag', label = 'Evidence Bag', unique = true }
local seenWeapon = 0
function GetSelectedPedWeapon() return seenWeapon end

QBCore = Mock.coreObject()
Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/config_evidence.lua')
load_resource('pfm-policejob/server/schema.lua')
load_resource('pfm-policejob/server/evidence/store.lua')
load_resource('pfm-policejob/server/evidence/custody.lua')
load_resource('pfm-policejob/server/evidence/scene.lua')
load_resource('pfm-policejob/server/evidence/api.lua')
load_resource('pfm-policejob/server/evidence.lua')
local E, S, A = PFEvidence, PFEvidence.Scene, PFEvidence.Api
assert_true(PFPoliceSchema.Run())
assert_true(A.Start())

local COP, CIV, FARCOP, OFFCOP = 1, 2, 3, 4

local function sqlCalls(fragment)
    local out = {}
    for _, c in ipairs(Mock.dbCalls) do
        if c.query:find(fragment, 1, true) then out[#out + 1] = c end
    end
    return out
end
local function targetsOf(name)
    local t = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do t[e.target] = (t[e.target] or 0) + 1 end
    return t
end
local function resetScene()
    S.drops, S.cells, S.cellCount, S.live, S.pending, S.lastCell = {}, {}, {}, 0, {}, {}
end
local function cop(src, cid, onduty, at)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'police', type = 'leo', onduty = onduty, grade = { level = 1 } }
    Mock.coords[src] = at
    return p
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000
    added, removed, seenWeapon = {}, {}, 0
    resetScene()
    Config.Evidence.Scene.MaxPerCell = 200
    cop(COP, 'COPCID', true, vector3(0, 0, 0))
    cop(FARCOP, 'FARCID', true, vector3(400, 0, 0))
    cop(OFFCOP, 'OFFCID', false, vector3(1, 0, 0))
    local civ = Mock.newPlayer(CIV, 'CIVCID')
    civ.PlayerData.metadata.bloodtype = 'A+'
    civ.PlayerData.metadata.fingerprint = 'FP-CIV'
    civ.PlayerData.items = { [3] = { name = 'weapon_pistol', slot = 3, amount = 1, info = { serie = 'SER123' } } }
    Mock.coords[CIV] = vector3(2, 0, 0)
end

describe('who is told about a drop', function()
    it('only on-duty police within 150 m, never everyone', function()
        assert_true(S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) }) ~= nil)
        local t = targetsOf('evidence:client:AddBlooddrop')
        assert_eq(t[COP], 1)
        assert_eq(t[FARCOP], nil)
        assert_eq(t[OFFCOP], nil)
        assert_eq(t[CIV], nil)
        assert_eq(t[-1], nil)
    end)
    it('clients get a random sample id, never the citizenid or its hex', function()
        S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) })
        local args = Mock.clientEventsNamed('evidence:client:AddBlooddrop')[1].args
        local label = tostring(args[2])
        assert_true(label:match('^S%-%x%x%x%x%x%x%x%x$') ~= nil, label)
        assert_eq(args[3], nil, 'no blood type before the bag')
        local hex = (('CIVCID'):gsub('.', function(c) return ('%02x'):format(c:byte()) end))
        for _, a in pairs(args) do
            assert_true(tostring(a):find('CIVCID', 1, true) == nil and tostring(a):find(hex, 1, true) == nil)
        end
    end)
    it('an officer moving into another area gets a snapshot; off duty gets an empty one', function()
        local drop = S.Report(CIV, 'fingerprint', { coords = vector3(2, 0, 0) })
        Mock.reset()
        S.SyncTick()
        local snaps = Mock.clientEventsNamed('evidence:client:SceneSnapshot')
        assert_eq(#snaps, 2, 'both on-duty officers get a first snapshot')
        local mine
        for _, e in ipairs(snaps) do if e.target == COP then mine = e.args[1] end end
        assert_eq(#mine, 1)
        assert_eq(mine[1].id, drop.id)
        assert_eq(mine[1].label, nil, 'a print shows no id on the ground')
        Mock.reset()
        S.SyncTick()
        assert_eq(#Mock.clientEventsNamed('evidence:client:SceneSnapshot'), 0, 'nothing new while they stay')
        Mock.coords[FARCOP] = vector3(10, 0, 0)
        S.SyncTick()
        local again = Mock.clientEventsNamed('evidence:client:SceneSnapshot')
        assert_eq(#again, 1)
        assert_eq(again[1].target, FARCOP)
        assert_eq(#again[1].args[1], 1)
        Mock.reset()
        Mock.players[FARCOP].PlayerData.job.onduty = false
        S.SyncTick()
        local cleared = Mock.clientEventsNamed('evidence:client:SceneSnapshot')
        assert_eq(#cleared, 1)
        assert_eq(#cleared[1].args[1], 0)
        Mock.reset()
        A.OnDutyChanged(OFFCOP, false)
        assert_eq(#Mock.clientEventsNamed('evidence:client:SceneSnapshot'), 0)
        Mock.players[OFFCOP].PlayerData.job.onduty = true
        A.OnDutyChanged(OFFCOP, true)
        assert_eq(Mock.clientEventsNamed('evidence:client:SceneSnapshot')[1].target, OFFCOP)
    end)
end)

describe('limits', function()
    it('5 reports per second per type, then refused until time passes', function()
        for i = 1, 5 do assert_true(S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) }) ~= nil, 'report ' .. i) end
        local drop, why = S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) })
        assert_eq(drop, nil)
        assert_eq(why, 'rate_limited')
        assert_true(S.Report(CIV, 'fingerprint', { coords = vector3(2, 0, 0) }) ~= nil, 'another type has its own budget')
        Mock.gameTimer = Mock.gameTimer + 1000
        assert_true(S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) }) ~= nil)
    end)
    it('a full cell refuses more drops', function()
        Config.Evidence.Scene.MaxPerCell = 3
        for _ = 1, 3 do S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) }) end
        local drop, why = S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) })
        assert_eq(drop, nil)
        assert_eq(why, 'conflict')
    end)
    it('the position is the server\'s: far hints are refused, near ones snap to the ped', function()
        local drop, why = S.Report(CIV, 'blood', { coords = vector3(40, 0, 0) })
        assert_eq(drop, nil)
        assert_eq(why, 'too_far')
        drop = S.Report(CIV, 'blood', { coords = vector3(8, 0, 0) })
        assert_eq(drop.x, 2)
        drop = S.Report(CIV, 'blood', { coords = vector3(3.5, 0, 0) })
        assert_eq(drop.x, 3.5)
        assert_eq(S.Report(CIV, 'blood', { coords = 'nope' }), nil)
    end)
end)

describe('casings', function()
    it('need a known weapon, the one in hand, and take the serial from the server inventory', function()
        assert_eq(S.Report(CIV, 'casing', { weapon = 12345, coords = vector3(2, 0, 0) }), nil)
        seenWeapon = GetHashKey('weapon_smg')
        local drop, why = S.Report(CIV, 'casing', { weapon = PISTOL, coords = vector3(2, 0, 0) })
        assert_eq(drop, nil)
        assert_eq(why, 'bad_args')
        seenWeapon = PISTOL
        drop = S.Report(CIV, 'casing', { weapon = PISTOL, coords = vector3(2, 0, 0) })
        assert_eq(drop.attrs.serial, 'SER123')
        assert_eq(drop.attrs.caliber, Config.AmmoLabels['AMMO_PISTOL'])
        assert_true(drop.attrs.clientReported)
        local args = Mock.clientEventsNamed('evidence:client:AddCasing')[1].args
        assert_eq(args[2], PISTOL)
        assert_eq(args[4], nil, 'the serial is shown on the bag only')
    end)
end)

describe('persistence', function()
    it('new drops go to the database in one INSERT IGNORE with their ids', function()
        local a = S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) })
        local b = S.Report(CIV, 'fingerprint', { coords = vector3(2, 0, 0) })
        Mock.reset()
        assert_eq(S.Flush(), 2)
        local ins = sqlCalls('INSERT IGNORE INTO pf_evidence_scene_drops')
        assert_eq(#ins, 1)
        assert_eq(ins[1].params[1], a.id)
        assert_eq(ins[1].params[11], b.id)
        assert_eq(ins[1].params[8], 'CIVCID', 'the source is kept on the server')
        assert_true(a.persisted and b.persisted)
        assert_eq(S.Flush(), 0)
    end)
    it('decay marks rows unrecoverable and deletes nothing', function()
        local d = S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) })
        Mock.reset()
        assert_eq(S.Decay(d.decayAt), 1)
        assert_eq(#sqlCalls("SET state = 'unrecoverable'"), 1)
        assert_eq(#sqlCalls('DELETE'), 0)
        assert_eq(targetsOf('evidence:client:RemoveBlooddrop')[COP], 1)
        assert_eq(S.drops[d.id], nil)
    end)
    it('the daily retention sweep deletes only old unrecoverable or cleared rows', function()
        Mock.reset()
        S.SweepRetention(Mock.clock)
        local del = sqlCalls('DELETE FROM pf_evidence_scene_drops')
        assert_eq(#del, 1)
        assert_true(del[1].query:find("state IN ('unrecoverable', 'cleared')", 1, true) ~= nil)
        assert_eq(del[1].params[1], Mock.clock - 30 * 86400)
    end)
end)

describe('legacy net events', function()
    it('CreateBloodDrop ignores the client\'s citizenid and blood type', function()
        Mock.fireNet('evidence:server:CreateBloodDrop', CIV, 'SOMEONEELSE', 'AB-', vector3(2, 0, 0))
        local id = Mock.clientEventsNamed('evidence:client:AddBlooddrop')[1].args[1]
        assert_eq(S.drops[id].sourceCid, 'CIVCID')
        assert_eq(S.drops[id].attrs.bloodtype, 'A+')
    end)
    it('CreateFingerDrop far from the sender is ignored', function()
        Mock.fireNet('evidence:server:CreateFingerDrop', CIV, vector3(3000, 0, 0))
        assert_eq(#Mock.clientEventsNamed('evidence:client:AddFingerPrint'), 0)
    end)
    it('only on-duty police bag or clear, and only next to the drop', function()
        Mock.fireNet('evidence:server:CreateCasing', CIV, PISTOL, vector3(2, 0, 0))
        local id = Mock.clientEventsNamed('evidence:client:AddCasing')[1].args[1]
        Mock.fireNet('evidence:server:AddCasingToInventory', CIV, id, {})
        Mock.fireNet('evidence:server:AddCasingToInventory', FARCOP, id, {})
        assert_eq(#removed, 0)
        Mock.fireNet('evidence:server:ClearCasings', CIV, { id })
        Mock.fireNet('evidence:server:ClearCasings', FARCOP, { id })
        assert_true(S.drops[id] ~= nil)
        Mock.fireNet('evidence:server:ClearCasings', COP, { id, 'junk', -1 })
        assert_eq(S.drops[id], nil)
        assert_eq(targetsOf('evidence:client:RemoveCasing')[-1], nil)
    end)
    it('clearing is rate limited', function()
        local a = S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) })
        local b = S.Report(CIV, 'blood', { coords = vector3(2, 0, 0) })
        assert_eq(S.Clear(COP, 'blood', { a.id }), 1)
        assert_eq(S.Clear(COP, 'blood', { b.id }), 0)
        assert_true(S.drops[b.id] ~= nil)
    end)
end)
