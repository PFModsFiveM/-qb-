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

### Batch 7b — ox_lib on staging, pf-mechanicjob runtime (2026-10-25)

**ox_lib:**
- **Version:** v3.41.0, the latest release, from github.com/overextended/ox_lib (`ox_lib.zip`, 3,479,914 bytes, sha256 `fc7cdbcf2860bcbf692172516de13339bb4e509a4d5ad367c26ea4a1a69e3193`). Downloaded with your approval into the **staging copy only**; the live resources are unchanged.
- **Why it was checked:** it was published on 2026-10-25, the same day it was installed.
- **Code scan:** no unexpected network calls, shell access, encoded payloads or dynamic code loading.
  - **Network:** the only HTTP calls are the version check (GitHub API) and the optional logger, which posts only to a provider you configure.
  - **Dynamic loading:** the only `load` calls are the module loader reading resource files.
- **Contents:** the zip also contains the `require` resource (`cfxlua-require`), which ox_lib now depends on. A `.git` folder with git's stock hook samples was left out.
- **Requirements:** server build 7290 or newer and OneSync. The local FXServer build met them.

**Start order (both the staging config and `docs/staging/server.staging.cfg`):** `oxmysql`, `cfxlua-require`, `ox_lib`, `pfm-core`, `[qb]`, `[standalone]`, `[voice]`, `[pfscripts]`.
- **The first run had ox_lib after `[standalone]`:** illenium-appearance then failed with "ox_lib must be started before this resource".
- **Two comment lines contained `;`:** a cfg file treats it as a command separator even inside a comment, which produced "No such command pfm-ambulancejob" and "No such command it". Fixed.

**Result (staging FXServer, existing staging database, 140 s):**
- 102 resources started, including ox_lib, cfxlua-require, illenium-appearance and pf-mechanicjob.
- No script errors.
- pf-mechanicjob created its 12 tables.
- pf-computer maps the five mechanic jobs to pf-mechanicjob as their data provider.
- The only remaining failure is kq_wheeldamage, a paid Tebex asset that needs its entitlement on the server's license key.
- No client connected, so pf-mechanicjob's menus and missions are still untested in game.

**ox_lib security advisory (not changed, a decision for you):**
- **The warning:** `sv_stateBagStrictMode` is off, so clients can change replicated state bags.
- **Why not just enable it:** about 20 client writes in our resources set replicated state: the QBCore `inv_busy` flag (pfm-inventory, pfm-drugs, pfm-diving, pfm-houses, pfm-smallresources), and pfm-fuel's nozzle and fuel. Enabling strict mode would break those.
- **What the flag guards:** the server only uses `inv_busy` to refuse opening an inventory while the client says it is busy, so a client clearing its own flag gains little.
- **The safe path:** move those writes to the server first, then enable strict mode.

**For the live server (your action):** install ox_lib v3.41.0 together with the `cfxlua-require` folder from the same zip, and start them right after oxmysql.

## Batch 8 — 2026-10-26: MDT, district power, tablet Business Manager

Checks run: Lua parse checks and `node --check` on every changed file, plus each new SQL query run against the throwaway staging database. Per the master mission, the full suites were not rerun; nothing was tested with a game client.

| Change | Repository and commit |
|---|---|
| `/mdt_seed` is admin-only (it already was) and now also off unless `Config.AllowSeedCommand = true`, because it writes sample warrants and reports into the real tables | -pfscripts- 3243a6e |
| District power reaches the world: pf-government publishes which districts have power (`GlobalState.pfGovDistrictPower`, every 10 s, only on change). A client in a cut district gets its lights switched off through pfm-weathersync | -pfscripts- ee0aad5, -qb- 3e8fab9 |
| MDT citizen profile, Licenses tab: government licenses, unpaid bills and fines (with total), owned businesses. Read only | -pfscripts- c1e5481 |
| PF Tablet Business Manager rebuilt on real data, replacing a mockup with hard-coded businesses whose buttons only edited browser data | -pfscripts- b97b392 |

**District power details:**
- **Zone mapping:** GTA zone codes map to the six government districts in `Config.InfrastructureWorld.ZoneDistricts`. County zones are not listed, so they never lose power. Adjust the list freely.
- **Admin blackout:** pfm-weathersync's `/blackout` is kept separate. The light state is `adminBlackout or districtOutage`, so neither one turns the other off.

**Tablet Business Manager:**
- **Government pages:** Overview, Registry, Compliance, Taxes and Audit read `pf_gov_businesses`, `pf_gov_business_revenue`, `pf_gov_bills`, `pf_gov_licenses` and `pf_gov_audit_log`. They need the government `businesses` permission.
- **Ownership changes:** go through the new export `pf-government:TransferBusinessOwnershipAs(src, …)`. That export checks the permission, updates the store or restaurant, and writes the audit log. Mechanic shops are job-owned and cannot be transferred.
- **My supplies:** the player's restaurant, job-business and owned-store orders, read with `pf-stores:ListOrdersFor`. That call checks the player may manage the buyer.
- **Removed:** the mock pages (Analytics, Employees, Settings) and the "Create business" form. Businesses register themselves when they are bought or opened.

**Still open (moved to the checklist):**
- **Restaurant equipment effects:** registers and stations.
- **Loan defaults:** handling of missed repayments.
- **Business employees:** a list in the government registry.
- **Job-garage fleet decision.**
- **State-bag strict mode:** move client writes to the server first.
- **Standalone repository sync.**

## Batch 9 — 2026-10-26: equipment effects, loans, registry employees, standalone sync

Checks run: parse checks on every changed file, plus the government real-DB specs. Those are 26 tests across 4 files, including the new loans spec (5 tests); a separate employees spec adds 3. Nothing was tested with a game client.

| Change | Commit |
|---|---|
| **Premises equipment in restaurants:** a bought POS Register becomes a working register, and a Grill Station or the new Deep Fryer becomes a cooking station. Both are copied from a configured station of that type and appear on server and clients, refreshed when equipment changes | -pfscripts- f506011 |
| **Loan servicing:** each due date adds interest and an installment, claimed once by a guarded update. Auto-pay takes it from the business account; otherwise it counts as a missed payment. A loan defaults after 3 misses (marked non-compliant; closing is optional and off). Paying what is due restores it. The `Config.Loans` block holds these settings | -pfscripts- 730ecac, test -qb- bffd5b0 |
| **Registry employees:** `GetBusinessEmployees` asks restaurants (new `GetStaffList` export), mechanic job members, or the owner, and keeps `employee_count` in step. Shown in the tablet registry. The restaurant `getLoans` callback now returns real loans | -pfscripts- 874d8a0, test -qb- a7b0970 |
| **Standalone repositories** synced from -pfscripts- 874d8a0 | see the checklist, section 11 |

**Defects found and fixed along the way:**
- **Loans used the wrong account:** grant and repayment moved money to or from `society:<business_id>` (for example `society:restaurant:bs`), which is not the business's account. They now use the registry's `account_ref`.
- **A crash the new test caught:** loans.lua called a function that is local to callbacks.lua, so it would have crashed in game. Fixed.
- **Installment idempotency keys:** keys for two due dates in the same second could collide, so the ledger replayed the earlier payment instead of charging. Each key is now unique; the guarded claim prevents double processing.

## Batch 10 — 2026-10-31: one app platform for the tablet and the computer, news, government field work, job links

The owner's brief: apps on both devices share code, pf-jobs feeds the job apps, the computer is
connected to every system, news is run by the news job and automatic for city-hall changes (but
not for everything), government field work is on the tablet, and jobs rely on other jobs, with a
full list of the links. Branch `main-9hq3gi` in both repositories. Nothing was tested with a game
client.

### New resources ([pfscripts])
| Resource | What it is |
|---|---|
| `pf-devices` | The app platform. One server-side registry (access by job and grade, duty, government permission, admin, custom check); one JS module per app, mounted by whichever shell is open; an RPC bridge with the real player id, rate limit and size limit; a push channel; installable apps with an App Store (paid installs on the ledger, `pf_device_apps`); websites shown identically in both browsers; launcher apps for screens that stay full-screen (the MDTs). Developer guide: `pf-devices/README.md` |
| `pf-services` | City events (one timeline, `pf_city_events`; news and police listen) and service requests between jobs (`pf_service_requests`: atomic accept, verified completion, rewards held from the payer and paid on the ledger). Apps: Dispatch (workers), Services (citizens), Directory |
| `pf-news` | The newsroom and the News app / news.ls website (same UI) |
| `pf-citizen` | Mail, Bills, Documents, Calendar for the phone, tablet and computer (see below) |

### What changed, by owner requirement
| Requirement | Done | Commits |
|---|---|---|
| Apps share code on both devices | pf-tablet and pf-computer are shells. Platform apps run as one module in both: Taxi, Gruppe 6, Garbage, Bus, Trucking, mechanic Work Orders / Cash Register / Management, Dispatch, Services, Directory, Supplier, Scrap List, Dive Guide, Hot Dog Stand, News, Newsroom, the government apps, the citizen apps, the App Store. The police and EMS MDTs open from either device. The tablet's hardcoded job wiring (about 40 callbacks and forwards) is gone | -pfscripts- 9f17e9c, 5e58d41, 3a4d045 |
| pf-jobs feeds the devices | pf-jobs registers its apps; app actions run the existing hardened job code for the real player | 3a4d045 |
| Computer connected | Platform apps on the desktop and start menu; platform websites in the computer browser; computer clean-up (see below) | 9f17e9c, see below |
| News run by the news job, automatic for city hall, not for everything | City Desk articles from presets for `auto` events (bursts become one digest, exactly once across restarts); `lead` events become reporter leads; the newsroom with grades (write, publish, edit); reporter bonuses; business ads. pfm-newsjob vehicles, duty and equipment are server-checked. Reporter grades 0-4 added | cb97962, -qb- 60bfc61 |
| News public with the app installed, and a website in both | The News app is installable; news.ls is the same module | cb97962 |
| Government on the tablet | Fines (nearby people only), Inspections (only at the business), Business Requests, City Budget, Announcements, Business Setup (equipment positions and delivery zones where the official stands); City Hall Requests for owners; delivery zones used by supply orders | cb97962, 1005687 |
| Jobs rely on jobs, with a full list | `docs/JOB_LINKS.md`: police → tow → impound lot, mechanic → tow, citizen services, robberies → police dispatch + news, downed players → EMS, 911 → Dispatch, court and warrants → newsroom, weather and races, City Hall → news, business → news ads, business → City Hall requests, store robbery → owner | e686e9f, 58b0dee, -qb- 512bc9d, 19c1d62 |

### Defects found and fixed on the way
- **pf-computer manifest:** the manifest never shipped `cityhall.js` or `domains-theme.css`, so the City Hall app and the domains theme never loaded in game.
- **pf-jobs bus:** the bus server used a global `QBCore` that no file sets, so every bus event errored.
- **pf-jobs Gruppe 6 client:** a syntax error (`while … then`) stopped the whole Gruppe 6 client from loading.
- **pf-jobs taxi:** the raw taxi events now need the taxi job. A random VIP call made the payout spec flaky.
- **pf-jobs Gruppe 6 app:** the app received every party on the server; it now gets only the player's own.
- **pf-tablet:** removed a dead client-total cash register, which had no server handler.
- **pf-mechanicjob:** the mechanic's tow request sent client values to events nothing handled. It is now a real request.
- **pfm-houserobbery:** the burglar alarm was rolled on the client. It is now rolled on the server.
- **pf-government:** bill waivers wrote a column that did not exist, so they failed silently. Announcements could be posted by any government grade; they now need the announcement permission.
- **pf-services review:**
  - a paid request closed by the system before anyone took it now refunds the payer;
  - request details sent to clients are whitelisted, so internal ids stay on the server.

### Citizen apps (`pf-citizen`, with pfm-phone)
- **Mail:**
  - one mailbox per citizen in the phone's `player_mails` table, so the phone, tablet and computer show the same mail;
  - folders, threads, search and an address book;
  - offline delivery, and broadcasts reach each citizen once;
  - the sender's identity always comes from the server, with rate limits;
  - pf-citizen handles City Hall announcements and laws itself, so offline citizens get them too.
- **Bills:**
  - one view of government bills and fines (including those of businesses the player manages) and phone invoices;
  - each is paid through its owner's path: the new `PayBillFromPlayer` export (one lock shared with the City Hall terminal, and a refund of anything it could not apply) or the phone's new `PayInvoice` / `DeclineInvoice` exports;
  - new bills arrive by push and by mail.
- **Documents:** stored on the server, with read-only links or copies, signatures (server identity and a fingerprint), and mail attachments.
- **Calendar:**
  - personal events;
  - city events (government `events` permission);
  - business events for staff;
  - reminders.
- **Fixed:** a phone invoice became unpayable forever after one failed attempt, because the failed ledger key was final. Later attempts now use retry keys and still charge once.

### The computer without fake data (`pf-computer`)
The final code is in -pfscripts- 97ed938, the last snapshot commit; its message still says WIP.
- **Gone:** the fake Mail (localStorage, with plaintext passwords), the six hardcoded Bills, local Documents and the broken Calendar. Those icons open the pf-citizen apps.
- **Job Board on MySQL:**
  - posts must belong to a business the poster really manages;
  - applicant identity comes from the server;
  - the boss is mailed about each applicant;
  - hiring is real: an online applicant accepts the offer, an offline one gets the job at next login;
  - "Jobs in the city" lists the job catalogue.
- **Business Manager, from real tables:**
  - employees, with promote, demote and fire done by pfm-management's rules;
  - stock from the real stock stashes;
  - analytics from the ledger and the government's revenue reports;
  - wages paid through the pfm-core job grades.
- **Persistence:** everything that mattered in `pc_data.json` moved to MySQL, imported once.
- **Security fixes:**
  - server identity on job applications and chat;
  - domain transfers go only to verified characters;
  - owners' citizen ids are no longer listed;
  - website saves are bounded in size;
  - business blips must be placed near the boss;
  - external programs launch on their own resource;
  - `OpenComputer` / `CloseComputer` exports;
  - pickup runs survive a restart.
- **Other:**
  - the fake City Hall and the dark-web market are removed; government staff open pf-government's own UI from any computer through launcher apps;
  - announcements go through pf-government;
  - order supplies use the government delivery zones.

### Database migrations (all through `pf_schema_migrations`, rerun-safe)
- **pf-devices v1:** `pf_device_apps`.
- **pf-services v1:** `pf_city_events`, `pf_service_requests`.
- **pf-news v1:** `pf_news_articles`, `pf_news_events`, `pf_news_leads`, `pf_news_views`, `pf_news_ads`, `pf_news_payouts`.
- **pf-government v1:**
  - new tables `pf_gov_delivery_zones` and `pf_gov_business_requests`;
  - new columns: `district` on businesses, `follow_up_at` and `request_id` on inspections, `notes` on bills.
