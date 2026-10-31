# Job links: how the jobs rely on each other

Every link below is server-checked and every payment goes through the bank ledger. Nothing here
was tested with a game client yet (see `FINAL_TEST_PLAN.md`).

## How links work

Two shared services in `[pfscripts]/pf-services` carry every link:

- **City events.** A system records something that happened: `exports['pf-services']:Emit(kind, data, opts)`.
  - Every event lands on one timeline (`pf_city_events`).
  - **pf-news** turns `auto` kinds into articles straight away (city-hall decisions, major heists). `lead` kinds become leads for reporters.
  - Kinds marked `police` also put a police dispatch request on the map.
  - The kinds are listed in `pf-services/shared/catalog.lua`.
- **Service requests.** One job, a citizen or the city asks another job to do something:
  - the request is created with `CreateRequest`;
  - workers see it in the **Dispatch** app (tablet and computer), accept it, and complete it;
  - citizens call for help from the **Services** app.
- **Workers can't fake completion.**
  - A request that pays completes only when the worker's resource proves the work was done (`RegisterRequestHandler`), or when the citizen who asked confirms it.
  - The reward is held from the payer when the request is made, paid to the worker on completion, and refunded on cancel or expiry. Each of these is one ledger transfer with a fixed key.

## Links built in this batch (batch 10)

