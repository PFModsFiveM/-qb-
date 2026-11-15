// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// NUI ROUTER — action dispatch + keyboard scopes (the original's router.js, unchanged in its code)
//
// Each module REGISTERS its own actions here at load, so the handler bodies live beside the
// state they touch. Dispatch is a Map, and actions are MULTI-SUBSCRIBER (an array per name,
// invoked in registration order).
//
// KEYBOARD SCOPES: a scope is { name, priority, isOpen, onKey }: on keydown, scopes are walked in
// ascending priority and THE FIRST ONE WHOSE isOpen() RETURNS TRUE CONSUMES THE KEY.
//
// CONTROLLER SCOPES RIDE THE SAME LIST. A scope may also carry `onNav`, and navigation arrives through
// handleNav() with the identical walk. A GAMEPAD PRODUCES NO KEYBOARD EVENTS: the pad is read in
// client/main.lua and arrives here as INTENT ('up', 'select', 'back'), never as a synthesised keypress.
// A scope may also ask for the sticks and triggers as numbers (`analog`, `onAnalog`): the pause map.
//
// In this resource there is one scope, the pause menu's (pause.js, priority 4); js/main.js feeds it.
// ========================================

export const NuiRouter = (function () {
    const actions = new Map();     // action name -> [fn, fn, ...]
    const keyScopes = [];          // sorted ascending by priority

    function register(action, fn) {
        let list = actions.get(action);
        if (!list) { list = []; actions.set(action, list); }
        list.push(fn);
    }

    function dispatch(data) {
        const list = actions.get(data && data.action);
        if (!list) return;
        // Each subscriber in its own try — actions are multi-subscriber by design (the
        // vehicle HUD message feeds two files), so one throwing handler must not starve
        // the ones registered after it. Same isolation the emitter gives its listeners;
        // the console line names the action so the broken subscriber is findable.
        for (let i = 0; i < list.length; i++) {
            try {
                list[i](data);
            } catch (err) {
                console.error(`[router] subscriber ${i} for "${data.action}" threw:`, err);
            }
        }

        // Panels open and close in response to messages, so this is where almost every nav-scope
        // change actually happens — which is also why it is THROTTLED here and forced elsewhere:
        // most messages are not panel opens, and the dials alone are twenty a second.
        syncNavScope();
    }

    function registerKeyScope(scope) {
        keyScopes.push(scope);
        keyScopes.sort((a, b) => a.priority - b.priority);
    }

    /** The first open scope, whatever it is. One walk, used by both input paths. */
    function topScope() {
        for (let i = 0; i < keyScopes.length; i++) {
            if (keyScopes[i].isOpen()) return keyScopes[i];
        }
        return null;
    }

    function handleKey(e) {
        const s = topScope();
        if (s && s.onKey) s.onKey(e);
        syncNavScope(true);     // this press may be what closed the panel
    }

    /* Controller navigation. Same walk as handleKey, same modal semantics: the topmost open
       scope consumes the input whether or not it does anything with it. `mods` says what was held
       under the press — { rb } (the inventory's RB + A shift-click); a scope that does not care
       never reads it. */
    function handleNav(nav, mods) {
        const s = topScope();
        if (s && s.onNav) s.onNav(nav, mods || {});
        syncNavScope(true);     // 'back' may be what just closed the panel
    }

    /** Name of the topmost open scope, but ONLY if it can actually handle a controller.
     *
     *  RETURNING null FOR AN UNCONVERTED PANEL IS THE POINT, not an oversight. Lua reads this to
     *  decide whether to take the pad over — and taking it over means disabling gameplay controls
     *  and holding NUI focus open. Do that for a panel with no onNav and a controller player is
     *  sealed inside a screen with no way to move and no way to leave. Answering null instead
     *  leaves that panel exactly as it is today: keyboard and mouse, nothing worse. */
    function activeNavScope() {
        const s = topScope();
        return (s && s.onNav) ? s.name : null;
    }

    /** Does the topmost scope want the pad's stick and triggers as numbers rather than as directions?
     *  A scope says so with `analog` (true, or a function for one that wants it only sometimes — the
     *  pause menu's map) and takes them in `onAnalog`. Lua then stops turning the stick into
     *  up/down/left/right for it and sends the positions instead (client/controller.lua). */
    function activeNavAnalog() {
        const s = topScope();
        if (!s || !s.onNav || !s.onAnalog) return false;
        return typeof s.analog === 'function' ? !!s.analog() : !!s.analog;
    }

    /** The sticks and triggers, { x, y, lt, rt, rx, ry }, to the topmost scope if it wants them. */
    function handleAnalog(a) {
        const s = topScope();
        if (s && s.onAnalog && activeNavAnalog()) s.onAnalog(a);
    }

    /** The topmost scope's pad hints — [[button, label], ...] — when it takes a pad; controller.js
     *  draws them as the hint strip. `padHints` is an array, or a function for a scope whose
     *  buttons change with what it shows (the dialogs). */
    function activeNavHints() {
        const s = topScope();
        if (!s || !s.onNav || !s.padHints) return null;
        return typeof s.padHints === 'function' ? s.padHints() : s.padHints;
    }

    /** How the topmost scope wants its hints to look: 'bare' (no pill, faint words under the screen's own
     *  column, a dot between; the character screen and the spawn picker), or null for the strip as it is. A scope says
     *  so with `padHintsLook` (a string, or a function). */
    function activeNavHintsLook() {
        const s = topScope();
        if (!s || !s.onNav || !s.padHintsLook) return null;
        return typeof s.padHintsLook === 'function' ? s.padHintsLook() : s.padHintsLook;
    }

    /* A scope whose hints change with no press — the Director's, as its circle moves over a card, a pin,
       a field — says so here, and the strip is drawn again at once rather than on its half-second
       backstop. The strip skips a redraw that would draw the same, so this is cheap to call. */
    const hintListeners = [];
    function onHintsChange(fn) { hintListeners.push(fn); }
    function hintsChanged() {
        for (let i = 0; i < hintListeners.length; i++) {
            try { hintListeners[i](); } catch (err) { console.error('[router] hints listener threw:', err); }
        }
    }

    /* ---- change notification ----
       Listeners are told when the answer to activeNavScope() changes, so client/controller.lua
       can start and stop the pad driver without polling across the NUI boundary. Evaluated after
       anything that could plausibly open or close a panel; controller.js adds a slow interval as
       a backstop for state that changes with no message and no keypress at all. */
    const scopeListeners = [];
    let lastNavScope;   // undefined until the first sync, so the first real answer always fires

    function onNavScopeChange(fn) { scopeListeners.push(fn); }

    /* COALESCED, because dispatch() calls this and dispatch runs on EVERY inbound message —
       including the vehicle dials, which are up to twenty a second while driving. The walk itself
       is cheap (a handful of property reads; nothing here forces layout), but "cheap × every
       message forever" is how a frame budget disappears without any one thing looking wrong.

       100ms is far below anything a person notices in a panel taking the pad, and it puts a hard
       ceiling on the cost no matter how chatty the message stream gets.

       FORCED FOR REAL INPUT. A keypress or a nav press may be the thing that opened or closed the
       panel, so those paths skip the throttle — that answer has to be current immediately. */
    let lastSyncAt = 0;
    let trailingSync = null;

    function syncNavScope(force) {
        if (!force) {
            const t = Date.now();
            if (t - lastSyncAt < 100) {
                /* AND A TRAILING CALL: a panel that opened inside 100ms of another message must
                   still be synced, or a pad's B could reach the game until the 500ms backstop.
                   One sync is scheduled for the end of the window. */
                if (!trailingSync) {
                    trailingSync = setTimeout(function () {
                        trailingSync = null;
                        syncNavScope(false);
                    }, 100 - (t - lastSyncAt));
                }
                return;
            }
            lastSyncAt = t;
        }

        const now = activeNavScope();
        const analog = now !== null && activeNavAnalog();
        const key = now === null ? null : now + (analog ? '+analog' : '');
        if (key === lastNavScope) return;
        lastNavScope = key;
        for (let i = 0; i < scopeListeners.length; i++) {
            try {
                scopeListeners[i](now, analog);
            } catch (err) {
                console.error('[router] nav scope listener threw:', err);
            }
        }
    }

    return {
        register, dispatch, registerKeyScope, handleKey,
        handleNav, activeNavScope, activeNavHints, activeNavHintsLook, onNavScopeChange, syncNavScope,
        activeNavAnalog, handleAnalog, onHintsChange, hintsChanged,
    };
})();
