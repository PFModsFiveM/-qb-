-- pf-ambulancejob: a 'Person down' request (and so its EMS MDT call) opens only when the SERVER sees the
-- player's ped down (health at or below 150, the last-stand health), at most one per player; a client
-- that keeps reporting down/up (hospital:server:SetLaststandStatus true/false every minute) with a
-- healthy ped opens nothing, and bleeding out of last stand keeps the one call.
load_resource('tests/lua/ledger_env.lua')
GetInvokingResource = function() return nil end
Requests, Closes = {}, {}
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function(_, opts) Requests[#Requests + 1] = opts return { ok = true, id = #Requests } end,
    CloseByRef = function(_, t, id, status, reason) Closes[#Closes + 1] = { type = t, id = id, status = status, reason = reason } return { ok = true } end,
    Emit = function() return 1 end,
}
Mock.exportsByResource['pfm-inventory'] = { RemoveItem = function() return true end, AddItem = function() return true end }
QBCoreMock.Functions.HasItem = function() return false end
QBCoreMock.Commands.Add = function() end
LedgerEnv.load('pf-ambulancejob', { '[pfscripts]/pf-ambulancejob/config.lua', '[pfscripts]/pf-ambulancejob/server/main.lua' })

-- the server's view of the ped, and Wait() with a hook so a spec can act while the handler waits
Health, Waits, OnWait = {}, {}, nil
function GetEntityHealth(ped) return Health[ped] or 200 end
function Wait(ms)
    Waits[#Waits + 1] = ms
    if OnWait then OnWait(ms, #Waits) end
end

local PATIENT, MEDIC = 1, 2
local function report(down) Mock.fireNet('hospital:server:SetLaststandStatus', PATIENT, down) end
local function closes(reason)
    local n = 0
    for _, c in ipairs(Closes) do if c.type == 'patient' and (not reason or c.reason == reason) then n = n + 1 end end
    return n
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Requests, Closes, Health, Waits, OnWait = {}, {}, {}, {}, {}, {}, nil
    FakeDB.society('ambulance', 0)
    local p = Mock.newPlayer(PATIENT, 'PATIENTCID')
    p.PlayerData.money = { cash = 0, bank = 5000 }
    p.PlayerData.metadata.injail = 0
    Mock.newPlayer(MEDIC).PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true }
    Mock.coords[PATIENT] = vector3(10.0, 20.0, 30.0)
end

describe('person-down calls need the server to see the player down', function()
    it('a healthy player reporting last stand gets no call (after the server looked for a while)', function()
        report(true)
        assert_eq(#Requests, 0)
        assert_eq(#Waits, 9)                                   -- checked 10 times, 500 ms apart
        for _, ms in ipairs(Waits) do assert_eq(ms, 500) end
    end)
    it('toggling down/up every minute with a healthy ped never opens a call', function()
        for _ = 1, 5 do
            report(true); report(false)
            Mock.clock = Mock.clock + 61
        end
        assert_eq(#Requests, 0)
        assert_eq(closes(), 0)
    end)
    it('the call opens once the ped is seen down, even when the state sync arrives late', function()
        OnWait = function(_, n) if n == 3 then Health[PATIENT] = 150 end end
        report(true)
        assert_eq(#Requests, 1)
        assert_eq(Requests[1].ref.id, 'PATIENTCID')
    end)
    it('a down report while the server is still checking the first one opens no second call', function()
        OnWait = function(_, n)
            if n == 1 then report(true) end                    -- arrives during the first check's Wait
            if n == 2 then Health[PATIENT] = 150 end
        end
        report(true)
        assert_eq(#Requests, 1)
    end)
    it('at most one open call per player, even after the cooldown', function()
        Health[PATIENT] = 150
        report(true)
        Mock.clock = Mock.clock + 120
        report(true)
        Mock.fireNet('hospital:server:SetDeathStatus', PATIENT, true)
        assert_eq(#Requests, 1)
    end)
    it('bleeding out of last stand (reports up, then dead) keeps the call', function()
        Health[PATIENT] = 150
        report(true)
        OnWait = function(ms) if ms == 5000 then Health[PATIENT] = 50; Mock.fireNet('hospital:server:SetDeathStatus', PATIENT, true) end end
        report(false)                                          -- laststand off ... then dead within the grace
        assert_eq(closes('recovered'), 0)
        assert_eq(#Requests, 1)
    end)
    it('really getting up closes it after the grace period', function()
        Health[PATIENT] = 150
        report(true)
        Health[PATIENT] = 200
        report(false)
        assert_eq(closes('recovered'), 1)
    end)
    it('after a medic revive, going down again is a new call (no cooldown)', function()
        Health[PATIENT] = 150
        report(true)
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        Health[PATIENT] = 200
        report(false)
        assert_eq(closes('recovered'), 0)                      -- already closed by the revive
        Mock.clock = Mock.clock + 10
        Health[PATIENT] = 150
        report(true)
        assert_eq(#Requests, 2)
    end)
    it('the flags are stored as booleans only', function()
        report('yes')
        assert_eq(Mock.players[PATIENT].PlayerData.metadata.inlaststand, false)
    end)
end)
