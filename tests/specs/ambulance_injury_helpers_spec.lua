-- pf-ambulancejob shared injury helpers (used by the client to describe a hit, and by the server to
-- check a report): weapon -> injury type, bone -> body zone, damage -> severity.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
Config = nil
load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/framework.lua')

describe('injury helpers', function()
    it('weapons map to injury types through their class, with overrides', function()
        assert_eq(PFAmbulance.InjuryTypeForWeapon(joaat('WEAPON_PISTOL')), 'gunshot_wound')
        assert_eq(PFAmbulance.InjuryTypeForWeapon(joaat('WEAPON_FALL')), 'fracture')
        assert_eq(PFAmbulance.InjuryTypeForWeapon(joaat('WEAPON_ELECTRIC_FENCE')), 'electrical_burn')
        assert_eq(PFAmbulance.InjuryTypeForWeapon(12345), 'blunt_trauma')
    end)
    it('bones map to body zones through Config.Bones labels', function()
        assert_eq(PFAmbulance.BodyPartForBone(31086).zone, 'head')
        assert_eq(PFAmbulance.BodyPartForBone(24818).zone, 'torso')
        assert_eq(PFAmbulance.BodyPartForBone(999999).zone, 'torso')
    end)
    it('damage maps to severity', function()
        assert_eq(PFAmbulance.SeverityForDamage(5), 'minor')
        assert_eq(PFAmbulance.SeverityForDamage(20), 'moderate')
        assert_eq(PFAmbulance.SeverityForDamage(30), 'severe')
        assert_eq(PFAmbulance.SeverityForDamage(80), 'critical')
    end)
    it('every treatment uses an item and treats known injury types', function()
        for name, t in pairs(Config.Treatments) do
            assert_true(type(t.item) == 'string', name .. ' item')
            for injuryType in pairs(t.treats) do assert_true(Config.InjuryTypes[injuryType] ~= nil, name .. ' treats ' .. injuryType) end
        end
        for _, injuryType in pairs(Config.WeaponInjuryTypes) do assert_true(Config.InjuryTypes[injuryType] ~= nil, injuryType) end
        for _, part in pairs(Config.BodyParts) do assert_true(Config.BodyZones[part.zone] ~= nil, part.zone) end
    end)
    it("the EMS MDT's treatment buttons are real treatments", function()
        local html = __readfile('[pfscripts]/pf-emsmdt/html/index.html')
        local n = 0
        for name in html:gmatch('data%-treatment="([%w_]+)"') do
            n = n + 1
            assert_true(Config.Treatments[name] ~= nil, 'button ' .. name)
        end
        assert_true(n > 0)
    end)
end)
