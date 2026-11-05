# PF Ultimate: implementation progress

The tracker for the overhaul. Update it at the end of every batch (lead) and resume from the journal at the bottom.

**Status values** (one per row):
- **Not started**
- **In progress** (a unit is working on it)
- **Implemented** (code exists; may be legacy or partial, see notes)
- **Integrated** (wired to the systems it depends on)
- **Tested (automated)** (implemented/integrated and covered by automated specs: mocked and/or real-DB/JS). Written
  "Tested" in older rows; it always means automated specs, never a game client.
- **Blocked** (needs something outside the code)

Nothing is validated with a game client yet (no FiveM client in the development environment). "Legacy" in a note
means the piece works today but is replaced or reshaped by the batch named.

Base: batch 14 is committed (qb `ff862ee`, pfscripts `e8ce836`). Batch 15 (2026-11-04) is built, checked and reworked
in the working trees, uncommitted at the time of this update; its rows count as committed once the lead's final
integration run is green and the lead commits. Batch-15 owners run **alongside** the old runtimes: the switch-over is
batch 16, so "Tested (automated)" on a batch-15 row means the new owner and its contract work, not that players use it
yet.

## 1. Medical engine (owner pf-ambulancejob)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Legacy limb/bleed model (15 client regions, bleed 0-4) | Implemented | AJ client | 16/17 retire | Legacy: client-authoritative, never persisted; painkillers pause bleeding |
| DB injury records `player_injuries` (6 zones, 8 types) | Tested | AJ | 16B import | Legacy: values chosen by the client; real-DB spec `ambulance_injuries_realdb_spec` |
| Anatomy entities (structures, regions, bone map) | Tested (automated) | AJ `shared/medical/anatomy.lua` | 15A | 61 structures (left/right), 25 weighted regions, `MechanismStructures` for non-bone structures, `BoneMap` for every `Config.Bones` id (56; weighted roll for multi-region bones). `b15_medical_models_spec` |
| Injury catalog (fractures..infection, 19 categories) | Tested (automated) | AJ `shared/medical/injuries.lua` | 15A | 19 types with subtypes, per-severity bleed/pain/heal data, effects, stage machine. Not used by live damage yet (16B ingestion) |
| Physiology model, derived vitals | Tested (automated) | AJ `shared/medical/physiology_model.lua` | 15A | Pure and deterministic (exact clotting integral, so tick size does not matter); loss classes I-IV at 15/30/40 %; tension pneumothorax, airway, opioid overdose + naloxone; consciousness alert -> altered -> unconscious -> arrest one level per evaluation; GCS capped at 8 when a level is forced from outside. Deviation: RR = 14 + 3 x (class - 1) |
| Patient store + persistence + offline catch-up | Tested (automated) | AJ `server/medical/store.lua`, `engine.lua` | 15A | Load on `PlayerLoaded` with offline catch-up (bleed capped at 120 s), write-behind every 10 s (multi-row upserts), flush on drop/unload/stop; a held down state survives a relog (`hold_until`, v3); only active patients tick (40 healthy players -> 0 reads). Engine pushes nothing to clients and writes no metadata yet (16A). Real-DB `b15_medical_store_realdb_spec` |
| Server-owned down/death state | Not started | AJ `server/medical/downstate.lua` | 16A | Today `isdead`/`inlaststand` come from client events; carry-over (a) from batch 14 lands here. The 15A engine already has the consciousness machine, `SetConsciousness` (report/rosc/revive/respawn, hold) and CPR pausing arrest-to-death; 16A wires it to the down state |
| Damage ingestion with plausibility (weaponDamageEvent, health sampler, falls, crashes) | Not started | AJ `server/medical/ingest.lua` | 16B | |
| Functional effects (walk, sprint, aim, drive, vision...) | Implemented | AJ client + `shared/medical/effects_model.lua` | 15A/17C | Legacy client limb effects still apply. The new model (15A, Tested (automated)): per-channel maximum, splint/cast cap 2, painkillers only pain/aim, crutches walk 2 no sprint. Applier on the client is 17C |
| Toxins (alcohol, poisoning, drugs) | Tested (automated) | AJ engine + pfm-smallresources | 15A/15H | `AddToxin` export (online patients, allowlisted); AJ listens to `pfm-smallresources:server:consumed` (ethanol, poisoned food). Toxin levels change vitals in the engine only (no client effect yet). pfm-drugs hook still unscheduled |
| Diagnosis layers + exam modalities | Implemented (storage only) | AJ | 15A/17A | Tables `pf_med_findings`/`pf_med_diagnoses` (v3, earlier than planned) and `Store.AddFinding/ListFindings/SetDiagnosis/ListDiagnoses` (only imaging/lab/surgery may confirm). Exams are 17A. `/checkinjuries` scan exists (Tested) and becomes the exam entry |
| Treatment engine with equipment | Implemented | AJ | 17B | Legacy: `/treat` with 4 generic treatments (server-validated, Tested); self-use items heal on the client |
| Recovery stages + restrictions + offline progression | Not started | AJ | 17C | |
| Medical records privacy | Not started | AJ | 17A | `GetPatientSummary` already filters fields per caller (15A) |
| Medical engine exports (`GetPatientSummary`, `IsDown`, `ApplyInjury`, `AddToxin`) and events (`consciousnessChanged`, `injuryAdded`) | Tested (automated) | AJ `server/medical/api.lua` | 15A | `Config.Medical.Callers` + `SummaryFields` (police/prison get only down, consciousness, stage, restrictions). `ApplyInjury` needs `opts.key` and an online patient; keyed requests at the 40-open-injury cap are refused (no double merge). Used by pf-justice booking screening |
| Medical rows on character delete | Tested (automated) | AJ `store.lua` | 15A | `pfm-core:server:characterDeleted` removes `pf_med_*` and legacy rows (player source ignored) |

