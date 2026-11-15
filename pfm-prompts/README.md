# pfm-prompts

In-world interaction prompts: walk up to a door and the key to press and what it does are drawn on the door
itself. The 3D renderer is a port of WHIP's (see `NOTICE.md`): textured quads in the world, depth-tested, so a
wall hides a prompt and it never lags the camera.

- **Distant** prompts (within `showDistance`) are a faint ring.
- **In reach** (within `distance`) a brighter ring.
- **Focused** (one at a time: the one you look at, else the nearest in reach) fills and shows the key, with the
  label beside it. Only the focused prompt reacts to the key.
- A prompt with **nothing to press** (its `canInteract` says no) shows its sublabel and icon in reach, never the
  key: a locked door you have no key for says "Locked".

Start it before the resources that use it (`ensure pfm-prompts`); a resource that adds prompts before it is
running should check `GetResourceState('pfm-prompts') == 'started'` and add them on `onClientResourceStart`.

## Client API

All calls are client-side exports. Ids are per resource (two resources may both use `'door1'`), and every
prompt a resource added is removed when that resource stops.

```lua
exports['pfm-prompts']:Add(id, def)        -- true, or false and a reason
exports['pfm-prompts']:Update(id, patch)   -- merge fields into the definition
exports['pfm-prompts']:Remove(id)
exports['pfm-prompts']:RemoveAllFor(resource) -- also done automatically on resource stop
exports['pfm-prompts']:Exists(id)
exports['pfm-prompts']:Flash(id, r, g, b)  -- flash the badge in a colour (an answer)
exports['pfm-prompts']:GetFocused()        -- id, owner resource of the focused prompt, or nil
exports['pfm-prompts']:GetRenderer()       -- 'world' or 'screen'
```

### Definition

One anchor:

| Field | |
|---|---|
| `coords = vector3` | a fixed point |
| `entity = handle` | follows the entity |
| `netId = n` | follows a networked entity while it exists here |
| `model = hash or name` | every object of that model near the player (searched once a second) |
| `door = id or hash` | a pfm-doorlock door: its id in the door list, or its door-system hash |

Then:

| Field | Default | |
|---|---|---|
| `offset = vector3` | none | added to `coords`; for an entity, in the entity's own space |
| `label` | | what the key does: `'Unlock'` |
| `sublabel` | | beside it, lighter: `'Locked'`; shown alone when there is nothing to press |
| `key` | `'E'` | the key's label on a keyboard (the game's own name for the control wins when it has one) |
| `control` | `38` | the GTA control the key reads (works on a pad too: GTA maps controls to pad buttons) |
| `distance` | `Config.Distance` (2.0) | the reach the key works in |
| `showDistance` | `Config.ShowDistance` (6.0) | the range the prompt is drawn in (capped at `Config.MaxShowDistance`) |
| `holdMs` | none | hold the key this long to use it (a ring fills round the badge) |
| `canInteract = function(id, option, entity)` | none | false hides the action |
| `onPress = function(id, info)` | | called on the press (`info = { option, entity, coords }`) |
| `onPress = 'server:event'`, `args = {...}` | | or a server event, triggered with `args` |
| `clientEvent = 'client:event'` | | a client event, with `args` |
| `icon` | | a glyph shown when there is nothing to press: `lock`, `unlock`, `lockpick`, `door`, `pickup`, `cash`, `bag`, `info`, `warning`, `success`, `fail`, `dot` |
| `image` | | a picture above the label while focused (`nui://resource/path.png`) |
| `scale` | 1.0 | size multiplier |
| `options = { {...}, {...} }` | | several options on one spot; each takes the fields above (`label` to `image`), the definition's own as defaults. They cycle with the mouse wheel (controls 16 / 17) or the D-pad on a pad |

Functions passed to an export arrive in pfm-prompts as function references: pfm-prompts calls them (under
`pcall`; one that throws counts as "no" and is reported once), it never tests their type. `canInteract` is
asked about 15 times a second while the prompt is in sight, and once more at the press: keep it cheap.

`canInteract` decides only what is shown and whether the key does anything. **A server event must still check
everything itself** (who, where, what they hold).

### Examples

A point with one action:

```lua
exports['pfm-prompts']:Add('stash', {
    coords = vector3(452.1, -980.2, 30.7),
    label = 'Open stash',
    distance = 1.5,
    canInteract = function() return PlayerData.job.name == 'police' end,
    onPress = function() TriggerServerEvent('my-stash:server:open') end,
})
```

Several options on an entity, one held:

```lua
exports['pfm-prompts']:Add('atm', {
    model = `prop_atm_01`,
    offset = vector3(0.0, -0.2, 1.0),
    options = {
        { label = 'Use ATM', onPress = 'my-bank:server:openAtm' },
        { label = 'Rob ATM', key = 'G', control = 47, holdMs = 3000, icon = 'warning',
          canInteract = function() return HasItem('drill') end, onPress = 'my-bank:server:robAtm' },
    },
})
```

State without an action:

```lua
exports['pfm-prompts']:Add('gate', { coords = gatePos, label = 'Open', sublabel = 'Closed', icon = 'lock',
    canInteract = function() return hasKey end, onPress = openGate })
exports['pfm-prompts']:Update('gate', { label = 'Close', sublabel = 'Open', icon = 'unlock' })
```

## Keys and pads

On a keyboard the badge shows the key the game reports for the control (`GetControlInstructionalButton`:
`t_E` shows E), else the prompt's `key`. On a pad (pfm-ui's `IsPadActive()` when pfm-ui is started, else
`IsUsingKeyboard(0) == false`) it shows a pad glyph: the game reports a pad button as an id (`b_NNN`), and
`Config.PadButtonIds` maps ids to glyphs; any other falls back to GTA's default pad layout for the control
(38 INPUT_PICKUP = LB, 51 INPUT_CONTEXT = D-pad right, 23 INPUT_ENTER = Y, ...). `/pfmprompts_glyph <control>`
prints what the game reports, to fill in `Config.PadButtonIds`. The screen renderer draws `~INPUT_...~`, which the
game itself turns into the right button.

## Renderers

`Config.Renderer` (or `setr pfm_prompts_renderer world|screen`):

- **world**: two quads per prompt (badge and label) sampled from three DUI browsers however many prompts there
  are: a badge atlas (every glyph in every state; a state change is a UV change), a label atlas (8 rows, repainted
  only when a row's words change) and a preview picture (made the first time a prompt has an `image`). Sized from
  the camera FOV so the badge is `Config.World.badgePx` tall at the prompt's own reach.
- **screen**: the fallback, used automatically if the game refuses the DUI textures: 2D text and a key box at
  the projected point. Not hidden by walls.

`/pfmprompts_renderer world|screen` switches live to compare.

## Performance

- Scoring runs about every 66 ms while a prompt is near (15 Hz), every 250 ms otherwise. It reads only the 25 m
  grid cells round the player (9 cells at the default 25 m cap); prompts further than their `showDistance` cost a
  distance check. Entity and model prompts are checked each score frame; the object pool is searched once a second
  and only when a model prompt exists.
- Drawing runs every frame while something is visible and makes no tables, strings or closures (scalars only,
  entries reused). A prompt costs two `DrawTexturedPoly` calls for its badge (four during a 110 ms crossfade), two
  for a label, two per stacked option, and 160 while a hold ring fills.
- The loop sleeps 500 ms with no prompts registered.
