# PF Ultimate: architecture and contracts

This is the blueprint for the police, EMS, medical, hospital, evidence, MDT, custody, prison, community service,
courts and department overhaul. An implementing agent takes **one work unit** from `PF_ULTIMATE_SYSTEM_PLAN.md`
and the contracts in this file and builds it without guessing.

- Written 2026-11-03 from the audits (`audit_police.md`, `audit_medical.md`, `audit_custody_integration.md`), the
  research notes and the lead's owner decisions. Every **existing** export, event or table named here was checked
  against the code on disk that day (batch-14 working tree). Line numbers drift, so re-grep before you edit.
- **New** interfaces are marked **(new)**. They do not exist yet; the unit named next to them builds them.
- Paths: `[qb]` = `/home/user/-qb-`, `[pfscripts]` = `/home/user/-pfscripts-` (the test harness resolves both).
- Short names: **AJ** `[pfscripts]/pf-ambulancejob`, **EMDT** `[pfscripts]/pf-emsmdt`, **PJ** `[qb]/pfm-policejob`,
  **PMDT** `[pfscripts]/pf-policemdt-DEV`, **PR** `[qb]/pfm-prison`, **JU** `[pfscripts]/pf-justice` (new resource),
  **GOV** `[pfscripts]/pf-government`.

Contents
1. Domain owners
2. Module layout per resource
3. Conventions every new interface follows
4. Contracts (medical, hospital, EMS equipment, justice, prison, evidence, police field and traffic, MDTs, government, platform hooks)
5. State machines
6. Security model
7. Sync model
8. Performance budget
9. Compatibility plan (legacy names)
10. Honest limits
11. Clinical and injury models (anatomy, injuries, physiology, effects, mechanisms, diagnosis, treatment, recovery)

---------------------------------------------------------------------------------------------------------------------

## 1. Domain owners

One owner per state. Nobody else writes it. Others read through the listed interface, never by reading the owner's
tables directly (house rule from `docs/DEVICES_AND_SERVICES.md`).

| State | Owner (resource / module) | Storage | Who may write | How others read |
|---|---|---|---|---|
| Patient clinical state: injuries, physiology, toxins, diagnosis layers, treatment log, recovery stage | AJ `server/medical/*` | `pf_med_*` tables + in-memory cache (write-behind) | AJ handlers only (ingest, exam, treatment, recovery, admin export) | exports `GetPatientSummary`, `GetMedicalRecord`, `GetRestrictions`; server events `pf-ambulancejob:server:*` |
| Down / dead state | AJ `server/medical/downstate.lua` | `pf_med_patients.consciousness`; metadata `isdead`/`inlaststand`; state bag `pf:down` | AJ only (clients only *ask*) | metadata (all existing readers keep working), state bag, export `IsDown` |
| Functional effects (limp, aim, drive, vision...) | AJ `server/medical/effects.lua` | derived, not stored | AJ | client event to the owner only |
| Hospital operations: check-in, triage, beds, admissions, discharge, transfers, pharmacy, lab, imaging, surgery, morgue, bills | AJ `server/hospital/*` | `pf_hosp_*` | AJ | exports (`GetAdmission`, `GetHospitalStatus`...) used by EMDT pages and JU |
| Medical documentation: PCR narrative, handover, EMS units board | EMDT | `pf_emsmdt_*` | EMDT (gated callbacks) | EMDT exports; PCR rows reference AJ treatment-log ids |
| EMS equipment runtime: stretchers, wheelchairs, medbags, patient-in-rig | AJ `server/ems/*` | memory + entity state bags; medbag/rig stock in inventory stashes | AJ | entity state bags (server-written) |
| Handcuffs | PJ `server/interactions.lua` (batch 14) | metadata `ishandcuffed`, state bag `handcuffed`, memory | PJ | `IsCuffed`, metadata (existing) |
| Detain, escort, vehicle placement, frisk, zipties | PJ `server/custody_field.lua` (new, batch 18) | memory + state bag `pf:escort` | PJ | state bag, export `GetFieldState` |
| Officer telemetry ("bodycam/dashcam" metadata timeline) | PJ `server/telemetry.lua` (new) | `pf_police_telemetry` | PJ (+ allowlisted `MarkTimeline` callers) | export `GetTimeline` |
| Physical evidence, chain of custody, lab | PJ `server/evidence/*` | `pf_evidence_*` + inventory item `info.evidenceId` | PJ (inventory moves are recorded automatically) | exports `GetEvidence`, `ListEvidence` |
| ALPR reads, speed events, breath tests, impound records | PJ `server/traffic.lua`, `server/vehicle.lua` | `pf_police_*` | PJ | exports `RunPlate`, `GetImpound` |
| Records: incidents, reports, cases, warrants, BOLOs, penal code, plate/citizen flags, notes, UoF/pursuit reports | PMDT | `pf_mdt_*` (created by migrations from batch 15) | PMDT gated callbacks; JU writes only warrant approval through `SetWarrantApproval` | PMDT exports (`GetPlateFlags`, `GetWarrant`...) |
| Custody: arrest-to-release record, booking, holding cell, property receipts | JU `server/custody.lua`, `booking.lua`, `property.lua` | `pf_justice_custody*`, `pf_justice_bookings`, `pf_justice_property*` | JU (callers on its allowlist) | exports `GetCustody`, `GetPropertyReceipt` |
| Orders of every kind (jail, prison, fine, citation, restitution, community service, probation, parole, remand) and their clocks | JU `server/orders.lua`, `clock.lua` | `pf_justice_orders`, `pf_justice_order_events` | JU | exports `GetOrders`, `IsIncarcerated`, `GetJailMinutes`; metadata mirrors `injail`, `criminalrecord` (written by JU only) |
| Bail | JU `server/bail.lua` | `pf_justice_bail` | JU | exports |
| Courts: cases, hearings, decisions, warrant reviews, release orders | JU `server/courts.lua`, `warrants.lua` | `pf_justice_cases`... | JU (judge, clerk, prosecutor roles) | exports |
| Supervision: probation/parole conditions, appointments, violations, monitors | JU `server/supervision.lua`, `monitors.lua` | `pf_justice_supervision*` | JU | exports |
| Community service runtime: shifts, tasks, attendance | JU `server/community_service.lua` | `pf_justice_cs_*` | JU | export `GetCommunityService` |
| Criminal record history, expungement | JU `server/records.lua` | `pf_justice_records` | JU (court / gov `records` permission) | export `GetRecord` |
| Incarceration runtime: intake, cells, classification, routines, headcount, work, commissary, inmate trust, visitation, discipline, security, escapes | PR | `pf_prison_*` | PR | exports `GetInmate`, `GetFacilityStatus`, `IsInside` |
| Municipal work orders | GOV `server/workorders.lua` (new) | `pf_gov_work_orders*` | GOV (generator, staff) + claimants through exports | exports `ListWorkOrders`, `ClaimWorkOrder`... |
| Department qualifications, shifts, training, assets, procurement, department audit | GOV `server/departments/*` (new) | `pf_gov_dept_*` | GOV (department managers in the app; listed resources through exports) | exports `HasQualification`, `GetShift`... |
| Ranks, hire, fire | pfm-management (existing) | `players.job` | pfm-management exports `HireEmployee`, `FireEmployee`, `SetEmployeeGrade`, `IsBoss`, `ListEmployees` | existing |
| Budgets, department society balances | GOV `server/budgets.lua` (existing) | `pf_gov_budget*` | GOV | existing exports |
| Money | pfm-banking ledger | `pf_transactions` | `exports['pfm-banking']:Transfer` / `PFPayout` only | ledger |
| Dispatch calls on the MDT boards | PMDT / EMDT dispatch (existing, memory), fed by pf-services requests | memory | MDT | existing `CreateDispatchCall` |
| Door states | pfm-doorlock | `Config.DoorList` + saves | doorlock; allowlisted servers through `SetDoorState` (new) | client events (existing) |
| Fleet vehicles and their service state | pf-jobgarages | `job_garage_vehicles` (+ new columns) | pf-jobgarages | new exports `GetFleetVehicle`, `ListFleet` |
| Supply orders and deliveries | pf-stores `PFOrders` + pf-trucking | pf-stores tables | pf-stores | existing exports, `RegisterBuyerKind` |

**Read rule for metadata.** `isdead`, `inlaststand`, `ishandcuffed`, `injail`, `criminalrecord` stay as the
compatibility surface that 20+ existing call sites read (`pfm-inventory`, `pfm-doorlock`, `pfm-vehiclekeys`,
`pfm-radialmenu`, `pfm-houses`, `pfm-phone`, `pfm-storerobbery`, `pfm-houserobbery`, PJ, PR, AJ). After batch 16
each of them is written by exactly one server owner (AJ for the first two, PJ for cuffs, JU for the last two), so
those readers become trustworthy without being edited.

---------------------------------------------------------------------------------------------------------------------

## 2. Module layout per resource

Only new or reshaped files are listed. "(bN)" is the batch that creates or reshapes the file.

### AJ `[pfscripts]/pf-ambulancejob`
```
config.lua                      legacy config (b16 trims death/revive keys, b17 moves hospital points out)
config_medical.lua        (b15) engine tunables: tick, thresholds, plausibility, privacy, callers
config_ems.lua            (b17) stretchers, wheelchairs, medbags, rig stock
config_hospital.lua       (b17) facilities, departments, beds, tariff, AI care, custody care
shared/medical/anatomy.lua        (b15) regions, structures, bone map, armour coverage
shared/medical/injuries.lua       (b15) injury catalog (types, subtypes, bleed, pain, effects, healing)
shared/medical/physiology_model.lua (b15) pure functions: derive vitals and consciousness from state
shared/medical/effects_model.lua  (b15) pure functions: combine injury effects per channel
shared/medical/mechanisms.lua     (b16) damage source -> injury rules (weapons, falls, vehicles, burns...)
shared/medical/findings.lua       (b17) exam modalities, signs per injury, sensitivity per tier
shared/medical/treatments.lua     (b17) treatment action catalog
server/medical/schema.lua         (b15) the resource's migrations (key 'pf-ambulancejob', v1 moved here)
server/medical/store.lua          (b15) load/save patients and injuries, cache, write-behind, offline catch-up
server/medical/engine.lua         (b15) tick, bleeding, physiology update, consciousness machine
server/medical/api.lua            (b15) exports and server events
server/medical/downstate.lua      (b16) the only writer of isdead/inlaststand/pf:down; revive tokens
server/medical/ingest.lua         (b16) damage hints + weaponDamageEvent + health sampler -> injuries
server/medical/legacy_import.lua  (b16) player_injuries -> pf_med_injuries (once)
server/medical/diagnosis.lua      (b17) findings, suspected/confirmed diagnoses
server/medical/exam.lua           (b17) exam actions per modality
server/medical/treatment.lua      (b17) treatment engine (replaces server/treatment.lua logic)
server/medical/recovery.lua       (b17) stage transitions, restrictions, offline progression
server/medical/effects.lua        (b15 computes the combined profile; b17 pushes it to the new client applier)
server/items.lua                  (b17) usable medical items (moved out of server/main.lua)
server/ems/equipment.lua          (b17) stretchers, wheelchairs, medbags, loading, entity safety
server/ems/fleet.lua              (b20) rig stock, restock, maintenance requests
server/hospital/facility.lua      (b17) hospitals, departments, zones, staffing counts
server/hospital/admissions.lua    (b17) check-in, triage, admit, discharge, transfer
server/hospital/beds.lua          (b17) bed occupancy (server), bed actions
server/hospital/billing.lua       (b17) itemised bills, payment, invoices for unpaid amounts
server/hospital/ai_care.lua       (b17) low-population care rules
server/hospital/custody.lua       (b19) infirmary, screening, escorted transfers with custody continuity
server/hospital/pharmacy.lua, lab.lua, imaging.lua, surgery.lua (b20)
server/hospital/morgue.lua        (b20) morgue, medical examiner, death records
server/hospital/supplies.lua      (b20) facility stock from pf-stores deliveries
client/medical_hints.lua          (b16) event-driven fall / vehicle / water hints (no per-frame loop)
client/effects.lua                (b17) applies the effect profile (only while a channel is non-zero)
client/exam.lua                   (b17) target options on a patient -> EMDT exam UI
client/ems_equipment.lua          (b17) stretcher/wheelchair visuals driven by entity state bags
client/hospital.lua               (b17) reception, bed and department interactions
client/morgue.lua                 (b20)
```
Retired: the client limb thread in `client/main.lua` and the bleed loop in `client/wounding.lua` (b16/b17),
`client/injury_handler.lua` (dead code, deleted b17), the stretcher in pfm-radialmenu (b17).

### EMDT `[pfscripts]/pf-emsmdt`
```
server/schema.lua      (b15) migrations key 'pf-emsmdt' (v1 from roster.lua moved here; ad-hoc tables -> v2)
server/pcr.lua         (b20) PCRs auto-charted from AJ treatment events + narrative + handover
server/units.lua       (b20) unit status, crew, rig assignment
server/hospital_app.lua(b21) pf-devices handlers for the hospital workstation (calls AJ exports)
html/exam.js, html/monitor.js, html/pcr.js (b21)
html/apps/hospital.js  (b21) hospital workstation as a pf-devices module app
```

