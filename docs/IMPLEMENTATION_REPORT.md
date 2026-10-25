# PF Framework Overhaul — Implementation Report

Maintained per batch. Newest batch first. Earlier UI/gameplay rounds are in `../_REBUILD_REPORT.md`.

---

## Batch 1 — 2026-10-24: Baseline, security, inventory integrity, freshness

### Baseline (recorded before any change)

| Repository | Local path | Branch | Commit | Uncommitted files at start |
| --- | --- | --- | --- | --- |
| PFModsFiveM/-qb- (public) | `resources/[qb]` | main | `66ffada7` | 0 |
| PFModsFiveM/-pfscripts- (public) | `resources/[pfscripts]` | main | `b8bee2a8` | 9 |
| pf-computer (private) | `[pfscripts]/pf-computer` | Work-In-Progress | `0cb4a2fb` | 9 |
| pf-government (private) | `[pfscripts]/pf-government` | main | `a171de60` | 14 |
| pf-jobsystem (private) | `[pfscripts]/pf-jobs` and `[pfscripts]/pf-tablet` | main | `077278b5` | 39 / 29 |
| pf-advancedmechanicjob (private) | `[pfscripts]/pf-mechanicjob` | main | `930a594a` | 62 |
| pf-policemdt (private) | `[pfscripts]/pf-policemdt-DEV` | main | `6085b811` | 11 |
| pf-stores (private) | `[pfscripts]/pf-stores` | main | `955e72e3` | 9 |
| pf-trucking (private) | `[pfscripts]/pf-trucking` | main | `71053c00` | 4 |
| pf-guidebook (private) | `[pfscripts]/pf-guidebook` | main | `3bef0f94` | 5 |

Existing uncommitted work in the nested repositories was left untouched; this batch added edits to two of them (listed below) and committed nothing.

### Runtime environment findings (blockers, not code)

- `server.cfg` has `#ensure [qb]`, `#ensure pfm-core` and the MySQL connection string commented out: the framework is not running on this server today.
- **oxmysql and ox_lib do not exist anywhere on disk.** pfm-core, pfm-inventory, pf-government, pf-stores, both MDTs and ~200 query sites require oxmysql; pf-mechanicjob, dolu_tool and oxtest require ox_lib. `ensure ox_lib` in server.cfg currently fails.
- There is no `qb-core` resource. pfm-core is the only core.

### Security audit

Confirmed, fixed in this batch:

| Finding | Where | Status |
| --- | --- | --- |
| Remote-code loader (steaxscripts campaign) still on GitHub as a `shared_script` | pf-computer, remote branch `Work-In-Progress` (`html/js/v2_settings.js`, added in `c8371a2`) | Fixed. Security-only commit `dedaaf4` (removes only the file and its manifest line) pushed to `origin/Work-In-Progress` on 2026-10-24 as a fast-forward from `0cb4a2f`; the branch tip no longer contains the loader. It remains in history at `c8371a2` — never check out older commits of that branch on a server. |
| Discord webhook token committed in config, and shipped to every client via a shared script | `[pfscripts]/pf-policemdt-DEV/config.lua` (2 commits in history), plus `[custom]` copies of pf-policemdt and pf-emsmdt | Moved to convars `pf_mdt_evidence_webhook` / `pf_emsmdt_evidence_webhook`. **The token must be rotated** — it remains in git history. |
| Drop items rebuilt from the client's item table (forged `info`, weight, label) — e.g. a forged `markedbills.worth` became launderable money | pfm-inventory `createDrop` | Fixed: dropped item is rebuilt from the server's slot copy; client only chooses slot + amount. |
| Any client could move any drop anywhere (`updateDrop`, no checks; nil id crashed) | pfm-inventory | Fixed: server-tracked carrier (`holdDrop` with proximity), position taken from the server's view of the carrier. |
| Shop purchases passed client-supplied `info` into `AddItem` (forged attachments, serials, freshness) | pfm-inventory `attemptPurchase` | Fixed: shop's own record is used; malformed requests rejected. |
| Free hunger/thirst: `addHunger`/`addThirst` trusted a client total, no food needed | pfm-smallresources | Fixed: server-issued, single-use, 30 s grants created only when the server consumed a real item. |
| Item loss on failed moves (remove-then-add, no rollback) | pfm-inventory `SetInventoryData` | Fixed: every failure path restores the removed items and resyncs the client. |
| Unique items destroyed when dropped onto a same-named unique item | pfm-inventory | Fixed: such moves swap. |
| `AddItem` overwrote a different item in an explicit slot; accepted 0/negative/NaN amounts; shared one `info` table across stacks | pfm-inventory | Fixed. |
| `RemoveItem` with a negative amount reported success and grew the stack; nil amount crashed | pfm-inventory | Fixed. |
| pf-computer's config executed inside pf-tablet replaced pf-tablet's whole server `Config` (`Config = {}`) | `[pfscripts]/pf-tablet/server/apps/business.lua` | Fixed: sandboxed environment. |

Verified clean / historical:

- No copies of the known loader signature remain in any resource folder (all hits were `node_modules` build tooling or the reports). The `[qb]` history match is the report text itself.
- `check_update.lua` files are benign version checks (fetch JSON, print).
- 11 quarantined loaders from the earlier incident are still in quarantine.

Unconfirmed, high risk (not changed):

- `[santa-fuegos]/__internal_ragemodding_cdn_01`: a map resource shipping obfuscated **client and server** Lua (custom VM, encrypted strings), unauditable by text scan. Disabled today via `#ensure [santa-fuegos]`. Do not enable unless re-obtained from the vendor and verified.
- Four map manifests reference missing files (`amb-ragsriches-lslive-map/startup.lua` in `[rnr]` and `[rags]`, `amb-ragsriches-script/ipl_loader.lua`). They are not in the quarantine log; a server-side `startup.lua` in a map fits the loader pattern, and the antivirus may have removed them. Remove the references or restore from the vendor.

### Compatibility strategy

- **Canonical core is pfm-core.** No PF-owned resource still calls `exports['qb-core']` (verified tree-wide). Remaining `'qb-target'` / `'qb-inventory'` strings are configuration selectors that each resource maps to pfm-* internally. No `provide 'qb-core'` alias was added: nothing needs it, and export aliasing through `provide` could not be verified without an FXServer.
- **Duplicate resources** — these names are loaded from more than one ensured folder; which copy runs depends on scan order. Canonical copies and what to disable:

| Resource | Canonical | Disable | Copies identical? |
| --- | --- | --- | --- |
| pf-jobs | `[pfscripts]` | `[jobsystem]` | yes |
| pf-tablet | `[pfscripts]` | `[jobsystem]` | yes |
| pf-scoreboard | `[pfscripts]` | `[jobsystem]` | yes |
| pf-mechanicjob | `[pfscripts]` (82 files) | `[jobsystem]` (same), `[custom]` (older 55-file version) | no |
| pf-jobsystem | none needed (`[pfscripts]` copy is a CSS wrapper) | `[custom]/pf-jobsystem` — an older copy of the pf-jobs codebase under another name; running both registers the job system's server events twice | no |
| pf-ambulancejob, pf-jobgarages | `[pfscripts]` | `[custom]` | yes |
| pf-elevator, pf-outfitbag | `[pfscripts]` | `[custom]` | no — compare before deleting |
| pf-policemdt | `[pfscripts]/pf-policemdt-DEV` (git) | `[custom]/pf-policemdt` | no |
| dolu_tool, DoluMappingTool | one of `[custom]` / `[scripts]` | the other | yes |
| timecycleeditor | one of `[custom]` / `[scripts]` | the other | no |

- **Government:** pf-government is canonical. `pf-governmentwebsiteonly` registers 15 net events and all 15 are also registered by pf-government, so with both running each is handled twice. Disable `pf-governmentwebsiteonly`. pfm-cityhall stays deprecated (its features live in pf-government).

### Features implemented

- **Batch-aware freshness** (`pfm-inventory/server/freshness.lua`, config `config/freshness.lua`): server-assigned batch per acquisition; shelf life always from config; lazy accrual `used + elapsed × storage rate`, settled whenever an item changes storage; storage types normal/person/stash/fridge/freezer/open_fridge/broken_fridge/trunk/glovebox/outdoor/sunlight/hot; identifier rules plus runtime overrides; legacy items backfilled on open (one batch per slot).
- **Stacking**: perishables merge only within one batch at matching freshness (±1%); merges keep the worse freshness; non-perishables behave exactly as before. Same rule in the UI (`canStackItems`) as on the server.
- **Spoiled food is never deleted**: bands fresh / good / stale / spoiled scale hunger/thirst gain (1.0 / 0.9 / 0.6 / 0.25) and illness chance (0 / 0 / 10 / 45 %), rolled server-side.
- **UI**: freshness pip on every slot type and a freshness chip in the item-info panel; values are server-computed display copies (`info.freshDisplay`) that the server never reads back.
- **Slot persistence**: stashes are normalised to slot-number keys at boot (JSON round-trips produced string keys); slot lookups use each item's `slot` field.
- **Exports** (server-to-server): `GetFreshness(itemName, info)`, `IsPerishable(itemName)`, `SetStorageCondition(identifier, storage|nil)` — the last settles accrued shelf life before switching, for business fridges/freezers and equipment failure.

### Files changed

`[qb]` (PFModsFiveM/-qb-):
- `pfm-inventory/server/freshness.lua` (new), `pfm-inventory/config/freshness.lua` (new)
- `pfm-inventory/server/functions.lua` — AddItem/RemoveItem validation and slot logic, ItemsForClient, freshness exports
- `pfm-inventory/server/main.lua` — move handler rollback + merge rule, drop hold/update/create, purchase hardening, NormalizeSlots, useItem guard
- `pfm-inventory/client/drops.lua` — notifies the server when a bag is picked up
- `pfm-inventory/html/app.js`, `index.html`, `main.css` — stacking rule + freshness display
- `pfm-inventory/fxmanifest.lua` — explicit config order, freshness module
- `pfm-smallresources/server/consumables.lua`, `client/consumables.lua`, `locales/en.lua` — consumption grants, food poisoning
- `tests/` (new) — harness, mocks, 6 spec files; `.gitignore` (new)

`[pfscripts]` nested repositories:
- `pf-tablet/server/apps/business.lua` (pf-jobsystem repo)
- `pf-policemdt-DEV/config.lua` (pf-policemdt repo)

Outside repositories: `[custom]/pf-policemdt/config.lua`, `[custom]/pf-emsmdt/config.lua` (webhook to convar).

### Database / migrations

None in this batch. Freshness lives in each item's existing `info` JSON (players.inventory and inventories.items), so no schema change and no destructive step. Legacy items are upgraded lazily when their inventory is opened. Rollback: restore the previous `pfm-inventory` folder; the extra `info.fresh` keys are ignored by the old code.

### Tests actually run

Command (from `resources/[qb]/tests`): `npm install` once, then `node harness.js`.
The harness executes the real resource files on the fengari Lua 5.3 VM with FiveM/QBCore mocks (Cfx `+=`, `?.` and backtick hashes are rewritten on load).

Result on 2026-10-24: **69 passed, 0 failed, 6 spec files** (consumables 10, freshness 28, drops 8, inventory integrity 18, shop 4, tablet config isolation 1).

The same specs were run against the unmodified code to prove they detect the defects: 20 inventory failures (forged `markedbills` worth 99,999,999 accepted into a drop, goldbar destroyed on a full-stash move, pistol destroyed on stacking, negative removals accepted), 6 consumption failures (hunger 10 → 60 with no food), 3 shop failures (forged suppressor attachment accepted).

Also run: `node --check pfm-inventory/html/app.js` (pass); luaparse parse check of every changed Lua file (pass); browser render of the inventory with freshness data (no JS errors).

### Not verified (needs a live server)

- Nothing in this batch has run on FXServer; the server currently cannot start the framework (oxmysql missing, `[qb]` disabled).
- Real `GetEntityCoords` behaviour for the drop carrier check (requires OneSync), NUI rendering in-game, the vomit animation dictionary, and multiplayer timing of grant expiry.
- `SetStorageCondition` overrides are in memory: the owning resource (e.g. restaurant equipment) must re-apply them after a restart.

### Manual steps for you

1. **Rotate the pf-policemdt Discord webhook** (delete and recreate it in Discord), then add to server.cfg: `setr pf_mdt_evidence_webhook "<new url>"` and, if pf-emsmdt is used, `setr pf_emsmdt_evidence_webhook "<url>"`. Note: replicated convars are readable by clients; a server-side upload proxy is listed below.
2. ~~Approve pushing commit `dedaaf4`~~ — done. Your local `pf-computer` checkout is now one commit behind its remote; to sync without losing your uncommitted work: `git stash`, `git pull --ff-only`, `git stash pop` (your local edit removes the same manifest line, so it reapplies cleanly).
3. Install **oxmysql** (and ox_lib if you keep the resources that need it), restore the MySQL connection string, and re-enable `pfm-core` / `[qb]` when ready to test.
4. Apply the duplicate-resource table above in server.cfg (stop ensuring `[jobsystem]`, remove the duplicate `[custom]` copies or move them out of the resources tree, disable `pf-governmentwebsiteonly`).
5. Earlier incident follow-ups still stand: rotate sv_licenseKey, txAdmin, MySQL and any other webhooks; block steaxscripts.com at the firewall.

### Remaining work, by priority

P0
- Rotate the webhook; resolve duplicates and the missing oxmysql.
- Server-side proxy for MDT evidence uploads so no webhook reaches clients.
- Security sweep of remaining reward events: pfm-houserobbery, pfm-truckrobbery, pfm-jewelery, pfm-pawnshop, pfm-drugs, pfm-weed, pfm-crypto, pfm-crafting; `GetCurrentDrops` still returns every drop's contents to any client; `qb-inventory:server:snowball` grants items without checks.

P1
- Shared business/transaction service (stable transaction IDs, idempotency keys, audit log, explicit transaction states for multi-resource money moves) — inspect pf-government budgets, pf-stores, pfm-banking accounts and pfm-management society accounts first and reuse rather than duplicate.
- Persistent orders and delivery contracts; player-trucker priority with AI fallback, restart recovery (inspect pf-trucking before designing).
- `pfm-worldobjects`: persistent pallets/boxes with isolated stashes, server-validated transforms, 30-minute unpack grace (wires into freshness via a dedicated storage type).
- pf-restaurants stock lots through pfm-inventory, atomic ingredient reservation/consumption, persistence of in-memory state.

P2–P3
- Restaurant persistence, cooking authority, equipment-driven `SetStorageCondition`, hygiene/inspection links to pf-government.
- Government premises slots, licenses, inspections, fines, closures, ownership transfers; banking reconciliation for treasury/society withdrawals.
- Computer/tablet backends to the shared APIs; mechanic parts supply; business fleets in pf-jobgarages.
- Farming: no farming, crop or agriculture resource exists locally or in the public PFModsFiveM repositories (closest: pfm-weed growing, pfm-vineyard picking). Provide its repository if it exists elsewhere; otherwise it needs a design decision before building.

---

## Batch 2 — 2026-10-24: Shared business transaction service (ledger)

### What was there

Money moved in many places with no shared record: `pfm-banking` read the balance, changed it in Lua and wrote it back, while paychecks, the boss menu, pf-government budgets/treasury/taxes and other scripts called its exports and mostly ignored the result. There was no transaction ID, no idempotency, no state for a half-finished move, and no way to tell whether the money in the accounts still added up.

Decision: **one ledger inside pfm-banking**, not a new resource. `bank_accounts` and `players.money` stay the authoritative balances; the new `pf_transactions` table is the journal for every move. No second balance table was created.

### Exploits found and fixed (all confirmed in code, now covered by tests)

| Where | Problem | Fix |
|---|---|---|
| pfm-banking withdraw / deposit / transfers | Negative or NaN amounts minted money or drained other accounts | `PFLedger.Amount` validates every amount (finite, > 0, max 2 decimals) |
| pfm-banking job/gang accounts | Any boss could withdraw **any** job's account; employees could withdraw their own job account | Same job/gang **and** boss required |
| pfm-banking shared accounts | No access check at all | Owner or listed user only |
| pfm-banking `RemoveMoney` export | Allowed overdrafts | Refuses when funds are short |
| pfm-banking `AddMoney` to a missing account | Money vanished | Society accounts are created on demand (known jobs/gangs only), otherwise refused |
| pfm-banking balance columns | `INT` rounded cents away | `DECIMAL(16,2)` |
| pfm-banking delete / rename | Delete destroyed the balance; rename could overwrite another account | Delete refunds the owner first; rename refuses existing names |
| `qb-bossmenu:server:addMoney` (pfm-management) | Registered as a **network** event: any client could add money to any society | Server-only event handler (pf-mechanicjob still calls it server-side) |
| pfm-core paychecks | Paid the employee before charging the company and ignored the charge result; a restart could double-pay | One ledger transfer per pay window with an idempotency key; a broke company pays nothing and the employee is told |
| pfm-core `AddMoney` / `RemoveMoney` / `SetMoney` | NaN / infinite / negative values accepted | Rejected, return false |
| pf-government budgets | Helpers always reported success | Return the real bank result; fail closed if pfm-banking is down |
| pf-government treasury / taxes | Read-then-set balance updates (concurrent deposits lost), bank results ignored | Move exact amounts through the ledger; retries with the same key apply and log once |
| pf-government `server/treasury.lua` | Called client-only `RegisterNUICallback`, so the file errored on every start; the handlers trusted a client-supplied `data.source` | Dead block removed (the real path is `server/callbacks.lua`, which overwrites `data.source` with the real sender) |

