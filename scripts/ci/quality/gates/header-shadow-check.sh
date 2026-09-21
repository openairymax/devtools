#!/bin/bash
# V16.12 (0.1.18 plan §12.16.2 第 6 条单立成门): 同名头遮蔽门禁
#
# 规则（0.1.18-架构改进方案.md:1960）：
#   同一 include 搜索路径集合内 basename 重复且内容不同 → FATAL_ERROR；
#   全仓 *_svc_adapter.h 变体施工期内收敛（llm_d / tool_d 两对先清理）。
#
# 分层裁定（fail-closed 台账模式）：
#   L1  组内副本内容相同                       → 放行
#   L2  转发对（IRON-6 R1：纯转发 + 可选别名宏）  → 放行（转发等价类连通）
#   L3  全部副本均为 /src/ 私有头且零裸 include   → 放行（无搜索路径合流）
#   L4  等价类间共享同一作用域（同一搜索路径集合）  → SHADED（plan 字面 FATAL 语义，存量台账只减不增）
#   L5  等价类作用域互异（组件搜索路径隔离）        → CROSS（合法同名，台账观察）
# 作用域近似：daemons/<name> 为 daemon 级构建目标，其余按顶层目录。
#
# 基线：v16-header-shadow-baseline.txt；--update-baseline 重建。
# 用法: header-shadow-check.sh [--update-baseline]
# 退出码: 0 = 通过；1 = 存在违例
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
BASELINE="$SCRIPT_DIR/v16-header-shadow-baseline.txt"
UPDATE_BASELINE=0
if [ "${1:-}" = "--update-baseline" ]; then
    UPDATE_BASELINE=1
fi

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

if [ ! -d "$AGENTRT" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 2
fi

python3 - "$AGENTRT" "$BASELINE" "$UPDATE_BASELINE" <<'PYEOF'
import os, re, sys
from collections import defaultdict

root, baseline, update = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

def strip_comments(txt):
    txt = re.sub(r'/\*.*?\*/', '', txt, flags=re.S)
    txt = re.sub(r'//[^\n]*', '', txt)
    return txt

def essence(txt):
    """去注释、去空白后的实质内容指纹"""
    return re.sub(r'\s+', '', strip_comments(txt))

def is_shim_of(a_path, b_path):
    """a 是否为 b 的纯转发（IRON-6 R1）：a 实质内容仅 guard + include b + #define 别名"""
    a_txt = strip_comments(open(a_path, encoding='utf-8', errors='replace').read())
    b_base = os.path.basename(b_path)
    incl_b = re.search(r'#include\s*"[^"]*' + re.escape(b_base) + r'"', a_txt)
    if not incl_b:
        return False
    leftovers = []
    for ln in a_txt.splitlines():
        s = ln.strip()
        if not s:
            continue
        if s.startswith('#include'):
            continue
        if re.match(r'#\s*(ifndef|define|endif)\s+\w+_H_?\b', s) or s in ('#pragma once', '#endif'):
            continue
        if re.match(r'#\s*endif', s):
            continue
        leftovers.append(s)
    # 剩余行只允许 #define 别名（无原型/typedef/extern 双写）
    return all(re.match(r'#\s*define\s+[A-Za-z_]\w*', s) for s in leftovers)

# ── 扫描全仓 .h ──────────────────────────────────────────────
by_name = defaultdict(list)
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if d not in ('.git', 'build', 'third_party', '_deps')]
    for fn in fns:
        if fn.endswith('.h'):
            by_name[fn].append(os.path.join(dp, fn))

conflict_groups = []   # (name, paths) 内容不同的同名组
for name, paths in sorted(by_name.items()):
    if len(paths) < 2:
        continue
    if len({essence(open(p, encoding='utf-8', errors='replace').read()) for p in paths}) > 1:
        conflict_groups.append((name, paths))

# ── 裸 include 使用面 ────────────────────────────────────────
bare_use = defaultdict(int)
conf_names = {n for n, _ in conflict_groups}
inc_re = re.compile(r'#include\s+"([A-Za-z0-9_.]+\.h)"')
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if d not in ('.git', 'build', 'third_party', '_deps')]
    for fn in fns:
        if not fn.endswith(('.c', '.h')):
            continue
        p = os.path.join(dp, fn)
        try:
            for m in inc_re.finditer(open(p, encoding='utf-8', errors='replace').read()):
                nm = m.group(1)
                if nm in conf_names:
                    bare_use[nm] += 1
        except OSError:
            pass

