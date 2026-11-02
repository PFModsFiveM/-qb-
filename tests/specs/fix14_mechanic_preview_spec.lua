-- pf-mechanicjob cosmetic preview (MECH-X5, server/preview.lua): an on-duty mechanic driving a car
-- opens a session for it; the server keeps the car's look from that moment (cosmetic parts only).
-- Only while it is open, and only for cosmetic mod types, are preview changes shown to everyone;
-- ending it puts the stored look back (never a client's "snapshot"). Walking away ends it. Any
-- player within 30 m used to send any mod type or any snapshot to every client.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
local existing = {}
function DoesEntityExist(e) return existing[e] == true end

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/server/preview.lua')

local MECH, STRANGER, OFFDUTY = 1, 2, 3
local CAR, TUNED = 500, 501
local HERE = vector3(0.0, 0.0, 0.0)
local SNAP = { mods = { [0] = 2, [11] = 3, [48] = 1 }, wheelType = 1, windowTint = 2,
    colors = { classic = { primary = 12, secondary = 5, pearl = 0, wheel = 4 }, customPrimary = { r = 10, g = 20, b = 30 }, junk = 'x' } }

local function sent(name) return Mock.clientEventsNamed(name) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.vehicleOf = {}, {}, {}
    existing = { [CAR] = true, [TUNED] = true }
    Mock.newPlayer(MECH).PlayerData.job = { name = 'mechanic', onduty = true }
    Mock.newPlayer(STRANGER).PlayerData.job = { name = 'unemployed' }
    Mock.newPlayer(OFFDUTY).PlayerData.job = { name = 'mechanic', onduty = false }
    for _, e in ipairs({ MECH, STRANGER, OFFDUTY, CAR, TUNED }) do Mock.coords[e] = HERE end
    Mock.vehicleOf = { [MECH] = CAR, [STRANGER] = TUNED }
    for _, src in ipairs({ MECH, STRANGER, OFFDUTY }) do Mock.fireEvent('playerDropped', src) end
    Mock.reset()
end

describe('MECH-X5 preview sessions', function()
    it("a passer-by cannot strip a tuned car (the old exploit)", function()
        Mock.fireNet('pf_mech:preview:syncMod', STRANGER, TUNED, 11, -1)
        Mock.fireNet('pf_mech:preview:restore', STRANGER, TUNED, { mods = { [11] = -1 } })
        Mock.fireNet('pf_mech:preview:begin', STRANGER, TUNED, SNAP)          -- drives it, not a mechanic
        Mock.fireNet('pf_mech:preview:syncMod', STRANGER, TUNED, 0, 1)
        assert_eq(#Mock.clientEvents, 0)
    end)

    it('only an on-duty mechanic driving the car opens a session', function()
        Mock.vehicleOf[OFFDUTY] = TUNED
        Mock.fireNet('pf_mech:preview:begin', OFFDUTY, TUNED, SNAP)
        Mock.fireNet('pf_mech:preview:syncMod', OFFDUTY, TUNED, 0, 1)
        Mock.fireNet('pf_mech:preview:begin', MECH, TUNED, SNAP)              -- not driving that one
        Mock.fireNet('pf_mech:preview:syncMod', MECH, TUNED, 0, 1)
        assert_eq(#Mock.clientEvents, 0)
        Mock.fireNet('pf_mech:preview:begin', MECH, CAR, SNAP)
        Mock.fireNet('pf_mech:preview:syncMod', MECH, CAR, 0, 1)
        assert_eq(#sent('pf_mech:preview:applyModClient'), 1)
    end)

    it('cosmetic mod types, tints and paints from fixed ranges only', function()
        Mock.fireNet('pf_mech:preview:begin', MECH, CAR, SNAP)
        for _, bad in ipairs({ { 11, 3 }, { 16, -1 }, { 18, 0 }, { 0, 999 }, { 0, 1.5 } }) do
            Mock.fireNet('pf_mech:preview:syncMod', MECH, CAR, bad[1], bad[2])
        end
        Mock.fireNet('pf_mech:preview:syncTint', MECH, CAR, 50)
        Mock.fireNet('pf_mech:preview:syncPaint', MECH, CAR, 'engine', 3)
        Mock.fireNet('pf_mech:preview:syncPaint', MECH, CAR, 'primary', 5000)
        assert_eq(#Mock.clientEvents, 0)
        Mock.fireNet('pf_mech:preview:syncMod', MECH, CAR, 23, 4)
        Mock.fireNet('pf_mech:preview:syncTint', MECH, CAR, 3)
        Mock.fireNet('pf_mech:preview:syncPaint', MECH, CAR, 'pearl', 70)
        assert_eq(#Mock.clientEvents, 3)
    end)

    it("ending restores the look stored at the start, not the client's, cosmetic parts only", function()
        Mock.fireNet('pf_mech:preview:begin', MECH, CAR, SNAP)
        Mock.fireNet('pf_mech:preview:restore', MECH, CAR, { mods = { [11] = -1, [0] = 9 } })
        local r = sent('pf_mech:preview:restoreSnapshotClient')
        assert_eq(#r, 1)
        local snap = r[1].args[2]
        assert_eq(snap.mods[0], 2)
        assert_eq(snap.mods[48], 1)
        assert_eq(snap.mods[11], nil, 'never an engine level')
        assert_eq(snap.colors.classic.primary, 12)
        assert_eq(snap.colors.customPrimary.b, 30)
        assert_eq(snap.colors.junk, nil)
        Mock.fireNet('pf_mech:preview:syncMod', MECH, CAR, 0, 1)            -- the session is over
        assert_eq(#sent('pf_mech:preview:applyModClient'), 0)
    end)

    it('walking away ends the session and puts the look back', function()
        Mock.fireNet('pf_mech:preview:begin', MECH, CAR, SNAP)
        Mock.coords[MECH] = vector3(50.0, 0.0, 0.0)
        Mock.fireNet('pf_mech:preview:syncMod', MECH, CAR, 0, 1)
        assert_eq(#sent('pf_mech:preview:applyModClient'), 0)
        assert_eq(#sent('pf_mech:preview:restoreSnapshotClient'), 1)
        Mock.coords[MECH] = HERE
        Mock.fireNet('pf_mech:preview:syncMod', MECH, CAR, 0, 1)
        assert_eq(#sent('pf_mech:preview:applyModClient'), 0)
    end)
end)
