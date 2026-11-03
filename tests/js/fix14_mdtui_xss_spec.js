// Batch 14, MDT-XSS-1..5, MDT-RTE-1 and MDT-DEAD-1: the police and EMS MDT pages loaded for real in
// jsdom (index.html with every local script, inline ones included, in page order) and fed the NUI
// messages the client sends. A string a player or an officer typed (character name, nationality,
// chat, notes, flags, warrant text, evidence status, photo URL) must show up as that text: it never
// becomes an element or an attribute, an onclick argument reaches its function unchanged, pictures
// come only from the allowed image hosts, rich text keeps only safe formatting, and a date that is
// not a date shows "Unknown".
// Run: node js/fix14_mdtui_xss_spec.js
// (MDT_UI_ROOT=<folder holding pf-policemdt-DEV/ and pf-emsmdt/> runs it against another copy.)
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

// A name a civilian can give a character, an officer can type into a note, a flag or the chat.
const EVIL = '"><img src=x onerror="window.__xss=1"><b id=pwn>x</b>\'-alert(1)-\'</script> ';
const EVIL_ID = "AB'1\"); window.__xss=1; ('";
const BAD_URL = 'https://cdn.discordapp.com/a.png");}*{background:url(//evil.tld/ip)';
const FOREIGN_URL = 'https://evil.tld/track.png';
const GOOD_URL = 'https://cdn.discordapp.com/attachments/1/2/photo.png?ex=1&is=2&hm=abc';

// Leaflet stand-in: every call chains; tooltips and popups are recorded (Leaflet puts a string
// tooltip into the page as HTML).
function leaflet(record) {
    const fn = function () {};
    const p = new Proxy(fn, {
        get(t, k) {
            if (k === Symbol.toPrimitive) return () => 0;
            if (k === 'then') return undefined;
            if (k === 'bindTooltip' || k === 'bindPopup') return (content) => { record.push({ kind: k, content }); return p; };
            return p;
        },
        apply() { return p; },
        construct() { return p; },
    });
    return p;
}

function boot(dir, { query = '', responses = {} } = {}) {
    const base = path.join(ROOT, dir, 'html');
    const html = fs.readFileSync(path.join(base, 'index.html'), 'utf8');
    const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)].map((m) => {
        const src = /\bsrc="([^"]+)"/.exec(m[1]);
        return src ? { file: src[1].split('?')[0] } : { inline: m[2] };
    }).filter((s) => s.inline !== undefined || !/^https?:/i.test(s.file));
    const errors = [];
    const vc = new VirtualConsole();
    vc.on('jsdomError', (e) => errors.push(String(e && e.message || e)));
    const dom = new JSDOM(html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, ''), {
        url: `https://cfx-nui-${dir.toLowerCase()}/html/index.html${query}`,
        runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole: vc,
    });
    const w = dom.window;
    const tooltips = [];
    const posts = [];
    w.L = leaflet(tooltips);
    w.GetParentResourceName = () => dir;
    w.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse((opts && opts.body) || '{}');
        posts.push({ name, body });
        const r = responses[name];
        const result = typeof r === 'function' ? r(body) : (r === undefined ? {} : r);
        return { ok: true, status: 200, json: async () => result, text: async () => JSON.stringify(result) };
    };
    const ctx = dom.getInternalVMContext();
    for (const s of scripts) {
        const code = s.inline !== undefined ? s.inline : fs.readFileSync(path.join(base, s.file), 'utf8');
        new vm.Script(code, { filename: s.file || 'inline' }).runInContext(ctx);
    }
    const run = (code) => new vm.Script(code).runInContext(ctx);
    const post = (data, source) => w.dispatchEvent(new w.MessageEvent('message', source === undefined ? { data } : { data, source }));
    // Runs an element's inline handler the way the browser compiles it (the attribute value after
    // HTML decoding), with `this` set to the element.
    const router = () => run('router'); // a top-level let, not a window property
    const click = (el, attr = 'onclick') => {
        w.__handlerEl = el;
        run(`(function (event) {\n${el.getAttribute(attr)}\n}).call(window.__handlerEl, { stopPropagation() {}, preventDefault() {} })`);
    };
    return { w, dom, posts, tooltips, errors, run, post, click, router };
}

