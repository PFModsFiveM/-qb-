# PF Ultimate: implementation progress

The tracker for the overhaul. Update it at the end of every batch (lead) and resume from the journal at the bottom.

**Status values** (one per row):
- **Not started**
- **In progress** (a unit is working on it)
- **Implemented** (code exists; may be legacy or partial, see notes)
- **Integrated** (wired to the systems it depends on)
- **Tested** (implemented/integrated and covered by automated specs: mocked and/or real-DB/JS)
- **Blocked** (needs something outside the code)

Nothing is validated with a game client yet (no FiveM client in the development environment). "Legacy" in a note
means the piece works today but is replaced or reshaped by the batch named.

Base at the time of writing: batch 14 is in the working trees, uncommitted (lead integrates it before batch 15).
Statuses marked "b14" count as Tested only once batch 14 is committed with green suites.

## 1. Medical engine (owner pf-ambulancejob)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Legacy limb/bleed model (15 client regions, bleed 0-4) | Implemented | AJ client | 16/17 retire | Legacy: client-authoritative, never persisted; painkillers pause bleeding |
| DB injury records `player_injuries` (6 zones, 8 types) | Tested | AJ | 16B import | Legacy: values chosen by the client; real-DB spec `ambulance_injuries_realdb_spec` |
| Anatomy entities (structures, regions, bone map) | Not started | AJ `shared/medical/anatomy.lua` | 15A | |
| Injury catalog (fractures..infection, 19 categories) | Not started | AJ `shared/medical/injuries.lua` | 15A | |
| Physiology model, derived vitals | Not started | AJ `shared/medical/physiology_model.lua` | 15A | |
| Patient store + persistence + offline catch-up | Not started | AJ `server/medical/store.lua` | 15A | |
| Server-owned down/death state | Not started | AJ `server/medical/downstate.lua` | 16A | Today `isdead`/`inlaststand` come from client events; carry-over (a) from batch 14 lands here |
| Damage ingestion with plausibility (weaponDamageEvent, health sampler, falls, crashes) | Not started | AJ `server/medical/ingest.lua` | 16B | |
| Functional effects (walk, sprint, aim, drive, vision...) | Implemented | AJ client | 17C | Legacy: client limb effects; new max-per-channel model in 17C |
| Toxins (alcohol, poisoning, drugs) | Not started | AJ | 15A/15H | pfm-drugs hook unscheduled |
| Diagnosis layers + exam modalities | Not started | AJ | 17A | `/checkinjuries` scan exists (Tested) and becomes the exam entry |
| Treatment engine with equipment | Implemented | AJ | 17B | Legacy: `/treat` with 4 generic treatments (server-validated, Tested); self-use items heal on the client |
| Recovery stages + restrictions + offline progression | Not started | AJ | 17C | |
| Medical records privacy | Not started | AJ | 17A | |

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
| EMS MDT tables by migrations | Not started | EMDT `server/schema.lua` | 15G | Created ad hoc today |
| Qualifications (EMR..surgeon) as scope of practice | Not started | GOV departments + AJ | 15I/17B | Implied by grade until granted |

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
| `/fine` with records and sweep | Tested | PJ `server/fines.lua` | b14 | new fines become JU orders in 16D |
| `/jail` through pfm-prison | Tested | PJ + PR | 16D | Becomes a JU order; custody check added |
| Tackle | Implemented | PJ | - | |
| Spikes (server-spawned, capped) | Tested | PJ | b14 | |
| Props (cones, barriers...) | Implemented | PJ | 18C | Legacy: client-spawned, no caps |
| Radar gun, speed cameras | Not started | PJ `server/traffic.lua` | 18B | |
| ALPR | Implemented | PJ | 18B | Legacy: fixed points, flag check only, in-memory flags, no read log |
| Registration/licence checks, run plate | Implemented | PJ + PMDT | 18B | `/plateinfo` + MDT vehicle profile; no single `RunPlate` |
| Breathalyzer | Not started | PJ | 18B | |
| Citations (one entity) | Not started | JU `IssueCitation` + PJ | 15B/18B | Four parallel fine paths today |
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
| Casings, blood, fingerprints (scene drops) | Implemented | PJ | 15D | Legacy: memory only, no rate limit, `-1` broadcasts |
| Evidence bags | Implemented | PJ | 15D | DNA label is reversible citizenid hex |
| Drug seizure -> news lead | Integrated | PJ | b10 | |
| Persistent evidence + chain of custody | Not started | PJ `server/evidence/*` | 15D | |
| Evidence lockers per case | Not started | PJ | 18D | Shared drawers today |
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
| MDT tables created by migrations | Not started | PMDT `server/schema.lua` | 15F | Today only if the SQL file was imported by hand |
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
| pf-justice resource | Not started | JU | 15B | |
| Orders of every kind + one clock | Not started | JU | 15B | |
| Custody record (arrest to release), reconnect safety | Not started | JU | 15C | |
| Booking (number, prints, DNA sample, mugshot, screening) | Not started | JU | 15C | |
| Holding cells | Not started | JU | 15C | |
| Property seizure with receipts | Not started | JU | 15C | Items stored today in metadata (PR) or JSON (MDT) |
| Bail | Tested | PMDT | 15C/16D | Moves to JU |
| Criminal record | Implemented | PJ/PR metadata | 15B/15C | Bug: expiry never saved (`prison:server:CheckRecordStatus`) |
| Legacy import (MDT jails, offline injail) | Not started | JU | 15C | |

