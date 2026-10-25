-- pf-jobs garbage (server/apps/garbage.lua): bags come only from requestBag next to the bag, go only
-- into the player's own truck, the run pays at the depot, XP is not client-settable, and a crew
-- needs an invite.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock

local trucks = {}
function CreateVehicle() Mock.nextNetId = Mock.nextNetId + 1; trucks[#trucks + 1] = Mock.nextNetId; return Mock.nextNetId end
function SetEntityHeading() end
function SetVehicleNumberPlateText() end

LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/garbage.lua' })
Config.Garbage.UseDatabase = false

local W, OTHER = 1, 2
local G = Config.Garbage
local depot = vector3(G.ReturnLocation.x, G.ReturnLocation.y, G.ReturnLocation.z)
-- a dumpster inside the first zone, keyed the way the client keys it
local zone
local function dumpsterKey(i) return ('%d:%.1f:%.1f:%.1f'):format(666561306, zone.x + i * 4, zone.y, zone.z) end
local function at(src, key)
    local x, y, z = key:match(':([%d%.%-]+):([%d%.%-]+):([%d%.%-]+)$')
    Mock.coords[src] = vector3(tonumber(x), tonumber(y), tonumber(z))
end
local function truck() return trucks[#trucks] end
local function atTruck(src) Mock.coords[truck()] = vector3(500, 500, 30); Mock.coords[src] = vector3(503, 500, 30) end
local function granted() return #Mock.clientEventsNamed('pf-jobs:garbage:grantBag') end
local function paid() return LedgerEnv.paid('pf-jobs:garbage:') end

local function start()
    Mock.fireNet('pf-jobs:garbage:startJob', W)
    local zones = Mock.clientEventsNamed('pf-jobs:garbage:setActiveZone')
    zone = zones[#zones].args[1].center
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, trucks = {}, {}, {}
    Mock.newPlayer(W).PlayerData.job = { name = 'garbage', onduty = true }
    Mock.newPlayer(OTHER)
    Mock.fireEvent('playerDropped', W)
    Mock.fireEvent('playerDropped', OTHER)
end

describe('pf-jobs garbage', function()
    it('claiming to carry a bag and throwing it in pays nothing (it used to pay per throw)', function()
        start()
        atTruck(W)
        for _ = 1, 10 do
            Mock.fireNet('pf-jobs:garbage:setCarrying', W, true)
            Mock.fireNet('pf-jobs:garbage:depositBag', W)
        end
        Mock.coords[W] = depot
        Mock.fireNet('pf-jobs:garbage:returnTruck', W)
        assert_eq(#paid(), 0)
    end)

    it('clients cannot set their XP', function()
        assert_eq(Mock.netHandlers['pf-jobs:garbage:updateXP'], nil)
    end)

    it('a bag must be next to the player, and a loose bag is taken once', function()
        start()
        local key = dumpsterKey(1)
        Mock.coords[W] = vector3(0, 0, 0)
        Mock.fireNet('pf-jobs:garbage:requestBag', W, key, true)
        assert_eq(granted(), 0)
        at(W, key)
        Mock.fireNet('pf-jobs:garbage:requestBag', W, key, true)
        assert_eq(granted(), 1)
        Mock.fireNet('pf-jobs:garbage:setCarrying', W, false)
        Mock.fireNet('pf-jobs:garbage:requestBag', W, key, true)
        assert_eq(granted(), 1)
    end)

    it('bags go only into the truck when standing at it, and the run pays at the depot', function()
        start()
        for i = 1, 3 do
            local key = dumpsterKey(i)
            at(W, key)
            Mock.fireNet('pf-jobs:garbage:requestBag', W, key, false)
            Mock.fireNet('pf-jobs:garbage:depositBag', W)       -- away from the truck: refused
            atTruck(W)
            Mock.fireNet('pf-jobs:garbage:depositBag', W)
        end
        Mock.coords[W] = vector3(0, 0, 0)
        Mock.fireNet('pf-jobs:garbage:returnTruck', W)          -- away from the depot
        assert_eq(#paid(), 0)
        Mock.coords[W] = depot
        Mock.fireNet('pf-jobs:garbage:returnTruck', W)
        local rows = paid()
        assert_eq(#rows, 1)
        assert_eq(rows[1].amount, 3 * G.PayoutPerBag[1])
    end)

    it('one run and one truck at a time', function()
        start()
        Mock.fireNet('pf-jobs:garbage:startJob', W)
        assert_eq(#trucks, 1)
    end)

    it('joining a crew needs an invite from its leader', function()
        Mock.fireNet('pf-jobs:garbage:createGroup', W)
        Mock.fireNet('pf-jobs:garbage:acceptInvite', OTHER, W)
        assert_eq(Mock.callCallback('pf-jobs:garbage:getGroupState', OTHER), nil)
        Mock.fireNet('pf-jobs:garbage:invitePlayer', W, OTHER)
        Mock.fireNet('pf-jobs:garbage:acceptInvite', OTHER, W)
        assert_eq(Mock.callCallback('pf-jobs:garbage:getGroupState', OTHER).leader, W)
    end)
end)