## 2. EMS operations (owners pf-ambulancejob, pf-emsmdt)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Person-down and medic calls opened/closed by the server | Tested | AJ `PFEmsRequests` + pf-services | b13/13b | Down detection gate uses server health |
| EMS dispatch board (pf-services -> EMDT) | Tested | EMDT | b10 | |
| EMS duty points | Tested | AJ + pfm-core | b14 | `fix14_core_duty_ems_spec` |
| Revive (medic, first aid) | Implemented | AJ | 16A/17B | Legacy: no distance/down check, client argument, auto-ban race |
| Stretcher | Implemented | pfm-radialmenu | 17D | Legacy placeholder (`prop_ld_binbag_01`), not tied to rigs |
| Wheelchair, medbag, rig loading | Not started | AJ `server/ems/equipment.lua` | 17D | |
| Rig stock, restock, maintenance | Not started | AJ `server/ems/fleet.lua` | 20C | |
| Units, crews, handover, PCR | Not started | EMDT | 20D | Unused SQL-file PCR tables in AJ |
| EMS MDT pages (dashboard, dispatch, patients, roster, SOP, staff) | Implemented | EMDT | 21C | Medical tab always empty; injury panel always reports success |
| EMS roster backups | Tested | EMDT | b14 | |
| EMS MDT tables by migrations | Tested (automated) | EMDT `server/schema.lua` | 15G | v1 moved unchanged, v2 function step creates the 9 tables the code uses; start-up jobs wait for the schema; the patient profile always answers once (8 s timeout, `not_ready`). Lead: `Config.SOP.ForceSeed` now `false` (it wiped SOP edits on every start) |
| Qualifications (EMR..surgeon) as scope of practice | Implemented | GOV departments + AJ | 15I/17B | GOV side Tested (automated) in 15I: implied by grade until granted (`emr`..`surgeon`); AJ treatments check them in 17B |

