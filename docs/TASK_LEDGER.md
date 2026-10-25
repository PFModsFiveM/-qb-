# PF Mods task ledger

The working list for the whole project. Read this first in every session, then `IMPLEMENTATION_REPORT.md`
(the detailed evidence) and `git log` in `[qb]` and `[pfscripts]`.

**Statuses:**
- `VERIFIED`: code in the authoritative resource, callers use it, tests pass, and the runtime part was checked
  where the environment allows (real MariaDB / staging FXServer). The evidence column says what was checked.
- `IN_PROGRESS`, `NOT_STARTED`, `BLOCKED` (with the blocker).
- "Mocked" = fengari harness with fake natives and a fake DB. "Real DB" = throwaway MariaDB 10.4.
  "Staging" = local FXServer with no client connected. **No requirement has been checked with a game client.**

**Where things are:**
- Branch `batch5-security-supply-chain` in `[qb]` (PFModsFiveM/-qb-) and `[pfscripts]` (PFModsFiveM/-pfscripts-, public). Not pushed.
- `[pfscripts]` is the source of truth for pf-* resources (the standalone repos are behind it).
  `[custom]` and `[jobsystem]` are old duplicate copies: not started on staging, never edited.
- Canonical choices: pfm-core, pf-mechanicjob, pf-scoreboard, pf-hud, pf-ambulancejob, pf-emsmdt, pf-policemdt-DEV.
  Removed: pfm-mechanicjob, pfm-scoreboard, pfm-ambulancejob. Not started: pfm-cityhall, pf-governmentwebsiteonly.

**Test commands** (from `[qb]/tests`):
- Mocked: `node harness.js [filter]`
- Real DB: start the throwaway MariaDB on port 3399, then `PF_TEST_DB="mysql://root@127.0.0.1:3399" node realdb/run.js [filter]`
  and `PF_TEST_DB=... node realdb/sql_install_check.js`
- Staging: `docs/staging/server.staging.cfg` (procedure in the report, "Staging run without duplicate resources").

---

## Priority 0: security and runtime blockers

| # | Requirement | Status | Evidence | Next |
|---|---|---|---|---|
| 0.1 | Inventory drops: updateDrop, GetCurrentDrops, snowball, open/hold/create/move | VERIFIED (mocked) | `pfm-inventory/server/main.lua` 390-421; inventory_drops_spec (15), inventory_integrity_spec | Two-client check of carrying/dropping the same bag |
| 0.2 | pf-computer saveProp/deleteProp and prop sync | VERIFIED (mocked, staging load) | b93222e; stores_trucking_ledger_spec | In-game placement check |
| 0.3 | pf-computer supplies:completeOrder and dispatcher | VERIFIED (mocked, real DB) | b93222e; computer orders realdb spec | — |
| 0.4 | pf-trucking AcceptJob lookup | VERIFIED (mocked, real DB) | 28636c1 | — |
| 0.5 | Money paths on the ledger (robberies, jobs, shops, houses, phone, police, vehicles, hospital, MDT, admin, fees) | VERIFIED (mocked; ledger itself on real DB) | Batches 2-5d in the report; 48 mocked spec files | Paycheck (pfm-core) still direct by design; see report 5d |
| 0.6 | Repository-wide sweep of every remote server handler (~1150 in 70 resources) | VERIFIED (mocked) | 2026-10-25: 8 audits, ~120 fixes, each test failing on the old code; suite 681/681; real DB 84/84. See "Sweep results" | Staging start-up with all fixes; open items in the table below |
| 0.7 | Credentials and malware | IN_PROGRESS (user action) | 28 steaxscripts backdoors quarantined (memory note, 2026-10-23); webhook in old pf-emsmdt history reported | You: rotate DB password, webhooks, license key; block the domain |

## Priority 1: runtime and database integrity

| # | Requirement | Status | Evidence | Next |
|---|---|---|---|---|
| 1.1 | Staging config without duplicates, correct order | VERIFIED (staging) | `docs/staging/server.staging.cfg`; 98 resources start | — |
| 1.2 | Missing dependencies | BLOCKED (user) | ox_lib not installed (pf-mechanicjob, illenium-appearance fail); kq_wheeldamage needs its Tebex entitlement; oxmysql outside `resources/` on live | You: install ox_lib, decide on kq_wheeldamage |
| 1.3 | Live server.cfg fixes | BLOCKED (needs your approval) | Report section 6 lists the steps | Apply to a copy, test against a copy of the live DB |
| 1.4 | Migrations: rerun, partial failure, existing data | VERIFIED (real DB, stock schemas) | realdb specs; sql_install_check.js | Run on a copy of the live database |
| 1.5 | Ledger on real MySQL: duplicates, crashes, reconcile, parallel sessions | VERIFIED (real DB) | ledger realdb spec (13); `realdb/ledger_parallel.js` 6 processes in parallel: each key once, exact balances, clean reconcile. It found tx_id clashes reported as failed transfers, fixed in 34addb5 | — |
| 1.6 | One shared-account model with migration | VERIFIED (real DB) | fa08b06; shared accounts realdb spec | — |
| 1.7 | Install SQL files work on a fresh DB | VERIFIED (real DB) | 3b3c378, 1631da1, 7d7e3a3; sql_install_check.js | — |

