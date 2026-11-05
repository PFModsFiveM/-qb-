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
| Batch 14 committed (qb `ff862ee`, pfscripts `e8ce836`): **baseline for batch 15** | 2496 passed / 0 failed (254 files) | 644 passed / 0 failed (69 files) | all green | lead journal (`scratchpad/ultimate/LEAD_PLAN.md`), `docs/IMPLEMENTATION_REPORT.md` Batch 14 |
| Batch 15 working tree, last unit full runs | 2942 passed / 0 failed (272 files) | 806 passed / 0 failed (81 files) | green (15F run) | 15B round-3 recheck, 15H report; section 4 Batch 15 |

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

### Batch 15 (2026-11-04, working trees on top of qb `ff862ee` / pfscripts `e8ce836`, uncommitted at the time of writing)

Every unit was built, then checked by a separate adversarial agent (read the diff, traced honest play, wrote probe
specs against the code, mutation-tested the new specs, ran the full suites). Units that failed an item were reworked
and checked again. All nine passed. Counts below are from the unit's last check or recheck; later follow-ups added
tests on top of them.

| Unit | New specs (tests at the last check) | Result | Fails without the change | Notes |
|---|---|---|---|---|
| 15A medical engine | `b15_medical_models_spec` (46), `b15_medical_engine_spec` (25), real-DB `b15_medical_store_realdb_spec` (11); `ambulance_injuries_realdb_spec` adjusted (14) | pass | yes: mutation proofs (scratchpad `b15a_mut`) | Check passed first time; follow-ups (cap-merge key, atomic `UpdateInjury`, GCS cap + `hold_until`, online-only activation, busy load) added after |
| 15B justice core | `b15_justice_states_spec` (21), `b15_justice_orders_spec` (56), `b15_justice_clock_spec` (22), real-DB `b15_justice_schema_realdb_spec` (21) | pass after 3 rounds | yes (probe specs failed on round-1/2 code: waiver with a live invoice, refused payment losing `referred`, double credit on a DB error, skipped conviction) | Round 3 recheck: justice mocked 176/0 (6 files with 15C), justice real DB 41/0 |
| 15C custody/booking/property/bail/import | `b15_justice_custody_spec` (23), `b15_justice_property_spec` (20), `b15_justice_bail_spec` (30), real-DB `b15_justice_import_realdb_spec` (20) | pass after 4 rounds | yes (probe sets P1-P9, Q1-Q4 failed on the earlier code, pass now; round 4 used mutation tests) | Round 4: all 13 probes pass, full mocked 2941/0 |
| 15D evidence | `b15_evidence_store_spec`, `b15_evidence_custody_spec`, `b15_evidence_scene_spec` (55 together), real-DB `b15_evidence_realdb_spec` (21); `sweep_pol_policejob_spec` patched (12), `fix14_police_fines_realdb_spec` adjusted (7) | pass | yes (scratch copy of the batch-14 code in `proof15d/old`) | Checker probes for the upgrade path and weak points (`p15d/realdb`); follow-ups: per-player drop cap, locale-free drawers, lab/court presence, civilian holder gap |
| 15E work orders + keyed budgets | `b15_gov_workorders_spec` (19), real-DB `b15_gov_workorders_realdb_spec` (18), `b15_gov_budget_keys_realdb_spec` (10) | pass | yes (old-code copy `b15e_old`) | government mocked 73/0, government real DB 146/0; `government_property_tax_spec` fixed for the new config. Follow-ups (grade fixes, ledger key on pending retry, `next_check_at`, weather site) after the check |
| 15F police MDT schema | `b15_mdt_schema_spec` (12), real-DB `b15_mdt_schema_realdb_spec` (8), `b15_mdt_startup_realdb_spec` (4); `fix14_mdtserver_jail_realdb_spec` (29) and `fix14_mdtserver_roster_realdb_spec` (7) adjusted | pass after 1 fix | yes (seed tests fail on the old seed guard) | MDT mocked 147/0, MDT real DB 57/0, MDT JS specs green; checker ran MariaDB `PREPARE` on 251 SQL literals from the server files against a fresh v7 DB (232 pass, 15 expected) |
| 15G EMS MDT schema | `b15_emsmdt_schema_spec` (11), real-DB `b15_emsmdt_schema_realdb_spec` (6); `emsmdt_legacy_tables_spec`, `fix14_mdtserver_ems_roster_realdb_spec` (3) adjusted | pass | yes (old-code copy `b15g_old`) | emsmdt mocked 34/0; checker probe restarted 3 times on a real DB with no SQL errors |
| 15H platform hooks | `b15_hooks_doorlock_spec` (21), `b15_hooks_consumed_spec`, `b15_hooks_phone_cancel_spec` (7) (41 together), real-DB `b15_hooks_phone_ref_realdb_spec` (16), `b15_hooks_jobgarages_realdb_spec` (13); `citizen_phone_realdb_spec` adjusted | pass | yes (fail-without-fix copy `h15/fwf`) | doorlock 40/0, phone 147/0, phone real DB 46/0, jobgarages 24/0, smallresources 10/0. Lead fix after the check: pf-citizen keeps `cancelled` (real-DB spec fails without it) |
| 15I department core | `b15_gov_departments_spec` (44), real-DB `b15_gov_departments_realdb_spec` (11) | pass | yes (old-code copies `old15i`, `old15i2`) | b15_gov mocked 66/0, b15_gov real DB 42/0; hardening follow-up (fail-closed callers, key on `unchanged`, grants scoped to the owning department, `max_length` shifts, corrupt `players.job`) after the check |

