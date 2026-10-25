-- pfm-management boss and gang menus: employee list SQL, and hire / fire / grade only inside the
-- boss's own job or gang.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.Functions.GetIdentifier = function(src, kind) return kind .. ':' .. tostring(src) end
local offline = {}
QBCoreMock.Functions.GetOfflinePlayerByCitizenId = function(cid) return offline[cid] end

local queries = {}
MySQL.query = setmetatable({ await = function(sql, params)
    queries[#queries + 1] = { sql = sql, params = params }
    return {}
end }, { __call = function() return {} end })

Config = nil
load_resource('pfm-management/config.lua')
load_resource('pfm-management/server/sv_boss.lua')
load_resource('pfm-management/server/sv_gang.lua')

local BOSS, WORKER, OUTSIDER, OTHERBOSS = 1, 2, 3, 4

local function member(src, cid, job, level, isboss, gang)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, label = job, isboss = isboss, grade = { level = level, name = 'g' .. level } }
    p.PlayerData.gang = gang or { name = 'none', isboss = false, grade = { level = 0 } }
    p.Functions.SetJob = function(name, grade)
        p.PlayerData.job = { name = name, label = name, grade = { level = tonumber(grade), name = 'g' .. tostring(grade) } }
        return true
    end
    p.Functions.SetGang = function(name, grade)
        p.PlayerData.gang = { name = name, label = name, grade = { level = tonumber(grade), name = 'g' .. tostring(grade) } }
        return true
    end
    p.Functions.Save = function() end
    return p
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.dropped = {}, {}, {}
    queries, offline = {}, {}
    member(BOSS, 'BOSSCID', 'mechanic', 4, true, { name = 'ballas', isboss = true, grade = { level = 4 } })
    member(WORKER, 'WORKCID', 'mechanic', 1, false, { name = 'ballas', isboss = false, grade = { level = 1 } })
    member(OUTSIDER, 'OUTCID', 'police', 1, false, { name = 'vagos', isboss = false, grade = { level = 1 } })
    member(OTHERBOSS, 'POLBOSS', 'police', 4, true)
end

describe('employee list', function()
    it('uses the boss own job as a bound parameter, whatever the client sends', function()
        Mock.callCallback('qb-bossmenu:server:GetEmployees', BOSS, "x' OR 1=1 -- ")
        assert_eq(#queries, 1)
        assert_true(not queries[1].sql:find("OR 1=1", 1, true))
        assert_eq(queries[1].params[1], '%mechanic%')
        Mock.callCallback('qb-gangmenu:server:GetEmployees', BOSS, "x' OR 1=1 -- ")
        assert_eq(queries[2].params[1], '%ballas%')
    end)
end)

describe('boss menu', function()
    it('cannot fire someone from another job', function()
        Mock.fireNet('qb-bossmenu:server:FireEmployee', BOSS, 'OUTCID')
        assert_eq(Mock.players[OUTSIDER].PlayerData.job.name, 'police')
        Mock.fireNet('qb-bossmenu:server:FireEmployee', BOSS, 'POLBOSS')
        assert_eq(Mock.players[OTHERBOSS].PlayerData.job.name, 'police')
    end)
    it('fires its own employee', function()
        Mock.fireNet('qb-bossmenu:server:FireEmployee', BOSS, 'WORKCID')
        assert_eq(Mock.players[WORKER].PlayerData.job.name, 'unemployed')
    end)
    it('cannot set the grade of someone outside the job (pulling them into it)', function()
        Mock.fireNet('qb-bossmenu:server:GradeUpdate', BOSS, { cid = 'OUTCID', grade = 3, gradename = 'x' })
        assert_eq(Mock.players[OUTSIDER].PlayerData.job.name, 'police')
        Mock.fireNet('qb-bossmenu:server:GradeUpdate', BOSS, { cid = 'WORKCID', grade = 3, gradename = 'x' })
        assert_eq(Mock.players[WORKER].PlayerData.job.grade.level, 3)
        Mock.fireNet('qb-bossmenu:server:GradeUpdate', BOSS, { cid = 'WORKCID', grade = 'abc' })
        Mock.fireNet('qb-bossmenu:server:GradeUpdate', BOSS, 'junk')
        assert_eq(Mock.players[WORKER].PlayerData.job.grade.level, 3)
    end)
    it('hires only someone standing near the boss', function()
        Mock.coords[OUTSIDER] = vector3(500, 0, 0)
        Mock.fireNet('qb-bossmenu:server:HireEmployee', BOSS, OUTSIDER)
        assert_eq(Mock.players[OUTSIDER].PlayerData.job.name, 'police')
        Mock.coords[OUTSIDER] = vector3(3, 0, 0)
        Mock.fireNet('qb-bossmenu:server:HireEmployee', BOSS, OUTSIDER)
        assert_eq(Mock.players[OUTSIDER].PlayerData.job.name, 'mechanic')
    end)
end)

describe('gang menu', function()
    it('cannot expel or rank members of another gang', function()
        Mock.fireNet('qb-gangmenu:server:FireMember', BOSS, 'OUTCID')
        assert_eq(Mock.players[OUTSIDER].PlayerData.gang.name, 'vagos')
        Mock.fireNet('qb-gangmenu:server:GradeUpdate', BOSS, { cid = 'OUTCID', grade = 2 })
        assert_eq(Mock.players[OUTSIDER].PlayerData.gang.name, 'vagos')
        Mock.coords[OUTSIDER] = vector3(500, 0, 0)
        Mock.fireNet('qb-gangmenu:server:HireMember', BOSS, OUTSIDER)
        assert_eq(Mock.players[OUTSIDER].PlayerData.gang.name, 'vagos')
    end)
    it('expels its own member', function()
        Mock.fireNet('qb-gangmenu:server:FireMember', BOSS, 'WORKCID')
        assert_eq(Mock.players[WORKER].PlayerData.gang.name, 'none')
    end)
end)
