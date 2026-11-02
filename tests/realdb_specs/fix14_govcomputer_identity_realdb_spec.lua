-- Batch 14, GOV-ID-1 and X10 on a real database: the government's civilian corrections.
--   civilian:updateIdentity checks each changed field with the same rules as character creation
--   (pfm-multicharacter's ValidateIdentityField: no markup or control characters, bounded, a real
--   YYYY-MM-DD birthdate), refuses a phone another citizen has, and changes an online citizen's live
--   character (a database-only edit was lost at their next save); civilian:updateJob likewise.
--   Character creation uses the same rules.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pfm-cityhall'] = 'missing', ['pf-services'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
RealDB.exec('pfm-core/qbcore.sql')
load_resource('pfm-core/server/migrations.lua')
-- (character creation reads the house list)
MySQL.query.await('CREATE TABLE IF NOT EXISTS houselocations (name VARCHAR(50) PRIMARY KEY, label VARCHAR(255), coords TEXT, owned TINYINT, price INT, tier INT, garage TEXT)')

-- pfm-multicharacter (its creation event and its validator export)
QBCore = QBCoreMock
QBCoreMock.Shared.StarterItems = {}
function LoadResourceFile() return '[]' end
function SetPlayerRoutingBucket() end
QBCoreMock.Functions.GetIdentifier = function(src, kind) return kind .. ':' .. tostring(src) end
QBCoreMock.Commands.Refresh = function() end
local logins = {}
local multicharLoaded   -- pfm-multicharacter's player-loaded hook (pf-government registers one too)
QBCoreMock.Player = {
    Login = function(src, cid, newData)
        logins[#logins + 1] = { src = src, newData = newData }
        Mock.newPlayer(src, cid or 'NEWCID')
        multicharLoaded(Mock.players[src])
        return true
    end,
}
function GetCurrentResourceName() return 'pfm-multicharacter' end
Config = nil
load_resource('pfm-apartments/config.lua')
load_resource('pfm-multicharacter/config.lua')
load_resource('pfm-multicharacter/server/main.lua')
multicharLoaded = Mock.eventHandlers['QBCore:Server:PlayerLoaded']
local multicharConfig = Config
Mock.exportsByResource['pfm-multicharacter'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil

-- pf-government
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government' }, police = { label = 'Police', grades = { ['0'] = { name = 'Cadet' } } } }
Config = nil
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/schema.lua', 'server/audit.lua', 'server/callbacks.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function DebugPrint() end
-- (one Lua state: the multicharacter code reads the shared Config at call time)
for _, k in ipairs({ 'DefaultNumberOfCharacters', 'PlayersNumberOfCharacters', 'SkipSelection', 'StarterItems' }) do
    if Config[k] == nil then Config[k] = multicharConfig[k] end
end
Mock.exportsByResource['__self'] = nil
assert(GovSchema.Ensure(), 'government migrations')

local MAYOR, CLERK, ONLINE = 1, 2, 3
local function nui(src, action, data)
    local before = #Mock.clientEvents
    Mock.fireNet('pf-government:server:nuiCallback', src, 'cb1', action, data or {})
    for i = #Mock.clientEvents, before + 1, -1 do
        local e = Mock.clientEvents[i]
        if e.name == 'pf-government:client:nuiCallback' then return e.args[2] end
    end
end
local function citizenRow(cid, charinfo)
    MySQL.query.await('DELETE FROM players WHERE citizenid = ?', { cid })
    MySQL.insert.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata)
        VALUES (?, 1, ?, 'x', '{}', ?, '{"name":"unemployed"}', '{}', '{}', '{}')]], { cid, 'license:' .. cid, json.encode(charinfo) })