## 3. Hospitals (owner pf-ambulancejob; UI pf-emsmdt)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Check-in desk, beds, "AI doctor" timer | Implemented | AJ | 17E | Legacy: doctor-count gate on the client, zone bugs, 20 s self-heal |
| Hospital bill | Tested | AJ | 17E | Legacy flat $2000: charge to a sink, then society mint; `pf_ambulance_bills_spec` |
| Respawn at nearest hospital | Implemented | AJ | 16A | Legacy: no dead check on the server |
| Triage, admissions, discharge, transfers | Not started | AJ `server/hospital/admissions.lua` | 17E | |
| AI care at low population | Not started | AJ `server/hospital/ai_care.lua` | 17E | |
| Itemised billing + unpaid invoices | Not started | AJ `server/hospital/billing.lua` | 17E | needs pfm-phone `ref` (15H) |
| Pharmacy, lab, imaging, surgery, wards | Not started | AJ | 20A | |
| Morgue / medical examiner | Not started | AJ | 20B | |
| Supplies via pf-stores/pf-trucking | Not started | GOV procurement + AJ | 20C | |
| Prison infirmary | Implemented | AJ + PR | 19G | Legacy jail beds with index bugs; no staff or screening |
| Hospital workstation app | Not started | EMDT | 21D | |
| Insurance | Blocked | - | - | No insurance system exists to integrate; config discounts only (open decision) |

## 4. Police field and traffic (owner pfm-policejob)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Hard/soft cuffs, server-owned state | Tested | PJ | b14 | `fix14_police_cuffstate_spec`; relog cuffs in memory only |
| Resist cuff minigame (server roll) | Tested | PJ | b14 | |
| Search with reach | Tested | PJ + pfm-inventory | b13b | |
| Escort, drag, put in/out of vehicle | Implemented | PJ | 18A | Partly server-checked; escort and seat client-driven |
| Surrender, detain, frisk, zipties | Not started | PJ `server/custody_field.lua` | 18A | |
| Arrest -> custody record | Not started | PJ -> JU | 18A | |
| Seize cash (ledger moneybag) | Tested | PJ | b13 | |
| Seize driver licence | Implemented | PJ | 18A | Bug: wipes other licences |
| Bill menu (ledger, no record) | Tested | PJ | - | |
| `/fine` with records and sweep | Tested | PJ `server/fines.lua` | b14 | Migration moved unchanged to `server/schema.lua` v1 (15D; real-DB proves no re-run). New fines become JU orders in 16D |
| `/jail` through pfm-prison | Tested | PJ + PR | 16D | Becomes a JU order; custody check added |
| Tackle | Implemented | PJ | - | |
| Spikes (server-spawned, capped) | Tested | PJ | b14 | |
| Props (cones, barriers...) | Implemented | PJ | 18C | Legacy: client-spawned, no caps |
| Radar gun, speed cameras | Not started | PJ `server/traffic.lua` | 18B | |
| ALPR | Implemented | PJ | 18B | Legacy: fixed points, flag check only, in-memory flags, no read log |
| Registration/licence checks, run plate | Implemented | PJ + PMDT | 18B | `/plateinfo` + MDT vehicle profile; no single `RunPlate` |
| Breathalyzer | Not started | PJ | 18B | |
| Citations (one entity) | Implemented | JU `IssueCitation` + PJ | 15B/18B | JU side Tested (automated): `IssueCitation` (on-duty officer, server position), contest window `ContestCitation`/`DecideCitation`. No caller yet: PJ/PMDT use it in 18B; four parallel fine paths remain until then |
| Impound / depot with tow job | Tested | PJ + pf-jobs tow | b10/b14 | No impound record table (18B) |
| Traffic incident records | Not started | PJ | 18B | |
| Bodycam/dashcam (telemetry timeline) | Not started | PJ `server/telemetry.lua` | 18C | Honest: metadata, not video |
| GPS blips | Implemented | PJ | 18C | Bug: every LEO/EMS position broadcast to every client |
| Panic / officer down | Implemented | PJ | 18C | Does not reach the MDT board |
| GSR test | Implemented | PJ | 18C | Self-reported by the shooter's client |
| K9, drones, riot shields | Not started | PJ | 18C | |
| Ankle tracker (on demand) | Implemented | PJ | 19B | Supervision monitors in JU |
| Duty points | Tested | PJ + pfm-core | b14 | |
| Armory / equipment checkout | Not started | PJ `server/armory.lua` + GOV assets | 20F | `Config.ArmoryWhitelist` unused |
| Use-of-force, pursuit reports | Not started | PMDT | 20F | |

