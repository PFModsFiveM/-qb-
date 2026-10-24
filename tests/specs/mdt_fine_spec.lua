-- pf-policemdt-DEV: a sentence fine is one keyed ledger transfer from the citizen's bank, and the
-- department deposit happens only for a fine that was paid.
load_resource('tests/lua/ledger_env.lua')
function IsDuplicityVersion() return true end

local CHARGES = { { code = 'P1', name = 'Speeding', fineAmount = 300, bailAmount = 0, prisonTime = 0 } }
local function answer(sql)
    if sql:find('FROM pf_mdt_charges', 1, true) then return CHARGES end
    if sql:find('information_schema', 1, true) then return { { COLUMN_NAME = 'fineAmount' }, { COLUMN_NAME = 'bailAmount' }, { COLUMN_NAME = 'prisonTime' } } end
    return {}
end
local oxmysql = {
    execute = function(_, sql, params, cb) if type(params) == 'function' then cb = params end local r = answer(sql) if cb then cb(r) end return r end,
    query = function(_, sql, params, cb) if type(params) == 'function' then cb = params end local r = answer(sql) if cb then cb(r) end return r end,
    insert = function(_, sql, params, cb) if type(params) == 'function' then cb = params end if cb then cb(1) end return 1 end,
    update = function(_, sql, params, cb) if type(params) == 'function' then cb = params end if cb then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) if type(params) == 'function' then cb = params end if cb then cb(nil) end return nil end,
    single = function(_, sql, params, cb) if type(params) == 'function' then cb = params end if cb then cb(nil) end return nil end,
}
Mock.exportsByResource['oxmysql'] = oxmysql

LedgerEnv.load('pf-policemdt-DEV', { '[pfscripts]/pf-policemdt-DEV/config.lua', '[pfscripts]/pf-policemdt-DEV/shared/framework.lua', '[pfscripts]/pf-policemdt-DEV/server/main.lua' })

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
    FakeDB.society('police', 0)
    Mock.newPlayer(OFFICER).PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 4 }, isboss = true }
    Mock.newPlayer(CITIZEN).PlayerData.money = { cash = 0, bank = 1000 }
end

describe('MDT sentence fine', function()
    it('takes the fine through the ledger and deposits it for the department', function()
        sentence()
        assert_eq(bank(), 700)
        assert_eq(police(), 300)
        assert_eq(#LedgerEnv.paid('pf-policemdt:fine:CID2:'), 2) -- the charge and the department deposit
    end)
    it('a citizen who cannot pay is not charged and the department gets nothing', function()
        Mock.players[CITIZEN].PlayerData.money.bank = 50
        sentence()
        assert_eq(bank(), 50)
        assert_eq(police(), 0)
    end)
end)
