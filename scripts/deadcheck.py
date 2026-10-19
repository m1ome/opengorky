#!/usr/bin/env python3
# Dead-code check (slow, compiler-verified): renames every container-level decl,
# rebuilds all variants and restores what the compiler asks for, to a fixpoint.
# Phase 1 (no tests) finds decls unused outside tests; phase 2 (+ `zig build test`)
# splits them into "dead" and "test-only". `--apply` deletes the dead ones.
# Usage: scripts/deadcheck.py [--apply]   (minutes; the tree is restored on exit)
import os, re, subprocess, sys


KW_CONT = {'struct', 'enum', 'union', 'opaque'}
MODS = {'pub', 'inline', 'noinline', 'export', 'extern', 'threadlocal'}
ident = re.compile(r'[A-Za-z_][A-Za-z0-9_]*|@"[^"]*"')


def tokenize(s):
    toks = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in ' \t\r\n':
            i += 1
        elif s.startswith('//', i):
            j = s.find('\n', i)
            i = n if j < 0 else j
        elif s.startswith('\\\\', i):
            j = s.find('\n', i)
            j = n if j < 0 else j
            toks.append(('str', s[i:j], i, j))
            i = j
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == '\\' else 1
            toks.append(('str', s[i:j + 1], i, j + 1))
            i = j + 1
        elif c == '@' and i + 1 < n and s[i + 1] == '"':
            m = ident.match(s, i)
            toks.append(('id', m.group(0), i, m.end()))
            i = m.end()
        elif c.isalpha() or c == '_':
            m = ident.match(s, i)
            toks.append(('id', m.group(0), i, m.end()))
            i = m.end()
        elif c.isdigit():
            m = re.compile(r'[0-9a-zA-Z_.]+').match(s, i)
            # avoid eating `..`
            t = m.group(0)
            k = t.find('..')
            if k >= 0:
                t = t[:k]
            toks.append(('num', t, i, i + len(t)))
            i += len(t)
        elif c == '@':
            m = ident.match(s, i + 1)
            e = m.end() if m else i + 1
            toks.append(('bi', s[i:e], i, e))
            i = e
        else:
            toks.append(('p', c, i, i + 1))
            i += 1
    return toks


def match_close(toks, k):
    """toks[k] is an opener; return index of matching closer."""
    d = 0
    for j in range(k, len(toks)):
        t = toks[j][1] if toks[j][0] == 'p' else None
        if t in ('(', '[', '{'):
            d += 1
        elif t in (')', ']', '}'):
            d -= 1
            if d == 0:
                return j
    return len(toks) - 1


def is_container_brace(toks, k):
    j = k - 1
    if j >= 0 and toks[j][1] == ')':
        d = 0
        while j >= 0:
            if toks[j][1] == ')':
                d += 1
            elif toks[j][1] == '(':
                d -= 1
                if d == 0:
                    break
            j -= 1
        j -= 1
    return j >= 0 and toks[j][0] == 'id' and toks[j][1] in KW_CONT, (toks[j][1] if j >= 0 else None)