end
local function charinfoOf(cid) return json.decode(MySQL.scalar.await('SELECT charinfo FROM players WHERE citizenid = ?', { cid })) end
local setData, saves, setJobs

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    logins = {}
    states['pfm-multicharacter'] = nil
    Mock.newPlayer(MAYOR, 'MAY1').PlayerData.job = { name = 'government', grade = { level = 4 }, onduty = true }
    Mock.newPlayer(CLERK, 'CLK1').PlayerData.job = { name = 'government', grade = { level = 1 }, onduty = true }
    citizenRow('OFF1', { firstname = 'Old', lastname = 'Name', birthdate = '1990-01-01', nationality = 'Legacy <value>', phone = '5551000' })
    citizenRow('TAKEN1', { firstname = 'Has', lastname = 'Phone', birthdate = '1980-01-01', phone = '5552222' })
    local on = Mock.newPlayer(ONLINE, 'ON1')
    on.PlayerData.charinfo = { firstname = 'Live', lastname = 'Person', birthdate = '1995-05-05', phone = '5553333' }
    setData, saves, setJobs = {}, 0, {}
    on.Functions.SetPlayerData = function(key, value) setData[#setData + 1] = { key = key, value = value } on.PlayerData[key] = value end
    on.Functions.Save = function() saves = saves + 1 end
    on.Functions.SetJob = function(name, grade) setJobs[#setJobs + 1] = { name = name, grade = grade } return true end
    citizenRow('ON1', { firstname = 'Stale', lastname = 'Row', birthdate = '1995-05-05', phone = '5553333' })
end

describe('GOV-ID-1: identity fields follow the character creation rules', function()
    it('refuses markup, control characters, overlong names and impossible dates, with the field named', function()
        local cases = {
            { { firstname = '<img src=x onerror=alert(1)>' }, 'invalid_firstname' },
            { { lastname = string.rep('a', 33) }, 'invalid_lastname' },
            { { lastname = 'Ro\nss' }, 'invalid_lastname' },
            { { dob = '1990-13-01' }, 'invalid_birthdate' },
            { { dob = '2001-02-29' }, 'invalid_birthdate' },
            { { dob = '01/02/1990' }, 'invalid_birthdate' },
            { { nationality = 'A"B' }, 'invalid_nationality' },
            { { firstname = { 'x' } }, 'invalid_firstname' },
        }
        for _, c in ipairs(cases) do
            local data = c[1]
            data.citizenId = 'OFF1'
            assert_eq(nui(MAYOR, 'civilian:updateIdentity', data).error, c[2], json.encode(data))
        end
        local ci = charinfoOf('OFF1')
        assert_eq(ci.firstname, 'Old', 'nothing written')
        assert_eq(ci.lastname, 'Name')
    end)
    it('writes a valid correction of an offline citizen; an old value it does not change does not block it', function()
        local res = nui(MAYOR, 'civilian:updateIdentity', { citizenId = 'OFF1', firstname = "Seán", lastname = "O'Brien-Smith", dob = '2000-02-29',
            nationality = 'Legacy <value>', phone = '5551000' })
        assert_true(res.ok, tostring(res.error))
        local ci = charinfoOf('OFF1')
        assert_eq(ci.firstname, 'Seán')
        assert_eq(ci.lastname, "O'Brien-Smith")
        assert_eq(ci.birthdate, '2000-02-29')
        assert_eq(ci.nationality, 'Legacy <value>', 'unchanged, so not re-checked')
        assert_eq(#res.changed, 3)
    end)
    it('refuses a phone number another citizen has (online or not) and one that is not a number', function()
        assert_eq(nui(MAYOR, 'civilian:updateIdentity', { citizenId = 'OFF1', phone = '5552222' }).error, 'phone_taken')
        assert_eq(nui(MAYOR, 'civilian:updateIdentity', { citizenId = 'OFF1', phone = '5553333' }).error, 'phone_taken', 'an online player')
        assert_eq(nui(MAYOR, 'civilian:updateIdentity', { citizenId = 'OFF1', phone = '<b>12' }).error, 'invalid_phone')
        assert_eq(nui(MAYOR, 'civilian:updateIdentity', { citizenId = 'OFF1', phone = '12' }).error, 'invalid_phone')
        assert_eq(charinfoOf('OFF1').phone, '5551000')
        assert_true(nui(MAYOR, 'civilian:updateIdentity', { citizenId = 'OFF1', phone = '555 9999' }).ok)
        assert_eq(charinfoOf('OFF1').phone, '5559999')
    end)
    it('without the creation rules running nothing is changed', function()
        states['pfm-multicharacter'] = 'stopped'
        assert_eq(nui(MAYOR, 'civilian:updateIdentity', { citizenId = 'OFF1', firstname = 'New' }).error, 'identity_rules_unavailable')
        assert_eq(charinfoOf('OFF1').firstname, 'Old')
    end)
    it('a clerk may not correct identities', function()
        assert_eq(nui(CLERK, 'civilian:updateIdentity', { citizenId = 'OFF1', firstname = 'New' }).error, 'no_permission')
    end)
end)

describe('X10: an online citizen is changed on their live character', function()
    it('identity: the live charinfo is set and saved (the database row is left to that save)', function()
        local res = nui(MAYOR, 'civilian:updateIdentity', { citizenId = 'ON1', firstname = 'Fixed', lastname = 'Person', dob = '1995-05-05', phone = '5553333' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(#setData, 1)
        assert_eq(setData[1].key, 'charinfo')
        assert_eq(setData[1].value.firstname, 'Fixed')
        assert_eq(setData[1].value.phone, '5553333', 'the other fields kept')
        assert_eq(saves, 1)
        assert_eq(charinfoOf('ON1').firstname, 'Stale', 'not a database-only edit the next save would undo')
    end)
    it('job: the live character gets the job at grade 0', function()
        assert_true(nui(MAYOR, 'civilian:updateJob', { citizenId = 'ON1', jobName = 'police' }).ok)
        assert_eq(#setJobs, 1)
        assert_eq(setJobs[1].name, 'police')
        assert_eq(setJobs[1].grade, 0)
        assert_eq(nui(MAYOR, 'civilian:updateJob', { citizenId = 'ON1', jobName = 'nojob' }).error, 'invalid_job')
        assert_true(nui(MAYOR, 'civilian:updateJob', { citizenId = 'OFF1', jobName = 'police' }).ok)
        assert_eq(json.decode(MySQL.scalar.await("SELECT job FROM players WHERE citizenid = 'OFF1'")).name, 'police')
    end)
end)

describe('character creation uses the same rules', function()
    local function create(src, data)
        data.cid = 1
        Mock.fireNet('qb-multicharacter:server:createCharacter', src, data)
    end
    it('a name with markup is refused at creation too; a real country name is kept', function()
        create(10, { firstname = '<script>x</script>', lastname = 'Rhodes', birthdate = '1990-01-01', nationality = 'USA', gender = 1 })
        assert_eq(#logins, 0)
        create(11, { firstname = 'Lana', lastname = 'Rhodes', birthdate = '1990-01-01', nationality = 'United Kingdom of Great Britain and Northern Ireland', gender = 1 })
        assert_eq(#logins, 1)
        assert_eq(logins[1].newData.charinfo.nationality, 'United Kingdom of Great Britain and Northern Ireland')
        create(12, { firstname = 'Ana', lastname = 'Lee', birthdate = '1990-02-30', nationality = 'USA', gender = 0 })
        assert_eq(#logins, 1, 'an impossible birthdate')
    end)
end)