## 5. Evidence (owner pfm-policejob)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Casings, blood, fingerprints (scene drops) | Tested (automated) | PJ `server/evidence/scene.lua` | 15D | The legacy net events forward to the module: 5/s per player per kind, 200 per 100 m cell, 6000 total, 50 live per player per kind (the next replaces the oldest); identity and position from the server; persisted in `pf_evidence_scene_drops` (survive restarts, decay to `unrecoverable`); sent only to on-duty police within 150 m. The client still reports drops (cannot frame others) |
| Evidence bags | Tested (automated) | PJ + pfm-core item `evidence_bag` | 15D/15H | Bagging (on-duty, 2.5 m) consumes `empty_evidence_bag` and gives an `evidence_bag` with `info.evidenceId`; blood label is a random sample id `S-XXXXXXXX`. `/takedna` still writes the citizenid hex (18D) |
| Drug seizure -> news lead | Integrated | PJ | b10 | |
| Persistent evidence + chain of custody | Tested (automated) | PJ `server/evidence/*` | 15D | `pf_evidence_items`/`pf_evidence_custody`; every bag move between inventories (stash, drawer, trunk, search, give, drop/pickup) is a custody row from pfm-inventory listeners; drawers recognised from the locale phrase (any language); integrity score (seal break outside lab/court -12, gap > 30 min incl. a civilian holder -20, no gloves -10). Gaps: `ClearInventory` (pfm-prison) records nothing; `TransferEvidence` kind `release` from the MDT reaches disposal (see remaining work) |
| Evidence lockers per case | Not started | PJ | 18D | Shared drawers today; the table `pf_evidence_lockers` exists since 15D (v2) |
| Lab processing, reference samples, ballistics | Not started | PJ `server/evidence/lab.lua` | 18D | |
| Medical -> forensics (retained projectiles) | Not started | AJ -> PJ | 20A/18D | |
| MDT photo evidence | Implemented | PMDT | 18E | Photo records only; linked to cases in 18E |
| Evidence camera webhook in a replicated convar | Blocked | PMDT | 18F | Webhook rotation is an owner action; the code moves the upload server-side |

## 6. MDT (owners pf-policemdt-DEV, pf-emsmdt)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Police-only gate on MDT handlers | Tested | PMDT `server/access.lua` | b14 | Gaps listed in the audit fixed in 18F |
| Dashboard, dispatch, citizens, vehicles, incidents, reports, weapons, penal code, FTO, templates, roster, officers, SOP | Implemented | PMDT | 21A/21B | Reports auto-approve after 24 h (18F) |
| Sentencing (fine, jail, bail, citation paper) | Tested | PMDT `server/sentencing.lua` | 16D | `fix14_mdtserver_jail_realdb_spec`; jail/bail move to JU |
| MDT built-in jail | Tested | PMDT | 16D retire | Duplicate of pfm-prison; imported into JU |
| MDT tables created by migrations | Tested (automated) | PMDT `server/schema.lua` | 15F | v1-v6 moved unchanged; v7 function step creates the 30 SQL-file tables + templates + ESX licence table, adds missing columns/indexes, seeds only tables v7 created. Every start-up DB path waits for the schema (sentencing, officers, SOP, roster, CCTV, chat wipe). The SQL file can no longer drop tables. `sql_init.lua` deleted |
| Warrants v2 (citizen link, judge review, expiry, served link) | Not started | PMDT + JU | 18F/19A | |
| Cases and investigations | Not started | PMDT `server/cases.lua` | 18E | |
| BOLO board, plate flags export | Not started | PMDT | 18F | Flags are free strings today |
| Record read/edit audit | Not started | PMDT | 18F | |
| CCTV (auto-discovered cameras) | Implemented | PMDT | 18F | Recordings never written; UI must stop claiming them |
| MDT on tablet and computer (iframe) | Tested | PMDT/EMDT + pf-devices | b10 | `mdt_embed_spec.js` |
| mdt-server rework UI leftovers | In progress | PMDT client/html | 16D/21A | From batch 14: StartMdtSentence, BailOffer, allowNegativeBank, bail toast, licence reason, licenseActions/releasedOnLogin, protected_chief text |

