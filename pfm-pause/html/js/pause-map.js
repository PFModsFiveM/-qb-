// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// PAUSE MAP — GTA's world in 3D, GTA's data drawn over it
//
// The pause menu's map (pause.js). The picture is 3D Clanker's 3D map —
// js/map3d/map3d.js, its data map/map3d-data.js in pfm-media-map: the 2D map's shapes and colours standing on the game's
// heights. Straight down and north up it IS the 2D map; tilted and turned (the pause map: V, a right-drag, a pad's LB
// and right stick) the buildings and hills stand up. On it go the player, the blips and the waypoint (elements of
// this page, placed on the picture), and the GPS line and a page's own lines (drawn by the 3D map, on the ground),
// read from the game by client/main.lua.
//
// ONE 3D MAP FOR THE PAGE. A WebGL map is a GPU's worth of buffers and a second of building, and the panel can show
// several maps at once (in the original). So there is one (gl, below), off the page: a map points it at its own view, draws, and copies
// the picture into a canvas of its own (draw). Each keeps its last picture. The HUD's minimap draws through it too
// (minimap.js).
//
// COORDINATES. "px0" is a pixel of the z0 tile (the whole map is 256 x 256 px0). The world maps on
// to it by a measured line — from the tile set's grid style, whose 100-unit lines sit 33.0 px apart
// at z4 with the world's 0,0 at z4 px 1877.5 x 2762. A view is a centre in px0 and a zoom: one px0
// is 2^zoom screen px. Then the 3D map's turn (yaw, GTA's sense: anticlockwise from north) and tilt
// (pitch, 90 = straight down). Straight down and north up ("flat"), everything is placed by that line, as it always
// was; turned or tilted, by the 3D map's own camera (project, pick).
//
// THE VIEW CENTRE CAN SIT OFF THE ELEMENT'S MIDDLE (offsetX): the map fills the whole screen, and with
// the legend open the centre is the middle of the part it leaves showing (pause.js mapOffset).
// Going full screen slides that offset to 0 — the map never changes size, so nothing snaps.
//
// DRAWN ON CHANGE, never in a loop: render() is asked for on a pan, a zoom or new data, and runs once
// on the next animation frame however many times it was asked.
//
// NO WEBGL: the 3D map does not start, and the map is the sea's black with the marks on it. One version only.
// ========================================

import { screenRect } from './pad-cursor.js';
import { assetUrl } from './utils.js';

/** px0 per world metre (toPx0's slope). Screen px per metre is K0 * 2^zoom. */
const K0 = 0.33 / 16;

/** The player is drawn this far behind the game, gliding between its readings (four a second). */
const PLAYER_LAG_MS = 300;
/** Readings further apart than this in time (the menu was shut) or space (a teleport) are not glided between. */
const READING_GAP_MS = 1000;
const TELEPORT_M = 200;

/** Into 3D (V, a pad's LB): tilted this far (degrees; 90 is straight down), eased over TILT_MS. A drag or the stick
 *  tilts no lower than MIN_PITCH. */
const TILT_PITCH = 55;
const MIN_PITCH = 25;
const TILT_MS = 450;
/** A right-drag: degrees of turn and of tilt per px. */
const DRAG_TURN = 0.3;
const DRAG_TILT = 0.25;

/** World (GTA X, Y) to px0. */
export function toPx0(x, y) {
    return [(1877.5 + 0.33 * x) / 16, (2762 - 0.33 * y) / 16];
}

/** px0 to world (GTA X, Y). */
export function toWorld(px, py) {
    return [(px * 16 - 1877.5) / 0.33, (2762 - py * 16) / 0.33];
}

const SVGNS = 'http://www.w3.org/2000/svg';
const WAYPOINT_COLOUR = '#a44cf2';   // GTA's own waypoint and route purple
const ROUTE_WIDTH = 5;               // px, the GPS line
const LINE_WIDTH = 4;                // px, a page's own lines 

// ---- the 3D map, one for the page ----
//
// Shared by every PauseMap and the HUD's minimap (minimap.js: whenMap3D, claimMap3D). Whoever draws next points it
// at their own view and gives it their own route and lines.

let gl = null;               // the Map3D every map draws through, once it is built
let glModule = null;         // map3d.js itself, once imported (the minimap's MinimapCamera)
let glState = 'idle';        // 'loading' | 'ready' | 'failed'
const glWaiting = [];        // maps that asked to draw before it was ready
const glReadyFns = [];       // whenMap3D's callers, waiting the same way
const glFailFns = [];        // ...and what each wants told if it never starts
let glOwner = null;          // who last pointed and drew it: a PauseMap, or 'minimap'
let glAimed = null;          // the view it is pointed at: { map, key }
let glLines = null;          // whose route and lines it holds: { map, route, lines }

/** fn(map, module) once the page's 3D map is built: at once if it is. If it did not start, never; `failed()` is
 *  called instead, when given (the spawn picker tells Lua so). */
