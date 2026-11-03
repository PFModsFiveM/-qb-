# PF Ultimate: integration matrix

How the public-safety domains connect to the rest of the city. "Existing" names were checked in the code on
2026-11-03; "(new)" names are defined in `PF_ARCHITECTURE.md` and built by the batch shown.

Domains: **MED** medical engine, **EMS** EMS operations, **HOSP** hospitals, **POL** police field/traffic,
**EVI** evidence, **MDT** police/EMS records, **CUS** custody/booking, **PRI** prison/corrections, **CS** community
service, **CRT** courts/probation/parole, **DEP** department management.

## 1. Overview grid

`x` = a real link in this plan; `-` = no link needed.

| Resource | MED | EMS | HOSP | POL | EVI | MDT | CUS | PRI | CS | CRT | DEP |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pf-government (budgets, taxes, laws, bills, infrastructure, permissions) | - | x | x | x | - | x | - | x | x | x | x |
| pfm-banking ledger / PFPayout | - | - | x | x | - | x | x | x | x | x | x |
| pfm-inventory | x | x | x | x | x | - | x | x | - | - | x |
| pfm-core (jobs, duty, metadata, players) | x | x | x | x | - | x | x | x | x | x | x |
| pfm-management (hire, fire, grades) | - | - | - | - | - | x | - | - | - | - | x |
| pf-jobs / pf-services (requests, city events, dispatch) | x | x | x | x | - | x | - | x | x | x | x |
| pf-restaurants | x | - | - | - | - | - | - | x | - | - | - |
| pf-stores / pf-trucking (supply orders, deliveries) | - | x | x | - | - | - | - | x | - | - | x |
| pf-mechanicjob / pf-jobgarages (fleet) | - | x | - | x | - | - | - | x | - | - | x |
| pfm-garages / pfm-vehiclekeys / pf-jobs tow (vehicles, impound) | - | - | - | x | x | x | - | - | - | - | - |
| pfm-houses (housing) | - | - | - | x | - | - | - | - | - | x | - |
| pf-government business registry | - | - | - | - | - | x | - | - | - | x | - |
| pfm-phone / pf-citizen (invoices, mail, calendar, documents) | - | x | x | x | - | - | x | x | x | x | - |
| pf-devices / pf-tablet / pf-computer (apps) | - | x | x | - | - | x | x | x | x | x | x |
| pfm-doorlock | - | - | - | - | - | - | x | x | - | - | - |
| pfm-smallresources / pfm-drugs (consumption) | x | - | - | x | - | - | - | - | - | - | - |
| pfm-weapons (serials) | x | - | - | - | x | x | - | - | - | - | - |
| pfm-adminmenu | x | - | - | - | - | - | x | x | - | - | - |
| pma-voice | - | x | - | x | - | - | - | x | - | - | - |
| pf-news | - | - | - | x | - | - | - | x | - | x | - |
| screenshot-basic | - | - | - | - | x | x | x | - | - | - | - |

## 2. Link details

