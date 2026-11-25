#!/usr/bin/env python3
"""Re-point the primary's regional endpoints (Jito, BAM, Harmonic, ...) to the region closest to
THIS machine. Table and rules: config/regional-endpoints.conf.

  localize-endpoints.py TABLE {args|toml} FILE [FILE...] --plan
      (primary) print the regional endpoints FILE uses, and unknown hosts under listed domains
  localize-endpoints.py TABLE {args|toml} FILE [FILE...] [--force provider=region ...]
      (standby) measure, choose a region per provider, rewrite FILE(s) in place

FILE: `args` = one command-line argument per line; `toml` = a Firedancer config (only string
values are touched, the formatting stays). All FILEs share one choice per provider.
ODS_RTT_FILE (tests): "host rtt_ms" lines used instead of measuring.
"""
import concurrent.futures, ipaddress, os, re, socket, subprocess, sys, time

def load_table(path):
    rows = []
    for ln in open(path):
        ln = ln.split('#', 1)[0].split()
        if not ln: continue
        if len(ln) not in (4, 5) or (len(ln) == 5 and ln[4] != 'alias'):
            sys.exit(f'{path}: bad line: {" ".join(ln)}')
        rows.append(dict(p=ln[0], role=ln[1], region=ln[2], host=ln[3].lower(), alias=len(ln) == 5))
    return rows

HOSTRE = re.compile(r'^(?P<pre>[A-Za-z][A-Za-z0-9+.-]*://)?(?P<host>[A-Za-z0-9.-]+\.[A-Za-z0-9-]+)(?P<post>(:[0-9]{1,5})?(/.*)?)$')

def split(v):
    m = HOSTRE.match(v)
    return (m.group('pre') or '', m.group('host').lower(), m.group('post')) if m else None

def domain(h):
    try: ipaddress.ip_address(h); return None
    except ValueError: return '.'.join(h.split('.')[-2:])

class Localizer:
    def __init__(self, rows):
        self.rows = rows
        self.by_host = {r['host']: r for r in rows}
        self.domains = {d for d in (domain(r['host']) for r in rows) if d}
        self.used = {}        # provider -> {role: set(old regions)}
        self.used_global = {} # same, for the providers' global endpoints (never changed)
        self.unknown = set()
        self.choice = {}      # provider -> region
        self.changes = []

    def hosts(self, p, role, region):
        return [r['host'] for r in self.rows if r['p'] == p and r['role'] == role and r['region'] == region and not r['alias']]

    def index(self, r):
        if r['alias']: return 0
        return self.hosts(r['p'], r['role'], r['region']).index(r['host'])

    def scan_value(self, v):
        for part in v.split(','):
            s = split(part.strip())
            if not s: continue
            r = self.by_host.get(s[1])
            if r and r['region'] == 'global':
                self.used_global.setdefault(r['p'], {}).setdefault(r['role'], set()).add('global')
            elif r:
                self.used.setdefault(r['p'], {}).setdefault(r['role'], set()).add(r['region'])
            elif not r and domain(s[1]) in self.domains:
                self.unknown.add(part.strip())

    def map_value(self, v):
        out = []
        for part in v.split(','):
            s = split(part.strip())
            r = self.by_host.get(s[1]) if s else None
            new = self.choice.get(r['p']) if r and r['region'] != 'global' else None
            if new and new != r['region']:
                hs = self.hosts(r['p'], r['role'], new)
                nv = s[0] + hs[self.index(r) % len(hs)] + s[2]
                lead = part[:len(part) - len(part.lstrip())]
                self.changes.append((part.strip(), nv)); out.append(lead + nv)
            else: out.append(part)
        return ','.join(out)

    def regions(self, p):
        """regions of provider p that offer every role the primary uses"""
        roles = self.used[p]
        regs = {r['region'] for r in self.rows if r['p'] == p and r['region'] != 'global'}
        return sorted(g for g in regs if all(self.hosts(p, role, g) for role in roles))

def rtt_ms(host):
    fake = os.environ.get('ODS_RTT_FILE')
    if fake:
        for ln in open(fake):
            h, *v = ln.split()
            if h == host: return float(v[0]) if v and v[0] != '-' else None
        return None
    try:
        out = subprocess.run(['ping', '-n', '-q', '-c', '3', '-i', '0.2', '-W', '1', host],
                             capture_output=True, text=True, timeout=10).stdout
        m = re.search(r'= ([0-9.]+)/', out)
        if m: return float(m.group(1))
    except Exception: pass
    best = None                                   # ICMP blocked: TCP connect time
    for port in (443, 80):
        for _ in range(3):
            try:
                t = time.monotonic(); socket.create_connection((host, port), timeout=1).close()
                d = (time.monotonic() - t) * 1000; best = d if best is None else min(best, d)
            except OSError: break
        if best is not None: return best
    return None

def read_args(path):
    return open(path).read().split('\n')[:-1] if os.path.getsize(path) else []

