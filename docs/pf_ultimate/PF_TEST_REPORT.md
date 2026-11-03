# PF Ultimate: test report

How the overhaul is tested, the baseline it starts from, a section to fill per batch, and the live-server checklist
for what automated tests cannot reach.

## 1. How testing works here

| Layer | Command (from `[qb]/tests`) | What it proves | Limits |
|---|---|---|---|
| Mocked Lua specs | `node harness.js [filter]` | Server logic of each resource, loaded from disk unmodified, in a fresh fengari VM per spec file, with FiveM mocks (`tests/lua/fivem_mocks.lua`), a fake MySQL (`fake_db.lua`) or the real ledger on the fake DB (`ledger_env.lua`) | fengari is **Lua 5.3** (FiveM is 5.4): no `<const>`/`<close>`; `CreateThread`/`SetTimeout` do nothing, so ticks are called directly; natives are mocks |
| Real-DB Lua specs | `PF_TEST_DB="mysql://root@127.0.0.1:3399" node realdb/run.js [filter]` | Migrations, SQL text, types, constraints, concurrency on MariaDB; each spec file gets a fresh `pf_rt_*` database | Throwaway MariaDB only (never a server with real data); other agents may share it, so run your area's specs and rerun once before blaming a change |
| Ledger concurrency | `PF_TEST_DB=... node realdb/ledger_parallel.js 6` | Truly parallel ledger sessions | |
| SQL install check | `PF_TEST_DB=... node realdb/sql_install_check.js` | Shipped SQL files install on a fresh DB | |
| JS UI specs | `node js/<spec>.js` | NUI modules in jsdom: rendering into the container, escaping, RPC calls, empty/error states | No real CEF; layout is not measured |
| Syntax | `node parsecheck.js <files>` | Lua parses with the harness preprocessor | |
| JS syntax | `node --check <file.js>` | | |
| State-bag scan | part of the mocked suite (`statebag_strict_scan_spec.lua`) | No client writes a replicated state bag | |
| Event collisions | `python docs/staging/event_collisions.py <resources>` | No two resources register the same event name | |
| Staging start | FXServer from `docs/staging/server.staging.cfg` for ~140 s | Every resource starts, migrations apply once | No clients |

What cannot be tested without a live FiveM server with game clients:
- Anything that depends on real natives on a real ped: `GetPedLastDamageBone`, `weaponDamageEvent` contents
  (`hitComponent` mapping), synced health after damage, `NetworkResurrectLocalPlayer`, ragdoll, clipsets, blur.
- Entity behaviour: stretcher attachment, `SetPedIntoVehicle` from the server, late joiners and OneSync scope,
  `entityRemoved` timing, door state on all clients.
- Timing: the race between client death and the server's health read, revive verification after 1.5 s.
- Performance under load (`resmon`), NUI rendering in CEF, keyboard focus inside pf-tablet/pf-computer windows.
- pma-voice radio state, screenshot-basic uploads.

## 2. Baseline (recorded from the session notes; suites not run for this document)

| Point | Mocked | Real-DB | JS | Source |
|---|---|---|---|---|
| Start of batch 14 (committed base qb `d4b3b2c`, pfscripts `35b5423`) | 2029 passed / 0 failed (205 files) | 503 passed / 0 failed (53 files) | all green | `scratchpad/BATCH14_BRIEF.md` |
| Batch 14 working tree, last full mocked run reported | 2455 passed / 0 failed (250 files) | area runs only (all green in each area report) | all green | `scratchpad/b14_resume/vehicles_report.md` |
| Spec files on disk 2026-11-03 | 251 mocked spec files | 69 real-DB spec files | 22 JS specs + 1 helper (`statebag_scan_fs.js`) in `tests/js` | directory listing |

The lead records the first full run after batch 14 is committed here; that is the baseline for batch 15.

