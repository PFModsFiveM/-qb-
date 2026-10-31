// pf-devices NUI runtime in a simulated browser (jsdom): a shell attaches, the app list comes from
// the server, a module mounts with a working ctx (rpc, push events, close), sites mount, and the
// same module works in two shells. Run: node js/pfdevices_runtime_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 10; i++) await tick(); }

// A browser window with the runtime loaded and a fake NUI fetch bridge.
function makeWindow(serverApps, handlers) {
    const dom = new JSDOM('<!doctype html><html><head></head><body><div id="shell"></div></body></html>', { runScripts: 'outside-only', url: 'https://cfx-nui-pf-tablet/html/index.html' });
    const win = dom.window;
    const posts = [];
    win.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse(opts && opts.body || '{}');
        posts.push({ url: String(url), name, body });
        let result;
        if (name === 'apps') result = { apps: serverApps(body.device), store: [], categories: [] };
        else if (name === 'rpc') result = (handlers[`${body.app}.${body.method}`] || (() => ({ ok: false, error: 'unknown_method' })))(body.payload);
        else if (name === 'sites') result = { ok: true, sites: [{ host: 'news.ls', name: 'News', appId: 'site-news-ls', entry: 'https://cfx-nui-pf-news/html/news.js', styles: [] }] };
        else result = { ok: true };
        return { json: async () => result };
    };
    // scripts the runtime asks for are "loaded" immediately (modules register themselves in tests)
    const origAppend = win.document.head.appendChild.bind(win.document.head);
    win.document.head.appendChild = (el) => {
        const r = origAppend(el);
        if (el.tagName === 'SCRIPT') setTimeout(() => el.onload && el.onload(), 0);
        return r;
    };
    win.jQuery = function () {};
    win.eval(RUNTIME);
    return { win, posts };
}

// A minimal shell: one div per window.
function attachShell(win, device) {
    const opened = [];
    const closed = [];
    let lastApps = [];
    win.PFApps.attachShell({
        device,
        openWindow(app, mount) {
            const el = win.document.createElement('div');
            el.dataset.window = app.id;
            win.document.getElementById('shell').appendChild(el);
            opened.push(app.id);
            mount(el);
        },
        closeWindow(id) {
            closed.push(id);
            const el = win.document.querySelector(`[data-window="${id}"]`);
            if (el) el.remove();
        },
        onApps(apps) { lastApps = apps; },
        notify() {},
    });
    return { opened, closed, apps: () => lastApps };
}

const APPS = (device) => [
    { id: 'taxi', name: 'Taxi', icon: '🚕', kind: 'module', entry: 'https://cfx-nui-pf-jobs/html/apps/taxi.js', styles: [] },
    ...(device === 'tablet' ? [{ id: 'tabletonly', name: 'T', kind: 'module', entry: 'https://cfx-nui-x/t.js', styles: [] }] : []),
];

