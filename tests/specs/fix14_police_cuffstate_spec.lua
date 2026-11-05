-- pfm-policejob handcuffs (batch 14: POL-1, X-1). The server owns the cuff state: a client cannot
-- uncuff itself (police:server:SetHandcuffStatus is gone), the server decides cuff or uncuff from its
-- own state and tells the client, and other resources' checks (inventory, trunk, robbery) read state
-- the client cannot write. The resist window: the answer must carry the attempt's nonce, come no
-- faster than the presses could be made, and only earns a roll the server makes; a suspect who broke
-- free cannot resist again for a while; only an on-duty officer's softcuff skips the window.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
Mock.exportsByResource['pfm-inventory'] = { OpenInventoryById = function() return true end, AddItem = function() return true end, RemoveItem = function() return true end }
local jailed = {}
Mock.exportsByResource['pfm-prison'] = { JailPlayer = function(_, src, minutes) jailed[#jailed + 1] = { src = src, minutes = minutes } return true end }
function GetResourceState(name) return name == 'pfm-prison' and 'started' or 'missing' end
local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = fn end
local bags = {}
function Player(src)
    bags[src] = bags[src] or { state = { set = function(self, k, v) self[k] = v end } }
    return bags[src]
end

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/commands.lua')
load_resource('pfm-policejob/server/interactions.lua')

local COP, SUSPECT, CIV = 1, 2, 3
local function meta(src) return Mock.players[src].PlayerData.metadata end
local function cuffEvents(target)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('police:client:SetCuffed')) do if e.target == target then out[#out + 1] = e end end
    return out
end
local function resistPrompt(target)
    local list = {}
    for _, e in ipairs(Mock.clientEventsNamed('police:client:ResistCuff')) do if e.target == target then list[#list + 1] = e end end
    return list[#list]
end
local function flush() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end

BeforeEach = function()
    for _, src in ipairs({ COP, SUSPECT, CIV }) do if Mock.players[src] then Mock.fireEvent('playerDropped', src) end end
    Mock.reset()
    Mock.players, Mock.coords, Mock.dropped, bags, jailed, timers = {}, {}, {}, {}, {}, {}
    Mock.gameTimer = Mock.gameTimer + 600000
    Mock.clock = Mock.clock + 3600
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 2 } }
    cop.GetItemByName = function() return nil end
    local s = Mock.newPlayer(SUSPECT, 'SUSPECTCID')
    s.PlayerData.metadata.ishandcuffed = false
    s.GetItemByName = function() return nil end
    local c = Mock.newPlayer(CIV, 'CIVCID')
    c.GetItemByName = function(name) return name == 'handcuffs' and { name = 'handcuffs' } or nil end
    Mock.coords[COP] = vector3(0, 0, 0)
    Mock.coords[SUSPECT] = vector3(1, 0, 0)
    Mock.coords[CIV] = vector3(0, 1, 0)
end

describe('the cuff state is the server\'s (POL-1)', function()
    it('a cuffed client cannot uncuff itself on the server', function()
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, true)       -- officer softcuff: no window
        assert_eq(meta(SUSPECT).ishandcuffed, true)
        assert_eq(Mock.netHandlers['police:server:SetHandcuffStatus'], nil)
        assert_eq(bags[SUSPECT].state.handcuffed, true)
        local e = cuffEvents(SUSPECT)
        assert_eq(#e, 1)
        assert_eq(e[1].args[1], true)
    end)
    it('cuff and uncuff are decided from the server\'s state, and told to the client explicitly', function()
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, true)
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, true)
        assert_eq(meta(SUSPECT).ishandcuffed, false)
        local e = cuffEvents(SUSPECT)
        assert_eq(e[2].args[1], false)
        assert_eq(bags[SUSPECT].state.handcuffed, false)
    end)
    it('jailing takes the cuffs off on the server before the prison takes them', function()
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, true)
        Mock.fireNet('police:server:JailPlayer', COP, SUSPECT, 20)
        assert_eq(meta(SUSPECT).ishandcuffed, false)
        assert_eq(#jailed, 1)
    end)
    it('police cuffs come back after a relog; someone else\'s do not, and neither do old ones', function()
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, true)
        Mock.fireEvent('playerDropped', SUSPECT)
        Mock.eventHandlers['QBCore:Server:PlayerLoaded'](Mock.pack(Mock.players[SUSPECT]))
        assert_eq(meta(SUSPECT).ishandcuffed, true)
        -- a relog long after the cuffs went on: free
        Mock.clock = Mock.clock + (Config.Gameplay.RelogCuffMinutes + 1) * 60
        Mock.fireEvent('playerDropped', SUSPECT)
        Mock.eventHandlers['QBCore:Server:PlayerLoaded'](Mock.pack(Mock.players[SUSPECT]))
        assert_eq(meta(SUSPECT).ishandcuffed, false)
    end)
    -- batch 16 (lead carry-over a): the uncuff follows pf-ambulancejob's server-side respawn, not the
    -- client's hospital:server:RespawnAtHospital (a cuffed client could send that one at will)
    it('a cuffed player is uncuffed when pf-ambulancejob reports the respawn; the client net event does nothing', function()
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, true)
        assert_eq(Mock.netHandlers['hospital:server:RespawnAtHospital'], nil, 'no listener on the client event')
        -- another player's citizenid with this source is not their respawn
        TriggerEvent('pf-ambulancejob:server:respawned', SUSPECT, 'COPCID', 'pillbox')
        assert_eq(meta(SUSPECT).ishandcuffed, true)
        TriggerEvent('pf-ambulancejob:server:respawned', SUSPECT, 'SUSPECTCID', 'pillbox')
        assert_eq(meta(SUSPECT).ishandcuffed, false)
        local e = cuffEvents(SUSPECT)
        assert_eq(e[#e].args[1], false, 'the client is told')
        -- an unknown source does not crash
        TriggerEvent('pf-ambulancejob:server:respawned', 99, 'X', 'pillbox')
    end)
    it('cuffs from a civilian with a handcuffs item come off by themselves after a while', function()
        Mock.fireNet('police:server:CuffPlayer', CIV, SUSPECT, true)
        -- a civilian's softcuff still gets the resist window; the suspect gives up
        local prompt = resistPrompt(SUSPECT)
        assert_true(prompt ~= nil, 'resist window for a civilian softcuff')
        Mock.fireNet('police:server:ResistResult', SUSPECT, prompt.args[4], false)
        assert_eq(meta(SUSPECT).ishandcuffed, true)
        PoliceCuffSweep()
        assert_eq(meta(SUSPECT).ishandcuffed, true)
        Mock.clock = Mock.clock + Config.Gameplay.CivilianCuffMinutes * 60
        PoliceCuffSweep()
        assert_eq(meta(SUSPECT).ishandcuffed, false)
    end)
    it('the export lets other server resources free a player', function()
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, true)
        assert_true(Mock.selfExport('SetCuffed')(SUSPECT, false, 'revive'))
        assert_eq(meta(SUSPECT).ishandcuffed, false)
        assert_eq(Mock.selfExport('IsCuffed')(SUSPECT), false)
    end)
