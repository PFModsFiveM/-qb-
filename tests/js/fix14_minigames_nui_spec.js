// pfm-minigames NUI (batch 14): with a server challenge the games play the server's puzzle (keys,
// zones, pattern, hidden angle, code positions) and send back the raw answer the server judges
// (server/challenge.lua); without one they behave as before for the old client exports.
// All scripts load into one page as index.html loads them (one global scope).
// Run: node js/fix14_minigames_nui_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');

const HTML = path.resolve(__dirname, '..', '..', 'pfm-minigames', 'html');
const SCRIPTS = ['hacking', 'keyminigame', 'lockpick', 'pinpad', 'quiz', 'skillbar', 'wordguess', 'wordscramble'];

let passed = 0;
let failed = 0;
const failures = [];
let pages = []; // pages made by the running test: none may log a script error
async function it(name, fn) {
    pages = [];
    try {
        await fn();
        const errors = pages.flatMap((p) => p.errors);
        if (errors.length) throw new Error(`script errors: ${errors.map((e) => e.message).join('; ')}`);
        passed++;
    } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function makePage({ manualTimers = false } = {}) {
    const errors = [];
    const vc = new VirtualConsole();
    vc.on('jsdomError', (e) => { if (!/Not implemented|Could not load/.test(String(e && e.message))) errors.push(e); });
    const body = fs.readFileSync(path.join(HTML, 'index.html'), 'utf8').replace(/<script[^>]*><\/script>/g, '').replace(/<link[^>]*>/g, '');
    const dom = new JSDOM(body, { runScripts: 'dangerously', url: 'https://cfx-nui-pfm-minigames/html/index.html', virtualConsole: vc });
    const win = dom.window;
    const posts = [];
    win.GetParentResourceName = () => 'pfm-minigames';
    win.fetch = (url, opts) => {
        posts.push({ name: String(url).replace(/^https:\/\/[^/]+\//, ''), body: opts && opts.body ? JSON.parse(opts.body) : null });
        return Promise.resolve({ json: async () => ({}) });
    };
    const noop = () => {};
    win.HTMLCanvasElement.prototype.getContext = () => new Proxy({}, { get: () => noop, set: () => true });
    win.HTMLMediaElement.prototype.load = noop;
    win.HTMLMediaElement.prototype.play = () => Promise.resolve();
    win.Element.prototype.animate = () => ({ onfinish: null });
    // animation frames run only when the spec says so, with the timestamp it gives
    const frames = new Map();
    let nextFrame = 1;
    win.requestAnimationFrame = (cb) => { frames.set(nextFrame, cb); return nextFrame++; };
    win.cancelAnimationFrame = (id) => { frames.delete(id); };
    const frame = (ts) => { const list = [...frames.values()]; frames.clear(); list.forEach((cb) => cb(ts)); };
    const timers = [];
    if (manualTimers) win.setTimeout = (fn) => { timers.push(fn); return timers.length; };
    const flushTimers = () => { while (timers.length) timers.shift()(); };
    for (const name of SCRIPTS) {
        const el = win.document.createElement('script');
        el.textContent = fs.readFileSync(path.join(HTML, 'js', `${name}.js`), 'utf8');
        win.document.body.appendChild(el);
    }
    const message = (data) => win.dispatchEvent(new win.MessageEvent('message', { data }));
    const key = (k, type = 'keydown') => win.document.dispatchEvent(new win.KeyboardEvent(type, { key: k }));
    const page = { win, posts, errors, frame, flushTimers, message, key };
    pages.push(page);
    return page;
}

const deg = (rad) => (rad * 180) / Math.PI;
// the server's skillbar rule (server/challenge.lua skillbarCheck): the indicator's angle at the
// press, from its run time, lies in the round's zone, and the right key was pressed
function serverSkillbarOk(puzzle, presses) {
    return puzzle.rounds.every((r, i) => {
        const p = presses[i];
        if (!p || p.k !== r.key) return false;
        const at = (p.ms * puzzle.speed * 10) / 1000;
        return at >= deg(r.start) - 0.5 && at <= deg(r.start + r.size) + 0.5;
    });
}

(async () => {
    await it('every game script loads into one page without clashing names', async () => {
        const page = makePage();
        eq(page.errors.length, 0, `script errors: ${page.errors.map((e) => e.message).join('; ')}`);
    });

    await it("skillbar: a challenge's rounds are played and the presses come back with the indicator's run time", async () => {
        const page = makePage();
        const puzzle = { difficulty: 'medium', speed: 25, keys: '12', rounds: [{ key: '1', start: 2.0, size: 0.8 }, { key: '2', start: 3.0, size: 0.8 }] };
        page.message({ action: 'openSkillbar', challenge: puzzle });
        page.frame(1000);
        page.frame(1550); // 550 ms: 137.5 degrees, inside 114.6..160.4
        page.key('1');
        page.frame(2000);
        page.frame(2780); // 780 ms: 195 degrees, inside 171.9..217.7
        page.key('2');
        const done = page.posts.filter((p) => p.name === 'skillbarFinish');
        eq(done.length, 1);
        eq(done[0].body.success, true);
        eq(JSON.stringify(done[0].body.presses), JSON.stringify([{ k: '1', ms: 550 }, { k: '2', ms: 780 }]));
        ok(serverSkillbarOk(puzzle, done[0].body.presses), 'the answer passes the server rule');
    });

    await it('skillbar: a wrong key ends the game and is sent as pressed', async () => {
        const page = makePage();
        const puzzle = { speed: 25, keys: '12', rounds: [{ key: '1', start: 2.0, size: 0.8 }, { key: '2', start: 3.0, size: 0.8 }] };
        page.message({ action: 'openSkillbar', challenge: puzzle });
        page.frame(1000);
        page.frame(1550);
        page.key('2');
        const done = page.posts.filter((p) => p.name === 'skillbarFinish');
        eq(done[0].body.success, false);
        eq(done[0].body.presses[0].k, '2');
        ok(!serverSkillbarOk(puzzle, done[0].body.presses));
    });

    await it('skillbar without a challenge (old Skillbar export) still runs on its own and fails when the indicator runs out', async () => {
        const page = makePage();
        page.message({ action: 'openSkillbar', difficulty: 'easy', validKeys: '1234' });
        page.frame(1000);
        page.frame(1000 + 2500); // 150 degrees a second: past 360 after 2.4 s
        const done = page.posts.filter((p) => p.name === 'skillbarFinish');
        eq(done.length, 1);
        eq(done[0].body.success, false);
    });

    await it("keys: the challenge's pattern and timings are played; the first press of each step comes back", async () => {
        const page = makePage();
        const puzzle = { amount: 3, pattern: ['ArrowUp', 'ArrowLeft', 'ArrowDown'], lead: 50, step: 250, window: 180 };
        page.message({ action: 'startKeygame', amount: 3, challenge: puzzle });
        await sleep(50 + 60);
        page.key('ArrowUp');
        page.key('ArrowDown'); // a second press in the same step is not the answer
        await sleep(250);
        page.key('ArrowLeft');
        await sleep(250);
        page.key('ArrowUp'); // wrong key for ArrowDown
        await sleep(400);
        const done = page.posts.filter((p) => p.name === 'keyminigameFinish');
        eq(done.length, 1);
        const presses = done[0].body.presses;
        eq(presses.length, 3);
        eq(presses.map((p) => `${p.s}:${p.k}`).join(','), '1:ArrowUp,2:ArrowLeft,3:ArrowUp');
        ok(presses.every((p) => p.ms >= 0 && p.ms < puzzle.window), `times after each key lit: ${presses.map((p) => p.ms)}`);
        eq(done[0].body.faults, 1);
    });

    await it('lockpick: the server angle opens it; the push angle, time and broken pins come back', async () => {
        const page = makePage();
        page.message({ action: 'startLockpick', pins: 3, challenge: { pins: 3, solve: 30.5, padding: 4 } });
        page.win.document.dispatchEvent(new page.win.MouseEvent('mousemove', { clientX: 61 })); // pin at 30.5 degrees
        page.key('w');
        for (let i = 0; i < 40; i++) page.frame(i * 16);
        const done = page.posts.filter((p) => p.name === 'lockpickFinish');
        eq(done.length, 1);
        eq(done[0].body.success, true);
        eq(done[0].body.a, 30.5);
        eq(done[0].body.broken, 0);
        ok(typeof done[0].body.ms === 'number');
    });

    await it('lockpick: escape reports the pins broken so far', async () => {
        const page = makePage();
        page.message({ action: 'startLockpick', pins: 3, challenge: { pins: 3, solve: -40, padding: 4 } });
        page.key('Escape');
        const done = page.posts.filter((p) => p.name === 'lockpickExit');
        eq(done.length, 1);
        eq(done[0].body.broken, 0);
    });

    await it("hacking: the challenge's codes sit where the server put them; each submit comes back with its position", async () => {
        const page = makePage({ manualTimers: true });
        const blocks = [{ row: 2, col: 3, code: 'AB' }, { row: 5, col: 10, code: 'CD' }];
        page.message({ action: 'startHack', solutionsize: 2, timeout: 30, challenge: { size: 2, seconds: 30, blocks } });
        page.frame(1000); // draws the grid with the codes
        eq(page.win.document.getElementById('23').textContent + page.win.document.getElementById('24').textContent, 'AB');
        page.key(' '); // a wrong submit at 1,1
        page.key('s');
        page.key('d');
        page.key('d');
        page.key(' ');
        for (let i = 0; i < 4; i++) page.key('ArrowDown');
        for (let i = 0; i < 7; i++) page.key('ArrowLeft'); // from column 17 to 10
        page.key('Enter');
        page.flushTimers();
        const done = page.posts.filter((p) => p.name === 'hackSuccess');
        eq(done.length, 1);
        const subs = done[0].body.submits.map((s) => `${s.b}@${s.r},${s.c}`).join(' ');
        eq(subs, '1@1,1 1@2,3 2@5,10');
    });

    await it('hacking without a challenge (old Hacking export) makes its own codes', async () => {
        const page = makePage({ manualTimers: true });
        page.message({ action: 'startHack', solutionsize: 4, timeout: 1 });
        page.key('Escape');
        const done = page.posts.filter((p) => p.name === 'hackClosed');
        eq(done.length, 1);
        eq(done[0].body.userCancelled, true);
    });

    console.log(`${failed ? 'FAIL' : 'ok'}  fix14_minigames_nui_spec.js  (${passed} passed, ${failed} failed)`);
    failures.forEach((f) => console.log(`  - ${f}`));
    process.exit(failed ? 1 : 0);
})();