export function whenMap3D(fn, failed) {
    loadGl();
    if (gl) fn(gl, glModule);
    else if (glState !== 'failed') { glReadyFns.push(fn); if (failed) glFailFns.push(failed); }
    else if (failed) failed();
}

/** `owner` is about to point and draw the 3D map: true when someone else had it last, whose view, route and lines are
 *  still in it (the owner sets its own again). */
export function claimMap3D(owner) {
    if (glOwner === owner) return false;
    glOwner = owner;
    glAimed = null;
    glLines = null;
    return true;
}

// ---- held: one owner has the 3D map to itself ----
//
// The spawn picker (spawn-pick.js) shows the map's own canvas full screen for as long as it is up. The minimap would
// otherwise draw into it at its own size and view the moment the load turns the HUD on (Josh, 31 Oct: the picker's
// picture flicked about and came back at 240p). While it is held nobody else draws; whoever was turned away draws
// again when it is let go.

let glHeld = null;
const glAfterHold = new Set();

/** `owner` has the 3D map to itself until letGoMap3D. */
export function holdMap3D(owner) {
    glHeld = owner;
    claimMap3D(owner);
}

export function letGoMap3D(owner) {
    if (glHeld !== owner) return;
    glHeld = null;
    const again = [...glAfterHold];
    glAfterHold.clear();
    for (const fn of again) fn();
}

/** May `owner` draw the 3D map now? Not while another holds it; `retry` then runs when it is let go. */
export function mayDrawMap3D(owner, retry) {
    if (glHeld === null || glHeld === owner) return true;
    if (retry) glAfterHold.add(retry);
    return false;
}

// ---- blip icons, for any map on the page ----

let tintDefs = null;         // one <svg><defs> for the page's blip colours (blipTint)
const tintIds = new Map();

/** A blip icon's colour filter: GTA's icons are drawn white with dark detail, and the game colours the white. So this
 *  MULTIPLIES — the icon's lightness times the blip's colour — and the dark lines stay dark (not flat silhouettes). */
export function blipTint(hex) {
    if (!hex) hex = '#ffffff';
    let id = tintIds.get(hex);
    if (!id) {
        if (!tintDefs) {
            const svg = document.createElementNS(SVGNS, 'svg');
            svg.classList.add('pmap-tints');
            tintDefs = document.createElementNS(SVGNS, 'defs');
            svg.appendChild(tintDefs);
            document.body.appendChild(svg);
        }
        id = 'pmap-tint-' + hex.slice(1);
        const rgb = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
        const row = (c) => [0.2126 * c, 0.7152 * c, 0.0722 * c, 0, 0].map((v) => v.toFixed(4)).join(' ');
        const f = document.createElementNS(SVGNS, 'filter');
        f.setAttribute('id', id);
        f.setAttribute('color-interpolation-filters', 'sRGB');
        f.innerHTML = '<feColorMatrix type="matrix" values="' + row(rgb[0]) + ' ' + row(rgb[1]) + ' ' + row(rgb[2]) + ' 0 0 0 1 0"/>';
        tintDefs.appendChild(f);
        tintIds.set(hex, id);
    }
    return 'url(#' + id + ')';
}

/** A blip's icon (img/blips/<sprite>.webp in its media pack) in its colour. */
export function blipImage(sprite, colour) {
    const img = document.createElement('img');
    img.className = 'pmap-blip';
    img.src = assetUrl('img/blips/' + sprite + '.webp');
    img.draggable = false;
    img.alt = '';
    img.style.filter = blipTint(colour) + ' drop-shadow(0 1px 2px rgba(0,0,0,.8))';
    // An icon FiveM's list has no picture for: a dot in the blip's colour instead.
    img.onerror = () => { img.onerror = null; img.classList.add('pmap-dot'); img.removeAttribute('src'); img.style.background = colour || '#fff'; img.style.filter = ''; };
    return img;
}

/** Load the data and build the 3D map, once for the page. three.js and the renderer are imported here, not at the
 *  page's load: the data's <script> first (a script, not a fetch, as gtav-map.js was: a media pack is another origin). */
function loadGl() {
    if (glState !== 'idle') return;
    glState = 'loading';
    const failed = (e) => {
        glState = 'failed';
        gl = null;
        glWaiting.length = 0;
        glReadyFns.length = 0;
        console.error('[pause map] the 3D map did not start; the map stays black:', e);
        for (const fn of glFailFns.splice(0)) {
            try { fn(e); } catch (err) { console.error('[pause map] a whenMap3D failed() threw:', err); }
        }
    };
    const s = document.createElement('script');
    s.src = assetUrl('map/map3d-data.js');
    s.onerror = () => failed(new Error('could not load ' + s.src));
    s.onload = () => {
        import('./map3d/map3d.js').then((mod) => {
            // Off the page (each map copies the picture: draw). antialias 2: a 2-sample target, about two thirds of the
            // canvas's own 4x MSAA in GPU memory (the 3D map's README, section 5).
            const m = new mod.Map3D(document.createElement('canvas'), { data: window.MAP3D_DATA, antialias: 2 });
            return m.ready.then(() => {
                window.MAP3D_DATA = null;   // the built map is all that is kept
                gl = m;
                glModule = mod;
                glState = 'ready';
                glFailFns.length = 0;   // built: nobody is told it failed
                // Each caller on its own: one that throws is logged, and the build stands for the rest (a throw here
                // would reach .catch(failed) below and black the map out for the session)
                for (const map of glWaiting.splice(0)) {
                    try { map.render(); } catch (err) { console.error('[pause map] a map\'s first draw threw:', err); }
                }
                for (const fn of glReadyFns.splice(0)) {
                    try { fn(gl, glModule); } catch (err) { console.error('[pause map] a whenMap3D ready() threw:', err); }
                }
            });
        }).catch(failed);
    };
    document.head.appendChild(s);
}

