# WHIP comparison: what to take into our framework (2026-11-15)

**Source:** WHIP server base at `F:\fivemserver\txData\WHIP_F9DD24.base`. It is a complete framework (`whip_core`) plus `whip_autos`, `whip_autos_shop`, `whip_chat`, `whip_dealership`, `whip_fuel`, `whip_gunny`, `whip_loadingscreen`, `whip_phone`, `whip_rope`, `whip_voice` and asset packs.

**How this was checked:** six read-only comparisons, one per area, against `[qb]` and `[pfscripts]`.

**Safety:** a backdoor scan found nothing:
- `load()` only re-reads WHIP's own files.
- `PerformHttpRequest` is used only for a GitHub release check and WHIP's voice service.
- No escrow.

**Exception:** `whip_voice` downloads and runs LiveKit and Node at runtime. Don't adopt it.

## Licence rules for anything we copy

**WHIP's own code is LGPL-3.0** (`whip_core/NOTICE.md`). For a copied file:
- keep its LGPL header;
- add `COPYING.LESSER` and `COPYING` to the resource;
- rename everything `whip`/`WHIP` (resources, events, textures, fonts);
- credit WHIP's author in a NOTICE.

**Other licences:**
- `whip_core/shared/emote_list.lua` is **GPL-3.0** (RPEmotes) and must keep its credits.
- The `*_example` resources are MIT.

**Not covered by WHIP's licence (Rockstar or third party).** Don't redistribute these as ours:
- the modified `pause_menu_pages_settings.gfx`;
- the `whip_media_*` packs: map tiles, the 3D map data from Regynate's unlicensed trace, blip and manufacturer images, emote preview videos;
- `whip_gunny` weapon models;
- the `whip_homes_mirrorpark` and `whip_autos_shop` maps;
- `chameleon_paint`, which is WildBrick142's: no reuse of its data, and no shipping it on a server that earns money;
- the keyboard word list (CC BY-SA 4.0).

## The build: visuals, interactions, controller (what the owner asked for first)

