-- pf-jobs recycling plant (server/apps/recycle.lua, moved from pfm-recyclejob): the shift is the
-- server's (desk, the shelf it chose, carry time, sorting table), materials go to the inventory once
-- per package, the shift is paid once on the ledger when it ends (also on disconnect, and later when
-- the bank was down), requests from too far away are refused and logged but never banned, sales are
-- paid in cash once per sale, levels raise the pay, and the Recycling app shows it all.
load_resource('tests/lua/ledger_env.lua')
LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/server/apps/recycle.lua' })

local R = PFRecycle
local cfg = R.Config
local W, OTHER = 1, 2

local bankUp = true
function GetResourceState(name)
    if name == 'pfm-banking' and not bankUp then return 'stopped' end
    return 'started'
end

-- inventory with one slot per AddItem (like perishable batches that do not stack)
local Inv, nextSlot, pocketsFull = {}, 0, false
local function bag(src) Inv[src] = Inv[src] or {} return Inv[src] end
local function count(src, item) local n = 0 for _, it in pairs(bag(src)) do if it.name == item then n = n + it.amount end end return n end
local function give(src, item, n) nextSlot = nextSlot + 1 bag(src)[nextSlot] = { slot = nextSlot, name = item, amount = n } end
local function materials(src) local n = 0 for _, m in ipairs(cfg.Materials) do n = n + count(src, m.item) end return n end
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
}

