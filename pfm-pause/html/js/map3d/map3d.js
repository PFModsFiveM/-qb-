// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF (names only).
// The 3D map: the 2D map's shapes (gtav-map.js: same shapes, colours and paint order) standing on the game's
// heights (pfm-media-map/map/map3d-data.js; built by the 3D map's build/ scripts). One WebGL canvas, drawn on demand only.
//
//   import { Map3D, MinimapCamera, K0 } from './map3d/map3d.js';
//   const map = new Map3D(container, { data: window.MAP3D_DATA });   // builds in slices: await map.ready
//   map.resize(W, H, dpr); map.setView({ x, y, pxPerMetre, offsetX, offsetY, yaw, pitch }); map.render();
//   map.setMarker({ x, y, z, rotDeg, sizePx }); map.render();   // the player arrow; hidden parts as an outline
//   map.setCamera({ x, y, z, rotX, rotY, rotZ, fov }); map.render();   // a GTA camera's own view (perspective)
//   map.setPin({ x, y, z, heading }); map.render();               // the spawn beacon + ring (renderPin(): its light only)
//
// TOP-DOWN (pitch 90) is today's map: an orthographic camera straight down, SCREEN PX PER METRE = K0 * 2^zoom, the
// palette of pause-map.js unlit, and each shape's paint order as its depth, so overlaps come out as the 2D painter's.
// TILTED, the depth is real: a depth pass of the terrain, the buildings and the raised road decks; the buildings and
// decks in colour; then every ground layer in paint order, lying exactly on the terrain (cut to its triangles) and not
// writing depth. The land is the terrain mesh itself (every land grey is the one land colour); the terrain and the
// walls are shaded only when tilted, so top-down keeps the exact palette.
// Everything is cut into squares (CHUNK) and each layer kind is one THREE.BatchedMesh: three culls every square against
// the view and draws a batch's visible squares in one call (WEBGL_multi_draw; without it, one call per square).
import * as THREE from 'three';

export const K0 = 0.33 / 16;                 // pause-map.js: screen px per world metre at zoom 0

// ---- the map's colours (pause-map.js: C, GREYS, mapColour) ----
const C = {
    land: [17, 20, 25], build: [43, 48, 58], build2: [53, 59, 71], path: [76, 83, 96],
    road: [126, 134, 147], hwy: [164, 172, 186], deep: [8, 14, 23], shore: [24, 39, 58],
};
const mix = (a, b, t) => [0, 1, 2].map((i) => Math.round(a[i] + (b[i] - a[i]) * Math.max(0, Math.min(1, t))));
const GREYS = [[35, C.land], [65, C.build], [99, C.build2], [130, C.path], [180, C.road], [220, C.hwy]];
export function mapColour([r, g, b]) {
    if (b > r + 6) return mix(C.deep, C.shore, ((r + g + b) / 765 - 0.25) / 0.62);
    const v = (r + g + b) / 3;
    if (v <= GREYS[0][0]) return GREYS[0][1];
    for (let i = 1; i < GREYS.length; i++) {
        if (v <= GREYS[i][0]) return mix(GREYS[i - 1][1], GREYS[i][1], (v - GREYS[i - 1][0]) / (GREYS[i][0] - GREYS[i - 1][0]));
    }
    return C.hwy;
}
const DEEP_SRC = [0, 20, 60];         // pack.py's colour for the sea's deepest (the 2D map's background)
const SEA = 0, LAND = 1, BUILD = 2, PATH = 3, ROAD = 4, HWY = 5;
function kindOf([r, g, b]) {
    if (b > r + 6) return SEA;
    const v = (r + g + b) / 3;
    if (v <= 35) return LAND;
    if (v < 130) return BUILD;
    if (v < 131) return PATH;
    return v <= 180 ? ROAD : HWY;
}

// ---- tuning ----
// the island in squares (ground layers, solids, terrain), each layer kind one BatchedMesh: three culls every square
// against the view and draws a batch's visible squares in one call (WEBGL_multi_draw). Rounded to whole terrain cells
// (40 m), on the grid's origin: a ground piece then never crosses a square's edge, and the ground pass (which paints in
// order, not by depth) keeps every square's pieces in rank order
const CHUNK = 480;            // measured (v6): the minimap draws 4-10x fewer triangles than v5's 3 km chunks, same calls
const SLAB = 1.5;             // a building shape the rays found no top for: a low slab, m
const DECK_LIFT = 0.3;        // a deck never comes closer to the ground than this, m
const DECK_DEPTH = 1.6;       // a deck's sides: this deep under its road surface, m
const DECK_SHADE = 0.8775;    // a v4 deck's shade: level ground's (Ground.shadeAt on the flat), so a deck and the road it joins match
const SKIRT_STEP = 8;         // a deck's sides follow its height in pieces this long, m
const SLICE_MS = 4;           // the build gives the page back this often
const B64_PIECE = 1 << 17;    // base64 characters decoded at a time (a multiple of 4)
const FAR = 30000;
const MARK_ABOVE = 1.5;       // the marker counts as hidden by surfaces more than this over the player, m
const MARK_PAD = 2;           // the marker's texture: the 24-unit box plus this much room for its stroke, each side
const MARK_TEX = 128;         // ... drawn at this many px
const MARKER = { sizePx: 22, path: 'M12 2.5 L19.5 20.5 L12 16.6 L4.5 20.5 Z', fill: '#f2f4f7', stroke: 'rgba(8,10,14,0.9)',
    strokePx: 1.6, outline: '#f2f4f7', outlinePx: 1.6, halo: 'rgba(8,10,14,0.9)' };
const PERSP_FAR = 80000;      // setCamera's far plane, m: the whole island from far out
const PIN_FRAC = 0.075;       // the spawn pin's height on screen, as a share of the canvas height
const PIN_SEG = 48;           // the ring and shadow round it: this many pieces
const PIN = { ring: 0.92 };     // the ring's alpha
// the spawn beacon, in the old pin's heights (1 = PIN_FRAC of the screen): a column of light this tall, its three
// layers (radius, how sharply it falls off to the sides, strength), the glow at its foot, the specks rising in it
const BEACON = { height: 4.2, layers: [[0.11, 2.0, 0.32], [0.045, 1.6, 0.5], [0.016, 0.8, 0.75]], colour: [0.92, 0.95, 1.0],
    glow: 0.62, glowK: 0.5, glowCol: [0.875, 0.914, 1.0], hot: 0.17, motes: 9, moteSize: 0.05, moteMs: 2600, moteRise: 1.7 };

// ---- data (pack.py's format, meta.v 3 or 4: v4's decks are 3D rings from the game's collision) ----
async function decode(data, breathe) {
    // the base64 in pieces (a multiple of 4 characters each), so no one step holds the page
    const meta = data.meta, b64 = data.bin, pad = b64.endsWith('==') ? 2 : b64.endsWith('=') ? 1 : 0;
    const u8 = new Uint8Array(b64.length / 4 * 3 - pad);
    for (let c = 0, o = 0; c < b64.length; c += B64_PIECE) {
        const s = atob(b64.slice(c, c + B64_PIECE));
        for (let i = 0; i < s.length; i++) u8[o++] = s.charCodeAt(i);
        await breathe('decode bytes');
    }
    const g = meta.grid, sec = meta.sections, dv = new DataView(u8.buffer);
    const t16 = new Int16Array(u8.buffer, sec.terrain, g.nx * g.ny);
    const h = new Float32Array(g.nx * g.ny);
    for (let i = 0; i < h.length; i++) h[i] = t16[i] / 10;
    const landcells = u8.subarray(sec.landcells, sec.shapes);
    let p = sec.shapes;
    const varint = () => { let v = 0, sh = 0, b; do { b = u8[p++]; v += (b & 0x7f) * 2 ** sh; sh += 7; } while (b & 0x80); return v; };
    const unzz = (v) => (v % 2 ? -(v + 1) / 2 : v / 2);
    const ring = () => {
        const n = varint(), pts = new Float64Array(n * 2);
        let x = 0, y = 0;
        for (let j = 0; j < n; j++) { x += unzz(varint()); y += unzz(varint()); pts[j * 2] = g.x0 + x / 10; pts[j * 2 + 1] = g.y0 + y / 10; }
        return pts;
    };
    const kinds = meta.colours.map(kindOf);
    const shapes = new Array(meta.shapes);
    for (let i = 0; i < meta.shapes; i++) {
        const col = u8[p++], flags = u8[p++];
        let polys;
        if (flags & 4) {
            polys = [];
            for (let a = varint(); a > 0; a--) { const rs = []; for (let b = varint(); b > 0; b--) rs.push({ pts: ring(), off: null }); polys.push(rs); }
        } else {
            const r = { pts: ring(), off: null };
            if (flags & 1) { const n = r.pts.length / 2; r.off = new Float32Array(n); for (let j = 0; j < n; j++, p += 2) r.off[j] = dv.getUint16(p, true) / 10; }
            polys = [[r]];
        }
        let level = 0;
        if (flags & 2) { level = dv.getUint16(p, true) / 10; p += 2; }
        let bottom = 0;
        if (flags & 128) { bottom = dv.getUint16(p, true) / 10; p += 2; }      // a building part over a passage
        let deck = null;
        if (flags & 16 && meta.v >= 4) {
            // decks (v4, from the game's collision): pieces of 3D rings, each point its road surface height and
            // whether its edge to the next point is a seam with another deck part (no side drawn there)
            deck = [];
            for (let c = varint(); c > 0; c--) {
                const polys2 = [];
                for (let a = varint(); a > 0; a--) {
                    const rs = [];
                    for (let b = varint(); b > 0; b--) {
                        const pts = ring(), n = pts.length / 2, xyz = new Array(n * 3), seam = new Uint8Array(n);
                        for (let j = 0; j < n; j++, p += 2) { xyz[j * 3] = pts[j * 2]; xyz[j * 3 + 1] = pts[j * 2 + 1]; xyz[j * 3 + 2] = dv.getUint16(p, true) / 10 - 100; }
                        for (let j = 0; j < n; j++) seam[j] = (u8[p + (j >> 3)] >> (j & 7)) & 1;
                        p += (n + 7) >> 3;
                        rs.push({ xyz, seam });
                    }
                    polys2.push(rs);
                }
                deck.push({ v4: polys2 });
            }
        } else if (flags & 16) {
            // decks: the shape's raised lanes (polylines of x, y, road surface z), then its pieces: the shape cut to
            // those lanes, each with the lanes its height comes from (its own first)
            const lanes = [];
            for (let a = varint(); a > 0; a--) {
                const n = varint(), L = new Float64Array(n * 3);
                let x = 0, y = 0;
                for (let j = 0; j < n; j++) { x += unzz(varint()); y += unzz(varint()); L[j * 3] = g.x0 + x / 10; L[j * 3 + 1] = g.y0 + y / 10; }
                for (let j = 0; j < n; j++, p += 2) L[j * 3 + 2] = dv.getUint16(p, true) / 10 - 100;
                lanes.push(L);
            }
            deck = [];
            for (let c = varint(); c > 0; c--) {
                const polys2 = [], own = [];
                for (let a = varint(); a > 0; a--) { const rs = []; for (let b = varint(); b > 0; b--) rs.push({ pts: ring(), off: null }); polys2.push(rs); }
                for (let a = varint(); a > 0; a--) own.push(lanes[varint()]);
                deck.push({ polys: polys2, lanes: own });
            }
        }
        // flags 32: drawn top-down only (inside a knot); 64: drawn tilted only (a knot's ribbon)
        shapes[i] = { col, kind: kinds[col], polys, level, drape: !!(flags & 8), top: 0, deck, topOnly: !!(flags & 32), tiltOnly: !!(flags & 64), bottom };
        if ((i & 63) === 0) await breathe('decode shapes');
    }
    p = sec.tops;
    for (const sh of shapes) if (sh.kind === BUILD) { sh.top = dv.getUint16(p, true) / 10; p += 2; }
    return { meta, grid: { ...g, h }, landcells, shapes };
}

