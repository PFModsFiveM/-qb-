-- pfm-houses agency sales on the real database and the real ledger: the buyer's accept charges
-- price + broker fee + tax exactly once, the agency's society account and the agent are paid their
-- commission exactly once, the sale is recorded once, the house is handed over in player_houses /
-- houselocations; a declined or unaffordable offer moves nothing.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-government'] = 'missing', ['pf-services'] = 'missing', ['pfm-apartments'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
CancelEvent = CancelEvent or function() end
local commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) commands[name] = fn end
QBCoreMock.Player = QBCoreMock.Player or {}

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-houses/qb-houses.sql')
MySQL.query.await('CREATE TABLE IF NOT EXISTS inventories (identifier VARCHAR(100) PRIMARY KEY, items LONGTEXT)')
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
assert(PFLedger.EnsureSociety('realestate', 'job'), 'agency account')
Mock.exportsByResource['pf-devices'] = { RegisterApp = function() return true end, RegisterAppHandlers = function() return true end, Push = function() return true end, PushToJob = function() return 0 end }

local OFFICE = vector3(-700.0, 260.0, 83.0)
local houseNo = 0
local HOUSE

local function loadHouses()
    function GetCurrentResourceName() return 'pfm-houses' end
    Config = nil
    load_resource('pfm-banking/payouts.lua')
    load_resource('pfm-houses/config.lua')
    load_resource('pfm-houses/server/main.lua')
    load_resource('pfm-houses/server/apps.lua')
    MySQL.Sync = { fetchSingle = function(q, p) return MySQL.single.await(q, p) end }
    PFHouses.Start()
end
loadHouses()
assert(PFHouses.dbReady, 'pfm-houses migrations')

local AGENT, BUYER = 1, 2
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function agencyBalance() return tonumber(MySQL.scalar.await("SELECT account_balance FROM bank_accounts WHERE account_name = 'realestate'")) or 0 end
local function completed(pattern) return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ? AND state = 'completed'", { pattern })) or 0 end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    houseNo = houseNo + 1
    HOUSE = 'agenthouse' .. houseNo
    MySQL.insert.await("INSERT INTO houselocations (name, label, coords, owned, price, tier, garage) VALUES (?, ?, '{}', 0, 300000, 1, '{}')", { HOUSE, 'Agent Street ' .. houseNo })
    Config.MinZOffset = 0
    Config.Houses[HOUSE] = { coords = { enter = { x = 1.0, y = 2.0, z = 3.0, h = 0.0 } }, price = 300000, adress = 'Agent Street ' .. houseNo, tier = 1, locked = true, garage = {} }
    local agent = Mock.newPlayer(AGENT, 'HAGENT')
    agent.PlayerData.money = { cash = 0, bank = 0 }
    agent.PlayerData.license = 'license:1'
    agent.PlayerData.job = { name = 'realestate', onduty = true, grade = { level = 0 } }
    local buyer = Mock.newPlayer(BUYER, 'HBUYER' .. houseNo)
    buyer.PlayerData.money = { cash = 0, bank = 1000000 }
    buyer.PlayerData.license = 'license:2'
    for src in pairs(Mock.players) do Mock.players[src].PlayerData.source = src Mock.coords[src] = OFFICE end
end