def parse(s):
    """Return decls, fields, members. Each: dict(kind,name,start,end,name_pos,line,cont)."""
    toks = tokenize(s)
    decls, fields, members = [], [], []

    def line_of(pos):
        return s.count('\n', 0, pos) + 1

    def scan_container(a, b, ckind, cname):
        # tokens a..b-1 are the inside of a container
        k = a
        stmt_start = True
        while k < b:
            kind, t, st, en = toks[k]
            if not stmt_start:
                # skip to next , or ; at depth 0 (fields) handled below
                k += 1
                continue
            j = k
            while j < b and toks[j][0] == 'id' and toks[j][1] in MODS:
                j += 1
            if j < b and toks[j][1] in ('fn', 'const', 'var') and toks[j][0] == 'id':
                dk = toks[j][1]
                nm = toks[j + 1]
                if dk == 'fn':
                    # params
                    p = j + 2
                    q = match_close(toks, p)
                    r = q + 1
                    end_idx = None
                    while r < b:
                        tt = toks[r][1]
                        if tt == ';' and toks[r][0] == 'p':
                            end_idx = r
                            break
                        if tt in ('(', '['):
                            r = match_close(toks, r) + 1
                            continue
                        if tt == '{':
                            iscont, _ = is_container_brace(toks, r)
                            c = match_close(toks, r)
                            if iscont:
                                r = c + 1
                                continue
                            end_idx = c
                            break
                        r += 1
                    body_open = r if toks[end_idx][1] == '}' else None
                else:
                    r = j + 2
                    end_idx = None
                    while r < b:
                        tt = toks[r][1]
                        if toks[r][0] == 'p' and tt in ('(', '[', '{'):
                            if tt == '{':
                                iscont, ck = is_container_brace(toks, r)
                                c = match_close(toks, r)
                                if iscont:
                                    scan_container(r + 1, c, ck, nm[1])
                                r = c + 1
                                continue
                            r = match_close(toks, r) + 1
                            continue
                        if toks[r][0] == 'p' and tt == ';':
                            end_idx = r
                            break
                        r += 1
                    body_open = None
                decls.append(dict(kind=dk, name=nm[1], start=toks[k][2], end=toks[end_idx][3],
                                  name_pos=nm[2], line=line_of(toks[k][2]), cont=cname,
                                  pub=toks[k][1] == 'pub', mods=[x[1] for x in toks[k:j]]))
                k = end_idx + 1
                continue
            if toks[k][0] == 'id' and toks[k][1] in ('test', 'comptime', 'usingnamespace'):
                # skip block / statement
                r = k + 1
                while r < b and toks[r][1] not in ('{', ';'):
                    r += 1
                if toks[r][1] == '{':
                    r = match_close(toks, r)
                k = r + 1
                continue
            # field or enum member: up to ',' at depth 0 or end
            r = k
            while r < b and not (toks[r][0] == 'p' and toks[r][1] == ','):
                if toks[r][0] == 'p' and toks[r][1] in ('(', '[', '{'):
                    if toks[r][1] == '{':
                        iscont, ck = is_container_brace(toks, r)
                        c = match_close(toks, r)
                        if iscont:
                            scan_container(r + 1, c, ck, cname + '.' + toks[k][1])
                        r = c + 1
                        continue
                    r = match_close(toks, r) + 1
                    continue
                r += 1
            if toks[k][0] == 'id':
                ent = dict(name=toks[k][1], start=toks[k][2], end=toks[min(r, b) - 1][3], line=line_of(toks[k][2]),
                           cont=cname, ckind=ckind)
                if k + 1 < b and toks[k + 1][1] == ':' and ckind in ('struct', 'union'):
                    fields.append(ent)
                elif ckind == 'enum' or (ckind == 'union'):
                    members.append(ent)
            k = r + 1

    scan_container(0, len(toks), 'struct', '')
    return decls, fields, members



root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
apply_mode = '--apply' in sys.argv[1:]
src = os.path.join(root, 'src')
KEEP = {'main', 'std_options', 'panic', 'format', 'hash', 'eql', 'lessThan', 'jsonStringify', 'jsonParse', '_start'}
FAST = ['-Dtool-optimize=debug', '-Dviewer-optimize=debug']
nontest = [['zig', 'build'] + FAST, ['zig', 'build', '-Dffmpeg=false'] + FAST]
withtest = nontest + [['zig', 'build', 'test']]

files = sorted(os.path.join(d, f) for d, _, fs in os.walk(src) for f in fs if f.endswith('.zig'))
orig = {f: open(f).read() for f in files}

# id -> decl
decls = {}
nid = 0
for f in files:
    d, _, _ = parse(orig[f])
    for x in d:
        if x['name'] in KEEP or x['name'].startswith('@') or 'export' in x['mods'] or 'extern' in x['mods'] or x['name'] == '_':
            continue
        x['file'] = f
        x['id'] = nid
        decls[nid] = x
        nid += 1

