# PF Mods final test plan (run once the FiveM environment is up)

Nothing in this plan has been run against a live FiveM server with clients yet. Record results in the "Result" column of each run, with the date and commit tested.

## 0. Environment needed
- **Staging server:** an FXServer started from `docs/staging/server.staging.cfg`, with:
  - its start order (oxmysql, cfxlua-require, ox_lib, pfm-core, [qb], [standalone], [voice], [pfscripts]);
  - progressbar and pma-voice from [qb] only: delete `[standalone]/progressbar` and `[voice]/pma-voice` (same names; either may start otherwise);
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
| App Store | Install and remove News. No app has a price yet: on staging, give one app a test price (`store.price` in its registration) first, then buy it with too little money, then with enough | Free install works; paid install charged once (reinstall is free); refused when the bank cannot pay |
| MDT in the devices | Police open the Police MDT app on the tablet, then on the computer; EMS the EMS MDT; use every page (records, warrants, reports, dispatch, map, CCTV); press the MDT's close button; put the tablet away with the MDT open; a civilian tries | The same MDT as the full-screen one, inside the window. The dispatch pop-up and custody timer still show over the game. Close shuts only the window, and the device keeps the cursor. Not listed for a civilian |
| Police and EMS dispatch | Call 911 or use Services → police / medic; get downed | A call appears on the MDT dispatch board; police and EMS have no separate Dispatch app |
| Citizen calls a tow | Citizen in a broken car calls "Vehicle recovery" in Services; tow driver accepts in Dispatch, hooks with the flatbed, drives to LS Customs, presses Complete away from the shop, then at the shop | Fee held from the citizen; Complete refused away from a shop; paid to the driver at the shop; the citizen sees "On the way" then "Done" |
| Police impound with a tow driver | Officer impounds while a tow driver is on duty; tow driver delivers to the Mission Row impound | The car stays (locked) until delivered; the record shows seized/depot only after delivery; the city account paid the driver once |
| Police impound without a tow driver | Same with no tow driver on duty | Instant impound as before |
| Mechanic tow order | The shop's boss scans a car with engine under 30% next to them; a mechanic who is not the boss tries the same | A tow request appears in Dispatch for tow drivers; the shop account holds the fee. The other mechanic is told the boss can order a tow |
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
| Strict state bags (staging cfg; the originals of progressbar and pma-voice removed) | Run the server with `setr sv_stateBagStrictMode true`; plant weed, corner-sell, fit a harness, decorate a house, refuel, fit NOS, take a car out of the garage | No state-bag errors in the console; the inventory locks and frees during each action; fuel, NOS and wear show the same for two players |
| Character deletion | Delete a character that owns a house, a car on the lot, installed apps, open requests and documents | Their rows are gone or anonymised; houses back on the market; shared documents stay with the others; nobody else's data changes |

## 3d. Review fixes and owner decisions (batch 13)
Run with strict state bags on (staging cfg) and the originals of progressbar and pma-voice removed.

