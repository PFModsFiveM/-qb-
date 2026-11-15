-- pfm-pause settings. Shared (client and server read it).

Config = Config or {}

Config.Pause = {
    -- The brand mark drawn in the logo's place, top left (a short wordmark; up to 24 characters).
    Brand = 'PF',

    -- The menu, top to bottom. Ids: resume, map, controller, swap, gameSettings, serverSettings, help, quit.
    -- Leave one out to hide it. A label may be changed: { id = 'quit', label = 'Leave' }.
    Menu = {
        { id = 'resume',         label = 'Resume' },
        { id = 'map',            label = 'Map' },
        { id = 'controller',     label = 'Controller' },
        { id = 'swap',           label = 'Swap Character' },
        { id = 'gameSettings',   label = 'Game Settings' },
        { id = 'serverSettings', label = 'Server Settings' },
        { id = 'help',           label = 'Help' },
        { id = 'quit',           label = 'Quit' },
    },

    -- Which keys open the menu. Escape is INPUT_FRONTEND_PAUSE_ALTERNATE (200); P and a pad's Start are
    -- INPUT_FRONTEND_PAUSE (199). Both are held off every frame so GTA's own pause never opens.
    OpenOnEscape = true,
    OpenOnP = true,          -- also a pad's Start (the same control)

    -- Do not take over before the character is loaded (character select and loading keep GTA's pause).
    RequireLogin = true,

    -- Allow the menu while dead or in last stand. pf-ambulancejob's death screen does not use Escape, so
    -- this is on; set false if your death screen needs the pause keys.
    AllowWhileDead = true,

    -- After another page lets go of NUI focus, wait this long before a pause key may open the menu: the
    -- Escape that closed the inventory must not also open the pause menu.
    FocusCooldownMs = 350,

    -- Blur the game behind the menu (ms for the fade in and out). 0 turns the blur off.
    BlurMs = 200,

    -- Hide GTA's radar and HUD components while the menu is open.
    HideHud = true,

    -- Come back to the menu after GTA's settings or key bindings close.
    ReturnAfterFrontend = true,

    -- GTA's own screens opened in the menu's place.
    GameSettingsMenu = 'FE_MENU_VERSION_LANDING_MENU',
    KeyBindingsMenu = 'FE_MENU_VERSION_LANDING_KEYMAPPING_MENU',

    -- The map: blips, the player and the waypoint are read from the game while the menu is open.
    -- Blips with these sprites are left off (the player's own arrow, north, the waypoint, radius circles...).
    MapSkipSprites = { 4, 5, 6, 7, 8, 9, 10, 161, 163, 164 },

    -- Swap Character: back to the character screen (pfm-multicharacter), as the admin /logout does.
    -- Shown off, with a note, when pfm-multicharacter is not running.
    SwapCharacter = {
        Enabled = true,
        Resource = 'pfm-multicharacter',
        AllowWhileDead = false,      -- no swapping out of a death or last stand
        AllowWhileCuffed = false,    -- nor out of handcuffs
        CooldownSec = 30,            -- per player, on the server
        DisabledNote = 'The character screen is not available right now.',
    },

    -- Quit. 'disconnect': leave the server (dropped with DisconnectReason); 'quit': close the game.
    QuitMode = 'disconnect',
    DisconnectReason = 'Disconnected from the pause menu. See you soon!',
    AllowQuit = true,        -- false: QuitMode 'quit' is refused

    -- Report a problem: sent through pfm-adminmenu's /report command (staff see it in chat, and it is
    -- logged). Set false to hide the button.
    Report = {
        Enabled = true,
        Command = 'report',     -- the existing command; the message is its argument
        MinLength = 8,
        MaxLength = 300,
        CooldownSec = 60,
    },

    -- Other resources that show a page without NUI focus (or keep game input) and must keep Escape.
    -- Checked only while the resource is started; any that answers truthy blocks the menu.
    BlockingExports = {
        { resource = 'pf-tablet',        export = 'IsTabletOpen' },
        { resource = 'pf-computer',      export = 'IsComputerOpen' },
        { resource = 'pf-emsmdt',        export = 'IsMDTOpen' },
        { resource = 'pf-policemdt-DEV', export = 'IsMDTOpen' },
        { resource = 'pf-devices',       export = 'GetOpenShell' },
    },

    -- Shortcuts on the Help page (more can be added with exports['pfm-pause']:AddQuickAction).
    -- command: a command to run after the menu closes. requires: only shown when that resource is started.
    -- action = 'keybinds': GTA's key bindings.
    QuickActions = {
        { id = 'hud',     label = 'HUD settings',   icon = 'sliders', command = 'hud', requires = 'pf-hud' },
        { id = 'keys',    label = 'Key bindings',   icon = 'keyboard', action = 'keybinds' },
    },

    -- Help page.
    Rules = {
        'Respect every player. No harassment, hate speech or discrimination, in or out of character.',
        'Stay in character. Use /ooc sparingly and never to share information your character does not know.',
        'Value your life. Act as if your character fears injury and death.',
        'No random deathmatch (RDM) or vehicle deathmatch (VDM). Violence needs a roleplay reason.',
        'No metagaming or powergaming. Streams, Discord and voice from outside the city are not your character\'s knowledge.',
        'No exploiting bugs, mods or cheats. Report bugs under Help, Report a problem.',
        'Staff decisions are final in the moment; appeal calmly on Discord afterwards.',
    },

    -- Key cheat sheet: { action, keyboard, pad }. Pad names: A B X Y LB RB LT RT Start Back D-Up D-Down
    -- D-Left D-Right LS RS (shown as button pictures).
    Keybinds = {
        { 'Pause menu',          'Esc / P',  'Start' },
        { 'Inventory',           'TAB',      'D-Right' },
        { 'Phone',               'M',        'D-Up' },
        { 'Radial menu',         'F1',       'D-Down' },
        { 'Target / interact',   'Left Alt', 'LB (hold)' },
        { 'Talk (push to talk)', 'N',        '' },
        { 'Voice range',         'Z',        '' },
        { 'Seatbelt',            'B',        '' },
        { 'Engine',              'G',        '' },
        { 'Lock vehicle',        'L',        '' },
        { 'HUD settings',        '/hud',     '' },
        { 'Emote menu',          'F3',       'LB + Y' },
    },

    -- Shown on Server Settings when pfm-ui is not running.
    NoPrefsNote = 'Server settings come from pfm-ui. It is not running right now, so there is nothing to change here.',
}