### PJ `[qb]/pfm-policejob`
```
config_evidence.lua        (b15) evidence kinds, decay, integrity rules, lab timings
config_traffic.lua         (b18) radar, ALPR, speed cameras, breath tests, citations
config_equipment.lua       (b18) props caps, telemetry, K9, drones
server/schema.lua          (b15) migrations key 'pfm-policejob' (v1 from fines.lua moved here)
server/evidence/store.lua  (b15) evidence rows, tags, integrity
server/evidence/custody.lua(b15) custody events, inventory ItemMoved listener
server/evidence/scene.lua  (b15) persisted scene drops (blood, casings, prints), decay
server/evidence/api.lua    (b15) exports and server events
server/evidence/lab.lua    (b18) lab queue, reference profiles, matching
server/evidence.lua        (b15 reshaped) legacy net events -> the evidence module
server/custody_field.lua   (b18) surrender, detain, frisk, zipties, escort, vehicle placement, arrest handoff
server/traffic.lua         (b18) radar, ALPR, speed cameras, breathalyzer, plate checks, citations
server/telemetry.lua       (b18) officer telemetry timeline
server/armory.lua          (b20) equipment checkout against the GOV asset register
client/custody_field.lua, client/traffic.lua (b18)
```

### PMDT `[pfscripts]/pf-policemdt-DEV`
```
server/schema.lua        (b15) migrations key = resource name (v1-v6 moved from sentencing.lua; v7 SQL-file tables)
server/sql_init.lua      deleted in b15 (never loaded; not in fxmanifest)
server/cases.lua         (b18) cases and investigations
server/records_ext.lua   (b18) warrants v2, BOLO board, plate-flag export, record audit, UoF/pursuit reports
server/personnel_ext.lua (b20) IA complaints, reviews, qualification view
client/pages_ext.lua     (b21) NUI relays for the new pages
html/pages/*.js          (b21) new pages, each self-registering with the router
```

### JU `[pfscripts]/pf-justice` (new resource)
```
fxmanifest.lua, config.lua
shared/states.lua            (b15) state machines as data + transition checker (pure, tested)
shared/cs_tasks.lua          (b19) community-service task kinds
server/main.lua              (b15) core object, helpers, caller allowlist, actor resolution, audit writer
server/schema.lua            (b15) migrations key 'pf-justice'
server/orders.lua            (b15) orders of every kind
server/clock.lua             (b15) the one sentence clock (presence providers, policies, credits)
server/records.lua           (b15) criminal record, expungement (audited)
server/api.lua               (b15) exports
server/custody.lua           (b15) custody records, holding cells, transfers
server/booking.lua           (b15) booking number, identity capture, medical screening link
server/property.lua          (b15) seizure into lockers, receipts, return, forfeiture
server/bail.lua              (b15) bail offers, payment, exoneration, forfeiture
server/legacy_import.lua     (b15) pf_mdt_active_jails and offline injail -> orders (once)
server/compat.lua            (b15) metadata mirrors (injail, criminalrecord)
server/courts.lua, server/warrants.lua       (b19)
server/supervision.lua, server/monitors.lua  (b19)
server/community_service.lua                 (b19)
server/apps.lua              (b21) pf-devices handlers (Court app, Community Service app, records portal)
client/main.lua, client/community_service.lua (b19)
html/apps/court.js, cs.js, records.js, justice.css (b21)
```

### PR `[qb]/pfm-prison`
```
server/schema.lua         (b16) migrations key 'pfm-prison' (first time this resource has tables)
server/justice_bridge.lua (b16) listens to pf-justice orders, admits/releases, IsInside provider
server/facility.lua, schedule.lua, discipline.lua, visitation.lua (b19)
server/work.lua, economy.lua    (b19) prison jobs, trust accounts, commissary, restitution
server/security.lua             (b19) doors, cameras, alarms, zones, contraband, searches, lockdowns, escapes
server/supplies.lua             (b20) kitchen/laundry/commissary stock via pf-stores
server/apps.lua                 (b21) Corrections MDT handlers
config_facility.lua, config_work.lua (b19)
html/apps/corrections.js, corrections.css (b21)
```
`fxmanifest.lua` gains `'@oxmysql/lib/MySQL.lua'` in b16 (it has none today).

### GOV `[pfscripts]/pf-government`
```
server/workorders.lua            (b15) work orders, claims, unit proofs, district effects
server/departments/core.lua      (b15) department of a job, config, audit writer
server/departments/qualifications.lua (b15)
server/departments/shifts.lua    (b15) shift rows from QBCore:Server:SetDuty
server/departments/training.lua, assets.lua, payroll.lua (b20)
server/departments/procurement.lua (b20) the 'facility' buyer kind for pf-stores
server/apps/department.lua       (b20) department admin app handlers
html/apps/department.js          (b21)
```

---------------------------------------------------------------------------------------------------------------------

## 3. Conventions every new interface follows

### 3.1 Result shape
New exports and RPC handlers return **one table**:
```lua
{ ok = true, ... }                                              -- success, named fields
{ ok = false, error = 'code', message = 'Short text for a notify' }
{ ok = true, duplicate = true, ... }                            -- the same idempotency key was seen; first result returned
```
Legacy exports keep their legacy shape (`ok, err` for pfm-prison, `id | nil, err` for pfm-phone).

### 3.2 Error codes (use these; add new ones only when none fits)
| Code | Meaning |
|---|---|
| `bad_args` | argument missing, wrong type, out of range, too long |
| `not_allowed` | the invoking resource is not on the caller allowlist |
| `no_permission` | the player lacks the job, grade, duty, qualification or court role |
| `not_on_duty` | the job is right but the player is off duty |
| `too_far` | a server-position distance check failed |
| `not_found` | the entity does not exist (or is not visible to this viewer) |
| `invalid_state` | the state machine refuses the transition (`message` names the current state) |
| `conflict` | another active record blocks this one (e.g. a second open custody) |
| `busy` | a per-entity lock is held; retry later with the same key |
| `rate_limited` | the actor exceeded the action's rate |
| `key_reused` | an idempotency key was reused with different arguments |
| `db_unavailable` | migrations not applied or a query failed; nothing was changed |
| `bank_unavailable` | pfm-banking is not started; nothing was charged |
| `payment_unclear` | the ledger outcome is unknown; the record is held as `payment_pending` and settled later |
| `insufficient_funds` | a clear ledger refusal |
| `offline` | the action needs the target online |

### 3.3 Idempotency keys
- Every mutating export that a caller could retry takes `opts.key` (string, 1..128 chars, `[%w%-_:%.]` only).
- The callee stores the key in a `UNIQUE` column of the row it creates (`idem_key`). A repeat with the same key and the
  same arguments returns the first result with `duplicate = true`. A repeat with different arguments returns
  `key_reused`.
- Key formats used across resources (callers build them from their own stable ids):

| Purpose | Key |
|---|---|
| MDT sentence -> order | `pf-policemdt:sentence:<sentenceId>:<kind>` |
| Field jail (PJ) -> order | `pfm-policejob:jail:<custodyId>` |
| Citation | `pfm-policejob:citation:<citationUid>` |
| Order payment attempt | `pf-justice:order:<orderId>:pay:<attempt>` (ledger key; numbered attempts per the ledger rule) |
| Bail payment | `pf-justice:bail:<bailId>:<attempt>` |
| Bail refund (exoneration) | `pf-justice:bail:<bailId>:refund` |
| Restitution payment | `pf-justice:restitution:<orderId>:<n>` |
| Prison time credit | `pfm-prison:credit:<orderId>:<workTicketId>` |
| Prison trust movement | `pfm-prison:trust:<cid>:<txId>` |
| Hospital bill charge | `pf-ambulancejob:bill:<billId>:<attempt>` |
| Hospital unpaid invoice | ref `pf-ambulancejob:bill:<billId>` (pfm-phone `ref`, new) |
| Work-order unit proof | `pf-justice:cs:<taskId>` or `pf-government:wo:<claimId>:<unit>` |
| Paid work-order payout | `pf-government:wo:<workOrderId>:pay:<cid>` |
| Evidence from surgery | `pf-ambulancejob:projectile:<injuryId>` |
| Evidence from prison search | `pfm-prison:contraband:<searchId>:<n>` |
| Department spend | `pf-government:dept:<dept>:<purpose>:<id>` (new optional `key` argument, batch 15) |

- Ledger rule (from the batch-14 brief, binding): a failed key stays failed, so a retry uses a **new numbered** key;
  an **unclear** ledger result is never treated as failed: hold the record as `payment_pending`, look it up later
  with `exports['pfm-banking']:GetTransaction(key)` and never charge again under a new key until it settles.

### 3.4 Caller allowlists
Every export that writes, or reads private data, checks `GetInvokingResource()` against a per-export list in the
owner's config:
```lua
Config.Callers = {
    CreateOrder = { ['pf-policemdt-DEV'] = true, ['pfm-policejob'] = true, ['pfm-adminmenu'] = true },
    GetRecord   = '*',   -- open read; the result is filtered by Config.RecordFields[invoker]
}
```
`nil` invoker (the owner itself) always passes. An unknown invoker gets `not_allowed` and one console line per
minute per resource. This copies the working pattern of `Config.JailResourceAllowlist` in pfm-prison.

### 3.5 Actor
Callers pass who acts in `opts.actor`:
```lua
opts.actor = { src = 12 }                                   -- a player: the callee re-reads job, grade, duty, position
opts.actor = { kind = 'system', label = 'pfm-prison work' } -- a server process
opts.actor = { kind = 'admin', src = 3 }                    -- callee checks the ACE itself
```
The callee never trusts a job, grade, name or position from `opts.actor`; with `src` it reads them from
`exports['pfm-core']:GetPlayer(src)` and `GetEntityCoords(GetPlayerPed(src))`.

### 3.6 Validation helpers (copy, do not import across resources)
- Integers: `math.tointeger(tonumber(v))` with explicit min/max; reject NaN/inf (`v ~= v`, `v == math.huge`).
- Strings: strip control characters, trim, clip to the column length; reject when empty after trim.
- Server ids: `tonumber(id)` then `GetPlayerPed(id) ~= 0`.
- Callables from other resources: never `type(x) == 'function'`; use a callable check (funcrefs are tables).
- After any mutating call on a player object (`SetMetaData`, `AddMoney`, `RemoveItem`), read the player again before
  using `PlayerData` (the harness emulates FiveM's snapshot boundary).
- If a check and the write it guards are separated by a DB wait, take the per-entity lock **before** the first wait.

### 3.7 Time
- Logic clocks are unix seconds from `os.time()`, stored as `BIGINT` (`*_at`). Display timestamps use
  `TIMESTAMP DEFAULT CURRENT_TIMESTAMP`. Never store "remaining seconds counted down by a client".
- Monotonic durations inside one server session use `GetGameTimer()`.

### 3.8 Audit
Every mutating action writes one row in the owner's events table (`pf_med_events`, `pf_justice_order_events`,
`pf_justice_custody_log`, `pf_evidence_custody`, `pf_prison_events`, `pf_gov_dept_audit`, `pf_mdt_record_audit`):
`(entity, entity_id, action, actor_cid, actor_src, actor_job, detail JSON <= 4 KB, at)`. Retention is a config value
per table (default 180 days), swept daily in batches of 500.

### 3.9 Lua compatibility (FiveM is 5.4, the harness is fengari 5.3)
- No `<const>` / `<close>` attributes. No integer-for-loop assumptions that differ between 5.3 and 5.4.
- `?.`, `+=`-style compound assignment and backtick hashes are rewritten by the harness preprocessor; keep each on
  one line (the rewrite is line-based).
- `CreateThread` and `SetTimeout` do nothing in the mocked harness: put every tick body in a named function
  (`PFMed.Engine.Tick(now)`) that specs call directly.

### 3.10 Names
- Net events (client -> server): `<resource>:server:<PascalAction>`, registered with `RegisterNetEvent`.
- Server-only events (between resources): `<resource>:server:<camelEvent>`, registered with `AddEventHandler` only
  (never `RegisterNetEvent`), like the existing `pfm-phone:server:invoiceSettled`.
- Client events: `<resource>:client:<PascalAction>`.
- Callbacks: `<resource>:server:<camelAction>` through `QBCore.Functions.CreateCallback`.
- pf-devices RPC methods: `camelCase` inside the app's handler map.
- State bags: `pf:<name>`; written by the server only (`tests/specs/statebag_strict_scan_spec.lua` fails on a new
  client write).

---------------------------------------------------------------------------------------------------------------------

## 4. Contracts

### 4.1 Medical engine (AJ, batches 15-17)

#### Exports (new)
| Export | Args | Returns | Callers (allowlist) | Notes |
|---|---|---|---|---|
| `GetPatientSummary(who)` | `who`: server id or citizenid | `{ ok, cid, online, consciousness, down, stage, bleeding, triage, vitals = { hr, sbp, dbp, rr, spo2, temp, gcs, pain }, restrictions = {...}, updatedAt }` | `pf-emsmdt`, `pf-justice`, `pfm-prison`, `pf-policemdt-DEV` | Fields filtered by `Config.Medical.SummaryFields[invoker]`: non-medical callers get only `down`, `consciousness`, `stage`, `restrictions` |
| `IsDown(who)` | id or cid | `down:boolean, state:string` | open | Mirrors `pf:down`; cheap (memory) |
| `ApplyInjury(who, spec, opts)` | `spec = { mechanism, type, subtype?, region?, structure?, severity 1..5, attrs?, note? }`, `opts = { key, actor }` | `{ ok, injuryId, duplicate? }` | `pfm-prison` (fence, fights), `pfm-adminmenu`, `pf-jobs` (work accidents) | Server-attested injuries that have no damage event |
| `AddToxin(who, toxin, amount, opts)` | `toxin` in `ethanol, opioid, stimulant, sedative, cannabis, poison, carbon_monoxide, food_poisoning`; amount in the toxin's unit (`Config.Medical.Toxins`) | `{ ok }` | `pfm-drugs`, `pf-restaurants`, `pfm-adminmenu` | Alcohol and food come from the pfm-smallresources event instead (4.11) |
| `Revive(who, opts)` | `opts = { mode = 'admin' \| 'script', by = src?, reason, key, keepInjuries = false }` | `{ ok }` | `pfm-adminmenu`, `txAdmin` path (internal) | Medical revives go through treatments, never this export |
| `Kill(who, opts)` | `opts = { by, reason }` | `{ ok }` | `pfm-adminmenu` | Replaces `hospital:client:KillPlayer` from adminmenu |
| `GetMedicalRecord(cid, opts)` | `opts = { viewer = src, purpose = 'treatment' \| 'self' \| 'court_order', courtOrderId? }` | `{ ok, record = { injuries[<=200], treatments[<=200], admissions[<=50], diagnoses (confirmed only), prescriptions, deathRecords } }` | `pf-emsmdt`, `pf-justice`, `pf-policemdt-DEV` | Privacy: see 6.6 |
| `GetRestrictions(who)` | id or cid | `{ ok, list = { { kind, until, reason } } }` | open | e.g. `no_sprint`, `no_drive`, `crutches`, `cast_arm_l`, `concussion` |
| `IsInCare(who)` | id or cid | `inCare:boolean, admissionId?` | open | Used by JU custody continuity |
| `SetCustodyCare(cid, custodyRef, opts)` | `custodyRef = { custodyId?, orderId?, facility }` or `nil` to clear | `{ ok }` | `pf-justice`, `pfm-prison` | (b19) marks a patient as in custody: escort required, discharge returns them |

