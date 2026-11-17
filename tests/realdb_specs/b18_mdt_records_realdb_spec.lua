-- Batch 18F (pf-policemdt-DEV server/records_ext.lua + main.lua) on MariaDB, on the MDT's own
-- migrated tables (schema v1-v8):
--   * warrants v2: created pending_approval with a server id/expiry; a supervisor (never the
--     requester) approves once (compare-and-set); a filed judge review blocks supervisors and only
--     the matching SetWarrantApproval decides; served links the suspect's own custody; removal needs
--     its grade; the sweep expires; legacy warrants can still be served; every change is audited;
--   * BOLO board: a vehicle BOLO shows in GetPlateFlags (BOLO + id) and is announced; only the
--     author or a supervisor clears it; the sweep expires it;
--   * vehicle flags: single-select, whitelisted, normalised plates, cache rebuilt from old rows;
--   * vehicle activity: MDT changes and pfm-policejob ALPR hits are written, the profile shows them;
--   * record audit rows for reads, retention prune;
--   * expungement and incident deletion are soft deletes with audit rows, hidden from the MDT.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = {}
function GetResourceState(name) return states[name] or 'missing' end
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end
-- real time: warrant expiry is compared with the database's NOW()
Mock.clock = os.time(os.date('*t'))

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
RealDB.exec('pfm-clothing/qb-clothing.sql')
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
local function ox(kind)
    return function(_, sql, params, cb)
        if Mock.callable(params) then cb, params = params, nil end
        local r = MySQL[kind].await(sql, params)
        if cb then cb(r) end
        return r
    end
end
Mock.exportsByResource['oxmysql'] = { execute = ox('query'), query = ox('query'), fetch = ox('query'), insert = ox('insert'),
    update = ox('update'), scalar = ox('scalar'), single = ox('single') }
local Emits = {}
Mock.exportsByResource['pf-services'] = { Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, data = data } return #Emits end }

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/schema.lua')
assert(PFMdtSchema.Run(), 'schema: ' .. tostring(PFMdtSchema.lastError))
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/records_ext.lua')
local R = PFMdtRecords
assert(R.Start(), 'records start')

MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata) VALUES
  ('SUS1', 1, 'license:s1', 'Rob', '{}', '{"firstname":"Rob","lastname":"Banks"}', '{}', '{}', '{}', '{}'),
  ('SUS2', 2, 'license:s2', 'Amy', '{}', '{"firstname":"Amy","lastname":"Ash"}', '{}', '{}', '{}', '{}')]])

