-- Batch 16 (16D): field jail through pf-justice (pfm-policejob server/interactions.lua, commands.lua).
-- After the hand-over (pf-justice Config.Compat.LegacyRuntimes.policejob = false):
--   * police:server:JailPlayer needs the suspect cuffed or at a booking desk (owner decision D3),
--     opens a pf-justice custody and creates a 'jail' order keyed pfm-policejob:jail:<custodyId>;
--     pfm-prison is not asked, the cuffs come off only once the order exists, and nothing writes
--     metadata.criminalrecord (pf-justice does);
--   * the one /unjail ends the orders through ReleaseNow (on-duty officer or admin);
--   * before the hand-over pfm-prison's JailPlayer still jails, as before.
-- pf-justice is a contract stub (its specs cover it).
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
local Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
local states = { ['pf-justice'] = 'started', ['pfm-prison'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end
Mock.exportsByResource['pfm-inventory'] = { OpenInventoryById = function() return true end, AddItem = function() return true end, RemoveItem = function() return true end }
local prisonJailed = {}
Mock.exportsByResource['pfm-prison'] = {
    JailPlayer = function(_, src, minutes) prisonJailed[#prisonJailed + 1] = { src = src, minutes = minutes } return true end,
    ReleasePlayer = function() return true end,
}
local bags = {}
function Player(src)
    bags[src] = bags[src] or { state = { set = function(self, k, v) self[k] = v end } }
    return bags[src]
end

local JU
local function resetJU() JU = { calls = {}, incarcerated = false, custody = { ok = true, custodyId = 31, state = 'arrested' }, order = nil, released = 1 } end
resetJU()
local function rec(name, ...) JU.calls[#JU.calls + 1] = { name = name, args = { ... } } end
local function called(name) local out = {} for _, c in ipairs(JU.calls) do if c.name == name then out[#out + 1] = c end end return out end
Mock.exportsByResource['pf-justice'] = {
    IsIncarcerated = function(_, who) rec('IsIncarcerated', who) return JU.incarcerated end,
    OpenCustody = function(_, target, opts) rec('OpenCustody', target, opts) return JU.custody end,
    CreateOrder = function(_, spec, opts)
        rec('CreateOrder', spec, opts)
        -- the cuffs are still on while the order is made
        JU.cuffedAtOrder = Mock.players[2].PlayerData.metadata.ishandcuffed
        return JU.order or { ok = true, orderId = 77, state = 'active' }
    end,
    ReleaseFromCustody = function(_, id, reason, opts) rec('ReleaseFromCustody', id, reason, opts) return { ok = true } end,
    ReleaseNow = function(_, who, reason, opts) rec('ReleaseNow', who, reason, opts) return { ok = true, released = JU.released } end,
}
local flags = 'false'
function LoadResourceFile(res, file)
    if res == 'pf-justice' and file == 'config.lua' then
        return ('Config = Config or {}\nConfig.Compat = { LegacyRuntimes = { mdt = true, prison = true, policejob = %s } }'):format(flags)
    end
end

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/commands.lua')
load_resource('pfm-policejob/server/interactions.lua')

local COP, SUSPECT, ADMIN = 1, 2, 3
local DESK = vector3(441.0, -981.0, 30.7)
local function meta(src) return Mock.players[src].PlayerData.metadata end
local function lastNotify(src)
    local out
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.target == src then out = e.args[1] end end
    return out
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.dropped, bags, prisonJailed = {}, {}, {}, {}, {}
    Mock.aces = {}
    resetJU()
    flags = 'false'
    PoliceJustice.Reset()
    Config.Justice = nil
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 2 } }
    local s = Mock.newPlayer(SUSPECT, 'SUSCID')
    s.PlayerData.metadata.ishandcuffed = true
    s.PlayerData.charinfo = { firstname = 'Jane', lastname = 'Doe' }
    local a = Mock.newPlayer(ADMIN, 'ADMCID')
    a.PlayerData.job = { name = 'unemployed', type = 'none', onduty = false, grade = { level = 0 } }
    Mock.coords[COP], Mock.coords[SUSPECT], Mock.coords[ADMIN] = vector3(0, 0, 0), vector3(1, 0, 0), vector3(50, 0, 0)
end

local function jail(minutes) Mock.fireNet('police:server:JailPlayer', COP, SUSPECT, minutes or 20) end

describe('field jail after the hand-over', function()
    it('follows pf-justice\'s policejob flag', function()
        assert_true(PoliceJustice.HandedOver())
        flags = 'true'
        PoliceJustice.Reset()
        assert_false(PoliceJustice.HandedOver())
        Config.Justice = { Runtime = 'justice' }
        assert_true(PoliceJustice.HandedOver())
    end)
    it('opens a custody, then one jail order keyed by it; pfm-prison is not asked and no record is written here', function()
        jail(20)
        local o = called('OpenCustody')
        assert_eq(#o, 1)
        assert_eq(o[1].args[1], SUSPECT)
        assert_eq(o[1].args[2].actor.src, COP)
        local c = called('CreateOrder')
        assert_eq(#c, 1)
        local spec, opts = c[1].args[1], c[1].args[2]
        assert_eq(spec.kind, 'jail')
        assert_eq(spec.cid, 'SUSCID')
        assert_eq(spec.minutes, 20)
        assert_eq(spec.custodyId, 31)
        assert_eq(spec.sourceRef.type, 'field')
        assert_eq(opts.key, 'pfm-policejob:jail:31')
        assert_eq(opts.actor.src, COP)
        assert_eq(#prisonJailed, 0)
        assert_eq(meta(SUSPECT).criminalrecord, nil)
    end)
    it('the cuffs come off only once the order exists', function()
        jail(20)
        assert_eq(JU.cuffedAtOrder, true)
        assert_eq(meta(SUSPECT).ishandcuffed, false)
    end)
    it('needs the suspect cuffed or at a booking desk (the MDT custody rule)', function()
        meta(SUSPECT).ishandcuffed = false
        jail(20)
        assert_eq(#called('OpenCustody'), 0)
        assert_eq(lastNotify(COP), 'The suspect must be handcuffed or at a booking desk')
        Mock.coords[COP], Mock.coords[SUSPECT] = DESK, vector3(DESK.x + 1, DESK.y, DESK.z)
        jail(20)
        assert_eq(#called('CreateOrder'), 1, 'at the desk')
    end)
    it('one player cannot hold two incarcerations', function()
        JU.incarcerated = true
        jail(20)
        assert_eq(#called('CreateOrder'), 0)
        assert_eq(lastNotify(COP), 'They are already serving a sentence')
    end)
    it('a suspect already in custody keeps that record; a refused order leaves it, a new one is closed again', function()
        JU.custody = { ok = false, error = 'conflict', custodyId = 12, existing = true }
        JU.order = { ok = false, error = 'db_unavailable', message = 'The justice database did not answer' }
        jail(20)
        assert_eq(called('CreateOrder')[1].args[2].key, 'pfm-policejob:jail:12')
        assert_eq(#called('ReleaseFromCustody'), 0, 'the existing custody stays')
        assert_eq(meta(SUSPECT).ishandcuffed, true, 'nothing happened to the suspect')
        resetJU()
        JU.order = { ok = false, error = 'db_unavailable', message = 'The justice database did not answer' }
        jail(20)
        local r = called('ReleaseFromCustody')
        assert_eq(#r, 1)
        assert_eq(r[1].args[1], 31)
        assert_eq(r[1].args[2], 'no_charges')
    end)
    it('time is capped, and an off-duty officer or a far suspect jails nobody', function()
        jail(1e9)
        assert_eq(called('CreateOrder')[1].args[1].minutes, Config.MaxJailTime)
        resetJU()
        Mock.players[COP].PlayerData.job.onduty = false
        jail(20)
        assert_eq(#called('OpenCustody'), 0)
    end)
    it('without pf-justice, or with field jail turned off, nothing happens', function()
        states['pf-justice'] = 'stopped'
        jail(20)
        states['pf-justice'] = 'started'
        assert_eq(#called('OpenCustody'), 0)
        Config.Justice = { AllowFieldJail = false }
        jail(20)
        assert_eq(#called('OpenCustody'), 0)
        assert_eq(#prisonJailed, 0)
    end)
end)

describe('/unjail after the hand-over', function()
    it('an on-duty officer ends the orders through ReleaseNow', function()
        Commands.unjail(COP, { tostring(SUSPECT) })
        local r = called('ReleaseNow')
        assert_eq(#r, 1)
        assert_eq(r[1].args[1], SUSPECT)
        assert_eq(r[1].args[3].actor.src, COP)
        assert_eq(r[1].args[3].actor.kind, nil)
    end)
    it('an admin acts as an admin; anyone else is refused', function()
        Commands.unjail(ADMIN, { tostring(SUSPECT) })
        assert_eq(#called('ReleaseNow'), 0)
        Mock.aces[ADMIN] = { command = true }
        Commands.unjail(ADMIN, { tostring(SUSPECT) })
        assert_eq(called('ReleaseNow')[1].args[3].actor.kind, 'admin')
    end)
    it('says so when there was nothing to release', function()
        JU.released = 0
        Commands.unjail(COP, { tostring(SUSPECT) })
        assert_eq(lastNotify(COP), 'They are not in jail')
    end)
end)

describe('before the hand-over', function()
    it('pfm-prison still jails and nothing reaches pf-justice', function()
        flags = 'true'
        PoliceJustice.Reset()
        jail(20)
        assert_eq(#prisonJailed, 1)
        assert_eq(#JU.calls, 0)
        assert_eq(meta(SUSPECT).criminalrecord.hasRecord, true)
    end)
end)