| Loop | Steps | Expect |
|---|---|---|
| Banking: counters | Withdraw and deposit cash at a bank counter, then a few metres away; do the same for a society account; rob the branch and try again | Works within about 5 m of the counter; refused further away; refused at the robbed branch until it reopens |
| Banking: ATMs | Use ATMs across the map, including the ones inside branches and the five vRP-added spots; try without a bank card; try an ATM that is not in the list; run `/atmcheck` as admin at a listed and an unlisted ATM | The screen opens and 4 m is enough at every listed ATM; no deposit option; refused without a card; an unlisted ATM says "out of service"; `/atmcheck` says "listed" or prints the line to add; a robbed branch closes its nearby ATMs |
| Property tax | Open the tax schedule; wait about a minute after start (or run `govpropertytax` in the console) with house owners online and offline; pay one bill in Bills on the tablet, another on the computer; restart pf-government | "property" shows at 0.5%; each owner gets one bill "Property tax: <address>, week of YYYY-MM-DD", and a notification if online; each bill is paid once; the restart creates no second bill |
| Computer: Job Board after a restart | Restart only pf-services, then post a vacancy | The hiring news item appears |
| Computer: supply pickup | A grade-2 mechanic who is not the boss presses Collect on a ready order; then the boss does | No truck for the employee; the boss's run unpacks the order |
| Inventory: search | An officer searches a player, then walks more than 5 m away; search again and the officer disconnects; search again and the officer opens their own inventory | Walking away frees the target within a minute (TAB does not free them at once); a disconnect and the officer's own inventory free them at once. *Batch 13b changes this: about 2 s, and TAB frees them at once (see 3e)* |
| Inventory: progress bar lock | Open the inventory during a progress bar; kill the client in the middle of a bar | Refused during the bar, free after it ends or is cancelled; after the kill, the lock ends after the bar's time plus about 10 s |
| Documents | Mail a document you don't own; delete a document someone else signed | The recipient gets a read-only copy; the signer still has the document |
| Phone invoices | Watch the console on first start; pay an invoice from the phone, another from the Bills app | The `ALTER phone_invoices` lines appear on the first start only; each invoice is paid once and the business credited once |
| EMS: down calls | Read a last-stand player's health on the server; go down, then bleed out; get revived; go down again and respawn, check in, log out, drop; reconnect while dead, once more than 60 s after the first call and once within 60 s | Last stand reads 150; one call on the EMS MDT, still one after bleeding out; the call shows done after the revive; respawn, check-in, logout and drop take it off the board; reconnecting dead brings it back |
| Dispatch | A citizen calls roadside repair with Benny's on duty; a government employee without the licenses permission opens a license request in Dispatch; Business Requests approves another request | Benny's gets the waypoint; no Accept button for that employee; the approval still works |
| Fuel | Drive a car with a second player watching the gauge; refuel at a pump and with a jerry can; spawn a new car from a garage; refuel at a pump far from a station | Both players see the same level (if the other player lags behind, raise `Config.MaxFuelBurnPerSecond`); the pump and the can work on a car that already has a level, and the pump charges only for what fits; the new car's level reaches the other player; the far pump still works at the base price (known). *Batch 13b changes this: pumps sell only at stations (see 3e)* |
| Cruise | Turn cruise on and off, steer through curves, leave the seat with cruise on; move the icon in HUD edit mode | The icon shows only while cruise is on and sits well in the vehicle icon row; leaving the seat turns it off. Note whether cruise switching off after curves is a problem |
| Jobs: tow return | Fire a tow driver who has a flatbed out; they return it at the bay; with a car on the bed, restart pf-jobs and use `/tow` | The Tow app stays and shows only the return; the return-only yard target appears; the deposit is refunded once and the app disappears; `/tow` takes the car off the bed |
| Jobs: Gruppe 6 early end | End a contract early with no bags, then another with some bags handed in; press E at HQ to return the truck | No bags: the crew is sent to the HQ return area, no pay; some bags: the partial share; one progress bar, and the truck's "Open Storage" target is gone |
| Jobs: bus | Spam "take bus" | One bus comes out |
| Mechanic: tow billing | The boss scans a car with engine health at 30% or less (batch 13b: or another reason the server reads as broken); a mechanic who is not the boss tries | A request appears in Dispatch, paid by the shop; the other mechanic gets the "boss can order" message |
| Mechanic: repair | Repair a part while another player drives the car | The old wear does not come back |
| Mechanic: NOS | Empty or remove a bottle, then store the car straight away; again, and let the 30 s save run; take the car out | The bottle is still empty |
| Stores: totals | A store, a restaurant and a job business each place a small delivery order and a pickup order; a player supplier fills one delivery; cancel another before delivery | Delivery charged goods + markup + freight (at least the freight minimum) from the business account; pickup charged goods only; the supplier sees "You earn…" and is paid only when the trucker delivers; the cancel refunds the whole amount. *Batch 13b: a delivery below `MinDeliveryGoods` is refused, so order at least the minimum (see 3e)* |
| Stores: delivery route | A restaurant and a mechanic shop each order a delivery | Each order gets a delivery point (or the government delivery zone) and is delivered |
| Voice | Push-to-talk on a radio channel with a second player; switch channel while talking; F11 proximity cycle; `/vol`; the radio volume buttons; die or get cuffed (resources that add a radio-disable bit); restart pma-voice | The other player hears you and the pf-hud radio icon shows (about one ping later); proximity and volumes change; the radio is blocked while dead or cuffed; voice works after the restart; no refused state-bag writes in the console |
| Vehicles: used lot | Start the server; list a car, then take it back; try to list and to sell back a fleet car and an impounded car (OneSync on) | "pfm-vehiclesales v1 applied" in the console, once; condition, odometer and loan unchanged after take-back; both refused, and the cars stay in the world |
| Vehicles: transfers | `/transfervehicle` as a gift, as a sale, with a fleet car, and with a financed car while `Config.PreventFinanceSelling` is on and off | Gift and sale move the car once; the sale pays the seller once; fleet car refused; financed car refused when on, and the buyer sees the loan before accepting when off |
| Vehicles: dealer offer | A dealer replaces an offer while the customer's prompt is open; the customer clicks the old prompt, then accepts the new offer; check both accounts | The old click accepts nothing; the new offer is paid; the dealership gets the price minus the commission and the salesperson the commission |