### 2.1 pf-government
| Domain | Direction | Existing interface | New interface | Batch |
|---|---|---|---|---|
| DEP / budgets | GOV -> departments | `GetDepartmentSocietyBalance`, `SpendFromDepartmentSociety`, `AddFundsToDepartmentSociety`, `GetAllBudgetDetails`, `Config.Budgets.LinkedSocietyAccounts` (police, ems->ambulance) | `key` argument on the two society moves; `corrections` and `doj` departments | 15E |
| DEP / qualifications, shifts, audit | departments -> GOV | `HasPermission` (gov staff only) | `GetDepartmentOf`, `HasQualification`, `GrantQualification`, `GetShift`, `LogDepartmentAudit` | 15I |
| DEP / training, assets, procurement, payroll reports, admin app | | | `RecordTraining`, `IssueAsset`, `ReturnAsset`, `ListAssets`, `CreateProcurement`; app `department` | 20E, 21G |
| CS / municipal work | JU -> GOV | infrastructure simulation (`server/infrastructure.lua`), read-only exports | `ListWorkOrders`, `ClaimWorkOrder`, `ReportWorkUnit`, `ReleaseWorkClaim`; event `workOrderCompleted` | 15E, 19C |
| PRI / prison maintenance | PR -> GOV | | work orders with `district` = the prison district, `csEligible = false`, claimant kind `job` (inmates) | 19E |
| MDT / laws | GOV -> PMDT | `SyncLawsWithMDT` -> PMDT `SyncLaws` (read-only SOP entries); `GetLawsForMDT` | none (penal code stays PMDT-owned; aligning laws to charges is an open decision) | - |
| CRT / expungement | GOV -> JU | GOV hard-deletes `pf_mdt_sentences`/`pf_mdt_incidents` (`server/callbacks.lua` ~2043-2105, unaudited) | JU `Expunge` (audited, soft delete) | 19A |
| CRT / city fines | GOV <-> JU | `IssueFineAs`, `IssueFineImmediate`, `PayBillFromPlayer`, `pf_gov_bills` | JU `PayOrder` at the City Hall desk (`pf-government` on the caller list) | 15B |
| HOSP / medical debt | AJ -> GOV | `CreateBill` export (6 args) | `CreateBill` passes `issuedBy, issuedByName, recurring` (used only if the owner prefers GOV bills over phone invoices for medical debt) | 15E |
| licences | MDT/CRT -> GOV | `HasLicense`; `SuspendLicense`/`RevokeLicense` exist but are **not exported** | export `SetLicenseStatus(cid, type, status, opts)` so courts can suspend licences (open item, `PF_REMAINING_WORK.md`) | 19A (request) |
| permissions on devices | | pf-devices `access.gov` -> `HasPermission` | | - |

### 2.2 pfm-banking ledger
| Domain | Use | Interface | Key |
|---|---|---|---|
| HOSP | bills | `PFPayout.Charge(cid, {'bank'}, total, { key, to = 'society:ambulance', kind = 'medical' })`; unclear -> `exports['pfm-banking']:GetTransaction(key)` | `pf-ambulancejob:bill:<billId>:<n>` |
| CRT | fines, citations | `PFPayout.Charge` -> `society:<Config.Fines.Account>` | `pf-justice:order:<orderId>:pay:<n>` |
| CUS | bail | `exports['pfm-banking']:Transfer({ from = 'player:<cid>:bank', to = 'society:<bail account>', key })` | `pf-justice:bail:<bailId>:<n>`, refund `...:refund` |
| CRT | restitution | `Transfer` to `player:<victim>:bank` | `pf-justice:restitution:<orderId>:<n>` |
| PRI | inmate trust | `Transfer` player <-> `system:pfm-prison-trust` (pf-services escrow pattern) | `pfm-prison:trust:<cid>:<txId>` |
| PRI | wages | `PFPayout.Pay` from `society:corrections` into the trust | same |
| CS / work orders | paid (non-CS) workers | `PFPayout.Pay(cid, 'bank', amount, { key, from = 'society:<dept>' })` | `pf-government:wo:<id>:pay:<cid>` |
| DEP | procurement | pf-stores supply orders charge the buyer account (`society:<linked>`) with their own keys | `supply:<id>:charge` (existing) |
| existing kept | `/fine` (`pfm_police_fines`), police bill menu, MDT sentence fines in `payment_pending` | unchanged until drained | existing keys |

