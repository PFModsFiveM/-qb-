-- pf-ambulancejob medical models (batch 15A): anatomy and injury catalogue coverage, the physiology
-- model (pure and deterministic: loss classes, tension pneumothorax, airway obstruction, opioid
-- overdose, consciousness thresholds) and the effect model (max per channel, never the sum).
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/config_medical.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/medical/anatomy.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/medical/injuries.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/medical/physiology_model.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/medical/effects_model.lua')

local A, I, P, EM = PFMed.Anatomy, PFMed.Injuries, PFMed.Physiology, PFMed.EffectsModel
local NOW = 1700000000

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function inj(t)
    t.stage = t.stage or 'injured'
    t.severity = t.severity or 3
    if t.pain == nil then t.pain = I.Pain(t.type, t.subtype, t.severity) end
    if t.bleed_ml_min == nil then t.bleed_ml_min = I.Bleed(t.type, t.subtype, t.structure, t.severity, t.attrs).mlPerMin end
    t.treatments = t.treatments or {}
    t.attrs = t.attrs or {}
    return t
end
local function state(over)
    local s = P.NewState()
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

-- ── anatomy ───────────────────────────────────────────────────────────────────────────────────

describe('anatomy', function()
    it('has every structure and region the owner listed', function()
        local structures = { 'skull', 'brain', 'face_jaw', 'neck', 'spine_cervical', 'spine_thoracic', 'spine_lumbar', 'sternum', 'heart',
            'airway', 'liver', 'spleen', 'stomach', 'bowel', 'bladder', 'pelvis', 'carotid', 'aorta' }
        for _, side in ipairs({ 'l', 'r' }) do
            for _, base in ipairs({ 'shoulder', 'clavicle', 'humerus', 'elbow', 'forearm', 'wrist', 'hand', 'ribs', 'lung', 'kidney',
                'hip', 'femur', 'knee', 'tibia', 'fibula', 'ankle', 'foot', 'heel', 'brachial', 'femoral' }) do
                structures[#structures + 1] = base .. '_' .. side
            end
        end
        for _, id in ipairs(structures) do assert_true(A.Structures[id] ~= nil, 'structure ' .. id) end
        local regions = { 'head', 'face', 'neck', 'abdomen', 'back_upper', 'back_lower', 'pelvis', 'chest_l', 'chest_r' }
        for _, side in ipairs({ 'l', 'r' }) do
            for _, base in ipairs({ 'shoulder', 'upper_arm', 'forearm', 'hand', 'thigh', 'knee', 'lower_leg', 'foot' }) do regions[#regions + 1] = base .. '_' .. side end
        end
        for _, id in ipairs(regions) do assert_true(A.Regions[id] ~= nil, 'region ' .. id) end
        assert_eq(count(A.Regions), #regions)
    end)

    it('every structure is reachable from a region or a mechanism', function()
        local reach = {}
        for _, r in pairs(A.Regions) do for _, e in ipairs(r.structures) do if e[1] then reach[e[1]] = true end end end
        for _, list in pairs(A.MechanismStructures) do for _, id in ipairs(list) do reach[id] = true end end
        for id in pairs(A.Structures) do assert_true(reach[id], 'unreachable structure ' .. id) end
        for id in pairs(reach) do assert_true(A.Structures[id] ~= nil, 'unknown structure referenced: ' .. id) end
    end)

    it('structures and regions are well formed (kinds, groups, weights summing to 1)', function()
        local kinds = { bone = true, joint = true, organ = true, vessel = true, soft = true }
        for id, s in pairs(A.Structures) do
            assert_true(kinds[s.kind], id .. ' kind')
            assert_true(A.GroupKind[s.group] ~= nil, id .. ' group')
            assert_true(s.bleedClass >= 0 and s.bleedClass <= 3, id .. ' bleedClass')
            assert_true(type(s.label) == 'string' and s.label ~= '', id .. ' label')
        end
        for id, r in pairs(A.Regions) do
            local total = 0
            for _, e in ipairs(r.structures) do
                total = total + e[2]
                assert_true(e[3] == 'surface' or e[3] == 'bone' or e[3] == 'organ', id .. ' depth')
            end
            assert_near(total, 1.0, 0.011, id .. ' weights')
            assert_true(A.GroupKind[r.group] ~= nil, id .. ' group')
        end
    end)

    it('maps every Config.Bones id to a region, spine bones by the roll', function()
        for bone in pairs(Config.Bones) do
            if bone ~= 0 then assert_true(A.RegionForBone(bone, 0.5) ~= nil, 'bone ' .. bone) end
        end
        assert_eq(A.RegionForBone(58271), 'thigh_l')
        assert_eq(A.RegionForBone(52301), 'foot_r')
        assert_eq(A.RegionForBone(4089), 'hand_l')
        assert_eq(A.RegionForBone(24818, 0.1), 'chest_l')
        assert_eq(A.RegionForBone(24818, 0.5), 'chest_r')
        assert_eq(A.RegionForBone(24818, 0.9), 'back_upper')
        assert_eq(A.RegionForBone(31086, 0.1), 'head')
        assert_eq(A.RegionForBone(31086, 0.9), 'face')
        assert_eq(A.RegionForBone(999999), nil)
    end)

    it('picks a structure by weight and filter, deterministically for a roll', function()
        local s1 = A.PickStructure('abdomen', 0.1, nil, false)
        local s2 = A.PickStructure('abdomen', 0.1, nil, false)
        assert_eq(s1, s2)
        assert_eq(s1, 'bowel')
        local bone = A.PickStructure('thigh_l', 0.99, function(_, def) return def.kind == 'bone' end, false)
        assert_eq(bone, 'femur_l')
        local s, depth, found = A.PickStructure('thigh_l', 0.99, nil, true)
        assert_eq(s, nil); assert_eq(depth, 'surface'); assert_true(found)
        local none, _, f2 = A.PickStructure('hand_l', 0.5, function(_, def) return def.kind == 'organ' end, false)
        assert_eq(none, nil); assert_eq(f2, nil)
        assert_true(A.StructureInRegion('ankle_l', 'lower_leg_l'), 'same limb group')
        assert_false(A.StructureInRegion('ankle_l', 'lower_leg_r'))
        assert_eq(A.ArmourFor('chest_l'), 'vest')
        assert_eq(A.ArmourFor('head'), 'helmet')
        assert_eq(A.ArmourFor('thigh_l'), nil)
    end)
end)

-- ── injury catalogue ──────────────────────────────────────────────────────────────────────────

describe('injury catalogue', function()
    local TYPES = {
        fracture = { 'closed', 'open', 'displaced', 'comminuted', 'stress' },
        dislocation = { 'shoulder', 'elbow', 'hip', 'knee', 'finger' },
        sprain = { 'ankle', 'wrist', 'knee' },
        bruising = { 'contusion', 'hematoma' },
        laceration = { 'superficial', 'deep', 'arterial' },
        gunshot = { 'graze', 'penetrating', 'perforating', 'retained' },
        stab = { 'superficial', 'penetrating' },
        burn = { 'first', 'second', 'third' },
        crush = { 'limb', 'chest', 'pelvis' },
        electrical = { 'taser', 'low_voltage', 'high_voltage' },
        head_trauma = { 'concussion', 'skull_fracture', 'epidural', 'subdural', 'diffuse' },
        spinal = { 'cervical', 'thoracic', 'lumbar' },
        internal_bleeding = { 'liver', 'spleen', 'kidney', 'pelvic', 'thoracic' },
        organ_trauma = { 'tamponade', 'pneumothorax', 'tension', 'hemothorax', 'bowel' },
        respiratory = { 'airway_obstruction', 'smoke_inhalation', 'aspiration' },
        drowning = { 'near_drowning' },
        poisoning = { 'ethanol', 'opioid', 'stimulant', 'sedative', 'co', 'food', 'chemical' },
        illness = { 'food_poisoning', 'infection_sepsis', 'hypothermia', 'heat_stroke' },
        infection = { 'wound_infection', 'sepsis' },
    }

    it('has every category and subtype of architecture 11.2', function()
        for name, subs in pairs(TYPES) do
            local t = I.Types[name]
            assert_true(t ~= nil, 'type ' .. name)
            for _, sub in ipairs(subs) do assert_true(t.subtypes[sub] ~= nil, name .. '.' .. sub) end
        end
        assert_eq(count(I.Types), count(TYPES))
    end)

    it('every type has bleed, pain, effects, care and healing data for each severity', function()
        for name, t in pairs(I.Types) do
            assert_true(type(t.label) == 'string', name .. ' label')
            assert_eq(#t.bleed.mlPerMin, 5, name .. ' bleed')
            assert_eq(#t.pain, 5, name .. ' pain')
            assert_eq(#t.healSeconds, 5, name .. ' heal')
            for i = 2, 5 do assert_true(t.healSeconds[i] >= t.healSeconds[i - 1], name .. ' heal grows') end
            assert_true(type(t.effects) == 'table' and next(t.effects) ~= nil, name .. ' effects')
            for _, spec in pairs(t.effects) do for ch, list in pairs(spec) do assert_eq(#list, 5, name .. ' effect ' .. ch) end end
            assert_true(type(t.stabilizeBy) == 'table' and type(t.treatBy) == 'table' and #t.treatBy > 0, name .. ' care')
            assert_true(type(t.infection) == 'boolean', name .. ' infection flag')
        end
    end)

    it('every type can be placed somewhere (a structure, skin, or the whole body)', function()
        for name, t in pairs(I.Types) do
            local ok = t.surface or t.systemic
            for id in pairs(A.Structures) do
                for sub in pairs(t.subtypes) do if I.AllowsStructure(name, sub, id) then ok = true end end
            end
            assert_true(ok, name .. ' has nowhere to go')
        end
        assert_true(I.AllowsStructure('fracture', 'closed', 'femur_l'))
        assert_false(I.AllowsStructure('fracture', 'closed', 'liver'))
        assert_false(I.AllowsStructure('dislocation', 'knee', 'shoulder_l'), 'subtype limits the joint')
        assert_false(I.AllowsStructure('fracture', 'closed', nil), 'a fracture needs a bone')
        assert_true(I.AllowsStructure('laceration', 'deep', nil), 'skin-only laceration')
    end)

    it('derives bleeding from type, subtype and the structure hit', function()
        local art = I.Bleed('laceration', 'arterial', 'femoral_l', 4)
        assert_true(art.arterial and art.noclot, 'arterial does not clot')
        assert_true(art.mlPerMin >= 200)
        local femur = I.Bleed('fracture', 'closed', 'femur_l', 3)
        assert_true(femur.internal, 'closed femur bleeds inside')
        assert_near(femur.mlPerMin, 7.5, 0.01)
        local open = I.Bleed('fracture', 'open', 'tibia_l', 3)
        assert_false(open.internal, 'an open fracture bleeds outside')
        local liver = I.Bleed('internal_bleeding', 'liver', 'liver', 3)
        assert_true(liver.internal and liver.noclot)
        local burn = I.Bleed('burn', 'third', nil, 4, { tbsa = 40 })
        assert_near(burn.mlPerMin, 10, 0.01)
        assert_true(burn.fluid)
        assert_eq(I.Bleed('sprain', 'ankle', 'ankle_l', 5).mlPerMin, 0)
    end)

    it('stage machine: forward steps and complications only', function()
        assert_true(I.CanTransition('injured', 'stabilized'))
        assert_true(I.CanTransition('stabilized', 'treated'))
        assert_true(I.CanTransition('treated', 'recovering'))
        assert_true(I.CanTransition('recovering', 'recovered'))
        assert_true(I.CanTransition('recovering', 'complicated'))
        assert_true(I.CanTransition('complicated', 'stabilized'))
        assert_false(I.CanTransition('injured', 'recovered'))
        assert_false(I.CanTransition('recovered', 'injured'))
        assert_eq(I.CleanSeverity(3.7), 3); assert_eq(I.CleanSeverity(0), nil); assert_eq(I.CleanSeverity(0 / 0), nil)
    end)
end)

-- ── physiology ────────────────────────────────────────────────────────────────────────────────

describe('physiology: haemorrhage classes', function()
    local cases = {
        { blood = 5000, class = 1, hr = 75, sbp = 120, gcs = 15 },
        { blood = 4300, class = 1, hr = 75, sbp = 120, gcs = 15 },   -- 14 %
        { blood = 4250, class = 2, hr = 100, sbp = 120, gcs = 15 },  -- 15 %
        { blood = 3600, class = 2, hr = 100, sbp = 120, gcs = 15 },  -- 28 %
        { blood = 3500, class = 3, hr = 120, sbp = 90, gcs = 15 },   -- 30 %
        { blood = 3000, class = 3, hr = 120, sbp = 90, gcs = 15 },   -- 40 %
        { blood = 2900, class = 4, hr = 140, sbp = 60, gcs = 12 },   -- 42 %: SBP < 80 costs 3 GCS
    }
    for _, c in ipairs(cases) do
        it(('blood %d ml -> class %d'):format(c.blood, c.class), function()
            local v = P.Vitals(state({ blood_ml = c.blood }), {}, NOW)
            assert_eq(v.lossClass, c.class)
            assert_eq(v.hr, c.hr)
            assert_eq(v.sbp, c.sbp)
            assert_eq(v.dbp, math.floor(c.sbp * 0.65 + 0.5))
            assert_eq(v.gcs, c.gcs)
            assert_eq(v.spo2, 98)
            assert_eq(v.rr, 14 + 3 * (c.class - 1))
            assert_eq(v.shock, c.class)
        end)
    end
end)

describe('physiology: threats', function()
    it('tension pneumothorax drops SBP by 30 and SpO2, raises shock; decompression relieves it', function()
        local tp = inj({ id = 1, type = 'organ_trauma', subtype = 'tension', structure = 'lung_l', region = 'chest_l', severity = 3 })
        local v = P.Vitals(state(), { tp }, NOW)
        assert_eq(v.sbp, 90)
        assert_eq(v.spo2, 80)
        assert_eq(v.shock, 2)
        assert_eq(v.gcs, 12)
        tp.treatments.decompressed = true
        local after = P.Vitals(state(), { tp }, NOW)
        assert_eq(after.sbp, 120)
        assert_true(after.spo2 > v.spo2, 'oxygenation improves')
    end)

    it('airway obstruction: no breathing, SpO2 floor, then unconscious and arrest from sustained hypoxia', function()
        local ao = inj({ id = 1, type = 'respiratory', subtype = 'airway_obstruction', structure = 'airway', region = 'neck', severity = 4 })
        local v = P.Vitals(state(), { ao }, NOW)
        assert_eq(v.airway, 'obstructed')
        assert_eq(v.rr, 0)
        assert_eq(v.spo2, 50)
        assert_eq(v.gcs, 9)
        local level, cause, ctx = P.NextConsciousness('alert', v, {}, NOW)
        assert_eq(level, 'altered')
        level, cause, ctx = P.NextConsciousness(level, v, ctx, NOW + 29)
        assert_eq(level, 'altered', 'not yet 30 s of hypoxia')
        level, cause, ctx = P.NextConsciousness(level, v, ctx, NOW + 30)
        assert_eq(level, 'unconscious'); assert_eq(cause, 'hypoxia')
        level, cause = P.NextConsciousness(level, v, ctx, NOW + 35)
        assert_eq(level, 'arrest'); assert_eq(cause, 'hypoxia')
        local secured = P.Vitals(state({ airway = 'secured' }), { ao }, NOW)
        assert_eq(secured.spo2, 98, 'a secured airway bypasses the obstruction')
    end)

    it('opioid overdose: respiratory depression, hypoxia, coma; naloxone reverses it', function()
        local s = state({ toxins = { opioid = 120 } })
        local v = P.Vitals(s, {}, NOW)
        assert_true(v.rr <= 8, 'slow breathing (' .. v.rr .. ')')
        assert_true(v.spo2 < 85, 'hypoxic')
        assert_eq(v.gcs, 3)
        assert_true(v.hr < 75)
        assert_eq((P.NextConsciousness('alert', v, {}, NOW)), 'unconscious')
        s.drugs = { naloxone = { mg = 2, at = NOW - 10 } }
        local rev = P.Vitals(s, {}, NOW)
        assert_eq(rev.gcs, 15)
        assert_eq(rev.spo2, 98)
        assert_eq((P.Vitals(s, {}, NOW + 3600)).gcs, 3, 'naloxone wears off before the opioid')
    end)

    it('lethal head trauma and heavy blood loss are arrest causes', function()
        local head = inj({ id = 1, type = 'head_trauma', subtype = 'epidural', structure = 'brain', region = 'head', severity = 5 })
        local v = P.Vitals(state(), { head }, NOW)
        assert_true(v.gcs <= 8)
        assert_eq(P.ArrestCause(v, {}, NOW), 'head_trauma')
        local bled = P.Vitals(state({ blood_ml = 2400 }), {}, NOW)
        assert_eq(P.ArrestCause(bled, {}, NOW), 'hemorrhage')
    end)

    it('arrest and death give no vitals', function()
        local v = P.Vitals(state(), {}, NOW, nil, 'arrest')
        assert_eq(v.hr, 0); assert_eq(v.sbp, 0); assert_eq(v.rr, 0); assert_eq(v.gcs, 3)
        assert_eq(v.rhythm, 'pea')
        assert_eq(P.Rhythm(v, {}, 'arrest', 'arrhythmia'), 'vf')
    end)
end)

describe('physiology: consciousness thresholds', function()
    local function vit(gcs, over)
        local v = { gcs = gcs, sbp = 120, spo2 = 98, lossFraction = 0, conditions = {} }
        for k, val in pairs(over or {}) do v[k] = val end
        return v
    end
    local cases = {
        { 'alert', 15, 'alert' }, { 'alert', 14, 'alert' }, { 'alert', 13, 'altered' }, { 'alert', 9, 'altered' },
        { 'alert', 8, 'unconscious' }, { 'altered', 8, 'unconscious' }, { 'altered', 13, 'altered' },
        { 'unconscious', 8, 'unconscious' }, { 'dead', 15, 'dead' },
    }
    for _, c in ipairs(cases) do
        it(('%s at GCS %d -> %s'):format(c[1], c[2], c[3]), function()
            assert_eq((P.NextConsciousness(c[1], vit(c[2]), {}, NOW)), c[3])
        end)
    end
    it('waking up needs the GCS for 10 s (altered -> alert at 14, unconscious -> altered at 9)', function()
        local level, _, ctx = P.NextConsciousness('altered', vit(14), {}, NOW)
        assert_eq(level, 'altered')
        level, _, ctx = P.NextConsciousness(level, vit(14), ctx, NOW + 9)
        assert_eq(level, 'altered')
        level = P.NextConsciousness(level, vit(14), ctx, NOW + 10)
        assert_eq(level, 'alert')
        local l2, _, c2 = P.NextConsciousness('unconscious', vit(9), {}, NOW)
        assert_eq(l2, 'unconscious')
        l2, _, c2 = P.NextConsciousness(l2, vit(12), c2, NOW + 5)
        l2 = P.NextConsciousness(l2, vit(12), c2, NOW + 10)
        assert_eq(l2, 'altered')
        local held = P.NextConsciousness('unconscious', vit(15), { okSince = NOW - 60, holdUntil = NOW + 30 }, NOW)
        assert_eq(held, 'unconscious', 'a held down state does not wake')
    end)
    it('arrest criteria: SBP < 50, loss > 50 %; a conscious patient goes unconscious first', function()
        assert_eq((P.NextConsciousness('unconscious', vit(5, { sbp = 45 }), {}, NOW)), 'arrest')
        assert_eq((P.NextConsciousness('unconscious', vit(5, { lossFraction = 0.51 }), {}, NOW)), 'arrest')
        assert_eq((P.NextConsciousness('alert', vit(12, { sbp = 45 }), {}, NOW)), 'unconscious')
    end)
    it('arrest -> dead after ArrestToDeathSeconds', function()
        assert_eq((P.NextConsciousness('arrest', vit(3), { arrestSince = NOW - 299 }, NOW)), 'arrest')
        local level, cause = P.NextConsciousness('arrest', vit(3), { arrestSince = NOW - 300 }, NOW)
        assert_eq(level, 'dead'); assert_eq(cause, 'arrest_timeout')
    end)
    it('forced transitions follow the table', function()
        assert_true(P.CanTransition('alert', 'unconscious', 'report'))
        assert_true(P.CanTransition('arrest', 'unconscious', 'rosc'))
        assert_true(P.CanTransition('dead', 'alert', 'respawn'))
        assert_false(P.CanTransition('dead', 'unconscious', 'rosc'))
        assert_false(P.CanTransition('alert', 'dead', 'auto'))
        assert_false(P.CanTransition('arrest', 'unconscious', 'auto'), 'ROSC needs treatment')
    end)
end)

describe('physiology: time steps (pure and deterministic)', function()
    it('bleeds, clots non-arterial wounds, keeps arterial ones', function()
        local cut = inj({ id = 1, type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 2, bleed_ml_min = 10 })
        local art = inj({ id = 2, type = 'laceration', subtype = 'arterial', structure = 'femoral_l', region = 'thigh_l', severity = 2, bleed_ml_min = 90, attrs = { noclot = true, arterial = true } })
        local s0 = state()
        local s1, bleeds, totals = P.Step(s0, { cut, art }, 60, NOW)
        assert_eq(s0.blood_ml, 5000, 'input not changed')
        assert_near(bleeds[1], 10 * 0.99 ^ 12, 0.01)
        assert_eq(bleeds[2], nil, 'arterial bleeding does not clot')
        assert_true(totals.lost > 99 and totals.lost < 100, 'about 90 + 9.7 ml lost')
        assert_near(s1.blood_ml, 5000 - totals.lost, 0.1)
        local a = P.Step(s0, { cut, art }, 10, NOW)
        local h1, b1 = P.Step(s0, { cut, art }, 5, NOW)
        local cut2 = inj({ id = 1, type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 2, bleed_ml_min = b1[1] })
        local h2 = P.Step(h1, { cut2, art }, 5, NOW + 5)
        assert_near(a.blood_ml, h2.blood_ml, 0.2)
        local again = P.Step(s0, { cut, art }, 60, NOW)
        assert_eq(again.blood_ml, s1.blood_ml, 'same input, same output')
    end)

    it('treatments and TXA change bleeding; tourniquet stops it', function()
        local w = inj({ id = 1, type = 'laceration', subtype = 'deep', region = 'thigh_l', severity = 3, bleed_ml_min = 20 })
        assert_eq(P.WoundBleed(w, state(), NOW), 20)
        w.treatments = { pressure = true }
        assert_near(P.WoundBleed(w, state(), NOW), 6, 0.001)
        w.treatments = { tourniquet = NOW }
        assert_eq(P.WoundBleed(w, state(), NOW), 0)
        w.treatments = {}
        assert_near(P.WoundBleed(w, state({ drugs = { txa = { mg = 1000, at = NOW - 60 } } }), NOW), 14, 0.001)
        w.stage = 'treated'
        assert_eq(P.WoundBleed(w, state(), NOW), 0, 'definitive care stops it')
    end)

    it('toxins are eliminated (ethanol linear, others by half-life)', function()
        local s = P.Step(state({ toxins = { ethanol = 0.15, opioid = 60 } }), {}, 3600, NOW)
        assert_near(s.toxins.ethanol, 0.135, 0.0001)
        assert_near(s.toxins.opioid, 60 * 0.5 ^ (60 / 180), 0.01)
        local gone = P.Step(state({ toxins = { ethanol = 0.01 } }), {}, 3600, NOW)
        assert_eq(gone.toxins.ethanol, nil)
    end)

    it('offline rest counts bleeding only up to the cap', function()
        local art = inj({ id = 1, type = 'laceration', subtype = 'arterial', structure = 'brachial_l', region = 'upper_arm_l', severity = 2, bleed_ml_min = 100, attrs = { noclot = true } })
        local s = P.Rest(state(), { art }, 3600, NOW, nil, 120)
        assert_near(s.blood_ml, 4800, 0.5)
        local healed = P.Rest(state({ blood_ml = 4000 }), {}, 7200, NOW, nil, 120)
        assert_near(healed.blood_ml, 4060, 0.5, 'regenerates 0.5 ml/min')
    end)

    it('saline adds volume only; blood adds carrying capacity', function()
        local s = P.AddVolume(state({ blood_ml = 4000 }), 'saline', 1000)
        assert_eq(s.blood_ml, 5000)
        assert_near(s.hgb_factor, 0.8, 0.001)
        local b = P.AddVolume(s, 'blood', 500)
        assert_true(b.hgb_factor > s.hgb_factor)
    end)

    it('pain: the worst wound plus half of the rest, minus analgesia', function()
        local a = inj({ id = 1, type = 'fracture', subtype = 'closed', structure = 'femur_l', region = 'thigh_l', severity = 3, pain = 6 })
        local b = inj({ id = 2, type = 'bruising', subtype = 'contusion', region = 'chest_l', severity = 2, pain = 2 })
        local v = P.Vitals(state(), { a, b }, NOW)
        assert_eq(v.pain, 7)
        local mor = P.Vitals(state({ drugs = { morphine = { mg = 10, at = NOW } } }), { a, b }, NOW)
        assert_eq(mor.pain, 4)
        assert_eq(v.hr, 75 + 2 * 7)
    end)
end)

-- ── effects ───────────────────────────────────────────────────────────────────────────────────

describe('effect model', function()
    local leg1 = function() return inj({ id = 1, type = 'fracture', subtype = 'closed', structure = 'femur_l', region = 'thigh_l', severity = 3 }) end
    local leg2 = function() return inj({ id = 2, type = 'sprain', subtype = 'ankle', structure = 'ankle_r', region = 'lower_leg_r', severity = 3 }) end
    local leg3 = function() return inj({ id = 3, type = 'gunshot', subtype = 'penetrating', structure = 'tibia_l', region = 'lower_leg_l', severity = 4 }) end

    it('three leg injuries -> walk 3, not 9 (max per channel)', function()
        local p = EM.Combine({ leg1(), leg2(), leg3() })
        assert_eq(p.walk, 3)
        for _, ch in ipairs(EM.Channels) do assert_true(p[ch] >= 0 and p[ch] <= 3, ch) end
        local one = EM.Combine({ leg1() })
        assert_eq(one.walk, 3)
    end)

    it('a splint holds the leg (walk 3 -> 2); recovering lowers further', function()
        local f = leg1()
        f.treatments.splinted = true
        assert_eq(EM.Combine({ f }).walk, 2)
        f.stage = 'recovering'
        assert_eq(EM.Combine({ f }).walk, 1)
    end)

    it('painkillers lower pain and aim, never structural channels', function()
        local f = leg1()
        local v = { pain = 8, shock = 1, spo2 = 98, gcs = 15 }
        local base = EM.Combine({ f }, v)
        local mod = EM.Combine({ f }, v, { analgesia = true })
        assert_eq(base.pain, 3); assert_eq(mod.pain, 2)
        assert_eq(mod.aim, base.aim - 1)
        assert_eq(mod.walk, base.walk)
    end)

    it('physiology adds: shock class 3 -> stamina 3, SpO2 < 85 -> vision 2; crutches -> walk 2 and no sprint', function()
        local p = EM.Combine({}, { shock = 3, spo2 = 80, gcs = 15, pain = 0 })
        assert_eq(p.stamina, 3)
        assert_eq(p.vision, 2)
        local c = EM.Combine({ leg1() }, nil, { crutches = true })
        assert_eq(c.walk, 2); assert_eq(c.sprint, 3)
    end)

    it('a healthy profile is empty; restrictions follow the profile', function()
        local empty = EM.Combine({}, { shock = 1, spo2 = 98, gcs = 15, pain = 0 })
        assert_true(EM.IsEmpty(empty))
        assert_eq(#EM.Restrictions(empty, {}), 0)
        local kinds = {}
        for _, r in ipairs(EM.Restrictions(EM.Combine({ leg1() }), { leg1() })) do kinds[r.kind] = true end
        assert_true(kinds.bed_rest and kinds.no_sprint and kinds.no_heavy_work)
        assert_eq(EM.Signature(empty), '0000000000')
    end)
end)