// the ground: the terrain grid every meta.drape samples, each cell two triangles split along its (0,0)-(1,1) diagonal
class Ground {
    constructor(g, drape, landcells) {
        this.D = g.step * drape; this.x0 = g.x0; this.y0 = g.y0;
        this.nx = Math.floor((g.nx - 1) / drape) + 1; this.ny = Math.floor((g.ny - 1) / drape) + 1;
        this.h = new Float32Array(this.nx * this.ny);
        for (let j = 0; j < this.ny; j++) for (let i = 0; i < this.nx; i++) this.h[j * this.nx + i] = g.h[j * drape * g.nx + i * drape];
        this.cnx = this.nx - 1; this.cny = this.ny - 1; this.landcells = landcells;
    }
    H(i, j) { return this.h[Math.min(this.ny - 1, Math.max(0, j)) * this.nx + Math.min(this.nx - 1, Math.max(0, i))]; }
    land(i, j) { const k = j * this.cnx + i; return i >= 0 && j >= 0 && i < this.cnx && j < this.cny && (this.landcells[k >> 3] >> (k & 7)) & 1; }
    /** the ground's height at (x, y): the plane of the triangle it falls in (the mesh's own surface) */
    at(x, y) {
        const gx = (x - this.x0) / this.D, gy = (y - this.y0) / this.D;
        const i = Math.min(this.nx - 2, Math.max(0, Math.floor(gx))), j = Math.min(this.ny - 2, Math.max(0, Math.floor(gy)));
        return this.plane(i, j, gx - i, gy - j);
    }
    plane(i, j, u, v) {
        const h00 = this.H(i, j), h10 = this.H(i + 1, j), h11 = this.H(i + 1, j + 1), h01 = this.H(i, j + 1);
        return v <= u ? h00 + (h10 - h00) * u + (h11 - h10) * v : h00 + (h11 - h01) * u + (h01 - h00) * v;
    }
    /** a shade for the slope at a grid point: light from the north-west, 0.55 .. 1 */
    shadeAt(i, j) {
        const dx = (this.H(i + 1, j) - this.H(i - 1, j)) / (2 * this.D), dy = (this.H(i, j + 1) - this.H(i, j - 1)) / (2 * this.D);
        const nz = 1 / Math.hypot(dx, dy, 1);
        const l = (0.45 * dx - 0.45 * dy + 0.77) * nz;      // . (-0.45, 0.45, 0.77)
        return Math.max(0.55, Math.min(1, 0.3 + 0.75 * l));
    }
    shade(x, y) {
        const gx = Math.round((x - this.x0) / this.D), gy = Math.round((y - this.y0) / this.D);
        return this.shadeAt(gx, gy);
    }
}

// growing typed arrays for one mesh
class Buf {
    // starts small (a few hundred squares x five layers each) and doubles as it fills
    constructor(size = 1 << 8) {
        this.p = new Float32Array(3 * size); this.c = new Uint8Array(size); this.s = new Uint8Array(size); this.r = new Uint16Array(size);
        this.i = new Uint32Array(2 * size); this.n = 0; this.m = 0;
    }
    vert(x, y, z, col, shade, rank) {
        if (this.n === this.c.length) {
            const g = (a) => { const b = new a.constructor(a.length * 2); b.set(a); return b; };
            this.p = g(this.p); this.c = g(this.c); this.s = g(this.s); this.r = g(this.r);
        }
        const i = this.n++;
        this.p[i * 3] = x; this.p[i * 3 + 1] = y; this.p[i * 3 + 2] = z;
        this.c[i] = col; this.s[i] = Math.round(shade * 255); this.r[i] = rank;
        return i;
    }
    tri(a, b, c) {
        if (this.m + 3 > this.i.length) { const b2 = new Uint32Array(this.i.length * 2); b2.set(this.i); this.i = b2; }
        this.i[this.m++] = a; this.i[this.m++] = b; this.i[this.m++] = c;
    }
    geometry() {
        if (!this.m) return null;
        const g = new THREE.BufferGeometry(), n = this.n;
        g.setAttribute('position', new THREE.BufferAttribute(this.p.slice(0, n * 3), 3));
        g.setAttribute('aCol', new THREE.BufferAttribute(this.c.slice(0, n), 1));
        g.setAttribute('aShade', new THREE.BufferAttribute(this.s.slice(0, n), 1, true));
        g.setAttribute('aRank', new THREE.BufferAttribute(this.r.slice(0, n), 1));
        g.setIndex(new THREE.BufferAttribute(this.i.slice(0, this.m), 1));
        g.computeBoundingBox(); g.computeBoundingSphere();
        this.p = this.c = this.s = this.r = this.i = null;
        return g;
    }
}

