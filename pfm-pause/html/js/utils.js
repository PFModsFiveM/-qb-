// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// UTILS — the few helpers the pause menu's modules share (the original's utils.js, cut down)
//
// nuiCallback posts to this resource's own Lua (GetParentResourceName), not to a framework core.
// assetUrl points at the map's media resource (pfm-media-map): the blip icons and the 3D map data.
// ========================================

/** This page's resource: FiveM's GetParentResourceName, or the name the preview gives. */
export function resourceName() {
    try {
        if (typeof globalThis.GetParentResourceName === 'function') return globalThis.GetParentResourceName();
    } catch (e) { /* not in FiveM */ }
    return 'pfm-pause';
}

/** POST to this resource's Lua (RegisterNUICallback); its answer, or {} when there is none. */
export function nuiCallback(name, data) {
    return fetch('https://' + resourceName() + '/' + name, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data || {}),
    }).then((r) => r.json()).catch(() => ({}));
}

// ---- where the map's pictures and data live ----

// The preview page sets window.PF_PAUSE_MEDIA_URL before the modules load (the map starts loading at once).
let assetBase = typeof globalThis.PF_PAUSE_MEDIA_URL === 'string' && globalThis.PF_PAUSE_MEDIA_URL
    ? globalThis.PF_PAUSE_MEDIA_URL.replace(/\/?$/, '/') : 'https://cfx-nui-pfm-media-map/';

/** The media resource's base URL (config: Config.Pause.MediaUrl, or the preview's local copy). */
export function setAssetBase(url) {
    if (typeof url === 'string' && url) assetBase = url.endsWith('/') ? url : url + '/';
}

/** A file in the map's media resource: img/blips/<id>.webp, map/map3d-data.js. */
export function assetUrl(path) {
    return assetBase + path;
}

/**
 * Text made safe to put in HTML — in an element OR an attribute value.
 *
 * QUOTES TOO, AND 0 IS "0": a value inside `data-x="…"` or `title="…"` must not close the
 * attribute, and the number 0 is not ''.
 */
export function escapeHtml(str) {
    if (str === null || str === undefined) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}
