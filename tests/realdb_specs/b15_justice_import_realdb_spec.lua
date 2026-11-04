-- pf-justice 15C on the real database (unit 15C acceptance 6, plus the SQL of custody, booking,
-- property and bail):
--   * schema v2 (15B's runner) calls PFJustice.LegacyImport.Run(): pf_mdt_active_jails rows (with and
--     without released_why, with bail fields, with items JSON) become jail orders, property receipts
--     and bail rows; offline players.metadata.injail > 0 become 'online'-clock prison orders with
--     legacy_ref 'meta_injail:<cid>:<jailid>', their jailitems a receipt; criminalrecord flags one
--     'legacy_flag' record each; a second run imports nothing;
--   * an online player is imported at load from live metadata, once;
--   * batch 15 coexistence: while the old jails run, receipts stay 'legacy' (no locker is filled, so
--     nothing can be returned twice) and shadow orders close when the old jail released the prisoner;
--   * hand-over (LegacyRuntimes off): lockers are filled from the receipt rows, released prisoners'
--     shadows close, pfm-prison jailitems move into the locker and the metadata copy is cleared;
--   * custody, booking, property and bail statements run on MariaDB (CAS updates, unique booking
--     numbers, receipt rows, keyed bail transfer on the real ledger).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-ambulancejob'] = 'missing', ['pf-services'] = 'missing', ['pfm-prison'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')

