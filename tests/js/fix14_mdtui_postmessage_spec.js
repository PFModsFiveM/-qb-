// Batch 14, DEV-MSG-1: who may talk to the device shell and to the MDT pages with postMessage.
//  * pf-devices/html/runtime.js (the tablet and computer shells): pfapp:* messages from the game
//    (no source, the shell itself, or the NUI root page that hosts it) still work; the same messages
//    posted by an app's iframe (the police MDT, the trucking page, a site) are ignored, so one app
//    cannot push fake NUI messages into another app or open apps and sites on the player's device;
//  * the police and EMS MDT pages (full screen): game messages work, a message from another frame is
//    dropped before any handler; inside a device window (?embed=1) only the device page around the
//    iframe (window.parent) is listened to;
//  * the pf-tablet shell no longer has the unused action that loaded any script URL named in a message.
// Browsers set MessageEvent.source to the posting window; jsdom's postMessage does not, so the
// events are dispatched with the source a browser would give them.
// Run: node js/fix14_mdtui_postmessage_spec.js
// (MDT_UI_ROOT=<folder holding pf-devices/, pf-tablet/, pf-policemdt-DEV/, pf-emsmdt/> runs it against another copy.)
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = process.env.MDT_UI_ROOT || path.resolve(__dirname, '..', '..', '..', '[pfscripts]');

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));
async function settle(n = 20) { for (let i = 0; i < n; i++) await tick(); }

function quiet() { const vc = new VirtualConsole(); vc.on('jsdomError', () => {}); return vc; }
function otherWindow() { return new JSDOM('<!doctype html><body></body>').window; }
// The page's window.parent: the NUI root page (full screen) or the device page (embedded).
function setParent(w, parent) { Object.defineProperty(w, 'parent', { get: () => parent, configurable: true }); }
function send(w, data, source) {
    w.dispatchEvent(new w.MessageEvent('message', source === undefined ? { data } : { data, source }));
}

// ── the device shell ─────────────────────────────────────────────────────
function shellWindow() {
    const dom = new JSDOM('<!doctype html><html><head></head><body><div id="shell"></div></body></html>',
        { runScripts: 'outside-only', url: 'https://cfx-nui-pf-tablet/html/index.html', virtualConsole: quiet() });
    const w = dom.window;
    w.fetch = async (url) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const result = name === 'apps' ? { apps: [
            { id: 'policemdt', name: 'Police MDT', kind: 'iframe', url: 'https://cfx-nui-pf-policemdt-dev/html/index.html?embed=1&device={device}' },
            { id: 'emsmdt', name: 'EMS MDT', kind: 'iframe', url: 'https://cfx-nui-pf-emsmdt/html/index.html?embed=1&device={device}' },
            { id: 'notes', name: 'Notes', kind: 'module', entry: 'https://cfx-nui-x/notes.js' },
        ], store: [], categories: [] } : { ok: true };
        return { json: async () => result };
    };
    const head = w.document.head.appendChild.bind(w.document.head);
    w.document.head.appendChild = (el) => { const r = head(el); if (el.tagName === 'SCRIPT') setTimeout(() => el.onload && el.onload(), 0); return r; };
    w.jQuery = function () {};
    w.eval(fs.readFileSync(path.join(ROOT, 'pf-devices/html/runtime.js'), 'utf8'));
    const opened = [];
    w.PFApps.attachShell({
        device: 'tablet',
        openWindow(app, mount) { const el = w.document.createElement('div'); el.dataset.window = app.id; w.document.getElementById('shell').appendChild(el); opened.push(app.id); mount(el); },
        closeWindow(id) { const el = w.document.querySelector(`[data-window="${id}"]`); if (el) el.remove(); },
        onApps() {},
        notify() {},
    });
    return { w, opened };
}

function frameOf(w, appId) { return w.document.querySelector(`[data-window="${appId}"] iframe`); }

