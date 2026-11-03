-- Batch 14, pf-restaurants client code:
--  X5  the cooking display places the server's start time on the client's clock (serverNow), so
--      progress runs from 0 and the doneness windows show; the label matches what the server will
--      judge when the dish is taken off. (It compared GetGameTimer with epoch seconds * 1000, so the
--      progress was always far below zero and every steak showed "Raw".)
--  X1  the customer's bill prompt passes plain text to pfm-menu (the third guard after the server's
--      plain-text rule and pfm-menu's escaping).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetResourceState() return 'missing' end
function RegisterNUICallback() end
function SetNuiFocus() end
function SendNUIMessage() end

Config = nil
load_resource('[pfscripts]/pf-restaurants/config/shared.lua')
load_resource('[pfscripts]/pf-restaurants/config/items.lua')
load_resource('[pfscripts]/pf-restaurants/config/restaurants.lua')
load_resource('[pfscripts]/pf-restaurants/config/stations.lua')
load_resource('[pfscripts]/pf-restaurants/config/recipes.lua')
QBCore = QBCoreMock
-- the server's doneness rules, to compare the client's labels with
load_resource('[pfscripts]/pf-restaurants/server/stations.lua')
local serverDoneness = CalculateDoneness
load_resource('[pfscripts]/pf-restaurants/client/stations.lua')
load_resource('[pfscripts]/pf-restaurants/client/registers.lua')

local menus = {}
Mock.exportsByResource['pfm-menu'] = { openMenu = function(_, data) menus[#menus + 1] = data end }

BeforeEach = function() Mock.reset() menus = {} end

describe('X5: the cooking display', function()
    it('a session that started 10 s ago on the server shows 10 s of progress on any client clock', function()
        local session = { sessionId = 's1', startTime = 1700000000, serverNow = 1700000010, duration = 25000, requiresDoneness = true }
        PlaceOnLocalClock(session, 5000)            -- this client has run for 5 s only
        assert_near(CookProgress(session, 5000), 0.4, 1e-9)
        assert_near(CookProgress(session, 5000 + 10000), 0.8, 1e-9)
        assert_eq((CookStatus(session, CookProgress(session, 5000 + 10000))), 'Medium-Rare Window')
    end)

    it('a session received as it starts begins at 0 and is done after its duration', function()
        local session = { sessionId = 's2', startTime = 1700000000, serverNow = 1700000000, duration = 25000 }
        PlaceOnLocalClock(session, 123456)
        assert_near(CookProgress(session, 123456), 0, 1e-9)
        assert_eq((CookStatus(session, CookProgress(session, 123456 + 12000))), 'Cooking')
        assert_eq((CookStatus(session, CookProgress(session, 123456 + 26000))), 'Ready')
    end)

    it('every window shown is the doneness the server gives at that moment', function()
        local label = { Raw = 'undercooked', ['Rare Window'] = 'rare', ['Medium-Rare Window'] = 'medium-rare',
            ['Medium Window'] = 'medium', ['Well-Done Window'] = 'well-done', ['BURNING!'] = 'burnt' }
        local session = { requiresDoneness = true }
        for _, p in ipairs({ 0.3, 0.65, 0.8, 0.9, 1.0, 1.05, 1.2 }) do
            local shown = CookStatus(session, p)
            local judged = serverDoneness(p, 'medium')
            assert_eq(label[shown], judged, ('progress %.2f shows %s'):format(p, shown))
        end
    end)
end)

describe('X1: the bill prompt', function()
    it('names reach pfm-menu as plain text; Pay and Decline stay the only buttons', function()
        Mock.fireNet('pf-restaurants:client:confirmPayment', nil, {
            orderId = 'R1', restaurant = '<b>Burger</b> "Shot"', total = 22, tax = 2, paymentMethod = 'card',
            items = { { name = '<img src=x onerror=postData(1)>', qty = 2 }, { name = "Fish & Chips", qty = 1 } },
        })
        local menu = menus[1]
        assert_true(menu ~= nil, 'the prompt opened')
        for _, entry in ipairs(menu) do
            for _, field in ipairs({ 'header', 'txt' }) do
                if entry[field] then assert_false(entry[field]:find('[<>"`]'), field .. ': ' .. entry[field]) end
            end
        end
        assert_true(menu[1].txt:find('Fish & Chips', 1, true) ~= nil, menu[1].txt)
        assert_true(menu[1].isMenuHeader)
        assert_eq(menu[2].header, 'Pay')
        assert_true(menu[2].params.args.accept)
        assert_eq(menu[3].header, 'Decline')
        assert_eq(#menu, 3)
    end)
end)