Batches: `GetPatientSummary`, `IsDown`, `ApplyInjury`, `AddToxin` (15A); `Revive`, `Kill` (16A); `GetMedicalRecord`
(17A); `GetRestrictions` (17C); `IsInCare` (17E); `SetCustodyCare` (19G). Each module registers its own exports in its
own file; `server/medical/api.lua` holds the 15A/16A ones.

#### Server-only events AJ emits (new; `AddEventHandler` only)
| Event | Args | Consumers |
|---|---|---|
| `pf-ambulancejob:server:consciousnessChanged` | `src?, cid, from, to, cause` | JU (custody medical alerts), PR |
| `pf-ambulancejob:server:patientDown` | `src, cid, state, cause = { mechanism, weapon?, attackerCid? }` | AJ EMS requests, PJ telemetry, PMDT dispatch (through pf-services as today) |
| `pf-ambulancejob:server:patientRevived` | `src, cid, by = { cid?, kind }, mode` | PJ (uncuff policy), JU |
| `pf-ambulancejob:server:respawned` | `src, cid, hospitalId` | PJ (replaces its listener on the net event `hospital:server:RespawnAtHospital`), JU (custody at hospital) |
| `pf-ambulancejob:server:patientDied` | `src?, cid, cause` | AJ morgue (b20), PMDT case link |
| `pf-ambulancejob:server:injuryAdded` | `cid, injury = { id, type, subtype, region, structure, severity, mechanism, attrs }` | EMDT PCR (b20) |
| `pf-ambulancejob:server:treatmentApplied` | `cid, t = { id, action, byCid, at, injuryId? }` | EMDT PCR auto-charting (b20) |
| `pf-ambulancejob:server:projectileRecovered` | `cid, p = { injuryId, caliber, weaponHash, attackerCid?, weaponSerial?, byCid, at }` | PJ evidence (b18): creates a `projectile` evidence item with key `pf-ambulancejob:projectile:<injuryId>` |
| `pf-ambulancejob:server:admissionChanged` | `admission, from, to` | JU custody, EMDT |
| `pf-ambulancejob:server:deathRecorded` | `record = { id, cid, cause, manner, at, examiner? }` | PMDT cases, JU |

#### Net events (client -> server, new)
| Event | Payload | Checks | Rate |
|---|---|---|---|
| `pf-ambulancejob:server:ReportDown` | `{ nonce <= 32 chars, kind = 'dead' \| 'laststand', hint = { weapon?, bone?, attacker? } }` | Accepted only if the server reads `GetEntityHealth(ped) <= Config.Medical.DownHealth` at arrival, or the engine already says unconscious/arrest | 1 / 2 s |
| `pf-ambulancejob:server:ReviveApplied` | `token` | Token issued by the server for this src, unexpired (20 s); server re-reads health > down threshold 1.5 s later | 1 / s |
| `pf-ambulancejob:server:DamageHint` | `{ seq, weapon, bone, hpBefore, hpAfter, armourBefore, armourAfter, attacker?, fall = { vz }?, vehicle = { speedBefore, speedAfter, seatbelt }?, water?, fire? }` (<= 256 bytes JSON) | 6.4 plausibility | 10 / s, burst 20 |
| `pf-ambulancejob:server:RequestHelp` | none | down state from the server; opens/announces the existing `PFEmsRequests` request | 1 / 60 s |
| `pf-ambulancejob:server:RequestRespawn` | `hospitalId?` | server down state `dead` and `now >= canRespawnAt` | 1 / 5 s |

#### Client events (server -> client, new)
| Event | Args | Meaning |
|---|---|---|
| `pf-ambulancejob:client:SetDown` | `state, info = { since, canRespawnAt, cause }` | Play the down/dead state; the client resurrects locally only after this |
| `pf-ambulancejob:client:Revive` | `token, mode, opts = { health }` | Resurrect and answer `ReviveApplied(token)` |
| `pf-ambulancejob:client:Effects` | `profile, version` | Functional effects (11.4); only sent on change |
| `pf-ambulancejob:client:Symptoms` | `list` | The patient's own symptoms panel (no hidden truth) |
| `pf-ambulancejob:client:Monitor` | `patientSrc, vitals, rhythm` | Only to the medic attached to that patient's monitor, every 5 s while attached |

#### State bags (server-written)
| Bag | Values | Replicated | Why |
|---|---|---|---|
| `Player(src).state['pf:down']` | `false`, `'unconscious'`, `'arrest'`, `'dead'` | yes | Other clients pick carry/escort/drag animations and target options |
| Entity `pf:stretcher` | `{ patient = src \| false, pusher = src \| false, folded, rig = netId \| false }` | yes | Late joiners see the right attachment |
| `Player(src).state['pf:onStretcher']` | `netId \| false` | yes | |

#### Internal Lua API between AJ modules (same resource, globals)
```lua
PFMed.Store.Get(cid)                  -> patient (cached, loads if needed)
PFMed.Store.MarkDirty(cid)
PFMed.Engine.AddInjury(cid, spec, ctx) -> injury            -- ctx = { actor, key, source = 'ingest'|'export'|'treatment' }
PFMed.Engine.UpdateInjury(cid, injuryId, patch, ctx)
PFMed.Engine.Tick(now)                                       -- one pass over active patients
PFMed.Engine.OnConsciousness(fn(cid, from, to, cause))       -- downstate subscribes
PFMed.Engine.Activate(cid) / Deactivate(cid)                 -- add/remove from the active set
PFMed.Down.Set(src, state, cause) / PFMed.Down.IssueReviveToken(src, mode) -- b16
PFMed.Effects.Profile(cid) -> profile                       -- b15: from injuries + physiology
PFMed.Effects.Push(src)                                      -- b17: sends the profile to client/effects.lua on change
```

### 4.2 Diagnosis and exam (AJ b17; UI in EMDT b21)
- Callback `pf-ambulancejob:server:exam(target, modality)` -> `{ ok, findings = { { id, region, structure?, sign, certainty = 'observed'|'suspected'|'confirmed', modality, at } }, vitals? }`.
  - `modality` in `look, palpate, auscultate, pupils, pulse, bp_cuff, spo2_probe, ecg, glucose, temperature, pain_scale, fast_us, xray, ct, labs`.
  - Requirements per modality (`shared/medical/findings.lua`): minimum tier (11.6), equipment item held or rig within
    10 m, location (imaging needs the patient in a bed inside an imaging zone), duration, distance 2.5 m (field) or
    same room.
  - Results are written to `pf_med_findings`; the same exam within 60 s returns the stored result (no re-roll).
- Callback `pf-ambulancejob:server:setDiagnosis(target, { structure, injuryType, status = 'suspected' | 'ruled_out', note })`
  by a tier >= 2 provider. `confirmed` is set only by imaging, labs or surgery.
- Callback `pf-ambulancejob:server:getChart(target)` -> what this provider may see: findings, diagnoses, treatment log,
  vitals history (24 h), never `pf_med_injuries` rows directly.

### 4.3 Treatment (AJ b17)
- Callback `pf-ambulancejob:server:treat({ target, action, injuryId?, slot?, params?, req })` ->
  `{ ok, result = { changed = { ... }, message } }`.
- Validation order (stop at first failure): rate limit -> target online and ped exists -> distance (2.5 m field, rig
  within 6 m for rig actions, zone for hospital actions) -> provider on duty in an EMS/medical job or civilian action
  allowed -> tier/qualification (`exports['pf-government']:HasQualification`, implied by grade until certifications
  are granted) -> action preconditions on server state (e.g. `needle_decompression` needs a tension pneumothorax
  *finding* `suspected` or `confirmed`) -> lock patient -> **consume items on the server** (`RemoveItem` must return
  true) -> apply effects -> log treatment -> unlock -> push effects/vitals.
- `req` is a client nonce; a repeat `(src, req)` within 30 s returns the first result.
- Continuous actions: CPR is `pf-ambulancejob:server:cprTick(target)` every 5 s while the provider stays within 1.5 m
  and does not move more than 1 m between ticks; the engine pauses the arrest-to-death timer while ticks arrive.
- Legacy forwarders: `pf-ambulancejob:server:applyTreatment(targetId, treatmentType)` maps
  `bandage -> pressure_dressing`, `splint -> splint`, `burn_dressing -> burn_dressing`, `oxygen -> oxygen` and calls
  the same pipeline. `hospital:server:TreatWounds(playerId)` maps to `basic_wound_care`.

### 4.4 Recovery and restrictions (AJ b17)
- No new exports beyond `GetRestrictions`. Internal: `PFMed.Recovery.Advance(cid, now)` runs on load (offline catch-up)
  and every 60 s for online patients with a non-healthy stage.
- Restrictions are pushed with the effect profile and enforced by the client applier; the server checks what it can
  see. Example: `no_drive` -> the client refuses the driver seat, and the 1 Hz sampler logs a violation when it sees
  `GetPedInVehicleSeat(veh, -1) == ped` (vehicle-enter events such as `baseevents` are client-originated, so they are
  not used). Violations are logged, not punished automatically.

### 4.5 Hospital operations (AJ b17, b19, b20)
| Interface | Shape | Notes |
|---|---|---|
| callback `pf-ambulancejob:server:checkIn(hospitalId)` | `{ ok, admissionId, mode = 'staff' \| 'ai', etaSeconds }` | Player must stand in the hospital's reception zone (server position). `mode` from 4.5.2 |
| callback `pf-ambulancejob:server:triage(target, level)` | `level` in `red, orange, yellow, green, blue` (ESI 1-5) | tier >= 4 (nurse) or tier 3 in the ED zone |
| callback `pf-ambulancejob:server:admit(admissionId, dept, bedId?)` | `{ ok, bedId }` | Bed must be free on the server |
| callback `pf-ambulancejob:server:discharge(admissionId, orders)` | `orders = { restrictions, followUpAt?, prescriptions? }` | Creates restrictions and follow-up calendar entry (`pf-citizen` `AddCalendarEvent`) |
| callback `pf-ambulancejob:server:transfer(admissionId, to)` | `to = { hospitalId }` or `{ facility = 'bolingbroke' }` | Custody patients need an escort (b19) |
| export `GetAdmission(who)` (new) | `{ ok, admission? }` | callers: EMDT, JU, PR |
| export `ListAdmissions(hospitalId, filter)` (new) | `{ ok, list }` | caller: EMDT |
| export `AdmitPatient(cid, spec, opts)` (new) | `spec = { hospitalId, dept, reason, custodyRef? }`, `opts = { key, actor }` | callers: JU, PR (infirmary transfer) |
| export `DischargePatient(admissionId, opts)` (new) | `{ ok }` | callers: JU (court order), EMDT |
| export `GetHospitalStatus(hospitalId)` (new) | `{ ok, beds = { [dept] = { total, free } }, staffOnDuty, aiActive }` | callers: EMDT dashboard, JU |

#### 4.5.1 Billing
- A bill is built from server records only: treatment log lines, bed hours, procedures, drugs dispensed, priced by
  `Config.Hospital.Tariff`. Rows: `pf_hosp_bills` + `pf_hosp_bill_lines`.
- Payment: `PFPayout.Charge(cid, { 'bank' }, total, { key = 'pf-ambulancejob:bill:<billId>:<attempt>', to = 'society:ambulance', kind = 'medical', reason })`.
  This replaces today's charge-to-sink-then-mint (`ChargeHospitalBill`: `PFPayout.Charge` then `PFPayout.PaySociety`).
- Clear refusal (no funds): a pfm-phone invoice for the open amount, `CreateInvoice({ citizenid, amount, society = 'ambulance', sender = <hospital label>, candecline = 0, reason, ref = 'pf-ambulancejob:bill:<billId>' })`
  (the `ref` field is new, batch 15H). The bill becomes `invoiced`; AJ listens to the existing server event
  `pfm-phone:server:invoiceSettled(invoice, 'paid')` and marks it paid.
- Unclear: `payment_pending`; a 120 s sweep checks `GetTransaction(key)`.
- Insurance: no insurance system exists in either repo. `Config.Hospital.Coverage` supports a flat discount per
  job type (e.g. on-duty government employees) only. A real insurer is an open decision (`PF_REMAINING_WORK.md`).

#### 4.5.2 AI care at low population (keeps EMS relevant)
- `mode = 'ai'` only when `exports['pfm-core']`-side duty count of EMS/medical staff (`QBCore.Functions.GetDutyCount('ambulance')`)
  is below `Config.Hospital.AI.MinStaff` **and** no player provider accepted the patient's request within
  `Config.Hospital.AI.WaitSeconds` (default 180).
- AI care stabilises and treats non-surgical injuries at `TimeMultiplier` x2 and `PriceMultiplier` x1.5, never
  revives an arrest faster than the respawn rule, and leaves injuries in stage `stabilized` with restrictions.