// ── an MDT page (index.html + its local scripts, inline ones included, in order) ──
function mdtPage(dir, query) {
    const base = path.join(ROOT, dir, 'html');
    const html = fs.readFileSync(path.join(base, 'index.html'), 'utf8');
    const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)].map((m) => {
        const src = /\bsrc="([^"]+)"/.exec(m[1]);
        return src ? { file: src[1].split('?')[0] } : { inline: m[2] };
    }).filter((s) => s.inline !== undefined || !/^https?:/i.test(s.file));
    const dom = new JSDOM(html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, ''), {
        url: `https://cfx-nui-${dir.toLowerCase()}/html/index.html${query || ''}`, runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole: quiet(),
    });
    const w = dom.window;
    const stub = new Proxy(function () {}, { get(t, k) { if (k === Symbol.toPrimitive) return () => 0; if (k === 'then') return undefined; return stub; }, apply() { return stub; }, construct() { return stub; } });
    w.L = stub;
    w.GetParentResourceName = () => dir;
    w.fetch = async () => ({ ok: true, json: async () => ({}) });
    const ctx = dom.getInternalVMContext();
    for (const s of scripts) new vm.Script(s.inline !== undefined ? s.inline : fs.readFileSync(path.join(base, s.file), 'utf8')).runInContext(ctx);
    return { w, run: (code) => new vm.Script(code).runInContext(ctx) };
}

const OPEN = { action: 'open', calls: [], config: { localeData: {}, map: {} }, permissions: { allowed: true, isSupervisor: true },
    user: { name: 'Officer Test', rankLevel: 4, grade: 'Chief' } };
const CITIZENS = { action: 'setCitizens', totalCount: 1, citizens: [{ citizenId: 'C1', name: 'Planted Name' }] };

