-- Character deletion on a real database: pfm-banking's CanDeleteCharacter (active loans, card
-- balances, an overdrawn bank) and the cleanup listeners added for a deleted character in pf-stores,
-- pf-government, pf-mechanicjob, pfm-phone, pfm-inventory and pf-news, with their real SQL against
-- each resource's own schema. Each listener runs twice (idempotent) and leaves other characters alone.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetResourceState() return 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
RealDB.exec('[pfscripts]/pf-stores/install.sql')
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
RealDB.exec('[pfscripts]/pf-mechanicjob/pf_mechanic.sql')
RealDB.exec('pfm-phone/qb-phone.sql')
RealDB.exec('pfm-inventory/qb-inventory.sql')
load_resource('pfm-core/server/migrations.lua')
load_resource('[pfscripts]/pf-news/server/schema.lua')
assert(RunMigrations('pf-news', PFNews.Migrations), 'pf-news tables')

local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) end
local function addPlayer(cid, money)
    MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, ?, '{}', '{}', '{}', '{}', '{}', '[]')]], { cid, 'license:' .. cid, cid, json.encode(money) })
end
addPlayer('CDALT001', { cash = 0, bank = 5000 })
addPlayer('CDNEG001', { cash = 0, bank = -40 })
addPlayer('CDOK0001', { cash = 0, bank = 10 })

-- pfm-banking's check
function GetCurrentResourceName() return 'pfm-banking' end
load_resource('pfm-banking/server_characters.lua')
local CanDelete = Mock.selfExport('CanDeleteCharacter')

describe('pfm-banking CanDeleteCharacter', function()
    it('refuses an active loan, a card balance and an overdrawn bank; allows a clean character', function()
        assert_true(CanDelete('CDOK0001'))
        MySQL.insert.await("INSERT INTO bank_loans (citizenid, tier, principal, balance, apr, payment_amount, payments_total, next_payment) VALUES ('CDALT001', 'Starter', 2500, 2950, 18, 246, 12, 0)")
        local ok, why = CanDelete('CDALT001')
        assert_false(ok)
        assert_eq(why, 'unpaid_debt')
        MySQL.update.await("UPDATE bank_loans SET status = 'paid', balance = 0 WHERE citizenid = 'CDALT001'")
        assert_true(CanDelete('CDALT001'))
        MySQL.insert.await("INSERT INTO bank_cards (citizenid, card_id, card_number, credit_limit, balance, apr) VALUES ('CDALT001', 'fleeca_green', '4000 9', 10000, 300, 24)")
        assert_false(CanDelete('CDALT001'))
        MySQL.update.await("UPDATE bank_cards SET balance = 0 WHERE citizenid = 'CDALT001'")
        assert_true(CanDelete('CDALT001'))
        ok, why = CanDelete('CDNEG001')
        assert_false(ok)
        assert_eq(why, 'unpaid_debt')
    end)
end)

