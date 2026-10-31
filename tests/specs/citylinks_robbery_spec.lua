-- Robberies → city timeline (pf-services): each robbery that really started on the server is one
-- city event (police dispatch + news), at server-side coordinates; a bare client event raises nothing.
load_resource('tests/lua/fivem_mocks.lua')

-- pf-services stand-in: records what the resources send
Emits, Kinds = {}, {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, data = data, opts = opts or {} } return #Emits end,
    RegisterEventKind = function(_, kind, def) Kinds[kind] = def return true end,
}
local started = { ['pf-services'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
local function emitted(kind)
    local out = {}
    for _, e in ipairs(Emits) do if e.kind == kind then out[#out + 1] = e end end
    return out
end

-- items players hold
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
local blackout
Mock.exportsByResource['pfm-weathersync'] = { setBlackout = function(_, on) blackout = on end }
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k, unique = false } end })

-- each resource keeps its own Config; the tests switch to the one they exercise
Config = nil
load_resource('pfm-bankrobbery/sh_config.lua')
load_resource('pfm-bankrobbery/sv_config.lua')
Config.OnRobberyStart, Config.OnRobberyTimeoutEnd, Config.OnBlackout, Config.OnPoliceCameraHit = function() end, function() end, function() end, function() end
load_resource('pfm-bankrobbery/server/main.lua')
local BankCfg = Config
Config = nil
load_resource('pfm-storerobbery/config.lua')
load_resource('pfm-storerobbery/server/main.lua')
local StoreCfg = Config
Config = nil
load_resource('pfm-houserobbery/config.lua')
load_resource('pfm-houserobbery/server/main.lua')
local HouseCfg = Config
Config = nil
load_resource('pfm-jewelery/config.lua')
load_resource('pfm-jewelery/server/main.lua')
local JewelCfg = Config

local R, COP1, COP2, OWNER = 1, 2, 3, 4
local weapon = {}
function GetSelectedPedWeapon(ped) return weapon[ped] or 0 end
local function at(src, c) Mock.coords[src] = vector3(c.x, c.y, c.z) end
local function same(a, b) return math.abs(a.x - b.x) < 0.01 and math.abs(a.y - b.y) < 0.01 end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.gameTimer = Mock.gameTimer + 60000
    Mock.players, Mock.coords, Mock.dropped, Inv, Emits, Kinds, weapon = {}, {}, {}, {}, {}, {}, {}
    started = { ['pf-services'] = true }
    local r = Mock.newPlayer(R)
    r.PlayerData.job = { name = 'unemployed', type = 'none', onduty = false }
    r.GetItemByName = function(item) if count(R, item) > 0 then return { name = item, amount = count(R, item) } end end
    r.Functions.GetItemByName = r.GetItemByName
    for _, c in ipairs({ COP1, COP2 }) do Mock.newPlayer(c).PlayerData.job = { name = 'police', type = 'leo', onduty = true } end
    math.randomseed(3)
end