export class PauseMap {
    /** @param {HTMLElement} root  an empty element; the map fills it */
    constructor(root) {
        this.root = root;
        this.root.classList.add('pmap');
        this.cx = 128; this.cy = 128;    // the view's centre, px0
        this.offsetX = 0;                // where that centre sits, in screen px from the middle
        this.zoom = 3.5;
        this.yaw = 0;                    // the 3D map's turn, degrees (GTA's sense)
        this.pitch = 90;                 // ...and tilt: 90 is straight down
        this.turnable = false;           // a right-drag, the stick and setTilt may turn and tilt it (the pause map's)
        this.minZoom = 1.4;
        this.maxZoom = 7.5;              // the shapes are sharp all the way in
        this.interactive = false;
        this.data = { player: null, blips: [], route: null, waypoint: null, lines: [], routeColour: null };
        this.onWaypoint = null;           // (x, y) or (null) to clear — set by pause.js
        this.onBlipClick = null;
        this.onBlipDrag = null;           // (b, x, y, done): set, a left-drag that starts on a blip moves it (bind)

        // The picture: the 3D map's, copied in (draw).
        this.canvas = document.createElement('canvas');
        this.canvas.className = 'pmap-canvas';
        this.root.appendChild(this.canvas);
        this.ctx = this.canvas.getContext('2d', { alpha: false });
        this.marks = this.layer('pmap-marks');
        this.cross = this.layer('pmap-cross');   // the pad's aiming point, shown by CSS

        this.blipEls = [];

        this.waypointEl = this.blipImage(8, WAYPOINT_COLOUR);
        this.waypointEl.classList.add('pmap-waypoint');
        this.playerEl = document.createElement('div');
        this.playerEl.className = 'pmap-player';
        this.playerEl.innerHTML = '<svg viewBox="0 0 24 24"><path d="M12 2.5L19.5 20.5L12 16.6L4.5 20.5Z"/></svg>';

        this.pending = false;
        this.tween = null;
        this.tiltTween = null;            // setTilt() under way
        this.vel = [0, 0, 0, 0, 0];       // drive(): the pad's pan, zoom, turn and tilt speeds
        this.driving = false;
        this.onMove = null;               // each frame of drive(): returns a speed factor
        this.onSettle = null;             // drive() stopped
        this.slide = null;                // slideTo() under way
        this.picked = null;               // setPicked()
        this.blipSize = 22;               // px, as last drawn
        this.markScale = 1;               // how much bigger than a blip the marks are (1.35 with pictures: buildBlips)
        this.lastHit = null;              // the blip last clicked, and when: a double-click there is a waypoint on it
        this.track = [];                  // the player's last readings { x, y, heading, t } (playerPose)
        this.pose = null;                 // where the player is drawn now
        this.follow = false;              // the view rides with the drawn player — the menu's map (setFollow)
        this.tracking = false;            // the glide loop is running (startTracking)
        this.bind();

        loadGl();
        if (glState !== 'ready') glWaiting.push(this);
    }

    layer(cls) {
        const el = document.createElement('div');
        el.className = cls;
        this.root.appendChild(el);
        return el;
    }

    // ---- view ----

    setInteractive(on) {
        this.interactive = !!on;
        this.root.classList.toggle('pmap-live', this.interactive);
    }

    /** Out of sight (pause.js: behind the Controller and Settings screens): not drawn at all, so the page's one 3D
     *  map is left to what is on screen (the minimap's preview). Drawn again, as it is now, when it comes back. */
    setHidden(on) {
        this.hidden = !!on;
        if (!this.hidden) this.render();
    }

    /** Centre on a world point, at a zoom if given. */
    centreOn(x, y, zoom) {
        [this.cx, this.cy] = toPx0(x, y);
        if (typeof zoom === 'number') this.zoom = this.clampZoom(zoom);
        this.render();
    }

    centreOnPlayer(zoom) {
        const p = this.pose || this.data.player;
        if (p) this.centreOn(p.x, p.y, zoom);
    }

    /** Straight down and north up: the 2D map's own line places everything. */
    flat() {
        return this.pitch >= 89.95 && Math.abs(this.yaw) < 1e-6;
    }

