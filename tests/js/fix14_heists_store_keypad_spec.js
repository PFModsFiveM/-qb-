// pfm-storerobbery NUI (batch 14): only the keypad of keypad safes is left in the page (register
// lockpicks and padlock dials are server-judged pfm-minigames challenges). The keypad is built with
// DOM calls, takes at most 4 digits and posts the guess for the server to check.
// Run: node js/fix14_heists_store_keypad_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');

const HTML = path.resolve(__dirname, '..', '..', 'pfm-storerobbery', 'html');

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }

function makePage() {
    const errors = [];
    const vc = new VirtualConsole();
    vc.on('jsdomError', (e) => { if (!/Not implemented|Could not load/.test(String(e && e.message))) errors.push(e); });
    const body = fs.readFileSync(path.join(HTML, 'index.html'), 'utf8').replace(/<script[^>]*><\/script>/g, '').replace(/<link[^>]*>/g, '');
    const dom = new JSDOM(body, { runScripts: 'dangerously', url: 'https://cfx-nui-pfm-storerobbery/html/index.html', virtualConsole: vc });
    const win = dom.window;
    const posts = [];
    win.GetParentResourceName = () => 'pfm-storerobbery';
    win.fetch = (url, opts) => {
        posts.push({ name: String(url).replace(/^https:\/\/[^/]+\//, ''), body: opts && opts.body ? JSON.parse(opts.body) : null });
        return Promise.resolve({});
    };
    const el = win.document.createElement('script');
    el.textContent = fs.readFileSync(path.join(HTML, 'script.js'), 'utf8');
    win.document.body.appendChild(el);
    const send = (data) => win.dispatchEvent(new win.MessageEvent('message', { data }));
    const press = (label) => {
        const btn = [...win.document.querySelectorAll('#keypad input[type=button]')].find((b) => b.value === label);
        ok(btn, `button ${label}`);
        btn.click();
    };
    return { win, posts, send, press, errors };
}

(async () => {
    await it('the page holds only the keypad: no lockpick or padlock UI is left', async () => {
        const { win, errors } = makePage();
        eq(win.document.getElementById('wrap'), null, 'pin lockpick removed');
        eq(win.document.getElementById('padlock'), null, 'padlock dial removed');
        ok(win.document.getElementById('keypad'));
        eq(errors.length, 0, 'script errors');
    });

    await it('typing at most 4 digits and enter posts the guess; clear empties it', async () => {
        const { win, posts, send, press, errors } = makePage();
        send({ action: 'openKeypad' });
        eq(win.document.getElementById('keypad').style.display, 'block');
        press('9'); press('1');
        press('clear');
        ['1', '2', '3', '4', '5'].forEach(press);
        eq(win.document.getElementById('PINbox').value, '1234');
        press('enter');
        eq(win.document.getElementById('keypad').style.display, 'none');
        const tries = posts.filter((p) => p.name === 'TryCombination');
        eq(tries.length, 1);
        eq(tries[0].body.combination, '1234');
        eq(errors.length, 0, 'script errors');
    });

    await it('closing (wrong code or Escape) tells the client script, without script errors', async () => {
        const { win, posts, send, errors } = makePage();
        send({ action: 'openKeypad' });
        send({ action: 'closeKeypad', error: true });
        ok(posts.some((p) => p.name === 'PadLockClose'));
        ok(posts.some((p) => p.name === 'CombinationFail'));
        send({ action: 'openKeypad' });
        win.document.dispatchEvent(new win.KeyboardEvent('keyup', { key: 'Escape' }));
        eq(win.document.getElementById('keypad').style.display, 'none');
        eq(errors.length, 0, 'script errors');
    });

    console.log(`${passed} passed, ${failed} failed`);
    if (failures.length) { console.log(failures.join('\n')); process.exit(1); }
})();
