-- pfm-policejob spike strips (batch 14: POL-3). The list lives on the server: the server places the
-- prop at the officer's own position, sends every client its list, and takes a strip up only for an
-- on-duty officer beside it. A client cannot send a list (police:server:SyncSpikes is gone), so it
-- cannot empty everyone's strips, break the clients' loops with bad coordinates, or plant another
-- car's network id as a "spike" for the next officer to delete.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
local created = {}
function CreateObjectNoOffset(model, x, y, z, networked) Mock.nextNetId = Mock.nextNetId + 1 created[#created + 1] = { model = model, x = x, y = y, z = z, networked = networked, id = Mock.nextNetId } return Mock.nextNetId end
local headings = {}
function GetEntityHeading(e) return headings[e] or 0.0 end
function SetEntityHeading() end
function FreezeEntityPosition() end
local gone = {}
function DoesEntityExist(e) return not gone[e] end

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/commands.lua')
load_resource('pfm-policejob/server/objects.lua')

local COP, COP2, CIV = 1, 2, 3
local function lastList()
    local e = Mock.clientEventsNamed('police:client:SyncSpikes')
    return e[#e] and e[#e].args[1]
end

BeforeEach = function()
    for _, src in ipairs({ COP, COP2, CIV }) do if Mock.players[src] then Mock.fireEvent('playerDropped', src) end end
    Mock.reset()
    Mock.players, Mock.coords, Mock.deleted, created, gone = {}, {}, {}, {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.clock = Mock.clock + 3600
    for _, src in ipairs({ COP, COP2 }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    end
    Mock.newPlayer(CIV)
    Mock.coords[COP] = vector3(100, 100, 30)
    Mock.coords[COP2] = vector3(500, 500, 30)
    Mock.coords[CIV] = vector3(100, 101, 30)
end

describe('spike strips', function()
    it('no client can send a spike list any more', function()
        assert_eq(Mock.netHandlers['police:server:SyncSpikes'], nil)
    end)
    it('are placed by the server two metres in front of the officer and sent to everyone', function()
        headings[COP] = 0.0                                      -- facing north
        Mock.fireNet('police:server:PlaceSpike', COP, { x = 9999 }) -- arguments are ignored
        assert_eq(#created, 1)
        assert_near(created[1].x, 100, 0.01)
        assert_near(created[1].y, 102, 0.01)
        assert_eq(created[1].networked, true)
        local list = lastList()
        assert_eq(#list, 1)
        assert_eq(Mock.clientEventsNamed('police:client:SyncSpikes')[1].target, -1)
        assert_near(list[1].coords.y, 102, 0.01)
        assert_eq(list[1].netid, created[1].id)
    end)
    it('only on-duty officers place them, within the per-officer cap', function()
        Mock.fireNet('police:server:PlaceSpike', CIV)
        assert_eq(#created, 0)
        for _ = 1, Config.MaxSpikes + 3 do
            Mock.gameTimer = Mock.gameTimer + 2000
            Mock.fireNet('police:server:PlaceSpike', COP)
        end
        assert_eq(#created, Config.MaxSpikes)
        Mock.gameTimer = Mock.gameTimer + 2000
        Mock.fireNet('police:server:PlaceSpike', COP2)           -- another officer has a cap of their own
        assert_eq(#created, Config.MaxSpikes + 1)
    end)
    it('are taken up by an on-duty officer beside one; the server deletes the prop', function()
        Mock.fireNet('police:server:PlaceSpike', COP)
        local id = lastList()[1].id
        Mock.fireNet('police:server:RemoveSpike', COP2, id)      -- far away
        Mock.fireNet('police:server:RemoveSpike', CIV, id)       -- not police
        assert_eq(#lastList(), 1)
        assert_eq(#Mock.deleted, 0)
        Mock.fireNet('police:server:RemoveSpike', COP, id)
        assert_eq(#lastList(), 0)
        assert_eq(Mock.deleted[1], created[1].id)
    end)
    it('a forged id deletes nothing (another car\'s network id is not a spike)', function()
        Mock.fireNet('police:server:PlaceSpike', COP)
        Mock.fireNet('police:server:RemoveSpike', COP, 4242)
        Mock.fireNet('police:server:RemoveSpike', COP, { 'x' })
        assert_eq(#Mock.deleted, 0)
    end)
    it('go when the officer goes off duty or leaves, and after their lifetime', function()
        Mock.fireNet('police:server:PlaceSpike', COP)
        Mock.fireNet('police:server:PlaceSpike', COP2)
        Mock.eventHandlers['QBCore:Server:SetDuty'](COP, false)
        assert_eq(#lastList(), 1)
        Mock.clock = Mock.clock + Config.SpikeLifetime
        PoliceSpikeSweep()
        assert_eq(#lastList(), 0)
        assert_eq(#Mock.deleted, 2)
    end)
    it('/spikestrip places through the server too', function()
        Commands.spikestrip(COP)
        assert_eq(#created, 1)
    end)
end)
