# PF Mods master implementation checklist

**How to use this list:**
- **Purpose:** this is the master list for the framework overhaul. Detailed evidence per item is in `TASK_LEDGER.md` and `IMPLEMENTATION_REPORT.md`; the test campaign is in `FINAL_TEST_PLAN.md`.
- **Read it first:** a new session starts here, then checks `git log` on `main` in both repositories.

**Statuses:**
- **NOT** – not implemented.
- **PARTIAL** – partially implemented.
- **ISOLATED** – implemented but not integrated with the systems it depends on.
- **AWAITING TEST** – implemented and integrated, awaiting the comprehensive test phase. Most have mocked and/or real-database tests, but none has been run with a game client.
- **BLOCKED** – needs a specific missing dependency or access.
- **VALIDATED** – fully validated in the final test phase. Nothing is VALIDATED yet: no FiveM client test has been done.

**Repositories:**
- `PFModsFiveM/-qb-`: framework and pfm-* resources.
- `PFModsFiveM/-pfscripts-`: the canonical pf-* resources.
- The standalone pf-* repositories are older copies (see section 11).

## 1. Foundation and deployment

| System | Status | Notes |
|---|---|---|
| Staging start order without duplicate resources | AWAITING TEST | `docs/staging/server.staging.cfg`; 102 resources start on the local FXServer with ox_lib |
| Dependencies (oxmysql, ox_lib + cfxlua-require, PolyZone, menuv) | BLOCKED (live) | Verified on staging; missing on the live server. kq_wheeldamage needs its Tebex entitlement |
| Live `server.cfg` (enable pfm-core/[qb], connection string, remove duplicates) | BLOCKED | Needs the owner, on a copy, with a copy of the live database. Batch 13: also delete `[standalone]/progressbar` and `[voice]/pma-voice` (patched copies start from [qb]) |
| Versioned migrations (`pf_schema_migrations`) | AWAITING TEST | Rerun-safe; tested on stock schemas, not on a copy of live data |
| Install SQL files on a fresh database | AWAITING TEST | `tests/realdb/sql_install_check.js` |
| Credentials rotation after the malware incident | BLOCKED | Owner action: DB password, webhooks, license key |

## 2. Money and banking

| System | Status | Notes |
|---|---|---|
| Shared ledger (`PFLedger.Transfer`, idempotency keys, recovery, reconciliation) | AWAITING TEST | Real-DB tested, including truly parallel sessions |
| One shared-account model (legacy `bank_accounts` shared + `bank_accounts_v2` IBAN) | AWAITING TEST | Migration v5 moves legacy shared accounts once; balances preserved |
| Payouts, charges, refunds for jobs, robberies, shops, houses, phone, police, vehicles, hospital, MDT, admin, fees | AWAITING TEST | `PFPayout`; one remaining direct path by design: the pfm-core paycheck |
| Business accounts (society) and transaction history | AWAITING TEST | |
| Fail closed when banking is down | AWAITING TEST | e2e spec |
| Cash only where the player stands: bank counters (5 m) and listed ATMs (4 m, bank card, withdrawals only) | AWAITING TEST | Batch 13 owner decision. 76 sourced ATM points (esx_atm GPL-3.0, vRP MIT); an unlisted ATM refuses until added (`/atmcheck`). The ATM PIN is still checked only in the UI |
| `PFPayout.Charge` stops on an unclear result instead of trying the next account | AWAITING TEST | Batch 13; returns `res.unclear`. Batch 13b: `/fine` sends no invoice on an unclear charge; fuel, vehicle sales and the tow deposit no longer charge again. Still a new key per click: car wash, truck robbery, rentals, taxi, farming, App Store, revive. The tow deposit retry can still charge cash and bank (open) |

## 3. Government

