-- pfm-policejob equipment and the police hardening backlog (batch 18, unit 18C).
--   * props (cone, barrier, sign, tent, light, police line) and the riot shield are spawned by the
--     server and capped per officer, per kind and server-wide; taken up only by on-duty officers;
--   * the duty GPS goes only to on-duty leo/ems (no -1 broadcast of positions);
--   * information callbacks are gated (GetDutyPlayers, isPlayerDead, IsPoliceForcePresent);
--   * the cop count broadcast is rate limited;
--   * police alerts are structured: the client names a kind, the server builds the text;
--   * officer down / panic reach the MDT dispatch board;
--   * fingerprint scanner: on-duty officer, 2.5 m, a session, the scanned person's print only;
--   * GSR comes from weaponDamageEvent and casing reports (no self-report);
--   * K9 sniff: certified handler, server inventory decides; drone: item, bounded radius, logged;
--   * the static /cam cameras are retired in favour of the MDT CCTV.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end

local created, gone, frozen = {}, {}, {}
function CreateObjectNoOffset(model, x, y, z, networked)
    Mock.nextNetId = Mock.nextNetId + 1
    created[#created + 1] = { model = model, x = x, y = y, z = z, networked = networked, id = Mock.nextNetId }
    return Mock.nextNetId
end
local headings, weapons = {}, {}
function GetEntityHeading(e) return headings[e] or 0.0 end
function SetEntityHeading() end
function FreezeEntityPosition(e, on) frozen[e] = on end
function DoesEntityExist(e) return not gone[e] end
function GetSelectedPedWeapon(ped) return weapons[ped] or 0 end
function DeleteEntity(e) gone[e] = true Mock.deleted[#Mock.deleted + 1] = e end
Mock.plates, Mock.vehicleOf, Mock.models = {}, {}, {}

local resources = {}
function GetResourceState(name) return resources[name] or 'missing' end
local held, invs, quals, dispatch = {}, {}, {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    HasItem = function(_, src, item) return held[src] ~= nil and held[src][item] == true end,
    GetInventory = function(_, id) return invs[id] end,
}
Mock.exportsByResource['pf-government'] = {
    HasQualification = function(_, cid, qual) return quals[cid .. ':' .. qual] == true, 'granted' end,
}
Mock.exportsByResource['pf-policemdt-DEV'] = {
    CreateDispatchCall = function(_, call) dispatch[#dispatch + 1] = call return { id = 'C1' } end,
}
QBCoreMock.Shared.Weapons[GetHashKey('weapon_pistol')] = { name = 'weapon_pistol', label = 'Pistol', ammotype = 'AMMO_PISTOL' }
QBCoreMock.Shared.Weapons[GetHashKey('weapon_knife')] = { name = 'weapon_knife', label = 'Knife' }
QBCoreMock.Shared.Weapons[GetHashKey('weapon_stungun')] = { name = 'weapon_stungun', label = 'Taser', ammotype = 'AMMO_STUNGUN' }

PFPoliceSchema = { Ready = function() return true end }

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/config_equipment.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/commands.lua')
local mainDropped = Mock.eventHandlers['playerDropped']
load_resource('pfm-policejob/server/objects.lua')
local objectsSetDuty = Mock.eventHandlers['QBCore:Server:SetDuty']
local objectsDropped = Mock.eventHandlers['playerDropped']
load_resource('pfm-policejob/server/gameplay.lua')
load_resource('pfm-policejob/server/telemetry.lua')

local COP, COP2, CIV, MEDIC, SGT, OFFSGT = 1, 2, 3, 4, 5, 6
local PISTOL = GetHashKey('weapon_pistol')

local function eventsTo(name, target)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if e.target == target then out[#out + 1] = e end end
    return out
end
local function fire(handler, src, ...)
    source = src
    handler(...)
    source = nil
end

BeforeEach = function()
    for _, src in ipairs({ COP, COP2, CIV, MEDIC, SGT, OFFSGT }) do
        if Mock.players[src] then
            fire(objectsDropped, src)
            fire(Mock.eventHandlers['playerDropped'], src)
            fire(mainDropped, src)
        end
    end
    for src in pairs(PFTelemetry.recording) do PFTelemetry.recording[src] = nil end
    for i = #PFTelemetry.buffer, 1, -1 do PFTelemetry.buffer[i] = nil end
    Mock.reset()
    Mock.players, Mock.coords, Mock.deleted, Mock.plates, Mock.vehicleOf = {}, {}, {}, {}, {}
    created, gone, frozen, headings, weapons = {}, {}, {}, {}, {}
    held, invs, quals, dispatch, resources = {}, {}, {}, {}, {}
    Mock.gameTimer = Mock.gameTimer + 1000000
    Mock.clock = Mock.clock + 100000
    local function leo(src, cid, grade, onduty)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.job = { name = 'police', type = 'leo', onduty = onduty ~= false, grade = { level = grade or 0 } }
        p.PlayerData.metadata.callsign = '1-' .. cid
        p.PlayerData.metadata.fingerprint = 'FP-' .. cid
        return p
    end
    leo(COP, 'COPCID')
    leo(COP2, 'COP2CID')
    leo(SGT, 'SGTCID', 3)
    leo(OFFSGT, 'OFFSGTCID', 3, false)
    local civ = Mock.newPlayer(CIV, 'CIVCID')
    civ.PlayerData.metadata.fingerprint = 'FP-CIVCID'
    local medic = Mock.newPlayer(MEDIC, 'MEDCID')
    medic.PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 1 } }
    Mock.coords[COP] = vector3(100, 100, 30)
    Mock.coords[COP2] = vector3(500, 500, 30)
    Mock.coords[CIV] = vector3(101, 100, 30)
    Mock.coords[MEDIC] = vector3(900, 900, 30)
    Mock.coords[SGT] = vector3(1500, 1500, 30)
    Mock.coords[OFFSGT] = vector3(1600, 1600, 30)
end

-- ── props ────────────────────────────────────────────────────────────────────────────────────
describe('props are spawned by the server and capped', function()
    it('a cone is created by the server in front of the officer, networked', function()
        headings[COP] = 0.0
        Mock.fireNet('police:server:spawnObject', COP, 'cone')
        assert_eq(#created, 1)
        assert_eq(created[1].model, Config.Equipment.Props.Kinds.cone.model)
        assert_true(created[1].networked)
        assert_near(created[1].x, 100, 0.01)
        assert_near(created[1].y, 101, 0.01)
        assert_eq(eventsTo('police:client:PropPlaced', COP)[1].args[1], created[1].id)
        assert_eq(#Mock.clientEventsNamed('police:client:spawnObject'), 0) -- no client spawns it any more
    end)
    it('civilians, unknown kinds and officers in a vehicle place nothing', function()
        Mock.fireNet('police:server:spawnObject', CIV, 'cone')
        Mock.fireNet('police:server:spawnObject', COP, 'nuke')
        Mock.fireNet('police:server:spawnObject', COP, { 'cone' })
        Mock.vehicleOf[COP2] = 55
        Mock.fireNet('police:server:spawnObject', COP2, 'cone')
        assert_eq(#created, 0)
    end)
    it('per kind, per officer and server-wide caps hold; placements are rate limited', function()
        local tentMax = Config.Equipment.Props.Kinds.tent.max
        for _ = 1, tentMax + 3 do
            Mock.gameTimer = Mock.gameTimer + 5000
            Mock.fireNet('police:server:spawnObject', COP, 'tent')
        end
        assert_eq(#created, tentMax)
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('police:server:spawnObject', COP, 'cone')
        Mock.fireNet('police:server:spawnObject', COP, 'cone')     -- too soon after the last one
        assert_eq(#created, tentMax + 1)
        local per = Config.Equipment.Props.PerOfficer
        for _ = 1, per + 5 do
            Mock.gameTimer = Mock.gameTimer + 5000
            Mock.fireNet('police:server:spawnObject', COP, 'cone')
        end
        assert_eq(#created, per)
        local total = Config.Equipment.Props.Total
        Config.Equipment.Props.Total = per + 1
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('police:server:spawnObject', COP2, 'cone')
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('police:server:spawnObject', COP2, 'cone')
        Config.Equipment.Props.Total = total
        assert_eq(#created, per + 1)
    end)
    it('the police line prop exists', function()
        Mock.fireNet('police:server:spawnObject', COP, 'tape')
        assert_eq(#created, 1)
        assert_true(frozen[created[1].id])
    end)
    it('an on-duty officer takes up the nearest prop within range; the server deletes it', function()
        Mock.fireNet('police:server:spawnObject', COP, 'cone')
        local id = created[1].id
        Mock.coords[id] = vector3(100, 101, 29)
        Mock.fireNet('police:server:deleteObject', CIV, 12345)     -- not police
        Mock.fireNet('police:server:deleteObject', COP2)           -- too far
        assert_eq(#Mock.deleted, 0)
        Mock.coords[COP2] = vector3(101, 101, 30)
        Mock.fireNet('police:server:deleteObject', COP2, 99999)    -- the id argument is ignored
        assert_eq(Mock.deleted[1], id)
        assert_eq(#PoliceProps(), 0)
    end)
    it('going off duty or leaving takes the officer\'s props up; old props expire', function()
        Mock.fireNet('police:server:spawnObject', COP, 'cone')
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('police:server:spawnObject', COP2, 'cone')
        fire(objectsSetDuty, nil, COP, false)
        assert_eq(#PoliceProps(), 1)
        Mock.clock = Mock.clock + Config.Equipment.Props.LifetimeSeconds
        PolicePropSweep()
        assert_eq(#PoliceProps(), 0)
    end)
end)

describe('riot shield', function()
    it('needs the item and duty; one per officer; spawned by the server; second use takes it away', function()
        Mock.useables.riot_shield(COP)
        assert_eq(#created, 0)                                      -- no item
        held[CIV] = { riot_shield = true }
        Mock.useables.riot_shield(CIV)
        assert_eq(#created, 0)                                      -- not police
        held[COP] = { riot_shield = true }
        Mock.useables.riot_shield(COP)
        assert_eq(#created, 1)
        assert_eq(created[1].model, Config.Equipment.RiotShield.Model)
        assert_eq(eventsTo('police:client:AttachShield', COP)[1].args[1], created[1].id)
        Mock.useables.riot_shield(COP)
        assert_eq(Mock.deleted[1], created[1].id)
        assert_eq(PoliceShieldOf(COP), nil)
    end)
    it('is taken away when the officer no longer carries the item', function()
        held[COP] = { riot_shield = true }
        Mock.useables.riot_shield(COP)
        held[COP] = {}
        PolicePropSweep()
        assert_eq(PoliceShieldOf(COP), nil)
        assert_eq(#Mock.deleted, 1)
    end)
end)

-- ── duty GPS ─────────────────────────────────────────────────────────────────────────────────
describe('duty GPS', function()
    it('positions go only to on-duty leo/ems, never to every client', function()
        local n = PolicePushDutyBlips()
        assert_eq(n, 4)                                             -- COP, COP2, SGT, MEDIC
        local sent = Mock.clientEventsNamed('police:client:UpdateBlips')
        assert_eq(#sent, 4)
        local targets = {}
        for _, e in ipairs(sent) do
            assert_true(e.target ~= -1)
            targets[e.target] = true
        end
        assert_true(targets[MEDIC] and targets[COP])
        assert_eq(targets[CIV], nil)
        assert_eq(targets[OFFSGT], nil)
        assert_eq(#sent[1].args[1], 4)
    end)
    it('a request (no handler existed): officers get the list, anyone else an empty one; rate limited', function()
        Mock.fireNet('police:server:UpdateBlips', CIV)
        local civ = eventsTo('police:client:UpdateBlips', CIV)
        assert_eq(#civ, 1)
        assert_eq(#civ[1].args[1], 0)
        Mock.fireNet('police:server:UpdateBlips', COP)
        Mock.fireNet('police:server:UpdateBlips', COP)
        local cop = eventsTo('police:client:UpdateBlips', COP)
        assert_eq(#cop, 1)
        assert_eq(#cop[1].args[1], 4)
    end)
end)

-- ── information callbacks ────────────────────────────────────────────────────────────────────
describe('information callbacks', function()
    it('GetDutyPlayers answers only on-duty leo/ems', function()
        assert_eq(#Mock.callCallback('police:GetDutyPlayers', CIV), 0)
        assert_eq(#Mock.callCallback('police:GetDutyPlayers', OFFSGT), 0)
        assert_eq(#Mock.callCallback('police:GetDutyPlayers', COP), 3)
    end)
    it('isPlayerDead answers only about someone next to the caller', function()
        Mock.players[COP2].PlayerData.metadata.isdead = true
        assert_false(Mock.callCallback('police:server:isPlayerDead', CIV, COP2))   -- far away
        Mock.coords[COP2] = vector3(102, 100, 30)
        assert_true(Mock.callCallback('police:server:isPlayerDead', CIV, tostring(COP2)))
        assert_false(Mock.callCallback('police:server:isPlayerDead', CIV, 'nobody'))
    end)
    it('IsPoliceForcePresent: only on-duty LEO ask; off-duty ranks do not count', function()
        assert_false(Mock.callCallback('police:server:IsPoliceForcePresent', CIV))
        assert_true(Mock.callCallback('police:server:IsPoliceForcePresent', COP))
        Mock.players[SGT].PlayerData.job.onduty = false
        assert_false(Mock.callCallback('police:server:IsPoliceForcePresent', COP)) -- OFFSGT is off duty
    end)
end)

describe('cop count broadcast', function()
    it('a spamming client causes at most one broadcast per window; the next tick sends a pending one', function()
        for _ = 1, 20 do Mock.fireNet('police:server:UpdateCurrentCops', CIV) end
        for _ = 1, 20 do Mock.fireNet('police:server:UpdateCurrentCops', COP) end
        assert_eq(#Mock.clientEventsNamed('police:SetCopCount'), 1)
        assert_eq(Mock.clientEventsNamed('police:SetCopCount')[1].args[1], 3)
        PoliceCopCountTick()
        assert_eq(#Mock.clientEventsNamed('police:SetCopCount'), 1)
        Mock.clock = Mock.clock + Config.Equipment.CopCount.GlobalSeconds
        PoliceCopCountTick()
        assert_eq(#Mock.clientEventsNamed('police:SetCopCount'), 2)
    end)
end)

-- ── structured alerts ────────────────────────────────────────────────────────────────────────
describe('structured police alerts', function()
    local function alerts() return eventsTo('police:client:policeAlert', COP) end
    it('free text only picks the kind: officers read the server text', function()
        Mock.fireNet('police:server:policeAlert', CIV, 'OFFICER DOWN at the pier, all units!!!')
        local a = alerts()
        assert_eq(#a, 1)
        assert_eq(a[1].args[2], Config.Equipment.Alerts.Kinds.suspicious.text)
        Mock.fireNet('police:server:policeAlert', CIV, 'Storerobbery in progress')
        assert_eq(alerts()[2].args[2], Config.Equipment.Alerts.Kinds.storerobbery.text)
        assert_near(alerts()[2].args[1].x, 101, 0.01)               -- the caller's server position
    end)
    it('new callers name the kind; unknown kinds are dropped; the same kind twice is dropped', function()
        Mock.fireNet('police:server:Alert', CIV, 'bankrobbery')
        Mock.fireNet('police:server:Alert', CIV, 'bankrobbery')
        Mock.fireNet('police:server:Alert', CIV, 'zombies')
        assert_eq(#alerts(), 1)
        assert_eq(alerts()[1].args[2], Config.Equipment.Alerts.Kinds.bankrobbery.text)
    end)
    it('SendEmergencyMessage has a handler now and ignores the client position and text', function()
        Mock.fireNet('police:server:SendEmergencyMessage', CIV, { x = 9999, y = 9999, z = 0 }, 'Fake text')
        local a = alerts()
        assert_eq(#a, 1)
        assert_eq(a[1].args[2], Config.Equipment.Alerts.Kinds.emergency.text)
        assert_near(a[1].args[1].x, 101, 0.01)
    end)
end)

describe('officer down and panic reach the MDT dispatch board', function()
    it('panic creates an MDT call at the server position', function()
        resources['pf-policemdt-DEV'] = 'started'
        Mock.fireNet('police:server:Panic', COP)
        assert_eq(#dispatch, 1)
        assert_eq(dispatch[1].callType, 'panic')
        assert_near(dispatch[1].coords.x, 100, 0.01)
        Mock.fireNet('police:server:Panic', CIV)
        assert_eq(#dispatch, 1)
    end)
    it('officer down (really down) creates one', function()
        resources['pf-policemdt-DEV'] = 'started'
        Mock.players[COP].PlayerData.metadata.inlaststand = true
        Mock.fireNet('police:server:OfficerDown', COP)
        assert_eq(#dispatch, 1)
        assert_eq(dispatch[1].callType, 'officer_down')
    end)
end)

-- ── fingerprint scanner and tracker ──────────────────────────────────────────────────────────
describe('fingerprint scanner', function()
    it('a civilian cannot open it; an officer within 2.5 m can', function()
        Mock.fireNet('police:server:showFingerprint', CIV, COP)
        assert_eq(#Mock.clientEventsNamed('police:client:showFingerprint'), 0)
        Mock.fireNet('police:server:showFingerprint', COP, tostring(CIV))
        assert_eq(#Mock.clientEventsNamed('police:client:showFingerprint'), 2)
    end)
    it('a scan from either side shows the scanned person\'s print to both, and only within a session', function()
        Mock.fireNet('police:server:showFingerprintId', COP, CIV)            -- no session
        assert_eq(#Mock.clientEventsNamed('police:client:showFingerprintId'), 0)
        Mock.fireNet('police:server:showFingerprint', COP, CIV)
        Mock.fireNet('police:server:showFingerprintId', CIV, COP)            -- the suspect presses scan
        Mock.fireNet('police:server:showFingerprintId', COP, CIV)            -- the officer presses scan
        local shown = Mock.clientEventsNamed('police:client:showFingerprintId')
        assert_eq(#shown, 4)
        for _, e in ipairs(shown) do
            assert_eq(e.args[1], 'FP-CIVCID')
            assert_true(e.target == COP or e.target == CIV)
        end
        Mock.fireNet('police:server:showFingerprintId', COP2, CIV)           -- not part of the session
        assert_eq(#Mock.clientEventsNamed('police:client:showFingerprintId'), 4)
    end)
end)

describe('ankle tracker', function()
    it('string ids are converted; the player must be found', function()
        Mock.fireNet('police:server:SetTracker', COP, tostring(CIV))
        assert_true(Mock.players[CIV].PlayerData.metadata.tracker)
        Mock.fireNet('police:server:SetTracker', COP, { 'x' })
        assert_eq(#Mock.dropped, 0)
    end)
end)

-- ── GSR ──────────────────────────────────────────────────────────────────────────────────────
describe('gunshot residue comes from the server', function()
    local function gsrResult(target)
        Mock.reset()
        Mock.coords[target] = vector3(101, 100, 30)
        Mock.fireNet('police:server:GsrTest', COP, target)
        local n = eventsTo('QBCore:Notify', COP)
        return n[1] and n[1].args[1]
    end
    it('the old self-report changes nothing', function()
        Mock.fireNet('police:server:MarkGSR', CIV)
        assert_eq(Mock.players[CIV].PlayerData.metadata.gsr, nil)
        assert_eq(gsrResult(CIV), 'info.gsr_negative')
    end)
    it('a firearm hit seen by weaponDamageEvent makes the shooter test positive', function()
        Mock.fireEvent('weaponDamageEvent', nil, CIV, { weaponType = GetHashKey('weapon_knife') })
        assert_eq(gsrResult(CIV), 'info.gsr_negative')
        Mock.fireEvent('weaponDamageEvent', nil, CIV, { weaponType = PISTOL })
        assert_eq(gsrResult(CIV), 'info.gsr_positive')
        assert_eq(Mock.players[CIV].PlayerData.metadata.gsr, Mock.clock)  -- survives a relog
    end)
    it('a casing report counts when the weapon is a firearm and matches the one in hand', function()
        weapons[CIV] = GetHashKey('weapon_knife')
        Mock.fireEvent('evidence:server:CreateCasing', CIV, PISTOL)
        assert_eq(gsrResult(CIV), 'info.gsr_negative')
        weapons[CIV] = PISTOL
        Mock.fireEvent('evidence:server:CreateCasing', CIV, PISTOL)
        assert_eq(gsrResult(CIV), 'info.gsr_positive')
    end)
    it('the metadata is written at most every MetaWriteSeconds', function()
        Mock.fireEvent('weaponDamageEvent', nil, CIV, { weaponType = PISTOL })
        local first = Mock.players[CIV].PlayerData.metadata.gsr
        Mock.clock = Mock.clock + 5
        Mock.fireEvent('weaponDamageEvent', nil, CIV, { weaponType = PISTOL })
        assert_eq(Mock.players[CIV].PlayerData.metadata.gsr, first)
        assert_eq(gsrResult(CIV), 'info.gsr_positive')
    end)
    it('a recording officer\'s server-seen shot and taser use land in the timeline', function()
        held[COP] = { bodycam = true }
        Mock.useables.bodycam(COP)
        Mock.fireEvent('weaponDamageEvent', nil, COP, { weaponType = PISTOL })
        Mock.fireEvent('weaponDamageEvent', nil, COP, { weaponType = GetHashKey('weapon_stungun') })
        local kinds = {}
        for _, r in ipairs(PFTelemetry.buffer) do kinds[r.kind] = (kinds[r.kind] or 0) + 1 end
        assert_eq(kinds.shot_hit, 1)
        assert_eq(kinds.taser, 1)
    end)
end)

-- ── K9 ───────────────────────────────────────────────────────────────────────────────────────
describe('K9 sniff search', function()
    local function sniff(src, kind, target) return PFGameplay.K9Sniff(src, kind, target) end
    it('needs a certified handler; fails closed when pf-government is not running', function()
        Mock.players[CIV].PlayerData.items = { { name = 'cokebaggy', amount = 2 } }
        quals['COPCID:k9'] = true
        assert_eq(sniff(COP, 'player', CIV).error, 'k9_no_qual')   -- pf-government stopped
        resources['pf-government'] = 'started'
        assert_eq(sniff(COP2, 'player', CIV).error, 'k9_no_qual')
        assert_eq(sniff(CIV, 'player', COP).error, 'on_duty_police_only')
        local r = sniff(COP, 'player', CIV)
        assert_true(r.ok)
        assert_true(r.alert)
    end)
    it('alerts exactly when the server finds a drug item; distance and cooldown hold', function()
        resources['pf-government'] = 'started'
        quals['COPCID:k9'] = true
        Mock.players[CIV].PlayerData.items = { { name = 'sandwich', amount = 1 } }
        assert_false(sniff(COP, 'player', CIV).alert)
        assert_eq(sniff(COP, 'player', CIV).error, 'k9_cooldown')
        Mock.clock = Mock.clock + Config.Equipment.K9.CooldownSeconds
        Mock.coords[CIV] = vector3(120, 100, 30)
        assert_eq(sniff(COP, 'player', CIV).error, 'k9_too_far')
    end)
    it('a vehicle: its trunk and glovebox (padded or trimmed plate)', function()
        resources['pf-government'] = 'started'
        quals['COPCID:k9'] = true
        Mock.coords[700] = vector3(103, 100, 30)
        Mock.plates[700] = ' ABC123 '
        invs['trunk-ABC123'] = { items = { [3] = { name = 'weed_brick', amount = 1 } } }
        local r = sniff(COP, 'vehicle', 700)
        assert_true(r.ok)
        assert_true(r.alert)
    end)
    it('the net event notifies the handler only', function()
        resources['pf-government'] = 'started'
        quals['COPCID:k9'] = true
        Mock.fireNet('police:server:K9Sniff', COP, 'player', CIV)
        local n = eventsTo('QBCore:Notify', COP)
        assert_eq(n[1].args[1], Config.Equipment.Text.k9_clear)
        assert_eq(#eventsTo('QBCore:Notify', CIV), 0)
    end)
end)

-- ── drone ────────────────────────────────────────────────────────────────────────────────────
describe('drone', function()
    it('needs the item and duty; out-of-range hints land it; flights are logged', function()
        assert_eq(PFGameplay.DroneStart(COP).error, 'no_item')
        held[CIV] = { police_drone = true }
        assert_eq(PFGameplay.DroneStart(CIV).error, 'on_duty_police_only')
        held[COP] = { police_drone = true, bodycam = true }
        Mock.useables.bodycam(COP)
        assert_true(PFGameplay.DroneStart(COP).ok)
        local start = eventsTo('police:client:DroneStart', COP)[1]
        assert_near(start.args[1].x, 100, 0.01)
        assert_eq(start.args[2], Config.Equipment.Drone.Radius)
        assert_true(PFGameplay.DroneHint(COP, 150, 150, 60))
        Mock.gameTimer = Mock.gameTimer + 1000
        assert_false(PFGameplay.DroneHint(COP, 100 + Config.Equipment.Drone.Radius + 100, 100, 60))
        assert_eq(eventsTo('police:client:DroneStop', COP)[1].args[1], 'range')
        local events = {}
        for _, r in ipairs(PFTelemetry.buffer) do
            if r.kind == 'drone' then events[#events + 1] = json.decode(r.data).event end
        end
        assert_eq(table.concat(events, ','), 'start,position,end')
    end)
    it('the time limit and going off duty land it; a cooldown follows', function()
        held[COP] = { police_drone = true }
        assert_true(PFGameplay.DroneStart(COP).ok)
        Mock.clock = Mock.clock + Config.Equipment.Drone.MaxSeconds
        PFGameplay.DroneTick()
        assert_eq(eventsTo('police:client:DroneStop', COP)[1].args[1], 'time')
        assert_eq(PFGameplay.DroneStart(COP).error, 'drone_busy')
        Mock.clock = Mock.clock + Config.Equipment.Drone.CooldownSeconds
        assert_true(PFGameplay.DroneStart(COP).ok)
        Mock.players[COP].PlayerData.job.onduty = false
        PFGameplay.DroneTick()
        assert_eq(eventsTo('police:client:DroneStop', COP)[2].args[1], 'off_duty')
    end)
end)

-- ── static cameras ───────────────────────────────────────────────────────────────────────────
describe('static /cam cameras are retired', function()
    it('the client no longer creates a camera for /cam', function()
        local src = __readfile('pfm-policejob/client/camera.lua')
        assert_eq(src:find('CreateCam', 1, true), nil)
        assert_true(src:find('MDT CCTV', 1, true) ~= nil)
    end)
end)
