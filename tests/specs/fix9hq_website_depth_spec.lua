-- pf-computer: a website the editor builds saves, whatever modules it holds. The editor's
-- Cards Grid / Quick Links items sit at depth 6 (state > pages > slug > modules > module > items > item),
-- which the save sanitizer used to refuse, so any site with those modules could not be saved.
-- Anything nested deeper is refused as too deep (not "too large").
load_resource('tests/lua/fivem_mocks.lua')

local started = { ['pfm-core'] = true, ['pfm-banking'] = false, ['pf-citizen'] = true, ['pf-government'] = true, ['pfm-inventory'] = true, ['pf-stores'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-computer' end
function LoadResourceFile() return nil end
function SaveResourceFile() return true end
function RegisterCommand() end

QBCoreMock.Shared.Jobs = {
    unemployed = { label = 'Civilian', grades = { ['0'] = { name = 'Freelancer', payment = 10 } } },
}
Mock.exportsByResource['pf-citizen'] = { SendMail = function() return true end, SendMailToAll = function() return true end }
Mock.exportsByResource['pf-government'] = { HasPermission = function() return false end }
Mock.exportsByResource['pfm-inventory'] = { CreateInventory = function() return true end, GetInventory = function() return { items = {} } end }
Mock.exportsByResource['pf-stores'] = { RegisterBuyerKind = function() return true end, ListOwnedStores = function() return { ok = true, data = { stores = {} } } end }

Config = nil
load_resource('[pfscripts]/pf-computer/config/config.lua')
load_resource('[pfscripts]/pf-computer/server/main.lua')

local OWNER = 3
local function call(src, action, payload)
    Mock.clientEvents = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.fireNet('pf-computer:server:callback', src, 7, action, payload or {})
    local ev = Mock.clientEventsNamed('pf-computer:client:callback')[1]
    return ev and ev.args[2]
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    local p = Mock.newPlayer(OWNER, 'CIT1')
    p.Functions.Save = function() end
    p.PlayerData.job = { name = 'unemployed', label = 'Civilian', grade = { level = 0, name = 'Freelancer' }, isboss = false }
end

local domainCount = 0
local function buyDomain()
    domainCount = domainCount + 1
    local domain = 'site' .. domainCount .. '.ls'
    started['pfm-banking'] = true
    Mock.exportsByResource['pfm-banking'] = { Transfer = function() return { ok = true } end }
    local res = call(OWNER, 'browser:domain:buy', { domain = domain })
    started['pfm-banking'] = false
    Mock.exportsByResource['pfm-banking'] = nil
    assert(res and res.ok, 'domain purchase: ' .. tostring(res and res.error))
    return domain
end

-- ui/js/script.js buildModuleLibrary(): every module type with its default fields and items
local LIBRARY = {
    hero = { title = 'Page Heading', body = 'Introduce the page here.', buttonLabel = 'Action', buttonUrl = '' },
    text = { title = 'Section Title', body = 'Write your content here.' },
    callout = { title = 'Important Notice', body = 'Highlight a message for visitors.' },
    cards = { title = 'Highlights', items = { { title = 'Card One', body = 'Describe the first item.' }, { title = 'Card Two', body = 'Describe the second item.' } } },
    links = { title = 'Quick Links', items = { { label = 'Home', url = 'home' }, { label = 'Contact', url = 'contact' } } },
    image = { title = 'Image', imageUrl = '', body = 'Use a hosted image URL for your logo or content.' },
}
local ORDER = { 'hero', 'text', 'callout', 'cards', 'links', 'image' }

-- the state the editor sends on Save (normalizeWebsiteState + modules added from the library)
local function editorModule(kind, i)
    local d = LIBRARY[kind]
    local items = {}
    for n, item in ipairs(d.items or {}) do
        local copy = {}
        for k, v in pairs(item) do copy[k] = v end
        items[n] = copy
    end
    return {
        id = kind .. '_' .. i .. '_1730000000000', type = kind,
        title = d.title or '', body = d.body or '', buttonLabel = d.buttonLabel or '', buttonUrl = d.buttonUrl or '',
        imageUrl = d.imageUrl or '', items = items,
    }
end
local function editorState(domain)
    local modules = {}
    for i, kind in ipairs(ORDER) do modules[i] = editorModule(kind, i) end
    local about = {}
    for i, kind in ipairs(ORDER) do about[i] = editorModule(kind, i + 10) end
    return {
        domain = domain, owner = {}, themeMode = 'auto',
        theme = { accent = '#143d6b', background = '#f5f7fb', surface = '#ffffff', text = '#10233a' },
        branding = { siteName = domain, tagline = 'Player-owned website', logoUrl = '' },
        pages = { home = { title = 'Home', modules = modules }, ['about-us'] = { title = 'About', modules = about } },
    }
end

describe('pf-computer website save depth', function()
    it('a site holding every module type from the editor library, with default items, saves', function()
        local domain = buyDomain()
        local res = call(OWNER, 'browser:website:save', { domain = domain, state = editorState(domain) })
        assert_true(res and res.ok, 'save: ' .. tostring(res and res.error))
        local home = res.data.pages.home.modules
        assert_eq(#home, #ORDER)
        for i, kind in ipairs(ORDER) do assert_eq(home[i].type, kind) end
        assert_eq(home[4].items[2].title, 'Card Two', 'cards items kept')
        assert_eq(home[5].items[1].label, 'Home', 'links items kept')
        assert_eq(home[5].items[2].url, 'contact')
        assert_eq(res.data.pages['about-us'].modules[4].items[1].body, 'Describe the first item.')
        -- and it is what visitors get
        local view = call(OWNER, 'browser:website:get', { domain = domain })
        assert_true(view and view.ok, 'get: ' .. tostring(view and view.error))
        assert_eq(view.data.state.pages.home.modules[4].items[1].title, 'Card One')
    end)
    it('each Cards Grid and Quick Links module saves on its own', function()
        for _, kind in ipairs({ 'cards', 'links' }) do
            local domain = buyDomain()
            local state = { pages = { home = { title = 'Home', modules = { editorModule(kind, 1) } } } }
            local res = call(OWNER, 'browser:website:save', { domain = domain, state = state })
            assert_true(res and res.ok, kind .. ': ' .. tostring(res and res.error))
            assert_eq(#res.data.pages.home.modules[1].items, 2)
        end
    end)
    it('a value nested deeper than the editor makes is refused as too deep', function()
        local domain = buyDomain()
        local state = editorState(domain)
        -- an object pasted into a card's items JSON: a table at depth 7
        state.pages.home.modules[4].items[1].extra = { nested = 'x' }
        assert_eq(call(OWNER, 'browser:website:save', { domain = domain, state = state }).error, 'website_too_deep')
        local deep, t = {}, nil
        t = deep
        for _ = 1, 10 do t.x = {} t = t.x end
        assert_eq(call(OWNER, 'browser:website:save', { domain = domain, state = deep }).error, 'website_too_deep')
    end)
    it('the size limits still hold and say too large', function()
        local domain = buyDomain()
        assert_eq(call(OWNER, 'browser:website:save', { domain = domain, state = { pages = { home = { body = string.rep('x', 70000) } } } }).error, 'website_too_large')
        local wide = {}
        for i = 1, 100 do wide['k' .. i] = 'v' end
        assert_eq(call(OWNER, 'browser:website:save', { domain = domain, state = wide }).error, 'website_too_large')
        local state = editorState(domain)
        local many = {}
        for i = 1, 61 do many[i] = { title = 'c' .. i, body = 'b' } end
        state.pages.home.modules[4].items = many
        assert_eq(call(OWNER, 'browser:website:save', { domain = domain, state = state }).error, 'website_too_large')
    end)
end)