- Surgery-required injuries wait for a player surgeon while one is on duty; with none on duty for
  `Config.Hospital.AI.SurgeryWaitSeconds` (default 900) the AI performs it with a complication chance.

### 4.6 EMS equipment (AJ b17)
- Net event `pf-ambulancejob:server:Equipment(action, args)`; `action` in
  `spawn_stretcher, place_patient, take_patient, push, release, load, unload, fold, return, spawn_wheelchair, seat, unseat, place_medbag, pickup_medbag`.
- Server spawns every prop (`CreateObjectNoOffset` server-side as PJ spikes do since batch 14), owns the attach
  state, and uses the RPC natives available on the server (`SetPedIntoVehicle`, `SetEntityCoords`,
  `FreezeEntityPosition`) for loading and safety. Distances: stretcher within 2.5 m of the patient; rig rear within
  4 m for load/unload; one stretcher per rig (`Config.EMS.Stretchers.PerRig`).
- Safety: `playerDropped` of the patient or pusher, `entityRemoved` of the stretcher or rig, and resource stop all
  release the patient at the last server position, clear `pf:onStretcher` and delete orphan props.
- Medbag: a placed medbag is a stash `pf_medbag_<id>`; a rig's stock is stash `pf_rig_<plate>` (b20 restock).

### 4.7 pf-justice (JU, batches 15 and 19)

#### 4.7.1 Orders
`CreateOrder(spec, opts)` (new) -> `{ ok, orderId, state, existing? }`
```lua
spec = {
  cid = 'ABC12345',                         -- required
  kind = 'jail' | 'prison' | 'fine' | 'citation' | 'restitution' | 'community_service'
       | 'probation' | 'parole' | 'remand',
  minutes = 30,                              -- jail / prison: required time (1..Config.MaxMinutes)
  amount = 1500,                             -- fine / citation / restitution
  units = 10,                                -- community service work units
  days = 14,                                 -- probation / parole duration (real days)
  victimCid = 'XYZ',                         -- restitution
  conditions = { ... },                      -- probation / parole / bail (4.7.6)
  facility = 'bolingbroke' | 'mrpd_holding' | ...,  -- jail / prison / remand (Config.Facilities)
  clock = 'online' | 'hybrid' | 'realtime',  -- default per kind (Config.Clock)
  charges = { { code = 'P-101', label, count } }, -- copied for the record (penal code stays in PMDT)
  sourceRef = { type = 'mdt_sentence' | 'court_decision' | 'citation' | 'field' | 'admin' | 'legacy', id = '...' },
  custodyId = 42,                            -- links the order to a custody record when one exists
  merge = 'concurrent' | 'consecutive',      -- a second incarceration order while one is active (default concurrent)
  dueAt = 1762300000,                        -- fines: due date; CS: deadline
}
opts = { key = 'pf-policemdt:sentence:991:prison', actor = { src = 7 } }
```
Callers: `pf-policemdt-DEV`, `pfm-policejob`, `pfm-prison` (legacy `JailPlayer` forwarder), `pfm-adminmenu`, JU itself.

| Export (new) | Args | Returns | Callers |
|---|---|---|---|
| `GetOrder(orderId)` | | `{ ok, order }` | open (field filter) |
| `GetOrders(cid, filter)` | `filter = { kinds?, states?, limit <= 100 }` | `{ ok, list }` | open (field filter) |
| `GetActiveIncarceration(who)` | id or cid | `{ ok, order?, remainingSeconds, facility }` | open |
| `IsIncarcerated(who)` | id or cid | `bool, orderId?, facility?` | open (memory) |
| `GetJailMinutes(who)` | id or cid | `integer` (ceil of remaining) | open; backs pfm-prison `GetJailTime` |
| `AdjustOrder(orderId, change, opts)` | `change = { kind = 'credit' \| 'forfeit' \| 'modify' \| 'suspend' \| 'resume', seconds?, units?, amount?, reason }` | `{ ok, order }` | `pfm-prison` (credit/forfeit only, capped by `Config.Credits`), `pfm-adminmenu`, JU courts |
| `SetOrderState(orderId, to, opts)` | `to` in `completed, vacated, revoked, waived` | `{ ok, order }` | `pfm-prison` (release by escape is **not** a completion: it suspends), JU courts, `pfm-adminmenu` |
| `ReleaseNow(who, reason, opts)` | ends active incarceration orders (`vacated` with reason) | `{ ok, released = n }` | `pfm-policejob` (`/unjail`), `pfm-adminmenu`, `pfm-prison` legacy forwarder |
| `IssueCitation(spec, opts)` | `spec = { cid, amount, violation, location = {x,y,z}, plate?, speed?, limit?, officerSrc, contestDays? }` | `{ ok, orderId, citationId }` | `pfm-policejob`, `pf-policemdt-DEV` |
| `PayOrder(orderId, opts)` | `opts = { payerSrc, account = 'bank' \| 'cash', key }` | `{ ok, state }` | `pf-policemdt-DEV`, `pf-government` (city hall desk), JU app |
| `GetRecord(cid, opts)` | `opts = { viewer = src? }` | `{ ok, entries }` | open, filtered by `Config.RecordFields[invoker]` |
| `AddRecordEntry(cid, entry, opts)` | `entry = { kind = 'conviction' \| 'arrest' \| 'citation' \| 'note', ref, summary }` | `{ ok, entryId }` | JU internal, `pf-policemdt-DEV` |
| `Expunge(cid, entryIds, opts)` | `opts = { actor, courtOrderId? }` | `{ ok, n }` | JU courts, `pf-government` (perm `records`); replaces GOV's unaudited hard delete of `pf_mdt_sentences`/`pf_mdt_incidents` |

Server-only events JU emits (new): `pf-justice:server:orderCreated(order)`, `pf-justice:server:orderChanged(order, change)`,
`pf-justice:server:releaseOrdered(cid, orderId, reason)`, `pf-justice:server:paymentSettled(order, state)`.

#### 4.7.2 The clock (one owner)
- Fields on each incarceration order: `required_seconds`, `served_seconds`, `credit_seconds`, `forfeit_seconds`,
  `last_tick_at`, `release_at` (realtime/hybrid only). Remaining = `required - served - credit + forfeit`.
- Tick every `Config.Clock.TickSeconds` (15). For each active incarceration order of an **online** player the clock
  asks the facility's presence provider:
  ```lua
  Config.Facilities.bolingbroke = { label = 'Bolingbroke Penitentiary', presence = { resource = 'pfm-prison', export = 'IsInside' },
                                    fallback = { center = vector3(1693.33, 2569.51, 45.56), radius = 200.0 } }
  Config.Facilities.mrpd_holding = { label = 'Mission Row holding', presence = { resource = 'pf-justice', export = 'IsInHoldingCell' } }
  ```
  Inside -> `served += dt`. In hospital custody (`IsInCare` true and `custody_ref` matches) -> counts as inside.
  When the provider resource is not started, the fallback radius is used, so the clock never stops for that reason.
- Offline: `online` counts nothing; `hybrid` counts `OfflineRate` (default 0.25) of wall time at the next load;
  `realtime` counts all. Policies per kind in `Config.Clock.Policy`.
- At remaining <= 0 the order becomes `completed`, `releaseOrdered` fires, property comes back (4.7.5) and the
  `injail` mirror goes to 0. An offline completion finishes at the next load.

#### 4.7.3 Custody
| Export (new) | Args | Returns | Callers |
|---|---|---|---|
| `OpenCustody(target, opts)` | `target` = server id; `opts = { reason, charges?, incidentId?, key, actor = { src } }` | `{ ok, custodyId, existing? }` | `pfm-policejob`, `pf-policemdt-DEV` |
| `GetCustody(who)` | id or cid | `{ ok, custody? = { id, state, facility, cellId, since, bookingNo, holdUntil, officerCid } }` | open |
| `SetCustodyState(custodyId, to, opts)` | 5.4 transitions | `{ ok, custody }` | `pfm-policejob`, `pf-policemdt-DEV`, JU |
| `BookCustody(custodyId, booking, opts)` | `booking = { mugshotUrl?, height?, marks?, notes? }` (identity fields are read by the server: fingerprint and bloodtype from metadata, DNA sample id generated) | `{ ok, bookingNo, receiptId }` | `pf-policemdt-DEV` (booking page), `pfm-policejob` |
| `AssignHoldingCell(custodyId, cellId, opts)` | | `{ ok }` | same |
| `AddCustodyLog(custodyId, kind, data, opts)` | `kind` in `rights_read, phone_call, attorney_visit, interview_start, interview_end, meal, medical_check, use_of_force, note` | `{ ok, logId }` | `pfm-policejob`, `pf-policemdt-DEV`, `pf-ambulancejob` |
| `TransferCustody(custodyId, to, opts)` | `to = { kind = 'hospital' \| 'prison' \| 'court' \| 'station', id }` | `{ ok }` | `pfm-policejob`, `pf-policemdt-DEV`, `pf-ambulancejob`, `pfm-prison` |
| `ReturnCustody(custodyId, opts)` | back from a transfer | `{ ok }` | same |
| `ReleaseFromCustody(custodyId, reason, opts)` | `reason` in `no_charges, cited, bailed, court_order, sentence_complete, transferred` | `{ ok }` | same |
| `IsInHoldingCell(src)` | | `bool` | JU clock |

Persistence across disconnect and restart: the custody row is the truth. A player who reconnects while `arrested`,
`in_transport`, `booking` or `held` is placed back (server `SetEntityCoords`) at the custody's facility
(`Config.Custody.ReturnPoint[facility]`), cuffs are re-applied through `exports['pfm-policejob']:SetCuffed(src, true, 'custody')`
for `arrested`/`in_transport`, and the log records `reconnect`. This also ends combat-logging out of an arrest.

#### 4.7.4 Booking
- Booking number `BK-<yyyymmdd>-<seq>`; fingerprint = `metadata.fingerprint` (server), DNA sample id = a new random
  token stored only in `pf_justice_bookings` and handed to PJ `RegisterReferenceSample` (b18) for lab matching, so
  DNA is no longer the reversible hex of the citizenid.
- Mugshot: an https URL from the client's screenshot upload is stored with `client_supplied = 1` and shown as such.
- Medical screening: `exports['pf-ambulancejob']:GetPatientSummary(cid)` at booking; a `down`, `red` or `orange`
  patient cannot be booked into a holding cell (must go to hospital first).

#### 4.7.5 Property
| Export (new) | Args | Returns | Callers |
|---|---|---|---|
| `SeizeProperty(target, opts)` | `opts = { custodyId, keep = { 'phone' }?, items = 'all' \| { { name, slot, amount } }, reason, key }` | `{ ok, receiptId, items = n }` | `pfm-policejob`, `pf-policemdt-DEV`, `pfm-prison` |
| `GetPropertyReceipt(receiptId)` | | `{ ok, receipt = { id, cid, items, state, lockerStash } }` | open to the owner citizen, officers, PR |
| `ReturnProperty(receiptId, opts)` | `opts = { toSrc, key }` | `{ ok, returned, kept = { ... } }` | JU internal, `pfm-prison`, `pf-policemdt-DEV` |
| `ForfeitPropertyItems(receiptId, items, opts)` | contraband -> evidence | `{ ok, evidenceIds }` | `pf-policemdt-DEV`, `pfm-prison` |

