#!/usr/bin/env python3
# Unused `pub`: declarations in src/ that no other file needs.
#   scripts/pubcheck.py .            fast: a decl counts as used if any other file has `.name`
#                                    (misses common names like init/tick/draw); regress `deps`.
#   scripts/pubcheck.py . --compile  exact, slow: drops every `pub`, rebuilds all variants and
#                                    restores only what the compiler asks for; reports the rest.
#   scripts/pubcheck.py . --apply    as --compile, but leaves the unneeded `pub`s removed.
# Exits 1 if any unused `pub` is found.
import os, re, subprocess, sys

root = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else ''
src = os.path.join(root, 'src')
# Called by std through comptime checks (@hasDecl/hasMethod), or roots the compiler looks up.
keep = {'main', 'std_options', 'panic', 'format', 'hash', 'eql', 'lessThan'}
decl = re.compile(r'^([ \t]*)pub\s+((?:inline\s+)?(?:fn|const|var)\s+(\w+))', re.M)
files = sorted(os.path.join(d, f) for d, _, fs in os.walk(src) for f in fs if f.endswith('.zig'))


def fast():
    text = {f: re.sub(r'//[^\n]*', '', open(f).read()) for f in files}
    bad = []
    for f in files:
        for m in decl.finditer(open(f).read()):
            name = m.group(3)
            if name in keep:
                continue
            dot = re.compile(r'\.' + name + r'\b')
            if not any(dot.search(text[g]) for g in files if g != f):
                line = open(f).read()[:m.start()].count('\n') + 1
                bad.append(f'{os.path.relpath(f, root)}:{line}: pub {name} unused outside the file')
    return bad


builds = [['zig', 'build'], ['zig', 'build', '-Dffmpeg=false'], ['zig', 'build', 'test']]
needed = re.compile(r"^(\S+\.zig):(\d+):\d+: note: declared here", re.M)
not_pub = re.compile(r"error: '(\w+)' is not marked 'pub'")


def exact(apply):
    orig = {f: open(f).read() for f in files}
    stripped = {}  # (file, line) -> name, every pub we removed
    for f in files:
        lines = orig[f].split('\n')
        for i, l in enumerate(lines):
            m = decl.match(l)
            if m and m.group(3) not in keep:
                lines[i] = m.group(1) + m.group(2) + l[m.end():]
                stripped[(os.path.realpath(f), i + 1)] = m.group(3)
        open(f, 'w').write('\n'.join(lines))
    try:
        while True:
            restored = 0
            for cmd in builds:
                out = subprocess.run(cmd, cwd=root, capture_output=True, text=True).stderr
                errs = [e for e in out.split('\n') if 'error:' in e]
                if not errs:
                    continue
                # each "not marked 'pub'" error is followed by its "declared here" note
                for m in needed.finditer(out):
                    key = (os.path.realpath(os.path.join(root, m.group(1))), int(m.group(2)))
                    if key in stripped:
                        f, n = key
                        lines = open(f).read().split('\n')
                        mm = re.match(r'^([ \t]*)', lines[n - 1])
                        lines[n - 1] = mm.group(1) + 'pub ' + lines[n - 1][mm.end():]
                        open(f, 'w').write('\n'.join(lines))
                        del stripped[key]
                        restored += 1
                if restored == 0:
                    sys.exit('pubcheck: build fails for another reason:\n' + '\n'.join(errs[:20]))
                break  # rebuild from the first variant after restoring
            if restored == 0:
                break
        bad = [f'{os.path.relpath(f, root)}:{n}: pub {name} not needed' for (f, n), name in sorted(stripped.items())]
    finally:
        if not apply:
            for f, t in orig.items():
                open(f, 'w').write(t)
    return bad


bad = exact(mode == '--apply') if mode in ('--compile', '--apply') else fast()
print('\n'.join(bad))
sys.exit(1 if bad else 0)
