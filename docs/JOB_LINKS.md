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
| Any event marked `police` → Police | Robberies, prison escapes (emitted by the robbery and prison resources) | A `police.assist` dispatch request at the event position, one per incident | `pf-services/server/main.lua` (`OnEvent`) | Alarms become dispatch calls officers can accept and navigate to. |
| City Hall → News | Every government decision (taxes, laws, budgets, power and water cuts, utility cut-offs, business registration, closure, transfer, failed inspections, loan defaults, announcements, appointments) | An automatic article from a preset, with no mayor action | `pf-government` emits → `pf-news` | Owner requirement: city-hall changes are reported automatically. |
| Crime, court, business events → Newsroom | Store and house robberies, drug seizures, sentences, warrants, store sales, supply shortages, races | A lead for reporters, never published automatically | emitters → `pf-news` leads | Reporters have stories to chase, so the news job stays meaningful. |
| Businesses → News | A business boss buys an ad | The ad price moves from the business account to the news company account (`society:reporter`) | `pf-news` | Businesses advertise; the news company earns money. |
| Businesses → City Hall | The City Hall Requests app | `gov.request.slot`, `gov.request.inspection`, `gov.request.license` and `gov.request.delivery_zone` requests to government staff, approved on site | `pf-government` / `pf-services` | Businesses ask the government for equipment positions, inspections, licenses and delivery bays. Staff approve them where they stand. |

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

To be filled from the remaining agents' reports.