- **pf-citizen v1:** `player_mails` extended (folders, threads, sender identity, attachments, refs). New tables:
  - `pf_citizen_mail_broadcasts`, `pf_citizen_broadcast_receipts`;
  - `pf_citizen_documents`, `pf_citizen_document_shares`, `pf_citizen_document_signatures`;
  - `pf_citizen_events`, `pf_citizen_event_subs`, `pf_citizen_event_reminders`;
  - `pf_citizen_bill_history`.
- **pf-computer:**
  - v1: `pf_computer_businesses`, `pf_computer_wage_caps`, `pf_computer_domains`, `pf_computer_chat`, `pf_computer_pickup_runs`, `pf_computer_meta`, `pf_computer_job_posts`, `pf_computer_job_applications`;
  - v2: the one-time import from `pc_data.json`, which is kept as a backup.

### Tests
Final runs with everything in:
- **Mocked:** 882 passed, 0 failed (119 spec files).
- **Real database:** 245 passed, 0 failed (24 spec files, MariaDB 10.11).
- **Browser (jsdom):** pf-devices runtime 7 passed; citizen apps 5 passed.
- **Syntax:** all 184 changed Lua files parse, and every app module passes `node --check`.
- **Starting point:** batch 9 ended at 695 mocked and 149 real-database tests.

### Still to check in game
See `FINAL_TEST_PLAN.md` section 3b. Also:
- yielding exports called through pf-devices;
- MDT launchers on the live resource names;
- the news duty-point position, which is a guess;
- slot and zone headings;
- layouts at the real tablet size.

### Owner decisions raised by this batch
- **Duplicate jobs:** pfm-taxijob and pfm-garbagejob still run beside the pf-jobs Taxi and Garbage. pfm-busjob is the only working bus job: pf-jobs Bus ships disabled with no routes. Pick one of each.
- **Two dispatch systems:** the MDT's own callouts and 911 board, and the pf-services Dispatch app. Pick the main one.
- **Crew splits:** Gruppe 6 and Garbage splits are stored but ignored in payouts. Gruppe 6 upgrades have no server effect.
- **Retire pf-governmentwebsiteonly:** it writes government tables directly, so its changes emit no events.

### Batch 10b — 2026-10-31: pf over pfm, the MDT inside the devices
Owner decisions:
- if a script exists in both pf and pfm, keep pf and remove pfm, but only where the pf version really covers it;
- the police and EMS dispatch is the MDT, 1:1 the same code and screens, as an app on the tablet and the computer.

**Removed** (-qb- 002fe57):
- `pfm-cityhall`: pf-government's civil services replaced it.
- `pfm-hud`: pf-hud is the full HUD with the same events; both were drawn on screen.
- `pfm-taxijob`: replaced by pf-jobs Taxi. The radial taxi buttons now run the pf-jobs commands.
- `pfm-garbagejob`: replaced by pf-jobs Garbage.

**Kept, because the pf version is not complete:**
- `pfm-busjob`: pf-jobs Bus ships with no routes, prices or levels.
- `pfm-towjob`: pf-jobs only has the tow request checks.
- `pfm-shops`: pf-stores covers five player-owned stores, not every NPC shop.
- `pfm-garages`: pf-garageuionly is only a UI copy and pf-jobgarages only covers job garages.
- `pfm-newsjob`: it works with pf-news; it is not a duplicate.

**MDT in the devices** (pf-policemdt-DEV, pf-emsmdt):
- **The app is the MDT's own page:** each MDT registers `html/index.html?embed=1&device={device}` as a pf-devices iframe app for its jobs (`server/devices.lua`).
- **Fitting the window:** `html/device_embed.js` / `.css` fit the page to the window. They make callbacks reach the MDT resource (inside an iframe, `GetParentResourceName` names the device) and tell the client when the window opens and closes.
- **Device mode** (`client/device_mode.lua`, loaded first):
  - the MDT's messages go to the window; overlays (dispatch pop-ups, custody timer, CCTV) still go to the full-screen frame;
  - focus is left to the device;
  - the MDT's close button closes only the window;
  - putting the device away ends device mode.
- **Launchers removed:** the old MDT launchers are gone from `pf-devices/shared/config.lua`.
- **One dispatch:** pf-services puts `police.assist` and `ems.patient` requests on the MDT's dispatch board (`CreateDispatchCall`). Police and EMS don't get the separate Dispatch app while their MDT runs; tow, mechanic, taxi, government and reporters keep it.
- **Tests:**
  - `mdt_device_mode_spec.lua` (6): registration, routing, focus, close, for both MDTs;
  - `js/mdt_embed_spec.js` (6): the real embed script, embedded and full-screen;
  - `pfservices_load_spec` MDT routing (1).
- **Totals:** mocked 882 passed, 0 failed; real-DB 245 passed, 0 failed.
- **Check in game:**
  - every MDT page inside both device windows: the map, CCTV (it uses a scripted camera), evidence camera mode and the citation paper;
  - sizes at the tablet's 760x640.

## Batch 11 — 2026-10-31: every framework system as a device app, the last pfm duplicates, strict state bags
Owner request: finish the whole rework in one go: the shared business apps, bank/garages/property/dealer/boss apps, bus and tow in pf-jobs, side jobs, old copies, character-deletion cleanup, and the state-bag lockdown.

### New apps on the tablet and the computer (one module each, server-checked, money on the ledger)
| App | Resource | What it does |
|---|---|---|
| Business Manager, Order Supplies, Job Board | pf-computer | The computer's own windows became platform apps; the computer's handlers sit behind them. The tablet's built-in Business Manager is gone (its registry view and transfers are in the shared app's City registry section). |
| Bank | pfm-banking | Accounts, shared and society accounts, statements from the ledger (paged, filtered), transfers with stable keys and daily limits, loans and cards, branches. Cash never moves remotely. |
| Crypto | pfm-crypto | Price and history, wallet, buy/sell/send once per key. |
| Boss | pfm-management | Staff, hiring a person beside you, ranks and wages, society money (cash only at the boss desk). The staff rules exist once and are exported. |
| Garages | pfm-garages | Every owned car and its state, waypoints, impound fee paid ahead (one payment path with the depot), tow to a garage through pf-services. |
| Real Estate, Agency | pfm-houses | Houses for sale, owned houses and keys, the apartment; agents list, reprice and sell to a customer beside them who accepts (fee, transfer tax, commission, registration). |
| Car Dealer, Dealership | pfm-vehicleshop | Catalogue with stock and finance; finance payments; dealer sales with stock, purchase tax, commission, DMV registration; stock orders. |
| Used Cars | pfm-vehiclesales | The used lot; sellers reprice their own cars. |
| Tow | pf-jobs | Flatbed rental with deposit, hooking any car, NPC contracts when no request is open, dispatch requests (accept, complete, hand back), levels. |
| Bus | pf-jobs | Real routes, passengers in the depot bus, levels, depot buses. |
| Recycling, Vineyard | pf-jobs | The moved side jobs: shifts paid once, levels, selling to restaurants and mechanic shops through the Supplier app. |
| Pawn Shop, Crafting | pfm-pawnshop, pfm-crafting | Today's prices, hours and melting; recipes with what you have. Read-only. |

### pf over pfm (the rest)
- **Removed:** pfm-busjob, pfm-towjob, pfm-recyclejob, pfm-vineyard (pf-jobs now covers each fully), and the old pf copies pf-governmentwebsiteonly, pf-tabletuionly, pf-garageuionly, pf-jobsystem, plus pf-mechanicjob's dead MechanicOS page.
- **Still kept:** pfm-shops (pf-stores covers five player-owned stores, not every NPC shop), pfm-garages (pf-jobgarages covers job fleets only), pfm-newsjob (works with pf-news).

### Rules every resource follows now (details in `DEVICES_AND_SERVICES.md`)
- `pfm-core:server:characterDeleted` (citizenid, deleted) clears each resource's own rows: pf-devices, pf-services, pf-citizen, pf-news, pf-computer, pf-jobs, pf-jobgarages, pfm-banking, pfm-garages, pfm-houses, pfm-apartments, pfm-vehicleshop, pfm-vehiclesales.
- Registry, store owner and staff data come through exports (`GetBusiness`, `GetBusinessesOwnedBy`, `ListBusinesses`, `GetStoreOwner`, pfm-management staff, `AddStaff`).
- Websites get live updates by host (`BroadcastSite`).
- **State bags are server-written.** `inv_busy` belongs to the inventory server (action locks via `SetBusyLock`). Fuel, NOS, drift tyres, part wear, mileage and a car's saved state are set by the server after range, timing and value checks. Staging now runs `setr sv_stateBagStrictMode true`; a scan spec fails on any new client write.

### Defects found and fixed on the way
- **Supplier items duplicated:** a mechanic part case is 10 items but a player supplier's stock unit was 1 item, so stocking 1 delivered 10. Supplier stock is now converted to the buyer's case size.
- **Restaurant food fed nobody:** only one burger was usable and it relieved stress instead of hunger. Items added with `AddFood`/`AddDrink` were eaten for nothing and crashed the client handler. Every consumable dish is now real food or drink, scaled by freshness, cooked quality and poison risk.
- **Bus distance paid without a bus:** a route checked in from any car paid its distance; now the depot bus is required (`MileageNeedsBus`).
- **Gruppe 6 shipped in debug** (offers every 5–10 s); now off.
- **Crew splits:** they were stored and then ignored; now each member is paid their share once.
- **Other fixes:** management gaps (nonexistent ranks, a boss changing their own rank, re-hire resets, self-hire); a seized car released by paying an old fee; pawn prices shown from the client; weed planting releasing the inventory lock at once; a cancelled harness leaving the player busy; a `bus_routes_log` foreign-key failure; finance commission ignored.

### Database migrations (rerun-safe)
- pfm-crypto v1;
- pfm-garages v1;
- pfm-houses v1;
- pfm-vehicleshop v1;
- pf-jobs v1–v3 (bus, Gruppe 6 XP and upgrades, tow);
- `pf-jobs:recycle` v1 and `pf-jobs:vineyard` v1;
- pf-computer v3 (profiles).

### Adversarial review of the round, and what it fixed
Five reviewers each took one angle: money, trust in client data, the app screens, contracts between resources, and SQL. A skeptic then tried to disprove every finding. 16 findings survived, 10 different defects. Each fix was checked again by a second skeptic, and their remaining gaps were closed too.

| Defect | Fix |
|---|---|
| A used-car seller could raise the price from the app while the buyer's contract was open; the buyer paid the new price | The buy carries the price shown and is refused if it differs. The listing claim also needs the price unchanged. |
| An agent's reprice could race a door purchase; the 70% state sell-back then paid out of a raised listing (money from nothing) | Reprice and purchase share one lock, taken before the first wait. Memory changes only when the database row changed. The price paid is stored (`player_houses.purchase_price`) and the sell-back uses it. The door contract stays until a purchase succeeds and covers only its own house. The backfill join works across mixed collations. |
| Saved wear, mileage and NOS were loaded from rows the client wrote, so a forged save gave free NOS, free repairs and a wound-back odometer | Saves read the server's own state of the car the sender is in or beside; nothing is written for a car that isn't spawned. NOS is kept in server-written columns. A restore only ever raises wear and mileage. A car carries the saved state of one plate only, and the plate is claimed before the database read. |
| Anyone within 10 m could wear out every part of a parked car | Only the driver, or a mechanic for the work-order car the server registered for their accepted order. The entry is dropped when the car is removed, and the plate and model are checked on every report. |
| One Gruppe 6 upgrade attempt without the money locked that upgrade forever (a failed ledger key never succeeds again) | The balance is checked first. A failed key moves to the next attempt key; a completed one only records the upgrade. |
| Relogging turned a wrecked or abandoned flatbed into a full deposit refund | The truck's state is recorded at disconnect, and the refund follows it. A txAdmin restart (which drops everyone) keeps the full refund. |
| Bank, Boss and Crypto apps reused a timed-out request id for a different action, and the server reported the new action as done | The id is kept only for a retry of exactly the same action. The server compares a duplicate with the stored transaction and refuses a mismatch. |
| A refund whose first attempt failed was retried under the same dead key forever; a deleted character's refunds never ended | Retries use numbered keys. A payer whose account is gone gets `forfeited` and is not retried. |
| A cancelled supplier order gave back stock in the new case units, more than was reserved | The reservation is stored on the order and returned exactly. |
| The Bank app and the business apps shared CSS class names and broke each other's bars and grids in every shell | The business apps use the `pfbiz` prefix. |

### Tests
Mocked 1190 passed, 0 failed (143 files); real DB 349 passed, 0 failed (38 files); 8 JS specs green; the SQL install check passes; every Lua file changed this round parses.

### Owner decisions and things to know
- **Dealer commission:** paid from `system:pfm-vehicleshop` on top of the full price going to the dealership, which creates money. The other option is to take it out of the dealership's share.
- **Small supplier orders:** the freight minimum ($150) comes out of the goods money, so a player supplier earns almost nothing on small orders.
- **ATM cash:** withdrawals and deposits are not position-checked on the server, because ATMs are map props. An ATM coordinate list would fix that.
- **Property tax:** there is no recurring property tax; only the transfer tax at a sale.
- **Gruppe 6:** Tier 2 and Tier 3 contracts now need the licence upgrade, as its config intended.
- **Bus:** a side job anyone can install (`Config.Bus.Job = nil`). Set it to `'bus'` to require the job.
- **Perishable wine:** with pf-restaurants running, `wine` and `grapejuice` are perishable everywhere, including wine sold in stores.
- **NOS:** bottles players had saved in vehicle mods (client-written) are not carried over.
- **Branch closures:** kept in memory; a restart reopens every branch.
- **Live server.cfg:** remove any `ensure` lines for pfm-busjob, pfm-towjob, pfm-recyclejob and pfm-vineyard, and `[custom]` (old pf-mechanicjob copy). Do not add `setr sv_stateBagStrictMode true` yet: the third-party progressbar and pma-voice still write state from the client (see batch 12). *Batch 13 changes this: patched copies start from [qb]; see the batch 13 owner decisions for the live steps.*
- **Old CSS:** the old Business Manager, Order Supplies and Job Board CSS in `pf-computer/ui/css/style.css` and `pf-tablet/html/style.css` is now unused.

## Batch 12 — 2026-10-31: fixes from the pre-merge review

**Source:** the review of branch `main-9hq3gi` (`docs/REVIEW_main-9hq3gi.md`) found 13 merge blockers. Each was fixed in its own set of files, then checked by two independent reviewers (correctness, and an attacker with a modified client). Two needed a repair round.

**Results on the branch:**
- mocked 1342 passed (158 files);
- real database 356 passed (40 files);
- browser-side 60 passed (8 files);
- parallel ledger and fresh-install SQL checks pass.

**Nothing has been tested in game.**

