-- pfm-storerobbery: the keypad code can't be brute-forced (3 wrong guesses lock the safe for 10 minutes).
load_resource('tests/lua/fivem_mocks.lua')
-- run each thread up to its first Wait, so the safe codes get generated
local realThread, realWait = CreateThread, Wait
CreateThread = function(fn) pcall(fn) end
Wait = function() error('stop thread') end
load_resource('pfm-storerobbery/config.lua')
load_resource('pfm-storerobbery/server/main.lua')
CreateThread, Wait = realThread, realWait

local R, COP = 1, 2
local KEYPAD = 1
local function guess(code) return Mock.callCallback('qb-storerobbery:server:isCombinationRight', R, KEYPAD, code) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.newPlayer(R)
    Mock.newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Config.MinimumStoreRobberyPolice = 1
    local s = Config.Safes[KEYPAD][1]
    Mock.coords[R] = vector3(s.x, s.y, s.z)
end

describe('store safe keypad', function()
    it('after 3 wrong guesses no code works, not even the right one', function()
        local wrong = 0
        for code = 1000, 9999 do
            if guess(code) then break end
            wrong = wrong + 1
            if wrong >= 3 then break end
        end
        local hits = 0
        for code = 1000, 9999 do if guess(code) then hits = hits + 1 end end
        assert_eq(hits, 0)
    end)
    it('the lockout ends after 10 minutes, and reconnecting does not reset it', function()
        Mock.clock = Mock.clock + 700
        local found, tries = false, 0
        for code = 1000, 9999 do
            tries = tries + 1
            if guess(code) then found = true break end
            if tries % 3 == 0 then
                Mock.fireEvent('playerDropped', R)          -- reconnecting does not help
                assert_false(guess(code + 1) and true or false)
                Mock.clock = Mock.clock + 601
            end
        end
        assert_true(found)
    end)
end)
