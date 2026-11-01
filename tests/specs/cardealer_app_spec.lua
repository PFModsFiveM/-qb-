-- pfm-vehicleshop Car Dealer apps (pf-devices): the catalogue with prices, stock and finance terms;
-- a dealer's sale from the app waits for the buyer's answer on their own screen, then charges
-- price + purchase tax once, splits the price once between the salesperson's commission and the
-- dealership (the commission comes out of the price, it is not paid on top), takes one car from stock,
-- registers the car with pf-government and records the sale; finance payments and pay-offs from the
-- app go through the same ledger path with stable keys; stock orders are paid by the dealership;
-- everything that is not the player's, or not their job's, is refused.
load_resource('tests/lua/ledger_env.lua')
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.GetIdentifier = function(src) return 'license:' .. tostring(src) end
QBCoreMock.Shared.Vehicles = {
    blista = { name = 'Blista', brand = 'Dinka', price = 10000, shop = 'pdm', category = 'compacts' },
    cognoscenti = { name = 'Cognoscenti', brand = 'Enus', price = 100000, shop = 'luxury', category = 'sedans' },
    nero = { name = 'Nero', brand = 'Truffade', price = 200000, shop = { 'luxury' }, category = 'super' },
}
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local vehicles, stock, sales, anonymised = {}, {}, {}, 0
local function sk(shop, model) return shop .. '|' .. model end
FakeDB.extraPatterns = {
    { 'SELECT plate FROM player_vehicles WHERE plate = ?', function(p) return vehicles[p[1]] and p[1] or nil end },
    { 'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance', function(p)
        vehicles[p[6]] = { citizenid = p[2], vehicle = p[3], plate = p[6], balance = p[9], paymentamount = p[10], paymentsleft = p[11], financetime = p[12] }
        return 1
    end },
    { 'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state)', function(p)
        vehicles[p[6]] = { citizenid = p[2], vehicle = p[3], plate = p[6], balance = 0 }
        return 1
    end },
    { 'SELECT balance, paymentamount, paymentsleft, financetime FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = vehicles[p[1]]
        return (v and v.citizenid == p[2]) and { v } or {}
    end },
    { 'SELECT balance FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = vehicles[p[1]]
        return (v and v.citizenid == p[2]) and { v } or {}
    end },
    { 'UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ? AND citizenid = ? AND balance = ?', function(p)
        local v = vehicles[p[5]]
        if not v or v.citizenid ~= p[6] or v.balance ~= p[7] then return 0 end
        v.balance, v.paymentamount, v.paymentsleft, v.financetime = p[1], p[2], p[3], p[4]
        return 1
    end },
    { 'SELECT plate, vehicle, balance, paymentamount, paymentsleft, financetime FROM player_vehicles WHERE citizenid = ? AND balance > 0', function(p)
        local out = {}
        for _, v in pairs(vehicles) do if v.citizenid == p[1] and (v.balance or 0) > 0 then out[#out + 1] = v end end
        table.sort(out, function(a, b) return a.plate < b.plate end)
        return out
    end },
    { 'SELECT plate, balance, paymentamount, paymentsleft, financetime FROM player_vehicles WHERE balance > 0 AND plate IN', function(p)
        local out = {}
        for _, plate in ipairs(p) do local v = vehicles[plate] if v and v.balance > 0 then out[#out + 1] = v end end
        return out
    end },
    -- stock
    { 'SELECT stock FROM pfm_vehicleshop_stock WHERE shop = ? AND model = ?', function(p) return stock[sk(p[1], p[2])] end },
    { 'INSERT IGNORE INTO pfm_vehicleshop_stock', function(p) if stock[sk(p[1], p[2])] == nil then stock[sk(p[1], p[2])] = p[3] end return 1 end },
    { 'SELECT model, stock FROM pfm_vehicleshop_stock WHERE shop = ?', function(p)
        local out = {}
        for key, n in pairs(stock) do local shop, model = key:match('^(.-)|(.*)$') if shop == p[1] then out[#out + 1] = { model = model, stock = n } end end
        return out
    end },
    { 'UPDATE pfm_vehicleshop_stock SET stock = stock - 1', function(p)
        local key = sk(p[1], p[2])
        if (stock[key] or 0) > 0 then stock[key] = stock[key] - 1 return 1 end
        return 0
    end },
    { 'UPDATE pfm_vehicleshop_stock SET stock = stock + 1', function(p) local key = sk(p[1], p[2]) stock[key] = (stock[key] or 0) + 1 return 1 end },
    { 'INSERT INTO pfm_vehicleshop_stock (shop, model, stock) VALUES (?, ?, ?) ON DUPLICATE', function(p)
        local key = sk(p[1], p[2])
        stock[key] = (stock[key] or 0) + p[4]
        return 1
    end },
    -- sales record
    { 'INSERT IGNORE INTO pfm_vehicleshop_sales', function(p)
        sales[#sales + 1] = { shop = p[1], model = p[2], plate = p[3], price = p[4], tax = p[5], paid = p[6], financed = p[7], buyer = p[8], seller = p[10], commission = p[12], key = p[13] }
        return #sales
    end },
    { 'SELECT plate, model, buyer_name FROM pfm_vehicleshop_sales WHERE shop IN', function()
        local out = {}
        for _, s in ipairs(sales) do if s.financed == 1 then out[#out + 1] = { plate = s.plate, model = s.model, buyer_name = 'Buyer' } end end
        return out
    end },
    { 'FROM pfm_vehicleshop_sales WHERE shop IN (?) ORDER BY id DESC', function()
        local out = {}
        for _, s in ipairs(sales) do out[#out + 1] = { shop = s.shop, model = s.model, plate = s.plate, price = s.price, paid_now = s.paid, financed = s.financed, seller_cid = s.seller, commission = s.commission } end
        return out
    end },
    { 'FROM pfm_vehicleshop_sales WHERE shop IN (?) AND created_at', function() return { { n = #sales, revenue = 0, mine = 0 } } end },
    { 'UPDATE pfm_vehicleshop_sales SET', function() anonymised = anonymised + 1 return 1 end },
}

local registered, handlers, pushes = {}, {}, {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) registered[def.id] = def return true end,
    RegisterAppHandlers = function(_, id, map) handlers[id] = map return true end,
    Push = function(_, src, app, event, payload) pushes[#pushes + 1] = { src = src, app = app, event = event, payload = payload } return true end,
    PushToJob = function() return 1 end,
}
local taxes, registrations = {}, {}
Mock.exportsByResource['pf-government'] = {
    CalculateTax = function(_, amount, kind)
        if kind == 'vehicle_purchase' then return amount * 8 / 100 end
        if kind == 'vehicle_registration' then return 500 end
        return 0
    end,
    CollectTaxAmount = function(_, amount, kind, _, cid, _, key) taxes[#taxes + 1] = { amount = amount, kind = kind, key = key } return amount end,
    ChargeVehicleRegistration = function(_, cid, data) registrations[#registrations + 1] = { cid = cid, plate = data.plate } return true, 500 end,
}

LedgerEnv.load('pfm-vehicleshop', { 'pfm-vehicleshop/config.lua', 'pfm-vehicleshop/server.lua', 'pfm-vehicleshop/server_apps.lua' })

local BUYER, DEALER, STRANGER = 1, 2, 3
local LUX = Config.Shops.luxury.Location
local function money(src) return Mock.players[src].PlayerData.money end
local function citizen(method, src, payload) return handlers.cardealer[method](src, payload or {}) end
local function staff(method, src, payload) return handlers['cardealer-sales'][method](src, payload or {}) end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function first() for _, v in pairs(vehicles) do return v end end
local function shopIn(cat, id) for _, s in ipairs(cat.shops) do if s.id == id then return s end end end
local function modelIn(shop, model) for _, m in ipairs(shop.models) do if m.model == model then return m end end end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    vehicles, stock, sales, taxes, registrations, pushes = {}, {}, {}, {}, {}, {}
    FakeDB.society('cardealer', 0)
    for _, src in ipairs({ BUYER, DEALER, STRANGER }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = 0, bank = 300000 }
        p.PlayerData.license = 'license:' .. src
        Mock.coords[src] = vector3(LUX.x, LUX.y, LUX.z)
    end
    Mock.players[DEALER].PlayerData.job = { name = 'cardealer', onduty = true, grade = { level = 0 } }
    PFShop.Start()
end

describe('registration', function()
    it('registers the catalogue for everyone and the dealership app for the dealership job, on both devices', function()
        registered = {}
        Mock.eventHandlers['pf-devices:server:ready']()
        assert_true(registered.cardealer.access.anyone)
        assert_eq(registered['cardealer-sales'].access.jobs.cardealer, 0)
        assert_eq(registered.cardealer.devices[1], 'tablet')
        assert_eq(registered['cardealer-sales'].entry, 'html/apps/cardealer.js')
        for _, m in ipairs({ 'catalog', 'finance', 'pay', 'payoff', 'answerOffer' }) do assert_true(handlers.cardealer[m] ~= nil, m) end
        for _, m in ipairs({ 'init', 'nearby', 'offer', 'cancelOffers', 'testDrive', 'orderStock' }) do assert_true(handlers['cardealer-sales'][m] ~= nil, m) end
    end)
end)

describe('the catalogue', function()
    it('lists every shop with its cars, prices, stock and finance terms', function()
        local cat = citizen('catalog', STRANGER)
        assert_true(cat.ok)
        local lux, pdm = shopIn(cat, 'luxury'), shopIn(cat, 'pdm')
        assert_true(lux.managed)
        assert_eq(#lux.models, 2)
        local cog = modelIn(lux, 'cognoscenti')
        assert_eq(cog.price, 100000)
        assert_eq(cog.stock, Config.Stock.Initial)
        assert_eq(cog.minDown, 10000)
        assert_eq(cog.payments, Config.MaximumPayments)
        assert_eq(modelIn(pdm, 'blista').stock, nil)            -- the showroom is not limited
        assert_eq(cat.purchaseTaxPercent, 8)
        assert_eq(cat.registrationFee, 500)
        assert_eq(lux.location.x, math.floor(LUX.x * 100 + 0.5) / 100)
    end)
end)

describe('a dealer sale from the app', function()
    it('waits for the buyer, then charges price + tax once and splits the price once: commission, then the dealership', function()
        local res = staff('offer', DEALER, { model = 'cognoscenti', target = BUYER })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.offer.total, 108000)
        assert_eq(money(BUYER).bank, 300000)                                   -- nothing before the answer
        assert_eq(#Mock.clientEventsNamed('qb-vehicleshop:client:confirmPurchase'), 1)
        local shown = citizen('catalog', BUYER).offer
        assert_eq(shown.id, res.offer.id)
        local pushed = false
        for _, p in ipairs(pushes) do if p.src == BUYER and p.app == 'cardealer' and p.event == 'offer' then pushed = true end end
        assert_true(pushed)

        local done = citizen('answerOffer', BUYER, { id = res.offer.id, accept = true })
        assert_true(done.ok, tostring(done.error))
        assert_eq(money(BUYER).bank, 300000 - 108000)
        -- the commission is the salesperson's share of the price: the dealership gets the rest, and
        -- together they are the price (nothing paid on top)
        local commission = 100000 * Config.Commission
        assert_eq(money(DEALER).bank, 300000 + commission)
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance, 100000 - commission)
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance + (money(DEALER).bank - 300000), 100000)
        assert_eq(sales[1] and sales[1].commission, commission)
        assert_eq(#taxes, 1)
        assert_eq(taxes[1].amount, 8000)
        assert_eq(#registrations, 1)
        assert_eq(registrations[1].cid, 'CID1')
        assert_eq(stock['luxury|cognoscenti'], Config.Stock.Initial - 1)
        assert_eq(#sales, 1)
        assert_eq(sales[1].buyer, 'CID1')
        assert_eq(first().citizenid, 'CID1')
        assert_eq(#Mock.clientEventsNamed('qb-vehicleshop:client:buyShowroomVehicle'), 1)
        -- answering again, in the app or at the prompt, changes nothing
        assert_eq(citizen('answerOffer', BUYER, { id = res.offer.id, accept = true }).error, 'not_found')
        Mock.fireNet('qb-vehicleshop:server:answerPurchase', BUYER, true)
        assert_eq(money(BUYER).bank, 300000 - 108000)
        assert_eq(#LedgerEnv.paid('pfm-vehicleshop:dealer:' .. res.offer.id .. ':commission'), 1)
        assert_eq(#LedgerEnv.paid('pfm-vehicleshop:dealer:' .. res.offer.id .. ':dealership'), 1)
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance, 100000 - commission)
        assert_eq(count(vehicles), 1)
    end)
    it('a declined or wrong offer costs nothing and keeps the car in stock', function()
        local res = staff('offer', DEALER, { model = 'cognoscenti', target = BUYER })
        assert_eq(citizen('answerOffer', BUYER, { id = 'someone-else', accept = true }).error, 'not_found')
        assert_eq(citizen('answerOffer', BUYER, { id = 7, accept = true }).error, 'bad_request')
        assert_eq(citizen('answerOffer', STRANGER, { id = res.offer.id, accept = true }).error, 'not_found')
        assert_true(citizen('answerOffer', BUYER, { id = res.offer.id, accept = false }).declined)
        assert_eq(money(BUYER).bank, 300000)
        assert_eq(stock['luxury|cognoscenti'], Config.Stock.Initial)
        assert_eq(count(vehicles), 0)
    end)
    it('a financed sale takes the down payment and tax, with the finance commission', function()
        local res = staff('offer', DEALER, { model = 'cognoscenti', target = BUYER, finance = { down = 20000, payments = 10 } })
        assert_true(res.ok, tostring(res.error))
        assert_true(citizen('answerOffer', BUYER, { id = res.offer.id, accept = true }).ok)
        assert_eq(money(BUYER).bank, 300000 - 20000 - 8000)
        assert_eq(first().balance, 80000)
        assert_eq(first().paymentsleft, 10)
        -- the finance commission, also out of the price; the shop lends the rest of it
        assert_eq(money(DEALER).bank, 300000 + 100000 * Config.FinanceCommission)
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance, 100000 - 100000 * Config.FinanceCommission)
        assert_eq(sales[1].commission, 100000 * Config.FinanceCommission)
        assert_eq(sales[1].financed, 1)
        local init = staff('init', DEALER)
        assert_eq(#init.plans, 1)
        assert_eq(init.plans[1].balance, 80000)
    end)
    it('a buyer who cannot pay gets nothing, and the car goes back into stock', function()
        Mock.players[BUYER].PlayerData.money.bank = 50000
        local res = staff('offer', DEALER, { model = 'cognoscenti', target = BUYER })
        assert_eq(citizen('answerOffer', BUYER, { id = res.offer.id, accept = true }).error, 'insufficient_funds')
        assert_eq(money(BUYER).bank, 50000)
        assert_eq(stock['luxury|cognoscenti'], Config.Stock.Initial)
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance, 0)
        assert_eq(#registrations, 0)
    end)
    it('is refused for non-staff, out of the dealership, far or absent buyers, bad terms and bad payloads', function()
        assert_eq(staff('offer', STRANGER, { model = 'cognoscenti', target = BUYER }).error, 'not_staff')
        assert_eq(staff('offer', DEALER, { model = 'blista', target = BUYER }).error, 'not_at_dealership')
        assert_eq(staff('offer', DEALER, { model = 'nothing', target = BUYER }).error, 'bad_request')
        assert_eq(staff('offer', DEALER, { model = 'cognoscenti', target = 1.5 }).error, 'bad_request')
        assert_eq(staff('offer', DEALER, { model = 'cognoscenti', target = DEALER }).error, 'Invalid_ID')
        assert_eq(staff('offer', DEALER, { model = 'cognoscenti', target = 99 }).error, 'Invalid_ID')
        assert_eq(staff('offer', DEALER, { model = 'cognoscenti', target = BUYER, finance = { down = 'x', payments = 2 } }).error, 'bad_request')
        assert_eq(staff('offer', DEALER, { model = 'cognoscenti', target = BUYER, finance = { down = 500, payments = 2 } }).error, 'downtoosmall')
        assert_eq(staff('offer', DEALER, { model = 'cognoscenti', target = BUYER, finance = { down = 20000, payments = 99 } }).error, 'exceededmax')
        Mock.coords[BUYER] = vector3(LUX.x + 10, LUX.y, LUX.z)
        assert_eq(staff('offer', DEALER, { model = 'cognoscenti', target = BUYER }).error, 'playertoofar')
        Mock.coords[DEALER] = vector3(0, 0, 0)
        assert_eq(staff('offer', DEALER, { model = 'cognoscenti', target = BUYER }).error, 'not_at_dealership')
        assert_eq(#Mock.clientEventsNamed('qb-vehicleshop:client:confirmPurchase'), 0)
        assert_eq(staff('init', STRANGER).error, 'not_staff')
    end)
    it('an empty stock stops the sale', function()
        stock['luxury|cognoscenti'] = 0
        assert_eq(staff('offer', DEALER, { model = 'cognoscenti', target = BUYER }).error, 'out_of_stock')
    end)
    it('a test drive is of a car this dealership sells, for the customer next to the dealer', function()
        assert_true(staff('testDrive', DEALER, { model = 'nero', target = BUYER }).ok)
        local ev = Mock.clientEventsNamed('qb-vehicleshop:client:customTestDrive')
        assert_eq(ev[1].target, BUYER)
        assert_eq(ev[1].args[1], 'nero')
        assert_eq(staff('testDrive', DEALER, { model = 'blista', target = BUYER }).error, 'bad_model')
        assert_eq(staff('testDrive', STRANGER, { model = 'nero', target = BUYER }).error, 'not_staff')
    end)
end)

describe('stock orders', function()
    it('are paid once by the dealership at the wholesale price, by a grade that may order', function()
        assert_eq(staff('orderStock', DEALER, { shop = 'luxury', model = 'nero', qty = 2 }).error, 'not_allowed')
        Mock.players[DEALER].PlayerData.job.grade = { level = Config.Stock.OrderGrade }
        assert_eq(staff('orderStock', DEALER, { shop = 'luxury', model = 'nero', qty = 2 }).error, 'insufficient_funds')
        assert_eq(stock['luxury|nero'], Config.Stock.Initial)
        FakeDB.bank_accounts.cardealer.account_balance = 1000000
        local res = staff('orderStock', DEALER, { shop = 'luxury', model = 'nero', qty = 2 })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.cost, 2 * 200000 * Config.Stock.WholesalePercent / 100)
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance, 1000000 - res.cost)
        assert_eq(stock['luxury|nero'], Config.Stock.Initial + 2)
        assert_eq(staff('orderStock', DEALER, { shop = 'luxury', model = 'blista', qty = 1 }).error, 'bad_model')
        assert_eq(staff('orderStock', DEALER, { shop = 'pdm', model = 'blista', qty = 1 }).error, 'bad_shop')
        assert_eq(staff('orderStock', DEALER, { shop = 'luxury', model = 'nero', qty = 0 }).error, 'bad_qty')
        assert_eq(staff('orderStock', DEALER, { shop = 'luxury', model = 'nero', qty = 500 }).error, 'bad_qty')
        assert_eq(staff('orderStock', DEALER, { shop = 'luxury', model = 'nero', qty = 1.5 }).error, 'bad_qty')
    end)
end)

describe('finance payments from the app', function()
    local function financedCar(owner)
        vehicles.FIN111 = { citizenid = owner or 'CID1', vehicle = 'cognoscenti', plate = 'FIN111', balance = 8000, paymentamount = 1000, paymentsleft = 8, financetime = 600 }
        return vehicles.FIN111
    end
    it('lists only my financed cars with what is due', function()
        financedCar()
        vehicles.THEIRS = { citizenid = 'CID3', vehicle = 'blista', plate = 'THEIRS', balance = 500, paymentamount = 100, paymentsleft = 5, financetime = 600 }
        local res = citizen('finance', BUYER)
        assert_eq(#res.vehicles, 1)
        assert_eq(res.vehicles[1].plate, 'FIN111')
        assert_eq(res.vehicles[1].payment, 1000)
        assert_eq(res.vehicles[1].dueInMinutes, 600)
        assert_false(res.vehicles[1].overdue)
        assert_eq(res.nextDue, 1000)
    end)
    it('pays the instalment once through the ledger and pays off the rest', function()
        local car = financedCar()
        local res = citizen('pay', BUYER, { plate = 'FIN111' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(car.balance, 7000)
        assert_eq(car.paymentsleft, 7)
        assert_eq(money(BUYER).bank, 299000)
        assert_true(citizen('pay', BUYER, { plate = 'FIN111', amount = 2000 }).ok)
        assert_eq(car.balance, 5000)
        assert_eq(citizen('pay', BUYER, { plate = 'FIN111', amount = 10 }).error, 'minimumallowed')
        assert_true(citizen('payoff', BUYER, { plate = 'FIN111' }).ok)
        assert_eq(car.balance, 0)
        assert_eq(money(BUYER).bank, 300000 - 8000)
        assert_eq(citizen('payoff', BUYER, { plate = 'FIN111' }).error, 'alreadypaid')
    end)
    it('the same payment retried after a crash before the car was updated does not charge again', function()
        local car = financedCar()
        assert_true(citizen('pay', BUYER, { plate = 'FIN111' }).ok)
        car.balance, car.paymentsleft, car.paymentamount = 8000, 8, 1000      -- the update was lost
        assert_true(citizen('pay', BUYER, { plate = 'FIN111' }).ok)
        assert_eq(money(BUYER).bank, 299000)
        assert_eq(car.balance, 7000)
    end)
    it('not enough money: nothing moves; with money later the same payment goes through', function()
        local car = financedCar()
        Mock.players[BUYER].PlayerData.money = { cash = 0, bank = 500 }
        assert_eq(citizen('pay', BUYER, { plate = 'FIN111' }).error, 'notenoughmoney')
        assert_eq(car.balance, 8000)
        Mock.players[BUYER].PlayerData.money.bank = 5000
        assert_true(citizen('pay', BUYER, { plate = 'FIN111' }).ok)
        assert_eq(money(BUYER).bank, 4000)
        assert_eq(car.balance, 7000)
    end)
    it('refuses cars that are not mine and bad payloads', function()
        financedCar('CID3')
        assert_eq(citizen('pay', BUYER, { plate = 'FIN111' }).error, 'not_owned')
        assert_eq(citizen('payoff', BUYER, { plate = 'FIN111' }).error, 'not_owned')
        assert_eq(citizen('pay', BUYER, { plate = 42 }).error, 'bad_plate')
        assert_eq(citizen('pay', STRANGER, { plate = 'FIN111', amount = -5 }).error, 'bad_amount')
        assert_eq(citizen('pay', STRANGER, { plate = 'FIN111', amount = 'all' }).error, 'bad_amount')
        assert_eq(citizen('pay', STRANGER, { plate = 'FIN111', amount = 10.5 }).error, 'bad_amount')
        assert_eq(money(STRANGER).bank, 300000)
        assert_eq(money(BUYER).bank, 300000)
    end)
end)

describe('a deleted character', function()
    it('loses their open offers; the sales record drops their id; a bad id changes nothing', function()
        local res = staff('offer', DEALER, { model = 'cognoscenti', target = BUYER })
        Mock.eventHandlers['pfm-core:server:characterDeleted'](12)
        assert_eq(anonymised, 0)
        Mock.eventHandlers['pfm-core:server:characterDeleted']('CID2')
        assert_eq(anonymised, 2)
        assert_eq(citizen('answerOffer', BUYER, { id = res.offer.id, accept = true }).error, 'not_found')
        assert_eq(money(BUYER).bank, 300000)
    end)
end)
