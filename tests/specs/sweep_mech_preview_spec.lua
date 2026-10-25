-- pf-mechanicjob preview (server/preview.lua, server/preview_receipt.lua): preview changes reach only a
-- car the sender is at; receipts are rate-limited with bounded text.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Items.preview_receipt = { name = 'preview_receipt', label = 'Receipt' }

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/server/preview.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/preview_receipt.lua')

local SRC, NEAR_CAR, FAR_CAR = 1, 500, 501
local given

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    given = {}
    local p = Mock.newPlayer(SRC)
    p.Functions.AddItem = function(name, n, slot, info) given[#given + 1] = info; return true end
    Mock.coords[SRC], Mock.coords[NEAR_CAR] = vector3(0.0, 0.0, 0.0), vector3(3.0, 0.0, 0.0)
    Mock.coords[FAR_CAR] = vector3(800.0, 0.0, 0.0)
    Mock.clock = Mock.clock + 1000
end

describe('preview', function()
    it("can't restyle a car the sender isn't at", function()
        Mock.fireNet('pf_mech:preview:syncMod', SRC, FAR_CAR, 11, 3)
        Mock.fireNet('pf_mech:preview:syncPaint', SRC, FAR_CAR, 'primary', 12)
        Mock.fireNet('pf_mech:preview:restore', SRC, FAR_CAR, { mods = {} })
        assert_eq(#Mock.clientEvents, 0)
        Mock.fireNet('pf_mech:preview:syncMod', SRC, NEAR_CAR, 11, 3)
        assert_eq(#Mock.clientEventsNamed('pf_mech:preview:applyModClient'), 1)
    end)
    it('receipts: one every few seconds, text bounded', function()
        local changes = {}
        for i = 1, 500 do changes[i] = { name = string.rep('n', 1000), from = 'a', to = 'b' } end
        Mock.fireNet('pf_mech:givePreviewReceipt', SRC, { vehicle = string.rep('v', 5000), plate = 'ABC', changes = changes, changeCount = 1e9 })
        Mock.fireNet('pf_mech:givePreviewReceipt', SRC, { vehicle = 'x' })
        assert_eq(#given, 1)
        assert_true(#given[1].description < 12000)
        assert_eq(given[1].changes, 999)
        Mock.clock = Mock.clock + 60
        Mock.fireNet('pf_mech:givePreviewReceipt', SRC, { vehicle = 'x' })
        assert_eq(#given, 2)
    end)
end)
