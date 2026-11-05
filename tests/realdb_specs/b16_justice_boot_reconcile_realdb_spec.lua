-- batch 16 (lead): regression specs from the combined check (escape + relog keeps a carried-over sentence;
-- the start-up reconcile runs after pf-justice is ready).
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
describe('probe: Boot after the hand-over closes the shadow of an MDT jail released before the restart', function()
    it('released MDT jail shadow vacated by Boot', function()
        Config.Compat = { LegacyRuntimes = { mdt = true, prison = true, policejob = true } }
        assert_true(J.Boot(), 'boot 1')
        MySQL.insert.await([[INSERT INTO pf_mdt_active_jails (id, citizenid, remaining_seconds, total_seconds, items, provider)
            VALUES (31, 'BOOTA', 100, 100, '[]', 'qb-inventory')]])
        LI.Run()
        assert_eq(order('mdt_jail:31').state, 'active')
        -- the MDT released them (row gone) before the restart with the flag flipped
        MySQL.query.await('DELETE FROM pf_mdt_active_jails WHERE id = 31')
        Config.Compat = { LegacyRuntimes = { mdt = false, prison = false, policejob = false } }
        J.ready = false
        assert_true(J.Boot(), 'boot 2')
        print('PROBE state after Boot: ' .. tostring(order('mdt_jail:31').state))
        LI.Run(); print('PROBE state after a second LI.Run with ready: ' .. tostring(order('mdt_jail:31').state))
        assert_eq(order('mdt_jail:31').state, 'vacated')
    end)
end)