Items move into the stash `pf_justice_property_<receiptId>` with the inventory's own `ClearInventory` +
`AddItem(stashId, ...)` path (rolled back like pfm-prison's `StoreItems`). Returning adds items back without clearing
what the player holds; items that do not fit stay in the locker and come back at the next load (fixes the MDT release
that cleared the current inventory, `sentencing.lua` `giveItems`).

#### 4.7.6 Bail
| Export (new) | Args | Returns | Callers |
|---|---|---|---|
| `OfferBail(ref, spec, opts)` | `ref = { custodyId } \| { orderId }`, `spec = { amount, conditions?, payerCid? }` | `{ ok, bailId }` | `pf-policemdt-DEV`, JU courts |
| `AcceptBail(bailId, payerSrc, opts)` | payer must stand near the officer or at a bail desk (`Config.Bail.Desks`, server position) | `{ ok, state = 'posted' \| 'payment_pending' }` | `pf-policemdt-DEV` (`/bailaccept` relay), JU |
| `DeclineBail(bailId, payerSrc)` | | `{ ok }` | same |
| `GetBail(who)` | | `{ ok, bail? }` | open |
| `ExonerateBail(bailId, opts)` | case closed -> refund to payer | `{ ok }` | JU courts |
| `ForfeitBail(bailId, opts)` | violation -> money stays with the city | `{ ok }` | JU courts |

Bail money: `Transfer({ from = 'player:<payer>:bank', to = 'society:<Config.Bail.Account>', key = 'pf-justice:bail:<bailId>:<n>' })`;
refund on exoneration with key `pf-justice:bail:<bailId>:refund`.

#### 4.7.7 Courts (b19)
| Export (new) | Args | Returns | Callers |
|---|---|---|---|
| `FileCase(spec, opts)` | `spec = { cid, charges, custodyId?, incidentIds?, evidenceIds?, prosecutorCid? }` | `{ ok, caseId }` | `pf-policemdt-DEV` (court submission), JU app |
| `ScheduleHearing(caseId, spec, opts)` | `spec = { kind = 'arraignment' \| 'bail' \| 'trial' \| 'sentencing' \| 'violation' \| 'appeal', at, courtroom, judgeCid? }` | `{ ok, hearingId }` | JU app (clerk/judge) |
| `RecordDecision(caseId, decision, opts)` | `decision = { kind = 'plea' \| 'verdict' \| 'sentence' \| 'dismissal' \| 'bail' \| 'release_order', ... }` | `{ ok, decisionId, orders? }` | JU app (judge) |
| `RequestWarrantReview(spec, opts)` | `spec = { warrantId, type = 'arrest' \| 'search' \| 'bench', targetCid?, address?, affidavit, requestedBy }` | `{ ok, reviewId }` | `pf-policemdt-DEV` |
| `DecideWarrant(reviewId, decision, opts)` | `approve \| deny \| needs_info` | `{ ok }` -> calls PMDT `SetWarrantApproval` | JU app (judge) |
| `IssueReleaseOrder(cid, spec, opts)` | court-ordered release | `{ ok, releaseOrderId }` | JU app (judge) |
| `IsCourtOrderValid(ref, purpose, cid)` | `purpose` in `medical_records, search, telemetry, property` | `bool` | AJ, PJ, PMDT |
| `GetCase(caseId)`, `ListDocket(filter)` | | `{ ok, ... }` | open, filtered |

Low population: when no player judge is on duty for `Config.Courts.AutoAfterSeconds`, arraignment and bail hearings
fall back to the published schedule (`Config.Courts.DefaultBail` by charge class) and the decision is recorded with
`decided_by = 'schedule'`. Trials and warrant approvals never auto-decide.

#### 4.7.8 Supervision: probation and parole (b19)
- Orders `probation`/`parole` carry `conditions = { { kind = 'checkin', everyDays }, { kind = 'curfew', from, to, zone },
  { kind = 'no_go', zone }, { kind = 'no_weapons' }, { kind = 'no_alcohol' }, { kind = 'community_service', units }, { kind = 'monitor' } }`.
- Exports (new): `GetSupervision(cid)`, `ScheduleAppointment(supId, spec, opts)`, `RecordCheckIn(supId, opts)`,
  `RecordViolation(supId, spec, opts)`, `SetMonitor(cid, monitor, opts)`.
- Monitors: server-side geofence at 0.2 Hz for monitored online players (`GetEntityCoords`), zones from config or a
  house from `exports['pfm-houses']:GetOwnedHouses()`. A breach writes a violation **report** for the officer; it
  never changes custody by itself (owner rule: the configured legal process decides).

#### 4.7.9 Community service (b19)
- The order is `kind = 'community_service', units, dueAt`. Runtime state in `pf_justice_cs_shifts`, `pf_justice_cs_tasks`.
- Flow: the citizen opens a shift at a sign-in point (server zone) -> JU lists eligible GOV work orders near them
  (`ListWorkOrders({ cs_eligible = true, near })`) -> claims one unit (`ClaimWorkOrder`) -> does the in-world task
  (4.7.9 tasks below) -> JU validates and calls `ReportWorkUnit(claimId, proof, { key = 'pf-justice:cs:<taskId>' })`
  -> on `{ ok = true }` the order's `units_done += 1`.
- Task validation (server): stayed within the site radius for the task's minimum time (sampled at 1 Hz from server
  positions), performed the required number of interaction steps (`pf-justice:server:CsTaskStep(taskId, step)`, each
  step at least `MinStepSeconds` apart and at a different point of the site for litter/graffiti), no vehicle used.
- Supervisor: an on-duty `doj` probation officer or `government` staff can verify a shift (adds `supervised = 1`;
  `Config.CommunityService.SupervisorBonus` may count 1.25 units). Without a supervisor, tasks still count (low pop).
- Missed deadline: the order becomes `overdue` and a court item is filed (`FileCase` with `kind = 'violation'`);
  **no automatic prison**.
- Export `CanUseCsApp(_, src, appId)` (new, 21F) is the pf-devices `access.check` for the Community Service app: true
  for a citizen with an active CS order, an on-duty `doj` probation officer, or `government` staff.
- Export `GetCommunityService(cid)` -> `{ ok, orders = { { orderId, units, unitsDone, dueAt, state } } }` (open, filtered).

### 4.8 pfm-prison (PR, batches 16 and 19)
| Export | Args | Returns | Callers | Status |
|---|---|---|---|---|
| `JailPlayer(src, minutes, opts)` | as today | `ok, err` (legacy shape) | allowlist `Config.JailResourceAllowlist` (add `pf-policemdt-DEV`, `pf-justice`) | existing, becomes a forwarder to `CreateOrder(kind='prison')` |
| `ReleasePlayer(src, reason)` | as today | `ok, err` | same | existing, forwards to `ReleaseNow` |
| `GetJailTime(src)` | | minutes | open | existing, forwards to `GetJailMinutes` |
| `IsInside(src)` (new) | | `bool` | `pf-justice` | walls test from the existing sampler (memory) |
| `GetInmate(who)` (new) | | `{ ok, inmate? = { cid, orderId, cellId, classification, status, since } }` | open | `status` in `intake, in_cell, yard, work, meal, infirmary, visitation, solitary, transfer` |
| `GetFacilityStatus(facility)` (new) | | `{ ok, population, lockdown, alarms, nextCount, cells = { total, free } }` | open | |
| `SetLockdown(facility, on, opts)` (new) | | `{ ok }` | PR apps, `pfm-adminmenu` | |
| `RecordInfraction(cid, spec, opts)` (new) | `spec = { code, severity, evidenceIds?, hearingAt? }` | `{ ok, infractionId }` | PR apps | due process in 5.13 |

PR listens to `pf-justice:server:orderCreated` (incarceration at a PR facility -> intake) and
`pf-justice:server:releaseOrdered` (release out of the gate). PR emits server-only events
`pfm-prison:server:inmateStatus(cid, status)`, `pfm-prison:server:escape(cid, info)` and keeps the existing city event
`crime.prison.escape`.

Inmate trust accounts (b19) follow the pf-services escrow pattern: money enters with
`Transfer({ from = 'player:<cid>:bank', to = 'system:pfm-prison-trust', key = 'pfm-prison:trust:<cid>:<txId>' })` and leaves
the same way; each inmate's balance is the sum of their keyed rows in `pf_prison_account_tx` (no money is created by
an UPDATE). Earnings come from `society:corrections` (budget-funded). Restitution takes `Config.Economy.RestitutionShare`
of each earning and pays the victim with key `pf-justice:restitution:<orderId>:<n>` through JU `AdjustOrder`.

### 4.9 Evidence (PJ, batches 15 and 18)
| Export (new) | Args | Returns | Callers |
|---|---|---|---|
| `CreateEvidence(spec, opts)` | `spec = { kind, label <= 64, attrs, scene = { coords, label?, sceneId? }, collectedBy = src?, method, sealed = true, caseRef = { type, id }?, origin = { type, id } }`, `opts = { key, giveTo = src \| 'stash:<id>' }` | `{ ok, evidenceId, tag }` | PJ, `pfm-prison`, `pf-justice` |
| `GetEvidence(id, opts)` | `opts = { viewer = src }` | `{ ok, item, custody = {...}, integrity = { score, flags }, labs = {...} }` | open to on-duty LEO, JU courts, PMDT |
| `ListEvidence(filter)` | `{ caseRef?, holder?, kind?, state?, limit <= 100, after? }` | `{ ok, list, next }` | same |
| `TransferEvidence(id, to, opts)` | `to = { kind = 'officer', src } \| { kind = 'locker', lockerId } \| { kind = 'lab', labId } \| { kind = 'court', caseId } \| { kind = 'release', cid }` | `{ ok }` | PJ, PMDT, JU |
| `SealEvidence(id, opts)`, `BreakSeal(id, reason, opts)` | | `{ ok }` | PJ |
| `LinkEvidence(id, caseRef, opts)`, `UnlinkEvidence(id, caseRef, opts)` | | `{ ok }` | PJ, PMDT |
| `SubmitToLab(id, tests, opts)` (b18) | `tests` in `dna, prints, ballistics, tox, drug_id, gsr, trace` | `{ ok, jobId, eta }` | PJ, PMDT |
| `GetLabJob(jobId)` (b18) | | `{ ok, job }` | same |
| `RegisterReferenceSample(cid, kind, source, opts)` (b18) | `kind` in `dna, prints`; `source = { custodyId } \| { warrantId }` | `{ ok }` | `pf-justice` |
| `DisposeEvidence(id, mode, opts)` | `mode` in `release, destroy`; `opts.courtOrderId` required | `{ ok }` | PJ, JU |

- Kinds and their `attrs` schemas: `casing { caliber, weaponHash, serial? }`, `projectile { caliber, weaponHash, serial?, fromInjuryId? }`,
  `blood { sampleId, bloodtype }`, `fingerprint { printId, quality }`, `dna_swab { sampleId, quality }`, `gsr_kit { result? }`,
  `drug { item, amount }`, `weapon { item, serial }`, `item { item, amount }`, `photo { url, clientSupplied = true }`,
  `document { title, body <= 2000 }`, `vehicle { plate }`, `digital { kind, ref }`.
- The inventory item is `evidence_bag` (new, unique) with `info = { evidenceId, tag, kind, label, sealed }`. A
  `pfm-inventory` `AddListener('ItemMoved', ...)` hook turns every move of an `evidence_bag` into a custody event
  (`moved`, from inventory id, to inventory id, actor), so the chain of custody is recorded by the server, not typed.
- Server-only events (new): `pfm-policejob:server:evidenceCreated(item)`, `pfm-policejob:server:evidenceCustody(item, event)`,
  `pfm-policejob:server:labCompleted(job)`.
