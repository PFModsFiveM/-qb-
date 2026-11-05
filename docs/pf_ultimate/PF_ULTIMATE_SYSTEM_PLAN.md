# PF Ultimate: system plan and implementation batches

Police, EMS, medical engine, hospitals, evidence, MDT, booking/jail, prison/corrections, community service,
courts/probation/parole and department management, rebuilt on the PF base (`pfm-core` + pf-devices + pf-services +
the pfm-banking ledger).

- Companion files: `PF_ARCHITECTURE.md` (owners and contracts: read it with every unit), `PF_DATABASE_MIGRATIONS.md`,
  `PF_INTEGRATION_MATRIX.md`, `PF_IMPLEMENTATION_PROGRESS.md`, `PF_TEST_REPORT.md`, `PF_REMAINING_WORK.md`.
- Written 2026-11-03 after the read-only audits and research. Nothing in this plan is implemented yet except what
  `PF_IMPLEMENTATION_PROGRESS.md` marks as existing (mostly batch 14 and earlier).
- **2026-11-04: batch 15 is done** (built, checked, reworked; all nine units passed; the lead's final run and commit
  pending). Section 6 keeps the unit specs as written and adds an "As built" line per unit; the contracts as built are
  in `PF_ARCHITECTURE.md` section 12 and the versions in `PF_DATABASE_MIGRATIONS.md` section 2a. Batches 16-22 are
  adjusted where batch 15 changed what they start from (16A, 16C, 16D, 17C). Next: batch 16.

---------------------------------------------------------------------------------------------------------------------

## 1. Vision

One city where the services depend on each other the way real ones do:
- A shot or a crash leaves **real injuries** the server derived from what happened (weapon, hit region, fall speed,
  impact, armour), with **vitals computed from a physiology model**, not typed in or rolled.
- A medic **examines** (what you find depends on your training and tools), **treats with real equipment** the
  server checks and consumes, **transports** on a stretcher in a rig, **hands over** at a hospital that has
  reception, triage, beds, imaging, surgery, a pharmacy, a morgue and bills. Recovery takes time, also while offline.
- An officer **detains, cuffs, frisks, escorts and arrests**; the suspect is **booked** (prints, DNA sample, property
  receipt, medical screening), held, charged, bailed or sentenced through **one justice record**. Evidence has a
  **chain of custody** the server records by itself, and a lab gives **plausible** results from real data.
- A sentence is **one order** with **one clock**. Prison is an institution (housing, routines, counts, work that
  feeds the city, commissary and trust accounts, visits, discipline, security). Community service repairs **real
  district state** through government work orders.
- Courts, probation and parole close the loop with hearings, decisions, conditions and violations, all audited.
- Departments (police, EMS, corrections, DOJ) have qualifications, shifts, training, equipment, procurement and
  budgets tied to pf-government and the ledger.
- Every screen is a real tool with a server behind it, in the PF visual language, on the tablet and the computer.

## 2. Scope

In scope: every requirement in the owner's master prompt, grouped into the domains in `PF_ARCHITECTURE.md` section 1.
Out of scope for this overhaul (listed in `PF_REMAINING_WORK.md` with the reason): a third-party insurance provider
(no insurance system exists to integrate with), real video for bodycams/CCTV (not possible in FiveM), NPC ambulance
crews (AI care stays in the hospital so EMS keeps its role), fire department (not requested).

## 3. Principles (binding for every unit)

1. **One owner per state** (`PF_ARCHITECTURE.md` section 1). Extend the owner; never build a second copy. The only new
   resource is `pf-justice`.
2. **Server truth.** Clients send intents and hints. Positions, health deltas, items, money, roles and timers come
   from the server. Hints are cross-checked and capped (architecture 6.8, 11.5).
3. **No fake features.** Every button does server-checked work. No placeholder that reports success. A feature that
   cannot work yet is not shown.
4. **Money only on the ledger** with stable idempotency keys; unclear results are held, never retried under a new key.
5. **Persistence by design**: every long-lived state is in a migration-created table; clocks are absolute
   timestamps; reconnect and restart resume the same state.
6. **Compatibility**: legacy events and exports stay as forwarders (architecture section 9) until their callers move.
7. **Honest limits**: say what the engine cannot know (architecture section 10) in the UI and docs.
8. **Performance**: no per-frame loops unless drawing; scoped sync; bounded tables (architecture section 8).
9. **Tests with every change**: mocked specs, real-DB specs for SQL, JS specs for UI; each new behaviour has a spec
   that fails without it.
10. **Low population works**: every flow has a defined fallback (AI care, schedule-based bail, unsupervised community
    service, automatic hearings limited to non-punitive outcomes) that never makes the player role pointless.

---------------------------------------------------------------------------------------------------------------------

## 4. How a batch runs (lead procedure)

1. **Base:** the previous batch is committed and both full suites are green (`PF_TEST_REPORT.md` section 2).
2. **Prompts:** one prompt per work unit = `AGENT_CONTEXT.md` + this unit's section + `PF_ARCHITECTURE.md` +
   `PF_DATABASE_MIGRATIONS.md` (the unit's tables). Units of one batch run in parallel.
3. **File ownership:** a unit edits **only** the files listed under "Owns". No two units of a batch share a file.
   Where several units add files to one resource, the unit marked **manifest owner** adds every `fxmanifest.lua`
   line listed for the batch, and the unit marked **schema owner** writes the resource's migration version for the
   whole batch from `PF_DATABASE_MIGRATIONS.md`. The same rule applies to config files: the unit that owns a
   config file adds the blocks the other units of its batch read (names and defaults from `PF_ARCHITECTURE.md`); a
   unit that needs a value nobody listed reads it with a safe default in its own file and reports it. A unit that
   needs a change elsewhere reports it; the lead folds it into a later unit.
4. **Interfaces:** a unit consumes another unit's interface of the same batch **by contract only** (mock it in its
   specs with `Mock.exportsByResource` or a stub global table); it never waits for the other unit.
5. **Checks:** after the units report, a checker agent per unit verifies the acceptance list against the code and
   runs the unit's specs plus the full mocked suite.
6. **Integrate:** run the full mocked and real-DB suites and the JS specs, fix cross-unit seams (lead or a small
   fix-up unit), commit, update `PF_IMPLEMENTATION_PROGRESS.md` and the journal.
7. **Live checks** that need a game client go into `PF_TEST_REPORT.md` section 5 for the in-game campaign.

### 4.1 Test harness facts every unit must respect
- **Mocked harness:** `cd [qb]/tests && node harness.js <filter>`; specs `tests/specs/*_spec.lua`; fengari = **Lua 5.3**.
  FiveM runs 5.4, but code must also parse and run on 5.3: **no `<const>`/`<close>`**. The preprocessor rewrites
  backtick hashes, `?.` and compound assignment line by line.
- `CreateThread`/`SetTimeout` do nothing in the harness: expose every tick as a named function and call it in specs.
- The harness emulates the export boundary (values copied, functions become funcrefs): use a callable check, never
  `type(x) == 'function'`, and re-read a player after a mutating call.
- Migrations: `exports['pfm-core']:RunMigrations(key, list)` is versioned per **key**; the runner refuses a second
  concurrent run of the same key (`'migrations already running'`), so each resource keeps **one schema file** that
  owns its key (`PF_DATABASE_MIGRATIONS.md` section 1). Steps must be rerun-safe (MariaDB DDL auto-commits).
- **Real DB:** `PF_TEST_DB="mysql://root@127.0.0.1:3399" node realdb/run.js <filter>`; specs
  `tests/realdb_specs/*_realdb_spec.lua`, each in a fresh `pf_rt_*` database. Use it for every table and every query.
- **JS:** `node tests/js/<spec>.js` (jsdom); `node --check` every new module.
- **Syntax:** `node tests/parsecheck.js <files>`.
- Never edit `tests/lua/*.lua` (shared mocks); define extra mocks in your spec.
- Spec names for this overhaul: `b<batch>_<area>_<topic>_spec.lua` (e.g. `b15_justice_orders_spec.lua`).

### 4.2 Definition of done for a unit
- Every acceptance item below is met and covered by a spec (or listed as live-only in `PF_TEST_REPORT.md`).
- Unit specs pass; the full mocked suite passes (or failures are proven to be another area's).
- Real-DB specs for every new table/query pass; parsecheck clean; `node --check` clean for JS.
- No client-trusted value, no unkeyed money move, no client state-bag write, no new per-frame loop.
- The report lists files, migrations, interfaces built, interfaces consumed, honest-play notes and live checks.

---------------------------------------------------------------------------------------------------------------------

## 5. Batch overview

| Batch | Theme | Units | Depends on |
|---|---|---|---|
| 15 (**done 2026-11-04**) | Foundations I: owners, storage, core contracts | 15A medical engine core, 15B justice core, 15C custody/booking/property/bail, 15D evidence core, 15E government work orders + budget keys, 15F police MDT migrations, 15G EMS MDT migrations, 15H platform hooks, 15I department core | batch 14 committed |
| 16 | Foundations II: switch runtimes to the owners | 16A server-owned down/death, 16B damage ingestion, 16C prison driven by justice, 16D MDT jail + police jail through justice | 15 |
| 17 | Medical, EMS and hospital features | 17A diagnosis/exam, 17B treatment/items, 17C recovery/effects, 17D EMS equipment, 17E hospital core | 16 |
| 18 | Police field, traffic, equipment, evidence lab, MDT records | 18A custody field flow, 18B traffic/ALPR/impound, 18C equipment/telemetry, 18D evidence lab, 18E cases, 18F warrants/BOLO/gate | 16 (18D also 17 for projectiles) |
| 19 | Justice and corrections features | 19A courts, 19B supervision, 19C community service, 19D prison facility, 19E prison work/economy, 19F prison security, 19G medical in custody | 16, 15E; 19G needs 17E |
| 20 | Hospital/EMS advanced, departments, personnel | 20A pharmacy/lab/imaging/surgery, 20B morgue/ME, 20C supplies/fleet, 20D PCR/units, 20E department management, 20F police personnel/armory | 17, 18, 19 |
| 21 | UI on every device | 21A MDT records pages, 21B MDT custody/evidence pages, 21C EMS tablet/exam/monitor, 21D hospital workstation, 21E corrections MDT, 21F justice apps, 21G department app + shared tokens | 17-20 |
| 22 | Integration, review, docs | 22A end-to-end specs, 22B security/performance review, 22C fix-ups, 22D docs | 21 |

Unit size target: 1-3k changed lines, one strong agent, one session.

---------------------------------------------------------------------------------------------------------------------

## 6. Batch 15: Foundations I (owners, storage, core contracts)

Goal: every new owner exists with its tables, internal API and exports, tested, while the old runtimes still run.
Nothing a player does changes yet except the hooks in 15H and the MDT table creation in 15F/15G.

**Status: done (2026-11-04).** All nine units passed their adversarial checks (15B after 3 rounds, 15C after 4, 15F
after 1 fix; 15A, 15D, 15E, 15I took follow-ups after passing). Latest unit full runs: mocked 2942/0 (272 files),
real DB 806/0 (81 files). Ownership held except two lead-requested edits (15F also changed `server/cctv.lua` and
`server/roster.lua` of pf-policemdt-DEV for the start-up wait) and the lead's own fixes (pf-justice `config.lua`
caller lists, pf-emsmdt `Config.SOP.ForceSeed = false`, pf-citizen `cancelled` bills outcome). Open items:
`PF_REMAINING_WORK.md` section 6; hand-over steps for batch 16+: section 7.