(async () => {
    await it('a shell gets the server app list for its device and modules mount with a working ctx', async () => {
        const handlers = { 'taxi.getInit': () => ({ ok: true, calls: 3 }) };
        const { win, posts } = makeWindow(APPS, handlers);
        const shell = attachShell(win, 'tablet');
        const apps = await win.PFApps.refresh();
        eq(apps.length, 2);
        eq(shell.apps().length, 2, 'shell told about the apps');
        eq(posts.find((p) => p.name === 'apps').body.device, 'tablet');
        let mountedCtx = null;
        let events = [];
        win.PFApps.register('taxi', {
            async mount(el, ctx) {
                mountedCtx = ctx;
                const res = await ctx.rpc('getInit', { a: 1 });
                el.appendChild(ctx.h('div.count', String(res.calls)));
                ctx.on('callsData', (p) => events.push(p));
            },
        });
        await win.PFApps.open('taxi');
        await settle();
        eq(shell.opened.join(','), 'taxi');
        const el = win.document.querySelector('[data-window="taxi"] .count');
        ok(el, 'module rendered');
        eq(el.textContent, '3');
        const rpc = posts.find((p) => p.name === 'rpc');
        eq(rpc.url, 'https://pf-devices/rpc', 'rpc goes to pf-devices whatever the shell');
        eq(rpc.body.app, 'taxi');
        eq(rpc.body.method, 'getInit');
        eq(rpc.body.payload.a, 1);
        eq(mountedCtx.device, 'tablet');
        // a server push reaches the module
        win.PFApps.handleMessage({ action: 'pfapp:event', app: 'taxi', event: 'callsData', payload: [1, 2] });
        eq(events.length, 1);
        eq(events[0].length, 2);
        // pushes for other apps do not
        win.PFApps.handleMessage({ action: 'pfapp:event', app: 'bus', event: 'callsData', payload: [] });
        eq(events.length, 1);
    });

    await it('opening twice focuses, closing unmounts once, and an app the player lost closes itself', async () => {
        let serverApps = APPS;
        const { win } = makeWindow((d) => serverApps(d), {});
        const shell = attachShell(win, 'computer');
        let unmounts = 0;
        win.PFApps.register('taxi', { mount(el) { el.textContent = 'hi'; }, unmount() { unmounts++; } });
        await win.PFApps.refresh();
        await win.PFApps.open('taxi');
        await settle();
        await win.PFApps.open('taxi');
        eq(shell.opened.length, 1, 'one window');
        ok(win.PFApps.isOpen('taxi'));
        serverApps = () => [];
        win.PFApps.handleMessage({ action: 'pfapp:appsChanged' });
        await settle();
        eq(unmounts, 1);
        eq(shell.closed.join(','), 'taxi');
        ok(!win.PFApps.isOpen('taxi'));
        eq(await win.PFApps.open('taxi'), false, 'cannot open an app that is not on the list');
    });

    await it('a device-specific app is only listed on that device; the same module runs in both shells', async () => {
        const handlers = { 'taxi.getInit': () => ({ ok: true, calls: 1 }) };
        const module = { async mount(el, ctx) { const r = await ctx.rpc('getInit'); el.textContent = `${ctx.device}:${r.calls}`; } };
        for (const device of ['tablet', 'computer']) {
            const { win } = makeWindow(APPS, handlers);
            attachShell(win, device);
            const apps = await win.PFApps.refresh();
            eq(apps.some((a) => a.id === 'tabletonly'), device === 'tablet');
            win.PFApps.register('taxi', module);
            await win.PFApps.open('taxi');
            await settle();
            eq(win.document.querySelector('[data-window="taxi"]').textContent, `${device}:1`);
        }
    });

    await it('a module that throws on mount shows an error instead of breaking the shell', async () => {
        const { win } = makeWindow(APPS, {});
        attachShell(win, 'tablet');
        await win.PFApps.refresh();
        win.PFApps.register('taxi', { mount() { throw new Error('boom'); } });
        const origError = win.console.error;
        win.console.error = () => {};
        await win.PFApps.open('taxi');
        await settle();
        win.console.error = origError;
        ok(win.document.querySelector('[data-window="taxi"] .pfapp-error'), 'error shown');
    });

    await it('sites mount from the server list with their own ctx and rpc', async () => {
        const handlers = { 'site-news-ls.latest': () => ({ ok: true, items: ['a', 'b'] }) };
        const { win, posts } = makeWindow(APPS, handlers);
        attachShell(win, 'computer');
        win.PFApps.registerSite('news.ls', {
            async mount(el, ctx) { const r = await ctx.rpc('latest'); el.textContent = r.items.join('|'); },
        });
        const sites = await win.PFApps.sites();
        eq(sites[0].host, 'news.ls');
        const el = win.document.createElement('div');
        await win.PFApps.mountSite(sites[0], el);
        await settle();
        eq(el.textContent, 'a|b');
        const rpc = posts.filter((p) => p.name === 'rpc').pop();
        eq(rpc.body.app, 'site-news-ls');
    });

    await it('the ctx DOM builder escapes text', async () => {
        const { win } = makeWindow(APPS, {});
        const { h, esc } = win.PFApps.util;
        const el = h('div.a#b', { dataset: { x: '1' } }, '<img src=x onerror=alert(1)>');
        eq(el.className, 'a');
        eq(el.id, 'b');
        eq(el.dataset.x, '1');
        eq(el.children.length, 0, 'text is not parsed as HTML');
        eq(esc('<b>"x"</b>'), '&lt;b&gt;&quot;x&quot;&lt;/b&gt;');
    });

    await it('an iframe app gets the device in its URL and its own NUI messages unwrapped', async () => {
        const apps = () => [{ id: 'trucking', name: 'Trucking', kind: 'iframe', url: 'https://cfx-nui-pf-trucking/html/index.html?embed=1&device={device}', styles: [] }];
        const { win } = makeWindow(apps, {});
        attachShell(win, 'computer');
        await win.PFApps.refresh();
        await win.PFApps.open('trucking');
        await settle();
        const frame = win.document.querySelector('[data-window="trucking"] iframe');
        ok(frame, 'iframe mounted');
        ok(frame.getAttribute('src').endsWith('device=computer'), frame.getAttribute('src'));
        const got = [];
        frame.contentWindow.postMessage = (m) => got.push(m);
        win.PFApps.handleMessage({ action: 'pfapp:event', app: 'trucking', event: 'nui', payload: { action: 'pf-trucking:setStatus', online: true } });
        win.PFApps.handleMessage({ action: 'pfapp:event', app: 'trucking', event: 'other', payload: { x: 1 } });
        eq(got[0].action, 'pf-trucking:setStatus', 'raw NUI message');
        eq(got[1].action, 'pfapp:event', 'other events wrapped');
    });

    console.log(`\n${passed} passed, ${failed} failed (pf-devices runtime)`);
    if (failed) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
})();