## Priority 2: business and supply chain

| # | Requirement | Status | Evidence | Next |
|---|---|---|---|---|
| 2.1 | One persistent order lifecycle (create, pay, player supplier/trucker priority, AI fallback, assignment, delivery, exactly-once payout, restart) | VERIFIED (real DB, mocked) | pf-stores `PFOrders`; supply chain realdb spec (20) | In-game trucking run |
| 2.2 | Business ownership, permissions, employees as one shared service | IN_PROGRESS | pf-government `pf_gov_businesses` is the shared registry: restaurants (`restaurant:<id>`, owner from employees), player-owned stores (`store:<id>`), mechanic shops (`mechanic:<job>`) register, report each sale once and stop trading when closed/without power (6f1b81c, d54d863, 1817c58, 15e9229; government_business_realdb_spec 5, store/mechanic mocked tests). Employees/permissions still live in each resource (restaurant roles, store owner, job grades) | Employee records into the registry (UpdateBusinessEmployees) and a read API for pf-computer/tablet/MDT |
| 2.3 | Business accounts and transactions | VERIFIED (real DB) | pfm-banking society accounts on the ledger | — |

## Priority 3: physical deliveries

| # | Requirement | Status | Evidence | Next |
|---|---|---|---|---|
| 3.1 | Persistent pallets with their own stash, server-checked access, restart restore | VERIFIED (real DB, staging load) | pfm-worldobjects v1; pallet persistence in supply chain realdb spec | Two players at one pallet, in game |
| 3.2 | 30-minute grace after unpacking before faster spoilage | VERIFIED (real DB) | Packed deliveries age at the normal rate for 30 min after delivery, then at the outdoor rate until unpacked (pfm-inventory DeliveredInfo; pf-stores passes delivered_at; pf-restaurants stocks with it). 31182bd; restaurants_realdb_spec 'deliveries left packed' | — |

## Priority 4: restaurants

| # | Requirement | Status | Evidence | Next |
|---|---|---|---|---|
| 4.1 | Persistent stock, atomic consumption, server prices/totals, roles, order states, refunds | VERIFIED (real DB) | df8eb0a; restaurants realdb spec (16) | Sweep result for remaining events |
| 4.2 | Freshness by item and storage (fridge, freezer, trunk, glovebox, sun, heat, broken equipment), offline, visible in UI | IN_PROGRESS | Rates and storage rules exist (freshness_spec 28). Restaurant cold storage follows government power: cut = broken_fridge rate (restaurants_realdb_spec 'power cuts'). Nothing yet applies `sunlight`/`hot` or a fridge equipment failure (restaurant fridges are not modelled as equipment) | Decide what sets sunlight/heat (weather? outdoor drops in daytime?) |
| 4.3 | Cooking: stock-backed recipes, doneness, burnt, quality | VERIFIED (real DB) | restaurants realdb spec | In-game cooking check |

## Priority 5: farming

| # | Requirement | Status | Evidence | Next |
|---|---|---|---|---|
| 5.1 | Farming on the shared inventory/stock/order APIs | IN_PROGRESS | New `[pfscripts]/pf-farming` (6346780): persistent plots (migration v1), timestamp growth (offline/restart), server positions, one harvest per plot, market by freshness and seeds on the ledger; business sales via pf-stores suppliers. farming_realdb_spec 14/14 (real DB) | (a) pf-stores `/supplystock` ignores freshness: spoiled produce can be stocked and delivered fresh; carry freshness or refuse stale/spoiled. (b) Staging start check. (c) In-game check of props/keys |

## Priority 6: government

| # | Requirement | Status | Evidence | Next |
|---|---|---|---|---|
| 6.1 | Fines, revenue, tax collection on the ledger | VERIFIED (mocked, staging) | 93be14f, 3aaaf7f | — |
| 6.2 | Registration, transfer, closure, licenses, inspections, utilities shutdown, loans, upgrades, shared with computer/tablet/MDT | IN_PROGRESS | Done: registration of the three business types; business tax on the ledger (no minting); closure and power checks enforced at the point of sale; utility bills -> delinquency -> power cut -> paying the last delinquent bill restores system cut-offs; loans from the treasury (529d354); business_status columns at start. Not done: business licenses required to trade (CheckBusinessLicense is not enforced), inspections linked to restaurant hygiene, ownership transfer synced back to stores/restaurants, upgrades | Decide whether trading needs an active business license (would block every existing business until licensed) |

## Priority 7: other resources

