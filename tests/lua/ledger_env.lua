-- The real pfm-banking ledger on the fake database, for specs of resources that pay through it.
--   load_resource('tests/lua/ledger_env.lua')
--   LedgerEnv.load('pfm-taxijob', { 'pfm-taxijob/config.lua', 'pfm-taxijob/server/main.lua' })
--   BeforeEach: LedgerEnv.reset() (fresh database and ledger), then create players.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetResourceState() return 'started' end

LedgerEnv = {}

function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
local bankingConfig = Config

--- Loads a resource that includes '@pfm-banking/payouts.lua', under its own resource name.
--- Its Config replaces the bank's; bank settings it lacks are kept.
function LedgerEnv.load(resource, files)
    function GetCurrentResourceName() return resource end
    Config = nil
    load_resource('pfm-banking/payouts.lua')
    for _, file in ipairs(files) do load_resource(file) end
    Config = Config or {}
    for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
end

function LedgerEnv.reset()
    FakeDB.reset()
    FakeDB.migrations = {}
    for k in pairs(BankingAccounts) do BankingAccounts[k] = nil end
    PFLedger.ready, PFLedger.failed = false, false
    assert(PFLedger.Start(), 'ledger start')
end

--- Completed ledger rows whose key starts with prefix.
function LedgerEnv.paid(prefix)
    local out = {}
    for _, row in pairs(FakeDB.byKey) do
        if row.state == 'completed' and tostring(row.idempotency_key):sub(1, #prefix) == prefix then out[#out + 1] = row end
    end
    return out
end
