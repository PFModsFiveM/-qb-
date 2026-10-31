-- pf-news (mocked): presets for every automatic kind render without 'nil' or template syntax,
-- bursts of one group update ONE article, each event is handled once, leads go open -> claimed ->
-- covered (on duty, grade rules), reporter bonuses and ads pay through the ledger with stable keys,
-- and the reader is one module registered as the News app and the news.ls site with the same handlers.
load_resource('tests/lua/fivem_mocks.lua')

function GetCurrentResourceName() return 'pf-news' end
local states = { ['pf-devices'] = 'started', ['pf-services'] = 'started', ['pfm-banking'] = 'started', ['pfm-core'] = 'started', ['pfm-newsjob'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end

Config = {}
load_resource('[pfscripts]/pf-services/shared/catalog.lua')
load_resource('[pfscripts]/pf-news/config.lua')

-- ── ledger stand-in with the real ledger's key rules: a key that moved money returns that result
-- again, a key that failed stays failed, bank down records nothing ────────────────────────────
Ledger = { balances = {}, byKey = {}, log = {}, down = false, n = 0 }
PFPayout = {
    Transfer = function(o)
        if Ledger.down then return { ok = false, error = 'bank_unavailable' } end
        local ex = Ledger.byKey[o.key]
        if ex then return { ok = ex.ok, txId = ex.txId, error = ex.error, duplicate = true } end
        local fromSystem = o.from:sub(1, 7) == 'system:'
        local r
        if not fromSystem and (Ledger.balances[o.from] or 0) < o.amount then
            r = { ok = false, error = 'insufficient_funds' }
        else
            Ledger.n = Ledger.n + 1
            if not fromSystem then Ledger.balances[o.from] = Ledger.balances[o.from] - o.amount end
            Ledger.balances[o.to] = (Ledger.balances[o.to] or 0) + o.amount
            r = { ok = true, txId = 'TX' .. Ledger.n }
            Ledger.log[#Ledger.log + 1] = { key = o.key, from = o.from, to = o.to, amount = o.amount }
        end
        Ledger.byKey[o.key] = r
        return r
    end,
}
PFPayout.Pay = function(who, account, amount, opts)
    local r = PFPayout.Transfer({ from = opts.from or 'system:pf-news', to = ('player:%s:%s'):format(who, account), amount = amount, key = opts.key })
    return r.ok == true, r
end

-- ── pf-devices / pf-services / pfm-banking / pfm-newsjob stand-ins ─────────────────────────────
local registered, appHandlers, siteDefs, siteHandlers = {}, {}, {}, {}
local broadcasts, pushes, installed = {}, {}, {}
local recentEvents = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) registered[def.id] = def return true end,
    RegisterAppHandlers = function(_, id, map) appHandlers[id] = map return true end,
    RegisterSite = function(_, def) siteDefs[def.host] = def return true end,
    RegisterSiteHandler = function(_, host, method, fn) siteHandlers[host] = siteHandlers[host] or {}; siteHandlers[host][method] = fn return true end,
    Broadcast = function(_, app, ev, p) broadcasts[#broadcasts + 1] = { app = app, event = ev, payload = p } return true end,
    PushToJob = function(_, job, app, ev, p) pushes[#pushes + 1] = { job = job, app = app, event = ev } return 1 end,
    PushToCitizen = function() return true end,
    Push = function(_, src, app, ev) pushes[#pushes + 1] = { src = src, app = app, event = ev } return true end,
    IsAppInstalled = function(_, cid, app) return installed[cid .. ':' .. app] == true end,
}
Mock.exportsByResource['pf-services'] = {
    GetEventKind = function(_, kind) return PFCatalog.Events[kind] end,
    GetRecentEvents = function() return recentEvents end,
}
Mock.exportsByResource['pfm-banking'] = {
    EnsureSocietyAccount = function() return true end,
    GetTransaction = function(_, key) local r = Ledger.byKey[key] return r and { state = r.ok and 'completed' or 'failed', tx_id = r.txId } or nil end,
}
Mock.exportsByResource['pfm-newsjob'] = { GetFieldStatus = function() return { CIDREP2 = { label = 'Rumpo', model = 'rumpo' } } end }
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

for _, f in ipairs({ 'util', 'schema', 'presets', 'articles', 'leads', 'auto', 'ads', 'pay', 'apps', 'main' }) do
    load_resource('[pfscripts]/pf-news/server/' .. f .. '.lua')
end
local SQL = PFNews.SQL

-- ── in-memory tables behind every PFNews.SQL statement ─────────────────────────────────────────
local DB
local function resetDB()
    DB = { articles = {}, events = {}, leads = {}, views = {}, ads = {}, payouts = {}, gov = {}, nextArticle = 0, nextLead = 0, nextAd = 0 }
end
resetDB()
local function copy(r) if not r then return nil end local o = {} for k, v in pairs(r) do o[k] = v end return o end
local function sorted(list, cmp) table.sort(list, cmp) return list end
local function byPubDesc(a, b) if (a.published_at or 0) ~= (b.published_at or 0) then return (a.published_at or 0) > (b.published_at or 0) end return a.id > b.id end
local function where(tbl, pred) local out = {} for _, r in pairs(tbl) do if pred(r) then out[#out + 1] = copy(r) end end return out end
local function count(tbl, pred) local n = 0 for _, r in pairs(tbl) do if pred(r) then n = n + 1 end end return n end
local function limit(list, n) local out = {} for i = 1, math.min(n, #list) do out[i] = list[i] end return out end
local function published(r) return r.status == 'published' end

local H = {}
local function on(stmt, fn) H[stmt] = fn end
-- statements built with :format() differ only in their numbers / IN lists
local function shape(q) return (q:gsub('LIMIT %%d', 'LIMIT N'):gsub('LIMIT %d+', 'LIMIT N'):gsub('OFFSET %%d', 'OFFSET N'):gsub('OFFSET %d+', 'OFFSET N'):gsub('IN %b()', 'IN (L)')) end

-- articles
on(SQL.getArticle, function(p) return copy(DB.articles[p[1]]) end)
on(SQL.insertDraft, function(p)
    DB.nextArticle = DB.nextArticle + 1
    DB.articles[DB.nextArticle] = { id = DB.nextArticle, title = p[1], summary = p[2], body = p[3], category = p[4], images = p[5], author_cid = p[6], author_name = p[7],
        status = 'draft', auto = 0, lead_id = p[8], breaking = p[9], pinned = 0, views = 0, created_at = p[10], updated_at = p[11] }
    return DB.nextArticle
end)
on(SQL.updateArticle, function(p)
    local r = DB.articles[p[9]]
    if not r or r.status ~= p[10] then return 0 end
    r.title, r.summary, r.body, r.category, r.images, r.lead_id, r.breaking, r.updated_at, r.group_until = p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], nil
    return 1
end)
on(SQL.countOpenDrafts, function(p) return count(DB.articles, function(r) return r.author_cid == p[1] and (r.status == 'draft' or r.status == 'review') end) end)
on(SQL.submitArticle, function(p) local r = DB.articles[p[2]] if not r or r.status ~= 'draft' then return 0 end r.status, r.submitted_at, r.review_note = 'review', p[1], nil return 1 end)
on(SQL.publishArticle, function(p)
    local r = DB.articles[p[5]]
    if not r or (r.status ~= 'draft' and r.status ~= 'review') then return 0 end
    r.status, r.published_at, r.updated_at, r.reviewed_by, r.reviewed_name, r.review_note = 'published', p[1], p[2], p[3], p[4], nil
    return 1
end)
on(SQL.rejectArticle, function(p) local r = DB.articles[p[5]] if not r or r.status ~= 'review' then return 0 end r.status, r.review_note, r.reviewed_by, r.reviewed_name = 'draft', p[1], p[2], p[3] return 1 end)
on(SQL.retractArticle, function(p) local r = DB.articles[p[3]] if not r or r.status ~= 'published' then return 0 end r.status, r.retract_note, r.retracted_at, r.pinned, r.group_until = 'retracted', p[1], p[2], 0, nil return 1 end)
on(SQL.pinArticle, function(p) local r = DB.articles[p[2]] if not r or r.status ~= 'published' then return 0 end r.pinned = p[1] return 1 end)
on(SQL.countPinned, function() return count(DB.articles, function(r) return published(r) and r.pinned == 1 end) end)
on(SQL.deleteDraft, function(p) local r = DB.articles[p[1]] if not r or r.status ~= 'draft' then return 0 end DB.articles[p[1]] = nil return 1 end)
on(SQL.frontLatest, function() return sorted(where(DB.articles, published), byPubDesc) end)
on(SQL.frontPinned, function() return sorted(where(DB.articles, function(r) return published(r) and r.pinned == 1 end), byPubDesc) end)
on(SQL.frontBreaking, function(p) return sorted(where(DB.articles, function(r) return published(r) and r.breaking == 1 and (r.published_at or 0) >= p[1] end), byPubDesc) end)
on(SQL.listCategory, function(p) return sorted(where(DB.articles, function(r) return published(r) and r.category == p[1] end), byPubDesc) end)
on(SQL.listAll, function() return sorted(where(DB.articles, published), byPubDesc) end)
on(SQL.search, function(p)
    local term = p[1]:sub(2, -2):gsub('\\', ''):lower()
    return sorted(where(DB.articles, function(r) return published(r) and ((r.title or '') .. ' ' .. (r.body or '')):lower():find(term, 1, true) ~= nil end), byPubDesc)
end)
on(SQL.insertView, function(p) local k = p[1] .. ':' .. p[2] if DB.views[k] then return 0 end DB.views[k] = true return 1 end)
on(SQL.addView, function(p) DB.articles[p[1]].views = DB.articles[p[1]].views + 1 return 1 end)
on(SQL.byAuthor, function(p) return where(DB.articles, function(r) return r.author_cid == p[1] and (r.status == 'draft' or r.status == 'review') end) end)
on(SQL.myPublished, function(p) return where(DB.articles, function(r) return r.author_cid == p[1] and (r.status == 'published' or r.status == 'retracted') end) end)
on(SQL.reviewQueue, function() return where(DB.articles, function(r) return r.status == 'review' end) end)
on(SQL.recentPublished, function() return sorted(where(DB.articles, function(r) return r.status == 'published' or r.status == 'retracted' end), byPubDesc) end)
on(SQL.statsToday, function(p) return count(DB.articles, function(r) return published(r) and (r.published_at or 0) >= p[1] end) end)
on(SQL.statsMine, function(p) local n, v = 0, 0 for _, r in pairs(DB.articles) do if r.author_cid == p[1] and published(r) then n = n + 1 v = v + r.views end end return { n = n, views = v } end)
-- city events
on(SQL.claimEvent, function(p) if DB.events[p[1]] then return 0 end DB.events[p[1]] = { event_id = p[1], kind = p[2], mode = p[3], payload = p[4] } return 1 end)
on(SQL.getEvent, function(p) return copy(DB.events[p[1]]) end)
on(SQL.openGroup, function(p)
    local best
    for _, r in pairs(DB.articles) do
        if r.group_key == p[1] and r.auto == 1 and published(r) and (r.group_until or 0) >= p[2] and (not best or r.id > best.id) then best = r end
    end
    return best and { id = best.id, published_at = best.published_at } or nil
end)
on(SQL.linkEventArticle, function(p) local e = DB.events[p[2]] if not e or e.article_id then return 0 end e.article_id = p[1] return 1 end)
on(SQL.groupPayloads, function(p) return sorted(where(DB.events, function(e) return e.article_id == p[1] end), function(a, b) return a.event_id < b.event_id end) end)
on(SQL.insertAuto, function(p)
    for _, r in pairs(DB.articles) do if r.event_id == p[6] then return 0 end end
    DB.nextArticle = DB.nextArticle + 1
    DB.articles[DB.nextArticle] = { id = DB.nextArticle, title = p[1], summary = p[2], body = p[3], category = p[4], images = '[]', author_name = p[5], status = 'published', auto = 1,
        event_id = p[6], preset_id = p[7], group_key = p[8], group_until = p[9], breaking = p[10], pinned = 0, views = 0, created_at = p[11], updated_at = p[12], published_at = p[13] }
    return DB.nextArticle
end)
on(SQL.articleByEvent, function(p) for _, r in pairs(DB.articles) do if r.event_id == p[1] then return r.id end end end)
on(SQL.updateDigest, function(p)
    local r = DB.articles[p[8]]
    if not r or not published(r) then return 0 end
    r.title, r.summary, r.body, r.preset_id, r.breaking, r.group_until, r.updated_at = p[1], p[2], p[3], p[4], math.max(r.breaking, p[5]), p[6], p[7]
    return 1
end)
-- leads
on(SQL.getLead, function(p) return copy(DB.leads[p[1]]) end)
on(SQL.leadByEvent, function(p) for _, l in pairs(DB.leads) do if l.event_id == p[1] then return l.id end end end)
on(SQL.findMergeLead, function(p)
    local best
    for _, l in pairs(DB.leads) do
        if l.kind == p[1] and (l.district or '') == p[2] and (l.status == 'open' or l.status == 'claimed') and l.created_at >= p[3] and (not best or l.id > best.id) then best = l end
    end
    return best and { id = best.id } or nil
end)
on(SQL.mergeLead, function(p) local l = DB.leads[p[4]] l.hits = l.hits + 1 l.updated_at = p[1] l.expires_at = math.max(l.expires_at or p[2], p[3]) return 1 end)
on(SQL.insertLead, function(p)
    if p[1] then for _, l in pairs(DB.leads) do if l.event_id == p[1] then return 0 end end end
    DB.nextLead = DB.nextLead + 1
    DB.leads[DB.nextLead] = { id = DB.nextLead, event_id = p[1], kind = p[2], category = p[3], title = p[4], details = p[5], district = p[6], x = p[7], y = p[8], z = p[9],
        status = 'open', hits = 1, created_at = p[10], updated_at = p[11], expires_at = p[12] }
    return DB.nextLead
end)
on(SQL.linkEventLead, function(p) local e = DB.events[p[2]] if not e or e.lead_id then return 0 end e.lead_id = p[1] return 1 end)
on(SQL.countClaimed, function(p) return count(DB.leads, function(l) return l.claimed_cid == p[1] and l.status == 'claimed' end) end)
on(SQL.claimLead, function(p)
    local l = DB.leads[p[5]]
    if not l or l.status ~= 'open' or l.expires_at < p[6] then return 0 end
    l.status, l.claimed_cid, l.claimed_name, l.claimed_at, l.expires_at = 'claimed', p[1], p[2], p[3], p[4]
    return 1
end)
on(SQL.releaseLead, function(p)
    local l = DB.leads[p[2]]
    if not l or l.status ~= 'claimed' or l.claimed_cid ~= p[3] then return 0 end
    l.status, l.claimed_cid, l.claimed_name, l.claimed_at, l.expires_at = 'open', nil, nil, nil, math.max(l.expires_at, p[1])
    return 1
end)
on(SQL.coverLead, function(p)
    local l = DB.leads[p[3]]
    if not l or l.status ~= 'claimed' or l.claimed_cid ~= p[4] then return 0 end
    l.status, l.article_id, l.covered_at = 'covered', p[1], p[2]
    return 1
end)
on(SQL.dismissLead, function(p) local l = DB.leads[p[2]] if not l or (l.status ~= 'open' and l.status ~= 'claimed') then return 0 end l.status = 'dismissed' return 1 end)
on(SQL.expireLeads, function(p) local n = 0 for _, l in pairs(DB.leads) do if (l.status == 'open' or l.status == 'claimed') and l.expires_at < p[1] then l.status = 'expired' n = n + 1 end end return n end)
on(SQL.countOpenLeads, function() return count(DB.leads, function(l) return l.status == 'open' end) end)
on(SQL.trimOpenLeads, function() return 0 end)
on(SQL.activeLeads, function() return where(DB.leads, function(l) return l.status == 'open' or l.status == 'claimed' end) end)
-- ads
on(SQL.getAd, function(p) return copy(DB.ads[p[1]]) end)
on(SQL.registryOwned, function(p) return where(DB.gov, function(b) return b.owner_id == p[1] or b.owner_id == p[2] end) end)
on(SQL.countActiveAds, function(p) return count(DB.ads, function(a) return (a.status == 'pending' or a.status == 'active') and (not a.ends_at or a.ends_at > p[1]) end) end)
on(SQL.countBusinessAds, function(p) return count(DB.ads, function(a) return a.business_id == p[1] and (a.status == 'pending' or a.status == 'active') and (not a.ends_at or a.ends_at > p[2]) end) end)
on(SQL.insertAd, function(p)
    DB.nextAd = DB.nextAd + 1
    DB.ads[DB.nextAd] = { id = DB.nextAd, business_id = p[1], business_name = p[2], account_ref = p[3], buyer_cid = p[4], buyer_name = p[5], text = p[6], image_url = p[7],
        duration_id = p[8], hours = p[9], price = p[10], status = 'pending', refund_state = 'none', refund_attempts = 0, created_at = p[11] }
    return DB.nextAd
end)
on(SQL.activateAd, function(p) local a = DB.ads[p[4]] if not a or a.status ~= 'pending' then return 0 end a.status, a.paid_tx, a.starts_at, a.ends_at = 'active', p[1], p[2], p[3] return 1 end)
on(SQL.failAd, function(p) local a = DB.ads[p[2]] if not a or a.status ~= 'pending' then return 0 end a.status, a.error = 'failed', p[1] return 1 end)
on(SQL.rejectAd, function(p)
    local a = DB.ads[p[5]]
    if not a or a.status ~= 'active' then return 0 end
    a.status, a.reject_note, a.rejected_by, a.rejected_name, a.refund_state = 'rejected', p[1], p[2], p[3], 'pending'
    return 1
end)
on(SQL.refundDone, function(p) local a = DB.ads[p[2]] if not a or a.refund_state ~= 'pending' then return 0 end a.refund_state, a.refund_tx = 'done', p[1] return 1 end)
on(SQL.refundRetry, function(p) local a = DB.ads[p[1]] if not a or a.refund_state ~= 'pending' or a.refund_attempts ~= p[2] then return 0 end a.refund_attempts = a.refund_attempts + 1 return 1 end)
on(SQL.activeAds, function(p) return where(DB.ads, function(a) return a.status == 'active' and a.ends_at > p[1] end) end)
on(SQL.adsFor, function() return where(DB.ads, function() return true end) end)
on(SQL.expireAds, function(p) local n = 0 for _, a in pairs(DB.ads) do if a.status == 'active' and a.ends_at <= p[1] then a.status = 'expired' n = n + 1 end end return n end)
on(SQL.stuckAds, function(p) return where(DB.ads, function(a) return a.status == 'pending' and a.created_at < p[1] end) end)
on(SQL.pendingRefunds, function() return where(DB.ads, function(a) return a.refund_state == 'pending' end) end)
on(SQL.newsroomAds, function() return where(DB.ads, function(a) return a.status ~= 'pending' end) end)
-- payouts
on(SQL.dayTotal, function(p) local s = 0 for _, r in pairs(DB.payouts) do if r.citizenid == p[1] and r.day == p[2] and (r.state == 'pending' or r.state == 'paid') then s = s + r.amount end end return s end)
on(SQL.insertPayout, function(p)
    if DB.payouts[p[1]] then return 0 end
    DB.payouts[p[1]] = { article_id = p[1], citizenid = p[2], amount = p[3], day = p[4], lead_bonus = p[5], state = 'pending', attempts = 0, due_at = p[6] }
    return 1
end)
on(SQL.duePayouts, function(p)
    local out = {}
    for _, r in pairs(DB.payouts) do
        if r.state == 'pending' and r.due_at <= p[1] then
            local a = DB.articles[r.article_id]
            out[#out + 1] = { article_id = r.article_id, citizenid = r.citizenid, amount = r.amount, attempts = r.attempts, status = a and a.status, title = a and a.title }
        end
    end
    return out
end)
on(SQL.payoutPaid, function(p) local r = DB.payouts[p[3]] if not r or r.state ~= 'pending' then return 0 end r.state, r.tx_id = 'paid', p[2] return 1 end)
on(SQL.payoutCancel, function(p) local r = DB.payouts[p[1]] if not r or r.state ~= 'pending' then return 0 end r.state = 'cancelled' return 1 end)
on(SQL.payoutRetry, function(p) local r = DB.payouts[p[3]] if not r or r.state ~= 'pending' then return 0 end if r.attempts + 1 >= p[1] then r.state = 'failed' end r.attempts = r.attempts + 1 r.error = p[2] return 1 end)
on(SQL.myPayouts, function(p) return where(DB.payouts, function(r) return r.citizenid == p[1] end) end)

local byShape = {}
for stmt, fn in pairs(H) do byShape[shape(stmt)] = fn end
local function run(q, params)
    local fn = H[q] or byShape[shape(q)]
    if not fn then error('pfnews spec: unhandled statement: ' .. (q:match('FROM .*') or q):gsub('%s+', ' '):sub(1, 200)) end
    return fn(params or {})
end
local function api() return setmetatable({ await = function(q, p) return run(q, p) end }, { __call = function(_, q, p) return run(q, p) end }) end
MySQL = { query = api(), single = api(), scalar = api(), insert = api(), update = api() }

-- ── players ────────────────────────────────────────────────────────
QBCoreMock.Shared.Jobs = { reporter = { label = 'Reporter', grades = { ['0'] = { name = 'Journalist' }, ['1'] = { name = 'Reporter' }, ['2'] = { name = 'Senior' }, ['3'] = { name = 'Editor' }, ['4'] = { name = 'Chief', isboss = true } } } }
local JUNIOR, SENIOR, EDITOR, OUTSIDER, BOSS, READER = 1, 2, 3, 4, 5, 6
local function person(src, cid, job, grade, onduty, isboss)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, label = job == 'burgershot' and 'Burger Shot' or job, grade = { level = grade or 0, name = 'G' .. tostring(grade or 0) }, onduty = onduty ~= false, isboss = isboss == true }
    p.Functions.SetJobDuty = function(v) p.PlayerData.job.onduty = v end
    return p
end
local function newsroom(method, src, p) return PFNews.NewsroomHandlers[method](src, p or {}) end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function articlesWhere(pred) local out = {} for _, r in pairs(DB.articles) do if pred(r) then out[#out + 1] = r end end return out end
local function ev(id, kind, data, opts)
    opts = opts or {}
    local def = PFCatalog.Events[kind] or {}
    return { id = id, kind = kind, category = def.category or 'city', news = opts.news or def.news or 'none', title = opts.title, data = data or {},
        district = opts.district, coords = opts.coords, police = def.police, bulletin = def.bulletin == true, at = Mock.clock }
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    resetDB()
    Ledger.balances, Ledger.byKey, Ledger.log, Ledger.down, Ledger.n = {}, {}, {}, false, 0
    broadcasts, pushes, installed, recentEvents = {}, {}, {}, {}
    PFNews.Articles.__reset(); PFNews.Ads.__reset(); PFNews.Auto.__reset()
    PFNews.ready = true
    Mock.clock = Mock.clock + 100000
    person(JUNIOR, 'CIDREP0', 'reporter', 0)
    person(SENIOR, 'CIDREP2', 'reporter', 2)
    person(EDITOR, 'CIDED3', 'reporter', 3)
    person(OUTSIDER, 'CIDOUT', 'police', 3)
    person(BOSS, 'CIDBOSS', 'burgershot', 4, true, true)
    person(READER, 'CIDREAD', 'unemployed', 0)
end

local function noTemplateLeft(s, what)
    assert_true(type(s) == 'string', what .. ' is text')
    assert_false(s:find('%f[%w]nil%f[%W]') ~= nil, what .. ' prints nil: ' .. s)
    assert_false(s:find('[{}%[%]]') ~= nil, what .. ' keeps template syntax: ' .. s)
end

describe('pf-news presets', function()
    it('every automatic catalog kind has a preset, and each renders without nil with full, partial or no data', function()
        local full = { tax = 'sales', label = 'Sales tax', oldRate = 5, newRate = 7.5, enabled = false, rate = 7, name = 'Noise Act', lawTitle = 'Noise Act', category = 'traffic',
            description = 'Quiet hours.', fine = 500, jail = 10, department = 'police', oldBudget = 10000, newBudget = 12500, upgrade = 'traffic_ai', cost = 50000,
            reason = 'Maintenance', businessName = 'Burger Shot', service = 'power', type = 'restaurant', findings = 'Dirty kitchen', amount = 25000,
            title = 'Curfew tonight', content = 'Stay indoors after 2am.', priority = 'urgent', role = 'Chief of Police', bank = 'Fleeca Legion',
            store = 'Vangelico', count = 3, weather = 'thunder', citizenid = 'ABC123', plate = 'SECRET1' }
        local partial = { label = 'Sales tax', newRate = 9, businessName = 'Bean Machine' }
        local n = 0
        for kind, def in pairs(PFCatalog.Events) do
            if def.news == 'auto' then
                n = n + 1
                assert_true(Config.Presets[kind] ~= nil, 'preset for ' .. kind)
                for id = 1, 4 do
                    for _, data in ipairs({ full, partial, {} }) do
                        local snap = PFNews.Presets.Snapshot(ev(id, kind, data, { district = 'mission_row' }))
                        local r = PFNews.Presets.Render(snap)
                        noTemplateLeft(r.title, kind .. ' title')
                        noTemplateLeft(r.summary or '', kind .. ' summary')
                        noTemplateLeft(r.body or '', kind .. ' body')
                        noTemplateLeft(PFNews.Presets.Line(snap), kind .. ' line')
                        assert_true(#r.title >= 6, kind .. ' title has words')
                        assert_false((r.body or ''):find('ABC123', 1, true) ~= nil, 'citizen ids never reach text')
                        assert_false((r.body or ''):find('SECRET1', 1, true) ~= nil, 'plates never reach text')
                    end
                end
            end
        end
        assert_true(n >= 20, 'checked the automatic kinds')
    end)

    it('fills, formats and degrades: tax direction, percent, money, optional parts, deterministic variant', function()
        local r = PFNews.Presets.Render(PFNews.Presets.Snapshot(ev(2, 'gov.tax.changed', { label = 'Sales tax', oldRate = 5, newRate = 7 })))
        assert_eq(r.title, 'Sales tax rises to 7%')
        assert_true(r.summary:find('up from 5%', 1, true) ~= nil, r.summary)
        assert_eq(r.presetId, 'gov.tax.changed/1')
        local again = PFNews.Presets.Render(PFNews.Presets.Snapshot(ev(2, 'gov.tax.changed', { label = 'Sales tax', oldRate = 5, newRate = 7 })))
        assert_eq(again.title, r.title, 'same event id, same text')
        -- without the old rate the "rises" variant is skipped, and the optional part disappears
        local r2 = PFNews.Presets.Render(PFNews.Presets.Snapshot(ev(2, 'gov.tax.changed', { tax = 'business', newRate = 12.5 })))
        assert_eq(r2.title, 'New rate for business tax: 12.5%')
        assert_false(r2.body:find('from', 1, true) ~= nil and r2.body:find('up from', 1, true) ~= nil)
        local b = PFNews.Presets.Render(PFNews.Presets.Snapshot(ev(4, 'gov.budget.changed', { department = 'police', oldBudget = 10000, newBudget = 12500 })))
        assert_true(b.title:find('$12,500', 1, true) ~= nil, b.title)
        local ann = PFNews.Presets.Render(PFNews.Presets.Snapshot(ev(5, 'gov.announcement', { title = 'Curfew', content = 'Stay home', priority = 'urgent' })))
        assert_true(ann.breaking, 'urgent announcements are breaking')
        local bank = PFNews.Presets.Render(PFNews.Presets.Snapshot(ev(6, 'crime.robbery.bank', {}, { district = 'legion_square' })))
        assert_true(bank.breaking, 'bulletins are breaking')
        assert_eq(bank.category, 'crime')
        local generic = PFNews.Presets.Render(PFNews.Presets.Snapshot(ev(7, 'custom.unknown', { details = 'Something happened' }, { news = 'auto', title = 'Strange lights over Sandy Shores' })))
        assert_eq(generic.presetId, 'generic/1')
        assert_eq(generic.title, 'Strange lights over Sandy Shores')
        noTemplateLeft(generic.body, 'generic body')
    end)

    it('lead text shows only public fields', function()
        local t = PFNews.Presets.LeadText(PFNews.Presets.Snapshot(ev(9, 'crime.robbery.store', { store = 'LTD Grove St', citizenid = 'CID9', plate = 'AB12CD', phone = '555' }, { district = 'davis' })))
        assert_true(t.details:find('LTD Grove St', 1, true) ~= nil)
        assert_false(t.details:find('CID9', 1, true) ~= nil)
        assert_false(t.details:find('AB12CD', 1, true) ~= nil)
        assert_false(t.details:find('555', 1, true) ~= nil)
        assert_eq(t.title, 'Store robbery in Davis')
    end)
end)

describe('pf-news City Desk', function()
    it('three tax changes in a minute update ONE article; a re-delivered event changes nothing', function()
        PFNews.Auto.Handle(ev(101, 'gov.tax.changed', { label = 'Sales tax', oldRate = 5, newRate = 7 }))
        Mock.clock = Mock.clock + 20
        PFNews.Auto.Handle(ev(102, 'gov.tax.changed', { label = 'Income tax', oldRate = 10, newRate = 8 }))
        Mock.clock = Mock.clock + 20
        PFNews.Auto.Handle(ev(103, 'gov.tax.toggled', { label = 'Vehicle tax', enabled = false }))
        local auto = articlesWhere(function(r) return r.auto == 1 end)
        assert_eq(#auto, 1, 'one article')
        local a = auto[1]
        assert_eq(a.author_name, 'City Desk')
        assert_true(a.title:find('3', 1, true) ~= nil, 'digest title counts the changes: ' .. a.title)
        assert_true(a.body:find('Sales tax', 1, true) and a.body:find('Income tax', 1, true) and a.body:find('Vehicle tax', 1, true), a.body)
        assert_true(a.preset_id:find('^digest:gov.tax') ~= nil)
        local published = 0
        for _, b in ipairs(broadcasts) do if b.event == 'published' and b.app == 'news' then published = published + 1 end end
        assert_eq(published, 1, 'readers are told once; later events are updates')
        PFNews.Auto.Handle(ev(102, 'gov.tax.changed', { label = 'Income tax', oldRate = 10, newRate = 8 }))
        assert_eq(count(DB.articles), 1)
        assert_eq(#articlesWhere(function(r) return r.auto == 1 end)[1].body, #a.body, 'unchanged')
        -- a later change starts a new article
        Mock.clock = Mock.clock + 700
        PFNews.Auto.Handle(ev(104, 'gov.tax.changed', { label = 'Sales tax', oldRate = 7, newRate = 6 }))
        assert_eq(count(DB.articles), 2)
        -- both the news app and the news.ls site get the push
        local site = false
        for _, b in ipairs(broadcasts) do if b.app == 'site-news-ls' and b.event == 'published' then site = true end end
        assert_true(site, 'open news.ls pages refresh too')
    end)

    it('bulletins are breaking, notify only players with the app, and give the newsroom a lead', function()
        installed['CIDREAD:news'] = true
        PFNews.Auto.Handle(ev(201, 'crime.robbery.bank', { bank = 'Fleeca Legion' }, { district = 'legion', coords = { x = 150.0, y = -1040.0, z = 29.0 } }))
        local a = articlesWhere(function(r) return r.auto == 1 end)[1]
        assert_eq(a.breaking, 1)
        local notified = {}
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do notified[e.target] = true end
        assert_true(notified[READER], 'installed app gets the alert')
        assert_false(notified[OUTSIDER], 'no app, no alert')
        assert_eq(count(DB.leads), 1, 'reporters can cover the full story')
        assert_eq(DB.events[201].article_id, a.id)
        assert_eq(DB.events[201].lead_id, 1)
    end)

    it('lead kinds never publish; none is ignored; owner overrides apply; unknown auto kinds use the generic preset', function()
        PFNews.Auto.Handle(ev(301, 'crime.robbery.store', { store = 'LTD' }, { district = 'davis' }))
        PFNews.Auto.Handle(ev(302, 'police.impound', {}))
        assert_eq(count(DB.articles), 0)
        assert_eq(count(DB.leads), 1)
        Config.Auto.modes['gov.business.registered'] = 'lead'
        PFNews.Auto.Handle(ev(303, 'gov.business.registered', { businessName = 'Pops Diner' }))
        Config.Auto.modes['gov.business.registered'] = nil
        assert_eq(count(DB.articles), 0)
        assert_eq(count(DB.leads), 2)
        PFNews.Auto.Handle(ev(304, 'custom.festival', {}, { news = 'auto', title = 'Vinewood festival opens' }))
        assert_eq(articlesWhere(function(r) return r.auto == 1 end)[1].preset_id, 'generic/1')
    end)

    it('catch-up after a restart fills gaps only', function()
        PFNews.Auto.Handle(ev(401, 'gov.law.published', { name = 'Noise Act' }))
        PFNews.Auto.__reset() -- in-memory state gone, database kept
        recentEvents = {
            { id = 402, kind = 'gov.power.cut', news = 'auto', data = {}, district = 'Davis', at = Mock.clock },
            { id = 401, kind = 'gov.law.published', news = 'auto', data = { name = 'Noise Act' }, at = Mock.clock },
        }
        assert_eq(PFNews.Auto.CatchUp(), 2)
        assert_eq(count(DB.articles), 2, 'only the missed event was added')
    end)
end)

describe('pf-news leads and stories', function()
    local function leadEvent(id)
        PFNews.Auto.Handle(ev(id, 'crime.robbery.store', { store = 'LTD Grove' }, { district = 'davis', coords = { x = 10.0, y = 20.0, z = 30.0 } }))
        return DB.events[id].lead_id
    end

    it('claim needs a reporter on duty; one claimer; coordinates only for the claimer', function()
        local id = leadEvent(501)
        assert_eq(newsroom('claimLead', OUTSIDER, { id = id }).error, 'not_authorized')
        Mock.players[JUNIOR].PlayerData.job.onduty = false
        assert_eq(newsroom('claimLead', JUNIOR, { id = id }).error, 'off_duty')
        Mock.players[JUNIOR].PlayerData.job.onduty = true
        local res = newsroom('claimLead', JUNIOR, { id = id })
        assert_true(res.ok)
        assert_eq(res.coords.x, 10.0)
        assert_eq(newsroom('claimLead', SENIOR, { id = id }).error, 'lead_taken')
        local seen = PFNews.Leads.Active('CIDREP2')[1]
        assert_eq(seen.coords, nil, 'others do not get the location')
        assert_eq(newsroom('leadWaypoint', SENIOR, { id = id }).error, 'not_yours')
        assert_true(newsroom('leadWaypoint', JUNIOR, { id = id }).ok)
        -- the same kind in the same district merges into the lead
        Mock.clock = Mock.clock + 30
        PFNews.Auto.Handle(ev(502, 'crime.robbery.store', { store = 'LTD Grove' }, { district = 'davis' }))
        assert_eq(count(DB.leads), 1)
        assert_eq(DB.leads[id].hits, 2)
    end)

    it('junior writes, submits for review, editor approves: lead covered, bonus with lead bonus paid once after the hold', function()
        local id = leadEvent(601)
        assert_true(newsroom('claimLead', JUNIOR, { id = id }).ok)
        local body = string.rep('The store on Grove Street was robbed at gunpoint. ', 12)
        local saved = newsroom('save', JUNIOR, { title = 'Armed robbery on Grove Street', summary = 'Clerk unhurt', body = body, category = 'crime', leadId = id, breaking = true })
        assert_true(saved.ok, tostring(saved.error))
        assert_eq(DB.articles[saved.id].breaking, 0, 'only editors set breaking')
        assert_eq(newsroom('publish', JUNIOR, { id = saved.id }).error, 'needs_review')
        local sub = newsroom('submit', JUNIOR, { id = saved.id })
        assert_eq(sub.status, 'review')
        assert_eq(newsroom('reject', SENIOR, { id = saved.id, note = 'no' }).error, 'not_authorized', 'grade 2 is not an editor')
        assert_eq(newsroom('reject', EDITOR, { id = saved.id }).error, 'note_required')
        local pub = newsroom('publish', EDITOR, { id = saved.id })
        assert_true(pub.ok, tostring(pub.error))
        assert_true(pub.covered)
        assert_eq(DB.leads[id].status, 'covered')
        assert_eq(DB.payouts[saved.id].amount, Config.Pay.perArticle + Config.Pay.leadBonus)
        assert_eq(PFNews.Pay.Sweep(), 0, 'held for review time')
        Mock.clock = Mock.clock + Config.Pay.holdSeconds + 1
        assert_eq(PFNews.Pay.Sweep(), 1)
        assert_eq(Ledger.balances['player:CIDREP0:bank'], Config.Pay.perArticle + Config.Pay.leadBonus)
        assert_true(Ledger.byKey['pf-news:bonus:' .. saved.id].ok)
        assert_eq(PFNews.Pay.Sweep(), 0, 'paid once')
    end)

    it('grade rules: a senior publishes directly; a retracted story is not paid; short stories earn nothing; daily cap', function()
        local body = string.rep('City Hall met today to discuss the budget of the police. ', 10)
        local a = newsroom('save', SENIOR, { title = 'Budget talks at City Hall', body = body, category = 'government' })
        assert_eq(newsroom('submit', SENIOR, { id = a.id }).status, 'published')
        assert_eq(newsroom('retract', SENIOR, { id = a.id, note = 'x' }).error, 'not_authorized')
        assert_true(newsroom('retract', EDITOR, { id = a.id, note = 'Wrong facts' }).ok)
        assert_eq(DB.payouts[a.id].state, 'cancelled')
        Mock.clock = Mock.clock + 1000
        PFNews.Pay.Sweep()
        assert_eq(Ledger.balances['player:CIDREP2:bank'], nil, 'retracted before the hold ended: never paid')
        local short = newsroom('save', SENIOR, { title = 'Short note here', body = 'Short story with enough words to publish.' })
        local res = newsroom('submit', SENIOR, { id = short.id })
        assert_eq(res.pay.skipped, 'too_short')
        local saveCap = Config.Pay.dailyCap
        Config.Pay.dailyCap = 300
        local b = newsroom('save', SENIOR, { title = 'Second long story', body = body })
        newsroom('submit', SENIOR, { id = b.id })
        assert_eq(DB.payouts[b.id].amount, 250)
        local c = newsroom('save', SENIOR, { title = 'Third long story', body = body })
        newsroom('submit', SENIOR, { id = c.id })
        assert_eq(DB.payouts[c.id].amount, 50, 'capped at what is left today')
        Config.Pay.dailyCap = saveCap
    end)

    it('non-reporters are refused everywhere; validation of text, images and ownership', function()
        assert_eq(newsroom('save', OUTSIDER, { title = 'Fake news story' }).error, 'not_authorized')
        assert_eq(newsroom('dashboard', OUTSIDER).error, 'not_authorized')
        assert_eq(newsroom('save', JUNIOR, { title = 'abc' }).error, 'title_too_short')
        assert_eq(newsroom('save', JUNIOR, { title = 'Images test story', images = { 'http://evil.com/a.png' } }).error, 'bad_image')
        assert_eq(newsroom('save', JUNIOR, { title = 'Images test story', images = { 'https://x.com/a.png" onerror="alert(1)' } }).error, 'bad_image')
        assert_eq(newsroom('save', JUNIOR, { title = 'Images test story', images = { 'javascript:alert(1)' } }).error, 'bad_image')
        local ok = newsroom('save', JUNIOR, { title = '<b>Tagged</b> headline', body = '<script>x</script> text', images = { 'https://i.imgur.com/abc.png' } })
        assert_true(ok.ok)
        assert_eq(DB.articles[ok.id].title, 'bTagged/b headline', 'no markup is stored')
        assert_false(DB.articles[ok.id].body:find('<', 1, true) ~= nil)
        assert_eq(newsroom('save', SENIOR, { id = ok.id, title = 'Taking over this draft' }).error, 'not_authorized', 'not your draft')
        assert_eq(newsroom('save', JUNIOR, { title = 'Lead I do not hold', leadId = 999 }).error, 'lead_not_claimed')
        assert_eq(newsroom('delete', SENIOR, { id = ok.id }).error, 'not_authorized')
        assert_true(newsroom('delete', JUNIOR, { id = ok.id }).ok)
    end)

    it('a short grade ladder gives its top grade the editor role; the boss grade is an editor', function()
        local saved = QBCoreMock.Shared.Jobs.reporter
        QBCoreMock.Shared.Jobs.reporter = { grades = { ['0'] = { name = 'Journalist' } } }
        assert_true(PFNews.U.hasRole(Mock.players[JUNIOR].PlayerData.job, 'editor'))
        QBCoreMock.Shared.Jobs.reporter = saved
        assert_false(PFNews.U.hasRole(Mock.players[JUNIOR].PlayerData.job, 'editor'))
        Mock.players[JUNIOR].PlayerData.job.isboss = true
        assert_true(PFNews.U.hasRole(Mock.players[JUNIOR].PlayerData.job, 'editor'))
    end)

    it('the view counter counts each citizen once and never the author', function()
        local a = newsroom('save', SENIOR, { title = 'Views test story', body = string.rep('words here ', 10) })
        newsroom('submit', SENIOR, { id = a.id })
        local reader = PFNews.ReaderHandlers
        for _ = 1, 5 do reader.article(READER, { id = a.id }) end
        reader.article(SENIOR, { id = a.id })
        assert_eq(DB.articles[a.id].views, 1)
        reader.article(OUTSIDER, { id = a.id })
        assert_eq(DB.articles[a.id].views, 2)
        assert_eq(reader.article(READER, { id = 9999 }).error, 'not_found')
        local s = reader.search(READER, { q = 'Views test' })
        assert_eq(#s.articles, 1)
        assert_eq(reader.search(READER, { q = 'x' }).error, 'query_too_short')
    end)

    it('old leads expire', function()
        local id = leadEvent(701)
        Mock.clock = Mock.clock + Config.Leads.openMinutes * 60 + 5
        PFNews.Leads.Sweep()
        assert_eq(DB.leads[id].status, 'expired')
        assert_eq(newsroom('claimLead', JUNIOR, { id = id }).error, 'lead_taken')
    end)
end)

describe('pf-news ads', function()
    it('only a boss or registered owner buys, paid from the business account with the ad key', function()
        Ledger.balances['society:burgershot'] = 5000
        local opts = PFNews.ReaderHandlers.adOptions(BOSS)
        assert_eq(#opts.businesses, 1)
        assert_eq(opts.businesses[1].id, 'job:burgershot')
        assert_eq(#PFNews.ReaderHandlers.adOptions(READER).businesses, 0)
        Mock.players[EDITOR].PlayerData.job.isboss = true
        assert_eq(#PFNews.Ads.Eligible(EDITOR), 0, 'the news job cannot pay itself')
        assert_eq(PFNews.ReaderHandlers.buyAd(READER, { businessId = 'job:burgershot', durationId = '1d', text = 'Best burgers in town' }).error, 'not_business_owner')
        assert_eq(PFNews.ReaderHandlers.buyAd(BOSS, { businessId = 'job:burgershot', durationId = '99d', text = 'Best burgers in town' }).error, 'bad_duration')
        assert_eq(PFNews.ReaderHandlers.buyAd(BOSS, { businessId = 'job:burgershot', durationId = '1d', text = 'short' }).error, 'text_too_short')
        assert_eq(PFNews.ReaderHandlers.buyAd(BOSS, { businessId = 'job:burgershot', durationId = '1d', text = 'Best burgers in town', image = 'http://x.png' }).error, 'bad_image')
        local res = PFNews.ReaderHandlers.buyAd(BOSS, { businessId = 'job:burgershot', durationId = '1d', text = 'Best burgers in town', image = 'https://i.imgur.com/b.png' })
        assert_true(res.ok, tostring(res.error))
        local tx = Ledger.byKey['pf-news:ad:' .. res.id]
        assert_true(tx and tx.ok)
        assert_eq(Ledger.log[1].from, 'society:burgershot')
        assert_eq(Ledger.log[1].to, 'society:reporter')
        assert_eq(Ledger.log[1].amount, 400)
        assert_eq(Ledger.balances['society:burgershot'], 4600)
        local front = PFNews.ReaderHandlers.front(READER)
        assert_eq(#front.front.ads, 1)
        assert_eq(front.front.ads[1].business, 'Burger Shot')
        assert_eq(front.front.ads[1].buyer, nil, 'readers do not see the buyer')
    end)

    it('registry owners buy from the business account; no money, no ad', function()
        DB.gov[1] = { business_id = 'store:ltd1', business_name = 'LTD Grove', owner_id = 'CIDREAD', account_ref = 'society:store_ltd1', business_status = 'active' }
        DB.gov[2] = { business_id = 'store:closed', business_name = 'Closed Shop', owner_id = 'CIDREAD', account_ref = 'society:store_closed', business_status = 'closed' }
        local list = PFNews.Ads.Eligible(READER)
        assert_eq(#list, 1)
        assert_eq(list[1].account, 'society:store_ltd1')
        local res = PFNews.ReaderHandlers.buyAd(READER, { businessId = 'store:ltd1', durationId = '3d', text = 'Open all night on Grove' })
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(DB.ads[res.id].status, 'failed')
        assert_eq(#Ledger.log, 0)
    end)

    it('a rejected ad is refunded once; a refund that fails is retried with its next key', function()
        Ledger.balances['society:burgershot'] = 5000
        local res = PFNews.ReaderHandlers.buyAd(BOSS, { businessId = 'job:burgershot', durationId = '3d', text = 'Two for one on Fridays' })
        assert_eq(newsroom('rejectAd', OUTSIDER, { id = res.id, note = 'x' }).error, 'not_authorized')
        Ledger.balances['society:reporter'] = 0 -- the company spent the money meanwhile
        local rej = newsroom('rejectAd', JUNIOR, { id = res.id, note = 'Misleading' })
        assert_true(rej.ok)
        assert_true(rej.refundPending)
        assert_false(Ledger.byKey['pf-news:ad:' .. res.id .. ':refund'].ok)
        assert_eq(newsroom('rejectAd', JUNIOR, { id = res.id, note = 'again' }).error, 'not_active')
        Ledger.balances['society:reporter'] = 2000
        PFNews.Ads.Sweep()
        assert_true(Ledger.byKey['pf-news:ad:' .. res.id .. ':refund:1'].ok)
        assert_eq(DB.ads[res.id].refund_state, 'done')
        assert_eq(Ledger.balances['society:burgershot'], 5000)
        PFNews.Ads.Sweep()
        assert_eq(Ledger.balances['society:burgershot'], 5000, 'refunded once')
    end)

    it('slots are limited per business and in total', function()
        Ledger.balances['society:burgershot'] = 50000
        for i = 1, Config.Ads.maxPerBusiness do
            assert_true(PFNews.ReaderHandlers.buyAd(BOSS, { businessId = 'job:burgershot', durationId = '1d', text = 'Burger deal number ' .. i }).ok)
        end
        assert_eq(PFNews.ReaderHandlers.buyAd(BOSS, { businessId = 'job:burgershot', durationId = '1d', text = 'One more burger deal' }).error, 'business_limit')
        Mock.clock = Mock.clock + 25 * 3600
        PFNews.Ads.Sweep()
        assert_eq(DB.ads[1].status, 'expired')
        assert_true(PFNews.ReaderHandlers.buyAd(BOSS, { businessId = 'job:burgershot', durationId = '1d', text = 'A fresh burger deal' }).ok)
    end)
end)

describe('pf-news apps', function()
    it('one reader module is the News app and the news.ls site, with the same handlers', function()
        assert_true(PFNews.RegisterApps())
        assert_eq(registered.news.access.installable, true)
        assert_eq(registered.news.store.publisher, 'Weazel News')
        assert_eq(registered.news.category, 'media')
        assert_eq(siteDefs['news.ls'].entry, registered.news.entry)
        assert_eq(siteDefs['news.ls'].access.anyone, true)
        for method, fn in pairs(appHandlers.news) do assert_eq(siteHandlers['news.ls'][method], fn, method) end
        assert_eq(registered.newsroom.access.jobs.reporter, 0)
        assert_eq(registered.newsroom.devices[1], 'tablet')
    end)

    it('the newsroom dashboard shows staff on duty and their field vehicle', function()
        local d = newsroom('dashboard', EDITOR)
        assert_true(d.ok)
        assert_true(d.me.roles.editor)
        local names = {}
        for _, s in ipairs(d.staff) do names[s.name] = s end
        assert_eq(names['Test Player2'].field, 'Rumpo')
        assert_eq(#d.staff, 3)
    end)
end)
