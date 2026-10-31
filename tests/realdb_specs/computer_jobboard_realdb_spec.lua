-- pf-computer on a real database: the one-time import of data/pc_data.json, the tables the apps
-- read and write, the Job Board (post, apply as yourself, hire with consent or at next login,
-- reject, close) and the Business Manager's staff and figures from real records.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
local states = { ['pf-mechanicjob'] = 'missing', ['pf-restaurants'] = 'missing', ['pf-stores'] = 'missing', ['pf-services'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
function GetCurrentResourceName() return 'pfm-banking' end
function SaveResourceFile() return true end
function RegisterCommand() end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
MySQL.query.await([[CREATE TABLE IF NOT EXISTS `pf_gov_business_revenue` (
    `id` INT NOT NULL AUTO_INCREMENT, `event_key` VARCHAR(100) NOT NULL, `business_id` VARCHAR(100) NOT NULL,
    `amount` DECIMAL(15,2) NOT NULL, `tax` DECIMAL(15,2) NOT NULL DEFAULT 0, `tax_state` VARCHAR(16) NOT NULL DEFAULT 'none',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (`id`), UNIQUE KEY `uq_event` (`event_key`)) ENGINE=InnoDB]])

local merged = {}
local function loadConfig(path)
    Config = nil
    load_resource(path)
    for k, v in pairs(Config or {}) do if merged[k] == nil then merged[k] = v end end
end
loadConfig('pfm-banking/config.lua')
loadConfig('[pfscripts]/pf-computer/config/config.lua')
Config = merged

QBCoreMock.Shared.Jobs = {
    mechanic = { label = 'LS Customs', grades = {
        ['0'] = { name = 'Recruit', payment = 50 }, ['1'] = { name = 'Mechanic', payment = 75 },
        ['2'] = { name = 'Senior', payment = 100 }, ['3'] = { name = 'Lead', payment = 125 },
        ['4'] = { name = 'Owner', isboss = true, payment = 150 } } },
    trucker = { label = 'Trucker', grades = { ['0'] = { name = 'Driver', payment = 50 } } },
    unemployed = { label = 'Civilian', grades = { ['0'] = { name = 'Freelancer', payment = 10 } } },
}

load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, m) return RunMigrations(res, m) end
Mock.exportsByResource['pfm-core'].UpdateJob = function(_, job, def) QBCoreMock.Shared.Jobs[job] = def return true end
local L = PFLedger
assert(L.Start(), 'ledger start')

-- the old data file, as it was on the server
local seed = {
    businesses = { mechanic = { settings = { name = 'Old Shop', blipColor = 2 }, stashLocations = { { x = 1.0, y = 2.0, z = 3.0 } } } },
    businessMenus = { burgershot = { { id = 5, name = 'Burger', price = 10 } } },
    businessMeals = { burgershot = { { id = 2, name = 'Combo', price = 20, items = {} } } },
    businessWages = { mechanic = { ['1'] = 90 } },
    wageCaps = { ['1'] = 150 },
    businessBlips = { mechanic = { name = 'Old Shop', coords = { x = 1.0, y = 2.0, z = 3.0 }, sprite = 446 } },
    businessDeliveryLocations = { mechanic = { x = 10.0, y = 20.0, z = 30.0, w = 0.0 } },
    browserDomains = { { domain = 'old.ls', ownerIdentifier = 'OLD1', ownerName = 'Old Owner', templateId = 'services' } },
    browserWebsites = { ['old.ls'] = { branding = { siteName = 'Old' }, owner = { identifier = 'OLD1', name = 'Old Owner' } } },
    chatRooms = { market = { messages = { { id = 1, author = 'someone', message = 'hello' } } } },
    jobPosts = { { id = 1, title = 'test', company = 'test', creatorIdentifier = 'OLD1' } },
    jobApplications = { { id = 1, jobId = 1, name = 'test' } },
    emails = { { id = 1, mailbox = 'admin@los-santos.gov', subject = 'x' } },
}
local seedJson = json.encode(seed)
function LoadResourceFile(_, path) if path == 'data/pc_data.json' then return seedJson end return nil end

local mails = {}
Mock.exportsByResource['pf-citizen'] = {
    SendMail = function(_, cid, mail) mails[#mails + 1] = { cid = cid, mail = mail } return true end,
}

local function loadComputer()
    function GetCurrentResourceName() return 'pf-computer' end
    load_resource('[pfscripts]/pf-computer/server/main.lua')
    load_resource('[pfscripts]/pf-computer/server/jobboard.lua')
    Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
end
loadComputer()

local BOSS, APPLICANT, OTHER, OWNER = 1, 2, 3, 4
local function setJob(p, name, grade)
    local j = QBCoreMock.Shared.Jobs[name]
    local g = j and j.grades[tostring(grade)]
    if not g then return false end
    p.PlayerData.job = { name = name, label = j.label, grade = { level = tonumber(grade), name = g.name }, isboss = g.isboss == true, onduty = true }
    return true
end
local function player(src, cid, job, grade, first)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.charinfo = { firstname = first, lastname = 'Test', phone = '555' .. src }
    p.Functions.SetJob = function(name, gr) return setJob(p, name, gr) end
    p.Functions.Save = function() end
    setJob(p, job, grade)
    return p
end
local function call(src, action, payload)
    Mock.clientEvents = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.fireNet('pf-computer:server:callback', src, 7, action, payload or {})
    local ev = Mock.clientEventsNamed('pf-computer:client:callback')[1]
    return ev and ev.args[2]
end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players = {}
    mails = {}
    player(BOSS, 'BOSS1', 'mechanic', 4, 'Bea')
    player(APPLICANT, 'APP1', 'unemployed', 0, 'Abe')
    player(OTHER, 'OTH1', 'mechanic', 1, 'Otto')
    player(OWNER, 'OWN1', 'unemployed', 0, 'Olga')
end

describe('pf-computer storage: data/pc_data.json imported once', function()
    it('nothing is written before the tables are loaded', function()
        assert_eq(PFComputerStorage.Mode(), 'starting')
        Mock.coords[BOSS] = vector3(1.0, 2.0, 3.0)
        assert_eq(call(BOSS, 'business:stash:place', { coords = { x = 1.0, y = 2.0, z = 3.0 } }).error, 'storage_starting')
    end)
    it('the first start imports the file into the tables and loads them', function()
        assert_true(PFComputerStorage.Init())
        assert_eq(PFComputerStorage.Mode(), 'ready')
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-computer' AND version = 2 AND name LIKE 'import%'"), 1)
        local profile = json.decode(MySQL.scalar.await("SELECT profile FROM pf_computer_businesses WHERE business_id = 'mechanic'"))
        assert_eq(profile.settings.name, 'Old Shop')
        assert_eq(#profile.stashLocations, 1)
        assert_eq(profile.delivery.x, 10.0)
        assert_eq(count("SELECT cap FROM pf_computer_wage_caps WHERE grade = '1'"), 150)
        assert_eq(MySQL.scalar.await("SELECT owner_cid FROM pf_computer_domains WHERE domain = 'old.ls'"), 'OLD1')
        assert_eq(count('SELECT COUNT(*) FROM pf_computer_chat'), 1)
        assert_eq(MySQL.scalar.await('SELECT status FROM pf_computer_job_posts WHERE id = 1'), 'closed', 'old free-text posts are kept, closed')
        assert_eq(count('SELECT COUNT(*) FROM pf_computer_job_applications'), 1)
        -- what the apps see
        local stashes = call(BOSS, 'business:stashes:getAll').data
        assert_eq(#stashes.mechanic, 1)
        local domains = call(APPLICANT, 'browser:domains:list').data
        assert_eq(domains[1].domain, 'old.ls')
        assert_eq(domains[1].ownerIdentifier, nil, 'no citizen ids for other players')
        local site = call(APPLICANT, 'browser:website:get', { domain = 'old.ls' }).data
        assert_eq(site.state.owner.identifier, nil)
    end)
    it('changes go to the tables', function()
        Mock.coords[BOSS] = vector3(5.0, 5.0, 5.0)
        assert_true(call(BOSS, 'business:stash:place', { coords = { x = 5.0, y = 5.0, z = 5.0 } }).ok)
        local profile = json.decode(MySQL.scalar.await("SELECT profile FROM pf_computer_businesses WHERE business_id = 'mechanic'"))
        assert_eq(#profile.stashLocations, 2)
        assert_true(call(BOSS, 'business:wages:set', { wages = { ['1'] = 120 } }).ok)
        assert_eq(json.decode(MySQL.scalar.await("SELECT wages FROM pf_computer_businesses WHERE business_id = 'mechanic'"))['1'], 120)
        assert_eq(QBCoreMock.Shared.Jobs.mechanic.grades['1'].payment, 120, 'the paycheck pays the boss-set wage')
        assert_eq(call(BOSS, 'business:wages:set', { wages = { ['1'] = 151 } }).error, 'cap_exceeded')
    end)
    it('a restart loads the tables and never imports the file again', function()
        seed.browserDomains[2] = { domain = 'second.ls', ownerIdentifier = 'OLD2', ownerName = 'Second' }
        seedJson = json.encode(seed)
        loadComputer()   -- a fresh start of the resource
        assert_true(PFComputerStorage.Init())
        assert_eq(count("SELECT COUNT(*) FROM pf_computer_domains WHERE domain = 'second.ls'"), 0)
        assert_eq(MySQL.scalar.await("SELECT v FROM pf_computer_meta WHERE k = 'legacy_import'"), '{"v":"done"}')
        assert_eq(#call(BOSS, 'business:stashes:getAll').data.mechanic, 2, 'the stash placed before the restart is back')
        local domains = call(APPLICANT, 'browser:domains:list').data
        assert_eq(#domains, 1)
    end)
end)

describe('pf-computer Job Board', function()
    local post
    it('only a business boss posts, for their own business', function()
        assert_eq(call(APPLICANT, 'jobs:create', { title = 'Mechanic' }).error, 'not_business_manager')
        assert_eq(call(OTHER, 'jobs:create', { title = 'Mechanic' }).error, 'not_business_manager', 'an employee is not the boss')
        local res = call(BOSS, 'jobs:create', { title = 'Mechanic', company = 'Fake Corp', salary = '$80/h', tags = { 'cars' } })
        assert_true(res.ok)
        post = res.data
        assert_eq(post.company, 'LS Customs', 'the business is the boss\'s job, not typed in')
        assert_eq(MySQL.scalar.await('SELECT poster_cid FROM pf_computer_job_posts WHERE id = ?', { post.id }), 'BOSS1')
        local list = call(APPLICANT, 'jobs:list').data
        assert_eq(list[1].id, post.id)
    end)
    it('applicants apply as themselves, once, and the boss is mailed', function()
        local res = call(APPLICANT, 'jobs:apply', { jobId = post.id, name = 'Somebody Else', phone = '000', message = 'Hire me' })
        assert_true(res.ok)
        local row = MySQL.single.await('SELECT applicant_cid, applicant_name, applicant_phone FROM pf_computer_job_applications WHERE id = ?', { res.data.id })
        assert_eq(row.applicant_cid, 'APP1')
        assert_eq(row.applicant_name, 'Abe Test')
        assert_eq(row.applicant_phone, '5552')
        assert_eq(call(APPLICANT, 'jobs:apply', { jobId = post.id }).error, 'already_applied')
        assert_eq(call(BOSS, 'jobs:apply', { jobId = post.id }).error, 'own_business')
        assert_eq(mails[1].cid, 'BOSS1')
        assert_eq(call(APPLICANT, 'jobs:getApplicants', { jobId = post.id }).error, 'not_authorized')
    end)
    it('the boss hires an online applicant: an offer the applicant accepts, never above the boss\'s rank', function()
        local apps = call(BOSS, 'jobs:getApplicants', { jobId = post.id }).data
        local appId = apps[1].id
        assert_eq(apps[1].name, 'Abe Test')
        assert_eq(call(BOSS, 'jobs:hire', { applicationId = appId, grade = 9 }).error, 'invalid_grade')
        local res = call(BOSS, 'jobs:hire', { applicationId = appId, grade = 1 })
        assert_true(res.ok)
        assert_eq(res.data.status, 'offered')
        assert_eq(Mock.players[APPLICANT].PlayerData.job.name, 'unemployed', 'nothing changes without consent')
        assert_eq(call(OTHER, 'jobs:respond', { applicationId = appId, accept = true }).error, 'application_not_found')
        local accepted = call(APPLICANT, 'jobs:respond', { applicationId = appId, accept = true })
        assert_true(accepted.ok)
        assert_eq(Mock.players[APPLICANT].PlayerData.job.name, 'mechanic')
        assert_eq(Mock.players[APPLICANT].PlayerData.job.grade.level, 1)
        assert_eq(call(APPLICANT, 'jobs:respond', { applicationId = appId, accept = true }).error, 'no_offer', 'once')
    end)
    it('an offline applicant is hired at their next login; rejected applicants are told', function()
        local res = call(OWNER, 'jobs:apply', { jobId = post.id })
        assert_true(res.ok)
        Mock.players[OWNER] = nil   -- logs off
        local hired = call(BOSS, 'jobs:hire', { applicationId = res.data.id, grade = 0 })
        assert_eq(hired.data.status, 'hire_pending')
        local back = player(OWNER, 'OWN1', 'unemployed', 0, 'Olga')
        PFComputerJobBoardLogin(OWNER)
        assert_eq(back.PlayerData.job.name, 'mechanic')
        assert_eq(MySQL.scalar.await('SELECT status FROM pf_computer_job_applications WHERE id = ?', { res.data.id }), 'hired')
        -- a third applicant is rejected and mailed
        player(9, 'NEW9', 'unemployed', 0, 'Nina')
        local third = call(9, 'jobs:apply', { jobId = post.id })
        mails = {}
        assert_eq(call(OTHER, 'jobs:reject', { applicationId = third.data.id }).error, 'not_authorized')
        assert_true(call(BOSS, 'jobs:reject', { applicationId = third.data.id }).ok)
        assert_eq(mails[1].cid, 'NEW9')
    end)
    it('the boss closes the post; it leaves the board', function()
        assert_eq(call(OTHER, 'jobs:close', { jobId = post.id }).error, 'not_authorized')
        assert_true(call(BOSS, 'jobs:close', { jobId = post.id }).ok)
        assert_eq(#call(APPLICANT, 'jobs:list').data, 0)
        assert_eq(call(OWNER, 'jobs:apply', { jobId = post.id }).error, 'job_not_found')
    end)
    it('a registry owner posts for their business; the city job list says what is open for hire', function()
        MySQL.query.await("INSERT INTO pf_gov_businesses (business_id, business_name, business_type, owner_id, owner_name) VALUES ('store:corner', 'Corner Store', 'store', 'OWN1', 'Olga')")
        Mock.players[OWNER].PlayerData.job = { name = 'unemployed', grade = { level = 0 }, isboss = false }
        local res = call(OWNER, 'jobs:create', { business = 'gov:store:corner', title = 'Cashier' })
        assert_true(res.ok)
        assert_eq(res.data.company, 'Corner Store')
        assert_false(res.data.hires, 'a store has no job to give: applicants are accepted, not hired')
        local catalog = call(APPLICANT, 'jobs:catalog').data
        local byJob = {}
        for _, j in ipairs(catalog) do byJob[j.job] = j end
        assert_true(byJob.trucker.jobCentre and byJob.trucker.openForHire)
        assert_false(byJob.mechanic.openForHire, 'the mechanic post was closed')
    end)
end)

describe('pf-computer Business Manager from real records', function()
    it('staff are the characters with the job (offline too), promoted and fired like the boss menu', function()
        MySQL.query.await([[INSERT INTO players (citizenid, license, name, money, charinfo, job, position, metadata)
            VALUES ('OFF1', 'l', 'x', '{}', '{"firstname":"Ofelia","lastname":"Line"}', '{"name":"mechanic","grade":{"level":2,"name":"Senior"}}', '{}', '{}')]])
        local res = call(BOSS, 'business:employees:list')
        assert_true(res.ok)
        local names = {}
        for _, e in ipairs(res.data) do names[e.name] = e end
        assert_true(names['Ofelia Line'] ~= nil, 'offline staff from the players table')
        assert_false(names['Ofelia Line'].online)
        assert_true(names['Otto Test'].online)
        assert_eq(names['Otto Test'].performance, nil, 'no invented score')
        assert_eq(call(OTHER, 'business:employees:update', { employeeId = 'BOSS1', grade = 0 }).error, 'not_authorized')
        assert_eq(call(BOSS, 'business:employees:update', { employeeId = 'OTH1', grade = 2 }).ok, true)
        assert_eq(Mock.players[OTHER].PlayerData.job.grade.level, 2)
        assert_eq(call(BOSS, 'business:employees:update', { employeeId = 'OTH1', grade = 9 }).error, 'invalid_grade')
        assert_eq(call(BOSS, 'business:employees:fire', { employeeId = 'BOSS1' }).error, 'cannot_fire_self')
        assert_true(call(BOSS, 'business:employees:fire', { employeeId = 'OTH1' }).ok)
        assert_eq(Mock.players[OTHER].PlayerData.job.name, 'unemployed')
    end)
    it('figures come from the ledger and the sale reports, nothing estimated', function()
        assert(L.EnsureSociety('mechanic', 'job'))
        assert(L.Transfer({ from = 'system:test', to = 'society:mechanic', amount = 300, key = 'pc-t-sale-1', kind = 'sale', reason = 'Repair' }).ok)
        assert(L.Transfer({ from = 'society:mechanic', to = 'system:test', amount = 40, key = 'pc-t-buy-1', kind = 'purchase', reason = 'Parts' }).ok)
        MySQL.query.await("INSERT INTO pf_gov_business_revenue (event_key, business_id, amount, tax) VALUES ('r1', 'mechanic:mechanic', 300, 15)")
        local a = call(BOSS, 'business:analytics', { period = 'week' })
        assert_true(a.ok)
        assert_eq(a.data.totalSales, 1)
        assert_eq(a.data.totalRevenue, 300)
        assert_eq(a.data.moneyIn, 300)
        assert_eq(a.data.moneyOut, 40)
        assert_eq(a.data.topItems, nil, 'no placeholder items')
        local d = call(BOSS, 'business:getData')
        assert_eq(d.data.stats.today.revenue, 300)
        local tx = call(BOSS, 'business:transactions:list')
        assert_eq(#tx.data, 2)
        assert_eq(tx.data[1].type, 'purchase')
    end)
end)