Existing specs the overhaul builds on (extend or adjust them in the units that own them):
- Police: `sweep_pol_policejob_spec`, `fix14_police_cuffstate_spec`, `fix14_police_fines_spec`,
  `fix14_police_impound_fuel_spec`, `fix14_police_spikes_spec`, `fix14_police_alerts_tracker_spec`,
  `fix13b_police_search_reach_spec`, `citylinks_police_spec`, `police_money_spec`, `police_pay_spec`;
  real-DB `fix14_police_fines_realdb_spec`.
- MDT: `sweep_mdt_access_spec`, `fix14_mdtserver_access_spec`, `sweep_mdt_jail_spec`, `mdt_fine_spec`,
  `boundary_mdt_spec`, `citylinks_mdt_spec`, `mdt_device_mode_spec`, `fix13b_policemdt_request_close_spec`;
  real-DB `fix14_mdtserver_jail_realdb_spec`, `fix14_mdtserver_roster_realdb_spec`; JS `mdt_embed_spec`,
  `fix14_mdtui_xss_spec`, `fix14_mdtui_postmessage_spec`.
- Prison: `fix14_prison_server_spec`, `sweep_pol_prison_spec`, `citylinks_prison_spec`.
- EMS/medical: `pf_ambulance_hardening_spec`, `pf_ambulance_bills_spec`, `ambulance_injury_helpers_spec`,
  `fix9hq2_ems_downcall_spec`, `citylinks_ems_spec`, `emsmdt_security_spec`, `emsmdt_legacy_tables_spec`,
  `fix9hq2_emsmdt_request_close_spec`, `fix14_core_duty_ems_spec`, `fix14_mdtserver_ems_roster_spec`; real-DB
  `ambulance_injuries_realdb_spec`, `fix14_mdtserver_ems_roster_realdb_spec`.
- Government: `government_*_realdb_spec` (business, employees, field requests, house bills, loans, premises,
  property tax, start order), `fix14_govcomputer_*_realdb_spec`.

## 3. Rules for overhaul specs

- Names: `b<batch>_<area>_<topic>_spec.lua` (mocked) and `b<batch>_<area>_<topic>_realdb_spec.lua` (real DB).
- Every new behaviour has a spec that **fails without it**: prove it by running the spec against a scratch copy of
  the old code under the scratchpad (never by editing the repos).
- Every honest-play flow touched by a unit has a spec that still passes (cuff -> escort -> jail; down -> EMS revive;
  check-in -> treated -> bill; sentence -> serve -> release).
- Table-driven specs for every state machine (`PF_ARCHITECTURE.md` section 5): all allowed transitions, a sample of
  refused ones.
- Every export allowlist has a spec with an unlisted invoker (`Mock.invokingResource`).
- Every money path runs on the real ledger (`ledger_env.lua`) with: success, clear refusal, unclear outcome, retry
  with the same key (no double move).
- Every migration version: real-DB spec on a fresh DB, on a DB with the previous versions, and a second run.
- Restart/reconnect: specs fire `onResourceStop`/`onResourceStart`, `playerDropped`, `QBCore:Server:PlayerLoaded`
  and assert the state resumes from the DB.
- Performance: specs count native calls and DB queries per tick for N mocked players (e.g. healthy players cost
  zero engine work).

## 4. Batch results (fill one section per batch)

Copy this template for each batch.

```
### Batch NN (date, commits qb <sha> / pfscripts <sha>)
| Unit | New specs | Result | Fails without the change | Notes |
|---|---|---|---|---|
| NNA | b NN_..._spec.lua (n tests), ..._realdb_spec.lua (n) | pass | yes (n of n fail on old code) | |

Full suites after integration:
- mocked: <passed> / <failed> (<files> files)
- real-DB: <passed> / <failed> (<files> files)
- JS: all green | list failures
- parsecheck: clean on <n> changed Lua files; node --check clean on <n> JS files
- ledger_parallel / sql_install_check: pass | fail
- statebag scan, event collisions: clean | findings

Live checks added to section 5: <ids>
Known gaps: <...>
```

