# Review of branch `main-9hq3gi` (2026-10-31)

**Scope:** both repositories at the branch tips: `-qb-` 3b01ccd and `-pfscripts-` 496888a.

**Method:**
- Every area of the diff was read by one of 13 reviewers. Three more checked across the whole tree: references to deleted resources, readiness for strict state bags, and the branch report's claims.
- Two skeptics then tried to refute each medium-or-worse finding.
- A final pass looked for anything left uncovered.

**Totals:** 61 findings. 23 confirmed by both skeptics, 9 confirmed by one, 3 refuted, 29 low-severity ones not sent to skeptics.

## Status (2026-11-01, after batch 13)

Each finding below now has a **Status** line. Batch 13 areas are named as in `IMPLEMENTATION_REPORT.md`, batch 13.
- **Fixed in batch 12:** merge blockers 1–5 and 7–12, plus Gruppe 6 XP, the Gruppe 6 "Open Storage" option, the escrow sweep race, raw request rows and the tow contract double spawn.
- **Fixed in batch 13:** strict state bags on staging (6), the rest of the smaller issues, and all five older issues.
- **Open:**
  - the phone invoice crash path (13);
  - strict state bags on live: the originals and `[custom]` must be deleted there first (6).
- **Gaps the batch 13 checkers found** are handled in batch 13b (see `IMPLEMENTATION_REPORT.md`, batch 13).

## Status (2026-10-31, after batch 12)

**Fixed:**
- All 13 merge blockers below were fixed on the branch in batch 12 (see `IMPLEMENTATION_REPORT.md`, batch 12).
- Also fixed: the strict-state-bag claim (staging no longer enables it).
- Fixed from the "smaller issues" list:
  - Gruppe 6 XP once per contract;
  - the Gruppe 6 "Open Storage" option;
  - the escrow sweep race;
  - raw request rows to clients;
  - tow contract double spawn.

**Still open:**
- the other smaller issues, including mail document re-sharing and signed-document deletion;
- the older issues.

## Test claims: verified

All re-run at the branch tips.
- **Mocked suite:** 1190 passed.
- **Real-database suite:** 349 passed.
- **Browser-side:** 8 spec files, 60 tests, all passed.
- **Other checks:** the parallel-ledger and fresh-install SQL checks pass.
- **Merge:** both branches fast-forward from `main`.

## Fix before merging (new on this branch)

**1. Gruppe 6 contracts can never be finished.**
- **Why the code runs now:** `pf-jobs/client/gruppe6.lua` failed to parse on `main`, so this code never ran before. The branch fixed the parse error.
- **The crash:** the deposit handlers (lines 706 and 736) read `VaultDoorStates`, which is declared as a local only at line 876. That resolves to a nil global, and the handlers crash.
- **The locked vault:** the vault "Use Security Panel" target (line 912) requires job `gruppe6`, which does not exist. So the vault never opens even with the crash fixed.
- **Status:** fixed in batch 12 (pf-jobs). The vault state is declared before use, and the security panel needs an active contract instead of a `gruppe6` job.

