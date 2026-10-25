-- pfm-apartments: entering someone else's apartment, pulling players in, and owner lookups
-- (plus pfm-spawn's owned-houses lookup).
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
local buckets = {}
QBCoreMock.Functions.SetPlayerBucket = function(src, b) buckets[src] = b end

local apartments = {
    apartment112345 = { name = 'apartment112345', type = 'apartment1', label = 'Alta 12345', citizenid = 'OWNERCID' },
}
MySQL.query = setmetatable({ await = function(sql, params)
    if sql:find('WHERE name = ?', 1, true) then return { apartments[params[1]] } end
    if sql:find('apartments WHERE citizenid = ?', 1, true) then
        for _, a in pairs(apartments) do if a.citizenid == params[1] then return { a } end end
        return {}
    end
    if sql:find('player_houses', 1, true) then return { { house = 'h1', citizenid = params[1] } } end
    return {}
end }, { __call = function() return {} end })

Config = nil
load_resource('pfm-apartments/config.lua')
load_resource('pfm-apartments/server/main.lua')
load_resource('pfm-spawn/server.lua')

local OWNER, INTRUDER, GUEST = 1, 2, 3
local APT, TYPE = 'apartment112345', 'apartment1'

local function inside(src)
    -- whether src is listed as inside: RingDoor reaches everyone listed
    Mock.clientEvents = {}
    Mock.fireNet('apartments:server:RingDoor', 99, APT, TYPE)
    for _, e in ipairs(Mock.clientEventsNamed('apartments:client:RingDoor')) do
        if e.target == src then return true end
    end
    return false
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    buckets = {}
    for _, src in ipairs({ OWNER, INTRUDER, GUEST }) do
        local p = Mock.newPlayer(src, ({ 'OWNERCID', 'INTRCID', 'GUESTCID' })[src])
        p.PlayerData.metadata.inside = { apartment = {} }
    end
    Mock.newPlayer(99, 'RINGER')
    -- everybody leaves whatever apartment an earlier test left them in
    for _, src in ipairs({ OWNER, INTRUDER, GUEST }) do Mock.fireNet('apartments:server:RemoveObject', src, APT, TYPE) end
end

describe('entering apartments', function()
    it("an intruder cannot add themselves to someone else's apartment or join its bucket", function()
        Mock.fireNet('apartments:server:AddObject', INTRUDER, APT, TYPE, 210)
        Mock.fireNet('qb-apartments:server:SetInsideMeta', INTRUDER, TYPE, APT, true, true)
        assert_eq(buckets[INTRUDER], nil)
        Mock.fireNet('apartments:server:AddObject', OWNER, APT, TYPE, 210)
        assert_true(inside(OWNER))
        assert_true(not inside(INTRUDER))
    end)
    it('the owner can only let in someone who rang the bell', function()
        Mock.fireNet('apartments:server:AddObject', OWNER, APT, TYPE, 210)
        Mock.clientEvents = {}
        Mock.fireNet('apartments:server:OpenDoor', OWNER, INTRUDER, APT, TYPE)   -- did not ring
        assert_eq(#Mock.clientEventsNamed('apartments:client:SpawnInApartment'), 0)
        Mock.fireNet('apartments:server:RingDoor', GUEST, APT, TYPE)
        Mock.fireNet('apartments:server:OpenDoor', OWNER, GUEST, APT, TYPE)
        assert_eq(#Mock.clientEventsNamed('apartments:client:SpawnInApartment'), 1)
        -- the invited guest gets in
        Mock.fireNet('apartments:server:AddObject', GUEST, APT, TYPE, 210)
        Mock.fireNet('qb-apartments:server:SetInsideMeta', GUEST, TYPE, APT, true, true)
        assert_true(buckets[GUEST] ~= nil)
        assert_true(inside(GUEST))
    end)
end)

describe('owner lookups', function()
    it("another character's apartment and houses are not disclosed", function()
        assert_eq(Mock.callCallback('apartments:GetOwnedApartment', INTRUDER, 'OWNERCID'), nil)
        assert_eq(Mock.callCallback('apartments:GetOwnedApartment', OWNER, 'OWNERCID').name, APT)
        assert_eq(#Mock.callCallback('qb-spawn:server:getOwnedHouses', INTRUDER, 'OWNERCID'), 0)
        assert_eq(#Mock.callCallback('qb-spawn:server:getOwnedHouses', OWNER, 'OWNERCID'), 1)
    end)
end)