-- the database (its SQL runs for real in pfjobs_sidejobs_realdb_spec)
local DBS
R.DB = {
    loadStats = function(cid) return DBS.stats[cid] end,
    addStats = function(cid, d)
        local r = DBS.stats[cid] or { xp = 0, packages = 0, materials = 0, wages = 0, sales = 0, shifts = 0 }
        for k, v in pairs(d) do r[k] = (r[k] or 0) + v end
        DBS.stats[cid] = r
    end,
    openShift = function(id, cid, at) DBS.shifts[id] = { id = id, citizenid = cid, started_at = at, packages = 0, materials = 0, wage = 0, status = 'open' } end,
    updateShift = function(id, p, m, w) local s = DBS.shifts[id] if s and s.status == 'open' then s.packages, s.materials, s.wage = p, m, w end end,
    endShift = function(id, at) local s = DBS.shifts[id] if s and s.status == 'open' then s.status, s.ended_at = 'unpaid', at return 1 end return 0 end,
    markPaid = function(id) local s = DBS.shifts[id] if s and s.status == 'unpaid' then s.status = 'paid' return 1 end return 0 end,
    unpaid = function(cid)
        local out = {}
        for _, s in pairs(DBS.shifts) do if s.status == 'unpaid' and (not cid or s.citizenid == cid) then out[#out + 1] = s end end
        return out
    end,
    closeOpen = function(at) for _, s in pairs(DBS.shifts) do if s.status == 'open' then s.status, s.ended_at = 'unpaid', at end end end,
    history = function(cid)
        local out = {}
        for _, s in pairs(DBS.shifts) do if s.citizenid == cid then out[#out + 1] = s end end
        return out
    end,
    deleteCharacter = function(cid)
        DBS.stats[cid] = nil
        for id, s in pairs(DBS.shifts) do if s.citizenid == cid then DBS.shifts[id] = nil end end
    end,
}

-- pf-devices as pf-jobs sees it
local app, pushes = {}, {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) app.def = def return true end,
    RegisterAppHandlers = function(_, id, map) app.id, app.h = id, map return true end,
    Push = function(_, src, id, event, payload) pushes[#pushes + 1] = { src = src, id = id, event = event, payload = payload } return true end,
}

local function at(p) Mock.coords[W] = vector3(p.x, p.y, p.z) end
local function shift() return R.__shift(W) end
local function bank() return Mock.players[W].PlayerData.money.bank end
local function cash() return Mock.players[W].PlayerData.money.cash end
local function wait(seconds) Mock.clock = Mock.clock + seconds Mock.gameTimer = Mock.gameTimer + seconds * 1000 + 6000 end
local function clockIn() at(cfg.DutyLocation) Mock.fireNet('pf-jobs:recycle:clockIn', W) assert_true(shift() ~= nil, 'clocked in') end
local function package()
    at(cfg.Shelves[shift().target])
    Mock.fireNet('pf-jobs:recycle:pickup', W)
    wait(10)
    at(cfg.DropLocation)
    Mock.fireNet('pf-jobs:recycle:handIn', W)
    wait(10)
end
local function paidRows(prefix) return #LedgerEnv.paid(prefix or 'pf-jobs:recycle:shift:') end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    bankUp, pocketsFull = true, false
    DBS = { stats = {}, shifts = {} }
    R.__reset()
    R.dbReady = true
    Inv, pushes = {}, {}
    Mock.players, Mock.coords = {}, {}
    Mock.newPlayer(W)
    Mock.newPlayer(OTHER)
    wait(100)
    math.randomseed(7)
end

describe('Recycling app registration', function()
    it('is an installable App Store app on both devices with its handlers', function()
        assert_true(R.RegisterApp())
        assert_eq(app.def.id, 'recycle')
        assert_true(app.def.access.installable)
        assert_eq(app.def.access.jobs, nil)
        assert_eq(table.concat(app.def.devices, ','), 'tablet,computer')
        assert_eq(app.def.entry, 'html/apps/recycle.js')
        assert_eq(app.def.styles[1], 'html/apps/recycle.css')
        assert_eq(app.def.category, 'jobs')
        assert_true(app.h.getInit ~= nil and app.h.clockOut ~= nil)
        app = {}
        TriggerEvent('pf-devices:server:ready')
        assert_eq(app.def.id, 'recycle', 'registers again when pf-devices restarts')
    end)
end)

describe('the shift', function()
    it('starts only at the desk inside the plant', function()
        Mock.coords[W] = vector3(0.0, 0.0, 0.0)
        Mock.fireNet('pf-jobs:recycle:clockIn', W)
        assert_eq(shift(), nil)
        clockIn()
        assert_true(shift().target ~= nil, 'the server chose the first package')
        local st = Mock.clientEventsNamed('pf-jobs:recycle:state')
        assert_eq(st[#st].args[1].target, shift().target, 'the world script outlines that package')
        assert_eq(DBS.shifts[shift().id].status, 'open')
    end)
    it('does not start while the database is not ready', function()
        R.dbReady = false
        at(cfg.DutyLocation)
        Mock.fireNet('pf-jobs:recycle:clockIn', W)
        assert_eq(shift(), nil)
    end)
    it('a package counts only from the shelf the server chose', function()
        clockIn()
        local target = shift().target
        local other = target == 1 and 2 or 1
        at(cfg.Shelves[other])
        Mock.fireNet('pf-jobs:recycle:pickup', W)
        assert_eq(shift().carrying, nil, 'another shelf')
        at(cfg.Shelves[target])
        Mock.fireNet('pf-jobs:recycle:pickup', W)
        assert_true(shift().carrying ~= nil)
        assert_eq(shift().target, nil)
    end)
    it('off shift, nothing can be picked up or sorted', function()
        at(cfg.Shelves[1])
        Mock.fireNet('pf-jobs:recycle:pickup', W)
        at(cfg.DropLocation)
        Mock.fireNet('pf-jobs:recycle:handIn', W)
        assert_eq(materials(W), 0)
    end)
    it('standing at the sorting table pays nothing; a carried package sorts once, after the carry time', function()
        clockIn()
        at(cfg.DropLocation)
        Mock.fireNet('pf-jobs:recycle:handIn', W)
        assert_eq(materials(W), 0, 'no package')
        at(cfg.Shelves[shift().target])
        Mock.fireNet('pf-jobs:recycle:pickup', W)
        at(cfg.DropLocation)
        Mock.gameTimer = Mock.gameTimer + 6000
        Mock.fireNet('pf-jobs:recycle:handIn', W)
        assert_eq(materials(W), 0, 'sorted too soon after the pick-up')
        wait(10)
        Mock.fireNet('pf-jobs:recycle:handIn', W)
        local got = materials(W)
        assert_true(got > 0, 'materials sorted')
        assert_eq(shift().packages, 1)
        wait(10)
        Mock.fireNet('pf-jobs:recycle:handIn', W)
        assert_eq(materials(W), got, 'one sorting per package')
        assert_eq(shift().packages, 1)
        assert_true(shift().target ~= nil, 'the next package is chosen')
    end)
    it('a package left for longer than the carry limit is replaced, not sorted', function()
        clockIn()
        at(cfg.Shelves[shift().target])
        Mock.fireNet('pf-jobs:recycle:pickup', W)
        wait(cfg.CarrySeconds[2] + 5)
        at(cfg.DropLocation)
        Mock.fireNet('pf-jobs:recycle:handIn', W)
        assert_eq(materials(W), 0)
        assert_eq(shift().carrying, nil)
        assert_true(shift().target ~= nil)
    end)
    it('sorting draws from the plant stock and pockets that are full lose nothing from it', function()
        clockIn()
        local before = 0
        for _, n in pairs(R.__stock()) do before = before + n end
        package()
        local after = 0
        for _, n in pairs(R.__stock()) do after = after + n end
        assert_eq(before - after, materials(W), 'stock went down by what was sorted')
        pocketsFull = true
        package()
        local full = 0
        for _, n in pairs(R.__stock()) do full = full + n end
        assert_eq(full, after, 'nothing taken from the stock')
    end)
end)

describe('pay', function()
    it('the shift is paid once, at clock out, with the wage of every package', function()
        clockIn()
        for _ = 1, 3 do package() end
        assert_eq(shift().packages, 3)
        local wage = cfg.Levels[1].wage * 3
        assert_eq(shift().wage, wage)
        assert_eq(bank(), 0, 'nothing paid while working')
        at(cfg.DutyLocation)
        Mock.fireNet('pf-jobs:recycle:clockOut', W, false)
        assert_eq(shift(), nil)
        assert_eq(bank(), wage)
        assert_eq(paidRows(), 1)
        Mock.fireNet('pf-jobs:recycle:clockOut', W, false)
        assert_eq(bank(), wage, 'paid once')
        local id = next(DBS.shifts)
        assert_eq(DBS.shifts[id].status, 'paid')
        assert_eq(DBS.stats.CID1.wages, wage)
        assert_eq(DBS.stats.CID1.shifts, 1)
        -- the shift's key is paid once even if the same shift is settled again
        R.Recover()
        assert_eq(bank(), wage)
    end)
    it('leaving the plant or disconnecting ends the shift and pays it once', function()
        clockIn()
        package()
        Mock.fireEvent('playerDropped', W)
        assert_eq(shift(), nil)
        assert_eq(bank(), cfg.Levels[1].wage)
        Mock.fireEvent('QBCore:Server:OnPlayerUnload', nil, W)
        assert_eq(bank(), cfg.Levels[1].wage)
        assert_eq(paidRows(), 1)
    end)
    it('a shift with nothing sorted pays nothing', function()
        clockIn()
        Mock.fireNet('pf-jobs:recycle:clockOut', W, true)
        assert_eq(bank(), 0)
        assert_eq(paidRows(), 0)
    end)
    it('a shift the bank could not pay is paid at the next clock in, once', function()
        clockIn()
        package()
        package()
        bankUp = false
        Mock.fireNet('pf-jobs:recycle:clockOut', W, false)
        assert_eq(bank(), 0)
        local id = next(DBS.shifts)
        assert_eq(DBS.shifts[id].status, 'unpaid')
        local view = app.h and app.h.getInit(W) or (R.RegisterApp() and app.h.getInit(W))
        assert_eq(view.owed, cfg.Levels[1].wage * 2, 'the app shows the pending pay')
        bankUp = true
        clockIn()
        assert_eq(bank(), cfg.Levels[1].wage * 2)
        assert_eq(DBS.shifts[id].status, 'paid')
        R.Recover()
        assert_eq(bank(), cfg.Levels[1].wage * 2, 'once')
        assert_eq(paidRows(), 1)
    end)
    it('a restart pays the shifts it interrupted, once', function()
        clockIn()
        package()
        R.__reset() -- the server stopped: memory is gone, the open shift is in the database
        R.Recover()
        assert_eq(bank(), cfg.Levels[1].wage)
        R.Recover()
        assert_eq(bank(), cfg.Levels[1].wage)
    end)
    it('the app ends the shift and pays it; it cannot clock in', function()
        R.RegisterApp()
        assert_eq(app.h.clockOut(W, {}).error, 'off_shift')
        clockIn()
        package()
        Mock.coords[W] = vector3(-3000.0, 0.0, 0.0)
        local res = app.h.clockOut(W, {})
        assert_true(res.ok)
        assert_eq(res.summary.wage, cfg.Levels[1].wage)
        assert_true(res.summary.paid)
        assert_eq(res.shift, nil)
        assert_eq(bank(), cfg.Levels[1].wage)
    end)
end)

describe('levels', function()
    it('XP per package; a higher level pays more per package', function()
        DBS.stats.CID1 = { xp = cfg.Levels[3].xp - cfg.XPPerPackage, packages = 0, materials = 0, wages = 0, sales = 0, shifts = 0 }
        clockIn()
        package()
        assert_eq(shift().wage, cfg.Levels[2].wage, 'the package that levels up is paid at the old level')
        package()
        assert_eq(shift().wage, cfg.Levels[2].wage + cfg.Levels[3].wage)
        R.RegisterApp()
        local view = app.h.getInit(W, {})
        assert_eq(view.stats.level, 3)
        assert_eq(view.stats.xp, cfg.Levels[3].xp + cfg.XPPerPackage)
        assert_eq(view.stats.wagePerPackage, cfg.Levels[3].wage)
        assert_eq(view.shift.packages, 2)
        assert_true(#view.prices == #cfg.Materials)
        assert_true(view.plant.x ~= nil)
    end)
end)

describe('requests from too far away', function()
    it('are refused and logged, never a ban (a lagging player used to be banned permanently)', function()
        Mock.coords[W] = vector3(-5000.0, -5000.0, 0.0)
        local bans = 0
        FakeDB.extraPatterns = FakeDB.extraPatterns or {}
        table.insert(FakeDB.extraPatterns, 1, { 'INSERT INTO bans', function() bans = bans + 1 return 1 end })
        for _ = 1, 5 do
            assert_eq(next(Mock.callCallback('pf-jobs:recycle:getPriceList', W) or {}), nil, 'refused')
            Mock.gameTimer = Mock.gameTimer + 5000
            Mock.fireNet('pf-jobs:recycle:sell', W, 'metalscrap', 1)
        end
        assert_eq(bans, 0)
        assert_eq(#Mock.dropped, 0)
        local logs = 0
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'qb-log:server:CreateLog' then logs = logs + 1 end end
        assert_true(logs >= 1, 'staff were told')
        table.remove(FakeDB.extraPatterns, 1)
    end)
end)

describe('selling materials', function()
    it('the buyer pays cash once per sale, from every slot, and refills the plant', function()
        give(W, 'metalscrap', 3)
        give(W, 'metalscrap', 4)
        local before = R.__stock().metalscrap
        at(cfg.SellPed)
        assert_eq(Mock.callCallback('pf-jobs:recycle:getPriceList', W).metalscrap, cfg.SellPrices.metalscrap)
        Mock.fireNet('pf-jobs:recycle:sell', W, 'metalscrap', 6)
        assert_eq(count(W, 'metalscrap'), 1)
        assert_eq(cash(), 6 * cfg.SellPrices.metalscrap)
        assert_eq(R.__stock().metalscrap, before + 6)
        assert_eq(#LedgerEnv.paid('pf-jobs:recycle:sell:'), 1)
        Mock.fireNet('pf-jobs:recycle:sell', W, 'metalscrap', 6)
        assert_eq(cash(), 6 * cfg.SellPrices.metalscrap, 'a resend right away is not a second sale')
    end)
    it('refuses what the buyer does not take and bad amounts', function()
        give(W, 'goldbar', 2)
        give(W, 'steel', 5)
        at(cfg.SellPed)
        Mock.fireNet('pf-jobs:recycle:sell', W, 'goldbar', 2)
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('pf-jobs:recycle:sell', W, 'steel', -5)
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('pf-jobs:recycle:sell', W, 'steel', 1e9)
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('pf-jobs:recycle:sell', W, { 'steel' }, 1)
        assert_eq(cash(), 0)
        assert_eq(count(W, 'goldbar'), 2)
        assert_eq(count(W, 'steel'), 5)
    end)
    it('if the bank is down the materials are handed back', function()
        give(W, 'copper', 5)
        bankUp = false
        at(cfg.SellPed)
        Mock.fireNet('pf-jobs:recycle:sell', W, 'copper', 5)
        assert_eq(count(W, 'copper'), 5)
        assert_eq(cash(), 0)
    end)
end)

describe('deleted characters', function()
    it('their levels and shifts are removed; anything but a citizen id is ignored', function()
        clockIn()
        package()
        Mock.fireNet('pf-jobs:recycle:clockOut', W, false)
        DBS.stats.CID2 = { xp = 50 }
        assert_true(DBS.stats.CID1 ~= nil)
        for _, bad in ipairs({ 42, '', { 'CID1' } }) do
            Mock.fireEvent('pfm-core:server:characterDeleted', nil, bad)
        end
        assert_true(DBS.stats.CID1 ~= nil, 'bad arguments delete nothing')
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'CID1')
        assert_eq(DBS.stats.CID1, nil)
        assert_eq(next(DBS.shifts), nil)
        assert_true(DBS.stats.CID2 ~= nil, 'other characters are kept')
    end)
end)
