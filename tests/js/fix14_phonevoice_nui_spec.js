// pfm-phone NUI (batch 14, PH-2 / X-4 and the phone UI): strings from other players (chat messages
// and their time/date/location/picture, avatars, names, tweets, mails, adverts, suggested contacts,
// police alerts, notifications) reach the page as text or as checked links, never as HTML. The phone's
// scripts load into its own index.html (scripts stripped) with a small jQuery shim (only what these
// scripts use; the real page loads jQuery from a CDN, which the test harness does not have).
// Run: node js/fix14_phonevoice_nui_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');

const HTML = path.resolve(__dirname, '..', '..', 'pfm-phone', 'html');
const SCRIPTS = ['config', 'app', 'settings', 'phone', 'twitter', 'bank', 'whatsapp', 'mail', 'meos'];

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }

// a minimal jQuery: selectors, HTML strings and elements; the methods the phone scripts call
const SHIM = `
(function () {
    function toNodes(x) {
        if (x == null) return [];
        if (x instanceof Q) return x.nodes;
        if (typeof x === 'string') {
            var s = x.trim();
            if (s.charAt(0) === '<') { var t = document.createElement('template'); t.innerHTML = x; return Array.prototype.slice.call(t.content.childNodes); }
            return Array.prototype.slice.call(document.querySelectorAll(x));
        }
        if (x === document || x === window || x.nodeType) return [x];
        if (Array.isArray(x)) return x;
        return [];
    }
    var dataStore = new WeakMap();
    function Q(x) { this.nodes = toNodes(x); this.length = this.nodes.length; }
    function contentNodes(x) {
        if (x instanceof Q) return x.nodes;
        if (typeof x === 'string') { var t = document.createElement('template'); t.innerHTML = x; return Array.prototype.slice.call(t.content.childNodes); }
        if (x && x.nodeType) return [x];
        return [];
    }
    Q.prototype.each = function (fn) { this.nodes.forEach(function (n, i) { fn.call(n, i, n); }); return this; };
    Q.prototype.html = function (v) { if (v === undefined) return this.nodes[0] ? this.nodes[0].innerHTML : undefined; this.nodes.forEach(function (n) { n.innerHTML = String(v); }); return this; };
    Q.prototype.text = function (v) { if (v === undefined) return this.nodes.map(function (n) { return n.textContent; }).join(''); this.nodes.forEach(function (n) { n.textContent = String(v); }); return this; };
    Q.prototype.append = function (x) { var self = this; this.nodes.forEach(function (n, i) { contentNodes(x).forEach(function (c) { n.appendChild(i === self.nodes.length - 1 ? c : c.cloneNode(true)); }); }); return this; };
    Q.prototype.appendTo = function (sel) { var target = new Q(sel); target.append(this); return this; };
    Q.prototype.prepend = function (x) { this.nodes.forEach(function (n) { var nodes = contentNodes(x); for (var k = nodes.length - 1; k >= 0; k--) n.insertBefore(nodes[k], n.firstChild); }); return this; };
    Q.prototype.after = function (x) { this.nodes.forEach(function (n) { var nodes = contentNodes(x); for (var k = nodes.length - 1; k >= 0; k--) n.parentNode.insertBefore(nodes[k], n.nextSibling); }); return this; };
    Q.prototype.find = function (sel) { var out = []; this.nodes.forEach(function (n) { if (n.querySelectorAll) out = out.concat(Array.prototype.slice.call(n.querySelectorAll(sel))); }); return new Q(out); };
    Q.prototype.parent = function () { return new Q(this.nodes.map(function (n) { return n.parentNode; }).filter(Boolean)); };
    Q.prototype.attr = function (k, v) { if (v === undefined) return this.nodes[0] ? this.nodes[0].getAttribute(k) : undefined; this.nodes.forEach(function (n) { n.setAttribute(k, String(v)); }); return this; };
    Q.prototype.prop = function (k, v) { if (v === undefined) return this.nodes[0] ? this.nodes[0][k] : undefined; this.nodes.forEach(function (n) { n[k] = v; }); return this; };
    Q.prototype.val = function (v) { if (v === undefined) return this.nodes[0] ? this.nodes[0].value : undefined; this.nodes.forEach(function (n) { n.value = v; }); return this; };
    Q.prototype.data = function (k, v) {
        var n = this.nodes[0];
        if (!n) return undefined;
        if (v === undefined) { var m = dataStore.get(n); if (m && k in m) return m[k]; var a = n.getAttribute && n.getAttribute('data-' + k); return a === null ? undefined : (isNaN(Number(a)) ? a : Number(a)); }
        this.nodes.forEach(function (x) { var m = dataStore.get(x) || {}; m[k] = v; dataStore.set(x, m); });
        return this;
    };
    Q.prototype.removeData = function () { return this; };
    Q.prototype.css = function (k, v) {
        if (typeof k === 'string' && v === undefined) return this.nodes[0] ? this.nodes[0].style[k] : undefined;
        var obj = typeof k === 'string' ? { [k]: v } : k;
        this.nodes.forEach(function (n) { if (n.style) Object.keys(obj).forEach(function (p) { n.style.setProperty(p.replace(/[A-Z]/g, function (c) { return '-' + c.toLowerCase(); }), String(obj[p])); }); });
        return this;
    };
    ['addClass', 'removeClass'].forEach(function (m) { Q.prototype[m] = function (c) { this.nodes.forEach(function (n) { n.classList && n.classList[m === 'addClass' ? 'add' : 'remove'](c); }); return this; }; });
    Q.prototype.remove = function () { this.nodes.forEach(function (n) { n.parentNode && n.parentNode.removeChild(n); }); return this; };
    // handlers bound on document are kept so a test can run one (window.__handlers)
    window.__handlers = [];
    Q.prototype.on = function (evt, sel, fn) {
        if (typeof sel === 'function') { fn = sel; sel = null; }
        if (this.nodes[0] === document) window.__handlers.push({ evt: evt, sel: sel, fn: fn });
        return this;
    };
    ['animate', 'fadeIn', 'fadeOut', 'show', 'hide', 'toggle', 'tooltip', 'filter', 'emojioneArea', 'select', 'click'].forEach(function (m) {
        Q.prototype[m] = function () { var cb = Array.prototype.slice.call(arguments).find(function (a) { return typeof a === 'function'; }); if (m === 'animate' && cb) cb.call(this.nodes[0]); return this; };
    });
    Q.prototype.ready = function (fn) { fn(); return this; };
    function $(x) { if (typeof x === 'function') { x(); return; } return new Q(x); }
    $.each = function (obj, fn) { if (Array.isArray(obj)) obj.forEach(function (v, i) { fn(i, v); }); else if (obj) Object.keys(obj).forEach(function (k) { fn(k, obj[k]); }); };
    window.__posts = [];
    window.__postReplies = {};
    $.post = function (url, body, cb) {
        var name = String(url).replace(/^https:\\/\\/[^/]+\\//, '');
        window.__posts.push({ name: name, body: body });
        if (typeof body === 'function') cb = body;
        var reply = window.__postReplies[name];
        if (cb) cb(typeof reply === 'function' ? reply(body) : reply);
    };
    window.$ = window.jQuery = $;
    // DOMPurify stand-in (the page loads it from a CDN): drops tags not allowed and every attribute
    window.DOMPurify = { sanitize: function (html, cfg) {
        var allowed = (cfg && cfg.ALLOWED_TAGS) || [];
        var t = document.createElement('template');
        t.innerHTML = String(html);
        (function walk(node) {
            Array.prototype.slice.call(node.childNodes).forEach(function (c) {
                if (c.nodeType !== 1) return;
                walk(c);
                if (allowed.indexOf(c.tagName.toLowerCase()) === -1) {
                    while (c.firstChild) c.parentNode.insertBefore(c.firstChild, c);
                    c.parentNode.removeChild(c);
                } else {
                    Array.prototype.slice.call(c.attributes).forEach(function (a) { c.removeAttribute(a.name); });
                }
            });
        })(t.content);
        return t.innerHTML;
    } };
})();
`;

