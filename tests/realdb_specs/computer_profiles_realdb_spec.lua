-- pf-computer's per-character state on a real database (server/profiles.lua, migration 3): the lock
-- screen (PIN stored as a salted hash, checked and counted on the server, surviving a restart) and the
-- desktop layout of each character on each computer; and the clean-up when a character is deleted
-- (server/characters.lua).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
local started = { ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-computer' end
function LoadResourceFile() return nil end
function SaveResourceFile() return true end
function RegisterCommand() end

RealDB.exec('pfm-core/qbcore.sql')
Config = nil
load_resource('[pfscripts]/pf-computer/config/config.lua')
load_resource('[pfscripts]/pf-computer/config/config_hack.lua')
load_resource('[pfscripts]/pf-computer/config/config_dark.lua')
QBCoreMock.Shared.Jobs = { unemployed = { label = 'Civilian', grades = { ['0'] = { name = 'Freelancer', payment = 10 } } } }
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, m) return RunMigrations(res, m) end

local function loadComputer()
    for _, f in ipairs({ 'main', 'jobboard', 'profiles', 'characters' }) do
        load_resource('[pfscripts]/pf-computer/server/' .. f .. '.lua')
    end
    assert(PFComputerStorage.Init(), 'computer storage')
end
loadComputer()

local ME, OTHER = 1, 2
local SCOPE = 'profile:default:model:-1234:pos:10.5,20,30'
local function call(src, action, payload)
    payload = payload or {}
    payload.scope = payload.scope or SCOPE
    return PFComputer.dispatch(action, payload, src)
end
local function row(cid, scope)
    return MySQL.single.await('SELECT layout, security FROM pf_computer_profiles WHERE citizenid = ? AND scope = ?', { cid, scope or SCOPE })
end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params or {})) or 0 end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(ME, 'PIN1')
    Mock.newPlayer(OTHER, 'PIN2')
end

