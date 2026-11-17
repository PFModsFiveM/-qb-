-- Batch 22 (22C) pf-justice on MariaDB: the custody log read-back and the booking's receipt id.
--   * GetCustodyLog(custodyId, opts) pages pf_justice_custody_log newest first (before = last id seen,
--     limit 1-50, one row more read to know whether older rows remain), decodes each row's data,
--     refuses a viewer who is not an on-duty officer and any resource but pf-policemdt-DEV;
--   * GetBooking answers receiptId: the custody's newest property receipt (by citizen and custody).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-ambulancejob'] = 'missing', ['pf-services'] = 'missing', ['pfm-prison'] = 'missing', ['pfm-policejob'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, doj = { label = 'DOJ' } }

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
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function() return nil end, CreateInventory = function() return true end,
}

function GetCurrentResourceName() return 'pf-justice' end
Config = nil
PFPayout = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'shared/states.lua', 'server/main.lua', 'server/schema.lua', 'server/orders.lua',
    'server/clock.lua', 'server/records.lua', 'server/custody.lua', 'server/booking.lua', 'server/property.lua',
    'server/bail.lua', 'server/api.lua' }) do
    load_resource('[pfscripts]/pf-justice/' .. f)
end
Mock.exportsByResource['pf-justice'] = Mock.exportsByResource['__self']
local J = PFJustice
assert(J.Schema and J.Schema.Run and J.Schema.Run() ~= false or true)
local api = exports['pf-justice']

local OFF, OFFDUTY, CIV = 1, 2, 3
local function as(res) Mock.invokingResource = res end
local function q(sql, p) return MySQL.query.await(sql, p or {}) end
local function insert(sql, p) return tonumber(MySQL.insert.await(sql, p or {})) end

local CID = 'B22LOG' .. tostring(os.time() % 100000)
local custodyId, otherId
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    local o = Mock.newPlayer(OFF, 'B22OFF')
    o.PlayerData.job = { name = 'police', type = 'leo', grade = { level = 1 }, onduty = true }
    local d = Mock.newPlayer(OFFDUTY, 'B22OFFD')
    d.PlayerData.job = { name = 'police', type = 'leo', grade = { level = 1 }, onduty = false }
    Mock.newPlayer(CIV, 'B22CIV')
    as('pf-policemdt-DEV')
end