## 3e. Gaps from the batch 13 checks (batch 13b)
Run with strict state bags on (staging cfg), as in 3d. Several rows need a second player.

| Loop | Steps | Expect |
|---|---|---|
| Phone: pay once | Pay an invoice from the phone, another from the Bills app; check the business account and the mails | The money moves once; the business mail arrives once |
| Phone: restart mid-payment | Pay an invoice and restart the server straight away; wait about 2 minutes after the start | The sweep settles it: the business is credited once and the paid mail arrives; the invoice is not charged again |
| Phone: business without an account | Send an invoice whose business has no bank account | The phone says it cannot receive payments; no money moves |
| Phone: escaped text | Put text such as `<b>x</b>` in an invoice reason | It shows as plain text on the phone |
| Phone: `/fine` | `/fine` a player who has no money | The invoice "Police fine" appears on their phone |
| Phone: console | Watch the console on the first start | The `ALTER phone_invoices` lines appear once; note any "waits for an admin" warnings |
| Inventory: search wait | An officer starts a search and steps back during the 1.5 s wait | No window opens |
| Inventory: walking off | During a search the searched player walks more than 2.5 m away, then presses TAB | The officer's window closes within about 2 s; TAB opens the target's own inventory at once |
| Inventory: target's windows | Start a search while the target has their inventory open; during the search the target tries hotbar keys, dropping a bag and giving an item | Their inventory closes; hotbar keys, drops and gives do nothing |
| Inventory: admin menu | An admin opens a player's inventory from the admin menu, far away | It opens (this confirms the server sees the call as `pfm-adminmenu`) |
| Inventory: moving suspect | Search a suspect who sways or is ragdolled | Note whether 2.5 m ends honest searches too early |
| Fuel: first level | Take a car out of a garage (note its stored fuel), also with a changed plate; spawn a new car, a job car and a test-drive car; buy a used car from the lot | The garage car starts at its stored fuel, also with the plate changed; new, job and test-drive cars start full; the used car starts at the fuel it was sold with |
| Fuel: parking | Drive a garage car, park it, take it out again | The real level was saved |
| Fuel: pumps | Use a pump right after getting into a car; use a pump far from any station and one on a custom map | The first waits briefly instead of saying "busy"; the others say "Fuel is only sold at a gas station" until their spot is in `Config.ExtraPumps` |
| Fuel: burn rate | Drive with a second player watching the gauge | The two gauges agree (the 0.5 per second cap from batch 13) |
| Cruise | Turn cruise on and drive through curves | Speed is held through the curves |
| Stores: delivery route | A restaurant and a mechanic shop each order a delivery | The contract is posted and the pallet appears |
| Stores: small orders | Place a delivery below the minimum, then the same order as a pickup; look at the cart | The delivery is refused with the message and "Place order" is disabled; the pickup works; the cart shows the delivery total |
| Stores: second boss | Two bosses press Collect on the same ready order | The second is refused; one truck |
| Stores: supplier deleted | A player supplier accepts an order, then their character is deleted before delivery; run `/supplyheld` as admin and as a player | The store gets the goods money back after about 7 minutes; `/supplyheld` works for the admin only |
| EMS: leaving while down | Log out, or drop, in last stand right as you go down | No call is left on the EMS MDT |
| EMS: reconnect | Crash in last stand and reconnect within 60 s; then bleed out | The call comes back; bleeding out keeps that one call |
| EMS: medic call | Make a /911e or Services medic call, then log out | The call leaves the EMS board |
| Police MDT | A citizen makes a Services police call, then cancels it | It leaves the police MDT board |
| Dispatch | A government licenser takes a license request in Dispatch; a clerk without the permission opens it | The licenser can take it; the clerk sees no Accept button |
| Vehicles: migrations | Start the server | "v2 applied" for pfm-vehicleshop and pfm-vehiclesales, once |
| Vehicles: held sale | On staging, block the database for a moment during a purchase, a used-lot buy and a paid `/transfervehicle` | Each finishes within about 60 s; a held purchase arrives parked in the delivery garage with a notification and a mail; nobody is charged twice |
| Vehicles: fleet | Repossess a fleet car; try to add a listed car to a fleet; re-add a car that was removed from a fleet | The repossessed car leaves the fleet and the road; the listed car is refused; the re-add works |
| Gruppe 6: shared stash | Take bags from a pickup, then end early right after | "You took N bag(s)" appears; no "not safe for net" line in the console; the early end counts those bags |
| Gruppe 6: lost bags | Hand in some bags, lose the rest, end again, close at the vault | The client is sent to return the truck |
| Gruppe 6: trunk | Put bags in the truck's trunk, lose the rest, end early | The trunk bags count |
| Gruppe 6: party | Leave the party, or get kicked, mid-contract; then take a new contract | The new contract starts |
| Gruppe 6: return | Return the truck at HQ, then take the next one | "Open Storage" is gone from the old truck and present on the next |
| Tow: owed pay | A driver whose contract pay is owed leaves the job and collects it in the Tow app; get fired while the app is open | Paid once; the open app switches to the return-only view |
| Tow: deposit | Rent a flatbed while the bank is restarting | One deposit at most, and a clear message |
| Mechanic: tow order | The boss orders a tow for a car that already has a police impound order; scan a car with only body damage | The impound reason is given; the body-damaged car is offered a tow |
| Mechanic: repair | Repair a car, then store or delete it at once; take it out again | It comes back repaired |
| Documents: signed copy | Mail a signed document to a third person; make a copy of a copy that its middle owner signed | The recipient sees "Signatures on the original" and no signatures on their copy; the second shows "signed an earlier copy" |
| Documents: copy room | Fill a citizen's room for received copies, then let them write a document | They can still write their own documents |
| Government: late fees | Let a fine go overdue; pay it at the moment the fee lands; on the copy of live, look at older overdue bills after the first hourly run | One late fee only; a fee that landed during the payment is still due; every older overdue bill gets one fee |
| Government: house utilities | Bill a house; pay one bill in the owner's Bills app; let another go delinquent, then waive it | The bill appears in Bills and is paid once; waiving the delinquent bill brings the power back |
| Government: Fines app | Staff open Fines → Houses | Property-tax bills are listed and can be waived |
| Government: start order | Restart pfm-houses, then pf-government | The property tax waits, then bills the price paid |
| Government: hourly run | Cause a database hiccup during the hourly run | It is logged, and the next hour's run still goes |
| Export boundary: device apps | Open one app from each resource on the tablet and the computer (Mail, Bills, Documents, Dispatch, Services, News, Supplier, the job apps, the government apps) and use one action in each | Every app answers; before batch 13b no app outside pf-devices could answer in game |
| Export boundary: requests with proof | Try to complete a government field request and a tow impound order without the proof | Both are refused; with the proof they complete once |
| Export boundary: migrations | Start on a fresh database and on a copy of live | Every resource's migrations run, including the ones with function steps; no migration error in the console |
| Export boundary: MDT access | A civilian triggers an MDT action (for example through the device app) | They get "no access" at once (no hanging window) |
| Export boundary: jail | Jail a player with items through the MDT, then release them | Items are taken at jailing and returned at release |
| Export boundary: licences | For an online citizen: grant a licence, then suspend another; lift and remove; relog the citizen; open the profile of one whose suspension ran out | Each change survives the relog; the licence granted just before the suspension is kept; the expired suspension is lifted at once |
| Export boundary: MDT duty | Toggle MDT duty twice | The right state shows each time |
| Export boundary: smaller fixes | Change a member's rank as a boss; clean a weapon; run `/admincustoms` as a QBCore admin; `/giveitem` a chop_kit; gain hot dog rep; trade crypto; check the crafting XP lock | The member is told the new rank; gun oil is used up; admincustoms opens; the item is given; the rep, wallet and portfolio show the new values; the XP lock works |

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
