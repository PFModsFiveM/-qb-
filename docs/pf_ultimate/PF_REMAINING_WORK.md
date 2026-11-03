# PF Ultimate: remaining work, blockers and open decisions

State on 2026-11-03: audits, research and the architecture are done; no overhaul code exists yet. Everything in the
batch plan (`PF_ULTIMATE_SYSTEM_PLAN.md`, batches 15-22) is remaining work. This file lists what the plan does not
settle by itself: blockers, decisions for the owner, concerns about lead decisions, and work outside the plan.

## 1. Blockers

| Blocker | Blocks | Who |
|---|---|---|
| Batch 14 not yet committed (working trees hold uncommitted security fixes; checks still running for some areas) | starting batch 15 (units edit the same files: pfm-policejob, pfm-prison, pf-policemdt-DEV, pf-ambulancejob) | lead |
| No FiveM server with game clients in the development environment | every row of `PF_TEST_REPORT.md` section 5; the `hitComponent` mapping; health-read timing for `ReportDown`; stretcher/rig behaviour; CEF focus | owner (staging with two clients and an admin) |
| No copy of the live database | verifying the migrations on real data (especially PMDT v7 on a hand-imported schema and the JU import of live jails) | owner |
| Webhook token in pf-policemdt history and the replicated evidence convar | 18F moves uploads server-side; the old token must still be rotated | owner |
| Owner decisions in section 2 | the units named next to each decision | owner |

## 2. Open decisions for the owner

Each has the plan's default (what units build if no answer arrives) and the unit it affects.

| # | Decision | Default in the plan | Affects |
|---|---|---|---|
| D1 | Jailing and jobs: pfm-prison sets the job to `unemployed` today. Keep the job and force off duty instead? | Keep the job, off duty while incarcerated (`Config.Prison.KeepJob = true`); GOV shifts refuse duty while incarcerated | 16C, 15I |
| D2 | Sentence clock policy: only online time inside counts (both jails do this today), or hybrid/realtime? | `online` for jail/prison; `realtime` for CS deadlines, probation and parole | 15B |
| D3 | Field `/jail` without an MDT sentence (summary jail) | Kept, with the MDT's custody rule (cuffed or booking zone) and a JU order; can be turned off (`Config.Justice.AllowFieldJail`) | 16D |
| D4 | Where fines and bail money go | Fines to `society:police` (as the MDT does today) for police-issued orders, court-issued fines to `society:doj`; bail held in `society:doj` and refunded on exoneration | 15B, 15C |
| D5 | Medical debt channel | Hospital bill charged to `society:ambulance`; unpaid -> pfm-phone invoice that cannot be declined (alternative: pf-government bill to the treasury) | 17E |
| D6 | Insurance | None exists in either repo; only config discounts by job type. A real insurer would be a new owner (pf-government or a business) | 17E |
| D7 | New jobs and grades | `corrections` (cadet .. warden), `doj` (clerk, prosecutor, public defender, probation officer, chief), `judge` (magistrate, judge, chief judge), `lawyer` partner grades; pay to be set by the owner | 15H |
| D8 | Penal code authority | PMDT `pf_mdt_charges` stays the penal code; pf-government laws stay SOP text. Alternative: generate charges from laws (fine/penalty ranges) | none until decided |
| D9 | Permadeath / character kill and the morgue | Ordinary deaths respawn; the morgue/ME flow runs only for characters an admin marks deceased | 20B |
| D10 | Inventory wipe on hospital respawn (`Config.WipeInventoryOnRespawn = true` today) | Unchanged | 16A |
| D11 | Prison intake | Teleport to intake as today; `transport` mode (officers drive the inmate) available by config | 16C |
| D12 | Escape consequences | Order suspended, items stay in the property locker (no forfeiture), warrant request, classification raised, forfeit on recapture. Today pfm-prison forfeits the stored items | 16C, 19F |
| D13 | Department management owner (the lead's decisions name budgets in pf-government but not qualifications/shifts/assets) | `pf-government/server/departments/*` (no new resource); MDT staff pages call its exports | 15I, 20E |
| D14 | Editing pf-devices for shared UI tokens (agents normally may not edit pf-devices) | One lead-approved unit (21G) adds CSS tokens to `pf-devices/html/runtime.css` only | 21G |
| D15 | Who may expunge | Courts (judge decision) and pf-government `records` permission, both through JU `Expunge` with audit | 19A |
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
| pf-government budget moves without keys in other callers | 15E adds the key; existing callers keep the unkeyed path until each is migrated | GOV |

## 5. Items inherited from batch 14 (lead notes) and where they land

| Item | Lands in |
|---|---|
| (a) `RespawnAtHospital` uncuffs on client-reported death | 16A (server down state) + 16D (PJ listens to `pf-ambulancejob:server:respawned`) |
| (b) pfm-phone `CreateInvoice` without an idempotency ref | 15H |
| (c) prison `JobDone` trusts position (teleport between spots) | 16C |
| (d) `policeAlert` free text spoofable | 18C (structured alerts) |
| MDT client/UI leftovers from the mdt-server rework (StartMdtSentence timer only, BailOffer prompt, `allowNegativeBank` line, bail toast `resp.message`, licence reason, `licenseActions`/`releasedOnLogin`, `protected_chief` text) | 16D (client parts) and 21A (html parts) |
| Wave 2 items KEYS-2, GAR-4 | Not part of this overhaul; fold into a later batch as the lead decides |

## 6. Exact next steps

1. Lead: finish batch 14 (checks, reworks), run the full suites, commit, push, and record the counts in
   `PF_TEST_REPORT.md` section 2.
2. Owner (can run in parallel): answer D1-D18, at least D1, D2, D4, D7, D12, D13 before batch 15/16 prompts are
   final; provide a staging server with clients and a live DB copy for the 16-batch live checks.
3. Lead: run the ownership check for batch 15 (plan section 14), then launch 15A-15I in parallel with prompts built
   from `AGENT_CONTEXT.md`, the unit section, `PF_ARCHITECTURE.md` and the unit's tables in
   `PF_DATABASE_MIGRATIONS.md`.
4. After batch 15: checker agents per unit, full suites, commit; update `PF_IMPLEMENTATION_PROGRESS.md` (statuses and
   journal) and section 4 of `PF_TEST_REPORT.md`.
5. Batch 16 is the riskiest switch (down state, jail, injuries). Run its live checks (`MED-L4..L8`, `POL-L2..L3`,
   `CRT-L1..L2`) on staging before starting batch 17, if a staging server with clients is available; otherwise
   continue and mark those rows pending.
6. Continue batches 17-22 in order; batch 18 and 19 may overlap only where the dependency column allows it.
