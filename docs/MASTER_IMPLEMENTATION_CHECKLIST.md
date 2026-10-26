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
| Loans from the treasury, repayment | AWAITING TEST | Default handling (missed repayments) is PARTIAL; see batch log |
| Premises: approved slots, equipment purchases, fixtures | AWAITING TEST | |
| Budgets and district infrastructure simulation | PARTIAL | Department budgets compute district power/water stages, but nothing in the world reacted (no blackout); see batch 8 |
| MDT access to government records (licenses, fines, businesses) | NOT | The MDT reads players and vehicles only; see batch 8 |

## 4. Businesses

| System | Status | Notes |
|---|---|---|
| Registry as shared business record | AWAITING TEST | Employees and permissions still live in each business resource |
| Employee permissions enforced on the server (restaurants, mechanic shops, stores, job bosses) | AWAITING TEST | Sweep fixes |
| Recurring costs (utilities), taxes, fines, closure/reopen | AWAITING TEST | |
| Upgrades and equipment | PARTIAL | Storage equipment changes restaurant capacity; registers and cooking stations do not yet add POS points or stations |

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
| Job garages (permissions, ownership, keys) | AWAITING TEST | Fleet car still usable from the owner's personal garage (decision pending) |
| Mechanic: checkout, work orders, staff, parts via job-business supply orders into `bizstash-<job>` | AWAITING TEST | pf-mechanicjob now starts on staging (ox_lib) |
| Police job: evidence, impound, fines, jail | AWAITING TEST | |
| Police MDT: police-only handlers, records, jail items | AWAITING TEST | The `mdt_seed` command had no permission; fixed in batch 8 |

## 7. Computer and tablet

| System | Status | Notes |
|---|---|---|
| PF Computer Business Manager: real stock, premises, supply orders, wages, stashes | AWAITING TEST | |
| PF Computer government apps through pf-government permissions | AWAITING TEST | |
| PF Tablet: job apps, business list | PARTIAL | No supply orders or stock on the tablet yet; see batch 8 |

## 8. Security

| Item | Status | Notes |
|---|---|---|
| Server-event sweep (~1,150 handlers) | AWAITING TEST | |
| Client-replicated state bags (`sv_stateBagStrictMode`) | PARTIAL | About 20 client writes (`inv_busy`, fuel nozzle); strict mode is off |

## 9. Batch log (newest first)
- **Batch 8 (in progress):** MDT seed command, government records in the MDT, district power to the world, tablet supplies, restaurant equipment effects.

## 10. Latest pushed commits
- `-qb-` main: see `git log -1 origin/main`. At the start of batch 8: 09be222.
- `-pfscripts-` main: at the start of batch 8: d1be559.

## 11. Standalone repositories
- **Which copy is canonical:** pf-government, pf-trucking, pf-computer, pf-policemdt, pf-jobsystem and pf-mechanicjob are older than the canonical copies in `-pfscripts-`.
- **pf-mechanicjob:** its real remote is pf-advancedmechanicjob.
- **Syncing:** see the batch log for whether they were brought up to date.
