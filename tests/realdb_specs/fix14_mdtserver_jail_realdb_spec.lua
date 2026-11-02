-- pf-policemdt-DEV sentencing on the real database and the real ledger (batch 14):
--   * the migrations create the jail, payment-state and audit tables, and can run again;
--   * a fine is one transfer keyed by the sentence row, from the citizen's bank to the police society;
--     a citizen who cannot pay is not charged and not jailed; a fine the bank cannot confirm waits as
--     'payment_pending' and is finished (fine and jail) once the ledger's recovery completes it;
--   * the citizen must be with the officer, and in custody for jail time; totals are capped;
--   * the jail is the server's: the row holds the time and the confiscated items, the time counts down
--     only while the prisoner is online and inside, an escapee is sent back, a reconnect resumes, the
--     items come back once, and a client saying "time is up" early is ignored;
--   * bail is offered to a payer who accepts and pays from their own bank (keyed), then the prisoner is
--     released; a payer who is not with the officer is refused;
--   * a citation is printed only at the printer when one is configured, and not twice in a row.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-services'] = 'missing', ['pf-devices'] = 'missing', ['ox_inventory'] = 'missing', ['pfm-inventory'] = 'missing',
    ['lj-inventory'] = 'missing', ['ps-inventory'] = 'missing', ['qs-inventory'] = 'missing', ['rcore_prison'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
MySQL.query.await([[CREATE TABLE IF NOT EXISTS `pf_mdt_charges` (
  `id` INT NOT NULL AUTO_INCREMENT, `code` VARCHAR(16) NOT NULL UNIQUE, `name` VARCHAR(128) NOT NULL, `description` LONGTEXT NULL,
  `fineAmount` INT NOT NULL DEFAULT 0, `bailAmount` INT NOT NULL DEFAULT 0, `prisonTime` INT NOT NULL DEFAULT 0, `category` VARCHAR(64) NULL,
  PRIMARY KEY (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
MySQL.query.await([[INSERT INTO pf_mdt_charges (code, name, fineAmount, bailAmount, prisonTime) VALUES
  ('F1', 'Speeding', 300, 0, 0), ('J1', 'Robbery', 0, 500, 10), ('BIG', 'Killing a Police Officer', 100000, 200000, 360),
  ('BIG2', 'Torture', 100000, 100000, 300)]])

QBCoreMock.Shared.Jobs = { police = { label = 'Police', grades = { ['0'] = { name = 'Recruit' }, ['4'] = { name = 'Chief', isboss = true } } } }
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

-- oxmysql's export API over the real database (main.lua uses it)
local function ox(kind)
    return function(_, sql, params, cb)
        if Mock.callable(params) then cb, params = params, nil end
        local r = MySQL[kind].await(sql, params)
        if cb then cb(r) end
        return r
    end
end
Mock.exportsByResource['oxmysql'] = { execute = ox('query'), query = ox('query'), fetch = ox('query'), insert = ox('insert'), update = ox('update'), scalar = ox('scalar'), single = ox('single') }

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/sentencing.lua')
local S = PFMdtSentencing
assert(S.Start(), 'pf-policemdt migrations')
Config.Citations.PrinterCoords = nil
Config.Citations.PrintFromMDT = true

local OFFICER, CITIZEN, PAYER, FAR = 1, 2, 3, 4
local STATION = vector3(441.0, -981.0, 30.7)   -- a booking area
local STREET = vector3(100.0, 100.0, 30.0)
local CELL = vector3(1700.0, 2570.0, 45.0)     -- inside the prison
local OUTSIDE = vector3(2400.0, 3000.0, 40.0)

local function player(src, cid, bank, job)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = bank or 0 }
    p.PlayerData.job = job or { name = 'unemployed', grade = { level = 0 }, onduty = false }
    p.PlayerData.items = {}
    p.Functions.ClearInventory = function() p.PlayerData.items = {} end
    p.Functions.RemoveItem = function() return true end
    p.Functions.AddItem = function(name, amount, slot, info)
        table.insert(p.PlayerData.items, { name = name, amount = amount, slot = slot, info = info })
        return true
    end
    return p
end
local function count(src, name)
    local n = 0
    for _, it in pairs(Mock.players[src].PlayerData.items) do if it.name == name then n = n + it.amount end end
    return n
end
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function society() return tonumber(MySQL.scalar.await("SELECT account_balance FROM bank_accounts WHERE account_name = 'police'")) or 0 end
local function jailRow(cid) return MySQL.single.await('SELECT * FROM pf_mdt_active_jails WHERE citizenid = ?', { cid }) end
local function sentenceRow(id) return MySQL.single.await('SELECT * FROM pf_mdt_sentences WHERE id = ?', { id }) end
local function sent(name, target)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if target == nil or e.target == target then n = n + 1 end end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.clock = Mock.clock + 1000 -- each test starts later (the "just sentenced" guard is per officer and citizen)
    MySQL.query.await('DELETE FROM pf_mdt_active_jails')
    MySQL.query.await('DELETE FROM pf_mdt_sentences')
    MySQL.query.await("DELETE FROM pf_transactions WHERE idempotency_key LIKE 'pf-policemdt:%'")
    MySQL.query.await("UPDATE bank_accounts SET account_balance = 0 WHERE account_name = 'police'")
    player(OFFICER, 'OFF1', 0, { name = 'police', label = 'Police', grade = { level = 2 }, onduty = true })
    player(CITIZEN, 'CIT2', 1000)
    player(PAYER, 'PAY3', 5000)
    player(FAR, 'FAR4', 5000)
    Mock.players[CITIZEN].PlayerData.items = { { name = 'phone', amount = 1, slot = 1 }, { name = 'lockpick', amount = 3, slot = 2 } }
    Mock.coords[OFFICER], Mock.coords[CITIZEN], Mock.coords[PAYER], Mock.coords[FAR] = STREET, STREET, STREET, OUTSIDE
    Mock.gameTimer = Mock.gameTimer + 1000000 -- the per-player rate limits start clear
end

local function sentence(charges, kind, extra)
    local data = { citizenId = 'CIT2', citizenName = 'Test Player2', title = 'Booking', sentenceType = kind or 'fine', charges = charges }
    for k, v in pairs(extra or {}) do data[k] = v end
    return Mock.callCallback('pf_mdt:createSentence', OFFICER, data)
end
local function jailCitizen()
    Mock.coords[OFFICER], Mock.coords[CITIZEN] = STATION, STATION
    local res = sentence({ 'J1' }, 'sentence')
    assert_eq(res.success, true, tostring(res.error))
    Mock.coords[CITIZEN] = CELL
    return res
end

describe('MDT database', function()
    it('the migrations made the tables and can run again', function()
        assert_eq(RunMigrations('pf-policemdt-DEV', S.Migrations), true)
        for _, t in ipairs({ 'pf_mdt_active_jails', 'pf_mdt_sentences', 'pf_mdt_license_actions', 'pf_mdt_charge_audit', 'pf_mdt_roster_backup' }) do
            assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t })), 1, t)
        end
        -- the steps themselves are rerun-safe (an interrupted migration starts again from its first step)
        for _, m in ipairs(S.Migrations) do
            for _, sql in ipairs(m.up) do MySQL.query.await(sql) end
        end
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_mdt_sentences' AND COLUMN_NAME = 'fine_key'")), 1)
    end)
end)

describe('MDT fines through the ledger', function()
    it('one keyed transfer from the citizen to the police society', function()
        local res = sentence({ 'F1' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(bank(CITIZEN), 700)
        assert_eq(society(), 300)
        local key = 'pf-policemdt:fine:' .. res.id
        local tx = MySQL.single.await('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { key })
        assert_eq(tx.state, 'completed')
        assert_eq(tx.from_account, 'player:CIT2:bank')
        assert_eq(tx.to_account, 'society:police')
        local row = sentenceRow(res.id)
        assert_eq(row.status, 'done')
        assert_eq(tonumber(row.fineSuccess), 1)
        assert_eq(row.fine_key, key)
    end)
    it('a citizen who cannot pay is not charged, and the sentence is marked failed', function()
        Mock.players[CITIZEN].PlayerData.money.bank = 50
        local res = sentence({ 'F1' })
        assert_eq(res.success, false)
        assert_eq(res.error, 'Insufficient bank funds')
        assert_eq(bank(CITIZEN), 50)
        assert_eq(society(), 0)
        assert_eq(sentenceRow(res.id).status, 'failed')
    end)
    it('a fine+sentence that cannot be paid jails nobody', function()
        Mock.players[CITIZEN].PlayerData.money.bank = 50
        Mock.coords[OFFICER], Mock.coords[CITIZEN] = STATION, STATION
        local res = sentence({ 'F1', 'J1' }, 'fine+sentence')
        assert_eq(res.success, false)
        assert_eq(jailRow('CIT2'), nil)
        assert_eq(count(CITIZEN, 'phone'), 1)
    end)
    it('a fine the bank could not confirm waits, and is finished once the ledger settles it', function()
        Mock.coords[OFFICER], Mock.coords[CITIZEN] = STATION, STATION
        -- the write that completes the transfer fails: the money left the citizen, the society has not got it
        local realUpdate = MySQL.update
        local fail = true
        MySQL.update = setmetatable({ await = function(q, p)
            if fail and q == PFLedger.SQL.creditSociety then fail = false; error('injected: connection lost') end
            return realUpdate.await(q, p)
        end }, { __call = function(_, ...) return realUpdate(...) end })
        local res = sentence({ 'F1', 'J1' }, 'fine+sentence')
        MySQL.update = realUpdate
        assert_eq(res.success, false)
        assert_eq(res.pending, true, tostring(res.error))
        local row = sentenceRow(res.id)
        assert_eq(row.status, 'payment_pending')
        assert_eq(jailRow('CIT2'), nil, 'no jail before the fine is confirmed')
        S.Tick()
        assert_eq(sentenceRow(res.id).status, 'payment_pending', 'still waiting while the ledger has not settled')
        -- the ledger's recovery completes the transfer, then the tick finishes the sentence
        MySQL.update.await('UPDATE pf_transactions SET updated_at = NOW() - INTERVAL 1 HOUR WHERE idempotency_key = ?', { 'pf-policemdt:fine:' .. res.id })
        PFLedger.Recover()
        S.Tick()
        row = sentenceRow(res.id)
        assert_eq(row.status, 'done')
        assert_eq(tonumber(row.fineSuccess), 1)
        assert_eq(tonumber(row.jailSuccess), 1)
        assert_true(jailRow('CIT2') ~= nil, 'jailed once the fine was paid')
        assert_eq(bank(CITIZEN), 700, 'charged once')
        assert_eq(society(), 300)
        S.Tick()
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'pf-policemdt:fine:%'")), 1)
    end)
    it('without the ledger nothing is charged and nobody is sentenced', function()
        states['pfm-banking'] = 'stopped'
        local res = sentence({ 'F1' })
        states['pfm-banking'] = nil
        assert_eq(res.success, false)
        assert_eq(bank(CITIZEN), 1000)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_mdt_sentences')), 0)
    end)
    it('the totals are capped at the statutory maximums', function()
        Mock.players[CITIZEN].PlayerData.money.bank = 500000
        local res = sentence({ 'BIG', 'BIG2' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(res.fineAmount, Config.Sentencing.MaxFine)
        assert_eq(bank(CITIZEN), 500000 - Config.Sentencing.MaxFine)
    end)
end)

describe('MDT sentencing needs the citizen present', function()
    it('a citizen across the map, an offline one or the officer themself cannot be sentenced', function()
        Mock.coords[CITIZEN] = OUTSIDE
        assert_eq(sentence({ 'F1' }).error, 'The suspect must be with you')
        assert_eq(Mock.callCallback('pf_mdt:createSentence', OFFICER, { citizenId = 'NOBODY', title = 'x', charges = { 'F1' } }).success, false)
        assert_eq(Mock.callCallback('pf_mdt:createSentence', OFFICER, { citizenId = 'OFF1', title = 'x', charges = { 'F1' } }).error, 'You cannot sentence yourself')
        assert_eq(bank(CITIZEN), 1000)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_mdt_sentences')), 0)
    end)
    it('an officer off duty cannot sentence', function()
        Mock.players[OFFICER].PlayerData.job.onduty = false
        local res = sentence({ 'F1' })
        assert_eq(res.error, 'off_duty')
        assert_eq(bank(CITIZEN), 1000)
    end)
    it('jail time needs the citizen in handcuffs or at a booking desk', function()
        local res = sentence({ 'J1' }, 'sentence')
        assert_eq(res.success, false)
        assert_eq(res.error, 'The suspect must be handcuffed or at a booking desk')
        assert_eq(count(CITIZEN, 'phone'), 1)
        Mock.players[CITIZEN].PlayerData.metadata.ishandcuffed = true
        res = sentence({ 'J1' }, 'sentence')
        assert_eq(res.success, true, tostring(res.error))
    end)
end)

describe('the server-owned jail', function()
    it('stores the items and the time before clearing the inventory', function()
        local res = jailCitizen()
        local row = jailRow('CIT2')
        assert_eq(tonumber(row.remaining_seconds), 600)
        assert_eq(tonumber(row.sentence_id), res.id)
        assert_eq(tonumber(row.bail_amount), 500)
        local items = json.decode(row.items)
        assert_eq(#items, 2)
        assert_eq(count(CITIZEN, 'phone'), 0)
        assert_eq(sent('pf_mdt:client:StartMdtSentence', CITIZEN), 1)
    end)
    it('counts down only while the prisoner is online and inside, then releases once with the items', function()
        jailCitizen()
        S.Tick()                                  -- starts the count
        Mock.clock = Mock.clock + 15; S.Tick()
        assert_eq(tonumber(jailRow('CIT2').remaining_seconds), 585)
        -- offline: no time served
        local p = Mock.players[CITIZEN]
        Mock.players[CITIZEN] = nil
        Mock.clock = Mock.clock + 300; S.Tick()
        assert_eq(tonumber(jailRow('CIT2').remaining_seconds), 585)
        -- back online (a reconnect): sent back to a cell with the time left
        Mock.players[CITIZEN] = p
        p.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 } } -- an old save came back
        Mock.reset()
        S.Resume(CITIZEN)
        local starts = Mock.clientEventsNamed('pf_mdt:client:StartMdtSentence')
        assert_eq(#starts, 1)
        assert_eq(starts[1].args[1].seconds, 585)
        assert_eq(count(CITIZEN, 'phone'), 0, 'the old save is not used in jail')
        -- serve the rest
        for _ = 1, 45 do Mock.clock = Mock.clock + 15; S.Tick() end
        assert_eq(jailRow('CIT2'), nil)
        assert_eq(count(CITIZEN, 'phone'), 1, 'items back once')
        assert_eq(count(CITIZEN, 'lockpick'), 3)
        assert_eq(sent('pf_mdt:client:ReleaseMdtSentence', CITIZEN), 1)
        assert_eq(S.Release('CIT2', 'served'), false, 'a second release does nothing')
        assert_eq(count(CITIZEN, 'phone'), 1)
    end)
    it('a prisoner outside the prison is sent back and serves no time out there', function()
        jailCitizen()
        S.Tick()
        Mock.clock = Mock.clock + 30
        Mock.coords[CITIZEN] = OUTSIDE
        Mock.reset()
        S.Tick()
        assert_eq(tonumber(jailRow('CIT2').remaining_seconds), 600, 'no time served outside')
        assert_eq(sent('pf_mdt:client:StartMdtSentence', CITIZEN), 1, 'sent back to a cell')
    end)
    it('a client that says its timer ran out early gets nothing; at the end it is released', function()
        jailCitizen()
        Mock.fireNet('pf_mdt:server:mdtSentenceReleased', CITIZEN)
        assert_true(jailRow('CIT2') ~= nil)
        assert_eq(count(CITIZEN, 'phone'), 0)
        MySQL.update.await("UPDATE pf_mdt_active_jails SET remaining_seconds = 10 WHERE citizenid = 'CIT2'")
        Mock.fireNet('pf_mdt:server:mdtSentenceReleased', CITIZEN)
        assert_eq(jailRow('CIT2'), nil)
        assert_eq(count(CITIZEN, 'phone'), 1)
    end)
    it('survives a restart of the resource: the row is in the database', function()
        jailCitizen()
        -- a fresh copy of the module (its memory is gone) still finds the prisoner
        S.dbReady = true
        assert_true(S.JailOf('CIT2') ~= nil)
        assert_eq(tonumber(S.JailOf('CIT2').remaining_seconds), 600)
    end)
    it('a citizen already in jail cannot be jailed again', function()
        jailCitizen()
        Mock.coords[CITIZEN] = STATION
        Mock.clock = Mock.clock + 10
        local res = sentence({ 'J1' }, 'sentence')
        assert_eq(res.success, false)
        assert_eq(res.error, 'Citizen is already serving a sentence')
    end)
end)

describe('MDT bail', function()
    local function offer(payer)
        return Mock.callCallback('pf_mdt:postBail', OFFICER, { prisonerCitizenId = 'CIT2', payerCitizenId = payer or 'PAY3' })
    end
    it('the payer accepts and pays from their own bank; the prisoner is released with the items', function()
        local res = jailCitizen()
        Mock.coords[OFFICER], Mock.coords[PAYER] = STREET, STREET
        local o = offer()
        assert_eq(o.success, true, tostring(o.error))
        assert_eq(o.pending, true)
        assert_eq(bank(PAYER), 5000, 'nothing taken before the payer accepts')
        local ok, msg = S.AcceptBail(PAYER)
        assert_eq(ok, true, tostring(msg))
        assert_eq(bank(PAYER), 4500)
        assert_eq(society(), 500)
        assert_eq(jailRow('CIT2'), nil)
        assert_eq(count(CITIZEN, 'phone'), 1)
        assert_eq(tonumber(sentenceRow(res.id).bailed), 1)
        assert_eq(sentenceRow(res.id).bailPaidByCitizenId, 'PAY3')
        assert_eq(S.AcceptBail(PAYER), false, 'the offer is used up')
        assert_eq(bank(PAYER), 4500)
    end)
    it('a payer far from the officer and from any bail desk is refused', function()
        jailCitizen()
        local o = offer('FAR4')
        assert_eq(o.success, false)
        assert_eq(o.error, 'The payer must be with you or at a bail desk')
        assert_eq(bank(FAR), 5000)
    end)
    it('a bail payment the bank could not confirm holds the prisoner until the ledger settles it', function()
        local res = jailCitizen()
        Mock.coords[PAYER] = STATION
        assert_eq(offer().success, true)
        local realUpdate = MySQL.update
        local fail = true
        MySQL.update = setmetatable({ await = function(q, p)
            if fail and q == PFLedger.SQL.creditSociety then fail = false; error('injected: connection lost') end
            return realUpdate.await(q, p)
        end }, { __call = function(_, ...) return realUpdate(...) end })
        local ok = S.AcceptBail(PAYER)
        MySQL.update = realUpdate
        assert_eq(ok, false)
        local row = jailRow('CIT2')
        assert_true(row ~= nil and row.bail_key ~= nil, 'the payment is remembered')
        Mock.gameTimer = Mock.gameTimer + 10000
        assert_eq(offer().error, 'A bail payment for this prisoner is still being confirmed by the bank', 'no second bail meanwhile')
        MySQL.update.await('UPDATE pf_transactions SET updated_at = NOW() - INTERVAL 1 HOUR WHERE idempotency_key = ?', { row.bail_key })
        PFLedger.Recover()
        S.Tick()
        assert_eq(jailRow('CIT2'), nil, 'released once the bail was confirmed')
        assert_eq(tonumber(sentenceRow(res.id).bailed), 1)
        assert_eq(bank(PAYER), 4500, 'paid once')
        assert_eq(count(CITIZEN, 'phone'), 1)
    end)
    it('a payer who cannot pay keeps their money and the prisoner stays', function()
        jailCitizen()
        Mock.coords[PAYER] = STATION -- with the officer
        Mock.players[PAYER].PlayerData.money.bank = 100
        assert_eq(offer().success, true)
        local ok = S.AcceptBail(PAYER)
        assert_eq(ok, false)
        assert_eq(bank(PAYER), 100)
        assert_true(jailRow('CIT2') ~= nil)
    end)
end)

describe('MDT citation printing', function()
    it('needs the printer when one is configured, and prints one copy at a time', function()
        local res = sentence({ 'F1' })
        Config.Citations.PrinterCoords = { x = 441.0, y = -978.0, z = 30.7 }
        local far = Mock.callCallback('pf_mdt:printCitationPaper', OFFICER, { sentenceId = res.id })
        assert_eq(far.success, false)
        Mock.coords[OFFICER] = vector3(441.0, -978.0, 30.7)
        Mock.players[OFFICER].Functions.AddItem = function() return true end
        assert_eq(Mock.callCallback('pf_mdt:printCitationPaper', OFFICER, { sentenceId = res.id }).success, true)
        assert_eq(Mock.callCallback('pf_mdt:printCitationPaper', OFFICER, { sentenceId = res.id }).success, false, 'not twice in a row')
        Config.Citations.PrinterCoords = nil
        Config.Citations.PrintFromMDT = false
        assert_eq(Mock.callCallback('pf_mdt:printCitationPaper', OFFICER, { sentenceId = res.id + 1 }).success, false, 'printing from the MDT is off')
        Config.Citations.PrintFromMDT = true
    end)
end)