async function open(mdt) {
    mdt.post({ action: 'open', calls: [], config: { localeData: {}, map: {} }, permissions: { allowed: true, isSupervisor: true, isOwner: true },
        user: { name: 'Officer Test', rank: 'Chief', rankLevel: 4, grade: 'Chief', callsign: '1-A' } });
    await settle();
    ok(mdt.run('typeof router !== "undefined" && !!router'), 'the MDT opened (router created)');
}

function noInjection(mdt, where, root) {
    const scope = root || mdt.w.document;
    eq(scope.querySelectorAll('img[src="x"], #pwn, [onerror]').length, 0, `${where}: a typed string became an element`);
    eq(mdt.w.__xss, undefined, `${where}: script ran`);
}

function textOf(el) { return el ? el.textContent : null; }

(async () => {
    // ── helpers (police app.js) ─────────────────────────────────────────
    const police = boot('pf-policemdt-DEV');
    await open(police);
    const P = police.w;

    await it('police: escapeJsAttr keeps any string intact inside an onclick JS string', async () => {
        const div = P.document.createElement('div');
        P.document.body.appendChild(div);
        for (const v of [EVIL, EVIL_ID, "O'Brien", 'a\\b', '</script><script>x</script>', ' x']) {
            div.innerHTML = `<button onclick="window.__got = ('${P.escapeJsAttr(v)}')">x</button>`;
            police.click(div.firstChild);
            eq(P.__got, v, 'onclick argument');
        }
        div.remove();
    });

    await it('police: picture URLs only from the allowed hosts, quotes never pass, CSS url() cannot break', async () => {
        eq(P.safeImageUrl(GOOD_URL), GOOD_URL, 'an uploaded screenshot keeps working');
        eq(P.safeImageUrl('https://media.discordapp.net/x.jpg'), 'https://media.discordapp.net/x.jpg');
        eq(P.safeImageUrl(FOREIGN_URL), '', 'unknown host');
        eq(P.safeImageUrl('https://cdn.discordapp.com.evil.tld/x.png'), '', 'look-alike host');
        eq(P.safeImageUrl(BAD_URL), '', 'quote in the URL');
        eq(P.safeImageUrl('javascript:alert(1)'), '');
        eq(P.safeImageUrl('https://cdn.discordapp.com/x&#39;);.png'), '', 'character reference');
        eq(P.safeCssUrl(GOOD_URL), GOOD_URL, 'query string kept for the CDN signature');
        eq(P.safeCssUrl("https://i.imgur.com/a(b).png"), 'https://i.imgur.com/a%28b%29.png');
        P.setMdtImageHosts(['images.example.com']);
        eq(P.safeImageUrl('https://images.example.com/a.png'), 'https://images.example.com/a.png', 'config.imageHosts replaces the list');
        eq(P.safeImageUrl(GOOD_URL), '');
        P.setMdtImageHosts(['cdn.discordapp.com', 'media.discordapp.net', 'i.imgur.com', 'fivemanage.com', 'r2.fivemanage.com']);
    });

    await it('police: formatDateTime shows "Unknown" for anything that is not a date (MDT-XSS-5)', async () => {
        eq(P.formatDateTime(EVIL), 'Unknown');
        eq(P.formatDateTime('<img src=x onerror=alert(1)>'), 'Unknown');
        ok(/^\d\d\/\d\d\/\d{4}$/.test(P.formatDateTime('2026-11-02 10:00:00')), 'a real date still formats');
    });

    // ── MDT-XSS-1: civilian character data ───────────────────────────────
    await it('police: citizen search cards show names, nationality, job, DOB and phone as text', async () => {
        police.run("router.set('citizens')");
        police.post({ action: 'setCitizens', totalCount: 1, citizens: [{ citizenId: EVIL_ID, name: EVIL, nationality: EVIL, job: EVIL, dob: EVIL, phone: EVIL, licenses: [EVIL] }] });
        await settle();
        const card = P.document.querySelector('#citizenGrid .citizen-card');
        ok(card, 'card rendered');
        noInjection(police, 'citizen cards', card);
        eq(textOf(card.querySelector('.card-name')), EVIL, 'name');
        ok(card.textContent.includes(EVIL), 'nationality/job/dob/phone as text');
        let opened = null;
        police.router().openCitizenProfile = (id) => { opened = id; };
        police.click(card);
        eq(opened, EVIL_ID, 'the profile opens for the exact citizen id');
    });

    await it('police: citizen profile (overview, licenses, flags, notes, warrants, vehicles, reports) is text', async () => {
        const profile = {
            citizenId: EVIL_ID, name: EVIL, firstname: EVIL, lastname: EVIL, dob: EVIL, age: 30, gender: EVIL, nationality: EVIL, phone: EVIL,
            job: EVIL, address: EVIL, profilePicture: BAD_URL,
            appearance: { skinToneLabel: EVIL, hairColorLabel: EVIL, eyeColorLabel: EVIL, hairHighlightLabel: EVIL },
            licenses: { driver: true }, licenseSuspensions: {}, flags: [EVIL], notes: [{ text: EVIL, author: EVIL, createdAt: EVIL }],
            warrants: [{ warrantId: EVIL_ID, status: 'active', issuedBy: EVIL, createdAt: EVIL, charges: [EVIL], narrative: EVIL, suspectName: EVIL, title: EVIL }],
            vehicles: [{ plate: EVIL_ID, model: EVIL, brand: EVIL }], vehicleCount: EVIL,
            incidents: [{ incidentId: EVIL_ID, title: EVIL, location: EVIL, createdAt: EVIL, status: EVIL }],
            reports: [{ reportId: EVIL, type: EVIL, title: EVIL, officer: EVIL, createdAt: EVIL }],
            properties: [{ name: EVIL, address: EVIL, source: EVIL, coords: { x: 1, y: 2, z: 3 } }],
            government: { licenses: [{ type: EVIL, status: EVIL }], unpaidBills: [{ id: EVIL, type: EVIL, owed: 1, description: EVIL }], businesses: [{ name: EVIL, type: EVIL }] },
            warrantCount: EVIL, convictionCount: EVIL,
        };
        police.post({ action: 'setCitizenProfile', profile });
        await settle();
        noInjection(police, 'citizen profile', P.document.getElementById('citizenProfileModal'));
        const header = P.document.getElementById('citizenIdentityHeader');
        eq(textOf(header.querySelector('.citizen-name')), EVIL, 'name in the header');
        const photo = P.document.getElementById('citizenProfilePhoto');
        ok(!/evil|url\(/.test(photo.getAttribute('style') || ''), 'a photo URL with quotes is not used');
        const content = P.document.getElementById('citizenProfileContent');
        ok(content.textContent.includes(EVIL), 'overview fields as text');
        eq(P.document.querySelector('#citizenSummaryBar .summary-value').textContent, '0', 'counts are numbers');

        const calls = [];
        const realDetails = P.openWarrantDetails;
        P.openLicenseModal = (s) => calls.push(['license', JSON.parse(s)]);
        P.openFlagRemoveModal = (s) => calls.push(['flag', JSON.parse(s)]);
        P.openNewWarrantForCitizen = (...a) => calls.push(['warrant', a]);
        P.openNewReportForCitizen = (...a) => calls.push(['report', a]);
        P.openIncidentDetails = (...a) => calls.push(['incident', a]);
        P.openWarrantDetails = (...a) => calls.push(['details', a]);
        police.router().openVehicleProfile = (...a) => calls.push(['vehicle', a]);
        police.click(content.querySelector('.license-badge[onclick]'));
        police.click(content.querySelector('.flag-chip[onclick]'));
        police.click(content.querySelector('[onclick^="openNewWarrantForCitizen"]'));
        police.click(content.querySelector('[onclick^="openNewReportForCitizen"]'));
        police.click(content.querySelector('.incident-item'));
        police.click(content.querySelector('.vehicle-item button'));
        police.click(content.querySelector('.warrant-item button.btn[onclick*="openWarrantDetails"]'));
        const byKind = Object.fromEntries(calls.map((c) => [c[0], c[1]]));
        eq(byKind.license.citizenName, EVIL, 'license modal gets the name unchanged');
        eq(byKind.license.citizenId, EVIL_ID);
        eq(byKind.flag.flag, EVIL, 'flag text unchanged');
        eq(byKind.warrant[0], EVIL_ID); eq(byKind.warrant[1], EVIL, 'new warrant gets the name unchanged');
        eq(byKind.report[1], EVIL);
        eq(byKind.incident[0], EVIL_ID);
        eq(byKind.vehicle[0], EVIL_ID, 'vehicle plate unchanged');
        eq(byKind.details[0], EVIL_ID); eq(byKind.details[3], EVIL, 'warrant narrative unchanged');
        eq(JSON.parse(byKind.details[4])[0], EVIL, 'charges unchanged');
        police.posts.length = 0;
        police.click(content.querySelector('.warrant-item .btn.success'));
        await settle();
        const served = police.posts.find((p) => p.name === 'updateWarrantStatus');
        ok(served, 'Mark as Served posts');
        eq(served.body.warrantId, EVIL_ID); eq(served.body.citizenId, EVIL_ID); eq(served.body.status, 'served');
        P.openWarrantDetails = realDetails;
    });

    await it('police: a profile photo on an allowed host is shown', async () => {
        police.post({ action: 'setCitizenProfile', profile: { citizenId: 'C1', name: 'Jane Doe', profilePicture: GOOD_URL } });
        await settle();
        const style = P.document.getElementById('citizenProfilePhoto').getAttribute('style');
        ok(style.includes(GOOD_URL), `photo kept: ${style}`);
    });

    // ── MDT-XSS-2/3: officer-typed text ──────────────────────────────────
    await it('police: warrant cards and the details modal show warrant text as text', async () => {
        police.run("router.set('warrant')");
        police.post({ action: 'setWarrants', totalCount: 1, warrants: [{ warrantId: EVIL, suspectName: EVIL, issuedBy: EVIL, issuedAt: EVIL, charges: [EVIL], narrative: EVIL, title: EVIL, status: 'active', officers: [EVIL], witnesses: [{ name: EVIL, statement: EVIL }] }] });
        await settle();
        const grid = P.document.getElementById('warrantGrid');
        noInjection(police, 'warrant cards', grid);
        eq(textOf(grid.querySelector('.warrant-suspect')), EVIL);
        eq(grid.querySelectorAll('[onclick]').length, 0, 'no inline handler carries the warrant');
        grid.querySelector('button[data-warrant-index]').dispatchEvent(new P.MouseEvent('click', { bubbles: true }));
        await settle();
        noInjection(police, 'warrant details', P.document.getElementById('warrantDetailsModal') || P.document.body);
        const body = P.document.getElementById('warrantDetailsBody') || P.document.getElementById('warrantDetailsModal');
        ok(body && body.textContent.includes(EVIL), 'details show the narrative as text');
    });

    await it('police: incident cards show title, location, officer and people as text; bad dates are "Unknown"', async () => {
        police.run("router.set('incidents')");
        police.post({ action: 'setIncidents', incidents: [{ id: EVIL, title: EVIL, location: EVIL, reportingOfficer: EVIL, status: EVIL, dateTime: EVIL, involvedCitizens: [EVIL] }] });
        await settle();
        const card = P.document.querySelector('#incidentGrid .incident-card');
        ok(card, 'card rendered');
        noInjection(police, 'incident cards', card);
        eq(textOf(card.querySelector('.incident-title')), EVIL);
        ok(card.textContent.includes('Unknown'), 'the invalid date shows Unknown');
        ok(/^incident-status status-[a-z0-9_-]*$/.test(card.querySelector('.incident-status').className), 'status class is a slug');
    });

    await it('police: evidence grid status, number and picture cannot inject (free-text status)', async () => {
        police.run("router.set('evidence')");
        police.post({ action: 'setEvidence', totalCount: 1, evidence: [{ evidence_number: EVIL, title: EVIL, status: EVIL, image_url: BAD_URL, created_by_name: EVIL, created_at: EVIL }] });
        await settle();
        const card = P.document.querySelector('#evidenceGrid .evidence-card');
        ok(card, 'card rendered');
        noInjection(police, 'evidence grid', card);
        ok(!/evil/.test(card.querySelector('.evidence-image').getAttribute('style')), 'no foreign url() in the style');
        const badge = card.querySelector('.evidence-status');
        eq(badge.textContent, EVIL.toUpperCase(), 'status as text');
        ok(/^evidence-status status-[a-z0-9_-]*$/.test(badge.className), 'status class is a slug');
    });

    await it('police: dashboard chat lines from other officers are text', async () => {
        police.run("router.set('dashboard')");
        await settle();
        police.router().pages.get('dashboard').onMessage({ action: 'chatMessage', name: EVIL, message: EVIL });
        const last = [...P.document.querySelectorAll('#chatMessages .chat-message')].pop();
        ok(last, 'chat line rendered');
        noInjection(police, 'chat', last);
        eq(textOf(last.querySelector('.chat-author')), EVIL);
        eq(textOf(last.querySelector('.chat-text')), EVIL);
    });

    await it('police: unit map tooltips are escaped (Leaflet writes a string tooltip as HTML)', async () => {
        police.tooltips.length = 0;
        police.run("router.set('dispatch')");
        await settle();
        police.router().pages.get('dispatch').updateUnitMarkers([{ source: 7, name: EVIL, coords: { x: 1, y: 2 } }]);
        const t = police.tooltips.find((x) => x.kind === 'bindTooltip');
        ok(t, 'tooltip bound');
        eq(t.content, P.escapeHtml(EVIL));
    });

    await it('police: dispatch call cards are text and a numeric call id still opens its call', async () => {
        police.run("router.set('dispatch')");
        await settle();
        police.post({ action: 'setCalls', calls: [{ id: 12, title: EVIL, locationLabel: EVIL, status: 'pending', priority: 2, createdAt: Math.floor(Date.now() / 1000), assignedUnitNames: [EVIL], coords: { x: 1, y: 2, z: 3 } }] });
        await settle();
        const card = P.document.querySelector('#dispatchCallsList .dispatch-call-card');
        ok(card, 'call card rendered');
        noInjection(police, 'dispatch calls', card);
        eq(textOf(card.querySelector('.dispatch-call-title')), EVIL);
        eq(card.getAttribute('onclick'), null, 'no inline handler');
        card.dispatchEvent(new P.MouseEvent('click', { bubbles: true }));
        eq(police.router().pages.get('dispatch').selectedCallId, 12, 'the call is selected by its real id');
        eq(textOf(P.document.getElementById('modalCallTitle')), EVIL, 'details modal shows the title as text');
    });

    await it('police: witness list and dropdown (every online name) are text', async () => {
        police.run("router.set('warrant')");
        await settle();
        const players = [{ name: EVIL, citizenid: EVIL_ID }];
        P.fetch = async (url) => ({ ok: true, json: async () => (String(url).endsWith('/getAllPlayers') ? players : {}) });
        P.openNewWarrantModal();
        await settle();
        const input = P.document.getElementById('warrantWitnessNameInput');
        ok(input, 'witness input exists');
        input.dispatchEvent(new P.Event('focus'));
        await settle();
        noInjection(police, 'witness dropdown', P.document.getElementById('warrantWitnessDropdown'));
        const item = P.document.querySelector('#warrantWitnessDropdown .dropdown-item');
        ok(item, 'dropdown rendered');
        eq(item.textContent, EVIL);
        eq(item.getAttribute('data-pick'), EVIL, 'picked value is the exact name');
        const select = P.document.getElementById('warrantWitnessAddSelect') || P.document.querySelector('select[id*="Witness"]');
        if (select) {
            ok([...select.options].some((o) => o.textContent === EVIL), 'select lists the name as text');
        }
        P.__selectedWitnesses = [{ name: EVIL, phone: EVIL, statement: EVIL }];
        P.__removeWitness(99); // re-renders the list
        noInjection(police, 'witness list', P.document.getElementById('warrantWitnessesList'));
        ok(P.document.getElementById('warrantWitnessesList').textContent.includes(EVIL));
    });

    // ── MDT-XSS-4 / MDT-RTE-1: pictures and rich text ────────────────────
    await it('police: report details keep only allowed pictures and clean rich text', async () => {
        const narrative = '<p style="position:fixed;inset:0;background:url(https://evil.tld/a)">Body</p>'
            + '<p style="text-align: center">Centered</p><img src="https://evil.tld/p.png"><img src="' + GOOD_URL + '" style="width: 50%; position: fixed">'
            + '<img src=x onerror="window.__xss=1"><script>window.__xss=1</script><a href="https://evil.tld">link</a><svg><script>window.__xss=1</script></svg>';
        P.fetch = async (url) => ({ ok: true, json: async () => (String(url).endsWith('/getReport')
            ? { success: true, report: { title: EVIL, officer: EVIL, location: EVIL, type: EVIL, narrative, linkedEvidence: [{ url: FOREIGN_URL, title: EVIL }, { url: GOOD_URL, title: 'ok' }, BAD_URL] } }
            : {}) });
        P.openReportDetails('R1');
        await settle();
        noInjection(police, 'report details', P.document.getElementById('reportDetailsModal'));
        const modal = P.document.getElementById('reportDetailsModal');
        ok(modal, 'modal open');
        const imgs = [...modal.querySelectorAll('img')].map((i) => i.getAttribute('src'));
        ok(imgs.length >= 2 && imgs.every((s) => s === GOOD_URL), `only allowed pictures: ${JSON.stringify(imgs)}`);
        const view = modal.querySelector('.rte-view');
        ok(!/position|fixed|url\(|evil/.test(view.innerHTML), `styles cleaned: ${view.innerHTML}`);
        ok(/text-align: center/.test(view.innerHTML), 'alignment kept');
        ok(/width: 50%/.test(view.innerHTML), 'picture size kept');
        eq(view.querySelectorAll('a, script, svg').length, 0, 'links unwrapped, scripts and svg removed');
        ok(view.textContent.includes('link'), 'link text kept');
        modal.remove();
    });

    await it('police: sanitizeRteHtml is an allow list (tags, attributes, styles)', async () => {
        const out = P.sanitizeRteHtml('<div class="modal" id="x" data-a="1" title="t"><b>B</b><u>U</u><h2>H</h2><ul><li>L</li></ul><pre>C</pre>'
            + '<span style="font-weight: bold; color: red; text-decoration: underline">S</span><marquee>M</marquee><style>*{}</style><form><input></form></div>');
        const box = P.document.createElement('div');
        box.innerHTML = out;
        const root = box.firstChild;
        eq(root.attributes.length, 0, `attributes dropped: ${out}`);
        ok(root.querySelector('b') && root.querySelector('u') && root.querySelector('h2') && root.querySelector('li') && root.querySelector('pre'), 'formatting kept');
        eq(root.querySelector('span').getAttribute('style'), 'font-weight: bold; text-decoration: underline', 'only allowed style properties');
        eq(box.querySelectorAll('marquee, style, form, input').length, 0, 'unknown tags unwrapped, blocked ones removed');
        ok(box.textContent.includes('M'), 'unwrapped text kept');
        eq(P.sanitizeRteHtml('plain text'), 'plain text', 'plain text unchanged');
    });

    await it('police: image lightbox and report photo list refuse foreign hosts', async () => {
        P.showImageLightbox(FOREIGN_URL);
        eq(P.document.getElementById('imageLightboxBackdrop'), null, 'no lightbox for a foreign host');
        P.showImageLightbox(GOOD_URL);
        eq(P.document.querySelector('#imageLightboxBackdrop img').getAttribute('src'), GOOD_URL);
        P.closeImageLightbox();
    });

    // ── MDT-DEAD-1 ───────────────────────────────────────────────────────
    await it('police: the unused legacy vehicle renderer is gone; pf-tablet no longer ships its dead mechanic.js', async () => {
        const ext = fs.readFileSync(path.join(ROOT, 'pf-policemdt-DEV/html/app-extended.js'), 'utf8');
        ok(!/function renderVehicleProfile\s*\(/.test(ext), 'renderVehicleProfile removed');
        const manifest = fs.readFileSync(path.join(ROOT, 'pf-tablet/fxmanifest.lua'), 'utf8');
        ok(!/^\s*'html\/mechanic\.js'/m.test(manifest), 'not in the manifest');
        ok(!fs.existsSync(path.join(ROOT, 'pf-tablet/html/mechanic.js')), 'file removed');
    });

    // ── EMS MDT ──────────────────────────────────────────────────────────
    const ems = boot('pf-emsmdt');
    await open(ems);
    const E = ems.w;

    await it('ems: formatDateTime shows "Unknown" for anything that is not a date', async () => {
        eq(E.formatDateTime(EVIL), 'Unknown');
    });

    await it('ems: patient search results and the patient profile are text', async () => {
        ems.run("router.set('citizens')");
        await settle();
        ems.post({ action: 'setCitizens', totalCount: 1, citizens: [{ citizenId: EVIL_ID, citizenid: EVIL_ID, name: EVIL, firstname: EVIL, lastname: EVIL, dob: EVIL, phone: EVIL, gender: EVIL, job: EVIL, nationality: EVIL }] });
        await settle();
        noInjection(ems, 'patient search', E.document.getElementById('citizensResults'));
        ok(E.document.getElementById('citizensResults').textContent.includes(EVIL), 'names as text');
        ems.post({ action: 'setCitizenProfile', profile: { citizenId: EVIL_ID, name: EVIL, dob: EVIL, phone: EVIL, gender: EVIL, job: EVIL, address: EVIL,
            notes: [{ text: EVIL, author: EVIL, createdAt: EVIL }], medical: { allergies: [EVIL], conditions: [EVIL], medications: [EVIL], injuries: [EVIL], bloodType: EVIL } } });
        await settle();
        noInjection(ems, 'patient profile', E.document.getElementById('citizenProfileModal'));
        ok(E.document.getElementById('citizenProfileContent').textContent.includes(EVIL), 'profile as text');
    });

    await it('ems: dashboard chat and unit tooltips are text', async () => {
        ems.run("router.set('dashboard')");
        await settle();
        ems.router().pages.get('dashboard').addChatMessage(EVIL, EVIL, false);
        noInjection(ems, 'ems chat');
        const last = [...E.document.querySelectorAll('#chatMessages .chat-message')].pop();
        eq(textOf(last.querySelector('.chat-text')), EVIL);
        ems.tooltips.length = 0;
        ems.run("router.set('dispatch')");
        await settle();
        ems.router().pages.get('dispatch').updateUnitMarkers([{ source: 3, name: EVIL, coords: { x: 1, y: 2 } }]);
        const t = ems.tooltips.find((x) => x.kind === 'bindTooltip');
        ok(t, 'tooltip bound');
        eq(t.content, E.escapeHtml(EVIL));
    });

    for (const m of [police, ems]) {
        if (m.errors.length) failures.push(`script errors while running: ${m.errors.slice(0, 5).join(' | ')}`);
    }
    console.log(`\n${passed} passed, ${failed} failed (MDT UI text-only)`);
    if (failed) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
    process.exit(0);
})();
