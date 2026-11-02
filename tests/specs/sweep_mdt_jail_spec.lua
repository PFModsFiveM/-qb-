-- pf-policemdt-DEV built-in jail (server/sentencing.lua): the confiscated items are the server's
-- inventory (the jailed player's client used to send the list that was "restored" on release), they
-- are stored before the inventory is cleared, and they come back once, only when the server says the
-- time is served, not when the client says so. The time counts on the server.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
local states = {}
function GetResourceState(name) return states[name] or 'missing' end
QBCore = QBCoreMock

-- In-memory stand-in for the MDT's sentencing tables (the real SQL runs in
-- tests/realdb_specs/fix14_mdtserver_jail_realdb_spec.lua).
local CHARGES = { J1 = { code = 'J1', name = 'Robbery', fineAmount = 0, bailAmount = 0, prisonTime = 10 } }
local DB = { jails = {}, sentences = {}, nextJail = 0, nextSentence = 0, failSetItems = false }
local function jailBy(field, v)
    for _, r in pairs(DB.jails) do if r[field] == v then return r end end
end
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
local function run(kind, sql, p)
    p = p or {}
    if sql:find('FROM pf_mdt_charges', 1, true) then
        local out = {}
        for _, code in ipairs(p) do if CHARGES[code] then out[#out + 1] = copy(CHARGES[code]) end end
        return out
    end
    if sql:find('SELECT * FROM pf_mdt_active_jails WHERE citizenid', 1, true) then
        local r = jailBy('citizenid', p[1]); return r and copy(r) or nil
    end
    if sql:find('SELECT * FROM pf_mdt_active_jails', 1, true) then
        local out = {} for _, r in pairs(DB.jails) do out[#out + 1] = copy(r) end return out
    end
    if sql:find('INSERT INTO pf_mdt_active_jails', 1, true) then
        if jailBy('citizenid', p[1]) then error('Duplicate entry for uq_mdt_jail_citizen') end
        DB.nextJail = DB.nextJail + 1
        DB.jails[DB.nextJail] = { id = DB.nextJail, citizenid = p[1], sentence_id = p[2], remaining_seconds = p[3], total_seconds = p[4],
            bail_amount = p[5], reason = p[6], items = p[7], provider = p[8], officer_citizenid = p[9] }
        return DB.nextJail
    end
    if sql:find('UPDATE pf_mdt_active_jails SET items', 1, true) then
        if DB.failSetItems then error('injected: connection lost') end
        local r = DB.jails[p[2]]; if r then r.items = p[1] return 1 end return 0
    end
    if sql:find('remaining_seconds = GREATEST', 1, true) then
        local r = DB.jails[p[2]]; if r then r.remaining_seconds = math.max(r.remaining_seconds - p[1], 0) return 1 end return 0
    end
    if sql:find('SET remaining_seconds = 0 WHERE', 1, true) then
        local r = DB.jails[p[1]]; if r then r.remaining_seconds = 0 return 1 end return 0
    end
    if sql:find('DELETE FROM pf_mdt_active_jails WHERE id', 1, true) then
        if DB.jails[p[1]] then DB.jails[p[1]] = nil return 1 end return 0
    end
    if sql:find('INSERT INTO pf_mdt_sentences', 1, true) then
        DB.nextSentence = DB.nextSentence + 1
        DB.sentences[DB.nextSentence] = { id = DB.nextSentence, citizenId = p[1], title = p[5], status = 'pending', prisonTime = p[11] }
        return DB.nextSentence
    end
    if sql:find('UPDATE pf_mdt_sentences SET status = ?, executed', 1, true) then
        local r = DB.sentences[p[7]]; if r then r.status, r.fineSuccess, r.jailSuccess, r.error = p[1], p[3], p[4], p[5] end return 1
    end
    if sql:find("status = 'payment_pending'", 1, true) then return kind == 'single' and nil or {} end
    return kind == 'query' and {} or (kind == 'single' and nil or 0)
end
local function op(kind)
    return setmetatable({ await = function(sql, p) return run(kind, sql, p) end }, { __call = function(_, sql, p, cb)
        local r = run(kind, sql, p) if cb then cb(r) end return r end })
end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), single = op('single'), scalar = op('scalar'), prepare = op('query') }
Mock.exportsByResource['oxmysql'] = {
    execute = function(_, sql, params, cb) if Mock.callable(params) then cb = params end if cb then cb({}) end return {} end,
    insert = function(_, sql, params, cb) if Mock.callable(cb) then cb(1) end return 1 end,
}
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/sentencing.lua')
local S = PFMdtSentencing
assert(S.Start(), 'start')

local OFFICER, PRISONER = 1, 2
local CELL = vector3(1700.0, 2570.0, 45.0)
local OUTSIDE = vector3(2400.0, 3000.0, 40.0)

local function inv() return Mock.players[PRISONER].PlayerData.items end
local function count(name)
    local n = 0
    for _, it in pairs(inv()) do if it.name == name then n = n + it.amount end end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.clock = Mock.clock + 3600
    DB.jails, DB.sentences, DB.failSetItems = {}, {}, false
    Mock.newPlayer(OFFICER).PlayerData.job = { name = 'police', onduty = true, grade = { level = 4 } }
    local p = Mock.newPlayer(PRISONER)
    p.PlayerData.metadata.ishandcuffed = true
    p.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 } }
    p.Functions.ClearInventory = function() p.PlayerData.items = {} end
    p.Functions.RemoveItem = function() return true end
    p.Functions.AddItem = function(name, amount, slot)
        table.insert(p.PlayerData.items, { name = name, amount = amount, slot = slot })
        return true
    end
    Mock.coords[OFFICER], Mock.coords[PRISONER] = CELL, CELL