## 7. Custody, booking, jail (owner pf-justice)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| pf-justice resource | Tested (automated) | JU | 15B | New resource (started by `ensure [pfscripts]`), no net events, every export allowlisted. Runs alongside the old jails (`Config.Compat.LegacyRuntimes` all true) |
| Orders of every kind + one clock | Tested (automated) | JU `orders.lua`, `clock.lua`, `shared/states.lua` | 15B | State machines as data; `CreateOrder` keyed (duplicate/key_reused); one active incarceration per citizen (others pending, concurrent/consecutive); online/hybrid/realtime clock with presence provider or fallback radius, hospital custody counts; `releaseOrdered` once. Fines: keyed `PayOrder`, phone invoice on a clear refusal, unclear held and settled by the sweep; a waiver of an invoiced fine cancels the invoice or refunds a late payment. Nothing creates orders yet: MDT/PJ/prison switch in 16C/16D |
| Custody record (arrest to release), reconnect safety | Tested (automated) | JU `custody.lua` | 15C | Custody machine with compare-and-set moves and a log row per move; one open custody per citizen; hospital transfer keeps the previous state; reconnect puts the player back at the return point/cell and re-cuffs (`SetCuffed`). No caller opens custody yet (18A/16D) |
| Booking (number, prints, DNA sample, mugshot, screening) | Tested (automated) | JU `booking.lua` | 15C | `BK-<yyyymmdd>-<seq>`, fingerprint/blood type from server metadata, random `DNA-` token passed to PJ `RegisterReferenceSample` when it exists, https mugshot stored `client_supplied = 1`, screening through AJ `GetPatientSummary` |
| Holding cells | Tested (automated) | JU + pfm-doorlock aliases | 15C/15H | `AssignHoldingCell` refuses patients who must go to hospital; `IsInHoldingCell` presence; door aliases `mrpd_cells_main`, `mrpd_cell_1..3` exist (15H). Door locking from JU is 18A |
| Property seizure with receipts | Tested (automated) | JU `property.lua` | 15C | Receipt first, inventory re-read until it matches, items into `pf_justice_property_<id>` with rollback; return never clears current items, leftovers come back at the next load; forfeit through PJ `CreateEvidence` (method `seizure`). Legacy items stay in metadata (PR) or JSON (MDT) until 16C/16D |
| Bail | Tested (automated) | PMDT (live) + JU (built) | 15C/16D | JU bail built and checked in 15C (keyed payment to `society:doj`, payer near the officer or at a desk, unclear held, refund on exoneration exactly once, offers expire when custody or order ends). The MDT bail is still the live one until 16D relays it |
| Criminal record | Implemented | PJ/PR metadata (live) + JU records (built) | 15B/15C | JU records Tested (automated): one conviction per finished order, soft `Expunge` with audit, per-caller field filter, legacy `hasRecord` imported as a `legacy_flag`. Legacy metadata bug (expiry never saved, `prison:server:CheckRecordStatus`) stays until 16C/16D make JU the writer |
| Legacy import (MDT jails, offline injail) | Tested (automated) | JU `legacy_import.lua`, `compat.lua` | 15C | JU v2 step: MDT jails, offline `injail`, `jailitems`, `hasRecord` become JU rows once (real DB); online players at load. While the legacy runtimes run, imported orders are shadows closed by `LI.SyncTick` (60 s); receipts stay `legacy` |