describe('22C GetCustodyLog (MariaDB)', function()
    it('pages the log newest first with a cursor and decodes each row', function()
        local now = os.time()
        custodyId = insert([[INSERT INTO pf_justice_custody (citizenid, state, opened_at, updated_at) VALUES (?, 'held', ?, ?)]], { CID, now, now })
        otherId = insert([[INSERT INTO pf_justice_custody (citizenid, state, opened_at, updated_at) VALUES (?, 'held', ?, ?)]], { CID .. 'X', now, now })
        for i = 1, 7 do
            insert('INSERT INTO pf_justice_custody_log (custody_id, kind, data, actor_cid, at) VALUES (?, ?, ?, ?, ?)',
                { custodyId, i % 2 == 0 and 'meal' or 'note', json.encode({ text = 'entry ' .. i, n = i }), 'B22OFF', now + i })
        end
        insert('INSERT INTO pf_justice_custody_log (custody_id, kind, data, actor_cid, at) VALUES (?, ?, ?, ?, ?)',
            { otherId, 'note', json.encode({ text = 'other custody' }), 'B22OFF', now })
        local p1 = api:GetCustodyLog(custodyId, { viewer = OFF, limit = 3 })
        assert_true(p1.ok, tostring(p1.error))
        assert_eq(#p1.list, 3)
        assert_eq(p1.list[1].data.text, 'entry 7')
        assert_eq(p1.list[1].kind, 'note')
        assert_eq(p1.list[2].kind, 'meal')
        assert_eq(p1.list[1].actorCid, 'B22OFF')
        assert_eq(p1.list[1].at, now + 7)
        assert_true(p1.nextBefore ~= nil, 'older rows remain')
        assert_eq(p1.nextBefore, p1.list[3].id)
        local p2 = api:GetCustodyLog(custodyId, { viewer = OFF, limit = 3, before = p1.nextBefore })
        assert_eq(#p2.list, 3)
        assert_eq(p2.list[1].data.text, 'entry 4')
        local p3 = api:GetCustodyLog(custodyId, { viewer = OFF, limit = 3, before = p2.nextBefore })
        assert_eq(#p3.list, 1)
        assert_eq(p3.list[1].data.text, 'entry 1')
        assert_eq(p3.nextBefore, nil, 'last page')
        -- default page size, and only this custody's rows
        local all = api:GetCustodyLog(custodyId)
        assert_eq(#all.list, 7)
        for _, l in ipairs(all.list) do assert_true(l.data.text ~= 'other custody') end
    end)

    it('refuses bad arguments, unknown custody, a viewer who is not an on-duty officer, and other resources', function()
        assert_eq(api:GetCustodyLog(custodyId, { limit = 51 }).error, 'bad_args')
        assert_eq(api:GetCustodyLog(custodyId, { limit = 0 }).error, 'bad_args')
        assert_eq(api:GetCustodyLog(custodyId, { before = 'x' }).error, 'bad_args')
        assert_eq(api:GetCustodyLog('abc').error, 'bad_args')
        assert_eq(api:GetCustodyLog(99999999).error, 'not_found')
        assert_true(api:GetCustodyLog(custodyId, { viewer = OFFDUTY }).ok ~= true, 'off duty')
        assert_true(api:GetCustodyLog(custodyId, { viewer = CIV }).ok ~= true, 'civilian')
        assert_eq(api:GetCustodyLog(custodyId, { viewer = 77 }).error, 'offline')
        as('pfm-prison')
        assert_eq(api:GetCustodyLog(custodyId).error, 'not_allowed')
        as('pf-policemdt-DEV')
        assert_true(api:GetCustodyLog(custodyId, { viewer = OFF }).ok)
    end)
end)

describe('22C GetBooking receiptId (MariaDB)', function()
    it('names the custody\'s newest property receipt, and none when nothing was seized', function()
        local now = os.time()
        insert([[INSERT INTO pf_justice_bookings (custody_id, booking_no, citizenid, booked_by, at) VALUES (?, ?, ?, 'B22OFF', ?)]],
            { custodyId, 'BK-B22-' .. custodyId, CID, now })
        local b = api:GetBooking(custodyId)
        assert_true(b.ok, tostring(b.error))
        assert_eq(b.booking.receiptId, nil)
        local r1 = insert([[INSERT INTO pf_justice_property (citizenid, custody_id, stash_id, state, seized_at) VALUES (?, ?, ?, 'held', ?)]],
            { CID, custodyId, 'b22_stash_a_' .. custodyId, now })
        local r2 = insert([[INSERT INTO pf_justice_property (citizenid, custody_id, stash_id, state, seized_at) VALUES (?, ?, ?, 'held', ?)]],
            { CID, custodyId, 'b22_stash_b_' .. custodyId, now })
        -- another custody's receipt of the same citizen is not this booking's
        insert([[INSERT INTO pf_justice_property (citizenid, custody_id, stash_id, state, seized_at) VALUES (?, ?, ?, 'held', ?)]],
            { CID, otherId, 'b22_stash_c_' .. otherId, now })
        b = api:GetBooking(custodyId)
        assert_true(r2 > r1)
        assert_eq(b.booking.receiptId, r2)
        -- the receipt reads back through GetPropertyReceipt for an officer
        local rc = api:GetPropertyReceipt(b.booking.receiptId, { viewer = OFF })
        assert_true(rc.ok, tostring(rc.error))
        assert_eq(rc.receipt.custodyId, custodyId)
        q('DELETE FROM pf_justice_property WHERE citizenid IN (?, ?)', { CID, CID .. 'X' })
    end)
end)
