-- Batch 14, pf-computer (mocked): no citizen ids in what the browser gets about domains, the
-- government website is bounded before every visitor gets it, and City Hall fines from the computer
-- go through pf-government's own rules (IssueFineAs: the official's server id, no client due date).
load_resource('tests/lua/fivem_mocks.lua')

local started = { ['pfm-core'] = true, ['pfm-banking'] = true, ['pf-government'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-computer' end
function LoadResourceFile() return nil end
function SaveResourceFile() return true end
function RegisterCommand() end
QBCoreMock.Shared.Jobs = {
    unemployed = { label = 'Civilian', grades = { ['0'] = { name = 'Freelancer', payment = 10 } } },
    government = { label = 'Government', grades = { ['1'] = { name = 'Clerk', payment = 10 } } },
}

local govSite, fines = {}, {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm) return src == 9 and (perm == 'fines' or perm == 'audit') end,
    GetWebsiteState = function() return govSite end,
    IssueFineAs = function(_, src, data)
        fines[#fines + 1] = { src = src, data = data }
        return true, { billId = 7, status = 'unpaid' }
    end,
}
Mock.exportsByResource['pfm-banking'] = { Transfer = function() return { ok = true } end, GetTransaction = function() return nil end }

Config = nil
load_resource('[pfscripts]/pf-computer/config/config.lua')
load_resource('[pfscripts]/pf-computer/server/main.lua')

local BUYER, OFFICIAL = 1, 9
local function call(src, action, payload)
    Mock.clientEvents = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.fireNet('pf-computer:server:callback', src, 7, action, payload or {})
    local ev = Mock.clientEventsNamed('pf-computer:client:callback')[1]
    return ev and ev.args[2]
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    govSite, fines = {}, {}
    local b = Mock.newPlayer(BUYER, 'BUY1')
    b.PlayerData.job = { name = 'unemployed', label = 'Civilian', grade = { level = 0, name = 'Freelancer' } }
    local o = Mock.newPlayer(OFFICIAL, 'GOV1')
    o.PlayerData.job = { name = 'government', label = 'Government', grade = { level = 1, name = 'Clerk' } }
end

describe('domains', function()
    it('the browser config lists your own domains without the citizen id', function()
        assert_true(call(BUYER, 'browser:domain:buy', { domain = 'mine.ls' }).ok)
        local cfg = call(BUYER, 'browser:config:get').data
        assert_eq(#cfg.ownedDomains, 1)
        local d = cfg.ownedDomains[1]
        assert_eq(d.domain, 'mine.ls')
        assert_eq(d.ownerIdentifier, nil, 'no citizen id')
        assert_eq(d.price, nil)
        assert_true(d.isOwner)
        for _, e in ipairs(call(OFFICIAL, 'browser:domains:list').data) do assert_eq(e.ownerIdentifier, nil) end
    end)
end)

describe('the government website', function()
    it('is passed on when it is within 64 KB, and an empty site when it is not', function()
        govSite = { globalNotice = 'Hello', pages = { home = { title = 'Welcome' } } }
        assert_eq(call(BUYER, 'gov:website:get').data.globalNotice, 'Hello')
        assert_eq(call(BUYER, 'browser:website:get', { domain = 'los-santos.gov' }).data.state.globalNotice, 'Hello')
        govSite = { pages = { home = { intro = string.rep('x', 70000) } } }
        local got = call(BUYER, 'gov:website:get').data
        assert_eq(next(got), nil, 'too large: nothing sent to visitors')
        assert_eq(next(call(BUYER, 'browser:website:get', { domain = 'los-santos.gov' }).data.state), nil, 'in the browser either')
    end)
end)

describe('City Hall fines from the computer', function()
    it('go through IssueFineAs with the official, never a client due date', function()
        local res = call(OFFICIAL, 'gov:fines:issue', { targetCitizenId = 'CIT1', amount = 250, description = 'Parking', dueDate = '2000-01-01 00:00:00' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(#fines, 1)
        assert_eq(fines[1].src, OFFICIAL)
        assert_eq(fines[1].data.targetCitizenId, 'CIT1')
        assert_eq(fines[1].data.amount, 250)
        assert_eq(fines[1].data.dueDate, nil, 'the due date is the government\'s')
        assert_eq(call(OFFICIAL, 'gov:fines:issue', { targetCitizenId = 'CIT1', amount = 2.5 }).error, 'invalid_amount')
        assert_eq(call(BUYER, 'gov:fines:issue', { targetCitizenId = 'CIT1', amount = 250 }).error, 'not_authorized')
        assert_eq(#fines, 1)
    end)
end)
