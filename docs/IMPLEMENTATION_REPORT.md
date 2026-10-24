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
