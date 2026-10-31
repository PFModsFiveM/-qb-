-- pf-jobs vineyard (server/apps/vineyard.lua, moved from pfm-vineyard): the vineyard job only; one
-- vine at a time, the one the server chose, never twice in a row, at least the picking time each;
-- juice and wine only after their processing time and only at the press and the winery, from
-- grapes and juice in any slot; a barrel is emptied once; sales pay cash once; the Vineyard app is
-- for the job and shows the shift, the press, the barrel and where to sell.
load_resource('tests/lua/ledger_env.lua')
LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/server/apps/vineyard.lua' })

local V = PFVineyard
local cfg = V.Config
local W, CITIZEN = 1, 2

local bankUp = true
function GetResourceState(name)
    if name == 'pfm-banking' and not bankUp then return 'stopped' end
    if name == 'pf-restaurants' then return 'started' end
    return 'started'
end

-- inventory with one slot per AddItem (perishable batches do not stack)
local Inv, nextSlot, pocketsFull = {}, 0, false
local function bag(src) Inv[src] = Inv[src] or {} return Inv[src] end
local function count(src, item) local n = 0 for _, it in pairs(bag(src)) do if it.name == item then n = n + it.amount end end return n end
local function give(src, item, n) nextSlot = nextSlot + 1 bag(src)[nextSlot] = { slot = nextSlot, name = item, amount = n } end
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, item, n) if pocketsFull then return false end give(src, item, n) return true end,
    RemoveItem = function(_, src, item, n, slot)
        for key, it in pairs(bag(src)) do
            if it.name == item and (not slot or it.slot == slot) then
                if it.amount < n then return false end
                it.amount = it.amount - n
                if it.amount == 0 then bag(src)[key] = nil end
                return true
            end
        end
        return false
    end,
    GetItemCount = function(_, src, item) return count(src, item) end,
    GetItemsByName = function(_, src, item)
        local out = {}
        for _, it in pairs(bag(src)) do if it.name == item then out[#out + 1] = it end end
        table.sort(out, function(a, b) return a.slot < b.slot end)
        return out
    end,
    GetFreshness = function() return nil end,
}
Mock.exportsByResource['pf-restaurants'] = { GetSupplyUnitPrice = function(_, item) return ({ wine = 18, grapejuice = 10 })[item] end }

-- the database (its SQL runs for real in pfjobs_sidejobs_realdb_spec)
local DBS
V.DB = {
    loadStats = function(cid) return DBS[cid] end,
    addStats = function(cid, d)
        local r = DBS[cid] or {}
        for k, v in pairs(d) do r[k] = (r[k] or 0) + v end
        DBS[cid] = r
    end,
    fillBarrel = function(cid, readyAt)
        DBS[cid] = DBS[cid] or {}
        if DBS[cid].barrel_ready_at then return 0 end
        DBS[cid].barrel_ready_at = readyAt
        return 1
    end,
    emptyBarrel = function(cid, readyAt)
        if not DBS[cid] or DBS[cid].barrel_ready_at ~= readyAt then return 0 end
        DBS[cid].barrel_ready_at = nil
        return 1
    end,
    deleteCharacter = function(cid) DBS[cid] = nil end,
}

local app, pushes = {}, {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) app.def = def return true end,
    RegisterAppHandlers = function(_, id, map) app.h = map return true end,
    Push = function(_, src, id, event, payload) pushes[#pushes + 1] = { src = src, id = id, event = event } return true end,
}

local function at(src, p) Mock.coords[src] = vector3(p.x, p.y, p.z) end
local function shift() return V.__shift(W) end
local function wait(seconds) Mock.clock = Mock.clock + seconds Mock.gameTimer = Mock.gameTimer + seconds * 1000 end
local function start() at(W, cfg.Start.coords) Mock.fireNet('pf-jobs:vineyard:startShift', W) assert_true(shift() ~= nil, 'shift started') end
local function pickTarget()
    at(W, cfg.Vines[shift().target])
    wait(cfg.PickSeconds[1] + 1)
    Mock.fireNet('pf-jobs:vineyard:pick', W)
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    bankUp, pocketsFull = true, false
    DBS = {}
    V.__reset()
    V.dbReady = true
    Inv, pushes = {}, {}
    Mock.players, Mock.coords = {}, {}
    Mock.newPlayer(W).PlayerData.job = { name = 'vineyard', onduty = true, grade = { level = 0 } }
    Mock.newPlayer(CITIZEN)
    wait(100)
    math.randomseed(11)
end