renamed = set(decls)


def write_all():
    by_file = {}
    for i in renamed:
        by_file.setdefault(decls[i]['file'], []).append(decls[i])
    for f in files:
        s = orig[f]
        for x in sorted(by_file.get(f, []), key=lambda x: -x['name_pos']):
            p = x['name_pos']
            s = s[:p] + x['name'] + '__d' + str(x['id']) + s[p + len(x['name']):]
        open(f, 'w').write(s)


loc = re.compile(r'^(\S+?\.zig):(\d+):(\d+): (error|note): (.*)$')


def blocks(out):
    cur = None
    res = []
    for l in out.split('\n'):
        m = loc.match(l)
        if m:
            if m.group(4) == 'error':
                cur = {'files': set(), 'names': set(), 'msg': l}
                res.append(cur)
            if cur is not None:
                cur['files'].add(os.path.realpath(os.path.join(root, m.group(1))))
                cur['names'].update(re.findall(r"'([A-Za-z_][A-Za-z0-9_]*)'", m.group(5)))
                # struct/enum names in messages like 'foo.Bar' too
                cur['names'].update(re.findall(r"named '([A-Za-z_][A-Za-z0-9_]*)'", m.group(5)))
    return res


def fixpoint(builds, tag):
    it = 0
    while True:
        it += 1
        write_all()
        restored = set()
        failed = None
        for cmd in builds:
            p = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
            if p.returncode == 0:
                continue
            bl = blocks(p.stderr)
            for b in bl:
                hit = {i for i in renamed if decls[i]['name'] in b['names'] and os.path.realpath(decls[i]['file']) in b['files']}
                if not hit:
                    hit = {i for i in renamed if decls[i]['name'] in b['names']}
                restored |= hit
            if not restored:
                failed = p.stderr
            break
        print(f'[{tag}] iter {it}: restored {len(restored)}, renamed {len(renamed) - len(restored)}', flush=True)
        if failed:
            for f, t in orig.items():
                open(f, 'w').write(t)
            sys.exit('build fails for another reason:\n' + failed[-4000:])
        if not restored:
            return
        renamed.difference_update(restored)


try:
    fixpoint(nontest, 'nontest')
    dead_nontest = set(renamed)
    fixpoint(withtest, 'all')
finally:
    for f, t in orig.items():
        open(f, 'w').write(t)

res = []
for i in sorted(dead_nontest):
    x = dict(decls[i])
    x['status'] = 'dead' if i in renamed else 'test-only'
    res.append(x)
for x in res:
    print(f"{x['status']:9} {os.path.relpath(x['file'], root)}:{x['line']} {x['kind']} {x['cont'] + '.' if x['cont'] else ''}{x['name']}")
print(len(res), 'items,', sum(1 for r in res if r['status'] == 'dead'), 'dead')


def remove_dead():
    """Delete dead decls with their doc comments; return removed line count."""
    by = {}
    for x in res:
        if x['status'] == 'dead':
            by.setdefault(x['file'], []).append(x)
    total = 0
    for f, xs in by.items():
        s = orig[f]
        xs.sort(key=lambda x: x['start'])
        outer = []
        for x in xs:  # a dead decl inside a dead container goes with it
            if outer and x['start'] < outer[-1]['end']:
                continue
            outer.append(x)
        for x in reversed(outer):
            a = s.rfind('\n', 0, x['start']) + 1
            nl = s.find('\n', x['end'])
            b = len(s) if nl < 0 else nl + 1
            while a > 0:
                pa = s.rfind('\n', 0, a - 1) + 1
                if not s[pa:a].lstrip().startswith('///'):
                    break
                a = pa
            total += s.count('\n', a, b)
            s = s[:a] + s[b:]
        open(f, 'w').write(re.sub(r'\n{3,}', '\n\n', s))
    return total


if apply_mode:
    print('removed lines', remove_dead())
