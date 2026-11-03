// Batch 14, X1 / X2 in jsdom:
//  * pfm-menu shows header, text and icon as text: a dish name such as
//    `<img src=x onerror=postData(1)>` in a restaurant bill can no longer become an element that
//    clicks "Pay" for the customer; the escape helper also escapes quotes (icons are attribute
//    values); the legacy <br> line break of old callers (pfm-crafting) still breaks the line;
//  * the pf-restaurants menu board, kitchen display and POS put every menu string in the page as
//    text, and the POS keeps working (categories filter by their exact name, items add to the order).
// Run: node js/fix14_restaurants_menu_ui_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
const PF = path.resolve(QB, '..', '[pfscripts]');
const JQ = fs.readFileSync(path.join(PF, 'pf-devices/html/vendor/jquery-3.6.0.min.js'), 'utf8');
const MENU_HTML = fs.readFileSync(path.join(QB, 'pfm-menu/html/index.html'), 'utf8');
const MENU_JS = fs.readFileSync(path.join(QB, 'pfm-menu/html/script.js'), 'utf8');
const MENU_CSS = fs.readFileSync(path.join(QB, 'pfm-menu/html/style.css'), 'utf8');
const WEB = path.join(PF, 'pf-restaurants/web');

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));
const windows = [];   // closed at the end (the kitchen display's clock is an interval)
async function settle() { for (let i = 0; i < 10; i++) await tick(); }

const EVIL = '"><img src=x onerror="window.__xss=1"><b id=pwn>x</b>\'';
const BILL_XSS = '<img src=x onerror=postData(1)>';

function stripExternal(html) {
    return html.replace(/<script[^>]*src="[^"]*"[^>]*><\/script>/g, '').replace(/<link[^>]*>/g, '');
}

function noInjection(win, root, where) {
    eq(root.querySelectorAll('img[src="x"], #pwn, b, script').length, 0, `${where}: a payload became an element`);
    root.querySelectorAll('[onerror]').forEach((el) => eq(el.getAttribute('onerror'), 'this.parentElement.remove();', `${where}: an onerror handler from a string`));
    eq(win.__xss, undefined, `${where}: script ran`);
}

// ── pfm-menu ────────────────────────────────────────────────────────────────

function bootMenu() {
    const dom = new JSDOM(stripExternal(MENU_HTML), { runScripts: 'outside-only', url: 'https://cfx-nui-pfm-menu/html/index.html', pretendToBeVisual: true });
    const win = dom.window;
    windows.push(win);
    const posts = [];
    win.GetParentResourceName = () => 'pfm-menu';
    win.fetch = async (url, opts) => { posts.push({ url: String(url), body: opts && opts.body }); return { json: async () => ({}) }; };
    win.HTMLElement.prototype.scrollIntoView = function () {};
    win.eval(MENU_JS);
    const send = (action, data) => win.dispatchEvent(new win.MessageEvent('message', { data: { action, data } }));
    return { win, posts, send, buttons: win.document.getElementById('buttons') };
}

// ── pf-restaurants pages ────────────────────────────────────────────────────

function bootPage(page, script, url) {
    const html = fs.readFileSync(path.join(WEB, page), 'utf8');
    const dom = new JSDOM(stripExternal(html), { runScripts: 'outside-only', url: url || `https://cfx-nui-pf-restaurants/web/${page}`, pretendToBeVisual: true });
    const win = dom.window;
    windows.push(win);
    win.console = { log() {}, warn() {}, error() {} };
    win.eval(JQ);
    const posts = [];
    win.$.post = (u, body, cb) => { posts.push({ url: u, body: JSON.parse(body || '{}') }); if (cb) cb({ success: true }); };
    win.eval(fs.readFileSync(path.join(WEB, 'js', script), 'utf8'));
    const send = (data) => win.dispatchEvent(new win.MessageEvent('message', { data }));
    return { win, posts, send, $: win.$ };
}