-- the listeners (the mock keeps one handler per event name: keep each)
local EV = 'pfm-core:server:characterDeleted'
local handlers = {}
local function loadHandler(file)
    Mock.eventHandlers[EV] = nil
    load_resource(file)
    handlers[#handlers + 1] = Mock.eventHandlers[EV]
end
loadHandler('[pfscripts]/pf-stores/server_characters.lua')
loadHandler('[pfscripts]/pf-government/server/characters.lua')
loadHandler('[pfscripts]/pf-mechanicjob/server/characters.lua')
loadHandler('pfm-phone/server/characters.lua')
Inventories = {}
loadHandler('pfm-inventory/server/characters.lua')
loadHandler('[pfscripts]/pf-news/server/characters.lua')
local function fire(cid, deleted) for _, h in ipairs(handlers) do h(cid, deleted) end end

local GONE, KEEP = 'CDGONE01', 'CDKEEP01'
local function seed()
    MySQL.insert.await("INSERT INTO pf_stores (store_id, label, store_type, owner_citizenid, purchased_at) VALUES ('cd_ltd1', 'LTD', 'ltd', ?, 1), ('cd_ltd2', 'LTD 2', 'ltd', ?, 1)", { GONE, KEEP })
    MySQL.insert.await("INSERT INTO pf_gov_staff (citizenid, name, role) VALUES (?, 'Gone', 'mayor'), (?, 'Keep', 'clerk')", { GONE, KEEP })
    MySQL.insert.await("INSERT INTO pf_gov_businesses (business_id, business_name, business_type, owner_id, owner_name) VALUES ('store:cd_ltd1', 'LTD', 'store', ?, 'Gone'), ('store:cd_ltd2', 'LTD 2', 'store', ?, 'Keep')", { GONE, KEEP })
    MySQL.insert.await("INSERT INTO pf_gov_utilities (property_type, property_id, property_name, owner_id, owner_name) VALUES ('property', 'cdhouse1', 'House', ?, 'Gone'), ('property', 'cdhouse2', 'House 2', ?, 'Keep')", { GONE, KEEP })
    MySQL.insert.await("INSERT INTO vehicle_diagnostics (plate, citizenid) VALUES ('CDG00001', ?), ('CDG00002', NULL), ('CDK00001', ?), ('CDS00001', ?)", { GONE, KEEP, GONE })
    MySQL.insert.await("INSERT INTO phone_gallery (citizenid, image) VALUES (?, 'a.png'), (?, 'b.png')", { GONE, KEEP })
    MySQL.insert.await("INSERT INTO phone_tweets (citizenid, firstName, lastName, message, tweetId) VALUES (?, 'G', 'G', 'hi', 'TWCD1'), (?, 'K', 'K', 'hi', 'TWCD2')", { GONE, KEEP })
    MySQL.insert.await("INSERT INTO inventories (identifier, items) VALUES ('trunk-CDG00001', '[]'), ('glovebox-CDG00001', '[]'), ('trunk-CDG00002', '[]'), ('trunk-CDK00001', '[]')")
    MySQL.insert.await("INSERT INTO pf_news_payouts (article_id, citizenid, amount, day, state) VALUES (9101, ?, 100, '2026-10-31', 'pending'), (9102, ?, 100, '2026-10-31', 'paid'), (9103, ?, 100, '2026-10-31', 'pending')", { GONE, GONE, KEEP })
    MySQL.insert.await([[INSERT INTO pf_news_ads (business_id, business_name, account_ref, buyer_cid, buyer_name, text, duration_id, hours, price, status)
        VALUES ('store:cd_ltd1', 'LTD', 'society:x', ?, 'Gone', 'Ad', 'd1', 24, 100, 'active'), ('store:cd_ltd2', 'LTD 2', 'society:y', ?, 'Keep', 'Ad', 'd1', 24, 100, 'active')]], { GONE, KEEP })
end

describe('a deleted character on the real schemas', function()
    it('clears what it left behind, twice without change, and keeps other characters', function()
        seed()
        local deleted = { apartments = {}, plates = { 'CDG00001', 'CDG00002' } }
        for _ = 1, 2 do fire(GONE, deleted) end

        assert_eq(MySQL.scalar.await("SELECT owner_citizenid FROM pf_stores WHERE store_id = 'cd_ltd1'"), nil)
        assert_eq(MySQL.scalar.await("SELECT owner_citizenid FROM pf_stores WHERE store_id = 'cd_ltd2'"), KEEP)
        assert_eq(count('SELECT COUNT(*) FROM pf_gov_staff WHERE citizenid = ?', { GONE }), 0)
        assert_eq(count('SELECT COUNT(*) FROM pf_gov_staff WHERE citizenid = ?', { KEEP }), 1)
        assert_eq(MySQL.scalar.await("SELECT owner_id FROM pf_gov_businesses WHERE business_id = 'store:cd_ltd1'"), 'unowned')
        assert_eq(MySQL.scalar.await("SELECT owner_id FROM pf_gov_businesses WHERE business_id = 'store:cd_ltd2'"), KEEP)
        assert_eq(MySQL.scalar.await("SELECT owner_id FROM pf_gov_utilities WHERE property_id = 'cdhouse1'"), nil)
        assert_eq(MySQL.scalar.await("SELECT owner_id FROM pf_gov_utilities WHERE property_id = 'cdhouse2'"), KEEP)
        assert_eq(count("SELECT COUNT(*) FROM vehicle_diagnostics WHERE plate IN ('CDG00001', 'CDG00002')"), 0)
        assert_eq(count("SELECT COUNT(*) FROM vehicle_diagnostics WHERE plate = 'CDK00001'"), 1)
        -- sold earlier: the row still names the seller but the car is someone else's now
        assert_eq(count("SELECT COUNT(*) FROM vehicle_diagnostics WHERE plate = 'CDS00001'"), 1)
        assert_eq(count('SELECT COUNT(*) FROM phone_gallery WHERE citizenid = ?', { GONE }), 0)
        assert_eq(count('SELECT COUNT(*) FROM phone_tweets WHERE citizenid = ?', { GONE }), 0)
        assert_eq(count('SELECT COUNT(*) FROM phone_tweets WHERE citizenid = ?', { KEEP }), 1)
        assert_eq(count("SELECT COUNT(*) FROM inventories WHERE identifier IN ('trunk-CDG00001', 'glovebox-CDG00001', 'trunk-CDG00002')"), 0)
        assert_eq(count("SELECT COUNT(*) FROM inventories WHERE identifier = 'trunk-CDK00001'"), 1)
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_news_payouts WHERE article_id = 9101'), 'cancelled')
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_news_payouts WHERE article_id = 9102'), 'paid')
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_news_payouts WHERE article_id = 9103'), 'pending')
        assert_eq(count('SELECT COUNT(*) FROM pf_news_ads WHERE buyer_cid = ?', { GONE }), 0)
        assert_eq(count("SELECT COUNT(*) FROM pf_news_ads WHERE business_id = 'store:cd_ltd1' AND status = 'active'"), 1, 'the ad itself stays')
    end)
end)

-- why pfm-core keys its character locks by the case-folded id and only accepts the stored spelling
describe('players.citizenid matching', function()
    it('matches another case of the id (so a case variant reaches the same rows)', function()
        local row = MySQL.single.await('SELECT citizenid, license FROM players WHERE citizenid = ? LIMIT 1', { 'cdok0001' })
        assert_true(row ~= nil, 'found case-insensitively')
        assert_eq(row.citizenid, 'CDOK0001')
    end)
end)
