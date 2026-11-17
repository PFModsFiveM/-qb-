-- Batch 21C: the EMS MDT client bridge (pf-emsmdt client/injury_integration.lua) for the field pages.
--  * exams and treatments go to pf-ambulancejob's callbacks and the page gets the server's answer as
--    it came (the old 'treatPatient' NUI callback fired applyTreatment and always answered success);
--  * the treatment menu's catalogue comes from pf-ambulancejob's shared data (no CPR tick, no self-only);
--  * unit board and PCR requests pass an allowlist and reach pf_emsmdt:units:* / pf_emsmdt:pcr:*;
--  * server pushes (UnitBoard, Monitor) reach the page only while the MDT is open, the monitor only
--    for the patient on the page;
--  * the police MDT's sentencing / jail-outfit client code and Config.Sentencing are gone.
load_resource('tests/lua/fivem_mocks.lua')

local nui, sent, calls, progress = {}, {}, {}, {}
local answers = {}           -- [callback name] = answer or function(...) -> answer
local cancelProgress = false

-- pfm-core's client: ONE pending slot per callback name (a second call of a name before its answer
-- replaces the first, whose answer is then lost). Sync mode answers at once; async mode keeps the
-- slot until deliver(name) answers it, like the real client.
local asyncMode = false
local slots = {}
local QB = {
    Functions = {
        TriggerCallback = function(name, cb, ...)
            calls[#calls + 1] = { name = name, args = table.pack(...) }
            local args = table.pack(...)
            local function answer()
                local a = answers[name]
                if type(a) == 'function' then a = a(table.unpack(args, 1, args.n)) end
                cb(a)
            end
            if asyncMode then slots[name] = answer else answer() end
        end,
        Progressbar = function(name, label, ms, _, canCancel, _, _, _, _, onFinish, onCancel)
            progress[#progress + 1] = { name = name, label = label, ms = ms, canCancel = canCancel }
            if cancelProgress then onCancel() else onFinish() end
        end,
    },
}
PFMdt = { GetCore = function() return QB end }
function RegisterNUICallback(name, fn) nui[name] = fn end
function SendNUIMessage(p) sent[#sent + 1] = p end
function PlayerId() return 0 end
function PlayerPedId() return 1000 end
function GetPlayerServerId(pl) return pl == 0 and 1 or pl + 10 end
function GetActivePlayers() return { 0, 1, 2, 3 } end
function GetPlayerPed(pl) return 2000 + pl end
function StopAnimTask() end

-- pf-ambulancejob's shared catalogues, as the manifest loads them
PFMed = nil
load_resource('[pfscripts]/pf-ambulancejob/shared/medical/anatomy.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/medical/findings.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/medical/treatments.lua')
load_resource('[pfscripts]/pf-emsmdt/client/injury_integration.lua')
local C = PFEmsCare

local function reply(name, data)
    local out
    nui[name](data or {}, function(r) out = r end)
    return out
end

local function deliver(name)
    local fn = slots[name]
    slots[name] = nil
    assert_true(fn ~= nil, 'a request is pending for ' .. name)
    fn()
end

local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end

local function callsNamed(name)
    local out = {}
    for _, c in ipairs(calls) do if c.name == name then out[#out + 1] = c end end
    return out
end

BeforeEach = function()
    Mock.reset()
    sent, calls, progress, answers = {}, {}, {}, {}
    cancelProgress = false
    C.target, C.uiOpen = nil, false
    asyncMode, slots, timers = false, {}, {}
    C.queues = {}
end

describe('catalogue for the menus', function()
    it('comes from the shared treatments: labels, targets, regions; no CPR tick and no self-only action', function()
        local cat = C.Catalog()
        assert_eq(cat.actions.splint.label, PFMed.Treatments.Actions.splint.label)
        assert_eq(cat.actions.splint.target, 'region')
        assert_true(#cat.actions.splint.regions > 0)
        for _, r in ipairs(cat.actions.traction_splint.regions) do assert_true(r == 'thigh_l' or r == 'thigh_r', r) end
        assert_eq(cat.actions.cpr, nil, 'CPR needs the /cpr tick stream')
        assert_eq(cat.actions.ifak, nil, 'self-only')
        assert_eq(cat.actions.pressure_dressing.target, 'wound')
        assert_eq(cat.regions[1].id, 'head')
        assert_eq(cat.structures.femur_l, PFMed.Anatomy.Structures.femur_l.label)
    end)
end)

describe('patient care: the server answers, the page shows them', function()
    it('nearby lists only players the server names, nearest first', function()
        Mock.coords[1000] = vector3(0, 0, 0)
        Mock.coords[2001] = vector3(2, 0, 0)   -- server id 11
        Mock.coords[2002] = vector3(1, 0, 0)   -- server id 12
        Mock.coords[2003] = vector3(9, 0, 0)   -- too far
        -- batch 22: one server answer (pf-emsmdt:server:getNearbyPatients) names whom the server sees
        answers['pf-emsmdt:server:getNearbyPatients'] = function(ids)
            local out = {}
            for _, t in ipairs(ids) do
                if t == 12 then out[#out + 1] = { target = 12, citizenid = 'C12', name = 'Ann Lee', distance = 1.0 } end
            end
            return { ok = true, list = out }
        end
        local r = reply('emsCareNearby')
        assert_true(r.ok)
        assert_eq(#r.list, 1)
        assert_eq(r.list[1].target, 12)
        assert_eq(r.list[1].name, 'Ann Lee')
        local asked = callsNamed('pf-emsmdt:server:getNearbyPatients')
        assert_eq(#asked, 1, 'one request')
        assert_eq(#asked[1].args[1], 2, 'only the two within reach were listed')
        assert_eq(#callsNamed('pf-emsmdt:server:getCitizenData'), 0)
    end)

    it('select: refused by the server -> not_found; else exam options and treat options as answered', function()
        answers['pf-emsmdt:server:getCitizenData'] = nil
        local r = reply('emsCareSelect', { target = 12 })
        assert_false(r.ok)
        assert_eq(r.error, 'not_found')
        assert_eq(#callsNamed('pf-ambulancejob:server:examOptions'), 0)
        answers['pf-emsmdt:server:getCitizenData'] = { citizenid = 'C12', firstname = 'Ann', lastname = 'Lee' }
        answers['pf-ambulancejob:server:examOptions'] = { ok = true, tier = 2, modalities = { { id = 'look', available = true } } }
        answers['pf-ambulancejob:server:treatOptions'] = { ok = false, error = 'offline' }
        r = reply('emsCareSelect', { target = 12 })
        assert_true(r.ok)
        assert_eq(r.patient.citizenid, 'C12')
        assert_eq(r.exam.modalities[1].id, 'look')
        assert_eq(r.treat.error, 'offline', 'a refusal is passed on, not hidden')
        assert_eq(callsNamed('pf-ambulancejob:server:examOptions')[1].args[1], 12)
        assert_eq(C.target, 12)
        assert_eq(reply('emsCareSelect', { target = 1 }).error, 'bad_args', 'not yourself')
    end)

    it('exam: target and modality to pf-ambulancejob:server:exam; the answer is the server one', function()
        answers['pf-ambulancejob:server:exam'] = { ok = false, error = 'too_far', message = 'You are too far from the patient.' }
        local r = reply('emsCareExam', { target = 12, modality = 'pulse' })
        local c = callsNamed('pf-ambulancejob:server:exam')[1]
        assert_eq(c.args[1], 12)
        assert_eq(c.args[2], 'pulse')
        assert_false(r.ok)
        assert_eq(r.error, 'too_far')
        assert_eq(progress[1].ms, PFMed.Findings.Modalities.pulse.seconds * 1000, 'the bar shows the server exam time')
        assert_eq(reply('emsCareExam', { target = 12 }).error, 'bad_args')
    end)

    it('treat: the bar, then the server with a request id; a refusal is never reported as success', function()
        answers['pf-ambulancejob:server:treat'] = { ok = false, error = 'missing_item', message = 'You do not have a splint' }
        local r = reply('emsCareTreat', { target = 12, action = 'splint', region = 'thigh_l', injuryId = '7' })
        assert_false(r.ok)
        assert_eq(r.error, 'missing_item')
        local data = callsNamed('pf-ambulancejob:server:treat')[1].args[1]
        assert_eq(data.target, 12)
        assert_eq(data.action, 'splint')
        assert_eq(data.region, 'thigh_l')
        assert_eq(data.injuryId, 7)
        assert_true(type(data.req) == 'string' and #data.req <= 64 and data.req:match('^[%w%-_:%.]+$') ~= nil, 'valid req id')
        assert_eq(progress[1].ms, PFMed.Treatments.Actions.splint.duration)
        answers['pf-ambulancejob:server:treat'] = { ok = true, id = 3, result = { changed = { result = 'no_effect' }, message = 'Nothing to splint' } }
        r = reply('emsCareTreat', { target = 12, action = 'splint', region = 'thigh_l' })
        assert_eq(r.result.changed.result, 'no_effect', 'the server outcome as given')
        local second = callsNamed('pf-ambulancejob:server:treat')[2].args[1]
        assert_true(second.req ~= data.req, 'a new request id per treatment')
    end)

    it('treat: cancelled bar or unknown action -> no server call', function()
        cancelProgress = true
        assert_eq(reply('emsCareTreat', { target = 12, action = 'oxygen' }).error, 'cancelled')
        cancelProgress = false
        assert_eq(reply('emsCareTreat', { target = 12, action = 'cpr' }).error, 'bad_args', 'CPR is not a one-shot')
        assert_eq(reply('emsCareTreat', { target = 12, action = 'self_destruct' }).error, 'bad_args')
        assert_eq(#callsNamed('pf-ambulancejob:server:treat'), 0)
    end)

    it('the old always-success treatPatient callback is gone', function()
        assert_eq(nui.treatPatient, nil)
        assert_eq(nui.saveMedicalNotes, nil)
    end)

    it('chart: pf-ambulancejob:server:getChart for the target', function()
        answers['pf-ambulancejob:server:getChart'] = { ok = true, findings = {} }
        assert_true(reply('emsCareChart', { target = 12 }).ok)
        assert_eq(callsNamed('pf-ambulancejob:server:getChart')[1].args[1], 12)
    end)
end)

describe('one request per callback name at a time (pfm-core keeps one slot per name)', function()
    local function twoNearby()
        Mock.coords[1000] = vector3(0, 0, 0)
        Mock.coords[2001] = vector3(2, 0, 0)   -- server id 11
        Mock.coords[2002] = vector3(1, 0, 0)   -- server id 12
        Mock.coords[2003] = vector3(9, 0, 0)
        answers['pf-emsmdt:server:getCitizenData'] = function(t) return { citizenid = 'C' .. t, firstname = 'P', lastname = tostring(t) } end
        answers['pf-emsmdt:server:getNearbyPatients'] = function(ids)
            local out = {}
            for _, t in ipairs(ids) do out[#out + 1] = { target = t, citizenid = 'C' .. t, name = 'P ' .. t, distance = t == 12 and 1.0 or 2.0 } end
            return { ok = true, list = out }
        end
    end

    it('nearby with two patients in reach answers with both', function()
        twoNearby()
        asyncMode = true
        local out
        nui.emsCareNearby({}, function(r) out = r end)
        assert_eq(#callsNamed('pf-emsmdt:server:getNearbyPatients'), 1, 'one request for both (batch 22)')
        deliver('pf-emsmdt:server:getNearbyPatients')
        assert_true(out ~= nil and out.ok, 'the page got its answer')
        assert_eq(#out.list, 2)
        assert_eq(out.list[1].target, 12, 'nearest first')
        assert_eq(out.list[2].target, 11)
    end)

    it('a selection while nearby is loading waits its turn and gets its own answer', function()
        twoNearby()
        asyncMode = true
        answers['pf-ambulancejob:server:examOptions'] = { ok = true, modalities = {} }
        answers['pf-ambulancejob:server:treatOptions'] = { ok = true, actions = {} }
        local near, sel
        nui.emsCareNearby({}, function(r) near = r end)
        nui.emsCareSelect({ target = 11 }, function(r) sel = r end)
        deliver('pf-emsmdt:server:getNearbyPatients')
        assert_eq(#near.list, 2)
        deliver('pf-emsmdt:server:getCitizenData')   -- the selection's own request
        assert_eq(callsNamed('pf-emsmdt:server:getCitizenData')[1].args[1], 11)
        deliver('pf-ambulancejob:server:examOptions')
        deliver('pf-ambulancejob:server:treatOptions')
        assert_true(sel.ok)
        assert_eq(sel.patient.citizenid, 'C11')
    end)

    it('a lost answer times out and the queue goes on; a late answer is dropped', function()
        asyncMode = true
        answers['pf_emsmdt:units:list'] = { ok = true, units = {} }
        local first, second
        nui.emsServer({ op = 'units:list' }, function(r) first = r end)
        local lost = slots['pf_emsmdt:units:list']
        nui.emsServer({ op = 'units:list' }, function(r) second = r end)
        assert_eq(#callsNamed('pf_emsmdt:units:list'), 1)
        timers[1].fn()                               -- the first answer never came
        assert_eq(first.error, 'no_answer')
        assert_eq(#callsNamed('pf_emsmdt:units:list'), 2, 'the next request went out')
        lost()                                       -- a late answer to the first request
        assert_eq(first.error, 'no_answer', 'not answered twice')
        deliver('pf_emsmdt:units:list')
        assert_true(second.ok)
    end)
end)

describe('unit board and PCR forwards', function()
    it('only allowlisted ops reach pf_emsmdt:*, with clean payloads', function()
        assert_eq(reply('emsServer', { op = 'pcr:delete', data = { id = 1 } }).error, 'bad_args')
        assert_eq(reply('emsServer', { op = 'main:anything' }).error, 'bad_args')
        assert_eq(#calls, 0)
        answers['pf_emsmdt:pcr:saveNarrative'] = { ok = true }
        reply('emsServer', { op = 'pcr:saveNarrative', data = { id = '5', text = 'hello', extra = 'x' } })
        local c = calls[#calls]
        assert_eq(c.name, 'pf_emsmdt:pcr:saveNarrative')
        assert_eq(c.args[1].id, 5)
        assert_eq(c.args[1].text, 'hello')
        assert_eq(c.args[1].extra, nil)
        reply('emsServer', { op = 'pcr:list', data = { scope = 'everything' } })
        assert_eq(calls[#calls].args[1].scope, 'mine')
        reply('emsServer', { op = 'pcr:list', data = { scope = 'patient', citizenId = 'ABC' } })
        assert_eq(calls[#calls].args[1].citizenId, 'ABC')
        reply('emsServer', { op = 'units:join', data = { unit = 'MEDIC 1' } })
        assert_eq(calls[#calls].name, 'pf_emsmdt:units:join')
        assert_eq(calls[#calls].args[1].unit, 'MEDIC 1')
        reply('emsServer', { op = 'units:setRig', data = { clear = 'yes' } })
        assert_eq(calls[#calls].args[1].clear, false)
        reply('emsServer', { op = 'pcr:close', data = { id = 5, disposition = 'refused' } })
        assert_eq(calls[#calls].args[1].disposition, 'refused')
    end)

    it('no answer becomes a failure, not an empty success', function()
        local r = reply('emsServer', { op = 'units:list' })
        assert_false(r.ok)
        assert_eq(r.error, 'no_answer')
    end)

    it('access: the board and my reports are asked from the server', function()
        answers['pf_emsmdt:units:list'] = { ok = true, units = {} }
        answers['pf_emsmdt:pcr:list'] = { ok = false, error = 'no_permission' }
        local r = reply('emsAccess')
        assert_true(r.units.ok)
        assert_eq(r.pcr.error, 'no_permission')
        assert_eq(callsNamed('pf_emsmdt:pcr:list')[1].args[1].scope, 'mine')
    end)
end)

describe('server pushes', function()
    it('the unit board reaches the page only while the MDT is open', function()
        Mock.fireNet('pf_emsmdt:client:UnitBoard', nil, { units = {} })
        assert_eq(#sent, 0)
        Mock.fireEvent('pf_emsmdt:client:UIOpenState', nil, true)
        Mock.fireNet('pf_emsmdt:client:UnitBoard', nil, { units = {} })
        assert_eq(sent[1].action, 'unitBoard')
    end)

    it('monitor readings go to the page only for the patient on it', function()
        C.uiOpen = true
        Mock.fireNet('pf-ambulancejob:client:Monitor', nil, 12, { hr = 80 }, 'sinus')
        assert_eq(#sent, 0, 'no patient selected')
        C.target = 12
        Mock.fireNet('pf-ambulancejob:client:Monitor', nil, 13, { hr = 80 }, 'sinus')
        assert_eq(#sent, 0, 'another patient')
        Mock.fireNet('pf-ambulancejob:client:Monitor', nil, 12, { hr = 80 }, 'sinus')
        assert_eq(sent[1].action, 'careMonitor')
        assert_eq(sent[1].vitals.hr, 80)
        assert_eq(sent[1].rhythm, 'sinus')
    end)

    it('other resources open the care page on a patient', function()
        local opened
        PFMdtOpen = function(how) opened = how end
        assert_true(C.Open(12))
        assert_eq(opened, 'care')
        assert_eq(sent[#sent].action, 'careOpen')
        assert_eq(sent[#sent].target, 12)
        assert_false(C.Open('x'))
        PFMdtOpen = nil
    end)
end)

describe('police sentencing leftovers are gone', function()
    it('client/main.lua has no sentencing, jail or outfit code; config has no Config.Sentencing', function()
        local main = __readfile('[pfscripts]/pf-emsmdt/client/main.lua')
        for _, needle in ipairs({ 'StartMdtSentence', 'ReleaseMdtSentence', 'SendInventorySnapshot', 'applyPrisonOutfit', 'Config.Sentencing', 'createSentence', 'postBail' }) do
            assert_eq(main:find(needle, 1, true), nil, needle)
        end
        Config = nil
        load_resource('[pfscripts]/pf-emsmdt/config.lua')
        assert_eq(Config.Sentencing, nil)
        assert_true(Config.PCR ~= nil and Config.Units ~= nil, 'the rest of the config is intact')
    end)
end)