(async () => {
    await it('runtime: game messages still reach apps; the same message from an app iframe is ignored', async () => {
        const { w } = shellWindow();
        await w.PFApps.refresh();
        await w.PFApps.open('policemdt');
        await w.PFApps.open('emsmdt');
        await settle();
        const police = frameOf(w, 'policemdt');
        const ems = frameOf(w, 'emsmdt');
        ok(police && ems, 'both MDT iframes mounted');
        const delivered = [];
        ems.contentWindow.postMessage = (msg) => delivered.push(msg);
        const forged = { action: 'pfapp:event', app: 'emsmdt', event: 'nui', payload: { action: 'setCitizenProfile', profile: { name: 'forged' } } };

        send(w, forged, police.contentWindow);           // script in the police MDT iframe
        await settle();
        eq(delivered.length, 0, 'an iframe cannot push NUI messages into another app');

        send(w, forged);                                 // the game (SendNUIMessage, no source)
        await settle();
        eq(delivered.length, 1, 'the game still reaches the embedded page');
        eq(delivered[0].profile.name, 'forged');

        const root = otherWindow();                      // the NUI root page that hosts the shell
        setParent(w, root);
        send(w, forged, root);
        await settle();
        eq(delivered.length, 2, 'messages relayed by the NUI root page are accepted');
        send(w, forged, w);
        await settle();
        eq(delivered.length, 3, "the shell's own messages are accepted");
    });

    await it('runtime: an app iframe cannot open apps or sites on the device', async () => {
        const { w, opened } = shellWindow();
        await w.PFApps.refresh();
        await w.PFApps.open('policemdt');
        await settle();
        const police = frameOf(w, 'policemdt');
        const sites = [];
        w.PFApps.openSite = (host) => { sites.push(host); };
        send(w, { action: 'pfapp:open', app: 'emsmdt' }, police.contentWindow);
        send(w, { action: 'pfapp:openSite', host: 'evil.ls' }, police.contentWindow);
        await settle();
        ok(!opened.includes('emsmdt'), 'no app opened');
        eq(sites.length, 0, 'no site opened');
        send(w, { action: 'pfapp:open', app: 'emsmdt' });
        await settle();
        ok(opened.includes('emsmdt'), 'the game can still open an app');
    });

    await it('pf-tablet shell: no message makes the tablet load a script from a URL (dead loadExternalModules removed)', async () => {
        const html = fs.readFileSync(path.join(ROOT, 'pf-tablet/html/index.html'), 'utf8');
        const dom = new JSDOM(html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, ''), { url: 'https://cfx-nui-pf-tablet/html/index.html', runScripts: 'outside-only', virtualConsole: quiet() });
        const w = dom.window;
        w.fetch = async () => ({ json: async () => ({}) });
        w.GetParentResourceName = () => 'pf-tablet';
        const ctx = dom.getInternalVMContext();
        new vm.Script(fs.readFileSync(path.join(ROOT, 'pf-devices/html/vendor/jquery-3.6.0.min.js'), 'utf8')).runInContext(ctx);
        new vm.Script(fs.readFileSync(path.join(ROOT, 'pf-tablet/html/script.js'), 'utf8')).runInContext(ctx);
        await settle();
        const frame = w.document.createElement('iframe');
        w.document.body.appendChild(frame);
        send(w, { action: 'loadExternalModules', scripts: [{ url: 'https://evil.tld/x.js' }], styles: ['https://evil.tld/x.css'] }, frame.contentWindow);
        send(w, { action: 'loadExternalModules', scripts: [{ url: 'https://evil.tld/y.js' }] });
        await settle();
        eq(w.document.querySelectorAll('script[src*="evil.tld"], link[href*="evil.tld"]').length, 0, 'no script or style loaded');
    });

    for (const mdt of [{ dir: 'pf-policemdt-DEV', grid: 'citizenGrid' }, { dir: 'pf-emsmdt', grid: 'citizensResults' }]) {
        await it(`${mdt.dir}: full screen, the game drives the page and another frame cannot`, async () => {
            const { w, run } = mdtPage(mdt.dir);
            const sibling = otherWindow();               // another resource's NUI frame, an app iframe, a site
            send(w, OPEN, sibling);
            await settle();
            ok(!run('typeof router !== "undefined" && !!router'), 'open from another frame ignored');
            send(w, OPEN);
            await settle();
            ok(run('typeof router !== "undefined" && !!router'), 'open from the game works');
            run("router.set('citizens')");
            await settle();
            send(w, CITIZENS, sibling);
            await settle();
            ok(!(w.document.getElementById(mdt.grid).textContent || '').includes('Planted Name'), 'data from another frame not shown');
            const root = otherWindow();
            setParent(w, root);
            send(w, CITIZENS, root);
            await settle();
            ok(w.document.getElementById(mdt.grid).textContent.includes('Planted Name'), 'data relayed by the NUI root page shown');
            const frame = w.document.getElementById('tabletFrame');
            const before = frame ? frame.className : '';
            send(w, { action: 'close' }, sibling);
            await settle();
            eq(frame ? frame.className : '', before, 'another frame cannot close or hide the MDT');
        });

        await it(`${mdt.dir}: in a device window (?embed=1) only the device page is listened to`, async () => {
            const { w, run } = mdtPage(mdt.dir, '?embed=1&device=tablet');
            const device = otherWindow();                // the tablet / computer page holding the iframe
            const sibling = otherWindow();               // another app's iframe in the same device
            setParent(w, device);
            send(w, OPEN);
            send(w, OPEN, sibling);
            await settle();
            ok(!run('typeof router !== "undefined" && !!router'), 'only the device page may open it');
            send(w, OPEN, device);
            await settle();
            ok(run('typeof router !== "undefined" && !!router'), 'open from the device page works');
            run("router.set('citizens')");
            await settle();
            send(w, CITIZENS, sibling);
            await settle();
            ok(!(w.document.getElementById(mdt.grid).textContent || '').includes('Planted Name'), 'a sibling iframe is ignored');
            send(w, CITIZENS, device);
            await settle();
            ok(w.document.getElementById(mdt.grid).textContent.includes('Planted Name'), 'the device page reaches the MDT');
        });
    }

    console.log(`\n${passed} passed, ${failed} failed (device and MDT postMessage sources)`);
    if (failed) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
    process.exit(0);
})();