### How the ledger works

- **Accounts** are named `society:<name>`, `player:<citizenid>:bank|cash` and `system:<label>` (money entering or leaving the economy, e.g. `system:paycheck`, `system:pf-government`).
- **`exports['pfm-banking']:Transfer({ from, to, amount, key, kind, reason, actor, metadata })`** returns `{ ok, txId, state, error, duplicate }`.
- **Idempotency:** `key` is unique. Repeating a key returns the first result (`duplicate = true`) and moves nothing.
- **States:** `pending → debited → completed`, or `failed` / `compensated`. Each balance change is written in the same SQL statement as its state change, so a crash leaves a record of exactly how far a move got.
- **Recovery** runs at start and every 60 seconds: a stuck `debited` move is completed or refunded; a stuck `pending` move is marked failed.
- **Reconciliation:** `/ledgerreconcile` (god permission) or `exports['pfm-banking']:ReconcileLedger()` compares each society account with its baseline plus the ledger sum and lists differences.
- **Other exports:** `GetTransaction`, `EnsureSocietyAccount`, `LedgerAutoKey`. The existing exports (`AddMoney`, `RemoveMoney`, `GetAccountBalance`, …) keep their names; `AddMoney` / `RemoveMoney` now take an optional 4th `key` argument and return `ok, result`.

### Files changed

- `[qb]/pfm-core/server/migrations.lua` (new): versioned migration runner, `pf_schema_migrations` table.
- `[qb]/pfm-core/fxmanifest.lua`, `server/player.lua`, `server/functions.lua` (`PayPaycheck`).
- `[qb]/pfm-banking/server_ledger.lua` (new), `server.lua`, `fxmanifest.lua`.
- `[qb]/pfm-management/server/sv_boss.lua`.
- `[pfscripts]/pf-government/server/budgets.lua`, `treasury.lua`, `taxes.lua`, `main.lua`. The other modified files in that folder were already modified before this batch and were not touched.
- Tests: `tests/lua/fake_db.lua` (new in-memory oxmysql), `tests/specs/ledger_spec.lua`, `tests/specs/money_callers_spec.lua`, plus mock fixes in `tests/lua/fivem_mocks.lua`.

### Database / migrations

`pfm-banking` migration **v1** runs automatically on first start (recorded in `pf_schema_migrations`):
1. Creates `pf_transactions` (unique `tx_id` and `idempotency_key`, state, from/to, amount, metadata) and `pf_ledger_baselines`.
2. Changes `bank_accounts.account_balance` and `bank_statements.amount` to `DECIMAL(16,2)`. This keeps existing values; whole-dollar balances do not change.
3. Snapshots every account balance as its reconciliation baseline.

Install order: oxmysql → pfm-core → pfm-banking → everything else (the manifest already loads them in that order). **Back up the database before the first start.** Rollback: restore the backup or old folders; the new tables can be dropped, and the DECIMAL columns work with the old code.

### Tests actually run

