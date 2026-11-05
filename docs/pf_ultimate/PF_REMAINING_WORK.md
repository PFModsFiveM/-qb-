# PF Ultimate: remaining work, blockers and open decisions

State on 2026-11-04: batch 15 (Foundations I) is built, checked and reworked in the working trees (all nine units
passed their adversarial checks); the lead's final integration run and commit are pending. Batches 16-22 are remaining
work. This file lists what the plan does not settle by itself: blockers, the owner decisions (adopted defaults),
concerns about lead decisions, work outside the plan, the open items batch 15 left, and the hand-over steps later
batches must carry out.

## 1. Blockers

| Blocker | Blocks | Who |
|---|---|---|
| Batch 15 not yet committed (final integration run pending: mocked, real DB, JS, parsecheck, `ledger_parallel`, `sql_install_check`) | starting batch 16 (16A/16C/16D edit files batch 15 touched: pf-ambulancejob, pfm-policejob, pf-policemdt-DEV, pf-justice config) | lead |
| No FiveM server with game clients in the development environment | every row of `PF_TEST_REPORT.md` section 5; the `hitComponent` mapping; health-read timing for `ReportDown`; stretcher/rig behaviour; CEF focus | owner (staging with two clients and an admin) |
| No copy of the live database | verifying the migrations on real data (especially PMDT v7 on a hand-imported schema and the JU import of live jails; both are covered by real-DB specs on synthetic data only) | owner |
| Webhook token in pf-policemdt history and the replicated evidence convar | 18F moves uploads server-side; the old token must still be rotated | owner |
| Placeholder coordinates (evidence lab and court, work-order sites) | the presence rules in 15D and the work-order sites in 15E work against config values nobody has checked in game | owner (confirm in game) |

## 2. Owner decisions (defaults adopted)

The lead **adopted the plan's default for every decision D1-D18** on 2026-11-03 (lead journal), and batch 15 was
built on them. The owner may still overrule one; the "Affects" column says which units would change. Where batch 15
already applied a default, the last column says how.

