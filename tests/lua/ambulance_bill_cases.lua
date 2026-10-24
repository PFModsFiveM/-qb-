-- Hospital bills and the revive fee through the ledger, for pf-ambulancejob ([pfscripts]), the ambulance
-- job in use (the [qb] pfm-ambulancejob copy was removed).
--   AmbulanceCases(resourceName, { files... })
load_resource('tests/lua/ledger_env.lua')

function AmbulanceCases(resource, files)
    QBCoreMock.Functions.HasItem = function() return true end
    Mock.exportsByResource['pfm-inventory'] = { RemoveItem = function() return true end, AddItem = function() return true end }
    LedgerEnv.load(resource, files)

    local PATIENT, MEDIC = 1, 2
    local function money(src) return Mock.players[src].PlayerData.money end
    local function ambulance() return FakeDB.bank_accounts.ambulance.account_balance end

    BeforeEach = function()
        Mock.reset()
        LedgerEnv.reset()
        Mock.players, Mock.coords = {}, {}
        FakeDB.society('ambulance', 0)
        Config.WipeInventoryOnRespawn = false -- not what these tests are about
        local p = Mock.newPlayer(PATIENT)
        p.PlayerData.money = { cash = 0, bank = 5000 }
        p.PlayerData.metadata.injail = 0
        local m = Mock.newPlayer(MEDIC)
        m.PlayerData.money = { cash = 6000, bank = 0 }
        m.PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true }
    end

    describe(resource .. ' hospital bills', function()
        it('a bed charges the patient once and credits the ambulance account', function()
            Mock.fireNet('hospital:server:SendToBed', PATIENT, 1, true, 1)
            assert_eq(money(PATIENT).bank, 5000 - Config.BillCost)
            assert_eq(ambulance(), Config.BillCost)
        end)
        it('a patient who cannot pay is treated, and nobody is credited', function()
            Mock.players[PATIENT].PlayerData.money.bank = 100
            Mock.fireNet('hospital:server:SendToBed', PATIENT, 1, true, 1)
            assert_eq(money(PATIENT).bank, 100)
            assert_eq(ambulance(), 0)
            assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 1)
        end)
        it('respawning at the hospital charges once', function()
            Mock.fireNet('hospital:server:RespawnAtHospital', PATIENT, 1)
            assert_eq(money(PATIENT).bank, 5000 - Config.BillCost)
            assert_eq(ambulance(), Config.BillCost)
        end)
    end)

    describe(resource .. ' revive fee', function()
        it('is taken from cash through the ledger', function()
            Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT, true)
            assert_eq(money(MEDIC).cash, 1000)
            assert_eq(#Mock.clientEventsNamed('hospital:client:Revive'), 1)
        end)
        it('without the cash there is no revive and no charge', function()
            Mock.players[MEDIC].PlayerData.money.cash = 100
            Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT, true)
            assert_eq(money(MEDIC).cash, 100)
            assert_eq(#Mock.clientEventsNamed('hospital:client:Revive'), 0)
        end)
    end)
end
