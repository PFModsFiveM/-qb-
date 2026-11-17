-- pf-ambulancejob shared injury helpers (used by the client to describe a hit, and by the server to
-- check a report): weapon -> injury type, bone -> body zone, damage -> severity.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
Config = nil
load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/framework.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/medical/anatomy.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/medical/injuries.lua')
load_resource('[pfscripts]/pf-ambulancejob/server/medical/legacy_import.lua')

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
    -- batch 21C: the EMS MDT no longer has fixed treatment buttons. Its Patient Care page builds the
    -- treatment menu from pf-ambulancejob's catalogue (shared/medical/treatments.lua, loaded by the
    -- pf-emsmdt manifest), sends every action to pf-ambulancejob:server:treat and shows the answer.
    it("the EMS MDT's treatments are catalogue actions sent to the server, and the old keys still map", function()
        load_resource('[pfscripts]/pf-ambulancejob/shared/medical/treatments.lua')
        local T = PFMed.Treatments
        local manifest = __readfile('[pfscripts]/pf-emsmdt/fxmanifest.lua')
        assert_true(manifest:find("'@pf-ambulancejob/shared/medical/treatments.lua'", 1, true) ~= nil, 'the MDT loads the catalogue')
        local html = __readfile('[pfscripts]/pf-emsmdt/html/index.html')
        assert_eq(html:find('data-treatment="', 1, true), nil, 'no fixed treatment buttons')
        local bridge = __readfile('[pfscripts]/pf-emsmdt/client/injury_integration.lua')
        assert_true(bridge:find("'pf-ambulancejob:server:treat'", 1, true) ~= nil, 'treatments go to the server callback')
        assert_eq(bridge:find('applyTreatment', 1, true), nil, 'not the old fire-and-forget event')
        -- the keys the old MDT buttons sent (bandage, splint, burn_dressing, oxygen) still reach real actions
        for _, key in ipairs({ 'bandage', 'splint', 'burn_dressing', 'oxygen' }) do
            local action = T.LegacyKeys[key]
            assert_true(action ~= nil and T.Actions[action] ~= nil, 'legacy key ' .. key)
        end
    end)
    it('every legacy injury type and zone has an engine mapping for the one-time import (16B)', function()
        local LI = PFMed.LegacyImport
        for injuryType in pairs(Config.InjuryTypes) do
            local t = LI.TypeMap[injuryType]
            assert_true(t ~= nil and PFMed.Injuries.Types[t[1]] ~= nil, injuryType)
        end
        for zone in pairs(Config.BodyZones) do assert_true(PFMed.Anatomy.IsRegion(LI.ZoneMap[zone]), zone) end
        for _, s in ipairs(Config.InjurySeverities) do assert_true(LI.SeverityMap[s] ~= nil, s) end
    end)
end)
