-- Car Dealer apps (pf-devices, tablet and computer).
--   cardealer         everyone: the catalogue of every shop with prices, stock and finance terms, the
--                     citizen's financed cars with what is due (paid through the ledger), and a
--                     dealer's offer to answer.
--   cardealer-sales   dealership staff (the managed shops' jobs): sell or finance a car to the customer
--                     next to them (the customer accepts on their own screen), test drives, stock
--                     orders paid by the dealership, the sales record, commissions and finance plans.
-- Every handler goes through the same server functions as the showroom (server.lua): prices come
-- from the shared vehicle list, money only moves through the pfm-banking ledger.

PFShop = PFShop or {}

local CITIZEN_APP, STAFF_APP = 'cardealer', 'cardealer-sales'
local sharedVehicles = exports['pfm-core']:GetShared('Vehicles') or {}

local function started(res) return GetResourceState(res) == 'started' end
local function playerOf(src) return exports['pfm-core']:GetPlayer(tonumber(src)) end

local function point(v)
    if not v or not tonumber(v.x) or not tonumber(v.y) then return nil end
    return { x = math.floor(v.x * 100 + 0.5) / 100, y = math.floor(v.y * 100 + 0.5) / 100 }
end

local function round(x) return x >= 0 and math.floor(x + 0.5) or math.ceil(x - 0.5) end

local function nameOf(Player)
    local ci = Player and Player.PlayerData.charinfo or {}
    return (('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function cleanPlate(v)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' or #v > 16 or v:find('[%c]') then return nil end
    return v
end

local function cleanModel(v)
    if type(v) ~= 'string' or v == '' or #v > 64 then return nil end
    return sharedVehicles[v] and v or nil
end

local function sells(v, shopName)
    if type(v.shop) == 'table' then
        for _, s in pairs(v.shop) do if s == shopName then return true end end
        return false
    end
    return v.shop == shopName
end

local function govRate(kind, base)
    if not started('pf-government') then return 0 end
    local ok, v = pcall(function() return exports['pf-government']:CalculateTax(base, kind) end)
    return ok and tonumber(v) or 0
end

-- Finance terms for a car at the minimum down payment and the most payments (what the app shows).
local function financeExample(price)
    local down = round((Config.MinimumDown / 100) * price)
    local balance = price - down
    return { minDown = down, payments = Config.MaximumPayments, perPayment = round(balance / Config.MaximumPayments) }
end

local function stockDefault() return math.max(0, math.floor(tonumber((Config.Stock or {}).Initial) or 0)) end

local function shopModels(shopName, shop)
    local stock = (shop.Type == 'managed') and PFShop.ShopStock(shopName) or {}
    local tracked = shop.Type == 'managed' and PFShop.dbReady and (Config.Stock or {}).Enabled ~= false
    local out = {}
    for model, v in pairs(sharedVehicles) do
        local price = tonumber(v.price)
        if price and price > 0 and sells(v, shopName) then
            local fin = financeExample(price)
            out[#out + 1] = {
                model = model, name = v.name or model, brand = v.brand or '', category = v.category or '', price = price,
                stock = tracked and (stock[model] or stockDefault()) or nil,
                minDown = fin.minDown, payments = fin.payments, perPayment = fin.perPayment,
            }
        end
    end
    table.sort(out, function(a, b) if a.price ~= b.price then return a.price < b.price end return a.model < b.model end)
    return out
end

local function push(src, app, event, payload)
    if not started('pf-devices') then return end
    pcall(function() exports['pf-devices']:Push(src, app, event, payload or {}) end)
end

function PFShop.PushFinance(src) push(src, CITIZEN_APP, 'changed') end

-- ── citizens ────────────────────────────────────────────────────────────────────────────────────

function PFShop.Catalog(src)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local shops = {}
    for name, shop in pairs(Config.Shops) do
        shops[#shops + 1] = {
            id = name, label = shop.ShopLabel or name, type = shop.Type, managed = shop.Type == 'managed',
            location = point(shop.Location), testDriveMinutes = tonumber(shop.TestDriveTimeLimit), models = shopModels(name, shop),
        }
    end
    table.sort(shops, function(a, b) return a.label < b.label end)
    return {
        ok = true, shops = shops, offer = PFShop.PendingOfferFor(src),
        finance = { minDownPercent = Config.MinimumDown, maxPayments = Config.MaximumPayments, intervalHours = Config.PaymentInterval },
        purchaseTaxPercent = govRate('vehicle_purchase', 10000) / 100,
        registrationFee = govRate('vehicle_registration', 1),
    }
end

--- The citizen's financed cars: balance, instalment, payments left and the play time until the next
--- payment is due (counting this session).
function PFShop.MyFinance(src)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local cid = Player.PlayerData.citizenid
    local rows = MySQL.query.await('SELECT plate, vehicle, balance, paymentamount, paymentsleft, financetime FROM player_vehicles WHERE citizenid = ? AND balance > 0', { cid }) or {}
    local since = PFShop.SessionStart(cid)
    local played = since and math.max(0, (os.time() - since) / 60) or 0
    local out, due = {}, 0
    for _, r in ipairs(rows) do
        local v = sharedVehicles[r.vehicle] or {}
        local minutes = math.max(0, math.floor((tonumber(r.financetime) or 0) - played))
        local balance, amount = tonumber(r.balance) or 0, tonumber(r.paymentamount) or 0
        out[#out + 1] = {
            plate = r.plate, model = r.vehicle, label = (v.brand and v.brand ~= '' and (v.brand .. ' ' .. (v.name or r.vehicle))) or v.name or r.vehicle,
            balance = balance, payment = math.min(amount, balance), paymentsLeft = tonumber(r.paymentsleft) or 0,
            dueInMinutes = minutes, overdue = minutes < 1, lastPayment = balance <= amount,
        }
        due = due + math.min(amount, balance)
    end
    table.sort(out, function(a, b) return a.dueInMinutes < b.dueInMinutes end)
    local m = Player.PlayerData.money or {}
    return { ok = true, vehicles = out, nextDue = due, cash = tonumber(m.cash) or 0, bank = tonumber(m.bank) or 0, offer = PFShop.PendingOfferFor(src),
        warningMinutes = Config.PaymentWarning }
end

--- Pays the instalment (or a larger amount) of the citizen's own financed car; the last instalment
--- pays it off.
function PFShop.AppPay(src, payload)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local plate = cleanPlate(payload and payload.plate)
    if not plate then return { ok = false, error = 'bad_plate' } end
    local amount = payload.amount
    if amount ~= nil and (type(amount) ~= 'number' or amount ~= math.floor(amount) or amount <= 0) then return { ok = false, error = 'bad_amount' } end
    local row = MySQL.query.await('SELECT balance, paymentamount, paymentsleft, financetime FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, Player.PlayerData.citizenid })
    row = row and row[1]
    if not row then return { ok = false, error = 'not_owned' } end
    local balance, minimum = tonumber(row.balance) or 0, tonumber(row.paymentamount) or 0
    if balance <= 0 then return { ok = false, error = 'alreadypaid' } end
    local res
    if (amount == nil and balance <= minimum) or (amount ~= nil and amount >= balance) then
        res = PFShop.PayOff(src, plate)
    else
        res = PFShop.FinancePayment(src, plate, amount or minimum)
    end
    if res.ok then push(src, CITIZEN_APP, 'changed') end
    return res
end

function PFShop.AppPayOff(src, payload)
    local plate = cleanPlate(payload and payload.plate)
    if not plate then return { ok = false, error = 'bad_plate' } end
    local res = PFShop.PayOff(src, plate)
    if res.ok then push(src, CITIZEN_APP, 'changed') end
    return res
end

function PFShop.AppAnswer(src, payload)
    if type(payload.id) ~= 'string' or #payload.id > 48 then return { ok = false, error = 'bad_request' } end
    return PFShop.AnswerOffer(src, payload.accept == true, payload.id)
end

-- ── dealership staff ────────────────────────────────────────────────────────────────────────────

local function staffShops(Player)
    local job = Player and Player.PlayerData.job
    local out = {}
    if not job then return out end
    for name, shop in pairs(Config.Shops) do
        if shop.Type == 'managed' and shop.Job == job.name then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

local function staffOf(src)
    local Player = playerOf(src)
    if not Player then return nil, 'no_player' end
    if #staffShops(Player) == 0 then return nil, 'not_staff' end
    return Player
end

local function canOrder(Player)
    local job = Player.PlayerData.job or {}
    local grade = tonumber(type(job.grade) == 'table' and job.grade.level or job.grade) or 0
    return job.isboss == true or grade >= (tonumber((Config.Stock or {}).OrderGrade) or 99)
end

local function wholesale(price) return math.floor(price * (tonumber((Config.Stock or {}).WholesalePercent) or 70) / 100) end

function PFShop.StaffInit(src)
    local Player, err = staffOf(src)
    if not Player then return { ok = false, error = err } end
    local job = Player.PlayerData.job.name
    local shops = {}
    for _, name in ipairs(staffShops(Player)) do
        local shop = Config.Shops[name]
        local models = shopModels(name, shop)
        for _, m in ipairs(models) do m.wholesale = wholesale(m.price) end
        shops[#shops + 1] = { id = name, label = shop.ShopLabel or name, location = point(shop.Location), models = models }
    end
    local balance
    if started('pfm-banking') then
        local ok, v = pcall(function() return exports['pfm-banking']:GetAccountBalance(job) end)
        balance = ok and tonumber(v) or nil
    end
    local sales, stats, plans = {}, { count = 0, revenue = 0, mine = 0 }, {}
    if PFShop.dbReady then
        local names = staffShops(Player)
        local marks = string.rep('?,', #names):sub(1, -2)
        for _, r in ipairs(MySQL.query.await(('SELECT shop, model, plate, price, paid_now, financed, buyer_name, seller_name, seller_cid, commission, UNIX_TIMESTAMP(created_at) AS at FROM pfm_vehicleshop_sales WHERE shop IN (%s) ORDER BY id DESC LIMIT 25'):format(marks), names) or {}) do
            local v = sharedVehicles[r.model] or {}
            sales[#sales + 1] = {
                shop = r.shop, model = r.model, label = v.name or r.model, plate = r.plate, price = tonumber(r.price), paid = tonumber(r.paid_now),
                financed = tonumber(r.financed) == 1, buyer = r.buyer_name, seller = r.seller_name, at = tonumber(r.at),
                commission = r.seller_cid == Player.PlayerData.citizenid and tonumber(r.commission) or nil,
            }
        end
        local params = {}
        params[1] = Player.PlayerData.citizenid
        for i, n in ipairs(names) do params[i + 1] = n end
        local row = MySQL.single.await(('SELECT COUNT(*) AS n, COALESCE(SUM(price), 0) AS revenue, COALESCE(SUM(CASE WHEN seller_cid = ? THEN commission ELSE 0 END), 0) AS mine FROM pfm_vehicleshop_sales WHERE shop IN (%s) AND created_at >= NOW() - INTERVAL 7 DAY'):format(marks), params) or {}
        stats = { count = tonumber(row.n) or 0, revenue = tonumber(row.revenue) or 0, mine = tonumber(row.mine) or 0 }
        -- finance plans of cars this dealership sold that are still being paid (two queries, no join:
        -- player_vehicles may use another collation than this resource's table)
        local sold = MySQL.query.await(('SELECT plate, model, buyer_name FROM pfm_vehicleshop_sales WHERE shop IN (%s) AND financed = 1 ORDER BY id DESC LIMIT 200'):format(marks), names) or {}
        if #sold > 0 then
            local byPlate, plates = {}, {}
            for _, r in ipairs(sold) do
                if not byPlate[r.plate] then byPlate[r.plate] = r plates[#plates + 1] = r.plate end
            end
            local pm = string.rep('?,', #plates):sub(1, -2)
            for _, r in ipairs(MySQL.query.await('SELECT plate, balance, paymentamount, paymentsleft, financetime FROM player_vehicles WHERE balance > 0 AND plate IN (' .. pm .. ')', plates) or {}) do
                local s = byPlate[r.plate]
                local v = sharedVehicles[s.model] or {}
                plans[#plans + 1] = {
                    plate = r.plate, label = v.name or s.model, buyer = s.buyer_name, balance = tonumber(r.balance),
                    payment = tonumber(r.paymentamount), paymentsLeft = tonumber(r.paymentsleft), dueInMinutes = tonumber(r.financetime),
                }
            end
            table.sort(plans, function(a, b) return (a.dueInMinutes or 0) < (b.dueInMinutes or 0) end)
        end
    end
    return {
        ok = true, shops = shops, balance = balance, canOrder = canOrder(Player), offers = PFShop.OffersBy(src),
        sales = sales, stats = stats, plans = plans, onDuty = Player.PlayerData.job.onduty == true,
        finance = { minDownPercent = Config.MinimumDown, maxPayments = Config.MaximumPayments },
        commission = { sale = Config.Commission, finance = Config.FinanceCommission or Config.Commission },
        stock = { tracked = PFShop.dbReady and (Config.Stock or {}).Enabled ~= false, maxOrder = (Config.Stock or {}).MaxOrder or 10 },
        saleDistance = tonumber(Config.SaleDistance) or 3.0,
    }
end

function PFShop.Nearby(src)
    local Player, err = staffOf(src)
    if not Player then return { ok = false, error = err } end
    local out = {}
    local mine = GetEntityCoords(GetPlayerPed(src))
    local range = (tonumber(Config.SaleDistance) or 3.0)
    for _, P in pairs(exports['pfm-core']:GetCoreObject({ 'Functions' }).Functions.GetQBPlayers() or {}) do
        local other = P.PlayerData.source
        if other ~= src then
            local pos = GetEntityCoords(GetPlayerPed(other))
            if #(vector3(mine.x, mine.y, mine.z) - vector3(pos.x, pos.y, pos.z)) < range then out[#out + 1] = { id = other, name = nameOf(P) } end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return { ok = true, players = out }
end

function PFShop.StaffOffer(src, payload)
    local Player, err = staffOf(src)
    if not Player then return { ok = false, error = err } end
    local model = cleanModel(payload.model)
    local target = tonumber(payload.target)
    if not model or not target or target ~= math.floor(target) then return { ok = false, error = 'bad_request' } end
    local down, payments
    if payload.finance ~= nil then
        if type(payload.finance) ~= 'table' or type(payload.finance.down) ~= 'number' or type(payload.finance.payments) ~= 'number' then
            return { ok = false, error = 'bad_request' }
        end
        down, payments = payload.finance.down, payload.finance.payments
    end
    return PFShop.DealerOffer(src, target, model, down, payments)
end

function PFShop.StaffTestDrive(src, payload)
    local Player, err = staffOf(src)
    if not Player then return { ok = false, error = err } end
    local model = cleanModel(payload.model)
    if not model or type(payload.target) ~= 'number' then return { ok = false, error = 'bad_request' } end
    return PFShop.OfferTestDrive(src, payload.target, model)
end

--- Buys cars for the dealership's stock from the manufacturer: the dealership's society account pays
--- the wholesale price through the ledger, then the stock grows.
function PFShop.OrderStock(src, payload)
    local Player, err = staffOf(src)
    if not Player then return { ok = false, error = err } end
    if not canOrder(Player) then return { ok = false, error = 'not_allowed' } end
    local shopName = type(payload.shop) == 'string' and payload.shop or nil
    local allowed = false
    for _, n in ipairs(staffShops(Player)) do if n == shopName then allowed = true end end
    if not allowed then return { ok = false, error = 'bad_shop' } end
    local model = cleanModel(payload.model)
    if not model or not sells(sharedVehicles[model], shopName) or not tonumber(sharedVehicles[model].price) then return { ok = false, error = 'bad_model' } end
    local qty = payload.qty
    if type(qty) ~= 'number' or qty ~= math.floor(qty) or qty < 1 or qty > ((Config.Stock or {}).MaxOrder or 10) then return { ok = false, error = 'bad_qty' } end
    if not PFShop.dbReady or (Config.Stock or {}).Enabled == false then return { ok = false, error = 'stock_untracked' } end
    local cost = wholesale(tonumber(sharedVehicles[model].price)) * qty
    PFShop.StockOf(shopName, model)   -- the row exists before it grows
    local job = Player.PlayerData.job.name
    local res = PFPayout.Transfer({
        from = 'society:' .. job, to = PFPayout.SYSTEM, amount = cost,
        key = ('pfm-vehicleshop:stock:%s:%s'):format(shopName, PFPayout.NewId()), kind = 'purchase',
        reason = ('Stock order: %dx %s'):format(qty, sharedVehicles[model].name or model), actor = Player.PlayerData.citizenid,
    })
    if not res.ok then return { ok = false, error = res.error == 'insufficient_funds' and 'insufficient_funds' or (res.error or 'payment_failed') } end
    PFShop.AddStock(shopName, model, qty)
    pcall(function() exports['pf-devices']:PushToJob(job, STAFF_APP, 'changed', {}, false) end)
    return { ok = true, cost = cost, stock = PFShop.StockOf(shopName, model) }
end

function PFShop.StaffCancel(src)
    local Player, err = staffOf(src)
    if not Player then return { ok = false, error = err } end
    return { ok = true, cancelled = PFShop.CancelOffersBy(src) }
end

-- ── registration ────────────────────────────────────────────────────────────────────────────────

local function staffJobs()
    local jobs = {}
    for _, shop in pairs(Config.Shops) do
        if shop.Type == 'managed' and type(shop.Job) == 'string' and shop.Job ~= 'none' then jobs[shop.Job] = 0 end
    end
    if next(jobs) == nil then jobs.cardealer = 0 end
    return jobs
end

function PFShop.RegisterApps()
    if not started('pf-devices') then return end
    local devices = exports['pf-devices']
    devices:RegisterApp({
        id = CITIZEN_APP, name = 'Car Dealer', icon = '🚘', entry = 'html/apps/cardealer.js', styles = { 'html/apps/cardealer.css' },
        devices = { 'tablet', 'computer' }, category = 'apps', order = 22, access = { anyone = true },
        window = { width = 940, height = 640 }, description = 'Vehicle catalogue, finance and payments',
    })
    devices:RegisterApp({
        id = STAFF_APP, name = 'Dealership', icon = '🏎️', entry = 'html/apps/cardealer.js', styles = { 'html/apps/cardealer.css' },
        devices = { 'tablet', 'computer' }, category = 'jobs', order = 41, access = { jobs = staffJobs() },
        window = { width = 980, height = 660 }, description = 'Sales, finance, stock and commissions',
    })
    devices:RegisterAppHandlers(CITIZEN_APP, {
        catalog = function(src) return PFShop.Catalog(src) end,
        finance = function(src) return PFShop.MyFinance(src) end,
        pay = function(src, p) return PFShop.AppPay(src, p) end,
        payoff = function(src, p) return PFShop.AppPayOff(src, p) end,
        answerOffer = function(src, p) return PFShop.AppAnswer(src, p) end,
    })
    devices:RegisterAppHandlers(STAFF_APP, {
        init = function(src) return PFShop.StaffInit(src) end,
        nearby = function(src) return PFShop.Nearby(src) end,
        offer = function(src, p) return PFShop.StaffOffer(src, p) end,
        cancelOffers = function(src) return PFShop.StaffCancel(src) end,
        testDrive = function(src, p) return PFShop.StaffTestDrive(src, p) end,
        orderStock = function(src, p) return PFShop.OrderStock(src, p) end,
    })
end

function PFShop.Start()
    local ok, done, err = pcall(function() return exports['pfm-core']:RunMigrations(GetCurrentResourceName(), PFShop.Migrations) end)
    PFShop.dbReady = ok and done == true
    if not PFShop.dbReady then print('^1[pfm-vehicleshop]^7 migrations failed, dealership stock and sales are not tracked: ' .. tostring(ok and err or done)) end
    PFShop.RegisterApps()
end

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then PFShop.Start()
    elseif resource == 'pf-devices' then PFShop.RegisterApps() end
end)
AddEventHandler('pf-devices:server:ready', function() PFShop.RegisterApps() end)

AddEventHandler('QBCore:Server:UpdateObject', function()
    sharedVehicles = exports['pfm-core']:GetShared('Vehicles') or sharedVehicles
end)
