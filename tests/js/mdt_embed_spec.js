// The MDT page embedded in a device window (?embed=1): device_embed.js fits the page, makes every
// callback reach the MDT resource (not the device that hosts the iframe), and tells the client the
// window opened and closed. Run: node js/mdt_embed_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');
const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]');

let passed = 0, failed = 0;
const failures = [];
function check(name, fn) { try { fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e.message}`); } }
function eq(a, b, m) { if (a !== b) throw new Error(`${m || ''} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }

for (const mdt of [{ dir: 'pf-policemdt-DEV', host: 'cfx-nui-pf-policemdt-dev' }, { dir: 'pf-emsmdt', host: 'cfx-nui-pf-emsmdt' }]) {
    const embed = fs.readFileSync(path.join(PF, mdt.dir, 'html/device_embed.js'), 'utf8');
    const html = fs.readFileSync(path.join(PF, mdt.dir, 'html/index.html'), 'utf8');
    check(`${mdt.dir}: the page loads the embed script after the app scripts`, () => {
        if (!/device_embed\.js/.test(html) || !/device_embed\.css/.test(html)) throw new Error('not referenced');
        if (html.indexOf('device_embed.js') < html.indexOf('app.js')) throw new Error('loaded before app.js');
    });
    for (const embedded of [true, false]) {
        const dom = new JSDOM('<!doctype html><html><body><div id="tabletFrame" class="tablet-frame"></div></body></html>',
            { url: `https://${mdt.host}/html/index.html${embedded ? '?embed=1&device=computer' : ''}`, runScripts: 'outside-only' });
        const w = dom.window;
        const posts = [];
        w.fetch = (url, opts) => { posts.push({ url, body: JSON.parse(opts.body), keepalive: opts.keepalive }); return Promise.resolve({ json: async () => ({ ok: true }) }); };
        // app.js's own resolver: inside an iframe GetParentResourceName names the device page
        w.GetParentResourceName = () => 'pf-tablet';
        w.eval('function getResourceName() { if (typeof window.GetParentResourceName === "function") return window.GetParentResourceName(); return "x"; }');
        w.eval(embed);
        w.dispatchEvent(new w.Event('load'));
        check(`${mdt.dir} embedded=${embedded}: resource and open message`, () => {
            if (embedded) {
                eq(w.getResourceName(), mdt.host.replace('cfx-nui-', ''), 'callbacks go to the MDT');
                eq(w.document.body.classList.contains('pf-embedded'), true, 'fits the window');
                eq(posts[0].url, `https://${mdt.host.replace('cfx-nui-', '')}/pfDeviceOpen`);
                eq(posts[0].body.device, 'computer');
                w.dispatchEvent(new w.Event('pagehide'));
                eq(posts[1].url.endsWith('/pfDeviceClosed'), true);
                eq(posts[1].keepalive, true);
            } else {
                eq(w.getResourceName(), 'pf-tablet', 'full-screen page unchanged');
                eq(posts.length, 0);
                eq(w.document.body.classList.contains('pf-embedded'), false);
            }
        });
    }
}
console.log(`\n${passed} passed, ${failed} failed (MDT embed)`);
if (failed) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