| # | What | From WHIP | Plan | Effort |
|---|---|---|---|---|
| 1 | **Controller support everywhere** | `client/controller.lua` reads the pad while a page has focus (`SetNuiFocusKeepInput`, Disabled reads) and posts intents (up/down/left/right/select/back/X/Y/LB/RB) to the page; `client/controls.lua`; `client/pad.lua` per-player button layouts; `html/js/router.js` keeps a keyboard-only panel working | New shared `pf-ui` resource: a controller bridge plus a small JS intent library every page includes. Convert pfm-menu, pfm-input, pfm-inventory, pf-devices (tablet/computer), pfm-target, pfm-radialmenu and pf-hud settings one at a time | M–L |
| 2 | **In-world prompts** (a door shows its key and label on the door) | `client/interact_world.lua` and `client/world_quad.lua`: depth-tested 3D quads drawn from three shared browser textures (badge atlas, label atlas, preview) | Port the renderer into `pf-ui`. pfm-target, pfm-doorlock and other resources register prompts on a point, entity or door. pfm-doorlock shows locked/unlocked with the key to press; it works with keyboard and pad | L |
| 3 | **Per-player settings** | `client/player_prefs.lua`: settings declared in code; only changes saved; server can force a value | Port into `pf-ui`; one settings page (HUD, controller layout, prompts) | S |
| 4 | **Shared look (theme tokens)** | `html/css/base.css` variables plus `html/js/theme.js` (theme resource CSS appended last) | `pf-ui/html/tokens.css` included by every page; pf-hud and pf-devices map onto it | M |
| 5 | **UI library rules** | `client/ui.lua`: each dialog or progress bar owned by its resource, one blocking dialog at a time, an "interrupted" state, pluggable skill checks | Bring into progressbar, pfm-input and pfm-minigames | M |
| 6 | **Vehicle dial** | `client/vehicle_hud.lua` plus `html/js/vehicle_hud/*` (three.js dial, per-car skins, air/boat modes) | Port into pf-hud as an option | M |
| 7 | **Minimap frame and tuner** | `client/hud_skin.lua` (frame sprite, GPS colour), `client/radar_debug.lua` (position tuner) | Port with WHIP's own frame art (renamed). Not the Rockstar-derived tiles | M |
| 8 | **Pause menu** | `client/pause.lua`: own menu (Resume / Map / Settings / Server settings / Quit) over GTA's frontend | Port without the modified scaleform | M |
| 9 | **Radial menu** | `client/radial.lua`: conditions, re-register replaces, close watcher, Seats page; `client/seats.lua` shuffle fix | pfm-radialmenu, pfm-smallresources | S–M |
| 10 | **Emotes and walk styles** (we have none; pf-ambulancejob calls a missing emote event) | `client/emotes.lua`, `server/held_props.lua` (props made on the server), `client/emote_place.lua`, `shared/emote_list.lua` (GPL) | New `pf-emotes` with menu, walk styles, server-made props; answers `animations:client:EmoteCommandStart` | M–L |
| 11 | **Doors** | `client/doors.lua`: register-then-verify with a slot cap, autolock generations, held/temporary doors | pfm-doorlock (together with #2) | S–M |
| 12 | **Chat** | `whip_chat`: server-set author, proximity, rate limit, controller keyboard | Server hook first, UI later | S–M |

## Framework and security

| What | From WHIP | Verdict | Effort |
|---|---|---|---|
| One checked event wrapper (types, rate limit, distance, permission, alive/dead, entity owner) | `server/secure.lua`, `server/sanitize.lua`, `RateLimit` | Port the core as `pfm-core` `SecureEvent`/`SecureCallback`; move events over one resource at a time, admin menu first. Ban the `any` type | M, then L |
| Callback rate limit | `server/callback.lua` | Add to `pfm-core/server/events.lua` | S |
| Admin powers need a per-session developer mode | `server/devtools_base.lua` | pfm-adminmenu | S |
| Named permissions saved to the database, with implies/grantedBy | `server/permissions.lua` | Port (our `setPermissions` is not saved) | M |
| Activity log per character and item; log every admin action | `server/activity_log.lua` | Build `PFLog` next to PFLedger | M–L |
| Config guard, DB timeout guard | `shared/config_guard.lua`, `server/db_guard.lua` | Port both | S |
| Session token (no payout to a character switched mid-action) | `server/player.lua` `IsSessionCurrent` | pfm-core, then job payouts | S |
| Needs decay on the server (today the client drives it) | `server/stats.lua` | pfm-core | M |
| Respawn hold while EMS is coming | `server/events_misc.lua` `HoldRespawn` | pf-ambulancejob downstate | S |
| Server-decided spawn point | `server/spawn_choices.lua` | pfm-spawn | S–M |
| Give items to offline characters | `server/pending_gives.lua` | pfm-core/pfm-inventory | S |
| Money holds (pre-authorise, settle what was used) | `server/money_holds.lua` | As a ledger feature in pfm-banking (fuel, taxi, rentals) | M |
| No bank transfers between one player's own characters | `server/bank.lua` `notOwnOther` | pfm-banking | S |
| Role permissions on top of job grades | `server/jobs.lua` | Additive `HasJobPermission` | L |
| Soft character delete | `characters.deleted` | pfm-core | M |
| Time anchor plus per-player override layers | `server/time.lua` | pfm-weathersync | M |

## Gameplay

| What | From WHIP | Verdict | Effort |
|---|---|---|---|
| Handling layer manager (one owner of all handling writes) | `client/vehicle_handling.lua` | Port into pf-mechanicjob | M |
| Damage persistence read by the server; doors and tyres as masks | `server/vehicle_damage.lua` | pfm-garages | M |
| Electric cars and fuel floor | `whip_fuel/client/tank.lua` | pfm-fuel | S |
| Engine swaps data, turbo, stance, drivetrain | `whip_autos` `engines.json`, `client/power/*`, `client/tuning.lua` | pf-mechanicjob, data and math first | M |
| Change locks / spare keys | `vehicle_key.lua` key tokens | pfm-vehicleshop | M |
| Garage bays | `server/garage_spots.lua` | pfm-garages | S–M |
| Bag weight counts its contents | `server/inventory.lua` `effectiveWeight` | pfm-inventory (fixes a weight hole) | S |
| Shop total guard | `server/shops.lua` `expectedTotal` | pfm-inventory shops | S |
| Weapon packs, attachment data and bench | `whip_gunny/lib/pack.lua`, `items/attachments.lua` | pfm-weapons | S–M |
| Ammo counted on the server, drawn/holstered/fired events | `whip_gunny/server/shooting.lua`, `weapons.lua` | pfm-weapons (feeds evidence) | M |
| Stash furniture, for-sale signs, property garages | `server/property_stashes.lua`, `client/property_listing.lua` | pfm-houses | M |
| Real interiors (MLO) instead of shells | `docs/properties.md` | Strategic rebuild of pfm-houses | L |

**Skipped:**
- the Director;
- whip_voice (LiveKit), until server-enforced voice privacy is wanted;
- whip_rope;
- the dealership: ours is richer;
- the WHIP loading screen (logo);
- the 3D WebGL minimap, because of its Rockstar map data;
- the keyboard word list.

## Problems found on our side during the comparison

- **No emote resource:** `animations:client:EmoteCommandStart` is called by pf-ambulancejob but has no receiver.
- **pma-voice twice:** it is in both `[qb]` and `[voice]`. Remove the `[voice]` copy on deploy.
- **Backpack weight:** a backpack's contents don't count toward its weight.
- **Admin actions:** kill, revive, freeze, goto, bring, spectate and permission changes are not logged.
- **Needs decay:** hunger and thirst only drop when the client asks.