### 2.3 pfm-inventory
| Domain | Use | Interface |
|---|---|---|
| MED/EMS | consume medical items before effects; medbag and rig stashes | `RemoveItem`, `HasItem`, `CreateInventory`, `OpenInventory` (existing) |
| EVI | evidence bags; chain of custody recorded from item moves | `AddItem` with `info.evidenceId`; `AddListener('ItemMoved', fn)` (existing, already used by PJ for drug seizures) |
| CUS | property seizure into a locker stash with receipt; return without clearing | `GetInventory`, `ClearInventory`, `AddItem(stashId, ...)`, `RemoveItem` (existing; rollback pattern from pfm-prison `StoreItems`) |
| POL | frisk (weapons only), search with reach | `GetItemsByName`, `OpenInventoryById(src, target, { reach })` (existing) |
| PRI | contraband searches, commissary, uniforms | existing exports |
| DEP | armory checkout | existing `AddItem`/`RemoveItem` + GOV asset register (new) |
| busy locks | progress actions (treat, frisk, book) | `exports['pfm-inventory']:SetBusyLock(src, reason, busy, ttl)` (existing) |

### 2.4 pfm-core (jobs, duty, metadata)
| Use | Interface |
|---|---|
| Jobs | `shared/jobs.lua`: police (`leo`), ambulance (`ems`), judge, lawyer (existing stubs); new `corrections`, `doj` + grades (15H) |
| Duty points | `exports['pfm-core']:RegisterDutyPoints({ job, points, radius })`, `IsAtDutyPoint` (existing; PJ and AJ use them) |
| Duty events | `QBCore:Server:SetDuty`, `QBCore:Server:OnJobUpdate`, `QBCore:Server:PlayerLoaded`, `QBCore:Server:OnPlayerUnload` (existing) -> GOV shifts, JU reconnect, AJ load |
| Counts | `QBCore.Functions.GetDutyCount(job)`, `GetPlayersByJob(job, onDuty)` (existing) -> AI care threshold, CO on duty |
| Metadata mirrors | `isdead`, `inlaststand` (AJ), `ishandcuffed` (PJ), `injail`, `criminalrecord` (JU) |
| Character delete | `pfm-core:server:characterDeleted(cid, deleted)` (existing) -> every new resource cleans its rows |
| Job vehicles | `RegisterJobVehicles` (existing; rigs, police, corrections vans) |
| Migrations | `RunMigrations`, `MigrationColumnExists`, `MigrationIndexExists` (existing) |

### 2.5 pf-services and pf-jobs
| Domain | Use | Interface |
|---|---|---|
| EMS | person-down and medic calls | existing `PFEmsRequests` in AJ on `CreateRequest(kind='ems.patient')`, `CloseByRef`; pf-services posts to EMDT `CreateDispatchCall` (existing) |
| POL | assists, alarms, 911 | `police.assist` requests and city events with `police = true` (existing) -> PMDT dispatch |
| POL | impound tow | `tow.impound` + PJ `FinalizeImpound` (existing, batch 10) |
| PRI | escape | city event `crime.prison.escape` (existing) |
| CRT | sentences, warrants | city events `police.sentenced`, `police.warrant` (existing, news leads) |
| CS | graffiti/litter sources | listen to `pf-services:cityEvent` (existing) for configured kinds -> GOV `CreateWorkOrder` |
| DEP / fleet | rig/police/corrections vehicle service | new request kind `mechanic.fleet` registered with `RegisterRequestKind` by the fleet owner; mechanic proves completion through `RegisterRequestHandler` (`canComplete` = pf-jobgarages service state + server vehicle health) (20C) |
| new event kinds | registered at runtime with `RegisterEventKind` (no catalog edit): `justice.verdict` (news lead), `prison.lockdown` (news auto), `ems.mci` (news lead) | 19A, 19F, 20D |

### 2.6 pf-restaurants (prison meals)
| Use | Interface | Batch |
|---|---|---|
| Inmate meals are cooked by the prison kitchen job from facility stock (no restaurant needed at low population) | PR `server/work.lua` + facility stash | 19E |
| Optional catering contract: a player restaurant supplies meals when the kitchen has no workers | pf-services request kind `restaurant.catering` (new) paid by `society:corrections`; restaurants prove delivery at the prison dock | not scheduled (open, `PF_REMAINING_WORK.md`) |
| Food poisoning from a bad dish | `pfm-smallresources:server:consumed` with `info.poisoned` (new, 15H) -> AJ illness | 15A/15H |