| From → To | Trigger | What moves | Code points (from / to) | Why it makes sense |
|---|---|---|---|---|
| Police → Tow | An officer impounds a car while a tow driver is on duty | A `tow.impound` request (plate, server position, depot price or seizure). The city treasury pays $250 to the driver. The car is locked and stays until towed. | `pfm-policejob/server/vehicle.lua` (`police:server:Impound`, `FinalizeImpound`, `GetImpoundLots`) / `pf-jobs/server/apps/tow_requests.lua` | Impounds become real work for tow drivers instead of cars vanishing. With no tow driver on duty, the old instant impound still applies, so police are never blocked. |
| Tow → Police records | The towed car reaches an impound lot with the driver beside it | The vehicle record is written (seized, or depot with fee) and the car is removed | `pf-jobs/server/apps/tow_requests.lua` → `pfm-policejob` `FinalizeImpound` | The impound only counts when the car is really at the lot. |
| Mechanic → Tow | A mechanic's diagnostic finds a car that can't be driven | A `tow.recovery` request for the car next to the mechanic. The shop's account pays, and the shop bills the customer at the register. | `pf-mechanicjob/server/advanced_systems.lua` (`requestTow`) / `tow_requests.lua` | Breakdowns become tow work, and the repair continues at the shop. Before this, the tow call went to events nothing handled. |
| Citizen → Tow | The Services app: "Vehicle recovery" | A `tow.recovery` request with the plate of the citizen's car. The citizen's bank pays the $175 call-out fee, paid to the driver on delivery to a mechanic shop. | `pf-services/server/requests.lua` (`CitizenRequest`) / `tow_requests.lua` | A broken-down player gets a real tow from a real driver. |
| Citizen → Mechanic | The Services app: "Roadside repair" | A `mechanic.roadside` request to every mechanic shop (mechanic, Benny's, Beeker's). The $100 call-out fee is paid when the citizen confirms the job. | `pf-services` catalog and `CitizenRequest` | Mechanics get call-outs. Parts and labour are still billed at the register. |
| Citizen → EMS, Police, Taxi | The Services app | `ems.patient`, `police.assist` and `taxi.ride` requests at the citizen's server position, with no fee | `pf-services` | One place to call any emergency or service, on the tablet or the computer. |
| Any event marked `police` → Police | Robberies, prison escapes (emitted by the robbery and prison resources) | A `police.assist` request at the event position, one per incident. It appears as a call on the police MDT's dispatch board. | `pf-services/server/main.lua` (`OnEvent`, then `CreateDispatchCall` on the MDT) | Alarms become MDT dispatch calls. |
| Police and EMS requests → their MDT | Any `police.assist` or `ems.patient` request (911, the Services app, alarms, downed players) | A call on that MDT's dispatch board (`CreateDispatchCall`). Police and EMS don't get the separate Dispatch app while their MDT runs. | `pf-services/server/main.lua`, `apps.lua` → `pf-policemdt-DEV` / `pf-emsmdt` | One dispatch for police and EMS: the MDT, on the tablet and the computer. |
| Bank robbery → Police + News | The vault opens after the hack, keycard and police-count checks | `crime.robbery.bank`: a dispatch request and an automatic breaking bulletin | `pfm-bankrobbery/server/main.lua` | A major heist is public news, and police get a call they can navigate to. |
| Power grid sabotage → News | Every power station is hit (thermite seen by the server) | `crime.blackout`: an automatic bulletin | `pfm-bankrobbery/server/main.lua` | A city-wide blackout is news. |
| Store robbery → Police + Newsroom | A register is lockpicked or the safe opened (once per store per 15 min) | `crime.robbery.store`: a dispatch request and a reporter lead | `pfm-storerobbery/server/main.lua` | Police respond; a reporter can cover it. |
| Store robbery → Store owner | The same, at a player-owned pf-stores shop | A notification to the owner | `pfm-storerobbery/server/main.lua` → `pf_stores` owner | The owner can call the police or come and defend the shop. |
| House burglary → Police + Newsroom | The burglar alarm, now rolled on the server when the lockpick starts (once per house per 10 min) | `crime.robbery.house` ("a home on <street>"): a dispatch request and a lead | `pfm-houserobbery/server/main.lua` | A modified client can't skip the alarm any more. |
| Armored truck → Police + Newsroom | The guard alert, or the loot being taken (once per mission) | `crime.robbery.truck`: a dispatch request and a lead | `pfm-truckrobbery/server/main.lua` | Skipping the client alert no longer means robbing in silence. |
| Jewelry heist → Police + News | The first display case really emptied | `crime.robbery.jewelry`: a dispatch request and an automatic bulletin | `pfm-jewelery/server/main.lua` | One heist, one bulletin. |
| Downed player → EMS | The player's state changes from up to down (last stand or death), at the server position | One `ems.patient` request in the medics' Dispatch app. Revive and first aid close it as done; respawn, check-in, admin revive, getting up and logging off close it as cancelled. | `pf-ambulancejob/server/main.lua`, `treatment.lua` | Medics see every downed player on the map, with no stale calls. |
| 911 → Police and EMS | `/911p` or `/911e` (server position) | `police.assist` / `ems.patient` requests from the caller, one open call per caller | `pfm-policejob/server/commands.lua`, `pf-ambulancejob/server/main.lua` | 911 calls arrive in the Dispatch app with a location. |
| Police jail and MDT sentences → Newsroom | `/jail` by an on-duty officer next to the target; an MDT sentence carried out | `police.sentenced` (name, months, charges): a court lead | `pfm-policejob/server/interactions.lua`, `pf-policemdt-DEV/server/main.lua` | Court reporting. |
| MDT warrant → Newsroom | `pf_mdt:createWarrant` (officers only) | `police.warrant` (suspect, charge titles; no narrative or witnesses): a lead | `pf-policemdt-DEV/server/main.lua` | Wanted-person stories. |
| Officer seizes drugs → Newsroom | An on-duty officer takes listed drugs from another player (moves within 60 s combined) | `crime.drugs.bust` (items, total; the suspect isn't named): a lead | `pfm-policejob/server/evidence.lua` | Busts become stories. |
| Prison escape → Police + News | Sentence cut short while the server sees the inmate far from the prison | `crime.prison.escape`: a dispatch request and an automatic bulletin | `pfm-prison/server/main.lua` | A manhunt plus a public warning. |
| Weather → News | The weather changes into thunder or a blizzard | `weather.severe`: an automatic bulletin | `pfm-weathersync/server/server.lua` | Storm warnings. |
| Street and lap races → Newsroom | A winner judged on the server, with 2 or more racers | `race.finished` (winner, time, racers, pot): a lead | `pfm-streetraces`, `pfm-lapraces` | Racing stories. |
| City Hall → News | Every government decision (taxes, laws, budgets, power and water cuts, utility cut-offs, business registration, closure, transfer, failed inspections, loan defaults, announcements, appointments) | An automatic article from a preset, with no mayor action | `pf-government` emits → `pf-news` | Owner requirement: city-hall changes are reported automatically. |
| Crime, court, business events → Newsroom | Store and house robberies, drug seizures, sentences, warrants, store sales, supply shortages, races | A lead for reporters, never published automatically | emitters → `pf-news` leads | Reporters have stories to chase, so the news job stays meaningful. |
| Businesses → News | A business boss buys an ad | The ad price moves from the business account to the news company account (`society:reporter`) | `pf-news` | Businesses advertise; the news company earns money. |
| Businesses → City Hall | The City Hall Requests app | `gov.request.slot`, `gov.request.inspection`, `gov.request.license` and `gov.request.delivery_zone` requests to government staff, approved on site | `pf-government` / `pf-services` | Businesses ask the government for equipment positions, inspections, licenses and delivery bays. Staff approve them where they stand. |

## Links built in batch 11

| From → To | Trigger | What moves | Code points (from / to) | Why it makes sense |
|---|---|---|---|---|
| Bank robbery → Bank branch | The vault opens (`Config.OnRobberyStart`), and the robbery timeout ends | The branch closes for 20 minutes, or until the robbery resource reopens it. Counter, ATM, cash and card actions within 30 m are refused (server position). City events `bank.branch.closed` / `bank.branch.reopened`. | `pfm-bankrobbery/sv_config.lua` / `pfm-banking/server_branches.lua` | A robbed branch can't serve customers. Paleto and Pacific now close too. |
| Boss app → Bank | A boss deposits to or withdraws from the society account | Money on the ledger (`SocietyTransfer`); cash only at the boss desk | `pfm-management/server/sv_app.lua` / `pfm-banking/server.lua` | One place for society money; nothing is created |
| Garages app → Tow → Garages | A citizen asks for their car to be towed to one of their garages | A `tow.recovery` request with the garage as destination. The call-out fee is held from the citizen; the car is parked in that garage when the driver delivers it there. | `pfm-garages/server/apps.lua` / `pf-jobs/server/apps/tow_requests.lua` | Stranded cars get home through a real tow driver |
| Garages app → City treasury | A citizen pays an impound release fee ahead | Cash or bank to the depot, then to the treasury. The car is released at the depot without paying again. | `pfm-garages/server/main.lua` (`PayDepot`) / pf-government `DepositToTreasury` | One payment path for the app and the depot |
| Real estate agent → Buyer → Government | An agent offers a house to a customer beside them, who accepts | The buyer's bank pays price, broker fee and transfer tax. The tax goes to the treasury, 10% to `society:realestate`, 3% to the agent. The house is registered (`RegisterProperty`). | `pfm-houses/server/apps.lua` / pf-government | The realestate job sells houses and the city records owners |
| Car dealer → Buyer → Government | A dealer offers a car to a customer beside them, who accepts | Price (or down payment) plus purchase tax from the buyer. The price goes to the dealership, the commission to the salesperson, the tax to the treasury, and a registration bill from the city. One car is taken from stock. | `pfm-vehicleshop/server.lua` / pf-government `CollectTaxAmount`, `ChargeVehicleRegistration` | The cardealer job sells, the city taxes and registers |
| Car dealer → Manufacturer | A dealership manager orders stock | The dealership's society account pays the wholesale price; stock rises | `pfm-vehicleshop/server_apps.lua` | Sales cost the dealership something real |
| Used car lot → Seller's mail | A car on the lot is bought | A mail to the seller on any device | `pfm-vehiclesales/server/main.lua` / pf-citizen `SendMail` | The seller learns of the sale even with no phone resource |
| Vineyard → Restaurants | A restaurant orders wine or grape juice; a vineyard worker fills it as a player supplier | Bottles from the worker's stock to the restaurant's storage; payment through escrow to the supplier | `pf-restaurants` `Config.Supplies.PricePerItem`, `SupplyUnitPrice` / pf-stores suppliers; the Vineyard app's Selling tab | Vineyard workers get a real customer, restaurants buy wine at a real price |
| Restaurant stock → Menu → Customers | A cook fills drinks at the drink station; a customer drinks them | 1 wine → 4 glasses, 1 grape juice → 2 glasses; glasses are sold, and drinking one gives thirst (alcohol for wine) | `pf-restaurants/config/recipes.lua`, `server/integration.lua` / pfm-smallresources consumables | The supplied wine becomes something the restaurant sells and people drink |
| Recycling and scrapyard → Mechanic shops | A mechanic shop orders materials; a recycler or scrapper fills it as a player supplier | Scrap materials into the shop's stash, one unit per unit paid | `pf-mechanicjob/config.lua` `SuppliesCatalog.materials`, `business_data_provider.lua` / pf-stores suppliers | Scrap gets a market beyond the NPC buyer, and shops get repair materials |
| Armoured truck robbery → Gruppe 6 | `crime.robbery.truck` on the city timeline | Gruppe 6 pickups within 600 m are held for 10 minutes; crews on a contract or searching are warned (notification and app push) | `pfm-truckrobbery` (emit) / `pf-jobs/server/apps/gruppe6.lua` (`OnTruckRobbery`, `HoldAt`) | Cash crews don't walk into a crime scene, and police get time to secure it |
| Dispatch requests → Tow app | Police impounds, mechanic breakdowns, citizen calls (`tow.impound`, `tow.recovery`) | Listed with destinations in the Tow app; accept, complete or hand back through pf-services; completion gives tow XP. NPC tow contracts are offered only while no request is open. | `pf-jobs/server/apps/tow.lua`, `tow_requests.lua` / `pf-services` | Real player work comes first; NPC work only fills idle time |
| Job Board → Restaurant staff | A restaurant owner hires an applicant | The applicant joins the restaurant's staff with the chosen role (`AddStaff`) | `pf-computer/server/jobboard.lua` / `pf-restaurants/server/business.lua` | Restaurants could only "accept" applicants before |
| Business Manager → Boss rules | Promote, demote or fire in a job business | The job grade, through pfm-management's single set of staff rules | `pf-computer/server/main.lua` / `pfm-management/server/sv_boss.lua` | One set of rules for the boss menu, the gang menu, the Boss app and the Business Manager |
| Supply deliveries → Business apps | An order is unpacked or a pickup run ends | Order Supplies and the stock view refresh by themselves | `pf-computer/server/main.lua` / pf-devices pushes | Bosses see deliveries arrive without reopening the app |

## Links that already existed (earlier batches)

| From → To | What moves | Where |
|---|---|---|
| Stores, restaurants, job businesses → Trucking | Supply orders delivered by player truckers first, AI after a timeout, then paid once | `pf-stores` `PFOrders`, `pf-trucking` |
| Farming → Stores and restaurants | Produce sold through player suppliers; stale food refused | `pf-farming`, `pf-stores` suppliers |
| Mechanic → Trucking | Parts supply orders into the shop stash | `pf-mechanicjob`, `PFOrders` (`jobbiz`) |
| Businesses → Government | Sales tax, business revenue tax, utility bills, inspections, closure without power | `pf-government` registry |
| Government budgets → Restaurants and districts | Power cuts switch off district lights and restaurant cold storage | `pf-government` infrastructure, `pf-restaurants` |
| Government → Police MDT | Citizen licenses, fines and business records in the MDT | `pf-policemdt-DEV` |
| EMS → Bank | Hospital bills on the ledger | `pf-ambulancejob` |

## Candidates (not built yet)

| From → To | Why not yet |
|---|---|
| Script alerts (drug sales, "suspicious activity") → Dispatch | These would need de-duplication against the robbery events, or every robbery would create two requests. |
| Dealership stock → Trucking | Stock orders are paid and arrive at once; a car-carrier delivery job could bring them (pf-stores orders carry items, not vehicles). |
| Property tax → Government | pf-government has no recurring property tax yet (`property_tax_frequency` is unused); only the transfer tax is charged at a sale. |