- Integrity (shown to courts): starts at 100; seal broken outside a lab or court -12 each; custody gap (holder unknown
  more than `GapMinutes`) -20; collected without gloves (`nitrile_gloves` item absent from the collector's inventory, server check) -10 for prints/DNA;
  biological sample collected after `DecayMinutes` -> quality lowered (lab gives partial results), never deleted
  silently: decayed scene drops become `unrecoverable` rows.
- Lab (b18): results come only from server data: DNA and prints match against reference samples registered at booking
  or by warrant (`pf_evidence_reference_samples`); partial quality gives `consistent_with` plus a candidate count;
  ballistics compares the casing's serial with test-fires of seized weapons (`pf_evidence_test_fires`); tox reads
  the AJ toxin levels stored on the sample at collection time. Processing time per test from config, lab tech
  qualification `lab_tech` required to release results.

### 4.10 Police field, traffic and telemetry (PJ, batch 18)
| Interface | Shape | Notes |
|---|---|---|
| net `police:server:Surrender` (new) | none | the suspect raises hands; sets `pf:escort = { state = 'surrendered' }` for 120 s |
| net `police:server:Detain(target)` (new) | | on-duty LEO, 2.5 m; target surrendered, cuffed or down; creates no custody record |
| net `police:server:Frisk(target)` (new) | | weapons-only pat-down: server lists weapon items, officer may seize into evidence |
| net `police:server:Ziptie(target)` (new) | | item `zipties` consumed; same server cuff state with `soft = true, kind = 'ziptie'` |
| net `police:server:EscortPlayer`, `PutPlayerInVehicle`, `SetPlayerOutVehicle` | existing names | server-owned escort state; seat chosen by the server (first free rear seat, `SetPedIntoVehicle`) |
| net `police:server:Arrest(target)` (new) | | `OpenCustody` on JU, then telemetry mark |
| net `police:server:RadarMeasure(netId)` (new) | | server reads the target's `GetEntitySpeed`, checks distance <= range and angle within the cone from the officer vehicle's server heading |
| net `police:server:AlprToggle(on)` (new) | | ALPR runs on the server (`GetAllVehicles`, `GetVehicleNumberPlateText`) around equipped police vehicles every 2 s |
| net `police:server:Breathalyze(target)` (new) | | item `breathalyzer`; BAC from AJ ethanol toxin; result logged |
| export `RunPlate(plate, opts)` (new) | `{ ok, owner?, registration?, flags, impound?, bolos }` | owner from `player_vehicles` (as PJ's `IsVehicleOwned` already does), flags from PMDT `GetPlateFlags`, impound from `pf_police_impounds`, driver licence from the owner's `licences` metadata and pf-government `HasLicense`; registration is `unknown` because pf-government only bills a fee at purchase (`ChargeVehicleRegistration`, no per-plate record) and insurance is not modelled (no insurer exists); both are open items |
| export `GetImpound(plate)` (new) | `{ ok, impound? }` | `pf_police_impounds` |
| export `MarkTimeline(who, kind, data)` (new) | | callers `pf-justice`, `pf-policemdt-DEV`, PJ modules |
| export `GetTimeline(cid, from, to, opts)` (new) | `{ ok, events }` | on-duty LEO supervisors, JU courts (`IsCourtOrderValid(..., 'telemetry')`) |

### 4.11 MDTs
PMDT (new exports, b18/b20):
| Export | Returns | Callers |
|---|---|---|
| `GetPlateFlags(plate)` | `{ flags = { 'STOLEN', 'BOLO', ... }, boloIds }` | PJ (cached; refreshed by `pf_mdt:server:plateFlagsChanged`) |
| `ListActiveBolos(kind)` | `{ ok, list }` | PJ |
| `AttachExternalRecord(target, ref, opts)` | `target = { caseId } \| { incidentId }`, `ref = { type = 'evidence' \| 'custody' \| 'order' \| 'death_record' \| 'citation' \| 'telemetry', id }` | PJ, JU, AJ |
| `SetWarrantApproval(warrantId, decision, opts)` | `{ ok }` | `pf-justice` only |
| `GetWarrant(warrantId)`, `ListWarrantsFor(cid)` | `{ ok, ... }` | PJ, JU |
| `DraftUseOfForce(spec, opts)` | `{ ok, reportId }` | PJ telemetry |
Server-only events (new): `pf_mdt:server:plateFlagsChanged(plate, flags)`, `pf_mdt:server:warrantChanged(warrant)`,
`pf_mdt:server:caseChanged(case)`. New MDT endpoints keep the `pf_mdt:*` prefix so `server/access.lua` gates them;
their permission entries register through `PFMdtAccess.RegisterActions(map)` (new helper, 18F) so a new file never
has to edit `access.lua`.

EMDT (new, b20): `GetPcr(pcrId)`, `ListPcrFor(cid, opts)` (privacy as `GetMedicalRecord`), `GetUnitStatus(src)`.
PCRs open automatically on the first `pf-ambulancejob:server:treatmentApplied` for a patient within a call, and the
narrative is the only typed part.

### 4.12 pf-government: work orders and departments
Work orders (new, b15):
| Export | Args | Returns | Callers |
|---|---|---|---|
| `CreateWorkOrder(spec, opts)` | `spec = { kind, district, site = { x, y, z, r }, units 1..20, effect = { field, delta }, source = { type, id }, payable = { amount, from = '<dept>' }?, csEligible = true, expiresAt }` | `{ ok, workOrderId }` | GOV itself (generator), `pf-services` listeners, `pfm-adminmenu` |
| `ListWorkOrders(filter)` | `{ district?, kinds?, status = 'open', csEligible?, near = { x, y, z, r }?, limit <= 50 }` | `{ ok, list }` | open |
| `GetWorkOrder(id)` | | `{ ok, order }` | open |
| `ClaimWorkOrder(id, claimant, opts)` | `claimant = { kind = 'cs' \| 'staff' \| 'job', cid, ref? }` | `{ ok, claimId, expiresAt }` | `pf-justice`, GOV apps |
| `ReportWorkUnit(claimId, proof, opts)` | `proof = { src }` (GOV re-reads the position) | `{ ok, unitsDone, completed }` | `pf-justice`, GOV apps |
| `ReleaseWorkClaim(claimId, reason)` | | `{ ok }` | same |
| `CancelWorkOrder(id, reason, opts)` | | `{ ok }` | GOV staff |
- `kind` in `litter, graffiti, park, landscaping, public_building, pothole, streetlight, sign`.
- `effect.field` in `pothole_density` (negative delta), `street_light_health`, `traffic_light_health`, `road_condition`
  (positive), `maintenance_backlog` (negative money). These district fields drift incrementally in
  `updateDistrictSimulation` (`server/infrastructure.lua`), so a completed order's delta applied to
  `Infrastructure.DistrictState[district]` and saved with `saveDistrict` persists naturally.
- Generator: every infrastructure tick, districts whose `pothole_density`, light health or backlog cross
  `Config.WorkOrders.Thresholds` get orders up to `MaxOpenPerDistrict`. Graffiti and litter orders also come from
  city events (`pf-services:cityEvent` kinds configured in `Config.WorkOrders.FromEvents`).
- Paid orders pay a non-CS worker with `PFPayout.Pay(cid, 'bank', amount, { key = 'pf-government:wo:<id>:pay:<cid>', from = 'society:<dept>' })`.
- Server-only event (new): `pf-government:server:workOrderCompleted(order)`.

Departments (new, b15 core, b20 rest):
| Export | Args | Returns | Callers |
|---|---|---|---|
| `GetDepartmentOf(srcOrJob)` | | `deptId?` (`police, ems, corrections, doj, government, dot`) | open |
| `HasQualification(cid, qual)` | | `has:boolean, source = 'granted' \| 'implied', expiresAt?` | open |
| `ListQualifications(cid)` | | `{ ok, list }` | open |
| `GrantQualification(cid, qual, opts)` / `RevokeQualification` | `opts = { actor, expiresAt?, key }` | `{ ok }` | GOV app, `pf-policemdt-DEV`, `pf-emsmdt` (department managers) |
| `GetShift(src)` | | `{ ok, shift? = { id, dept, startedAt } }` | open |
| `ListShifts(dept, filter)` | | `{ ok, list }` | GOV app, MDT staff pages |
| `LogDepartmentAudit(dept, action, actor, target, detail)` | | `{ ok }` | allowlisted department resources |
| `RecordTraining`, `IssueAsset`, `ReturnAsset`, `ListAssets`, `CreateProcurement` (b20) | | | |
- Implied qualifications (`Config.Departments.Implied[job][grade] = { 'emt', ... }`) keep every action working on a
  live server before anyone grants certifications; a granted revocation overrides the implied one.
- Shifts are recorded from the existing server event `QBCore:Server:SetDuty`; an incarcerated employee
  (`exports['pf-justice']:IsIncarcerated`) is set off duty. Jailing no longer sets the job to unemployed (decision in
  `PF_REMAINING_WORK.md`).
- Existing budget exports gain an optional trailing `key` (new) for idempotent society moves:
  `SpendFromDepartmentSociety(dept, amount, category, actorId, actorName, reason, key)`,
  `AddFundsToDepartmentSociety(dept, amount, actorId, actorName, reason, key)`. Without a key they behave as today.
- `Config.Budgets.Defaults/LinkedSocietyAccounts/DepartmentNames` gain `corrections` (society `corrections`) and `doj`
  (society `doj`).
- The `CreateBill` export passes its remaining arguments (`issuedBy, issuedByName, recurring`) through to the
  function, so callers can use the unique `recurring` ref (new; the function already supports it).

### 4.13 Platform hooks (batch 15H)
| Resource | Change | Contract |
|---|---|---|
| pfm-doorlock | new exports | `SetDoorState(doorId, locked, opts = { reason })` -> `{ ok }`, allowlist `Config.StateCallers = { ['pfm-prison'] = true, ['pf-justice'] = true }`; `GetDoorState(doorId)` -> `locked:boolean?`. Uses the internal `setDoorState`; no player needed (today relocking needs an online player as `sentSource`) |
| pfm-doorlock config | Bolingbroke doors | `authorizedJobs` adds `corrections = 0` on every prison door; police keep access |
| pfm-phone | `CreateInvoice(data)` accepts `data.ref` (<= 128) | unique; a second call with the same ref returns the first id and `'duplicate'` as the second value |
| pfm-smallresources | new server-only event | `pfm-smallresources:server:consumed(src, itemName, kind, info)` after the item is removed on the server; `kind` in `food, drink, alcohol, custom`; `info = { poisoned?, quality? }` |
| pf-jobgarages | new exports + columns | `GetFleetVehicle(plate)` -> `{ garageId, job, model, plate, serviceState, lastServiceAt, outBy? }`; `ListFleet(job)`; `SetServiceState(plate, state, opts)` with `state` in `ok, due, in_service, out_of_service` |
| pfm-core `shared/jobs.lua` | jobs | `corrections` (type `corrections`, grades 0-5), `doj` (type `doj`: clerk, prosecutor, public defender, probation officer, chief), `judge` grades magistrate/judge/chief judge; `lawyer` keeps grade 0 and gains partner grades |

---------------------------------------------------------------------------------------------------------------------

## 5. State machines

Each machine lives as data in the owner's code (JU: `shared/states.lua`) and is tested by a table-driven spec. A
transition not listed returns `invalid_state`.

### 5.1 Consciousness (AJ)
| From | To | Trigger (server) |
|---|---|---|
| `alert` | `altered` | GCS 9-13 |
| `altered` | `alert` | GCS >= 14 for 10 s |
| `alert`/`altered` | `unconscious` | GCS <= 8, or an accepted `ReportDown` (GTA health 0) |
| `unconscious` | `arrest` | SBP < 50, or SpO2 < 60 for 30 s, or blood loss > 50 %, or lethal head trauma |
| `unconscious` | `altered` | GCS >= 9 for 10 s (e.g. after naloxone, oxygen) |
| `arrest` | `unconscious` | ROSC: defibrillation or CPR success roll per tick while correctable causes are treated |
| `arrest` | `dead` | `ArrestToDeathSeconds` (default 300) without CPR ticks; CPR pauses the timer |
| `dead` | `alert` | admin `Revive`, or respawn at a hospital (`RequestRespawn` after `RespawnAfterSeconds`) |
`inlaststand` = `unconscious` or `arrest`; `isdead` = `dead`. The legacy "last stand" timer becomes the
arrest-to-death timer.

### 5.2 Injury recovery stage (AJ)
`injured -> stabilized -> treated -> recovering -> recovered`, plus `complicated` (infection, re-bleed) from
`stabilized`/`treated`/`recovering` back to `injured`.
| Transition | Condition |
|---|---|
| injured -> stabilized | bleeding controlled (bleed 0 or tourniqueted), airway/breathing threat treated, fracture splinted |
| stabilized -> treated | definitive care for the type done (sutures, reduction, cast, surgery, burn care) |
| treated -> recovering | immediate on definitive care; sets `recover_at = now + HealSeconds(type, severity)` |
| recovering -> recovered | `now >= recover_at` (offline time counts); restrictions end |
| any open -> complicated | untreated open wound older than `InfectionAfterSeconds`, or a re-bleed roll on exertion while `stabilized` |
A patient's `stage` is the worst stage of their open injuries.

### 5.3 Hospital admission (AJ)
`arrived -> checked_in -> triaged -> waiting -> in_treatment -> admitted -> discharged`, with exits `transferred`,
`left_ama` (leaving the zone without discharge; restrictions stay), `deceased`. `in_treatment` and `admitted` hold a
bed. A custody patient cannot reach `left_ama`; leaving is reported to JU as a custody event.

### 5.4 Custody (JU)
| From | To | Who / guard |
|---|---|---|
| (none) | `detained` | PJ `Detain` (no record) or `OpenCustody` with `state = detained` |
| `detained` | `arrested` | officer arrests (`police:server:Arrest`) |
| `arrested` | `in_transport` | placed in a police vehicle (PJ) |
| `in_transport`/`arrested` | `booking` | inside a booking zone with an officer |
| `booking` | `booked` | `BookCustody` done |
| `booked` | `held` | `AssignHoldingCell` |
| `held`/`booked` | `remanded` | court or schedule decides no bail |
| `held`/`booked`/`remanded` | `transferred` | an incarceration order starts at another facility (prison intake) |
| any of the above | `hospital` | `TransferCustody(kind='hospital')`; returns to the previous state with `ReturnCustody` |
| any open | `released` | `ReleaseFromCustody(reason)` |
Detention (custody) and sentence (order) are separate records. A sentence may start while the custody record is
`held` (it then closes as `transferred`).

### 5.5 Incarceration orders (JU)
`pending -> active -> completed`, `active <-> suspended` (escape, court stay), `active -> vacated` (released early by
court, admin or appeal), `active -> revoked` (parole revocation creates a new order). `pending` waits for intake when
`Config.Prison.Intake = 'transport'`.

### 5.6 Fines and citations (JU)
`issued -> paid`, `issued -> payment_pending -> paid | issued`, `issued -> invoiced -> paid`, `issued -> overdue`
(after `dueAt`) `-> referred` (court item), `issued -> waived`. Citation: `issued -> contested -> (upheld | dismissed)`
within `contestDays`.

### 5.7 Evidence custody (PJ)
`collected -> sealed -> stored | in_transit | at_lab -> analysed -> stored -> in_court -> stored`, ends `released`,
`destroyed`. Flags (not states): `seal_broken`, `gap`, `contaminated`, `missing`.

### 5.8 Community service order (JU)
`assigned -> active` (first shift) `-> completed` when `units_done >= units`; `active -> overdue` after `dueAt`
`-> referred` (court); `-> vacated` by court. No transition to an incarceration order exists in this machine.

### 5.9 Court case (JU)
`filed -> arraignment_scheduled -> arraigned -> plea_guilty -> sentencing_scheduled -> sentenced -> closed`;
`arraigned -> plea_not_guilty -> trial_scheduled -> trial -> (guilty -> sentencing_scheduled | acquitted -> closed)`;
`any -> dismissed -> closed`; `sentenced -> appeal_pending -> (affirmed -> closed | reversed -> closed)`.

### 5.10 Warrant review (JU) and warrant (PMDT)
Review: `requested -> approved | denied | needs_info -> requested`. Warrant (PMDT, existing statuses extended):
`draft -> pending_approval -> active -> served | expired | recalled`. Expiry is enforced by a PMDT sweep.

### 5.11 Work order (GOV)
`open -> in_progress` (any claim) `-> completed` (units done), `open/in_progress -> expired | cancelled`.
Claim: `claimed -> done | released | expired` (TTL `ClaimSeconds`, default 600).

### 5.12 Bail (JU)
`offered -> accepted -> posted -> (exonerated -> refunded) | forfeited`; `offered -> declined | expired`;
`accepted -> payment_pending -> posted | offered`.

### 5.13 Prison discipline (PR, b19)
`reported -> hearing_scheduled -> heard -> (sanctioned | dismissed)`; sanctions: `forfeit` credits (through
`AdjustOrder`), `privileges` loss for N hours, `solitary` up to `MaxSolitaryMinutes`. A hearing may be held by an
on-duty corrections officer of grade >= `HearingGrade`; with none on duty for `AutoHearingAfter` the sanction is
limited to privileges (no forfeits without a person deciding).

---------------------------------------------------------------------------------------------------------------------

## 6. Security model

### 6.1 Trust boundaries
- Hostile: every `TriggerServerEvent`, every NUI callback, every client state-bag write, every client-supplied
  coordinate, health value, weapon hash, bone, speed, seatbelt flag, image URL and text.
- Semi-trusted: server natives that read synced entity state (`GetEntityHealth`, `GetEntityCoords`,
  `GetEntityVelocity`, `GetEntitySpeed`, `GetPedArmour`). They come from the entity owner's client, so they are good
  for cross-checks and plausibility, not proof (10).
- Trusted: server-held records, the ledger, inventory server state, other resources' exports (behind allowlists).

### 6.2 Net event handler checklist (in this order)
1. `local src = source`; reject non-numbers and `src <= 0`.
2. Rate limit (6.3).
3. Validate and normalise every argument (3.6).
4. Load the actor's player; check job, grade, duty, qualification.
5. Read server positions; check distances and zones (6.4).
6. Check the owner's state machine allows the transition.
7. Take the per-entity lock before the first DB wait.
8. Consume items or money first; abort on failure.
9. Apply, persist, audit, then notify/push.

### 6.3 Rate limits (defaults, per source)
| Action | Rate |
|---|---|
| Damage hints | 10/s, burst 20 |
| Exam / treat | 2/s, burst 4; same `(src, req)` deduped 30 s |
| Equipment actions | 2/s |
| Evidence scene drops (casing, blood, print reports) | 5/s per type, 200 live drops per 100 m cell |
| Radar measure | 2/s |
| Field custody actions (detain, frisk, escort, arrest) | 1/s |
| MDT writes | existing per-handler limits; new writes 1/s |
| Bail/fine payment | 1/5 s |
| CS task steps | 1 per `MinStepSeconds` |
| pf-devices RPC | 15/s, burst 40 (platform default) |

### 6.4 Proximity rules (server positions only)
| Kind | Distance |
|---|---|
| Touch (cuff, frisk, search, treat, place on stretcher) | 2.5 m (PJ batch-14 standard; exceeding a 2.5 m cuff check drops the player, keep that behaviour only where it already exists) |
| Exam with instruments | 2.5 m; monitor attach 3 m |
| Rig actions | rig rear within 4 m; rig stock within 6 m |
| Sentencing / booking presence | 5 m, or both in the same booking zone (PMDT rule) |
| Bail payer | within 5 m of the officer or inside a `Config.Bail.Desks` zone |
| Radar | target within `Config.Traffic.Radar.Range` (150 m) and inside a 12 degree cone |
| Work-order task | inside the site radius for the task's minimum time |

### 6.5 Role and qualification gates
- Jobs and duty from pfm-core; grades from the job; qualifications from GOV (implied by grade until granted).
- Medical tiers (11.6) decide which exams and treatments a provider may do (scope of practice).
- Courts: judge actions need job `judge` on duty; clerk/prosecutor/defender/probation need `doj` grades; government
  permission `records` may expunge (audited).

### 6.6 Privacy
- Medical records: the patient sees their own; on-duty EMS/medical staff see a patient they treated in the last
  24 h, or who is admitted or on their unit's call; physicians (tier 5) see all medical records; police, prison and
  courts receive only `GetPatientSummary` fields allowed for them, or full records with a valid court order
  (`IsCourtOrderValid(ref, 'medical_records', cid)`). Every read through `GetMedicalRecord` is audited.
- Inmate medical data: corrections staff see `fit_for_work`, `restrictions` and `infirmary_needed` only.

### 6.7 Money
Only through the ledger with keys (3.3). No `SetMoney`/`AddMoney` on players. Society moves through GOV budget
exports with the new key argument, or `Transfer` with a society ref.

### 6.8 Anomaly log
AJ (`pf_med_events` with `action = 'anomaly'`), PJ (telemetry `anomaly`), PR (`pf_prison_events`). Examples: damage
seen by the attacker's `weaponDamageEvent` with no health drop on the victim (godmode), a down player moving faster
than an escort, a hint claiming a fall the server never saw, an inmate moving faster than `MaxSpeed`. Logged with
counts; admins act. Nothing bans automatically except the existing batch-14 behaviours.

---------------------------------------------------------------------------------------------------------------------

## 7. Sync model

| Data | Mechanism | Scope |
|---|---|---|
| Down state | state bag `pf:down` (replicated) + metadata | everyone (needed for animations and target options) |
| Effect profile, symptoms | `TriggerClientEvent` to the owner | owner only, on change |
| Vitals monitor | `TriggerClientEvent` every 5 s | the attached medic only |
| Exam findings, chart | callback result | the asking provider |
| Stretcher/wheelchair attachment | entity state bag `pf:stretcher` (replicated) | everyone in scope; late joiners get it automatically |
| Cuffs | existing `handcuffed` bag + metadata | everyone |
| Escort / surrender | state bag `pf:escort = { state, by }` (replicated) | everyone |
| Sentence countdown for the inmate | `pf-justice:client:Sentence(summary)` on change of the whole minute | owner only |
| Prison facility (lockdown, alarms) | `TriggerClientEvent` to inmates and on-duty corrections; pf-devices `PushToJob('corrections', ...)` | facility audience |
| Evidence scene drops | `TriggerClientEvent` to on-duty LEO within 150 m of the drop, plus a join snapshot of drops within 150 m when an officer goes on duty | officers in range |
| ALPR hits, radar | to the officer who owns the reader | owner |
| MDT boards | existing MDT push | job |
| Apps | `exports['pf-devices']:Push/PushToJob/PushToCitizen` | app audience |

No client ever writes a state bag (strict-mode rule). Values only one client needs are sent by event, not by a
replicated bag.

---------------------------------------------------------------------------------------------------------------------

## 8. Performance budget

Server (target: all PF police/EMS/justice loops together under 2 ms per second of server time at 128 players):
| Loop | Interval | Scope | Budget |
|---|---|---|---|
| AJ health/armour sampler | 1 s | all players (2 natives each) | 0.3 ms |
| AJ velocity sampler | 0.5 s | players in a vehicle or falling (vz < -4 m/s last sample) | 0.2 ms |
| AJ engine tick | 5 s | active patients only (bleeding, down, toxins, monitored) | 0.3 ms per 20 patients |
| AJ write-behind | 10 s | dirty patients, one multi-row statement | 1 query |
| AJ recovery | 60 s | online non-healthy patients | small |
| JU clock | 15 s | online incarcerated players (memory) | 0.1 ms |
| JU monitors | 5 s | monitored online players | 0.1 ms |
| PR sampler | 2 s (existing) | inmates | existing |
| PJ ALPR | 2 s | equipped police vehicles x vehicles within 60 m (spatial bucket) | 0.3 ms |
| PJ speed cameras | 1 s | configured cameras (cap 24) | 0.2 ms |
| PJ telemetry | 5 s | recording officers | 0.1 ms + batched insert every 30 s |
| GOV work-order generator | infrastructure tick | districts | small |

Client: no `Wait(0)` loop unless an effect is being drawn (limp clipset, blur, monitor HUD) or a prop is being placed;
effect loops stop when the profile is all zeros. Hidden NUI pages stop timers on `unmount` and render nothing while
hidden. Bounded tables: every in-memory map keyed by source is cleared on `playerDropped`; every DB list endpoint has
`limit <= 100` and cursor paging; scene drops capped per cell; telemetry and events tables swept by retention.

---------------------------------------------------------------------------------------------------------------------

## 9. Compatibility plan (legacy names kept as forwarders)

| Legacy name | Kind | New behaviour | Batch | Remove when |
|---|---|---|---|---|
| `hospital:server:SetDeathStatus(isDead)` | net | `true` -> treated as `ReportDown(kind='dead')`; `false` ignored (only revive tokens clear down) | 16 | never (old clients and third-party scripts) |
| `hospital:server:SetLaststandStatus(bool)` | net | `true` -> `ReportDown(kind='laststand')`; `false` ignored | 16 | never |
| `hospital:server:SyncInjuries`, `SetWeaponDamage`, `RestoreWeaponDamage` | net | no-op (accepted, dropped) | 16 | after one release |
| `hospital:GetPlayerStatus` | callback | on-duty EMS within 5 m; returns the engine summary in the legacy shape `{ isBleeding, limbs }` | 16 | after pfm-radialmenu `/status` moves to the exam UI (b21) |
| `hospital:GetPlayerBleeding` | callback | the caller's own bleeding level from the engine | 16 | never |
| `hospital:server:RevivePlayer(playerId, isOldMan)` | net | forwards to the treatment pipeline (`cpr`/`defibrillate`/`first_aid_revive` by state); `isOldMan` ignored; the auto-ban on a missing item is removed (a race could ban an honest player) | 16 | never |
| `hospital:server:TreatWounds(playerId)` | net | forwards to `basic_wound_care` | 17 | never |
| `hospital:server:SendToBed`, `RespawnAtHospital`, `LeaveBed` | net | hospital module with server checks (reception zone, down state, bed ownership) | 16/17 | never |
| `hospital:server:resetHungerThirst` | net | removed (free food/water exploit); revive resets needs on the server | 16 | now |
| `hospital:server:SetArmor(amount)` | net | ignored; AJ saves `GetPedArmour(ped)` on drop and every 60 s for all players | 16 | now |
| `hospital:server:AddDoctor` / `RemoveDoctor` | net | no-op; counts from `GetDutyCount('ambulance')` | 16 | now |
| `hospital:server:ambulanceAlert(text)`, `SendDoctorAlert` | net | rate limited; text replaced by a structured alert built on the server | 16 | never |
| `hospital:server:UseFirstAid`, `CanHelp` | net | civilian first aid through the treatment pipeline (2.5 m, target down) | 16 | never |
| `hospital:server:removeBandage/removeIfaks/removePainkillers` | net | no-op; usable items consume on the server (b17) | 17 | after one release |
| `qb-ambulancejob:server:stash` | net | job + duty + within 3 m of the stash point | 16 | never |
| `pf-ambulancejob:server:processDamage` | net | becomes a damage hint (6.4 rules) | 16 | after one release |
| `pf-ambulancejob:server:applyTreatment` | net | forwards to the treatment pipeline | 17 | never (EMDT panel) |
| `hospital:client:Revive` (client) from pfm-adminmenu | client | adminmenu calls `exports['pf-ambulancejob']:Revive` | 16 | now |
| `player_injuries`, `player_treatment_log` | tables | imported once into `pf_med_*`, then read-only | 16 | never dropped automatically |
| `police:server:JailPlayer(playerId, time)` | net | custody check (cuffed or booking zone, like PMDT) -> `OpenCustody` -> `CreateOrder(kind='jail')` | 16 | never |
| `/jail`, `/unjail` | commands | one `/unjail` (PJ, LEO grade or admin) -> `ReleaseNow`; PMDT's admin `/unjail` is removed (it shadowed PJ's) | 16 | now |
| `exports['pfm-prison']:JailPlayer/ReleasePlayer/GetJailTime` | exports | forwarders to JU, legacy return shapes, allowlist extended | 16 | never |
| `metadata.injail` | metadata | written only by JU (remaining minutes) | 16 | never |
| `metadata.jailitems` | metadata | read once on load: items moved into a JU property receipt; then `{}` | 16 | after one release |
| `metadata.criminalrecord` | metadata | written only by JU (`hasRecord`, `date` of last conviction); expiry computed by JU | 16 | never |
| PMDT `createSentence` jail/fine/bail | callbacks | keeps the legal record (`pf_mdt_sentences`) and calls JU for the order, fine and bail; the built-in jail tick is removed | 16 | — |
| PMDT `pf_mdt_active_jails` | table | imported once into JU orders and property; then read-only | 15/16 | never dropped automatically |
| PMDT rcore bridge (`pf_mdt:prison:*`) | callbacks | untouched; only used when `Config.Sentencing.PrisonScript == 'rcore'` | — | — |
| PJ `filled_evidence_bag` | item | still opens; new evidence uses `evidence_bag`; legacy bags can be registered into the evidence store at a station terminal | 15/18 | never |
| PJ in-memory `Plates` flags (`/flagplate`) | memory | `/flagplate` writes a PMDT flag; ALPR reads PMDT flags | 18 | — |
| PJ `police:server:showFingerprint*` | net | LEO + 2.5 m; shows the booking print record when one exists | 18 | — |
| GOV expungement hard delete | code | calls JU `Expunge` (audited; MDT rows soft-deleted by PMDT export) | 19 | now |

---------------------------------------------------------------------------------------------------------------------

## 10. Honest limits (what the game can and cannot tell us)

- **Server health is the owner client's report.** Under OneSync the server reads `GetEntityHealth`, `GetPedArmour`,
  positions and velocities, but they are synced from the ped's owner (the player's own client). A modified client
  can lie about all of them. We cross-check and log; we cannot prove.