    /** Tilted at all (V's state). */
    tilted() {
        return this.pitch < 89.95;
    }

    /** The 3D map pointed at this map's view, at its size. Cheap when it already is. */
    aim(W = this.root.clientWidth, H = this.root.clientHeight) {
        claimMap3D(this);
        const dpr = window.devicePixelRatio || 1;
        const key = [this.cx, this.cy, this.zoom, this.offsetX, this.yaw, this.pitch, W, H, dpr].join();
        if (glAimed && glAimed.map === this && glAimed.key === key) return;
        glAimed = { map: this, key };
        if (gl.W !== W || gl.H !== H || gl.dpr !== dpr) gl.resize(W, H, dpr);
        const [x, y] = toWorld(this.cx, this.cy);
        gl.setView({ x, y, pxPerMetre: K0 * 2 ** this.zoom, offsetX: this.offsetX, offsetY: 0,
            yaw: this.yaw, pitch: this.pitch, heightScale: 1 });
    }

    /** Into 3D — tilted, keeping the turn — or back to the 2D map: straight down, north up. Eased over TILT_MS, or at
     *  once. Nothing to tilt before the 3D map is built (or if it never is). */
    setTilt(on, instant) {
        if (!gl || !this.turnable) on = false;
        const to = on ? { yaw: this.yaw, pitch: TILT_PITCH } : { yaw: 0, pitch: 90 };
        if (instant || !gl) {
            this.tiltTween = null;
            this.yaw = to.yaw; this.pitch = to.pitch;
            this.render();
            return;
        }
        const from = { yaw: this.yaw, pitch: this.pitch };
        const dyaw = ((to.yaw - from.yaw) % 360 + 540) % 360 - 180;   // the short way round
        const start = performance.now();
        const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
        const id = {};
        this.tiltTween = id;
        const tick = (now) => {
            if (this.tiltTween !== id) return;
            const t = Math.min(1, (now - start) / TILT_MS), e = ease(t);
            this.yaw = t < 1 ? from.yaw + dyaw * e : to.yaw;
            this.pitch = t < 1 ? from.pitch + (to.pitch - from.pitch) * e : to.pitch;
            this.draw();
            if (t < 1) requestAnimationFrame(tick); else this.tiltTween = null;
        };
        requestAnimationFrame(tick);
    }

    /** Turn by `dyaw` degrees and tilt by `dpitch` (down toward the horizon is negative). */
    turnBy(dyaw, dpitch) {
        if (!gl || !this.turnable) return;
        this.tiltTween = null;
        this.yaw = ((this.yaw + dyaw) % 360 + 540) % 360 - 180;
        this.pitch = Math.max(MIN_PITCH, Math.min(90, this.pitch + dpitch));
        this.render();
    }

    // ---- the player, glided ----
    //
    // The game says where the player is four times a second. The arrow is drawn PLAYER_LAG_MS behind the game, sliding between
    // the two readings either side of that moment every frame, and the menu's map rides along (follow).

    /** Where the player is drawn at `now`: between the readings either side of now - PLAYER_LAG_MS,
     *  the heading turned the short way round. */
    playerPose(now) {
        const tr = this.track;
        if (!tr.length) return this.data.player;
        const t = now - PLAYER_LAG_MS;
        if (t <= tr[0].t) return tr[0];
        for (let i = 1; i < tr.length; i++) {
            const a = tr[i - 1], b = tr[i];
            if (t > b.t) continue;
            const u = (t - a.t) / Math.max(1, b.t - a.t);
            const dh = ((b.heading - a.heading) % 360 + 540) % 360 - 180;
            return { x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u, heading: a.heading + dh * u };
        }
        return tr[tr.length - 1];
    }

    /** A reading arrived. After a gap (the menu was shut) or a jump (a teleport), start afresh rather
     *  than glide across the map. */
    addReading(p) {
        const now = performance.now();
        const r = { x: p.x, y: p.y, heading: p.heading || 0, t: now };
        const last = this.track[this.track.length - 1];
        if (last && (now - last.t > READING_GAP_MS || Math.hypot(r.x - last.x, r.y - last.y) > TELEPORT_M)) this.track = [];
        this.track.push(r);
        if (this.track.length > 4) this.track.shift();
        if (this.track.length === 1) this.pose = r;
        this.startTracking();
    }

    /** One frame at a time while the drawn player is still catching up with the last reading. The
     *  menu's map is redrawn round it; the live map only moves the arrow. */
    startTracking() {
        if (this.tracking) return;
        this.tracking = true;
        let drawn = null;
        const tick = (now) => {
            const pose = this.playerPose(now);
            const last = this.track[this.track.length - 1];
            const moved = !drawn || pose.x !== drawn.x || pose.y !== drawn.y || pose.heading !== drawn.heading;
            this.pose = pose;
            if (moved) {
                if (this.follow && !this.slide) {
                    [this.cx, this.cy] = toPx0(pose.x, pose.y);
                    this.draw();
                } else {
                    this.placePlayer(pose);
                }
                drawn = pose;
            }
            if (last && pose !== last) requestAnimationFrame(tick);
            else this.tracking = false;
        };
        requestAnimationFrame(tick);
    }

