-- pf-ambulancejob → pf-services: a player who goes down gets one 'ems.patient' request at the server's
-- position; a medic's revive completes it, respawn / check-in / admin revive / getting up cancel it.
load_resource('tests/lua/ledger_env.lua')
GetInvokingResource = function() return nil end
Requests, Closes, Emits = {}, {}, {}
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function(_, opts) Requests[#Requests + 1] = opts return { ok = true, id = #Requests } end,
    CloseByRef = function(_, t, id, status, reason) Closes[#Closes + 1] = { type = t, id = id, status = status, reason = reason } return { ok = true } end,
    Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, opts = opts } return #Emits end,
}
Mock.exportsByResource['pfm-inventory'] = { RemoveItem = function() return true end, AddItem = function() return true end }
QBCoreMock.Functions.HasItem = function() return false end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
LedgerEnv.load('pf-ambulancejob', { '[pfscripts]/pf-ambulancejob/config.lua', '[pfscripts]/pf-ambulancejob/server/main.lua' })

local PATIENT, MEDIC = 1, 2
local function closesFor(t, status, reason)
    local n = 0
    for _, c in ipairs(Closes) do
        if c.type == t and c.id == 'PATIENTCID' and (not status or c.status == status) and (not reason or c.reason == reason) then n = n + 1 end
    end
    return n
end
local function goDown() Mock.fireNet('hospital:server:SetLaststandStatus', PATIENT, true) end
local function getUp()
    Mock.fireNet('hospital:server:SetDeathStatus', PATIENT, false)
    Mock.fireNet('hospital:server:SetLaststandStatus', PATIENT, false)
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Requests, Closes, Emits = {}, {}, {}, {}, {}
    FakeDB.society('ambulance', 0)
    Config.WipeInventoryOnRespawn = false
    local p = Mock.newPlayer(PATIENT, 'PATIENTCID')
    p.PlayerData.money = { cash = 0, bank = 5000 }
    p.PlayerData.metadata.injail = 0
    p.ClearInventory = function() end
    Mock.newPlayer(MEDIC).PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true }
    Mock.coords[PATIENT] = vector3(120.5, -300.25, 45.0)
end

describe('EMS patient requests', function()
    it('going down opens one request at the server position', function()
        goDown()
        Mock.fireNet('hospital:server:SetDeathStatus', PATIENT, true)        -- bleeds out: still the same call
        assert_eq(#Requests, 1)
        local r = Requests[1]
        assert_eq(r.kind, 'ems.patient')
        assert_eq(r.ref.type, 'patient')
        assert_eq(r.ref.id, 'PATIENTCID')
        assert_eq(r.from.type, 'system')
        assert_near(r.coords.x, 120.5, 0.01)
        assert_near(r.coords.y, -300.25, 0.01)
        assert_eq(#Emits, 1)
        assert_eq(Emits[1].kind, 'ems.patient')
    end)
    it('a medic\'s revive completes it (and a medic call the patient made)', function()
        goDown()
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        assert_eq(closesFor('patient', 'completed', 'revived'), 1)
        assert_eq(closesFor('citizen:ems.patient', 'completed', 'revived'), 1)
        getUp()                                                              -- the client reports it is up
        assert_eq(closesFor('patient', 'completed'), 1)
    end)
    it('respawning at hospital, an admin revive, getting up or logging off cancel it', function()
        goDown()
        Mock.fireNet('hospital:server:RespawnAtHospital', PATIENT, 1)
        assert_eq(closesFor('patient', 'cancelled', 'respawned'), 1)
        Commands.revive(MEDIC, { tostring(PATIENT) })
        assert_eq(closesFor('patient', 'cancelled', 'admin_revive'), 1)
        getUp()
        assert_eq(closesFor('patient', 'cancelled', 'recovered'), 1)
        Mock.clock = Mock.clock + 120
        goDown()
        Mock.fireEvent('playerDropped', PATIENT)
        assert_eq(closesFor('patient', 'cancelled', 'left'), 1)
        assert_eq(closesFor('patient', 'completed'), 0)
    end)
    it('no request without a real up -> down change, and toggling cannot flood the medics', function()
        Mock.fireNet('hospital:server:SetLaststandStatus', PATIENT, false)    -- already up
        assert_eq(#Requests, 0)
        goDown(); getUp(); goDown(); getUp(); goDown()
        assert_eq(#Requests, 1)
        Mock.clock = Mock.clock + 61
        getUp(); goDown()
        assert_eq(#Requests, 2)
    end)
    it('/911e lands in the medics\' Dispatch app as the caller\'s one open call; treatment closes it', function()
        Commands['911e'](PATIENT, { 'broken', 'leg' })
        assert_eq(#Requests, 1)
        assert_eq(Requests[1].ref.type, 'citizen:ems.patient')
        assert_eq(Requests[1].requester, 'PATIENTCID')
        assert_eq(Requests[1].details, 'broken leg')
        assert_near(Requests[1].coords.x, 120.5, 0.01)
        Mock.fireNet('hospital:server:TreatWounds', MEDIC, PATIENT)
        assert_eq(closesFor('citizen:ems.patient', 'completed', 'treated'), 1)
    end)
end)