| # | Requirement | Status | Evidence | Next |
|---|---|---|---|---|
| 7.1 | Mechanics: parts via supply orders, checkout on the ledger | IN_PROGRESS | checkout on the ledger (2g); car save events fixed (a145539) | Sweep result; parts supply |
| 7.2 | pf-jobgarages: business fleets, fail-open permissions, ownership/keys | IN_PROGRESS | Fail-open keys check fixed, ownership/grade/distance enforced (ee43911, sweep_jobs_jobgarages_spec) | Decide how a fleet car is blocked from its owner's personal garage; on-duty rule |
| 7.3 | Trucking: priority, AI fallback, persistence, exactly-once | VERIFIED (real DB) | 2.1 | — |
| 7.4 | Police MDT data from authoritative sources with permissions | IN_PROGRESS | In the sweep (mdt group) | — |
| 7.5 | Stale qb-core references, broken exports, duplicate event names | IN_PROGRESS | `docs/staging/event_collisions.py`; staging start-up clean apart from 1.2 | Rerun the scan after the sweep |

---

## Sweep results (0.6), 2026-10-25

| Group | Status | Commits | Found, not fixed (decision or later) |
|---|---|---|---|
| rob (robberies, side jobs) | done | 9005fcf, 27b9fee, 427c1d2, 4a3ee5a; weed 8da5632 | hotdog quality/price from client (P2; `hotdog` item never given, play-test); recycle/pawnshop permanently ban on one distance miss (lag risk, policy decision); thermite StopFires any player (P2); newsjob gear per plate (P2); drugs delivery re-yield after 2 h (economy) |
| mdt (pf-policemdt-DEV) | done | 9202e1a, d2e9ebd | sentence/jail any online citizen without proximity (design); grade 4+ can reseed roster (permission decision); built-in jail timer is client-side; UI JS not fully XSS-audited (18k lines) |
| pol (police, prison, management, multichar, apartments, admin) | done | 4d90d39, 2db1416, d5c586f, 53e529c, 3896a3e, e7def91 | handcuff status client-driven (redesign); escape detection distance only; SyncSpikes rebroadcasts client table (police only, capped); /reportr never works (ace compare bug) |
| jobs (pf-jobs, jobgarages, outfitbag, tablet, scoreboard, elevator, hud) | done | 877aba6, ee43911, 1b8d753, 5f8c5b8, ffb522a | pf-tabletuionly cash register sends a client total to pf-computer DepositSale (P0 if ever loaded; no manifest today); Gruppe6 stop distance unchecked (would break gruppe6_stash_spec positions); a fleet car can still leave its owner's personal garage (needs a state decision); jobgarages no on-duty requirement, min_grade_manage unused; taxi rating from client (P2); group payouts 1.5x each (economy) |
| mech (pf-mechanicjob) | done | c5dc441, 0aa16d9, 1bd4789 | offline hiring by citizen id no longer works; parts fitted before a restart return no item; work-order minimum time tunable; attemptRepair and setLiftState/clutch flow lack job/distance checks (P2); service history readable for any plate (P2); first service:addEntry handler always errors; pf_business_employees roles not split by shop; locations table global; coal/smoke particle relays broadcast client net ids; diagnosticReport/requestTow pass client cost to unhandled events |
| veh (phone, houses, banking, crypto, vehicle shop/sales, garages, keys, fuel) | done | 5fd0f87, 3810209, 1ef03d5, 5712bf2 | phone Cancel/AnswerCall any number; UpdateMessages lets the sender rewrite the stored chat (redesign); GetWebhook exposed if ever set; /bill amount uncapped, no duty check; bank withdraw/deposit without ATM proximity (ATMs are props); can_manage members grant themselves anything; refuel anywhere at base price; syncGarage house entries; vehicle sale mods from client; lockpick/hotwire success client-decided |
| biz (government, restaurants, computer, stores, trucking, rentals) | done | 529d354, 346b355, ba7c604, b3db99f, 211feb0; supplier freshness b94751f | `civilians` permission only for the Mayor (assign to roles in config); loan cap 1,000,000 default; **every purchasable store has price = 0 (free to claim)**; restaurant newOrder/station events broadcast to all clients with citizen ids; stored restaurant roles skip duty; website:saveState any government grade; bill:create no cap; pf-computer domain list shows owner cids, double-buy race, website state size, records-only numbers; pf-garageuionly (not running) open lookups; pf-governmentwebsiteonly has the free bill:pay (keep it disabled) |
| core (pfm-core, inventory, weapons, doorlock, misc) | done | ea579d9, 87df51d, 6ad640a, 9c85296, 98bfa25 | pfm-bankrobbery/pfm-prison send unlockAnyway from the client: call GrantDoorAccess server-side when a hack succeeds (their door ids don't exist in Config.DoorList today); lockpick minigame client-side; ToggleDuty from anywhere (needs duty locations); pf-jobs/pf-tablet register QBCore:ToggleDuty/OnJobUpdate as broadcasting net events (P2); vending location from client; vehicle class from client (0-22 clamped); lap times bounded only from below |

## Session log

- **2026-10-25:** ledger created. pf-farming added (5.1). Ledger parallel test + tx id fix (1.5). Loose ends fixed (billing mails, pf-mechanicjob save events, SQL files). Started the 0.6 sweep.