describe('bank robbery', function()
    it('the opened vault is one event at the bank, with its public name', function()
        Config = BankCfg
        local bank = 2
        at(R, Config.SmallBanks[bank].coords)
        Mock.fireNet('qb-bankrobbery:server:setBankState', R, bank)          -- no hack: nothing
        assert_eq(#Emits, 0)
        give(R, 'electronickit'); give(R, 'trojan_usb')
        Mock.fireNet('qb-bankrobbery:server:removeElectronicKit', R)
        Mock.clock = Mock.clock + 10
        Mock.fireNet('qb-bankrobbery:server:setBankState', R, bank)
        Mock.fireNet('qb-bankrobbery:server:setBankState', R, bank)          -- already open
        local ev = emitted('crime.robbery.bank')
        assert_eq(#ev, 1)
        assert_true(same(ev[1].opts.coords, Config.SmallBanks[bank].coords), 'server coords of the bank')
        assert_eq(ev[1].data.place, 'Fleeca Bank Legion Square')
        assert_eq(ev[1].data.bank, 'Fleeca Bank Legion Square')
        assert_eq(ev[1].opts.dedupe, 'bank:2')
        assert_eq(ev[1].data.ref, 'robbery:bank:2')
        -- the police alert of the resource still goes out
        assert_true(#Mock.clientEventsNamed('qb-bankrobbery:client:robberyCall') >= 1)
    end)
    it('a sabotaged power grid is a city-wide blackout bulletin', function()
        Config = BankCfg
        local old = Config.HitsNeeded
        Config.HitsNeeded = 1
        for _, st in pairs(Config.PowerStations) do st.hit = false end
        give(R, 'thermite')
        at(R, Config.PowerStations[4].coords)
        Mock.fireNet('qb-bankrobbery:server:SetStationStatus', R, 4, true)  -- no thermite used: refused
        assert_eq(#emitted('crime.blackout'), 0)
        assert_true(Mock.callCallback('thermite:server:check', R))
        Mock.fireNet('qb-bankrobbery:server:SetStationStatus', R, 4, true)
        Config.HitsNeeded = old
        assert_true(blackout)
        local ev = emitted('crime.blackout')
        assert_eq(#ev, 1)
        assert_eq(Kinds['crime.blackout'].news, 'auto')
        assert_true(same(ev[1].opts.coords, Config.PowerStations[4].coords))
    end)
end)

describe('store robbery', function()
    it('a picked register is one event per store, at the register, named', function()
        Config = StoreCfg
        give(R, 'lockpick')
        for k, reg in pairs(Config.Registers) do reg.robbed = false; reg.time = 0 end
        at(R, Config.Registers[1][1])
        Mock.fireNet('qb-storerobbery:server:setRegisterStatus', R, 1)
        at(R, Config.Registers[2][1])
        Mock.fireNet('qb-storerobbery:server:setRegisterStatus', R, 2)       -- same store
        local ev = emitted('crime.robbery.store')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.place, 'LTD Gasoline, Grove Street')
        assert_true(same(ev[1].opts.coords, Config.Registers[1][1]))
        assert_eq(ev[1].opts.dedupe, 'store:1')
        at(R, Config.Registers[7][1])
        Mock.fireNet('qb-storerobbery:server:setRegisterStatus', R, 7)       -- another store
        assert_eq(#emitted('crime.robbery.store'), 2)
    end)
    it('no event from a client away from the register, without a lockpick or police', function()
        Config = StoreCfg
        for _, reg in pairs(Config.Registers) do reg.robbed = false end
        at(R, Config.Registers[3][1])
        Mock.fireNet('qb-storerobbery:server:setRegisterStatus', R, 3)       -- no lockpick
        give(R, 'lockpick')
        Mock.coords[R] = vector3(0, 0, 0)
        Mock.fireNet('qb-storerobbery:server:setRegisterStatus', R, 3)       -- far away
        Mock.players[COP2] = nil
        at(R, Config.Registers[3][1])
        Mock.fireNet('qb-storerobbery:server:setRegisterStatus', R, 3)       -- one cop, two needed
        assert_eq(#Emits, 0)
    end)
    it('a robbery while pf-services is not running still works and sends nothing', function()
        Config = StoreCfg
        started = {}
        for _, reg in pairs(Config.Registers) do reg.robbed = false end
        give(R, 'lockpick')
        at(R, Config.Registers[10][1])
        Mock.fireNet('qb-storerobbery:server:setRegisterStatus', R, 10)
        assert_true(Config.Registers[10].robbed)
        assert_eq(#Emits, 0)
    end)
    it('the owner of a player-owned pf-stores shop at that counter is told', function()
        Config = StoreCfg
        for _, reg in pairs(Config.Registers) do reg.robbed = false end
        started['pf-stores'] = true
        Mock.exportsByResource['pf-stores'] = { GetStoreConfig = function() return { Stores = {
            twentyfourseven_2 = { id = 'twentyfourseven_2', label = '24/7 Innocence', npc = { coords = vector4(24.50, -1347.28, 29.50, 268.93) } },
        } } end }
        local realScalar = MySQL.scalar
        MySQL.scalar = { await = function(q, p) if q:find('FROM pf_stores', 1, true) and p[1] == 'twentyfourseven_2' then return 'OWNERCID' end end }
        Mock.newPlayer(OWNER, 'OWNERCID')
        give(R, 'lockpick')
        at(R, Config.Registers[8][1])
        Mock.fireNet('qb-storerobbery:server:setRegisterStatus', R, 8)
        MySQL.scalar = realScalar
        local told = 0
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.target == OWNER then told = told + 1 end end
        assert_eq(told, 1)
        assert_eq(#emitted('crime.robbery.store'), 1)
    end)
end)

describe('house robbery', function()
    local HOUSE = 'miltonroad2'
    it('the server-rolled burglar alarm is one event and one police alert per house', function()
        Config = HouseCfg
        Config.ChanceToAlertPolice = 100
        give(R, 'advancedlockpick')
        at(R, Config.Houses[HOUSE].coords)
        Mock.fireNet('qb-houserobbery:server:startLockpick', R, HOUSE)
        Mock.fireNet('qb-houserobbery:server:startLockpick', R, HOUSE)
        local ev = emitted('crime.robbery.house')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.place, 'a home on Milton Road')
        assert_true(same(ev[1].opts.coords, Config.Houses[HOUSE].coords))
        local alerts = Mock.clientEventsNamed('police:client:policeAlert')
        assert_eq(#alerts, 2)                                                  -- each on-duty officer once
    end)
    it('no alarm without the tools, away from the door, or when the roll says no', function()
        Config = HouseCfg
        Config.ChanceToAlertPolice = 100
        at(R, Config.Houses['grove1'].coords)
        Mock.fireNet('qb-houserobbery:server:startLockpick', R, 'grove1')     -- no tools
        give(R, 'advancedlockpick')
        Mock.coords[R] = vector3(0, 0, 0)
        Mock.fireNet('qb-houserobbery:server:startLockpick', R, 'grove1')     -- not at the door
        Config.ChanceToAlertPolice = 0
        at(R, Config.Houses['grove1'].coords)
        Mock.fireNet('qb-houserobbery:server:startLockpick', R, 'grove1')
        assert_eq(#Emits, 0)
        assert_eq(#Mock.clientEventsNamed('police:client:policeAlert'), 0)
        Config.ChanceToAlertPolice = 20
    end)
end)

describe('jewelry heist', function()
    it('the first case really emptied is the one event; more cases add none', function()
        Config = JewelCfg
        Config.RequiredCops = 1
        weapon[R] = joaat('weapon_pistol')
        Mock.fireNet('qb-jewellery:server:vitrineReward', R, 1)               -- bare claim
        assert_eq(#Emits, 0)
        for _, k in ipairs({ 1, 2 }) do
            at(R, Config.Locations[k].coords)
            Mock.fireNet('qb-jewellery:server:setVitrineState', R, 'isBusy', true, k)
            Mock.clock = Mock.clock + 15
            Mock.gameTimer = Mock.gameTimer + 5000
            Mock.fireNet('qb-jewellery:server:vitrineReward', R, k)
        end
        assert_true(Config.Locations[2].isOpened)
        local ev = emitted('crime.robbery.jewelry')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.place, 'Vangelico, Rockford Hills')
        assert_true(same(ev[1].opts.coords, Config.JewelleryLocation.coords))
    end)
end)