end

local function sentence()
    return Mock.callCallback('pf_mdt:createSentence', OFFICER, { citizenId = 'CID2', citizenName = 'Test Player2', title = 'Robbery', sentenceType = 'sentence', charges = { 'J1' } })
end
-- serves the whole sentence on the server's clock, inside the prison
local function serve()
    S.Tick()
    for _ = 1, 45 do Mock.clock = Mock.clock + 15; S.Tick() end
end

describe('MDT jail inventory', function()
    it('confiscates the server inventory and gives back only that, when the server says the time is served', function()
        local res = sentence()
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(#Mock.clientEventsNamed('pf_mdt:client:StartMdtSentence'), 1)
        assert_eq(count('phone'), 0)
        assert_eq(json.decode(jailBy('citizenid', 'CID2').items)[1].name, 'phone', 'stored in the jail row')
        serve()
        assert_eq(count('phone'), 1)
        assert_eq(count('goldbar'), 0)
        assert_eq(jailBy('citizenid', 'CID2'), nil)
    end)
    it('the inventory snapshot from the client is no longer a net event', function()
        assert_eq(Mock.netHandlers['pf_mdt:server:InventorySnapshot'], nil)
    end)
    it('a release sent by the client before the sentence ends gives nothing back', function()
        sentence()
        Mock.fireNet('pf_mdt:server:mdtSentenceReleased', PRISONER)
        assert_eq(#inv(), 0)
        assert_true(jailBy('citizenid', 'CID2') ~= nil, 'still jailed')
    end)
    it('the time does not run on the client: an hour away from the prison serves nothing', function()
        sentence()
        S.Tick()
        Mock.coords[PRISONER] = OUTSIDE
        for _ = 1, 240 do Mock.clock = Mock.clock + 15; S.Tick() end
        assert_eq(jailBy('citizenid', 'CID2').remaining_seconds, 600)
        assert_eq(#inv(), 0)
        assert_true(#Mock.clientEventsNamed('pf_mdt:client:StartMdtSentence') > 2, 'sent back to a cell again and again')
    end)
    -- P comes from pfm-core, so RemoveItem and ClearInventory are function references here: the two
    -- tests below fail if either step tests them with type() == 'function' (it is skipped).
    it('items a one-call clear leaves in the hotbar are taken one by one', function()
        local p = Mock.players[PRISONER]
        p.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 }, { name = 'lockpick', amount = 2, slot = 7 } }
        -- an inventory whose clear keeps the hotbar (slots 1-5)
        p.Functions.ClearInventory = function()
            local kept = {}
            for _, it in pairs(p.PlayerData.items) do if it.slot <= 5 then kept[#kept + 1] = it end end
            p.PlayerData.items = kept
        end
        p.Functions.RemoveItem = function(name, amount, slot)
            for i, it in pairs(p.PlayerData.items) do
                if it.name == name and (slot == nil or it.slot == slot) and it.amount >= amount then
                    it.amount = it.amount - amount
                    if it.amount == 0 then table.remove(p.PlayerData.items, i) end
                    return true
                end
            end
            return false
        end
        assert_eq(sentence().success, true)
        assert_eq(count('phone'), 0, 'the hotbar item was confiscated')
        assert_eq(count('lockpick'), 0)
        serve()
        assert_eq(count('phone'), 1)
        assert_eq(count('lockpick'), 2)
    end)
    it('the release clears what the prisoner holds before the confiscated items come back', function()
        sentence()
        assert_eq(count('phone'), 0)
        -- the inventory came back from the last save (a reconnect in jail), and a jail item
        local p = Mock.players[PRISONER]
        p.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 }, { name = 'prison_spoon', amount = 1, slot = 2 } }
        serve()
        assert_eq(count('phone'), 1, 'one phone, not two')
        assert_eq(count('prison_spoon'), 0)
    end)
    it('an item picked up while the jail row was written is stored before the inventory is cleared', function()
        local p = Mock.players[PRISONER]
        local realInsert = MySQL.insert
        MySQL.insert = setmetatable({ await = function(sql, prm)
            local id = realInsert.await(sql, prm)
            if sql:find('pf_mdt_active_jails', 1, true) then table.insert(p.PlayerData.items, { name = 'goldbar', amount = 2, slot = 3 }) end
            return id
        end }, { __call = function(_, ...) return realInsert(...) end })
        local res = sentence()
        MySQL.insert = realInsert
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(count('goldbar'), 0)
        local stored = json.decode(jailBy('citizenid', 'CID2').items)
        assert_eq(#stored, 2, 'phone and the gold bar are both in the row')
        serve()
        assert_eq(count('goldbar'), 2, 'nothing was lost')
    end)
    it('when the changed list cannot be stored, nothing is cleared and nobody is jailed', function()
        local p = Mock.players[PRISONER]
        local realInsert = MySQL.insert
        MySQL.insert = setmetatable({ await = function(sql, prm)
            local id = realInsert.await(sql, prm)
            if sql:find('pf_mdt_active_jails', 1, true) then table.insert(p.PlayerData.items, { name = 'goldbar', amount = 2, slot = 3 }) end
            return id
        end }, { __call = function(_, ...) return realInsert(...) end })
        DB.failSetItems = true
        local res = sentence()
        MySQL.insert = realInsert
        assert_eq(res.success, false)
        assert_eq(count('phone'), 1)
        assert_eq(count('goldbar'), 2)
        assert_eq(jailBy('citizenid', 'CID2'), nil)
    end)
end)
