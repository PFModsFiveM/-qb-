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
| Live `server.cfg` (enable pfm-core/[qb], connection string, remove duplicates) | BLOCKED | Needs the owner, on a copy, with a copy of the live database |
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

## 3. Government

| System | Status | Notes |
|---|---|---|
| Roles and permissions, NUI router identity | AWAITING TEST | Router sets the real sender |
| Taxes (sales, business revenue tax on the ledger) | AWAITING TEST | |
| Bills, fines, payment from the payer | AWAITING TEST | |
| Business registry (restaurants, stores, mechanic shops), closure, power enforcement at sale | AWAITING TEST | |
| Ownership transfers driving store/restaurant owners | AWAITING TEST | Mechanic shops are job-owned |
| Licenses | AWAITING TEST | Record only, not required to trade (owner decision) |
| Inspections on the government record (restaurants) | AWAITING TEST | |
| Utility bills, auto-pay from the business account, delinquency, cut-off, restore | AWAITING TEST | |
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
| Job garages (permissions, ownership, keys, fleet cars job-only) | AWAITING TEST | Owner decision 2026-10-26: a fleet car comes out of the job garage only; pfm-garages hides it, refuses it and its impound fee; it must be parked to join a fleet |
| Mechanic: checkout, work orders, staff, parts via job-business supply orders into `bizstash-<job>` | AWAITING TEST | pf-mechanicjob now starts on staging (ox_lib) |
| Police job: evidence, impound, fines, jail | AWAITING TEST | |
| Police MDT: police-only handlers, records, jail items | AWAITING TEST | `/mdt_seed` is admin-only and off by default (`Config.AllowSeedCommand`) |

## 7. Computer and tablet

| System | Status | Notes |
|---|---|---|
| PF Computer Business Manager: real stock, premises, supply orders, wages, stashes | AWAITING TEST | |
| PF Computer government apps through pf-government permissions | AWAITING TEST | |
| PF Tablet: job apps, business list, Business Manager | AWAITING TEST | Business Manager reads the real registry and the player's supply orders (batch 8). Ordering and unpacking stay on PF Computer |

## 8. Security

| Item | Status | Notes |
|---|---|---|
| Server-event sweep (~1,150 handlers) | AWAITING TEST | |
| Client-replicated state bags (`sv_stateBagStrictMode`) | PARTIAL | About 20 client writes (`inv_busy`, fuel nozzle); strict mode is off |

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
- **Open:** state-bag strict mode (owner, needs refactor first).

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
