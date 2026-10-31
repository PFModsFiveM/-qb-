-- pf-jobs Gruppe 6 client (client/gruppe6.lua), which could never finish a contract:
--   * the deposit handlers read VaultDoorStates before its `local` declaration further down, so
--     they read a nil global and errored; no top-level local is now used before it is declared;
--   * the vault's security panel needed a 'gruppe6' job that does not exist (Gruppe 6 is a side
--     job anyone takes through the app), so the vault never opened and every deposit said the
--     door was locked. The panel is now for a player on an active contract, the main vault once
--     that contract reached the deposit stage; the event checks the same;
--   * 'Open Storage' on the truck triggered a server event nothing handles; it now opens the trunk
--     through pfm-inventory's own (server-checked) 'inventory' command.
load_resource('tests/lua/fivem_mocks.lua')

local CLIENT = '[pfscripts]/pf-jobs/client/gruppe6.lua'

-- ── static check: no top-level local used before its declaration ─────────────
-- Comments and strings are blanked (newlines kept), then every name declared by a `local` at the
-- start of a line is looked for, as a free name (not a field after . or :), before that line.
local function blankCode(src)
    local out, i, n = {}, 1, #src
    local function blank(s) return (s:gsub('[^\n]', ' ')) end
    while i <= n do
        local c = src:sub(i, i)
        if src:sub(i, i + 1) == '--' then
            local eq = src:match('^%[(=*)%[', i + 2)
            local j
            if eq then
                local _, e = src:find(']' .. eq .. ']', i + 2, true)
                j = e or n
            else
                j = (src:find('\n', i, true) or (n + 1)) - 1
            end
            out[#out + 1] = blank(src:sub(i, j)); i = j + 1
        elseif c == '[' and src:match('^%[=*%[', i) then
            local eq = src:match('^%[(=*)%[', i)
            local _, e = src:find(']' .. eq .. ']', i, true)
            e = e or n
            out[#out + 1] = blank(src:sub(i, e)); i = e + 1
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then j = j + 2
                elseif d == c or d == '\n' then break
                else j = j + 1 end
            end
            out[#out + 1] = blank(src:sub(i, j)); i = j + 1
        else
            out[#out + 1] = c; i = i + 1
        end
    end
    return table.concat(out)
end

local function usedBeforeDeclared(src)
    local code = blankCode(src)
    local lines = {}
    for line in (code .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = line end
    local problems = {}
    for ln, line in ipairs(lines) do
        local names = line:match('^local%s+function%s+([%a_][%w_]*)')
        local list = names and { names } or {}
        if not names then
            local decl = line:match('^local%s+([%a_][%w_%s,<>]*)')
            if decl then
                for name in decl:gsub('<%a+>', ''):gmatch('[%a_][%w_]*') do list[#list + 1] = name end
            end
        end
        for _, name in ipairs(list) do
            for prev = 1, ln - 1 do
                local text = ' ' .. lines[prev]
                local pos = 1
                while true do
                    local s, e = text:find('%f[%w_]' .. name .. '%f[^%w_]', pos)
                    if not s then break end
                    local before = text:sub(1, s - 1):match('(%S)%s*$')
                    if before ~= '.' and before ~= ':' then
                        problems[#problems + 1] = ('%s used on line %d, declared local on line %d'):format(name, prev, ln)
                        break
                    end
                    pos = e + 1
                end
            end
        end
    end
    return problems
end

-- ── loading the client file with client natives ─────────────────────────────
local toServer, notes, bars, zones, entityTargets, commands, threads
local function lastBar() return bars[#bars] end
local function sentToServer(name)
    local n = 0
    for _, e in ipairs(toServer) do if e.name == name then n = n + 1 end end
    return n
end
local function noted(fragment)
    for _, m in ipairs(notes) do if tostring(m):find(fragment, 1, true) then return true end end
    return false
end

-- names the file reads that are not natives (a missing native is a no-op; these stay nil)
local NOT_NATIVES = { Config = true, VehicleSpawnInProgress = true, VaultDoorStates = true, VaultPanelTargets = true,
    CurrentContract = true, CurrentVehicle = true }
local function noop() return nil end

local env
local function loadClient()
    toServer, notes, bars, zones, entityTargets, commands, threads = {}, {}, {}, {}, {}, {}, {}
    _G.__PF_G6_CLIENT_LOADED = nil
    QBCoreMock.Functions.Notify = function(msg) notes[#notes + 1] = msg end
    QBCoreMock.Functions.Progressbar = function(name, _, _, _, _, _, _, _, _, onFinish, onCancel)
        bars[#bars + 1] = { name = name, finish = onFinish, cancel = onCancel }
    end
    QBCoreMock.Functions.GetPlayerData = function() return { job = { name = 'unemployed', onduty = true } } end
    QBCoreMock.Functions.TriggerCallback = function() end
    QBCoreMock.Functions.DeleteVehicle = function() end
    Mock.exportsByResource['pfm-target'] = {
        AddBoxZone = function(_, name, coords, _, _, _, opts) zones[name] = { coords = coords, options = opts.options } end,
        RemoveZone = function(_, name) zones[name] = nil end,
        AddTargetEntity = function(_, ent, opts) entityTargets[#entityTargets + 1] = { entity = ent, options = opts.options } end,
        RemoveTargetEntity = function() end,
    }
    local own = {
        TriggerServerEvent = function(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end,
        ExecuteCommand = function(cmd) commands[#commands + 1] = cmd end,
        CreateThread = function(fn) threads[#threads + 1] = fn end,
        Citizen = { SetTimeout = noop, CreateThread = function(fn) threads[#threads + 1] = fn end, Wait = noop },
        HasAnimDictLoaded = function() return true end,
        NetworkDoesNetworkIdExist = function() return true end,
        NetToVeh = function(netId) return netId end,
        PlayerPedId = function() return 1 end,
        PlayerId = function() return 0 end,
        GetPlayerServerId = function() return 7 end,
    }
    env = setmetatable(own, { __index = function(_, k)
        local v = _G[k]
        if v ~= nil then return v end
        if type(k) == 'string' and not NOT_NATIVES[k] and k:match('^%u') then return noop end
    end })
    assert(load(__readfile('[pfscripts]/pf-jobs/config.lua'), '@config.lua', 't', env))()
    assert(load(__readfile(CLIENT), '@' .. CLIENT, 't', env))()
    -- the threads started while loading (the vault door set-up)
    local started = threads
    threads = {}
    for _, fn in ipairs(started) do fn() end
end

local function fire(name, ...) Mock.fireNet(name, 7, ...) end
local function mainVault()
    for i, v in ipairs(env.Config.Gruppe6.VaultDoors) do if v.isMainVault then return i end end
end
local function otherVault()
    for i, v in ipairs(env.Config.Gruppe6.VaultDoors) do if not v.isMainVault then return i end end
end
local function panel(i)
    local z = zones['gruppe6_vault_panel_' .. i]
    assert(z, 'panel zone ' .. i)
    return z.options[1]
end
local function startContract()
    fire('pf-jobs:gruppe6:startContract', {
        vehicle = 'stockade', plate = 'G6TEST', spawnCoords = { x = 1.0, y = 2.0, z = 3.0, w = 0.0 },
        pickupSequence = { 1, 2 }, locationBags = { 2, 2 }, spawnOwner = 7,
    })
end
local function atDeposit()
    fire('pf-jobs:gruppe6:goToDeposit', env.Config.Gruppe6.DepositLocation)
end

BeforeEach = function()
    Mock.reset()
    loadClient()
end

describe('Gruppe 6 client: no local used before its declaration', function()
    it('client/gruppe6.lua declares every top-level local before using it', function()
        local problems = usedBeforeDeclared(__readfile(CLIENT))
        assert_eq(#problems, 0, table.concat(problems, '; '))
    end)

    it('the check finds a local used before its declaration', function()
        local problems = usedBeforeDeclared('local a = 1\nlocal function f() return Later[1] end\n-- Later\nlocal x = "Later"\nlocal Later = {}\nlocal t = { Later = 1 }; t.Later = 2\n')
        assert_eq(#problems, 1, table.concat(problems, '; '))
        assert_true(problems[1]:find('Later used on line 2', 1, true) ~= nil, problems[1])
    end)
end)

describe('Gruppe 6 client: vault security panel', function()
    it('is not offered to a player without a contract, and its event does nothing for them', function()
        local main = mainVault()
        assert_false(panel(main).canInteract(), 'main vault, no contract')
        assert_false(panel(otherVault()).canInteract(), 'other vault, no contract')
        fire('pf-jobs:gruppe6:useSecurityPanel', { vaultIndex = main })
        assert_eq(#bars, 0, 'no card swipe')
    end)

    it('opens the main vault once the contract reaches the deposit stage (no gruppe6 job needed)', function()
        startContract()
        local main = mainVault()
        assert_false(panel(main).canInteract(), 'still collecting bags')
        fire('pf-jobs:gruppe6:useSecurityPanel', { vaultIndex = main })
        assert_eq(#bars, 0, 'refused before the deposit stage')
        atDeposit()
        assert_true(panel(main).canInteract(), 'at the deposit stage')
    end)

    it('a whole deposit: locked door refused, panel opens it, bags handed in, door closed', function()
        startContract()
        atDeposit()
        assert_true(zones['gruppe6_deposit'] ~= nil, 'deposit point')

        -- the door is shut: told so, nothing sent (this used to error on a nil VaultDoorStates)
        fire('pf-jobs:gruppe6:depositBags')
        assert_true(noted('Vault door is locked'), 'locked message')
        assert_eq(#bars, 0)

        local main = mainVault()
        fire('pf-jobs:gruppe6:useSecurityPanel', { vaultIndex = main })
        assert_eq(lastBar().name, 'vault_access')
        lastBar().finish()

        fire('pf-jobs:gruppe6:depositBags')
        assert_eq(lastBar().name, 'deposit_bags')
        lastBar().finish()
        assert_eq(sentToServer('pf-jobs:gruppe6:depositComplete'), 1)

        -- every bag in with the door open: asked to close it (also read VaultDoorStates)
        fire('pf-jobs:gruppe6:depositProgress', 4, 4)
        assert_true(noted('Close the vault door'), 'close the door prompt')
        assert_true(panel(main).canInteract(), 'the open door can be closed')
        fire('pf-jobs:gruppe6:useSecurityPanel', { vaultIndex = main })
        assert_eq(lastBar().name, 'vault_close')
        lastBar().finish()
        fire('pf-jobs:gruppe6:depositBags')
        assert_true(#bars == 3, 'door closed again: no deposit bar')
    end)
end)

describe('Gruppe 6 client: truck storage', function()
    it("'Open Storage' opens the trunk through pfm-inventory's inventory command", function()
        startContract()
        fire('pf-jobs:gruppe6:vehicleSpawned', 55, 'G6TEST', 7, { x = 1.0, y = 2.0, z = 3.0 })
        assert_eq(#entityTargets, 1, 'storage target on the truck')
        local opt = entityTargets[1].options[1]
        assert_eq(opt.event, 'pf-jobs:gruppe6:openStorage')
        fire(opt.event)
        assert_eq(sentToServer('inventory:server:OpenInventory'), 0, 'no unhandled server event')
        assert_eq(#commands, 1)
        assert_eq(commands[1], 'inventory')
    end)
end)
