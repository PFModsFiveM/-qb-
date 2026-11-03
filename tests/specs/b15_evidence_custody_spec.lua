-- pfm-policejob chain of custody (batch 15, unit 15D): the pfm-inventory listeners turn every move of
-- an evidence bag into a queued observation (holder and actor read on the server), the queue is
-- recorded only once the schema is ready, a bag that vanishes is flagged missing, and the integrity
-- rules and the custody state machine behave as architecture 4.9 / 5.7 say.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pfm-policejob' end
function GetResourceState(name) return name == 'pfm-inventory' and 'started' or 'missing' end
local migrationsOk = false
Mock.exportsByResource['pfm-core'].RunMigrations = function() return migrationsOk end
local registered = {}
Mock.exportsByResource['pfm-inventory'] = {
    AddListener = function(_, kind, fn) registered[#registered + 1] = { kind = kind, fn = fn } return #registered end,
    AddItem = function() return true end, RemoveItem = function() return true end, GetInventory = function() return nil end,
}
QBCoreMock.Shared.Items.evidence_bag = { name = 'evidence_bag', unique = true }

QBCore = Mock.coreObject()
Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/config_evidence.lua')
load_resource('pfm-policejob/server/schema.lua')
load_resource('pfm-policejob/server/evidence/store.lua')
load_resource('pfm-policejob/server/evidence/custody.lua')
load_resource('pfm-policejob/server/evidence/scene.lua')
load_resource('pfm-policejob/server/evidence/api.lua')
local E, Store, C = PFEvidence, PFEvidence.Store, PFEvidence.Custody

local COP, CIV, COP2 = 1, 2, 3
local function bag(id, slot) return { name = 'evidence_bag', slot = slot or 1, amount = 1, info = { evidenceId = id } } end

-- an in-memory stand-in for the row store, so the recorder logic is seen without SQL
local rows, custody = {}, {}
local realGet, realMove, realAdd, realRefresh = Store.Get, Store.Move, Store.AddCustody, Store.Refresh
local function fakeStore()
    Store.Get = function(id) return rows[id] and { id = id, state = rows[id].state, holder_kind = rows[id].holder_kind, holder_ref = rows[id].holder_ref, kind = 'blood', tag = 'EV-1', attrs = '{}' } end
    Store.Move = function(row, kind, ref, state)
        rows[row.id].holder_kind, rows[row.id].holder_ref, rows[row.id].state = kind, ref, state
        row.holder_kind, row.holder_ref, row.state = kind, ref, state
        return true
    end
    Store.AddCustody = function(id, event, from, to, actor, note) custody[#custody + 1] = { id = id, event = event, from = from, to = to, actor = actor and actor.cid, note = note } return true end
    Store.Refresh = function() return 100, {}, {} end
end
local function realStore() Store.Get, Store.Move, Store.AddCustody, Store.Refresh = realGet, realMove, realAdd, realRefresh end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    rows, custody = {}, {}
    C.queue, C.pendingRemoval, C.suppress, C.viewers = {}, {}, {}, {}
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } }
    local cop2 = Mock.newPlayer(COP2, 'COP2CID')
    cop2.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } }
    Mock.newPlayer(CIV, 'CIVCID')
    fakeStore()
    migrationsOk, PFPoliceSchema.state = true, 'ready'
end

describe('listener registration', function()
    it('listens to moves, adds, removals, drops and opened inventories', function()
        registered = {}
        assert_true(C.RegisterListeners())
        local kinds = {}
        for _, l in ipairs(registered) do kinds[l.kind] = Mock.funcrefTarget(l.fn) end
        assert_eq(kinds.ItemMoved, C.OnItemMoved)
        assert_eq(kinds.ItemAdded, C.OnItemAdded)
        assert_eq(kinds.ItemRemoved, C.OnItemRemoved)
        assert_eq(kinds.ItemDropped, C.OnItemDropped)
        assert_eq(kinds.InventoryOpened, C.OnInventoryOpened)
    end)
end)

describe('holders', function()
    it('are read on the server', function()
        local k, r = C.Holder('player', COP)
        assert_eq(k, 'officer'); assert_eq(r, 'player:COPCID')
        k, r = C.Holder('player', CIV)
        assert_eq(k, 'civilian'); assert_eq(r, 'player:CIVCID')
        k, r = C.Holder('inventory', '2 | Drawer 4')
        assert_eq(k, 'locker'); assert_eq(r, 'inv:2 | Drawer 4')
        k, r = C.Holder('trunk', 'trunk-ABC123')
        assert_eq(k, 'inventory'); assert_eq(r, 'inv:trunk-ABC123')
        k, r = C.Holder('drop', 'drop-55')
        assert_eq(k, 'ground'); assert_eq(r, 'drop:drop-55')
        k, r = C.Holder('player', 999)
        assert_eq(k, 'unknown'); assert_eq(r, 'unknown')
    end)
end)