describe('the lock screen on the server', function()
    it('migration 3 makes the table', function()
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-computer' AND version = 3"), 1)
        assert_eq(count("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'pf_computer_profiles'"), 1)
    end)

    it('stores the PIN only as a salted hash', function()
        local res = call(ME, 'security:lock:settings', { enabled = true, method = 'pin', pin = '2468', lockWallpaper = 'https://i.example/w.png' })
        assert_true(res.ok, tostring(res.error))
        local r = row('PIN1')
        assert_true(r ~= nil)
        assert_eq(r.security:find('2468', 1, true), nil, 'the PIN is not in the database')
        local sec = json.decode(r.security)
        assert_eq(#sec.pin, 64)
        assert_eq(sec.pin, PFComputer.sha256(sec.salt .. ':2468'))
        assert_eq(call(ME, 'security:lock:settings', { lockWallpaper = "https://x/'); alert(1)" }).error, 'bad_wallpaper')
    end)

    it('a lock survives a restart; wrong tries are counted in the database', function()
        assert_true(call(ME, 'security:lock:lock').security.locked)
        loadComputer()   -- the resource restarts
        assert_true(call(ME, 'security:lock:state').security.locked)
        local wrong = call(ME, 'security:lock:unlock', { secret = '0000' })
        assert_eq(wrong.error, 'wrong_secret')
        assert_eq(json.decode(row('PIN1').security).fails, 1)
        loadComputer()
        assert_eq(call(ME, 'security:lock:unlock', { secret = '2468' }).error, 'timeout', 'a restart does not clear the timeout')
        Mock.clock = Mock.clock + 11
        local ok = call(ME, 'security:lock:unlock', { secret = '2468' })
        assert_true(ok.ok)
        assert_false(json.decode(row('PIN1').security).locked)
        assert_false(call(OTHER, 'security:lock:state').security.enabled, 'another character on the same computer is not affected')
    end)
end)

describe('the desktop layout on the server', function()
    it('is saved per character and computer and comes back after a restart', function()
        local items = { { id = 'browser', app = 'browser', type = 'app', location = 'desktop', position = { x = 2, y = 1 } },
            { id = 'pfapp-jobboard', app = 'pfapp-jobboard', type = 'app', location = 'desktop', position = { x = 0, y = 4 } } }
        assert_true(call(ME, 'profile:layout:save', { items = items, folders = { { id = 'folder_1', name = 'Work', location = 'desktop', position = { x = 5, y = 5 } } } }).ok)
        loadComputer()
        local got = call(ME, 'profile:get')
        assert_eq(#got.layout.items, 2)
        assert_eq(got.layout.items[2].id, 'pfapp-jobboard')
        assert_eq(got.layout.folders[1].name, 'Work')
        assert_true(got.security.enabled, 'the lock settings come along')
        assert_eq(call(ME, 'profile:get', { scope = 'other-computer' }).layout, nil, 'another computer has its own layout')
        assert_eq(call(OTHER, 'profile:get').layout, nil)
    end)

    it('remembers at most 30 computers per character, forgetting the longest unused', function()
        for i = 1, 30 do
            MySQL.query.await('INSERT INTO pf_computer_profiles (citizenid, scope, layout, updated_at) VALUES (?, ?, NULL, NOW() - INTERVAL ? MINUTE)', { 'PIN2', 'pc-' .. i, 100 - i })
        end
        assert_true(call(OTHER, 'profile:layout:save', { scope = 'pc-new', items = {} }).ok)
        assert_eq(count("SELECT COUNT(*) FROM pf_computer_profiles WHERE citizenid = 'PIN2'"), 30)
        assert_eq(row('PIN2', 'pc-1'), nil, 'the oldest is gone')
        assert_true(row('PIN2', 'pc-new') ~= nil)
    end)
end)

describe('a deleted character', function()
    it('loses their private computer data; their posts stay without the link', function()
        local now = os.time()
        local postId = MySQL.insert.await([[INSERT INTO pf_computer_job_posts (business_kind, business_id, business_name, title, poster_cid, poster_name, status, created_at)
            VALUES ('job', 'mechanic', 'LS Customs', 'Mechanic', 'PIN1', 'Me', 'open', ?)]], { now })
        local otherPost = MySQL.insert.await([[INSERT INTO pf_computer_job_posts (business_kind, business_id, business_name, title, poster_cid, poster_name, status, created_at)
            VALUES ('job', 'taxi', 'Taxi', 'Driver', 'PIN2', 'Other', 'open', ?)]], { now })
        MySQL.insert.await("INSERT INTO pf_computer_job_applications (post_id, applicant_cid, applicant_name, status, created_at) VALUES (?, 'PIN1', 'Me', 'pending', ?)", { otherPost, now })
        MySQL.insert.await("INSERT INTO pf_computer_job_applications (post_id, applicant_cid, applicant_name, status, decided_by, created_at) VALUES (?, 'PIN2', 'Other', 'rejected', 'PIN1', ?)", { postId, now })
        MySQL.query.await("INSERT INTO pf_computer_chat (id, room, handle, citizenid, message, created_at) VALUES (900, 'market', 'anon-1', 'PIN1', 'mine', 'x'), (901, 'market', 'anon-2', 'PIN2', 'theirs', 'x')")
        PFComputer.dataStore.pickupRuns['PIN1'] = { orderId = 3, businessId = 'mechanic', startedAt = now }
        PFComputer.persist('pickup', 'PIN1')

        TriggerEvent('pfm-core:server:characterDeleted', 'PIN1')

        assert_eq(count("SELECT COUNT(*) FROM pf_computer_profiles WHERE citizenid = 'PIN1'"), 0, 'lock screen and layouts')
        assert_eq(count("SELECT COUNT(*) FROM pf_computer_job_applications WHERE applicant_cid = 'PIN1'"), 0, 'their applications')
        assert_eq(count("SELECT COUNT(*) FROM pf_computer_job_applications WHERE decided_by = 'PIN1'"), 0, 'decisions no longer name them')
        assert_eq(count("SELECT COUNT(*) FROM pf_computer_job_applications WHERE applicant_cid = 'PIN2'"), 1, 'the other applicant keeps theirs')
        assert_eq(MySQL.scalar.await('SELECT poster_cid FROM pf_computer_job_posts WHERE id = ?', { postId }), 'deleted', 'the business keeps the post')
        assert_eq(MySQL.scalar.await('SELECT status FROM pf_computer_job_posts WHERE id = ?', { postId }), 'open')
        assert_eq(count("SELECT COUNT(*) FROM pf_computer_chat WHERE citizenid = 'PIN1'"), 0)
        assert_eq(count("SELECT COUNT(*) FROM pf_computer_chat WHERE citizenid = 'PIN2'"), 1)
        assert_eq(count("SELECT COUNT(*) FROM pf_computer_pickup_runs WHERE citizenid = 'PIN1'"), 0)
        assert_eq(count("SELECT COUNT(*) FROM pf_computer_profiles WHERE citizenid = 'PIN2'"), 30, 'other characters untouched')
    end)
end)
