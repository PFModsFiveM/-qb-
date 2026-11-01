-- pf-policemdt-DEV across the FiveM boundary: its QBCore object comes from pfm-core, so callback
-- answers (cb) and player methods are function references, and players are copies.
--   * the access gate answers a refused caller (cb is a funcref, not a function);
--   * licence changes for an online citizen reach the live player through SetMetaData (writing the
--     copy changed nothing, and pfm-core's next save wrote the old licences back);
--     They start from the live licences, not the players row (saved only now and then), so a
--     licence granted since the last save is not taken back;
--   * a fine that may go below zero is not reported paid when pfm-core refuses the balance, and is
--     worked out from the live balance, not the copy's;
--   * a suspension that ran out is lifted on the live player too when the profile is opened;
--   * the duty/status toggle answers with what was just set (the copy holds the old values).
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

local CHARGES = { { code = 'F1', name = 'Speeding', fineAmount = 500, bailAmount = 0, prisonTime = 0 } }
local stored = {}      -- citizenid -> metadata in the players table
local updates = {}
local function answer(sql, params)
    if sql:find('FROM pf_mdt_charges', 1, true) then return CHARGES end
    if sql:find('information_schema', 1, true) then return { { COLUMN_NAME = 'fineAmount' }, { COLUMN_NAME = 'bailAmount' }, { COLUMN_NAME = 'prisonTime' } } end
    if sql:find('SELECT citizenid, charinfo, job, metadata FROM players', 1, true) then
        local meta = stored[params[1]]
        return meta and { { citizenid = params[1], charinfo = json.encode({ firstname = 'Test', lastname = 'Player2' }),
            job = json.encode({ name = 'unemployed' }), metadata = json.encode(meta) } } or {}
    end
    if sql:find('SELECT metadata FROM players', 1, true) then
        local meta = stored[params[1]]
        return meta and { { metadata = json.encode(meta) } } or {}
    end
    if sql:find('UPDATE players SET metadata', 1, true) then
        updates[#updates + 1] = { cid = params[2], meta = json.decode(params[1]) }
        stored[params[2]] = json.decode(params[1])
    end
    return {}
end
local function call(sql, params, cb)
    if Mock.callable(params) then cb, params = params, nil end
    local r = answer(sql, params or {})
    if cb then cb(r) end
    return r
end
Mock.exportsByResource['oxmysql'] = {
    execute = function(_, sql, params, cb) return call(sql, params, cb) end,
    query = function(_, sql, params, cb) return call(sql, params, cb) end,
    fetch = function(_, sql, params, cb) return call(sql, params, cb) end,
    insert = function(_, sql, params, cb) if Mock.callable(cb) then cb(1) end return 1 end,
    update = function(_, sql, params, cb) if Mock.callable(cb) then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) if Mock.callable(cb) then cb(0) end return 0 end,
}

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')

local OFFICER, CITIZEN, STRANGER = 1, 2, 3

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    stored, updates = {}, {}
    Config.Billing = 'none'
    Config.Sentencing = Config.Sentencing or {}
    Config.Sentencing.AllowNegativeBank = nil
    Mock.newPlayer(OFFICER).PlayerData.job = { name = 'police', onduty = true, grade = { level = 4 } }
    local c = Mock.newPlayer(CITIZEN)
    c.PlayerData.metadata.licences = { driver = true, weapon = true }
    c.PlayerData.money = { cash = 0, bank = 100 }
    c.Functions.SetMoney = function(kind, amount)
        if tonumber(amount) == nil or amount < 0 then return false end -- like pfm-core
        c.PlayerData.money[kind] = amount
        return true
    end
    c.Functions.GetMoney = function(kind) return c.PlayerData.money[kind] end
    Mock.newPlayer(STRANGER)
    stored.CID2 = { licences = { driver = true, weapon = true } }
end

local function live() return Mock.players[CITIZEN].PlayerData.metadata end

describe('the MDT access gate', function()
    it('answers a caller who is not police instead of leaving them waiting', function()
        local res = Mock.callCallback('pf_mdt:createSentence', STRANGER, { citizenId = 'CID2', charges = { 'F1' } })
        assert_true(res ~= nil, 'the refused caller got an answer')
        assert_eq(res.success, false)
        assert_eq(res.error, 'no_access')
    end)
end)

describe('licences of an online citizen', function()
    it('a suspension reaches the live player', function()
        Mock.fireNet('pf_mdt:suspendLicense', OFFICER, { citizenId = 'CID2', licenseType = 'driver', durationDays = 3 })
        assert_eq(#updates, 1, 'stored')
        assert_eq(live().licences.driver, false, 'the live player lost the licence')
        assert_eq(live().licences.weapon, true)
        assert_true(type(live().licenseSuspensions) == 'table' and live().licenseSuspensions.driver ~= nil)
    end)
    it('lifting the suspension gives it back to the live player', function()
        Mock.fireNet('pf_mdt:suspendLicense', OFFICER, { citizenId = 'CID2', licenseType = 'driver', durationDays = 3 })
        Mock.fireNet('pf_mdt:unsuspendLicense', OFFICER, { citizenId = 'CID2', licenseType = 'driver' })
        assert_eq(live().licences.driver, true)
        assert_eq(live().licenseSuspensions.driver, nil)
    end)
    it('a licence granted since the last save is kept (the change starts from the live licences)', function()
        live().licences.business = true -- granted in game, the players row does not have it yet
        Mock.fireNet('pf_mdt:suspendLicense', OFFICER, { citizenId = 'CID2', licenseType = 'driver', durationDays = 3 })
        assert_eq(live().licences.driver, false)
        assert_eq(live().licences.business, true, 'the new licence survived the suspension')
        assert_eq(stored.CID2.licences.business, true, 'and is in the stored row too')
        Mock.fireNet('pf_mdt:removeLicense', OFFICER, { citizenId = 'CID2', licenseType = 'weapon' })
        assert_eq(live().licences.business, true, 'and the removal')
        Mock.fireNet('pf_mdt:unsuspendLicense', OFFICER, { citizenId = 'CID2', licenseType = 'driver' })
        assert_eq(live().licences.driver, true)
        assert_eq(live().licences.business, true, 'and the lifted suspension')
    end)
    -- the two below start from a row without the new licence (the test above suspends first, which
    -- writes it into the row), so each handler is checked on its own
    it('a removal alone keeps a licence granted since the last save', function()
        live().licences.business = true
        Mock.fireNet('pf_mdt:removeLicense', OFFICER, { citizenId = 'CID2', licenseType = 'weapon' })
        assert_eq(live().licences.weapon, false)
        assert_eq(live().licences.business, true, 'the removal kept the new licence')
        assert_eq(stored.CID2.licences.business, true, 'and stored it')
    end)
    it('lifting a suspension alone keeps a licence granted since the last save', function()
        local fut = os.date('%Y-%m-%d %H:%M:%S', os.time() + 86400)
        live().licences.driver = false
        live().licenseSuspensions = { driver = fut }
        live().licences.business = true
        stored.CID2 = { licences = { driver = false, weapon = true }, licenseSuspensions = { driver = fut } }
        Mock.fireNet('pf_mdt:unsuspendLicense', OFFICER, { citizenId = 'CID2', licenseType = 'driver' })
        assert_eq(live().licences.driver, true)
        assert_eq(live().licences.business, true, 'lifting the suspension kept the new licence')
        assert_eq(stored.CID2.licences.business, true, 'and stored it')
    end)
    it('a suspension that ran out is lifted on the live player when the profile is opened', function()
        local past = os.date('%Y-%m-%d %H:%M:%S', os.time() - 3600)
        live().licences.driver = false
        live().licenseSuspensions = { driver = past }
        stored.CID2 = { licences = { driver = false, weapon = true }, licenseSuspensions = { driver = past } }
        -- (the answer itself waits for lookups this spec does not fake; the licences are done first)
        Mock.callCallback('pf_mdt:getCitizenProfile', OFFICER, { citizenId = 'CID2' })
        assert_eq(stored.CID2.licences.driver, true, 'the row')
        assert_eq(live().licences.driver, true, 'and the live player (its next save kept the suspension)')
        assert_eq(live().licenseSuspensions.driver, nil)
    end)
    it('a removal reaches the live player', function()
        Mock.fireNet('pf_mdt:removeLicense', OFFICER, { citizenId = 'CID2', licenseType = 'weapon' })
        assert_eq(live().licences.weapon, false)
        assert_eq(stored.CID2.licences.weapon, false)
    end)
end)

describe('a fine allowed below zero', function()
    it('is declined when pfm-core refuses the negative balance, not reported paid', function()
        Config.Sentencing.AllowNegativeBank = true
        local res = Mock.callCallback('pf_mdt:createSentence', OFFICER,
            { citizenId = 'CID2', citizenName = 'Test Player2', title = 'Speeding', sentenceType = 'fine', charges = { 'F1' } })
        assert_eq(res.success, false)
        assert_eq(Mock.players[CITIZEN].PlayerData.money.bank, 100, 'nothing moved')
    end)
    it('is worked out from the live balance, not the copy taken before the billing attempt', function()
        Config.Sentencing.AllowNegativeBank = true
        Config.Billing = 'custom-billing'
        Mock.players[CITIZEN].PlayerData.money.bank = 800
        local sendFine = PFMdt.Billing.SendFine
        PFMdt.Billing.SendFine = function()
            Mock.players[CITIZEN].PlayerData.money.bank = 1800 -- a deposit lands meanwhile
            return false                                       -- the billing provider declines
        end
        local ok, res = pcall(Mock.callCallback, 'pf_mdt:createSentence', OFFICER,
            { citizenId = 'CID2', citizenName = 'Test Player2', title = 'Speeding', sentenceType = 'fine', charges = { 'F1' } })
        PFMdt.Billing.SendFine = sendFine
        assert_true(ok, tostring(res))
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(Mock.players[CITIZEN].PlayerData.money.bank, 1300, 'the deposit is kept, the fine taken')
    end)
    it('within the balance it is charged', function()
        Config.Sentencing.AllowNegativeBank = true
        Mock.players[CITIZEN].PlayerData.money.bank = 800
        local res = Mock.callCallback('pf_mdt:createSentence', OFFICER,
            { citizenId = 'CID2', citizenName = 'Test Player2', title = 'Speeding', sentenceType = 'fine', charges = { 'F1' } })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(Mock.players[CITIZEN].PlayerData.money.bank, 300)
    end)
end)

describe('the duty and status toggle', function()
    local function set(field, value)
        Mock.clientEvents = {}
        Mock.fireEvent('pf_mdt:updatePlayerStatus', OFFICER, { changed = field, [field] = value })
        local sent = Mock.clientEventsNamed('pf_mdt:client:UpdatePersonalInfo')
        return sent[#sent] and sent[#sent].args[1]
    end
    it('answers with the duty just set, also on the second change', function()
        assert_eq(set('duty', 'on_duty').duty, 'on_duty', 'first change')
        assert_eq(Mock.players[OFFICER].PlayerData.metadata.mdt_duty, 'on_duty')
        assert_eq(set('duty', 'off_duty').duty, 'off_duty', 'second change')
        assert_eq(Mock.players[OFFICER].PlayerData.metadata.mdt_duty, 'off_duty')
    end)
    it('answers with the status just set and keeps the duty', function()
        set('duty', 'off_duty')
        set('status', 'busy')
        local reply = set('status', 'on_mission')
        assert_eq(reply.status, 'on_mission')
        assert_eq(reply.duty, 'off_duty')
    end)
end)