## 8. Prison and corrections (owner pfm-prison)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Server-owned sentence countdown, inside-walls check | Tested | PR | b14 | Moves to the JU clock in 16C (PR keeps the presence test) |
| Escape detection through hacked gates | Tested | PR | b14 | |
| Gate hack with minigame verdict | Tested | PR + pfm-minigames | b14 | |
| Electrician job with time cuts | Tested | PR | b14 | carry-over (c): teleport check in 16C |
| Jailing sets job to unemployed | Implemented | PR | 16C | D1 adopted (keep the job, off duty). GOV shifts (15I) already force an employee with an active/suspended JU incarceration off duty; pfm-prison still sets unemployed until 16C |
| Driven by pf-justice orders | Not started | PR `server/justice_bridge.lua` | 16C | |
| Housing, cells, classification, uniforms | Not started | PR | 19D | |
| Routines, headcounts | Not started | PR | 19D | |
| Discipline with due process | Not started | PR | 19D | |
| Visitation | Not started | PR | 19D | |
| Prison jobs tied to real operations | Not started | PR | 19E | kitchen, laundry, maintenance |
| Commissary, trust accounts, earnings, restitution | Not started | PR | 19E | |
| Doors, cameras, alarms, contraband, searches, lockdowns | Implemented | PR | 19F | Legacy: alarm/lockdown exist; doors need an online player to relock. pfm-doorlock `SetDoorState` (no player needed, aliases `bolingbroke_gate_1..3`) exists since 15H; pfm-prison uses it from 16C/19F |
| Corrections officer job | Implemented | pfm-core jobs | 15H | `corrections` grades 0-5 (cadet .. warden), Bolingbroke doors allow `corrections = 0`. Grade pay to be set by the owner |
| Corrections MDT | Not started | PR | 21E | |

## 9. Community service, courts, probation, parole (owner pf-justice)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Government work orders | Tested (automated) | GOV `server/workorders.lua` | 15E | Generator from district thresholds (one per rule, max 3 open per district) and city events (`weather.severe` uses a district site); claims (one unit, 600 s, one per citizen), server-position proof with minimum seconds on site (`too_soon`), effect saved to the district; paid workers on numbered keys. Only pf-justice may claim (CS); paid non-CS work has no caller yet (20E/21 GOV apps) |
| Community service runtime | Not started | JU | 19C | |
| Courts: cases, hearings, decisions, release orders | Not started | JU | 19A | judge/lawyer jobs are one-grade stubs |
| Warrant approval | Not started | JU + PMDT | 19A/18F | |
| Probation / parole, monitors | Not started | JU | 19B | |
| Expungement with audit | Implemented | GOV (live) + JU `Expunge` (built) | 19A | JU `Expunge` Tested (automated) in 15B (soft delete + audit; judge on duty, gov `records` permission, admin). GOV's unaudited hard delete of MDT rows stays until 19A |
| Court/Justice app, CS app, records portal | Not started | JU | 21F | |

## 10. Department management (owner pf-government)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Budgets and linked society accounts | Tested (automated) | GOV `server/budgets.lua` | 15E | Optional trailing `key` on `SpendFromDepartmentSociety`/`AddFundsToDepartmentSociety`: pending -> applied/failed rows, one ledger transfer for funding, unclear held and settled by `ReconcileBudgetMoves` (60 s, rows re-checked later so none hide the others). Unkeyed path unchanged. `corrections` and `doj` departments added. `CreateBill` export passes `issuedBy, issuedByName, recurring` |
| Ranks, hire, fire | Implemented | pfm-management | - | |
| Officer HR (discipline, profiles) | Implemented | PMDT / EMDT `officers.lua` | 20F | |
| Fleet garages | Tested (automated) | pf-jobgarages | 15H | Migration key `pf-jobgarages` v1; `GetFleetVehicle`, `ListFleet`, `SetServiceState` (allowlisted, per-plate lock, audit, `serviceStateChanged`); a car `in_service`/`out_of_service` cannot be taken out |
| Qualifications, shifts | Tested (automated) | GOV `server/departments/*` | 15I | Implied by job grade (fails closed), grants count only while working in the qualification's department, revocations override; manager-only changes, keyed; shifts from duty events with the live job deciding, closed on drop/job change/restart and at `MaxShiftHours` (16) every minute; D1 forced off duty while incarcerated; audit with 180-day sweep. Callers: the MDTs (UI in 21G/20E) |
| Training, asset register, procurement, payroll reports | Not started | GOV | 20E | Pay stays in the pfm-core paycheck |
| Department admin app | Not started | GOV | 21G | |

