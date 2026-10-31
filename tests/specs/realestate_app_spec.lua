-- pfm-houses Real Estate apps (pf-devices): citizens see houses for sale and their own properties;
-- a Dynasty 8 agent offers an unowned house to a customer next to them, the customer accepts on
-- their own screen, and only then the ledger moves price + broker fee + tax once, with the agency's
-- and the agent's commission once each; the house is registered with pf-government. Listings are
-- repriced/created by on-duty agents only. Decorating sets inv_busy on the server; a deleted
-- character's houses and keys are released.
load_resource('tests/lua/ledger_env.lua')
CancelEvent = CancelEvent or function() end
QBCoreMock.Commands.Add = function() end
QBCoreMock.Player = QBCoreMock.Player or {}
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local DOOR = vector3(100.0, 200.0, 30.0)
local OFFICE = vector3(-700.0, 260.0, 83.0)
local houses, playerHouses, sales, writes, cleared = {}, {}, {}, {}, {}
local function record(name) return function(p) writes[#writes + 1] = { name = name, params = p } return 1 end end

FakeDB.extraPatterns = {
    { 'SELECT owned FROM houselocations WHERE name = ?', function(p) local h = houses[p[1]]; return h and { { owned = h.owned } } or {} end },
    { 'UPDATE houselocations SET owned = ?', function(p) houses[p[2]] = houses[p[2]] or {}; houses[p[2]].owned = p[1]; return 1 end },
    { 'UPDATE houselocations SET price = ?', function(p) if houses[p[2]] and houses[p[2]].owned ~= 1 then houses[p[2]].price = p[1] return 1 end return 0 end },
    { 'INSERT INTO houselocations', function(p) houses[p[1]] = { owned = 0, price = p[5], tier = p[6], label = p[2] }; writes[#writes + 1] = { name = 'newhouse', params = p } return 1 end },
    { 'SELECT * FROM houselocations WHERE name LIKE ?', function() return nil end },
    { 'INSERT INTO player_houses', function(p) playerHouses[p[1]] = { house = p[1], citizenid = p[3], keyholders = p[4] }; return 1 end },
    { 'UPDATE player_houses SET keyholders = ?', function(p) if playerHouses[p[2]] then playerHouses[p[2]].keyholders = p[1] end; writes[#writes + 1] = { name = 'keys', params = p } return 1 end },
    { 'DELETE FROM inventories WHERE identifier = ?', function(p) cleared[#cleared + 1] = p[1] return { affectedRows = 1 } end },
    { 'INSERT IGNORE INTO pfm_house_sales', function(p)
        for _, s in ipairs(sales) do if s.key == p[13] then return 0 end end
        sales[#sales + 1] = { house = p[1], price = p[3], total = p[6], buyer = p[7], agent = p[9], agentCut = p[11], agencyCut = p[12], key = p[13] }
        return #sales
    end },
    { 'FROM pfm_house_sales ORDER BY id DESC', function() return {} end },
    { 'FROM pfm_house_sales WHERE created_at', function() return { { n = #sales, agency = 0, mine = 0 } } end },
    { 'UPDATE pfm_house_sales SET', record('anonymise') },
}

local registered, handlers, pushes = {}, {}, {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) registered[def.id] = def return true end,
    RegisterAppHandlers = function(_, id, map) handlers[id] = map return true end,
    Push = function(_, src, app, event, payload) pushes[#pushes + 1] = { src = src, app = app, event = event, payload = payload } return true end,
    PushToJob = function(_, job, app, event) pushes[#pushes + 1] = { job = job, app = app, event = event } return 1 end,
}
local properties, taxes = {}, {}
Mock.exportsByResource['pf-government'] = {
    CalculateTax = function(_, amount, kind) return kind == 'property_transfer' and math.floor(amount * 5) / 100 or 0 end,
    CollectTaxAmount = function(_, amount, kind, _, cid, _, key) taxes[#taxes + 1] = { amount = amount, key = key, cid = cid } return amount end,
    RegisterProperty = function(_, id, name, owner) properties[#properties + 1] = { id = id, owner = owner } return true end,
}
Mock.exportsByResource['pfm-apartments'] = {
    GetCitizenApartment = function(_, cid) return cid == 'CID2' and { id = 'apartment1555', label = 'South Rockford Drive 555', building = 'South Rockford Drive', coords = { x = 1, y = 2 } } or nil end,
}
local stashCleared = {}
Mock.exportsByResource['pfm-inventory'] = { ClearStash = function(_, id) stashCleared[#stashCleared + 1] = id end }

LedgerEnv.load('pfm-houses', { 'pfm-houses/config.lua', 'pfm-houses/server/main.lua', 'pfm-houses/server/apps.lua' })
MySQL.Sync = { fetchSingle = function(q, p) return MySQL.single.await(q, p) end }

local AGENT, BUYER, OTHER, FAR = 1, 2, 3, 4
local agencyBefore = 0
local function P(src) return Mock.players[src] end
local function bank(src) return P(src).PlayerData.money.bank end
local function citizen(method, src, payload) return handlers.realestate[method](src, payload or {}) end
local function agency(method, src, payload) return handlers['realestate-agency'][method](src, payload or {}) end
local function events(name) return Mock.clientEventsNamed(name) end

local function newPlayer(src, money, at)
    local p = Mock.newPlayer(src)
    p.PlayerData.license = 'license:' .. src
    p.PlayerData.money = { cash = 0, bank = money or 0 }
    p.PlayerData.metadata.inside = { apartment = {} }
    Mock.coords[src] = at or OFFICE
    return p
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    pushes, properties, taxes, sales, writes, cleared, stashCleared = {}, {}, {}, {}, {}, {}, {}
    houses = { grove1 = { owned = 0, price = 200000 }, vinewood1 = { owned = 0, price = 900000 }, owned1 = { owned = 0, price = 100000 } }
    playerHouses = {}
    -- a fresh copy of the resource each time (houses sold in one test stay sold in its memory)
    LedgerEnv.load('pfm-houses', { 'pfm-houses/config.lua', 'pfm-houses/server/main.lua', 'pfm-houses/server/apps.lua' })
    Config.MinZOffset = 0
    local function H(price, address) return { coords = { enter = { x = DOOR.x, y = DOOR.y, z = DOOR.z, h = 0.0 } }, price = price, adress = address, tier = 1, locked = true, garage = {} } end
    Config.Houses = { grove1 = H(200000, 'Grove Street 1'), vinewood1 = H(900000, 'Vinewood Hills 1'), owned1 = H(100000, 'Mirror Park 1') }
    FakeDB.society('realestate', 0)
    local agent = newPlayer(AGENT, 1000)
    agent.PlayerData.job = { name = 'realestate', label = 'Dynasty 8', onduty = true, grade = { level = 0 } }
    newPlayer(BUYER, 500000)
    newPlayer(OTHER, 2000000, DOOR)
    newPlayer(FAR, 2000000, vector3(3000, 3000, 30))
    PFHouses.Start()
    -- someone else already owns owned1 (bought at the door)
    Mock.fireNet('qb-houses:server:buyHouse', OTHER, 'owned1')
    assert(PFHouses.OwnerOf('owned1') == 'CID3', 'setup: owned1 bought')
    pushes, taxes, properties = {}, {}, {}
    agencyBefore = FakeDB.bank_accounts.realestate.account_balance   -- the door purchase pays the agency too
end

describe('registration', function()
    it('registers the citizen app for everyone and the agency app for the realestate job, on both devices', function()
        registered = {}
        Mock.eventHandlers['pf-devices:server:ready']()
        assert_true(registered.realestate.access.anyone)
        assert_eq(registered['realestate-agency'].access.jobs.realestate, 0)
        assert_eq(registered.realestate.devices[2], 'computer')
        assert_eq(registered['realestate-agency'].entry, 'html/apps/realestate.js')
        assert_true(handlers.realestate.list ~= nil and handlers.realestate.answerOffer ~= nil)
        for _, m in ipairs({ 'agency', 'nearby', 'offer', 'cancelOffer', 'setPrice', 'createListing' }) do assert_true(handlers['realestate-agency'][m] ~= nil, m) end
    end)
end)

describe('the citizen app', function()
    it('lists unowned houses with their costs and my own properties, keys and apartment', function()
        local res = citizen('list', BUYER)
        assert_true(res.ok)
        assert_eq(#res.forSale, 2)
        assert_eq(res.forSale[1].id, 'grove1')          -- cheapest first
        assert_eq(res.forSale[1].tax, 10000)             -- the city's 5% transfer tax
        assert_eq(res.forSale[1].doorTotal, 240000)      -- price + 15% fees + tax
        assert_eq(res.forSale[1].agentTotal, 220000)     -- price + 5% broker fee + tax
        assert_eq(res.forSale[1].coords.x, DOOR.x)
        assert_eq(#res.mine, 0)
        assert_eq(res.apartment.building, 'South Rockford Drive')
        assert_false(res.isAgent)
        local mine = citizen('list', OTHER).mine
        assert_eq(#mine, 1)
        assert_eq(mine[1].id, 'owned1')
        assert_eq(mine[1].role, 'owner')
        assert_eq(mine[1].keys, 0)
    end)
end)

describe('an agent sale', function()
    local function offer(house, target) return agency('offer', AGENT, { house = house or 'grove1', target = target or BUYER }) end

    it('waits for the buyer, then charges once and pays both commissions once', function()
        local res = offer()
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.offer.total, 220000)
        assert_eq(bank(BUYER), 500000)                                  -- nothing before the answer
        local prompt = events('qb-houses:client:ConfirmAgentSale')
        assert_eq(#prompt, 1)
        assert_eq(prompt[1].target, BUYER)
        local pushed = false
        for _, p in ipairs(pushes) do if p.src == BUYER and p.app == 'realestate' and p.event == 'offer' then pushed = true end end
        assert_true(pushed, 'offer pushed to the buyer app')
        assert_eq(citizen('list', BUYER).offer.id, res.offer.id)

        local done = citizen('answerOffer', BUYER, { id = res.offer.id, accept = true })
        assert_true(done.ok, tostring(done.error))
        assert_eq(bank(BUYER), 280000)
        assert_eq(PFHouses.OwnerOf('grove1'), 'CID2')
        assert_eq(houses.grove1.owned, 1)
        assert_eq(FakeDB.bank_accounts.realestate.account_balance - agencyBefore, 20000)   -- 10% of the price
        assert_eq(bank(AGENT), 1000 + 6000)                                 -- 3% of the price
        assert_eq(#taxes, 1)
        assert_eq(taxes[1].amount, 10000)
        assert_eq(properties[#properties].id, 'grove1')
        assert_eq(properties[#properties].owner, 'CID2')
        assert_eq(#sales, 1)
        assert_eq(sales[1].agentCut, 6000)
        -- a repeated accept, in the app or at the prompt, changes nothing
        assert_eq(citizen('answerOffer', BUYER, { id = res.offer.id, accept = true }).error, 'not_found')
        Mock.fireNet('qb-houses:server:RespondAgentSale', BUYER, res.offer.id, true)
        assert_eq(bank(BUYER), 280000)
        assert_eq(#LedgerEnv.paid('pfm-houses:agent:'), 3)                 -- charge, agency, agent
        assert_eq(FakeDB.bank_accounts.realestate.account_balance - agencyBefore, 20000)
        assert_eq(bank(AGENT), 7000)
        -- the house is no longer for sale
        assert_eq(offer('grove1', OTHER).error, 'not_for_sale')
    end)
    it('can be accepted from the in-game prompt as well', function()
        local res = offer()
        Mock.fireNet('qb-houses:server:RespondAgentSale', BUYER, res.offer.id, true)
        assert_eq(PFHouses.OwnerOf('grove1'), 'CID2')
        assert_eq(bank(BUYER), 280000)
    end)
    it('a declined, expired or unaffordable offer moves no money and no house', function()
        local res = offer()
        assert_true(citizen('answerOffer', BUYER, { id = res.offer.id, accept = false }).declined)
        assert_eq(bank(BUYER), 500000)
        res = offer()
        Mock.clock = Mock.clock + 120
        assert_eq(citizen('answerOffer', BUYER, { id = res.offer.id, accept = true }).error, 'expired')
        P(BUYER).PlayerData.money.bank = 1000
        res = offer()
        assert_eq(citizen('answerOffer', BUYER, { id = res.offer.id, accept = true }).error, 'insufficient_funds')
        assert_eq(PFHouses.OwnerOf('grove1'), nil)
        assert_eq(FakeDB.bank_accounts.realestate.account_balance, agencyBefore)
        assert_eq(bank(AGENT), 1000)
        assert_eq(#sales, 0)
    end)
    it('only the buyer it was made to can answer it, with its id', function()
        local res = offer()
        assert_eq(citizen('answerOffer', OTHER, { id = res.offer.id, accept = true }).error, 'not_found')
        assert_eq(citizen('answerOffer', BUYER, { id = 'other', accept = true }).error, 'not_found')
        assert_eq(citizen('answerOffer', BUYER, { id = 42, accept = true }).error, 'bad_request')
        assert_eq(bank(OTHER), 2000000 - 115000 - 5000)                   -- only their door purchase
        assert_eq(PFHouses.OwnerOf('grove1'), nil)
    end)
    it('is refused for non-agents, off duty, owned or unknown houses, far, absent or self buyers, and bad payloads', function()
        assert_eq(agency('offer', BUYER, { house = 'grove1', target = OTHER }).error, 'not_agent')
        P(AGENT).PlayerData.job.onduty = false
        assert_eq(offer().error, 'off_duty')
        P(AGENT).PlayerData.job.onduty = true
        assert_eq(offer('owned1').error, 'not_for_sale')
        assert_eq(offer('nowhere').error, 'unknown_house')
        assert_eq(offer({}).error, 'unknown_house')
        assert_eq(offer('grove1', FAR).error, 'too_far')
        assert_eq(offer('grove1', AGENT).error, 'bad_buyer')
        assert_eq(offer('grove1', 99).error, 'bad_buyer')
        assert_eq(offer('grove1', 2.5).error, 'bad_buyer')
        assert_eq(#events('qb-houses:client:ConfirmAgentSale'), 0)
        assert_true(offer().ok)
        assert_eq(offer('vinewood1', BUYER).error, 'offer_pending')
    end)
    it('checks the agent and the distance again when the buyer accepts', function()
        local res = offer()
        Mock.coords[BUYER] = vector3(3000, 3000, 30)
        assert_eq(citizen('answerOffer', BUYER, { id = res.offer.id, accept = true }).error, 'too_far')
        Mock.coords[BUYER] = OFFICE
        res = offer()
        P(AGENT).PlayerData.job = { name = 'unemployed' }
        assert_eq(citizen('answerOffer', BUYER, { id = res.offer.id, accept = true }).error, 'agent_unavailable')
        assert_eq(bank(BUYER), 500000)
    end)
    it('the agent can withdraw it', function()
        local res = offer()
        assert_true(agency('cancelOffer', AGENT).ok)
        assert_eq(citizen('answerOffer', BUYER, { id = res.offer.id, accept = true }).error, 'not_found')
    end)
end)

describe('listings', function()
    it('an on-duty agent reprices an unowned house within bounds, not a sold one', function()
        assert_true(agency('setPrice', AGENT, { house = 'grove1', price = 250000 }).ok)
        assert_eq(Config.Houses.grove1.price, 250000)
        assert_eq(houses.grove1.price, 250000)
        assert_eq(agency('setPrice', AGENT, { house = 'owned1', price = 250000 }).error, 'not_for_sale')
        assert_eq(agency('setPrice', AGENT, { house = 'grove1', price = -5 }).error, 'bad_price')
        assert_eq(agency('setPrice', AGENT, { house = 'grove1', price = 1.5 }).error, 'bad_price')
        assert_eq(agency('setPrice', AGENT, { house = 'grove1', price = '9' }).error, 'bad_price')
        assert_eq(agency('setPrice', BUYER, { house = 'grove1', price = 1000 }).error, 'not_agent')
        assert_eq(Config.Houses.grove1.price, 250000)
    end)
    it('a new listing is created where the agent stands, from a typed street name', function()
        local res = agency('createListing', AGENT, { street = 'Grove Street', price = 150000, tier = 2 })
        assert_true(res.ok, tostring(res.error))
        local h = Config.Houses[res.house]
        assert_eq(h.coords.enter.x, OFFICE.x)
        assert_eq(h.price, 150000)
        assert_eq(agency('createListing', AGENT, { street = '<b>x</b>', price = 150000, tier = 2 }).error, 'bad_street')
        assert_eq(agency('createListing', AGENT, { street = 'Grove', price = 150000, tier = 21 }).error, 'bad_tier')
        assert_eq(agency('createListing', BUYER, { street = 'Grove', price = 150000, tier = 2 }).error, 'not_agent')
    end)
    it('the agency view lists every house with its status', function()
        local res = agency('agency', AGENT)
        assert_true(res.ok)
        local status = {}
        for _, l in ipairs(res.listings) do status[l.id] = l.status end
        assert_eq(status.grove1, 'available')
        assert_eq(status.owned1, 'sold')
        assert_eq(agency('agency', BUYER).error, 'not_agent')
        local near = agency('nearby', AGENT)
        assert_eq(#near.players, 1)
        assert_eq(near.players[1].id, BUYER)
    end)
end)

describe('decorating', function()
    it('sets inv_busy on the server for a key holder inside the house, and only clears what it set', function()
        Mock.coords[OTHER] = DOOR
        Mock.fireNet('qb-houses:server:SetDecorating', BUYER, 'owned1', true)        -- no key
        assert_eq(Player(BUYER).state.inv_busy, nil)
        Mock.fireNet('qb-houses:server:SetDecorating', OTHER, 'owned1', true)
        assert_eq(Player(OTHER).state.inv_busy, true)
        Mock.fireNet('qb-houses:server:SetDecorating', OTHER, nil, false)
        assert_eq(Player(OTHER).state.inv_busy, false)
        -- the inventory's own busy flag cannot be cleared through this event
        Player(BUYER).state.inv_busy = true
        Mock.fireNet('qb-houses:server:SetDecorating', BUYER, nil, false)
        assert_eq(Player(BUYER).state.inv_busy, true)
    end)
end)

describe('a deleted character', function()
    it('frees their houses (empty stash), takes back their keys elsewhere and drops their offers', function()
        Mock.fireNet('qb-houses:server:giveHouseKey', OTHER, BUYER, 'owned1')   -- not next to each other
        Mock.coords[BUYER] = DOOR
        Mock.fireNet('qb-houses:server:giveHouseKey', OTHER, BUYER, 'owned1')
        assert_eq(#PFHouses.KeyHolders('owned1'), 2)
        Mock.eventHandlers['pfm-core:server:characterDeleted']('CID2')
        assert_eq(#PFHouses.KeyHolders('owned1'), 1)
        Mock.eventHandlers['pfm-core:server:characterDeleted'](nil)
        Mock.eventHandlers['pfm-core:server:characterDeleted']('CID3')
        assert_eq(PFHouses.OwnerOf('owned1'), nil)
        assert_eq(houses.owned1.owned, 0)
        assert_eq(cleared[1], 'owned1')
        assert_eq(stashCleared[1], 'owned1')
        local listed = false
        for _, h in ipairs(citizen('list', BUYER).forSale) do if h.id == 'owned1' then listed = true end end
        assert_true(listed, 'back on the market')
    end)
end)