describe('picking', function()
    it('needs the vineyard job and the office', function()
        at(CITIZEN, cfg.Start.coords)
        Mock.fireNet('pf-jobs:vineyard:startShift', CITIZEN)
        assert_eq(V.__shift(CITIZEN), nil, 'not a vineyard worker')
        Mock.coords[W] = vector3(0.0, 0.0, 0.0)
        Mock.fireNet('pf-jobs:vineyard:startShift', W)
        assert_eq(shift(), nil, 'away from the office')
        start()
        assert_true(shift().target ~= nil)
        assert_true(shift().goal >= cfg.VinesPerShift[1] and shift().goal <= cfg.VinesPerShift[2])
    end)
    it('only the vine the server chose, once, after the picking time; then a different vine', function()
        start()
        local target = shift().target
        local other = target == 1 and 2 or 1
        at(W, cfg.Vines[other])
        wait(10)
        Mock.fireNet('pf-jobs:vineyard:pick', W)
        assert_eq(count(W, 'grape'), 0, 'another vine nearby')
        at(W, cfg.Vines[target])
        Mock.fireNet('pf-jobs:vineyard:pick', W)
        local first = count(W, 'grape')
        assert_true(first >= cfg.GrapesPerVine[1], 'picked')
        assert_eq(shift().picked, 1)
        assert_true(shift().target ~= target, 'never the same vine twice in a row')
        Mock.fireNet('pf-jobs:vineyard:pick', W)
        assert_eq(count(W, 'grape'), first, 'the old vine pays nothing')
        at(W, cfg.Vines[shift().target])
        Mock.gameTimer = Mock.gameTimer + 1000
        Mock.fireNet('pf-jobs:vineyard:pick', W)
        assert_eq(count(W, 'grape'), first, 'faster than the picking bar')
        wait(cfg.PickSeconds[1])
        Mock.fireNet('pf-jobs:vineyard:pick', W)
        assert_true(count(W, 'grape') > first)
    end)
    it('a job change stops the picking', function()
        start()
        Mock.players[W].PlayerData.job = { name = 'unemployed' }
        pickTarget()
        assert_eq(count(W, 'grape'), 0)
    end)
    it('the shift ends after its vines and is counted', function()
        start()
        local goal = shift().goal
        for _ = 1, goal do pickTarget() end
        assert_eq(shift(), nil)
        assert_eq(DBS.CID1.vines, goal)
        assert_eq(DBS.CID1.shifts, 1)
        assert_eq(DBS.CID1.xp, goal * cfg.XP.vine)
    end)
    it('full pockets keep the vine: nothing is lost and nothing is counted', function()
        start()
        local target = shift().target
        pocketsFull = true
        pickTarget()
        assert_eq(shift().picked, 0)
        assert_eq(shift().target, target)
        pocketsFull = false
        Mock.fireNet('pf-jobs:vineyard:pick', W)
        assert_eq(shift().picked, 1)
    end)
end)

describe('juice and wine', function()
    it('juice needs 16 grapes (from any slot), the press and the pressing time; once', function()
        give(W, 'grape', 9)
        give(W, 'grape', 9)
        at(W, cfg.Winery.coords)
        assert_false(Mock.callCallback('pf-jobs:vineyard:startJuice', W), 'not at the press')
        at(W, cfg.Press.coords)
        assert_true(Mock.callCallback('pf-jobs:vineyard:startJuice', W))
        assert_eq(count(W, 'grape'), 2, 'sixteen grapes taken from two batches')
        assert_false(Mock.callCallback('pf-jobs:vineyard:startJuice', W), 'one batch at a time')
        Mock.fireNet('pf-jobs:vineyard:collectJuice', W)
        assert_eq(count(W, 'grapejuice'), 0, 'not pressed yet')
        wait(cfg.JuiceMinSeconds)
        at(W, cfg.Start.coords)
        Mock.fireNet('pf-jobs:vineyard:collectJuice', W)
        assert_eq(count(W, 'grapejuice'), 0, 'walked away from the press')
        at(W, cfg.Press.coords)
        Mock.fireNet('pf-jobs:vineyard:collectJuice', W)
        local juice = count(W, 'grapejuice')
        assert_true(juice >= cfg.JuicePerBatch[1] and juice <= cfg.JuicePerBatch[2])
        Mock.fireNet('pf-jobs:vineyard:collectJuice', W)
        assert_eq(count(W, 'grapejuice'), juice, 'once')
    end)
    it('a citizen without the job cannot press', function()
        give(CITIZEN, 'grape', 20)
        at(CITIZEN, cfg.Press.coords)
        assert_false(Mock.callCallback('pf-jobs:vineyard:startJuice', CITIZEN))
        assert_eq(count(CITIZEN, 'grape'), 20)
    end)
    it('wine comes out only after the wine time, at the winery, once; the barrel survives a relog', function()
        give(W, 'grapejuice', 10)
        give(W, 'grapejuice', 10)
        at(W, cfg.Winery.coords)
        assert_false(Mock.callCallback('pf-jobs:vineyard:loadWine', W), 'needs 23 juice')
        assert_eq(count(W, 'grapejuice'), 20, 'nothing taken')
        give(W, 'grapejuice', 5)
        assert_true(Mock.callCallback('pf-jobs:vineyard:loadWine', W))
        assert_eq(count(W, 'grapejuice'), 2)
        assert_false(Mock.callCallback('pf-jobs:vineyard:loadWine', W), 'one barrel at a time')
        Mock.fireNet('pf-jobs:vineyard:collectWine', W)
        assert_eq(count(W, 'wine'), 0, 'still fermenting')
        -- relog: the server forgets the player, the barrel stays in the database
        Mock.fireEvent('playerDropped', W)
        V.__reset()
        wait(cfg.WineSeconds)
        at(W, cfg.Press.coords)
        Mock.fireNet('pf-jobs:vineyard:collectWine', W)
        assert_eq(count(W, 'wine'), 0, 'not at the winery')
        at(W, cfg.Winery.coords)
        Mock.fireNet('pf-jobs:vineyard:collectWine', W)
        local wine = count(W, 'wine')
        assert_true(wine >= cfg.WinePerBarrel[1])
        Mock.fireNet('pf-jobs:vineyard:collectWine', W)
        assert_eq(count(W, 'wine'), wine, 'emptied once')
        assert_eq(DBS.CID1.barrel_ready_at, nil)
        assert_eq(DBS.CID1.wine, wine)
    end)
end)