## 11. Platform hooks and cross-cutting

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Doorlock state export without a player | Tested (automated) | pfm-doorlock | 15H | `SetDoorState`/`GetDoorState`, `Config.StateCallers` {pfm-prison, pf-justice}, `Config.DoorAliases` by coordinates; legacy `updateState` unchanged. No caller yet (16C/19F) |
| Phone invoice idempotency `ref` | Tested (automated) | pfm-phone | 15H | carry-over (b) from batch 14 closed: `CreateInvoice` `data.ref` (unique index, duplicate returns the first id); new `CancelInvoice(idOrRef, opts)` (allowlisted, loses to a payment in progress). Used by pf-justice fines (ref `pf-justice:order:<id>`); pf-citizen bills history shows `cancelled` (lead fix) |
| Consumed-item server event | Tested (automated) | pfm-smallresources | 15H | `pfm-smallresources:server:consumed(src, item, kind, info)` only after the server removed the item; AJ listens (15A) |
| New jobs and grades (corrections, doj, judge, lawyer) and items (`evidence_bag`, `nitrile_gloves`) | Implemented | pfm-core `shared/jobs.lua`, `shared/items.lua` | 15H | Match pf-government departments and pf-justice config (spec). Grade pay and the `nitrile_gloves.png` icon are still to do |
| Structured police alerts | Not started | PJ | 18C | carry-over (d) from batch 14 |
| Shared UI tokens | Not started | pf-devices `runtime.css` | 21G | lead-approved exception |
| End-to-end specs | Not started | tests | 22A | |
| Live-server test campaign | Blocked | owner | after 22 | needs a FiveM server with clients |

---------------------------------------------------------------------------------------------------------------------

## 12. Development journal

### 2026-11-03: audit, research and architecture done
- Read-only audits written (scratchpad `ultimate/audit_police.md`, `audit_medical.md`, `audit_custody_integration.md`)
  and the public research (`ultimate/research.md`). Key findings: two jails (pfm-prison metadata vs MDT table), two
  injury systems (client limb model vs client-reported DB rows), client-reported death state used as a trust anchor
  by six resources, evidence in memory with reversible DNA labels, MDT tables only from a hand-imported SQL file,
  no work-order API in government infrastructure, no court/probation/CS code.
- Lead's owner decisions applied (`PF_ARCHITECTURE.md` section 1): clinical state and hospital ops in
  pf-ambulancejob, records UI in the MDTs, evidence in pfm-policejob, custody/justice/CS in the new pf-justice,
  incarceration runtime in pfm-prison, money on the ledger, budgets in pf-government.
- Wrote `docs/pf_ultimate/` (this folder): system plan with batches 15-22 and work units, architecture and contracts,
  database migrations, integration matrix, this tracker, test report, remaining work.
- No code changed by this step. Batch 14 is still being checked and integrated by the lead.

**Next steps at the time (done on 2026-11-04):**
1. Confirm batch 14 is committed and both suites are green; record the counts in `PF_TEST_REPORT.md` section 2.
2. Read `PF_REMAINING_WORK.md` "Open decisions"; apply any owner answers to the plan (they change 16C and 15B).
3. Run the ownership check (plan section 14) for batch 15.
4. Launch batch 15 units 15A-15I with prompts built from `AGENT_CONTEXT.md` + the unit section + the architecture.
5. After batch 15: update this tracker (statuses, notes), add a journal entry, then start batch 16.

