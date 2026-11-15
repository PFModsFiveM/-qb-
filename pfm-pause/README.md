# pfm-pause

PF's pause menu. Escape, P or a pad's Start open it in place of GTA's pause screen. The page is a
port of WHIP's pause menu (LGPL-3.0, see `NOTICE.md`), with PF's own brand mark in place of WHIP's
logo. The game keeps running behind it: only your own input is taken.

`ensure pfm-media-map` and `ensure pfm-pause` after `pfm-core`. It also uses `pfm-ui` (server
settings, controller layout), `pfm-multicharacter` (Swap Character) and `pfm-adminmenu` (reports)
when they are running, and works without them.

## What it does

- **The menu** (left): the brand mark with its light, then Resume / Map / Controller / Swap
  Character / Game Settings / Server Settings / Help / Quit (`Config.Pause.Menu`), and the
  character, area and street at the bottom. Behind it the 3D map fills the screen, centred on you.
- **Map:** the menu slides away and the map is live. Drag to move, scroll to zoom, double-click for
  a waypoint (on the waypoint again clears it), V for 3D, right-drag to turn, C to centre, L for the
  legend (a click goes to the next blip of that kind). On a pad: left stick moves, triggers zoom,
  right stick turns and tilts, LB 3D, A waypoint, X centre, Y legend, B back. Blips, the waypoint,
  the GPS line and your position are read from the game while the menu is open. A waypoint set here
  is GTA's own.
- **Controller:** an Xbox controller with every button's job, on foot, in a vehicle and with LB
  held. The D-pad, LB (hold) and LB combos are pfm-ui's buttons and can be changed here; Reset puts
  the server's layout back.
- **Swap Character:** asks first, then saves and unloads the character and opens the character
  screen (the admin `/logout` path of pfm-multicharacter). Not while down or cuffed, with a cooldown,
  checked on the server too. Shown off with a note when pfm-multicharacter is not running.
- **Game Settings:** GTA's own settings menu. The menu comes back when it closes.
- **Server Settings:** every setting registered with pfm-ui's `DefinePref`, one tab per group:
  toggles, choices and sliders, forced ones locked, your own choices marked, a reset per tab.
- **Help:** the rules, the keys (keyboard and pad), shortcuts, and **Report a problem** (through
  pfm-adminmenu's `/report`: cleaned to one line, with a cooldown).
- **Quit:** asks first, then leaves the server (`QuitMode = 'disconnect'`) or closes the game
  (`'quit'`). Lua gives a one-time token with each question, and only a confirm with it acts.

## When it will not open

- another page has NUI focus, or let go of it less than `FocusCooldownMs` ago;
- GTA's own frontend is up;
- a page shown without focus says it is open (`BlockingExports`);
- the character is not loaded yet (character select keeps GTA's pause);
- the screen is faded out;
- the player is dead, only with `AllowWhileDead = false`.

## Config (`config.lua`, `Config.Pause`)

| Key | What |
|---|---|
| `Brand` | The mark's text (default `PF`). |
| `Menu` | The items in order: `{ id, label }`. |
| `OpenOnEscape`, `OpenOnP` | Which keys open it (`OpenOnP` covers Start too). |
| `RequireLogin`, `AllowWhileDead`, `FocusCooldownMs` | When it may open. |
| `BlurMs`, `HideHud`, `ReturnAfterFrontend` | Blur, HUD, coming back after GTA's screens. |
| `GameSettingsMenu`, `KeyBindingsMenu` | GTA frontend menus used. |
| `MapSkipSprites` | Blip sprites left off the map. |
| `SwapCharacter` | `Enabled`, `Resource`, `AllowWhileDead`, `AllowWhileCuffed`, `CooldownSec`, `DisabledNote`. |
| `QuitMode`, `DisconnectReason`, `AllowQuit` | Quit. |
| `Report` | `Enabled`, `Command`, `MinLength`, `MaxLength`, `CooldownSec`. |
| `BlockingExports` | `{ resource, export }` pairs; a truthy answer keeps the menu shut. |
| `QuickActions`, `Rules`, `Keybinds` | Help's shortcuts, rules and key list. |

## Exports and events

- `exports['pfm-pause']:IsOpen()`, `Open()`, `Close()`.
- `exports['pfm-pause']:AddQuickAction({ id, label, onSelect | command, order? })` and
  `RemoveQuickAction(id)`: shortcuts on the Help page (removed when their resource stops).
- Local events `pfm-pause:opened` and `pfm-pause:closed`.

## Development

- `html/preview.html` shows the page in a desktop browser with mock data (not sent to players).
  Serve the `[qb]` folder over http and open `pfm-pause/html/preview.html`.
- Tests: `cd tests && node harness.js pause` and `node tests/js/pause_menu_ui_spec.js`.