### 15A Medical engine core (pf-ambulancejob)
**Manifest owner and schema owner for pf-ambulancejob in batch 15.**
Owns:
- `[pfscripts]/pf-ambulancejob/fxmanifest.lua`
- `[pfscripts]/pf-ambulancejob/config_medical.lua` (new)
- `[pfscripts]/pf-ambulancejob/shared/medical/anatomy.lua` (new)
- `[pfscripts]/pf-ambulancejob/shared/medical/injuries.lua` (new)
- `[pfscripts]/pf-ambulancejob/shared/medical/physiology_model.lua` (new)
- `[pfscripts]/pf-ambulancejob/shared/medical/effects_model.lua` (new)
- `[pfscripts]/pf-ambulancejob/server/medical/schema.lua` (new; takes over v1 from `injury_database.lua`)
- `[pfscripts]/pf-ambulancejob/server/medical/store.lua` (new)
- `[pfscripts]/pf-ambulancejob/server/medical/engine.lua` (new)
- `[pfscripts]/pf-ambulancejob/server/medical/effects.lua` (new)
- `[pfscripts]/pf-ambulancejob/server/medical/api.lua` (new)
- `[pfscripts]/pf-ambulancejob/server/injury_database.lua` (migration list removed; CRUD kept for legacy callers)
- `[pfscripts]/pf-ambulancejob/sql/pf-ambulancejob-qb.sql` (header: created by migrations; SQL-only tables marked unused)
- `[qb]/tests/specs/b15_medical_models_spec.lua`, `[qb]/tests/specs/b15_medical_engine_spec.lua` (new)
- `[qb]/tests/realdb_specs/b15_medical_store_realdb_spec.lua` (new); `[qb]/tests/realdb_specs/ambulance_injuries_realdb_spec.lua` (adjust to the moved migration)

Provides: exports `GetPatientSummary`, `IsDown` (engine state; metadata wiring is 16A), `ApplyInjury`, `AddToxin`;
server events `consciousnessChanged`,
`injuryAdded`; internal `PFMed.Store`, `PFMed.Engine`, `PFMed.Effects` (architecture 4.1); a listener for
`pfm-smallresources:server:consumed` (15H) that turns alcohol and poisoned food into toxins.
Consumes: `pfm-core` `GetPlayer`, `RunMigrations` (via `@pfm-core/server/migrations.lua`, already in the manifest).
Acceptance:
1. Anatomy and injury catalog cover every structure and category in architecture 11.1/11.2; a spec checks each
   structure id is reachable from at least one region or mechanism and each type has bleed/pain/effects/heal data.
2. `physiology_model` is pure and deterministic: table-driven spec for loss classes I-IV, tension pneumothorax,
   airway obstruction, opioid overdose, and consciousness thresholds (architecture 11.3, 5.1).
3. `effects_model` combines per channel by maximum, never sums (spec with three leg injuries -> walk 3, not 9).
4. `PFMed.Engine.Tick(now)` touches only active patients; a healthy player costs nothing (spec counts store reads).
5. Store: load on `QBCore:Server:PlayerLoaded`, write-behind every 10 s, flush on `playerDropped` and resource stop;
   offline catch-up on load uses absolute timestamps (real-DB spec: save, advance time, reload).