-- the MDT jail table as pf-policemdt-DEV v1 + v6 create it
MySQL.query.await([[CREATE TABLE IF NOT EXISTS `pf_mdt_active_jails` (
    `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `sentence_id` INT NULL,
    `remaining_seconds` INT NOT NULL, `total_seconds` INT NOT NULL, `bail_amount` INT NOT NULL DEFAULT 0,
    `bail_key` VARCHAR(128) NULL, `bail_payer_cid` VARCHAR(64) NULL, `bail_payer_name` VARCHAR(128) NULL, `bail_started_at` INT NULL,
    `reason` VARCHAR(255) NULL, `items` LONGTEXT NULL, `provider` VARCHAR(32) NULL, `officer_citizenid` VARCHAR(64) NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (`id`), UNIQUE KEY `uq_mdt_jail_citizen` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
MySQL.query.await('ALTER TABLE `pf_mdt_active_jails` ADD COLUMN IF NOT EXISTS `released_why` VARCHAR(16) NULL')

QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, doj = { label = 'DOJ' } }
QBCoreMock.Shared.Items.weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', weight = 1000, type = 'weapon', unique = true }

-- the real ledger
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

-- pfm-inventory stand-in: player inventories are PlayerData.items, stashes are tables here
local Stashes = {}
local stashFull = {}
local function invOf(id)
    if type(id) == 'number' then return Mock.players[id] and Mock.players[id].PlayerData.items end
    return Stashes[id] and Stashes[id].items
end
local function freeSlot(items)
    local used = {}
    for _, it in pairs(items) do used[it.slot] = true end
    local s = 1
    while used[s] do s = s + 1 end
    return s
end
Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function(_, id, data) Stashes[id] = Stashes[id] or { items = {} } Stashes[id].label = data and data.label return true end,
    GetInventory = function(_, id) return Stashes[id] end,
    SaveStash = function() end,
    ClearStash = function(_, id) if Stashes[id] then Stashes[id].items = {} end end,
    CanAddItem = function(_, id) return not stashFull[id] end,
    ClearInventory = function(_, src) Mock.players[src].PlayerData.items = {} end,
    AddItem = function(_, id, name, amount, slot, info)
        local items = invOf(id)
        if not items or stashFull[id] then return false end
        items[#items + 1] = { name = name, amount = amount, slot = tonumber(slot) or freeSlot(items), info = info }
        return true
    end,
    RemoveItem = function(_, id, name, amount, slot)
        local items = invOf(id)
        if not items then return false end
        for k, it in pairs(items) do
            if it.name == name and (slot == nil or it.slot == slot) and it.amount >= amount then
                it.amount = it.amount - amount
                if it.amount <= 0 then items[k] = nil end
                return true
            end
        end
        return false
    end,
}
local cuffs = {}
Mock.exportsByResource['pfm-policejob'] = {
    SetCuffed = function(_, src, on) cuffs[src] = on return true end,
    IsCuffed = function(_, src) return cuffs[src] == true end,
}
local teleports = {}
function SetEntityCoords(ped, x, y, z) teleports[#teleports + 1] = { ped = ped, x = x, y = y, z = z } end

-- pf-justice, as its fxmanifest loads it
function GetCurrentResourceName() return 'pf-justice' end
Config = nil
PFPayout = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'shared/states.lua', 'server/main.lua', 'server/schema.lua', 'server/orders.lua',
    'server/clock.lua', 'server/records.lua', 'server/custody.lua', 'server/booking.lua', 'server/property.lua',
    'server/bail.lua', 'server/legacy_import.lua', 'server/compat.lua', 'server/api.lua' }) do
    load_resource('[pfscripts]/pf-justice/' .. f)
end
Mock.exportsByResource['pf-justice'] = Mock.exportsByResource['__self']
local J = PFJustice
local LI = J.LegacyImport

local function q(sql, p) return MySQL.query.await(sql, p or {}) end
local function one(sql, p) return MySQL.single.await(sql, p or {}) end
local function n(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local function order(ref) return one('SELECT * FROM pf_justice_orders WHERE legacy_ref = ?', { ref }) end
local function receipt(ref) return one('SELECT * FROM pf_justice_property WHERE legacy_ref = ?', { ref }) end
local function itemsOf(id) return q('SELECT * FROM pf_justice_property_items WHERE property_id = ? ORDER BY item', { id }) end
local function addPlayerRow(cid, meta)
    MySQL.insert.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, 'Legacy', '{"cash":0,"bank":0}', '{}', '{}', '{}', '{}', ?, '[]')]], { cid, 'license:' .. cid, meta })
end

-- legacy data as the old jails left it
local items2 = json.encode({ { name = 'phone', amount = 1, slot = 1 }, { name = 'lockpick', amount = 3, slot = 2, info = { uses = 2 } } })
MySQL.insert.await([[INSERT INTO pf_mdt_active_jails (id, citizenid, sentence_id, remaining_seconds, total_seconds, bail_amount, reason, items, provider, officer_citizenid)
    VALUES (11, 'MDTA', 501, 400, 600, 500, 'Robbery', ?, 'qb-inventory', 'OFF1')]], { items2 })
MySQL.insert.await([[INSERT INTO pf_mdt_active_jails (id, citizenid, sentence_id, remaining_seconds, total_seconds, bail_amount, reason, items, provider, officer_citizenid, released_why)
    VALUES (12, 'MDTB', 502, 0, 900, 0, 'Theft', ?, 'qb-inventory', 'OFF1', 'bail')]], { items2 })
MySQL.insert.await([[INSERT INTO pf_mdt_active_jails (id, citizenid, sentence_id, remaining_seconds, total_seconds, bail_amount, bail_key, bail_payer_cid, bail_payer_name, reason, items, provider)
    VALUES (13, 'MDTC', 503, 1200, 1800, 700, 'pf-policemdt:bail:13:1-1', 'PAYC', 'Pay Er', 'Assault', '[]', 'qb-inventory')]])
MySQL.insert.await([[INSERT INTO pf_mdt_active_jails (id, citizenid, sentence_id, remaining_seconds, total_seconds, bail_amount, reason, items, provider)
    VALUES (14, 'MDTD', 504, 300, 300, 0, 'Trespass', '[]', 'qb-inventory')]])
addPlayerRow('METAE', json.encode({ injail = 20, jailid = '1700000000-1-123456', jailitems = { { name = 'goldbar', amount = 2, info = {} } } }))
addPlayerRow('METAF', json.encode({ injail = 0, criminalrecord = { hasRecord = true, date = { year = 2026, month = 10, day = 1 } } }))
addPlayerRow('METAG', json.encode({ injail = 0, criminalrecord = { hasRecord = false } }))
addPlayerRow('METAH', 'not json')

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.clock = Mock.clock + 1000
    Mock.gameTimer = Mock.gameTimer + 1000000
    Config.Compat = nil
    teleports = {}
end

describe('schema v2 legacy import (15B runner, 15C code)', function()
    it('v1 and v2 apply and the v2 step imports every legacy jail once', function()
        assert_true(J.Boot(), 'boot (schema v1 + v2)')
        assert_eq(n("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-justice' AND version IN (1, 2)"), 2)
        local a = order('mdt_jail:11')
        assert_true(a ~= nil, 'MDT jail 11 imported')
        assert_eq(a.citizenid, 'MDTA')
        assert_eq(a.kind, 'jail')
        assert_eq(a.state, 'active')
        assert_eq(a.facility, 'bolingbroke')
        assert_eq(a.clock, 'online')
        assert_eq(tonumber(a.required_seconds), 600)
        assert_eq(tonumber(a.served_seconds), 200)
        assert_eq(a.source_type, 'mdt_sentence')
        assert_eq(a.source_id, '501')
        assert_eq(order('mdt_jail:12').state, 'completed', 'released_why -> completed')
        assert_eq(order('mdt_jail:13').state, 'active')
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_order_events WHERE action = 'imported'"), 5)
    end)

    it('items JSON becomes a receipt listing every item, held by the legacy jail (no locker filled)', function()
        local r = receipt('mdt_jail_items:11')
        assert_true(r ~= nil, 'receipt for jail 11')
        assert_eq(r.state, 'legacy')
        assert_eq(r.stash_id, 'pf_justice_property_' .. r.id)
        assert_eq(tonumber(r.order_id), tonumber(order('mdt_jail:11').id))
        local list = itemsOf(r.id)
        assert_eq(#list, 2)
        assert_eq(list[1].item, 'lockpick')
        assert_eq(tonumber(list[1].amount), 3)
        assert_eq(json.decode(list[1].info).uses, 2)
        assert_true(receipt('mdt_jail_items:12') ~= nil, 'a released row with items still gets its receipt')
        assert_eq(receipt('mdt_jail_items:13'), nil, 'no receipt for an empty items list')
        assert_eq(Stashes['pf_justice_property_' .. r.id], nil, 'nothing was put in a locker while the MDT holds the items')
    end)

    it('open bail becomes offered, a held bail key payment_pending with that key', function()
        local a = one("SELECT * FROM pf_justice_bail WHERE legacy_ref = 'mdt_bail:11'")
        assert_eq(a.state, 'offered')
        assert_eq(tonumber(a.amount), 500)
        assert_eq(tonumber(a.order_id), tonumber(order('mdt_jail:11').id))
        local c = one("SELECT * FROM pf_justice_bail WHERE legacy_ref = 'mdt_bail:13'")
        assert_eq(c.state, 'payment_pending')
        assert_eq(c.pay_key, 'pf-policemdt:bail:13:1-1')
        assert_eq(c.payer_cid, 'PAYC')
        assert_eq(one("SELECT * FROM pf_justice_bail WHERE legacy_ref = 'mdt_bail:12'"), nil, 'no bail for a released prisoner')
    end)

    it('offline injail becomes an online-clock prison order; jailitems a receipt; criminal records a flag', function()
        local e = order('meta_injail:METAE:1700000000-1-123456')
        assert_true(e ~= nil, 'METAE imported')
        assert_eq(e.kind, 'prison')
        assert_eq(e.clock, 'online')
        assert_eq(tonumber(e.required_seconds), 1200)
        assert_eq(e.state, 'active')
        local r = receipt('meta_jailitems:METAE:1700000000-1-123456')
        assert_eq(r.state, 'legacy')
        assert_eq(tonumber(r.order_id), tonumber(e.id))
        assert_eq(itemsOf(r.id)[1].item, 'goldbar')
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_records WHERE citizenid = 'METAF' AND kind = 'legacy_flag'"), 1)
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_records WHERE citizenid = 'METAG'"), 0)
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_orders WHERE citizenid IN ('METAF', 'METAG', 'METAH')"), 0)
        -- the index of active incarcerations knows the imported orders after the boot
        assert_true((J.Orders.IsIncarcerated('METAE')), 'IsIncarcerated sees the imported order')
    end)

    it('a second run imports nothing and changes nothing; legacy rows are untouched', function()
        local before = { n('SELECT COUNT(*) FROM pf_justice_orders'), n('SELECT COUNT(*) FROM pf_justice_property'),
            n('SELECT COUNT(*) FROM pf_justice_property_items'), n('SELECT COUNT(*) FROM pf_justice_bail'), n('SELECT COUNT(*) FROM pf_justice_records') }
        local res = LI.Run()
        assert_eq(res.ok, true)
        assert_eq(res.counts.orders + res.counts.receipts + res.counts.bails + res.counts.records, 0)
        local after = { n('SELECT COUNT(*) FROM pf_justice_orders'), n('SELECT COUNT(*) FROM pf_justice_property'),
            n('SELECT COUNT(*) FROM pf_justice_property_items'), n('SELECT COUNT(*) FROM pf_justice_bail'), n('SELECT COUNT(*) FROM pf_justice_records') }
        for i = 1, #before do assert_eq(after[i], before[i], 'table ' .. i) end
        assert_eq(n('SELECT COUNT(*) FROM pf_mdt_active_jails'), 4)
        assert_true(J.Schema.Run(), 'the schema runner again (v2 recorded: not run again)')
        assert_eq(n('SELECT COUNT(*) FROM pf_justice_orders'), before[1])
    end)
end)

describe('online players and batch-15 coexistence', function()
    it('an online player is imported at load from live metadata, once', function()
        local p = Mock.newPlayer(5, 'LIVEP')
        p.PlayerData.metadata = { injail = 7, jailid = 'J-77', jailitems = { { name = 'sandwich', amount = 2 } } }
        local c = LI.ForPlayer(5)
        assert_eq(c.orders, 1)
        assert_eq(c.receipts, 1)
        assert_eq(tonumber(order('meta_injail:LIVEP:J-77').required_seconds), 420)
        local again = LI.ForPlayer(5)
        assert_eq(again.orders + again.receipts, 0)
        assert_eq(#p.PlayerData.metadata.jailitems, 1, 'pfm-prison still holds its items in batch 15')
    end)

    it('SyncTick closes a shadow once the MDT released the prisoner and settles its receipt', function()
        MySQL.query.await('DELETE FROM pf_mdt_active_jails WHERE id = 11')
        local closed = LI.SyncTick()
        assert_true(closed >= 1, 'closed shadows')
        assert_eq(order('mdt_jail:11').state, 'vacated')
        local r = receipt('mdt_jail_items:11')
        assert_eq(r.state, 'returned')
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_property_items WHERE property_id = ? AND state = 'held'", { r.id }), 0)
        assert_false((J.Orders.IsIncarcerated('MDTA')), 'no longer incarcerated')
        assert_eq(order('mdt_jail:13').state, 'active', 'a jail the MDT still holds stays')
    end)

    it('SyncTick closes a pfm-prison shadow when injail went back to 0 (offline row)', function()
        MySQL.update.await("UPDATE players SET metadata = JSON_SET(metadata, '$.injail', 0) WHERE citizenid = 'METAE'")
        LI.SyncTick()
        assert_eq(order('meta_injail:METAE:1700000000-1-123456').state, 'vacated')
        assert_eq(receipt('meta_jailitems:METAE:1700000000-1-123456').state, 'returned')
    end)

    it('a legacy MDT bail is paid through the MDT while it runs its jail', function()
        local b = one("SELECT * FROM pf_justice_bail WHERE legacy_ref = 'mdt_bail:13'")
        assert_eq(J.Bail.Tick(Mock.clock + 10000), 0, 'the sweep leaves it')
        assert_eq(one('SELECT state FROM pf_justice_bail WHERE id = ?', { b.id }).state, 'payment_pending')
    end)
end)

describe('hand-over to pf-justice (LegacyRuntimes off)', function()
    it('MDT: a jail still held gets its locker filled from the receipt rows; a released one closes', function()
        Config.Compat = { LegacyRuntimes = { mdt = false, prison = false, policejob = false } }
        -- a new MDT jail imported before the hand-over, then released offline by the MDT
        MySQL.insert.await([[INSERT INTO pf_mdt_active_jails (id, citizenid, remaining_seconds, total_seconds, items, provider)
            VALUES (15, 'MDTE', 100, 100, ?, 'qb-inventory')]], { json.encode({ { name = 'phone', amount = 1 } }) })
        Config.Compat = nil
        LI.Run()
        Config.Compat = { LegacyRuntimes = { mdt = false, prison = false, policejob = false } }
        MySQL.update.await("UPDATE pf_mdt_active_jails SET released_why = 'unjail' WHERE id = 15")
        -- the MDT jail 12 receipt: row still exists (released_why set before the import) -> filled
        local res = LI.Run()
        assert_true(res.counts.filled >= 1, 'lockers filled')
        local r12 = receipt('mdt_jail_items:12')
        assert_true(r12.state == 'held' or r12.state == 'returning', 'jail 12 receipt taken over: ' .. tostring(r12.state))
        local stash = Stashes[r12.stash_id]
        assert_true(stash ~= nil, 'the locker exists')
        local count = 0
        for _, it in pairs(stash.items) do count = count + it.amount end
        assert_eq(count, 4, 'phone + 3 lockpicks in the locker')
        assert_eq(order('mdt_jail:15').state, 'vacated', 'released by the MDT after the import')
        local r15 = receipt('mdt_jail_items:15')
        assert_true(r15.state == 'returning' or r15.state == 'held', 'jail 15 receipt waits for its owner: ' .. tostring(r15.state))
        -- open bail of a prisoner the MDT no longer holds expires
        MySQL.query.await('DELETE FROM pf_mdt_active_jails WHERE id = 13')
        LI.Run()
        assert_eq(order('mdt_jail:13').state, 'vacated')
    end)

    it('a second hand-over pass fills nothing twice', function()
        Config.Compat = { LegacyRuntimes = { mdt = false, prison = false, policejob = false } }
        local r12 = receipt('mdt_jail_items:12')
        local before = 0
        for _, it in pairs(Stashes[r12.stash_id].items) do before = before + it.amount end
        LI.Run()
        local after = 0
        for _, it in pairs(Stashes[r12.stash_id].items) do after = after + it.amount end
        assert_eq(after, before)
    end)

    it('pfm-prison: at load the stored jailitems move into the locker and the metadata copy is cleared', function()
        Config.Compat = { LegacyRuntimes = { mdt = false, prison = false, policejob = false } }
        local p = Mock.newPlayer(5, 'LIVEP')
        p.PlayerData.metadata = { injail = 7, jailid = 'J-77', jailitems = { { name = 'sandwich', amount = 2 } } }
        LI.ForPlayer(5)
        local r = receipt('meta_jailitems:LIVEP:J-77')
        assert_eq(r.state, 'held')
        assert_eq(#p.PlayerData.metadata.jailitems, 0, 'jailitems cleared')
        assert_eq(Stashes[r.stash_id].items[1].name, 'sandwich')
        -- released later: the locker comes back without clearing what the player holds
        p.PlayerData.items = { { name = 'water_bottle', amount = 1, slot = 1 } }
        local res = J.Property.Return(tonumber(r.id), { toSrc = 5 })
        assert_eq(res.ok, true)
        assert_eq(res.returned, 1)
        local names = {}
        for _, it in pairs(p.PlayerData.items) do names[it.name] = it.amount end
        assert_eq(names.water_bottle, 1, 'current items kept')
        assert_eq(names.sandwich, 2, 'locker returned')
        assert_eq(receipt('meta_jailitems:LIVEP:J-77').state, 'returned')
    end)
end)

-- ── custody, booking, property and bail statements on MariaDB ──────────────────────────────────

local OFFICER, SUSPECT, PAYER = 1, 2, 3
local DESK = vector3(441.0, -981.0, 30.7)
local function cop()
    local p = Mock.newPlayer(OFFICER, 'COP1')
    p.PlayerData.job = { name = 'police', type = 'leo', grade = { level = 2 }, onduty = true }
    return p
end

describe('custody, booking, property and bail SQL', function()
    local custodyId, suspect
    -- BeforeEach empties Mock.players: the same player objects come back in each step
    local function again() cop() Mock.players[SUSPECT] = suspect end
    it('opens one custody per citizen and moves it with compare-and-set updates', function()
        cop()
        local s = Mock.newPlayer(SUSPECT, 'SUS1')
        suspect = s
        s.PlayerData.metadata = { fingerprint = 'FP-123', bloodtype = 'O+' }
        s.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 }, { name = 'lockpick', amount = 2, slot = 2 } }
        Mock.coords[OFFICER], Mock.coords[SUSPECT] = DESK, DESK
        local res = J.Custody.Open(SUSPECT, { reason = 'Robbery', key = 'spec:custody:1', actor = { src = OFFICER } })
        assert_eq(res.ok, true, tostring(res.error))
        custodyId = res.custodyId
        local again = J.Custody.Open(SUSPECT, { reason = 'Robbery', key = 'spec:custody:1', actor = { src = OFFICER } })
        assert_eq(again.duplicate, true)
        local other = J.Custody.Open(SUSPECT, { reason = 'Other', key = 'spec:custody:2', actor = { src = OFFICER } })
        assert_eq(other.error, 'conflict')
        assert_eq(J.Custody.SetState(custodyId, 'booking', { actor = { src = OFFICER } }).ok, true)
        assert_eq(one('SELECT state FROM pf_justice_custody WHERE id = ?', { custodyId }).state, 'booking')
        -- a stale compare-and-set changes nothing
        assert_false(J.Custody.Store.cas(custodyId, 'arrested', { state = 'held', updated_at = 1 }))
    end)

    it('books with a unique BK number, server identity, a receipt of every item, and logs each step', function()
        again()
        Mock.coords[OFFICER], Mock.coords[SUSPECT] = DESK, DESK
        local res = J.Booking.Book(custodyId, { height = 180, mugshotUrl = 'https://cdn.example.com/m.png' }, { actor = { src = OFFICER } })
        assert_eq(res.ok, true, tostring(res.error) .. ' ' .. tostring(res.message))
        assert_eq(res.bookingNo, ('BK-%s-0001'):format(os.date('%Y%m%d', Mock.clock)))
        local b = one('SELECT * FROM pf_justice_bookings WHERE custody_id = ?', { custodyId })
        assert_eq(b.fingerprint, 'FP-123')
        assert_eq(b.bloodtype, 'O+')
        assert_eq(tonumber(b.client_supplied), 1)
        assert_true(b.dna_sample_ref:match('^DNA%-') ~= nil and not b.dna_sample_ref:find('SUS1'), 'random DNA ref')
        assert_eq(#itemsOf(res.receiptId), 2)
        assert_eq(#Mock.players[SUSPECT].PlayerData.items, 0)
        assert_eq(J.Booking.NextNumber(Mock.clock), ('BK-%s-0002'):format(os.date('%Y%m%d', Mock.clock)))
        assert_true(n("SELECT COUNT(*) FROM pf_justice_custody_log WHERE custody_id = ? AND kind IN ('opened', 'state', 'booked', 'property_seized')", { custodyId }) >= 4)
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_records WHERE citizenid = 'SUS1' AND kind = 'arrest'"), 1)
    end)

    it('holds in a cell, then bail on the real ledger releases and returns the property once', function()
        again()
        local cell = Config.Custody.HoldingCells.mrpd_holding[1]
        Mock.coords[SUSPECT] = cell.center
        Mock.coords[OFFICER] = vector3(cell.center.x + 2.0, cell.center.y, cell.center.z)
        assert_eq(J.Custody.AssignCell(custodyId, cell.id, {}).ok, true)
        assert_true(J.Custody.IsInHoldingCell(SUSPECT), 'in the cell')
        local offer = J.Bail.Offer({ custodyId = custodyId }, { amount = 300 }, { actor = { src = OFFICER } })
        assert_eq(offer.ok, true, tostring(offer.error))
        local payer = Mock.newPlayer(PAYER, 'PAY1')
        payer.PlayerData.money.bank = 1000
        Mock.coords[PAYER] = DESK
        local res = J.Bail.Accept(offer.bailId, PAYER, {})
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(res.state, 'posted')
        assert_eq(Mock.players[PAYER].PlayerData.money.bank, 700)
        local tx = one("SELECT * FROM pf_transactions WHERE idempotency_key = ?", { ('pf-justice:bail:%d:1'):format(offer.bailId) })
        assert_eq(tx.state, 'completed')
        assert_eq(tx.to_account, 'society:doj')
        local c = one('SELECT * FROM pf_justice_custody WHERE id = ?', { custodyId })
        assert_eq(c.state, 'released')
        assert_eq(c.release_reason, 'bailed')
        local names = {}
        for _, it in pairs(Mock.players[SUSPECT].PlayerData.items) do names[it.name] = it.amount end
        assert_eq(names.lockpick, 2, 'property returned on release')
        assert_eq(one('SELECT state FROM pf_justice_property WHERE custody_id = ?', { custodyId }).state, 'returned')
        -- exoneration refunds once
        local ex = J.Bail.Exonerate(offer.bailId, {})
        assert_eq(ex.ok, true, tostring(ex.error))
        assert_eq(Mock.players[PAYER].PlayerData.money.bank, 1000)
        assert_eq(J.Bail.Exonerate(offer.bailId, {}).duplicate, true)
        assert_eq(Mock.players[PAYER].PlayerData.money.bank, 1000)
        assert_eq(one('SELECT state FROM pf_justice_bail WHERE id = ?', { offer.bailId }).state, 'refunded')
    end)
end)

describe('rework: bail follows its custody on MariaDB', function()
    local function fresh(cid, src)
        cop()
        local s = Mock.newPlayer(src, cid)
        s.PlayerData.items = {}
        Mock.coords[OFFICER], Mock.coords[src] = DESK, DESK
        local id = J.Custody.Open(src, { reason = 'Rework', actor = { src = OFFICER } }).custodyId
        assert_true(id ~= nil, 'custody')
        assert_eq(J.Booking.Book(id, { seize = false }, { actor = { src = OFFICER } }).ok, true)
        return id
    end

    it('closing a custody expires its open offer (payable no more)', function()
        local id = fresh('REW1', 6)
        local o = J.Bail.Offer({ custodyId = id }, { amount = 100 }, { actor = { src = OFFICER } })
        assert_eq(o.ok, true, tostring(o.error))
        assert_eq(J.Custody.Release(id, 'no_charges', { actor = { src = OFFICER } }).ok, true)
        assert_eq(one('SELECT state FROM pf_justice_bail WHERE id = ?', { o.bailId }).state, 'expired')
    end)

    it('a posted bail whose release hit a busy custody is released by the sweep (due query joins the custody)', function()
        local id = fresh('REW2', 7)
        local o = J.Bail.Offer({ custodyId = id }, { amount = 100 }, { actor = { src = OFFICER } })
        local payer = Mock.newPlayer(PAYER, 'PAY1')
        payer.PlayerData.money.bank = 500
        Mock.coords[PAYER] = DESK
        Mock.clock = Mock.clock + 10
        assert_true(J.Locks.Take('custody:' .. id), 'hold the custody lock')
        local res = J.Bail.Accept(o.bailId, PAYER, {})
        J.Locks.Free('custody:' .. id)
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(one('SELECT closed_at FROM pf_justice_custody WHERE id = ?', { id }).closed_at, nil)
        assert_true(#q("SELECT id FROM pf_justice_bail WHERE id = ? AND state = 'posted'", { o.bailId }) == 1)
        J.Bail.Tick(Mock.clock + 1)
        local c = one('SELECT * FROM pf_justice_custody WHERE id = ?', { id })
        assert_eq(c.state, 'released')
        assert_eq(c.release_reason, 'bailed')
        assert_eq(Mock.players[PAYER].PlayerData.money.bank, 400, 'paid once')
        -- released now: the sweep no longer picks it up
        local due = J.Bail.Store.due(Mock.clock + 2)
        for _, b in ipairs(due) do assert_true(tonumber(b.id) ~= o.bailId, 'not due any more') end
    end)
end)