// Sutherland-Hodgman against a half-plane a*x + b*y + c >= 0; a ring is a flat array x, y, o, x, y, o, ...
// (o = a deck's height above the ground, interpolated along the cut)
function clipHalf(r, a, b, c) {
    const n = r.length / 3, out = [];
    if (!n) return out;
    let px = r[(n - 1) * 3], py = r[(n - 1) * 3 + 1], po = r[(n - 1) * 3 + 2], dp = a * px + b * py + c;
    for (let i = 0; i < n; i++) {
        const qx = r[i * 3], qy = r[i * 3 + 1], qo = r[i * 3 + 2], dq = a * qx + b * qy + c;
        if ((dp >= 0) !== (dq >= 0)) { const t = dp / (dp - dq); out.push(px + (qx - px) * t, py + (qy - py) * t, po + (qo - po) * t); }
        if (dq >= 0) out.push(qx, qy, qo);
        px = qx; py = qy; po = qo; dp = dq;
    }
    return out;
}
const ringBox = (r) => {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (let i = 0; i < r.length; i += 3) { const x = r[i], y = r[i + 1]; if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    return [x0, y0, x1, y1];
};
// a polygon (outer ring + holes, flat x, y, o arrays) as triangles: [[a, b, c], ...] into its own vertex list
function triangulate(rings) {
    const vs = [], holes = [];
    rings.forEach((r, k) => {
        const list = [];
        for (let i = 0; i < r.length; i += 3) list.push(new THREE.Vector2(r[i], r[i + 1]));
        if (k === 0) vs.push(...list); else holes.push(list);
    });
    const faces = THREE.ShapeUtils.triangulateShape(vs, holes);
    return faces;
}

const VERT = /* glsl */`
    uniform vec3 uPal[64];
    uniform float uTopDown, uShadeAmt, uRankMax;
    attribute float aCol, aRank, aShade;
    varying vec3 vCol;
    void main() {
        float c = aCol, wall = 0.0;
        if (c >= 128.0) { c -= 128.0; wall = 1.0; }
        vCol = uPal[int(c)] * mix(1.0, aShade, wall > 0.5 ? 1.0 : uShadeAmt);
        gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
        // top-down: paint order is the depth (later shapes in front), as the 2D map paints them
        if (uTopDown > 0.5) gl_Position.z = (1.0 - 2.0 * (aRank + 1.0) / (uRankMax + 2.0)) * gl_Position.w;
    }`;
const FRAG = /* glsl */`
    varying vec3 vCol;
    void main() { gl_FragColor = vec4(vCol, 1.0); }`;

// the route / extra lines: a ribbon of constant screen width lying on the ground
const LINE_VERT = /* glsl */`
    uniform vec2 uView;
    uniform float uWidth, uTopDown;
    attribute vec3 aNext, aPrev;
    attribute float aSide;
    void main() {
        vec4 p = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
        vec4 n = projectionMatrix * modelViewMatrix * vec4(aNext, 1.0);
        vec4 q = projectionMatrix * modelViewMatrix * vec4(aPrev, 1.0);
        vec2 a = (n.xy / n.w - q.xy / q.w) * uView;
        vec2 d = length(a) > 1e-6 ? normalize(a) : vec2(1.0, 0.0);
        p.xy += vec2(-d.y, d.x) * aSide * uWidth / uView * p.w;
        if (uTopDown > 0.5) p.z = -0.999 * p.w;
        gl_Position = p;
    }`;
const LINE_FRAG = /* glsl */`
    uniform vec3 uColour;
    void main() { gl_FragColor = vec4(uColour, 1.0); }`;

// the player marker: a textured quad, its texture drawn from the SVG path
const MARK_VERT = /* glsl */`
    varying vec2 vUv;
    void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`;
const MARK_FRAG = /* glsl */`
    uniform sampler2D tMap;
    varying vec2 vUv;
    void main() { vec4 c = texture2D(tMap, vUv); if (c.a < 0.004) discard; gl_FragColor = c; }`;

// the spawn beacon's column: an open cylinder, bright where it faces the eye and soft to its sides, fading out up its
// height, light drifting slowly up it. uGrow < 1 = striking down from the sky (only the top uGrow of it, with a bright
// leading edge); uFlash brightens the landing
const BEAM_VERT = /* glsl */`
    uniform float uH;
    varying vec3 vN, vV;
    varying float vZ;
    void main() {
        vZ = position.z / uH;
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        vV = isOrthographic ? vec3(0.0, 0.0, 1.0) : -mv.xyz;
        vN = normalMatrix * normal;
        gl_Position = projectionMatrix * mv;
    }`;
const BEAM_FRAG = /* glsl */`
    uniform vec3 uCol;
    uniform float uTime, uAlpha, uGrow, uCore, uFlash;
    varying vec3 vN, vV;
    varying float vZ;
    void main() {
        float head = 1.0 - uGrow;
        if (vZ < head) discard;
        float body = pow(abs(dot(normalize(vN), normalize(vV))), uCore);
        float fade = (1.0 - smoothstep(0.12, 1.0, vZ)) * smoothstep(0.0, 0.015, vZ);
        float lead = (1.0 - step(0.999, uGrow)) * exp(-(vZ - head) * 30.0) * 1.6;
        float drift = 0.8 + 0.2 * sin((vZ * 7.0 - uTime * 0.55) * 6.2831853);
        gl_FragColor = vec4(uCol, min(body * (fade * drift + lead) * uAlpha * (1.0 + uFlash), 1.0));
    }`;
// a soft round glow facing the screen (the beacon's foot, its specks): uSize world m across, uK its strength
const GLOW_VERT = /* glsl */`
    uniform float uSize;
    varying vec2 vUv;
    void main() {
        vUv = uv;
        vec4 mv = modelViewMatrix * vec4(0.0, 0.0, 0.0, 1.0);
        mv.xy += position.xy * uSize;
        gl_Position = projectionMatrix * mv;
    }`;
const GLOW_FRAG = /* glsl */`
    uniform vec3 uCol;
    uniform float uK;
    varying vec2 vUv;
    void main() {
        float d = length(vUv - 0.5) * 2.0;
        float a = d < 0.35 ? mix(1.0, 0.55, d / 0.35) : mix(0.55, 0.0, clamp((d - 0.35) / 0.65, 0.0, 1.0));
        gl_FragColor = vec4(uCol, a * uK);
    }`;
// the spawn ring: a colour (with its alpha) per vertex
const FLAT_VERT = /* glsl */`
    attribute vec4 aCol;
    varying vec4 vCol;
    void main() { vCol = aCol; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`;
const FLAT_FRAG = /* glsl */`
    uniform float uAlpha;
    varying vec4 vCol;
    void main() { gl_FragColor = vec4(vCol.rgb, vCol.a * uAlpha); }`;

function releaseArray() { this.array = null; }
// a BatchedMesh reads its index's element size every render (multi-draw starts are in bytes): keep an empty array of the
// same type in its place (the attribute's count stays as it was)
function releaseIndexArray() { this.array = new this.array.constructor(0); }

function rgb(css) {
    const c = new THREE.Color(); c.setStyle(css, THREE.SRGBColorSpace);
    const o = { r: 0, g: 0, b: 0 }; c.getRGB(o, THREE.SRGBColorSpace);
    return new THREE.Vector3(o.r, o.g, o.b);       // sRGB components, written as they are
}

export class Map3D {
    /** @param el a container (a canvas is made in it) or a canvas; opts.data = window.MAP3D_DATA. When WebGL will not
     *  start, nothing throws: map.failed holds the error, ready rejects with it, and every other call does nothing */
    constructor(el, opts = {}) {
        this.canvas = el instanceof HTMLCanvasElement ? el : document.createElement('canvas');
        if (!(el instanceof HTMLCanvasElement)) { this.canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;display:block'; el.appendChild(this.canvas); }
        this.scene = new THREE.Scene();
        // setView's orthographic camera (the 2D map's maths) and setCamera's perspective one (a GTA camera's view);
        // this.camera is whichever the last of the two calls chose
        this.ortho = this.camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 1, FAR);
        this.persp = new THREE.PerspectiveCamera(50, 1, 1, PERSP_FAR);
        this.gcam = null;
        this.W = 1; this.H = 1; this.dpr = 1;
        this.view = { x: 0, y: 0, pxPerMetre: K0 * 4, offsetX: 0, offsetY: 0, yaw: 0, pitch: 90 };
        this.lines = [];
        this.marker = null;
        this.pin = null;
        this.gen = 0; this.pinKey = null;    // gen: bumped by every change renderPin's cached frame cannot see in its key
        this.solidMeshes = []; this.groundMeshes = []; this.terrainMesh = null;
        this.topMeshes = []; this.tiltMeshes = [];     // knots: their 2D shapes top-down only, their ribbons tilted only
        this.renderer = null; this.failed = null;
        // opts.antialias: true = the canvas's own MSAA (4 samples; ~36 bytes a pixel of GPU memory), a number = an MSAA
        // target with that many samples copied to a plain canvas (2: ~24 bytes a pixel), false = none (~8 bytes a pixel)
        const aa = opts.antialias ?? true, samples = typeof aa === 'number' ? aa : 0;
        try {
            this.renderer = new THREE.WebGLRenderer({ canvas: this.canvas, antialias: aa === true, alpha: false, depth: !samples, stencil: false,
                powerPreference: 'high-performance', preserveDrawingBuffer: !!opts.preserveDrawingBuffer });
        } catch (e) {
            this.failed = e;
            this.ready = Promise.reject(e);
            this.ready.catch(() => {});           // a caller that never waits on ready sees no unhandled rejection
            return;
        }
        this.renderer.autoClear = false;
        this.renderer.info.autoReset = false;        // a frame is several passes: render() counts them all
        // the shaders write the palette's sRGB values as they are: three's colour management is made a no-op (linear
        // output, raw clear values), so the clear colour comes out the same into the canvas and into a target
        this.renderer.outputColorSpace = THREE.LinearSRGBColorSpace;
        this.setPalette(opts.palette || mapColour);
        if (samples) {
            this.rt = new THREE.WebGLRenderTarget(1, 1, { samples, depthBuffer: true, stencilBuffer: false, generateMipmaps: false,
                minFilter: THREE.NearestFilter, magFilter: THREE.NearestFilter });
            this.blitScene = new THREE.Scene();
            this.blitCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
            const q = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), new THREE.ShaderMaterial({
                uniforms: { tSrc: { value: this.rt.texture } }, depthTest: false, depthWrite: false,
                vertexShader: 'varying vec2 vUv; void main() { vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }',
                fragmentShader: 'uniform sampler2D tSrc; varying vec2 vUv; void main() { gl_FragColor = texture2D(tSrc, vUv); }',
            }));
            q.frustumCulled = false;
            this.blitScene.add(q);
        }
        this.keepArrays = !!opts.keepArrays;        // tests: the meshes' JS copies kept after upload
        this.chunk = opts.chunk || CHUNK;            // tests: another square size (m; rounded to whole terrain cells)
        // a ground piece not cut to the terrain's cells (the flat sea) stays whole in the square of its centre, as v5 kept
        // it in its 3 km chunk. true = cut at the square edges instead: paint order strictly kept, but a few pixels change
        // along the cuts (depth rounding where the sea meets the terrain), so off
        this.splitGround = !!opts.splitGround;
        this.ready = this._build(opts.data || window.MAP3D_DATA);
    }

    async _build(data) {
        const t0 = performance.now();
        // the build gives the page back every SLICE_MS; the longest stretch between two breaths (and where it ended) is
        // kept in the stats. GIVEN BACK BY A MESSAGE, NOT A TIMER: Chromium holds a nested
        // setTimeout(0) for at least 4 ms, so every breath cost as long as the slice before it: the build waited as long
        // as it worked (1.12 s -> 0.58 s headless), and far longer with the CPU busy, as it is under FiveM's own loading
        // screen when the page first builds this (92 s -> 2.4 s at a quarter speed). The page still runs between slices.
        let tSlice = t0, longest = 0, longestAt = '';
        const mc = new MessageChannel();
        let wake = null;
        mc.port1.onmessage = () => { const w = wake; wake = null; if (w) w(); };
        const breathe = async (at) => {
            const d = performance.now() - tSlice;
            if (d > SLICE_MS) {
                if (d > longest) { longest = d; longestAt = at; }
                await new Promise((r) => { wake = r; mc.port2.postMessage(0); });
                tSlice = performance.now();
            }
        };
        const dec = await decode(data, breathe);
        const ground = this.ground = new Ground(dec.grid, dec.meta.drape, dec.landcells);
        await breathe('ground');
        const pal = Array.from({ length: 64 }, () => new THREE.Vector3());
        const uniforms = { uPal: { value: pal }, uTopDown: { value: 1 }, uShadeAmt: { value: 0 }, uRankMax: { value: dec.shapes.length + 1 } };
        this.uniforms = uniforms;
        this.meta = dec.meta;                     // the decoded shapes are not kept; the ground (heightAt) is
        this.setPalette(this.paletteFn);
        this.matColour = new THREE.ShaderMaterial({ uniforms, vertexShader: VERT, fragmentShader: FRAG, depthFunc: THREE.LessEqualDepth });
        // the ground layers: tested against the depth pass, never written (their paint order decides between them)
        this.matGround = new THREE.ShaderMaterial({ uniforms, vertexShader: VERT, fragmentShader: FRAG, depthFunc: THREE.LessEqualDepth,
            depthWrite: false, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -4 });
        this.matDepth = new THREE.ShaderMaterial({ uniforms, vertexShader: VERT, fragmentShader: FRAG, colorWrite: false });
        // squares: per square the terrain, a ground-layer piece list, the solids (buildings + raised decks) and the knots'
        // top-down / tilted-only pieces; S whole terrain cells on the terrain's own origin (CHUNK)
        const g = dec.meta.grid, D = ground.D, S = Math.max(1, Math.round(this.chunk / D)) * D;
        if (ground.x0 !== g.x0 || ground.y0 !== g.y0) throw new Error('map3d: the terrain and the squares must share an origin');
        const ncx = Math.ceil((g.nx - 1) * g.step / S), ncy = Math.ceil((g.ny - 1) * g.step / S);
        const chunks = [];
        const sqI = (x) => Math.min(ncx - 1, Math.max(0, Math.floor((x - g.x0) / S)));
        const sqJ = (y) => Math.min(ncy - 1, Math.max(0, Math.floor((y - g.y0) / S)));
        const chunkAt = (i, j) => {
            const k = j * ncx + i;
            return chunks[k] || (chunks[k] = { ground: new Buf(), solid: new Buf(), gtop: new Buf(), stilt: new Buf(), terrain: new Buf(), tvid: new Map() });
        };
        const chunkOf = (x, y) => chunkAt(sqI(x), sqJ(y));
        // a square's x / y range; the outer squares reach on past the grid (the sea beyond it)
        const sqX = (i) => [i === 0 ? -Infinity : g.x0 + i * S, i === ncx - 1 ? Infinity : g.x0 + (i + 1) * S];
        const sqY = (j) => [j === 0 ? -Infinity : g.y0 + j * S, j === ncy - 1 ? Infinity : g.y0 + (j + 1) * S];
        let splitPieces = 0;
        // the shape being built goes to the top-down-only or tilted-only buffers when it is a knot's
        let route = '';
        const solidOf = (x, y) => { const ch = chunkOf(x, y); return route === 'tilt' ? ch.stilt : ch.solid; };
        // a polygon's pieces as triangles at their heights: z(x, y, o)
        const emit = (rings, col, rank, zOf, shadeOf, solidIf, faces = triangulate(rings)) => {
            if (!faces.length) return;
            const flat = [];
            for (const r of rings) for (let i = 0; i < r.length; i += 3) flat.push(r[i], r[i + 1], r[i + 2]);
            let raised = solidIf === 'deck';
            if (solidIf === true) for (let i = 2; i < flat.length; i += 3) if (flat[i] > 0.05) { raised = true; break; }
            let sx = 0, sy = 0;
            for (let i = 0; i < flat.length; i += 3) { sx += flat[i]; sy += flat[i + 1]; }
            const ci = sqI(sx / (flat.length / 3)), cj = sqJ(sy / (flat.length / 3)), ch = chunkAt(ci, cj);
            const buf = raised ? (route === 'tilt' ? ch.stilt : ch.solid) : (route === 'top' ? ch.gtop : ch.ground);
            if (buf === ch.ground && this.splitGround) {
                // the ground pass paints in order: a piece reaching into another square is cut at the square edges, so
                // each square's pieces stay in rank order (the terrain-cut ones never need it; the flat sea can)
                const [bx0, by0, bx1, by1] = ringBox(flat), [x0, x1] = sqX(ci), [y0, y1] = sqY(cj), e = 1e-3;
                if (bx0 < x0 - e || bx1 > x1 + e || by0 < y0 - e || by1 > y1 + e) {
                    splitPieces++;
                    for (const f of faces) {
                        const tri = [];
                        for (const v of f) tri.push(flat[v * 3], flat[v * 3 + 1], flat[v * 3 + 2]);
                        const [tx0, ty0, tx1, ty1] = ringBox(tri);
                        for (let j = sqJ(ty0); j <= sqJ(ty1); j++) {
                            for (let i = sqI(tx0); i <= sqI(tx1); i++) {
                                let q = tri;
                                const [qx0, qx1] = sqX(i), [qy0, qy1] = sqY(j);
                                if (qx0 > -Infinity) q = clipHalf(q, 1, 0, -qx0);
                                if (qx1 < Infinity) q = clipHalf(q, -1, 0, qx1);
                                if (qy0 > -Infinity) q = clipHalf(q, 0, 1, -qy0);
                                if (qy1 < Infinity) q = clipHalf(q, 0, -1, qy1);
                                if (q.length < 9) continue;
                                const b = chunkAt(i, j).ground, b0 = b.n;
                                for (let k = 0; k < q.length; k += 3) b.vert(q[k], q[k + 1], zOf(q[k], q[k + 1], q[k + 2]), col, shadeOf(q[k], q[k + 1]), rank);
                                for (let k = 1; k + 1 < q.length / 3; k++) b.tri(b0, b0 + k, b0 + k + 1);
                            }
                        }
                    }
                    return;
                }
            }
            const base = buf.n;
            for (let i = 0; i < flat.length; i += 3) {
                const x = flat[i], y = flat[i + 1];
                buf.vert(x, y, zOf(x, y, flat[i + 2]), col, shadeOf(x, y), rank);
            }
            for (const f of faces) buf.tri(base + f[0], base + f[1], base + f[2]);
        };
        const onGround = (x, y, o) => ground.at(x, y) + o;
        const shadeGround = (x, y) => ground.shade(x, y);
        // a ground layer cut to the terrain's triangles: columns first, then cells, then the cell's diagonal. A concave
        // shape cut to a cell can come out with zero-width seams along the cut, which the triangulator may fill across:
        // where a piece's triangles don't add up to its area, that cell takes the shape's own (convex) triangles cut
        // to it instead, which is always exact.
        const area = (r) => { let a = 0; const n = r.length / 3; for (let k = 0, l = n - 1; k < n; l = k++) a += (r[l * 3] + r[k * 3]) * (r[l * 3 + 1] - r[k * 3 + 1]); return Math.abs(a) / 2; };
        let fallbacks = 0;
        const drape = async (rings, col, rank, zOf = onGround, deck = false, shade = null) => {
            const shadeOf = shade || (deck ? () => 1 : shadeGround), solid = deck ? 'deck' : true;
            const [bx0, by0, bx1, by1] = ringBox(rings[0]);
            const i0 = Math.floor((bx0 - ground.x0) / D), i1 = Math.floor((bx1 - ground.x0) / D);
            let whole = null;                                                    // the shape's own triangles, made if needed
            for (let i = i0; i <= i1; i++) {
                const xa = ground.x0 + i * D;
                const strip = i0 === i1 ? rings : rings.map((r) => clipHalf(clipHalf(r, 1, 0, -xa), -1, 0, xa + D));
                if (strip[0].length < 9) continue;
                const [, sy0, , sy1] = ringBox(strip[0]);
                const j0 = Math.floor((sy0 - ground.y0) / D), j1 = Math.floor((sy1 - ground.y0) / D);
                for (let j = j0; j <= j1; j++) {
                    const ya = ground.y0 + j * D;
                    const cell = j0 === j1 ? strip : strip.map((r) => clipHalf(clipHalf(r, 0, 1, -ya), 0, -1, ya + D));
                    if (cell[0].length < 9) continue;
                    for (const side of [1, -1]) {                                   // below / above the diagonal
                        const half = cell.map((r) => clipHalf(r, side, -side, side * (ya - xa))).filter((r, k) => k === 0 || r.length >= 9);
                        if (half[0].length < 9) continue;
                        const faces = triangulate(half);
                        const pts = [];
                        for (const r of half) for (let k = 0; k < r.length; k += 3) pts.push(r[k], r[k + 1]);
                        let ta = 0;
                        for (const [a, b, c] of faces) ta += Math.abs((pts[b * 2] - pts[a * 2]) * (pts[c * 2 + 1] - pts[a * 2 + 1]) - (pts[c * 2] - pts[a * 2]) * (pts[b * 2 + 1] - pts[a * 2 + 1])) / 2;
                        let pa = area(half[0]);
                        for (let k = 1; k < half.length; k++) pa -= area(half[k]);
                        if (Math.abs(ta - pa) <= Math.max(0.25, 0.005 * pa)) { emit(half, col, rank, zOf, shadeOf, solid, faces); continue; }
                        fallbacks++;
                        if (!whole) {
                            const fs = triangulate(rings), flat = [];
                            for (const r of rings) for (let k = 0; k < r.length; k++) flat.push(r[k]);
                            whole = fs.map(([a, b, c]) => [flat[a * 3], flat[a * 3 + 1], flat[a * 3 + 2], flat[b * 3], flat[b * 3 + 1], flat[b * 3 + 2], flat[c * 3], flat[c * 3 + 1], flat[c * 3 + 2]]);
                        }
                        for (const t of whole) {
                            let q = clipHalf(clipHalf(clipHalf(clipHalf(t, 1, 0, -xa), -1, 0, xa + D), 0, 1, -ya), 0, -1, ya + D);
                            if (q.length >= 9) q = clipHalf(q, side, -side, side * (ya - xa));
                            if (q.length >= 9) emit([q], col, rank, zOf, shadeOf, solid, fan(q.length / 3));
                        }
                    }
                }
                await breathe('drape ' + rank);
            }
        };
        const fan = (n) => { const f = []; for (let k = 1; k < n - 1; k++) f.push([0, k, k + 1]); return f; };
        // a ring's turn: anticlockwise seen from above. The filled side of an outer ring going anticlockwise (or of a
        // hole going clockwise) is on its left, so its walls must face right: the other way round from wall() as written
        const ccw = (r) => { let a = 0; const n = r.length / 3; for (let k = 0, l = n - 1; k < n; l = k++) a += r[l * 3] * r[k * 3 + 1] - r[k * 3] * r[l * 3 + 1]; return a > 0; };
        const faceRight = (r, ri) => (ri === 0) === ccw(r);
        // a wall from a to b, tops ta, tb, bottoms ba, bb; facing left of a -> b unless right
        const wall = (buf, ax, ay, ta, ba, bx, by, tb, bb, c, sw, rank, right) => {
            const w0 = buf.vert(ax, ay, ta, c, sw, rank), w1 = buf.vert(bx, by, tb, c, sw, rank);
            const w2 = buf.vert(bx, by, bb, c, sw, rank), w3 = buf.vert(ax, ay, ba, c, sw, rank);
            if (right) { buf.tri(w0, w2, w1); buf.tri(w0, w3, w2); } else { buf.tri(w0, w1, w2); buf.tri(w0, w2, w3); }
        };
        // the wall's shade: facing the light (north-west) lighter
        const wallShade = (dx, dy, len) => 0.55 + 0.45 * Math.abs(-0.7 * dy / len - 0.7 * dx / len);
        // a deck's road surface at (x, y): per lane its nearest point's height, blended by 1 / (distance^2 + 1), so
        // pieces beside each other meet flush; never closer than DECK_LIFT to the ground
        const deckZ = (lines) => (x, y) => {
            let sw = 0, sz = 0;
            for (const L of lines) {
                let best = Infinity, z = 0;
                if (L.length === 3) { best = (x - L[0]) ** 2 + (y - L[1]) ** 2; z = L[2]; }
                for (let k = 0; k + 5 < L.length; k += 3) {
                    const ax = L[k], ay = L[k + 1], dx = L[k + 3] - ax, dy = L[k + 4] - ay;
                    const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy || 1)));
                    const d = (x - ax - dx * t) ** 2 + (y - ay - dy * t) ** 2;
                    if (d < best) { best = d; z = L[k + 2] + (L[k + 5] - L[k + 2]) * t; }
                }
                const w = 1 / (best + 1);
                sw += w; sz += w * z;
            }
            return Math.max(sw > 0 ? sz / sw : -1e9, ground.at(x, y) + DECK_LIFT);
        };
        // a deck's sides: DECK_DEPTH deep (not below the ground), wherever it is a metre or more over the ground
        const skirts = (rings, col, rank, zOf) => {
            rings.forEach((r, ri) => {
                const n = r.length / 3, right = faceRight(r, ri), c = col | 128;
                for (let k = 0; k < n; k++) {
                    const ax = r[k * 3], ay = r[k * 3 + 1], bx = r[((k + 1) % n) * 3], by = r[((k + 1) % n) * 3 + 1];
                    const len = Math.hypot(bx - ax, by - ay);
                    if (len < 0.05) continue;
                    const m = Math.ceil(len / SKIRT_STEP), sw = wallShade(bx - ax, by - ay, len);
                    let x0 = ax, y0 = ay, t0 = zOf(ax, ay), g0 = ground.at(ax, ay);
                    for (let q = 1; q <= m; q++) {
                        const x1 = ax + (bx - ax) * q / m, y1 = ay + (by - ay) * q / m, t1 = zOf(x1, y1), g1 = ground.at(x1, y1);
                        if (t0 - g0 >= 1 || t1 - g1 >= 1) {
                            wall(solidOf(x0, y0), x0, y0, t0, Math.max(g0 - 0.5, t0 - DECK_DEPTH), x1, y1, t1, Math.max(g1 - 0.5, t1 - DECK_DEPTH), c, sw, rank, right);
                        }
                        x0 = x1; y0 = y1; t0 = t1; g0 = g1;
                    }
                }
            });
        };
        // a v4 deck's sides: each ring edge that is not a seam, its top along the edge's own heights, DECK_DEPTH deep (not
        // below the ground), wherever it is a metre or more over the ground
        const skirts4 = (pg, col, rank) => {
            pg.forEach((r, ri) => {
                const a = r.xyz, n = a.length / 3, right = faceRight(a, ri), c = col | 128;
                for (let k = 0; k < n; k++) {
                    if (r.seam[k]) continue;
                    const k2 = (k + 1) % n, ax = a[k * 3], ay = a[k * 3 + 1], az = a[k * 3 + 2];
                    const bx = a[k2 * 3], by = a[k2 * 3 + 1], bz = a[k2 * 3 + 2];
                    const len = Math.hypot(bx - ax, by - ay);
                    if (len < 0.05) continue;
                    const m = Math.ceil(len / SKIRT_STEP), sw = wallShade(bx - ax, by - ay, len);
                    let x0 = ax, y0 = ay, t0 = az, g0 = ground.at(ax, ay);
                    for (let q = 1; q <= m; q++) {
                        const f = q / m, x1 = ax + (bx - ax) * f, y1 = ay + (by - ay) * f, t1 = az + (bz - az) * f, g1 = ground.at(x1, y1);
                        if (t0 - g0 >= 1 || t1 - g1 >= 1) {
                            wall(solidOf(x0, y0), x0, y0, t0, Math.max(g0 - 0.5, t0 - DECK_DEPTH), x1, y1, t1, Math.max(g1 - 0.5, t1 - DECK_DEPTH), c, sw, rank, right);
                        }
                        x0 = x1; y0 = y1; t0 = t1; g0 = g1;
                    }
                }
            });
        };
        const asRings = (pg) => pg.map((r) => {
            const n = r.pts.length / 2, a = new Array(n * 3);
            for (let k = 0; k < n; k++) { a[k * 3] = r.pts[k * 2]; a[k * 3 + 1] = r.pts[k * 2 + 1]; a[k * 3 + 2] = r.off ? r.off[k] : 0; }
            return a;
        });
        let buildingTris = 0;
        for (let s = 0; s < dec.shapes.length; s++) {
            const sh = dec.shapes[s], rank = s + 1;                 // rank 0 is the terrain (the land), under everything
            route = sh.topOnly ? 'top' : sh.tiltOnly ? 'tilt' : '';
            for (const pg of sh.polys) {
                const rings = asRings(pg);
                if (rings[0].length < 9) continue;
                if (sh.kind === BUILD && !sh.drape) {
                    // a prism: a flat roof at the found height (never under the highest ground at its corners), each
                    // wall down to the ground at its corners. A shape across a slope (its ground varies by more than
                    // 6 m: walls, terraces traced as blocks) follows the ground at its height above the middle of it
                    // instead of standing as one tall slab; so does a shape with no height found (a low slab on the
                    // ground: plazas, low structures)
                    const gs = [];
                    for (const r of rings) for (let i = 0; i < r.length; i += 3) gs.push(ground.at(r[i], r[i + 1]));
                    let gmin = Infinity, gmax = -Infinity;
                    for (const v of gs) { if (v < gmin) gmin = v; if (v > gmax) gmax = v; }
                    const gmed = gs.slice().sort((a, b) => a - b)[gs.length >> 1];
                    const follow = gmax - gmin > 6 || !(sh.top > 0);
                    const hgt = sh.top > 0 ? Math.max(1.0, sh.top - (follow ? gmed : gmin)) : SLAB;
                    const topAt = (x, y, g) => (follow ? g + hgt : Math.max(sh.top, gmax + 1.0));
                    const buf = solidOf(rings[0][0], rings[0][1]);
                    if (sh.bottom > 0) {
                        // over a drive-under passage: a block from its roof down to the passage's ceiling, open under
                        const top = Math.max(sh.top, sh.bottom + 1.0), bot = sh.bottom;
                        const faces = triangulate(rings), base = buf.n;
                        for (const r of rings) for (let i = 0; i < r.length; i += 3) buf.vert(r[i], r[i + 1], top, sh.col, 1, rank);
                        for (const f of faces) buf.tri(base + f[0], base + f[1], base + f[2]);
                        const ub = buf.n;                            // its underside, facing down
                        for (const r of rings) for (let i = 0; i < r.length; i += 3) buf.vert(r[i], r[i + 1], bot, sh.col | 128, 0.45, rank);
                        for (const f of faces) buf.tri(ub + f[0], ub + f[2], ub + f[1]);
                        rings.forEach((r, ri) => {
                            const n = r.length / 3, right = faceRight(r, ri);
                            for (let k = 0; k < n; k++) {
                                const ax = r[k * 3], ay = r[k * 3 + 1], bx = r[((k + 1) % n) * 3], by = r[((k + 1) % n) * 3 + 1];
                                const len = Math.hypot(bx - ax, by - ay);
                                if (len < 0.05) continue;
                                wall(buf, ax, ay, top, bot, bx, by, top, bot, sh.col | 128, wallShade(bx - ax, by - ay, len), rank, right);
                            }
                        });
                        buildingTris += faces.length;
                        continue;
                    }
                    if (follow && gmax - gmin > 1.5) {
                        // following uneven ground: its roof cut to the terrain's triangles (between its corners the
                        // ground may rise: a long strip up a mountain, a house on a slope), its walls in pieces of at
                        // most SKIRT_STEP along the ground (on level ground the plain prism below does)
                        await drape(rings, sh.col, rank, (x, y) => ground.at(x, y) + hgt, true);
                        rings.forEach((r, ri) => {
                            const n = r.length / 3, right = faceRight(r, ri), c = sh.col | 128;
                            for (let k = 0; k < n; k++) {
                                const ax = r[k * 3], ay = r[k * 3 + 1], bx = r[((k + 1) % n) * 3], by = r[((k + 1) % n) * 3 + 1];
                                const len = Math.hypot(bx - ax, by - ay);
                                if (len < 0.05) continue;
                                const m = Math.ceil(len / SKIRT_STEP), sw = wallShade(bx - ax, by - ay, len);
                                let x0 = ax, y0 = ay, g0 = ground.at(ax, ay);
                                for (let q = 1; q <= m; q++) {
                                    const x1 = ax + (bx - ax) * q / m, y1 = ay + (by - ay) * q / m, g1 = ground.at(x1, y1);
                                    wall(solidOf(x0, y0), x0, y0, g0 + hgt, g0 - 1.0, x1, y1, g1 + hgt, g1 - 1.0, c, sw, rank, right);
                                    x0 = x1; y0 = y1; g0 = g1;
                                }
                            }
                        });
                        continue;
                    }
                    const faces = triangulate(rings);
                    const base = buf.n;
                    let gi = 0;
                    for (const r of rings) for (let i = 0; i < r.length; i += 3) buf.vert(r[i], r[i + 1], topAt(r[i], r[i + 1], gs[gi++]), sh.col, 1, rank);
                    for (const f of faces) buf.tri(base + f[0], base + f[1], base + f[2]);
                    gi = 0;
                    rings.forEach((r, ri) => {
                        const n = r.length / 3, g0 = gi, right = faceRight(r, ri);
                        for (let k = 0; k < n; k++) {
                            const a = k * 3, b = ((k + 1) % n) * 3, ga = gs[g0 + k], gb = gs[g0 + (k + 1) % n];
                            const ax = r[a], ay = r[a + 1], bx = r[b], by = r[b + 1], len = Math.hypot(bx - ax, by - ay);
                            if (len < 0.05) continue;
                            wall(buf, ax, ay, topAt(ax, ay, ga), ga - 1.0, bx, by, topAt(bx, by, gb), gb - 1.0, sh.col | 128, wallShade(bx - ax, by - ay, len), rank, right);
                        }
                        gi += n;
                    });
                    buildingTris += faces.length;
                } else if (sh.kind === SEA && !sh.drape && sh.level > 0) {
                    // a lake: flat at its level, cut to the terrain's triangles so that where the terrain (40 m cells,
                    // its banks averaged in) comes up over the water the water follows it instead of vanishing under it
                    const z = sh.level;
                    await drape(rings, sh.col, rank, (x, y) => Math.max(z, ground.at(x, y) + 0.05));
                } else if (sh.kind === SEA && !sh.drape) {
                    // flat: the sea at 0; one piece in the chunk of its first point
                    emit(rings, sh.col, rank, () => 0, () => 1, false);
                } else if (sh.kind === SEA) {
                    // the sea round the coast, a river no water quad covers: flat at 0 or on the terrain where it comes
                    // up over that, one flat shade (dipping with the sea bed and shaded by its slope, the terrain's 40 m
                    // cells showed as squares on the water)
                    await drape(rings, sh.col, rank, (x, y) => Math.max(0, ground.at(x, y)), false, () => 1);
                } else if (sh.kind === ROAD || sh.kind === HWY || sh.kind === PATH) {
                    // a road: one flat shade, the decks' (shaded by the terrain's 40 m cells under it, a road was a
                    // patchwork of lighter and darker squares, and never matched the deck it ran onto)
                    await drape(rings, sh.col, rank, onGround, false, () => DECK_SHADE);
                } else {
                    await drape(rings, sh.col, rank);
                }
            }
            // decks: their own layer at their lanes' height, over whatever they pass over (the shape lies under them)
            if (sh.deck) for (const pc of sh.deck) {
                if (pc.v4) {
                    // v4: at the collision's own heights (every ring point carries one), flat-shaded like level ground;
                    // cut to the terrain's triangles and never closer than DECK_LIFT to it (between its outline points a
                    // deck or a road at ground level is flat, and a terrain triangle rising in its middle came through)
                    for (const pg of pc.v4) {
                        const rings = pg.map((r) => r.xyz);
                        if (rings[0].length < 9) continue;
                        await drape(rings, sh.col, rank, (x, y, z) => Math.max(z, ground.at(x, y) + DECK_LIFT), true, () => DECK_SHADE);
                        skirts4(pg, sh.col, rank);
                    }
                    continue;
                }
                const zOf = deckZ(pc.lanes);
                for (const pg of pc.polys) {
                    const rings = asRings(pg);
                    if (rings[0].length < 9) continue;
                    // cut to the terrain's triangles like a ground layer: within each, deck and terrain are both flat, so a
                    // deck kept DECK_LIFT over the ground at every corner never dips under it (a hill between two
                    // corners would poke through a deck cut only along its outline)
                    await drape(rings, sh.col, rank, zOf, true);
                    skirts(rings, sh.col, rank, zOf);
                }
            }
            await breathe('shape ' + rank);
        }
        // the terrain: the land's cells, per square (the land colour; the depth pass's ground when tilted). A square's
        // cells share their vertices, as the one island mesh did; its edge vertices are repeated in the next square
        // (the same values, so no seam)
        const landCol = dec.meta.landColour;
        for (let j = 0; j < ground.cny; j++) {
            for (let i = 0; i < ground.cnx; i++) {
                if (!ground.land(i, j)) continue;
                const ch = chunkOf(ground.x0 + (i + 0.5) * D, ground.y0 + (j + 0.5) * D), tb = ch.terrain, vid = ch.tvid;
                const V = (vi, vj) => {
                    const k = vj * ground.nx + vi;
                    let v = vid.get(k);
                    if (v === undefined) vid.set(k, v = tb.vert(ground.x0 + vi * D, ground.y0 + vj * D, ground.h[k], landCol, ground.shadeAt(vi, vj), 0));
                    return v;
                };
                const a = V(i, j), b = V(i + 1, j), c = V(i + 1, j + 1), d = V(i, j + 1);
                tb.tri(a, b, c); tb.tri(a, c, d);
            }
            await breathe('terrain rows');
        }
        // one BatchedMesh per layer kind, its squares in the order the meshes were drawn (sortObjects off: these are
        // opaque, the paint order is aRank's depth and the passes'); buffers sized to exactly what goes in
        let gpu = 0, verts = 0, tris = 0;
        const squares = {};
        const batch = async (key) => {
            const geos = [];
            for (const ch of chunks) {
                if (!ch) continue;
                const geo = ch[key].geometry();
                if (ch.tvid && key === 'terrain') ch.tvid = null;
                if (geo) geos.push(geo);
                await breathe('squares ' + key);
            }
            squares[key] = geos.length;
            if (!geos.length) return [];
            let nv = 0, ni = 0;
            for (const geo of geos) { nv += geo.attributes.position.count; ni += geo.index.count; }
            const b = new THREE.BatchedMesh(geos.length, nv, ni, this.matColour);
            b.sortObjects = false;
            b.perObjectFrustumCulled = true;
            for (const geo of geos) {
                b.addInstance(b.addGeometry(geo));        // world-space geometry: the instance matrix stays identity
                await breathe('batch ' + key);
            }
            b.computeBoundingBox(); b.computeBoundingSphere();
            const bg = b.geometry;
            for (const a of Object.values(bg.attributes)) gpu += a.array.byteLength;
            gpu += bg.index.array.byteLength; verts += nv; tris += ni / 3;
            // the geometry never changes: once on the GPU, its JS copies go (each square's bounds were copied in already)
            if (!this.keepArrays) {
                for (const a of Object.values(bg.attributes)) a.onUpload(releaseArray);
                bg.index.onUpload(releaseIndexArray);
            }
            return [b];
        };
        [this.terrainMesh = null] = await batch('terrain');
        if (this.terrainMesh) this.terrainMesh.renderOrder = -1;
        this.groundMeshes = await batch('ground');
        this.solidMeshes = await batch('solid');
        this.topMeshes = await batch('gtop');
        this.tiltMeshes = await batch('stilt');
        chunks.length = 0;
        this.scene.add(...this._layers());
        this._placeCamera();
        // warm-up, still in slices, so the first frame shown has neither to do: the shader programs compiled where the
        // driver can do it in the background (KHR_parallel_shader_compile: ANGLE's D3D compile is the slow part), then
        // each batch's buffers sent to the GPU on a slice of its own (a render with every square hidden: no draws)
        const all = this._layers();
        this._setLine('warm', [[g.x0, g.y0, 0], [g.x0 + 1, g.y0, 0]], '#000000', 1);
        const parallel = this.renderer.extensions.has('KHR_parallel_shader_compile');
        for (const mat of [this.matColour, this.matGround, this.matDepth]) {
            this._only(all, mat, true);
            if (parallel) await this.renderer.compileAsync(this.scene, this.camera);
            else this.renderer.compile(this.scene, this.camera);
            await breathe('compile');
        }
        this._setLine('warm', null);
        // the spawn pin's programs too (its meshes are a few KB; made now so its first frame does not compile)
        const pp = this._pinParts();
        for (const sc of [pp.ringScene, pp.beaconScene]) {
            if (parallel) await this.renderer.compileAsync(sc, this.camera);
            else this.renderer.compile(sc, this.camera);
        }
        if (this.rt) this.renderer.compile(this.blitScene, this.blitCam);
        for (const m of all) {
            const fc = m.frustumCulled, n = m.instanceCount;
            this._only([m], this.matColour, false);
            m.frustumCulled = false;
            for (let i = 0; i < n; i++) m.setVisibleAt(i, false);
            this.renderer.render(this.scene, this.camera);
            for (let i = 0; i < n; i++) m.setVisibleAt(i, true);
            m.frustumCulled = fc;
            await breathe('upload');
        }
        this._only(all, this.matColour, true);
        this.stats = { buildMs: Math.round(performance.now() - t0), longestSliceMs: +longest.toFixed(1), longestSliceAt: longestAt, triangles: tris, vertices: verts, gpuBytes: gpu,
            meshes: all.length, squareM: S, squares, splitPieces, multiDraw: this.renderer.extensions.has('WEBGL_multi_draw'),
            shapes: dec.shapes.length, buildingTops: buildingTris, fallbacks };
        mc.port1.close();   // the breaths' channel, done with
        return this.stats;
    }

    resize(W, H, dpr = window.devicePixelRatio || 1) {
        this.W = W; this.H = H; this.dpr = dpr;
        if (!this.renderer) return;
        this.renderer.setPixelRatio(dpr);
        this.renderer.setSize(W, H, false);
        if (this.rt) this.rt.setSize(Math.max(1, Math.round(W * dpr)), Math.max(1, Math.round(H * dpr)));
        this._placeCamera();
    }

    /** x, y: the world point drawn at the view's centre (middle + offsetX, offsetY CSS px); pxPerMetre there;
     *  yaw: degrees, 0 = north up, GTA's sense (anticlockwise); pitch: 90 = straight down */
    setView(v) { this.gcam = null; this.camera = this.ortho; Object.assign(this.view, v); this._placeCamera(); }

    /** a perspective camera placed as a GTA camera is, so the map can stand in for the game's picture (a cross-fade
     *  lines up): x, y, z its position (world m); rotX the pitch (degrees, -90 straight down), rotY the roll, rotZ the
     *  heading (degrees anticlockwise from north), as GetCamRot(cam, 2) gives them; fov the vertical field of view
     *  (degrees, as GetCamFov); shiftX, shiftY: CSS px the picture's centre moves right and down (a lens shift: the
     *  point looked at sits off the middle, e.g. beside a menu; 0 for a cross-fade). Heights are real (heightScale 1).
     *  A partial object changes only what it names. setView goes back to the orthographic map. */
    setCamera(c) {
        this.gcam = Object.assign(this.gcam || { x: 0, y: 0, z: 1000, rotX: -90, rotY: 0, rotZ: 0, fov: 50, shiftX: 0, shiftY: 0 }, c);
        this.camera = this.persp;
        this._placeCamera();
    }

    _placePersp() {
        const c = this.gcam, cam = this.persp, rad = THREE.MathUtils.degToRad;
        this.hs = 1;
        this.scene.scale.set(1, 1, 1); this.scene.updateMatrixWorld();
        const px = rad(c.rotX ?? -90), rz = rad(c.rotZ || 0);
        // GTA's camera looks along f; its right is r (heading 0 looks north, right is east); up = r x f
        const f = new THREE.Vector3(-Math.sin(rz) * Math.cos(px), Math.cos(rz) * Math.cos(px), Math.sin(px));
        const r = new THREE.Vector3(Math.cos(rz), Math.sin(rz), 0), u = new THREE.Vector3().crossVectors(r, f);
        if (c.rotY) { r.applyAxisAngle(f, rad(c.rotY)); u.applyAxisAngle(f, rad(c.rotY)); }
        cam.position.set(c.x, c.y, c.z);
        cam.quaternion.setFromRotationMatrix(new THREE.Matrix4().makeBasis(r, u, f.clone().negate()));
        cam.fov = c.fov ?? 50;
        cam.aspect = this.W / Math.max(1, this.H);
        // the near plane from the height over the ground: depth precision from far out, nothing cut off close up
        const agl = Math.max(1, c.z - this.heightAt(c.x, c.y));
        cam.near = Math.min(200, Math.max(0.3, agl * 0.02)); cam.far = PERSP_FAR;
        if (c.shiftX || c.shiftY) cam.setViewOffset(this.W, this.H, -(c.shiftX || 0), -(c.shiftY || 0), this.W, this.H);
        else cam.clearViewOffset();
        cam.updateProjectionMatrix(); cam.updateMatrixWorld();
        this.topDown = false;
    }

    _placeCamera() {
        if (this.gcam) { this._placePersp(); return; }
        const v = this.view, cam = this.ortho, k = v.pxPerMetre, W = this.W, H = this.H;
        const ox = v.offsetX || 0, oy = v.offsetY || 0;
        const p = THREE.MathUtils.degToRad(Math.max(5, Math.min(90, v.pitch ?? 90)));
        const yaw = THREE.MathUtils.degToRad(v.yaw || 0);
        // heightScale squashes every height alike (the minimap: GTA's radar is flat; the ground layers stay on it)
        this.hs = v.heightScale ?? 1;
        this.scene.scale.set(1, 1, this.hs); this.scene.updateMatrixWorld();
        const f = new THREE.Vector3(-Math.sin(yaw), Math.cos(yaw), 0);       // the screen's up, on the ground
        const T = new THREE.Vector3(v.x, v.y, (this.ground ? this.ground.at(v.x, v.y) : 0) * this.hs);
        const dir = f.clone().multiplyScalar(Math.cos(p)).add(new THREE.Vector3(0, 0, -Math.sin(p)));
        cam.position.copy(T).addScaledVector(dir, -FAR / 2);
        cam.up.copy(f).multiplyScalar(Math.sin(p)).add(new THREE.Vector3(0, 0, Math.cos(p)));
        cam.lookAt(T);
        cam.left = -(W / 2 + ox) / k; cam.right = (W / 2 - ox) / k;
        cam.top = (H / 2 + oy) / k; cam.bottom = -(H / 2 - oy) / k;
        cam.near = 1; cam.far = FAR;
        cam.updateProjectionMatrix(); cam.updateMatrixWorld();
        this.topDown = (v.pitch ?? 90) >= 89.95;
    }

    /** one draw; nothing runs in between */
    render() {
        if (!this.terrainMesh) return;
        const r = this.renderer, u = this.uniforms;
        r.info.reset();
        if (this.rt) r.setRenderTarget(this.rt);
        r.clear(true, true, true);
        u.uTopDown.value = this.topDown ? 1 : 0;
        u.uShadeAmt.value = this.topDown ? 0 : 1;
        for (const l of this.lines) { l.mesh.material.uniforms.uTopDown.value = u.uTopDown.value; l.mesh.material.uniforms.uView.value.set(this.W, this.H); }
        if (this.topDown) {
            this._only([this.terrainMesh, ...this.solidMeshes, ...this.groundMeshes, ...this.topMeshes], this.matColour, true);
            r.render(this.scene, this.camera);
        } else {
            // 1. depth: terrain, buildings, decks; 2. the land and every ground layer in paint order, on the terrain,
            // not writing depth; 3. buildings + decks in colour, over them wherever they are in front (a deck just over
            // the ground stays over the ground layers' depth offset); 4. the route and lines
            this._only([this.terrainMesh, ...this.solidMeshes, ...this.tiltMeshes], this.matDepth, false);
            r.render(this.scene, this.camera);
            this._only([this.terrainMesh, ...this.groundMeshes], this.matGround, false);
            r.render(this.scene, this.camera);
            this._only([...this.solidMeshes, ...this.tiltMeshes], this.matColour, false);
            r.render(this.scene, this.camera);
            this._only([], null, true);
            r.render(this.scene, this.camera);
        }
        if (this.pin) this._drawRing();
        if (this.marker) this._drawMarker();
        if (this.rt) { r.setRenderTarget(null); r.render(this.blitScene, this.blitCam); }
        if (this.pin) this._drawBeacon();
        this.pinKey = this.rt ? this._pinKey() : null;
    }

    /** a frame where only the spawn beacon's light moved on (strike / flash / glow / motes / t): with an MSAA target
     *  (antialias: a number) the last render's map and ring are copied out again and only the beacon is drawn over them,
     *  a copy and a few small draws instead of the whole map. Anything else changed since (the camera, the size, the
     *  ring's inputs, the marker, a line, the palette), or no target = a full render(). True when it drew the whole map. */
    renderPin() {
        if (!this.terrainMesh) return false;
        if (!this.rt || this.pinKey !== this._pinKey()) { this.render(); return true; }
        const r = this.renderer;
        r.info.reset();
        r.setRenderTarget(null);
        r.render(this.blitScene, this.blitCam);
        if (this.pin) this._drawBeacon();
        return false;
    }

    /** what the cached frame was drawn with: the camera, the canvas, the ring's inputs, the map's other changes (gen) */
    _pinKey() {
        const c = this.camera, p = this.pin;
        const ring = p ? [p.x, p.y, p.z, p.heading, p.sizePx, p.scale, p.alpha, p.ring].join(',') : '-';
        return `${this.gen}|${this.W}|${this.H}|${this.dpr}|${c.projectionMatrix.elements.join(',')}|${c.matrixWorld.elements.join(',')}|${ring}`;
    }

    /** the spawn pin: a beacon, a column of light standing on a spot with a glow at its foot, and a ring on the ground
     *  round it with a notch pointing the heading. Both are drawn over everything: buildings never hide them. It stays
     *  the same size on screen however far the camera is (sizePx, default 7.5% of the canvas height; the column is
     *  BEACON.height of those tall). p: { x, y, z (the spot, world m; omitted = the map's ground), heading (degrees,
     *  GTA's; omitted = no notch), sizePx, scale (times the size), alpha (0-1, all of it), ring (0-1, the ring and notch),
     *  strike (0-1, how much of the column has come down from the sky: 1 = all of it), flash (0+, the landing's
     *  brightening), glow (0-1, the glow at the foot), motes (0-1, the specks rising), t (ms, the clock the light drifts
     *  on; default performance.now()) }. null = no pin. Then render(), or renderPin() when only strike, flash, glow, motes
     *  or t changed. */
    setPin(p) {
        if (!this.renderer) return;
        this.pin = p ? Object.assign({}, p) : null;
    }

    _pinParts() {
        if (this.pinParts) return this.pinParts;
        // the ring (2 x PIN_SEG + 1 vertices, the notch 3 more), lying on the ground: rebuilt each draw, since its size
        // follows the camera and the ground under it is not flat. No depth test: drawn over everything
        const rg = new THREE.BufferGeometry(), n = PIN_SEG * 2 + 3, idx = [];
        rg.setAttribute('position', new THREE.BufferAttribute(new Float32Array(n * 3), 3));
        rg.setAttribute('aCol', new THREE.BufferAttribute(new Float32Array(n * 4), 4));
        for (let i = 0; i < PIN_SEG; i++) {
            const a = i * 2, b = ((i + 1) % PIN_SEG) * 2;
            idx.push(a, b, a + 1, a + 1, b, b + 1);
        }
        idx.push(PIN_SEG * 2, PIN_SEG * 2 + 1, PIN_SEG * 2 + 2);
        rg.setIndex(idx);
        const ring = new THREE.Mesh(rg, new THREE.ShaderMaterial({ vertexShader: FLAT_VERT, fragmentShader: FLAT_FRAG,
            uniforms: { uAlpha: { value: 1 } }, transparent: true, depthTest: false, depthWrite: false, side: THREE.DoubleSide }));
        ring.frustumCulled = false;
        const ringScene = new THREE.Scene();
        ringScene.add(ring);
        // the beacon, in the old pin's heights (the group is scaled to that each draw), standing along +z from the spot:
        // the column's layers (open cylinders), the glow at its foot with a hot core, the specks. Light: added, no depth
        const B = BEACON, beacon = new THREE.Group(), beams = [], glows = [];
        const light = { transparent: true, depthTest: false, depthWrite: false, blending: THREE.AdditiveBlending };
        for (const [radius, core, k] of B.layers) {
            const cg = new THREE.CylinderGeometry(radius, radius, B.height, radius > 0.05 ? 40 : 16, 1, true);
            cg.rotateX(Math.PI / 2); cg.translate(0, 0, B.height / 2);
            const m = new THREE.Mesh(cg, new THREE.ShaderMaterial(Object.assign({ vertexShader: BEAM_VERT, fragmentShader: BEAM_FRAG,
                uniforms: { uH: { value: B.height }, uCol: { value: new THREE.Vector3(...B.colour) }, uTime: { value: 0 },
                    uAlpha: { value: k }, uGrow: { value: 1 }, uCore: { value: core }, uFlash: { value: 0 } },
                side: THREE.DoubleSide }, light)));
            m.userData.k = k;
            beams.push(m);
        }
        const quad = new THREE.PlaneGeometry(1, 1);
        const glow = (col) => {
            const m = new THREE.Mesh(quad, new THREE.ShaderMaterial(Object.assign({ vertexShader: GLOW_VERT, fragmentShader: GLOW_FRAG,
                uniforms: { uSize: { value: 1 }, uK: { value: 0 }, uCol: { value: new THREE.Vector3(...col) } } }, light)));
            glows.push(m);
            return m;
        };
        const foot = glow(B.glowCol), hot = glow([1, 1, 1]), motes = [];
        foot.position.z = 0.02; hot.position.z = 0.03;
        for (let i = 0; i < B.motes; i++) motes.push(glow([1, 1, 1]));
        for (const m of [...beams, ...glows]) { m.frustumCulled = false; beacon.add(m); }
        const beaconScene = new THREE.Scene();
        beaconScene.add(beacon);
        return (this.pinParts = { ringScene, beaconScene, ring, beacon, beams, foot, hot, motes, glows, quad });
    }

    /** world metres per CSS px at a point, on the screen's plane through it */
    _metresPerPx(pt) {
        if (!this.gcam) return 1 / this.view.pxPerMetre;
        const cam = this.persp, fwd = new THREE.Vector3(0, 0, -1).applyQuaternion(cam.quaternion);
        const depth = Math.max(cam.near, pt.clone().sub(cam.position).dot(fwd));
        return 2 * depth * Math.tan(THREE.MathUtils.degToRad(cam.fov) / 2) / Math.max(1, this.H);
    }

    /** the pin this draw: its spot (world), s (world m to one of its units: PIN_FRAC of the screen), alpha */
    _pinPlace() {
        const p = this.pin, hs = this.hs ?? 1, zs = p.z ?? this.heightAt(p.x, p.y);
        const base = new THREE.Vector3(p.x, p.y, zs * hs);
        const s = (p.sizePx ?? PIN_FRAC * this.H) * this._metresPerPx(base) * (p.scale ?? 1);
        return { p, hs, zs, base, s, alpha: Math.max(0, Math.min(1, p.alpha ?? 1)) };
    }

    /** the ring and notch, into the frame with the map, over everything: draped on the map's ground (or flat at the
     *  spot when the spot is over it: a roof, a deck) */
    _drawRing() {
        const P = this._pinParts(), { p, hs, zs, s, alpha } = this._pinPlace();
        const lift = Math.max(0.2, s * 0.012);
        const at = (x, y) => (Math.max(this.heightAt(x, y), zs - 0.6) + lift) * hs;
        const ring = P.ring.geometry, rp = ring.attributes.position, rc = ring.attributes.aCol;
        const ra = (p.ring ?? 1) * PIN.ring * alpha, r0 = 0.46 * s, r1 = 0.56 * s;
        for (let i = 0; i < PIN_SEG; i++) {
            const a = (i / PIN_SEG) * Math.PI * 2, cx = Math.cos(a), sy = Math.sin(a);
            for (let k = 0; k < 2; k++) {
                const rr = k ? r1 : r0, x = p.x + cx * rr, y = p.y + sy * rr;
                rp.setXYZ(i * 2 + k, x, y, at(x, y));
                rc.setXYZW(i * 2 + k, 0.949, 0.957, 0.969, ra);
            }
        }
        // the notch: a triangle off the ring, pointing the heading (GTA's: 0 = north, anticlockwise)
        const n0 = PIN_SEG * 2, hd = p.heading == null ? null : THREE.MathUtils.degToRad(p.heading);
        const dx = hd == null ? 0 : -Math.sin(hd), dy = hd == null ? 0 : Math.cos(hd);
        const tri = [[r1 + 0.24 * s, 0], [r1 - 0.02 * s, 0.15 * s], [r1 - 0.02 * s, -0.15 * s]];
        tri.forEach(([fw, sd], k) => {
            const x = p.x + dx * fw + dy * sd, y = p.y + dy * fw - dx * sd;
            rp.setXYZ(n0 + k, x, y, at(x, y));
            rc.setXYZW(n0 + k, 0.949, 0.957, 0.969, hd == null ? 0 : ra);
        });
        rp.needsUpdate = rc.needsUpdate = true;
        this.renderer.render(P.ringScene, this.camera);
    }

    /** the beacon, over the finished frame (on the canvas, after the MSAA copy): soft light needs no smoothing and no
     *  depth, and drawn here it can move on alone (renderPin) */
    _drawBeacon() {
        const P = this._pinParts(), B = BEACON, { p, base, s, alpha } = this._pinPlace();
        if (alpha <= 0) return;
        const c01 = (v, d) => Math.max(0, Math.min(1, v ?? d));
        const t = (p.t ?? performance.now()) / 1000, flash = Math.max(0, p.flash ?? 0), gk = c01(p.glow, 1), mk = c01(p.motes, 1);
        P.beacon.position.copy(base);
        P.beacon.scale.setScalar(s);
        for (const m of P.beams) {
            const u = m.material.uniforms;
            u.uTime.value = t; u.uGrow.value = c01(p.strike, 1); u.uFlash.value = flash; u.uAlpha.value = m.userData.k * alpha;
        }
        const set = (m, size, k) => { m.material.uniforms.uSize.value = size; m.material.uniforms.uK.value = k; m.visible = k > 0; };
        set(P.foot, B.glow * s * (1 + flash), B.glowK * gk * alpha);
        set(P.hot, B.hot * s * (1 + 0.6 * flash), gk * alpha);
        P.motes.forEach((m, i) => {
            const ph = (t * 1000 / B.moteMs + i / P.motes.length) % 1, a = i * 2.39 + ph * 2.2;
            m.position.set(0.07 * Math.cos(a), 0.07 * Math.sin(a), 0.05 + ph * B.moteRise);
            set(m, B.moteSize * s, Math.sin(Math.PI * ph) * 0.8 * mk * alpha);
        });
        P.beacon.updateMatrixWorld(true);
        this.renderer.render(P.beaconScene, this.camera);
    }

    /** the player marker, drawn by the map so buildings can hide it: wherever a surface more than MARK_ABOVE over the
     *  player is in front of it (a building between the camera and the player, a roof or a bridge over the player) that
     *  part is drawn as an outline, the rest filled, so half hidden = half outline. The ground or a deck under the player
     *  never hides it. m: { x, y (world m), z (the ped's, ~1 m over the ground; omitted = 1 m over the map's ground),
     *  rotDeg (screen degrees clockwise, as a CSS rotate), sizePx (CSS px of the 24-unit box, default 22), path (an SVG
     *  path in a 24 x 24 box), fill, stroke, strokePx (the visible part), outline, outlinePx, halo (the hidden part:
     *  the outline over a halo twice as wide) }; omitted fields keep MARKER's. null = no marker. Then render(). */
    setMarker(m) {
        if (!this.renderer) return;
        this.gen++;
        if (!m) { this.marker = null; return; }
        this.marker = Object.assign({}, MARKER, m);
        this._markerTextures();
    }

    _markerTextures() {
        const m = this.marker, key = JSON.stringify([m.path, m.fill, m.stroke, m.strokePx, m.outline, m.outlinePx, m.halo]);
        if (this.mark && this.mark.key === key) return;
        const draw = (paint) => {
            const c = document.createElement('canvas');
            c.width = c.height = MARK_TEX;
            const g = c.getContext('2d'), k = MARK_TEX / (24 + 2 * MARK_PAD);
            g.setTransform(k, 0, 0, k, MARK_PAD * k, MARK_PAD * k);
            g.lineJoin = 'round';
            paint(g, new Path2D(m.path));
            const t = new THREE.CanvasTexture(c);
            t.colorSpace = THREE.NoColorSpace;                 // written as it is, like the palette
            t.minFilter = THREE.LinearMipmapLinearFilter;
            return t;
        };
        const shown = draw((g, path) => {
            g.fillStyle = m.fill; g.fill(path);
            if (m.strokePx > 0) { g.lineWidth = m.strokePx; g.strokeStyle = m.stroke; g.stroke(path); }
        });
        const hidden = draw((g, path) => {
            if (m.halo) { g.lineWidth = m.outlinePx * 2; g.strokeStyle = m.halo; g.stroke(path); }
            g.lineWidth = m.outlinePx; g.strokeStyle = m.outline; g.stroke(path);
        });
        if (!this.mark) {
            const geo = new THREE.BufferGeometry();
            geo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(12), 3));
            geo.setAttribute('uv', new THREE.BufferAttribute(new Float32Array([0, 1, 1, 1, 1, 0, 0, 0]), 2));
            geo.setIndex([0, 1, 2, 0, 2, 3]);
            const mat = (depthFunc) => new THREE.ShaderMaterial({ uniforms: { tMap: { value: null } }, vertexShader: MARK_VERT,
                fragmentShader: MARK_FRAG, transparent: true, depthWrite: false, depthFunc, side: THREE.DoubleSide });
            const shownMesh = new THREE.Mesh(geo, mat(THREE.LessEqualDepth)), hiddenMesh = new THREE.Mesh(geo, mat(THREE.GreaterDepth));
            shownMesh.frustumCulled = hiddenMesh.frustumCulled = false;
            this.markScene = new THREE.Scene();                // unscaled: the quad is placed in drawn coordinates
            this.markScene.add(shownMesh, hiddenMesh);
            this.mark = { geo, shownMesh, hiddenMesh };
        } else {
            this.mark.shownMesh.material.uniforms.tMap.value.dispose();
            this.mark.hiddenMesh.material.uniforms.tMap.value.dispose();
        }
        this.mark.shownMesh.material.uniforms.tMap.value = shown;
        this.mark.hiddenMesh.material.uniforms.tMap.value = hidden;
        this.mark.key = key;
    }

    _drawMarker() {
        const r = this.renderer, u = this.uniforms, m = this.marker, cam = this.camera;
        if (this.topDown) {
            // top-down the depth is paint order: the real heights first, in a depth pass of their own
            r.clearDepth();
            u.uTopDown.value = 0;
            this._only([this.terrainMesh, ...this.solidMeshes, ...this.tiltMeshes], this.matDepth, false);
            r.render(this.scene, cam);
            u.uTopDown.value = 1;
        }
        // the screen square at the player, rotated, laid on the level plane MARK_ABOVE over the player: the camera is
        // orthographic, so each pixel's depth is where its ray meets that plane, and the depth test then says whether
        // a surface over that plane is in front there
        const zp = m.z ?? this.heightAt(m.x, m.y) + 1, hs = this.hs ?? 1;
        const c = this.project(m.x, m.y, zp), plane = (zp + MARK_ABOVE) * hs;
        const half = (m.sizePx / 2) * (24 + 2 * MARK_PAD) / 24;
        const a = THREE.MathUtils.degToRad(m.rotDeg || 0), ca = Math.cos(a), sa = Math.sin(a);
        const pos = this.mark.geo.attributes.position, o = new THREE.Vector3(), d = new THREE.Vector3();
        [[-1, -1], [1, -1], [1, 1], [-1, 1]].forEach(([ex, ey], k) => {
            const ox = ex * half, oy = ey * half;
            const px = c.sx + ox * ca - oy * sa, py = c.sy + ox * sa + oy * ca;
            const nx = px / this.W * 2 - 1, ny = 1 - py / this.H * 2;
            o.set(nx, ny, -1).unproject(cam); d.set(nx, ny, 1).unproject(cam).sub(o);
            const t = Math.abs(d.z) > 1e-9 ? (plane - o.z) / d.z : 0;
            pos.setXYZ(k, o.x + d.x * t, o.y + d.y * t, plane);
        });
        pos.needsUpdate = true;
        r.render(this.markScene, cam);
    }

    /** the map's batches: terrain, solids, ground layers, knots' top-down pieces, knots' tilted pieces (those built) */
    _layers() {
        return [this.terrainMesh, ...this.solidMeshes, ...this.groundMeshes, ...this.topMeshes, ...this.tiltMeshes].filter(Boolean);
    }

    _only(meshes, mat, lines) {
        const on = new Set(meshes);
        for (const m of this._layers()) {
            m.visible = on.has(m);
            if (m.visible) m.material = mat;
        }
        for (const l of this.lines) l.mesh.visible = lines;
    }

    /** world -> CSS px on the canvas; z omitted = the ground there */
    project(x, y, z) {
        const p = new THREE.Vector3(x, y, (z ?? this.heightAt(x, y)) * (this.hs ?? 1)).project(this.camera);
        const sx = (p.x + 1) / 2 * this.W, sy = (1 - p.y) / 2 * this.H;
        // (perspective: a point behind the camera projects mirrored, and is never visible)
        return { sx, sy, visible: p.z < 1 && sx >= 0 && sy >= 0 && sx <= this.W && sy <= this.H };
    }

    /** the ground under a CSS px point (tilted too): a march along the camera's ray over the heights */
    pick(sx, sy) {
        if (!this.ground) return null;
        const ndc = new THREE.Vector3(sx / this.W * 2 - 1, 1 - sy / this.H * 2, -1);
        const o = ndc.clone().unproject(this.camera), d = ndc.clone().setZ(1).unproject(this.camera).sub(o).normalize();
        if (this.topDown) return { x: o.x, y: o.y, z: this.ground.at(o.x, o.y) };
        const hs = this.hs ?? 1, gAt = (x, y) => this.ground.at(x, y) * hs;   // the ground as drawn
        let t = Math.max(0, (o.z - 1000 * hs) / -d.z), prev = t;
        for (let i = 0; i < 40000; i++, t += 4) {
            const x = o.x + d.x * t, y = o.y + d.y * t, z = o.z + d.z * t;
            if (z <= gAt(x, y)) {
                let a = prev, b = t;
                for (let k = 0; k < 24; k++) {
                    const m = (a + b) / 2;
                    if (o.z + d.z * m <= gAt(o.x + d.x * m, o.y + d.y * m)) b = m; else a = m;
                }
                const X = o.x + d.x * b, Y = o.y + d.y * b;
                return { x: X, y: Y, z: this.ground.at(X, Y) };
            }
            prev = t;
            if (z < -200) break;
        }
        return null;
    }

    heightAt(x, y) { return this.ground ? this.ground.at(x, y) : 0; }

    /** recolours the map without rebuilding it (a theme): fn maps a colour of the 2D map's table, [r, g, b], to the
     *  colour drawn (mapColour by default); the sea outside the shapes is fn's colour for the deepest sea. Then render(). */
    setPalette(fn = mapColour) {
        this.gen++;
        this.paletteFn = fn;
        if (this.meta) this.uniforms.uPal.value.forEach((v, i) => {
            const c = this.meta.colours[i] ? fn(this.meta.colours[i]) : [0, 0, 0];
            v.set(c[0] / 255, c[1] / 255, c[2] / 255);
        });
        const d = fn(DEEP_SRC);
        if (this.renderer) this.renderer.setClearColor(new THREE.Color().setRGB(d[0] / 255, d[1] / 255, d[2] / 255, THREE.LinearSRGBColorSpace), 1);
    }

    /** the GPS route: [[x, y, z?], ...] (z omitted = on the ground) */
    setRoute(points, colour = '#a44cf2', widthPx = 5) { this._setLine('route', points, colour, widthPx); }

    /** extra lines: [{ points, colour, width? }] */
    setLines(list) {
        for (const l of this.lines.filter((l) => l.key !== 'route')) this._drop(l);
        this.lines = this.lines.filter((l) => l.key === 'route');
        (list || []).forEach((l, i) => this._setLine('line' + i, l.points, l.colour || '#a44cf2', l.width || 4));
    }

    _drop(l) { this.scene.remove(l.mesh); l.mesh.geometry.dispose(); l.mesh.material.dispose(); }

    _setLine(key, points, colour, widthPx) {
        this.gen++;
        const old = this.lines.find((l) => l.key === key);
        if (old) { this._drop(old); this.lines = this.lines.filter((l) => l !== old); }
        if (!points || points.length < 2) return;
        const n = points.length, P = points.map(([x, y, z]) => [x, y, (z ?? this.heightAt(x, y)) + 0.6]);
        const pos = new Float32Array(n * 6), nxt = new Float32Array(n * 6), prv = new Float32Array(n * 6), side = new Float32Array(n * 2);
        for (let i = 0; i < n; i++) {
            const a = P[Math.max(0, i - 1)], b = P[Math.min(n - 1, i + 1)];
            for (let s = 0; s < 2; s++) { const k = i * 2 + s; pos.set(P[i], k * 3); nxt.set(b, k * 3); prv.set(a, k * 3); side[k] = s ? 1 : -1; }
        }
        const idx = [];
        for (let i = 0; i < n - 1; i++) { const a = i * 2; idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2); }
        const g = new THREE.BufferGeometry();
        g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
        g.setAttribute('aNext', new THREE.BufferAttribute(nxt, 3));
        g.setAttribute('aPrev', new THREE.BufferAttribute(prv, 3));
        g.setAttribute('aSide', new THREE.BufferAttribute(side, 1));
        g.setIndex(idx);
        const m = new THREE.ShaderMaterial({
            uniforms: { uView: { value: new THREE.Vector2(this.W, this.H) }, uWidth: { value: widthPx }, uTopDown: { value: 1 }, uColour: { value: rgb(colour) } },
            vertexShader: LINE_VERT, fragmentShader: LINE_FRAG, depthFunc: THREE.LessEqualDepth, depthWrite: false, side: THREE.DoubleSide,
            polygonOffset: true, polygonOffsetFactor: -4, polygonOffsetUnits: -8,
        });
        const mesh = new THREE.Mesh(g, m);
        mesh.frustumCulled = false; mesh.renderOrder = 10;
        this.scene.add(mesh);
        this.lines.push({ key, mesh });
    }

    /** moves the canvas into another container (the pause map and the minimap share one copy of the map) */
    attach(el) { el.appendChild(this.canvas); }

    dispose() {
        for (const m of this._layers()) m.dispose();             // a BatchedMesh's geometry and its textures
        for (const l of this.lines) this._drop(l);
        this.lines = [];
        if (this.mark) {
            this.mark.geo.dispose();
            for (const mesh of [this.mark.shownMesh, this.mark.hiddenMesh]) { mesh.material.uniforms.tMap.value.dispose(); mesh.material.dispose(); }
            this.mark = null; this.marker = null;
        }
        if (this.pinParts) {
            const P = this.pinParts;
            P.ring.geometry.dispose(); P.ring.material.dispose();
            for (const m of P.beams) { m.geometry.dispose(); m.material.dispose(); }
            for (const m of P.glows) m.material.dispose();
            P.quad.dispose();
            this.pinParts = null; this.pin = null;
        }
        for (const m of [this.matColour, this.matGround, this.matDepth]) if (m) m.dispose();
        if (this.rt) { this.rt.dispose(); this.blitScene.children[0].geometry.dispose(); this.blitScene.children[0].material.dispose(); }
        if (this.renderer) { this.renderer.dispose(); this.renderer.forceContextLoss?.(); }
        this.canvas.remove();
    }
}