### Batch 15
(to be filled)

### Batch 16
(to be filled)

### Batch 17
(to be filled)

### Batch 18
(to be filled)

### Batch 19
(to be filled)

### Batch 20
(to be filled)

### Batch 21
(to be filled)

### Batch 22
(to be filled)

## 5. Live-server checklist (skeleton; run on staging with at least two clients and an admin)

Record date, commit, result and notes per row. Rows are added by each batch.

### 5.1 Medical engine and down state (batches 15-17)
| Id | Check | Expected |
|---|---|---|
| MED-L1 | Shoot a player in the leg (pistol), then the chest with armour | leg GSW with limp; chest: bruising/rib fracture, no penetration at small calibre |
| MED-L2 | Fall from ~4 m, ~8 m, ~15 m | heel/ankle/tibia; femur/pelvis/spine; multi-trauma; heights logged match |
| MED-L3 | Crash a car at ~40 and ~90 km/h, belted and unbelted | delta-v bands applied; seatbelt moves one band |
| MED-L4 | Go down from bleeding (no GTA death) | consciousness drops on vitals; `pf:down` set; others see the down animation |
| MED-L5 | Die by GTA health 0 | `ReportDown` accepted; death screen; respawn only after the timer |
| MED-L6 | Try to clear down from a modified client (`SetDeathStatus(false)`) | ignored; anomaly logged when moving |
| MED-L7 | Revive by EMS, by civilian first aid, by admin | token flow works; health verified; failure leaves the player down |
| MED-L8 | Relog while down / injured / recovering | same state after relog; recovery advanced by offline time |
| MED-L9 | Drink alcohol, eat a poisoned dish | BAC rises and decays; food poisoning illness |
| MED-L10 | `resmon` with 30+ players, 5 injured | AJ server under budget (architecture 8) |

### 5.2 EMS operations (batch 17)
| Id | Check | Expected |
|---|---|---|
| EMS-L1 | Exam modalities by an EMT and a paramedic | tier-appropriate findings; internal bleeding hidden until FAST |
| EMS-L2 | Tourniquet, splint, IV, TXA, CPR, AED | items consumed first; vitals respond; CPR pauses the arrest timer only while performed |
| EMS-L3 | Stretcher -> rig -> drive -> unload | attachment visible to a late joiner; patient seated by the server |
| EMS-L4 | Pusher disconnects mid-push; rig deleted with patient | patient released at the last position, no frozen ped |
| EMS-L5 | Wheelchair and medbag | |
| EMS-L6 | Monitor attached in the rig | vitals update every 5 s for the medic only |

### 5.3 Hospitals (batches 17, 19, 20)
| Id | Check | Expected |
|---|---|---|
| HOSP-L1 | Check-in with 0 EMS on duty, then with 3 | AI mode after the wait; staff mode with EMS on duty |
| HOSP-L2 | Triage, admit to ward, discharge with restrictions and follow-up | restrictions persist; calendar entry; bill itemised |
| HOSP-L3 | Unpaid bill | phone invoice that cannot be declined; paying it marks the bill paid |
| HOSP-L4 | X-ray/CT confirm a fracture, surgery removes a retained bullet | projectile evidence created once |
| HOSP-L5 | Pharmacy prescription and controlled dispensing log | |
| HOSP-L6 | Inmate infirmary visit and escorted hospital transfer | custody continuity; leaving the zone reported |
| HOSP-L7 | Morgue intake and autopsy for a CK'd character | death record linked to the MDT case |

