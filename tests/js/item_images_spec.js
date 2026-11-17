// Every item in pfm-core shared/items.lua must point at an image that pfm-inventory ships, so no
// inventory slot shows a broken icon. Items that were already missing images before batch 17 are
// listed in LEGACY_MISSING; a NEW missing image fails this spec (batch 18 check B18-7).
// Run: node js/item_images_spec.js
const fs = require('fs');
const path = require('path');

const QB = path.resolve(__dirname, '..', '..');
const items = fs.readFileSync(path.join(QB, 'pfm-core/shared/items.lua'), 'utf8');
const images = new Set(fs.readdirSync(path.join(QB, 'pfm-inventory/html/images')));
const LEGACY_MISSING = new Set([
    'outfitbag', 'weapon_unarmed', 'weapon_briefcase', 'weapon_briefcase_02', 'weapon_bread', 'weapon_candycane',
    'weapon_remotesniper', 'weapon_grenadelauncher_smoke', 'weapon_railgunxm3', 'weapon_bzgas', 'weapon_proxmine',
    'weapon_smokegrenade', 'luxuryfinish_attachment', 'emp_ammo', 'supply_crate', 'diamond',
]);

let checked = 0;
const bad = [];
for (const line of items.split('\n')) {
    const m = line.match(/name\s*=\s*'([^']+)'.*?image\s*=\s*'([^']*)'/);
    if (!m) continue;
    checked++;
    const [, name, image] = m;
    if (!images.has(image) && !LEGACY_MISSING.has(name)) bad.push(`${name} -> ${image}`);
}
if (checked < 300) { console.error(`only ${checked} items parsed`); process.exit(1); }
if (bad.length) { console.error('items with a missing image:\n  ' + bad.join('\n  ')); process.exit(1); }
console.log(`ok item_images_spec (${checked} items, ${LEGACY_MISSING.size} legacy without art)`);