function makePage() {
    const errors = [];
    const vc = new VirtualConsole();
    vc.on('jsdomError', (e) => { if (!/Not implemented|Could not load/.test(String(e && e.message))) errors.push(e); });
    const body = fs.readFileSync(path.join(HTML, 'index.html'), 'utf8').replace(/<script[\s\S]*?<\/script>/g, '').replace(/<link[^>]*>/g, '');
    const dom = new JSDOM(body, { runScripts: 'dangerously', url: 'https://cfx-nui-pfm-phone/html/index.html', virtualConsole: vc });
    const win = dom.window;
    win.moment = (d) => ({ format: () => String(d) });
    const add = (src) => { const el = win.document.createElement('script'); el.textContent = src; win.document.body.appendChild(el); };
    add(SHIM);
    for (const name of SCRIPTS) add(fs.readFileSync(path.join(HTML, 'js', `${name}.js`), 'utf8'));
    win.__postReplies.HasPhone = true;
    win.QB.Phone.Data.PlayerData = { citizenid: 'ME', charinfo: { firstname: 'Me', lastname: 'Myself', phone: '5550001' }, job: { name: 'police', onduty: true } };
    return { win, doc: win.document, errors };
}

const EVIL = '<img src=x onerror="window.__xss=1">';
const EVIL_ATTR = '1" onmouseover="window.__xss=1" x="';
// anything a payload could have turned into a live element or handler
function injected(root) {
    const bad = root.querySelectorAll('[onerror], [onmouseover], [onclick], [onload], script, iframe, svg');
    if (bad.length) return `${bad.length} injected (${bad[0].outerHTML.slice(0, 80)})`;
    for (const el of root.querySelectorAll('img')) {
        const src = el.getAttribute('src') || '';
        if (/^javascript:|onerror|\s/i.test(src)) return `bad img src ${src}`;
    }
    for (const el of root.querySelectorAll('[style]')) {
        if (/javascript:|onerror|expression\(/i.test(el.getAttribute('style'))) return `bad style ${el.getAttribute('style')}`;
    }
    return null;
}

(async () => {
    await it('helpers: Esc escapes markup, SafeUrl/CssUrl only pass https links and local images', async () => {
        const { win } = makePage();
        const P = win.QB.Phone;
        eq(P.Esc('<b a="1">&\''), '&lt;b a&#61;&quot;1&quot;&gt;&amp;&#39;');
        eq(P.SafeUrl('https://i.imgur.com/a.png'), 'https://i.imgur.com/a.png');
        eq(P.SafeUrl('x);"><img src=x>'), './img/default.png');
        eq(P.SafeUrl('javascript:alert(1)'), './img/default.png');
        eq(P.SafeUrl('https://a.b/x y'), './img/default.png');
        eq(P.SafeUrl('https://a.b/x"y', null), null);
        eq(P.CssUrl('https://i.imgur.com/a.png'), 'url("https://i.imgur.com/a.png")');
    });

    await it('whatsapp chat list: names, last message, time and avatars are text / checked links', async () => {
        const { win, doc, errors } = makePage();
        win.QB.Phone.Functions.LoadWhatsappChats([{
            name: EVIL, number: '5550002', picture: 'x);background:url(javascript:alert(1));"><img src=x onerror=alert(1)>',
            messages: [{ date: '1-0-2026', messages: [{ sender: 'X', type: 'message', message: EVIL, time: EVIL, data: {} }] }],
        }]);
        const list = doc.querySelector('.whatsapp-chats');
        eq(injected(list), null);
        ok(list.textContent.includes('<img src=x onerror'), 'the text was not shown as text');
        ok(/default\.png/.test(list.querySelector('.whatsapp-chat-picture').style.backgroundImage), 'avatar not the default');
        eq(errors.length, 0, 'script errors');
    });

    await it('whatsapp opened chat: message, time, date, location and picture fields cannot inject', async () => {
        const { win, doc } = makePage();
        win.__postReplies.GetProfilePicture = 'x);"><img src=x onerror=alert(1)>';
        win.QB.Phone.Functions.SetupChatMessages({
            name: EVIL, number: '5550002',
            messages: [{ date: '1-0-2026', messages: [
                { sender: 'X', type: 'message', message: EVIL, time: EVIL, data: {} },
                { sender: 'X', type: 'location', message: 'Shared Location', time: '10:00', data: { x: EVIL_ATTR, y: 2 } },
                { sender: 'X', type: 'location', message: 'Shared Location', time: '10:00', data: { x: 12.5, y: -3 } },
                { sender: 'X', type: 'picture', message: 'Photo', time: '10:00', data: { url: 'x onerror=window.__xss=1' } },
                { sender: 'ME', type: 'picture', message: 'Photo', time: EVIL, data: { url: 'https://media.discordapp.net/attachments/1/2/p.jpg' } },
            ] }],
        });
        const box = doc.querySelector('.whatsapp-openedchat-messages');
        eq(injected(box), null);
        eq(injected(doc.querySelector('.whatsapp-openedchat-name')), null);
        const locs = box.querySelectorAll('.whatsapp-shared-location');
        eq(locs.length, 1, 'only the valid location is shown');
        eq(locs[0].getAttribute('data-x'), '12.5');
        const imgs = box.querySelectorAll('img.wppimage');
        eq(imgs.length, 1, 'only the allowed picture is shown');
        eq(imgs[0].getAttribute('src'), 'https://media.discordapp.net/attachments/1/2/p.jpg');
        ok(/default\.png/.test(doc.querySelector('.whatsapp-openedchat-picture').style.backgroundImage), 'opened chat avatar not the default');
        eq(win.__xss, undefined);
    });

    await it('sending posts the typed text as it is (the server stores text, every phone escapes it)', async () => {
        const { win } = makePage();
        win.OpenedChatData.number = '5550002';
        win.$('#whatsapp-openedchat-message').val('Tom & Jerry <3');
        win.__posts.length = 0;
        // the Enter key (the document keypress handler of whatsapp.js)
        const handler = win.__handlers.find((h) => h.evt === 'keypress' && !h.sel);
        ok(handler, 'no keypress handler');
        handler.fn.call(win.document, { which: 13, preventDefault() {} });
        const post = win.__posts.find((p) => p.name === 'SendMessage');
        ok(post, 'nothing sent');
        const body = JSON.parse(post.body);
        eq(body.ChatMessage, 'Tom & Jerry <3');
        eq(body.ChatType, 'message');
    });

    await it('tweets: names, time, links and @/# tags cannot inject (also through quotes in a tag)', async () => {
        const { win, doc } = makePage();
        const tweets = [{
            firstName: EVIL, lastName: 'B', citizenid: 'X', tweetId: 'TWEET-1', date: EVIL,
            message: "hello @x'onmouseover=window.__xss=1 #tag'onmouseover=window.__xss=1 " + EVIL + ' @Real_Name #real',
            picture: 'x onerror=alert(1)', url: 'x onerror=alert(1)',
        }, { firstName: 'Ann', lastName: 'Lee', message: 'pic', picture: 'default', url: 'https://i.imgur.com/p.png', date: '2026' }];
        win.QB.Phone.Notifications.LoadTweets(tweets);
        win.QB.Phone.Notifications.LoadMentionedTweets(tweets);
        win.QB.Phone.Notifications.LoadHashtagMessages(tweets);
        win.QB.Phone.Notifications.LoadHashtags({ evil: { hashtag: EVIL_ATTR, messages: tweets } });
        for (const sel of ['.twitter-home-tab', '.twitter-mentions-tab', '.twitter-hashtag-tweets', '.twitter-hashtags']) {
            eq(injected(doc.querySelector(sel)), null, sel);
        }
        const home = doc.querySelector('.twitter-home-tab');
        const mentions = [...home.querySelectorAll('.mentioned-tag')].map((e) => e.getAttribute('data-mentiontag'));
        ok(mentions.includes('@Real_Name'), 'a real mention is still a tag');
        ok(mentions.every((m) => /^@[\w-]+$/.test(m)), `bad mention tag ${mentions}`);
        const tags = [...home.querySelectorAll('.hashtag-tag-text')].map((e) => e.getAttribute('data-hashtag'));
        ok(tags.every((t) => /^[\w-]+$/.test(t)), `bad hashtag ${tags}`);
        eq(home.querySelectorAll('img.image').length, 1, 'only the allowed tweet picture');
        eq(win.__xss, undefined);
    });

    await it('mails and adverts: sender, subject and body cannot run script; an advert picture must be a link', async () => {
        const { win, doc } = makePage();
        win.QB.Phone.Functions.SetupMails([{ mailid: 5, sender: EVIL, subject: EVIL, message: 'Line one\n' + EVIL, date: 0 }]);
        eq(injected(doc.querySelector('.mail-list')), null);
        win.QB.Phone.Functions.SetupMail({ mailid: 5, sender: EVIL, subject: EVIL, message: '<strong>$50</strong> ' + EVIL, date: 0 });
        eq(injected(doc.querySelector('.mail-subject')), null);
        eq(injected(doc.querySelector('.mail-content')), null);
        win.QB.Phone.Functions.RefreshAdverts([{ name: EVIL, number: EVIL, message: EVIL, url: 'x onerror=window.__xss=1' },
            { name: 'Ann', number: '555', message: 'car', url: 'https://i.imgur.com/c.png' }]);
        const ads = doc.querySelector('.advert-list');
        eq(injected(ads), null);
        eq(ads.querySelectorAll('img.advimage').length, 1);
        eq(ads.querySelector('img.advimage').getAttribute('src'), 'https://i.imgur.com/c.png');
    });

    await it('contacts, recent calls and suggested contacts from other players are text', async () => {
        const { win, doc } = makePage();
        win.QB.Phone.Functions.SetupSuggestedContacts([{ name: [EVIL, EVIL], number: EVIL, bank: 'x' }]);
        eq(injected(doc.querySelector('.suggested-contacts')), null);
        win.QB.Phone.Functions.SetupRecentCalls([{ name: EVIL, number: '5550002', time: EVIL, type: 'missed' },
            { name: 'Anonymous', number: null, time: '10:00', type: 'incoming', anonymous: true }]);
        const recent = doc.querySelector('.phone-recent-calls');
        eq(injected(recent), null);
        eq(recent.querySelectorAll('.phone-recent-call').length, 2);
        win.QB.Phone.Functions.LoadContacts([{ name: EVIL, number: '5550002', status: true }]);
        eq(injected(doc.querySelector('.phone-contact-list')), null);
    });

    await it('notifications, police alerts and the avatar setting are text / checked links', async () => {
        const { win, doc } = makePage();
        win.QB.Phone.Notifications.Add('fas fa-x" onerror="1', EVIL, EVIL, '#fff', 100);
        eq(injected(doc.querySelector('.phone-notification-container')), null);
        eq(doc.querySelector('.notification-text').textContent, EVIL);
        win.AddPoliceAlert({ alert: { title: EVIL, description: EVIL, coords: { x: 1, y: 2 } } });
        eq(injected(doc.querySelector('.meos-recent-alerts')), null);
        win.QB.Phone.Functions.LoadMetaData({ background: "x'); background: url(javascript:alert(1))", profilepicture: '" onerror="window.__xss=1' });
        eq(injected(doc.querySelector('[data-settingstab="profilepicture"]')), null);
        eq(doc.querySelector('[data-settingstab="profilepicture"] img').getAttribute('src'), './img/default.png');
        ok(!/javascript/.test(doc.querySelector('.phone-background').style.backgroundImage), 'background took the link');
        eq(win.__xss, undefined);
    });

    console.log(`${failed ? 'FAIL' : 'ok  '}  fix14_phonevoice_nui_spec.js  (${passed} passed, ${failed} failed)`);
    if (failures.length) { console.log('\nFailures:'); failures.forEach((f) => console.log('  - ' + f)); }
    process.exit(failed ? 1 : 0);
})();