describe('an agency sale', function()
    it('charges once and pays the agency and the agent once, and hands the house over', function()
        local before = agencyBalance()
        local offer = PFHouses.AgentOffer(AGENT, { house = HOUSE, target = BUYER })
        assert_true(offer.ok, tostring(offer.error))
        assert_eq(bank(BUYER), 1000000)
        local total = 300000 + 15000 + 18000          -- price + 5% broker fee + 6% tax (pf-government not running)
        assert_eq(offer.offer.total, total)
        local res = PFHouses.AnswerAgentOffer(BUYER, offer.offer.id, true)
        assert_true(res.ok, tostring(res.error))
        -- the tax nobody collected went back to the buyer
        assert_eq(bank(BUYER), 1000000 - total + 18000)
        assert_eq(agencyBalance() - before, 30000)
        assert_eq(bank(AGENT), 9000)
        assert_eq(PFHouses.AnswerAgentOffer(BUYER, offer.offer.id, true).error, 'not_found')
        Mock.fireNet('qb-houses:server:RespondAgentSale', BUYER, offer.offer.id, true)
        assert_eq(completed('pfm-houses:agent:' .. offer.offer.id .. ':charge%'), 1)
        assert_eq(completed('pfm-houses:agent:' .. offer.offer.id .. ':agency'), 1)
        assert_eq(completed('pfm-houses:agent:' .. offer.offer.id .. ':agent'), 1)
        assert_eq(bank(AGENT), 9000)
        assert_eq(tonumber(MySQL.scalar.await('SELECT owned FROM houselocations WHERE name = ?', { HOUSE })), 1)
        assert_eq(MySQL.scalar.await('SELECT citizenid FROM player_houses WHERE house = ?', { HOUSE }), 'HBUYER' .. houseNo)
        local sale = MySQL.single.await('SELECT price, agent_commission, agency_commission, buyer_cid FROM pfm_house_sales WHERE house = ?', { HOUSE })
        assert_eq(tonumber(sale.price), 300000)
        assert_eq(tonumber(sale.agent_commission), 9000)
        assert_eq(tonumber(sale.agency_commission), 30000)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pfm_house_sales WHERE house = ?', { HOUSE })), 1)
        -- the price paid is kept with the house, for the state sell-back
        assert_eq(tonumber(MySQL.scalar.await('SELECT purchase_price FROM player_houses WHERE house = ?', { HOUSE })), 300000)
        local view = PFHouses.AgencyData(AGENT)
        assert_true(view.stats.count >= 1)
        assert_true(view.stats.mine >= 9000)
    end)
    it('the state sell-back pays 70% of the price paid, not of the listing price', function()
        local offer = PFHouses.AgentOffer(AGENT, { house = HOUSE, target = BUYER })
        assert_true(PFHouses.AnswerAgentOffer(BUYER, offer.offer.id, true).ok)
        assert_eq(PFHouses.SetListingPrice(AGENT, { house = HOUSE, price = 100000000 }).error, 'not_for_sale')
        Config.Houses[HOUSE].price = 100000000          -- the listing changed by any route
        Mock.coords[BUYER] = vector3(1.0, 2.0, 3.0)
        local before = bank(BUYER)
        commands.sellhouse(BUYER, {})
        assert_eq(bank(BUYER) - before, 210000)
        assert_eq(PFHouses.OwnerOf(HOUSE), nil)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM player_houses WHERE house = ?', { HOUSE })), 0)
    end)
    it('a declined or unaffordable offer moves nothing', function()
        local before = agencyBalance()
        local offer = PFHouses.AgentOffer(AGENT, { house = HOUSE, target = BUYER })
        assert_true(PFHouses.AnswerAgentOffer(BUYER, offer.offer.id, false).declined)
        Mock.players[BUYER].PlayerData.money.bank = 1000
        offer = PFHouses.AgentOffer(AGENT, { house = HOUSE, target = BUYER })
        assert_eq(PFHouses.AnswerAgentOffer(BUYER, offer.offer.id, true).error, 'insufficient_funds')
        assert_eq(bank(BUYER), 1000)
        assert_eq(agencyBalance(), before)
        assert_eq(bank(AGENT), 0)
        assert_eq(tonumber(MySQL.scalar.await('SELECT owned FROM houselocations WHERE name = ?', { HOUSE })), 0)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pfm_house_sales WHERE house = ?', { HOUSE })), 0)
    end)
    it('a deleted owner frees the house again and their name stays in the record without the id', function()
        local offer = PFHouses.AgentOffer(AGENT, { house = HOUSE, target = BUYER })
        assert_true(PFHouses.AnswerAgentOffer(BUYER, offer.offer.id, true).ok)
        MySQL.query.await('DELETE FROM player_houses WHERE citizenid = ?', { 'HBUYER' .. houseNo })   -- what pfm-core does
        Mock.eventHandlers['pfm-core:server:characterDeleted']('HBUYER' .. houseNo)
        assert_eq(tonumber(MySQL.scalar.await('SELECT owned FROM houselocations WHERE name = ?', { HOUSE })), 0)
        assert_eq(PFHouses.OwnerOf(HOUSE), nil)
        local sale = MySQL.single.await('SELECT buyer_cid, buyer_name FROM pfm_house_sales WHERE house = ?', { HOUSE })
        assert_eq(sale.buyer_cid, nil)
        assert_true(sale.buyer_name ~= nil)
    end)
end)