| System | Status | Notes |
|---|---|---|
| Roles and permissions, NUI router identity | AWAITING TEST | Router sets the real sender |
| Taxes (sales, business revenue tax on the ledger) | AWAITING TEST | |
| Bills, fines, payment from the payer | AWAITING TEST | Batch 13b: a payment applies only what is still due and refunds the rest |
| Late fees: once per bill, a share of the original amount | AWAITING TEST | Batch 13b: 10% of the original amount, 1 day after the due date, once (`LateFeeMaxCount`). Every bill already overdue gets one fee on the first hourly run. The Bills app does not say the amount includes a fee |
| Weekly property tax (0.5% of house value, minimum $50, one bill per house per week) | AWAITING TEST | Batch 13 owner decision. `bill_type 'tax'`, unique `(bill_period, bill_ref)`; delinquent like other bills (this suspends licenses); no repossession. Batch 13b: late fees once per bill; the Fines app lists and waives property-tax bills; the run waits until pfm-houses is ready |
| Business registry (restaurants, stores, mechanic shops), closure, power enforcement at sale | AWAITING TEST | |
| Ownership transfers driving store/restaurant owners | AWAITING TEST | Mechanic shops are job-owned |
| Licenses | AWAITING TEST | Record only, not required to trade (owner decision) |
| Inspections on the government record (restaurants) | AWAITING TEST | |
| Utility bills, auto-pay from the business account, delinquency, cut-off, restore | AWAITING TEST | Batch 13b: houses are billed to the owner citizen (`utility:property:<house>`) and paid in Bills; waiving the last delinquent bill restores a cut the system made. House power cuts have no effect in game yet; pfm-houses' transfer should call `RegisterProperty` |
| Loans from the treasury, repayment, missed payments, default | AWAITING TEST | Batch 9: interest and installments each due date, auto-pay, default after `Config.Loans.DefaultAfterMissed`; real-DB tested |
| Premises: approved slots, equipment purchases, fixtures | AWAITING TEST | |
| Budgets and district infrastructure simulation | AWAITING TEST | Power stages now switch the lights off for players in a cut district (batch 8); water/roads stay in the simulation and its exports |
| MDT access to government records (licenses, fines, businesses) | AWAITING TEST | Citizen profile, Licenses tab (batch 8). Vehicle profiles do not show government data |

## 4. Businesses

| System | Status | Notes |
|---|---|---|
| Registry as shared business record, with employees | AWAITING TEST | Batch 9: `GetBusinessEmployees` asks each business's staff source (restaurants, job members, owner); permissions stay in each business |
| Employee permissions enforced on the server (restaurants, mechanic shops, stores, job bosses) | AWAITING TEST | Sweep fixes |
| Recurring costs (utilities), taxes, fines, closure/reopen | AWAITING TEST | |
| Upgrades and equipment | AWAITING TEST | Storage raises capacity; bought registers open the POS and grill/fryer stations cook (batch 9). Other slot types (office, locker, delivery bay) are only fixtures |

## 5. Supply chain, restaurants, freshness

| System | Status | Notes |
|---|---|---|
| One order lifecycle (stores, restaurants, job businesses): pricing, payment, duplicates, cancellation, AI and player suppliers, trucker priority, AI delivery | AWAITING TEST | End-to-end real-DB spec over the real resources |
| Supply order money: freight on top (paid by the buyer), supplier markup at delivery, case sizes in one place, cancel refunds retried under new keys | AWAITING TEST | Batch 13 owner decision on freight. Batch 13b: settlement and freight on numbered keys; a payee gone for good is refunded to the buyer or held (`pf_supply_order_payouts`, `/supplyheld`); a cancel refund ends `forfeited`; Order Supplies shows the totals. pf-trucking `payContract` still retries one key |
| Minimum goods for a trucker delivery (`MinDeliveryGoods`) | AWAITING TEST | Batch 13b: default is the freight minimum ($250 stores, $150 restaurants and job businesses); below it a delivery is refused, a pickup is not. pf-restaurants' own screen shows the raw error code |
| Persistent pallets with own stash, sealed contents, unpack once, restart restore | AWAITING TEST | |
| Restaurant ordering from PF Computer | AWAITING TEST | |
| Cooking: stock-backed, all-or-nothing, doneness, burnt, quality, dish freshness | AWAITING TEST | |
| POS: server prices, customer acceptance, tax, refunds once | AWAITING TEST | |
| Freshness: offline, storage rates, fridge/freezer, trunk/glovebox, sunlight on drops, power cuts, 30-minute delivery grace, batch-aware stacking | AWAITING TEST | The `hot` rate is unused (owner decision pending) |
| Farming (pf-farming) and player suppliers | AWAITING TEST | Supplier stock refuses stale food |

## 6. Jobs, garages, mechanic, police