**2. Deleting a character creates money.**
- **A player can delete the character they are playing** (pfm-core `player.lua:584`; pfm-multicharacter's delete event has no "not loaded" check). The new cleanup writes off loans and card debt, then the next periodic save re-creates the character with its full balance.
- **Alt-character loans:** `pfm-banking/server_characters.lua:59-60` writes off active loans and card debt on deletion. A player can take loans on an alt, move the money to their main character, then delete the alt. This is repeatable. Unpaid debt should block deletion, or the bank should recover it.
- **Status:** fixed in batch 12 (pfm-core, pfm-multicharacter, pfm-banking). A loaded character can't be deleted, and a player delete is refused while the character owes the bank.

**3. Police impounds are lost.**
- **The impound becomes a tow to the owner's garage.** `pf-services/server/requests.lua:326` treats a request as a duplicate by plate alone, ignoring the request kind. If the owner has an open garage tow, the officer's impound returns that request, shows "Tow ordered", and the car goes to the owner's garage.
- **An impound nobody tows is dropped.** `pf-jobs/server/apps/tow_requests.lua:77` has no `onClosed` handler. If no tow driver completes it within an hour, the impound expires silently: no depot fee and no seizure.
- **Status:** fixed in batch 12 (pf-services, pf-jobs). De-duplication matches the request kind, and an impound that ends untowed is applied directly.

**4. pf-services payment is not "paid once the work is proven".**
- **Roadside repair:** `mechanic.roadside` has `verify = false` and no handler. A mechanic can accept and complete from across the map and take the citizen's $100 (`requests.lua:482`).
- **Cancel after acceptance:** the requester can cancel an accepted request and get the escrow back after the worker did the job (`requests.lua:512`).
- **The claim is partly wrong:** the branch claim and `docs/JOB_LINKS.md` overstate this.
- **Status:** fixed in batch 12 (pf-services). Roadside repair pays on the citizen's confirmation or an on-site check, there is no cancel after acceptance, and `JOB_LINKS.md` was corrected.

**5. Government announcements bypass the new permission.** `gov:createAnnouncement` (`pf-government/server/callbacks.lua:285`) and the net event `pf-government:server:createAnnouncement` (`integrations.lua:186`) check only "is a government employee".
- **What a low-grade employee can do:** take the author name from the client, skip length checks, auto-publish as a City Desk news article with no editor, and raise an "urgent" breaking alert.
- **Deletion:** `announcement:delete` lets any government employee delete any announcement.
- **Status:** fixed in batch 12 (pf-government). Every create and delete path needs the announcement permission (urgent ones need their own), and the author comes from the server.

**6. Strict state bags are not ready to turn on.**
- **Third-party writers:** `[standalone]/progressbar` (`inv_busy`) and `[voice]/pma-voice` still write replicated state from the client.
- **Inventory not blocked:** with strict mode on, the server no longer blocks the inventory during progress bars.
- **Staging fails its own test:** staging (`docs/staging/server.staging.cfg:26`) already enables strict mode, so FINAL_TEST_PLAN's "no state-bag errors" step will fail.
- **Live cfg duplicate:** the live cfg also starts `[custom]/pf-mechanicjob`, an old duplicate full of client writes.
- **Status:** fixed in batch 13 on staging (Strict state bags). Patched copies of progressbar and pma-voice start from [qb], progressbar holds pfm-inventory's lock, and staging runs strict mode again. Open on live: delete `[standalone]/progressbar`, `[voice]/pma-voice` and `[custom]` before turning it on (owner action on the live cfg).

**7. Websites with a Cards Grid or Quick Links module cannot be saved.** The new depth limit (`pf-computer/server/main.lua:1431`, `SITE_MAX_DEPTH = 6`) rejects the editor's own structure.
- **Status:** fixed in batch 12 (pf-computer). The depth limit fits every editor module.

**8. Character deletion leaves data behind** (the claim "cleans every system" is partly false):
- pf-stores ownership;
- pf-government staff, registry owner and property records;
- pf-mechanicjob `vehicle_diagnostics`;
- phone gallery and tweets;
- vehicle trunks and gloveboxes;
- pf-news payouts and ads.
- **Status:** fixed in batch 12 (each resource listed). New server-only `characterDeleted` listeners clear each of these.

**9. NOS.**
- **Free refill:** an emptied bottle refills when the car is lost before the next save (`pf-mechanicjob/server/nos.lua:162`).
- **Passenger wear reports:** any occupant can max out the car's wear parts, possibly on a different car with the same plate (`nos.lua:220`).
- **Status:** fixed in batch 12 (pf-mechanicjob): NOS is saved as soon as it changes, and only the driver reports wear. The garage-save race that batch 12 left was fixed in batch 13 (Mechanic).

**10. Tow rental.**
- **Double deposit:** two rent requests at once charge two $250 deposits, one of which can never be refunded (`pf-jobs/server/apps/tow.lua:267`).
- **Deposit kept after leaving the job:** the deposit cannot be returned once the player leaves the tow job (`tow.lua:304`).
- **Status:** fixed in batch 12 (pf-jobs): a per-character lock, and return or report-lost after leaving the job. Batch 13 (Jobs) adds a return-only Tow app for former drivers.

**11. News vehicles** (`pfm-newsjob/server/main.lua`).
- **Stuck lock:** the "return your vehicle first" lock never clears when the van is destroyed (line 76).
- **Trusted client event:** `vehicleStored` is trusted from the client, giving unlimited vans, each with a freshly stocked trunk of equipment (line 96).
- **Status:** fixed in batch 12 (pfm-newsjob). The lock frees when the van is gone or wrecked, and storing is decided by the server.

**12. App Store paid apps.** This is latent, because no app has a price yet.
- **Failed payment sticks:** one failed payment blocks that app forever, because the fixed ledger keys stay failed (`pf-devices/server/installs.lua:70`).
- **Double charge:** two installs at once charge both bank and cash (`installs.lua:63`).
- **Status:** fixed in batch 12 (pf-devices). A per-character lock, a new ledger key per attempt, and one charge per app.

**13. Phone invoice retry.** `pfm-phone/server/main.lua:458` treats every non-completed ledger key as failed. It can charge twice after a crash in the middle of a transfer, and an invoice becomes unpayable after 20 failed attempts.
- **Status:** open (Documents and phone). Batch 12 ended the 20-attempt dead end, and batch 13 gave each invoice its own ledger token. The batch 13 checker showed that a crash mid-transfer can still charge twice: a key the ledger recovers as `interrupted_unverified` is treated as failed. Handled in batch 13b.

## Smaller issues (new on this branch)

- **Mail re-sharing:** a read-only document link can be re-shared through mail attachments, which bypasses unshare; a re-shared holder can sign and lock the owner's document (`pf-citizen/server/mail.lua:477`).
  - **Status:** fixed in batch 13 (Documents and phone). Only the owner hands out links, anyone else sends a locked copy, and only people the owner or the server shared it with can sign.
- **Signed documents:** the owner of a signed document can delete or unshare it, removing the other signers' record (`documents.lua:139`).
  - **Status:** fixed in batch 13 (Documents and phone). Once someone else has signed, the owner's delete only hides it from the owner, and a signer can't be unshared.
- **EMS calls:** "Person down" calls stay on the EMS MDT after the patient respawns, and a client can add a new one every 60 seconds (`pf-ambulancejob/server/main.lua:47`).
  - **Status:** fixed in batch 13 (EMS and Dispatch). The MDT call closes with the patient's request, and a call opens only when the server reads the player down. Two edge cases the checker found (a logout during the request insert, a reconnect within the 60 s cooldown) are handled in batch 13b.
- **Job Board after a restart:** hiring events stop after `restart pf-services` (`pf-computer/server/jobboard.lua:158`).
  - **Status:** fixed in batch 13 (Computer and inventory). The hiring kind is registered again when pf-services starts.
- **Cruise control:** the HUD indicator is gone; its only handler was in the deleted pfm-hud (`pfm-smallresources/client/cruise.lua:45`).
  - **Status:** fixed in batch 13 (Fuel and cruise). pf-hud shows a cruise icon, and cruise always sends the off state.
- **Fuel sync:** the network owner of any empty car can set its fuel from any distance (`pfm-fuel/server/main.lua:61`).
  - **Status:** fixed in batch 13 (Fuel and cruise). Only the driver reports, only downward, capped per second. A new car's first level still comes from its driver: handled in batch 13b.
- **Mechanic tows:** any on-duty mechanic, not only the boss, can spend the shop's money on tows (`pf-mechanicjob/server/advanced_systems.lua:398`).
  - **Status:** fixed in batch 13 (Mechanic). Only the boss, for a car near them that the server reads as broken.
- **Gruppe 6 XP:** parallel deposit requests add XP once per request (`gruppe6.lua:1054`).
  - **Status:** fixed in batch 12 (pf-jobs). The deposit is locked per contract.
- **Bus spawn:** two take-out requests at once spawn two buses (`bus.lua:557`).
  - **Status:** fixed in batch 13 (Jobs). A per-player lock taken before the first wait (from the WIP, verified and tested).
- **Gruppe 6 storage:** the truck's "Open Storage" option fires an event nothing handles (`gruppe6.lua:537`).
  - **Status:** fixed in batch 12 (pf-jobs). It uses pfm-inventory's inventory command.
- **Supply pickup:** non-boss staff can start a supply pickup run that can never be collected (`pf-computer/server/main.lua:2926`).
  - **Status:** fixed in batch 13 (Computer and inventory). The boss check runs before the order is read or any truck spawns.
- **Supplier stock:** it ignores `Config.SupplyChain.CaseSize` for restaurant lines (`pf-stores/server_orders.lua:440`).
  - **Status:** fixed in batch 13 (Stores). One case-size helper is used for matching, reserving, stocking and returning.
- **Failed refunds:** a failed refund on a cancelled supply order is never retried, although the log says it is (`server_orders.lua:606`).
  - **Status:** fixed in batch 13 (Stores). Retried under a new numbered key after a stored failure, with a growing wait; migration v3 covers older orders.
- **Escrow sweep:** it can charge a citizen for a request that was already cancelled (`pf-services/server/requests.lua:555`).
  - **Status:** fixed in batch 12 (pf-services). The sweep refunds a request that was cancelled meanwhile.
- **Dispatch app:**
  - waypoints fail for Benny's and Beeker's;
    - **Status:** fixed in batch 13 (EMS and Dispatch). One job rule for the list, accept and the waypoint.
  - a government request can be claimed there without the permission;
    - **Status:** fixed in batch 13 (EMS and Dispatch). Taking or completing one needs the kind's pf-government permission.
  - accept, release and complete return the raw request row to the client.
    - **Status:** fixed in batch 12 (pf-services). The RPCs return the public request view.
- **Fleet cars on the used lot:** an active job-fleet car can still be sold there or through /transfervehicle.
  - **Status:** fixed in batch 13 (Vehicles). Refused on the lot and by `/transfervehicle`, also inside the SQL. The lot's buy path does not check the fleet again: handled in batch 13b.
- **Accept and pay:** the prompt accepts whatever offer is pending, not the one shown (`pfm-vehicleshop/server.lua:900`).
  - **Status:** fixed in batch 13 (Vehicles). Only the offer with the id shown is accepted.
- **Stale wear reports:** a repair can be undone by the driver's in-flight wear report (`advanced_systems.lua:221`).
  - **Status:** fixed in batch 13 (Mechanic). Each server repair raises a wear epoch, and older reports are dropped.
- **Test plan:** it includes a paid App Store purchase, but no app has a price.
  - **Status:** fixed in batch 13 (docs). The App Store row of `FINAL_TEST_PLAN.md` now says to give an app a test price on staging first.

## Older issues (also on `main`, worth fixing)

- **Supplier markup drain:** cancelling a player-supplied order refunds the buyer in full while the supplier keeps the markup bonus. A store boss who is also a supplier can drain the escrow (`pf-stores/server_orders.lua:600`). One skeptic confirmed it; the other said it predates the branch.
  - **Status:** fixed in batch 13 (Stores). The supplier's markup share is paid only at delivery, so a cancel leaves the supplier nothing.
- **Gruppe 6 early end:** ending a contract pays the tier maximum rather than the contract's payout (`gruppe6.lua:1003`).
  - **Status:** fixed in batch 13 (Jobs). It pays the contract's payout times the share of bags handed in.
- **Used-car lot and loans:** listing a financed car on the used lot and taking it back erases the loan (`pfm-vehiclesales/server/main.lua:122`).
  - **Status:** fixed in batch 13 (Vehicles). Financed cars can't be listed, and taking a listing back restores its loan.
- **Bank counters:** cash and society-cash callbacks have no proximity check (`pfm-banking/server.lua:359`).
  - **Status:** fixed in batch 13 (Banking). Cash needs the player within 5 m of a counter, or within 4 m of a listed ATM for a withdrawal.
- **Inventory search:** a searched player's inventory stays locked when the searcher disconnects (`pfm-inventory/server/main.lua:198`).
  - **Status:** fixed in batch 13 (Computer and inventory). The search ends on the searcher's disconnect, logout, close or another inventory. A searcher who steps away during the 1.5 s opening wait stays unbound: handled in batch 13b.

## Refuted (no action)

- **Gruppe 6 crew pay pool:** not new.
  - **Status:** no action (refuted).
- **NOS migration:** NOS was never saved in `mods` on `main`.
  - **Status:** no action (refuted).
- **Bus route double count:** the ledger key lock refuses parallel copies.
  - **Status:** no action (refuted).