def strip_comment(line):
    q = False
    for i, c in enumerate(line):
        if c == '"': q = not q
        elif c == '#' and not q: return line[:i]
    return line

def toml_strings(text):
    """basic strings "..." outside comments (endpoint values have no escapes)"""
    return re.finditer(r'"([^"\\\n]*)"', '\n'.join(strip_comment(l) for l in text.split('\n')))

def main():
    a = sys.argv[1:]
    plan = '--plan' in a; a = [x for x in a if x != '--plan']
    force = {}
    while '--force' in a:
        i = a.index('--force'); kv = a[i + 1]; del a[i:i + 2]
        for item in kv.split():
            k, _, v = item.partition('='); force[k] = v
    if len(a) < 3 or a[1] not in ('args', 'toml'): sys.exit(__doc__)
    L = Localizer(load_table(a[0])); fmt, files = a[1], a[2:]
    texts = {f: open(f).read() for f in files}
    for f in files:
        if fmt == 'args':
            for x in read_args(f): L.scan_value(x)
        else:
            for m in toml_strings(texts[f]): L.scan_value(m.group(1))
    for u in sorted(L.unknown):
        print(f'warning: {u}: host under a known provider domain but not in the table: kept as on the primary', file=sys.stderr)
    if plan:
        allp = {}
        for d in (L.used, L.used_global):
            for p, roles in d.items():
                for role, regs in roles.items(): allp.setdefault(p, {}).setdefault(role, set()).update(regs)
        for p, roles in sorted(allp.items()):
            print(f'{p}: ' + ', '.join(f'{role}@{"/".join(sorted(regs))}' for role, regs in sorted(roles.items())))
        return
    for p in sorted(L.used):
        regs = L.regions(p)
        if p in force:
            if force[p] not in regs: sys.exit(f'STANDBY_REGIONS: {p}={force[p]} is not a region with {"/".join(sorted(L.used[p]))} (have: {" ".join(regs)})')
            L.choice[p] = force[p]; print(f'{p}: region {force[p]} (STANDBY_REGIONS)'); continue
        hosts = sorted({h for g in regs for role in L.used[p] for h in L.hosts(p, role, g)})
        with concurrent.futures.ThreadPoolExecutor(16) as ex:
            rtt = dict(zip(hosts, ex.map(rtt_ms, hosts)))
        reg_rtt = {}
        for g in regs:
            v = [rtt[h] for role in L.used[p] for h in L.hosts(p, role, g) if rtt.get(h) is not None]
            if v: reg_rtt[g] = min(v)
        olds = set().union(*L.used[p].values())
        if not reg_rtt:
            print(f'{p}: no region answered: kept as on the primary ({"/".join(sorted(olds))})'); continue
        best = min(reg_rtt, key=reg_rtt.get)
        old = next(iter(olds)) if len(olds) == 1 else None
        if old in reg_rtt and reg_rtt[old] <= reg_rtt[best] + 0.5: best = old   # no change for <0.5 ms
        L.choice[p] = best
        print(f'{p}: region {best} ({reg_rtt[best]:.1f} ms; primary uses {"/".join(sorted(olds))}'
              + (f' {reg_rtt[old]:.1f} ms' if old in reg_rtt else '') + '; measured: '
              + ' '.join(f'{g}={reg_rtt[g]:.0f}' for g in sorted(reg_rtt, key=reg_rtt.get)) + ')')
    for f in files:
        if fmt == 'args':
            out, seen, group = [], set(), []
            def flush():
                key = tuple(group)
                if group and not (key in seen and len(group) > 1 and any(new in group for _, new in L.changes)):
                    out.extend(group); seen.add(key)
            for x in read_args(f):
                if x.startswith('-') and not x.lstrip('-').isdigit(): flush(); group = [x]
                else: group.append(L.map_value(x))
            flush(); new = ''.join(x + '\n' for x in out)
        else:
            def line(l):
                code = strip_comment(l)
                return re.sub(r'"([^"\\]*)"', lambda m: '"' + L.map_value(m.group(1)) + '"', code) + l[len(code):]
            new = '\n'.join(line(l) for l in texts[f].split('\n'))
            def dedup(m):                         # an array that now names an endpoint twice
                items = re.findall(r'"([^"]*)"', m.group(2))
                if len(set(items)) == len(items) or not any(n in items for _, n in L.changes): return m.group(0)
                keep = list(dict.fromkeys(items))
                return m.group(1) + '[ ' + ', '.join(f'"{x}"' for x in keep) + ' ]'
            new = re.sub(r'(?m)^(\s*[A-Za-z0-9_]+\s*=\s*)\[([^\[\]\n]*)\]', dedup, new)
        if new != texts[f]:
            tmp = f + '.localize'
            with open(tmp, 'w') as fh: fh.write(new)
            os.chmod(tmp, os.stat(f).st_mode & 0o7777); os.replace(tmp, f)
    for old, nv in dict.fromkeys(L.changes):
        print(f'  {old} -> {nv}')

if __name__ == '__main__':
    main()