    /** Follow the player (the menu's map) or not (the live map, which stays where it is). */
    setFollow(on) {
        this.follow = !!on;
    }

    /** The player's arrow at a pose. */
    placePlayer(p) {
        this.playerEl.style.display = p ? '' : 'none';
        if (!p) return;
        const [sx, sy] = this.screenOf(p.x, p.y);
        // GTA's heading turns anticlockwise from north; the screen's rotation clockwise. Less the map's own turn.
        this.playerEl.style.transform = 'translate(' + sx + 'px,' + sy + 'px) rotate(' + (this.yaw - p.heading) + 'deg)';
    }

    clampZoom(z) { return Math.max(this.minZoom, Math.min(this.maxZoom, z)); }

    /** The screen point the view's centre is drawn at. */
    middle() {
        return [this.root.clientWidth / 2 + this.offsetX, this.root.clientHeight / 2];
    }

    /** Slide the view's centre to `x` px from the middle, and the zoom to `zoom`, over `ms`. */
    glide(x, zoom, ms) {
        const from = { x: this.offsetX, zoom: this.zoom };
        const to = { x, zoom: typeof zoom === 'number' ? this.clampZoom(zoom) : this.zoom };
        const start = performance.now();
        const ease = (t) => 1 - Math.pow(1 - t, 3);
        const id = {};
        this.tween = id;
        const tick = (now) => {
            if (this.tween !== id) return;
            const t = Math.min(1, (now - start) / ms);
            const e = ease(t);
            this.offsetX = from.x + (to.x - from.x) * e;
            this.zoom = from.zoom + (to.zoom - from.zoom) * e;
            this.draw();
            if (t < 1) requestAnimationFrame(tick); else this.tween = null;
        };
        requestAnimationFrame(tick);
    }

    /** Zoom by `dz` keeping the screen point (sx, sy) where it is (the view's centre if not given). Turned or tilted,
     *  always about the centre. */
    zoomBy(dz, sx, sy) {
        if (!this.flat()) {
            this.zoom = this.clampZoom(this.zoom + dz);
            this.render();
            return;
        }
        const [mx, my] = this.middle();
        if (sx === undefined) { sx = mx; sy = my; }
        const before = 2 ** this.zoom;
        const px = this.cx + (sx - mx) / before, py = this.cy + (sy - my) / before;
        this.zoom = this.clampZoom(this.zoom + dz);
        const after = 2 ** this.zoom;
        this.cx = px - (sx - mx) / after;
        this.cy = py - (sy - my) / after;
        this.render();
    }

    /** Pan by screen pixels. A slide under way stops: the player is moving the map. */
    panBy(dx, dy) {
        this.slide = null;
        const s = 2 ** this.zoom;
        let ux = dx / s, uy = dy / s;   // how far the picture moved, px0
        if (!this.flat()) {
            // Along the screen, which runs across the ground at the map's turn; a tilt squeezes the ground's up and down
            // by sin(pitch). The 3D map's camera is orthographic, so this is the same everywhere on the screen.
            const a = this.yaw * Math.PI / 180, sinP = Math.sin(this.pitch * Math.PI / 180);
            const r = dx / s, u = -dy / s / sinP;   // along the screen's right and up, px0 on the ground
            ux = r * Math.cos(a) - u * Math.sin(a);
            uy = -(r * Math.sin(a) + u * Math.cos(a));
        }
        this.cx = Math.max(0, Math.min(256, this.cx - ux));
        this.cy = Math.max(0, Math.min(256, this.cy - uy));
        this.render();
    }

