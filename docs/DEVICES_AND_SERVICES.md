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
   pf-jobs (taxi, bus, garbage, Gruppe6, tow checks)   pf-mechanicjob (work orders, register, management)
   pf-news (newsroom, News app + news.ls)              pf-government (fines, inspections, requests, budget...)
   pf-citizen (mail, bills, documents, calendar)       pf-services (Dispatch, Services, Directory)
   MDT launchers (police, EMS)                         pf-computer's own apps (browser, business manager...)
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
- **Launchers:** an app can open an existing full-screen system instead of a window. The police and EMS MDTs work this way.
- **Developer guide:** `[pfscripts]/pf-devices/README.md`.

## pf-services: jobs relying on each other
- **City events:** one timeline that every system writes to.
  - The news listens: city-hall decisions become articles automatically; crime and court events become reporter leads.
  - The police listen too: alarms become dispatch requests.
- **Service requests:** one job, a citizen or the city asks another job to do something.
  - The job's workers see it in **Dispatch**.
  - Citizens call for help from **Services**.
  - Paid work is held from the payer up front, paid to the worker only when the work is proven, and refunded otherwise.
- **Directory:** shows which businesses are open and which services are on duty.
- **The list of every link:** `JOB_LINKS.md`.

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
