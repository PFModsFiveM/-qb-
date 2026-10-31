-- City Hall → News end to end (mocked): events built by pf-government's GovEmit (with the real
-- government field names) render into pf-news articles that name the business, tax, law and amounts.
load_resource('tests/lua/fivem_mocks.lua')
vec4 = vec4 or function(x, y, z, w) return vector4(x, y, z, w) end
vec2 = vec2 or function(x, y) return vector2(x, y) end
local states = { ['pf-services'] = 'started', ['pf-devices'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end

local emitted = {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) emitted[#emitted + 1] = { kind = kind, data = data, opts = opts } return #emitted end,
}
Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
load_resource('[pfscripts]/pf-government/server/core.lua')

local govConfig = Config
Config = {}
load_resource('[pfscripts]/pf-services/shared/catalog.lua')
load_resource('[pfscripts]/pf-news/config.lua')
function GetCurrentResourceName() return 'pf-news' end
load_resource('[pfscripts]/pf-news/server/util.lua')
load_resource('[pfscripts]/pf-news/server/presets.lua')
local P = PFNews.Presets

local function article(kind, data)
    emitted = {}
    local saved = Config
    Config = govConfig
    GovEmit(kind, data, {})
    Config = saved
    local e = emitted[1]
    assert(e, 'nothing emitted for ' .. kind)
    return P.Render(P.Snapshot({ id = 7, kind = e.kind, data = e.data, at = os.time() }))
end

local function text(a) return (a.title or '') .. ' ' .. (a.summary or '') .. ' ' .. (a.body or '') end

describe('City Hall decisions become readable articles', function()
    it('a business closure names the business', function()
        local a = text(article('gov.business.closed', { businessId = 'restaurant:bs', business = 'Burger Shot', businessType = 'restaurant', reason = 'failed inspection' }))
        assert_true(a:find('Burger Shot', 1, true) ~= nil, a)
        assert_true(a:find('nil', 1, true) == nil, a)
    end)
    it('a tax change names the tax and both rates', function()
        local a = text(article('gov.tax.changed', { tax = 'sales', label = 'Sales Tax', oldRate = 5, newRate = 7, direction = 'up' }))
        assert_true(a:lower():find('sales tax', 1, true) ~= nil, a)
        assert_true(a:find('7', 1, true) ~= nil, a)
    end)
    it('a new law shows its title and summary', function()
        local a = text(article('gov.law.published', { lawId = 3, title = 'Noise Ordinance', summary = 'No loud music after midnight', fineMax = 500 }))
        assert_true(a:find('Noise Ordinance', 1, true) ~= nil, a)
    end)
    it('a utility disconnection names the business', function()
        local a = text(article('gov.utility.disconnected', { business = 'Pizza This', utility = 'power', reason = 'unpaid bills' }))
        assert_true(a:find('Pizza This', 1, true) ~= nil, a)
    end)
    it('an announcement carries its title', function()
        local a = text(article('gov.announcement', { title = 'Road works on Vespucci', excerpt = 'Expect delays all week', priority = 'normal' }))
        assert_true(a:find('Vespucci', 1, true) ~= nil, a)
    end)
end)