describe('moves into the queue', function()
    it('a move into a stash names the player who has it open', function()
        C.OnItemMoved('moved', { fromType = 'player', toType = 'inventory', fromId = COP, toId = '1 | Drawer 2', fromSlot = 1, toSlot = 4,
            fromInventory = { items = {} }, toInventory = { items = { [4] = bag(7, 4) }, isOpen = COP } })
        assert_eq(#C.queue, 1)
        assert_eq(C.queue[1].id, 7)
        assert_eq(C.queue[1].ref, 'inv:1 | Drawer 2')
        assert_eq(C.queue[1].kind, 'locker')
        assert_eq(C.queue[1].actorSrc, COP)
    end)
    it('a search move names the searching officer, a swap records both bags, other items are ignored', function()
        C.OnInventoryOpened(nil, { source = COP, inventoryId = CIV })
        C.OnItemMoved('swapped', { fromType = 'player', toType = 'player', fromId = CIV, toId = COP, fromSlot = 2, toSlot = 5,
            fromInventory = { items = { { name = 'evidence_bag', slot = 2, amount = 1, info = { evidenceId = 9 } } } },
            toInventory = { items = { [5] = bag(8, 5) } } })
        assert_eq(#C.queue, 2)
        assert_eq(C.queue[1].id, 8); assert_eq(C.queue[1].actorSrc, COP); assert_eq(C.queue[1].ref, 'player:COPCID')
        assert_eq(C.queue[2].id, 9); assert_eq(C.queue[2].ref, 'player:CIVCID'); assert_eq(C.queue[2].kind, 'civilian')
        C.OnItemMoved('moved', { fromType = 'player', toType = 'player', fromId = CIV, toId = COP, toSlot = 1,
            toInventory = { items = { [1] = { name = 'sandwich', slot = 1, amount = 1, info = {} } } } })
        C.OnItemMoved('moved', { fromType = 'player', toType = 'player', fromId = CIV, toId = COP, toSlot = 1,
            toInventory = { items = { [1] = { name = 'filled_evidence_bag', slot = 1, amount = 1, info = { type = 'blood' } } } } })
        assert_eq(#C.queue, 2, 'no evidenceId, nothing to record')
    end)
    it('the module\'s own moves are not recorded twice', function()
        C.suppress[7] = true
        C.OnItemAdded(nil, { toId = COP, toType = 'player', item = bag(7) })
        C.OnItemRemoved(nil, { fromId = COP, fromType = 'player', item = bag(7) })
        assert_eq(#C.queue, 0)
        assert_eq(C.pendingRemoval[7], nil)
    end)
    it('nothing is recorded before the schema is ready; then the queue is', function()
        PFPoliceSchema.state = 'idle'
        migrationsOk = false
        assert_false(PFPoliceSchema.Run())
        rows[7] = { state = 'sealed', holder_kind = 'officer', holder_ref = 'player:COPCID' }
        C.OnItemAdded(nil, { toId = COP2, toType = 'player', item = bag(7) })
        assert_eq(C.Process(), 0)
        assert_eq(#C.queue, 1)
        migrationsOk = true
        PFPoliceSchema.state = 'idle'
        assert_true(PFPoliceSchema.Run())
        assert_eq(C.Process(), 1)
        assert_eq(rows[7].holder_ref, 'player:COP2CID')
        assert_eq(custody[1].event, 'moved')
    end)
end)

describe('recording', function()
    it('locker check-in stores, check-out to an officer is in transit, a civilian holder is noted', function()
        rows[5] = { state = 'sealed', holder_kind = 'officer', holder_ref = 'player:COPCID' }
        assert_eq(C.Observe({ id = 5, kind = 'locker', ref = 'inv:1 | Drawer 1', actorSrc = COP }), 'moved')
        assert_eq(rows[5].state, 'stored')
        assert_eq(custody[#custody].event, 'checked_in')
        assert_eq(custody[#custody].actor, 'COPCID')
        assert_eq(C.Observe({ id = 5, kind = 'locker', ref = 'inv:1 | Drawer 1', actorSrc = COP }), 'same')
        assert_eq(C.Observe({ id = 5, kind = 'officer', ref = 'player:COP2CID', actorSrc = COP2 }), 'moved')
        assert_eq(rows[5].state, 'in_transit')
        assert_eq(custody[#custody].event, 'checked_out')
        assert_eq(C.Observe({ id = 5, kind = 'civilian', ref = 'player:CIVCID', actorSrc = CIV }), 'moved')
        assert_eq(custody[#custody].note, 'not on-duty police')
        assert_eq(C.Observe({ id = 404, kind = 'officer', ref = 'player:COPCID' }), 'missing')
        E.Lock('ev:5')
        assert_eq(C.Observe({ id = 5, kind = 'officer', ref = 'player:COPCID' }), 'busy')
        E.Unlock('ev:5')
    end)
    it('a removed bag seen nowhere is flagged missing after the grace time', function()
        rows[6] = { state = 'sealed', holder_kind = 'officer', holder_ref = 'player:COPCID' }
        C.pendingRemoval = {}
        C.OnItemRemoved(nil, { fromId = COP, fromType = 'player', item = bag(6) })
        C.CheckRemovals(Mock.clock + 2)
        assert_eq(rows[6].holder_ref, 'player:COPCID')
        C.CheckRemovals(Mock.clock + 11)
        assert_eq(rows[6].holder_ref, 'unknown')
        assert_eq(custody[#custody].event, 'flagged_missing')
        assert_eq(C.pendingRemoval[6], nil)
    end)
    it('a removal followed by an add is a plain move by the giver', function()
        rows[8] = { state = 'sealed', holder_kind = 'officer', holder_ref = 'player:COPCID' }
        C.pendingRemoval, C.queue = {}, {}
        C.OnItemRemoved(nil, { fromId = COP, fromType = 'player', item = bag(8) })
        C.OnItemAdded(nil, { toId = COP2, toType = 'player', item = bag(8) })
        C.Process()
        C.CheckRemovals(Mock.clock + 60)
        assert_eq(rows[8].holder_ref, 'player:COP2CID')
        assert_eq(custody[#custody].event, 'moved')
        assert_eq(custody[#custody].actor, 'COPCID')
    end)
    it('a bag dropped on the ground is recorded there', function()
        rows[9] = { state = 'sealed', holder_kind = 'officer', holder_ref = 'player:COPCID' }
        C.OnItemDropped(nil, { source = COP, item = bag(9), dropId = 'drop-77' })
        C.Process()
        assert_eq(rows[9].holder_ref, 'drop:drop-77')
        assert_eq(custody[#custody].note, 'left on the ground')
        realStore()
    end)
end)

describe('integrity rules (architecture 4.9)', function()
    local T0 = 1000000
    local cases = {
        { name = 'clean chain', events = { { event = 'collected', to_ref = 'player:A', at = T0 } }, score = 100 },
        { name = 'seal broken in the field', events = { { event = 'seal_broken', from_ref = 'player:A', at = T0 } }, score = 88, flags = 'seal_broken' },
        { name = 'two breaks', events = { { event = 'seal_broken', from_ref = 'player:A', at = T0 }, { event = 'seal_broken', from_ref = 'inv:x', at = T0 + 1 } }, score = 76 },
        { name = 'seal broken at the lab', events = { { event = 'seal_broken', from_ref = 'lab:main', at = T0 } }, score = 100 },
        { name = 'seal broken in court', events = { { event = 'seal_broken', from_ref = 'court:C1', at = T0 } }, score = 100 },
        { name = 'short time on the ground', events = { { event = 'moved', to_ref = 'drop:d1', at = T0 }, { event = 'moved', to_ref = 'player:A', at = T0 + 600 } }, score = 100 },
        { name = 'long time on the ground', events = { { event = 'moved', to_ref = 'drop:d1', at = T0 }, { event = 'moved', to_ref = 'player:A', at = T0 + 3600 } }, score = 80, flags = 'gap' },
        { name = 'still missing past the gap', events = { { event = 'flagged_missing', to_ref = 'unknown', at = T0 } }, holder = 'unknown', now = T0 + 3600, score = 80, flags = 'gap,missing' },
        { name = 'no gloves on a print', kind = 'fingerprint', rowFlags = 'contaminated', events = {}, score = 90, flags = 'contaminated' },
        { name = 'no gloves on a casing costs nothing', kind = 'casing', rowFlags = 'contaminated', events = {}, score = 100 },
        { name = 'never below zero', events = (function()
            local list = {}
            for i = 1, 12 do list[i] = { event = 'seal_broken', from_ref = 'player:A', at = T0 + i } end
            return list
        end)(), score = 0 },
    }
    for _, case in ipairs(cases) do
        it(case.name, function()
            local row = { kind = case.kind or 'blood', flags = case.rowFlags, holder_ref = case.holder or 'player:A' }
            local score, flags = Store.ComputeIntegrity(row, case.events, case.now or (T0 + 7200))
            assert_eq(score, case.score)
            if case.flags then assert_eq(table.concat(flags, ','), case.flags) end
        end)
    end
end)

describe('custody state machine (architecture 5.7)', function()
    local allowed = {
        { 'collected', 'sealed' }, { 'sealed', 'stored' }, { 'sealed', 'in_transit' }, { 'sealed', 'at_lab' },
        { 'stored', 'in_court' }, { 'at_lab', 'analysed' }, { 'analysed', 'stored' }, { 'in_court', 'stored' },
        { 'stored', 'released' }, { 'stored', 'destroyed' },
    }
    local refused = {
        { 'released', 'stored' }, { 'destroyed', 'in_transit' }, { 'at_lab', 'released' }, { 'at_lab', 'in_court' },
        { 'collected', 'analysed' }, { 'stored', 'analysed' }, { 'stored', 'collected' }, { 'bogus', 'stored' },
    }
    it('allows the listed transitions', function()
        for _, p in ipairs(allowed) do assert_true(Store.CanMove(p[1], p[2]), p[1] .. ' -> ' .. p[2]) end
    end)
    it('refuses the rest', function()
        for _, p in ipairs(refused) do assert_false(Store.CanMove(p[1], p[2]), p[1] .. ' -> ' .. p[2]) end
        assert_true(Store.IsTerminal('released') and Store.IsTerminal('destroyed'))
    end)
end)
