-- pf-policemdt-DEV: a sentence fine is one ledger transfer from the citizen's bank straight to the
-- department, keyed by the sentence row (server/sentencing.lua). A citizen who cannot pay is not
-- charged; a double click, or a second sentence while the bank still confirms the first, never
-- charges twice.
load_resource('tests/lua/ledger_env.lua')
function IsDuplicityVersion() return true end

local CHARGES = { P1 = { code = 'P1', name = 'Speeding', fineAmount = 300, bailAmount = 0, prisonTime = 0 } }
local sentences = {}
local function answer(sql)
    if sql:find('FROM pf_mdt_charges', 1, true) then return { CHARGES.P1 } end
    if sql:find('information_schema', 1, true) then return { { COLUMN_NAME = 'fineAmount' }, { COLUMN_NAME = 'bailAmount' }, { COLUMN_NAME = 'prisonTime' } } end
    return {}
end
local oxmysql = {
    execute = function(_, sql, params, cb) if Mock.callable(params) then cb = params end local r = answer(sql) if cb then cb(r) end return r end,
    query = function(_, sql, params, cb) if Mock.callable(params) then cb = params end local r = answer(sql) if cb then cb(r) end return r end,
    insert = function(_, sql, params, cb) if Mock.callable(params) then cb = params end if cb then cb(1) end return 1 end,
    update = function(_, sql, params, cb) if Mock.callable(params) then cb = params end if cb then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) if Mock.callable(params) then cb = params end if cb then cb(nil) end return nil end,
    single = function(_, sql, params, cb) if Mock.callable(params) then cb = params end if cb then cb(nil) end return nil end,
}
Mock.exportsByResource['oxmysql'] = oxmysql

-- the MDT's own statements on the fake database (the ledger's are FakeDB's)
FakeDB.extraPatterns = {
    { 'FROM pf_mdt_charges WHERE code IN', function(p)
        local out = {}
        for _, code in ipairs(p) do if CHARGES[code] then out[#out + 1] = CHARGES[code] end end
        return out
    end },
    { 'FROM pf_mdt_active_jails', function() return {} end },
    { "WHERE citizenId = ? AND status = 'payment_pending'", function(p)
        for _, r in ipairs(sentences) do if r.citizenId == p[1] and r.status == 'payment_pending' then return { r } end end
        return {}
    end },
    { "WHERE status = 'payment_pending'", function()
        local out = {}
        for _, r in ipairs(sentences) do if r.status == 'payment_pending' then out[#out + 1] = r end end
        return out
    end },
    { 'INSERT INTO pf_mdt_sentences', function(p)
        sentences[#sentences + 1] = { id = #sentences + 1, citizenId = p[1], title = p[5], fineAmount = p[10], status = 'pending' }
        return #sentences
    end },
    { 'UPDATE pf_mdt_sentences SET status = ?, executed', function(p)
        local r = sentences[p[7]]
        if r then r.status, r.fineSuccess, r.error, r.fine_key = p[1], p[3], p[5], p[6] end
        return { affectedRows = r and 1 or 0 }
    end },
    { 'UPDATE pf_mdt_sentences SET status = ?, fineSuccess', function(p)
        local r = sentences[p[4]]
        if r and r.status == 'payment_pending' then r.status, r.fineSuccess, r.error = p[1], p[2], p[3] return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
    { 'UPDATE pf_mdt_sentences SET executed = 1', function() return { affectedRows = 1 } end },
}

LedgerEnv.load('pf-policemdt-DEV', {
    '[pfscripts]/pf-policemdt-DEV/shared/framework.lua', '[pfscripts]/pf-policemdt-DEV/config.lua',
    '[pfscripts]/pf-policemdt-DEV/server/access.lua', '[pfscripts]/pf-policemdt-DEV/server/main.lua',
    '[pfscripts]/pf-policemdt-DEV/server/sentencing.lua',
})
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end
local S = PFMdtSentencing
assert(S.Start(), 'sentencing start')

local OFFICER, CITIZEN = 1, 2
local function bank() return Mock.players[CITIZEN].PlayerData.money.bank end
local function police() return FakeDB.bank_accounts.police.account_balance end
local function sentence()
    return Mock.callCallback('pf_mdt:createSentence', OFFICER, { citizenId = 'CID2', citizenName = 'Test Citizen', title = 'Traffic stop', sentenceType = 'fine', charges = { 'P1' } })
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players = {}
    sentences = {}
    Mock.clock = Mock.clock + 100
    FakeDB.society('police', 0)
    Mock.newPlayer(OFFICER).PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 4 }, isboss = true }
    Mock.newPlayer(CITIZEN).PlayerData.money = { cash = 0, bank = 1000 }
end

describe('MDT sentence fine', function()
    it('one keyed transfer from the citizen to the department', function()
        local res = sentence()
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(bank(), 700)
        assert_eq(police(), 300)
        local paid = LedgerEnv.paid('pf-policemdt:fine:')
        assert_eq(#paid, 1, 'one transfer, no separate deposit')
        assert_eq(paid[1].idempotency_key, 'pf-policemdt:fine:' .. res.id)
        assert_eq(paid[1].to_account, 'society:police')
        assert_eq(sentences[res.id].status, 'done')
    end)
    it('a citizen who cannot pay is not charged and the department gets nothing', function()
        Mock.players[CITIZEN].PlayerData.money.bank = 50
        local res = sentence()
        assert_eq(res.success, false)
        assert_eq(bank(), 50)
        assert_eq(police(), 0)
        assert_eq(sentences[res.id].status, 'failed')
    end)
    it('a second click right after the first is not a second fine', function()
        assert_eq(sentence().success, true)
        local again = sentence()
        assert_eq(again.success, false)
        assert_eq(bank(), 700)
        assert_eq(#LedgerEnv.paid('pf-policemdt:fine:'), 1)
    end)
    it('while the bank still confirms a fine, no new fine is taken for that citizen', function()
        sentences[1] = { id = 1, citizenId = 'CID2', title = 'Earlier', status = 'payment_pending', fine_key = 'pf-policemdt:fine:1' }
        local res = sentence()
        assert_eq(res.success, false)
        assert_eq(res.error, 'A fine for this citizen is still being confirmed by the bank; wait for it to settle')
        assert_eq(bank(), 1000)
    end)
    it('an officer off duty cannot fine anyone', function()
        Mock.players[OFFICER].PlayerData.job.onduty = false
        local res = sentence()
        assert_eq(res.success, false)
        assert_eq(res.error, 'off_duty')
        assert_eq(bank(), 1000)
    end)
end)