| System | Status | Notes |
|---|---|---|
| Job payouts and completion checks (taxi, bus, tow, garbage, recycle, diving, vineyard, pawnshop, Gruppe6, prison, robberies) | AWAITING TEST | Sweep; garbage crews now actually paid |
| Job garages (permissions, ownership, keys, fleet cars job-only) | AWAITING TEST | Owner decision 2026-10-26: a fleet car comes out of the job garage only; pfm-garages hides it, refuses it and its impound fee; it must be parked to join a fleet. Batch 13b: a listed car can't join a fleet; repossession ends the fleet entry. pfm-garages' fleet lookup still fails open |
| Mechanic: checkout, work orders, staff, parts via job-business supply orders into `bizstash-<job>` | AWAITING TEST | pf-mechanicjob now starts on staging (ox_lib) |
| Police job: evidence, impound, fines, jail | AWAITING TEST | |
| Police MDT: police-only handlers, records, jail items | AWAITING TEST | `/mdt_seed` is admin-only and off by default (`Config.AllowSeedCommand`) |
| Mechanic tow billing (boss only, broken car nearby), repairs not undone by old wear reports, NOS saved in order | AWAITING TEST | Batch 13. Batch 13b: cooldown only after a request, every refusal explained, one broken-car rule for server and client; the 30 s save can't write pre-repair wear |
| Bus spawn lock, Gruppe 6 early end paid by share, tow return after leaving the job | AWAITING TEST | Batch 13; a return-only Tow app for former drivers. Batch 13b: Gruppe 6 leavers cleared, lost bags written off, the bag recount registered as a net event; former drivers collect owed tow pay |
| Used lot (no financed, impounded or fleet cars; take-back keeps the loan), `/transfervehicle` fleet and finance rules, accept by offer id | AWAITING TEST | Batch 13. Listing and sell-back need OneSync. Batch 13b: fleet checked at purchase too, inside the claim; listings send only UI columns |
| Vehicle sale settlements: owed payouts and refunds retried, unclear charges held | AWAITING TEST | Batch 13b (`pfm-vehicleshop/settlements.lua`, used by both resources): owed rows retried every 60 s on numbered keys; a held sale finishes (car in `Config.DeliveryGarage`) or releases its reservation. No staff tool for `review`, `forfeit` or `stuck` rows |
| Dealer commission out of the dealership's share | AWAITING TEST | Batch 13 owner decision: dealership gets price minus commission, salesperson the commission |
| Fuel level owned by the server (only the driver drains it; refuels only through the server) | AWAITING TEST | Batch 13. Batch 13b: the first level comes from `player_vehicles.fuel` (else 100); garage spawns name their row; the garage save is clamped; pumps sell only at stations and `Config.ExtraPumps`. Open: fleet cars' stored fuel is never updated, and police impound releases are client-spawned |
| Cruise control indicator in pf-hud | AWAITING TEST | Batch 13. Batch 13b: speed held through turns again |

## 7. Computer and tablet

| System | Status | Notes |
|---|---|---|
| PF Computer Business Manager: real stock, premises, supply orders, wages, stashes | AWAITING TEST | |
| PF Computer government apps through pf-government permissions | AWAITING TEST | |
| PF Tablet: job apps, business list, Business Manager | AWAITING TEST | Business Manager reads the real registry and the player's supply orders (batch 8). Ordering and unpacking stay on PF Computer |

## 7b. Devices, news, government field work, job links (batch 10)

| System | Status | Notes |
|---|---|---|
| App platform for both devices (`pf-devices`): registry, access rules, RPC, pushes, App Store, websites, launchers | AWAITING TEST | Mocked, real-DB and jsdom runtime tests |
| Tablet and computer as shells; job, mechanic, MDT, trucking apps from the platform | AWAITING TEST | The tablet's hardcoded job wiring is gone |
| City events and service requests (`pf-services`), Dispatch / Services / Directory apps | AWAITING TEST | Real-DB: escrow, racing workers, verification, refunds, expiry |
| News (`pf-news`): City Desk presets, leads, newsroom, bonuses, ads, News app + news.ls | AWAITING TEST | Reporter grades 0-4 added to pfm-core |
| Government field apps and City Hall Requests; delivery zones in supply orders | AWAITING TEST | |
| Job links (see `JOB_LINKS.md`) | AWAITING TEST | Candidates listed there |
| Citizen apps (`pf-citizen`): mail, bills, documents, calendar on phone, tablet, computer | AWAITING TEST | One mailbox in `player_mails`; government bills via `PayBillFromPlayer` (refunds what it cannot apply); phone invoices via pfm-phone exports |
| Computer without fake data (job board, business manager, persistence, security fixes) | AWAITING TEST | Restaurants hire through pf-restaurants `AddStaff` (batch 11) |
| pf over pfm duplicates | AWAITING TEST | Removed: pfm-cityhall, pfm-hud, pfm-taxijob, pfm-garbagejob (batch 10); pfm-busjob, pfm-towjob, pfm-recyclejob, pfm-vineyard (batch 11). Kept: pfm-shops, pfm-garages, pfm-newsjob (no complete pf version) |
| Police and EMS MDT inside the tablet and computer (1:1, same page) with their dispatch | AWAITING TEST | Requests from pf-services land on the MDT dispatch board |
| EMS person-down calls opened by the server and closed with the patient's request | AWAITING TEST | Batch 13. Batch 13b: a call made during a logout is closed, a returning patient gets the call back, a citizen's medic call closes on logout, and police MDT calls close with their request |
| Dispatch: one job rule (Benny's and Beeker's waypoints), government requests need the pf-government permission | AWAITING TEST | Batch 13. Batch 13b: the permission is read from pf-government (`GetRequestPermission`) |
| Documents: only the owner hands out links, others mail a copy, signed documents survive the owner's delete | AWAITING TEST | Batch 13. Batch 13b: copies carry the signatures as a record; received copies have their own cap (100); no orphan copy when a mail fails |
| Phone invoices: one ledger token per invoice, paid exactly once across a crash | AWAITING TEST | Batch 13 added the token. Batch 13b: a 'paying' state, numbered keys per step and a sweep every 2 minutes; unverified charges wait; unknown businesses refused. Open: character delete removes 'paying' rows (pfm-core), and Bills still lists them (pf-citizen) |
| Job Board after a pf-services restart, boss-only supply pickup, announcement days and category | AWAITING TEST | Batch 13. Batch 13b: one pickup run per order |

