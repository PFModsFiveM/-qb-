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
| Job fleet | Owner parks a car, adds it to the job fleet; tries the personal garage and the impound; an employee takes it from the job garage; the car is removed from the fleet | Personal garage and impound do not list or release it and charge nothing; the job garage does; after removal the owner gets it back |
| Tablet Business Manager | Government staff open the registry, view employees, transfer a store; a cook opens My supplies | Real businesses and staff; transfer changes the store owner and appears in Audit; cook sees their restaurant's orders only |

## 3b. Devices, news and job links (batch 10)
| Loop | Steps | Expect |
|---|---|---|
| Same app, both devices | Open Taxi, Dispatch, Services and a mechanic app on the tablet, then on the computer | Same screens and same data on both; actions on one show on the other after a refresh |
| App visibility | Change job, grade and duty (police, tow, mechanic, unemployed) with the tablet open | The home screen and the desktop update by themselves; apps of the old job disappear and their RPCs are refused |
| App Store | Install and remove News; buy a paid app with too little money, then with enough | Free install works; paid install charged once (reinstall is free); refused when the bank cannot pay |
| MDT in the devices | Police open the Police MDT app on the tablet, then on the computer; EMS the EMS MDT; use every page (records, warrants, reports, dispatch, map, CCTV); press the MDT's close button; put the tablet away with the MDT open; a civilian tries | The same MDT as the full-screen one, inside the window. The dispatch pop-up and custody timer still show over the game. Close shuts only the window, and the device keeps the cursor. Not listed for a civilian |
| Police and EMS dispatch | Call 911 or use Services → police / medic; get downed | A call appears on the MDT dispatch board; police and EMS have no separate Dispatch app |
| Citizen calls a tow | Citizen in a broken car calls "Vehicle recovery" in Services; tow driver accepts in Dispatch, hooks with the flatbed, drives to LS Customs, presses Complete away from the shop, then at the shop | Fee held from the citizen; Complete refused away from a shop; paid to the driver at the shop; the citizen sees "On the way" then "Done" |
| Police impound with a tow driver | Officer impounds while a tow driver is on duty; tow driver delivers to the Mission Row impound | The car stays (locked) until delivered; the record shows seized/depot only after delivery; the city account paid the driver once |
| Police impound without a tow driver | Same with no tow driver on duty | Instant impound as before |
| Mechanic tow order | Mechanic scans a car with engine under 30% | A tow request appears in Dispatch for tow drivers; the shop account holds the fee |
| Robbery → dispatch → news | Start a store robbery and a bank robbery | A police dispatch request each; the store robbery becomes a newsroom lead only; the bank robbery gets an automatic breaking bulletin |
| City Hall → news | Mayor changes a tax, publishes a law, cuts a district's power | An automatic article for each (taxes changed together become one article); nothing for a no-op change |
| Newsroom | Reporter claims a lead, writes and publishes (or submits for review by an editor); a business boss buys an ad; an editor rejects an ad | Article on the News app and on news.ls in both browsers; reporter paid once; ad charged to the business and refunded once on rejection |
| Government on the tablet | Officer/staff issue a fine to a nearby citizen; inspect a business at its door and away from it; approve a slot request where the business recorded it; set a delivery zone | Fine billed; inspection refused away from the business; slot created at the recorded spot; the next supply order delivers to the zone |
| Mail and bills everywhere | Send mail tablet → computer → phone; receive a City Hall notice while offline; pay a fine in Bills | One mailbox on all three; notice waiting at login; fine paid once |
| Computer without fakes | Post a job on the Job Board as a boss, apply as a citizen, hire | Applicant identity from the server; hire sets the job; no fake bills, stock or employee numbers anywhere |

## 3c. Every system as a device app (batch 11)
| Loop | Steps | Expect |
|---|---|---|
| Business apps on both devices | A restaurant owner opens Business Manager, Order Supplies and Job Board on the tablet, then on the computer; promotes, fires, orders, posts a job and hires an applicant | Same screens on both; the hire appears in the restaurant's staff list; the order and its delivery show without reopening |
| Lock screen | Set a PIN on the computer, reconnect, enter a wrong PIN several times | The PIN survives the reconnect; the lockout is counted on the server |
| Bank | Transfer to another citizen by IBAN and by citizen id; retry when the screen hangs; read statements with filters; rob a Fleeca | Each transfer once; the daily limit holds; the robbed branch refuses counter and ATM use nearby and reopens by itself |
| Crypto and Boss | Buy, sell and send coin; a boss hires a person beside them, deposits and withdraws society cash at the desk and away from it | Each trade once; cash only at the desk; staff changes follow the boss rules |
| Garages | Pay an impound fee from the app, then collect the car at the depot; ask for a tow to a garage; a tow driver delivers it | Charged once, the depot shows it paid; the car is parked in that garage after delivery |
| Real estate and dealer | An agent sells a house and a dealer sells a car to a customer beside them; the customer accepts in the prompt, then in the app | Money moves only after accepting; commission once; the house is registered; the car gets a DMV bill; dealer stock drops by one |
| Bus and tow | Drive a bus route in the depot bus and in another car; rent a flatbed, hook a car, finish an NPC contract, hand a dispatch request back | Pay only in the depot bus; deposit refunded once on return; contract paid once; the request goes back to the queue |
| Crews and Gruppe 6 | A Gruppe 6 leader sets 60/40 shares; buy an upgrade; rob an armoured truck near a pickup | Each member paid their share once; the upgrade charged once and applied; pickups near the robbery held, crews warned |
| Side jobs to businesses | A vineyard worker supplies wine to a restaurant; a recycler supplies scrap and a mechanic part case to a mechanic shop | Exactly what was paid for arrives (10 supplier units for a case of 10); glasses of wine are made, sold and drunk (alcohol) |
| Strict state bags (only after progressbar and pma-voice are patched; see the staging cfg) | Run the server with `setr sv_stateBagStrictMode true`; plant weed, corner-sell, fit a harness, decorate a house, refuel, fit NOS, take a car out of the garage | No state-bag errors in the console; the inventory locks and frees during each action; fuel, NOS and wear show the same for two players |
| Character deletion | Delete a character that owns a house, a car on the lot, installed apps, open requests and documents | Their rows are gone or anonymised; houses back on the market; shared documents stay with the others; nobody else's data changes |

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
| Two tow drivers accept the same request | One wins |
| Forged device RPCs: another job's app, an uninstalled app, oversized payloads, a flood of calls | not_authorized / not_installed / payload_too_large / rate_limited |
| A worker completes a paid request without doing it | Refused by the job's check; the citizen's confirmation is the only other way to pay |

## 5. Performance
- **Profile:** resmon on staging with two clients for 30 minutes. Watch pf-trucking, pf-stores (ticks), pfm-inventory (sunlight tick every 5 minutes), pf-government (simulation tick), pfm-worldobjects.
- **Queries:** check the MySQL slow query log during the gameplay loops.

## 6. Failure handling
Failures found here are fixed on main, then this section is rerun for the affected loop and the automated suites.
