-- pf-justice state machines (batch 15B, acceptance 1): every machine of PF_ARCHITECTURE 5.4, 5.5,
-- 5.6, 5.8 and 5.12 is data in shared/states.lua. The spec lists each transition the architecture
-- names and walks every edge the data holds, so a machine that loses a transition, or gains one no
-- one asked for, fails here; a sample of refused transitions returns invalid_state.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('[pfscripts]/pf-justice/shared/states.lua')
local S = PFJustice.States

-- Transitions written in the architecture (5.4-5.6, 5.8, 5.12) plus the documented additions in
-- the header of shared/states.lua. Each entry: machine, from, to.
local EXPECTED = {
    custody = {
        { nil, 'detained' }, { nil, 'arrested' },
        { 'detained', 'arrested' }, { 'arrested', 'in_transport' }, { 'in_transport', 'booking' }, { 'arrested', 'booking' },
        { 'booking', 'booked' }, { 'booked', 'held' }, { 'held', 'remanded' }, { 'booked', 'remanded' },
        { 'held', 'transferred' }, { 'booked', 'transferred' }, { 'remanded', 'transferred' },
        { 'detained', 'hospital' }, { 'arrested', 'hospital' }, { 'in_transport', 'hospital' }, { 'booking', 'hospital' },
        { 'booked', 'hospital' }, { 'held', 'hospital' }, { 'remanded', 'hospital' },
        { 'hospital', 'detained' }, { 'hospital', 'arrested' }, { 'hospital', 'in_transport' }, { 'hospital', 'booking' },
        { 'hospital', 'booked' }, { 'hospital', 'held' }, { 'hospital', 'remanded' },
        { 'detained', 'released' }, { 'arrested', 'released' }, { 'in_transport', 'released' }, { 'booking', 'released' },
        { 'booked', 'released' }, { 'held', 'released' }, { 'remanded', 'released' }, { 'hospital', 'released' },
        { 'in_transport', 'arrested' },
    },
    incarceration = {
        { nil, 'pending' }, { nil, 'active' },
        { 'pending', 'active' }, { 'active', 'completed' }, { 'active', 'suspended' }, { 'suspended', 'active' },
        { 'active', 'vacated' }, { 'active', 'revoked' }, { 'pending', 'vacated' }, { 'suspended', 'vacated' },
    },
    fine = {
        { nil, 'issued' },
        { 'issued', 'paid' }, { 'issued', 'payment_pending' }, { 'payment_pending', 'paid' }, { 'payment_pending', 'issued' },
        { 'issued', 'invoiced' }, { 'invoiced', 'paid' }, { 'issued', 'overdue' }, { 'overdue', 'referred' }, { 'issued', 'waived' },
        { 'overdue', 'payment_pending' }, { 'overdue', 'paid' }, { 'overdue', 'invoiced' }, { 'overdue', 'waived' },
        { 'invoiced', 'issued' }, { 'invoiced', 'waived' }, { 'referred', 'paid' }, { 'referred', 'payment_pending' }, { 'referred', 'waived' },
    },
    citation = {
        { nil, 'issued' },
        { 'issued', 'paid' }, { 'issued', 'payment_pending' }, { 'payment_pending', 'paid' }, { 'payment_pending', 'issued' },
        { 'issued', 'invoiced' }, { 'invoiced', 'paid' }, { 'issued', 'overdue' }, { 'overdue', 'referred' }, { 'issued', 'waived' },
        { 'overdue', 'payment_pending' }, { 'overdue', 'paid' }, { 'overdue', 'invoiced' }, { 'overdue', 'waived' },
        { 'invoiced', 'issued' }, { 'invoiced', 'waived' }, { 'referred', 'paid' }, { 'referred', 'payment_pending' }, { 'referred', 'waived' },
        { 'issued', 'contested' }, { 'contested', 'upheld' }, { 'contested', 'dismissed' },
        { 'upheld', 'paid' }, { 'upheld', 'payment_pending' }, { 'upheld', 'invoiced' }, { 'upheld', 'overdue' }, { 'upheld', 'waived' },
    },
    community_service = {
        { nil, 'assigned' },
        { 'assigned', 'active' }, { 'active', 'completed' }, { 'active', 'overdue' }, { 'overdue', 'referred' },
        { 'assigned', 'vacated' }, { 'active', 'vacated' }, { 'overdue', 'vacated' }, { 'referred', 'vacated' },
        { 'assigned', 'overdue' }, { 'overdue', 'completed' },
    },
    supervision = {
        { nil, 'pending' }, { nil, 'active' },
        { 'pending', 'active' }, { 'pending', 'vacated' }, { 'active', 'completed' }, { 'active', 'revoked' }, { 'active', 'vacated' },
        { 'active', 'suspended' }, { 'suspended', 'active' }, { 'suspended', 'revoked' }, { 'suspended', 'vacated' },
    },
    bail = {
        { nil, 'offered' },
        { 'offered', 'accepted' }, { 'accepted', 'posted' }, { 'posted', 'exonerated' }, { 'exonerated', 'refunded' },
        { 'posted', 'forfeited' }, { 'offered', 'declined' }, { 'offered', 'expired' },
        { 'accepted', 'payment_pending' }, { 'payment_pending', 'posted' }, { 'payment_pending', 'offered' },
        { 'accepted', 'offered' },
    },
}