| # | Decision | Adopted default | Affects |
|---|---|---|---|
| D1 | Jailing and jobs: pfm-prison sets the job to `unemployed` today. Keep the job and force off duty instead? | Keep the job, off duty while incarcerated (`Config.Prison.KeepJob = true`); GOV shifts refuse duty while incarcerated | 16C, 15I. **Applied in 15I:** an employee with an active or suspended JU jail/prison/remand order is put off duty (fails open while pf-justice is down); pfm-prison still sets `unemployed` until 16C |
| D2 | Sentence clock policy: only online time inside counts (both jails do this today), or hybrid/realtime? | `online` for jail/prison; `realtime` for CS deadlines, probation and parole | 15B. **Applied:** `Config.Clock.Policy` (remand `online` too); `hybrid` only by admin override |
| D3 | Field `/jail` without an MDT sentence (summary jail) | Kept, with the MDT's custody rule (cuffed or booking zone) and a JU order; can be turned off (`Config.Justice.AllowFieldJail`) | 16D |
| D4 | Where fines and bail money go | Fines to `society:police` (as the MDT does today) for police-issued orders, court-issued fines to `society:doj`; bail held in `society:doj` and refunded on exoneration | 15B, 15C. **Applied:** `Config.Fines.Accounts` (police sources -> `police`, `court_decision` -> `doj`), `Config.Bail.Account = 'doj'` |
| D5 | Medical debt channel | Hospital bill charged to `society:ambulance`; unpaid -> pfm-phone invoice that cannot be declined (alternative: pf-government bill to the treasury) | 17E |
| D6 | Insurance | None exists in either repo; only config discounts by job type. A real insurer would be a new owner (pf-government or a business) | 17E |
| D7 | New jobs and grades | `corrections` (cadet .. warden), `doj` (clerk, prosecutor, public defender, probation officer, chief), `judge` (magistrate, judge, chief judge), `lawyer` partner grades; pay to be set by the owner | 15H. **Applied:** jobs and grades in `pfm-core/shared/jobs.lua`; **the owner still sets the pay per grade** |
| D8 | Penal code authority | PMDT `pf_mdt_charges` stays the penal code; pf-government laws stay SOP text. Alternative: generate charges from laws (fine/penalty ranges) | none until decided |
| D9 | Permadeath / character kill and the morgue | Ordinary deaths respawn; the morgue/ME flow runs only for characters an admin marks deceased | 20B |
| D10 | Inventory wipe on hospital respawn (`Config.WipeInventoryOnRespawn = true` today) | Unchanged | 16A |
| D11 | Prison intake | Teleport to intake as today; `transport` mode (officers drive the inmate) available by config | 16C |
| D12 | Escape consequences | Order suspended, items stay in the property locker (no forfeiture), warrant request, classification raised, forfeit on recapture. Today pfm-prison forfeits the stored items | 16C, 19F. JU already refuses bail for a suspended order and does not let a late settlement vacate it (15C round 4) |
| D13 | Department management owner (the lead's decisions name budgets in pf-government but not qualifications/shifts/assets) | `pf-government/server/departments/*` (no new resource); MDT staff pages call its exports | 15I, 20E. **Applied in 15I** |
| D14 | Editing pf-devices for shared UI tokens (agents normally may not edit pf-devices) | One lead-approved unit (21G) adds CSS tokens to `pf-devices/html/runtime.css` only | 21G |
| D15 | Who may expunge | Courts (judge decision) and pf-government `records` permission, both through JU `Expunge` with audit | 19A. **Applied in 15B** (`Expunge`: admin, on-duty judge, gov `records` permission); GOV's own hard delete is removed in 19A |
| D16 | Courts suspending licences | Needs a pf-government export (`SetLicenseStatus` exists as a local function, not exported) | 19A + a GOV change |
| D17 | AI care limits | Below 2 EMS on duty and after 180 s wait; x2 time, x1.5 price; AI surgery after 900 s without a surgeon | 17E |
| D18 | Reports auto-approval after 24 h in the police MDT | Turned off | 18F |

## 3. Concerns about the lead's owner decisions (kept as decided)

1. **Clinical and down state in pf-ambulancejob.** The decision is kept. Concern: a job resource becomes the health
   authority for every player, so if pf-ambulancejob stops or errors, nobody can go down or be revived correctly and
   `isdead`/`inlaststand` stall. Mitigation in the plan: the engine (`server/medical/*`) has no dependency on EMS job
   features, loads before them in the manifest, the down state persists in `pf_med_patients` so a restart resumes it,
   and 16A specs cover a resource restart while a player is down. If the owner later wants the engine separable, the
   `server/medical` and `shared/medical` folders are self-contained and can move to their own resource without
   changing the export names (only the resource name in callers).
2. **"MDT jail runtime migrated into pfm-prison/pf-justice".** The plan splits it precisely: pf-justice owns the order
   and the only clock; pfm-prison owns presence ("inside the walls"), intake and release. Concern: a player's
   incarceration then spans two resources. Mitigation: the clock falls back to a configured radius when pfm-prison is
   down, so time never stops, and releases are driven by one JU event.
3. **PCR rows in pf-emsmdt while the treatment log is in pf-ambulancejob.** Kept. Concern: duplicated clinical data.
   Mitigation: PCR entries store only references to AJ treatment/vitals ids plus the typed narrative; AJ remains the
   clinical truth.
4. **Evidence in pfm-policejob while EMS and prison also create evidence.** Kept; cross-resource creation goes through
   allowlisted `CreateEvidence` with idempotency keys (`pf-ambulancejob:projectile:<injuryId>`,
   `pfm-prison:contraband:<searchId>:<n>`).
5. **Community service runtime in pf-justice.** Kept. Note: it makes pf-justice a client resource as well (task
   markers and steps), from batch 19.

## 4. Work outside the batch plan (not scheduled)

| Item | Why not scheduled | Suggested owner |
|---|---|---|
| pfm-drugs -> medical toxins (`AddToxin` on drug use) | pfm-drugs is not in any unit; a small change once the export exists (15A) | a later small unit on pfm-drugs |
| Restaurant catering contract for the prison | Optional; the inmate kitchen covers meals | pf-restaurants + pfm-prison, pf-services kind `restaurant.catering` |
| Vehicle registration per plate (status, expiry) and vehicle insurance | pf-government only bills a fee at purchase; no per-plate record exists; MDT `RunPlate` shows `unknown` | pf-government |
| Aligning government laws with the penal code (D8) | Owner decision | PMDT + GOV |
| Business closure by court order | Owner decision; registry exports exist | GOV + JU |
| Fire department | Not requested | - |
| NPC ambulance crews | Deliberately excluded: AI care stays in the hospital so EMS keeps its role | - |
| Real bodycam/CCTV video | Not possible in FiveM (architecture section 10) | - |
| Importing MDT photo evidence (`pf_mdt_evidence`) into PJ evidence | Optional; cases link both | PMDT |
| `pf_mdt_vehicle_activity` (read, never written) | Write from ALPR hits or remove from the UI (18F/21A decide) | PMDT |
| Removing the legacy client limb code entirely | Kept until the effects applier (17C) is verified in game | AJ, after live tests |
| `police:client:UpdateBlips`-style broadcasts elsewhere | Only PJ's is in 18C; others found later go to a sweep | 22B |
| pf-government budget moves without keys in other callers | 15E added the key; existing callers keep the unkeyed path until each is migrated | GOV |
| A `dot` member job | `dot` is a budget department with no job, so `society:dot` may not exist in pfm-banking (societies come from shared jobs); pothole/road work orders pay from `dot` | owner decides: add a job or change `pay.from` in `Config.WorkOrders.Thresholds` |
| pf-policemdt-DEV `README.md` still tells operators to import the SQL by hand | not owned by 15F; harmless now (v7 creates everything) | 22D docs |

## 5. Items inherited from batch 14 (lead notes) and where they land

| Item | Lands in |
|---|---|
| (a) `RespawnAtHospital` uncuffs on client-reported death | 16A (server down state) + 16D (PJ listens to `pf-ambulancejob:server:respawned`) |
| (b) pfm-phone `CreateInvoice` without an idempotency ref | **Done in 15H** (`data.ref` + `CancelInvoice`) |
| (c) prison `JobDone` trusts position (teleport between spots) | 16C |
| (d) `policeAlert` free text spoofable | 18C (structured alerts) |
| MDT client/UI leftovers from the mdt-server rework (StartMdtSentence timer only, BailOffer prompt, `allowNegativeBank` line, bail toast `resp.message`, licence reason, `licenseActions`/`releasedOnLogin`, `protected_chief` text) | 16D (client parts) and 21A (html parts) |
| Wave 2 items KEYS-2, GAR-4 | Not part of this overhaul; fold into a later batch as the lead decides |

## 6. Open items from batch 15 (from every unit report and checker verdict)

None of these blocks batch 16; each names where it lands. "Minor" means the checker found no money or data at risk.

| Unit | Item | Lands in |
|---|---|---|
| 15A | Two overlapping flushes of one patient on different pool connections could in theory land out of order (minor) | 16A review |
| 15A | `onResourceStop` waits on SQL while the resource stops: check in game that the flush completes (B15-L4) | in game |
| 15A | Penetrating lung entries set `pneumo = true`, which the physiology never reads (only the breathing loss applies) | 17A/17B |
| 15A | `findings`/`diagnoses` tables already exist from v3: 17C's v5 must not redefine them | 17C |
| 15B | The `created` order event is best effort (an order can exist without its `created` row) | 22B |
| 15B | At start `LoadQueues` reloads at most 200 queued settlements; a `settle_queued` (or a deletion queued while JU is not ready) that could not be written lives in memory only until the next retry (theoretical) | 22B |
| 15B | A queued character deletion that runs after the same citizenid was handed out again would close the new character's orders (theoretical: needs the same random id within one tick) | 22B |
| 15B | Remand without minutes never completes by the clock (a court ends it) | 19A |
| 15B | Confirm a pf-government role grants the `records` permission used by `Expunge` | 19A / owner |
| 15C | After an offline MDT release the shadow order stays active (IsIncarcerated true) until the player's next login; players online when pf-justice (re)starts are imported at their next login | ends at 16D |
| 15C | Legacy MDT bail settled after the hand-over sits in `society:police`, but an exoneration refunds from `society:doj` | 16D (move or refund from the right society) |
| 15C | Corrections staff cannot forfeit property to evidence (`CreateEvidence` needs on-duty police); the item safely stays in the locker | 18D / 19F |
| 15C | Reconnecting in `hospital` custody does not place the player anywhere | 19G |
| 15D | `TransferEvidence { kind = 'release' }` from pf-policemdt-DEV reaches disposal without `DisposeEvidence`'s pf-justice-only list; any `courtOrderId` string passes and the call shape does not match `IsCourtOrderValid(ref, purpose, cid)` | 18D + 19A |
| 15D | `pfm-inventory` `ClearInventory` (used by pfm-prison) fires no listener, so that path writes no custody row for an evidence bag | 16C (route through JU property) / 18D |
| 15D | The custody queue lives in memory (a restart in the instant between a listener and processing loses that row); two near-simultaneous moves of one bag can in a rare race apply out of order | 18D |
| 15D | `/takedna` still writes the citizenid hex; the client still reports drops (it cannot frame others: identity comes from the server); a cell can be pre-filled (200 per cell) to block prints there | 18D |
| 15D | `GetEvidence` refreshes the stored integrity without the row lock (the stored column shown by `ListEvidence` can be briefly stale) | 18D |
| 15D | Lab and court coordinates are placeholders (Mission Row forensics `442.17, -996.07, 30.69`, Courthouse `-544.85, -204.40, 38.22`) | owner confirms in game (B15-L8) |
| 15E | Paid (non-CS) work orders have no caller yet: only pf-justice is on the claim/report allowlist | 20E / 21G GOV apps |
| 15E | Work-site coordinates in `Config.WorkOrders` must be verified in game (B15-L15) | owner |
| 15E | Payouts and funding need the societies `dot`, `government`, `corrections`, `doj` in pfm-banking (pfm-banking creates one per shared job at start; `dot` has no job, see section 4); keyed funding of the `government` department itself fails as `same_account` | owner / GOV |
| 15E | After `MaxPayAttempts` (10) clear refusals a payout is `failed` with an audit row and is not paid automatically; an admin must pay it | 20E admin tools |
| 15E | Event orders count toward the same per-district cap as threshold orders; an off-site stretch shorter than the 5 s sampler is not seen | by design |
| 15F | v2 (kept byte-identical) uses MariaDB-only `ADD COLUMN IF NOT EXISTS`, so on MySQL 8 v2 fails and v7 never runs (the project targets MariaDB) | owner if MySQL is ever used |
| 15F | Client callbacks in `server/main.lua` do not wait for the schema (only the first seconds of a brand-new DB); after a failed run nothing retries until a restart | 18F |
| 15F | `pf-policemdt-templates.sql` still uses a plain INSERT (a hand re-import duplicates the example template); `Config.CCTVStaticCameras` is not defined, so the static-camera path is dormant; a code comment about charge descriptions is wrong | 18F / 22D |
| 15G | Officers/notes/bulletins callbacks are not gated on `Ready()`; roster SQL uses `rank` without backticks (reserved in MySQL 8); the `procedure -> procedure_text` rename uses `TEXT NOT NULL` (strict mode with NULL rows would fail; no such rows exist); the manifest does not list `pfm-core` as a dependency (the 5 x 10 s retry covers it) | 20D |
| 15H | `nitrile_gloves.png` is missing in `pfm-inventory/html/images` (broken icon until added) | owner / 22C |
| 15H | Pay for the new job grades (corrections, doj, judge, lawyer) is not set | owner (D7) |
| 15H | A paid or declined invoice row is deleted, which frees its ref: a caller that missed `invoiceSettled` and retries `CreateInvoice` with the same ref creates a second invoice (callers keep their own state; pf-justice does) | by contract |
| 15H | pfm-prison and the bank heist could use `SetDoorState` instead of `updateState` with a player | 16C / 19F |
| 15H | A plate in two job garages: the fleet exports act on the lowest-id active row | 20C |
| 15I | Duty is allowed when pf-justice is stopped or answers `db_unavailable` (fails open, by design); running shifts rely on `orderChanged` for a newly suspended order | by design |
| 15I | A DB outage also hides implied qualifications (fails closed); the sweep DELETEs have no index on `at`/`ended_at` alone (bounded batches) | 22B |
| 15I | No repo spec covered the login-on-duty (`PlayerLoaded`) refusal at the check (the checker's probe showed it works) | 16C/22A |

## 7. Hand-over steps for later batches (carry these into the unit prompts)

| Batch / unit | Step |
|---|---|
| 16A | Wire the engine's `SetConsciousness` (causes `report`, `rosc`, `revive`, `respawn`) to the server down state; **pass `opts.holdSeconds`** for a reported down so the patient does not wake after 10 s (the hold persists in `hold_until`); only call internal engine functions for online patients; emit `respawned`/`patientRevived` as section 4.1 says |
| 16B | Damage ingestion calls `PFMed.Engine.AddInjury` with keys (a keyed request at the 40-injury cap is refused with `conflict`, not merged) |
| 16C | Set `Config.Compat.LegacyRuntimes.prison = false` in pf-justice; **turn off pfm-prison's own `jailitems` restore on load** (`server/main.lua` ~668) in the same change, or items come back twice (JU `LI.ForPlayer` fills the locker and returns them); provide `IsInside` for `Config.Facilities.bolingbroke`; intake with `SetOrderState(id, 'active')`; credits through `AdjustOrder` with `pfm-prison:credit:<orderId>:<ticket>` (capped by `Config.Credits`); escape suspends the order; use `SetDoorState` with the `bolingbroke_gate_*` aliases; D1 `KeepJob` |
| 16D | Set `LegacyRuntimes.mdt = false` and `policejob = false`; **relay MDT bail** (`postBail`, `/bailaccept`, `/baildecline`) to JU `OfferBail`/`AcceptBail`/`DeclineBail`; stop the MDT offering imported bails (JU expires legacy `offered` rows after `LegacyOfferSeconds`, 7 days, once the MDT runtime is off); run `LI.Reconcile` so shadows become real and lockers fill; decide where legacy MDT bail money already in `society:police` is refunded from; PJ `/jail` opens custody and creates a `jail` order; un-cuff through `SetCuffed` when a jail order starts |
| 17C | v5 leaves out `pf_med_findings`/`pf_med_diagnoses` (they exist from v3) or keeps their DDL byte-for-byte |
| 18A | Holding-cell doors through `SetDoorState` (`mrpd_cell_1..3`, `mrpd_cells_main`); PJ opens custody through `OpenCustody` |
| 18B | PJ and PMDT issue citations through JU `IssueCitation` |
| 18D | `RegisterReferenceSample` takes the booking DNA token; `/takedna` stops writing the citizenid hex; gate `TransferEvidence { kind = 'release' }` like `DisposeEvidence`; record `ClearInventory` moves of evidence bags; per-source live cap review |
| 19A | `IsCourtOrderValid(ref, purpose, cid)` and the matching PJ call shape; remand end by the court; GOV `SetLicenseStatus` export; remove GOV's hard delete in favour of `Expunge` |
| 19C | Community service uses `ClaimWorkOrder`/`ReportWorkUnit` (pf-justice is already the only allowed caller) |
| 20E / 21G | A caller for `staff`/`job` claimants so paid work orders can be worked; department admin UI over the 15I exports |

## 8. Exact next steps

1. Lead: final batch-15 integration run (mocked, real DB, JS, parsecheck, `ledger_parallel`, `sql_install_check`,
   state-bag scan, event collisions); fill the placeholders in `PF_TEST_REPORT.md` (Batch 15) and
   `docs/IMPLEMENTATION_REPORT.md` (Batch 15); commit and push both repos.
2. Lead: run the ownership check for batch 16 (plan section 14) and launch 16A-16D with the section 7 steps in their
   prompts.
3. Owner (in parallel): set pay for the new grades; confirm the lab/court and work-site coordinates; add
   `nitrile_gloves.png`; decide on a `dot` job; provide a staging server with clients and a live DB copy.
4. Batch 16 is the riskiest switch (down state, jail, injuries). Run its live checks (`MED-L4..L8`, `POL-L2..L3`,
   `CRT-L1..L2`) and the batch-15 rows (`B15-L*`) on staging before batch 17 if a server with clients exists;
   otherwise continue and mark those rows pending.
5. Continue batches 17-22 in order; batch 18 and 19 may overlap only where the dependency column allows it.