## 7c. Every framework system as a device app (batch 11)

| System | Status | Notes |
|---|---|---|
| Business Manager, Order Supplies, Job Board shared on both devices | AWAITING TEST | The tablet's own Business Manager removed; lock screen and layout stored on the server |
| Bank, Crypto, Boss apps; robbed branch closes | AWAITING TEST | Real-DB: transfers once, daily limit, statements, society money, closures |
| Garages, Real Estate, Car Dealer, Used Cars apps | AWAITING TEST | Real-DB: depot fee once, agent and dealer sales with commission once, finance payments |
| pf-jobs Bus and Tow complete; pfm-busjob and pfm-towjob removed | AWAITING TEST | Bus distance pay needs the depot bus |
| Recycling and Vineyard in pf-jobs; Pawn Shop and Crafting apps | AWAITING TEST | Wine and grape juice are restaurant supplies; scrap is a mechanic supply |
| Crew pay splits, Gruppe 6 upgrades, truck-robbery hold, job-garage on-duty rule | AWAITING TEST | |
| Character deletion cleans every resource's own rows | AWAITING TEST | `pfm-core:server:characterDeleted` |
| Restaurant dishes as real food and drink | AWAITING TEST | Through pfm-smallresources consumables |

## 8. Security

| Item | Status | Notes |
|---|---|---|
| Server-event sweep (~1,150 handlers) | AWAITING TEST | |
| Client-replicated state bags (`sv_stateBagStrictMode`) | AWAITING TEST | Batch 13: on in staging. No client in [qb] or [pfscripts] writes replicated state (scan spec, which now covers the copies). progressbar and pma-voice run as patched copies in [qb], from the owner's BigLeagueQB snapshot of 2025-10-19 (the live copies may differ). Live: delete `[standalone]/progressbar`, `[voice]/pma-voice` and `[custom]` (old pf-mechanicjob) before turning it on. Batch 13b did not take up the batch 13 checker's three small points (progressbar LICENSE, voice mode names, push-to-talk on a channel switch) |
| Inventory search lock and action-lock TTL | AWAITING TEST | Batch 13: the search ends on close, logout, disconnect and another inventory; TTL 1–600 s. Batch 13b: the reach is fixed before the wait (police 2.5 m, admin menu exempt); TAB frees a stale search; the target's windows close and the lock is taken before the wait |

## 9. Batch log (newest first)
- **Batch 8 (2026-10-26):**
  - MDT seed flag;
  - government records in the MDT;
  - district power in the world;
  - tablet Business Manager on real data.
- **Batch 9 (2026-10-26):**
  - restaurant equipment effects;
  - loan servicing and defaults;
  - registry employees;
  - standalone repositories synced.
- **After batch 9:** job fleet cars only from the job garage (owner decision).
- **Batch 10 (2026-10-31, branch `main-9hq3gi`):**
  - one app platform for the tablet and the computer;
  - city events and job-to-job requests;
  - news run by the news job;
  - government field apps on the tablet;
  - job links (`JOB_LINKS.md`);
  - citizen apps;
  - computer clean-up.

  See `DEVICES_AND_SERVICES.md` and the report.
