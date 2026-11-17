-- Evidence and lab commands are plain functions (PoliceEvidenceCommands) so they can be tested;
-- the evidence module (server/evidence/*) does the work and every check is made there or here on
-- the server: duty, distance from the server positions, items in the server inventory.
PoliceEvidenceCommands = PoliceEvidenceCommands or {}
local EC = PoliceEvidenceCommands

local function notify(src, msg, kind) TriggerClientEvent('QBCore:Notify', src, msg, kind or 'error') end

local function onDutyLeo(P)
    local job = P and P.PlayerData and P.PlayerData.job
    return job ~= nil and job.type == 'leo' and job.onduty == true
end

local function commandRate(src)
    local E = PFEvidence
    if not E or not E.Rate then return true end
    local rate = (E.Cfg().Rates or {}).command or {}
    return E.Rate(tostring(src) .. ':command', rate.perSecond or 1, rate.burst or 2)
end

local function resultText(res)
    if type(res) ~= 'table' then return 'Evidence could not be processed' end
    return tostring(res.message or res.error or 'Evidence could not be processed')
end

-- License

QBCore.Commands.Add('grantlicense', Lang:t('commands.license_grant'), { { name = 'id', help = Lang:t('info.player_id') }, { name = 'license', help = Lang:t('info.license_type') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.grade.level >= Config.LicenseRank then
        if args[2] == 'driver' or args[2] == 'weapon' then
            local SearchedPlayer = exports['pfm-core']:GetPlayer(tonumber(args[1]))
            if not SearchedPlayer then return end
            local licenseTable = SearchedPlayer.PlayerData.metadata['licences']
            if licenseTable[args[2]] then
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.license_already'), 'error')
                return
            end
            licenseTable[args[2]] = true
            SearchedPlayer.Functions.SetMetaData('licences', licenseTable)
            TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('success.granted_license'), 'success')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.grant_license'), 'success')
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.error_license_type'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.rank_license'), 'error')
    end
end)

QBCore.Commands.Add('revokelicense', Lang:t('commands.license_revoke'), { { name = 'id', help = Lang:t('info.player_id') }, { name = 'license', help = Lang:t('info.license_type') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.grade.level >= Config.LicenseRank then
        if args[2] == 'driver' or args[2] == 'weapon' then
            local SearchedPlayer = exports['pfm-core']:GetPlayer(tonumber(args[1]))
            if not SearchedPlayer then return end
            local licenseTable = SearchedPlayer.PlayerData.metadata['licences']
            if not licenseTable[args[2]] then
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.error_license'), 'error')
                return
            end
            licenseTable[args[2]] = false
            SearchedPlayer.Functions.SetMetaData('licences', licenseTable)
            TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('error.revoked_license'), 'error')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.revoke_license'), 'success')
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.error_license'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.rank_revoke'), 'error')
    end
end)

QBCore.Commands.Add('takedrivinglicense', Lang:t('commands.drivinglicense'), {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:SeizeDriverLicense', source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Objects

QBCore.Commands.Add('spikestrip', Lang:t('commands.place_spike'), {}, false, function(source)
    -- placed by the server at the officer's own position (server/objects.lua)
    local ok, err = PolicePlaceSpike(source)
    if not ok and err then TriggerClientEvent('QBCore:Notify', source, err, 'error') end
end)

QBCore.Commands.Add('pobject', Lang:t('commands.place_object'), { { name = 'type', help = Lang:t('info.poobject_object') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local type = args[1]:lower()
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        if type == 'cone' then
            TriggerClientEvent('police:client:spawnCone', src)
        elseif type == 'barrier' then
            TriggerClientEvent('police:client:spawnBarrier', src)
        elseif type == 'roadsign' then
            TriggerClientEvent('police:client:spawnRoadSign', src)
        elseif type == 'tent' then
            TriggerClientEvent('police:client:spawnTent', src)
        elseif type == 'light' then
            TriggerClientEvent('police:client:spawnLight', src)
        elseif type == 'tape' then
            TriggerClientEvent('police:client:spawnTape', src)
        elseif type == 'delete' then
            TriggerClientEvent('police:client:deleteObject', src)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Interaction

QBCore.Commands.Add('cuff', Lang:t('commands.cuff_player'), {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:CuffPlayer', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('escort', Lang:t('commands.escort'), {}, false, function(source)
    local src = source
    TriggerClientEvent('police:client:EscortPlayer', src)
end)

--- /callsign: on-duty police and EMS only; letters, digits, spaces and dashes, at most 12 characters.
function EC.Callsign(src, args)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return false end
    local job = Player.PlayerData.job or {}
    if not job.onduty or (job.type ~= 'leo' and job.type ~= 'ems' and job.name ~= 'ambulance') then
        notify(src, Lang:t('error.on_duty_police_only'))
        return false
    end
    if not commandRate(src) then return false end
    local parts = {}
    for i, v in ipairs(type(args) == 'table' and args or {}) do
        if i > 4 then break end
        if type(v) == 'string' then parts[#parts + 1] = v end
    end
    local text = table.concat(parts, ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' or #text > 12 or text:find('[^%w%- ]') then
        notify(src, 'A callsign is 1-12 letters, digits, spaces or dashes')
        return false
    end
    Player.Functions.SetMetaData('callsign', text)
    notify(src, 'Callsign set to ' .. text, 'success')
    return true
end

QBCore.Commands.Add('callsign', Lang:t('commands.callsign'), { { name = 'name', help = Lang:t('info.callsign_name') } }, false, function(source, args)
    EC.Callsign(source, args)
end)

QBCore.Commands.Add('jail', Lang:t('commands.jail_player'), {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local J = PoliceJustice
        if J and J.HandedOver() and ((Config.Justice or {}).AllowFieldJail == false) then
            TriggerClientEvent('QBCore:Notify', src, 'Field jail is turned off: sentence them through the MDT', 'error')
            return
        end
        TriggerClientEvent('police:client:JailPlayer', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- After the hand-over to pf-justice this is the one /unjail (the MDT's admin /unjail is gone): it
-- ends every open incarceration order of the player (pf-justice ReleaseNow); pf-justice and
-- pfm-prison do the release itself. An on-duty officer of Config.Justice.UnjailGrade or an admin.
local function justiceUnjail(src, Player, args)
    local notify = function(msg, kind) TriggerClientEvent('QBCore:Notify', src, msg, kind or 'error') end
    local J = PoliceJustice
    local job = Player.PlayerData.job or {}
    local grade = type(job.grade) == 'table' and tonumber(job.grade.level) or tonumber(job.grade) or 0
    local officer = job.type == 'leo' and job.onduty and grade >= (tonumber((Config.Justice or {}).UnjailGrade) or 0)
    local admin = not officer and IsPlayerAceAllowed(src, 'command')
    if not officer and not admin then return notify(Lang:t('error.on_duty_police_only')) end
    local targetId = tonumber(args and args[1])
    local Target = targetId and exports['pfm-core']:GetPlayer(targetId)
    if not Target then return notify('Usage: /unjail <id> (player not found)') end
    if not J.Up() then return notify('The justice system is not available right now') end
    local res = J.Call('ReleaseNow', targetId, ('unjail by %s'):format(Player.PlayerData.citizenid),
        { actor = admin and { kind = 'admin', src = src } or { src = src } })
    if type(res) ~= 'table' or not res.ok then return notify(J.Text(res)) end
    if (tonumber(res.released) or 0) == 0 then return notify('They are not in jail') end
    notify(('Released %s from jail'):format(targetId), 'success')
end

QBCore.Commands.Add('unjail', Lang:t('commands.unjail_player'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if PoliceJustice and PoliceJustice.HandedOver() then return justiceUnjail(src, Player, args) end
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local targetId = tonumber(args[1])
        local Target = targetId and exports['pfm-core']:GetPlayer(targetId)
        if not Target then return end
        -- pfm-prison releases on the server: the time, the stored items and the client's exit
        if GetResourceState('pfm-prison') ~= 'started' then
            TriggerClientEvent('QBCore:Notify', src, 'The prison is not available right now', 'error')
            return
        end
        local ok, released, err = pcall(function() return exports['pfm-prison']:ReleasePlayer(targetId, 'unjail') end)
        if not ok or not released then
            TriggerClientEvent('QBCore:Notify', src, ok and err == 'not_jailed' and 'They are not in jail' or 'The prison could not release them', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('seizecash', Lang:t('commands.seizecash'), {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:SeizeCash', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('sc', Lang:t('commands.softcuff'), {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:CuffPlayerSoft', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('fine', Lang:t('commands.fine'), { { name = 'id', help = Lang:t('info.player_id') }, { name = 'amount', help = Lang:t('info.amount') } }, false, function(source, args)
    args = type(args) == 'table' and args or {}
    local biller = exports['pfm-core']:GetPlayer(source)
    local billed = exports['pfm-core']:GetPlayer(tonumber(args[1]))
    local amount = math.floor(tonumber(args[2]) or 0)

    if not biller or biller.PlayerData.job.type ~= 'leo' or not biller.PlayerData.job.onduty then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.on_duty_police_only'), 'error')
        return
    end

    if not billed then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.not_online'), 'error')
        return
    end

    if biller.PlayerData.citizenid == billed.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.fine_yourself'), 'error')
        return
    end

    -- a whole amount up to Config.MaxFine (a missing amount used to crash the command; no limit)
    if amount <= 0 or amount > (Config.MaxFine or 50000) then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.amount_higher'), 'error')
        return
    end

    -- The fine is recorded first, then charged (bank, then cash) straight to the department in one
    -- ledger step; a charge the bank has not settled, or one that could not reach the bank, is
    -- finished by the sweep from the record (server/fines.lua).
    local outcome, info = PFPoliceFines.Issue(biller, billed, amount)
    if outcome == 'paid' then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('info.fine_issued'), 'success')
        TriggerClientEvent('QBCore:Notify', billed.PlayerData.source, Lang:t('info.received_fine'))
    elseif outcome == 'unclear' or outcome == 'pending' then
        -- the money may have been taken: an invoice on top of it could make them pay twice
        TriggerClientEvent('QBCore:Notify', source, 'The bank is still processing this fine. No invoice was sent; it settles by itself.', 'error')
    elseif outcome == 'bank_down' then
        TriggerClientEvent('QBCore:Notify', source, 'The bank is not responding. The fine is recorded and will be charged when it is back.', 'error')
    elseif outcome == 'invoiced' then
        -- they could not pay: pfm-phone made the invoice (with its own ledger token)
        TriggerClientEvent('qb-phone:client:AcceptorDenyInvoice', billed.PlayerData.source, info, biller.PlayerData.charinfo.firstname, biller.PlayerData.job.name, biller.PlayerData.citizenid, amount, GetCurrentResourceName())
        TriggerClientEvent('qb-phone:RefreshPhone', billed.PlayerData.source)
        TriggerClientEvent('QBCore:Notify', source, 'They could not pay: the fine was sent to their phone as an invoice', 'primary')
    elseif outcome == 'retry' then
        TriggerClientEvent('QBCore:Notify', source, 'They could not pay and the fine could not be sent as an invoice yet. It will be charged again later.', 'error')
    elseif outcome == 'db_error' then
        TriggerClientEvent('QBCore:Notify', source, 'The fine could not be recorded. Nothing was charged.', 'error')
    else
        TriggerClientEvent('QBCore:Notify', source, 'The fine could not be sent as an invoice', 'error')
    end
end)

-- Evidence

QBCore.Commands.Add('clearcasings', Lang:t('commands.clear_casign'), {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('evidence:client:ClearCasingsInArea', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('clearblood', Lang:t('commands.clearblood'), {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('evidence:client:ClearBlooddropsInArea', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

--- /takedna <id>: a DNA swab from a restrained (cuffed) or downed person within 2.5 m. The swab is an
--- evidence record with a random sample id (the bag no longer carries the citizen id); who it was
--- taken from is the record's origin, which the lab reads.
function EC.TakeDna(src, args)
    local E = PFEvidence
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or not onDutyLeo(Player) then
        notify(src, Lang:t('error.on_duty_police_only'))
        return false
    end
    if not commandRate(src) then return false end
    local targetId = tonumber(type(args) == 'table' and args[1] or nil)
    local Target = targetId and targetId ~= src and exports['pfm-core']:GetPlayer(targetId) or nil
    if not Target then
        notify(src, Lang:t('error.not_online'))
        return false
    end
    local reach = (E and E.Cfg().HandoverReach) or 2.5
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(targetId))) > reach then
        notify(src, 'Get closer to take a swab')
        return false
    end
    local meta = Target.PlayerData.metadata or {}
    if not (meta.ishandcuffed or meta.isdead or meta.inlaststand) then
        notify(src, 'They must be restrained to take a swab')
        return false
    end
    if not E or not E.Api or not E.Api.CreateEvidence then
        notify(src, 'Evidence storage is not ready')
        return false
    end
    local emptyBag = E.Cfg().EmptyBagItem or 'empty_evidence_bag'
    if not exports['pfm-inventory']:RemoveItem(src, emptyBag, 1, false, 'pfm-policejob:takedna') then
        notify(src, Lang:t('error.have_evidence_bag'))
        return false
    end
    local sampleId = 'D-' .. E.RandomHex(8):upper()
    local res = E.Api.CreateEvidence({
        kind = 'dna_swab', label = Lang:t('info.dna_sample'), attrs = { sampleId = sampleId, quality = 100 },
        collectedBy = src, method = 'swab', sealed = true, origin = { type = 'person', id = Target.PlayerData.citizenid },
    }, { key = ('pfm-policejob:takedna:%s:%s'):format(Player.PlayerData.citizenid, sampleId), actor = { src = src } })
    if type(res) ~= 'table' or not res.ok then
        exports['pfm-inventory']:AddItem(src, emptyBag, 1, false, nil, 'pfm-policejob:takedna refund')
        notify(src, resultText(res))
        return false
    end
    notify(src, ('DNA swab %s taken'):format(res.tag or sampleId), 'success')
    return res
end

QBCore.Commands.Add('takedna', Lang:t('commands.takedna'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    EC.TakeDna(source, args)
end)

-- Evidence ids in commands: the tag (EV-2026-000012) or the number.
local function evidenceId(arg)
    if type(arg) ~= 'string' then return nil end
    local E = PFEvidence
    if arg:match('^%u+%-%d+%-%d+$') then
        local row = E.Store.Normalise(E.Store.Query('single', E.Store.SQL.byTag, { arg }))
        return row and row.id or nil
    end
    return E.Int(arg, 1)
end

--- /labsubmit <evidence> <test> [test...]: request tests on evidence held at the lab.
function EC.LabSubmit(src, args)
    local E = PFEvidence
    if not E or not E.Lab then return notify(src, 'The lab is not available') end
    if not commandRate(src) then return false end
    args = type(args) == 'table' and args or {}
    local id = E.DbReady() and evidenceId(args[1]) or nil
    if not id then return notify(src, 'Usage: /labsubmit <evidence tag> <dna|prints|ballistics|tox|drug_id|gsr|trace>') end
    local tests = {}
    for i = 2, math.min(#args, 8) do tests[#tests + 1] = tostring(args[i]):lower() end
    local res = E.Api.SubmitToLab(id, tests, { actor = { src = src } })
    if not res.ok then return notify(src, resultText(res)) end
    local mins = math.max(0, math.ceil(((res.eta or E.Now()) - E.Now()) / 60))
    notify(src, ('Lab job %d queued; results in about %d min'):format(res.jobId, mins), 'success')
    return res
end

--- /labresult <job>: the job's state, and its result once released (lab techs see results to review).
function EC.LabResult(src, args)
    local E = PFEvidence
    if not E or not E.Lab then return notify(src, 'The lab is not available') end
    if not commandRate(src) then return false end
    local res = E.Api.GetLabJob(E.Int(type(args) == 'table' and args[1] or nil, 1), { viewer = src })
    if not res.ok then return notify(src, resultText(res)) end
    local job = res.job
    local text = ('Lab job %d (%s): %s'):format(job.id, job.test, job.state)
    if job.result then text = text .. ' - ' .. tostring(job.result.summary or job.result.outcome) end
    notify(src, text:sub(1, 220), 'primary')
    return res
end

--- /labrelease <job>: a lab tech releases a reviewed result.
function EC.LabRelease(src, args)
    local E = PFEvidence
    if not E or not E.Lab then return notify(src, 'The lab is not available') end
    if not commandRate(src) then return false end
    local res = E.Api.ReleaseLabResult(E.Int(type(args) == 'table' and args[1] or nil, 1), { actor = { src = src } })
    if not res.ok then return notify(src, resultText(res)) end
    notify(src, ('Lab job %d released'):format(res.jobId), 'success')
    return res
end

--- /registerbag [slot]: exchange an old evidence bag for a recorded one at an evidence locker or lab.
function EC.RegisterBag(src, args)
    local E = PFEvidence
    if not E or not E.Lab then return notify(src, 'The lab is not available') end
    if not commandRate(src) then return false end
    local res = E.Lab.RegisterLegacyBag(src, type(args) == 'table' and args[1] or nil)
    if not res.ok then return notify(src, resultText(res)) end
    notify(src, ('Registered as %s'):format(res.tag or ('#' .. tostring(res.evidenceId))), 'success')
    return res
end

--- /evlocker <case type> <case id>: create (once) and open the case's locker at this station.
function EC.EvidenceLocker(src, args)
    local E = PFEvidence
    if not E or not E.Lab then return notify(src, 'The lab is not available') end
    if not commandRate(src) then return false end
    args = type(args) == 'table' and args or {}
    local res = E.Api.CreateEvidenceLocker({ type = args[1], id = args[2] }, { actor = { src = src } })
    if not res.ok then return notify(src, resultText(res)) end
    local opened = E.Lab.OpenLocker(src, res.lockerId)
    if not opened.ok then return notify(src, resultText(opened)) end
    return opened
end

QBCore.Commands.Add('labsubmit', 'Request crime lab tests on evidence at the lab', { { name = 'evidence', help = 'Evidence tag' }, { name = 'test', help = 'dna, prints, ballistics, tox, drug_id, gsr or trace' } }, true, function(source, args)
    EC.LabSubmit(source, args)
end)
QBCore.Commands.Add('labresult', 'Show a crime lab job', { { name = 'job', help = 'Lab job number' } }, true, function(source, args)
    EC.LabResult(source, args)
end)
QBCore.Commands.Add('labrelease', 'Release a reviewed crime lab result (lab technician)', { { name = 'job', help = 'Lab job number' } }, true, function(source, args)
    EC.LabRelease(source, args)
end)
QBCore.Commands.Add('registerbag', 'Register an old evidence bag at an evidence locker or the lab', { { name = 'slot', help = 'Inventory slot (optional)' } }, false, function(source, args)
    EC.RegisterBag(source, args)
end)
QBCore.Commands.Add('evlocker', 'Open the evidence locker of a case at this station', { { name = 'type', help = 'incident, report, case...' }, { name = 'id', help = 'Case id' } }, true, function(source, args)
    EC.EvidenceLocker(source, args)
end)

QBCore.Commands.Add('anklet', Lang:t('commands.anklet'), {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:CheckDistance', src)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('ankletlocation', Lang:t('commands.ankletlocation'), { { name = 'cid', help = Lang:t('info.citizen_id') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local citizenid = type(args) == 'table' and args[1]
        if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 50 then return end
        local Target = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        if not Target then return end
        if Target.PlayerData.metadata['tracker'] then
            -- the anklet's position is where the server sees the player (their client used to be
            -- asked, and could answer with any position)
            local coords = GetEntityCoords(GetPlayerPed(Target.PlayerData.source))
            local ci = Target.PlayerData.charinfo or {}
            local msg = Lang:t('info.target_location', { firstname = ci.firstname, lastname = ci.lastname })
            local at = { x = coords.x, y = coords.y, z = coords.z }
            TriggerClientEvent('police:client:TrackerMessage', src, msg, at)
            TriggerClientEvent('qb-phone:client:addPoliceAlert', src, { title = Lang:t('info.anklet_location'), coords = at, description = msg })
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_anklet'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Vehicle

QBCore.Commands.Add('depot', Lang:t('commands.depot'), { { name = 'price', help = Lang:t('info.impound_price') } }, false, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:ImpoundVehicle', src, false, tonumber(args[1]))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('impound', Lang:t('commands.impound'), {}, false, function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        TriggerClientEvent('police:client:ImpoundVehicle', src, true)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- Misc

-- /cam is retired (batch 18C): live security cameras are viewed on the MDT CCTV page, which checks
-- duty on the server and audits every camera opened.
QBCore.Commands.Add('cam', Lang:t('commands.camera'), {}, false, function(source)
    TriggerClientEvent('QBCore:Notify', source, 'Use the MDT CCTV page to view security cameras.', 'primary')
end)

QBCore.Commands.Add('paytow', Lang:t('commands.paytow'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local playerId = tonumber(args[1])
        local OtherPlayer = exports['pfm-core']:GetPlayer(playerId)
        if OtherPlayer then
            if OtherPlayer.PlayerData.job.name == 'tow' then
                -- paid from the officer's department account through the ledger (it used to create the money)
                local key = ('pfm-policejob:paytow:%s:%s'):format(Player.PlayerData.citizenid, PFPayout.NewId())
                if not PFPayout.Pay(OtherPlayer, 'bank', 500, { key = key, from = 'society:' .. Player.PlayerData.job.name, reason = 'police-tow-paid', quiet = true }) then
                    TriggerClientEvent('QBCore:Notify', src, 'The department account could not pay this.', 'error')
                    return
                end
                TriggerClientEvent('QBCore:Notify', OtherPlayer.PlayerData.source, Lang:t('success.tow_paid'), 'success')
                TriggerClientEvent('QBCore:Notify', src, Lang:t('info.tow_driver_paid'))
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_towdriver'), 'error')
            end
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('paylawyer', Lang:t('commands.paylawyer'), { { name = 'id', help = Lang:t('info.player_id') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' or Player.PlayerData.job.name == 'judge' then
        local playerId = tonumber(args[1])
        local OtherPlayer = exports['pfm-core']:GetPlayer(playerId)
        if not OtherPlayer then return end
        if OtherPlayer.PlayerData.job.name == 'lawyer' then
            -- paid from the payer's department account through the ledger (it used to create the money)
            local key = ('pfm-policejob:paylawyer:%s:%s'):format(Player.PlayerData.citizenid, PFPayout.NewId())
            if not PFPayout.Pay(OtherPlayer, 'bank', 500, { key = key, from = 'society:' .. Player.PlayerData.job.name, reason = 'police-lawyer-paid', quiet = true }) then
                TriggerClientEvent('QBCore:Notify', src, 'The department account could not pay this.', 'error')
                return
            end
            TriggerClientEvent('QBCore:Notify', OtherPlayer.PlayerData.source, Lang:t('success.tow_paid'), 'success')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.paid_lawyer'))
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_lawyer'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('911p', Lang:t('commands.police_report'), { { name = 'message', help = Lang:t('commands.message_sent') } }, false, function(source, args)
    local src = source
    local message
    if args[1] then message = table.concat(args, ' ') else message = Lang:t('commands.civilian_call') end
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            local alertData = { title = Lang:t('commands.emergency_call'), coords = { x = coords.x, y = coords.y, z = coords.z }, description = message }
            TriggerClientEvent('qb-phone:client:addPoliceAlert', v.PlayerData.source, alertData)
            TriggerClientEvent('police:client:policeAlert', v.PlayerData.source, coords, message)
        end
    end
    -- the call also goes to the police Dispatch app (pf-services), under the same ref a Services app
    -- call uses, so one caller has one open police call at a time
    local Caller = exports['pfm-core']:GetPlayer(src)
    if Caller and GetResourceState('pf-services') == 'started' then
        local cid = Caller.PlayerData.citizenid
        local ci = Caller.PlayerData.charinfo or {}
        local name = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
        pcall(function()
            exports['pf-services']:CreateRequest({
                kind = 'police.assist', title = '911 call from ' .. (name ~= '' and name or 'a citizen'),
                details = tostring(message):gsub('%c', ' '):sub(1, 300), coords = vector3(coords.x, coords.y, coords.z),
                ref = { type = 'citizen:police.assist', id = cid }, requester = cid,
                from = { type = 'citizen', id = cid, name = name ~= '' and name or nil },
            })
        end)
    end
end)
