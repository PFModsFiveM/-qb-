-- Batch 18A: field custody (pfm-policejob server/custody_field.lua and server/interactions.lua).
-- Surrender, detain, frisk, zipties, escort/carry, server-chosen seats, arrest -> pf-justice
-- OpenCustody, release at the scene, hand-over between officers, property seizure, holding cells,
-- GetFieldState, the SeizeDriverLicense fix and the use-of-force marks. Civilians may still drag a
-- cuffed or downed player but cannot detain or frisk; every action is within 2.5 m and rate limited;
-- an escort ends (target released) when the escorting player drops.
-- pf-justice, the evidence API, telemetry (18C) and pfm-doorlock are contract stubs here.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.Commands.Add = function() end

local states = { ['pf-justice'] = 'started', ['pfm-doorlock'] = 'started', ['pfm-prison'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end

-- inventory: items per player are Mock players' PlayerData.items
local inv = { removed = {}, added = {}, has = {} }
Mock.exportsByResource['pfm-inventory'] = {
    OpenInventoryById = function() return true end,
    AddItem = function(_, src, name, amount, slot, info, why)
        inv.added[#inv.added + 1] = { src = src, name = name, slot = slot, info = info, why = why }
        local P = Mock.players[src]
        if P and slot then P.PlayerData.items[slot] = { name = name, slot = slot, amount = amount, info = info, type = name:find('^weapon_') and 'weapon' or 'item' } end
        return true
    end,
    RemoveItem = function(_, src, name, amount, slot, why)
        local P = Mock.players[src]
        if not P then return false end
        if slot then
            local it = P.PlayerData.items[slot]
            if not it or it.name ~= name then return false end
            P.PlayerData.items[slot] = nil
        else
            local found
            for s, it in pairs(P.PlayerData.items) do if it.name == name then found = s break end end
            if not found then return false end
            P.PlayerData.items[found] = nil
        end
        inv.removed[#inv.removed + 1] = { src = src, name = name, slot = slot, why = why }
        return true
    end,
    HasItem = function(_, src, name) return inv.has[src] and inv.has[src][name] == true or false end,
}

-- telemetry (18C contract: MarkTimeline(who, kind, data))
local marks = {}
Mock.exportsByResource['pfm-policejob'] = {
    MarkTimeline = function(_, who, kind, data) marks[#marks + 1] = { who = who, kind = kind, data = data } return { ok = true } end,
}
local function marked(kind, who)
    local out = {}
    for _, m in ipairs(marks) do if m.kind == kind and (who == nil or m.who == who) then out[#out + 1] = m end end
    return out
end

-- pfm-doorlock SetDoorState (15H contract)
local doors = {}
Mock.exportsByResource['pfm-doorlock'] = {
    SetDoorState = function(_, door, locked) doors[#doors + 1] = { door = door, locked = locked } return { ok = true, doorId = door, locked = locked, changed = true } end,
}

-- pf-justice (15C contract)
local JU
local function resetJU()
    JU = { calls = {}, custody = nil, open = { ok = true, custodyId = 41, state = 'arrested' }, release = { ok = true },
        cell = { ok = true }, seize = { ok = true, receiptId = 9, items = 3 }, setState = { ok = true } }
end
resetJU()
local function rec(name, ...) JU.calls[#JU.calls + 1] = { name = name, args = { ... } } end
local function called(name) local out = {} for _, c in ipairs(JU.calls) do if c.name == name then out[#out + 1] = c end end return out end
Mock.exportsByResource['pf-justice'] = {
    LegacyRuntimeLive = function() return false end,
    IsIncarcerated = function() return false end,
    GetCustody = function(_, who) rec('GetCustody', who) return { ok = true, custody = JU.custody } end,
    OpenCustody = function(_, target, opts) rec('OpenCustody', target, opts) return JU.open end,
    SetCustodyState = function(_, id, to, opts) rec('SetCustodyState', id, to, opts) return JU.setState end,
    AddCustodyLog = function(_, id, kind, data, opts) rec('AddCustodyLog', id, kind, data, opts) return { ok = true, logId = 1 } end,
    ReleaseFromCustody = function(_, id, reason, opts) rec('ReleaseFromCustody', id, reason, opts) return JU.release end,
    SeizeProperty = function(_, target, opts) rec('SeizeProperty', target, opts) return JU.seize end,
    AssignHoldingCell = function(_, id, cell, opts) rec('AssignHoldingCell', id, cell, opts) return JU.cell end,
}

-- evidence API (15D, same resource): the bag goes to the officer
local evidence = { calls = {}, answer = nil }
PFEvidence = { Api = { CreateEvidence = function(spec, opts)
    evidence.calls[#evidence.calls + 1] = { spec = spec, opts = opts }
    return evidence.answer or { ok = true, evidenceId = 501, tag = 'EV-501' }
end } }

-- state bags with set()
local bags = {}
function Player(src)
    bags[src] = bags[src] or { state = { set = function(self, k, v) self[k] = v end } }
    return bags[src]
end

-- vehicles: seat occupancy, models with a fixed set of seats, server SetPedIntoVehicle
local vehicles, seatsOf, occupant = {}, {}, {}
function GetAllVehicles() return vehicles end
function GetEntityType(e) return seatsOf[e] and 2 or 1 end
function GetPedInVehicleSeat(veh, seat) return (occupant[veh] or {})[seat] or 0 end
function SetPedIntoVehicle(ped, veh, seat)
    if not seatsOf[veh] or not seatsOf[veh][seat] then return end -- that model has no such seat
    occupant[veh] = occupant[veh] or {}
    occupant[veh][seat] = ped
    Mock.vehicleOf[ped] = veh
end
local timers = {}
function SetTimeout(_, fn) timers[#timers + 1] = fn end

QBCoreMock.Shared.Items = QBCoreMock.Shared.Items or {}
QBCoreMock.Shared.Items['weapon_pistol'] = { name = 'weapon_pistol', label = 'Pistol', type = 'weapon' }
QBCoreMock.Shared.Items['lockpick'] = { name = 'lockpick', label = 'Lockpick', type = 'item' }
QBCoreMock.Shared.Items['zipties'] = { name = 'zipties', label = 'Zipties', type = 'item' }

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/commands.lua')
load_resource('pfm-policejob/server/interactions.lua')
load_resource('pfm-policejob/server/custody_field.lua')

local COP, SUS, CIV, COP2 = 1, 2, 3, 4
local function meta(src) return Mock.players[src].PlayerData.metadata end
local function bag(src) return bags[src] and bags[src].state['pf:escort'] end
local function events(name, target)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if target == nil or e.target == target then out[#out + 1] = e end end
    return out
end
local function last(name, target) local l = events(name, target) return l[#l] end
local function lastNotify(src) local e = last('QBCore:Notify', src) return e and e.args[1] end
local function tick() Mock.gameTimer = Mock.gameTimer + 2000 end -- past the 1 s rate limit
local function fire(name, src, ...) tick() Mock.fireNet(name, src, ...) end

BeforeEach = function()
    for _, src in ipairs({ COP, SUS, CIV, COP2 }) do if Mock.players[src] then Mock.fireEvent('playerDropped', src) end end
    Mock.reset()
    Mock.players, Mock.coords, Mock.dropped, Mock.vehicleOf = {}, {}, {}, {}
    bags, marks, doors, timers = {}, {}, {}, {}
    vehicles, seatsOf, occupant = {}, {}, {}
    inv = { removed = {}, added = {}, has = {} }
    evidence = { calls = {}, answer = nil }
    resetJU()
    Mock.gameTimer = Mock.gameTimer + 600000
    Mock.clock = Mock.clock + 3600
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 2 } }
    cop.PlayerData.items = { [1] = { name = 'zipties', slot = 1, amount = 5, type = 'item' } }
    local cop2 = Mock.newPlayer(COP2, 'COP2CID')
    cop2.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } }
    local s = Mock.newPlayer(SUS, 'SUSCID')
    s.PlayerData.metadata.ishandcuffed = false
    s.PlayerData.metadata.licences = { driver = true, weapon = true, business = false, pilot = true }
    s.PlayerData.items = {
        [3] = { name = 'weapon_pistol', slot = 3, amount = 1, type = 'weapon', info = { serie = 'SER123' } },
        [4] = { name = 'lockpick', slot = 4, amount = 1, type = 'item' },
    }
    local c = Mock.newPlayer(CIV, 'CIVCID')
    c.PlayerData.items = { [1] = { name = 'zipties', slot = 1, amount = 2, type = 'item' } }
    Mock.coords[COP] = vector3(0, 0, 0)
    Mock.coords[SUS] = vector3(1, 0, 0)
    Mock.coords[CIV] = vector3(0, 1, 0)
    Mock.coords[COP2] = vector3(1, 1, 0)
end

local function cuffSuspect()
    fire('police:server:CuffPlayer', COP, SUS, true) -- officer softcuff: no resist window
    assert_eq(meta(SUS).ishandcuffed, true)
end

describe('surrender and detain', function()
    it('surrendering raises the hands (server bag) for 120 s, then they come down', function()
        fire('police:server:Surrender', SUS)
        assert_eq(bag(SUS).state, 'surrendered')
        assert_eq(last('police:client:FieldState', SUS).args[1], 'surrendered')
        PoliceField.Sweep(Mock.clock + 119)
        assert_eq(bag(SUS).state, 'surrendered')
        PoliceField.Sweep(Mock.clock + 120)
        assert_eq(bag(SUS), nil)
    end)
    it('an officer detains a surrendered suspect; a free one cannot be detained; again releases', function()
        fire('police:server:Detain', COP, SUS)
        assert_eq(bag(SUS), nil, 'not surrendered, cuffed or down')
        fire('police:server:Surrender', SUS)
        fire('police:server:Detain', COP, SUS)
        assert_eq(bag(SUS).state, 'detained')
        assert_eq(bag(SUS).by, COP)
        assert_eq(#marked('detain', COP), 1)
        assert_eq(#called('OpenCustody'), 0, 'detention creates no custody record')
        fire('police:server:Detain', COP, SUS)
        assert_eq(bag(SUS), nil)
    end)
    it('civilians cannot detain or frisk, even a cuffed or downed player', function()
        cuffSuspect()
        fire('police:server:Detain', CIV, SUS)
        assert_eq(bag(SUS), nil)
        fire('police:server:Frisk', CIV, SUS)
        assert_eq(#events('police:client:FriskResult'), 0)
        meta(SUS).isdead = true
        fire('police:server:Detain', CIV, SUS)
        fire('police:server:Frisk', CIV, SUS)
        assert_eq(bag(SUS), nil)
        assert_eq(#events('police:client:FriskResult'), 0)
    end)
    it('every field action is refused beyond 2.5 m (server positions)', function()
        fire('police:server:Surrender', SUS)
        Mock.coords[SUS] = vector3(2.6, 0, 0)
        fire('police:server:Detain', COP, SUS)
        fire('police:server:Frisk', COP, SUS)
        fire('police:server:Ziptie', COP, SUS)
        assert_eq(bag(SUS).state, 'surrendered')
        assert_eq(#events('police:client:FriskResult'), 0)
        assert_eq(meta(SUS).ishandcuffed == true, false)
        meta(SUS).ishandcuffed = true
        fire('police:server:Arrest', COP, SUS)
        fire('police:server:EscortPlayer', COP, SUS)
        assert_eq(#called('OpenCustody'), 0)
        assert_eq(#events('police:client:SetEscorted'), 0)
    end)
    it('one action of a kind per second per player', function()
        fire('police:server:Surrender', SUS)
        Mock.fireNet('police:server:Detain', COP, SUS)
        Mock.fireNet('police:server:Detain', COP, SUS) -- same second: ignored, still detained
        assert_eq(bag(SUS).state, 'detained')
        tick()
        Mock.fireNet('police:server:Detain', COP, SUS)
        assert_eq(bag(SUS), nil)
    end)
    it('ids that are not online players are ignored', function()
        fire('police:server:Surrender', SUS)
        fire('police:server:Detain', COP, 'x')
        fire('police:server:Detain', COP, { 2 })
        fire('police:server:Detain', COP, 2.5)
        assert_eq(bag(SUS).state, 'surrendered')
        fire('police:server:Detain', COP, '2') -- a numeric string is the same player
        assert_eq(bag(SUS).state, 'detained')
    end)
end)

describe('frisk', function()
    it('lists only the weapons the server sees and seizes one into evidence for the officer', function()
        fire('police:server:Surrender', SUS)
        fire('police:server:Frisk', COP, SUS)
        local res = last('police:client:FriskResult', COP)
        assert_eq(#res.args[2], 1)
        assert_eq(res.args[2][1].name, 'weapon_pistol')
        assert_eq(res.args[2][1].serial, 'SER123')
        assert_eq(#marked('frisk', COP), 1)
        fire('police:server:FriskSeize', COP, SUS, 4) -- the lockpick was not listed
        assert_eq(#evidence.calls, 0)
        fire('police:server:FriskSeize', COP, SUS, 3)
        assert_eq(Mock.players[SUS].PlayerData.items[3], nil, 'the weapon left the suspect')
        assert_eq(#evidence.calls, 1)
        local c = evidence.calls[1]
        assert_eq(c.spec.kind, 'weapon')
        assert_eq(c.spec.attrs.serial, 'SER123')
        assert_eq(c.spec.collectedBy, COP)
        assert_eq(c.opts.giveTo, COP)
        assert_true(type(c.opts.key) == 'string' and c.opts.key:find('^pfm%-policejob:frisk:SUSCID:') ~= nil)
        fire('police:server:FriskSeize', COP, SUS, 3) -- once only
        assert_eq(#evidence.calls, 1)
    end)
    it('an item moved since the pat-down is not taken, and a failed record hands the weapon back', function()
        fire('police:server:Surrender', SUS)
        fire('police:server:Frisk', COP, SUS)
        Mock.players[SUS].PlayerData.items[3].info = { serie = 'OTHER' }
        fire('police:server:FriskSeize', COP, SUS, 3)
        assert_eq(#evidence.calls, 0)
        Mock.players[SUS].PlayerData.items[3].info = { serie = 'SER123' }
        fire('police:server:Frisk', COP, SUS)
        evidence.answer = { ok = false, error = 'db_unavailable', message = 'down' }
        fire('police:server:FriskSeize', COP, SUS, 3)
        assert_eq(Mock.players[SUS].PlayerData.items[3].name, 'weapon_pistol', 'given back')
    end)
    it('a pat-down list expires', function()
        fire('police:server:Surrender', SUS)
        fire('police:server:Frisk', COP, SUS)
        Mock.clock = Mock.clock + Config.CustodyField.FriskSeconds + 1
        fire('police:server:FriskSeize', COP, SUS, 3)
        assert_eq(#evidence.calls, 0)
    end)
end)

describe('zipties', function()
    it('a ziptie uses one item and is the same server cuff state (soft, kind ziptie)', function()
        fire('police:server:Ziptie', CIV, SUS)
        assert_eq(meta(SUS).ishandcuffed == true, false, 'hands not up: refused')
        assert_eq(#inv.removed, 0)
        fire('police:server:Surrender', SUS)
        fire('police:server:Ziptie', CIV, SUS)
        assert_eq(meta(SUS).ishandcuffed, true)
        assert_eq(inv.removed[1].name, 'zipties')
        assert_eq(inv.removed[1].src, CIV)
        local cuff = last('police:client:SetCuffed', SUS)
        assert_eq(cuff.args[1], true)
        assert_eq(cuff.args[2], true, 'soft')
        assert_eq(PoliceCuffRecord(SUS).kind, 'ziptie')
        assert_eq(Mock.selfExport('GetFieldState')(SUS).cuffKind, 'ziptie')
        assert_eq(bag(SUS), nil, 'the hands-up state ends with the restraint')
    end)
    it('without a ziptie item nothing happens', function()
        Mock.players[CIV].PlayerData.items = {}
        fire('police:server:Surrender', SUS)
        fire('police:server:Ziptie', CIV, SUS)
        assert_eq(meta(SUS).ishandcuffed == true, false)
    end)
    it('zipties are cut, not unlocked: a civilian needs a cutter; officers may always', function()
        fire('police:server:Surrender', SUS)
        fire('police:server:Ziptie', CIV, SUS)
        Mock.players[CIV].GetItemByName = function(name) return name == 'handcuffs' and { name = 'handcuffs' } or nil end
        fire('police:server:CuffPlayer', CIV, SUS, true) -- a handcuff key does not open zipties
        assert_eq(meta(SUS).ishandcuffed, true)
        fire('police:server:CutZiptie', CIV, SUS)
        assert_eq(meta(SUS).ishandcuffed, true)
        inv.has[CIV] = { ziptie_cutter = true }
        fire('police:server:CutZiptie', CIV, SUS)
        assert_eq(meta(SUS).ishandcuffed, false)
    end)
    it('an officer\'s ziptie or cuffs are use-of-force marks on their timeline', function()
        fire('police:server:Surrender', SUS)
        fire('police:server:Ziptie', COP, SUS)
        assert_eq(marked('use_of_force', COP)[1].data.kind, 'ziptie')
        Mock.players[SUS].PlayerData.metadata.ishandcuffed = false
        PoliceSetCuffed(SUS, false)
        cuffSuspect()
        assert_eq(marked('use_of_force', COP)[2].data.kind, 'handcuffs')
    end)
end)

describe('escort and carry', function()
    it('civilians keep dragging a cuffed or downed player, not a free one', function()
        fire('police:server:EscortPlayer', CIV, SUS)
        assert_eq(#events('police:client:SetEscorted'), 0)
        cuffSuspect()
        fire('police:server:EscortPlayer', CIV, SUS)
        local e = last('police:client:SetEscorted', SUS)
        assert_eq(e.args[1], true)
        assert_eq(e.args[2], CIV)
        assert_eq(bag(SUS).state, 'escorted')
        fire('police:server:EscortPlayer', CIV, SUS) -- the same player lets go
        assert_eq(last('police:client:SetEscorted', SUS).args[1], false)
        meta(SUS).ishandcuffed = false
        meta(SUS).isdead = true
        fire('police:server:KidnapPlayer', CIV, SUS)
        assert_eq(bag(SUS).state, 'carried')
    end)
    it('an officer escorts a detained (uncuffed) suspect; nobody else takes a held suspect', function()
        fire('police:server:Surrender', SUS)
        fire('police:server:Detain', COP, SUS)
        fire('police:server:EscortPlayer', COP, SUS)
        assert_eq(bag(SUS).state, 'escorted')
        meta(SUS).ishandcuffed = true
        fire('police:server:EscortPlayer', CIV, SUS)
        assert_eq(bag(SUS).by, COP)
    end)
    it('when the escorting officer drops the target is released from the escort', function()
        cuffSuspect()
        fire('police:server:EscortPlayer', COP, SUS)
        assert_eq(bag(SUS).state, 'escorted')
        Mock.fireEvent('playerDropped', COP)
        local e = last('police:client:SetEscorted', SUS)
        assert_eq(e.args[1], false)
        assert_eq(bag(SUS), nil)
        assert_eq(Mock.selfExport('GetFieldState')(SUS).state, 'free')
        assert_eq(meta(SUS).ishandcuffed, true, 'the cuffs stay as they were')
    end)
    it('the target dropping ends the escort for the escorting player too', function()
        cuffSuspect()
        fire('police:server:KidnapPlayer', CIV, SUS)
        Mock.fireEvent('playerDropped', SUS)
        local e = last('police:client:EscortEnded', CIV)
        assert_eq(e.args[2], 'carry')
    end)
    it('an escort that rested on the cuffs ends when they come off', function()
        cuffSuspect()
        fire('police:server:EscortPlayer', CIV, SUS)
        PoliceSetCuffed(SUS, false)
        assert_eq(bag(SUS), nil)
    end)
end)

describe('vehicle placement (seat chosen by the server)', function()
    local CAR = 500
    local function car(seats)
        vehicles = { CAR }
        seatsOf[CAR] = seats
        Mock.coords[CAR] = vector3(2, 0, 0)
    end
    it('the first free rear seat; the server verifies and moves the custody to in_transport', function()
        car({ [-1] = true, [0] = true, [1] = true, [2] = true })
        occupant[CAR] = { [1] = 77 }
        cuffSuspect()
        JU.custody = { id = 41, state = 'arrested', officerCid = 'COPCID' }
        fire('police:server:PutPlayerInVehicle', COP, SUS, CAR)
        local put = last('police:client:PutInVehicle', SUS)
        assert_eq(put.args[2], 2, 'seat 1 is taken')
        assert_eq(Mock.vehicleOf[SUS], CAR)
        assert_true(PoliceField.VerifySeat(SUS))
        assert_eq(bag(SUS).state, 'in_vehicle')
        local s = called('SetCustodyState')
        assert_eq(s[1].args[2], 'in_transport')
        assert_eq(s[1].args[3].actor.src, COP)
        local st = Mock.selfExport('GetFieldState')(SUS)
        assert_eq(st.vehicle, CAR)
        assert_eq(st.seat, 2)
        -- out again: back to arrested
        JU.custody.state = 'in_transport'
        fire('police:server:SetPlayerOutVehicle', COP, SUS)
        assert_eq(called('SetCustodyState')[2].args[2], 'arrested')
        assert_eq(#events('police:client:SetOutVehicle', SUS), 1)
    end)
    it('a seat the model does not have is skipped after the check; none left tells the officer', function()
        car({ [-1] = true, [0] = true }) -- a two-door car: no rear seats
        cuffSuspect()
        fire('police:server:PutPlayerInVehicle', COP, SUS, CAR)
        assert_eq(last('police:client:PutInVehicle', SUS).args[2], 1)
        for _ = 1, 6 do PoliceField.VerifySeat(SUS) end
        assert_eq(Mock.vehicleOf[SUS], nil)
        assert_eq(lastNotify(COP), 'No free rear seat in that vehicle')
        assert_eq(Mock.selfExport('GetFieldState')(SUS).state, 'free')
    end)
    it('a vehicle hint far from the officer is ignored for the nearest vehicle; a free player is refused', function()
        car({ [-1] = true, [1] = true })
        seatsOf[900] = { [1] = true }
        Mock.coords[900] = vector3(300, 0, 0)
        fire('police:server:PutPlayerInVehicle', CIV, SUS, CAR)
        assert_eq(#events('police:client:PutInVehicle'), 0, 'not cuffed')
        cuffSuspect()
        fire('police:server:PutPlayerInVehicle', CIV, SUS, 900)
        assert_eq(last('police:client:PutInVehicle', SUS).args[1], CAR)
    end)
end)

describe('arrest, release, hand-over, property, cells', function()
    it('an arrest needs restraint and opens a pf-justice custody once, keyed by the restraint', function()
        fire('police:server:Arrest', COP, SUS)
        assert_eq(#called('OpenCustody'), 0)
        cuffSuspect()
        fire('police:server:Arrest', CIV, SUS)
        assert_eq(#called('OpenCustody'), 0, 'civilians cannot arrest')
        fire('police:server:Arrest', COP, SUS)
        local o = called('OpenCustody')[1]
        assert_eq(o.args[1], SUS)
        assert_eq(o.args[2].state, 'arrested')
        assert_eq(o.args[2].actor.src, COP)
        assert_true(o.args[2].key:find('^pfm%-policejob:arrest:SUSCID:%d+:1$') ~= nil)
        assert_eq(#marked('arrest', COP), 1)
        assert_eq(marked('arrest', COP)[1].data.custodyId, 41)
        local log = called('AddCustodyLog')
        assert_eq(log[#log].args[2], 'use_of_force')
        assert_eq(Mock.selfExport('GetFieldState')(SUS).lead, COP)
        -- the key of an arrest that is already over: refused, and the next attempt gets a new key
        JU.open = { ok = true, duplicate = true, existing = true, custodyId = 41, state = 'released' }
        fire('police:server:Arrest', COP, SUS)
        assert_eq(lastNotify(COP), 'That arrest is already closed; arrest them again')
        JU.open = { ok = true, custodyId = 42, state = 'arrested' }
        fire('police:server:Arrest', COP, SUS)
        local keys = called('OpenCustody')
        assert_true(keys[#keys].args[2].key:find(':3$') ~= nil, 'a fresh key')
        -- already in custody: told, nothing new
        JU.open = { ok = false, error = 'conflict', custodyId = 41 }
        fire('police:server:Arrest', COP, SUS)
        assert_eq(lastNotify(COP), 'They are already in custody (#41)')
    end)
    it('release at the scene closes an open custody as no_charges through pf-justice', function()
        cuffSuspect()
        JU.custody = { id = 41, state = 'arrested', officerCid = 'COPCID' }
        fire('police:server:ReleaseAtScene', COP, SUS)
        local r = called('ReleaseFromCustody')[1]
        assert_eq(r.args[1], 41)
        assert_eq(r.args[2], 'no_charges')
        assert_eq(meta(SUS).ishandcuffed, false)
        -- pf-justice refuses (e.g. remanded): nothing changes here
        cuffSuspect()
        JU.release = { ok = false, error = 'invalid_state', message = 'A remanded citizen is released by the court' }
        fire('police:server:ReleaseAtScene', COP, SUS)
        assert_eq(meta(SUS).ishandcuffed, true)
        assert_eq(lastNotify(COP), 'A remanded citizen is released by the court')
    end)
    it('release without a custody ends the detention and the police cuffs', function()
        cuffSuspect()
        fire('police:server:Detain', COP, SUS)
        fire('police:server:ReleaseAtScene', COP, SUS)
        assert_eq(#called('ReleaseFromCustody'), 0)
        assert_eq(meta(SUS).ishandcuffed, false)
        assert_eq(bag(SUS), nil)
    end)
    it('hand-over: only the responsible officer, to an on-duty officer with the suspect; logged', function()
        cuffSuspect()
        JU.custody = { id = 41, state = 'arrested', officerCid = 'COPCID' }
        fire('police:server:HandOver', COP2, SUS, COP)
        assert_eq(#called('AddCustodyLog'), 0, 'cop2 is not responsible')
        fire('police:server:HandOver', COP, SUS, CIV)
        assert_eq(#called('AddCustodyLog'), 0, 'a civilian cannot take over')
        fire('police:server:EscortPlayer', COP, SUS)
        fire('police:server:HandOver', COP, SUS, COP2)
        local log = called('AddCustodyLog')
        assert_eq(log[#log].args[2], 'note')
        assert_eq(log[#log].args[3].from, 'COPCID')
        assert_eq(log[#log].args[3].to, 'COP2CID')
        assert_eq(last('police:client:SetEscorted', SUS).args[1], false, 'the escort ends; the new officer takes them')
        assert_eq(Mock.selfExport('GetFieldState')(SUS).lead, COP2)
        local h = marked('note', COP2)
        assert_eq(h[#h].data.action, 'handover')
    end)
    it('property goes to a pf-justice locker linked to the open custody, one receipt per custody', function()
        fire('police:server:SeizeProperty', COP, SUS)
        assert_eq(#called('SeizeProperty'), 0, 'no custody')
        JU.custody = { id = 41, state = 'arrested', officerCid = 'COPCID' }
        fire('police:server:SeizeProperty', COP, SUS)
        local s = called('SeizeProperty')[1]
        assert_eq(s.args[2].custodyId, 41)
        assert_eq(s.args[2].key, 'pfm-policejob:property:41')
        assert_eq(s.args[2].items, 'all')
        assert_eq(s.args[2].keep[1], 'phone')
    end)
    it('a holding cell through pf-justice, door locked by alias and opened when the custody closes', function()
        JU.custody = { id = 41, state = 'booked', officerCid = 'COPCID' }
        fire('police:server:PlaceInCell', COP, SUS, 'mrpd_cell_1')
        assert_eq(called('AssignHoldingCell')[1].args[2], 'mrpd_cell_1')
        assert_eq(doors[1].door, 'mrpd_cell_1')
        assert_eq(doors[1].locked, true)
        fire('police:server:PlaceInCell', COP, SUS, 'cell; drop')
        assert_eq(#called('AssignHoldingCell'), 1, 'bad cell id')
        TriggerEvent('pf-justice:server:custodyChanged', { id = 41, cid = 'SUSCID', state = 'released', closedAt = Mock.clock }, { to = 'released' })
        assert_eq(doors[2].door, 'mrpd_cell_1')
        assert_eq(doors[2].locked, false)
        -- pf-justice refuses (not booked): no door moves
        JU.cell = { ok = false, error = 'invalid_state', message = 'book first' }
        fire('police:server:PlaceInCell', COP, SUS, 'mrpd_cell_2')
        assert_eq(#doors, 2)
    end)
end)

describe('audit fixes and export', function()
    it('SeizeDriverLicense takes the driving licence only; the other licences stay', function()
        fire('police:server:SeizeDriverLicense', COP, SUS)
        local l = meta(SUS).licences
        assert_eq(l.driver, false)
        assert_eq(l.weapon, true)
        assert_eq(l.pilot, true)
        assert_eq(l.business, false)
    end)
    it('GetFieldState answers for any server resource', function()
        local st = Mock.selfExport('GetFieldState')(SUS)
        assert_eq(st.ok, true)
        assert_eq(st.state, 'free')
        assert_eq(st.cuffed, false)
        assert_eq(Mock.selfExport('GetFieldState')(99).ok, false)
    end)
    it('jailing clears the field state (escort and lead)', function()
        cuffSuspect()
        fire('police:server:EscortPlayer', COP, SUS)
        PoliceField.Clear(SUS, 'jailed')
        assert_eq(bag(SUS), nil)
        assert_eq(last('police:client:SetEscorted', SUS).args[1], false)
    end)
end)