def rel(p):
    return p[len(root):].lstrip('/')

def scope_of(p):
    """构建目标作用域近似：daemons/<name> 为 daemon 级，其余按顶层目录"""
    parts = rel(p).split('/')
    if parts[0] == 'daemons' and len(parts) > 2:
        return parts[1]
    return parts[0]

# ── 分层裁定 ────────────────────────────────────────────────
shim_ok, private_ok, shaded, cross = [], [], [], []
for name, paths in conflict_groups:
    # L2: 转发等价类（并查思想：任一 shim 边即连通）
    parent = {p: p for p in paths}
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for i, a in enumerate(paths):
        for b in paths[i+1:]:
            if is_shim_of(a, b) or is_shim_of(b, a):
                parent[find(a)] = find(b)
    classes = defaultdict(list)
    for p in paths:
        classes[find(p)].append(p)
    if len(classes) == 1:
        shim_ok.append(name)
        continue
    # 等价类外的副本对
    real = [grp for grp in classes.values()]
    # L3: 全部副本均为 src 私有头且零裸 include → 无搜索路径合流
    if all('/src/' in p for grp in real for p in grp) and bare_use[name] == 0:
        private_ok.append(name)
        continue
    # L4/L5: 等价类间作用域判定——不同类共享作用域 = 同一搜索路径集合内互异副本
    class_scopes = [{scope_of(p) for p in grp} for grp in real]
    shared = any(class_scopes[i] & class_scopes[j]
                 for i in range(len(class_scopes))
                 for j in range(i + 1, len(class_scopes)))
    if shared:
        shaded.append((name, real))
    else:
        cross.append((name, real))

# ── 输出与基线 ───────────────────────────────────────────────
def pair_key(name, real):
    flat = sorted(rel(p) for grp in real for p in grp)
    return f"{name}|{'|'.join(flat)}"

print(f"conflict groups (content-distinct same-basename): {len(conflict_groups)}")
print(f"  [SHIM]    re-export resolved: {len(shim_ok)}")
print(f"  [PRIVATE] src-internal, no bare use: {len(private_ok)}")
print(f"  [SHADED]  same-scope distinct replicas: {len(shaded)}")
print(f"  [CROSS]   cross-scope replicas (isolated search paths): {len(cross)}")

for name in private_ok:
    print(f"  [PRIVATE] {name}")

ledger = shaded + cross
new_entries = {pair_key(n, g) for n, g in ledger}
violations = 0

if update:
    with open(baseline, 'w') as f:
        for k in sorted(new_entries):
            f.write(k + '\n')
    print(f"baseline rewritten: {baseline} ({len(new_entries)} entries)")
else:
    old_entries = set()
    if os.path.exists(baseline):
        old_entries = {l.strip() for l in open(baseline) if l.strip()}
    for name, grp in shaded:
        key = pair_key(name, grp)
        if key in old_entries:
            print(f"  [SHADED-BASELINE] {name}")
        else:
            print(f"  [SHADED-NEW] {name}: distinct replicas within one include search path scope")
            for g in grp:
                for p in g:
                    print(f"      {rel(p)}")
            violations += 1
    for name, grp in cross:
        key = pair_key(name, grp)
        if key in old_entries:
            print(f"  [CROSS-BASELINE] {name}")
        else:
            print(f"  [CROSS-NEW] {name}")
            for g in grp:
                for p in g:
                    print(f"      {rel(p)}")
            violations += 1
    shrunk = old_entries - new_entries
    for k in sorted(shrunk):
        print(f"  [SHRUNK] {k}")
    if shrunk:
        print(f"baseline entries resolved: {len(shrunk)}")

sys.exit(1 if violations else 0)
PYEOF
rc=$?

section "V16.12 header-shadow gate"
if [ "$rc" -eq 0 ]; then
    log_ok "V16.12 header-shadow gate PASSED"
    exit 0
else
    log_err "V16.12 header-shadow gate FAILED"
    exit 1
fi