- **No server `SetEntityHealth`.** Healing, damage and revive are applied by the owning client; the server issues a
  token and verifies afterwards. A cheater can refuse to be revived (harmless) or resurrect locally (the server keeps
  them `down`, other resources treat them as down, and movement while down is logged and can be frozen with the
  server `FreezeEntityPosition` RPC native).
- **Hit location.** `GetPedLastDamageBone` is a client native. The server's `weaponDamageEvent.hitComponent` mapping is
  undocumented; we map only components verified in game (start with the head) and otherwise accept the victim's bone
  hint for their own injuries.
- **`weaponDamageEvent`** is sent by the attacker's client, before the damage applies, and `willKill` is unreliable.
  Falls, drowning, fire and vehicle impacts without an attacker do not produce it.
- **Falls and crashes** are estimated from 1-2 Hz server velocity samples plus client hints clamped to them. Results
  are estimates (height bands, delta-v bands), not physics. Seatbelt state is a client claim and can only lower
  severity by one band.
- **Protective equipment.** Armour value is server-readable. Helmets and other props are read from the client or
  inventory items (`Config.Medical.Protection.Items`), so helmet protection is item-based.
- **Bodycam/dashcam are not video.** FiveM has no server-side video. "Bodycam" here is a server telemetry timeline
  (positions, weapon in hand where readable, server-seen actions like cuff, search, shots registered by
  `weaponDamageEvent`, vehicle entry, radio channel where pma-voice exposes it). Optional screenshots are
  client-supplied stills and are labelled as such. Shots that hit nothing are only known from the shooter's client
  (casing reports) and are labelled "client-reported".
- **CCTV** is a live client camera at a fixed point; recordings are not possible. The MDT shows camera locations and
  the telemetry/evidence linked to that area and time, and states that no recording exists.
- **ALPR and radar** read synced plates and speeds; a spoofed plate text on a modified client would be read as spoofed.
- **Mugshots and evidence photos** come from `screenshot-basic` on the client; stored with `client_supplied = 1`.
- **Drones and K9** are client presentations; the server decides results (search hits from inventory, drone position
  bounded to a radius from its operator) and logs them.
- **Doors** change state for everyone through pfm-doorlock; a client that ignores the door state can still clip
  through geometry (same as today); prison presence is decided by the server sampler, not by doors.

