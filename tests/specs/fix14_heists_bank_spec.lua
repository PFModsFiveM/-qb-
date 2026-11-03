-- pfm-bankrobbery (batch 14): thermite fires are server-owned sessions, the bank doors are opened
-- and locked by the server through pfm-doorlock's server path, and the hack / thermite results are
-- pfm-minigames challenges the server judges.
load_resource('tests/lua/fivem_mocks.lua')

Inv = {}
local function count(src, item) return (Inv[src] and Inv[src][item]) or 0 end
local function give(src, item, n) Inv[src] = Inv[src] or {}; Inv[src][item] = count(src, item) + (n or 1) end
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, item, n) give(src, item, n or 1); return true end,
    RemoveItem = function(_, src, item, n)
        n = n or 1
        if count(src, item) < n then return false end
        Inv[src][item] = count(src, item) - n
        return true
    end,
    GetItemByName = function(_, src, item) if count(src, item) > 0 then return { name = item, amount = count(src, item) } end end,
}
Mock.exportsByResource['pfm-weathersync'] = { setBlackout = function() end }

-- pfm-minigames: the spec decides each challenge's verdict (Pass) before the resource verifies it
Challenges, Issued = {}, {}
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function(_, src, kind, opts)
        local id = 'ch' .. (#Issued + 1)
        Challenges[id] = { src = src, kind = kind, opts = opts }
        Issued[#Issued + 1] = id
        return { id = id, kind = kind, puzzle = {}, expiresIn = 30000 }
    end,
    Verify = function(_, src, id)
        local c = Challenges[id]
        Challenges[id] = nil
        if not c then return false, 0, 'unknown' end
        if c.src ~= src then return false, 0, 'wrong_player' end
        return c.passed == true, 0, c.passed and nil or 'pending'
    end,
    Cancel = function(_, _, id) Challenges[id] = nil return true end,
}
local function Pass(id) Challenges[id].passed = true end

-- timers run when the spec says so
Timers = {}
function SetTimeout(ms, fn) Timers[#Timers + 1] = { ms = ms, fn = fn } end
local function runTimers()
    for _ = 1, 20 do
        if #Timers == 0 then return end
        local list = Timers
        Timers = {}
        for _, t in ipairs(list) do t.fn() end
    end
end
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k, unique = false } end })

load_resource('pfm-bankrobbery/sh_config.lua')
load_resource('pfm-bankrobbery/sv_config.lua')
Config.OnRobberyStart, Config.OnRobberyTimeoutEnd, Config.OnBlackout, Config.OnPoliceCameraHit = function() end, function() end, function() end, function() end
load_resource('pfm-bankrobbery/server/main.lua')
function CreateThread(fn) fn() end -- the reset timers are scheduled inside threads