end)

describe('resisting (X-1)', function()
    it('an answer without the attempt\'s nonce changes nothing; the cuff lands at the timeout', function()
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, false)
        assert_true(resistPrompt(SUSPECT) ~= nil)
        Mock.fireNet('police:server:ResistResult', SUSPECT, 'forged', true)
        Mock.fireNet('police:server:ResistResult', SUSPECT, true)          -- the old one-argument answer
        assert_eq(meta(SUSPECT).ishandcuffed, false)
        flush()
        assert_eq(meta(SUSPECT).ishandcuffed, true)
    end)
    it('"resisted" the moment the prompt arrived is too fast for the presses: cuffed', function()
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, false)
        local prompt = resistPrompt(SUSPECT)
        Mock.gameTimer = Mock.gameTimer + 50
        Mock.fireNet('police:server:ResistResult', SUSPECT, prompt.args[4], true)
        assert_eq(meta(SUSPECT).ishandcuffed, true)
    end)
    it('a resist in time only earns the server\'s roll', function()
        local realRandom = math.random
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, false)
        local prompt = resistPrompt(SUSPECT)
        Mock.gameTimer = Mock.gameTimer + 1500
        math.random = function(a, b) if a == nil then return 0.99 end return realRandom(a, b) end
        Mock.fireNet('police:server:ResistResult', SUSPECT, prompt.args[4], true)
        math.random = realRandom
        assert_eq(meta(SUSPECT).ishandcuffed, true, 'the roll failed')
    end)
    it('a won roll frees the suspect once; the next attempt cannot be resisted', function()
        local realRandom = math.random
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, false)
        local prompt = resistPrompt(SUSPECT)
        Mock.gameTimer = Mock.gameTimer + 1500
        math.random = function(a, b) if a == nil then return 0.01 end return realRandom(a, b) end
        Mock.fireNet('police:server:ResistResult', SUSPECT, prompt.args[4], true)
        math.random = realRandom
        assert_eq(meta(SUSPECT).ishandcuffed, false)
        assert_eq(#Mock.clientEventsNamed('police:client:ResistOutcome'), 1)
        local prompts = #Mock.clientEventsNamed('police:client:ResistCuff')
        Mock.gameTimer = Mock.gameTimer + 5000                          -- past the officer's cooldown
        Mock.fireNet('police:server:CuffPlayer', COP, SUSPECT, false)
        assert_eq(#Mock.clientEventsNamed('police:client:ResistCuff'), prompts, 'no second window')
        assert_eq(meta(SUSPECT).ishandcuffed, true)
    end)
    it('anyone without handcuffs or police duty cannot cuff', function()
        Mock.players[CIV].GetItemByName = function() return nil end
        Mock.fireNet('police:server:CuffPlayer', CIV, SUSPECT, true)
        assert_eq(meta(SUSPECT).ishandcuffed, false)
        assert_eq(resistPrompt(SUSPECT), nil)
    end)
end)
