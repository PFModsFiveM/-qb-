"""Server-side event and callback names registered by more than one started resource in staging."""
import os, re, sys, collections

root = sys.argv[1]
pat = re.compile(r"""(RegisterNetEvent|RegisterServerEvent|AddEventHandler|CreateCallback|lib\.callback\.register)\s*\(\s*['"]([^'"]+)['"]""")
by_name = collections.defaultdict(set)


def resources(base):
    for dirpath, dirnames, filenames in os.walk(base):
        if 'fxmanifest.lua' in filenames or '__resource.lua' in filenames:
            dirnames[:] = []
            yield dirpath


for group in os.listdir(root):
    gpath = os.path.join(root, group)
    if not os.path.isdir(gpath):
        continue
    for res in resources(gpath):
        name = os.path.basename(res)
        for dirpath, dirnames, filenames in os.walk(res):
            dirnames[:] = [d for d in dirnames if d not in ('node_modules', 'html', 'web', 'ui', 'stream')]
            rel = os.path.relpath(dirpath, res).replace('\\', '/').lower()
            for fn in filenames:
                if not fn.endswith('.lua'):
                    continue
                low = (rel + '/' + fn).lower()
                if 'client' in low or 'locale' in low:
                    continue
                if not ('server' in low or fn.lower().startswith('sv_') or fn.lower() == 'main.lua' and rel == '.'):
                    continue
                try:
                    text = open(os.path.join(dirpath, fn), encoding='utf-8', errors='replace').read()
                except OSError:
                    continue
                for kind, ev in pat.findall(text):
                    if ev in ('playerDropped', 'onResourceStart', 'onResourceStop', 'onServerResourceStart', 'QBCore:Server:UpdateObject',
                              'QBCore:Server:OnPlayerLoaded', 'QBCore:Server:OnPlayerUnload', 'QBCore:Server:PlayerLoaded',
                              'QBCore:Server:SetDuty', 'QBCore:Server:OnJobUpdate', 'QBCore:Server:OnGangUpdate', 'playerConnecting',
                              'txAdmin:events:scheduledRestart', 'txAdmin:events:serverShuttingDown', 'onResourceStarting', 'chatMessage'):
                        continue
                    by_name[ev].add(name)

dups = {ev: sorted(r) for ev, r in by_name.items() if len(r) > 1}
pairs = collections.defaultdict(list)
for ev, rs in dups.items():
    pairs[tuple(rs)].append(ev)
for rs, evs in sorted(pairs.items(), key=lambda kv: -len(kv[1])):
    print(f"{' + '.join(rs)}: {len(evs)} shared  e.g. {', '.join(sorted(evs)[:4])}")
