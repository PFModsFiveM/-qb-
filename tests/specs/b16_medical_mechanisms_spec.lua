-- pf-ambulancejob damage mechanisms (batch 16B, shared/medical/mechanisms.lua): weapon classes,
-- falls by server peak speed -> height band -> structures (table-driven), landing plausibility,
-- vehicle delta-v bands with the seatbelt claim moving one band at most, armour and helmet
-- protection, and the severity cap from the server-seen drop. The rolls are fixed.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/config_medical.lua')
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'mechanisms' }) do
    load_resource('[pfscripts]/pf-ambulancejob/shared/medical/' .. f .. '.lua')
end
local M, A = PFMed.Mechanisms, PFMed.Anatomy
local HALF = function() return 0.5 end
local function build(ctx) ctx.roll = ctx.roll or HALF; return M.Build(ctx) end
local function places(specs)
    local out = {}
    for i, s in ipairs(specs) do out[i] = s.type .. ':' .. tostring(s.structure or s.region) end
    return table.concat(out, ',')
end
local function kinds(specs)
    local out = {}
    for _, s in ipairs(specs) do out[A.GroupKindOf(s.region, s.structure)] = true end
    return out
end

describe('weapons', function()
    it('classify through Config.Weapons classes and the special hashes', function()
        assert_eq(M.Classify(joaat('WEAPON_PISTOL')).group, 'firearm')
        assert_eq(M.Classify(GetHashKey('WEAPON_PISTOL')).class, 'SMALL_CALIBER', 'signed and unsigned hashes agree')
        assert_true(M.Classify(joaat('WEAPON_KNIFE')).thrust)
        assert_false(M.Classify(joaat('WEAPON_MACHETE')).thrust)
        assert_eq(M.Classify(joaat('WEAPON_FALL')).group, 'fall')
        assert_eq(M.Classify(joaat('WEAPON_RUN_OVER_BY_CAR')).group, 'pedestrian')
        assert_eq(M.Classify(joaat('WEAPON_STUNGUN')).group, 'taser')
        assert_eq(M.Classify(joaat('WEAPON_UNARMED')).group, 'blunt')
        assert_eq(M.Classify(12345).group, 'unknown')
        assert_true(M.NeedsAttacker.firearm and not M.NeedsAttacker.fall)
    end)
end)

