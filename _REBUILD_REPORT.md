# PF Framework Rebuild — 2026-10-22

Full overhaul of `[qb]` + pf-hud. Backup of the original `[qb]` folder:
`F:\fivemserver\txData\PF\resources\_backup_qb_2026-10-22.zip`

---

## ⚠️ SECURITY — READ FIRST

An obfuscated **remote-code-execution backdoor** was found planted across the server
(XOR-encoded JS loaders wired into fxmanifests; they fetch and `eval()` code from
`steaxscripts.com` every ~2 minutes — endpoints `/qwertyJJ`, `/qwertyJJgg`, `/qwertyJJcfxre`).
28 infected files were found in total.

**Cleaned (quarantined + de-referenced from manifests)** — 11 files in `[qb]` / `[pfscripts]`:
qb-newsjob, qb-pawnshop, qb-management, qb-garages, qb-jewelery, qb-loading, qb-shops,
qb-smallresources, pf-computer, pf-elevator, pf-outfitbag.
Quarantine + log: `...\scratchpad\quarantine\MANIFEST.txt` (session temp folder).

**STILL INFECTED AND LOADING** — 17 files outside the folders I was given
(`[custom]`, `[standalone]`, `[scripts]`), including: safecracker, connectqueue,
cfx-gom-map-amb-prcc (×2 files), pf_cctv, amb_salls_sheriff, lsia_fix, amb_nodes,
pf_mirrorpark_01, amb_rox_11_garbage_dept_int, laundrotest, pf_hut, pf_fog,
timecycleeditor (both copies), plus a dangling manifest line in amb_stella_apartments.

**Do now:**
1. Block `steaxscripts.com` at the firewall / DNS.
2. Remove the 17 remaining loader files + their fxmanifest lines (or ask me to).
3. Rotate every secret the server runtime could read: `sv_licenseKey`, txAdmin admin
   passwords, MySQL password, Discord webhooks/bot tokens.
4. Audit the DB for tampering — the remote payload had full server-side access.

---

## qb-core — rebuilt from the ground up
- Based on current upstream main (all fixes since your v1.3.0): async paychecks, client
  loop CPU reduction, ghost-character deletion fix, asset-loader timeouts, partial player
  data updates, command middleware, AddPlayerMethod fixes, duty-at-login, GetShared API.
- Your customizations preserved: `government` job, `outfitbag` + 3 `hack_usb_*` items.
- Added a backward-compat shim so legacy `QBCore:Player:SetPlayerData` listeners
  (pf-hud, pf-restaurants, qb-target, etc.) still fire on partial updates.
- **New notification + interaction-prompt UI** (glass design, grouping badges, progress
  bars, keycap prompts). Respects the global theme.

## All 56 other [qb] resources — synced to upstream main
Everything was near-stock; merges verified by re-diff. Notable:
- Anti-exploit fixes picked up in: taxijob (NpcPay), hotdogjob (Sell), houserobbery,
  scrapyard, truckrobbery, prison, vehicleshop (finance + spawn validation), apartments
  (stash validation), crafting (server-side recipes), busjob (pay cooldown), radialmenu
  (trunk validation), garages (ownership checks).
- Local customizations preserved: qb-houses + qb-vehiclesales pf-government tax
  integration, qb-inventory pf-government sales tax (re-applied onto inventory 2.2.3
  with new hooks system), qb-shops live stock JSON, all door configs.
- qb-target intentionally left on your local build (same 57-export API as upstream;
  upstream was only a refactor — kept for pf-jobs safety).
- qb-management: `qb-bossmenu:server:addMoney` (fired by pf-mechanicjob) was a silent
  no-op before — now actually deposits into qb-banking society accounts.
- Compat shims added where upstream renamed things (vehiclekeys plate fallback,
  inventory UseItem arg order, OnJobUpdate aliases).

## New UIs (all themeable, previews in chat + `pf-ui-preview-hub.html`)
- **pf-hud** — rebuilt: rings/bars/minimal styles, global RGB theme editor
  (primary/secondary/accent/text + opacity), drag-to-move + scroll-to-resize layout
  editor, minimap shapes (rounded/square/circle) with frame + white iFruit logo,
  compass, speedo/fuel/seatbelt/nitro, money popups, cinematic mode. Settings persist
  per player (KVP). All old `hud:*` events still work.