(async () => {
    await it('pfm-menu: the escape helper escapes quotes as well (icons are attribute values)', async () => {
        const { win, send, buttons } = bootMenu();
        const icon = `fa'x" data-pwn='1`;
        send('OPEN_MENU', [{ header: '<a href="x" title=\'y\'>&', icon }]);
        await settle();
        const i = buttons.querySelector('.icon i');
        eq(i.getAttribute('class'), icon, 'the whole icon string is one class attribute');
        eq(i.getAttribute('data-pwn'), null);
        eq(buttons.querySelector('.header').textContent, '<a href="x" title=\'y\'>&');
        eq(buttons.querySelectorAll('a').length, 0);
        noInjection(win, buttons, 'quotes');
    });

    await it('pfm-menu: a restaurant bill with a dish named like markup renders it as text and clicks nothing', async () => {
        const { win, posts, send, buttons } = bootMenu();
        send('OPEN_MENU', [
            { header: `Burger Shot: $${22}`, txt: `20x ${BILL_XSS}, 1x Fish & Chips (tax $2.00, cash)`, isMenuHeader: true },
            { header: 'Pay', params: { event: 'pf-restaurants:client:answerPayment', args: { orderId: 'R1', accept: true } } },
            { header: 'Decline', params: { event: 'pf-restaurants:client:answerPayment', args: { orderId: 'R1', accept: false } } },
        ]);
        await settle();
        noInjection(win, buttons, 'bill');
        eq(buttons.querySelectorAll('img').length, 0, 'no image from the dish name');
        ok(buttons.querySelector('.title .text').textContent.includes(BILL_XSS), 'the name is shown as typed');
        ok(buttons.querySelector('.title .text').textContent.includes('Fish & Chips'), '"&" shown as is');
        eq(posts.length, 0, 'nothing was clicked for the customer');
        // the customer's own click still works
        buttons.querySelectorAll('.button')[0].click();
        eq(posts.length, 1);
        ok(posts[0].url.endsWith('/clickedButton'));
        eq(posts[0].body, '2', 'entry 2 (Pay)');
    });

    await it('pfm-menu: header, text and icon strings never become elements', async () => {
        const { win, send, buttons } = bootMenu();
        send('OPEN_MENU', [
            { header: EVIL, txt: EVIL, icon: EVIL, isMenuHeader: true },
            { header: EVIL, text: EVIL, icon: 'fas fa-x" onmouseover="window.__xss=1' },
            { header: 'Image', icon: 'nui://pfm-inventory/html/images/x".png' },
            { header: undefined, txt: 'no header' },
        ]);
        await settle();
        noInjection(win, buttons, 'menu');
        const items = buttons.querySelectorAll('.title, .button');
        eq(items.length, 4);
        eq(items[0].querySelector('.header').textContent, EVIL);
        eq(items[1].querySelector('.text').textContent, EVIL);
        eq(items[1].querySelector('i').getAttribute('class'), 'fas fa-x" onmouseover="window.__xss=1', 'an icon class stays one attribute');
        eq(items[1].querySelector('i').getAttribute('onmouseover'), null);
        eq(items[2].querySelector('img').getAttribute('src'), 'nui://pfm-inventory/html/images/x".png');
        eq(items[3].querySelector('.header').textContent, '', 'a missing header is empty, not "undefined"');
    });

    await it('pfm-menu: the legacy <br> of old callers still breaks the line, as text', async () => {
        const { send, buttons } = bootMenu();
        send('OPEN_MENU', [{ header: 'Lockpick', txt: ' x2 Metal Scrap<br> x1 Plastic<BR/> x1 Rubber<br />' }]);
        await settle();
        const text = buttons.querySelector('.text');
        eq(text.querySelectorAll('br').length, 0);
        eq(text.textContent, ' x2 Metal Scrap\n x1 Plastic\n x1 Rubber\n');
        ok(/\.text\s*\{[^}]*white-space:\s*pre-line/.test(MENU_CSS), 'the text keeps its line breaks (pre-line)');
    });

    await it('pfm-menu: hotkeys and keyboard still choose an entry', async () => {
        const { win, posts, send } = bootMenu();
        send('OPEN_MENU', [{ header: 'Title', isMenuHeader: true }, { header: 'One' }, { header: 'Two', disabled: true }, { header: 'Three' }]);
        await settle();
        win.document.onkeydown({ key: '2' });
        eq(posts.length, 1);
        eq(posts[0].body, '4', 'the second selectable entry is entry 4 (Three)');
    });

    await it('menu board: categories, names and descriptions are text', async () => {
        const { win, send } = bootPage('menu.html', 'menu.js', 'https://cfx-nui-pf-restaurants/web/menu.html?businessId=bs');
        await settle();
        send({ action: 'updateMenu', menu: { a: { category: EVIL, displayName: EVIL, description: EVIL, price: 5, enabled: true }, b: { category: 'Mains', displayName: "Bob's Fish & Chips", price: '7', enabled: false } } });
        await settle();
        const root = win.document.getElementById('menu-categories');
        noInjection(win, root, 'menu board');
        eq(root.querySelector('.category-title').textContent, EVIL);
        eq(root.querySelector('.item-name').textContent, EVIL);
        eq(root.querySelector('.item-description').textContent, EVIL);
        ok(root.textContent.includes("Bob's Fish & Chips"));
        ok(root.textContent.includes('$7.00'), 'a price sent as text still shows');
    });

    await it('kitchen display: ticket strings are text; a shift change replaces the tickets', async () => {
        const { win, send } = bootPage('kds.html', 'kds.js');
        await settle();
        const now = Math.floor(Date.now() / 1000);
        send({ action: 'newOrder', order: { orderId: 'R1', status: 'placed', placedAt: now, items: [{ qty: 2, displayName: EVIL }, { qty: 1, recipeId: EVIL, mods: { note: EVIL } }] } });
        await settle();
        const root = win.document.getElementById('new-orders');
        noInjection(win, root, 'kds');
        eq(root.querySelectorAll('.order-ticket').length, 1);
        ok(root.querySelector('.ticket-item strong').textContent.includes(EVIL));
        send({ action: 'newOrder', order: { orderId: `R2${EVIL}`, status: 'placed', placedAt: now, items: [] } });
        await settle();
        noInjection(win, root, 'kds order id');
        send({ action: 'setOrders', orders: [] });
        await settle();
        eq(root.querySelectorAll('.order-ticket').length, 0, 'a shift ended: cleared');
        send({ action: 'setOrders', orders: [{ orderId: 'R3', status: 'placed', placedAt: now, items: [{ qty: 1, displayName: 'Classic' }] }] });
        await settle();
        eq(root.querySelectorAll('.order-ticket').length, 1, 'a shift started: the open tickets');
    });

    await it('POS: menu strings are text, categories filter by their exact name, items add and order', async () => {
        const { win, posts, send, $ } = bootPage('pos.html', 'pos.js');
        await settle();
        send({ action: 'openPOS', businessId: 'bs', taxRate: 0.1, menu: {
            m1: { menuItemId: 'm1', category: EVIL, displayName: EVIL, price: 5, enabled: true },
            m2: { menuItemId: 'm2', category: '{"a":1}', displayName: 'Fries & Dip', price: 2, enabled: true },
        } });
        await settle();
        const doc = win.document;
        noInjection(win, doc.getElementById('categories'), 'POS categories');
        noInjection(win, doc.getElementById('menu-items'), 'POS items');
        eq(doc.querySelectorAll('#menu-items .menu-item').length, 2);
        // the category that looks like JSON filters by its own name (attr, not data())
        $('#categories .category-btn').filter((_, el) => el.textContent === '{"a":1}').trigger('click');
        eq(doc.querySelectorAll('#menu-items .menu-item').length, 1);
        eq(doc.querySelector('#menu-items h3').textContent, 'Fries & Dip');
        $('#categories .category-btn').filter((_, el) => el.textContent === EVIL).trigger('click');
        eq(doc.querySelectorAll('#menu-items .menu-item').length, 1);
        $('#menu-items .menu-item').trigger('click');
        noInjection(win, doc.getElementById('order-items'), 'POS order');
        eq(doc.querySelector('#order-items strong').textContent, EVIL);
        eq(doc.getElementById('total').textContent, '$5.50');
        $('#complete-order').trigger('click');
        eq(posts.length, 1);
        ok(posts[0].url.endsWith('/createOrder'));
        eq(posts[0].body.items[0].menuItemId, 'm1', 'the server prices it by menu item id');
    });

    windows.forEach((w) => w.close());
    console.log(`${passed} passed, ${failed} failed`);
    if (failures.length) { console.log(failures.join('\n\n')); process.exitCode = 1; }
})();