### 2026-11-04: batch 15 built, checked and reworked (Foundations I)
- Batch 14 was committed and pushed first (qb `ff862ee`, pfscripts `e8ce836`; mocked 2496/0, real DB 644/0, JS green).
  The lead adopted the plan's default for every owner decision D1-D18 (`PF_REMAINING_WORK.md` section 2).
- Nine units ran in two waves (15A-15D, then 15E-15I), each followed by an adversarial checker that read the diff,
  wrote probes against the code and mutation-tested the new specs. Work stopped on 2026-11-03 at a usage limit
  (partial edits kept in the tree) and resumed on 2026-11-04 from the same agents.
- Rework rounds: 15B (an invoiced fine could be waived while its phone invoice stayed payable; then a queue so a
  settlement that arrives while the order is busy is never dropped) - 3 rounds; 15C (a `transferred` request could
  release a prisoner, a bail offer stayed payable after custody closed, a refund could be marked done unpaid; then
  remand-through-hospital and escape-forgiven edge cases) - 4 rounds; 15F (seeds re-inserted on hand-imported
  databases) - 1 fix. Follow-ups after a passed check: 15A (cap-merge key, atomic `UpdateInjury`, GCS cap and
  persisted hold `hold_until`, online-only activation, busy load), 15D (per-player drop cap, locale-free drawers,
  lab/court presence, civilian holder counts as a gap), 15E (grade mismatches in `Config.Departments.Implied`, keyed
  budget retry records the ledger key on pending rows, reconcile re-check time `next_check_at`, severe weather work
  orders at a district site), 15I (write exports fail closed without a `Callers` entry, `unchanged` stores the key,
  grants scoped to the owning department, `MaxShiftHours` enforced every minute, corrupt `players.job` reads as no
  job). All are in the code.
- Lead fixes: pf-justice `config.lua` caller lists (`GetBooking` added, `GetPropertyReceipt` narrowed) and
  `Config.Compat.LegacyRuntimes.policejob`; pf-emsmdt `Config.SOP.ForceSeed = false`; pf-citizen bills keep the
  `cancelled` outcome of `CancelInvoice` (server + `bills.js` label; real-DB spec fails without it); the
  `sweep_pol_policejob_spec` patch for the evidence forwarders.
- Result: all nine units passed. Latest full counts from the unit runs: mocked 2942 passed / 0 failed (272 files);
  real DB 806 passed / 0 failed at 15H's full run (81 files). The lead's final integration run is recorded in
  `PF_TEST_REPORT.md` (batch 15). Nothing is tested in game.
- Docs updated: this tracker, `PF_DATABASE_MIGRATIONS.md` (versions as built), `PF_ARCHITECTURE.md` section 12
  (contracts as built), `PF_TEST_REPORT.md` (batch 15 + in-game checklist), `PF_REMAINING_WORK.md`,
  `PF_INTEGRATION_MATRIX.md`, `PF_ULTIMATE_SYSTEM_PLAN.md`, `docs/IMPLEMENTATION_REPORT.md` (Batch 15 section).

**Resume here (next session):**
1. Lead: finish the batch-15 integration run (mocked, real DB, JS, parsecheck, `ledger_parallel`,
   `sql_install_check`), fill the placeholder in `PF_TEST_REPORT.md` and `IMPLEMENTATION_REPORT.md`, commit and push.
2. Batch 16 (Foundations II, the switch-over): 16A server-owned down/death state (uses `SetConsciousness` with a hold,
   `hold_until`), 16B damage ingestion, 16C pfm-prison driven by pf-justice, 16D MDT jail and police jail through
   pf-justice. Carry the batch-15 hand-over steps into the 16C/16D prompts (`PF_REMAINING_WORK.md` section 7).
3. Run the batch-15 in-game checks (`PF_TEST_REPORT.md` 5.10) on staging when a server with clients exists; batch 16's
   live checks matter more (MED-L4..L8, POL-L2..L3, CRT-L1..L2).