| Blocker | Fix |
|---|---|
| Gruppe 6 contracts never finish | The vault state local is declared before use. The security panel needs an active contract at the deposit stage, not a non-existent `gruppe6` job. "Open Storage" uses pfm-inventory's inventory command. Deposit is locked per contract, so XP is added once, and a refused bag removal is not paid. |
| Deleting a character creates money | The character can't be deleted while it is loaded (a per-citizenid lock also covers a login during a delete). A player delete is refused while the character owes the bank (`unpaid_debt`, shown in the character menu). An admin force-delete still writes the debt off and logs it. The multicharacter event works only from the character menu. |
| Character deletion leaves data | New server-only listeners clear: store ownership (the store's money and stock stay with the store); government staff, registry owner (`unowned`) and properties; restaurant staff (the restaurant re-registers under its next owner); mechanic diagnostics of the plates the character owned; phone photos and tweets (the feed cache reloads); trunk and glovebox stashes of those plates (`characterDeleted` now passes them); pending news payouts and the ad buyer's name. |
| Police impounds lost | De-duplication matches the request kind. An impound replaces an open garage or mechanic tow of the plate (refunded). A `tow.impound` that ends untowed is applied directly (`FinalizeImpound`), once. |
| Service payments not proof-based | The requester can cancel only while the request is open. `mechanic.roadside` (and any kind with `confirm`) pays on the citizen's confirmation, or after `Config.Requests.confirmWindow` when the worker was checked on site (`onSiteRange`) without a dispute. A dispute or an expiry without an on-site check refunds. The escrow sweep refunds a request that was cancelled meanwhile. RPCs return the public request view. |
| Announcements bypass the permission | Every create and delete path needs `Config.GovApps.AnnouncementPermission`, and urgent ones need `UrgentAnnouncementPermission`. The author is the server-side name. Types and lengths are checked. The unused net event was removed. |
| Strict state bags not ready | Staging no longer sets `sv_stateBagStrictMode`. The cfg and docs name the blockers: third-party `[standalone]/progressbar` (`inv_busy`), `[voice]/pma-voice`, and the old `[custom]/pf-mechanicjob` on live. |
| Websites with cards or links can't be saved | The depth limit fits every editor module. "Too deep" and "too large" are separate errors. |
| NOS | NOS state is saved as soon as it changes, so an emptied bottle no longer refills. Wear reports come only from the driver of their own current vehicle, capped by elapsed time. |
| Tow rental | A per-character lock covers rent and contract requests. Return and report-lost work after leaving the job, with a return-only yard target for players who still hold a rental. Batch 13 adds a return-only Tow app for them. |
| News vehicles | The lock frees when the vehicle is gone or wrecked. On a new request, a vehicle the reporter left more than `Config.AbandonRange` away (stolen, sunk) is retired. Storing is decided by the server. The trunk is stocked once per issued vehicle. |
| App Store paid installs | A per-character lock and a fresh ledger key per attempt. One charge per app, recorded in `pf_device_app_purchases` (migration v2), with a refund if recording fails. |
| Phone invoice retry | The previous attempt is checked on the ledger. A new key is used only after a failed attempt, and "in progress" while one is pending. There is no 20-attempt dead end. Mails and events go out only when the business credit really moved money. |

**Known, not fixed here:**
- **Phone invoice ledger keys:** keyed by invoice id. If `phone_invoices` ids were ever reused (table truncated, or MySQL before 8.0 after a restart), a new invoice could match an old paid key. Fixing it needs a schema change.
- **`PFPayout.Charge` (cash, then bank):** if the cash transfer ends unclear (debited, waiting for recovery), it still tries the bank, so a deposit could be taken twice once recovery completes. This needs a change in the helper.
- **NOS garage save:** a periodic garage save in flight during an empty or level save can write older NOS values. This needs a change in `garage_sync.lua`.
- **Government apps:** pf-computer passes announcement duration in days while pf-government reads seconds. This is older behaviour.
- **Older issues from the review**, still open: the supplier markup on a cancelled order, Gruppe 6 "end contract" paying the tier maximum, the used-car lot erasing a loan, bank counter proximity, and the lock after an inventory search.

Batch 13 fixed each of these. The gaps its checkers found are listed in the batch 13 section.

## Batch 13 — 2026-11-01: the last review fixes and the owner decisions

**Source:** the items batch 12 left open, the open findings of `REVIEW_main-9hq3gi.md`, and six owner decisions.
- **Starting point:** a "WIP batch 13" commit (`-qb-` 721686a, `-pfscripts-` 6b91ddd) left by agents that were stopped mid-run. It passed the syntax check only (mocked 1455 passed / 3 failed, real DB 354 / 2).
- **How:** eleven agents, one per area, finished it. A skeptic then checked each area against its goal. It reran the specs, ran the new specs against the WIP code and the code before it to see them fail, and wrote probe specs for paths the tests did not cover.
- **Commits:** `-qb-` 80f97db, `-pfscripts-` 28ff205.

**Results on the branch:**
- mocked 1695 passed, 0 failed (182 files);
- real database 414 passed, 0 failed (45 files);
- browser-side: every JS spec green (11 files, 79 tests);
- parallel ledger and fresh-install SQL checks pass.

**Nothing has been tested in game.**

### Banking (pfm-banking)
- **Counter cash** (`server.lua`): cash withdraw and deposit, for own and society accounts, need the player within 5 m (`Config.CashRange.counter`) of a bank counter (`Config.locations`). The position is read on the server. Deposits are counter-only. Branch closures still apply. The WIP's "ATM session" is gone: a modified client could open it anywhere.
- **ATMs** (`config.lua`, `server.lua`; the list is under the owner decisions): opening the ATM screen and withdrawing need a listed ATM within 4 m and a `bank_card`, both checked on the server. ATMs have no deposit.
  - An unlisted ATM answers "This ATM is out of service" (new `error.atm` in all five locales; `it.lua` also gets the missing `toofar`).
  - An empty list makes every ATM refuse and prints a warning at start. Counters keep working.
  - New admin command `/atmcheck`: standing at an ATM, it says whether that ATM is listed, or prints the `vector3(...)` line to add.
- **`PFPayout.Charge`** (`payouts.lua`): it moves to the next account (cash, then bank) only on a clear refusal: a `failed` transfer, or an error the ledger returns before writing anything (such as `insufficient_funds`).
  - It stops on everything else: pending, debited, `in_progress`, `ledger_write_failed`, `internal_error`, unknown replies, a compensated transfer, and a failed `interrupted_unverified` row (the cash may have left before a crash).
  - On an unclear stop it returns `false, res` with `res.unclear = true`, and tells the player unless the caller passed `quiet`.
  - Every caller in both repos was read. None relied on falling through to the next account, and none was changed.
- `README.md` explains the cash points and the new Charge behaviour.

### Property tax (pf-government, pfm-houses)
- **pfm-houses export** (`server/main.lua`): read-only `GetOwnedHouses()` returns `{ house, citizenid, value, label }`.
  - The value is the price paid (`player_houses.purchase_price`), else the listing price, else 0 (then the minimum applies).
  - It reads the database, so it is right even before pfm-houses has loaded its houses. A house with two rows counts once.
  - pf-government never reads the housing tables.
- **Migration pf-government v2** (`server/schema.lua`): `pf_gov_bills.bill_ref`, `bill_period` and the unique index `uq_bill_period_ref (bill_period, bill_ref)`. Bills without a period (fines, invoices) leave both empty and are not limited.
- **`CreateBill`** (`server/bills.lua`): an optional 9th argument `{ ref, period }`. With it, the insert is `INSERT IGNORE` on the key, and a repeat returns `false, 'duplicate', existingId`. A malformed key, or a database without the migration, is refused. The NUI and export paths cannot pass it.
- **New `server/property_tax.lua`:** `PropertyTax.Run(now)` bills each owned house once per week (rules under the owner decisions). One run at a time; houses already billed this week are skipped with one read, and the unique key settles a race. An online owner gets a notification.
- **Scheduler** (`server/main.lua`, `StartBackgroundTasks`): the auto-collection thread was an empty placeholder. It now runs the property tax 60 s after start, then every `AutoCollection.interval` (30) minutes. The console command `govpropertytax` runs it on demand.
- **Rate** (`config.lua`, `server/taxes.lua`): `property` joins `Taxes.Defaults` (0.50%) and `Enforcement` (0–5%), labelled "Property tax". After the first seed the database row is the live rate, set by the mayor like every other tax. `Config.Taxes.PropertyTax` holds on/off, minimum, due days, issuer and the housing resource. The unused `property_tax_frequency` setting is gone.
- **Business overview** (`server/callbacks.lua`, `business:getStats`): the "unpaid taxes" alert now counts business bills only. It would have counted citizens' property tax.
- `INTEGRATION.md` has a "Weekly Property Tax" section.

### Computer and inventory (pf-computer, pfm-inventory)
- **Job Board hiring news** (`pf-computer/server/jobboard.lua`): the `business.hiring` kind is registered again when pf-services starts (its `starting` state counts too), when pf-computer starts, and on `pf-services:server:ready`. The WIP's check before `Emit` stays as a fallback.
- **Supply pickup** (`pf-computer/server/main.lua`, `startJobPickup`): for job businesses the boss check (`jobAdapter.canManage`, the same check pf-stores runs when the run ends) comes before the order is read and before any truck spawns. Staff get "Only the boss can collect supply orders." One pickup start per player at a time. The pf-stores `CanManageOrderBuyer` export is no longer called here.
- **Announcements** (`handlers['gov:announcements:create']`): the duration is whole days 1–90, sent as seconds. The category is cleaned to letters, digits, spaces, `_` and `-`, at most 32 characters. Empty means pf-government's `general`.
- **Search lock** (`pfm-inventory/server/main.lua`, `functions.lua`):
  - client and server action locks are counted separately, so 8 client locks no longer block the `inv:search` lock;
  - new `EndInventorySearchesBy(viewer)`: the search ends when the searcher opens their own inventory, a stash, a shop or a drop;
  - close, walking away (the minute check or the next item move), and disconnect or logout of either player already ended it in the WIP.
- **Busy-lock TTL** (`qb-inventory:server:setActionBusy(reason, busy, ttlSeconds)`): an optional TTL of 1–600 s, rounded up. No TTL keeps the 30-minute default. An invalid TTL changes nothing. A release ignores the TTL. A short lock ends within about a second of its TTL. Disconnect and logout still clear it.

### Documents and phone (pf-citizen, pfm-phone)
- **Documents** (`pf-citizen/server/documents.lua`, `mail.lua`): the WIP was kept and finished.
  - Only the owner hands out a read-only link by mail. Anyone else who mails a document sends each recipient a locked copy, or points at the original when the recipient can already read it.
  - Only the owner, or someone the owner or the server shared it with, can sign.
  - Once someone else has signed, the owner's delete only hides it from the owner (`owner_hidden`, migration pf-citizen v2), and unsharing a signer is refused. These checks are inside the SQL statements.
  - New: a failed signature no longer leaves the document locked with no signature (`D.Sign`).
  - New: a person who gets a mail directly and as a business boss gets one copy (`M.SendFromPlayer`).
  - UI (`mail.js`, `documents.js`): a document you don't own is marked "(copy)"; the Share dialog says the recipient gets a copy.
- **Phone invoices** (`pfm-phone/server/main.lua`, `qb-phone.sql`):
  - each invoice has its own `ledger_token`: a nullable column with a `DEFAULT (UUID())`, added by a guarded `ALTER` that runs only when the column or default is missing. Payment keys come from the token, so a reused invoice id no longer matches an old paid key. Rows without a token keep their id key;
  - the default also gives a token to invoices other resources insert directly (pfm-policejob `/bill`);
  - the business and the commission are paid before the row is deleted (`PayInvoiceLocked`); a decline takes the same lock as a payment;
  - `CreateInvoice` caps the amount at the column limit and the ids at 50 characters; the token is never sent to the client.

### EMS and Dispatch (pf-ambulancejob, pf-emsmdt, pf-services)
- **The 3 WIP failures** were the spec's fault: the resource loads once per spec file and kept the earlier patient's open call. Each test now starts clean (also `citylinks_ems_spec`).
- **Person-down calls** (`pf-ambulancejob/server/main.lua`):
  - a call opens only when the server reads the player down, one per character;
  - logging out to the character menu (`QBCore:Server:OnPlayerUnload`) closes it, like a drop, and only once;
  - a character who left while down and comes back dead counts as down again;
  - a call held back by the cooldown no longer blocks the next one;
  - the city event goes out only for a new request.
- **EMS MDT** (`pf-emsmdt/server/main.lua`, `pf-services/server/main.lua`): pf-services passes `requestId`, and the MDT matches calls by request id only. The WIP's match by title and position could delete an unrelated call. Cancelled or expired requests remove the call; completed ones show it as done.
- **Dispatch** (`pf-services/server/requests.lua`, `apps.lua`, `shared/catalog.lua`, `html/apps/dispatch.js`):
  - one job rule, `PFServices.WorksOn`, drives the list, accept and the waypoint, so Benny's and Beeker's get waypoints on mechanic calls;
  - each `gov.request.*` kind declares its `govPermission` (businesses or licenses). Taking or completing one needs that permission through `pf-government:HasPermission`. A kind without one, or pf-government stopped, cannot be taken. Giving a request back needs no permission;
  - the app hides Accept when the server says no, and points to the Business Requests app.

### Fuel and cruise (pfm-fuel, pfm-smallresources, pf-hud)
- **Fuel reports** (`pfm-fuel/server/main.lua`, `qb-fuel:server:syncFuel`): accepted only from the car's driver, only downward, and by at most `Config.MaxFuelBurnPerSecond` (0.5) per second since the last accepted value (counted up to 30 s). A car with no level yet takes its driver's first report.
- **Refuelling** (pump callback, `setCanFuel`, jerry can):
  - needs a real car within 10 m; the client's level is ignored;
  - the pump charges only for what fits, refuses a full tank, and answers `(paid, newLevel, reason)`;
  - a per-car lock (`withRefuelLock`) is taken before the payment wait;
  - the jerry can edits a copy of the item info, so a failed swap leaves the can as it was.
- **New server exports:** `SetVehicleFuel(entity, level)` and `GetVehicleFuel(entity)` (in the README).
- **Client** (`client/main.lua`, `client/exports.lua`): the pump sets the level the server answered. A capped answer no longer pushes the driver's gauge back up; refuels always apply.
- **Cruise indicator** (`pf-hud/client.lua`, `html/index.html`, `app.js`, `style.css`): the live HUD is the plain-JS `app.js`; the svelte source and the old bundle are not loaded. A cruise icon shows while cruise is on, and in layout edit mode.
- **Cruise** (`pfm-smallresources/client/cruise.lua`): sends `false` however cruise ends (also when leaving the seat), starts no second loop, and checks steering and the handbrake every frame.

### Jobs (pf-jobs)
- **Bus** (`server/apps/bus.lua`): the WIP's per-player spawn lock was already correct: taken before the first wait, released on every path. Tests added.
- **Gruppe 6 early end** (`server/apps/gruppe6.lua`): pays the contract's payout × bags handed in ÷ total bags, never the tier maximum. In a party the crew bonus applies to that share.
  - Ending before any bag was collected now closes the contract with no pay for the crew and sends them to the return area (new client event `pf-jobs:gruppe6:returnWithoutBags`). Before, the contract was stuck.
- **Gruppe 6 client** (`client/gruppe6.lua`): exactly one `returnVehicle` handler remains.
- **Tow return after leaving the job** (`server/devices.lua`, `server/apps/tow.lua`, `client/tow.lua`, `html/apps/tow.js`):
  - the Tow app is open to the tow job, or anyone whose character has an open rental;
  - a former driver sees only the rental, the car on the bed, the bay flag and the depot, and can only return the flatbed or report it lost; every other method is refused and moves no money;
  - after the rental settles, the app leaves their device;
  - `/tow` takes a car off the bed whenever the server says one is on it.

### Mechanic (pf-mechanicjob)
- **Tow billing** (`server/advanced_systems.lua`, `config.lua`, `client/advanced_systems.lua`):
  - only the shop's boss can order a tow, for a car within `Reach` (8 m);
  - the server must read the car as broken: engine below 400, body below 300, a ruptured tank, or a part at 100% wear;
  - the boss and the plate are locked before the first wait and checked again after it; the shop's account pays;
  - other mechanics are told the boss can order a tow. The WIP's `MinBillingGrade` setting is gone.
- **Repairs vs old wear reports** (`server/main.lua`, `repair.lua`, `consumables.lua`, `admin_customs.lua`): every server repair calls `PFMech.MarkWearRepaired`, which raises the car's wear epoch after the repaired wear is set. A report with an older epoch is dropped. The WIP's state-bag handler raised the epoch too early; it now only records known wear.
- **NOS save order** (`server/garage_sync.lua`, `nos.lua`, `admin_customs.lua`): every NOS write goes through one ordered writer per plate (`PFMech.SaveNos`) that writes the newest state last. The 30 s wear save never writes NOS. The garage store queues its NOS snapshot with the wear. Admin NOS install and remove save at once.

### Stores (pf-stores, pf-computer Order Supplies)
- **Markup at delivery** (`server_orders.lua`): accepting a player-supplied order moves no money. The supplier's markup share is paid only at settlement (`O.Settle`). A cancel refunds the buyer the total minus what really left escrow, counted over every payout key. Accept-then-cancel can no longer drain escrow.
- **Case sizes:** `caseSizeOf` (exported as `O.CaseSizeOf`) is the one place that reads `Config.SupplyChain.CaseSize`, always a whole number of at least 1. It is used for matching, reserving, `DepositStock` and the Supplier app. `CaseSize = 0` no longer stocks cases for free. A cancel returns the `reservedUnits` recorded at accept.
- **Refund retries:** a cancel refund the ledger stored as failed is retried under `supply:<id>:cancel:<n>`, with a growing wait (15 s, up to 1 h; every owed refund once at start). Migration pf-stores v3 marks older cancelled orders whose refund never reached the ledger as owed.
- **Freight on top** (rules under the owner decisions): `CreateOrder` answers include `freight`. New exports `GetDeliveryPricing(kind, buyerId)` and `QuoteOrder(kind, buyerId, method, subtotal)`. `ListSupplyOrders` and `GetStoreManagerData` (`server.lua`) return subtotal, markup and freight. The 7-day spend skips failed and cancelled orders.
- **Apps** (`pf-computer/html/apps/ordersupplies.js`, `pf-stores/html/apps/supplier.js`), display only:
  - the cart shows goods, markup, freight and an estimate when the server sends pricing; otherwise it says the extras are added on top;
  - the notice after ordering shows what was charged; order cards show the breakdown when the server sends it; a cancel whose refund is still owed says so;
  - the Supplier app shows "You earn $X + $Y bonus on delivery".

### Strict state bags (progressbar, pma-voice, staging)
- **Copies** in `-qb-`, under their own names: `progressbar` and `pma-voice`, with LICENSE and README kept (source under the owner decisions).
  - Left out: `.github/`, a root `.gitignore`, and `ui/js/*.js.map` (build output that holds the upstream author's local path).
  - A scan for steaxscripts and loaders over the Lua, the server JS and the UI bundles is clean.
- **progressbar** (`client.lua`): no longer writes `inv_busy`. Each bar takes pfm-inventory's `progressbar` action lock with a TTL: the time left plus 10 s, at most 600 s, renewed for longer bars. It releases the lock only if it holds it.
- **pma-voice** (new `server/module/state.lua`; `server/module/radio.lua`, `server/main.lua` and the client files):
  - the client no longer writes replicated state. The server checks and writes `voiceIntent`, `disableRadio`, the four volumes, `proximity` and `radioActive`;
  - rate limits: 20 per 5 s per player and key, 40 for radio talk. The latest value is applied when the window ends;
  - `radioActive` is true only while the server has the player in a non-zero channel. Talking reaches only channel members. Leaving or switching radio clears it;
  - joining sets `disableRadio` to 0 if unset and clears a `radioActive` left from before a restart.
- **Staging** (`docs/staging/server.staging.cfg`): `setr sv_stateBagStrictMode true` is on. The scan spec now covers both copies.

### Vehicles (pfm-vehiclesales, pfm-vehicleshop)
- **Used lot** (`pfm-vehiclesales/server/main.lua`, `client/main.lua`, `qb-vehiclesales.sql`):
  - financed, impounded (`depotprice > 0`) and active fleet cars are refused. The DELETE that hands the car over repeats each condition, so a car put in a fleet after the check is still refused;
  - the server picks the car the seller sits in and reads the model and the sell-back price from its record (this needs OneSync);
  - migration pfm-vehiclesales v1 adds `vehicle_state`. A listing keeps the car's finance columns, condition and odometer; taking it back restores them exactly. A buyer gets the condition and odometer, never a loan;
  - the server removes the car from the world only after success. Before, the client deleted it even when the server refused;
  - a full lot refuses new listings; a sell-back at price 0 is refused; a failed write puts the car or listing back, or refunds the buyer.
- **Transfers** (`pfm-vehicleshop/server.lua`; `/transfervehicle` is the only ownership-change path in either repo):
  - gifts and sales refuse fleet cars. Financed cars are refused when `Config.PreventFinanceSelling` is on; when it is off, the loan goes with the car and the buyer sees it before accepting;
  - the car is locked before the first wait. Ownership changes in one UPDATE that checks the owner, the loan shown and the fleet again;
  - a paid sale goes through `system:pfm-vehicleshop`: the buyer pays in, the car moves, then the seller is paid. If the car can't move, the buyer is refunded. All keys come from the offer id;
  - an amount that isn't a number (`5k`) is refused; before, it gave the car away.
- **Accept and pay** (`client.lua`, `server.lua`): the prompt sends `{ accept, id }`. Only the offer with that id is accepted. An old or missing id accepts nothing and leaves the current offer open.
- **Dealer commission** (rules under the owner decisions): `html/apps/cardealer.js` shows both parts. The config comments and README are updated.

### Owner decisions as built
- **Dealer commission comes out of the dealership's share** (pfm-vehicleshop).
  - The dealership gets the price minus the commission. The salesperson gets the commission: `Config.Commission` (10%), or `Config.FinanceCommission` (5%) for a financed sale.
  - Both come from `system:pfm-vehicleshop`, which received the price, each once under its own key (`<offer>:dealership`, `<offer>:commission`). No money is created.
  - The commission is clamped between 0 and the price.
- **Freight on top, paid by the buyer** (pf-stores).
  - A delivery costs goods + AI markup (15%) + freight. A pickup costs the goods only.
  - The supplier gets the full goods value. A player supplier also gets half the markup at delivery; the rest goes back to the buyer. The driver gets the freight. Escrow pays out exactly the total.
  - Orders placed before this change settle as they were charged.
  - The old cap of freight at the goods value is gone, so the freight minimum applies to small orders: 12% of the goods, at least $250 for stores and $150 for restaurants and job businesses. A small order is cheapest as a pickup.
- **ATMs** (pfm-banking `Config.ATMs`, 76 points; withdrawals within 4 m, `Config.CashRange.atm`).
  - 71 points from esx_atm `Config.ATMLocations`: GPL-3.0, © 2015-2018 Jérémie N'gadi, read from the mirror github.com/ESX-Brasil/esx_atm at a11170f.
  - 5 points from vRP `vrp/cfg/atms.lua`: MIT, © 2017 ImagicTheCat, github.com/ImagicTheCat/vRP at 8d35fdf. These are the vRP points more than 2 m from every esx_atm point; where the two lists share an ATM they agree within 1.6 m.
  - Rejected: jsfour-atm ("All Rights Reserved"). The owner's pack has no ATM coordinates.
  - An ATM missing from the list (other GTA ATMs, custom maps) refuses cash until it is added; `/atmcheck` gives the line.
- **Weekly property tax** (pf-government).
  - Each owned house gets one bill a week: 0.5% of its value (the mayor's `property` rate, 0–5%), at least $50 (`Config.Taxes.PropertyTax.Minimum`).
  - `bill_type 'tax'`, to the owner as a citizen bill, so it shows in pf-citizen Bills. Due in 7 days. Title "Property tax: <address>, week of YYYY-MM-DD".
  - The key is `house:<house>` plus the week (its Monday, 00:00 UTC). The unique index `(bill_period, bill_ref)` keeps it to one bill per house per week, even after a restart or a racing run.
  - Unpaid bills go delinquent after due + 7 days through the existing escalation. Like any delinquent citizen bill, this suspends the owner's active licenses.
  - No repossession: the house keeps its owner.
  - Paying uses the existing `PayBillFromPlayer` path; the money goes to the treasury.
  - A week the server was down is not billed later. Whoever owns the house at the first run of a week pays that week.
- **progressbar and pma-voice copied into [qb]** from the owner's BigLeagueQB snapshot of 2025-10-19. The copies on the live server may differ from that snapshot. The originals (`[standalone]/progressbar`, `[voice]/pma-voice`) must be removed from the live server: two resources with one name conflict, and either one may start.
- **Strict state bags on in staging** (`setr sv_stateBagStrictMode true`). On live, remove the two originals and `[custom]` (the old pf-mechanicjob) before turning it on.

### What the checkers confirmed
| Area | Confirmed |
|---|---|
| Banking | Counter cash uses the server position, before any ledger call. The ATM list matches both sources point for point, with the licences as stated; no invented coordinates. `Charge` was checked against every return path of the ledger's `Transfer`: no path takes money from a second account after the first may have moved money. The specs fail on the WIP and pre-WIP code. |
| Property tax | One bill per house per week on every path (second run, restart, console command, a race between read and insert). Real DB amounts 1,250 / 600 / 50. Delinquency keeps the owner. Paid once in Bills, treasury credited. No client path reaches the recurring key. |
| Computer and inventory | The Job Board kind is registered again after a pf-services restart. The boss check runs before any order read or spawn. Duration and category match pf-government's rules. The search lock clears on close, disconnect, logout and another inventory. The TTL is bounded and validated, and matches progressbar. |
| Documents and phone | No path hands out a link except the owner's. Signature, delete and unshare checks are inside the SQL. The token column is added once. Pay and Decline share one lock, taken before the first wait. |
| EMS and Dispatch | The 3 WIP failures were the spec's. The MDT call closes by id on every request close path. One call per character. Dispatch list, accept and waypoint use one rule. Government kinds need the same permission as Business Requests. |
| Fuel and cruise | Only the driver lowers the level, capped by time. Refuels take no client value and lock before the charge. The live HUD is the plain-JS one. Cruise sends exactly one on and one off. |
| Jobs | The bus lock comes before the first wait and is released on every path. The Gruppe 6 early end pays the share and never more than finishing. One return handler. The tow return-only view refuses every other action with no money moved. |
| Mechanic | Boss only, damage and position read on the server, locks before the first wait (checked with a held wait). Every server path that lowers wear marks the epoch. NOS writes are ordered per plate; mutation checks fail without the fix. |
| Stores | No money moves at accept. Full refund on cancel. Escrow pays out exactly the total. Case sizes come from one place. Refunds use a new key only after a stored failure. The adapters still send the goods subtotal. |
| Strict state bags | The copies differ from the snapshot only in the patched files. The rescan is clean. With the originals swapped in, the scan finds exactly the 12 upstream client writes. The progressbar TTL matches pfm-inventory's 600 s cap. The staging line is on. |
| Vehicles | Fleet, finance and impound refusals hold inside the DELETE or UPDATE. Take-back restores the loan; a buyer never gets one. Only the shown offer id is accepted. Dealership share + commission = price, each paid once. |

### Gaps the checkers found
| Area | Gap | Status |
|---|---|---|
| Banking | pfm-policejob `/bill` creates a phone invoice when `Charge` returns false. On an unclear result that later completes, the player pays twice. | handled in batch 13b: fixed (Phone invoices). `/fine` sends no invoice on an unclear charge |
| Banking | Callers that make a new key per click (fuel, car wash, vehicle shop, truck robbery, rentals, taxi, farming, App Store, revive) can charge twice when the player retries after an unclear result (older). | handled in batch 13b: partly. Fuel, vehicle sales and the tow deposit no longer charge again; the others are still open |
| Banking | On an unclear result, callers with their own error show two notices (pfm-shops bail), and the tow app says "insufficient funds". | handled in batch 13b: partly. The tow app says the deposit is still settling; pfm-shops still open |
| Property tax | While pfm-houses' database is not ready, the export uses the listing price instead of the price paid. | handled in batch 13b: fixed. The export answers "not ready" and the run retries |
| Property tax | The government Fines app does not list citizens' property-tax bills, so staff cannot see or waive them. The dashboard's pending-bill count now includes them. | handled in batch 13b: fixed. Listed with filters; staff can waive them |
| Computer and inventory | A search is bound to range only if the searcher is within 5 m after the 1.5 s opening wait. Police search and rob need only 2.5 m, so a searcher who steps away during the wait can loot from any distance and keep the target locked. | handled in batch 13b: fixed. The reach is decided before the wait (police 2.5 m) |
| Computer and inventory | TAB does not free a searched player at once (the `inventory` command stops on `inv_busy` first); only the minute sweep does. The spec skips that key path. | handled in batch 13b: fixed. TAB frees the target on the same key press |
| Computer and inventory | During the 1.5 s wait the target can reopen their own inventory and keep it open for the whole search (older). | handled in batch 13b: fixed. The lock is taken and the target's windows close before the wait |
| Computer and inventory | The pickup lock is per player, not per order: two bosses can spawn two trucks for one order. No money moves. | handled in batch 13b: fixed (Stores). One pickup run per order |
| Documents and phone | A key the ledger recovers as `interrupted_unverified` is treated as failed, and a new key charges again: a crash mid-transfer can still charge twice. Two specs assert this as correct. | handled in batch 13b: fixed. It waits for reconciliation; the two specs were rewritten |
| Documents and phone | A decline does not check the invoice's ledger keys. After a completed or in-flight charge the payer can decline: they are charged and the business is never paid. | handled in batch 13b: fixed. A decline checks every charge key first |
| Documents and phone | If the business credit is interrupted, the row is deleted and the payment returns true while the business stays unpaid. The `:society` key never moves to a new attempt key. | handled in batch 13b: fixed. The row stays 'paying' until every step is paid, on numbered keys, with a sweep |
| Documents and phone | After a crash between the payouts and the delete, the retry sends no settled event or mail, so the Bills history misses the invoice. | handled in batch 13b: fixed. The request that deletes the row sends the events, once |
| Documents and phone | A copy holds only the title and body, not the signatures. Mailed copies count against the recipient's document limit. A failed delivery leaves an orphan copy. An attachment dropped for lack of room is still reported ok. | handled in batch 13b: fixed (Citizen and government). Signature record, own cap, no orphan copy, missing attachments reported |
| EMS and Dispatch | If the patient logs out, drops or is revived while the request insert is still running, the request and its MDT call stay open until expiry (900 s). | handled in batch 13b: fixed. The new request is closed after the insert |
| EMS and Dispatch | A player who crashes or logs out in last stand and comes back within the 60 s cooldown gets no call. | handled in batch 13b: fixed. The cooldown is skipped once for a returning patient |
| EMS and Dispatch | A standing player at 101–150 health who fakes last stand gets one call at their real position (design limit kept from the WIP). | handled in batch 13b: kept as a design limit (one call per relog) |
| Fuel and cruise | A new car's first level is still its driver's first report (any 0–100): no spawner calls `SetVehicleFuel` yet. | handled in batch 13b: fixed. Read from `player_vehicles.fuel`, else 100 |
| Fuel and cruise | Cruise now checks steering and the handbrake every frame (not asked for): speed is not held in a turn, and cruise may switch off after a curve. | handled in batch 13b: fixed. Checked once at switch-on again |
| Fuel and cruise | A car that is not networked can no longer be pump-refuelled. A car with no shared level is charged for the full litres asked, with no room check. | handled in batch 13b: fixed. The room comes from the server level; a message for a car that is not networked |
| Fuel and cruise | The pump works next to any car anywhere, at the base price (older). | handled in batch 13b: fixed. Only at stations and `Config.ExtraPumps` |
| Jobs | Gruppe 6: the truck's storage target is removed after the truck is deleted, which does nothing in game (the target is kept under the net id). | handled in batch 13b: fixed. Removed before the delete |
| Jobs | Bus: the spec runs without the database read, so it does not prove the lock comes before the first database wait. | handled in batch 13b: fixed. A new spec with a yielding database read |
| Jobs | Gruppe 6: the zero-bag end clears only current group members; lost bags still block an early end; ending in the 250 ms bag recount window pays nothing. | handled in batch 13b: fixed in a second round. Leavers cleared, lost bags written off, the recount event registered |
| Jobs | Tow: a former driver with an owed contract cannot claim the pay. An open Tow window keeps the driver layout until it refreshes. The client comment about a restart is misleading. | handled in batch 13b: fixed. Owed pay from the return-only view; the app switches on a job change |
| Mechanic | The tow cooldown is used up even when the request fails. The client offers a tow only at engine 30% or less. Busy and cooldown refusals are silent. No committed spec holds the first wait. | handled in batch 13b: fixed. Cooldown after a request, one shared rule, every refusal explained, a spec |
| Mechanic | The 30 s wear save takes its snapshot before its database wait, so a repair in that window can leave pre-repair wear saved. | handled in batch 13b: fixed. One wear writer per plate, checked against the repair epoch |
| Stores | `O.Settle` and AI delivery retry fixed ledger keys after a stored failure: the order never settles and its money stays in escrow. | handled in batch 13b: fixed. Numbered keys; a payee gone for good is refunded to the buyer or held |
| Stores | `O.Route` (and pf-services `RegisterRequestHandler`) accept only a Lua function. Adapters registered through exports arrive as function references in FiveM, so restaurant and job-business deliveries probably get no route in game. | handled in batch 13b: fixed in pf-stores (`callable` check in `O.Route` and `O.GovernmentId`) |
| Stores | The cart estimate and the order-card breakdown need pf-computer's `business:supplies:catalog` and `orders:list` to pass the pricing. Until then the app shows generic wording. | handled in batch 13b: fixed. pf-computer sends the pricing and the breakdown |
| Stores | A buyer account that is gone for good gets a new failed refund row about once an hour, forever (no `forfeited` state). | handled in batch 13b: fixed. `forfeited` after 5 refusals |
| Stores | `/supplyorders` prints the buyer's lines without converting them; the `ListSupplyOrders` mock in `stores_trucking_ledger_spec` is stale. | handled in batch 13b: fixed. Converted lines; the mock matches the query |
| Strict state bags | The progressbar copy has no LICENSE (the snapshot had none; upstream is GPL-3.0). | not taken up in batch 13b; still open |
| Strict state bags | Proximity `index` and `mode` are checked for type and range only, not against `Cfg.voiceModes`. | not taken up in batch 13b; still open |
| Strict state bags | Switching channel while holding push-to-talk clears `radioActive` until release. A server-side `disableRadio` write would not reach the client's copy (no such writer exists). | not taken up in batch 13b; unchanged |
| Vehicles | `buyVehicle` does not check the fleet again: a listing made before this fix, or during pf-jobgarages' add-to-fleet race, can sell a fleet car. | handled in batch 13b: fixed. Checked before the charge and inside the claiming DELETE |
| Vehicles | `getVehicles` sends every listing's `vehicle_state` (finance and condition) to all clients. | handled in batch 13b: fixed. Only the columns the UI uses |
| Vehicles | `fleetTableExists` caches "no table" for 5 minutes, so a failed lookup lets fleet cars through. | handled in batch 13b: fixed. A failed lookup is not cached and refuses |
| Vehicles | A failed seller payout or buyer refund after a paid transfer is never retried. An unclear buyer charge can leave the buyer charged with no car. | handled in batch 13b: fixed in a second round. Settlements: payouts stored and retried, unclear charges held |

### Known, not fixed here (older, or outside this batch)
- **pfm-banking:** the ATM PIN is checked only in the UI; `Config.useDailyLimit` / `dailyLimit` are unused. Only an attribution line was added for the 5 MIT (vRP) points.
- **pf-government:** `ProcessBillLateFees` never runs (`os.time` on a number). Fixing only that line would add 10% every hour, compounding: an owner decision. House utility bills use `target_type 'property'`, which `pf_gov_bills` does not allow.
- **pfm-phone:** pfm-policejob `/bill` inserts into `phone_invoices` itself instead of calling `CreateInvoice`. The Bills history is keyed by invoice id.
- **pf-services and MDTs:** the police MDT ignores `requestId`, so police calls stay on its board after the request closes. pf-government's Business Requests keeps its own permission list (a spec catches drift). A citizen's own medic call is not closed when they log out; it expires after 15 minutes (true for every citizen request). pf-services never raises `pf-services:server:ready` (optional; the restart is covered).
- **pf-computer:** no computer screen calls `gov:announcements:create`. Keep pf-stores' `CanManageOrderBuyer`: pfm-worldobjects uses it.
- **pfm-garages:** `updateVehicleStats` still saves the fuel level the client sends.
- **pf-jobs:** Gruppe 6 `vehicleReturned` clears the sender's contract without checks (pays nothing). A tow contract in progress keeps its car and spot until the former driver disconnects.
- **pfm-vehicleshop / pf-jobgarages:** repossession deletes the car's row but leaves its active `job_garage_vehicles` row. Old listings without `vehicle_state` come back with default columns; a loan erased by an earlier listing can't be recovered.
- **pf-hud:** `svelte-source` and the old `html/index.js` / `index.css` are unused and could be retired.

Batch 13b fixed the late fees, the house utility bills, the police invoice insert (`/fine`), the police MDT's `requestId`, the second permission list, the citizen medic call on logout, the garage fuel save and the fleet row left by a repossession. See the batch 13b section.

### Database migrations (rerun-safe)
- pf-government v2: `bill_ref`, `bill_period`, unique `uq_bill_period_ref`;
- pf-stores v3: older cancelled orders with an unsent refund marked as owed;
- pfm-vehiclesales v1: `occasion_vehicles` and its `vehicle_state` column (also in `qb-vehiclesales.sql`);
- pf-citizen v2: `owner_hidden` (from the WIP);
- pfm-phone: a guarded `ALTER` adds `ledger_token` and its `DEFAULT (UUID())` (also in `qb-phone.sql`).

### Tests
- **New mocked specs:** `fix9hq2_inventory_action_busy_ttl`, `fix9hq2_emsmdt_request_close`, `fix9hq2_cruise_hud`, `fix9hq2_jobs_tow_return`, `fix9hq2_mechanic_wear_epoch`, `fix9hq2_mechanic_nos_save_order`, `fix9hq2_vehicle_prompts_client`, `government_property_tax`, `progressbar_busy`, `pmavoice_state`. The WIP's `fix9hq2_*` specs were finished so they test the goal.
- **New real-DB specs:** `fix9hq2_banking_charge_unclear`, `fix9hq2_dispatch_visibility`, `government_property_tax`, `phone_invoice_tokens`, `vehiclesales_listing`. `citizen_documents` gained 10 tests. `supply_chain` and `vineyard_restaurant_supply` now expect the markup share at delivery.
- **New JS specs:** `ordersupplies_totals`, `pfhud_cruise`, `pfservices_dispatch_app`.
- Mocked 1695 / 0, real DB 414 / 0, JS all green; `ledger_parallel` and `sql_install_check` pass.

### Things to know before live
- **Freight minimum on small orders:** confirm it. An employee with supply-order permission at a store or restaurant can place tiny delivery orders and drive them for $150–250 each from the business account. It is real work for real pay and creates no money. *Batch 13b changes this: a delivery below `MinDeliveryGoods` (default: the freight minimum) is refused.*
- **Delinquent property tax suspends licenses** (the existing escalation for citizen bills).
- **`qb-phone.sql`** now needs a database with expression defaults: MariaDB 10.2+ or MySQL 8.0.13+. It fails on MySQL 5.7.
- **Used lot:** listing and selling back need OneSync (the server reads which car the seller sits in).
- **pma-voice:** replicated values (`radioActive`, proximity, volumes) appear after one round trip, so pf-hud's radio icon lags by about the ping. Server code must not write `disableRadio` itself.
- **pfm-inventory** allows 30 client lock events per 10 s. Very fast back-to-back bars could lose a hold or a release; a lost release still ends after the bar's time plus 10 s.
- **Fuel:** the 0.5 per second cap is not checked against real burn at `GlobalFuelConsumptionMultiplier` 4.5. If cars burn faster, other players see the level catch up slowly; raise `Config.MaxFuelBurnPerSecond`.
- **Mechanic repairs** rely on FiveM sending one car's state-bag changes to clients in the order the server set them (wear, then epoch).

## Batch 13b — 2026-11-01: gaps from the batch 13 checks

**Source:** the gaps the batch 13 checkers found (batch 13, "Gaps the checkers found"), plus some items batch 13 listed as known.
- **How:** eight agents, one per area. A skeptic then checked each area against its goal. It reran the specs, ran the new specs against the older code to see them fail, and wrote probe specs for paths the tests did not cover.
- **Second rounds:** five areas went back for a second round: phone invoices, fuel and cruise, vehicles, jobs and mechanic, citizen and government. The skeptic then checked them again.
- **Commits:** `-qb-` 734fd96, `-pfscripts-` 95987df. A "WIP batch 13b" snapshot came first (`-qb-` beecf51, `-pfscripts-` b00d7a9).

- **Export boundary:** committed after the area fixes, on top of WIP snapshots (`-qb-` fc19d59, 08d45f2; `-pfscripts-` 5c1eaef). See "Export boundary" below.

**Results on the area commits:** mocked 1977 passed, 0 failed (196 files); real database 495 / 0 (51 files); all 12 JS spec files green; parallel ledger and fresh-install SQL checks pass.

**Results after the export boundary (end of batch 13b):**
- mocked 2029 passed, 0 failed (205 files);
- real database 503 passed, 0 failed (53 files);
- browser-side: all JS spec files green;
- parallel ledger and fresh-install SQL checks pass.

**Nothing has been tested in game.**

### Rounds and what the checkers confirmed
| Area | Rounds | What the last check confirmed |
|---|---|---|
| Phone invoices | 2. Round 1 met every goal but found four gaps: the sweep stalled behind 50 stuck rows, an id sent as 5.0 got its own lock, a business the bank refuses was still charged, and a reused id without a token skipped the business credit. | All six items. No path charges the payer twice or makes a payout twice. The new tests fail on the batch 13 code. |
| Inventory search | 1 | All three items. The reach is fixed before the wait, TAB frees the target on the same key press, and the lock is taken before the wait and released on every failure path. 24 of the 29 new tests fail on the old code on behaviour alone. |
| Fuel and cruise | 2. Round 1 failed the garage save: sending the save again after the car was deleted stored a full tank. It also found a plate swap that gave a free full tank. | All four items. A resend after the delete now keeps the stored level (12, not 100). The new specs fail on the batch 13 code. |
| Stores and supply pickup | 1 | All eight items. Escrow pays out exactly what came in. No failed key is retried under the same key, and no unclear state is treated as failed. |
| EMS and Dispatch | 1 | All five items. Police and EMS MDT calls close by request id on every close path. |
| Vehicles | 2. Round 1 failed the unclear-charge item: a database error at one step could leave a buyer charged with no car, and a finance payment rerun created $1,000. | All six items. The round 1 probes now pass (sale held, then the car delivered), and no money is created. |
| Jobs and mechanic | 2. Round 1 failed the Gruppe 6 item: pf-jobs never registered the inventory move as a net event, so the bag recount never ran in game. It also found the tow deposit losing its key during a bank outage. | All eight items. 31 of 36 single-point mutations are caught. One finding is left to fix (the tow deposit, under open items). |
| Citizen and government | 2. Round 1 failed the orphan-copy item (oxmysql raises on a SQL error, so the cleanup never ran) and found a regression: one SQL error stopped the hourly bill loop. | All seven items, no regressions. Every item has a test that fails on the batch 13 code. |

### Phone invoices (pfm-phone, pfm-policejob)
- **Closes:** documents and phone gaps 1–4 (an unverified charge, a decline after a charge, an interrupted business credit, no report after a crash) and banking gap 1 (a police invoice after an unclear charge).
- **The 'paying' state** (`server/main.lua`, `qb-phone.sql`):
  - a new column `pay_state VARCHAR(16) NULL`, added by the same guarded `ALTER` as `ledger_token`;
  - the row is marked `'paying'` before the charge. A 'paying' row is hidden from the phone and cannot be declined;
  - the row is deleted only after the business credit and the commission are done. Until then the payer's money waits in `system:pfm-phone`, and the payer is told the payment was received (`in_progress`);
  - the request whose `DELETE` removed the row sends the paid events and mails, once.
- **Numbered keys per step.** Each step is a ledger transfer with keys of its own. `<base>` is `pfm-phone:invoice:tok:<token>`.
  - charge: `<base>:bank`, then `<base>:retry<n>:bank`;
  - business credit: `<base>:society`, then `<base>:society:retry<n>`;
  - commission: `<base>:commission`, then `<base>:commission:retry<n>`.
  - A step that failed or was refunded moves to the next number, with no cap. A pending, debited or `interrupted_unverified` step waits and never gets a new key.
- **The sweep** (`PFPhoneInvoices.Sweep`):
  - it starts once the ledger is ready, then runs every 2 minutes;
  - it pages through the 'paying' rows by id, 50 a page and at most 20 pages a run. It goes on where it stopped and wraps round, so rows that wait for good no longer block later ones;
  - each invoice it could not finish backs off from 2 up to 30 minutes;
  - it makes the missing payouts and deletes the row, or opens the invoice again when no charge can have moved money;
  - for a charge left unverified it prints one console warning per invoice, naming the ledger key, so an admin can reconcile it.
- **Lock:** a payment, a decline and the sweep of one invoice share the lock `citizenid:id`, taken before the first database wait. The id is turned into an integer (`InvoiceIdOf`), so 5 and 5.0 share a lock. Fractions, 0, negatives, NaN and huge numbers answer `bad_request`.
- **Decline:** it walks every charge key first. A completed charge finishes the payment instead (`not_open`); a pending, debited or unverified one answers `in_progress`. A decline now needs the bank: with pfm-banking down it answers `bank_unavailable`.
- **Unknown businesses:** `CreateInvoice` refuses a business the bank does not know. Paying checks the business account before every new charge. If the bank refuses it, nothing is charged, the answer is `unknown_society`, and the phone says "This business cannot receive payments right now". An invoice charged before its business account went away stays 'paying' until the account is back.
- **Rows without a token** are checked against their old id keys first (same payer and amount). On id keys a payout counts only if the ledger stored it after this invoice's charge, so an older invoice's payouts under a reused id are skipped.
- **Mails:** no "Commission Received" mail when the commission was dropped because the biller's character was deleted.
- **Stored XSS fixed** (`html/js/bank.js`, `LoadBankInvoices`): the business, sender, reason and amount are escaped, and the id is read as an integer.
- **`/fine`** (`pfm-policejob/server/commands.lua`; pfm-policejob has no `/bill`, the lines batch 13 named are `/fine`): on an unclear charge the officer is told and no invoice is sent. Otherwise the invoice is made through `exports['pfm-phone']:CreateInvoice`. No code in either repo inserts into `phone_invoices` directly any more.

### Inventory search (pfm-inventory, pfm-policejob)
- **Closes:** computer and inventory gaps 1–3.
- **Reach fixed before the wait** (`server/main.lua`, `server/functions.lua`):
  - `ResolveSearchReach` uses the caller's `opts.reach` (a number above 0, capped at 5 m), else 5 m;
  - the admin menu is the only exemption. The server reads it with `GetInvokingResource() == 'pfm-adminmenu'`; no client value is used;
  - `BeginInventorySearch` refuses when the two are already further apart than the reach. After the wait the search is checked against its own reach;
  - a new 2 s loop checks every open search. The minute sweep still renews the locks.
- **Police** (`pfm-policejob/server/interactions.lua`): search and rob use 2.5 m for the start check and pass it to the export. The "cash found" and "being searched" notices go out only if the search opened.
- **The target's own paths:** `IsBeingSearched(src)` runs before the busy check in TAB (`inventory`), `hotbar`, `OpenInventory`, `OpenShop` (vending too), `openDrop` and `getBackpack`. TAB after the searcher walked off frees the target and opens their inventory on the same key press.
- **Lock before the wait:** `OpenInventoryById` takes the `inv:search` lock before the hook and the 1.5 s wait.
  - The target's own inventory, stash or drop, and any search they were making, are closed. The close goes out only if something was open.
  - The lock is released if the hook refuses, either player leaves, they move apart, or the window fails to build (`pcall`).
  - After the wait, a search that was ended or replaced opens nothing.
- **While a search holds a player** they cannot move their own items, drop, give or use items (hotbar keys and drawing a weapon too). The searcher can still take items.
- `OpenInventoryById` refuses a self-search and a searcher who is being searched. It returns `true` only when the window opens.

### Fuel and cruise (pfm-fuel, pfm-garages, pfm-smallresources)
- **Closes:** fuel and cruise gaps 1–4, the batch 13 known item "pfm-garages saves the client's fuel", and the fuel part of banking gap 2.
- **First level from the server** (`server/main.lua`):
  - `ensureLevel` reads `player_vehicles.fuel` by the plate the server sees on the car (trimmed), under the car lock taken before the database wait;
  - with no row it waits 2 s for a plate the owner's client sets, looks again, then uses `Config.DefaultFuel` (100);
  - a failed read hands out nothing. The driver's first report is never used as the level;
  - the manifest now loads oxmysql.
- **Spawners name the row:** the new export `UseStoredFuel(veh, plate)` reads that row at once, whatever plate the client shows later. pfm-garages `qb-garages:server:spawnvehicle` calls it, so garage and depot cars start at their stored fuel. This closes the plate swap. New, job, test-drive and rental cars have no row and start at 100. A used car bought on the lot starts at the fuel it was sold with.
- **Answers bound to the plate:** each first level remembers its plate. `GetVehicleFuel(veh, plate)` answers only for that plate (without a plate it works as before). New export `IsFuelSynced()`.
- **Pumps only at stations** (`server/pricing.lua`, `StationForPlayer`):
  - the server's ped position must be within 60 m of a listed station (`Config.GasStations`, the 27 stock stations), or within `Config.ExtraPumpRadius` (10 m) of a point in `Config.ExtraPumps` (empty by default);
  - this gates pump refills, the pump price, and buying or refilling a jerry can. Pouring a can into a car works anywhere;
  - away from a station the player sees "Fuel is only sold at a gas station".
- **Room from the server level:** litres are capped at `floor(100 - level)`. With no level, nothing is charged. A car that is not networked gets a clear message.
- **Charges** (round 2):
  - `chargeOnce` keeps an unclear charge per player and kind (pump, jerry can, can refill). The next purchase of that kind asks the bank again under the same key and amount. Once it goes through, the earlier litres are poured or the can is handed over;
  - `pourPaidRefill` refunds under the charge key plus `:refund`, with no tax, when the car is gone or a settled earlier refill no longer fits. A refund the bank refuses is paid before the player's next refill;
  - a clear refusal now shows `payment_declined`; too little money for a jerry can shows `no_money`. New texts `payment_declined`, `refunded`, `refund_pending` (en, es, nl);
  - a pump used while the car's first level is being read waits up to 5 s instead of saying "busy". One purchase per player at a time.
- **Garage save** (`pfm-garages/server/main.lua`, `qb-garages:server:updateVehicleStats`). Fuel is saved as whole litres, and NaN is handled.

| Situation | What is saved |
|---|---|
| Fuel sync on, the car is in the world, and its level was given for this plate | the client's fuel, capped at the server's level |
| Fuel sync on, but no such car (deleted, never out, or showing another car's plate), or pfm-fuel errors | `LEAST(COALESCE(fuel, ?), ?)`: the client can only lower the stored value |
| pfm-fuel stopped, or sync off | the client's value, as before |

- **Cruise** (`pfm-smallresources/client/cruise.lua`): steering and the handbrake are checked once, when cruise is switched on, as in the original. Speed is held through turns. pf-hud still gets exactly one on and one off.

### Stores and supply pickup (pf-stores, pf-computer)
- **Closes:** stores gaps 1–5 and computer and inventory gap 4 (one pickup per order).
- **Settlement and AI freight on numbered keys** (`server_orders.lua`):
  - `payoutState` walks `base`, `base:1`, `base:2`… from the ledger's own records. Completed means paid. Failed or compensated means try the next key. Pending, debited or `interrupted_unverified` means wait; no new key is used;
  - `payFromEscrow` makes at most one attempt per pass. `O.Settle` pays through `settlementShares` and `settleShare` (the old `splitMarkup` is gone);
  - `aiDeliver` walks from `freight:supply:<id>`, so a trip already paid to a player driver is not paid again;
  - retries wait 15 s, 30 s and so on up to 1 h, one settlement per order at a time (`trySettle`). Cancel refunds use the same waits. After 241 attempts (about ten days) a share is left for staff.
- **Terminal states for payees that are gone:**
  - a payee is gone after 5 refusals with compensated or `unknown_account`, each under its own key (at least 15 + 30 + 60 + 120 s apart);
  - a player supplier's share (goods value and bonus) then goes back to the buyer who paid it, under `supply:<id>:<part>:buyer`;
  - whatever the buyer can't take either (the markup refund too) stays in `society:freight_escrow`. It is recorded as `held` in the new table `pf_supply_order_payouts` (migration pf-stores v4);
  - the order is then marked settled, so the sweep stops. Escrow pays out exactly what the order put in;
  - staff list held shares with the admin command `/supplyheld` or the export `ListUnpaidSupplyPayouts(outcome, limit)`.
- **Cancel refunds** (`refundCancelled`): after 5 such refusals `refund_state` becomes `'forfeited'`, a `held` row with part `cancel` is written, and the retries stop. Other failures, such as escrow short, keep retrying. Order Supplies says when a refund was forfeited.
- **`MinDeliveryGoods`** (`shared/config.lua`, `Config.SupplyChain.MinDeliveryGoods`):
  - unset means the business's freight minimum: $250 for stores, $150 for restaurants and job businesses. 0 turns it off;
  - a trucker delivery below it is refused with `below_delivery_minimum` and the message "Trucker delivery needs at least $X of goods; this order has $Y. Add more, or collect it yourself." Nothing is charged or stored. Pickups are still allowed;
  - every order path goes through it: pf-stores checkout, pf-computer and pf-restaurants;
  - `O.Pricing` and `O.Quote` report `minGoods`. Order Supplies shows the notice and disables "Place order" below it. Freight on top is unchanged.
- **Adapters from other resources:** a `callable()` check (a Lua function, a function reference, or a table with `__call`) replaces `type(...) == 'function'` in `O.Route` and `O.GovernmentId`. A route into a stopped resource means "no delivery" instead of an error. So restaurant and job-business deliveries get a route in game.
- **Order Supplies totals** (`pf-computer/server/main.lua`): the catalog sends `deliveryPricing` for stores, restaurants and job businesses (`deliveryPricingFor`). Order cards get the subtotal, markup, freight and refund state (`appOrder`; `ListSupplyOrders` now returns `refund_state`). For restaurants, "delivery available" follows pf-stores' route.
- **One pickup run per order** (pf-computer): a second boss gets `pickup_in_progress`. The start lock is per player and per order, taken before any wait. A run whose driver is offline, or that started over 2 h ago, no longer blocks the order. Order ids must be whole positive numbers.
- **`/supplyorders`** (`O.SupplierLines`, `O.DescribeOffer`) shows what accepting reserves, for example "2 cases of Red Wine (6 per case, 12 items) at $108 a case. Pays $100 + $7.50 bonus on delivery." The Supplier app uses the same lines. The stale mock in `stores_trucking_ledger_spec` now matches the real query.

### EMS and Dispatch (pf-ambulancejob, pf-policemdt-DEV, pf-government, pf-services)
- **Closes:** EMS and Dispatch gaps 1–3, and three batch 13 known items: the police MDT ignored `requestId`, Business Requests kept its own permission list, and a citizen's own medic call stayed open after logout.
- **A call made while the patient leaves** (`pf-ambulancejob/server/main.lua`, `DownStateChanged`): after `PFEmsRequests.Open` returns, a patient who is no longer down has the new request closed with the status of the close that happened meanwhile (kept in `opening[cid]`). A revive ends it completed, a logout cancelled.
- **City event:** the "Person down" event moved to `PFEmsRequests.Announce`. It goes out only once the patient is confirmed still down.
- **Back within the cooldown:** the 60 s cooldown is skipped once for a character the server had down who left while down (`leftDown`). Any "up" report clears it, so toggling flags cannot flood medics.
- **The citizen's own medic call** (`citizen:ems.patient`) closes on `QBCore:Server:OnPlayerUnload`, once per logout or drop.
- **Police MDT** (`pf-policemdt-DEV/server/main.lua`): `CreateCall` stores `requestId` and posts each request once. A new `pf-services:requestChanged` listener deletes the call when its request is completed, cancelled or expired. A player source raising the event is ignored.
- **One permission list:** new pf-government export `GetRequestPermission(kind)` (`server/registry_views.lua`). Dispatch (`pf-services/server/apps.lua`, `mayClaim`) asks it, then `HasPermission`. No permission, pf-government stopped, or an older pf-government without the export means the request cannot be claimed. `RegisterRequestKind` no longer takes `govPermission`.
- `DOWN_HEALTH` stays 150; a comment names the fake-last-stand limit.

### Vehicles (pfm-vehiclesales, pfm-vehicleshop, pf-jobgarages)
- **Closes:** vehicles gaps 1–4, the batch 13 known item "repossession leaves the fleet row", and the vehicle part of banking gap 2.
- **Fleet cars at purchase** (`pfm-vehiclesales/server/main.lua`, `qb-occasions:server:buyVehicle`): checked before the charge, and again inside the claiming `DELETE` (`AND NOT EXISTS` an active `job_garage_vehicles` row). The claim runs through `claimListing`, which catches errors.
- **Fleet add** (pf-jobgarages `ADD_FLEET_SQL`): one `INSERT … SELECT` that checks the owner, parked, not impounded, not in a fleet and not on the lot. A two-session MariaDB test showed a car is never both listed and in a fleet (under REPEATABLE READ).
- **Repossession:** `PFShop.Repossess` fires `pfm-vehicleshop:server:vehicleRepossessed`. pf-jobgarages `RemoveRepossessed` deactivates the fleet rows and despawns a car that is out. A failed query is retried every 30 s, up to 10 times. With pf-jobgarages stopped, pfm-vehicleshop closes the row itself.
- **Listings** (`getVehicles`) send only the columns the UI uses: no finance or condition.
- **The fleet table lookup fails closed** in all three resources: a failed lookup is not cached, and callers refuse.
- **Settlements** (new `pfm-vehicleshop/settlements.lua`; pfm-vehiclesales loads it as `@pfm-vehicleshop/settlements.lua`; each resource has its own tables and pays from its own `system:<resource>` account):
  - **Pending payouts and refunds** (`PFSettle.Owe`): a payout owed after a buyer was charged is tried at once. If it does not complete, it is stored in `<prefix>_owed` (unique ledger key) and a sweep retries it every 60 s.
    - A key still in flight is asked again under the same key. Only a failed or compensated key moves on to `<key>:r2`, `:r3`…
    - Errors that can never pay make the row `forfeit`; after 20 keys it becomes `stuck`.
    - Until it is paid, the money stays in `system:<resource>`.
    - Every payout after a charge uses it: seller payouts, buyer and tax refunds, the dealership share and the commission, finance refunds.
  - **Unclear charges** (`PFSettle.Hold`): when `PFPayout.Charge` returns `res.unclear`, the buyer gets no car yet, is told, and is never charged again for it. The sale is stored in `<prefix>_held` with its charge key. The car and the buyer stay blocked meanwhile. The sweep reads the key:
    - charged: the sale finishes. The car is parked in `Config.DeliveryGarage`, with a notification and a mail, and the payouts go through `Owe`;
    - nothing taken (or no ledger row after 10 minutes): the reservation is released (stock, listing);
    - `interrupted_unverified`: the hold becomes `review`, the reservation is released, and the buyer is told to ask staff (`/ledgerreconcile` lists the transfer).
  - Holds cover the showroom purchase and finance, the dealer sale and finance, the paid `/transfervehicle`, finance payments and pay-offs, and the used lot.
  - **Round 2:** a used-lot claim that throws is held with its claim marked unknown; `resolveClaim` decides it when the hold settles. A paid transfer whose owner change throws is held as `transfer` and finished by the sweep. The dealer's plate is picked before stock is taken or money charged. A hold releases its blocks only after its final mark is stored, and a finance payment stores `data.applied`, so it is never applied twice or refunded after it was applied.
- **Migrations:** pfm-vehicleshop v2 (`pfm_vehicleshop_owed`, `pfm_vehicleshop_held`), pfm-vehiclesales v2 (`pfm_vehiclesales_owed`, `pfm_vehiclesales_held`).
- pfm-vehiclesales does not declare pfm-vehicleshop as a `dependency`, on purpose: a pfm-vehicleshop restart would then stop the used lot. pfm-vehicleshop must be on disk.

### Jobs and mechanic (pf-jobs, pf-mechanicjob)
- **Closes:** jobs gaps 1–4, mechanic gaps 1–2, and the tow part of banking gap 3.
- **Gruppe 6 truck** (`client/gruppe6.lua`): `RemoveVehicleStorageTarget` runs before every truck delete, so the next truck gets "Open Storage" again.
- **Bus:** a new spec with a yielding stats read shows the lock comes before the first database wait. `bus.lua` is unchanged.
- **Gruppe 6 contracts** (`server/apps/gruppe6.lua`):
  - `leaveContract` takes a member off the contract when they leave, are kicked, switch party, the party is disbanded, or the leader drops. A closed contract is cleared for everyone still holding it (`contractHolders`);
  - ending again writes off lost bags (`writeOffLostBags`: bags no longer carried or in the trunk). Pay stays the payout × bags handed in ÷ total bags, so it can only go down;
  - round 2: `qb-inventory:server:SetInventoryData` is now registered as a net event. Before, pf-jobs only had a local handler, so the shared-stash bag count never ran in game. Each stash gets one count at a time (`runRecount`), read from its real contents;
  - round 2: the early end (`endContract`) runs under a `contract.ending` lock taken before the recount wait. A second request is refused. A member leaving, a count that does not arrive, or a deposit in progress leave the contract as it was;
  - round 2: when a write-off leaves nothing to hand in, the vault close sends the client on to the truck return;
  - round 2: trunk bags are found under every 8-character padding of the plate. The app's End reports success only when something changed.
- **Tow** (`server/apps/tow.lua`, `server/devices.lua`, `html/apps/tow.js`):
  - a former driver collects owed contract pay from the return-only view ("Collect pay");
  - a job change pushes the tow state, so an open app switches to the return-only view;
  - contract pay uses numbered keys (`attemptKey`, shared with the refund). A per-character lock (`ClaimBusy`) comes before the bank wait, and XP is credited once;
  - an unclear deposit says "still settling" (`deposit_pending`) instead of "insufficient funds". `PendingDeposit` keeps the same key for the retry, also through a bank or ledger outage, and is cleared only on a settled result.
- **Mechanic tow order** (`server/advanced_systems.lua`, `client/advanced_systems.lua`, new `shared/tow_check.lua`):
  - one "needs a tow" rule for the server and the client scan: engine, body, tank and part wear;
  - the cooldown starts only when pf-services makes a new request;
  - every refusal says why: busy, cooldown (with the seconds left), not near, already pending, not the boss, an impound already ordered, another service, an unpaid shop, the bank down, a database error. The boss is told when the request was posted unpaid;
  - a spec holds the `EnsureVehicleRestored` wait and shows both locks come before it.
- **Wear save vs repair** (`server/garage_sync.lua`): wear goes through one writer per plate, checked against the repair counter (`wearEpoch`). `PFMech.MarkWearRepaired` snaps the repaired car at once while a write is waiting, so a car deleted mid-write still keeps its repair. The writer runs under `pcall`, and a failed write lets the next driving report save again.

### Citizen and government (pf-citizen, pf-government, pfm-houses)
- **Closes:** documents and phone gap 5 (copies), property tax gaps 1–2, and two batch 13 known items: late fees never ran, and house utility bills used `target_type 'property'`, which `pf_gov_bills` does not allow.
- **Signed copies** (`pf-citizen/server/documents.lua`, migration pf-citizen v3): a copy keeps the source's signatures as a read-only record (`copied_signatures`, returned as `signatureRecord`). It never counts as a signature on the copy, and it is dropped when an editable copy's text changes. The Documents app shows it in its own block and marks a signature made on an earlier copy "signed an earlier copy".
- **Received-copy cap:**
  - `MaxPerCitizen` now counts only documents the citizen wrote;
  - copies from others count against `MaxReceivedCopies` (100);
  - the cap is checked inside the copy's own `INSERT` in `D.MakeCopy`, which both mail copies and "share as copy" use;
  - a full copy room never stops a citizen writing their own documents.
- **No orphan copies** (`server/mail.lua`, `M.SendFromPlayer`): each recipient's attachments and delivery run in one `pcall`. If that raises, or the mail is not stored, the copies and links made for that recipient are removed and the name goes into `undelivered`; the other recipients still get the mail. "Share as copy" removes the copy when its mail fails. The sender sees "Sent, but: …" for attachments that could not be made.
- **Late fees once per bill** (`pf-government/server/bills.lua`; migration pf-government v3 adds `late_fee_count`, `late_fee_amount` and `last_late_fee_at`):
  - `ProcessBillLateFees` reads `UNIX_TIMESTAMP(due_date)`, so the `os.time` bug is gone;
  - a bill still open `LateFeeInterval` (1 day) after its due date gets `LateFeePercentage` (10%) of its original amount, once (`LateFeeMaxCount = 1`). With a higher count it gets one more fee per interval, each a share of the original amount, so fees never compound;
  - the `UPDATE` needs the fee count it read, so a fee lands once even when two runs read the same bill. Property tax follows the same rule;
  - `PayBill` writes only if the amount and the amount paid are what it read (up to three tries), and returns the amount applied as a fourth value. `payBillFromPlayer` and pf-citizen's `payGov` refund the rest, so a fee that lands during a payment stays due;
  - the hourly jobs run through `runJob`, and each bill's escalation in its own `pcall`, so one SQL error no longer stops the loop. A bill paid or waived during the run is not made delinquent.
- **The property utility bill target type** (`server/utilities.lua`):
  - houses are billed to the owner citizen: `CreateBill('citizen', owner, …, 'utility', …, { ref = 'utility:property:<house>', period })`, one bill per house per cycle. The owner comes from pfm-houses; an unowned house is not billed;
  - the bills show in pf-citizen Bills as Utilities and are paid there;
  - escalation cuts a house only while the billed citizen still owns it. It asks pfm-houses once per run, else uses the last synced owner;
  - a shared `restoreIfSettled` runs after `PayBill` and `WaiveBill`. Waiving the last delinquent bill restores a cut the system made, for houses and businesses; a cut staff made stays;
  - migration v3 waives the old bills stored with an empty type. No `CreateBill` caller passes `'property'` any more.
- **Fines app** (`server/apps/fines.lua`, `html/apps/fines.js`): lists citizens' property-tax and house-utility bills, with the filters all, fines, businesses and houses (whitelisted on the server). Waiving uses the existing permission-checked path.
- **`GetOwnedHouses` before pfm-houses is ready** (`pfm-houses/server/main.lua`): it returns `false, 'not_ready'`, never listing prices. The property tax and the utility run wait `RetrySeconds` (120 s) and try again.

### Export boundary (test harness and cross-resource fixes)
**Why:** in FiveM, an export call copies its arguments and results (msgpack). A function passed to another resource, also inside a table, arrives there as a funcref: `type()` is `'table'`, it is callable, and indexing it errors. The QBCore object from `GetCoreObject` is such a copy too, so a player object from it is a snapshot whose methods are funcrefs. The mocked tests used to run every resource in one Lua state with no copying, so code that only works in that setup passed every spec.

**Test harness** (`tests/lua/fivem_mocks.lua`, "resource boundary" section; the real-DB harness uses the same file):
- exports, hand-written mocks, `GetCoreObject`, `CreateCallback` (pfm-core gets a funcref, the callback gets `cb` as a funcref), `CreateUseableItem`, `TriggerEvent` and `TriggerClientEvent` copy what they pass and turn functions into funcrefs that behave like FiveM's;
- a table that contains itself raises an error;
- `QBCore.Shared` and `Config` stay live (specs add items and jobs at any time); a spec that needs a copied Shared swaps it in;
- `boundary_mock_spec` pins this behaviour; `boundary_funcref_scan_spec` reads every Lua file outside pfm-core for `type(...Functions.X) == 'function'`.

**Real bugs found and fixed** (each has a spec that fails with the fix reverted):
- **pf-devices** `RegisterAppHandler`: refused every app handler registered from another resource, so in game no device app outside pf-devices would have answered. It now takes funcrefs.
- **pf-services** `RegisterRequestHandler`: dropped hooks from other resources, so a request that needs proof could be completed without it; a handler passed as one funcref crashed.
- **pfm-core** `RunMigrations`: a migration whose step is a function failed.
- **pf-policemdt-DEV:**
  - the access wrapper never answered a refused caller;
  - jail confiscation and return called methods on a copy, so items were not taken;
  - licence suspend, remove and unsuspend wrote the copy (pfm-core's next save undid them) and started from an older database row; they now use the live licences;
  - the expired-suspension lift on profile open went to the database only;
  - `tryChargeBank` reported "paid" when `SetMoney` was refused;
  - duty and status replies showed the old value.
- **pf-mechanicjob:**
  - `/admincustoms` refused every QBCore admin;
  - engineering items existed only in the resource's own copy (they are now added through pfm-core);
  - the client progress fallback check was always false.
- **pfm-crafting:** the XP lock read 0.
- **pfm-crypto:** wallet and portfolio replies used the values from before the trade.
- **pfm-hotdogjob:** the rep sent to the client was the value from before the gain.
- **pfm-management** boss `SetGrade`: the member was told their old rank.
- **pfm-weapons** `CleanWeapon`: gun oil was never used up (the old copy was written back after `RemoveItem`).
- **Already correct:** pf-stores adapters (`O.Callable`), pfm-inventory `AddHook`/`AddListener`.

**Specs made boundary-correct:** stubs that tested `type(cb) == 'function'` now use `Mock.callable`; specs that compared handlers by identity use `Mock.funcrefTarget`; specs that relied on items reaching a resource after load add them first.

**Open:** the MDT `AllowNegativeBank` path (off by default) still moves money with `SetMoney`, outside the ledger. `TriggerEvent` reaching `RegisterNetEvent` handlers is not emulated.

### Database migrations (rerun-safe)
- pfm-phone: `pay_state`, through the guarded `ALTER` (also in `qb-phone.sql`);
- pf-stores v4: `pf_supply_order_payouts`. `refund_state` gains `'forfeited'` with no schema change;
- pfm-vehicleshop v2 and pfm-vehiclesales v2: `<prefix>_owed` and `<prefix>_held`;
- pf-citizen v3: `copied_signatures`;
- pf-government v3: the late-fee columns. Old utility bills with an empty type are waived.

### Tests
- **New mocked specs:** `fix9hq3_phone_invoice_settle`, `fix13b_inventory_search_reach`, `fix13b_police_search_reach`, `fix13b_fuel_first_level`, `fix13b_fuel_payments`, `fix13b_garages_fuel_clamp`, `fix13b_policemdt_request_close`, `fix13b_vehiclesales_settle`, `fix13b_vehicleshop_settle`, `fix13b_vehicleshop_repossess`, `fix13b_jobgarages_fleet`, `fix13b_jobs_bus_lock_db`, `fix13b_jobs_g6_party_lost_bags`, `fix13b_mechanic_wear_save_order`.
- **New real-DB specs:** `fix13b_fuel_first_level`, `fix13b_garages_fuel_clamp`, `fix13b_jobgarages_fleet`, `fix13b_vehiclesales_settle`, `fix13b_vehicleshop_settle`, `government_house_bills`. Extended: `phone_invoice_tokens`, `citizen_phone`, `citizen_documents`, `supply_chain`, `supply_chain_e2e`, `computer_orders`, `government_property_tax`, `fix9hq2_dispatch_visibility`.
- **Changed expectations:** the two `fix9hq2_phonekeys` tests that expected a new key after an unverified charge now expect a wait. Specs that placed tiny deliveries now order more, or set `MinDeliveryGoods = 0`. The Gruppe 6 specs send the inventory move as a net event.
- Each new test fails on the code before its fix (the agents and the skeptics ran them on copies of the older code).
- Area commits: mocked 1977 / 0 (196 files), real DB 495 / 0 (51 files). After the export boundary: mocked 2029 / 0 (205 files), real DB 503 / 0 (53 files); every JS spec green; `ledger_parallel` and `sql_install_check` pass.
- **Export boundary specs:** `boundary_mock`, `boundary_funcref_scan`, `boundary_devices`, `boundary_migrations`, `boundary_mdt`, `boundary_mechanic`, `boundary_mechanic_progress`, `boundary_hotdog`, `boundary_weapons_jam`, and the real-DB `boundary_services_handlers` and `boundary_services_onclosed`; `sweep_mdt_jail`, `crafting_app`, `crypto_app` and `boss_app` extended.

### Behaviour changes owners must know about
- **Pumps off the station list stop selling.** A pump more than 60 m from the 27 listed stations, such as a custom-map pump, answers "Fuel is only sold at a gas station" until its spot is added to `Config.ExtraPumps`. Jerry cans still pour anywhere.
- **A used car starts at its stored fuel**, not a full tank. Garage and depot cars start at their stored fuel too. New, job, test-drive and rental cars start at 100.
- **Unknown businesses are refused for invoices.** `CreateInvoice` refuses a business the bank does not know. Paying such an invoice charges nothing and answers `unknown_society`.
- **Small delivery orders are refused.** A trucker delivery below `MinDeliveryGoods` (default: the freight minimum, $250 for stores and $150 for restaurants and job businesses) is refused. Pickups still work. This replaces batch 13's note about tiny paid deliveries.
- **Late fees start.** Every bill already overdue gets one 10% fee on the first hourly run after the update.
- **House utility bills now reach the owner.** A delinquent one suspends the owner's licenses, like any citizen bill. House power cuts have no effect in game yet.
- **Searches:** a searched player cannot use items until the search ends. A police search ends once the two are more than 2.5 m apart. Any other resource calling `OpenInventoryById` from more than 5 m is refused.
- **Phone invoices:** an invoice whose payment is still settling is hidden from the phone. A decline needs the bank.
- **Vehicle sales the bank cannot confirm are held.** The buyer gets the car, parked in `Config.DeliveryGarage`, only once the ledger settles; otherwise the reservation is released.
- **A supplier whose character is gone:** their share of a supply order goes back to the buyer.

### Open items
Grouped by area. Many need a change outside the files the area's agent owned.

**Phone invoices**
- pfm-core `server/player.lua` (around line 583) deletes a character's `'paying'` invoice rows on character delete. A business credit still waiting is then never made, and the money stays in `system:pfm-phone`. It should keep rows with `pay_state = 'paying'`.
- pf-citizen `server/bills.lua` should read `pay_state` and show `'paying'` rows as processing (or skip them). Today it still lists them. It could also give `unknown_society` a label.
- pfm-policejob `server/interactions.lua` (around line 218) charges without the `unclear` handling.
- The `/fine` department credit (`PaySociety` on the `:society` key) is never checked or retried. A fix needs a stored fine record.
- An unverified charge keeps its invoice hidden until an admin edits `pf_transactions`. There is no admin tool; the sweep's console warning is the only signal.
- A commission to a biller id the ledger cannot parse leaves the invoice `'paying'` for good, after the business was paid. Only a `CreateInvoice` caller passing an odd biller id can cause this.
- If a business account disappears after the charge, every pay call writes a new compensated ledger row (no rate limit). The money stays held, with no refund path.
- A crash after the `DELETE` but before the events, in the same tick, loses those events.
- `pay_state` has no index (the table is small).
- A reused id without a token, whose older invoice had the same payer and amount, counts as paid with no money moved. That business goes unpaid.

**Inventory search**
- The admin exemption depends on the name `pfm-adminmenu`. If it is renamed, admin searches are bound to 5 m. Check in game that `GetInvokingResource()` returns that name.
- A modified searcher client can take items during the 1.5 s before the window opens (within reach, after the hook approved). Fix: also require the search record's `shown` in `isOpenFor` for `otherplayer-`.
- A shop or vending window open on the target is not closed. This is harmless: purchases only add items.
- Older: closing the target's windows does not clear the server's open flag on their stash, backpack or drop.
- 2.5 m for the whole police search may end the search of a swaying or ragdolling suspect.

**Fuel**
- pf-jobgarages fleet cars start at their row's stored fuel, which is never updated when a car comes back. pf-jobgarages should save `GetVehicleFuel(veh, plate)` on return.
- pfm-policejob impound release: the client spawns the car and sets its plate, so a modded client can get a full tank for that one trip (it cannot be saved back). `police:server:TakeOutImpound` could call `UseStoredFuel`.
- pfm-policejob `police:server:Impound` writes the fuel the officer's client sends.
- Unclear charges and owed refunds are kept in memory. A restart forgets them, and a refill that settles later is poured only at the player's next pump use.
- A refund that ends clearly failed is retried under the same key, so that player's pump purchases answer `refund_pending` until a restart. This is almost unreachable.
- If a car's first level was given before its plate settled (over 2 s), parking can only lower the stored fuel.
- After a pfm-fuel restart, each car out takes the plate it shows then.
- Older: with `Config.SyncFuelBetweenPlayers = false` the pump charges the litres asked; the jerry can refill reads the can before the bank wait; a player's own second purchase says "someone else is refuelling".

**Stores**
- pf-restaurants `pf-restaurants:server:orderSupplies` shows "Supply order failed: below_delivery_minimum". It should show `res.message`.
- pf-trucking `payContract` retries a funded payout under the same key forever after a stored failure, so a driver is never paid once escrow was short. It should use the numbered walk; pf-stores' `paidOutOfEscrow` must then count the numbered rental keys.
- A share that fails 241 times for other reasons (escrow short for about ten days) waits for good. It is not recorded in `pf_supply_order_payouts`, and each hour it costs up to 241 ledger lookups.
- A store or restaurant account missing for about 8 minutes forfeits a cancel refund, even if the account comes back. There is no tool to release a held row.
- `activePickupRunFor` saves inside its loop over the runs; a run added during that wait can make the request fail (no money moves). A run whose mission ended unfinished blocks other bosses for up to 2 h while its driver is online.
- Retry waits are kept in memory, so a restart shortens them.
- `/supplyorders` says "cases" even when a supplier unit is one item.

**EMS and Dispatch**
- `pf-services/shared/catalog.lua`: the `govPermission` fields and the comment at lines 73–76 are no longer read and should be deleted.
- Other citizen requests (`taxi.ride`, `police.assist`, tow, mechanic) stay open after the requester leaves.
- Completing or deleting a call on an MDT does not close the pf-services request.
- The police MDT drops its calls after 300 s (`Config.CallExpirySeconds`), while the request lives 900 s.
- pf-services posts a new request to the MDT without checking it is still open, so a close that wins the race can leave the call (very unlikely).
- A medic call still being created when the caller logs out is not closed.
- Design limit kept: a standing player at 101–150 health who fakes last stand gets one call, and one more per relog.

**Vehicles**
- `interrupted_unverified` charges are never decided automatically. There is no staff tool for `review` holds or for `forfeit` and `stuck` owed rows; `/ledgerreconcile` lists the transfers.
- Owed rows and holds the database did not accept live only in memory and are lost on a restart.
- If reading the open holds fails at start, their car and buyer blocks are not restored. `data.applied` still stops a double payment.
- A paid transfer whose owner change committed but whose answer was lost is held. If the buyer lists or sells back the car before the next sweep (60 s), the buyer is refunded and keeps the car, and the seller is unpaid.
- Finance payments: `ChargeOutcome` treats a compensated cash transfer as final, while the payment had moved on to the bank. With a second ledger fault the bank is charged and the loan is unchanged.
- `resolveClaim` can, in a narrow window, give one plate two owners. A released listing ignores the lot's capacity.
- The comment at `pfm-vehicleshop/server.lua` (around lines 1221–1223) says pf-jobgarages refuses a car whose record is gone. It does not: `jobgarages:takeVehicle` still spawns it.
- The repossession retry (10 × 30 s) is kept in memory. The fallback when pf-jobgarages is stopped runs once.
- Fleet-add atomicity was checked under REPEATABLE READ only.
- Outside the area: pfm-garages `fleetTableExists` and `fleetPlateSet` still fail open. pf-government `CollectTaxAmount` returns 0 on an unclear treasury credit, so the tax can be refunded and also collected. pfm-vehicleshop `OrderStock` does not handle unclear results.

**Jobs and mechanic**
- **The tow deposit retry can still charge twice** (the recheck's should-fix). `PFPayout.Charge` keys each account (`:cash`, `:bank`) and starts from cash on every call. After a cash refusal and an unclear bank charge, a retry with enough cash charges `:cash` while `:bank` is still unsettled. Fix: retry only the account that went unclear, or check both keys first.
- `PendingDeposit` lives in memory. A charge that settles as taken after a restart, or when the player never retries, leaves the deposit in `system:pf-jobs` with no rental. A pending model the player no longer qualifies for blocks other rentals.
- A contract pay that failed on all 10 keys answers `pay_pending` for good.
- Gruppe 6, now that the recount runs in game: the close check and the recount can count a stop's bags twice (no money moves, but an honest early end is told bags were lost). Any client can grow `g6PickupRemaining` with made-up stash ids.
- The client tow scan reads replicated wear, so a car broken only by saved wear may not be offered on its first scan. The server still decides correctly.
- Older: Gruppe 6 `vehicleReturned` clears the sender's contract without checks; only the depositing player gets `goToDeposit`; a re-queued wear write reuses client-reported health; the wear epoch relies on state-bag order.

**Citizen and government**
- pfm-houses' transfer callback (`server/main.lua`, around line 956) should call `exports['pf-government']:RegisterProperty`. Without it, a cut made before an unregistered sale stays on the buyer's house until the next billing cycle.
- `PayBill`'s guarded `UPDATE` does not check the status, so a bill waived just before its read is paid and marked paid.
- A payment between escalation's "delinquent" update and `DisconnectService` leaves the power cut on a paid bill.
- An escalation action that raises is logged, not retried.
- The late-fee query compares the database time with the server's local time. A time-zone gap delays a fee by some hours; it never doubles it.
- The Bills app shows the higher amount without saying it includes a late fee.
- Mail:
  - a mail insert that raises after the row was saved counts as not delivered;
  - a link share whose mail fails keeps the link;
  - two copies at the same instant can go one over the cap;
  - recipients are not told about a missing attachment;
  - `undelivered` names the person even when only their business copy failed;
  - the draft `DELETE` after delivery is not guarded, so a retry can send twice (older).
- A copy's signature record is a snapshot: later signatures on the original do not appear on it.
- The Fines app's Recent list shows the newest 80, so under "all" property tax can crowd out fines.
- If pfm-houses never becomes ready, the property tax retries every 2 minutes, logging once.

**Batch 13 gaps not taken up in 13b**
- Banking: car wash, truck robbery, rentals, taxi, farming, App Store and revive still make a new key per click, so a retry after an unclear result that later completes can charge twice. The pfm-shops bail still shows two notices on an unclear result.
- Strict state bags: the progressbar copy has no LICENSE (upstream is GPL-3.0). pma-voice checks proximity for type and range only, not against `Cfg.voiceModes`. A channel switch while holding push-to-talk clears `radioActive` until release.

## Batch 14 — 2026-11-03: the confirmed security and backlog items (12 areas)

A read-only sweep confirmed 107 open items across both repos. Each area got one agent that first re-verified every
item on the current code, then fixed it, and an adversarial checker that read the diff, traced honest play and ran
the new specs against the old code. Areas that failed a check were reworked and checked again (MDT server: offline
bail; mechanic: NOS empty bottle; gov-computer: domain purchase keys). Every area passed.

| Area | Items | What changed (short) |
|---|---|---|
| Minigames, doors, keys | minigame-success, DOOR-1, KEYS-1, PICK-2 | pfm-minigames gets a server half: `IssueChallenge(src, kind, opts)` / `Verify(src, id)`, one answer per id, expiry and min/max duration. Doorlock and vehicle-key lockpicks and hotwiring are decided on the server; pick breakage is rolled there. |
| Heists | 9 items | Bank hack and thermite results verified through challenges; fire sessions owned by the server; bank doors opened through the doorlock server path at the verified step and relocked at reset; store registers, padlock safes (the combination never leaves the server) and house lockpick/search verified; armoured truck and guards spawned by the server, the charge planted only with guards down and the truck stopped; the accept race locked before the ledger wait, an unclear fee followed and refunded if it settles after the job was freed. |
| Police, prison, duty | POL-1..4, X-1..3, X-6..8, PRISON-01, prison gates, DUTY-1, 13B-POLICE | Cuff state only written by the server; escape detection, prison timer, jail items and gate hacks server-decided; spikes server-placed; `/fine` and bills through one keyed charge to the society with numbered attempts; impound fuel from pfm-fuel; duty points registered by resources (`RegisterDutyPoints`). |
| Police and EMS MDT server | MDT-01..11, EMS-01, MDT-XSS-4, MDT-NEGBANK | One permission table (`Config.Permissions`) with on-duty checks; sentencing only with the citizen present or booked; the MDT jail on the server (`pf_mdt_active_jails`), bail as an accepted offer with one keyed transfer and a released marker; roster reset backed up; charge caps and audit; image URLs validated. |
| MDT UI | MDT-XSS-1..5, DEV-MSG-1, MDT-RTE-1, MDT-DEAD-1 | Every server string into the DOM as text; image URLs through `safeImageUrl`; inline handler arguments through `escapeJsAttr`; the rich text editor is an allow list; postMessage accepted only from the right frame; dead pages removed (pf-jobs legacy NUI, pf-emsmdt app-extended.js). |
| Phone and voice | PH-1..3, X-4, X-5, 13B-PAYING | Calls held on the server with random ids; chat messages built by the server and appended under a lock; the upload webhook stays on the server (`pfm_phone_webhook` convar); `voice_serverCallsOnly` (default on) stops clients joining call channels. |
| Banking | BANK-1, X-9 | Shared-account managers cannot raise their own or others' rights beyond what they hold; the account lock is taken before the first wait. |
| Gov and computer | G1-3, X6-X10, GOV-XSS-1, GOV-ID-1, C2 | Website edits need the `website` permission; bills are server-only and capped; remote fines become unpaid bills; bill payments recorded before the charge (`pf_gov_bill_payments`); waivers and surplus refunds on numbered keys; identity edits use the character-creation validator; domain purchases reserved and keyed per try (`pf_computer_domain_purchases`). |
| Mechanic | MECH-1..11, MECH-X1..X9 | Hiring is an offer the citizen accepts (offline too, once a day); fitted parts persist; repairs, lift, clutch, coal, diagnostics, NOS drain, preview and service book checked on the server; roadside calls server-spawned, cancellable, timed out and paid on numbered keys to the character who took them; per-shop roles and settings. |
| Street jobs | hotdog x2, newsjob, drugs x2, ledger-unclear-handback, JOBS-1, JOBS-2, TOW-DEP | Hot dog cooking, price, quality and stock on the server; drug deliveries run by the server with a capped police multiplier; `PFPayout.IsClearFailure(res)` decides when goods go back; Gruppe 6 stops checked; taxi rating from the server; tow and taxi deposits read before charging. |
| Restaurants | R1, R2, X1-X5 | Kitchen events only to staff on shift, without citizen ids; roles need a shift; menu text is plain; pfm-menu escapes every string. |
| Vehicles | GAR-1..3, VS-1, VEND-1, CLASS-1, LAP-1 | House garages from the server; parking and take-out checked against the server's car (a second live copy or a different model is refused); sale mods from the server's record; vending distance and vehicle class on the server; lap times from server checkpoint stamps (radius 25 m). |

Lead fixes during integration: numbered keys for drug hand-over payments (pfm-drugs migration v2 `pay_attempt`);
one settle run per character for corner and hot dog sales (nothing lost, nothing handed back twice); the truck fee
follow-up; garage park checks; NOS drain loop walks a snapshot under pcall; roadside calls bound to the character;
premises-equipment registers get Clock in/out.

Tests: mocked 2496 passed, 0 failed (254 files); real DB 644 passed, 0 failed (69 files); all tests/js specs green;
`realdb/ledger_parallel.js` and `realdb/sql_install_check.js` pass. Not tested in game.

Open (carried into the overhaul plan, `docs/pf_ultimate/PF_REMAINING_WORK.md`): wave 2 (KEYS-2 callers to the server
GiveKeys export, GAR-4 garage props path); pf-tablet/pf-computer frame message guards; the PFPayout wrapper reports a
thrown bank call as `bank_unavailable` (a clear failure) although a row may have been written; per-target fine cap
and phone uniqueness not locked across officials; MDT tick release vs bail lock; client prompts for MDT bail.

In-game checks: see each area in the batch 14 reports; the main ones are the bank heist flow end to end, store and
house robberies, the armoured truck, prison gates and escape detection, MDT sentencing at a traffic stop and at the
station with bail, phone calls and photo upload, NOS boosting to empty, roadside calls, restaurant clock-in, garage
park and take-out, lap races.

The PF Ultimate overhaul blueprint (Police, EMS, Medical, Justice, Jail, Prison, Corrections, Community Service) is
in `docs/pf_ultimate/` (plan, architecture, migrations, integration matrix, progress tracker, test report, remaining
work). Implementation starts with batch 15.