- **Batch 11 (2026-10-31, branch `main-9hq3gi`):**
  - shared business apps;
  - bank, crypto, boss, garages, real estate, dealer and used-car apps;
  - bus, tow, recycling and vineyard in pf-jobs (pfm versions removed);
  - character-deletion cleanup;
  - state bags written by the server in our resources.
- **Batch 12 (2026-10-31, branch `main-9hq3gi`):** fixes from the pre-merge review (`REVIEW_main-9hq3gi.md`):
  - Gruppe 6 contracts finish;
  - character deletion refused while loaded or in debt, and cleans stores, government, restaurants, mechanic diagnostics, phone, trunks and news;
  - police impounds replace other tows and apply when untowed;
  - service payments only on proof; no cancel after acceptance;
  - announcements need the permission;
  - website saves, NOS, tow rental, news vehicles, App Store and phone invoices;
  - strict state bags back off until progressbar and pma-voice are patched.
- **Batch 13 (2026-11-01, branch `main-9hq3gi`):** the remaining review findings and six owner decisions (`-qb-` 80f97db, `-pfscripts-` 28ff205):
  - bank cash only at a counter or a listed ATM; `PFPayout.Charge` stops on unclear results;
  - weekly property tax;
  - supply orders: freight on top, markup at delivery, case sizes, refund retries;
  - dealer commission from the dealership's share; used lot and transfers refuse fleet and financed cars;
  - documents, phone invoice tokens, EMS calls, Dispatch, Job Board, supply pickup, inventory search;
  - fuel, cruise, mechanic tows, wear and NOS, bus, Gruppe 6, tow return;
  - patched progressbar and pma-voice in [qb]; strict state bags on in staging.

  Checker gaps are handled in batch 13b (see the report).
- **Batch 13b (2026-11-01, branch `main-9hq3gi`):** the gaps the batch 13 checkers found (`-qb-` 734fd96, `-pfscripts-` 95987df):
  - phone invoices: a 'paying' state, numbered keys per step, a sweep; `/fine` without an invoice on an unclear charge;
  - inventory search bound before the wait; TAB frees a stale search;
  - fuel: first level from the server, pumps only at stations, garage save clamped; cruise holds through turns;
  - supply orders: numbered settlement keys, terminal states for payees that are gone, `MinDeliveryGoods`, totals in Order Supplies, one pickup per order;
  - EMS calls on logout and reconnect, police MDT calls close with their request, one permission list;
  - vehicle settlements (owed payouts, held sales), fleet checks at purchase and fleet add;
  - Gruppe 6 leavers and lost bags, tow owed pay, mechanic tow refusals, wear save order;
  - document copies with a signature record and their own cap, late fees once per bill, house utility bills, property tax in the Fines app.
  - export boundary: the test harness now copies values and passes funcrefs across resources like FiveM; fixed pf-devices app handlers from other resources (refused before), pf-services request hooks, pfm-core function migrations, the police MDT access wrapper, jail, licences and bank charge, and smaller copy bugs in pf-mechanicjob, pfm-crafting, pfm-crypto, pfm-hotdogjob, pfm-management and pfm-weapons.

  Open items are listed in the report (batch 13b).

## 10. Latest pushed commits
- **`-qb-` main:** 09be222 at the start of batch 8; then the batch 8 docs and code. See `git log -1 origin/main`.
- **`-pfscripts-` main:** d1be559 at the start of batch 8; b97b392 after batch 8; 874d8a0 after batch 9.

## 11. Standalone repositories
- **Canonical copies:** the canonical copies are in `-pfscripts-`.
- **Synced in batch 9** to `-pfscripts-` 874d8a0, each as one new commit on its `main` with no force-push:
  - pf-government b152085;
  - pf-computer c4d3054 (main first fast-forwarded to its Work-In-Progress branch);
  - pf-policemdt dee6767;
  - pf-stores c11ffc4;
  - pf-trucking 4850833;
  - pf-advancedmechanicjob 1d49c1e (canonical pf-mechanicjob).
- **pf-guidebook:** already identical.
- **Not synced:**
  - **pf-jobsystem:** its code moved into pf-jobs and pf-tablet, and the local copies are stubs, so a sync would have wiped the repo.
  - **The old pf-mechanicjob repository:** a separate, stale WIP project.
- **Before the sync:** every file version in those repositories was checked against `-pfscripts-` history, so nothing newer was overwritten.