### 2.7 pf-stores and pf-trucking (supplies)
| Use | Interface | Batch |
|---|---|---|
| Hospital, prison and police department supplies | `exports['pf-stores']:RegisterBuyerKind('facility', adapter)` (existing API) registered by GOV procurement; adapter `canManage` = department permission, `account` = linked society, `price` = facility catalog, `route` = facility dock, `unpack` = facility stash | 20C |
| Delivery | pf-stores posts `SUP-<id>` contracts to `exports['pf-trucking']:CreateExternalJob` (existing) | 20C |
| Rig restock | hospital supply room stash -> rig stash `pf_rig_<plate>` (inventory moves, logged in `pf_hosp_supply_usage`) | 20C |

### 2.8 Mechanics and fleet
| Use | Interface | Batch |
|---|---|---|
| Fleet list and service state | pf-jobgarages `GetFleetVehicle`, `ListFleet`, `SetServiceState` (new) on `job_garage_vehicles` | 15H |
| Maintenance work | pf-services `mechanic.fleet` request; existing mechanic register bills the department society | 20C |
| Vehicle health proof | server `GetVehicleBodyHealth`, `GetVehicleEngineHealth` | 20C |

### 2.9 Vehicles and impound
| Use | Interface | Batch |
|---|---|---|
| Impound/depot | PJ `police:server:Impound`, `FinalizeImpound`, `GetImpoundLots` (existing); new `pf_police_impounds` record and `GetImpound` | 18B |
| Seizure release | PJ `police:server:ReleaseImpound` (existing) | 18B |
| Owner lookup | `player_vehicles` (as PJ already reads) | 18B |
| Plate flags / BOLO | PMDT `GetPlateFlags` + `plateFlagsChanged` (new) replace PJ in-memory `Plates` | 18B/18F |
| Keys | pfm-vehiclekeys `GiveKeys`, `HasKeys`, `RemoveKeys` (existing) for fleet and seized vehicles | 18B |
| Tow destinations | pf-jobs `GetTowDestinations` (existing) | - |

### 2.10 Housing
| Use | Interface | Batch |
|---|---|---|
| House arrest / curfew zones for probation | `exports['pfm-houses']:GetOwnedHouses()` (existing) | 19B |
| Search warrants for a house | JU warrant review with `address`; entry through pfm-doorlock `GrantDoorAccess` (existing) for door-locked interiors | 19A |

### 2.11 Business registry
| Use | Interface | Batch |
|---|---|---|
| Court-ordered closure or a business fine | GOV registry exports (`GetBusiness`, `IssueFineAs` for business targets) | 19A (read), closure is an open decision |
| MDT business lookup | existing PMDT `fetchGovernmentRecord` (reads `pf_gov_licenses`, `pf_gov_bills`, `GetBusinessesOwnedBy`) | - |

### 2.12 Phone and pf-citizen
| Use | Interface | Batch |
|---|---|---|
| Unpaid bills/fines as invoices (cannot be declined) | `exports['pfm-phone']:CreateInvoice({ ..., candecline = 0, ref })` (`ref` new, 15H); settlement event `pfm-phone:server:invoiceSettled` (existing) | 15B, 17E |
| Court dates, hearing notices, follow-up appointments | `exports['pf-citizen']:AddCalendarEvent(scope, owner, data, byName)`, `SendMail(cid, {...})` (existing) | 17E, 19A, 19B |
| Discharge papers, citations, property receipts as documents | `exports['pf-citizen']:CreateDocument(cid, { title, body })` (existing) | 15C, 17E, 18B |
| Lawyers list | `qb-phone:server:GetCurrentLawyers` (existing, pfm-phone) | 19A |
| 911 | existing PJ `/911p`, AJ `/911e`, pf-services Services app | - |