local ROBBER, OTHER = 1, 2
local function at(src, c) Mock.coords[src] = vector3(c.x, c.y, c.z) end
local function doorChanges()
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do
        if e.name == 'qb-doorlock:server:updateState' then
            out[#out + 1] = { id = e.args[1], locked = e.args[2], unlockAnyway = e.args[5], player = e.args[8] }
        end
    end
    return out
end
local function fires(name) return Mock.clientEventsNamed(name) end

BeforeEach = function()
    runTimers() -- ends a robbery an earlier test started (bank resets)
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players, Mock.coords, Inv, Challenges, Issued = {}, {}, {}, {}, {}
    for _, src in ipairs({ ROBBER, OTHER }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.job = { name = 'unemployed', type = 'none', onduty = false }
    end
    for _, st in pairs(Config.PowerStations) do st.hit = false end
    math.randomseed(3)
end

describe('thermite fires', function()
    it('no client can start or put out fires any more', function()
        assert_eq(Mock.netHandlers['thermite:StartServerFire'], nil)
        assert_eq(Mock.netHandlers['thermite:StopFires'], nil)
    end)

    it('a charge that went off lights fires for its own session at the server position, and the server stops exactly those', function()
        local key = 5
        local station = Config.PowerStations[key].coords
        give(OTHER, 'thermite')
        at(OTHER, station)
        local ch = Mock.callCallback('thermite:server:check', OTHER)
        assert_eq(type(ch), 'table')
        assert_eq(count(OTHER, 'thermite'), 0)
        Pass(ch.id)
        Mock.coords[OTHER] = vector3(station.x + 0.5, station.y, station.z)
        Mock.fireNet('qb-bankrobbery:server:thermiteFinish', OTHER)
        runTimers()
        local starts, stops = fires('thermite:StartFire'), fires('thermite:StopFires')
        assert_eq(#starts, 1)
        assert_eq(#stops, 1)
        assert_eq(starts[1].args[1], stops[1].args[1])            -- same session id
        assert_near(starts[1].args[2].x, station.x + 0.5, 0.001)  -- where the server saw the player
        assert_true(starts[1].args[5] >= 1 and starts[1].args[5] <= 7)
        assert_true(Config.PowerStations[key].hit)
    end)

    it('a failed charge flares up but blows nothing, and a finish without a charge lights nothing', function()
        local key = 6
        give(OTHER, 'thermite')
        at(OTHER, Config.PowerStations[key].coords)
        Mock.fireNet('qb-bankrobbery:server:thermiteFinish', OTHER)   -- no charge placed
        runTimers()
        assert_eq(#fires('thermite:StartFire'), 0)
        local ch = Mock.callCallback('thermite:server:check', OTHER)
        assert_eq(type(ch), 'table')
        Mock.fireNet('qb-bankrobbery:server:thermiteFinish', OTHER)   -- never passed
        runTimers()
        assert_eq(#fires('thermite:StartFire'), 1)
        assert_false(Config.PowerStations[key].hit)
        Mock.fireNet('qb-bankrobbery:server:thermiteFinish', OTHER)   -- the charge is gone
        runTimers()
        assert_eq(#fires('thermite:StartFire'), 1)
    end)

    it('thermite placed nowhere useful keeps the charge, and no client blows a station by itself', function()
        give(OTHER, 'thermite')
        Mock.coords[OTHER] = vector3(0, 0, 0)
        assert_false(Mock.callCallback('thermite:server:check', OTHER))
        assert_eq(count(OTHER, 'thermite'), 1)
        assert_eq(Mock.netHandlers['qb-bankrobbery:server:SetStationStatus'], nil)
    end)
end)

describe('bank doors', function()
    it('the Pacific card opens door 1 from the server; a second swipe uses no card', function()
        give(ROBBER, 'security_card_02', 2)
        at(ROBBER, Config.BigBanks.pacific.coords[1])
        Mock.fireNet('qb-bankrobbery:server:removeBankCard', ROBBER, '02')
        local doors = doorChanges()
        assert_eq(#doors, 1)
        assert_eq(doors[1].id, Config.BankDoors.pacificFront)
        assert_false(doors[1].locked)
        assert_true(doors[1].unlockAnyway)
        assert_eq(doors[1].player, ROBBER)
        Mock.fireNet('qb-bankrobbery:server:removeBankCard', ROBBER, '02')
        assert_eq(count(ROBBER, 'security_card_02'), 1)
        -- nobody hacked the vault: the gate locks again after Config.PacificFrontDoorMinutes
        runTimers()
        doors = doorChanges()
        assert_eq(doors[#doors].id, Config.BankDoors.pacificFront)
        assert_true(doors[#doors].locked)
    end)

    it('Paleto: the card opens the bank and its gate (door 4); the reset locks doors 1-5 again', function()
        give(ROBBER, 'security_card_01')
        at(ROBBER, Config.BigBanks.paleto.coords)
        Mock.fireNet('qb-bankrobbery:server:setBankState', ROBBER, 'paleto')
        assert_true(Config.BigBanks.paleto.isOpened)
        local doors = doorChanges()
        assert_eq(#doors, 1)
        assert_eq(doors[1].id, Config.BankDoors.paletoVault)
        assert_false(doors[1].locked)
        runTimers() -- the 90 minute reset
        assert_false(Config.BigBanks.paleto.isOpened)
        local relocked = {}
        for _, d in ipairs(doorChanges()) do if d.locked then relocked[d.id] = true end end
        for id = 1, 5 do assert_true(relocked[id], 'door ' .. id .. ' relocked') end
    end)

    it('a thermite gate opens only after a passed charge, and only once the step before it is done', function()
        local gate1 = Config.BigBanks.pacific.thermite[1]
        local gate2 = Config.BigBanks.pacific.thermite[2]
        give(ROBBER, 'thermite', 3)
        at(ROBBER, gate2.coords)
        assert_false(Mock.callCallback('thermite:server:check', ROBBER))   -- gate 1 is still shut
        at(ROBBER, gate1.coords)
        assert_false(Mock.callCallback('thermite:server:check', ROBBER))   -- the vault is still shut
        Config.BigBanks.pacific.isOpened = true                            -- (the vault was hacked)
        local ch = Mock.callCallback('thermite:server:check', ROBBER)
        assert_eq(type(ch), 'table')
        Pass(ch.id)
        Mock.fireNet('qb-bankrobbery:server:thermiteFinish', ROBBER)
        assert_eq(#doorChanges(), 0)                                       -- not before the fuse burnt
        runTimers()
        local doors = doorChanges()
        assert_eq(doors[1].id, gate1.doorId)
        assert_false(doors[1].locked)
        assert_true(gate1.isOpened)
        assert_eq(#Mock.clientEventsNamed('qb-bankrobbery:client:setThermiteGate'), 1)
        at(ROBBER, gate2.coords)
        assert_eq(type(Mock.callCallback('thermite:server:check', ROBBER)), 'table')
        Config.BigBanks.pacific.isOpened = false
        gate1.isOpened, gate2.isOpened = false, false
    end)
end)

describe('bank hacks', function()
    local fleeca = next(Config.SmallBanks)
    it('the kit is used up, but the vault opens only for a hack the server judged passed', function()
        give(ROBBER, 'electronickit', 2); give(ROBBER, 'trojan_usb', 2)
        at(ROBBER, Config.SmallBanks[fleeca].coords)
        assert_eq(Mock.netHandlers['qb-bankrobbery:server:removeElectronicKit'], nil)
        local ch = Mock.callCallback('qb-bankrobbery:server:startHack', ROBBER)
        assert_eq(ch.kind, 'hacking')
        assert_eq(count(ROBBER, 'electronickit'), 1)
        assert_eq(count(ROBBER, 'trojan_usb'), 1)
        Mock.clock = Mock.clock + 20
        Mock.fireNet('qb-bankrobbery:server:setBankState', ROBBER, fleeca)  -- hack not passed
        assert_false(Config.SmallBanks[fleeca].isOpened)
        ch = Mock.callCallback('qb-bankrobbery:server:startHack', ROBBER)
        Pass(ch.id)
        Mock.clock = Mock.clock + 20
        Mock.fireNet('qb-bankrobbery:server:setBankState', ROBBER, fleeca)
        assert_true(Config.SmallBanks[fleeca].isOpened)
    end)
    it('the Pacific vault panel takes no kit before the front gate was opened', function()
        give(ROBBER, 'electronickit'); give(ROBBER, 'trojan_usb')
        at(ROBBER, Config.BigBanks.pacific.coords[2])
        assert_false(Mock.callCallback('qb-bankrobbery:server:startHack', ROBBER))
        assert_eq(count(ROBBER, 'electronickit'), 1)
    end)
end)
