-- pf-news on a real database with the real money ledger: migrations, City Desk articles from city
-- events (a burst of tax changes is ONE article), exactly once per event across a simulated restart
-- (including an event claimed just before a crash), the lead -> story -> review -> publish -> bonus
-- lifecycle, the view counter, search, and ads bought from a business account and refunded once.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end

-- the bank
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
QBCoreMock.Shared.Jobs = {
    reporter = { label = 'Reporter', grades = { ['0'] = { name = 'Journalist' }, ['1'] = { name = 'Reporter' }, ['2'] = { name = 'Senior' }, ['3'] = { name = 'Editor' } } },
    burgershot = { label = 'Burger Shot', grades = { ['0'] = { name = 'Cook' }, ['4'] = { name = 'Owner', isboss = true } } },
}
assert(PFLedger.Start(), 'ledger start')
local bankConfig = Config
-- the business registry pf-news reads for owners
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, resource, list) return RunMigrations(resource, list) end

-- pf-devices and pf-services stand-ins
local broadcasts, recentEvents = {}, {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end, RegisterAppHandlers = function() return true end,
    RegisterSite = function() return true end, RegisterSiteHandler = function() return true end,
    Broadcast = function(_, app, ev, p) broadcasts[#broadcasts + 1] = { app = app, event = ev, payload = p } return true end,
    PushToJob = function() return 0 end, PushToCitizen = function() return true end, Push = function() return true end,
    IsAppInstalled = function() return false end,
}
Mock.exportsByResource['pf-services'] = {
    GetEventKind = function(_, kind) return PFCatalog.Events[kind] end,
    GetRecentEvents = function() return recentEvents end,
}
Mock.exportsByResource['pfm-newsjob'] = { GetFieldStatus = function() return {} end }

--- Loads pf-news from scratch, as a (re)started resource: all in-memory state is new.
local function startNews()
    function GetCurrentResourceName() return 'pf-news' end
    Config = nil
    PFNews = nil
    load_resource('pfm-banking/payouts.lua')
    load_resource('[pfscripts]/pf-services/shared/catalog.lua')
    load_resource('[pfscripts]/pf-news/config.lua')
    for k, v in pairs(bankConfig) do if Config[k] == nil then Config[k] = v end end
    for _, f in ipairs({ 'util', 'schema', 'presets', 'articles', 'leads', 'auto', 'ads', 'pay', 'apps', 'main' }) do
        load_resource('[pfscripts]/pf-news/server/' .. f .. '.lua')
    end
    assert_true(PFNews.Start(), 'pf-news started')
end

local function scalar(sql, p) return MySQL.scalar.await(sql, p or {}) end
local function n(sql, p) return tonumber(scalar(sql, p)) or 0 end
local function society(name) return n('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name }) end
local function fund(name, amount)
    MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES (?, ?, 'job', '[]') ON DUPLICATE KEY UPDATE account_balance = VALUES(account_balance)", { name, amount })
    MySQL.query.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, ?)', { 'society:' .. name, amount })
    if BankingAccounts then BankingAccounts[name] = nil end
end
local function txState(key) return scalar('SELECT state FROM pf_transactions WHERE idempotency_key = ?', { key }) end

local function city(id, kind, data, opts)
    opts = opts or {}
    local def = PFCatalog.Events[kind] or {}
    return { id = id, kind = kind, category = def.category, news = opts.news or def.news, title = opts.title, data = data or {},
        district = opts.district, coords = opts.coords, bulletin = def.bulletin == true, at = Mock.clock }
end
local function emit(e) TriggerEvent('pf-services:cityEvent', e) end

local JUNIOR, SENIOR, EDITOR, BOSS, READER, OWNER = 1, 2, 3, 4, 5, 6
local function people()
    Mock.players = {}
    local function person(src, cid, job, grade, isboss)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.job = { name = job, label = job, grade = { level = grade, name = 'G' .. grade }, onduty = true, isboss = isboss == true }
        return p
    end
    person(JUNIOR, 'NEWS0', 'reporter', 0)
    person(SENIOR, 'NEWS2', 'reporter', 2)
    person(EDITOR, 'NEWS3', 'reporter', 3)
    person(BOSS, 'BSBOSS', 'burgershot', 4, true)
    person(READER, 'READ1', 'unemployed', 0)
    person(OWNER, 'LTDOWN', 'unemployed', 0)
end
people()
startNews()
local room = function(m, src, p) return PFNews.NewsroomHandlers[m](src, p or {}) end
local reader = function(m, src, p) return PFNews.ReaderHandlers[m](src, p or {}) end

describe('pf-news schema', function()
    it('creates every table and its migration is safe to run again', function()
        local tables = n([[SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN
            ('pf_news_articles', 'pf_news_events', 'pf_news_leads', 'pf_news_views', 'pf_news_ads', 'pf_news_payouts')]])
        assert_eq(tables, 6)
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-news'")
        assert_true(RunMigrations('pf-news', PFNews.Migrations), 'rerun')
        assert_eq(n("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-news'"), 1)
    end)
end)

describe('pf-news City Desk on a real database', function()
    it('coalesces a burst, handles each event once, and survives a restart without duplicates', function()
        emit(city(1001, 'gov.tax.changed', { label = 'Sales tax', oldRate = 5, newRate = 7 }))
        Mock.clock = Mock.clock + 15
        emit(city(1002, 'gov.tax.changed', { label = 'Income tax', oldRate = 10, newRate = 12 }))
        emit(city(1003, 'crime.robbery.bank', { bank = 'Fleeca Legion' }, { district = 'legion', coords = { x = 150.1, y = -1040.2, z = 29.3 } }))
        assert_eq(n('SELECT COUNT(*) FROM pf_news_articles WHERE auto = 1'), 2, 'tax digest + bulletin')
        local digest = MySQL.single.await("SELECT id, title, body, preset_id FROM pf_news_articles WHERE group_key = 'gov.tax'")
        assert_true(digest.title:find('2', 1, true) ~= nil, digest.title)
        assert_true(digest.body:find('Income tax', 1, true) ~= nil)
        assert_eq(n('SELECT COUNT(*) FROM pf_news_events WHERE article_id = ?', { digest.id }), 2)
        assert_eq(n('SELECT breaking FROM pf_news_articles WHERE event_id = 1003'), 1)
        assert_eq(n('SELECT COUNT(*) FROM pf_news_leads WHERE event_id = 1003'), 1, 'bulletin lead')
        -- the same events again (a second listener, a replay): nothing changes
        emit(city(1001, 'gov.tax.changed', { label = 'Sales tax', oldRate = 5, newRate = 7 }))
        emit(city(1003, 'crime.robbery.bank', { bank = 'Fleeca Legion' }, { district = 'legion' }))
        assert_eq(n('SELECT COUNT(*) FROM pf_news_articles'), 2)
        assert_eq(n('SELECT COUNT(*) FROM pf_news_leads'), 1)

        -- crash: event 1004 was claimed but its article never written
        MySQL.query.await("INSERT INTO pf_news_events (event_id, kind, mode, payload, created_at) VALUES (1004, 'gov.law.published', 'auto', '{}', FROM_UNIXTIME(?))", { Mock.clock })
        -- restart; pf-services replays its recent timeline (newest first), including 1005 missed while down
        recentEvents = {
            { id = 1005, kind = 'gov.power.cut', news = 'auto', data = {}, district = 'Davis', at = Mock.clock },
            { id = 1004, kind = 'gov.law.published', news = 'auto', data = { name = 'Noise Act' }, at = Mock.clock },
            { id = 1003, kind = 'crime.robbery.bank', news = 'auto', data = { bank = 'Fleeca Legion' }, at = Mock.clock },
            { id = 1002, kind = 'gov.tax.changed', news = 'auto', data = { label = 'Income tax', oldRate = 10, newRate = 12 }, at = Mock.clock },
            { id = 1001, kind = 'gov.tax.changed', news = 'auto', data = { label = 'Sales tax', oldRate = 5, newRate = 7 }, at = Mock.clock },
        }
        startNews()
        recentEvents = {}
        assert_eq(n('SELECT COUNT(*) FROM pf_news_articles'), 4, 'only the unfinished and the missed events were added')
        assert_eq(n('SELECT COUNT(*) FROM pf_news_events WHERE article_id IS NULL'), 0, 'every event is linked')
        assert_eq(n('SELECT COUNT(*) FROM pf_news_articles WHERE event_id = 1004'), 1)
        assert_eq(n('SELECT COUNT(*) FROM pf_news_leads'), 1, 'the bulletin lead was not made twice')
        -- the open group lives in the database: a third tax change after the restart joins it
        Mock.clock = Mock.clock + 20
        emit(city(1006, 'gov.tax.toggled', { label = 'Vehicle tax', enabled = false }))
        assert_eq(n('SELECT COUNT(*) FROM pf_news_events WHERE article_id = ?', { digest.id }), 3)
        assert_true(scalar('SELECT title FROM pf_news_articles WHERE id = ?', { digest.id }):find('3', 1, true) ~= nil)
        -- after the window a new change is a new article
        Mock.clock = Mock.clock + 700
        emit(city(1007, 'gov.tax.changed', { label = 'Sales tax', oldRate = 7, newRate = 6 }))
        assert_eq(n('SELECT COUNT(*) FROM pf_news_articles'), 5)
        local front = reader('front', READER).front
        assert_eq(#front.latest, 5)
        assert_eq(#front.breaking, 1, 'the bank bulletin is in the breaking banner')
    end)
end)

describe('pf-news newsroom on a real database', function()
    it('lead -> claim -> story -> review -> publish -> covered -> bonus paid once through the ledger', function()
        Mock.clock = Mock.clock + 1000
        people()
        emit(city(2001, 'crime.robbery.store', { store = 'LTD Grove Street', citizenid = 'SECRET' }, { district = 'davis', coords = { x = -47.0, y = -1758.0, z = 29.4 } }))
        local lead = MySQL.single.await('SELECT id, details FROM pf_news_leads WHERE event_id = 2001')
        assert_false(lead.details:find('SECRET', 1, true) ~= nil)
        local claim = room('claimLead', JUNIOR, { id = lead.id })
        assert_true(claim.ok, tostring(claim.error))
        assert_true(math.abs(claim.coords.x + 47.0) < 0.01)
        assert_eq(room('claimLead', SENIOR, { id = lead.id }).error, 'lead_taken')
        local body = string.rep('Two masked men robbed the LTD on Grove Street. ', 12)
        local saved = room('save', JUNIOR, { title = 'Masked men rob Grove Street LTD', summary = 'Nobody hurt', body = body, category = 'crime', leadId = lead.id, images = { 'https://i.imgur.com/x1.jpg' } })
        assert_true(saved.ok, tostring(saved.error))
        assert_eq(room('submit', JUNIOR, { id = saved.id }).status, 'review')
        assert_eq(room('publish', JUNIOR, { id = saved.id }).error, 'needs_review')
        local pub = room('publish', EDITOR, { id = saved.id })
        assert_true(pub.ok, tostring(pub.error))
        assert_true(pub.covered)
        assert_eq(scalar('SELECT status FROM pf_news_leads WHERE id = ?', { lead.id }), 'covered')
        assert_eq(n('SELECT article_id FROM pf_news_leads WHERE id = ?', { lead.id }), saved.id)
        local bonus = Config.Pay.perArticle + Config.Pay.leadBonus
        assert_eq(n('SELECT amount FROM pf_news_payouts WHERE article_id = ?', { saved.id }), bonus)
        local before = Mock.players[JUNIOR].PlayerData.money.bank
        assert_eq(PFNews.Pay.Sweep(), 0, 'held')
        Mock.clock = Mock.clock + Config.Pay.holdSeconds + 5
        assert_eq(PFNews.Pay.Sweep(), 1)
        assert_eq(Mock.players[JUNIOR].PlayerData.money.bank, before + bonus)
        assert_eq(txState('pf-news:bonus:' .. saved.id), 'completed')
        assert_eq(PFNews.Pay.Sweep(), 0)
        assert_eq(Mock.players[JUNIOR].PlayerData.money.bank, before + bonus, 'paid once')

        -- readers: one view per citizen, never the author; search finds it, wildcards are literal
        for _ = 1, 3 do reader('article', READER, { id = saved.id }) end
        reader('article', JUNIOR, { id = saved.id })
        reader('article', BOSS, { id = saved.id })
        assert_eq(n('SELECT views FROM pf_news_articles WHERE id = ?', { saved.id }), 2)
        assert_eq(#reader('search', READER, { q = 'Grove Street' }).articles, 1)
        assert_eq(#reader('search', READER, { q = '%%' }).articles, 0)
        local cat = reader('list', READER, { category = 'crime' })
        assert_true(#cat.articles >= 1)

        -- a senior publishes directly; a retraction inside the hold stops the bonus
        local b = room('save', SENIOR, { title = 'Rumours from the docks', body = body })
        assert_eq(room('submit', SENIOR, { id = b.id }).status, 'published')
        assert_true(room('retract', EDITOR, { id = b.id, note = 'Unsourced' }).ok)
        Mock.clock = Mock.clock + Config.Pay.holdSeconds + 5
        PFNews.Pay.Sweep()
        assert_eq(scalar('SELECT state FROM pf_news_payouts WHERE article_id = ?', { b.id }), 'cancelled')
        assert_eq(txState('pf-news:bonus:' .. b.id), nil)
        -- leads expire
        emit(city(2002, 'police.warrant', { name = 'Jim' }, { district = 'vinewood' }))
        Mock.clock = Mock.clock + Config.Leads.openMinutes * 60 + 10
        PFNews.Sweep()
        assert_eq(scalar('SELECT status FROM pf_news_leads WHERE event_id = 2002'), 'expired')
    end)
end)

describe('pf-news ads on a real database', function()
    it('a boss buys from the job account into society:reporter; rejection refunds once, a failed refund retries with its next key', function()
        people()
        fund('burgershot', 5000)
        local res = reader('buyAd', BOSS, { businessId = 'job:burgershot', durationId = '3d', text = 'Two burgers for the price of one' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(txState('pf-news:ad:' .. res.id), 'completed')
        assert_eq(society('burgershot'), 4000)
        assert_eq(society('reporter'), 1000)
        assert_eq(#reader('front', READER).front.ads, 1)
        -- the same ad cannot be charged twice: the key is spent
        local again = PFPayout.Transfer({ from = 'society:burgershot', to = 'society:reporter', amount = 1000, key = 'pf-news:ad:' .. res.id })
        assert_true(again.duplicate)
        assert_eq(society('burgershot'), 4000)

        -- the company spent the money: the refund fails, then goes through on the next sweep under :refund:1
        MySQL.update.await("UPDATE bank_accounts SET account_balance = 0 WHERE account_name = 'reporter'")
        if BankingAccounts then BankingAccounts.reporter = nil end
        local rej = room('rejectAd', JUNIOR, { id = res.id, note = 'Misleading offer' })
        assert_true(rej.ok)
        assert_true(rej.refundPending)
        assert_eq(txState('pf-news:ad:' .. res.id .. ':refund'), 'failed')
        assert_eq(room('rejectAd', EDITOR, { id = res.id, note = 'again' }).error, 'not_active')
        MySQL.update.await("UPDATE bank_accounts SET account_balance = 3000 WHERE account_name = 'reporter'")
        PFNews.Sweep()
        assert_eq(txState('pf-news:ad:' .. res.id .. ':refund:1'), 'completed')
        assert_eq(scalar('SELECT refund_state FROM pf_news_ads WHERE id = ?', { res.id }), 'done')
        assert_eq(society('burgershot'), 5000)
        PFNews.Sweep()
        assert_eq(society('burgershot'), 5000, 'refunded once')
    end)

    it('a registered owner buys from the business account; without money there is no ad', function()
        people()
        -- pf-government adds account_ref at start (EnsureBusinessSchema); business_status is left out on
        -- purpose: pf-news falls back to the older registry shape
        MySQL.query.await('ALTER TABLE pf_gov_businesses ADD COLUMN account_ref VARCHAR(96) NULL DEFAULT NULL')
        MySQL.query.await([[INSERT INTO pf_gov_businesses (business_id, business_name, business_type, owner_id, owner_name, account_ref)
            VALUES ('store:ltd_grove', 'LTD Grove', 'store', 'LTDOWN', 'Owner', 'society:store_ltd_grove')]])
        fund('store_ltd_grove', 100)
        local opts = reader('adOptions', OWNER)
        assert_eq(#opts.businesses, 1)
        assert_eq(opts.businesses[1].id, 'store:ltd_grove')
        assert_eq(#reader('adOptions', READER).businesses, 0)
        local res = reader('buyAd', OWNER, { businessId = 'store:ltd_grove', durationId = '1d', text = 'Open all night on Grove' })
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(scalar('SELECT status FROM pf_news_ads WHERE id = ?', { res.id }), 'failed')
        assert_eq(society('store_ltd_grove'), 100)
        fund('store_ltd_grove', 1000)
        local ok = reader('buyAd', OWNER, { businessId = 'store:ltd_grove', durationId = '1d', text = 'Open all night on Grove' })
        assert_true(ok.ok, tostring(ok.error))
        assert_eq(society('store_ltd_grove'), 600)
        Mock.clock = Mock.clock + 25 * 3600
        PFNews.Sweep()
        assert_eq(scalar('SELECT status FROM pf_news_ads WHERE id = ?', { ok.id }), 'expired')
    end)
end)
