# pfm-ui

Controller (gamepad) support for the PF framework, plus small shared UI assets.
The controller code is ported from WHIP (LGPL-3.0, see NOTICE.md).

`ensure pfm-ui` before the resources that use it. They still work without it running: keyboard
and mouse are unchanged, and the bridge falls back to its defaults.

## Why it works this way

- A NUI page cannot read a gamepad, and `SendNUIMessage` only reaches the calling resource's own
  page. So each resource reads the pad for its own page with `lib/pad_bridge.lua`, and the page
  receives intents (`up`, `down`, `left`, `right`, `select`, `back`, `buttonX`, `buttonY`, `tabPrev`,
  `tabNext`, `triggerLeft`, `triggerRight`) through `html/pad.js`.
- FiveM key mappings never fire from a pad. Outside menus pfm-ui reads the frontend controls every
  frame while a pad is the device and runs the action the button layout puts on each button.

## Adopting it in a resource (3 steps)

1. **fxmanifest.lua**: include the bridge before your client files.

   ```lua
   client_scripts { '@pfm-ui/lib/pad_bridge.lua', 'client/main.lua' }
   ```

2. **Lua**: attach when your page takes focus, detach when it gives it back.

   ```lua
   SetNuiFocus(true, true)
   if PadBridge then PadBridge.attach({ active = function() return menuOpen end }) end
   -- on close:
   SetNuiFocus(false, false)
   if PadBridge then PadBridge.detach() end
   ```

   Pass `keepInput = true` if you already call `SetNuiFocusKeepInput(true)` yourself, and
   `enable = { 30, 31 }` to let the player walk while your page is open.

3. **Page**: load the library and say what the buttons do.

   ```html
   <link rel="stylesheet" href="https://cfx-nui-pfm-ui/html/pad.css" />
   <script src="https://cfx-nui-pfm-ui/html/pad.js"></script>
   ```

   ```js
   if (window.PfmPad) {
       // default: a focus ring moves among buttons/inputs/[data-pad] in the panel, A clicks, B closes
       PfmPad.focusables(panel, { onBack: closePanel, autoFocus: true });
       // or your own handling; return false to fall back to the default
       PfmPad.on("buttonX", () => useSelected());
   }
   ```

   `body.pfm-pad` is set while a pad is the device: use `.pfm-pad-only` / `.pfm-kbm-only` or
   `PfmPad.hints(el, [["select", "Choose"], ["back", "Close"]])` to show button hints, and
   `PfmPad.glyph("select")` for a single button picture.

Outside a NUI page, `PadBridge.padNow()` tells a resource whether the last input was a pad (for
example to cancel a bar with B: `IsControlJustPressed(0, 202) and PadBridge.padNow()`).

## Default layout (outside menus)

| Button | Action |
|---|---|
| D-pad up | Phone (`phone`) |
| D-pad down | Radial menu (`radialmenu`) |
| D-pad left | Focus a menu shown without focus (`playerfocus`, pfm-menu) |
| D-pad right | Inventory (`openInv`) |
| Hold LB | Target / interact (`+playerTarget`), A opens the options |
| LB + Y | Emote menu (`emotemenu`, when an emote resource registers it) |

Change it in `config.lua` (`Config.Pad.Layout`). Players change their own with `/padbind <slot>
<action|none>`, `/padreset` and `/padlayout`; only the buttons that differ from the server default
are saved, so a player who never changes anything follows the server.

Other resources add actions:

```lua
exports['pfm-ui']:RegisterPadAction('engine', { label = 'Engine', command = 'engine', slot = 'lb_x' })
```

## Settings

`/padprefs` lists them, `/padset <key> <value>` changes one: `pad.enabled`, `pad.repeatDelay`,
`pad.repeatRate`, `pad.stickNav`. Exports: `DefinePref`, `GetPref`, `SetPref`, `ResetPref`,
`GetPrefs`. The server can force a value for everyone in `Config.ForcedPrefs` or with
`setr pfm_ui_forced "pad.enabled=false"`.

## Exports

`IsPadActive()` (settled), `IsPadActiveNow()`, `GetLayout()`, `SetLayoutSlot(slot, action)`,
`ResetLayout()`, `RegisterPadAction(id, def)`, `RemovePadAction(id)`, `GetPadActionButton(id)`,
`GetLayoutState()` (the layout, every action `{ id, label }` and whether the player changed any: pfm-pause's Controller screen).
Local event: `pfm-ui:padChanged` (pad), `pfm-ui:prefChanged` (key, value).
