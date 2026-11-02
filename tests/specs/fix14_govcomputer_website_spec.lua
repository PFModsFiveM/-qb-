-- Batch 14, pf-government (mocked):
--   G1  the official website is edited only with the 'website' permission; what is stored is cut to
--       what the editor makes (known fields, bounded text, at most 64 KB), saves are spaced out and
--       written to the KVP at most once per flush window; the editor is offered only with the right;
--   G3  the Deputy Mayor (not only 'all') corrects civilians and their records; records are their
--       own permission ('records'), identity and job edits stay 'civilians'.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pf-government' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4 or function(x, y, z, w) return { x = x, y = y, z = z, w = w } end

local kvp, kvpWrites = {}, 0
function GetResourceKvpString(k) return kvp[k] end
function SetResourceKvp(k, v) kvp[k] = v kvpWrites = kvpWrites + 1 end
local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
local function runTimers() local t = timers timers = {} for _, x in ipairs(t) do x.fn() end end

local audits = {}
MySQL = setmetatable({}, { __index = function() return setmetatable({ await = function() return nil end }, { __call = function() end }) end })
Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
for _, f in ipairs({ 'server/core.lua', 'server/callbacks.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function LogAudit(action, cid) audits[#audits + 1] = { action = action, cid = cid } end
function DebugPrint() end
local govX = Mock.exportsByResource['__self']

local MAYOR, DEPUTY, CLERK, UTIL, CIV = 1, 2, 3, 4, 5
local function nui(src, action, data)
    local before = #Mock.clientEvents
    Mock.fireNet('pf-government:server:nuiCallback', src, 'cb1', action, data or {})
    for i = #Mock.clientEvents, before + 1, -1 do
        local e = Mock.clientEvents[i]
        if e.name == 'pf-government:client:nuiCallback' then return e.args[2] end
    end
end

local function site()
    return {
        globalNotice = 'Official notice',
        siteChrome = { brandTitle = 'Los Santos', footerResourcesItems = { 'Notices', 'Code' } },
        pages = {
            home = { kicker = 'k', title = 'Welcome', intro = 'Line one\nLine two', blocks = {
                { id = 'block-1', type = 'cards', eyebrow = 'e', title = 'Cards', body = 'b', items = { 'A|a', 'B|b' }, buttonLabel = 'Go', buttonPage = 'laws' },
            } },
            laws = { kicker = 'Code', title = 'Laws', intro = '', blocks = {} },
        },
    }
end

local clockAt = 1000000
BeforeEach = function()
    runTimers()   -- a write a test left queued goes out now (the module keeps its queue)
    Mock.reset()
    clockAt = clockAt + 100000
    Mock.gameTimer = clockAt
    kvp, kvpWrites, audits = {}, 0, {}
    Mock.players = {}
    local function gov(src, cid, grade)
        Mock.newPlayer(src, cid).PlayerData.job = { name = 'government', grade = { level = grade }, onduty = true }
    end
    gov(MAYOR, 'MAY1', 4)
    gov(DEPUTY, 'DEP1', 3)
    gov(CLERK, 'CLK1', 1)
    gov(UTIL, 'UTL1', 0)
    Mock.newPlayer(CIV, 'CIV1').PlayerData.job = { name = 'unemployed', grade = { level = 0 } }
end

describe('G1: the official website', function()
    it('only roles with the website permission save it; the editor is offered to them only', function()
        assert_eq(nui(UTIL, 'website:saveState', { state = site() }).error, 'no_permission', 'grade 0')
        assert_eq(nui(CLERK, 'website:saveState', { state = site() }).error, 'no_permission')
        assert_eq(nui(CIV, 'website:saveState', { state = site() }).error, 'no_permission')
        runTimers()
        assert_eq(kvpWrites, 0)
        assert_false(nui(UTIL, 'website:getState').canEdit)
        assert_true(nui(DEPUTY, 'website:getState').canEdit)
        assert_true(nui(MAYOR, 'website:getState').canEdit)
        assert_true(nui(DEPUTY, 'website:saveState', { state = site() }).ok)
        assert_eq(nui(CIV, 'website:getState').state.pages.home.title, 'Welcome', 'everyone sees the saved site')
        assert_eq(audits[#audits].action, 'website_update')
    end)
    it('keeps only what the editor makes, cut to its limits', function()
        local s = site()
        s.evil = { nested = { deeper = true } }
        s.globalNotice = string.rep('n', 1000) .. '\1'
        s.siteChrome.brandTitle = '<b>' .. string.rep('t', 500)
        s.siteChrome.unknownKey = 'x'
        s.pages.admin = { title = 'hidden page' }
        local blocks = {}
        for i = 1, 40 do blocks[i] = { id = 'b' .. i, type = 'script', title = string.rep('x', 300), body = string.rep('y', 5000),
            items = { 'one', { nested = true }, string.rep('z', 400) }, buttonPage = 'javascript:alert(1)', onclick = 'x' } end
        blocks[2].id = '"><img src=x>'
        s.pages.home.blocks = blocks
        assert_true(nui(MAYOR, 'website:saveState', { state = s }).ok)
        local st = nui(CIV, 'website:getState').state
        assert_eq(st.evil, nil)
        assert_eq(#st.globalNotice, 300)
        assert_eq(#st.siteChrome.brandTitle, 200)
        assert_eq(st.siteChrome.unknownKey, nil)
        assert_eq(st.pages.admin, nil, 'only the editor pages')
        local home = st.pages.home
        assert_eq(#home.blocks, 20, 'at most 20 modules a page')
        local b = home.blocks[1]
        assert_eq(b.type, 'content', 'a known module type')
        assert_eq(#b.title, 120)
        assert_eq(#b.body, 2000)
        assert_eq(#b.items, 2, 'text items only')
        assert_eq(#b.items[2], 200)
        assert_eq(b.buttonPage, 'home')
        assert_eq(b.onclick, nil)
        assert_true(home.blocks[2].id:match('^[%w_%-]+$') ~= nil, 'a safe module id')
        assert_eq(home.intro, 'Line one\nLine two', 'newlines kept in the text')
        assert_eq(st.pages.laws.intro, '', 'an emptied field stays empty')
    end)
    it('refuses a site over 64 KB once cut, and anything that is not a table', function()
        local s = site()
        for _, key in ipairs({ 'home', 'announcements', 'laws', 'taxes' }) do
            local blocks = {}
            for i = 1, 20 do blocks[i] = { id = key .. i, type = 'content', title = 't', body = string.rep('w', 2000), items = {} } end
            s.pages[key] = { title = key, blocks = blocks }
        end
        assert_eq(nui(MAYOR, 'website:saveState', { state = s }).error, 'website_too_large')
        Mock.gameTimer = Mock.gameTimer + 1000
        assert_eq(nui(MAYOR, 'website:saveState', { state = 'x' }).error, 'invalid_state')
        runTimers()
        assert_eq(kvpWrites, 0)
    end)
    it('saves while typing go live at once and reach the KVP once per flush window', function()
        for i = 1, 5 do
            local s = site()
            s.pages.home.title = 'Draft ' .. i
            Mock.gameTimer = Mock.gameTimer + 600
            assert_true(nui(DEPUTY, 'website:saveState', { state = s }).ok)
        end
        assert_eq(govX.GetWebsiteState().pages.home.title, 'Draft 5', 'visitors see the latest save')
        assert_eq(kvpWrites, 0)
        assert_eq(#timers, 1, 'one write queued')
        runTimers()
        assert_eq(kvpWrites, 1)
        assert_true(kvp.pf_government_website_state_v1:find('Draft 5', 1, true) ~= nil)
        -- faster than twice a second: refused
        Mock.gameTimer = Mock.gameTimer + 600
        assert_true(nui(DEPUTY, 'website:saveState', { state = site() }).ok)
        assert_eq(nui(DEPUTY, 'website:saveState', { state = site() }).error, 'rate_limited')
    end)
    it('a site stored before the rules is cut when it is read', function()
        package.loaded = package.loaded or {}
        kvp.pf_government_website_state_v1 = json.encode({ globalNotice = string.rep('g', 900), hack = { a = 1 }, pages = { home = { title = 'Old' } } })
        load_resource('[pfscripts]/pf-government/server/callbacks.lua')   -- a restart: nothing read yet
        govX = Mock.exportsByResource['__self']
        local st = govX.GetWebsiteState()
        assert_eq(#st.globalNotice, 300)
        assert_eq(st.hack, nil)
        assert_eq(st.pages.home.title, 'Old')
    end)
    it('the SetWebsiteState export follows the same rules', function()
        assert_true(govX.SetWebsiteState({ globalNotice = 'From a script', other = 1 }))
        assert_eq(govX.GetWebsiteState().other, nil)
        assert_false(govX.SetWebsiteState('x'))
    end)
end)

describe('G3: civilian permissions', function()
    it('the Deputy Mayor may correct civilians and their records, a clerk may not', function()
        assert_true(HasPermission(DEPUTY, 'civilians'))
        assert_true(HasPermission(DEPUTY, 'records'))
        assert_true(HasPermission(DEPUTY, 'website'))
        assert_true(HasPermission(MAYOR, 'records'), 'all')
        assert_false(HasPermission(CLERK, 'civilians'))
        assert_false(HasPermission(CLERK, 'records'))
        assert_false(HasPermission(UTIL, 'website'))
    end)
    it('deleting records and clearing convictions need records; identity and job need civilians', function()
        local savedRoles = Config.Roles[3]
        Config.Roles[3] = { name = 'Deputy Mayor', permissions = { 'civilians' } }   -- civilians without records
        assert_eq(nui(DEPUTY, 'civilian:deleteRecord', { recordType = 'conviction', recordId = 1 }).error, 'no_permission')
        assert_eq(nui(DEPUTY, 'civilian:clearConvictions', { citizenId = 'CIV1' }).error, 'no_permission')
        Config.Roles[3] = { name = 'Deputy Mayor', permissions = { 'records' } }     -- records without civilians
        assert_eq(nui(DEPUTY, 'civilian:updateIdentity', { citizenId = 'CIV1', firstname = 'X' }).error, 'no_permission')
        assert_eq(nui(DEPUTY, 'civilian:updateJob', { citizenId = 'CIV1', jobName = 'police' }).error, 'no_permission')
        assert_eq(nui(DEPUTY, 'civilian:seizeVehicle', { citizenId = 'CIV1', plate = 'ABC' }).error, 'no_permission')
        assert_true(nui(DEPUTY, 'civilian:clearConvictions', { citizenId = 'CIV1' }).error ~= 'no_permission', 'records lets them through')
        Config.Roles[3] = savedRoles
    end)
    it('the terminal is told the role permissions so it can hide what the role may not do', function()
        local info = nui(DEPUTY, 'user:getInfo')
        local has = {}
        for _, p in ipairs(info.user.permissions) do has[p] = true end
        assert_true(has.civilians and has.records and has.website)
    end)
end)