// ---- the minimap's camera ----
//
// GTA's radar, ours: top-down on foot, tilted in a vehicle, zooming out with speed, turning with the gameplay camera
// (its yaw is never smoothed: it must feel instant), the player low in the middle. Poses arrive at any rate with a
// timestamp; between them the position is carried on along the last velocity (at most 250 ms).
const smooth = (cur, target, dt, tau) => cur + (target - cur) * (1 - Math.exp(-dt / tau));
export class MinimapCamera {
    constructor(opts = {}) {
        this.o = Object.assign({
            footPxPerMetre: 1.45,     // ~115 m each side in a 330 px box
            slowPxPerMetre: 1.15,     // in a vehicle, standing
            fastPxPerMetre: 0.42,     // at fastSpeed (m/s) and above
            fastSpeed: 45,
            footPitch: 90, vehiclePitch: 52,
            vehicleHeightScale: 0.35,  // heights squashed in the tilted minimap, so buildings don't hide the roads
            playerAt: 0.28,           // the player this far below the box's centre, as a share of its height (tilted)
            footPlayerAt: 0.12,
            tauZoom: 900, tauPitch: 500, tauPos: 60,   // ms
            boxH: 179,
        }, opts);
        this.pose = null; this.vel = [0, 0]; this.cur = null; this.tLast = 0;
        this.settled = false;     // after viewAt: true once the view has stopped moving (no more frames needed)
    }