### 5.4 Police field and traffic (batches 16, 18)
| Id | Check | Expected |
|---|---|---|
| POL-L1 | Surrender, detain, frisk, ziptie, cuff, escort, place in car | server seat choice; escort ends safely if the officer drops |
| POL-L2 | Arrest -> booking -> holding cell | custody record, booking number, property receipt, mugshot flagged client-supplied |
| POL-L3 | Suspect disconnects while arrested | returns cuffed at the station |
| POL-L4 | Radar on a moving car; speed camera | server speeds; ticket once per uid |
| POL-L5 | ALPR hit on a stolen plate flagged in the MDT | alert to on-duty LEO only; read logged |
| POL-L6 | Breathalyzer after drinking | BAC from the medical engine |
| POL-L7 | Impound with a tow driver and without | record with reason; release flows |
| POL-L8 | Bodycam on, draw weapon, cuff, search | timeline shows server-seen actions; UI says metadata, not video |
| POL-L9 | Props, spikes, K9 sniff, drone | caps; results server-decided |
| POL-L10 | GPS blips with a civilian connected | civilian receives no officer positions |

### 5.5 Evidence (batches 15, 18)
| Id | Check | Expected |
|---|---|---|
| EVI-L1 | Shoot, bleed, touch a car; officer collects with and without gloves | drops visible only to nearby officers; integrity reflects gloves |
| EVI-L2 | Restart the server before collection | drops still there (or marked unrecoverable after decay) |
| EVI-L3 | Move a bag officer -> locker -> lab -> court | every move in the chain of custody |
| EVI-L4 | Lab DNA with and without a booked reference | match only with a reference; partial gives candidates |
| EVI-L5 | Ballistics after test-firing a seized gun | casing matched by serial |

### 5.6 MDT (batches 15, 18, 21)
| Id | Check | Expected |
|---|---|---|
| MDT-L1 | Fresh database start | every MDT page loads with no SQL errors |
| MDT-L2 | Case with suspects, evidence, warrant, custody, court submission | links open the right records |
| MDT-L3 | Warrant review by a judge; expiry | status changes audited |
| MDT-L4 | BOLO broadcast to units and ALPR | |
| MDT-L5 | Keyboard-only use of a page in the tablet and computer windows | focus, Enter/Escape, no layout break at 760x640 |

### 5.7 Custody, courts, supervision, community service (batches 15, 16, 19)
| Id | Check | Expected |
|---|---|---|
| CRT-L1 | MDT sentence -> prison -> serve inside only -> release | one clock; property returned once; `injail` mirror correct |
| CRT-L2 | Bail offered and paid by a friend at the desk | paid once; released; exonerated later -> refund once |
| CRT-L3 | Arraignment with no judge on duty | schedule-based bail only; trial waits for a judge |
| CRT-L4 | Probation with curfew; breach | violation report to the officer, no automatic custody |
| CRT-L5 | Community service: sign in, litter and pothole tasks, supervisor sign-off | district state improves; units counted; disconnect keeps progress |
| CRT-L6 | CS deadline missed | court item, no automatic prison |

### 5.8 Prison (batches 16, 19)
| Id | Check | Expected |
|---|---|---|
| PRI-L1 | Intake: uniform, cell by classification | |
| PRI-L2 | Headcount with an inmate outside the zone | alert and infraction report |
| PRI-L3 | Kitchen and laundry work | credits capped; laundry reaches hospital linen stock; wages into trust |
| PRI-L4 | Commissary purchase, release payout of the trust | each move keyed; balance reconciles |
| PRI-L5 | Gate hack escape and recapture | order suspended then resumed with a forfeit; warrant request created |
| PRI-L6 | Lockdown from the Corrections MDT | doors lock with no online player needed |
| PRI-L7 | Visitation booking and contraband search | |

### 5.9 Departments and money (batches 15, 20)
| Id | Check | Expected |
|---|---|---|
| DEP-L1 | Grant/revoke a paramedic qualification | treatments follow the change |
| DEP-L2 | Shifts recorded on duty on/off and on disconnect | |
| DEP-L3 | Procurement order for the hospital delivered by a trucker | facility stock rises; department society charged once |
| DEP-L4 | Budget move with a key retried | money moves once |
