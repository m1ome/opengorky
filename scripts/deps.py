#!/usr/bin/env python3
# Import graph of @import("….zig") in src/: cycles between files (mode file)
# and between subsystems (mode group). Usage: scripts/deps.py . file|group.
# Both modes exit 1 on any cycle (regress scenario deps); without cycles,
# group mode prints the folders by layer, bottom up (hosts on top, via og.X uses).

import os,re,sys,collections
root=sys.argv[1]; src=os.path.join(root,'src')
files=[os.path.join(d,f) for d,_,fs in os.walk(src) for f in fs if f.endswith('.zig')]
imp=re.compile(r'@import\("([^"]+\.zig)"\)')
G=collections.defaultdict(set)
for f in files:
    for m in imp.finditer(open(f).read()):
        t=os.path.normpath(os.path.join(os.path.dirname(f),m.group(1)))
        if os.path.exists(t): G[os.path.relpath(f,src)].add(os.path.relpath(t,src))
def group(p):
    parts=p.split('/')
    if parts[0] in('viewer','tool'): return parts[0]
    if len(parts)==1: return parts[0][:-4]
    return parts[0]
# folder-level: merge foo.zig with foo/
H=collections.defaultdict(set); W=collections.defaultdict(list)
for a,bs in G.items():
    for b in bs:
        ga,gb=group(a),group(b)
        if ga!=gb: H[ga].add(gb); W[(ga,gb)].append(f"{a} -> {b}")
# Hosts (viewer, tool) reach the engine through the `opengorky` module: `og.X` uses are
# edges to the group of root.zig's export X.
og_exp={m.group(1):group(os.path.normpath(m.group(2))) for m in
        re.finditer(r'pub const (\w+) = @import\("([^"]+\.zig)"\)',open(os.path.join(src,'root.zig')).read())}
for f in files:
    a=os.path.relpath(f,src)
    if group(a) not in ('viewer','tool'): continue
    for m in set(re.findall(r'\bog\.(\w+)',open(f).read())):
        if m in og_exp: H[group(a)].add(og_exp[m]); W[(group(a),og_exp[m])].append(f"{a} -> og.{m}")
# tarjan
idx={};low={};st=[];on=set();sccs=[];c=[0]
def sc(v):
    idx[v]=low[v]=c[0];c[0]+=1;st.append(v);on.add(v)
    for w in H[v]:
        if w not in idx: sc(w);low[v]=min(low[v],low[w])
        elif w in on: low[v]=min(low[v],idx[w])
    if low[v]==idx[v]:
        s=[]
        while True:
            w=st.pop();on.discard(w);s.append(w)
            if w==v:break
        sccs.append(s)
for v in list(H): 
    if v not in idx: sc(v)
mode=sys.argv[2] if len(sys.argv)>2 else 'group'
if mode=='group':
    bad=[s for s in sccs if len(s)>1]
    for s in bad:
        print('CYCLE:',sorted(s))
        for a in s:
            for b in s:
                if (a,b) in W: print(f'  {a}->{b}: {len(W[(a,b)])}  e.g. {W[(a,b)][0]}')
    if not bad:
        L={}
        def lv(g): 
            if g not in L: L[g]=1+max([lv(h) for h in H[g]],default=-1)
            return L[g]
        for g in {group(f) for f in G}: lv(g)
        for n in sorted(set(L.values())): print(n, ' '.join(sorted(g for g in L if L[g]==n)))
    sys.exit(1 if bad else 0)
else:
    # file-level SCCs
    H2=G; idx.clear();low.clear();st.clear();on.clear();sccs.clear();c[0]=0
    H.clear(); H.update(G)
    for v in list(G):
        if v not in idx: sc(v)
    # The editor is an application of its own, its pages and its state import each other
    # (app.zig ↔ pages): its cycles are not checked; the engine's and the viewer's are.
    bad=[s for s in sccs if len(s)>1 and not all(f.startswith('editor/') for f in s)]
    for s in bad: print('FILE CYCLE',len(s),sorted(s))
    # Entry points: another folder imports F/x.zig only through F.zig, unless
    # x.zig itself imports F.zig (it can't be re-exported without a cycle).
    for a,bs in list(G.items()):
        for b in bs:
            p=b.split('/')
            if len(p)!=2 or group(a)==p[0] or not os.path.exists(os.path.join(src,p[0]+'.zig')): continue
            if p[0]+'.zig' in G.get(b,()): continue
            bad.append(b); print(f'ENTRY: {a} imports {b}, use {p[0]}.zig')
    sys.exit(1 if bad else 0)