Latest full counts reported by the units (before the lead's final run):
- mocked: 2942 passed / 0 failed (272 files) (15B round-3 recheck and 15H check)
- real-DB: 806 passed / 0 failed (81 files) at 15H's full run
- JS: green in the 15F run (`fix14_mdtui_postmessage`, `fix14_mdtui_xss`, `mdt_embed`, `pfdevices_runtime`, `citizen_apps`)
- parsecheck: clean on every changed Lua file in each unit; no `<const>`/`<close>`

Full suites after the lead's integration (final run):
- LEAD: to be filled by the lead (mocked / real-DB / JS / parsecheck / ledger_parallel / sql_install_check / statebag scan / event collisions)

How the checks worked (batch 15):
- **Probe specs** written by each checker outside the repos (scratchpad `b15/probe15B*`, `b15/15C_probe`, `b15/p15d`,
  `b15/probe15E`, `b15/probe15g_realdb`, `b15/15H_probe`, `b15/probe15I`, `chk15a`, `b15chk/probe`), run with the same
  harness against the working tree. A probe that fails is a finding; the builder fixes it and the probe must pass on
  the recheck. Probes stay out of the repo; the builder adds a repo spec for each fixed finding.
- **Mutation tests** (`b15/mut_tools`, `b15/mut`, `b15/mut_r3`, `b15/mut_r4`, `b15/mutrdb`, `b15a_mut`): a tool applies one
  deliberate break to a scratch copy of the new code (drop a lock, skip a compare-and-set, re-key an unclear payment,
  remove an allowlist check) and the unit's specs must fail on it. Used for 15A and for the later rounds of 15B/15C.
- **Fail-without-fix** for changed behaviour: the new specs run against a scratch copy of the old code (batch-14 files
  from git) and must fail there.
- **Real-DB upgrade paths** for every moved migration: a database built by the old code (or by the hand-imported SQL
  file, with staff edits) upgraded by the new schema with no re-applied version and no data change.

Live checks added: section 5.10 (batch 15).
Known gaps: see `PF_REMAINING_WORK.md` sections 6-7 (batch-15 open items and hand-over steps).

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

### 5.10 Batch 15 foundations (collected from every unit's report and check; nothing here was run in game)
Most batch-15 owners have no player UI yet (MDT pages are 21B, GOV apps 20E/21G): drive them from the server console
or a small admin helper resource on the allowlist. Do not test on a server with real data.
| Id | Check | Expected |
|---|---|---|
| B15-L1 | Start the full server on a fresh database, then restart it twice | every resource starts; `pf_schema_migrations` shows pf-ambulancejob 1-3, pf-emsmdt 1-2, pfm-policejob 1-2, pf-policemdt-DEV 1-7, pf-justice 1-2, pf-government 1-6, pf-jobgarages 1; no SQL errors in the console |
| B15-L2 | Start on a copy of a database where the MDT SQL was imported by hand and staff edited charges, cameras and templates | no data change; nothing staff deleted comes back; every police MDT page loads (MDT-L1) |
| B15-L3 | EMS MDT on a fresh DB and after a restart: edit an SOP, restart, open a patient profile | pages load; the SOP edit survives (`ForceSeed = false`); the profile answers (no hang) |
| B15-L4 | Injure a player through `ApplyInjury` (allowlisted helper), relog, then stop and start pf-ambulancejob | the patient row persists and catches up after the relog; the flush on resource stop completes (the stop handler waits on SQL) |
| B15-L5 | Eat, drink, drink alcohol, eat a poisoned dish; try with an item the server cannot remove | `pfm-smallresources:server:consumed` once per item, none when the removal fails; AJ toxin level rises for alcohol/poison (`GetPatientSummary` from pf-emsmdt) |
| B15-L6 | Shoot, bleed and leave prints near two officers (one on duty, one off duty) and a civilian; restart before collection | only the on-duty officer within 150 m sees the drops; drops are still there after the restart; a player spamming drops replaces their own oldest (cap 50 per kind) |
| B15-L7 | Bag drops; move the bag to a station drawer (also on a non-English locale), to another officer, onto the ground and back, into a trunk; collect prints with and without `nitrile_gloves` | one custody row per move with the right holder; drawer moves show `stored`/`checked_out`; integrity -10 without gloves; the gloves icon shows (the image is missing today) |
| B15-L8 | Transfer evidence to the lab and to the court standing at the configured spots (lab 442.17, -996.07, 30.69; court -544.85, -204.40, 38.22) and away from them | accepted only at the spot (`too_far` elsewhere); confirm the coordinates are the right rooms (placeholders) |
| B15-L9 | `/fine` an online and an offline player, pay and refuse | works as in batch 14 after the migration move |
| B15-L10 | `SetDoorState` on `bolingbroke_gate_1..3`, `mrpd_cells_main`, `mrpd_cell_1..3` with nobody near, with two clients watching, and with a late joiner | the right physical door changes for everyone, sound plays, no animation on anyone; a door already in that state is not re-sent; a corrections officer can use the Bolingbroke gates; the prison gate hack still works |
| B15-L11 | Pay a fine through a phone invoice with a ref; cancel an invoice from pf-justice while the payer has it open and while paying | one payment; a cancel during payment returns `busy` and the payment wins; the Bills app history shows Cancelled for a cancelled invoice |
| B15-L12 | Job garages: set a fleet car `in_service`, try to take it out; set `ok` | refused while in service; works again after `ok`; `last_service_at` set |
| B15-L13 | Set players to every grade of `corrections`, `doj`, `judge`, `lawyer`; toggle duty; check pfm-banking | labels right; society accounts `corrections` and `doj` exist; pay per grade still to be set by the owner |
| B15-L14 | Shifts: duty on/off, drop, job change, server restart, a 16 h shift; go on duty with an active JU order (created by an admin helper) | one shift row per stretch with the right end reason (`max_length` after 16 h); the incarcerated employee is put off duty at once |
| B15-L15 | Work orders: let a district cross a threshold; fire a store robbery, a race finish and severe weather; claim and report a CS unit through pf-justice standing on site, leaving early, in a car | orders appear at sensible sites (verify every work-site coordinate in game); `too_soon` when leaving early; district state improves on the government infrastructure page and stays improved |
| B15-L16 | Keyed budget moves and work-order payouts with the societies `dot`, `government`, `corrections`, `doj` | each move once; a missing society shows as a clear failure, not a double move (no paid non-CS work order has a caller yet: use a helper) |
| B15-L17 | JU custody through exports: open custody, disconnect while arrested, reconnect; book at the MRPD desk; assign a holding cell to a downed suspect; seize and return property with a full inventory; bail paid by a friend at the desk | back at the return point and cuffed; booking number and receipt; cell refused for a patient who needs hospital; nothing lost, leftovers come back at the next login; bail paid once |
| B15-L18 | Legacy coexistence: jail through the MDT and through `/jail`, release, relog, restart pf-justice in between | both old jails work as before; JU shows shadow orders that close within 60 s of the release; nobody is jailed twice; jail items come back once (from pfm-prison) |
| B15-L19 | Delete a character that has medical, justice, evidence and department rows | AJ and department rows removed; JU orders closed and anonymised |