describe('falls (server peak downward speed -> height -> band -> structures)', function()
    local CASES = {
        -- speed m/s, band, feet-first structures (roll 0.5: right side, second pick)
        { 6.0, 1, 'bruising:lower_leg_r' },
        { 9.0, 2, 'fracture:fibula_r,bruising:foot_r' },
        { 12.0, 3, 'fracture:heel_r,fracture:pelvis,spinal:spine_lumbar' },
        { 16.0, 4, 'fracture:pelvis,fracture:femur_r,spinal:spine_lumbar,internal_bleeding:pelvis,head_trauma:brain' },
    }
    for _, c in ipairs(CASES) do
        it(('%.0f m/s is band %d'):format(c[1], c[2]), function()
            local specs, info = build({ group = 'fall', downSpeed = c[1], landing = 'feet', hpDrop = 80 })
            assert_eq(info.band, c[2])
            assert_near(info.height, c[1] * c[1] / (2 * 9.81), 1e-6)
            assert_eq(places(specs), c[3])
            for _, s in ipairs(specs) do assert_eq(s.mechanism, 'fall') end
        end)
    end
    it('every fall rule is a spec the injury catalogue accepts', function()
        local I = PFMed.Injuries
        for landing, bands in pairs(M.FallRules) do
            for band = 1, 4 do
                local specs = build({ group = 'fall', downSpeed = ({ 6, 9, 12, 16 })[band], landing = landing, region = 'chest_l', roll = function() return 0.1 end })
                for _, s in ipairs(specs) do
                    assert_true(I.Types[s.type] ~= nil, landing .. band .. s.type)
                    assert_true(s.structure == nil or I.AllowsStructure(s.type, s.subtype, s.structure), landing .. band .. tostring(s.structure))
                end
            end
        end
    end)
    it('a feet-first fall hits the lower body; a head impact gives no isolated ankle fracture', function()
        local feet = kinds((build({ group = 'fall', downSpeed = 9, landing = 'feet' })))
        assert_true(feet.leg and not feet.head and not feet.arm)
        for _, speed in ipairs({ 6, 9, 12, 16 }) do
            local specs = build({ group = 'fall', downSpeed = speed, landing = 'head' })
            local k = kinds(specs)
            assert_true(k.head, 'head landing injures the head')
            assert_false(k.leg, 'no lower-limb injury from a head-first fall')
        end
        -- the landing comes from the victim's bone hint
        assert_eq(M.Landing('head'), 'head')
        assert_eq(M.Landing('foot_l'), 'feet')
        assert_eq(M.Landing('forearm_r'), 'side')
        assert_eq(M.Landing(nil), 'feet')
        -- the plausibility filter drops what a landing cannot produce
        local kept, dropped = M.Plausible({ { mechanism = 'fall', type = 'sprain', subtype = 'ankle', structure = 'ankle_l', severity = 2, attrs = {} },
            { mechanism = 'fall', type = 'head_trauma', subtype = 'concussion', structure = 'brain', severity = 2, attrs = {} } }, {}, { landing = 'head', band = 2 })
        assert_eq(#kept, 1)
        assert_eq(kept[1].type, 'head_trauma')
        assert_eq(dropped[1].structure, 'ankle_l')
    end)
end)

describe('vehicle occupants (server delta-v bands)', function()
    local function band(dv, belt) local _, info = build({ group = 'vehicle', deltaV = dv, seatbelt = belt }) return info.band end
    it('bands by delta-v', function()
        assert_eq(band(5), 0, 'below the minimum no mechanism')
        assert_eq(band(15), 1)
        assert_eq(band(35), 2)
        assert_eq(band(65), 3)
        assert_eq(band(90), 4)
    end)
    it('the seatbelt claim moves at most one band', function()
        assert_eq(band(35, true), 1)
        assert_eq(band(35, false), 3)
        assert_eq(band(90, true), 3)
        assert_eq(band(90, false), 4)
        assert_eq(band(15, true), 1)
        local specs = build({ group = 'vehicle', deltaV = 90 })
        assert_true(places(specs):find('head_trauma:brain', 1, true) ~= nil)
        assert_eq(specs[1].attrs.deltaV, 90)
    end)
end)

describe('protection', function()
    local PISTOL, RIFLE = joaat('WEAPON_PISTOL'), joaat('WEAPON_MARKSMANRIFLE')
    it('a vest stops a pistol round by class (bruising instead of a gunshot wound)', function()
        local s = build({ group = 'firearm', class = 'SMALL_CALIBER', weapon = PISTOL, region = 'chest_l', vest = true, hpDrop = 5, armourDrop = 30 })
        assert_eq(s[1].type, 'bruising')
        assert_eq(s[1].attrs.stopped, 'vest')
        -- a high-calibre round goes through (15 % stop), and without a vest the pistol does too
        s = build({ group = 'firearm', class = 'HIGH_CALIBER', weapon = RIFLE, region = 'chest_l', vest = true, hpDrop = 30 })
        assert_eq(s[1].type, 'gunshot')
        s = build({ group = 'firearm', class = 'SMALL_CALIBER', weapon = PISTOL, region = 'chest_l', vest = false, hpDrop = 30 })
        assert_eq(s[1].type, 'gunshot')
        -- the vest does not cover the legs
        s = build({ group = 'firearm', class = 'SMALL_CALIBER', weapon = PISTOL, region = 'thigh_l', vest = true, hpDrop = 30 })
        assert_eq(s[1].type, 'gunshot')
    end)
    it('a helmet item protects the head', function()
        local helmet = M.Defaults.ProtectionItems.helmet
        local s = build({ group = 'firearm', class = 'SMALL_CALIBER', weapon = PISTOL, region = 'head', helmet = helmet, hpDrop = 40 })
        assert_eq(s[1].type, 'bruising')
        assert_eq(s[1].attrs.stopped, 'helmet')
        s = build({ group = 'firearm', class = 'SMALL_CALIBER', weapon = PISTOL, region = 'head', hpDrop = 40 })
        assert_eq(s[1].type, 'gunshot')
        -- blunt and fall head injuries are one level lower and a skull fracture becomes a concussion
        local bare = build({ group = 'fall', downSpeed = 12, landing = 'head' })
        local prot = build({ group = 'fall', downSpeed = 12, landing = 'head', helmet = helmet })
        assert_eq(bare[1].subtype, 'skull_fracture')
        assert_eq(prot[1].subtype, 'concussion')
        assert_eq(prot[1].severity, bare[1].severity - 1)
        assert_eq(prot[1].attrs.protected, 'helmet')
    end)
end)

describe('severity cap', function()
    it('follows ceil((hp + 0.5 armour) / 10) + 1 and caps a list in order', function()
        assert_eq(M.SeverityCap(0, 0), 0)
        assert_eq(M.SeverityCap(9, 0), 2)
        assert_eq(M.SeverityCap(30, 0), 4)
        assert_eq(M.SeverityCap(20, 20), 4)
        local list = M.ApplyCap({ { severity = 4 }, { severity = 3 }, { severity = 2 } }, 5)
        assert_eq(#list, 2)
        assert_eq(list[1].severity, 4)
        assert_eq(list[2].severity, 1)
    end)
end)
