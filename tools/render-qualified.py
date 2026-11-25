#!/usr/bin/env python3
"""Regenerate the qualified-servers tables in README.md, one per standby client:
config/candidates.conf (Firedancer) and config/candidates-agave.conf (Agave), between the markers
<!-- QUALIFIED-TABLE-<CLIENT>:BEGIN --> and <!-- QUALIFIED-TABLE-<CLIENT>:END -->.
Specs are read from the providers' public plan APIs (no credentials needed)."""
import json, re, urllib.request, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENTS = (('FIREDANCER', 'config/candidates.conf'), ('AGAVE', 'config/candidates-agave.conf'))

def qualified(fn):
    rows = {}
    for line in open(os.path.join(root, fn)):
        f = line.split('#', 1)
        parts = f[0].split()
        if len(parts) != 4 or parts[3] != 'yes':
            continue
        prov, plan, region, _ = parts
        r = rows.setdefault((prov, plan), {'regions': set(), 'note': ''})
        r['regions'].add(region)
        if len(f) > 1 and ('cold restart' in f[1] or 'delivered' in f[1]) and len(f[1]) > len(r['note']):
            r['note'] = f[1].strip()
    return rows

cherry = json.load(urllib.request.urlopen('https://api.cherryservers.com/v1/plans', timeout=30))
spec = {}
for p in cherry:
    c = p['specs']['cpus']; st = ' + '.join('%dx %s' % (s['count'], s['name']) for s in p['specs']['storage'])
    pr = [x['price'] for x in p['pricing'] if x['unit'] == 'Hourly']
    spec[('cherry', p['slug'])] = (c['name'], c['cores'], c['threads'], c.get('frequency'), p['specs']['memory']['total'], st, pr[0] if pr else None)

def table(rows):
    out = ['| Provider | Plan | CPU | RAM | Disks | €/h | Regions | Evidence |', '|---|---|---|---|---|---|---|---|']
    for (prov, plan), r in sorted(rows.items(), key=lambda kv: spec.get(kv[0], ('', 0, 0, 0, 0, '', 99))[6] or 99):
        s = spec.get((prov, plan))
        cpu = '%s (%dc/%dt, %.2f GHz)' % (s[0], s[1], s[2], s[3]) if s else '?'
        out.append('| %s | `%s` | %s | %s GB | %s | %s | %s | %s |' % (
            prov, plan, cpu, s[4] if s else '?', s[5] if s else '?', '%.2f' % s[6] if s and s[6] else '?',
            ', '.join(sorted(r['regions'])), r['note'].replace('|', '/')))
    if len(out) == 2: out = ['_None qualified yet._']
    return out

readme = os.path.join(root, 'README.md'); t = open(readme).read()
for client, fn in CLIENTS:
    out = table(qualified(fn))
    pat = r'(<!-- QUALIFIED-TABLE-%s:BEGIN -->\n).*?(<!-- QUALIFIED-TABLE-%s:END -->)' % (client, client)
    if not re.search(pat, t, flags=re.S): raise SystemExit('README.md: markers for %s missing' % client)
    t = re.sub(pat, lambda m: m.group(1) + '\n'.join(out) + '\n' + m.group(2), t, flags=re.S)
    print('%s:\n%s\n' % (client, '\n'.join(out)))
open(readme, 'w').write(t)