---------------------------------------------------------------------------------------------------------------------

## 11. Clinical and injury models

### 11.1 Anatomy (AJ `shared/medical/anatomy.lua`)
Two layers, both configurable data:
- **Structures** (the named entities the owner listed): `skull`, `brain`, `face_jaw`, `neck`, `spine_cervical`,
  `spine_thoracic`, `spine_lumbar`, `shoulder_l/r`, `clavicle_l/r`, `humerus_l/r` (arm), `elbow_l/r`, `forearm_l/r`,
  `wrist_l/r`, `hand_l/r`, `sternum` (chest), `ribs_l/r`, `heart`, `lung_l/r`, `airway`, `liver`, `spleen`,
  `kidney_l/r`, `stomach`, `bowel`, `bladder`, `pelvis`, `hip_l/r`, `femur_l/r`, `knee_l/r`, `tibia_l/r`, `fibula_l/r`,
  `ankle_l/r`, `foot_l/r`, `heel_l/r`, plus vessels `carotid`, `aorta`, `brachial_l/r`, `femoral_l/r`.
  Each: `{ label, kind = 'bone'|'joint'|'organ'|'vessel'|'soft', group = 'head'|'torso'|'arm_l'|..., side, vital, bleedClass, armour = 'helmet'|'vest'|nil }`.
- **Regions** (hit zones): `head`, `face`, `neck`, `chest_l/r`, `abdomen`, `back_upper`, `back_lower`, `pelvis`,
  `shoulder_l/r`, `upper_arm_l/r`, `forearm_l/r`, `hand_l/r`, `thigh_l/r`, `knee_l/r`, `lower_leg_l/r`, `foot_l/r`.
  Each region lists structures with hit weights and depth (`surface`, `bone`, `organ`), e.g.
  `abdomen = { { 'bowel', 0.35, 'organ' }, { 'liver', 0.25, 'organ' }, { 'spleen', 0.15, 'organ' }, { 'kidney_r', 0.1, 'organ' }, { 'stomach', 0.15, 'organ' } }`.
- **Bone map**: GTA bone ids -> region, starting from the ids already in `Config.Bones` (`31086` head, `39317` neck,
  `24816-24818`/`23553`/`57597` spine, `10706`/`64729` clavicles, `11816` pelvis, `45509`/`61163` left arm,
  `18905` left hand, `40269`/`28252` right arm, `57005` right hand, `58271`/`63931` left thigh/calf, `14201`/`2108`
  left foot, `51826`/`36864` right thigh/calf, `52301`/`20781` right foot, finger ids -> hands). Knee and elbow
  helper bones are added only after in-game verification.
- `heel_l/r` and `ankle_l/r` are reached by fall and crush mechanisms (no GTA bone).

### 11.2 Injury catalog (AJ `shared/medical/injuries.lua`)
Each type: `{ label, subtypes, structures (allowed kinds), bleed = { class, mlPerMin by severity }, pain by severity,
effects by severity, stabilizeBy = { actions }, treatBy = { actions }, healSeconds by severity, infection = bool,
signs (see findings) }`. Severity 1..5 (minor, moderate, serious, severe, critical).
| Type | Subtypes | Notes |
|---|---|---|
| `fracture` | `closed, open, displaced, comminuted, stress` | open -> bleed + infection risk; femur/pelvis -> internal bleed class 2-3 |
| `dislocation` | shoulder, elbow, hip, knee, finger | reduction (tier >= 3 field for shoulder/finger, hospital otherwise) |
| `sprain` | ankle, wrist, knee | no bleed; walk/climb effects |
| `bruising` | `contusion, hematoma` | pain only; hematoma on head -> watch for head trauma |
| `laceration` | `superficial, deep, arterial` | arterial -> class 3 bleed, tourniquet |
| `gunshot` | `graze, penetrating, perforating (exit), retained` | organ roll by region weights; `retained` keeps `attrs.projectile` |
| `stab` | `superficial, penetrating` | organ roll |
| `burn` | `first, second, third` degree + `tbsa` % | fluid loss, infection, airway if face/neck |
| `crush` | limb, chest, pelvis | compartment risk, rhabdo flag after 30 min |
| `electrical` | `taser, low_voltage, high_voltage` | arrhythmia chance by voltage, entry/exit burns |
| `head_trauma` | `concussion, skull_fracture, epidural, subdural, diffuse` | GCS penalty, vision, no-drive restriction |
| `spinal` | `cervical, thoracic, lumbar` + `cord` flag | immobilisation required before moving (moving without collar/backboard can worsen) |
| `internal_bleeding` | liver, spleen, kidney, pelvic, thoracic | hidden; found by FAST/CT; needs surgery above severity 3 |
| `organ_trauma` | heart (tamponade), lung (pneumothorax, tension, hemothorax), bowel | respiratory/circulatory threats |
| `respiratory` | `airway_obstruction, smoke_inhalation, aspiration` | airway factor |
| `drowning` | `near_drowning` | SpO2 drop, aspiration |
| `poisoning` | `ethanol, opioid, stimulant, sedative, co, food, chemical` | from toxins (11.3) |
| `illness` | `food_poisoning, infection_sepsis, hypothermia, heat_stroke` | from consumables, wounds, weather |
| `infection` | `wound_infection, sepsis` | from untreated open wounds over time |

### 11.3 Physiology (AJ `shared/medical/physiology_model.lua`, pure functions)
State per patient: `blood_ml` (start 5000), `hgb_factor` (0..1, carrying capacity), `airway` (`clear, partial,
obstructed, secured`), `breathing` (0..1 effort x mechanics), `pain` (0..10), `temp_c`, `toxins = { name = level }`,
`drugs = { name = { mg, at } }`, `cpr_last_at`, `arrest_since`.
Per tick (`dt` seconds, default 5):
- `bleed = sum(wound.bleed_ml_min)` after treatments (tourniquet 0 for that limb, pressure x0.3, hemostatic x0.2,
  TXA x0.7 for 3 h); clotting: non-arterial wounds `bleed *= (1 - 0.01 * dt/5)`.
- `blood_ml -= bleed * dt / 60`; fluids add volume (saline adds volume only), blood products add volume and `hgb_factor`.
- Loss class from `loss = (5000 - blood_ml) / 5000`: <15 % I, 15-30 % II, 30-40 % III, >40 % IV.
- `hr = 75 + {0, 25, 45, 65}[class] + 2*pain + stimulant*20 - opioid*10`, clamped 30..190 (0 in arrest).
- `sbp = 120 - {0, 0, 30, 60}[class] - 30*tension_pneumo - 25*tamponade - 20*spinal_shock + 15*epi_active`; `dbp = 0.65*sbp`.
- `rr = 14 + 3*class + hypoxia_drive - 8*opioid`, 0 when the airway is obstructed or in arrest.
- `spo2 = clamp(98 * breathing * airway_factor * hgb_factor^0.3 + oxygen_bonus, 50, 100)`, `airway_factor` 1 / 0.8 / 0.3 / 1.
- `gcs = 15 - head_penalty - (spo2 < 85 and 3 or 0) - (spo2 < 75 and 3 or 0) - (sbp < 80 and 3 or 0) - (sbp < 60 and 3 or 0) - toxin_penalty`, clamped 3..15.
- `shock` = loss class, raised by one for tension pneumothorax, tamponade or spinal shock.
- Pain = max wound pain + 0.5 x the rest, capped 10, minus analgesia (morphine -3, fentanyl -4, for their duration).
- Natural recovery when not bleeding and conscious: `blood_ml += 0.5 ml/min` (slow; transfusion is the real fix).
Vitals shown to anyone are **derived** from this state each tick; nothing stores "HR = 90" as a fact.

### 11.4 Functional effects (AJ `shared/medical/effects_model.lua`)
Channels 0..3: `walk` (0 normal, 1 limp, 2 heavy limp / no sprint, 3 cannot walk -> crawl), `sprint`, `jump`, `climb`,
`aim` (sway), `reload` (slower), `drive` (1 wobble, 2 cannot drive), `stamina`, `vision` (blur/tunnel), `pain`
(screen intensity), plus events `passOut` (scheduled by the server from GCS).
Combination: per channel the **maximum** over open injuries, never the sum; physiology adds (shock class 3 -> stamina 3,
SpO2 < 85 -> vision 2); treatment lowers (splint: walk 3->2, crutches restriction: walk 2 with no sprint, painkillers
lower `pain` and `aim` by one but never structural channels). The client applies only non-zero channels and stops its
loop at all zeros.

### 11.5 Mechanisms (AJ `shared/medical/mechanisms.lua`)
Inputs: weapon group (from `Config.Weapons` classes), region (bone), server health and armour deltas, server velocity
samples, vehicle state, protection items, water/fire hints.
| Mechanism | Rule |
|---|---|
| Firearm | region by bone; armour covering the region (`vest` for chest/abdomen/back, helmet item for head) stops penetration by class (`SMALL` 80 %, `MEDIUM` 50 %, `HIGH` 15 %) -> bruising/rib fracture instead; otherwise `gunshot` with organ roll by depth weights; exit chance by class; retained otherwise |
| Edged | `laceration` (slash) or `stab` (thrust weapons); organ roll for torso |
| Blunt / melee | `bruising`; face -> `face_jaw` fracture chance by damage; head -> concussion chance |
| Fall | height `h = vz^2 / (2 * 9.81)` from the server's peak downward speed: < 3 m bruising/sprain; 3-6 m `heel`/`ankle`/`tibia` fracture; 6-10 m `femur`/`pelvis`/`spine_lumbar`; > 10 m multi-trauma incl. head; landing region from the victim's bone hint when consistent |
| Vehicle occupant | delta-v from server speed samples: < 20 km/h bruising; 20-50 whiplash (`neck` sprain), `ribs`; 50-80 fractures, `internal_bleeding`, concussion; > 80 critical multi-trauma; unbelted (client claim) raises one band, belted lowers one |
| Pedestrian struck | `WEAPON_RUN_OVER_BY_CAR`/`RAMMED_BY_CAR` + striking speed: lower-leg fractures, pelvis, head on bonnet |
| Burn | `WEAPON_FIRE`/molotov/explosion: degree by damage per second, TBSA by exposure duration |
| Electrical | `WEAPON_STUNGUN` -> taser (barb wounds, brief incapacity), `WEAPON_ELECTRIC_FENCE` -> burns + arrhythmia roll |
| Explosion | blast: multiple regions, burns, `organ_trauma` lung, hearing (vision 1 for 60 s) |
| Drowning | `WEAPON_DROWNING` hint + health drop while the server sees the ped in water (hint) -> `drowning` |
| Poisoning / illness | toxins from `pfm-smallresources:server:consumed` (alcohol, poisoned food) and `AddToxin` |
| Infection | open wound untreated past `InfectionAfterSeconds` -> `infection` with fever |
Plausibility (6.8 / ingest): a hint becomes injuries only when the server saw a matching health or armour drop within
2 s (1 Hz cache) or a `weaponDamageEvent` against this victim within 1.5 s; the total new severity is capped by
`ceil((hpDrop + 0.5 * armourDrop) / 10) + 1`; a claimed weapon with no matching attacker event (and not environmental)
is downgraded to unknown blunt trauma and logged.

### 11.6 Diagnosis tiers and modalities
| Tier | Who (implied) | Modalities |
|---|---|---|
| 0 | anyone | look (visible bleeding, deformity, burns), ask (pain scale) |
| 1 | EMR (`ambulance` grade 0) | + pulse, palpate |
| 2 | EMT (grade 1) | + bp_cuff, spo2_probe, pupils, glucose, temperature |
| 3 | Paramedic (grade 2+) | + auscultate, ecg (monitor), fast_us on a rig |
| 4 | Nurse (`nurse` qual) | ED triage, labs ordering |
| 5 | Physician / surgeon (`physician`, `surgeon` quals) | xray, ct, labs, confirmed diagnoses, surgery |
Each injury type defines `signs[modality] = { sign, sensitivity by tier }`; a miss leaves no finding (an honest
"not found", not a wrong one). Internal bleeding shows only indirect signs (tachycardia, low BP) until FAST/CT.

### 11.7 Treatment catalog (AJ `shared/medical/treatments.lua`)
`pressure_dressing`, `hemostatic_gauze`, `tourniquet` (time on > 120 min -> limb damage), `chest_seal`,
`needle_decompression` (tier 3), `opa`, `npa`, `bvm`, `intubation` (tier 3, `paramedic`), `oxygen`, `c_collar`,
`backboard`, `splint`, `traction_splint`, `pelvic_binder`, `iv_access`, `fluids` (saline), `blood_onegative`,
`txa`, `morphine`, `fentanyl`, `naloxone`, `epinephrine`, `cpr`, `defibrillate` (AED item; shockable rhythm from
cause), `burn_dressing`, `cooling`, `basic_wound_care`, `sutures` (hospital), `reduction`, `cast` (hospital),
`antibiotics`, `antidote`, `surgery_*` (OR, `surgeon`, confirmed diagnosis), `first_aid_revive` (civilian with
`firstaid` on an `unconscious` patient whose causes allow it; never on `arrest` or `dead`).
Each entry: `{ label, tier, qual?, location = 'field'|'rig'|'hospital'|'or', items = { name = count }, equipment = { names },
duration, requires = { findings? / states? }, apply = '<handler key>' }`.

### 11.8 Recovery and restrictions
`healSeconds` per type and severity in config (examples: bruising 1800 s, sprain 7200 s, closed fracture with cast
43200 s, gunshot treated 21600 s, concussion 7200 s with `no_drive`). Offline time counts. Restrictions from
discharge orders persist in `pf_med_restrictions` and are re-pushed at load. A follow-up appointment goes to the
patient's calendar (`pf-citizen` `AddCalendarEvent`), and an earlier follow-up visit can shorten `recover_at` by
`FollowUpBonus`.