### 2.13 Devices (tablet and computer)
| App | Owner resource | Interface |
|---|---|---|
| Police MDT (existing, iframe) | PMDT | `RegisterApp` in `server/devices.lua` (existing) |
| EMS MDT / EMS tablet (existing, iframe) | EMDT | existing |
| Hospital workstation (new module app) | EMDT | `RegisterApp({ id = 'hospital', kind = 'module', access = { jobs = { ambulance = 0 }, onduty = true } })` + `RegisterAppHandlers` (21D) |
| Corrections MDT (new) | PR | `RegisterApp({ id = 'corrections', access = { jobs = { corrections = 0 }, onduty = true } })` (21E) |
| Court app, Community Service app, records portal (new) | JU | `access = { jobs = { judge = 0, doj = 0, lawyer = 0 } }`; CS app `access = { check = { resource = 'pf-justice', export = 'CanUseCsApp' } }`; portal `anyone` (21F) |
| Department admin (new) | GOV | `access = { handler = true }` with an `__access` handler checking department manager grade (21G) |
| Pushes | all | `Push`, `PushToJob`, `PushToCitizen` (existing) |

### 2.14 pfm-doorlock
| Use | Interface | Batch |
|---|---|---|
| Prison gates and cell blocks, lockdown | `SetDoorState`, `GetDoorState` (new, allowlisted) | 15H, 19F |
| Gate hacks (existing) | `GrantDoorAccess` + server `qb-doorlock:server:updateState` (existing) | kept |
| Corrections access | `authorizedJobs` adds `corrections = 0` on Bolingbroke doors | 15H |
| Holding cells at stations | doors per cell in config; JU locks/unlocks through `SetDoorState` when assigning/releasing | 15H config, 18A use |

### 2.15 Dispatch
| Use | Interface |
|---|---|
| Police and EMS boards | PMDT/EMDT `CreateDispatchCall(callData)` (existing; one call per `requestId`) |
| Requests from citizens and systems | pf-services `police.assist`, `ems.patient` (existing) |
| Officer down / panic | PJ `police:server:OfficerDown`, `Panic` (existing) -> also `CreateDispatchCall` on PMDT (18C) |
| EMS MCI | EMDT unit board + `ems.mci` event (20D) |
| Corrections alarms | PR -> PMDT `CreateDispatchCall` for escapes/riots (existing `crime.prison.escape` path) |

### 2.16 Other resources
| Resource | Use | Interface | Batch |
|---|---|---|---|
| pfm-smallresources | alcohol and food -> toxins/illness | `pfm-smallresources:server:consumed` (new) | 15H/15A |
| pfm-drugs | drug use -> toxins | `exports['pf-ambulancejob']:AddToxin` (new) called from pfm-drugs **(change in pfm-drugs not scheduled; open item)** | - |
| pfm-weapons / pfm-inventory | weapon serial `info.serie` (existing) -> casings, projectiles, ballistics | server reads the attacker's equipped weapon item | 16B, 18D |
| pfm-adminmenu | revive, kill, jail | AJ `Revive`/`Kill` (16A), PR `JailPlayer` forwarder (16C) | 16 |
| pma-voice | radio channel in telemetry; restricted channels | server state bag `radioChannel` (read), `exports['pma-voice']:addChannelCheck(channel, fn)` (existing) | 18C |
| pf-news | court and prison news | city events through pf-services (existing pipeline) | 19 |
| screenshot-basic | mugshots, scene photos | client upload, stored with `client_supplied = 1` | 15C, 18D |
| pfm-minigames | gate hacks and lockpicks stay server-verified; lab analysis is not a minigame | `IssueChallenge`, `Verify` (existing) | 19F |
| pfm-radialmenu | EMS/police radial entries call the new events; stretcher moves to AJ | config entries | 17D |