- **Global theme system** — pf-hud broadcasts `pf-ui:themeUpdated`; qb-menu, qb-input,
  qb-banking, qb-multicharacter, qb-scoreboard and qb-core (notify/drawtext) restyle live.
- **qb-banking** — advanced bank: per-location brands (Fleeca / Pacific Standard /
  Blaine County Savings, Maze available), dashboard, credit score (bank_credit),
  loans with APR tiers + installments + late fees + auto-billing (bank_loans),
  credit cards with limits, cash advances and interest (bank_cards). Tables
  auto-create on first start. All old exports/events unchanged.
- **qb-menu / qb-input / qb-multicharacter / qb-scoreboard / qb-loading** — redesigned
  (multicharacter dropped ~180KB of Vue/Vuetify/axios/swal2; loading screen is clean
  with an expandable "get familiar" panel; input's Enter-submit bug fixed).

## Notes / follow-ups
- `server.cfg` has `#ensure [qb]` commented out — qb resources currently start only as
  dependencies. Uncomment it (or ensure individually) if that's not intentional.
- No `progressbar` resource exists in [standalone]; `QBCore.Functions.Progressbar`
  errors without it (pre-existing). qb-banking's ATM flow uses it.
- Restart the server (or `refresh` + restart pfm-core first, then the rest) to load
  everything. Import nothing manually — banking tables self-create.
- No Lua interpreter was available for machine syntax-checking; agent merges are
  verbatim upstream files, hand-written files were reviewed manually. Watch the first
  server start's console for script errors.

---

# ROUND 2 — 2026-10-23

## Malware: fully cleaned
All 28 backdoor loaders are now quarantined (session scratchpad quarantine\) and every
fxmanifest reference removed, including the 17 in [custom], [standalone] and [scripts]
and the dangling amb_stella_apartments line. Final signature sweep across all of
resources\: zero matches. (5 earlier samples were also eaten by Avast — check its Virus
Chest.) Still do: block steaxscripts.com, rotate credentials, audit the DB.

## Renamed qb- -> pfm-
All 57 framework resources renamed (folders + ~538 files of references across every
resource category + server.cfg): exports['pfm-core'], @pfm-core/..., nui://pfm-...,
NUI fetch URLs, GetResourceState, dependencies. Event name strings intentionally
unchanged ('qb-banking:server:...' etc.) so all existing wiring keeps working.
Your pf-* resources keep their names. The grouping folder is still called [qb] —
rename it to [pfm] whenever you like (nothing references the folder name).
Reference backups: scratchpad\rename-backup\.

## Beyond-stock code improvements (server-side)
Four hardening/feature passes over the gameplay resources. Highlights of real
exploits that existed in stock qb and are now fixed:
- Money printers: pawnshop sell/melt paid client-sent prices; drug corner-selling and
  deliveries paid client-sent payouts; phone banking credited receivers even when the
  sender debit failed (and accepted negative amounts); tow paid a client-sent drop count.
- Item printers: pawnshop melt rewards from client table; drugs delivery bricks;
  newsjob trunk restock; weapon repair point overwrite dupe.
- Access: adminmenu leaked all player coords + dealer locations to ANY client;
  police SeizeDriverLicense/Impound/SetTracker had no job checks; evidence DNA was
  spoofable; any client could teleport anyone into any apartment; any player could
  toggle anklet trackers or read tracker locations.
- Sessions: jobs (garbage/bus/taxi/tow/hotdog) now track work sessions server-side and
  reject payouts without one; hotdog infinite-deposit-refund fixed; bus one-vehicle
  check actually works now.
- New config-gated features (all default-off unless noted): job StreakBonus payouts,
  shops DynamicStock, pawnshop FluctuatingPrices, diving RarityTable, garages
  SharedGarages, vehiclekeys GiveTemporaryKeys export, weathersync
  DynamicWeatherPatterns, drugs ServerPoliceCallChance + customer-ped validation (on),
  smallresources consumable cooldowns/clamps (on), prison MaxJailTime clamp (on),
  phone rate limits + 280-char caps (on), crypto MaxTransaction (on).

## pfm-cityhall -> pf-government
All cityhall features (ID/driver/weapon license items, job center + AddCityJob export,
driving school, peds/blips/zones) are now implemented inside pf-government
(client/civil.lua + server/civil.lua + Config.CivilServices), with every original
qb-cityhall event name kept as a compat alias. pfm-cityhall is marked DEPRECATED and
self-disables the new code if both run — remove pfm-cityhall from your start list.
Also fixed pf-government's FrameworkResourceName ('qb-core' -> 'pfm-core').

## UI round 2 (all verified with real-browser screenshots)
- pf-hud: speed / belt+engine / nitro are now SEPARATE elements, each draggable and
  scroll-resizable in Edit Layout; per-element background toggles (speedo, status,
  compass, icons, money); white iFruit logo on the minimap (fixed); theme RGB pickers.
- Notifications: new design — glowing icon squircle, type title line, accent border +
  shine sweep + spring entrance, gradient progress bar.
- pfm-menu: icon squircles, 1-9 hotkey badges + number-key selection, hover glow +
  chevron, staggered entrances.
- pfm-input: glow focus, accent group titles, animated submit arrow, dimmed backdrop.
- pfm-banking: real brand logos (Fleeca leaf, Maze M, Pacific star, Blaine shield,
  PFCU bolt) in sidebar/hero/cards; credit cards v2 with gold chip, contactless mark,
  holographic sheen + hover lift.
- pfm-multicharacter: slot-numbered cards + detail panel (avatar, job/cash/bank/
  nationality grid, big Play, delete), PF ROLEPLAY branding, entrance animations.
- One self-contained preview hub (pf-ui-preview-hub.html) with a selector for every UI
  and a global theme editor.

## Restart checklist
1. Remove pfm-cityhall from the start list (or leave — it self-guards, but remove soon).
2. Full server restart. Watch the console: no Lua runtime exists on this machine, so
   everything was verified by review/parser only.
3. Smoke test: bank (loans/cards), cuff flow, hospital beds, jail+release, phone
   tweet/transfer, garbage/taxi/tow payouts, /hud edit layout.
---

# ROUND 3 — 2026-10-23 (economy tool + inventory v2)

## PF Economy Tool (new) — F:\fivemserver\txData\PF\economy-tool\
Run `node server.js`, open http://localhost:8790. Tracks 141 live values across the
configs (job payouts incl. server-hardcoded NPC fares, drug/pawn prices, loan APRs,
paychecks, fuel, crypto, hunger rates), models 13 activity loops with editable cycle
assumptions, charts $/hour per activity, and WRITES edits back into the Lua files
(timestamped backup per save — verified with a live write/revert round-trip).
See economy-tool\README.md. test-extract.js re-verifies the manifest after edits.

## pfm-inventory — UI rebuilt
Same NUI protocol (all 9 callbacks, 6 message actions — zero server/client Lua changes
except the theme hookup), new look + new functions:
- Live search box (dims non-matches), hover item-info panel with metadata chips
- Favorites (F key or context menu): starred items are blocked from drop/give
- Quick stack button: moves every stack that already exists in the open container
- Ctrl+click = move half, Shift+click = split (kept), right-click quick-move (kept)
- Amount box with 1/5/10/all chips, slots+weight counters, animated weight bars
- Unique-item gold corner, quality bars, hotkey badges, stacking item-box
  notifications, restyled hotbar/required-items/attachments, global theme support
Previews verified in a real browser (hub v3 opens on the inventory with real item images).
---

# Round 4 — Economy profit view, Inventory v3, player-owned stores

## Economy tool (F:\fivemserver\txData\PF\economy-tool, node server.js, port 8790)
- The chart is now **Profit per hour** — earnings minus expenses, not gross. Every job card header shows `$X/hr profit` and `$Y profit per cycle · Z min`.
- Each activity gained an editable **"Expenses per cycle"** assumption (fuel, supplies, deposits…), so the math is `gross − expenses = profit`, spelled out in the tooltip for jobs that have costs.
- Config values still write straight back into the Lua files (timestamped backups in economy-tool\backups).

## pfm-inventory v3 — structural redesign (not a reskin)
- **ID card**: avatar, character name, citizen ID, job, and current residence (reads `metadata.currentapartment`/`residence`).
- **SIM section**: when the player carries a phone with a simcard (or has a phone number), the card shows the number; otherwise "NO SIM".
- **Pockets**: slots 1–5 are a separate hotbar strip (keys 1–5), visually distinct from the main grid.
- **Backpack**: equipping a `backpack` item adds a Backpack section (20 slots / 30 kg by default, `Config.Backpack`). It is a real persistent stash (`backpack-<id>` in the `inventories` table) — contents survive restarts, open-state is anti-cheat gated server-side, and backpacks-inside-backpacks are blocked by a server hook. Drag into it, right-click inside pulls back out, ctrl+click quick-moves.
- **Item info** moved to the center column; realistic on-person weight kept (120 kg default — tune in config).
- New items in pfm-core/shared/items.lua: `backpack`, `simcard` (+ generated icons in html/images).
- New files: server/backpack.lua (getBackpack callback + nested-container hook), client buildPlayerInfo/backpack plumbing. NUI protocol unchanged for everything else.

## pf-stores — real player-owned stores
- Owners now manage **prices** (per-item override, clamped to 50× supply cost) and see **margin vs supply cost**.
- Stores have a **balance**: customer pays item price + tax → tax goes to pf-government as before → the sale subtotal is credited to the store's balance → the owner withdraws to their bank from the Manage panel.
- **Ledger**: every sale logs per-line rows (`pf_store_ledger`); Manage panel shows today / 7-day / all-time revenue, top-5 sellers, and recent activity.
- New DB: `pf_store_prices`, `pf_store_ledger`, `pf_stores.balance` — all self-migrate at resource start, no manual SQL.
- Management UI is owner-only (ownership resolved server-side on every callback).

## Verified in browser (Playwright)
- Inventory v3: stash/shop/solo views, backpack right-click pull, item-info panel, SIM card — no JS errors.
- Economy tool profit chart + per-job profit headers — no JS errors.
- Preview hub rebuilt with the v3 inventory.

## Still untested on a live server
Nothing from rounds 1–4 has run on an actual FXServer yet — restart the server and smoke-test: open inventory (with/without backpack), buy from a shop, a store owner setting a price + withdrawing, and the economy tool after editing a value.

---

# Round 4.1 — Inventory v4: fullscreen spread (feedback: "not a reskin")

Layout rebuilt from the reference screenshots:
- **Fullscreen spread over the game** (no boxed panel): big INVENTORY title + character name top-left, ESC chip top-right.
- **Pockets strip** (keys 1–5) as its own left column.
- **Character silhouette** with equipment slots: Backpack, Body Armour, Phone, Radio and two Weapon slots auto-populate from carried items (hover shows info, drag works straight from the slot).
- **Personal info** bottom-left: Name / Phone Number / Citizen ID / Occupation / Residence with colored accent bars (phone row says "No SIM card" when the SIM is missing).
- Player grid + gold-accented Backpack section center, amount/quick-stack/item-info strip, then the stash/shop/trunk panel on the right.
- Filled slots get an accent underline; everything is glass over the game world. Scales at 1920/1750/1366 (body column hides on very small screens).
- Same app logic and NUI protocol — only layout/presentation changed, so nothing server-side moved.

---

# Round 4.2 — Inventory v5 (feedback round)

- **Figure + equipment slots removed** — they were display-only and not FiveM-practical; the freed space went into bigger item slots.
- **Pockets strip kept** (keys 1–5) with its header stacked above it.
- **Personal info is now a proper card** bottom-left: avatar badge, name, **cash + bank chips** (new — client now sends money with the open payload), then Phone Number / Citizen ID / Occupation / Residence rows.
- Slot size bumped (104px at 1080p); scales down at 1750px-wide and short screens.
- Previews/mock data use a fake RP identity, not the real name.

---

# Round 4.3 — Inventory v6 polish + drag-routing fix

- **Important fix:** drag & drop between panels was silently broken by the v4 layout rename (the drop detection still looked for the old panel class names). Fixed and verified with real browser drags — player → stash moves, splits and merges all work again.
- **Tidy button** (wand icon in the search bar): combines duplicate non-unique stacks into the earliest slot, using the same server-validated move protocol as manual merging. Plays the fail sound when there is nothing to tidy.
- **Shop totals**: hovering a shop item now shows "$X each" and, with an amount selected, "$Y for N" in the item info panel.
- **Hotbar restyled** to match the v5 glass look (frosted slots, accent underline on filled slots).
- **Item/required notifications** switched to frosted glass.
- **Theme hookup restored for the spread**: slot tiles now follow the player's /hud secondary color + accent again (new --inv-slot-spread var set by the theme broadcast).

---

# Round 5 — pfm-garages redone

Server was already hardened in the earlier passes (ownership checks everywhere, depot price read from the DB, stat clamps, protected garage sync) — this round was the UI and the client payload.

## UI (full rebuild, stock qb UI replaced)
- PF glass panel: garage name + type chip (public/depot/job/gang/house) + live vehicle count, animated card list.
- **Search** by vehicle name or plate.
- Each vehicle card: brand + name, plate chip, mileage, outstanding **finance** chip, status chip (In garage / Out / In depot / Impounded) and one clear action: **Drive**, **Track** (for vehicles that are out), or **Pay $X** (depot fee, server-priced).
- Fuel / engine / body as compact tri-color bars with icons.
- Follows the global /hud theme like every other pfm UI.

## Client improvements
- Payload now includes brand, category and the **shared** flag the server already sent for shared job/gang garages — shared vehicles show a gold "shared" chip and no Drive button (only the owner can take them out server-side; before, the button just silently failed).
- Same NUI callbacks as before (closeGarage / takeOutVehicle / trackVehicle / takeOutDepo) — no server surface changed.

---

# Round 6 — pfm-banking: multi-account banking (reference-grade)

## New features
- **Shared & business accounts**: create (fee + max-owned cap from config), rename, custom color, delete (owner, empty only); unique PF IBANs, personal accounts get IBANs too.
- **Members & permissions**: per-member deposit / withdraw / cards / manage toggles, add by citizen ID, remove (their cards auto-cancel); owner immutable.
- **Transfers**: between own accounts or to any IBAN (account or player personal), with a note; offline recipients handled, refund path if credit fails.
- **Cards**: up to 4 per account/personal, 5 designs, lock/unlock, cancel, reveal + copy; shared accounts can hold different members' cards.
- **Transactions ledger** for every account and personal banking, feeding the UI.

## UI (matches the reference screenshots)
- Sidebar dashboard: brand logo, icon nav with accent pill, Exit at bottom.
- Dashboard: welcome header + credit score, Income/Expenses/Transfers stat tiles (7 days), weekday income-vs-expense chart, transactions table with status chips, "My Account" panel (balance, debit-card visual, Withdraw/Deposit, Fast transfer to IBAN).
- Accounts: account-card carousel with type chips + per-account colors + masked IBAN + copy + balance-privacy eye, "+ New account"; per-account quick actions, Members & permissions table, settings, activity.
- Cards: large card stage with reveal flip, Card N of M arrows, Reveal/Copy/Lock/Cancel, "Issue card" flow (link to personal or permitted account + design swatches).
- Loans / credit score / existing features untouched; global theme still applies.

## Safety
Every operation permission-checked server-side; amounts floored/capped; conditional single-statement debits with refund paths; legacy bank_accounts untouched (new tables are bank_accounts_v2 etc., self-created on start).

## Verified
Browser-driven preview: dashboard, accounts hub (members table, deposit/withdraw, settings), cards view — zero JS errors. Lua review-verified only (no runtime); needs in-game smoke test.

---

# Round 7 — pfm-spawn redone

- Stock Vuetify UI replaced with a lightweight PF glass panel (left side, world stays visible): sections for **Last location** (green), **My properties** (owned houses, gold), **City spawns**, and the **apartment picker** for fresh characters; selected state + single Spawn button.
- **Camera now flies to every location type you click** — houses, apartments and last location included (stock only previewed normal spawns; the client already supported the rest).
- Follows the global /hud theme; dropped the bundled 137 KB vue.js + Vuetify CDN (now zero frameworks); same NUI callbacks (setCam/spawnplayer/chooseAppa/exit) so no server/flow changes.

---

# Round 8 — pfm-policejob gameplay pack

New gameplay (all under `Config.Gameplay` in config.lua, each feature toggleable):

- **Cuff resistance**: hardcuffing a standing suspect gives them a 3s mash-E window (10 presses) to break free; surrendered (hands up), downed, ragdolled or in-vehicle suspects can't resist, uncuffing and softcuffing are never contested. Officer gets a 4s retry cooldown after a breakout; if the suspect's client never answers, the cuff lands anyway (anti-cheat safety net). Officer cuff animation now plays only when the cuff actually lands.
- **Tackle** (police, default key G, rebindable): while sprinting near a fleeing suspect, dive-tackle them to the ground (both ragdoll); 15s cooldown, server-validated distance/job, target must actually be running.
- **GSR**: firing any real gun marks the shooter server-side (metadata, 45 min). New `/gsr` swabs the nearest person with a progressbar and reports POSITIVE/NEGATIVE to the officer; the suspect is told they were swabbed.
- **Panic button** (`/panic` + bindable key): alerts every on-duty officer with a sound, a notification with your callsign, and a flashing red route blip for 60s. 60s cooldown.
- **Impound fees now fund the city**: paying a depot/impound release fee in pfm-garages deposits it into the pf-government treasury (same pattern as pf-stores sales tax).

Files: new client/gameplay.lua + server/gameplay.lua, cuff flow reworked in server/interactions.lua, en locale additions. All changed Lua parse-checked (luaparse, Cfx extensions stripped); needs in-game testing with two players for cuff/tackle flows.

---

# Round 9 — pfm-ambulancejob: bystander CPR

New `/cpr` for **everyone**, not just EMS (Config.Gameplay.CPR, all numbers tunable):

- Kneel over a downed player and do 15s of chest compressions (proper CPR animation).
- On someone **in last stand**: adds 90s of bleed-out time (capped at the normal maximum) — bystanders can genuinely keep someone alive until medics arrive.
- On someone **fully dead**: 15% chance they gasp back into last stand with 120s on the clock; otherwise "no response".
- Per-victim 60s cooldown so CPR can't be chained forever; rescuer must be healthy; all distance/state checks server-side.
- Both players get RP notifications, and on-duty EMS get a "Bystander performing CPR" alert at the location.

This stacks with the existing first-aid-kit rescue (item still fully revives from late last stand). Files: client/cpr.lua + server/cpr.lua + config + en locale. Parse-checked; needs a two-player in-game test.

---

# Round 10 — pfm-weapons: jamming & field maintenance

Weapon wear finally matters before the gun breaks outright (Config.Jam, all tunable):

- **Jamming**: below 50% condition a shot can jam the gun — 2% per trigger pull at 25-50%, 5% at 10-25%, 10% under 10%. A jammed gun can't fire; press **R** for a 2.5s clearing action (then it racks a reload). Full-auto rolls at most twice a second so mag dumps aren't instantly punished.
- **Gun Oil & Brush** (new `gunoil` item + icon, added to pfm-core items): use it with the weapon in hand for an 8s strip-and-oil that restores +40 condition (capped at 100) and clears any jam. Consumed on use, validated server-side (kit + weapon both checked, quality computed server-side).
- Melee, throwables, tasers, extinguisher and petrol can never jam. The existing paid repair shops stay as the full 0→100 repair path; gun oil is the cheaper field maintenance between fights.
- Add `gunoil` to your shop/crafting configs where you want it purchasable (item + icon are ready).

Files: client/jamming.lua + server/jamming.lua + config + locales; icon generated into pfm-inventory images. Parse-checked; needs an in-game shooting test with a worn weapon.

---

# Round 11 — pfm-fuel: dynamic station prices + fuel tax

- **Per-station pricing** (Config.DynamicPricing): every gas station rolls its own price between 0.85x and 1.25x of the base per-litre price, rerolled every 6 hours — Sandy might be the cheap fill while the city costs you. The pump UI shows that station's real all-in price.
- **City sales tax at the pump** (Config.FuelSalesTax): the pf-government sales tax is added to fuel purchases and collected into the city treasury, same as store sales — fuel is now part of the city economy loop.
- All prices are resolved server-side from the player's actual position; the client price is display-only. Falls back cleanly to flat pricing when disabled or when pf-government isn't running.
- The economy tool's base Config.FuelPrice is still the knob to tune; dynamic pricing multiplies on top.

Files: new server/pricing.lua, surgical edits to server/main.lua + client/main.lua, config. Parse-checked.

---

# Round 12 — pfm-houses: house selling + property registry

Houses were buy-only; now the market goes both ways:

- **Sell to the state**: `/sellhouse` at a house you own pays out 70% of the base price (Config.HouseSellBackPercent). Your house storage must be empty first (checked in the DB) so items can't vanish or leak to the next owner.
- **Sell to a player**: `/sellhouse [buyer id] [price]` with the buyer next to you sends them a confirmation dialog showing seller, address, price and the property transfer tax. On YES the buyer pays price + tax (tax to the pf-government treasury), the seller gets the price, and ownership + keys transfer (keys reset to the buyer only; contents stay with the house, as a private sale should). Offers expire after 60s, every check re-validated server-side (ownership, distance, funds, seller identity).
- **Government property registry**: both buying and private sales now call pf-government's RegisterProperty, so houses plug into the utilities/power/water systems automatically.

Files: server/main.lua (appended; uses the existing in-memory ownership tables), client confirmation dialog, config, en locale. Parse-checked.

---

# Round 13 — pfm-storerobbery: exploit fixes + loot that scales with risk

**Critical fixes** (these were live money printers):
- `takeMoney(register, true)` could be fired repeatedly by a modified client for infinite marked bills — now it requires a server-tracked robbery session (lockpick success validated server-side: distance, cops online, lockpick in inventory) and at least 20s of "emptying" time, one payout per session.
- The safe-code callbacks handed the actual combination to ANY client that asked. The keypad guess is now validated entirely server-side (the code never leaves the server); the padlock dial still needs its combination for the minigame, but only with an in-range, rate-limited attempt on an unrobbed safe.
- `SafeReward` could be spammed without ever touching a safe — now only the player who entered the right code (or ran an active padlock attempt) can claim, and the server marks the safe robbed itself.
- `callCops` is rate-limited, bounded to the caller's real position, and the street label is sanitized — no more fake-alert spam across the map.

**Gameplay**:
- **Safes now pay $600-1000 per bag** vs $250-450 from registers (they were identical) — cracking the safe is finally worth the noise.
- **Loot scales with police presence**: +15% cash per on-duty cop above the minimum, capped at +60% — robbing on a full-cop night pays more than farming dead hours.

Same events/flow for the client (two small client edits for the keypad validation). Parse-checked.

---

# Round 14 — pfm-bankrobbery: exploit fixes + risk-scaled loot

**Critical fixes** (same class as the store robbery, bigger payouts):
- `recieveItem` paid Pacific-tier loot ($19-21k bags, crypto sticks, SMGs) with only a distance check — no bank-open, no locker-open, no one-claim. Now every claim requires: bank opened, that locker actually drilled open, one claim per locker per robbery (cleared on the robbery reset), correct bank/loot-type pairing, and proximity.
- `setLockerState` let clients write ANY key on ANY locker (corruptable config) — now whitelisted to isBusy/isOpened booleans on real lockers of an opened bank.
- `SetStationStatus` let any client toggle power stations from anywhere = remote citywide blackouts on demand. Now requires standing at that station, valid station key, boolean state, 10s per-player cooldown.
- `thermite:StartServerFire` took unclamped fire counts and arbitrary coords (fire-spam griefing) — now capped at 25 children and pinned near the caller.
- `callCops` alert coords pinned to the caller's position + 30s cooldown; `removeBankCard` suffix whitelisted; small-bank ids validated (no more nil-index crashes on bogus ids).
- Small-bank timeout now actually reopens the bank for the next crew (isOpened was never reset).

**Gameplay**: marked-bills worth scales +10% per on-duty cop above 2, capped at +50% (Config.CopsLootScaling in sv_config) — big jobs on busy nights pay best.

Parse-checked. Client flow unchanged.