local REFUSED = {
    { 'custody', 'released', 'held' }, { 'custody', 'detained', 'booked' }, { 'custody', 'transferred', 'released' },
    { 'custody', 'arrested', 'held' }, { 'custody', nil, 'held' }, { 'custody', 'booking', 'remanded' },
    { 'incarceration', 'completed', 'active' }, { 'incarceration', 'pending', 'completed' }, { 'incarceration', 'vacated', 'active' },
    { 'incarceration', 'suspended', 'completed' }, { 'incarceration', nil, 'completed' }, { 'incarceration', 'revoked', 'active' },
    { 'fine', 'paid', 'issued' }, { 'fine', 'waived', 'paid' }, { 'fine', 'payment_pending', 'invoiced' },
    { 'fine', 'payment_pending', 'waived' }, { 'fine', 'issued', 'contested' }, { 'fine', nil, 'paid' },
    { 'citation', 'dismissed', 'paid' }, { 'citation', 'contested', 'paid' }, { 'citation', 'upheld', 'contested' },
    { 'community_service', 'completed', 'active' }, { 'community_service', 'overdue', 'active' },
    { 'community_service', 'assigned', 'completed' },
    { 'bail', 'posted', 'refunded' }, { 'bail', 'forfeited', 'refunded' }, { 'bail', 'declined', 'accepted' },
    { 'bail', 'offered', 'posted' }, { 'bail', 'refunded', 'posted' },
    { 'supervision', 'completed', 'active' }, { 'supervision', 'pending', 'completed' },
}

local function key(from, to) return tostring(from or '(new)') .. '>' .. tostring(to) end

describe('every listed transition is allowed', function()
    for machine, list in pairs(EXPECTED) do
        it(machine .. ': ' .. #list .. ' transitions', function()
            for _, t in ipairs(list) do
                assert_true(S.Can(machine, t[1], t[2]), machine .. ' ' .. key(t[1], t[2]))
                local ok, err = S.Check(machine, t[1], t[2])
                assert_true(ok, machine .. ' check ' .. key(t[1], t[2]))
                assert_eq(err, nil)
            end
        end)
    end
end)

describe('the data holds nothing more than the listed transitions', function()
    for machine, list in pairs(EXPECTED) do
        it(machine .. ' has exactly the listed edges', function()
            local want = {}
            for _, t in ipairs(list) do want[key(t[1], t[2])] = true end
            local m = S.Machines[machine]
            assert_true(m ~= nil, 'machine ' .. machine)
            local seen = 0
            for to in pairs(m.initial) do
                assert_true(want[key(nil, to)], machine .. ' unexpected initial ' .. to)
                seen = seen + 1
            end
            for from, tos in pairs(m.edges) do
                for to in pairs(tos) do
                    assert_true(want[key(from, to)], machine .. ' unexpected edge ' .. key(from, to))
                    seen = seen + 1
                end
            end
            assert_eq(seen, #list, machine .. ' edge count')
        end)
    end
end)

describe('refused transitions', function()
    it('return invalid_state with the current state in the message', function()
        for _, t in ipairs(REFUSED) do
            assert_false(S.Can(t[1], t[2], t[3]), t[1] .. ' ' .. key(t[2], t[3]))
            local ok, err = S.Check(t[1], t[2], t[3])
            assert_false(ok)
            assert_eq(err.ok, false)
            assert_eq(err.error, 'invalid_state')
            assert_true(err.message:find(tostring(t[2] or 'new'), 1, true) ~= nil, 'message names the state')
        end
    end)

    it('unknown machines, states and targets are refused', function()
        assert_false(S.Can('nope', 'issued', 'paid'))
        assert_false(S.Can('fine', 'nope', 'paid'))
        assert_false(S.Can('fine', 'issued', nil))
        assert_false(S.Can('fine', 'issued', 42))
    end)
end)

describe('terminal states end a record', function()
    it('no edge leaves a terminal state', function()
        for name, m in pairs(S.Machines) do
            for state in pairs(m.terminal) do
                assert_eq(m.edges[state], nil, name .. ' terminal ' .. state .. ' has edges')
                assert_true(S.IsTerminal(name, state))
                assert_false(S.IsOpen(name, state))
            end
        end
    end)

    it('open states are the non-terminal ones', function()
        assert_true(S.IsOpen('incarceration', 'active'))
        assert_true(S.IsOpen('incarceration', 'suspended'))
        assert_true(S.IsOpen('fine', 'payment_pending'))
        assert_true(S.IsOpen('bail', 'exonerated'))
        assert_false(S.IsOpen('fine', 'paid'))
        assert_false(S.IsOpen('custody', 'transferred'))
    end)
end)

describe('order kinds map to machines', function()
    it('every kind of the contract has a machine (by kind name too)', function()
        local kinds = { 'jail', 'prison', 'fine', 'citation', 'restitution', 'community_service', 'probation', 'parole', 'remand' }
        for _, k in ipairs(kinds) do
            assert_true(S.Kinds[k], k)
            assert_true(S.Machine(k) ~= nil, k)
        end
        assert_eq(S.Machine('prison'), S.Machines.incarceration)
        assert_eq(S.Machine('restitution'), S.Machines.fine)
        assert_eq(S.Machine('parole'), S.Machines.supervision)
        assert_true(S.Can('jail', 'active', 'completed'))
        assert_false(S.Can('jail', 'issued', 'paid'))
    end)

    it('the open states of a kind feed the SQL filters', function()
        local open = table.concat(S.OpenStates('prison'), ',')
        assert_eq(open, 'active,pending,suspended')
        -- the clock's query lists exactly these states
        assert_true(#S.StatesOf('fine') >= 7)
    end)

    it('states fit the VARCHAR(16) state column', function()
        for name in pairs(S.Machines) do
            for _, s in ipairs(S.StatesOf(name)) do assert_true(#s <= 16, name .. ' ' .. s) end
        end
    end)
end)