## 8. Prison and corrections (owner pfm-prison)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Server-owned sentence countdown, inside-walls check | Tested | PR | b14 | Moves to the JU clock in 16C (PR keeps the presence test) |
| Escape detection through hacked gates | Tested | PR | b14 | |
| Gate hack with minigame verdict | Tested | PR + pfm-minigames | b14 | |
| Electrician job with time cuts | Tested | PR | b14 | carry-over (c): teleport check in 16C |
| Jailing sets job to unemployed | Implemented | PR | 16C | Owner decision pending (keep job, off duty) |
| Driven by pf-justice orders | Not started | PR `server/justice_bridge.lua` | 16C | |
| Housing, cells, classification, uniforms | Not started | PR | 19D | |
| Routines, headcounts | Not started | PR | 19D | |
| Discipline with due process | Not started | PR | 19D | |
| Visitation | Not started | PR | 19D | |
| Prison jobs tied to real operations | Not started | PR | 19E | kitchen, laundry, maintenance |
| Commissary, trust accounts, earnings, restitution | Not started | PR | 19E | |
| Doors, cameras, alarms, contraband, searches, lockdowns | Implemented | PR | 19F | Legacy: alarm/lockdown exist; doors need an online player to relock (15H fixes) |
| Corrections officer job | Not started | pfm-core jobs | 15H | |
| Corrections MDT | Not started | PR | 21E | |

## 9. Community service, courts, probation, parole (owner pf-justice)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Government work orders | Not started | GOV `server/workorders.lua` | 15E | Infrastructure is a simulation with no work orders today |
| Community service runtime | Not started | JU | 19C | |
| Courts: cases, hearings, decisions, release orders | Not started | JU | 19A | judge/lawyer jobs are one-grade stubs |
| Warrant approval | Not started | JU + PMDT | 19A/18F | |
| Probation / parole, monitors | Not started | JU | 19B | |
| Expungement with audit | Implemented | GOV | 19A | Legacy: unaudited hard delete of MDT rows |
| Court/Justice app, CS app, records portal | Not started | JU | 21F | |

## 10. Department management (owner pf-government)

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Budgets and linked society accounts | Implemented | GOV | 15E | Society moves have no idempotency key today |
| Ranks, hire, fire | Implemented | pfm-management | - | |
| Officer HR (discipline, profiles) | Implemented | PMDT / EMDT `officers.lua` | 20F | |
| Fleet garages | Implemented | pf-jobgarages | 15H | No service state |
| Qualifications, shifts | Not started | GOV `server/departments/*` | 15I | |
| Training, asset register, procurement, payroll reports | Not started | GOV | 20E | Pay stays in the pfm-core paycheck |
| Department admin app | Not started | GOV | 21G | |

## 11. Platform hooks and cross-cutting

| Feature | Status | Owner | Batch | Notes |
|---|---|---|---|---|
| Doorlock state export without a player | Not started | pfm-doorlock | 15H | |
| Phone invoice idempotency `ref` | Not started | pfm-phone | 15H | carry-over (b) from batch 14 |
| Consumed-item server event | Not started | pfm-smallresources | 15H | |
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

**Resume here (next session):**
1. Confirm batch 14 is committed and both suites are green; record the counts in `PF_TEST_REPORT.md` section 2.
2. Read `PF_REMAINING_WORK.md` "Open decisions"; apply any owner answers to the plan (they change 16C and 15B).
3. Run the ownership check (plan section 14) for batch 15.
4. Launch batch 15 units 15A-15I with prompts built from `AGENT_CONTEXT.md` + the unit section + the architecture.
5. After batch 15: update this tracker (statuses, notes), add a journal entry, then start batch 16.
