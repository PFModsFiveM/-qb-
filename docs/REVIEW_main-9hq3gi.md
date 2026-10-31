# Review of branch `main-9hq3gi` (2026-10-31)

**Scope:** both repositories at the branch tips: `-qb-` 3b01ccd and `-pfscripts-` 496888a.

**Method:**
- Every area of the diff was read by one of 13 reviewers. Three more checked across the whole tree: references to deleted resources, readiness for strict state bags, and the branch report's claims.
- Two skeptics then tried to refute each medium-or-worse finding.
- A final pass looked for anything left uncovered.

**Totals:** 61 findings. 23 confirmed by both skeptics, 9 confirmed by one, 3 refuted, 29 low-severity ones not sent to skeptics.

## Status (2026-10-31)

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

**2. Deleting a character creates money.**
- **A player can delete the character they are playing** (pfm-core `player.lua:584`; pfm-multicharacter's delete event has no "not loaded" check). The new cleanup writes off loans and card debt, then the next periodic save re-creates the character with its full balance.
- **Alt-character loans:** `pfm-banking/server_characters.lua:59-60` writes off active loans and card debt on deletion. A player can take loans on an alt, move the money to their main character, then delete the alt. This is repeatable. Unpaid debt should block deletion, or the bank should recover it.

**3. Police impounds are lost.**
- **The impound becomes a tow to the owner's garage.** `pf-services/server/requests.lua:326` treats a request as a duplicate by plate alone, ignoring the request kind. If the owner has an open garage tow, the officer's impound returns that request, shows "Tow ordered", and the car goes to the owner's garage.
- **An impound nobody tows is dropped.** `pf-jobs/server/apps/tow_requests.lua:77` has no `onClosed` handler. If no tow driver completes it within an hour, the impound expires silently: no depot fee and no seizure.

**4. pf-services payment is not "paid once the work is proven".**
- **Roadside repair:** `mechanic.roadside` has `verify = false` and no handler. A mechanic can accept and complete from across the map and take the citizen's $100 (`requests.lua:482`).
- **Cancel after acceptance:** the requester can cancel an accepted request and get the escrow back after the worker did the job (`requests.lua:512`).
- **The claim is partly wrong:** the branch claim and `docs/JOB_LINKS.md` overstate this.

**5. Government announcements bypass the new permission.** `gov:createAnnouncement` (`pf-government/server/callbacks.lua:285`) and the net event `pf-government:server:createAnnouncement` (`integrations.lua:186`) check only "is a government employee".
- **What a low-grade employee can do:** take the author name from the client, skip length checks, auto-publish as a City Desk news article with no editor, and raise an "urgent" breaking alert.
- **Deletion:** `announcement:delete` lets any government employee delete any announcement.

**6. Strict state bags are not ready to turn on.**
- **Third-party writers:** `[standalone]/progressbar` (`inv_busy`) and `[voice]/pma-voice` still write replicated state from the client.
- **Inventory not blocked:** with strict mode on, the server no longer blocks the inventory during progress bars.
- **Staging fails its own test:** staging (`docs/staging/server.staging.cfg:26`) already enables strict mode, so FINAL_TEST_PLAN's "no state-bag errors" step will fail.
- **Live cfg duplicate:** the live cfg also starts `[custom]/pf-mechanicjob`, an old duplicate full of client writes.

**7. Websites with a Cards Grid or Quick Links module cannot be saved.** The new depth limit (`pf-computer/server/main.lua:1431`, `SITE_MAX_DEPTH = 6`) rejects the editor's own structure.

**8. Character deletion leaves data behind** (the claim "cleans every system" is partly false):
- pf-stores ownership;
- pf-government staff, registry owner and property records;
- pf-mechanicjob `vehicle_diagnostics`;
- phone gallery and tweets;
- vehicle trunks and gloveboxes;
- pf-news payouts and ads.

**9. NOS.**
- **Free refill:** an emptied bottle refills when the car is lost before the next save (`pf-mechanicjob/server/nos.lua:162`).
- **Passenger wear reports:** any occupant can max out the car's wear parts, possibly on a different car with the same plate (`nos.lua:220`).

**10. Tow rental.**
- **Double deposit:** two rent requests at once charge two $250 deposits, one of which can never be refunded (`pf-jobs/server/apps/tow.lua:267`).
- **Deposit kept after leaving the job:** the deposit cannot be returned once the player leaves the tow job (`tow.lua:304`).

**11. News vehicles** (`pfm-newsjob/server/main.lua`).
- **Stuck lock:** the "return your vehicle first" lock never clears when the van is destroyed (line 76).
- **Trusted client event:** `vehicleStored` is trusted from the client, giving unlimited vans, each with a freshly stocked trunk of equipment (line 96).

**12. App Store paid apps.** This is latent, because no app has a price yet.
- **Failed payment sticks:** one failed payment blocks that app forever, because the fixed ledger keys stay failed (`pf-devices/server/installs.lua:70`).
- **Double charge:** two installs at once charge both bank and cash (`installs.lua:63`).

**13. Phone invoice retry.** `pfm-phone/server/main.lua:458` treats every non-completed ledger key as failed. It can charge twice after a crash in the middle of a transfer, and an invoice becomes unpayable after 20 failed attempts.

## Smaller issues (new on this branch)

- **Mail re-sharing:** a read-only document link can be re-shared through mail attachments, which bypasses unshare; a re-shared holder can sign and lock the owner's document (`pf-citizen/server/mail.lua:477`).
- **Signed documents:** the owner of a signed document can delete or unshare it, removing the other signers' record (`documents.lua:139`).
- **EMS calls:** "Person down" calls stay on the EMS MDT after the patient respawns, and a client can add a new one every 60 seconds (`pf-ambulancejob/server/main.lua:47`).
- **Job Board after a restart:** hiring events stop after `restart pf-services` (`pf-computer/server/jobboard.lua:158`).
- **Cruise control:** the HUD indicator is gone; its only handler was in the deleted pfm-hud (`pfm-smallresources/client/cruise.lua:45`).
- **Fuel sync:** the network owner of any empty car can set its fuel from any distance (`pfm-fuel/server/main.lua:61`).
- **Mechanic tows:** any on-duty mechanic, not only the boss, can spend the shop's money on tows (`pf-mechanicjob/server/advanced_systems.lua:398`).
- **Gruppe 6 XP:** parallel deposit requests add XP once per request (`gruppe6.lua:1054`).
- **Bus spawn:** two take-out requests at once spawn two buses (`bus.lua:557`).
- **Gruppe 6 storage:** the truck's "Open Storage" option fires an event nothing handles (`gruppe6.lua:537`).
- **Supply pickup:** non-boss staff can start a supply pickup run that can never be collected (`pf-computer/server/main.lua:2926`).
- **Supplier stock:** it ignores `Config.SupplyChain.CaseSize` for restaurant lines (`pf-stores/server_orders.lua:440`).
- **Failed refunds:** a failed refund on a cancelled supply order is never retried, although the log says it is (`server_orders.lua:606`).
- **Escrow sweep:** it can charge a citizen for a request that was already cancelled (`pf-services/server/requests.lua:555`).
- **Dispatch app:**
  - waypoints fail for Benny's and Beeker's;
  - a government request can be claimed there without the permission;
  - accept, release and complete return the raw request row to the client.
- **Fleet cars on the used lot:** an active job-fleet car can still be sold there or through /transfervehicle.
- **Accept and pay:** the prompt accepts whatever offer is pending, not the one shown (`pfm-vehicleshop/server.lua:900`).
- **Stale wear reports:** a repair can be undone by the driver's in-flight wear report (`advanced_systems.lua:221`).
- **Test plan:** it includes a paid App Store purchase, but no app has a price.

## Older issues (also on `main`, worth fixing)

- **Supplier markup drain:** cancelling a player-supplied order refunds the buyer in full while the supplier keeps the markup bonus. A store boss who is also a supplier can drain the escrow (`pf-stores/server_orders.lua:600`). One skeptic confirmed it; the other said it predates the branch.
- **Gruppe 6 early end:** ending a contract pays the tier maximum rather than the contract's payout (`gruppe6.lua:1003`).
- **Used-car lot and loans:** listing a financed car on the used lot and taking it back erases the loan (`pfm-vehiclesales/server/main.lua:122`).
- **Bank counters:** cash and society-cash callbacks have no proximity check (`pfm-banking/server.lua:359`).
- **Inventory search:** a searched player's inventory stays locked when the searcher disconnects (`pfm-inventory/server/main.lua:198`).

## Refuted (no action)

- **Gruppe 6 crew pay pool:** not new.
- **NOS migration:** NOS was never saved in `mods` on `main`.
- **Bus route double count:** the ledger key lock refuses parallel copies.
