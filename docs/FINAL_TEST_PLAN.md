# PF Mods final test plan (run once the FiveM environment is up)

Nothing in this plan has been run against a live FiveM server with clients yet. Record results in the "Result" column of each run, with the date and commit tested.

## 0. Environment needed
- **Staging server:** an FXServer started from `docs/staging/server.staging.cfg`, with:
  - its start order (oxmysql, cfxlua-require, ox_lib, pfm-core, [qb], [standalone], [voice], [pfscripts]);
  - a copy of the live database (never the live database itself);
  - ox_lib v3.41.0 with cfxlua-require.
- **Clients:** at least two connected game clients (owner and employee, or two players), plus one admin.
- **Console access:** to the server, to read the logs.
- **Missing today:**
  - no game client is reachable from the development session;
  - the live database is not available;
  - only the local FXServer has been driven, with no clients.

## 1. Automated checks (development machine)
| Check | Command |
|---|---|
| Lua syntax of changed files | `node tests/parsecheck.js <files>` |
| Mocked suite | `cd tests && node harness.js` |
| Real-database suite | start the throwaway MariaDB on 3399, then `PF_TEST_DB=mysql://root@127.0.0.1:3399 node realdb/run.js` |
| Parallel ledger | `PF_TEST_DB=... node realdb/ledger_parallel.js 6` |
| Install SQL files | `PF_TEST_DB=... node realdb/sql_install_check.js` |
| Event collisions | `python docs/staging/event_collisions.py <staging resources>` |
| Staging start | run FXServer about 140 s; expect only the kq_wheeldamage entitlement failure |

## 2. Database and migrations (copy of live)
1. **Back up**, then start staging on the copy. Every migration logs once; a second start applies nothing.
2. **Balances:**
   - `/ledgerreconcile` reports no mismatches;
   - totals of `players.money` (bank/cash) and `bank_accounts` match before and after;
   - legacy shared accounts appear once as IBAN accounts.
3. **Data kept:** businesses, vehicles, houses, inventories and stashes are unchanged.
4. **Interrupted transfer:** kill the server in the middle of a transfer (staging only), restart, and check that recovery settles it.

## 3. Gameplay loops (two clients)
| Loop | Steps | Expect |
|---|---|---|
| Restaurant supply chain | Boss orders ingredients on PF Computer (delivery); trucker accepts on the tablet/app, loads at the warehouse, drives to the restaurant; staff inspect and unpack the pallet; cook; sell to the second player at the register | Business account charged once; driver paid once; pallet visible to both players; stock in fridge/freezer; dish made; customer charged the menu price plus tax; government record shows revenue |
| AI fallback | Order with nobody accepting for the priority window | AI delivers, pallet appears |
| Cancellation | Cancel before a driver accepts; try after | Refund once; refused after |
| Restart mid-delivery | Restart pf-trucking and pf-stores while in transit | Same driver, same order |
| Pallet persistence | Restart pfm-worldobjects / the server with a sealed pallet | Same position, rotation, contents |
| Store | Buy a store, stock it via supply order, sell through the storefront | Owner account credited, tax collected |
| Mechanic | Bill a customer at the register, customer accepts; order parts and run the pickup mission | Shop account credited, commission once; parts in the shop stock |
| Jobs | One full run each: garbage, Gruppe6, taxi, bus, tow, recycle, diving, vineyard, trucking contract | Paid once at the end; repeats pay nothing |
| Government | Approve a premises slot; owner buys a fridge; close a business; cut and restore power by paying a delinquent bill; transfer ownership; inspect a restaurant | Effects visible in the business (sales refused while closed, capacity up, owner changed) |
| District power | Underfund the power department | Lights go out on the schedule; restored when funded |
| Farming | Plant, water, harvest, sell to the market, stock a supplier offer | Plot persists across restart; spoiled produce refused |
| MDT | Officer looks up a citizen: licenses, unpaid fines; non-police try to open records | Data shown to police only |
| Premises equipment | Government approves a register slot and a cooking slot; owner buys a POS Register and a Grill Station; staff use both | Register opens the POS and sales pass the range check; the grill cooks like a configured one; both survive a restart |
| Loans | Grant a loan (auto-pay on), shorten the interval, wait for a due date; then empty the business account and miss payments | Installment taken once per due date; missed payments mark the business warning, then non-compliant on default; paying what is due restores it |
| Tablet Business Manager | Government staff open the registry, view employees, transfer a store; a cook opens My supplies | Real businesses and staff; transfer changes the store owner and appears in Audit; cook sees their restaurant's orders only |

## 4. Multiplayer and exploits
| Case | Expect |
|---|---|
| Two truckers accept the same delivery | One wins |
| Two players unpack the same pallet | Stock added once |
| Double-click order / resend events | One order, one charge |
| Disconnect mid-cook, mid-order, mid-delivery | Ingredients returned / order intact / contract released |
| Another business boss opens our pallet / stash / premises | Refused |
| Forged events from a modified client: payouts, completion, prices, give items, open stashes by id | Refused (see sweep specs for the list) |
| Freshness reset by moving items between stashes, trunk, glovebox | Freshness kept |

## 5. Performance
- **Profile:** resmon on staging with two clients for 30 minutes. Watch pf-trucking, pf-stores (ticks), pfm-inventory (sunlight tick every 5 minutes), pf-government (simulation tick), pfm-worldobjects.
- **Queries:** check the MySQL slow query log during the gameplay loops.

## 6. Failure handling
Failures found here are fixed on main, then this section is rerun for the affected loop and the automated suites.