    /** { x, y, z, heading, camYaw, speed, inVehicle, vehicleClass, t } (t = ms); true when the pose changes the
     *  picture (moved, turned, got in or out), so a pose that changes nothing needn't cost a frame */
    update(p) {
        const q = this.pose;
        if (q && p.t > q.t) {
            const dt = (p.t - q.t) / 1000;
            if (Math.hypot(p.x - q.x, p.y - q.y) > 200) { this.vel = [0, 0]; this.cur = null; }   // a teleport
            else if (dt > 0 && dt < 1) this.vel = [(p.x - q.x) / dt, (p.y - q.y) / dt];
        }
        this.pose = { ...p };
        const changed = !q || Math.hypot(p.x - q.x, p.y - q.y) > 0.02 || Math.abs((p.camYaw ?? p.heading ?? 0) - (q.camYaw ?? q.heading ?? 0)) > 0.05
            || Math.abs((p.heading ?? 0) - (q.heading ?? 0)) > 0.05 || !!p.inVehicle !== !!q.inVehicle || Math.abs((p.speed || 0) - (q.speed || 0)) > 0.05;
        if (changed) this.settled = false;
        return changed;
    }

    /** the setView for this frame */
    viewAt(now) {
        const p = this.pose, o = this.o;
        if (!p) return null;
        const ahead = Math.min(250, Math.max(0, now - p.t)) / 1000;
        const x = p.x + this.vel[0] * ahead, y = p.y + this.vel[1] * ahead;
        const sp = Math.max(0, p.speed || 0);
        const tz = p.inVehicle ? o.slowPxPerMetre + (o.fastPxPerMetre - o.slowPxPerMetre) * Math.min(1, sp / o.fastSpeed) ** 0.8 : o.footPxPerMetre;
        const tp = p.inVehicle ? o.vehiclePitch : o.footPitch, ta = p.inVehicle ? o.playerAt : o.footPlayerAt;
        if (!this.cur) this.cur = { k: tz, pitch: tp, at: ta, x, y };
        const dt = Math.min(200, Math.max(0, now - (this.tLast || now)));
        this.tLast = now;
        const c = this.cur;
        c.k = smooth(c.k, tz, dt, o.tauZoom); c.pitch = smooth(c.pitch, tp, dt, o.tauPitch); c.at = smooth(c.at, ta, dt, o.tauZoom);
        c.x = smooth(c.x, x, dt, o.tauPos); c.y = smooth(c.y, y, dt, o.tauPos);
        // settled: what is left to move is under about a quarter of a pixel in the box
        this.settled = Math.abs(c.k - tz) < 0.0015 * tz && Math.abs(c.pitch - tp) < 0.05 && Math.abs(c.at - ta) < 0.0015
            && Math.hypot(c.x - x, c.y - y) < 0.02 && (Math.hypot(this.vel[0], this.vel[1]) < 0.02 || now - p.t >= 250);
        // pitch within 0.05 of straight down counts as top-down (exact palette, paint order)
        const hs = 1 + (o.vehicleHeightScale - 1) * Math.min(1, Math.max(0, (o.footPitch - c.pitch) / Math.max(1, o.footPitch - o.vehiclePitch)));
        return { x: c.x, y: c.y, pxPerMetre: c.k, offsetX: 0, offsetY: c.at * o.boxH, yaw: p.camYaw ?? p.heading ?? 0,
            pitch: c.pitch > 89.9 ? 90 : c.pitch, heightScale: hs };
    }
}
