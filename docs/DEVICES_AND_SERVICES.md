# Devices, apps and services: how the systems fit together

This is the structure behind "systems in systems": one script controls many, every app works on
the tablet and the computer, and jobs rely on other jobs.

## The layers

```
pfm-core (framework: players, jobs, money)      pfm-banking (one ledger for all money)
        │                                                │
pf-devices  ── app registry, access rules, RPC bridge, push channel, App Store, websites, launchers
   │    └─ shells: pf-tablet, pf-computer (they only draw windows; apps come from pf-devices)
   │
pf-services ── city events timeline + service requests between jobs (Dispatch / Services apps)
   │
apps and systems that register with them:
   pf-jobs (taxi, bus, garbage, Gruppe6, tow)          pf-mechanicjob (work orders, register, management)
   pf-news (newsroom, News app + news.ls)              pf-government (fines, inspections, requests, budget...)
   pf-citizen (mail, bills, documents, calendar)       pf-services (Dispatch, Services, Directory)
   police and EMS MDTs (their own page in a device window) pf-computer (Business Manager, Order Supplies, Job Board)
   pf-jobs (tow, bus, recycling, vineyard too)          pfm-banking (Bank), pfm-crypto, pfm-management (Boss)
   pfm-garages, pfm-houses (Real Estate, Agency)        pfm-vehicleshop (Car Dealer, Dealership), pfm-vehiclesales
   pfm-pawnshop, pfm-crafting                           pf-stores (Supplier)
```

## pf-devices: one app, every device
- **Registration:** a resource registers an app once, giving its name, icon, which devices it appears on, and who may use it.
  - Access can depend on job and grade, on-duty status, a government permission, admin rights, or a custom check.
  - The server decides the list each player gets. The client never decides it.
- **One shared screen:** the app's screen is a single JavaScript module. The tablet and the computer both run that same module, so there are no per-device copies to keep in sync.
- **Server actions:** the module talks to its server code through `ctx.rpc`.
  - The server knows the real player.
  - It checks access, call rate and payload size on every call.
- **Live updates:** the server can push updates to an open app.
- **App Store:** some apps must be installed first, for example News and the side-job apps. Paid apps are charged once on the ledger.
- **Websites:** a website registered once looks the same in the tablet browser and the computer browser. news.ls is the first one.
- **MDTs inside the devices:** the police and EMS MDTs are apps on both devices. The window shows the MDT's own page, so the code and the screens are 1:1 the same as the full-screen MDT. While the app is open:
  - the MDT's messages go to the window;
  - the device keeps focus;
  - closing the MDT closes only the window.
- **Launchers:** an app can still open another full-screen screen instead of a window. pf-government's own management UI opens from any computer this way.
- **Developer guide:** `[pfscripts]/pf-devices/README.md`.

## pf-services: jobs relying on each other
- **City events:** one timeline that every system writes to.
  - The news listens: city-hall decisions become articles automatically; crime and court events become reporter leads.
  - The police listen too: alarms become dispatch requests.
- **Service requests:** one job, a citizen or the city asks another job to do something.
  - The job's workers see it in **Dispatch**. Police and EMS see it on the dispatch board of their MDT app instead: their dispatch is the MDT.
  - Citizens call for help from **Services**.
  - Paid work is held from the payer up front, paid to the worker only when the work is proven, and refunded otherwise.
- **Directory:** shows which businesses are open and which services are on duty.
- **The list of every link:** `JOB_LINKS.md`.

## Rules every resource follows (batch 11)
- **Deleted characters:** pfm-core fires the server-only event `pfm-core:server:characterDeleted` (citizenid, deleted) after a character is deleted. `deleted.apartments` lists the apartment names it held. Each resource clears or anonymises its own rows in its handler:
  - private rows go;
  - rows other people still need stay without the link (published articles keep their byline, shared documents stay with the people they were shared with, ledger entries are never touched);
  - open requests are cancelled and refunded, and jobs the character had accepted go back to the queue.
- **Other resources' tables are read through exports, never directly:**
  - pf-government registry: `GetBusiness(id)`, `GetBusinessesOwnedBy(ownerIds, businessIds)`, `ListBusinesses({ limit })`;
  - pf-stores: `GetStoreOwner(storeId)`;
  - pfm-management staff rules: `IsBoss`, `ListEmployees`, `SetEmployeeGrade`, `FireEmployee`, `HireEmployee`;
  - pf-restaurants staff: `AddStaff`, `RemoveStaff`.
- **Websites get live updates by host:** `exports['pf-devices']:BroadcastSite('news.ls', event, payload)` reaches every open copy in both browsers.
- **State bags are written by the server only** (ready for `sv_stateBagStrictMode`):
  - a client asks with a validated event and the server sets the value;
  - values only that client reads are set locally with `:set(key, value, false)`;
  - `inv_busy` belongs to the inventory server; other resources take an action lock with `exports['pfm-inventory']:SetBusyLock(src, reason, busy, ttl)` (server) or `qb-inventory:server:setActionBusy(reason, busy)` (client);
  - `tests/specs/statebag_strict_scan_spec.lua` fails on any new client write.
- **Consumables:** food and drink from any resource is registered with pfm-smallresources (`AddFood`, `AddDrink`, `AddAlcohol`), which removes the item on the server before granting hunger or thirst. Freshness, a dish's quality and its poison risk are taken into account.
- **Supplier stock and case sizes:** a player supplier's stock unit is `Config.SupplyChain.CaseSize[item]` items. Orders whose lines carry their own `caseSize` are converted, so the supplier hands over exactly what the buyer unpacks.

## Where each owner requirement lives
| Requirement | Where |
|---|---|
| Apps on both devices share code | pf-devices runtime and registry; pf-tablet and pf-computer are shells |
| pf-jobs holds the jobs and feeds both devices | pf-jobs registers its apps and handlers with pf-devices |
| Computer connected to every system | Platform apps appear on the computer desktop; the computer browser shows platform websites; fake data removed (see the batch 10 report) |
| News run by the news job, automatic for city-hall changes, not for everything | pf-news: presets for `auto` events, leads for `lead` events, the newsroom for reporters |
| News public to whoever installed the app, and a website in both | The News app (installable) and news.ls (same UI module) |
| Government on the tablet: fines, inspections, business requests, budgets, announcements, business setup (equipment positions, delivery zones) | pf-government platform apps; requests through pf-services |
| Jobs rely on other jobs, with a full list | pf-services, plus the emitters in each resource; `JOB_LINKS.md` |