describe('the wholesale buyer', function()
    it('pays cash for all wine and juice, once, and only at the buyer', function()
        give(W, 'wine', 4)
        give(W, 'wine', 2)
        give(W, 'grapejuice', 3)
        Mock.coords[W] = vector3(0.0, 0.0, 0.0)
        Mock.fireNet('pf-jobs:vineyard:sell', W)
        assert_eq(Mock.players[W].PlayerData.money.cash, 0)
        Mock.gameTimer = Mock.gameTimer + 5000
        at(W, cfg.Sell.coords)
        Mock.fireNet('pf-jobs:vineyard:sell', W)
        assert_eq(Mock.players[W].PlayerData.money.cash, 6 * cfg.Sell.prices.wine + 3 * cfg.Sell.prices.grapejuice)
        assert_eq(count(W, 'wine') + count(W, 'grapejuice'), 0)
        assert_eq(#LedgerEnv.paid('pf-jobs:vineyard:sell:'), 1)
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('pf-jobs:vineyard:sell', W)
        assert_eq(#LedgerEnv.paid('pf-jobs:vineyard:sell:'), 1, 'nothing left to sell')
    end)
    it('hands the goods back when the bank is down', function()
        give(W, 'wine', 5)
        bankUp = false
        at(W, cfg.Sell.coords)
        Mock.fireNet('pf-jobs:vineyard:sell', W)
        assert_eq(count(W, 'wine'), 5)
        assert_eq(Mock.players[W].PlayerData.money.cash, 0)
    end)
end)

describe('Vineyard app', function()
    it('is for the vineyard job on both devices and shows the day, the prices and the places', function()
        assert_true(V.RegisterApp())
        assert_eq(app.def.id, 'vineyard')
        assert_eq(app.def.access.jobs.vineyard, 0)
        assert_eq(table.concat(app.def.devices, ','), 'tablet,computer')
        assert_eq(app.def.entry, 'html/apps/vineyard.js')
        start()
        pickTarget()
        local view = app.h.getInit(W, {})
        assert_true(view.ok)
        assert_eq(view.shift.picked, 1)
        assert_true(view.shift.vine.x ~= nil, 'waypoint to the next vine')
        assert_eq(view.carrying.grape, count(W, 'grape'))
        assert_eq(view.prices[1].item, 'wine')
        assert_eq(view.prices[1].buyer, cfg.Sell.prices.wine)
        assert_eq(view.prices[1].restaurants, 18, 'what restaurants pay through the Supplier app')
        assert_eq(#view.places, 4)
        assert_true(#pushes > 0, 'open apps follow the shift')
        local ended = app.h.endShift(W, {})
        assert_true(ended.ok)
        assert_eq(ended.shift, nil)
        assert_eq(app.h.endShift(W, {}).error, 'off_shift')
    end)
end)

describe('deleted characters', function()
    it('their levels, totals and barrel are removed; bad arguments are ignored', function()
        DBS.CID1 = { xp = 100, barrel_ready_at = Mock.clock + 50 }
        DBS.CID2 = { xp = 10 }
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 7)
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, '')
        assert_true(DBS.CID1 ~= nil)
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'CID1')
        assert_eq(DBS.CID1, nil)
        assert_true(DBS.CID2 ~= nil)
    end)
end)
