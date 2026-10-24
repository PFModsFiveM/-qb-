-- pf-tablet reads pf-computer's config without clobbering its own global Config.
load_resource('tests/lua/fivem_mocks.lua')

Config = { TabletOwnSetting = 'keep-me' }
function GetResourcePath() return 'pf-computer' end
function LoadResourceFile(resource, file)
    assert(resource == 'pf-computer' and file == 'config/config.lua')
    return __readfile('[pfscripts]/pf-computer/config/config.lua')
end
QBCoreMock.Functions.GetPlayers = function() return {} end

load_resource('[pfscripts]/pf-tablet/server/apps/business.lua')

describe('pf-tablet business app', function()
    it("keeps pf-tablet's Config intact after reading pf-computer's config", function()
        assert_eq(Config.TabletOwnSetting, 'keep-me')
    end)
end)
