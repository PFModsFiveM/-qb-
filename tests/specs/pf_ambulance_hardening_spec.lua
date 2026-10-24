-- pf-ambulancejob (the ambulance job in use) with the server hardening ported from the removed
-- pfm-ambulancejob: beds, armor, wound treatment and revives are checked on the server.
load_resource('tests/lua/ledger_env.lua')
GetInvokingResource = GetInvokingResource or function() return nil end   -- a client-triggered event
local bandages = 0
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, src, item) if item == 'bandage' then if bandages < 1 then return false end bandages = bandages - 1 end return true end,
    AddItem = function() return true end,
}
QBCoreMock.Functions.HasItem = function() return false end
LedgerEnv.load('pf-ambulancejob', { '[pfscripts]/pf-ambulancejob/config.lua', '[pfscripts]/pf-ambulancejob/server/main.lua' })

local PATIENT, MEDIC, OTHER = 1, 2, 3
local function sent(name, target)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if target == nil or e.target == target then n = n + 1 end end
    return n
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players = {}
    bandages = 0
    FakeDB.society('ambulance', 0)
    Mock.newPlayer(PATIENT).PlayerData.money = { cash = 0, bank = 5000 }
    Mock.newPlayer(OTHER).PlayerData.money = { cash = 0, bank = 5000 }
    Mock.newPlayer(MEDIC).PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true }
end

describe('pf-ambulancejob hardening', function()
    it('a taken bed cannot be taken by someone else', function()
        Mock.fireNet('hospital:server:SendToBed', PATIENT, 1, true, 1)
        Mock.fireNet('hospital:server:SendToBed', OTHER, 1, true, 1)
        assert_eq(sent('hospital:client:SendToBed', PATIENT), 1)
        assert_eq(sent('hospital:client:SendToBed', OTHER), 0)
    end)
    it('an unknown hospital or bed is refused without an error', function()
        Mock.fireNet('hospital:server:SendToBed', PATIENT, 999, true, 1)
        Mock.fireNet('hospital:server:SendToBed', PATIENT, 1, true, 999)
        assert_eq(sent('hospital:client:SendToBed'), 0)
    end)
    it('only medics set armor, between 0 and 100', function()
        Mock.fireNet('hospital:server:SetArmor', PATIENT, 100)
        assert_eq(Mock.players[PATIENT].PlayerData.metadata.armor, nil)
        Mock.fireNet('hospital:server:SetArmor', MEDIC, 9999)
        assert_eq(Mock.players[MEDIC].PlayerData.metadata.armor, 100)
    end)
    it('treating wounds needs an on-duty medic and a bandage', function()
        Mock.fireNet('hospital:server:TreatWounds', OTHER, PATIENT)       -- not a medic
        Mock.fireNet('hospital:server:TreatWounds', MEDIC, PATIENT)       -- no bandage
        assert_eq(sent('hospital:client:HealInjuries'), 0)
        bandages = 1
        Mock.fireNet('hospital:server:TreatWounds', MEDIC, PATIENT)
        assert_eq(sent('hospital:client:HealInjuries', PATIENT), 1)
    end)
    it('an on-duty medic revives; an off-duty one is refused (not banned)', function()
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        assert_eq(sent('hospital:client:Revive', PATIENT), 1)
        Mock.players[MEDIC].PlayerData.job.onduty = false
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        assert_eq(sent('hospital:client:Revive', PATIENT), 1)
    end)
end)