6. Migrations v1 (moved unchanged) + v2/v3 apply on a fresh DB and on a DB that already has v1 (real-DB).
7. Exports enforce `Config.Medical.Callers`; `GetPatientSummary` filters fields per caller.
8. `pfm-core:server:characterDeleted` deletes the character's `pf_med_*` rows.
Size: ~2.5k lines. Depends on: nothing in this batch.
**As built:** done. Findings/diagnoses tables in v3 (not 17C's v5) and `pf_med_patients.hold_until`; added internal `SetConsciousness` with a persisted hold; keyed `AddInjury` refused at the 40-injury cap; RR 14 + 3 x (class - 1).

### 15B pf-justice core: orders, clock, records (new resource)
**Manifest owner, config owner and schema owner for pf-justice in batch 15** (schema v1 holds every table of 15B
and 15C; v2 is the legacy import step that calls 15C's `PFJustice.LegacyImport.Run()`; `config.lua` includes the
`Config.Custody`, `Config.Property`, `Config.Bail` and `Config.Facilities` blocks 15C reads).
Owns:
- `[pfscripts]/pf-justice/fxmanifest.lua`, `config.lua`, `shared/states.lua`
- `[pfscripts]/pf-justice/server/main.lua`, `server/schema.lua`, `server/orders.lua`, `server/clock.lua`,
  `server/records.lua`, `server/api.lua` (all new)
- `[qb]/tests/specs/b15_justice_states_spec.lua`, `b15_justice_orders_spec.lua`, `b15_justice_clock_spec.lua` (new)
- `[qb]/tests/realdb_specs/b15_justice_schema_realdb_spec.lua` (new)

Provides: exports `CreateOrder`, `GetOrder`, `GetOrders`, `GetActiveIncarceration`, `IsIncarcerated`,
`GetJailMinutes`, `AdjustOrder`, `SetOrderState`, `ReleaseNow`, `IssueCitation`, `PayOrder`, `GetRecord`,
`AddRecordEntry`, `Expunge`; server events `orderCreated`, `orderChanged`, `releaseOrdered`, `paymentSettled`;
internal `PFJustice.Orders`, `PFJustice.Clock`, `PFJustice.Records`, `PFJustice.Audit`, `PFJustice.Callers`,
`PFJustice.Actor`, `PFJustice.States` used by 15C.
Consumes: `pfm-prison` `IsInside` through `Config.Facilities[*].presence` (built in 16C; the fallback radius makes the
clock work before that), `@pfm-banking/payouts.lua`, pfm-phone `CreateInvoice` with `ref` (15H), `pfm-core`.
Acceptance:
1. Every state machine of architecture 5.4-5.6, 5.8, 5.12 is data in `shared/states.lua`; a table-driven spec walks
   every allowed transition and asserts a sample of refused ones.
2. `CreateOrder` validates per kind, is idempotent by `opts.key` (`duplicate`, `key_reused`), enforces the caller
   allowlist, writes an order event, and fires `orderCreated` once.
3. Clock: online-only, hybrid and realtime policies; credits/forfeits; presence provider missing -> fallback radius;
   offline completion finishes at next load; `releaseOrdered` fires exactly once (spec drives `PFJustice.Clock.Tick`).
4. Fines: `PayOrder` charges with `pf-justice:order:<id>:pay:<n>`; clear refusal -> invoice with
   `ref = 'pf-justice:order:<id>'`; unclear -> `payment_pending` + sweep via `GetTransaction`; settlement on
   `pfm-phone:server:invoiceSettled` (spec with the real ledger through `ledger_env.lua`).
5. Citations: `IssueCitation` creates an order of kind `citation` plus a `pf_justice_citations` row; contest window.
6. Records: conviction entries on completed sentences; `Expunge` soft-deletes with an audit row.
7. Real-DB: v1 tables created, rerun-safe; unique `idem_key` enforced.
8. `pfm-core:server:characterDeleted`: open orders vacated, records kept anonymised (court history is shared).
Size: ~2.5k lines. Depends on: nothing in this batch (15C builds on its internal API by contract).
**As built:** done after 3 rounds. Extra exports `ContestCitation`, `DecideCitation`; `PayOrder` uses `PFPayout.Transfer`; waiving an invoiced fine goes through pfm-phone `CancelInvoice` (`waiverPending` / `invoiceCancelled`, refund `paymentSettled 'refunded'`); settlement and deletion queues survive a busy lock or a restart; v1 has `pay_from`, `refund_*` and `pf_justice_audit`.

### 15C pf-justice custody, booking, property, bail, legacy import
Owns:
- `[pfscripts]/pf-justice/server/custody.lua`, `server/booking.lua`, `server/property.lua`, `server/bail.lua`,
  `server/legacy_import.lua`, `server/compat.lua` (all new)
- `[qb]/tests/specs/b15_justice_custody_spec.lua`, `b15_justice_property_spec.lua`, `b15_justice_bail_spec.lua` (new)
- `[qb]/tests/realdb_specs/b15_justice_import_realdb_spec.lua` (new)

Provides: exports `OpenCustody`, `GetCustody`, `SetCustodyState`, `BookCustody`, `AssignHoldingCell`,
`AddCustodyLog`, `TransferCustody`, `ReturnCustody`, `ReleaseFromCustody`, `IsInHoldingCell`, `SeizeProperty`,
`GetPropertyReceipt`, `ReturnProperty`, `ForfeitPropertyItems`, `OfferBail`, `AcceptBail`, `DeclineBail`, `GetBail`,
`ExonerateBail`, `ForfeitBail`; `PFJustice.LegacyImport.Run()`; metadata mirrors `injail`/`criminalrecord`
(compat.lua subscribes to order events; JU becomes their only writer once 16C/16D land).
Consumes: 15B internal API; `pfm-policejob` `IsCuffed`/`SetCuffed`; `pfm-inventory` (`GetInventory`,
`ClearInventory`, `AddItem`, `RemoveItem`, `CreateInventory`); `pf-ambulancejob` `GetPatientSummary` (15A, by
contract); PJ `CreateEvidence` (15D, by contract) for `ForfeitPropertyItems`; `PFPayout`.
Acceptance:
1. Custody machine (architecture 5.4) enforced; one open custody per citizen (`conflict`).
2. Reconnect while `arrested`/`in_transport`/`booking`/`held` puts the player back at the facility return point and
   re-cuffs where required (spec fires `QBCore:Server:PlayerLoaded`).
3. Booking: number format, server-read fingerprint/bloodtype, random DNA sample id, `client_supplied` mugshot flag,
   medical screening blocks `down`/`red`/`orange` patients from a holding cell.
4. Property: seize into `pf_justice_property_<receiptId>` with rollback on a failed clear; return without clearing
   the player's current items; leftovers return at next load; receipt lists every item.
5. Bail: payer near the officer or at a desk (server position); keyed transfer; unclear -> `payment_pending`;
   exoneration refund keyed once; forfeiture keeps money.
6. Legacy import (real-DB): rows of `pf_mdt_active_jails` (with and without `released_why`, with bail fields, with
   items JSON) become orders + property receipts, once (rerun imports nothing); offline `players.metadata.injail > 0`
   become `online`-clock orders with `legacy_ref = 'meta_injail:<cid>:<jailid>'`; `jailitems` become a receipt.
Size: ~2.5k lines. Depends on: 15B (contract), 15A/15D (contract).
**As built:** done after 4 rounds. Extra export `GetBooking`; property state `legacy` while the old runtimes run; `AcceptBail` unclear -> `ok = false, payment_unclear`; `BookCustody` steps to booking at a desk; offers expire when custody/order ends; forfeits use evidence method `seizure`.

### 15D Evidence chain-of-custody core (pfm-policejob)
**Manifest owner and schema owner for pfm-policejob in batch 15.**
Owns:
- `[qb]/pfm-policejob/fxmanifest.lua`, `config_evidence.lua` (new)
- `[qb]/pfm-policejob/server/schema.lua` (new; takes over v1 from `server/fines.lua`)
- `[qb]/pfm-policejob/server/fines.lua` (migration list moved; waits on the schema)
- `[qb]/pfm-policejob/server/evidence.lua` (legacy net events now call the module)
- `[qb]/pfm-policejob/server/evidence/store.lua`, `custody.lua`, `scene.lua`, `api.lua` (new)
- `[qb]/pfm-policejob/client/evidence.lua`
- `[qb]/tests/specs/b15_evidence_store_spec.lua`, `b15_evidence_custody_spec.lua`, `b15_evidence_scene_spec.lua` (new)
- `[qb]/tests/realdb_specs/b15_evidence_realdb_spec.lua` (new); `[qb]/tests/realdb_specs/fix14_police_fines_realdb_spec.lua` (adjust to the moved migration)

Provides: exports `CreateEvidence`, `GetEvidence`, `ListEvidence`, `TransferEvidence`, `SealEvidence`, `BreakSeal`,
`LinkEvidence`, `UnlinkEvidence`, `DisposeEvidence`; server events `evidenceCreated`, `evidenceCustody`; the
`ItemMoved` custody recorder; persisted scene drops.
Consumes: `pfm-inventory` `AddListener`, `AddItem`, `GetItemBySlot`; item `evidence_bag` (15H).
Acceptance:
1. Scene drops (`CreateBloodDrop`, `CreateFingerDrop`, `CreateCasing`) are rate-limited (architecture 6.3),
   persisted in `pf_evidence_scene_drops`, sent only to on-duty LEO within 150 m (no `-1` broadcast), and survive a
   restart; decay marks rows `unrecoverable` instead of deleting them.
2. Bagging creates an evidence row + `evidence_bag` item (`info.evidenceId`) from server data; the blood label is a
   random sample id (no reversible citizenid hex).
3. Every move of an `evidence_bag` between inventories writes a custody event with actor and both inventory ids.
4. Integrity score rules (architecture 4.9) computed and returned by `GetEvidence`.
5. `ListEvidence` paged (limit <= 100); exports allowlisted.
6. `/fine` keeps working: `pfm_police_fines` v1 applied once on a DB that already has it (real-DB).
Note: identifying a DNA sample needs the lab (18D). Until then the MDT shows "awaiting lab"; fingerprints keep the
existing station scanner flow.
Size: ~2.5k lines. Depends on: 15H item (contract).
**As built:** done. Per-player drop cap (50 per kind), drawers recognised in any locale, lab/court presence rules (`Config.Evidence.Labs`/`Courts`, placeholder coordinates), a civilian holder counts as a gap. Open: `TransferEvidence` release path, `ClearInventory` not recorded.

### 15E pf-government work orders, keyed budget moves, CreateBill passthrough
**Manifest owner, config owner and schema owner for pf-government in batch 15** (v5 work orders, v6 department core
tables for 15I; `config.lua` gets `Config.WorkOrders` and the `Config.Departments` block 15I reads).
Owns:
- `[pfscripts]/pf-government/fxmanifest.lua`, `config.lua`
- `[pfscripts]/pf-government/server/schema.lua`
- `[pfscripts]/pf-government/server/workorders.lua` (new)
- `[pfscripts]/pf-government/server/infrastructure.lua` (generator hook, effect application)
- `[pfscripts]/pf-government/server/budgets.lua` (optional `key` on society moves)
- `[pfscripts]/pf-government/server/main.lua` (`CreateBill` export passes all arguments)
- `[qb]/tests/specs/b15_gov_workorders_spec.lua` (new)
- `[qb]/tests/realdb_specs/b15_gov_workorders_realdb_spec.lua`, `b15_gov_budget_keys_realdb_spec.lua` (new)

Provides: exports `CreateWorkOrder`, `ListWorkOrders`, `GetWorkOrder`, `ClaimWorkOrder`, `ReportWorkUnit`,
`ReleaseWorkClaim`, `CancelWorkOrder`; event `pf-government:server:workOrderCompleted`; `key` argument on
`SpendFromDepartmentSociety`/`AddFundsToDepartmentSociety`; `corrections` and `doj` budget departments.
Consumes: `pf-services:cityEvent` (existing), `PFPayout`.
Acceptance:
1. Generator creates orders from district thresholds (capped per district) and from configured city events.
2. Claim TTL, one unit per claim, server-position proof inside the site radius, minimum seconds per unit by kind.
3. Completion applies the effect to the district state and persists it (spec reads the saved row); the next
   simulation tick keeps the improvement (incremental drift).
4. Paid orders pay once per worker (`pf-government:wo:<id>:pay:<cid>`); CS claims pay nothing.
5. Budget moves with a key are idempotent (real-DB: the same key twice moves money once); without a key unchanged.
6. `CreateBill` export with `recurring` dedupes (real-DB).
Size: ~1.5k lines. Depends on: nothing.
**As built:** done. v5 adds `pf_gov_work_payments`; v6 adds `state`, `ledger_key`, `attempt_at`, `next_check_at` to budget rows; new error `too_soon`; `weather.severe` orders at a district site; only pf-justice may claim (paid non-CS work has no caller yet).

### 15F Police MDT tables by migrations (pf-policemdt-DEV)
**Manifest owner and schema owner for pf-policemdt-DEV in batch 15.**
Owns:
- `[pfscripts]/pf-policemdt-DEV/fxmanifest.lua`
- `[pfscripts]/pf-policemdt-DEV/server/schema.lua` (new; v1-v6 moved from `sentencing.lua`, v7 the SQL-file tables)
- `[pfscripts]/pf-policemdt-DEV/server/sentencing.lua` (migration list removed; `S.Start` waits on the schema)
- `[pfscripts]/pf-policemdt-DEV/server/sql_init.lua` (deleted: never loaded)
- `[pfscripts]/pf-policemdt-DEV/server/officers.lua`, `server/sop.lua` (ad-hoc CREATE/ALTER moved into the schema)
- `[pfscripts]/pf-policemdt-DEV/server/main.lua` (ESX-only CREATE moved; `pf_mdt_fto_reports_legacy` read guarded)
- `[pfscripts]/pf-policemdt-DEV/sql/pf-policemdt-qb.sql` (header: no manual import needed)
- `[qb]/tests/specs/b15_mdt_schema_spec.lua` (new), `[qb]/tests/realdb_specs/b15_mdt_schema_realdb_spec.lua` (new)
- `[qb]/tests/realdb_specs/fix14_mdtserver_jail_realdb_spec.lua`, `fix14_mdtserver_roster_realdb_spec.lua` (adjust to the moved migrations)

Acceptance:
1. A fresh DB gets every table the code reads (spec greps the server code for `pf_mdt_` table names and checks each
   is created by the schema).
2. A DB where the SQL file was imported by hand migrates with no error and no data change (real-DB: import the SQL
   file first, then run).
3. Existing versions v1-v6 keep their numbers and are not re-applied on an existing install.
4. Seeds (CCTV cameras, templates) use `INSERT IGNORE`.
Size: ~1.5k lines (mostly the port). Depends on: nothing.
**As built:** done after 1 fix (seeds only for tables v7 created). v7 is a function step with `information_schema` checks; `sql_init.lua` deleted; roster and CCTV start-up wait for the schema (lead-requested follow-up).

### 15G EMS MDT tables by migrations (pf-emsmdt)
**Manifest owner and schema owner for pf-emsmdt in batch 15.**
Owns:
- `[pfscripts]/pf-emsmdt/fxmanifest.lua`, `server/schema.lua` (new; v1 moved from `roster.lua`, v2 the ad-hoc tables)
- `[pfscripts]/pf-emsmdt/server/main.lua` (ad-hoc CREATE moved; the broken PCR count query removed)
- `[pfscripts]/pf-emsmdt/server/roster.lua`, `server/officers.lua`, `server/sop.lua`
- `[pfscripts]/pf-emsmdt/sql/pf-emsmdt-qb.sql`
- `[qb]/tests/specs/b15_emsmdt_schema_spec.lua` (new), `[qb]/tests/realdb_specs/b15_emsmdt_schema_realdb_spec.lua` (new)
- `[qb]/tests/specs/emsmdt_legacy_tables_spec.lua`, `[qb]/tests/realdb_specs/fix14_mdtserver_ems_roster_realdb_spec.lua` (adjust)

Acceptance: as 15F for the EMS tables; the configurable roster table name is created by a function step reading
the config; the patient profile callback always answers (no SQL error on a missing PCR table).
Size: ~800 lines. Depends on: nothing.
**As built:** done. No roster-table setting exists, so the table name is fixed (`pf_emsmdt_roster`) inside the v2 function step; legacy police tables are never altered; lead set `Config.SOP.ForceSeed = false`.

### 15H Platform hooks (doorlock, phone, consumables, job garages, jobs, items)
Owns:
- `[qb]/pfm-doorlock/server/main.lua`, `[qb]/pfm-doorlock/config.lua`
- `[qb]/pfm-phone/server/main.lua`, `[qb]/pfm-phone/qb-phone.sql`
- `[qb]/pfm-smallresources/server/consumables.lua`
- `[qb]/pfm-core/shared/jobs.lua`, `[qb]/pfm-core/shared/items.lua`
- `[pfscripts]/pf-jobgarages/server/main.lua`
- `[qb]/tests/specs/b15_hooks_doorlock_spec.lua`, `b15_hooks_consumed_spec.lua` (new)
- `[qb]/tests/realdb_specs/b15_hooks_phone_ref_realdb_spec.lua`, `b15_hooks_jobgarages_realdb_spec.lua` (new)
- `[qb]/tests/specs/sweep_core_doorlock_spec.lua` (adjust if needed)

Provides (architecture 4.13): doorlock `SetDoorState`/`GetDoorState` with `Config.StateCallers`; corrections access
on Bolingbroke doors; pfm-phone `CreateInvoice` `ref` (added through the file's existing `EnsureInvoiceColumns`
column check, plus `qb-phone.sql`); event
`pfm-smallresources:server:consumed`; pf-jobgarages `GetFleetVehicle`/`ListFleet`/`SetServiceState` (migration key
`pf-jobgarages` v1); jobs `corrections`, `doj`, judge/lawyer grades; items `evidence_bag`, `nitrile_gloves`.
Acceptance: each export allowlisted and tested; a duplicate invoice `ref` returns the first id (real-DB); the
consumed event fires only after the server removed the item; job garages' existing flows unchanged (spec).
Size: ~1.2k lines. Depends on: nothing.
**As built:** done. Added (lead request) pfm-phone `CancelInvoice`; door aliases by coordinates; fleet event `serviceStateChanged`; only three Bolingbroke doors exist in the config. Open: `nitrile_gloves.png` missing, grade pay to set.

### 15I Department core (pf-government)
Owns:
- `[pfscripts]/pf-government/server/departments/core.lua`, `qualifications.lua`, `shifts.lua` (new)
- `[qb]/tests/specs/b15_gov_departments_spec.lua` (new), `[qb]/tests/realdb_specs/b15_gov_departments_realdb_spec.lua` (new)

Provides: exports `GetDepartmentOf`, `HasQualification`, `ListQualifications`, `GrantQualification`,
`RevokeQualification`, `GetShift`, `ListShifts`, `LogDepartmentAudit` (architecture 4.12); implied qualifications by
job grade; shift rows from `QBCore:Server:SetDuty`; incarcerated employees forced off duty (`IsIncarcerated`, 15B,
by contract). Manifest lines and v6 tables come from 15E.
Acceptance: implied quals work with no rows; a granted revocation overrides; shifts open/close on duty changes and
drops; audit rows written; allowlists.
Size: ~1k lines. Depends on: 15E (manifest, schema), 15B (contract).
**As built:** done. Follow-ups: escaped (suspended order) employees cannot go on duty; write exports fail closed; `unchanged` stores the key; grants count only in the owning department; `MaxShiftHours` enforced every minute (`max_length`).

**Batch 15 manifest lines** (added by each resource's manifest owner):
- pf-ambulancejob (15A): `shared_scripts` + `config_medical.lua`, `shared/medical/anatomy.lua`, `shared/medical/injuries.lua`,
  `shared/medical/physiology_model.lua`, `shared/medical/effects_model.lua`; `server_scripts` + `server/medical/schema.lua`,
  `server/medical/store.lua`, `server/medical/engine.lua`, `server/medical/effects.lua`, `server/medical/api.lua` (after
  `server/injury_database.lua`).
- pf-justice (15B): a new manifest (`fx_version 'cerulean'`, `lua54 'yes'`); shared `config.lua`, `shared/states.lua`;
  server `@oxmysql/lib/MySQL.lua`, `@pfm-banking/payouts.lua`, then `server/main.lua`, `server/schema.lua`,
  `server/orders.lua`, `server/clock.lua`, `server/records.lua`, `server/custody.lua`, `server/booking.lua`,
  `server/property.lua`, `server/bail.lua`, `server/legacy_import.lua`, `server/compat.lua`, `server/api.lua`;
  `dependencies { 'pfm-core', 'oxmysql', 'pfm-banking', 'pfm-inventory' }`. Migrations go through the export
  `exports['pfm-core']:RunMigrations('pf-justice', list)` (as pf-devices and pf-services do), not the included file.
- pfm-policejob (15D): `shared_scripts` + `config_evidence.lua`; `server_scripts` + `server/schema.lua` (before `server/fines.lua`),
  `server/evidence/store.lua`, `server/evidence/custody.lua`, `server/evidence/scene.lua`, `server/evidence/api.lua`
  (before `server/evidence.lua`).
- pf-government (15E): `server/workorders.lua` (after `server/infrastructure.lua`), `server/departments/core.lua`,
  `server/departments/qualifications.lua`, `server/departments/shifts.lua` (after `server/budgets.lua`).
- pf-policemdt-DEV (15F): `server/schema.lua` (before `server/main.lua`).
- pf-emsmdt (15G): `server/schema.lua` (first after oxmysql).

---------------------------------------------------------------------------------------------------------------------

## 7. Batch 16: Foundations II (switch the runtimes over)

Goal: down/death, injuries, jail and prison now run on the new owners. Old paths become forwarders. This is the
batch with the most player-visible change; its live checklist (`PF_TEST_REPORT.md` 5.1, 5.4) runs before batch 17.

### 16A Server-owned down/death state and legacy medical hardening (pf-ambulancejob)
**Manifest owner for pf-ambulancejob in batch 16.**
Owns:
- `[pfscripts]/pf-ambulancejob/fxmanifest.lua`, `config.lua`, `config_medical.lua`
- `[pfscripts]/pf-ambulancejob/server/main.lua`
- `[pfscripts]/pf-ambulancejob/server/medical/downstate.lua` (new), `server/medical/api.lua`
- `[pfscripts]/pf-ambulancejob/client/dead.lua`, `client/laststand.lua`, `client/main.lua`, `client/job.lua`, `client/wounding.lua`
- `[qb]/pfm-adminmenu/server/server.lua`, `[qb]/pfm-adminmenu/client/client.lua`
- `[qb]/tests/specs/b16_medical_downstate_spec.lua`, `b16_medical_legacy_events_spec.lua` (new)
- `[qb]/tests/specs/pf_ambulance_hardening_spec.lua`, `fix9hq2_ems_downcall_spec.lua`, `citylinks_ems_spec.lua`, `pf_ambulance_bills_spec.lua`, `fix14_core_duty_ems_spec.lua` (adjust)

Provides: `PFMed.Down` (the only writer of `isdead`/`inlaststand`/`pf:down`), revive tokens, net events
`ReportDown`, `ReviveApplied`, `RequestHelp`, `RequestRespawn`, client events `SetDown`, `Revive`; exports `Revive`,
`Kill`; server events `patientDown`, `patientRevived`, `respawned`, `patientDied`; every legacy row of architecture
section 9 marked batch 16.
Consumes: 15A engine; `PFEmsRequests` (existing in `server/main.lua`).
**From batch 15:** use `PFMed.Engine.SetConsciousness(cid, to, cause, opts)` (causes `report`, `rosc`, `revive`,
`respawn`) and pass `opts.holdSeconds` for a reported down (persisted in `hold_until`), otherwise the engine wakes the
patient to `altered` after 10 s; call internal engine functions only for online patients.
Acceptance:
1. A client can no longer clear its own down state (`SetDeathStatus(false)`, `SetLaststandStatus(false)` ignored).
2. `ReportDown` accepted only with server health at or below the threshold (or engine already down); the client
   resurrects only after `SetDown`.
3. Revive needs a server token; the server re-reads health after `ReviveApplied`; a refused revive leaves the player down.
4. `RevivePlayer`: 2.5 m, target down, rules per state (civilian first aid only on `unconscious`); no ban on a
   missing item.
5. `RespawnAtHospital` and `SendToBed`: only when the server says `dead` and the respawn timer passed / the player is
   in the reception zone; inventory wipe and bill as today.
6. `resetHungerThirst`, `SetArmor`, `AddDoctor`/`RemoveDoctor` closed (architecture 9); armour saved from the server.
7. `hospital:GetPlayerStatus` gated (on-duty EMS within 5 m).
8. Movement while down (faster than escort speed, not attached) is logged as an anomaly and re-sends `SetDown`.
9. pfm-adminmenu revive/kill use the exports and close the EMS request.
10. Honest play: the death screen, last-stand crawl, civilian first aid and EMS revive still work (spec drives the
    full flow with mocks).
Size: ~2.5k lines. Depends on: 15A.

### 16B Damage ingestion and plausibility (pf-ambulancejob)
**Schema owner for pf-ambulancejob in batch 16** (v4 import step + anomaly index).
Owns:
- `[pfscripts]/pf-ambulancejob/shared/medical/mechanisms.lua` (new)
- `[pfscripts]/pf-ambulancejob/server/medical/ingest.lua`, `server/medical/legacy_import.lua` (new), `server/medical/schema.lua`
- `[pfscripts]/pf-ambulancejob/server/injury_handler.lua`, `server/injury_database.lua`
- `[pfscripts]/pf-ambulancejob/client/damage_detection.lua`, `client/medical_hints.lua` (new)
- `[qb]/tests/specs/b16_medical_ingest_spec.lua`, `b16_medical_mechanisms_spec.lua` (new)
- `[qb]/tests/realdb_specs/b16_medical_import_realdb_spec.lua` (new)
- `[qb]/tests/specs/ambulance_injury_helpers_spec.lua` (adjust)

Provides: `DamageHint` net event, `weaponDamageEvent` listener (no `CancelEvent` outside configured safe zones),
1 Hz health/armour sampler, 2 Hz velocity sampler (scoped), mechanism rules (architecture 11.5), anomaly rows, the
one-time `player_injuries` import; `processDamage` becomes a hint.
Acceptance:
1. A hint with no server-seen health/armour drop and no attacker event creates nothing (anomaly logged).
2. Severity capped by the observed drop; claimed weapon without attacker event downgraded.
3. Falls: server peak vz -> height bands -> heel/ankle/tibia/femur/pelvis/spine/head per 11.5 (table-driven spec).
4. Vehicle: server speed drop -> delta-v bands; seatbelt claim moves at most one band.
5. Armour coverage stops penetration by class; helmet item protects the head.
6. Samplers touch only the players they need (spec counts natives).
7. Import (real-DB): open `player_injuries` rows become `pf_med_injuries` with `legacy_id`, once.
Size: ~2k lines. Depends on: 15A.

### 16C pfm-prison driven by pf-justice
**Manifest owner and schema owner for pfm-prison in batch 16.**
Owns:
- `[qb]/pfm-prison/fxmanifest.lua` (adds `@oxmysql/lib/MySQL.lua`), `config.lua`
- `[qb]/pfm-prison/server/main.lua`, `server/schema.lua` (new), `server/justice_bridge.lua` (new)
- `[qb]/pfm-prison/client/main.lua`, `client/jobs.lua`, `locales/en.lua`
- `[qb]/tests/specs/b16_prison_justice_spec.lua` (new)
- `[qb]/tests/specs/fix14_prison_server_spec.lua`, `sweep_pol_prison_spec.lua`, `citylinks_prison_spec.lua` (adjust)

Provides: `IsInside`, `GetInmate`, `GetFacilityStatus` (population, lockdown, alarms); intake on `orderCreated`,
release on `releaseOrdered`; `JailPlayer`/`ReleasePlayer`/`GetJailTime` forwarders (allowlist + `pf-policemdt-DEV`,
`pf-justice`); work credits through `AdjustOrder` (key `pfm-prison:credit:<orderId>:<ticket>`); escape suspends the
order (no item forfeiture: the property stays in the JU locker); `JobDone` speed/teleport check (lead carry-over c);
`Config.Prison.KeepJob` (default true: off duty instead of unemployed; owner decision pending).
**From batch 15 (hand-over):** set pf-justice `Config.Compat.LegacyRuntimes.prison = false` in the same change that
turns off pfm-prison's own `jailitems` restore on load (`server/main.lua` ~668), or the items come back twice; intake
uses `SetOrderState(id, 'active')`; gates through pfm-doorlock `SetDoorState` with the `bolingbroke_gate_1..3`
aliases; pfm-prison is already on the JU caller lists. Batch 16 has no pf-justice unit, so the lead assigns the
pf-justice `config.lua` edit (one owner for the 16C and 16D flags).
Acceptance: an MDT- or field-created order puts an online player in the prison and the JU clock counts only inside;
release happens once from the JU event, also for an offline completion at load; escape path unchanged for honest
gate hacks; every old test scenario still passes in its new form.
Size: ~1.8k lines. Depends on: 15B, 15C.

### 16D MDT jail runtime migrated; police jail through pf-justice
Owns:
- `[pfscripts]/pf-policemdt-DEV/server/sentencing.lua`, `client/main.lua`, `config.lua`
- `[qb]/pfm-policejob/server/interactions.lua`, `server/commands.lua`, `client/interactions.lua`
- `[qb]/tests/specs/b16_mdt_justice_spec.lua`, `b16_police_jail_spec.lua` (new)
- `[qb]/tests/realdb_specs/b16_mdt_justice_realdb_spec.lua` (new)
- `[qb]/tests/specs/sweep_mdt_jail_spec.lua`, `mdt_fine_spec.lua`, `sweep_pol_policejob_spec.lua`, `fix14_police_cuffstate_spec.lua`, `citylinks_police_spec.lua`, `citylinks_mdt_spec.lua`, `[qb]/tests/realdb_specs/fix14_mdtserver_jail_realdb_spec.lua` (adjust)

Provides: `createSentence` keeps its presence/custody rules and its `pf_mdt_sentences` row, then calls `CreateOrder`
for fine and jail with keys `pf-policemdt:sentence:<id>:<kind>`; `postBail`/`/bailaccept`/`/baildecline` relay to JU
bail; the MDT jail tick, `S.Jail`, `S.Release` and the MDT `/unjail` are removed (`payment_pending` MDT fines keep
their sweep until drained); MDT un-cuffs through `SetCuffed` when a jail order starts; client `StartMdtSentence`
shows the JU countdown only; BailOffer prompt, bail toast `resp.message`, `allowNegativeBank` line removed (mdt-server
rework leftovers). PJ `police:server:JailPlayer` requires cuffs or a booking zone, opens custody and creates a `jail`
order (`pfm-policejob:jail:<custodyId>`); one `/unjail` (PJ) -> `ReleaseNow`; PJ's uncuff-on-respawn listens to
`pf-ambulancejob:server:respawned` instead of the client net event (lead carry-over a).
**From batch 15 (hand-over):** set `Config.Compat.LegacyRuntimes.mdt = false` and `policejob = false` (the same
pf-justice `config.lua` owner as 16C), relay MDT bail to JU bail, stop the MDT offering imported bails (JU expires
legacy `offered` rows after `LegacyOfferSeconds`), run `LI.Reconcile` so shadow orders become real, and decide where
legacy MDT bail money already in `society:police` is refunded from on exoneration.
Acceptance: no path jails without a JU order; one player cannot hold two incarcerations; an MDT jail survives a
restart through JU; bail pays once; old MDT payment_pending rows still settle.
Size: ~2k lines. Depends on: 15B, 15C, 16A (event name by contract).

**Batch 16 manifest lines** (16A for pf-ambulancejob): `shared/medical/mechanisms.lua` (shared); server
`server/medical/downstate.lua`, `server/medical/ingest.lua`, `server/medical/legacy_import.lua` (after
`server/medical/engine.lua`); client `client/medical_hints.lua`. pfm-prison (16C): `@oxmysql/lib/MySQL.lua`,
`server/schema.lua`, `server/justice_bridge.lua` (after `server/main.lua`). pf-justice: none (no JU unit in 16).

---------------------------------------------------------------------------------------------------------------------

## 8. Batch 17: Medical, EMS and hospital features

### 17A Diagnosis and exam (pf-ambulancejob)
Owns: `[pfscripts]/pf-ambulancejob/shared/medical/findings.lua` (new), `server/medical/diagnosis.lua` (new),
`server/medical/exam.lua` (new), `client/exam.lua` (new), `client/check_injuries.lua`, `client/injury_handler.lua`
(deleted: dead code); `[qb]/tests/specs/b17_medical_exam_spec.lua`, `b17_medical_diagnosis_spec.lua` (new).
Provides: callbacks `exam`, `setDiagnosis`, `getChart`; export `GetMedicalRecord` (privacy rules 6.6, audited reads).
Acceptance: findings by modality and tier with sensitivity (misses produce no finding, never a false one); stored
results reused within 60 s; imaging only in imaging zones with the patient in bed; internal bleeding invisible until
FAST/CT; `/checkinjuries` now opens the exam flow.
Size: ~1.8k. Depends on: 15A, 16B.

### 17B Treatment engine and medical items (pf-ambulancejob)
Owns: `[pfscripts]/pf-ambulancejob/shared/medical/treatments.lua` (new), `server/medical/treatment.lua` (new),
`server/treatment.lua` (legacy forwarder), `server/items.lua` (new), `server/main.lua` (usable-item registrations
moved out, `TreatWounds` forwarder), `client/treatment.lua`, `client/job.lua`; `[qb]/pfm-core/shared/items.lua`
(medical items: `tourniquet, pressure_dressing, hemostatic_gauze, chest_seal, decompression_needle, opa, npa, bvm,
et_tube, oxygen_tank, c_collar, backboard, splint, traction_splint, pelvic_binder, iv_kit, saline_bag, blood_onegative,
txa, morphine, fentanyl, naloxone, epinephrine, aed, burn_dressing, suture_kit, cast_kit, antibiotics, bp_cuff,
pulse_oximeter, stethoscope, penlight, glucometer, thermometer, crutches`); `[qb]/tests/specs/b17_medical_treatment_spec.lua`,
`b17_medical_items_spec.lua` (new), `pf_ambulance_hardening_spec.lua` (adjust).
Provides: callback `treat`, `cprTick`; every action of architecture 11.7 with tier/qual/location/items/preconditions;
civilian first aid; self-use items (bandage, painkillers, ifaks) consumed on the server before any effect.
Acceptance: items consumed before effect (spec where `RemoveItem` returns false -> no effect); scope of practice
enforced; tourniquet time penalty; CPR pauses the arrest timer only while ticks arrive within 1.5 m; defib needs a
shockable cause; dedupe by `req`; legacy `applyTreatment` keys still work from the EMDT panel.
Size: ~2.5k. Depends on: 15A, 16A, 15I (`HasQualification`, implied fallback).

### 17C Recovery, restrictions and functional effects (pf-ambulancejob)
**Manifest owner and schema owner for pf-ambulancejob in batch 17** (v5: treatments, restrictions, hospital core
tables of 17E; **findings and diagnoses already exist from 15A's v3**, so v5 leaves them out or keeps their DDL
byte-for-byte).
Owns: `[pfscripts]/pf-ambulancejob/fxmanifest.lua`, `config_medical.lua`, `server/medical/schema.lua`,
`server/medical/recovery.lua` (new), `server/medical/effects.lua`, `client/effects.lua` (new), `client/wounding.lua`
(legacy loop retired); `[qb]/tests/specs/b17_medical_recovery_spec.lua`, `b17_medical_effects_spec.lua` (new),
`[qb]/tests/realdb_specs/b17_medical_schema_realdb_spec.lua` (new).
Provides: export `GetRestrictions`; stage machine (architecture 5.2), restrictions persisted and re-pushed at load, offline progression,
infection/complications, effect profiles pushed on change; the client applier with no loop when all channels are 0.
Acceptance: offline healing (real-DB: save, advance clock, reload -> recovered); restrictions survive relog; effects
max-per-channel; painkillers never remove structural channels; `no_drive` violation logged by the sampler.
Size: ~1.8k. Depends on: 15A.

### 17D EMS equipment: stretchers, wheelchairs, medbags, loading
Owns: `[pfscripts]/pf-ambulancejob/server/ems/equipment.lua` (new), `client/ems_equipment.lua` (new),
`config_ems.lua` (new); `[qb]/pfm-radialmenu/client/stretcher.lua`, `server/stretcher.lua`, `config.lua` (bin-bag
stretcher retired, radial entries call the new events); `[qb]/tests/specs/b17_ems_equipment_spec.lua` (new).
Provides: `Equipment` net event actions, entity state bags `pf:stretcher`, player `pf:onStretcher`, rig loading via
`SetPedIntoVehicle`, disconnect/entity-deletion safety, medbag stash.
Acceptance: server-spawned props; one stretcher per rig; load/unload distances; patient released safely on pusher
drop, patient drop, rig deletion and resource stop (specs fire `playerDropped`/`entityRemoved`); late joiner sees
the attachment (state bag).
Size: ~1.5k. Depends on: 16A.

### 17E Hospital core: facilities, check-in, triage, beds, admissions, billing, AI care
Owns: `[pfscripts]/pf-ambulancejob/server/hospital/facility.lua`, `admissions.lua`, `beds.lua`, `billing.lua`,
`ai_care.lua` (new), `config_hospital.lua` (new), `client/hospital.lua` (new), `client/main.lua` (old check-in/bed
code removed), `config.lua` (old hospital points forwarded to `config_hospital.lua`);
`[qb]/tests/specs/b17_hospital_admissions_spec.lua`, `b17_hospital_billing_spec.lua` (new),
`[qb]/tests/realdb_specs/b17_hospital_billing_realdb_spec.lua` (new), `[qb]/tests/specs/pf_ambulance_bills_spec.lua` (adjust).
Provides: callbacks `checkIn`, `triage`, `admit`, `discharge`, `transfer`; exports `GetAdmission`, `ListAdmissions`,
`AdmitPatient`, `DischargePatient`, `GetHospitalStatus`, `IsInCare`; itemised bills (charge to `society:ambulance`,
invoice with `ref` on refusal, pending sweep); AI care rules (architecture 4.5.2); server bed occupancy (fixes the
jail-bed and zone-name bugs from the audit).
Acceptance: check-in only in the reception zone; AI mode only below staff threshold and after the wait; bills built
from server records only and paid once (real-DB with the ledger); a discharge writes restrictions and a calendar
follow-up; respawn path admits to the ED with injuries kept.
Size: ~2.5k. Depends on: 15A, 16A, 17C (schema by contract), 15H (`ref`).

**Batch 17 manifest lines** (17C): `config_ems.lua`, `config_hospital.lua`, `shared/medical/findings.lua`,
`shared/medical/treatments.lua`; server `server/medical/diagnosis.lua`, `exam.lua`, `treatment.lua`, `recovery.lua`,
`server/items.lua`, `server/ems/equipment.lua`, `server/hospital/facility.lua`, `admissions.lua`, `beds.lua`,
`billing.lua`, `ai_care.lua`; client `client/exam.lua`, `client/effects.lua`, `client/ems_equipment.lua`,
`client/hospital.lua`; remove `client/injury_handler.lua`.

---------------------------------------------------------------------------------------------------------------------

## 9. Batch 18: Police field, traffic, equipment, evidence lab, MDT records

### 18A Custody field flow (pfm-policejob)
**Manifest owner for pfm-policejob in batch 18.**
Owns: `[qb]/pfm-policejob/fxmanifest.lua`, `config.lua`, `locales/en.lua`, `server/interactions.lua`,
`client/interactions.lua`, `server/custody_field.lua` (new), `client/custody_field.lua` (new);
`[qb]/pfm-core/shared/items.lua` (`zipties`, `ziptie_cutter`, `breathalyzer`, `radar_gun`, `evidence_kit`,
`spike_strip` if missing); `[qb]/tests/specs/b18_police_field_spec.lua` (new), `fix14_police_cuffstate_spec.lua`,
`fix13b_police_search_reach_spec.lua`, `sweep_pol_policejob_spec.lua` (adjust).
Provides: `Surrender`, `Detain`, `Frisk`, `Ziptie`, server-owned escort/vehicle placement (seat chosen by the server),
`Arrest` -> JU `OpenCustody`, custody transfer between officers, release at scene (`ReleaseFromCustody('no_charges')`),
seized property through JU `SeizeProperty`, use-of-force marks to telemetry; fixes from the audit:
`SeizeDriverLicense` no longer wipes other licences, escort/vehicle events `tonumber` their ids; export `GetFieldState`.
Acceptance: civilians keep "drag a cuffed/dead player" by design but cannot detain or frisk; every action within
2.5 m and rate limited; escort state survives the escorting officer dropping (target released).
Size: ~2k. Depends on: 15C.

### 18B Traffic, ALPR, impound records
**Schema owner for pfm-policejob in batch 18** (v4: traffic, impound, telemetry, lab tables of 18B/18C/18D).
Owns: `[qb]/pfm-policejob/server/traffic.lua` (new), `client/traffic.lua` (new), `server/vehicle.lua`,
`client/anpr.lua`, `client/job.lua`, `config_traffic.lua` (new), `server/schema.lua`;
`[qb]/tests/specs/b18_police_traffic_spec.lua` (new), `[qb]/tests/realdb_specs/b18_police_traffic_realdb_spec.lua`
(new), `[qb]/tests/specs/fix14_police_impound_fuel_spec.lua` (adjust).
Provides: radar measure, server ALPR with read log, speed cameras, breathalyzer (AJ ethanol), `RunPlate`,
`GetImpound`, impound records with reason/officer/hold-until/case, plate flags from PMDT (`GetPlateFlags`, cache
refreshed by `plateFlagsChanged`), citations through JU `IssueCitation`, traffic incident records; `IsPlateFlagged`
callback gated to on-duty LEO; ALPR alerts to all `leo`-type jobs.
Acceptance: readings come only from server natives; ALPR scoped by spatial buckets (spec counts work); impound
release still works through `ReleaseImpound`/`FinalizeImpound`; citation creates a JU order once per uid.
Size: ~2.2k. Depends on: 15B (`IssueCitation`), 18F (`GetPlateFlags`, contract), 16B (toxins).

### 18C Equipment, telemetry and the police hardening backlog
Owns: `[qb]/pfm-policejob/server/telemetry.lua` (new), `server/objects.lua`, `client/objects.lua`,
`server/gameplay.lua`, `client/gameplay.lua`, `server/main.lua`, `client/main.lua`, `client/camera.lua`,
`client/heli.lua`, `client/tracker.lua`, `config_equipment.lua` (new); `[qb]/tests/specs/b18_police_telemetry_spec.lua`,
`b18_police_equipment_spec.lua` (new), `fix14_police_spikes_spec.lua`, `fix14_police_alerts_tracker_spec.lua` (adjust).
Provides: telemetry timeline (`MarkTimeline`, `GetTimeline`; recording toggled by a `bodycam` item or rig dashcam),
props spawned by the server with per-officer caps (cones, barriers, tape, lights, riot shield item), K9 sniff search
(server checks drug items; `k9` qualification), drone (bounded radius, logged), GPS: blips sent only to on-duty
`leo`/`ems` (fixes the `-1` broadcast), structured police alerts (lead carry-over d), auth on info callbacks
(`GetDutyPlayers`, `isPlayerDead`, `IsPoliceForcePresent`), `UpdateCurrentCops` rate limit, GSR from the server's
`weaponDamageEvent` attacker record plus casing reports (no self-report), `/cam` static cameras retired in favour of
PMDT CCTV.
Acceptance: no `-1` broadcast of positions; telemetry bounded and batched; every new prop server-spawned and capped.
Size: ~2.2k. Depends on: 18B (schema, contract).

### 18D Evidence lab and evidence features
Owns: `[qb]/pfm-policejob/server/evidence.lua`, `server/evidence/store.lua`, `custody.lua`, `scene.lua`, `api.lua`,
`server/evidence/lab.lua` (new), `client/evidence.lua`, `server/commands.lua`, `config_evidence.lua`;
`[qb]/tests/specs/b18_evidence_lab_spec.lua` (new), `[qb]/tests/realdb_specs/b18_evidence_lab_realdb_spec.lua` (new).
Provides: `SubmitToLab`, `GetLabJob`, `RegisterReferenceSample` (JU booking calls it), ballistics test-fires for seized
weapons, projectile evidence from `pf-ambulancejob:server:projectileRecovered`, lockers per case (stash per locker,
custody events), legacy `filled_evidence_bag` registration at a station terminal; `/takedna` within 2.5 m;
`showFingerprint` LEO-only; `/callsign` validated (commands.lua).
Acceptance: results only from server data (no match without a reference sample); partial quality -> candidates; lab
time and `lab_tech` release; integrity drops on seal breaks and custody gaps.
Size: ~2k. Depends on: 15D, 15C (booking), 17B (projectile event by contract).

### 18E Cases and investigations (pf-policemdt-DEV)
**Manifest owner and schema owner for pf-policemdt-DEV in batch 18** (v8: cases and 18F tables).
Owns: `[pfscripts]/pf-policemdt-DEV/server/cases.lua` (new), `server/schema.lua`, `fxmanifest.lua`;
`[qb]/tests/specs/b18_mdt_cases_spec.lua` (new), `[qb]/tests/realdb_specs/b18_mdt_cases_realdb_spec.lua` (new).
Provides: cases (lead detective, status, notes), links to incidents/reports/evidence/warrants/custody/orders, suspects,
witnesses, victims, statements, leads, assignments, surveillance logs, interview records, court submission
(`exports['pf-justice']:FileCase`, contract 19A; until 19A lands the submission is stored as `ready_for_court`), export
`AttachExternalRecord`; endpoints under `pf_mdt:cases:*`, permissions via `PFMdtAccess.RegisterActions` (18F).
Size: ~2k. Depends on: 18F (helper, contract).

### 18F Warrants v2, BOLO board, plate flags, record audit, gate fixes, CCTV honesty (pf-policemdt-DEV)
Owns: `[pfscripts]/pf-policemdt-DEV/server/records_ext.lua` (new), `server/main.lua`, `server/access.lua`,
`server/cctv.lua`, `config.lua`; `[qb]/tests/specs/b18_mdt_records_spec.lua` (new), `sweep_mdt_access_spec.lua`,
`fix14_mdtserver_access_spec.lua`, `boundary_mdt_spec.lua` (adjust).
Provides: warrants with `suspectCitizenId`, type (arrest/search/bench), server-generated id and expiry, judge review
through JU `RequestWarrantReview` (contract 19A; without a judge resource the warrant stays `pending_approval` unless
`Config.Warrants.SupervisorApproval` lets a grade >= N approve), served-to-custody link, expiry sweep, audited status
changes; BOLO board (people/vehicles, description, last seen, expiry, broadcast to units and ALPR); vehicle flags
whitelisted and synced to `GetPlateFlags`; `pf_mdt_record_audit` for reads/edits of citizens, incidents, reports;
`PFMdtAccess.RegisterActions`; gate fixes from the audit (`updatePlayerStatus`/`updatePlayerCallsign` through the
wrapper, mutating endpoints added to `ACTIONS`, `CreatePanicCall` uses the server position, input caps on
`createWarrant`, `addVehicleFlag`, `removeCitizenFlag`, `createEvidence`); CCTV: recordings removed from config/UI
claims, `getCameraList` registered once; reports no longer auto-approve after 24 h (`Config.Reports.AutoApproveHours = nil`);
the evidence-camera webhook leaves the replicated config: photos are taken with screenshot-basic's server-side
request (`requestClientScreenshot`) and posted by the server from a server-only convar (`set`, not `setr`), so no
client can read the URL (the old webhook must still be rotated by the owner).
Size: ~2.2k. Depends on: 15F.

**Batch 18 manifest lines**: pfm-policejob (18A): `config_traffic.lua`, `config_equipment.lua`, server
`server/custody_field.lua`, `server/traffic.lua`, `server/telemetry.lua`, `server/evidence/lab.lua`, client
`client/custody_field.lua`, `client/traffic.lua`. pf-policemdt-DEV (18E): `server/cases.lua`, `server/records_ext.lua`
(after `server/main.lua`).

---------------------------------------------------------------------------------------------------------------------

## 10. Batch 19: Justice and corrections features

### 19A Courts and warrant reviews (pf-justice)
**Manifest owner, config owner and schema owner for pf-justice in batch 19** (v3 courts, v4 supervision, v5 community
service; `config.lua` gets the `Config.Courts`, `Config.Supervision` and `Config.CommunityService` blocks that 19B
and 19C read).
Owns: `[pfscripts]/pf-justice/server/courts.lua`, `server/warrants.lua` (new), `server/schema.lua`, `fxmanifest.lua`,
`config.lua`; `[qb]/tests/specs/b19_justice_courts_spec.lua` (new), `[qb]/tests/realdb_specs/b19_justice_courts_realdb_spec.lua` (new).
Provides: architecture 4.7.7 exports; court roles (judge, clerk, prosecutor, defender); schedule-based fallback for
arraignment/bail only; decisions create orders through the 15B API; `IsCourtOrderValid`; PMDT `SetWarrantApproval`
calls; citizen notices (`pf-citizen` `SendMail`, `AddCalendarEvent` for hearing dates); GOV expungement path.
Size: ~2.5k. Depends on: 15B, 18F.

### 19B Probation, parole and monitors (pf-justice)
Owns: `[pfscripts]/pf-justice/server/supervision.lua`, `server/monitors.lua` (new);
`[qb]/tests/specs/b19_justice_supervision_spec.lua` (new).
Provides: architecture 4.7.8; appointments with calendar entries, check-ins at a probation office zone, violations as
reports to an officer, never automatic custody; monitor geofence at 0.2 Hz.
Size: ~1.5k. Depends on: 15B, 19A (schema, contract).

### 19C Community service runtime (pf-justice)
Owns: `[pfscripts]/pf-justice/server/community_service.lua`, `shared/cs_tasks.lua`, `client/main.lua`,
`client/community_service.lua` (new); `[qb]/tests/specs/b19_justice_cs_spec.lua` (new),
`[qb]/tests/realdb_specs/b19_justice_cs_realdb_spec.lua` (new).
Provides: architecture 4.7.9: sign-in, task claims on GOV work orders (litter, graffiti, parks, landscaping, public
buildings, potholes, streetlights), server-validated steps, supervisor verification, overdue -> court item.
Acceptance: no unit without a GOV `ReportWorkUnit` success; offline/disconnect keeps progress; no automatic prison.
Size: ~2k. Depends on: 15B, 15E.

### 19D Prison facility operations (pfm-prison)
**Manifest owner and schema owner for pfm-prison in batch 19** (v2 facility, v3 economy, v4 security).
Owns: `[qb]/pfm-prison/server/facility.lua`, `server/schedule.lua`, `server/discipline.lua`, `server/visitation.lua`
(new), `server/schema.lua`, `fxmanifest.lua`, `config_facility.lua` (new); `[qb]/tests/specs/b19_prison_facility_spec.lua`
(new), `[qb]/tests/realdb_specs/b19_prison_facility_realdb_spec.lua` (new).
Provides: intake (uniform, cell assignment by classification), housing log, classification (min/medium/max), daily
routine schedule (counts, meals, yard, work, lock-in) that degrades gracefully at low population (count only when at
least one inmate is online; meals as timed events), headcounts with server presence, discipline with due process
(architecture 5.13), visitation booking and visit room presence, `RecordInfraction`, `SetLockdown`.
Size: ~2.5k. Depends on: 16C.

### 19E Prison work and economy (pfm-prison)
Owns: `[qb]/pfm-prison/server/work.lua`, `server/economy.lua` (new), `client/jobs.lua`, `config_work.lua` (new);
`[qb]/pfm-core/shared/items.lua` (prison items: `prison_uniform`, `commissary_*`, `laundry_bag`, `contraband_*`);
`[qb]/tests/specs/b19_prison_work_spec.lua` (new), `[qb]/tests/realdb_specs/b19_prison_economy_realdb_spec.lua` (new).
Provides: jobs tied to real operations (kitchen meals for inmates, laundry producing clean linen stock for hospital
beds via a stash transfer, maintenance as GOV work orders inside the prison district, electrician kept), earnings
from `society:corrections` into the trust escrow, commissary purchases, limits, restitution share, credits through
`AdjustOrder`, trust paid out at release.
Acceptance: every money move keyed; trust balance reconciles with its keyed rows (real-DB); credits capped.
Size: ~2.2k. Depends on: 19D (schema), 15B.

### 19F Prison security (pfm-prison)
Owns: `[qb]/pfm-prison/server/security.lua` (new), `server/main.lua`, `client/main.lua`, `client/prisonbreak.lua`,
`config.lua`; `[qb]/tests/specs/b19_prison_security_spec.lua` (new), `fix14_prison_server_spec.lua`, `sweep_pol_prison_spec.lua` (adjust).
Provides: doors through pfm-doorlock `SetDoorState` (no online player needed), camera points for the Corrections MDT,
alarms and zones, contraband searches with detection probability (items to JU forfeiture -> evidence), cell and pat
searches, lockdowns, escapes with persistent consequences (order suspended, warrant request to PMDT, classification
raised, recapture resumes the order with a forfeit).
Size: ~2k. Depends on: 15H, 19D.

### 19G Medical in custody (pf-ambulancejob)
**Manifest owner and schema owner for pf-ambulancejob in batch 19.**
Owns: `[pfscripts]/pf-ambulancejob/server/hospital/custody.lua` (new), `fxmanifest.lua`, `server/medical/schema.lua`,
`config_hospital.lua`; `[qb]/tests/specs/b19_medical_custody_spec.lua` (new).
Provides: prison infirmary as a hospital department (beds from the existing `jailbeds`), intake screening, prescriptions
for inmates (pharmacy rows from 20A later; until then the infirmary dispenses from its stock stash), escorted hospital
transfer with custody continuity (`TransferCustody`/`ReturnCustody`, escort officer required within 15 m, leaving the
zone reported), privacy for corrections staff (`fit_for_work` etc.).
Size: ~1.5k. Depends on: 17E, 15C, 16C.

**Batch 19 manifest lines**: pf-justice (19A): server `server/courts.lua`, `server/warrants.lua`,
`server/supervision.lua`, `server/monitors.lua`, `server/community_service.lua` (before `server/api.lua`); shared
`shared/cs_tasks.lua`; client `client/main.lua`, `client/community_service.lua` (first client scripts of the
resource). pfm-prison (19D): `config_facility.lua`, `config_work.lua` (shared); server `server/facility.lua`,
`server/schedule.lua`, `server/discipline.lua`, `server/visitation.lua`, `server/work.lua`, `server/economy.lua`,
`server/security.lua`. pf-ambulancejob (19G): `server/hospital/custody.lua`.

---------------------------------------------------------------------------------------------------------------------

## 11. Batch 20: Hospital/EMS advanced, department management, personnel

### 20A Pharmacy, lab, imaging, surgery (pf-ambulancejob)
**Manifest owner and schema owner for pf-ambulancejob in batch 20.**
Owns: `server/hospital/pharmacy.lua`, `lab.lua`, `imaging.lua`, `surgery.lua` (new), `client/hospital.lua`,
`config_hospital.lua`, `server/medical/schema.lua`, `fxmanifest.lua` (all under `[pfscripts]/pf-ambulancejob/`);
`[qb]/tests/specs/b20_hospital_services_spec.lua` (new), `[qb]/tests/realdb_specs/b20_hospital_services_realdb_spec.lua` (new).
Provides: prescriptions and a controlled-substance dispensing log; lab orders (blood type, CBC, tox, BAC) from engine
state; imaging orders (x-ray, CT) that confirm diagnoses; surgery in OR zones (`surgeon`), retained projectile recovery
-> `projectileRecovered`; ward/ICU stays with bed-hour billing lines.
Size: ~2.5k. Depends on: 17A-17E.

### 20B Morgue and medical examiner (pf-ambulancejob)
Owns: `[pfscripts]/pf-ambulancejob/server/hospital/morgue.lua`, `client/morgue.lua` (new);
`[qb]/tests/specs/b20_morgue_spec.lua` (new).
Provides: morgue intake for characters marked deceased by the owner's rules (permadeath/CK flag through an admin
command; ordinary deaths respawn), autopsy reading the engine's injury history (cause, manner, time-of-death range),
death records, `deathRecorded` -> PMDT `AttachExternalRecord`.
Size: ~1.2k. Depends on: 20A (manifest/schema), 18E.

### 20C Supplies, restock and fleet maintenance
Owns: `[pfscripts]/pf-ambulancejob/server/hospital/supplies.lua`, `server/ems/fleet.lua` (new);
`[qb]/pfm-prison/server/supplies.lua` (new), `[qb]/pfm-prison/fxmanifest.lua`;
`[pfscripts]/pf-government/server/departments/procurement.lua` (new); `[qb]/tests/specs/b20_supplies_fleet_spec.lua`
(new), `[qb]/tests/realdb_specs/b20_supplies_realdb_spec.lua` (new).
Provides: the pf-stores buyer kind `facility` (registered by GOV; buyer ids such as `ems:pillbox`, `corrections:bolingbroke_kitchen`,
`police:mrpd_armory`; account = the department's linked society; delivery by pf-trucking through the normal
supply-order flow); hospital/rig/prison stock drawn from facility stashes; rig restock at a hospital supply room;
fleet maintenance requests as pf-services kind `mechanic.fleet` (new, registered by AJ/PJ/PR) proven by pf-jobgarages
`SetServiceState` + server vehicle health.
Size: ~2k. Depends on: 15H, 20E (contract).

### 20D EMS MDT: PCR, handover, units (pf-emsmdt)
**Manifest owner and schema owner for pf-emsmdt in batch 20.**
Owns: `[pfscripts]/pf-emsmdt/server/pcr.lua`, `server/units.lua` (new), `server/main.lua`, `server/schema.lua`,
`fxmanifest.lua`, `config.lua`; `[qb]/tests/specs/b20_emsmdt_pcr_spec.lua` (new),
`[qb]/tests/realdb_specs/b20_emsmdt_pcr_realdb_spec.lua` (new).
Provides: PCRs auto-charted from AJ events (interventions, vitals snapshots, times), narrative, handover acknowledgement
by the receiving hospital staff, unit status/crew/rig board; patient profile Medical tab reads `GetMedicalRecord`
(fixes the always-empty tab); police leftovers removed from the EMS server.
Size: ~2k. Depends on: 17A-17E.

### 20E Department management (pf-government)
**Manifest owner and schema owner for pf-government in batch 20.**
Owns: `[pfscripts]/pf-government/server/departments/training.lua`, `assets.lua`, `payroll.lua` (new),
`server/apps/department.lua` (new), `server/schema.lua`, `fxmanifest.lua`, `config.lua`;
`[qb]/tests/specs/b20_gov_departments_spec.lua` (new), `[qb]/tests/realdb_specs/b20_gov_departments_realdb_spec.lua` (new).
Provides: training records that grant qualifications, the asset register (serial-tracked equipment: radios, bodycams,
AEDs, rigs' monitors) with issue/return, payroll reports from budget transactions (pay itself stays in the pfm-core
paycheck), department admin app handlers (roster from pfm-management, quals, shifts, assets, procurement, budget view).
Size: ~2k. Depends on: 15I.

### 20F Police personnel, use of force, IA, armory
**Manifest owner and schema owner for pf-policemdt-DEV and manifest owner for pfm-policejob in batch 20.**
Owns: `[pfscripts]/pf-policemdt-DEV/server/personnel_ext.lua` (new), `server/officers.lua`, `server/schema.lua`,
`fxmanifest.lua`; `[qb]/pfm-policejob/server/armory.lua` (new), `[qb]/pfm-policejob/fxmanifest.lua`,
`[qb]/pfm-policejob/client/job.lua`; `[qb]/tests/specs/b20_police_personnel_spec.lua` (new).
Provides: use-of-force and pursuit reports auto-drafted from telemetry (`DraftUseOfForce`), supervisor review chain, IA
complaints (citizen intake through the records portal in 21F), performance reviews, qualification view from GOV,
armory checkout/return against the GOV asset register (fixes the unused `Config.ArmoryWhitelist`).
Size: ~1.8k. Depends on: 18C, 20E (contract).

**Batch 20 manifest lines**: pf-ambulancejob (20A): server `server/hospital/pharmacy.lua`, `lab.lua`, `imaging.lua`,
`surgery.lua`, `morgue.lua`, `supplies.lua`, `server/ems/fleet.lua`; client `client/morgue.lua`. pfm-prison (20C):
`server/supplies.lua`. pf-government (20E): `server/departments/training.lua`, `assets.lua`, `payroll.lua`,
`procurement.lua`, `server/apps/department.lua`. pf-emsmdt (20D): `server/pcr.lua`, `server/units.lua`.
pf-policemdt-DEV and pfm-policejob (20F): `server/personnel_ext.lua`; `server/armory.lua`.

---------------------------------------------------------------------------------------------------------------------

## 12. Batch 21: UI on every device

Shared UI rules (all units): render only inside the given container; escape every server string (`ctx.esc`/`ctx.h`
in pf-devices modules, `escapeHtml`/`safeUrl` helpers in the MDTs); role-based navigation from the server's
permission answer (never hide-only); search/filter/sort on server-paged lists; linking between records by id; autosave
of drafts to the server (not localStorage) for reports/PCRs; validation messages from the server's error codes;
keyboard access (tab order, Enter/Escape, focus outlines); loading, error and empty states for every list; responsive
from the 760x640 tablet window to large computer windows; no decorative screen without an endpoint behind it.
PF visual language: pf-devices `runtime.css` classes (`.pf-app`, `.pf-card`, `.pf-table`, `.pf-badge` ...) plus the
tokens added in 21G for status, triage and vitals colours.

| Unit | Owns | Provides |
|---|---|---|
| **21A** MDT records pages (manifest owner pf-policemdt-DEV) | `[pfscripts]/pf-policemdt-DEV/html/index.html`, `html/app.js`, `html/app-extended.js`, `html/pages/cases.js`, `html/pages/warrants.js`, `html/pages/bolos.js`, `html/pages/citations.js`, `html/pages/vehicles_ext.js` (new), `client/main.lua`, `fxmanifest.lua`; `[qb]/tests/js/b21_mdt_records_pages_spec.js` (new), `fix14_mdtui_xss_spec.js` (adjust) | case, warrant v2, BOLO, citation, impound/ALPR pages; mdt-server rework UI leftovers (licence reason, `licenseActions`, `releasedOnLogin`, `protected_chief` text) |
| **21B** MDT custody, evidence, personnel pages | `[pfscripts]/pf-policemdt-DEV/html/pages/custody.js`, `evidence_coc.js`, `lab.js`, `timeline.js`, `uof.js`, `personnel_ext.js`, `pages_ext.css`, `client/pages_ext.lua` (new); `[qb]/tests/js/b21_mdt_custody_pages_spec.js` (new) | booking/custody/jail record page (JU data, read-only sentence clock), evidence with chain of custody and integrity, lab queue, telemetry timeline (labelled "metadata, not video"), UoF, personnel |
| **21C** EMS tablet, exam, monitor (manifest owner pf-emsmdt) | `[pfscripts]/pf-emsmdt/html/index.html`, `html/app.js`, `html/exam.js`, `html/monitor.js`, `html/pcr.js` (new), `html/injury_panel.js`, `client/main.lua`, `client/injury_integration.lua`, `fxmanifest.lua`; `[qb]/tests/js/b21_ems_pages_spec.js` (new) | exam UI by modality, treatment actions with server results (no always-success), vitals monitor fed by `Monitor` events, PCR editor, Medical tab |
| **21D** Hospital workstation | `[pfscripts]/pf-emsmdt/html/apps/hospital.js`, `html/apps/hospital.css`, `server/hospital_app.lua` (new), `server/devices.lua`; `[qb]/tests/js/b21_hospital_app_spec.js`, `[qb]/tests/specs/b21_hospital_app_spec.lua` (new) | pf-devices module app: reception queue, triage board, bed board, admissions, discharge orders, pharmacy/lab/imaging queues, bills |
| **21E** Corrections MDT | `[qb]/pfm-prison/html/apps/corrections.js`, `html/apps/corrections.css`, `server/apps.lua` (new), `fxmanifest.lua`; `[qb]/tests/js/b21_corrections_app_spec.js`, `[qb]/tests/specs/b21_corrections_app_spec.lua` (new) | population, cells, counts, schedule, infractions and hearings, visits, lockdown, cameras list, trust accounts (read), sentence data from JU |
| **21F** Justice apps | `[pfscripts]/pf-justice/html/apps/court.js`, `cs.js`, `records.js`, `justice.css`, `server/apps.lua` (new), `fxmanifest.lua`; `[qb]/tests/js/b21_justice_apps_spec.js`, `[qb]/tests/specs/b21_justice_apps_spec.lua` (new) | Court app (docket, case, hearing, decision, warrant review), Community Service app (orders, shifts, tasks, supervisor sign-off), citizen records portal (own record, court dates, sentence clock, fines payable, IA complaint intake) |
| **21G** Department app and shared tokens | `[pfscripts]/pf-government/html/apps/department.js` (new), `[pfscripts]/pf-government/fxmanifest.lua`, `[pfscripts]/pf-devices/html/runtime.css` (token additions only; lead-approved exception to the "never edit pf-devices" rule); `[qb]/tests/js/b21_department_app_spec.js` (new), `[qb]/tests/js/pfdevices_runtime_spec.js` (adjust if needed) | department admin app; CSS tokens `--pf-status-*`, `--pf-triage-*`, `--pf-vital-*` |

21A adds the pf-policemdt-DEV manifest lines for 21B's pages (`files`) and `client/pages_ext.lua` (`client_scripts`);
21C adds the pf-emsmdt lines for 21D (`html/apps/hospital.*` in `files`, `server/hospital_app.lua` before
`server/devices.lua`). Depends on: the server batches each page reads.

---------------------------------------------------------------------------------------------------------------------

## 13. Batch 22: Integration, review, docs

| Unit | Owns | Work |
|---|---|---|
| **22A** End-to-end specs | `[qb]/tests/specs/b22_e2e_*.lua`, `[qb]/tests/realdb_specs/b22_e2e_*_realdb_spec.lua` (new only) | Flows: shooting -> injuries -> EMS exam/treat -> rig -> hospital -> surgery -> discharge -> bill; arrest -> booking -> property -> bail or court -> prison -> work credit -> release -> property back; citation -> contest -> court; CS order -> work order -> district improves; escape -> warrant -> recapture; restart in the middle of each |
| **22B** Security and performance review | read-only; writes a findings list for the lead | handler checklist 6.2 over every new net event/callback/RPC; allowlists; statebag strict scan; event collisions (`docs/staging/event_collisions.py`); tick budgets measured with the harness counters |
| **22C** Fix-ups | files assigned by the lead from 22A/22B findings | |
| **22D** Docs | `[qb]/docs/pf_ultimate/*`, `docs/MASTER_IMPLEMENTATION_CHECKLIST.md`, `docs/JOB_LINKS.md`, `docs/FINAL_TEST_PLAN.md`, `docs/IMPLEMENTATION_REPORT.md` (lead) | statuses, links, live test campaign |

---------------------------------------------------------------------------------------------------------------------

## 14. Ownership check (no file in two units of one batch)

The lead runs this before launching a batch: collect every "Owns" path of the batch, sort, and fail on a duplicate.
Paths shared across **different** batches are expected (e.g. `pf-ambulancejob/fxmanifest.lua` is owned by 15A, 16A,
17C, 19G and 20A in turn).
