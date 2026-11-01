-- pfm-core RunMigrations through its export (as pf-devices, pf-services, pf-government... call it):
-- a step whose `up` is a function arrives as a function reference and must be run, not read as a
-- list of SQL statements (ipairs over a funcref errors and the migration failed).
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pfm-core' end
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = Mock.exportsByResource['__self'].RunMigrations

local function ran(fragment)
    local n = 0
    for _, c in ipairs(Mock.dbCalls) do if tostring(c.query):find(fragment, 1, true) then n = n + 1 end end
    return n
end

BeforeEach = function() Mock.reset() end

describe('RunMigrations across the export', function()
    it('runs a step given as a function', function()
        local calls = 0
        local ok, err = exports['pfm-core']:RunMigrations('pf-x', {
            { version = 1, name = 'table', up = { 'CREATE TABLE IF NOT EXISTS pf_x (id INT)' } },
            { version = 2, name = 'backfill', up = function()
                calls = calls + 1
                MySQL.query.await('UPDATE pf_x SET id = id')
            end },
        })
        assert_true(ok, tostring(err))
        assert_eq(calls, 1, 'the function step ran once')
        assert_eq(ran('CREATE TABLE IF NOT EXISTS pf_x'), 1)
        assert_eq(ran('UPDATE pf_x SET id = id'), 1)
        assert_eq(ran('INSERT INTO pf_schema_migrations'), 2, 'both versions recorded')
    end)

    it('a failing function step is reported, not recorded', function()
        local ok, err = exports['pfm-core']:RunMigrations('pf-y', {
            { version = 1, name = 'boom', up = function() error('step failed') end },
        })
        assert_false(ok)
        assert_true(tostring(err):find('step failed', 1, true) ~= nil, tostring(err))
        assert_eq(ran('INSERT INTO pf_schema_migrations'), 0)
    end)
end)