local OFFICER, SGT, CHIEF, LT = 1, 2, 3, 4
local function one(sql, p) return MySQL.single.await(sql, p or {}) end
local function n(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local function audits(entity, id) return n('SELECT COUNT(*) FROM pf_mdt_record_audit WHERE entity = ? AND entity_id = ?', { entity, tostring(id) }) end
local function setJob(src, grade, cid)
    Mock.newPlayer(src, cid).PlayerData.job = { name = 'police', label = 'Police', onduty = true, grade = { level = grade } }
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.gameTimer = Mock.gameTimer + 1000000
    Mock.invokingResource = nil
    states = { ['pf-services'] = 'started' }
    Emits = {}
    setJob(OFFICER, 1, 'OFF1')
    setJob(SGT, 3, 'SGT1')
    setJob(CHIEF, 5, 'CHF1')
    setJob(LT, 4, 'LT1')
    for src in pairs(Mock.players) do Mock.coords[src] = vector3(100.0, 100.0, 30.0) end
end

local function newWarrant(src, extra)
    Mock.gameTimer = Mock.gameTimer + 100000
    local data = { type = 'arrest', suspectCitizenId = 'SUS1', charges = { 'Robbery' }, narrative = 'affidavit' }
    for k, v in pairs(extra or {}) do data[k] = v end
    local res = R.CreateWarrant(src, data)
    assert_eq(res.success, true, tostring(res.error))
    return res.warrantId
end

describe('warrants v2 (MariaDB)', function()
    it('a new warrant is pending approval with the server id, suspect and expiry; the requester cannot approve it', function()
        local id = newWarrant(LT)
        local w = one('SELECT *, TIMESTAMPDIFF(DAY, NOW(), expiresAt) AS days FROM pf_mdt_warrants WHERE warrantId = ?', { id })
        assert_eq(w.status, 'pending')
        assert_eq(w.approval_state, 'pending_approval')
        assert_eq(w.suspectCitizenId, 'SUS1')
        assert_eq(w.suspectName, 'Rob Banks')
        assert_eq(w.warrant_type, 'arrest')
        assert_true(tonumber(w.days) >= 13 and tonumber(w.days) <= 14, 'arrest default 14 days, got ' .. tostring(w.days))
        assert_eq(audits('warrant', id), 1)
        assert_eq(#Emits, 0, 'no court lead before approval')
        assert_eq(R.ReviewWarrant(LT, { warrantId = id, decision = 'approve' }).error, 'own_warrant')
        assert_eq(R.ReviewWarrant(SGT, { warrantId = id, decision = 'approve' }).error, 'no_permission')
    end)
    it('a supervisor approves once; the warrant becomes active and is a court lead', function()
        local id = newWarrant(OFFICER)
        local res = R.ReviewWarrant(CHIEF, { warrantId = id, decision = 'approve' })
        assert_eq(res.success, true, tostring(res.error))
        local w = one('SELECT * FROM pf_mdt_warrants WHERE warrantId = ?', { id })
        assert_eq(w.status, 'active')
        assert_eq(w.approval_state, 'approved')
        assert_eq(w.approved_by, 'supervisor:CHF1')
        assert_eq(R.ReviewWarrant(LT, { warrantId = id, decision = 'deny' }).error, 'invalid_state', 'decided once')
        assert_eq(#Emits, 1)
        assert_eq(Emits[1].kind, 'police.warrant')
        assert_eq(Emits[1].data.suspect, 'Rob Banks')
        assert_eq(audits('warrant', id), 2)
    end)
    it('with a filed judge review only the matching pf-justice decision counts', function()
        states['pf-justice'] = 'started'
        Mock.exportsByResource['pf-justice'] = { RequestWarrantReview = function() return { ok = true, reviewId = 77 } end }
        local id = newWarrant(OFFICER, { type = 'search', address = '12 Grove St' })
        assert_eq(one('SELECT review_id FROM pf_mdt_warrants WHERE warrantId = ?', { id }).review_id, 77)
        assert_eq(R.ReviewWarrant(CHIEF, { warrantId = id, decision = 'approve' }).error, 'judge_review')
        Mock.invokingResource = 'pfm-policejob'
        assert_eq(Mock.selfExport('SetWarrantApproval')(id, 'approve', { reviewId = 77 }).error, 'not_allowed')
        Mock.invokingResource = 'pf-justice'
        assert_eq(Mock.selfExport('SetWarrantApproval')(id, 'approve', { reviewId = 5 }).error, 'conflict')
        assert_eq(Mock.selfExport('SetWarrantApproval')(id, 'needs_info', { reviewId = 77, judgeCid = 'J1' }).ok, true)
        assert_eq(one('SELECT approval_state, status FROM pf_mdt_warrants WHERE warrantId = ?', { id }).approval_state, 'needs_info')
        assert_eq(Mock.selfExport('SetWarrantApproval')(id, 'approve', { reviewId = 77, judgeCid = 'J1' }).ok, true)
        local w = one('SELECT * FROM pf_mdt_warrants WHERE warrantId = ?', { id })
        assert_eq(w.status, 'active')
        assert_eq(w.approved_by, 'judge:J1')
        assert_eq(w.address, '12 Grove St')
        assert_eq(Mock.selfExport('SetWarrantApproval')(id, 'deny', { reviewId = 77 }).error, 'invalid_state')
        Mock.invokingResource = nil
        Mock.exportsByResource['pf-justice'] = nil
    end)
    it('served links the suspect\'s own custody; a custody of someone else is refused; pending cannot be served', function()
        local pending = newWarrant(OFFICER)
        assert_eq(R.SetWarrantStatus(OFFICER, { warrantId = pending, status = 'served' }).error, 'invalid_state')
        local id = newWarrant(OFFICER)
        R.ReviewWarrant(CHIEF, { warrantId = id, decision = 'approve' })
        states['pf-justice'] = 'started'
        Mock.exportsByResource['pf-justice'] = { GetCustody = function(_, cid) return { ok = true, custody = { id = 9, cid = cid, state = 'booked' } } end }
        assert_eq(R.SetWarrantStatus(OFFICER, { warrantId = id, status = 'served', custodyId = 10 }).error, 'custody_mismatch')
        local res = R.SetWarrantStatus(OFFICER, { warrantId = id, status = 'served', custodyId = 9 })
        assert_eq(res.success, true, tostring(res.error))
        local w = one('SELECT status, served_custody_id FROM pf_mdt_warrants WHERE warrantId = ?', { id })
        assert_eq(w.status, 'served')
        assert_eq(w.served_custody_id, 9)
        Mock.exportsByResource['pf-justice'] = nil
    end)
    it('a legacy active warrant can still be served; removal needs the grade', function()
        MySQL.query.await("INSERT INTO pf_mdt_warrants (warrantId, suspectName, issuedBy, status) VALUES ('WOLD1', 'Old Case', 'Sgt A', 'active')")
        assert_eq(one("SELECT approval_state FROM pf_mdt_warrants WHERE warrantId = 'WOLD1'").approval_state, 'legacy')
        assert_eq(R.SetWarrantStatus(OFFICER, { warrantId = 'WOLD1', status = 'served' }).success, true)
        local id = newWarrant(OFFICER)
        assert_eq(R.SetWarrantStatus(OFFICER, { warrantId = id, status = 'removed' }).error, 'no_permission')
        assert_eq(R.SetWarrantStatus(SGT, { warrantId = id, status = 'removed' }).success, true)
        assert_eq(one('SELECT status FROM pf_mdt_warrants WHERE warrantId = ?', { id }).status, 'removed')
    end)
    it('the sweep expires active and pending warrants past their expiry', function()
        local a = newWarrant(OFFICER)
        local b = newWarrant(OFFICER)
        MySQL.update.await('UPDATE pf_mdt_warrants SET expiresAt = DATE_SUB(NOW(), INTERVAL 1 HOUR) WHERE warrantId IN (?, ?)', { a, b })
        assert_true(R.SweepWarrants() >= 2)
        assert_eq(one('SELECT status FROM pf_mdt_warrants WHERE warrantId = ?', { a }).status, 'expired')
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_record_audit WHERE entity = 'warrant' AND entity_id = ? AND by_cid = 'system'", { b }), 1)
    end)
    it('the current page sends a name: one matching citizen is taken, an unknown name is refused', function()
        Mock.gameTimer = Mock.gameTimer + 100000
        local res = R.CreateWarrant(OFFICER, { suspect = 'Amy Ash', charges = {} })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(one('SELECT suspectCitizenId FROM pf_mdt_warrants WHERE warrantId = ?', { res.warrantId }).suspectCitizenId, 'SUS2')
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_eq(R.CreateWarrant(OFFICER, { suspect = 'Nobody Here', charges = {} }).error, 'suspect_required')
    end)
    it('the read exports serve pfm-policejob only', function()
        local id = newWarrant(OFFICER)
        Mock.invokingResource = 'pfm-policejob'
        local got = Mock.selfExport('GetWarrant')(id)
        assert_eq(got.ok, true)
        assert_eq(got.warrant.suspectCitizenId, 'SUS1')
        assert_true(#Mock.selfExport('ListWarrantsFor')('SUS1').list >= 1)
        Mock.invokingResource = 'pf-mechanicjob'
        assert_eq(Mock.selfExport('GetWarrant')(id).error, 'not_allowed')
        Mock.invokingResource = nil
    end)
end)

describe('BOLO board and plate flags (MariaDB)', function()
    it('a vehicle BOLO feeds GetPlateFlags and is announced; only the author or a supervisor clears it', function()
        local res = R.CreateBolo(OFFICER, { kind = 'vehicle', plate = ' bolo 1 ', description = 'Black Sultan, armed', danger = true, hours = 2 })
        assert_eq(res.success, true, tostring(res.error))
        local flags = Mock.selfExport('GetPlateFlags')('BOLO 1')
        assert_eq(table.concat(flags.flags, ','), 'BOLO')
        assert_eq(flags.boloIds[1], res.id)
        local announced = false
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf_mdt:server:plateFlagsChanged' and e.args[1] == 'BOLO 1' then announced = true end end
        assert_true(announced, 'ALPR told')
        assert_true(#Mock.clientEventsNamed('pf_mdt:client:boloChanged') >= 4, 'every on-duty officer')
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_vehicle_activity WHERE plate = 'BOLO 1' AND type = 'bolo'"), 1)
        local other = Mock.newPlayer(9, 'OFF9')
        other.PlayerData.job = { name = 'police', onduty = true, grade = { level = 1 } }
        assert_eq(R.ClearBolo(9, { id = res.id }).error, 'no_permission')
        assert_eq(R.ClearBolo(OFFICER, { id = res.id }).success, true)
        assert_eq(#Mock.selfExport('GetPlateFlags')('BOLO 1').flags, 0)
        assert_eq(R.ClearBolo(OFFICER, { id = res.id }).error, 'invalid_state')
    end)
    it('a person BOLO needs a known citizen when one is named; the sweep expires', function()
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_eq(R.CreateBolo(OFFICER, { kind = 'person', citizenid = 'NOPE', description = 'tall' }).error, 'unknown_citizen')
        Mock.gameTimer = Mock.gameTimer + 100000
        local res = R.CreateBolo(OFFICER, { kind = 'person', citizenid = 'SUS2', description = 'Red jacket', lastSeen = 'Legion Square' })
        assert_eq(res.success, true)
        MySQL.update.await('UPDATE pf_mdt_bolos SET expires_at = ? WHERE id = ?', { os.time() - 10, res.id })
        assert_true(R.SweepBolos() >= 1)
        assert_eq(one('SELECT status FROM pf_mdt_bolos WHERE id = ?', { res.id }).status, 'expired')
        local active = R.ListActiveBolos('person')
        for _, b in ipairs(active) do assert_true(b.id ~= res.id) end
    end)
    it('vehicle flags are single-select and whitelisted; old rows load normalised', function()
        assert_eq(select(2, R.SetVehicleFlag(OFFICER, { plate = 'FLG1', flag = 'WANTED' })), 'bad_flag')
        assert_true(R.SetVehicleFlag(OFFICER, { plate = 'flg1', flag = 'stolen' }))
        assert_true(R.SetVehicleFlag(OFFICER, { plate = 'FLG1', flag = 'DANGEROUS' }))
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_vehicle_flags WHERE plate = 'FLG1'"), 1)
        assert_eq(table.concat(R.GetPlateFlags('FLG1').flags, ','), 'DANGEROUS')
        MySQL.query.await("INSERT INTO pf_mdt_vehicle_flags (plate, flag) VALUES (' old 2 ', 'seized'), ('OLD3', 'free text')")
        R.RefreshPlate(nil)
        assert_eq(table.concat(R.GetPlateFlags('OLD 2').flags, ','), 'SEIZED')
        assert_eq(#R.GetPlateFlags('OLD3').flags, 0, 'unknown flag text is not reported')
        assert_true(R.ClearVehicleFlag(OFFICER, { plate = 'FLG1' }))
        assert_eq(#R.GetPlateFlags('FLG1').flags, 0)
        assert_eq(audits('vehicle', 'FLG1'), 3)
    end)
    it('ALPR hits from pfm-policejob are written once a minute and shown as last seen on the profile', function()
        Mock.invokingResource = 'pfm-policejob'
        assert_eq(Mock.selfExport('RecordPlateActivity')('ALPR1', { type = 'alpr_hit', location = 'Del Perro Fwy' }).ok, true)
        assert_eq(Mock.selfExport('RecordPlateActivity')('ALPR1', { type = 'alpr_hit', location = 'Del Perro Fwy' }).error, 'duplicate')
        Mock.invokingResource = 'pf-mechanicjob'
        assert_eq(Mock.selfExport('RecordPlateActivity')('ALPR1', { type = 'alpr_hit' }).error, 'not_allowed')
        Mock.invokingResource = nil
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_vehicle_activity WHERE plate = 'ALPR1'"), 1)
        local profile = Mock.callCallback('pf_mdt:getVehicleProfile', OFFICER, { plate = 'ALPR1' })
        assert_true(profile ~= nil and #profile.activity == 1, 'activity on the profile')
        assert_eq(profile.activity[1].type, 'alpr_hit')
        assert_eq(profile.lastSeenLocation, 'Del Perro Fwy')
    end)
end)

describe('record audit and soft deletes (MariaDB)', function()
    it('a citizen profile read is audited; the list and retention prune work', function()
        Mock.callCallback('pf_mdt:getCitizenProfile', OFFICER, { citizenId = 'SUS2' })
        local list = R.ListAudit('citizen', 'SUS2')
        assert_eq(#list, 1)
        assert_eq(list[1].action, 'read')
        assert_eq(list[1].by_cid, 'OFF1')
        MySQL.query.await("INSERT INTO pf_mdt_record_audit (entity, entity_id, action, by_cid, at) VALUES ('citizen', 'OLD', 'read', 'X', ?)", { os.time() - 400 * 86400 })
        assert_eq(R.PruneAudit(), 1)
        assert_eq(audits('citizen', 'SUS2'), 1)
        local res = Mock.callCallback('pf_mdt:audit:list', OFFICER, { entity = 'citizen', entityId = 'SUS2' })
        assert_eq(res.error, 'no_permission', 'supervisors only')
        assert_eq(#Mock.callCallback('pf_mdt:audit:list', CHIEF, { entity = 'citizen', entityId = 'SUS2' }).list, 1)
    end)
    it('a deleted incident is kept with deleted_at, audited and hidden', function()
        MySQL.query.await("INSERT INTO pf_mdt_incidents (incidentId, title, priority, status, narrative, createdBy) VALUES ('INC-DEL', 'Shots', 'HIGH', 'active', 'x', 'OFF1')")
        assert_eq(Mock.callCallback('pf_mdt:getIncident', OFFICER, { incidentId = 'INC-DEL' }).success, true)
        Mock.fireNet('pf_mdt:deleteIncident', CHIEF, { incidentId = 'INC-DEL' })
        assert_true(one("SELECT deleted_at FROM pf_mdt_incidents WHERE incidentId = 'INC-DEL'").deleted_at ~= nil)
        assert_eq(Mock.callCallback('pf_mdt:getIncident', OFFICER, { incidentId = 'INC-DEL' }).error, 'not_found')
        assert_eq(Mock.callCallback('pf_mdt:searchIncidents', OFFICER, { query = 'Shots' }).total, 0)
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_record_audit WHERE entity = 'incident' AND entity_id = 'INC-DEL' AND action = 'delete'"), 1)
    end)
    it('expungement soft-deletes convictions with one audit row each, once', function()
        MySQL.query.await([[INSERT INTO pf_mdt_sentences (citizenId, citizenName, officerCitizenId, officerName, title, sentenceType, charges)
            VALUES ('SUS2', 'Amy Ash', 'OFF1', 'A', 'Theft', 'fine', '[]'), ('SUS2', 'Amy Ash', 'OFF1', 'A', 'Fraud', 'fine', '[]')]])
        Mock.invokingResource = 'pf-government'
        local res = Mock.selfExport('ExpungeRecord')({ type = 'convictions', citizenId = 'SUS2' }, { actorCid = 'GOV1', reason = 'court order' })
        assert_eq(res.ok, true)
        assert_eq(res.changed, 2)
        assert_eq(Mock.selfExport('ExpungeRecord')({ type = 'convictions', citizenId = 'SUS2' }, { actorCid = 'GOV1' }).changed, 0)
        Mock.invokingResource = nil
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_sentences WHERE citizenId = 'SUS2' AND deleted_at IS NULL"), 0)
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_sentences WHERE citizenId = 'SUS2'"), 2, 'kept')
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_record_audit WHERE entity = 'sentence' AND action = 'delete' AND by_cid = 'GOV1'"), 2)
    end)
end)