`node harness.js` from `resources/[qb]/tests` on 2026-10-24: **109 passed, 0 failed, 8 spec files** (Batch 1's 69 still pass, plus ledger 30 and money callers 10).

The ledger tests cover:
- Validation, permissions and idempotency.
- Offline recipients.
- Injected database failures at each step, with recovery afterwards.
- Reconciliation and the migration.

The money-caller tests cover:
- Paycheck window dedupe.
- An underfunded company.
- The state fallback.
- The boss-menu event no longer being reachable from clients.
- Treasury deposits, refused withdrawals, concurrent tax credits, and a retried deposit (one move, one log row).

A test-mock bug was fixed along the way: resource-registered exports were being called with an extra `self` argument.

The specs were not rerun against the pre-change code for this batch (unlike Batch 1), because that would mean stashing your uncommitted work. Each exploit above was confirmed by reading the old code.

### Not verified

- **No real MySQL was available.** The SQL (multi-table UPDATEs, `JSON_SET` on `players.money`, `ALTER … DECIMAL`) was tested only against the in-memory fake. Run it once on a copy of the database first.
- Online players: if the server crashes between removing in-memory money and the ledger write, recovery refunds from the record, but QBCore saves player money on its own timer, so a crash in that window can still lose or keep one move. The window is milliseconds.
- The treasury's `AllowNegative` setting no longer lets the treasury go negative, because the ledger never overdraws a society account.

### Manual steps

1. Back up the database, then start pfm-banking once and check the console for `pfm-banking v1 applied`.
2. Run `/ledgerreconcile` after a day of play; it should report no differences.
3. Scripts that call `AddMoney` / `RemoveMoney` should pass a stable key (e.g. `'impound:'..plate..':'..id`) so retries cannot double-charge.

### Batch 2b — IBAN accounts, loans and credit cards on the ledger

`server_accounts.lua` (shared/business IBAN accounts) and `server_finance.lua` (loans, credit cards) no longer write balances themselves. Every money move is one `Transfer`.

**New account type: `acct:<id>`.** It is a `bank_accounts_v2` row with its own ledger adapter. The account balance and the transaction state change in one SQL statement, as with society accounts. System accounts used: `system:bank_fees`, `system:loans`, `system:credit`.

**Fixed in `server_accounts.lua`:**
- Transfers credited the recipient with a separate write after the debit, so a crash could take money from one side without giving it to the other. Offline recipients went through `GetOfflinePlayerByCitizenId(...).Save()`, which can race the player logging in. Both sides are now one ledger transfer. Offline recipients are paid through their stored balance, and a deleted recipient or closed account gets an automatic refund.
- Closing an account checked the balance, then deleted the row in a separate statement. A deposit landing in between was destroyed. The balance check is now part of the `DELETE`.
- If the account row could not be written after the creation fee was charged, the refund went outside any record. It is now a keyed ledger refund.
- Double-clicks could run two withdrawals at once. Each player now runs one bank action at a time (`PFLedger.WithLock`).

**Fixed in `server_finance.lua`:**
- **Loan payout:** it was not awaited, and the money was paid even if the loan row was never written. Now the loan row is written first, then paid out with key `loan:<id>:disburse`. If the payout fails, the loan is voided.
- **Installments and payoff:**
  - Old behaviour: they read the balance, charged, then wrote absolute values, so two payments at once could both apply.
  - New behaviour: they charge with a key built from the loan's state, and the loan update only applies if the loan is still in that state; otherwise the charge is refunded.
  - Manual payment and autopay of the same installment share one key, so they cannot both charge.
  - A payment that failed for lack of funds can be retried once the player has the money.
  - A payment charged just before a crash is applied on retry without charging again.
- **Autopay:**
  - Offline borrowers are charged through the ledger, replacing the offline `Save()`.
  - A late fee applies only on a real shortfall, and at most once per billing period.
  - A bank outage no longer counts as a missed payment.
- **Card advance:** it added the debt and then paid without checking the limit at write time. The debt is now reserved with the limit check inside the `UPDATE`, and released if the payout fails. A crash can leave debt without cash, never cash without debt.
- **Card payment:** it could pay a card below zero if interest or another payment changed the balance. The decrease is now conditional, and the charge is refunded otherwise.

**Migration `pfm-banking` v2:**
- The five IBAN-account tables are now created here (moved out of `server_accounts.lua`).
- `bank_accounts_v2.balance` and `bank_transactions.amount` become `DECIMAL(16,2)`.
- Every existing IBAN account gets a reconciliation baseline.

`/ledgerreconcile` now checks IBAN accounts too.

**Tests:** `tests/specs/banking_accounts_finance_spec.lua` adds 32 tests. The full suite is **141 passed, 0 failed, 9 spec files**.

Against the pre-change `server_accounts.lua` / `server_finance.lua`, the new spec fails 23 of 32:
- Most failures come from the old code writing balances directly, outside the ledger.
- Two are behaviour failures in the old code: it paid a loan out while the bank was unavailable, and it kept a card payment after the card debt it was paying had already dropped.

**Not changed:**
- `bank_transactions` stays as the per-account history the UI shows. `pf_transactions` is the authoritative record.
- Credit-card interest (`runCardInterest`) moves no money and stays a single `UPDATE`.

### Batch 2c — pf-stores and pf-trucking on the ledger

**pf-stores** (`[pfscripts]/pf-stores/server.lua`, `fxmanifest.lua`)
- **Store money is now in the bank.** A player-owned store's money lives in a bank society account `store_<storeId>` of the new type `business`. Shoppers pay into `system:pf-stores`. The owner's share (the subtotal) then moves to the store account.
  - `pf_stores.balance` is no longer written.
  - On start, any balance left in that column is moved into the store's bank account once (key = store + amount) and the column is zeroed.
- **Checkout order:** charge → reserve stock (conditional) → hand over items → sales tax → owner revenue. Out-of-stock or a full inventory restores the stock and refunds the shopper in full through the ledger.
- **Sales tax (the requested refund):**
  - The treasury now receives exactly the tax the shopper paid, through the new `CollectTaxAmount` export with an idempotency key.
  - Before, `CollectTax` recalculated the tax and could credit a different amount.
  - Tax the treasury cannot accept is refunded to the shopper instead of vanishing.
  - The receipt shows what was actually paid.
- **Store purchase and owner withdrawal** are ledger transfers; losing a purchase race refunds the buyer.
- **Fails closed:** pf-stores refuses sales while the ledger is unavailable, and now lists `pfm-banking` as a dependency.

**pf-government** (`server/taxes.lua`): new `CollectTaxAmount(taxAmount, type, targetType, targetId, collectedBy, key, subtotal)`. `CollectTax` now calls it and takes an optional key. A retried key is not credited or logged twice.

**pfm-banking** (`server_ledger.lua`):
- Migration v3 adds `business` to `bank_accounts.account_type`. The bank UI never lists or opens these accounts for players.
- New export `IsLedgerReady`.
- New accounts are cached with their real type.

**pf-trucking** (`[pfscripts]/pf-trucking/server.lua`, `config.lua`): money-printing exploits found and fixed.

| Problem (old code) | Fix |
|---|---|
| `markDelivered` trusted the client: claim a contract, call it, get paid, from anywhere | The server checks the driver's real position against the final stop (`Config.Delivery.DropoffRadius`, default 80 m) |
| `completeActiveJob` paid with no delivery check at all | Same position check, plus a minimum trip time (pickup→drop distance at 45 m/s, at least 45 s) |
| With a rented work truck, `completeActiveJob` paid and then `completeDeliveredJob` paid **again** on return | `completeActiveJob` refuses work-truck jobs; they are paid once, at the depot (`ReturnRadius` 35 m) |
| Pay was `AddMoney` with no record | One ledger transfer from `system:pf-trucking`, key = contract + driver + claim time. A failed payment keeps the job, and a retry pays once |
| A store supply delivery finished with an own truck never told pf-stores | `externalJobCompleted` now fires on both completion paths |

Server-side position checks need OneSync (the default). Without it, every delivery fails the check (it fails closed).

**Tests:** `tests/specs/stores_trucking_ledger_spec.lua` adds 18 tests on the real pf-stores and pf-trucking files, with a stubbed pf-government. The full suite is **159 passed, 0 failed, 10 spec files**. Every changed file also compile-checks.

These specs were not run against the pre-change pf-stores and pf-trucking code: those repositories hold your uncommitted edits, so their git HEAD is not the "before" state. The trucking exploits were confirmed by reading the old code.

**Found, not changed (gameplay decision needed):**
- pf-stores supply orders are **never charged**: `CheckoutSupplies` records a `total` but takes no money. An owner can order unlimited stock for free and sell it.
- The trucker who delivers a store supply contract is paid by `system:pf-trucking`, not by the store.

Charging the store account for supplies, and paying store contracts' truckers from that payment, is the natural next step. It changes how stores play: a new owner starts with an empty account, so they need a way to fund the store.

### Batch 2d — Paid supply orders, store deposits, escrowed freight pay

Supply orders now cost money, owners can fund their store, and the trucker for a store delivery is paid out of the store's payment.

- **Pickup orders:** charged from the store's bank account (`store_<id>`) to `system:pf-stores-supplier`. A store without enough money gets `insufficient_store_funds`, and nothing is ordered.
- **Trucking orders:** the full order total moves from the store into the `freight_escrow` business account.
  - The trucker's pay (`payoutRate` / `payoutMin` / `payoutMax` as before) is part of that total and never more than it.
  - On delivery, pf-trucking pays the driver from escrow under the order's own key (`freight:supply:<orderId>`), so it can be paid at most once. A work-truck rental fee also comes out of the escrowed pay.
  - pf-stores then releases the rest to the supplier.
  - If the contract cannot be posted, the store is refunded in full.
- **Cancelling:** new export `CancelSupplyOrder(src, { storeId, orderId })` refunds the store in full while no driver has claimed the contract (new pf-trucking export `CancelExternalJob`).
- **Restarts:** pf-trucking keeps contracts in memory. On start, pf-stores re-posts every paid, undelivered trucking order under the same contract id `SUP-<orderId>` and pay key (new column `pf_store_supply_orders.freight_payout`).
- **Delivery is claimed atomically:** the order moves to `delivered` with a conditional update before stock is added. A double-fired completion adds stock once, and cancelled or failed orders never deliver. Owners can no longer self-deliver trucking orders through `DeliverSupplyOrder`.
- **Deposits:** new callback `pf-stores:server:depositBalance`, plus a **Deposit** button next to Withdraw in the store Manage panel (`client.lua`, `ui/index.html`, `ui/script.js`). Deposits show in the activity list and are excluded from revenue figures.
- **pf-trucking fix:** cancelling and re-claiming a contract took the rental fee off the pay a second time each time. The gross pay is now remembered from the first claim.

**Balancing notes:**
- Store items have no `cost` set, so supplies cost the item's retail price; owners profit by setting their own prices. Add `cost = ...` per storefront item for wholesale prices.
- `payoutMin = 250` means small trucking orders pay the whole order total to the trucker and nothing to the supplier.

**Integration gaps:**
- No resource in the local tree calls pf-stores' supply exports (`GetOrderSuppliesConfig`, `CheckoutSupplies`, `ListSupplyOrders`, `DeliverSupplyOrder`, `CancelSupplyOrder`).
- pf-computer's own Order Supplies app (`business:supplies:orders:create`) runs a separate business-account system stored in its JSON data file, outside the bank. That is a second store of money and should be pointed at these exports.

**Tests:** 11 new supply-order tests in `stores_trucking_ledger_spec.lua`. The full suite is **170 passed, 0 failed**. Test-harness fixes made along the way:
- The mock JSON encoder now writes arrays as arrays.
- The decoder handles numbers; a fengari pattern quirk had made it return nil.
- `TriggerEvent` reaches server event handlers.
- Trucking state is reset between tests.

### Batch 2e — pf-computer Order Supplies for player-owned stores

The pf-computer **Order Supplies** app now serves player-owned stores through pf-stores. Their orders are paid from the store's bank account; pf-computer's JSON-file business balances are never used for stores.

**Server** (`[pfscripts]/pf-computer/server/main.lua`)
- **Which business a request is for:**
  - A player with an authorised job business gets that by default (mechanics and restaurants keep working exactly as before).
  - A player who only owns a store gets their store.
  - Someone with both can switch: requests carry `mode = 'store' | 'job'`, and the catalog reports `canSwitch`.
- **Store requests map to pf-stores exports:**
  - catalog → `GetOrderSuppliesConfig` (pf-stores prices; the client never sets a price)
  - orders → `ListSupplyOrders`
  - place order → `CheckoutSupplies` (`pickup` goes straight into stock; `delivery` posts a trucking contract paid from escrow)
  - pick up → `DeliverSupplyOrder`
  - new cancel action → `CancelSupplyOrder`
  - Responses include the store's bank balance (new pf-stores export `GetStoreBalance`, owner-checked).
- **Crash fixed:** `getAuthorizedBusiness` called `isGovJob` before that local was declared, so it resolved to a missing global. Every request from a non-boss player whose job is not in `Config.BusinessManager.AllowedJobs` errored with no reply to the client. This was confirmed by running the new tests against the original code (6 failures with that error).

**Client and UI** (`client/main.lua`, `ui/js/script.js`)
- New NUI callback `pc:supplies:orders:cancel`.
- In store mode, the Order Supplies window:
  - shows the store-account balance;
  - enables **Trucking Delivery** when the store has trucking configured;
  - explains where the money comes from;
  - shows paid / in-transit status;
  - offers **Cancel & Refund** while no trucker has taken the job;
  - maps pf-stores errors (e.g. not enough money in the store account) to clear messages.
- A **Switch to my store / job business** button appears for players with both.

**Tests:** 7 new tests run the real pf-computer server file through its callback event, together with pf-stores, pf-trucking and the ledger. They cover:
- store detection for an ordinary-job owner;
- pf-stores pricing and bank balance;
- a pickup order charging the bank account and never writing store data to the pf-computer data file;
- an unfunded store refused;
- a forged client price ignored;
- delivery + cancel refund;
- a player with neither refused cleanly;
- switching for a boss who also owns a store.

The full suite is **177 passed, 0 failed**.

**Not changed (noted):**
- Job businesses (mechanics, restaurants) still use the JSON-file balances in pf-computer (`business:account:*`, `business:supplies:*` job path). Moving them to their bank society accounts is the next consolidation step.
- `pf-computer:server:supplies:completeOrder` is a network event that takes the player and order id from the client, so any client can mark job-business orders as picked up. No money moves, but it should become server-only.
- The app is listed as `companyOnly` in the computer's app store, so store owners need a computer with the business profile enabled to install it.

### Batch 2f — pf-computer company accounts moved to the bank

A job business's **Company Account** in the pf-computer Business Manager is now the job's bank society account in pfm-banking: the same money paychecks, the boss menu and the bank use. `data/pc_data.json` keeps only the history log; its balance is no longer used.

| Action | Before | Now |
|---|---|---|
| View balance | data-file number | bank balance (`GetAccountBalance`) + history log |
| Deposit | player charged, then a data-file write | one ledger transfer `player:<cid>:bank → society:<job>`; amounts validated (finite, > 0, cents) |
| Withdraw | any authorised manager, data-file decrement, then `AddMoney` | **boss only** (same rule as the bank), one ledger transfer `society:<job> → player`; the bank refuses overdrafts |
| Job supply order | data-file decrement | ledger transfer `society:<job> → system:pf-computer-supplier`; refused with `insufficient_funds` |
| `DepositSale` export | added to the data-file balance | **records the sale only** (history/analytics), moves no money |

**Why `DepositSale` no longer adds money** — its callers:
- pf-mechanicjob's register already pays the society through the bank, then called `DepositSale` for the same sale. That is double counting.
- pf-mechanicjob's tablet checkout charges no customer at all and passes a client-sent total.
- pf-tabletuionly passes a client-sent total.

Crediting the bank there would print money. Those resources must move the sale's money themselves.

**Existing data-file balances:** moved once on start (`MigrateBusinessAccountsToBank`, keyed and marked per business).
- Only the player-funded part moves: deposits − withdrawals − supply orders, capped at the old balance. The history was never trimmed, so this is exact.
- The sale part stays out of the bank, because it was either already in the bank or never paid.
- `Config.BusinessManager.MigrateSalesBalance = true` moves the full old balance instead.
- What moved and what did not is stored on each account as `bankMigration`.

**Bugs found and fixed in pf-computer `server/main.lua`:**
- `nowIso()` was called throughout but **never defined** (neither in the working copy nor on the remote branch). As a result:
  - every company deposit took the player's bank money and then errored before recording it, so the money was lost;
  - withdrawals, supply orders, `DepositSale` and the law and announcement syncs all errored the same way.
  - It is now defined.
- `loadData`, `saveData` and `nextId` were used by the law-feed sync and announcement emails above their `local` definitions, which made those calls error. They are now forward-declared.
- The Company Account UI showed raw error codes; it now shows readable messages.

**Tests:** 6 new tests on the real pf-computer server file:
- the data-file move (player-funded 400 of 700 moves, once);
- the balance read from the bank;
- deposits, including overdraft and negative amounts refused;
- boss-only withdrawal and overdraft refusal;
- `DepositSale` creating no money;
- a job supply order paid from the bank (via a stubbed pf-mechanicjob catalog), refused when the account is empty.

The full suite is **183 passed, 0 failed**.

**Found, not changed:**
- **pf-mechanicjob `pf_mech:tablet:checkout`** (both the `[pfscripts]` and the duplicate `[jobsystem]` copy) pays the mechanic a 20% commission in real bank money on a `total` the client sends, without charging any customer. **A mechanic can mint money.** It needs to charge a customer, or stop paying the commission.
- **pf-mechanicjob `register_pos`:** takes the society from the client (`data.business`), and credits it with `qb-bossmenu:server:addMoney` without a key.
- **pf-computer net events:** `pf-computer:server:supplies:completeOrder` (any client can mark job orders picked up) and `pf-computer:server:deleteProp` (any client can delete placed computers) trust the client.
- **Job supply catalogs** only exist for businesses with a provider resource (pf-mechanicjob). Restaurant businesses get an empty Order Supplies catalog, because the internal config's ingredient list is never used.

### Batch 2g — pf-mechanicjob register and tablet checkout

Files: `[pfscripts]/pf-mechanicjob/server/register_pos.lua`, `server/tablet.lua`, `config.lua`. The duplicate copy in `[jobsystem]` was not changed; it should not be ensured.

| Problem (old code) | Fix |
|---|---|
| `pf_mech:tablet:checkout` charged nobody, but paid the mechanic 20% of a client-sent `total` in real bank money: **mint money at will** | Moves no money; tells the caller to use the register. No UI called it (the tablet POS uses `mechanic:server:chargeCustomer`) |
| `mechanic:server:chargeCustomer` took the shop from the client (`data.business`): prices and takings could go to any society (e.g. `police`) | The shop is always the charging mechanic's own job (`Config.GetBusinessKey`); a different client-sent name is refused |
| No job check: **any player could charge any player** on the server by server id | Only mechanic jobs (`Config.IsMechanicJob`) may charge |
| No distance check | Customer must be within `Config.POS.MaxChargeDistance` (10 m, server-side position, needs OneSync); charging yourself is allowed |
| The 20% commission was created on top of the sale (customer paid X, shop got X, mechanic got 0.2·X extra) | Commission (`Config.POS.CommissionRate`) is paid out of the shop's takings |
| Customer debited with `RemoveMoney` and the shop credited separately (`qb-bossmenu:server:addMoney`) with no shared record | One key per sale: customer → `system:pf-mechanicjob` → `society:<shop>` → mechanic commission, all ledger transfers; nothing is charged if the bank is down |
| Forwarded tax was recalculated by the government (`CollectTax`), so it could differ from what the customer paid | `CollectTaxAmount` with the exact tax charged and a key; tax not forwarded stays with the shop, as before |

**Tests:** `tests/specs/mechanic_pos_spec.lua`, 9 tests on the real register and tablet files:
- a sale moves money without creating any (total money before = after);
- a client-sent other shop or society is refused;
- a rival shop's mechanic is paid into their own shop;
- a non-mechanic cannot charge;
- a distant customer cannot be charged;
- a broke customer is not charged;
- charging yourself earns no commission;
- the bank down means nothing is charged;
- the tablet checkout no longer pays.

The full suite is **192 passed, 0 failed**.

**Customer confirmation (Batch 2h).** The register no longer charges straight away.

- **Sending the bill:** `mechanic:server:chargeCustomer` validates the request and prices the bill on the server. It then sends the bill to the customer's screen (`mechanic:client:confirmCharge`, a `pfm-menu` prompt):
  - shop and mechanic;
  - every line with its price;
  - subtotal, tax, total and payment method;
  - **Pay** / **Decline**.
- **Answering:** the customer answers with `mechanic:server:answerCharge`. Money moves only on Pay, and only if all of these hold:
  - the answer comes from the billed customer;
  - the bill is unused;
  - it has not expired (`Config.POS.ConfirmSeconds`, 60 s);
  - the mechanic is still online and still works for that shop;
  - the two are still within range.
- **One bill at a time:** a customer can have one bill waiting and a mechanic one bill out. Expired bills are dropped (the mechanic is told and the prompt closes); bills of players who disconnect are discarded.
- **Self-charge** needs no prompt.
- Files: `server/register_pos.lua` (charge split into bill → answer → `executeCharge`), `client/tablet.lua` (the prompt), `config.lua`.
- Tests: `mechanic_pos_spec.lua` now has 16, adding:
  - nothing is charged before Pay;
  - Decline;
  - another player cannot accept, and a repeated answer pays once;
  - an expired bill cannot be paid;
  - a customer who walked away is not charged;
  - one bill at a time;
  - a forged bill id does nothing.
- The full suite is **199 passed, 0 failed**. The `pfm-menu` prompt itself was not tried in-game.

**Not changed:**
- `mechanic:server:getBusinessPrices` and `openRegisterApp` still accept a client-sent shop name. They only show a price list; editing stays boss-only for the player's own shop.

### Remaining work for this service

- Two account systems still exist for player-shared accounts: the legacy shared rows in `bank_accounts` (old `openAccount` UI, `society:<name>`) and `bank_accounts_v2` (IBAN UI, `acct:<id>`). Both are on the ledger now, but they should be merged into one. That needs a data migration of existing legacy shared accounts plus a UI decision, so it is not done.
- ~~Make `pf-computer:server:supplies:completeOrder` server-only.~~ Done in batch 3.
- Move the remaining direct money callers (robberies' rewards, other job payouts) onto `Transfer` with keys.
- pf-trucking `AcceptJob` export (pf-computer path) looks up jobs with `ipairs` over an id-keyed table, so it never finds a job. Not a money issue, but that path is broken.

## Batch 3 — 2026-10-24: Reward and payout events (P0 security sweep)

An audit of every server event that hands out money or items found that most of them trusted the client to say "I did the work". The pattern used to fix them is the same everywhere: the server records the starting step itself (with the player's position, items and time), and the reward needs that record, the player in the right place, and enough time for the real activity. Each reward clears its record before paying, so it pays once. Nothing here was committed.

### Exploits found and fixed

| Resource | What a cheating client could do | What the server now requires |
|---|---|---|
| pfm-houserobbery | Open any house and loot it with a bare event | A lockpick attempt at the door (tools checked, police on duty), 3–60 s of minigame, only players who entered can search, each piece once |
| pfm-bankrobbery | Open vaults, lockers and power stations by event; Pacific payout tiers were wrong | Hack kit or card used at the panel and removed server-side, hack/drill time, thermite used at that station, alarm raised by the server; tiers fixed |
| pfm-streetraces | Create races with fake coords, win any race, keep stakes on disconnect | Races built by the server, entrant at the start, winner at the finish after a plausible time; stakes, refunds and pot through the ledger with keys |
| pfm-drugs (deliveries, corner selling) | Pick any drop point, pay without delivering, sell to own ped/players at any price | Drop point from the config, at the drop after the drive time, items removed before pay; real NPC buyers once per 30 min, price capped by the server |
| pfm-weed | Plant without a house key, harvest any plant, unlimited seeds | House key and seed removed by the server, plant ready and nearby, row deleted before harvest |
| pfm-crafting | Craft without a bench | Player's own placed bench nearby; amount capped |
| pfm-crypto | Exchange without the stick, reboot the exchange, inflate transfers | At the exchange, stick removed before pay, server-owned reboot, transfers checked and atomic |
| pfm-inventory | Snowball item spawning; drop list leaked contents | Only removal remains; drops list sends entity ids only |
| pfm-garbagejob | Refund a deposit never paid; collect the last stop forever | Deposit recorded only when taken; every stop paid once, route closes after the last. Also fixed a crash: `PayForStop` called `applyStreakBonus` before it existed |
| pfm-towjob | Tow any car (own truck too) and get paid; rent any vehicle model | Mission car near its tow spot, once per car, delivered car checked at the drop-off and deleted by the server; only config trucks; deposit back at the depot |
| pfm-taxijob | Parked at a drop-off, paid every 30 s | A passenger picked up at a pickup point (`qb-taxi:server:PickupNpc`), paid once at a drop-off at least 150 m away after the drive |
| pfm-busjob | Parked at a stop, paid every 10 s | Each payment from a different stop at least 100 m and a drive away from the last paid one (shortest real gap between stops is 155 m) |
| pfm-recyclejob | Standing at the drop point, paid every 5 s | A package picked up at a shelf (`qb-recyclejob:server:pickupPackage`), handed in once after 4 s; price-list callback no longer hangs |
| pfm-vineyard | Pick one vine every 3 s; wine and juice without waiting | A new vine for each pick (the client no longer repeats a vine), 6 s per pick; wine after `Config.wineTimer`, juice after 14 s |
| pfm-jewelery | Pick any case and claim; police count from a skippable callback; any client could start the store timeout; lag races permabanned | Smash started by the server (at the case, whitelisted weapon, police on duty now), reward after the weapon's smash time; timeout started by the server; no bans on this path |
| pfm-truckrobbery | Claim the cash right after accepting; fee not checked; an old timer ended a newer mission | Server picks the spawn point, the client reports the truck spawned there, payout at the truck after bomb time; fee must be taken; timers tied to a mission id |
| pfm-storerobbery | Brute-force the 4-digit keypad (no limit); padlock after 10 s | 3 wrong codes lock that safe for the character for 10 min (reconnecting does not reset it); padlock needs 20 s |
| pfm-diving | Sell coral from anywhere; paid even if removal failed | At a coral buyer, paid only for what was removed |
| pfm-scrapyard | Scrap owned cars (the owner check ran only on the client) | Plate checked against `player_vehicles` on the server; the server deletes the car |
| pfm-hotdogjob | Second stand charged a deposit that never came back; sale check banned on client coords then paid anyway | No second deposit; a mismatched position is ignored, not banned |
| pf-computer | Anyone could save or delete computer props; anyone could complete supply orders | Staff ACE for props (model checked, list capped); `supplies:completeOrder` is server-only |

### Not changed (noted)
- `QBCore:Server:SpawnVehicle` (pfm-core `server/events.lua`) still spawns any model a client asks for. Many resources use it; locking it down needs a per-resource allow-list.
- pfm-diving's oxygen refill is client-side state only, so a server check would protect nothing.
- Job payouts still use `AddMoney` directly, not ledger `Transfer` (only street races moved in this batch).

### Tests actually run
New specs: `robbery_spec` (10), `streetraces_spec` (5), `taxi_spec` (3), `bus_spec` (2), `recycle_spec` (3), `vineyard_spec` (2), `jewelery_spec` (3), `truckrobbery_spec` (2), `storerobbery_spec` (2), `scrapyard_spec` (2), `garbage_spec` (3), plus pf-computer prop tests in `stores_trucking_ledger_spec`. Mock additions: ACE checks, `GetHashKey`/`joaat`, vehicles and plates, `DropPlayer`, `RegisterServerEvent`, `Mock.fireEvent`, vector `.xyz`; `Mock.callCallback` now returns every value (it returned only the first).

Full suite: **239 passed, 0 failed** (22 spec files). Every changed Lua file (62) parses. Weed, crafting, crypto, drugs, tow and hotdog have no specs yet.

### Not verified
None of this was tried on a live server. The client-side changes (new events sent at pickup/spawn, the scrapyard and tow clients no longer deleting vehicles, the vineyard picking a new vine) need a play-through of each job.

## Batch 4 — 2026-10-24: Job payouts on the ledger

Job pay, NPC sales, and job deposits and refunds no longer change player money directly. Each one is a ledger `Transfer` between the player and the job's own system account (`system:<resource>`), so it is journaled in `pf_transactions` with a stable idempotency key. Nothing here was committed.

### The helper
`pfm-banking/payouts.lua` is included by each job through `server_script '@pfm-banking/payouts.lua'` (pfm-banking does not load it itself). It defines `PFPayout`:
- `Pay(who, 'cash'|'bank', amount, { key, reason, kind, from })` pays a player. A key that already paid is not paid again.
- `Charge(who, {'cash','bank'}, amount, { key, ... })` takes a deposit or fee. Each account tried gets its own key.
- `PaySociety(name, amount, { key, ... })` goes through pfm-banking's `AddMoney`, so the society statement is written too.
- `NewId()` makes the id for a shift, route, stand or bail that the keys are built from.

All of them fail closed. When pfm-banking isn't started or the ledger isn't ready, nothing moves and the player is told the payment was not made.

### What moved ([qb])
| Resource | Payment | Key | If the payment fails |
|---|---|---|---|
| pfm-taxijob | fare (cash, or `society:taxi` with `Config.Management`) | `pfm-taxijob:<shift>:fare:<n>` | fare stays open; a retry uses the same key |
| pfm-busjob | each stop | `pfm-busjob:<shift>:stop:<n>` | the stop is not counted |
| pfm-towjob | deposit, refund, salary | `pfm-towjob:bail:<id>`, `…:refund`, `pfm-towjob:<session>:salary` | the session and its drops stay |
| pfm-garbagejob | deposit, pay, deposit refund | `pfm-garbagejob:<route>:deposit / :pay / :deposit-refund` | the route stays open; a retry reuses the keys |
| pfm-hotdogjob | stand deposit, refund, each sale | `pfm-hotdogjob:stand:<id>`, `…:refund`, `…:sale:<n>` | the hot dogs are handed back |
| pfm-recyclejob, pfm-diving, pfm-vineyard, pfm-pawnshop | NPC sales | `<resource>:…:<citizenid>:<sale id>` | the items are handed back |
| pfm-drugs | deliveries (one key per delivery, whichever branch pays), corner sales | `pfm-drugs:delivery:<id>`, `pfm-drugs:corner:<cid>:<id>` | the drugs are handed back |
| pfm-shops | each delivery, truck deposit and refund, payslip | `pfm-shops:delivery:…`, `pfm-shops:bail:<id>`, `pfm-shops:payslip:<round>` | the drop is not counted, or the deposit/round stays |
| pfm-prison | jail money | `pfm-prison:jailmoney:<cid>:<id>` | not paid |
| pfm-policejob | `/paytow`, `/paylawyer` | `pfm-policejob:paytow / paylawyer:<officer>:<id>` | the officer is told |

### What moved ([pfscripts])
| Resource | Payment | Key | If the payment fails |
|---|---|---|---|
| pf-jobs bus | route fare | `pf-jobs:bus:<payoutId>:<cid>` | the route stays; a retry uses the same key |
| pf-jobs garbage | solo and crew pay | `pf-jobs:garbage:<routeId>:<cid>`, one per member | the session stays; a retry pays only whoever was missed |
| pf-jobs Gruppe6 (both files) | contract pay, solo and group | `pf-jobs:gruppe6:<payoutId>:<cid>` | the contract stays (bags handed back) |
| pf-jobs taxi | fare, rental charge, spawn-failure refunds, deposit refund | `pf-jobs:taxi:ride:<rideId>:<cid>`, `pf-jobs:taxi:rental:<id>:<cid>` (`:refund`, `:deposit`) | the ride or rental record stays; refunds now go back to the account that was charged |
| pf-mechanicjob work orders (callback and event) | order pay | `pf-mechanicjob:workorder:<payoutId>:<cid>` | the order stays accepted; a repeat gives no XP |
| pf-mechanicjob roadside | reward | `pf-mechanicjob:roadside:<cid>:<plate>` | no XP or success message |

Payouts of 0 skip the payment call.

### Exploits fixed on the way
- **pfm-shops payslip.** It paid `DeliveryPrice` for each drop the client claimed (capped at `MaxDeliveries`), once a minute, on top of the pay for each delivery. Now it pays only for drops the server counted, once per round.
- **`/paytow` and `/paylawyer`** created $500 every time. They are now paid from the payer's department account (`society:<job>`), and the payment is refused when that account is short. A judge paying a lawyer needs a `judge` bank account.
- **Deposits.** The tow and shops trucks and the hot dog stand can't be rented twice at once. A second deposit used to be taken without being refunded.

### Batch 4b: the four pf-jobs and pf-mechanicjob problems, fixed
- **Duplicate taxi rental handler** (`pf-jobs/server/apps/taxi.lua`). FiveM runs every handler of an event, so a second `pf-taxi:server:rentVehicle` took another $120 cash (or a client-chosen amount) on every rental. It also overwrote the rental record and lost the deposit refund.
  - The second handler is removed.
  - `returnRentalVehicle` (the depot E key) now uses the same return code as the tablet, so the deposit refund and damage check apply to both.
  - A retried refund keeps the damage result.
  - The client records the rental on `vehicleSpawned`; the removed handler used to do that.
- **Taxi fares from client data.**
  - The fare uses the server's own pickup-to-destination distance; the client's `distanceMiles` is ignored.
  - `ridePickedUp` counts only within 30 m of the pickup point.
  - `completeRide` needs the passenger on board, the driver within 40 m of the destination, and at least max(15 s, distance ÷ 45 m/s) since pickup.
  - Collisions are the higher of the client's count and the server's own count; the penalty is clamped to 0–1.
  - The unused legacy `startRide` / `completeRideLegacy` events were removed. `startRide` built a ride from client coordinates and distance.
- **Bus fares from client data** (`pf-jobs/server/apps/bus.lua`; bus is still disabled in the config).
  - Stops count once each, in order, within 25 m of the stop.
  - The route pays only after every stop, and no sooner than max(60 s, route distance ÷ 30 m/s).
  - Level and "on time" are decided by the server; the client's vehicle health and rating are clamped and can only lower the pay.
  - One route at a time.
- **Roadside service** (`pf-mechanicjob/server/advanced_systems.lua`).
  - The client reports the car it spawned (`startRoadside`). The server records the call, for mechanics only, with a cooldown between calls (`CooldownSeconds`, 180).
  - Payment needs that car, repaired according to the server's own health readings (≥ 900), the mechanic within 15 m, and `MinRepairSeconds` (20) since the start.
  - The key is the call id, so each call pays once.
  - The client keeps reporting until the server confirms (`roadsideDone`), so a quick repair is paid once the minimum time passes.
- **Client-built mechanic invoice** (`pf-mechanicjob/server/main.lua`). The old `pos:requestCharge` / `pos:customerPay` handlers are removed. No client or tablet page called them, but a modified client could name any payer, seller and total. Charging stays on `register_pos.lua`, which prices bills from the shop's list and needs the customer to accept.
  - The tablet's leftover NUI callbacks (`pf_mech:pos:chargePlayer` / `customerPay`) still fire events that have no server handler. They were dead before too.
- **Tests:** `pfjobs_payouts_spec` now has 10 tests (rides and routes must be driven; the client distance is ignored; one rental handler; the depot return refunds). New `mechanic_roadside_spec` has 6. The full suite is 265 passed, 0 failed, 28 spec files.

### Not moved (deliberately)
- Player-to-player payments: phone transfers, vehicle and house sales between players, robbing a player, invoices.
- Payments players make: ambulance and police bills, fines.
- Crypto: not cash or bank.
- Item conversions: police money bags. Refunds: shop purchase refunds and weapon repair.
- Government and housing payouts, and vehicle buy-backs.

### Tests actually run
- **Converted to the real ledger:** `taxi_spec`, `bus_spec`, `garbage_spec` and `recycle_spec` now run on the fake database via `tests/lua/ledger_env.lua` (new).
- **New specs:** `tow_spec`, `hotdog_spec`, `shops_delivery_spec` and `police_pay_spec`. They cover single payment, journal rows, the bank being down (nothing paid, items handed back or the fare kept), the payslip using the server's drop count, and `/paytow` drawing from the police account.
- **pf-jobs:** `pfjobs_payouts_spec` (6) covers the taxi fare, the rental charge and deposit refund, and the bus route, each paid once with a retry after a bank outage. Garbage, Gruppe6 and the mechanic files are only parse-checked.
- **Full suite:** 255 passed, 0 failed, 27 spec files (this count includes your uncommitted inventory specs). All changed files parse.

### Not verified
Not run on a live server. Every one of these jobs needs pfm-banking started, with the ledger migrations applied, before it can pay.


## Batch 5 — 2026-10-24: Source verification, security corrections, persistent supply chain

Branch `batch5-security-supply-chain` in both repositories, cut from `main` (`[qb]` 32891c7, `-pfscripts-` 0ff2676). Nothing pushed, nothing deployed.

### 1. Baseline

| Repository | Base | Batch 5 commits |
|---|---|---|
| `[qb]` (PFModsFiveM/-qb-) | `main` 32891c7 | fe62cb2, 58f736c, 199cdde, fa08b06, 820b83e, 12d0645, 859c70b |
| `[pfscripts]` (PFModsFiveM/-pfscripts-) | `main` 0ff2676 | b93222e, 93be14f, 28636c1, f0f445c, 39a9236, df8eb0a, 3aaaf7f, 441edb7, 9bf4b28 |

**Uncommitted work left as it was** (yours, in `[qb]`):
- `pfm-inventory`: drops, freshness, UI and integrity;
- `pfm-smallresources` consumables;
- six spec files;
- `leonida-id-maker/`.

Batch 5 changes inside those files are also uncommitted. See section 4.

**Source of truth per resource:**
- **Upstream repositories:** the standalone repositories (pf-government, pf-computer, pf-trucking, pf-mechanicjob, pf-jobsystem) were cloned and compared with the copies in `[pfscripts]`. Every upstream head matches the `[pfscripts]` copy at fa4482d, and `[pfscripts]` has newer commits (batches 2–5) on top. **`[pfscripts]` is authoritative**; the standalone repositories are behind it.
- **pf-mechanicjob:** its real remote is `pf-advancedmechanicjob`.
- **`[jobsystem]` folder:** it holds nested git checkouts of pf-jobs, pf-tablet, pf-mechanicjob, pf-scoreboard and pf-jobsystem. These are on older bases and carry uncommitted edits.
- **`[custom]` folder:** it holds further copies of pf-mechanicjob and pf-jobsystem.
- **server.cfg:** it currently ensures `[pfscripts]`, `[custom]` **and** `[jobsystem]`, so the same resource names are started from up to three folders. The server should run only the `[pfscripts]` copies.
- **Farming:** no farming resource exists in any folder; only `pfm-weed` and `pfm-vineyard` exist. No farming API was invented (see section 11).

**Live `server.cfg` (read only, not changed):**
- `#ensure pfm-core` and `#ensure [qb]` are still commented out.
- The `mysql_connection_string` line is commented out; no active connection string is set.
- `ensure ox_lib` is present, but no `ox_lib` folder exists under `resources/`.
- `oxmysql` sits at `PF/oxmysql`, outside `resources/`, so the server will not find it.
- `ensure guard` names a resource that does not exist in any resource folder. Check what it is before enabling anything by that name.
- `menuv` and `PolyZone` are present in `[standalone]`.

### 2. Report-versus-code discrepancies

| Finding | File / event | State at baseline | Now |
|---|---|---|---|
| updateDrop writes client coordinates; nil access on a bad id | `pfm-inventory/server/main.lua`, `qb-inventory:server:updateDrop` | **Confirmed in committed code** (`Drops[dropId].coords = coords`, no checks) | **Fixed only in the uncommitted inventory work**: it needs a string id and that the caller is holding the drop (`holdDrop`, within reach). The server places the bag at the carrier's position and ignores client coordinates. |
| GetCurrentDrops returns the full drop table | same file, `qb-inventory:server:GetCurrentDrops` | **Already fixed in committed code** (returns `entityId` only) | Unchanged |
| Other drop paths (open, close, hold, create, move items) | same file: `openDrop`, `closeInventory`, `holdDrop`, `createDrop`, `SetInventoryData` | Confirmed: anyone could close another player's inventory; a held drop could be opened or emptied; non-integer amounts and slots were accepted; a reused network id overwrote the slot | Fixed (uncommitted, inside your inventory work). 7 new regression tests in `inventory_drops_spec` (15 in that file in total). |
| saveProp trusts client prop data; deleteProp by coordinates for anyone | `pf-computer/server/main.lua`, `pf-computer:server:saveProp` / `deleteProp` | Confirmed | Fixed (b93222e) |
| supplies:completeOrder and other business/government writes | `pf-computer/server/main.lua` dispatcher | Confirmed: there was no government permission per action, any job grade 0 counted as authorised, fines had no limit, mail was readable across players, the domain price came from the client, and announcements could be created through net events | Fixed (b93222e) |
| AcceptJob cannot find a contract | `pf-trucking/server.lua`, export `AcceptJob` | Confirmed: it searched the id-keyed table with `ipairs`, so it never matched; it also skipped the claim state | Fixed (28636c1); tested |
| Fines edit balances directly, uncapped | `pf-government/server/bills.lua` | Confirmed | Ledger, capped (93be14f) |
| Restaurant revenue / business registration from any client | `pf-government/server/integrations.lua` | Confirmed (net events) | Server-only (93be14f); also in `pf-governmentwebsiteonly` |
| Two shared-account models | `pfm-banking` | Confirmed (legacy `bank_accounts` 'shared' + JSON users, and IBAN accounts with members) | One model, with migration (fa08b06) |
| Vehicle spawn callbacks spawn any model anywhere | `pfm-core/server/events.lua` `QBCore:Server:SpawnVehicle` / `CreateVehicle` | Confirmed (found during the audit, not in the report) | Fixed (58f736c) |
| Restaurant stock in memory, cooking from the cook's pockets, client expiry, client totals | `pf-restaurants/server/*` | Confirmed, as the spec described | Fixed (df8eb0a) |
| Ledger reconcile on MariaDB | `pfm-banking/server_ledger.lua` | Not in the report: "Illegal mix of collations" on every reconcile (found by real-DB tests) | Migration v4 (fa08b06) |
| pfm-banking start-up | `server_ledger.lua` | Not in the report: crashed at start because `QBCore.Commands` is nil (found on staging) | 859c70b |
| Government tax defaults | `pf-government/sql/install.sql`, `server/taxes.lua` | Not in the report: rate columns `DECIMAL(5,2)` cannot hold the 5000 registration fee, so on strict MySQL/MariaDB the tax system started empty (found on staging) | 3aaaf7f |
| Garbage group tables | `pf-jobs/server/apps/garbage.lua` | Not in the report: fire-and-forget CREATEs raced, so on a fresh database the members table failed its foreign key (found on staging) | 441edb7 |

### 3. Security issues fixed in this batch

All of these are server-side; hiding UI was not counted as a fix.

- **Inventory drops** (uncommitted, see above):
  - only the opener can close an inventory;
  - drops must be opened by a valid id and must not be in someone's hands;
  - a carried drop cannot be opened or moved into;
  - amounts and slots must be positive integers;
  - moving items into a drop requires being within reach.
- **pf-computer**:
  - **Props:**
    - the server assigns prop ids and checks the model, the 5 m reach, duplicates within 0.75 m and the heading;
    - only the owner, or a holder of `pf-computer.admin.all`, can remove a prop, and the server picks the prop;
    - late joiners now receive the saved props.
  - **Action dispatcher:**
    - type checks;
    - a token-bucket rate limit;
    - boss-only business writes;
    - per-action pf-government permissions;
    - fines limited to 1–50,000.
  - **Mail and calendar:** they are per player.
  - **Domains:** bought at the server price through the ledger.
  - **Job board:** posts are length-bounded and escaped in the UI (stored XSS).
  - **Delivery points:** need the boss and real coordinates within 25 m.
  - **Removed:** the unauthenticated `pf-computer:announcements:create` event and the unused direct-debit helper.
- **pf-government**:
  - exports `HasPermission`;
  - fines go through the ledger, keyed by bill, with a cap;
  - `addRevenue`/`registerBusiness` are server-only.
- **pf-trucking**:
  - `AcceptJob`/`CancelContract` use the real claim and cancel code;
  - cargo loading is checked at the pickup;
  - a restored contract keeps its driver.
- **pfm-core vehicle spawns**:
  - a spawn needs a job vehicle rule (on duty) or a one-time server ticket;
  - the spawn point must be within 150 m;
  - there is a 3 s cooldown.
- **pf-restaurants**:
  - no client-created stock;
  - `startFire` is server-only;
  - menu prices are bounded;
  - recipes may only use restaurant items;
  - roles are validated (only the owner can grant owner);
  - the inspector needs pf-government `licenses`;
  - repairs are paid by the restaurant's account through the ledger.
- **Supply chain**:
  - no client sets a price, payment result, payout or delivery state;
  - every payout has a fixed per-order ledger key.

### 4. Files and repositories changed

**`[qb]` (committed):**
- pfm-core: `server/vehicle_spawns.lua` (new), `server/events.lua`, `shared/items.lua` (`supply_crate`), `fxmanifest.lua`.
- pfm-banking: `server_ledger.lua`, `server_shared_migration.lua` (new), `server.lua`, `config.lua`, `fxmanifest.lua`.
- `pfm-worldobjects/` (new resource): `server.lua`, `client.lua`, `config.lua`, `fxmanifest.lua`.
- Vehicle registration in pfm-ambulancejob, -busjob, -garbagejob, -mechanicjob, -newsjob, -policejob, -shops, -taxijob, -towjob and -vehiclesales.
- tests:
  - the real-DB runner: `tests/realdb/run.js`, `sqlworker.js`, `lua/real_mysql.lua`;
  - five `realdb_specs`;
  - `vehicle_spawns_spec`;
  - `stores_trucking_ledger_spec`;
  - `harness.js`, `fivem_mocks.lua`, `fake_db.lua`, `parsecheck.js`, `package.json`.

**`[qb]` (uncommitted, mixed into your own uncommitted work):**
- `pfm-inventory/server/main.lua`: the drop fixes.
- `pfm-inventory/server/functions.lua`: the `SaveStash` and `RegisterPerishables` exports.
- `pfm-inventory/server/freshness.lua`: `RegisterItems`.
- `tests/specs/inventory_drops_spec.lua`: 7 tests.

**Committed code depends on these uncommitted pieces:**
- **pfm-worldobjects** needs `SaveStash`.
- **pf-restaurants** needs `RegisterPerishables` and the freshness module.
- **Effect:** until your inventory work is committed, a checkout of the branch alone is incomplete.

**`[pfscripts]` (committed):**
- pf-computer: server (`main.lua`, `gov_announcements_sync.lua`), client, UI script.
- pf-government: `core.lua`, `bills.lua`, `integrations.lua`, `taxes.lua`, `config.lua`, `sql/install.sql`.
- pf-governmentwebsiteonly: `integrations.lua`.
- pf-trucking: `server.lua`, `client.lua`.
- pf-ambulancejob: `server/main.lua`.
- pf-stores: `server_orders.lua` (new), `server.lua`, `shared/config.lua`, `fxmanifest.lua`.
- pf-restaurants:
  - `server/persistence.lua` (new);
  - inventory, stations, orders, menu, business, recipes, fire, equipment, hygiene, main, government placeholders;
  - client interactions and registers;
  - config, fxmanifest.
- pf-jobs: `server/apps/garbage.lua`.

### 5. API contracts

**pf-stores order service (`PFOrders`, exports on `pf-stores`):**
- **`CreateOrder(src, payload)`**:
  - payload: `{kind, buyerId, cart, method = 'trucking'|'pickup'}`;
  - returns `{ok = true, data = {orderId, total, subtotal, markup, status, contractId, items, createdAt}}` or `{ok = false, error = <code>}`, for example `not_owner`, `invalid_items`, `bank_unavailable`;
  - prices come from the buyer kind's catalog;
  - payment goes to `society:freight_escrow`, or straight to the AI supplier for pickup.
- **`CancelOrder(src, kind, buyerId, orderId)`**: allowed only from `awaiting_supplier` or `awaiting_delivery`. The refund is paid once; any part of the markup already returned is subtracted.
- **`CollectOrder(src, kind, buyerId, orderId)`**: the deferred pickup.
- **`UnpackSupplyOrder(src, orderId)`**: `delivered → unpacked`. The adapter adds the stock; the status is reverted if that fails.
- **`GetOrder(orderId)`** and **`GetOrderHistory(orderId)`**.
- **`CanManageOrderBuyer(src, orderId)`**.
- **`RegisterBuyerKind(kind, adapter)`**:
  - adapter: `{canManage(src, buyerId), account(buyerId), ensureAccount(buyerId), price(buyerId, cart) -> lines, subtotal, route(buyerId), unpack(order)}`;
  - pf-stores registers `store`, pf-restaurants registers `restaurant`.
- **Statuses:**
  - delivery: `created → paid → awaiting_supplier → awaiting_delivery → assigned → in_transit → delivered → unpacked`;
  - pickup: `paid → ready → delivered → unpacked`;
  - plus `cancelled` and `failed`;
  - every change is a guarded `UPDATE … WHERE status = from` with a history row.
- **Ledger keys:** `supply:<id>:charge`, the supplier share, the markup split, `freight:supply:<id>` and the refund. One key per payout.
- **Commands:** `/supplier`, `/supplyoffer`, `/supplystock`, `/supplyorders`, `/supplyaccept`.

**pf-trucking:**
- **Exports:** `AcceptJob`, `CancelContract`, `GetAvailableJobs`, `SetContractRoute`, `CreateExternalJob` (restores the driver after a restart) and `ReleaseExternalJob` (new).
- **Server events:** `pf-trucking:server:externalJobClaimed`, `externalJobLoaded`, `externalJobReleased`, `externalJobCompleted` and `started`.
- **Net event:** `pf-trucking:server:cargoLoaded`, checked against the pickup position.

**pfm-worldobjects:**
- **Exports:**
  - `CreateDeliveryObject({model, coords, heading, owner, orderId, contents})` returns an object with a unique `stash_id` of the form `worldobj-<id>`;
  - `GetObject(id)`.
- **Net events:** open, unpack, move and sync. Each checks owner and proximity; a move is placed by the server.

**pfm-core:**
- `RegisterJobVehicles(job, models, {anyDuty?, catalog?})`;
- `GrantVehicleSpawn(src, model, seconds)`.

**pfm-inventory (uncommitted):**
- `SaveStash(identifier)` writes a stash to the database now.
- `RegisterPerishables({item = category})` adds items to the freshness rules.

**pf-government:**
- `HasPermission(src, perm)`, using pf-government's own staff roles.

**pfm-banking:**
- `Transfer`, `GetTransaction` and `LedgerAutoKey` are unchanged.
- The ledger now also takes `Commands` from pfm-core, for `/ledgerreconcile`.

### 6. Database migrations and upgrade

Versioned through `pfm-core/server/migrations.lua`, recorded in `pf_schema_migrations`. Every step is safe to rerun.

| Resource | Version | What it does |
|---|---|---|
| pfm-banking | v4 | `pf_transactions` / `pf_ledger_baselines` take the collation of `bank_accounts` |
| pfm-banking | v5 | `pf_shared_account_migration` (record of moved legacy shared accounts) |
| pf-stores | v1 | order lifecycle columns, `pf_store_supply_order_events`, `pf_suppliers`, `pf_supplier_offers`, `freight_payout` when missing; maps old statuses (`ordered→ready`, `outsource_posted→awaiting_delivery`, `delivered→unpacked`) |
| pfm-worldobjects | v1 | `pf_world_objects` (unique `stash_id`, unique `order_id`) |
| pf-restaurants | v1 | employees, menu, recipes, orders, state, inspections |

**Fixes made outside the migration system:**
- **pf-government tax columns:** they are widened to `DECIMAL(10,2)` both in `install.sql` and at start-up. The old `DECIMAL(5,2)` made the default tax insert fail on strict MySQL/MariaDB.
- **pf-jobs garbage tables:** they are now created in order.

**Upgrade steps for the live server (not done; needs your go-ahead):**
1. Back up the database.
2. Install `ox_lib`, and move `oxmysql` under `resources/`.
3. Set the connection string, keeping it out of git.
4. Remove the duplicate folders from `server.cfg`, plus `pfm-cityhall` and `pf-governmentwebsiteonly` (see section 10).
5. Commit or deploy the pfm-inventory work together with this branch.
6. Start the server. Migrations run by themselves.
7. Legacy shared accounts move once (`Config.MigrateLegacySharedAccounts = true`; set it to false to postpone the move).
8. Run `/ledgerreconcile` and check that there are no mismatches.

### 7. Automated tests (mocked, fengari)

`node tests/harness.js`:
- **Result:** **277 passed, 0 failed, 29 spec files**.
- **Your uncommitted specs:** 76 of these tests are in them (consumables 10, freshness 28, inventory_drops 15 including my 7, inventory_integrity 18, inventory_shop 4, tablet_config_isolation 1).
- **Committed specs:** the remaining 201 are in 23 files.

What was added for this batch:
- **stores_trucking_ledger_spec** (44): props, computer dispatcher, AcceptJob/CancelContract.
- **vehicle_spawns_spec** (6).
- **The 7 drop tests.**
- **The mocks:** `GetCoreObject` now honours the filter list, as real pfm-core does.

These tests use a fake database and fake FiveM natives. They prove the Lua logic only.

### 8. Staging FXServer and real-database tests actually performed

**Real database:**
- **Server:** a throwaway MariaDB 10.4 on 127.0.0.1:3399, with a fresh `pf_rt_*` database per spec.
- **Command:** `PF_TEST_DB=mysql://root@127.0.0.1:3399 node tests/realdb/run.js`.
- **Result:** **54 passed, 0 failed, 5 spec files**:
  - ledger 13;
  - shared accounts 3;
  - supply chain 19;
  - computer orders 3;
  - restaurants 16.
- **What they cover:**
  - migrations on a stock schema with existing balances, plus reruns;
  - a database-level unique idempotency key;
  - money moving once per key, with the original result returned;
  - overdraft;
  - offline and online players;
  - crash before or after the debit, and recovery never completing an undebited transfer;
  - reconciliation, including flagging a direct balance edit;
  - legacy shared accounts moving once;
  - the full supply chain (escrow, forged carts, player trucker priority and single claim, AI fallback, suppliers, cancellation, pickup, work-truck fee, restart recovery, pallet persistence with one stash per pallet, sealed crates, exactly-once payouts, reconciliation at the end);
  - the restaurant flows (stock, all-or-nothing cooking, two cooks with stock for one batch, disconnect refund, freezer vs room freshness, expired food kept, server prices, customer acceptance, tax, refunds once, restart).
- **Limit:** "concurrent" here means interleaved requests on one Lua state; truly parallel database sessions were not tested.

**Staging FXServer:**
- **Setup:**
  - the local FXServer build, `sv_lan`, 127.0.0.1:30150;
  - a disposable `pf_staging` database with all `[qb]` SQL plus pf-government `install.sql`;
  - `chat, oxmysql, PolyZone, pfm-core, [qb], pf-government, pf-scoreboard, pf-trucking, pf-computer, pf-jobs, pf-tablet, pf-mechanicjob, pf-stores, pf-restaurants`.
- **Three runs** of about 100 s each.
- **Found and fixed:**
  - pfm-banking start-up crash;
  - pf-government taxes failing to load;
  - pf-jobs garbage foreign-key race.
- **Upgrade path:** tested by giving the server an old narrow tax table. It widened it and loaded 7 taxes.
- **Final run:**
  - no script errors;
  - all migrations applied in order (pfm-banking v1–v5, pf-stores v1, pfm-worldobjects v1, pf-restaurants v1);
  - pfm-worldobjects restored 0 objects (an empty database);
  - pf-computer loaded saved props.
- **Expected failures:** `pfm-adminmenu` (menuv not copied to staging) and `pf-mechanicjob` (no ox_lib).
- **Other observations:**
  - pf-scoreboard is a hard dependency of pf-trucking and pf-tablet, so pf-stores needs it too;
  - pf-government disables its civil services while `pfm-cityhall` runs;
  - `pfm-inventory/migrate.sql` and `pfm-vehicleshop/vehshop.sql` fail on a fresh database (an old-data migration, and a column added twice). These are harmless for a fresh install but noisy.
- **Secrets:** the license key was copied into staging without being printed and was deleted afterwards. No credentials appear in logs, commits or this report.
- **Not performed:** no client connected to staging.

### 9. Remaining runtime checks (not verified)

- **Multiplayer and client behaviour:**
  - two players opening, carrying and dropping the same drop bag;
  - two players at the same pallet;
  - late joiners seeing computers and pallets.
- **NUI:**
  - inventory, computer (Order Supplies statuses, job board), restaurant POS bill prompt and kitchen display;
  - none of these was opened in a game client.
- **Entity networking:**
  - pallet entities after a restart;
  - pallet move placement;
  - drop routing buckets;
  - vehicle spawns through the new gate for every job garage. A garage whose model list is not registered will now refuse its spawn. Check every job garage.
- **Trucking in game:** trailer connect sending `cargoLoaded`, and arriving at the drop.
- **Live data:** migrations on a copy of the live database (balances, shared accounts, open store orders with old statuses). Only stock schemas with sample data were tested.
- **Cross-resource adapters:** pf-restaurants registers its buyer adapter through exports with function references; tests ran on one Lua state, so the funcref path across resources is not covered there.
- **Remaining direct money callers** (audited, not moved):
  - house purchases, furniture and private sales (pfm-houses);
  - phone invoices and transfers (pfm-phone);
  - police fines, bills, cash seizure and robbery (pfm-policejob);
  - vehicle shop sales (pfm-vehicleshop);
  - used-car seller pay (pfm-vehiclesales);
  - shop purchases (pfm-inventory, your uncommitted file);
  - crypto transfer (pfm-crypto);
  - armored-truck activation (pfm-truckrobbery);
  - the paycheck (pfm-core) and the admin give/set commands;
  - hospital bills and revive fee (pf-ambulancejob);
  - city hall ID fee (pf-government civil);
  - MDT fines and bonuses (pf-policemdt-DEV);
  - rentals (pf-rentals);
  - the old website-only fine collection (pf-governmentwebsiteonly, which should be removed).
- **Why these were not moved:**
  - most are plain player-to-system charges with a check before them;
  - pfm-houses private sale, pfm-phone transfers and pfm-vehiclesales are player-to-player and should move first, because a crash between the two calls loses or creates money.

### 10. Installation order, dependencies, configuration

**Start order:**
1. `oxmysql`, `ox_lib`, `PolyZone`, `menuv`;
2. `pfm-core`;
3. `[qb]` (including `pfm-banking`, `pfm-inventory`, `pfm-worldobjects`);
4. `pf-government`;
5. `pf-scoreboard`;
6. `pf-trucking`;
7. `pf-computer`;
8. `pf-jobs`;
9. `pf-tablet`;
10. `pf-mechanicjob`;
11. `pf-stores`;
12. `pf-restaurants`.

**Remove from start-up:**
- `pfm-cityhall`;
- `pf-governmentwebsiteonly`;
- the `[jobsystem]` and `[custom]` copies of pf-jobs, pf-tablet, pf-mechanicjob, pf-scoreboard and pf-jobsystem. Keep their folders until the uncommitted edits in the nested `[jobsystem]` checkouts are reviewed.

**New configuration:**
- `Config.SupplyChain` in pf-stores:
  - `PlayerSuppliers`;
  - `SupplierOfferSeconds` 120;
  - `AIMarkup` 0.15;
  - `PlayerSupplierShareOfMarkup` 0.5;
  - `DriverPrioritySeconds` 300;
  - `DriverMaxSeconds` 3600;
  - `AIDeliverySeconds` 600;
  - `PalletModel`;
  - `CaseSize`.
- `Config.MigrateLegacySharedAccounts` (pfm-banking).
- `Config.Bills.MaxFine` (pf-government, 50000) and `Config.Government.MaxFine` (pf-computer, 50000 when unset).
- pf-restaurants: `GradeRoles`, `Supplies`, `POS` (`MaxMenuPrice`), `Cooking` (`StationRange`, `MinProgressPlain`) and `FreshnessCategories`.
- ACE `pf-computer.admin.all` for senior admins who may remove any world computer.

### 11. Remaining work, by priority

1. **Commit your pfm-inventory/pfm-smallresources work** (with the drop fixes inside it). Until then the committed `updateDrop` is still exploitable, and pfm-worldobjects and pf-restaurants lack exports they call.
2. **Fix the live `server.cfg`** on a copy and test it on staging with a copy of the live database:
   - enable pfm-core and `[qb]`;
   - set the connection string;
   - install ox_lib;
   - move oxmysql;
   - identify `guard`;
   - remove the duplicates.
3. **Run the in-game checks in section 9** with two clients on staging.
4. **Move the player-to-player money callers to the ledger:** house private sale, phone transfers and invoices, used-car seller pay.
5. **Then the remaining charges in section 9:** shop purchases, vehicle shop, police, hospital, rentals, MDT.
6. **Farming:** no resource exists. Supplier stock is currently player inventory. A farming resource would feed `/supplystock` once one is chosen.
7. **Clean-up:**
   - retire `pf-governmentwebsiteonly`;
   - fix `pfm-inventory/migrate.sql` and `vehshop.sql` so they work on fresh databases;
   - update the standalone repositories from `[pfscripts]` if they are still used.

### Update: inventory work committed

Your pfm-inventory and pfm-smallresources work, together with the drop fixes and exports above, is now committed on this branch:
- 623a49d: freshness module and UI;
- 7f2211d: drop security and item integrity, including `SaveStash` and `RegisterPerishables`;
- 5f4fc64: consumables;
- 1d6615f: pf-tablet config test.

Where sections 2, 4 and 11 say "uncommitted", read "committed in these commits". The branch now runs on its own, and the `updateDrop` exploit is closed in committed code. Mocked suite: 277 passed, 0 failed. `leonida-id-maker/` stays untracked.

### Batch 5b — player-to-player money on the ledger (priority 4)

All three resources now include `@pfm-banking/payouts.lua`. Every payment has a fixed key, and a player-to-player move is a single ledger `Transfer`, so a crash cannot lose or create money.

| Resource | Commit | Moved to the ledger | Exploits fixed on the way |
|---|---|---|---|
| pfm-houses | 16cf380 | <ul><li>house purchase (paid before handover; per-house lock)</li><li>private sale: price + tax in one debit, then seller and tax paid, uncollected tax refunded</li><li>sell to the state (paid before the house is given up)</li><li>agency commission</li><li>furniture</li></ul> | <ul><li>`buyFurniture` took the price from the client (0 or negative bought anything)</li><li>`savedecorations` let any client rewrite any house's furniture, with any model, for every player, without buying it</li><li>`lockHouse` let anyone lock or unlock any house</li><li>`SetRamState` / `SetHouseRammed` were open to everyone</li><li>the ram state was sent to an event nobody listened to</li><li>two quick `/sellhouse` paid twice</li></ul> |
| pfm-phone | 9385305 | <ul><li>bank app transfer and `TransferMoney` event (one function)</li><li>invoice payment, business credit and commission</li></ul> | <ul><li>`PayInvoice` took amount, business and biller from the client</li><li>the commission was paid before the bill</li><li>`TransferMoney` matched receivers with `LIKE '%<number>%'`</li><li>an offline receiver's money record was rewritten from a stale copy</li></ul> |
| pfm-vehiclesales | ba1f232 | <ul><li>used-car purchase (charge, then an atomic listing claim, refund if lost)</li><li>seller pay (online or offline)</li><li>vehicle tax with refund</li><li>sell-back</li></ul> | <ul><li>the purchase never checked `RemoveMoney`</li><li>two buyers could both get one car</li><li>an offline seller's money record was rewritten</li></ul> |

**Tests (mocked):**
- New specs: `houses_spec` (13), `phone_bank_spec` (8), `vehiclesales_spec` (6).
- Run against the pre-change code, 10, 6 and 3 of them fail. The ones that still pass cover behaviour the old code already got right.
- Full suite: **304 passed, 0 failed, 32 spec files**.
- Not run on the real database or staging.

**Not verified in game:**
- The furniture purchase now sends the model and the house instead of a price (`client/decorate.lua`).
- Decorations saved by older clients with entity handles are cleaned on the next save.
- Furniture already in a house is kept and can still be moved. Furniture paid for but never placed is remembered only until restart.
- Police raids now need `job.type == 'leo'` and on duty at the door.

**Still direct (unchanged):**
- `pfm-policejob` fines, bills, cash seizure and robbery;
- `pfm-vehicleshop`;
- `pfm-inventory` shop purchases;
- `pfm-crypto`, `pfm-truckrobbery`;
- the `pfm-core` paycheck and admin commands;
- `pf-ambulancejob`, `pf-government` civil fees;
- `pf-policemdt-DEV`, `pf-rentals`.

**Found, not fixed:** `qb-phone:server:BillingEmail` in pfm-phone lets a client send fake "bill paid" mails to a job.

### Batch 5c — police and vehicle shop money on the ledger

| Resource | Commit | Moved to the ledger | Exploits fixed on the way |
|---|---|---|---|
| pfm-policejob | 8a0faff | <ul><li>`/fine` (bank then cash, then to the department, falling back to an invoice)</li><li>bill menu</li><li>cash seizure into `system:pfm-policejob-evidence`</li><li>evidence bag payout</li><li>robbing a cuffed player (victim to robber in one transfer)</li></ul> | <ul><li>the bill menu credited the police even when the payment failed</li><li>a duplicated evidence bag paid out twice (each bag now has an id)</li><li>`/fine` crashed on a missing amount, had no limit (new `Config.MaxFine` = 50000) and worked off duty</li><li>the robber was paid before the victim's cash was taken</li><li>seizing an empty pocket made a bag</li></ul> |
| pfm-vehicleshop | df4c115 | <ul><li>showroom purchase</li><li>finance down payment, instalments and pay-off</li><li>dealer sale: dealership account and commission</li><li>paid `/transfervehicle`</li></ul> | <ul><li>anyone could "sell" a dealer car to a nearby player, who was charged without being asked; the seller earned the commission</li><li>`/transfervehicle` charged a nearby player any amount without asking</li><li>the car was written before payment, and the payment was never checked</li><li>free-use purchases accepted any model from anywhere</li><li>missing finance values crashed the handler; zero payments divided by zero</li></ul> |

**Behaviour changes to check in game:**
- Dealer sales and paid vehicle transfers now show the customer a pfm-menu offer (accept or decline, valid 60 s).
- The amounts are unchanged:
  - the dealership gets the full price, and the seller gets 10 % (`Config.Commission`; `Config.FinanceCommission` is still unused, as before);
  - finance payments go to `system:pfm-vehicleshop`.

**Tests (mocked):**
- New specs: `police_money_spec` (8) and `vehicleshop_spec` (12).
- On the pre-change code, 6 and 8 of them fail. Some of those failures are crashes or the missing confirmation step rather than wrong amounts.
- Full suite: **324 passed, 0 failed, 34 spec files**.
- Not run on the real database or staging.

**Correction to my first reading of the vehicle shop:** the old finance instalment code looked as if it swapped the payment count and amount, but its two swaps cancel out, and the stored values were right. The new code computes them directly.

**Still direct after this batch:**
- `pfm-inventory` shop purchases;
- `pfm-crypto` transfer;
- `pfm-truckrobbery` activation;
- the `pfm-core` paycheck and admin give/set;
- `pf-ambulancejob` hospital bills and revive fee;
- `pf-government` civil ID fee;
- `pf-policemdt-DEV` fines and bonuses;
- `pf-rentals`;
- `pf-governmentwebsiteonly` (to be removed).

### Batch 5d — the remaining direct money calls

**Audit correction:** my earlier audits searched only for `Functions.AddMoney/RemoveMoney`. They missed the method form `Player.AddMoney(...)`, which pfm-fuel, pfm-garages, pfm-smallresources, pfm-weapons, pfm-cityhall and the [qb] pfm-ambulancejob use. A wider search (`.AddMoney(`, `.RemoveMoney(`, `.SetMoney(`) found them, and they are covered below.

| Resource | Commit | Moved to the ledger | Bugs fixed on the way |
|---|---|---|---|
| pfm-inventory | 8362d43 | shop purchases (cash), refund on a failed hand-over, sales tax by exact amount and key | stock is now reserved before payment (two purchases at once could oversell; not reproducible in the single-threaded mocks) |
| pfm-ambulancejob ([qb]) / pf-ambulancejob ([pfscripts]) | 5aebb3a / f1d8d49 | hospital bill (5 places each), revive fee | the ambulance account was credited even when the patient could not pay |
| pfm-crypto | 52d4246 | the bank side of buying and selling Qbit | selling now gives the coins back if the bank cannot pay. Coins stay a direct balance: the ledger only carries bank and cash in cents |
| pfm-fuel, pfm-garages, pfm-smallresources, pfm-weapons, pfm-truckrobbery, pfm-cityhall | b4636bf | refuel, jerry can, impound release, car wash, weapon repair (+ refund), armored truck activation, city hall ID | <ul><li>the fuel tax is now handed over by its exact amount</li><li>the impound fee credits the treasury only after a successful charge</li><li>pfm-cityhall crashed on an unknown hall</li></ul> |
| pf-government civil | 20231ad | city hall ID fee | the fee was kept when the document could not be handed over |
| pf-policemdt-DEV | ab54a15 | sentence fine (citizen to `system:pf-policemdt`, then department, same key) | **fines never reached the police account**: the deposit called a `pfm-management` export that does not exist and fell back to a `management_funds` table nothing reads. Also removed unused bonus helpers that rewrote offline money records |
| pf-rentals | ff70708 | rental payment | <ul><li>the client sent the total price</li><li>**`pf-rentals:spawnVehicle` spawned any model anywhere**; now only the rented car, once, within 50 m</li></ul> |
| pfm-core | 0b0a11f | `/givemoney`, `/setmoney` for bank and cash (via `system:admin`) | negative or missing amounts are refused |

**Left direct on purpose:**
- **Fallbacks without pfm-banking:** the paycheck, the admin commands, and the MDT's other-framework fallbacks only run when pfm-banking is not started (the paycheck refuses society pay in that case).
- **Crypto coins:** buying, mining a stick and transferring coins need a new account kind in the ledger.
- **`pf-governmentwebsiteonly`:** an old copy that should be removed from start-up.

**Tests:**
- New or changed mocked specs:
  - `inventory_shop_spec` (6), `ambulance_bills_spec` and `pf_ambulance_bills_spec` (5 each), `crypto_spec` (4), `service_fees_spec` (2), `civil_fee_spec` (3), `mdt_fine_spec` (2), `rentals_spec` (4), `admin_money_spec` (4);
  - `truckrobbery_spec` now checks the activation fee. It was broken by b4636bf and fixed in 0b0a11f.
- Mocks gained `RegisterCommand`, `ExecuteCommand` and `WasEventCanceled`.
- Full mocked suite: **355 passed, 0 failed, 42 spec files**.
- Real-database suite, re-run after these changes on the throwaway MariaDB: **54 passed, 0 failed**.
- Nothing was run in game or on staging.

**Duplicates to resolve before going live:**
- pfm-ambulancejob ([qb]) and pf-ambulancejob ([pfscripts]) register the same `hospital:server:*` events. Started together, every bill and revive runs twice. Both are fixed, but only one should run.
- The same applies to pfm-cityhall and pf-government civil services; pf-government already disables its civil services while pfm-cityhall runs.

### Staging run without duplicate resources (2026-10-24)

**Config:** `docs/staging/server.staging.cfg`.
- **Order:** the live start order and settings: cfx defaults, oxmysql, pfm-core, `[qb]`, `[standalone]`, `[voice]`, ox_lib, `[pfscripts]`.
- **Removed:**
  - `pf-ambulancejob` ([pfscripts]); `pfm-ambulancejob` ([qb]) runs instead;
  - `pfm-cityhall`;
  - `pf-governmentwebsiteonly`;
  - the `[jobsystem]` and `[custom]` copies.
- **Not started:** `guard` (no such resource on disk), the map packs and `[scripts]` (map and editing tools).
- **Setup:**
  - fresh copies of both repos;
  - a backdoor signature sweep first (clean);
  - a throwaway MariaDB with 28 of 31 install SQL files loaded. The 3 failures are `pfm-inventory/migrate.sql` and `vehshop.sql` (known), and `pf-garageuionly` (an index another resource already created).
- **Not touched:** the live `server.cfg`.
- **License key:** copied into staging without being printed, and deleted afterwards.

**Ambulance choice:**
- `pfm-ambulancejob` has the security hardening: duty checks, bed ownership and limits on who may trigger revives. It also has CPR and a medal.
- `pf-ambulancejob` has an injury system instead (damage detection, injury checks, treatments, its own SQL), with none of that hardening.
- The injury features are lost until they are ported onto `pfm-ambulancejob`.

**Run 1:** 99 resources started.

| Problem | Cause | Fixed |
|---|---|---|
| illenium-appearance and qb-radio: "No such export GetCoreObject in resource pfm-core" | my staging config started `[standalone]` before pfm-core (the live order is right) | config order |
| `pf-stores` "Unknown column 'unpacked_at'" | pf-trucking's start event made pf-stores recover contracts before its own migration ran | 2ad13de (+ real-DB test) |
| `pf-elevator`: "attempt to call a nil value (SetEntityDynamic)" | client-only natives in the server script; the elevator never spawned | 60faa09 |

**Run 2:** 99 resources started; every migration applied (pfm-banking v1–v5, pf-stores v1, pfm-worldobjects v1, pf-restaurants v1).
- Started: pf-government (with civil services, since pfm-cityhall is gone), pf-policemdt-DEV, screenshot-basic, the elevator (entity spawned), pfm-ambulancejob and every other money resource changed in this batch.
- Remaining failures:
  - `ox_lib` is not on disk. As a result `pf-mechanicjob` does not start and `illenium-appearance` errors ("global 'lib'").
  - `kq_wheeldamage`: "You lack the required entitlement". This is an escrowed asset licensed to the live server, so it is expected on staging.
  - `pf-tabletuionly` and `pf-garageuionly` have no fxmanifest. They are UI-only folders and are skipped.

**Overlaps still running side by side.** These were outside the requested list; found by the log and `docs/staging/event_collisions.py`:

| Pair | Effect | Suggested |
|---|---|---|
| `pf-hud` + `pfm-hud` | both handle `hud:server:GainStress`/`RelieveStress`, so stress changes are applied **twice** | run only pf-hud (the active HUD), or remove pfm-hud's stress handlers |
| `pf-scoreboard` + `pfm-scoreboard` | no shared server events; two scoreboards on the client | keep pf-scoreboard (pf-trucking, pf-tablet and pf-stores depend on it) |
| `pf-mechanicjob` + `pfm-mechanicjob` | both start once ox_lib exists; pf-mechanicjob also handles `qb-garages:server:updateVehicleStats` beside pfm-garages | decide one mechanic job |
| `pf-jobsystem` + `pf-jobs`/`pf-tablet` | no shared server events | check whether pf-jobsystem is still needed |

`QBCore:ToggleDuty` in pf-jobs and pf-tablet only refreshes their screens, which is harmless.

**Bug found, not fixed (gameplay, needs its own test):**
- `pf-jobs/server/apps/gruppe6.lua` listens to `qb-inventory:server:SetInventoryData` as `(src, fromInv, toInv)`, but the inventory sends `(fromInventory, toInventory, fromSlot, ...)`.
- Bags taken out of a Gruppe6 pickup stash are therefore never counted while `Config.Gruppe6.ServerSideStash = false` (the current setting).
- Fix: read `fromInventory, toInventory` and use `source`.

**Still not verified:** no game client connected to staging.

### Follow-up: stress, Gruppe6, and the removed [qb] duplicates

| Change | Commit | Test |
|---|---|---|
| `pfm-hud` leaves stress to `pf-hud` while pf-hud is started (each change used to apply twice); on its own it limits a gain to 1–10 (any number was accepted, a negative one cleared stress) | 47ea23d | `hud_stress_spec` (4; all fail on the old code). Mocks: `Mock.fireNetAll` runs every handler of an event |
| Gruppe6 (`pf-jobs`) reads pfm-inventory's move event in the right order (`fromInventory, toInventory`, mover = `source`). Bags taken out of a pickup stash were never counted with `ServerSideStash = false`, the current setting. Bags are now credited only to the player whose pickup it is | 40d5d86 | `gruppe6_stash_spec` (3; 2 fail on the old code) |
| `pfm-garages` saves parked cars' mods itself (`qb-garages:server:SaveVehicleProps`, owner only). The save used to go to pfm-mechanicjob | 8b382fd | `service_fees_spec` (+2) |
| **Removed `pfm-mechanicjob` and `pfm-scoreboard`** from [qb] (owner's decision: pf-mechanicjob and pf-scoreboard are the ones in use) | 594e382 | — |

**Removal checks:**
- The only other user of pfm-mechanicjob's server events was the pfm-garages mods save (moved above).
- pf-computer falls back to its own blip.
- pf-mechanicjob spawns its own vehicles and does not need pfm-core spawn registration.
- The robberies' `qb-scoreboard:server:SetActivityBusy` calls become no-ops. The scoreboard's open net event of that name, which any client could fire, is gone.
- pfm-mechanicjob's database tables are untouched.

**Tests:**
- Full mocked suite: **364 passed, 0 failed, 44 spec files**.
- Staging (`docs/staging/server.staging.cfg`, updated): 97 resources started. The only failures are the missing `ox_lib` (so pf-mechanicjob does not start and illenium-appearance errors) and `kq_wheeldamage`'s licence.

**Still to look at:**
- Once ox_lib is installed, `pf-mechanicjob/server/garage_sync.lua` also handles `qb-garages:server:updateVehicleStats` (beside pfm-garages) with no check on who sends it. It updates its cached vehicle state for any plate.

### Ambulance job: pf-ambulancejob kept, pfm-ambulancejob removed

Owner's decision: keep `pf-ambulancejob` ([pfscripts]) and remove the [qb] copy.

**Commits:**
- **-pfscripts- 65a35c3 (hardening port):** pfm-ambulancejob's `server/main.lua` was pf-ambulancejob's plus the hardening, so the hardened file was ported whole. It adds:
  - bed ownership and freeing beds on disconnect;
  - checked hospital and bed lookups;
  - armor for medics only, 0–100;
  - wound treatment only by an on-duty medic with a real bandage;
  - revives by an on-duty medic or a first-aid kit, with off-duty medics refused instead of banned;
  - a doctor list for medics only;
  - a `Config.AllowedRevivalResources` list for server-side revive/heal.
  
  Ledger bills and the vehicle registration are unchanged.
- **[qb] f434238 / 7b8ccb7 (removal):** pfm-ambulancejob removed. Nothing referenced it by name, and its exports and events are identical in pf-ambulancejob. Its **CPR and medal features are gone**; pf-ambulancejob never had them.

**Tests:**
- `pf_ambulance_hardening_spec` (5): all fail on the old pf-ambulancejob code.
- `pf_ambulance_bills_spec` (5): still passes.
- Full mocked suite: **364 passed, 0 failed, 44 spec files**.
- Staging: 97 resources started, pf-ambulancejob among them. There are no overlapping hospital events left. Only ox_lib and kq_wheeldamage fail, as before.

**The injury system is not running, and never has.**
- Its files (`server/injury_database.lua`, `injury_handler.lua`, `treatment.lua`, `shared/framework.lua`, `client/check_injuries.lua`, `damage_detection.lua`, `injury_handler.lua`, `treatment.lua`) are not listed in `fxmanifest.lua`. The same is true in the `[custom]` copy, where the files are identical.
- They use 9 config entries that exist nowhere: `Framework`, `AllowedJobs`, `BodyParts`, `Treatments`, `WeaponInjuryTypes`, `DamageTracking`, `CheckInjuries`, `Database`, `Debug`.
- **To use it:**
  1. write those settings, including its data tables;
  2. add the files to the manifest;
  3. load `sql/pf-ambulancejob-qb.sql`;
  4. review its 6 server events and callbacks (for example, `pf-ambulancejob:server:revivePlayerEvent` and `applyTreatment` are client-triggerable) before enabling it.
- Nothing else on the server calls its events.

### pf-ambulancejob injury system finished and enabled (-pfscripts- 47d3c4e)

**What was missing:**
- the files were not in `fxmanifest.lua`;
- 9 config entries did not exist;
- `PFAmbulance.Framework` (callbacks) was never defined;
- the client never reported damage, called a server event that did not exist, mixed server ids with player indexes, and used an undefined `IsPlayerAEMSMember`;
- `sql/pf-ambulancejob-qb.sql` failed to import at its stored procedures.

**Config** (`config.lua`, section "INJURY SYSTEM"):
- 8 injury types and 4 severities;
- body parts mapped from the existing `Config.Bones` labels to 6 zones;
- weapon classes mapped to injury types, plus overrides (falls, vehicles, electric fence);
- report and scan limits;
- 4 field treatments using existing items:

| Treatment | Item | Treats |
|---|---|---|
| bandage | `bandage` | lacerations, gunshot wounds |
| splint | `firstaid` | fractures, blunt trauma |
| burn_dressing | `ifaks` | burns, electrical burns, blast injuries |
| oxygen | `ifaks` | respiratory |

Field treatment works up to *severe*; *critical* injuries need the hospital.

**Server rules:**
- **Injury reports:** about yourself only; every value checked against the config; one report per 2 s; the latest 50 kept per citizen.
- **Scans** (`getInjuriesAndData`, `getDamageHistory`) and **treatment:** an on-duty medic within 4 m of the patient. Treatment uses up its item, removes what it treats, and logs it with the medic's citizen id. No item is taken when there is nothing it can treat.
- **Hospital check-in or respawn** clears all injuries.
- **Tables:** a versioned migration (`pf-ambulancejob` v1), no longer a client-triggerable net event. The treatment-log foreign key is `ON DELETE SET NULL`.
- **Removed:** `revivePlayerEvent` (a revive without the hospital checks) and the unused `injuryScanComplete`.

**Client:**
- **Damage reports:** sent on the game's damage event, with the attacker's weapon and the real bone hit.
- **`/checkinjuries [id]`:** shows the result in pf-emsmdt if it runs, otherwise in a pfm-menu list.
- **`/treat [id] [treatment]`:** applies a treatment.

**SQL file:**
- Removed the three stored procedures. They used `DELIMITER`, so the import failed under oxmysql and most tools; one read a column that does not exist; nothing called them.
- All 9 tables load. The file is only needed for pf-emsmdt's extra tables (patient care reports, vitals, medications, MCI).

**Tests:**
- `ambulance_injuries_realdb_spec` (14, MariaDB): migration and foreign key, report validation, rate limit and cap, scan rules, treatment rules, item use, critical-needs-hospital, hospital clearing, removed events.
- `ambulance_injury_helpers_spec` (4).
- Suites: mocked **368 passed** (45 files), real database **69 passed** (6 files, including the injury spec), all green.
- Staging: 97 resources started and `pf-ambulancejob v1 applied`, with no new errors.

**Not verified in game:**
- the damage event's weapon and bone values on a live client;
- the progress bars and animations;
- the pfm-menu list.

pf-emsmdt (in `[custom]`, not started) was not tested with this.

### pf-emsmdt moved into [pfscripts], reviewed and hardened

**Move** (-pfscripts- 5a41d58, unchanged first):
- **From:** `resources/[custom]/pf-emsmdt`, a checkout of `PFModsFiveM/pf-policemdt` with the EMS conversion uncommitted on top. Only the working files were copied, not `.git`.
- **Backup:** the full original, `.git` included, is at `F:\fivemserver\txData\PF\_moved_backup_2026-10-24\pf-emsmdt`. The `[custom]` copy was then removed.
- **Checked before committing to the public repository:**
  - no backdoor signatures;
  - no webhook URLs, keys or passwords in the files (the evidence webhook comes from the `pf_emsmdt_evidence_webhook` convar).
- **One webhook URL exists in that checkout's old git history** (not copied). It is the pf-policemdt webhook already flagged for rotation; rotate it if not done.

**Server hardening** (f9540e5, c5e6897):

| Area | Problem | Now |
|---|---|---|
| Civilian callouts, auto calls (shots/theft/homicide), `/911` | placed anywhere on the map; suspect fields passed on as sent | within 150 m of the caller; payload must be a table; suspect fields cleaned |
| Roster reload `pf_emsmdt:server:RosterUpdated` | any client could force a reload and broadcast | server-only |
| Accept/complete call | job check only | on-duty medic |
| Profile (callsign/status/avatar) | anyone, any text, any URL, shown to all medics | medics only, rate-limited, short callsign, one-word status, https avatar |
| Patient search | any page size (one request could list every player) | 1–25 per page, 64-character query |
| Patient notes | job only | on duty, rate-limited, existing citizen |
| Chat | — | rate-limited |
| Bulletins | broadcast to every player | medics only |
| `pf-emsmdt:server:getCitizenData` | answered anyone (server id to citizen id and name) | on-duty medic within 5 m |
| Fire / employment / flags / discipline | command could act on **any citizen** (firing set a police officer's job to unemployed) | EMS staff only; firing needs a higher grade and never applies to yourself; viewing a profile no longer creates a staff record |
| Leftovers | unused money helpers editing balances directly; `ensureTablesOnce` called an undeclared function | removed; forward-declared |
| Start order | roster queries before the roster table existed (fresh database, found on staging) | waits for the table |

**Police MDT data** (702311b):
- **Start-up copies:** pf-emsmdt copied the police MDT's staff, discipline, audit, roster and SOP rows (`pf_mdt_*`, pf-policemdt's tables here) into itself on first start, and ran `ALTER TABLE` on the police SOP table. This is now behind `Config.MigrateLegacyPoliceTables` (default **false**).
- **SQL files:** `sql/pf-emsmdt-qb.sql` and `-esx.sql` were the police MDT's schema plus police SOPs and cameras; importing them wrote into the police tables and failed with a duplicate key. The EMS MDT creates its own tables, so the files now explain that. The old content is in git history.

**One /911 for both departments** (8105de0):
- **Before:** both MDTs registered `/911`, so only one department got calls.
- **Now:** `/ems911` always works, and `/911` is registered by pf-emsmdt only when the police MDT isn't running. The EMS server also listens to the police MDT's 911 event and opens an EMS call when the description matches an EMS 911 type.

**UI (NUI) escaping** (2b5e1c8):
- **The risk:** text from other players (chat, 911 descriptions, call titles, units, notes, bulletins, SOPs, roster, staff and injury records) was in places inserted as HTML. A civilian could run script in a medic's MDT and act through its callbacks.
- **The fix:** about 135 insertions escaped, plus helpers for JS-in-attribute values (`escapeJsAttr`) and URLs (`safeUrl`, `safeCssUrl`).
- **Not loaded:** `app-extended.js` is fixed too but is not loaded by `index.html`.

**Injury system connection:**
- **Treatment buttons** (df7d28f): the panel's buttons were bandage, medkit, painkiller and surgery, and only bandage existed. They are now bandage, splint, burn dressing and oxygen. A test keeps them in line with `Config.Treatments`.
- **Local display events:** `displayInjuries` and `displayInjuryAssessment` are now local (AddEventHandler).
- **One view per refresh:** pf-ambulancejob only shows its own injury list when pf-emsmdt isn't running (5559e16), so a refresh opens one view.
- **The scan flow:** `/checkinjuries` → pf-emsmdt injury panel → treatment buttons → `pf-ambulancejob:server:applyTreatment`, which has the server checks from the injury system.

**Tests:**
- `emsmdt_security_spec` (14; 11 fail on the old code).
- `emsmdt_legacy_tables_spec` (2).
- Treatment-button check in `ambulance_injury_helpers_spec`.
- Full suites: mocked **385 passed** (47 files), real database **69 passed**.
- Staging: 98 resources started. pf-emsmdt and pf-policemdt-DEV run side by side; pf-emsmdt touches no police table and has no errors. The remaining failures are unchanged (ox_lib, kq_wheeldamage).

**Not verified in game:**
- the MDT UI itself (only checked for syntax);
- the F6 keybind;
- the injury panel;
- whether both MDTs' `/911` behave as described on a client.

**Notes:**
- The optional `ems_mdt` item (`Config.Item.Name`) does not exist in pfm-core's item list. The MDT opens by command or F6.

### Loose ends: fake billing mails, car save events, SQL files on a fresh database (2026-10-25)

**pfm-phone fake "invoice paid" mails** (-qb- d53a8a3):
- **Before:** the phone sent `qb-phone:server:BillingEmail` with a business and amount it chose. The server mailed every online member of that job, so any player could send any job fake "Invoice Paid ... $999999" mails.
- **Now:** `PayInvoice` and `DeclineInvoice` mail the business themselves, from the stored invoice (amount, business) and the payer's real name. The relay event and its client handler are removed.
- **Tests:** 3 new in `phone_bank_spec` (all 3 fail on the old code). The mock QBCore gained `Functions.GetPlayers`.

**pf-mechanicjob car save events** (-pfscripts- a145539, test -qb- d857d3e):
- **Before:** not only `updateVehicleStats`: all four sync events (`cacheVehicleState`, `forceSave`, `qb-garages:server:updateVehicleStats`, `saveFullDiagnostics`) took any plate from any client and wrote `player_vehicles.mods` and `vehicle_diagnostics`. A player could overwrite anyone's car mods and damage.
- **Now:** a write needs the plate's owner, or a player sitting in that car (checked on the server, so a friend driving the car still syncs it). Props must be a table under 64 KB; client engine/body values are clamped.
- **Tests:** `mechanic_garage_sync_spec` (5; 3 fail on the old code).
- **Not changed:** the unused copies in `[custom]` and `[jobsystem]` (not in the staging config).

**SQL files on a fresh database:**
- `pfm-vehicleshop/vehshop.sql` (3b3c378): columns, the unique plate index and the foreign key use `IF NOT EXISTS`, so the file loads after pfm-garages and on a re-import.
- `pfm-inventory/migrate.sql` (1631da1): this was a one-time copy from the old qb-inventory tables, not an install file. It is now `upgrade/migrate_from_old_qb_inventory.sql` with a note on when to run it, and uses `INSERT IGNORE` so a second run never overwrites newer inventories. README updated.
- `pf-garageuionly/sql/garage.sql` (-pfscripts- 7d7e3a3): a duplicate `plate` key in the standalone table, and two indexes on an `owner` column QBCore doesn't have (now `citizenid`).
- **Test:** `tests/realdb/sql_install_check.js` (5648d4f) loads each file twice on a fresh database and checks the inventory upgrade keeps newer rows. Run: `PF_TEST_DB="mysql://root@127.0.0.1:3399" node realdb/sql_install_check.js`. Checked on MariaDB (XAMPP); the `IF NOT EXISTS` forms are MariaDB syntax and would fail on MySQL 8.

**Found, not fixed:** pf-garageuionly's `server/integration.lua` also queries `player_vehicles.owner`. The resource has no manifest and doesn't run, so nothing breaks today.

**Totals:** mocked **393 passed** (48 files), real database **69 passed**, SQL install check passed. No staging run this time: the changes are server event checks and SQL files, covered by the tests above. Nothing pushed.

## Batch 6 — 2026-10-25: full server-event sweep, farming, parallel ledger test

The working list is now `docs/TASK_LEDGER.md` (statuses, evidence, next task per requirement). This section is the evidence summary.

### Server-event sweep (ledger 0.6)
- **Scope:** every remotely callable server handler in the started resources, about 1,150 in 70 resources. The work was split into 8 groups audited in parallel (robberies/side jobs, police MDT, police/admin/characters, jobs/tablet, mechanic, business/government, vehicles/phone/houses, core/inventory).
- **Result:** about 120 abusable handlers fixed. Each fix has a regression test that was run against the previous code and failed there. Commits and per-group open items are in the ledger's "Sweep results" table.
- **The most serious ones:**
  - SQL injection: `pfm-management` GetEmployees, `pfm-phone` FetchResult.
  - Money or items from nothing:
    - pf-government `bill:pay` charged no one;
    - loans were created with AddMoney;
    - free IDs on request;
    - prison item pay;
    - Gruppe6 legacy server and deposits;
    - garbage per-throw pay;
    - mechanic DPF, parts, NOS bottles and chop salvage;
    - outfit bags;
    - weapon ammo to 250;
    - forged item info on give;
    - vehicle sale return as any model;
    - repeat spawns of bought or impounded cars.
  - Acting on other players:
    - house transfer to anyone;
    - any stash, trunk or apartment;
    - doors with another player's access;
    - keys to any car;
    - staff actions on any citizen (management, mechanic, MDT officers).
  - Police records: about 100 MDT handlers had no job check. Now gated in `server/access.lua`.
- **Functional bugs found on the way:**
  - garbage crews were never paid, because the client never sent `returnTruck`;
  - `GetVehicleNumberPlate` is not a native (pf-mechanicjob engineering);
  - `AddRecentCall` errored on every call;
  - officer tables were never created (`ensureTables` nil).

### Ledger under truly parallel database sessions (ledger 1.5)
- **New test:** `tests/realdb/ledger_parallel.js` runs N processes, each with its own connection, against one database. They send the same and different idempotency keys at once.
- **Found:** transfers failed with `ledger_write_failed` when two inserts drew the same tx_id. Ids came only from `math.random`, and a clash was reported as a failure. No money moved wrongly; the payments were lost.
- **Fixed in 34addb5:** ids now include time and a counter, and a clash is retried with a new id.
- **Result:** 6 workers running at once for about 2.4 s. Every key moved money once, balances are exact and reconciliation is clean.

### Farming (ledger 5.1), new resource `[pfscripts]/pf-farming` (6346780)
- Persistent plots (`pf_farm_plots`, migration v1). Growth comes from timestamps and only while watered, so it continues offline and across restarts.
- The server places plots at the player's position; ownership and reach are checked; one harvest per plot.
- Produce is a normal perishable item. The market pays by freshness and refuses spoiled produce. Seeds and sales go through the ledger.
- Selling to businesses uses pf-stores' existing player suppliers. Suppliers can now stock food only while it is fresh or good (b94751f), so stale produce can't come back out of a delivery as fresh.
- Tests: `farming_realdb_spec` (14, real DB) and the supplier freshness test in `supply_chain_realdb_spec`.

### Tests actually run (2026-10-25)
- **Mocked:** `node harness.js`: **681 passed, 0 failed, 96 spec files**.
- **Real DB** (throwaway MariaDB 10.4):
  - `realdb/run.js`: 84 passed in 7 spec files (21 supply chain, 14 farming, 14 injuries, 13 ledger, 16 restaurants, 3 shared accounts, 3 computer orders);
  - `realdb/ledger_parallel.js 6`: passed;
  - `realdb/sql_install_check.js`: passed.
- **Staging FXServer** (`docs/staging/server.staging.cfg`, fresh `pf_staging` database with 29 install SQL files):
  - 99 resources started, pf-farming migration v1 applied;
  - no script errors apart from the known ones: ox_lib missing (pf-mechanicjob, illenium-appearance) and the kq_wheeldamage entitlement;
  - the first run showed missing MDT tables because I had not loaded `pf-policemdt-qb.sql`; with it loaded, the second run was clean.
- **Not covered:** pf-mechanicjob does not start without ox_lib, so its sweep fixes are covered only by mocked tests. No game client connected.

### Install SQL note
`pf-government/sql/migration_monthly_budget_infrastructure.sql` is an upgrade from weekly to monthly budgets. It fails on a fresh database (`Unknown column 'weekly_budget'`), which is expected for an upgrade file.

### Batch 6b — government business registry, deliveries, freshness, job-business supplies (2026-10-25)

**Government business registry (ledger 2.2, 6.2):**
- **What was there:** pf-government had a business registry (licenses, utilities, closure), but no business resource used it. The restaurant revenue hook existed, but restaurants never registered, so it did nothing. Had they registered, its tax step would have created money: it credited the treasury first, then charged a society named after the business id.
- **Now:**
  - Restaurants (`restaurant:<id>`, owner from staff), player-owned stores (`store:<id>`) and mechanic shops (`mechanic:<job>`) register with their own ledger account.
  - Each sale is recorded once (`pf_gov_business_revenue`, unique key). Business tax is one keyed transfer from the business account to the treasury; an underfunded business is billed instead.
  - Sales stop while the government has closed the business or cut its power (`CanBusinessTrade`).
  - Daily utility bills are paid automatically from the business account when it can pay.
  - Paying the last delinquent bill restores power the system cut (staff cut-offs stay).
  - `business_status`, `closed_at` and `account_ref` are added at start. The first two used to be added only when staff opened the businesses page, so closure checks failed on a fresh install.
- **Commits:** 6f1b81c, d54d863, 1817c58, 15e9229, 2266b9d.
- **Tests:** `government_business_realdb_spec` (7, real DB; all fail on the old code), plus mocked store and mechanic registry tests.
- **Staging:** both restaurants registered with utility accounts on a fresh database.

**Deliveries and freshness (ledger 3.2, 4.2):**
- **Delivery grace:** packed deliveries age at the normal rate for 30 minutes after delivery, then at the outdoor rate until unpacked (`DeliveredInfo`). Restaurants and job businesses stock with it; pf-stores passes the delivery time (31182bd).
- **Cold storage:** restaurant fridges and freezers stop cooling while the government has cut the power (dd28254).
- **Sunlight:** ground drops spoil at the sunlight rate in clear weather from 11:00 to 16:00 game time (541d97b).
- **Tests:** `restaurants_realdb_spec` (delivery grace, power cuts), `freshness_spec` (sunlight).

**Job-business supplies (ledger 7.1, 2.1):**
- **What was there:** mechanic shops and other job businesses ordered through a separate list in pf-computer's data file. The business paid, and nothing ever added the goods anywhere.
- **Now:** they use the shared order service (buyer kind `jobbiz`):
  - priced from their catalog, known items only;
  - paid from the job's bank account;
  - collected by the mechanic pickup run, or delivered by a trucker on a pallet once a delivery point is set;
  - unpacked once into `bizstash-<job>`.
- **Business stash points:** these never opened, because the client event had no handler. They now open the business stock after a server check of job and position.
- **Commits:** 131718c, e65c680. **Tests:** `computer_orders_realdb_spec` job mode (4).

**Smaller items:**
- pf-jobs and pf-tablet refresh on `QBCore:Server:SetDuty` instead of accepting the client duty event (33ace78).
- Ledger tx ids fixed (34addb5, see batch 6).

**Tests actually run at the end of this batch:**
- `node harness.js`: 689 passed, 0 failed, 96 files.
- `realdb/run.js`: 98 passed in 8 files.
- `realdb/ledger_parallel.js 6`: passed.
- Staging FXServer on a fresh database: 99 resources, no new errors (ox_lib and kq_wheeldamage only), all migrations applied, restaurants registered.

**Not verified:** anything in a game client; pf-mechanicjob at runtime (needs ox_lib).

**Staging restart finding (be48b94):**
- **Setup:** a restart against an existing staging database, the case a live upgrade goes through.
- **Problem 1:** pf-restaurants registered its businesses before pf-government had finished starting, so the new `account_ref` column did not exist yet.
- **Problem 2:** after the first fix, two registrations at once both ran the same `ALTER`, so one business lost its account.
- **Fix:** the schema is now made on first use, once, with other callers waiting.
- **Checks:**
  - reproduced and fixed on staging (both restaurants have their account, no errors);
  - `government_start_order_realdb_spec` (2, fails on the old code).
- **Additional work since the 6b section:**
  - restaurant inspections on the government record (b99d811);
  - employee counts (7e458ba).
- **Final totals:**
  - mocked 689 passed;
  - real database 103 passed in 9 files;
  - staging: 99 resources, only the known ox_lib and kq_wheeldamage failures.

**Decisions applied (2026-10-25):**
- **Business licenses:** record-only. Not required to trade; no change.
- **Government transfers drive ownership (b5d22d2):** `business:updateOwner` changes the real owner first, then the record.
  - Stores: pf-stores `SetStoreOwnerFromGovernment` (empty = for sale).
  - Restaurants: pf-restaurants `SetOwnerFromGovernment` (the old owner leaves the staff).
  - Both exports accept pf-government only and need an existing character.
  - Mechanic shops are job-owned and are refused.
  - Tests (real DB): government_business (3), restaurants (1), supply_chain (1).
- **No more auto-bans (e86e9e8):** pfm-pawnshop and pfm-recyclejob refuse and log a request from too far away. Previously one miss (pawnshop) or three (recycling) banned permanently. Tests: `recycle_spec`, `pawnshop_distance_spec` (both fail on the old code).
- **Store prices:** left to you: every purchasable store in `pf-stores/shared/config.lua` still has price 0.
- **Totals:**
  - mocked 691 passed;
  - real database 108 passed in 9 files;
  - staging 99 resources, known failures only.


## Batch 7 — 2026-10-25: end-to-end supply chain, restaurant ordering, premises and equipment

### 1. Starting and final commits

| Repository | On GitHub (`origin/main`) | Start of this batch | End of this batch |
|---|---|---|---|
| `[qb]` (PFModsFiveM/-qb-) | 0d5e7d1 (batch 2) | a398ea4 | see `git log` (last code commit c99ba43) |
| `[pfscripts]` (PFModsFiveM/-pfscripts-) | fa4482d (initial import) | b5d22d2 | d1be559 |

- **Branch:** `batch5-security-supply-chain` in both repositories.
- **Pushed state:** GitHub has only batch 2 (`-qb-`) and the initial import (`-pfscripts-`). Batches 3–7 exist only on the local branch, which contains all of `origin/main` (0 commits behind). Nothing was pushed or deployed.

**Standalone repositories, checked today against `[pfscripts]`:**
- **pf-government, pf-trucking, pf-policemdt:** every differing file equals our base (fa4482d), so `[pfscripts]` is newer and nothing needs importing.
- **pf-jobsystem:** the only extra file is the duplicate `server/gruppe6.lua`, removed on purpose in batch 6.
- **pf-computer (2026-03) and pf-mechanicjob (2025-08, real remote pf-advancedmechanicjob):** their differences are older versions, not newer work.
- **Canonical copies:** the `[pfscripts]` ones, unchanged from earlier batches.

### 2. Files changed

**`[qb]`:**
- `pfm-worldobjects/{server,client,config}.lua`: fixtures, float clock.
- `pfm-inventory/server/{freshness,functions}.lua`: `FreshnessAtPercent`, `SetInventoryCapacity`.
- New tests: `tests/realdb_specs/supply_chain_e2e_realdb_spec.lua`, `government_premises_realdb_spec.lua`, additions to `restaurants_realdb_spec.lua`.

**`[pfscripts]`:**
- `pf-computer/{server/main.lua, client/main.lua, ui/js/script.js}`
- `pf-government/{server/premises.lua (new), server/businesses.lua, config.lua, fxmanifest.lua, client/nui.lua, html/script.js}`
- `pf-restaurants/{server/inventory.lua, server/persistence.lua, server/stations.lua, config/shared.lua}`
- `pf-stores/{server_orders.lua, server.lua, shared/config.lua}`
- `pf-trucking/server.lua`

### 3. Features implemented

**Restaurants can order supplies (889b37b):**
- **What was wrong:** nothing in any UI sent `pf-restaurants:server:orderSupplies`. On PF Computer a restaurant boss got the job-business catalog, which is empty for restaurant jobs. This is the "empty supplier catalog" from earlier reports.
- **Now, on PF Computer:** a restaurant job orders as its restaurant.
  - The catalog is the configured ingredients at the server's unit prices (`GetRestaurantForJob`, `GetSupplyCatalog`).
  - Create, list, cancel and collect all use the shared order service with buyer kind `restaurant`.
  - Delivery is offered when the restaurant has a receiving point. The pallet's rotation comes from `receiving.deliveryHeading`.

**One shared order lifecycle, used end to end:**
- **Users:** stores, restaurants and job businesses all use pf-stores `PFOrders`.
- **Delivery states:** `created → paid → awaiting_supplier → awaiting_delivery → assigned → in_transit → delivered → unpacked`.
- **Pickup states:** `paid → ready → delivered → unpacked`.
- **Side states:** `cancelled` and `failed`. A driver release or timeout returns to `awaiting_delivery`.
- **Stored per order:** order id, buyer kind and id, purchaser, items with server prices, totals, markup, freight payout, payment transaction, supplier, driver, delivery method, pallet id, every status change with actor and note, and timestamps.
- **Duplicate prevention, new in d71ec7c:**
  - one order at a time per business;
  - the same items and method from the same person within `DuplicateWindowSeconds` (10) returns the existing order instead of charging again.
- **Cancellation policy:** allowed with a full refund only while nobody has taken the delivery (`awaiting_supplier`, `awaiting_delivery`). Refused once a driver is assigned.

**Truckers, AI fallback, pallets, unpacking:** unchanged in design (batches 2d–6), now verified end to end for restaurants; see the tests.

**Dish freshness (9d460de):**
- A dish starts as fresh as the least fresh ingredient lot it was cooked from (`Config.Cooking.DishFreshnessFromIngredients`).
- Quality and poison risk already followed the ingredients.

**Government premises and equipment (8207f4d, 8333bbd, e08f590, d1be559):**
- **Approving slots:** officials with the `businesses` permission approve typed slots at their own position:
  - cooking station, register, office, locker, delivery point, fridge, freezer, shelf;
  - limits: at most 40 per business, at least 1 m apart.
- **Who may buy:** the owner on the government record, the restaurant owner role (`premises.buy`, which only `all` grants), or the boss of a job-owned business.
- **Purchase checks:** the buyer stands at the slot and the slot is empty and of the matching type.
- **Payment:** one keyed ledger transfer from the business account. If the slot was filled meanwhile, the money comes back under its own key.
- **The prop:** a persistent pfm-worldobjects fixture at the approved position and heading, restored after restarts, with no delivery actions.
- **Blocked:** closed businesses cannot buy, and slots in use cannot be withdrawn.
- **Restaurant capacity:** installed fridges, freezers and shelves enlarge the matching restaurant stock area.
- **UI:** "Premises & Equipment" in the government business registry (officials), and "Premises" in the PF Computer Business Manager (owners).

**PF Computer Business Manager uses the authoritative data (bd39271):**
- **Inventory:** it showed `Math.random()` stock and its editor wrote a data-file number nothing used. It now lists the real stock from the business's stashes, with freshness. Typed quantities are refused (`stock_is_physical`).
- **"Add initial inventory" option on new menu items:** removed. It called a handler that does not exist and would have created stock from nothing.
- **Dead buttons:** `stash:place`, `wages:get` and `wages:set` were called by the UI but never forwarded by the client, so the buttons did nothing. They are forwarded now.

### 4. Security fixes confirmed in this batch
- **Duplicate supply orders from resent requests:** charged twice. Fixed in d71ec7c.
- **Fake inventory numbers:** a boss could set any "stock" count in the computer data file. That count is no longer used, and the write is refused.
- **Re-checked from the report, still fixed in the current code:**
  - `pf-computer:server:supplies:completeOrder` is server-only and only collects the order the player's own pickup run was started for;
  - `deleteProp` is owner or admin only;
  - mechanic register and tablet totals come from server prices;
  - `AcceptJob` finds contracts by id;
  - there is one shared-account model (batch 5, fa08b06).

### 5. Database and migrations
No new versioned migrations. The new tables are created at start and on first use, idempotently and once (a lock against concurrent first use):
- **pf-government:**
  - `pf_gov_premises_slots`;
  - `pf_gov_premises_equipment` (unique `slot_id`).
- **pfm-worldobjects:** fixtures use the existing `pf_world_objects` table (`kind = 'fixture'`, `state = 'installed'`).
- **Upgrade:** start the resources; nothing to run by hand.
- **Clocks (8f2f803):**
  - Millisecond clocks in pf-stores, pf-trucking, pf-restaurants and pfm-worldobjects use float maths (`os.time() * 1000.0`).
  - FiveM Lua 5.4 is 64-bit, so stored values are unchanged.
  - The 32-bit test VM used to wrap them.

### 6. Dependencies and start order
Unchanged from batch 5, section 10:
1. oxmysql, ox_lib, PolyZone, menuv;
2. pfm-core;
3. `[qb]` (pfm-banking, pfm-inventory, pfm-worldobjects);
4. pf-government;
5. pf-scoreboard;
6. pf-trucking;
7. pf-computer;
8. pf-jobs;
9. pf-tablet;
10. pf-mechanicjob;
11. pf-stores;
12. pf-restaurants.

Notes:
- **New cross-resource calls:**
  - pf-computer → pf-restaurants (`GetRestaurantForJob`, `GetSupplyCatalog`, `GetStockStashes`) and → pf-government (`ListPremisesFor`, `BuyPremisesEquipment`);
  - pf-government → pfm-worldobjects (`CreateFixture`) and → pf-restaurants (`HasPermission`).
- **Missing dependencies:** each call fails closed: no order, no purchase, a clear error.
- **ox_lib:** pf-mechanicjob uses it client-side only (context menus, progress circles, an input dialog). Install it; removing it would remove those menus.

### 7. Tests actually run (end of batch)
- **Mocked (`node harness.js`):** 691 passed, 0 failed, 97 files.
- **Real database (`PF_TEST_DB=mysql://root@127.0.0.1:3399 node realdb/run.js`):** 141 passed, 0 failed, 11 files.
- **New: `supply_chain_e2e_realdb_spec` (24).** It runs the real pf-computer, pf-stores, pf-trucking, pfm-worldobjects, pf-restaurants, pfm-inventory and the pfm-banking ledger together:
  - **Ordering:** the restaurant catalog is not empty; an unfunded restaurant is refused; prices come from the server; the restaurant account pays into escrow; a resend is not charged twice; the order points at its ledger transaction.
  - **Supplier and drivers:** an AI supplier takes it; of two truckers, one wins; no cancellation after a driver takes it; cargo is loaded only at the warehouse.
  - **Restart mid-delivery:** pf-stores and pf-trucking restart with the same driver and nothing lost.
  - **Delivery:** the driver is paid once, escrow is settled, and a sealed pallet appears at the receiving point with its heading.
  - **Isolation:** another restaurant, a stranger and forged requests cannot open, move or unpack it; contents are sealed.
  - **Pallet restart:** pfm-worldobjects restarts and restores position, rotation and contents.
  - **Unpacking:** goods are unpacked once into the right storage, aged by the wait, with the full status history recorded.
  - **Computer:** the PF Computer stock shows the real items; typed quantities are refused; premises go through pf-government.
  - **Kitchen and sale:** cooking uses the delivered stock and the dish keeps its freshness; the customer pays the server price, the restaurant gets the revenue and the government the tax.
  - **Other paths:** AI delivery fallback with a pallet; cancellation refunded once; another restaurant sees none of the orders.
  - **Dependency failures:** bank down means nothing is ordered; order service down means no unpacking; bank down means no payout, then exactly one payout after recovery.
  - **Ledger:** reconciles.
- **New: `government_premises_realdb_spec` (8):**
  - slot approval and refusals;
  - purchase permissions, type, distance, payment once, underfunded, closed;
  - fixture position and rotation across a restart;
  - job-boss purchases;
  - who may list premises.
- **Restaurants:** capacity follows installed equipment (`restaurants_realdb_spec`, 23).
- **Staging FXServer, fresh database:**
  - 99 resources start; the only failures are ox_lib (pf-mechanicjob, illenium-appearance) and the kq_wheeldamage entitlement;
  - all migrations applied;
  - restaurants registered with their accounts.

### 8. Still needs a real FXServer test with clients
- **Trucking and pallets in game:** a trucker's trailer connect (`cargoLoaded`) and arrival; pallet entities seen by several players; pallet and fixture targets.
- **UIs in a client:** the PF Computer Order Supplies (restaurant mode), Inventory and Premises sections, and the government Premises dialog.
- **pf-mechanicjob:** anything at runtime (needs ox_lib), including the mechanic pickup run collecting a shared order.
- **Live data:** the order service and premises against a copy of the live database.

### 9. Known issues and migration risks
- **Old pf-computer orders:** job-business orders from the data file stay listed and collectable but deliver nothing, as before. The shared service handles every new order.
- **Store prices:** purchasable stores still cost 0 until you set prices in `pf-stores/shared/config.lua`.
- **Existing hardware:** existing restaurants get no premises slots until officials approve them. Nothing changes for them until then.
- **Heat:** `hot` spoilage is still unused, as decided earlier.

### 10. Remaining work, in priority order
1. **ox_lib:** install it (your action) and re-run staging so pf-mechanicjob starts.
2. **Client test:** with two clients on staging, run the end-to-end path from section 8.
3. **Live database:** test on a copy of the live database.
4. **Tablet:** connect PF Tablet to the same supply-order and stock views. It still has its own job apps.
5. **Mechanic parts:** use the shared stock (`bizstash-<job>`) in mechanic repairs, which still use personal inventory items.
6. **Register equipment:** let installed registers and cooking stations add POS points and stations to restaurants. Today only storage capacity follows equipment.