    /** Keep moving: pan at `vx, vy` screen px a second (right and down positive), zoom at `vz` levels a second, and
     *  turn at `vyaw` / tilt at `vpitch` degrees a second, a little each frame, until called with them all 0. A pad's
     *  sticks and triggers (pause.js). */
    drive(vx, vy, vz, vyaw = 0, vpitch = 0) {
        this.vel = [vx, vy, vz, vyaw, vpitch];
        if (this.driving || this.vel.every((v) => !v)) return;
        this.driving = true;
        let last = performance.now();
        const tick = (now) => {
            const [x, y, z, ty, tp] = this.vel;
            if (!x && !y && !z && !ty && !tp) {
                this.driving = false;
                if (this.onSettle) this.onSettle();
                return;
            }
            const dt = Math.min(0.05, (now - last) / 1000);   // a stalled frame does not leap
            last = now;
            const slow = this.onMove ? this.onMove() : 1;     // pause.js: slower over a blip
            if (z) this.zoomBy(z * dt);
            if (ty || tp) this.turnBy(ty * dt, tp * dt);
            if (x || y) this.panBy(-x * dt * slow, -y * dt * slow);
            requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
    }

    /** Slide the view's centre to a world point over `ms` (onto a blip: a snap, a click). */
    slideTo(x, y, ms) {
        const [tx, ty] = toPx0(x, y), fx = this.cx, fy = this.cy;
        const start = performance.now();
        const id = {};
        this.slide = id;
        const tick = (now) => {
            if (this.slide !== id) return;
            const t = Math.min(1, (now - start) / ms), e = 1 - Math.pow(1 - t, 3);
            this.cx = fx + (tx - fx) * e;
            this.cy = fy + (ty - fy) * e;
            this.draw();
            if (t < 1) requestAnimationFrame(tick); else this.slide = null;
        };
        requestAnimationFrame(tick);
    }

    /** The blip nearest the screen point (sx, sy) within `r` px, or null. */
    blipNear(sx, sy, r) {
        let best = null, bd = r;
        for (const b of this.data.blips) {
            const [x, y] = this.screenOf(b.x, b.y);
            const d = Math.hypot(x - sx, y - sy);
            if (d <= bd) { bd = d; best = b; }
        }
        return best;
    }

    /** The blip under a pointer or mouse event, as a click finds it (picture marks are bigger, so further out), or null. */
    blipUnder(e) {
        const [sx, sy] = this.localOf(e);
        return this.blipNear(sx, sy, this.blipSize * (this.markScale || 1) / 2 + 4);
    }

    /** Ring one blip (pause.js: the one the pad's centre is on, or clicked), or none. */
    setPicked(b) {
        this.picked = b || null;
        for (const el of this.blipEls) el.classList.toggle('pmap-blip-on', !!b && el._blip === b);
    }

    /** Screen point -> world, or null: tilted, a point above the horizon is on no ground. */
    worldAt(sx, sy) {
        if (this.flat() || !gl) {
            const [mx, my] = this.middle(), s = 2 ** this.zoom;
            return toWorld(this.cx + (sx - mx) / s, this.cy + (sy - my) / s);
        }
        this.aim();
        const p = gl.pick(sx, sy);
        return p ? [p.x, p.y] : null;
    }

    /** The ground's height at a world point, from the 3D map's heights; null before it is built (or if it never is). */
    groundAt(x, y) {
        return gl ? gl.heightAt(x, y) : null;
    }

    /** A pointer or mouse event's point in the map's own px: a map inside a zoomed page
     *  is drawn bigger than its own px say. Its box measured in screen px on either browser (CEF 103 measures it
     *  unzoomed). */
    localOf(e) {
        const r = screenRect(this.root), k = (r.width / (this.root.clientWidth || r.width)) || 1;
        return [(e.clientX - r.left) / k, (e.clientY - r.top) / k];
    }

    /** World -> screen point (on the ground there, turned or tilted). */
    screenOf(x, y) {
        if (this.flat() || !gl) {
            const [mx, my] = this.middle(), s = 2 ** this.zoom;
            const [px, py] = toPx0(x, y);
            return [(px - this.cx) * s + mx, (py - this.cy) * s + my];
        }
        this.aim();
        const p = gl.project(x, y);
        return [p.sx, p.sy];
    }

    // ---- data ----

    /** Whatever arrived; missing fields keep what was there. */
    setData(d) {
        if (d.player) { this.data.player = d.player; this.addReading(d.player); }
        if ('waypoint' in d) this.data.waypoint = d.waypoint || null;
        if ('route' in d) this.data.route = d.route || null;
        if (typeof d.routeColour === 'string' && d.routeColour !== this.data.routeColour) {
            // The game's waypoint colour (client/main.lua): GTA's HUD_COLOUR_WAYPOINT, as the radar draws it.
            this.data.routeColour = d.routeColour;
            this.tintWaypoint();
        }
        if ('lines' in d) this.data.lines = Array.isArray(d.lines) ? d.lines : [];   // [{ points: [[x, y], ...], colour }]
        if (d.blips) { this.data.blips = d.blips; this.buildBlips(); }
        this.render();
    }

    /** The waypoint's mark in the route's colour (its dot too, when the icon is missing). */
    tintWaypoint() {
        const colour = this.data.routeColour || WAYPOINT_COLOUR;
        const el = this.waypointEl;
        if (el.classList.contains('pmap-dot')) el.style.background = colour;
        else el.style.filter = blipTint(colour) + ' drop-shadow(0 1px 2px rgba(0,0,0,.8))';
    }

    /** A blip's colour filter (blipTint) and icon (blipImage, above): pause.js's legend draws its icons through these. */
    tint(hex) { return blipTint(hex); }

    blipImage(sprite, colour) { return blipImage(sprite, colour); }

    /** A mark drawn from one of the page's own glyphs (an SVG, ours, never data), for what GTA has no blip icon for: a
     *  scenario's NPC, car, prop, door. A dark disc with the glyph in white, the size of a blip. */
    glyphMark(svg) {
        const el = document.createElement('span');
        el.className = 'pmap-blip pmap-glyph';
        el.innerHTML = svg;
        return el;
    }

    /** A mark with the thing's own picture (b.pic: a car's, an NPC's, a prop's), round and a little bigger than a
     *  blip, over its glyph mark: where the picture is missing, the glyph is what shows. b.fit 'face': a ped's
     *  picture (the whole of them, standing) closed in on the head; else the whole picture fits. b.frame: a framed
     *  portrait ({ x, y, z }, a lore character's), placed as the phone places it. */
    pictureMark(b) {
        const el = this.glyphMark(b.glyph || '');
        el.classList.add('pmap-pic', b.fit === 'face' && !b.frame ? 'pmap-pic-face' : 'pmap-pic-whole');
        const img = document.createElement('img');
        img.alt = '';
        img.draggable = false;
        if (b.frame) {
            img.style.objectFit = 'cover';
            img.style.objectPosition = `${b.frame.x}% ${b.frame.y}%`;
            img.style.transformOrigin = `${b.frame.x}% ${b.frame.y}%`;
            img.style.transform = `scale(${b.frame.z})`;
        }
        img.onload = () => el.classList.add('pmap-pic-on');
        img.onerror = () => img.remove();
        img.src = b.pic;
        el.appendChild(img);
        return el;
    }

    buildBlips() {
        for (const el of this.blipEls) el.remove();
        // Picture marks are bigger, so a click finds them further out (bind's click).
        this.markScale = this.data.blips.some((b) => b.pic) ? 1.35 : 1;
        this.blipEls = this.data.blips.map((b) => {
            const el = b.pic ? this.pictureMark(b) : b.glyph ? this.glyphMark(b.glyph) : this.blipImage(b.sprite, b.colour);
            el.title = b.name || '';
            this.marks.appendChild(el);
            el._blip = b;
            return el;
        });
        this.marks.appendChild(this.waypointEl);
        this.marks.appendChild(this.playerEl);
    }

    // ---- drawing ----

    render() {
        if (this.pending) return;
        this.pending = true;
        requestAnimationFrame(() => { this.pending = false; this.draw(); });
    }

    /** The 3D map's big buffers let go (pause.js, on the menu's close): it shrinks to nothing until a map draws again. */
    static release() {
        if (!gl) return;
        gl.resize(1, 1, 1);
        glOwner = null;
        glAimed = null;
        glLines = null;
    }

    /** The 3D map holds one map's route and lines at a time: this one's, if they were another map's or have changed. */
    syncLines() {
        const d = this.data;
        const colour = d.routeColour || WAYPOINT_COLOUR;
        if (glLines && glLines.map === this && glLines.route === d.route && glLines.lines === d.lines
            && glLines.colour === colour) return;
        glLines = { map: this, route: d.route, lines: d.lines, colour };
        gl.setRoute(d.route && d.route.length > 1 ? d.route : null, colour, ROUTE_WIDTH);
        gl.setLines((d.lines || []).filter((l) => l && Array.isArray(l.points) && l.points.length > 1)
            .map((l) => ({ points: l.points, colour: l.colour || colour, width: LINE_WIDTH })));
    }

    draw() {
        const W = this.root.clientWidth, H = this.root.clientHeight;
        if (!W || !H || this.hidden) return;
        if (gl && mayDrawMap3D(this, () => this.render())) {
            // The 3D map at this view, drawn, and its picture copied into this map's own canvas (it is off the page).
            this.aim(W, H);
            this.syncLines();
            gl.render();
            const dpr = window.devicePixelRatio || 1, cw = Math.round(W * dpr), ch = Math.round(H * dpr);
            if (this.canvas.width !== cw || this.canvas.height !== ch) { this.canvas.width = cw; this.canvas.height = ch; }
            this.ctx.drawImage(gl.canvas, 0, 0, cw, ch);
        }

        // Blips: a little bigger as the map does, within reason.
        const size = Math.round(Math.max(18, Math.min(30, 13 + this.zoom * 3)));
        if (size !== this.blipSize) this.root.style.setProperty('--pmap-blip', size + 'px');
        this.blipSize = size;
        for (const el of this.blipEls) {
            const [sx, sy] = this.screenOf(el._blip.x, el._blip.y);
            const off = sx < -40 || sy < -40 || sx > W + 40 || sy > H + 40;
            el.style.display = off ? 'none' : '';
            if (!off) el.style.transform = 'translate(' + sx + 'px,' + sy + 'px)';
        }

        const wp = this.data.waypoint;
        this.waypointEl.style.display = wp ? '' : 'none';
        if (wp) {
            const [sx, sy] = this.screenOf(wp.x, wp.y);
            this.waypointEl.style.transform = 'translate(' + sx + 'px,' + sy + 'px)';
        }

        this.placePlayer(this.pose || this.data.player);   // the glided pose (startTracking)

        // The pad's aiming point sits on the view's centre, wherever that is.
        const [mx] = this.middle();
        this.cross.style.setProperty('--pmap-cx', mx + 'px');
    }

    // ---- input ----

    bind() {
        let drag = null, turn = null, down = null;
        this.root.addEventListener('pointerdown', (e) => {
            down = { x: e.clientX, y: e.clientY };
            if (!this.interactive) return;
            // The right button turns and tilts the pause map (left and right turn it, up tilts it toward the horizon).
            if (e.button === 2 && this.turnable && gl) {
                turn = { x: e.clientX, y: e.clientY };
                this.root.setPointerCapture(e.pointerId);
                return;
            }
            if (e.button !== 0) return;
            // On a blip that can be moved: the blip moves (the mousedown below), not the map.
            if (this.onBlipDrag && this.blipUnder(e)) return;
            drag = { x: e.clientX, y: e.clientY, moved: 0 };
            this.root.setPointerCapture(e.pointerId);
            this.root.classList.add('pmap-dragging');
        });
        // Moving a blip: mouse events, not pointer ones, so the controller's circle (which sends those) moves it too.
        // It moves once the pointer has, by more than a click's wobble; let go, and its place is told (done).
        this.root.addEventListener('mousedown', (e) => {
            if (!this.interactive || !this.onBlipDrag || e.button !== 0) return;
            const b = this.blipUnder(e);
            if (!b) return;
            e.preventDefault();
            const from = { x: e.clientX, y: e.clientY };
            down = from;   // the circle sends no pointerdown: its click on the blip still picks it (the click, below)
            let moving = false;
            const move = (ev) => {
                if (!moving && Math.hypot(ev.clientX - from.x, ev.clientY - from.y) <= 4) return;
                moving = true;
                this.root.classList.add('pmap-moving');
                const at = this.worldAt(...this.localOf(ev));
                if (!at) return;
                [b.x, b.y] = at;
                this.render();
                this.onBlipDrag(b, b.x, b.y, false);
            };
            const up = () => {
                document.removeEventListener('mousemove', move, true);
                document.removeEventListener('mouseup', up, true);
                this.root.classList.remove('pmap-moving');
                if (moving) this.onBlipDrag(b, b.x, b.y, true);
            };
            document.addEventListener('mousemove', move, true);
            document.addEventListener('mouseup', up, true);
        });
        this.root.addEventListener('pointermove', (e) => {
            if (turn) {
                const dx = e.clientX - turn.x, dy = e.clientY - turn.y;
                turn.x = e.clientX; turn.y = e.clientY;
                this.turnBy(-dx * DRAG_TURN, dy * DRAG_TILT);
                return;
            }
            if (!drag) return;
            const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
            drag.x = e.clientX; drag.y = e.clientY; drag.moved += Math.abs(dx) + Math.abs(dy);
            this.panBy(dx, dy);
        });
        const end = () => { drag = null; turn = null; this.root.classList.remove('pmap-dragging'); };
        this.root.addEventListener('pointerup', end);
        this.root.addEventListener('pointercancel', end);
        this.root.addEventListener('contextmenu', (e) => { if (this.turnable) e.preventDefault(); });
        this.root.addEventListener('wheel', (e) => {
            if (!this.interactive) return;
            e.preventDefault();
            const r = this.root.getBoundingClientRect();
            this.zoomBy(-e.deltaY * 0.0022, e.clientX - r.left, e.clientY - r.top);
        }, { passive: false });
        // A click on a blip (not the end of a drag): found by distance, as a drag's pointer capture
        // sends the click to the map rather than to the blip under it.
        this.root.addEventListener('click', (e) => {
            if (!this.onBlipClick || !down || Math.hypot(e.clientX - down.x, e.clientY - down.y) > 6) return;
            const b = this.blipUnder(e);
            if (!b) return;
            e.stopPropagation();   // not also the menu's "click the map to open it"
            this.lastHit = { b, t: performance.now(), x: e.clientX, y: e.clientY };
            this.onBlipClick(b);
        });
        this.root.addEventListener('dblclick', (e) => {
            if (!this.interactive || !this.onWaypoint) return;
            // On a blip: the waypoint goes on the blip, though the first click slid it to the middle.
            const hit = this.lastHit;
            if (hit && performance.now() - hit.t < 600 && Math.hypot(e.clientX - hit.x, e.clientY - hit.y) < 8) {
                const [sx, sy] = this.screenOf(hit.b.x, hit.b.y);
                this.waypointAt(sx, sy);
                return;
            }
            const r = this.root.getBoundingClientRect();
            this.waypointAt(e.clientX - r.left, e.clientY - r.top);
        });
    }

    /** A waypoint at a screen point — or, on the waypoint itself, none (as GTA does). Above the horizon of a tilted map
     *  there is no ground, and nothing happens. */
    waypointAt(sx, sy) {
        const wp = this.data.waypoint;
        if (wp) {
            const [wx, wy] = this.screenOf(wp.x, wp.y);
            if (Math.hypot(wx - sx, wy - sy) < 16) {
                this.data.waypoint = null; this.data.route = null; this.render();
                this.onWaypoint(null);
                return;
            }
        }
        const at = this.worldAt(sx, sy);
        if (!at) return;
        const [x, y] = at;
        this.data.waypoint = { x, y };
        this.render();
        this.onWaypoint(x, y);
    }
}
