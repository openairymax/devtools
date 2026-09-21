#!/bin/bash
# V16.13 (0.1.18 plan §12.16.7): 传播面与死信号门禁
#
# 规则（0.1.18-架构改进方案.md:1961）：
#   ① target_include_directories(... PUBLIC ...) 内出现 ${CMAKE_CURRENT_SOURCE_DIR}/src
#      及其子目录 → FATAL_ERROR（llm_d / a2a_d / common / gateway_d 收敛前常红，属预期，台账承载）
#   ② __attribute__((unused)) 在 daemons/ 内计数只减不增（0.1.19 末清零）
#
# 分层裁定（fail-closed 台账模式）：
#   A1 逐 CMakeLists.txt 解析 target_include_directories 块（括号平衡），
#      PUBLIC/INTERFACE 段内 ${CMAKE_CURRENT_SOURCE_DIR}/src 路径条目 → 基线只减不增
#   A2 PRIVATE 段内 /src 路径 → 合法（不外传，不入台账）
#   B1 daemons/ 内 __attribute__((unused)) 计数 ≤ 基线（宽松正则含 __unused/空格变体）；
#      下降时提示 --update-baseline 锁定新低位
#
# 基线：v16-propagation-dead-signal-baseline.txt（A|file:line:tok / B|count）；--update-baseline 重建。
# 用法: propagation-dead-signal-check.sh [--update-baseline]
# 退出码: 0 = 通过；1 = 存在违例
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
BASELINE="$SCRIPT_DIR/v16-propagation-dead-signal-baseline.txt"
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

def rel(p):
    return p[len(root):].lstrip('/')

def walk_src(top, exts):
    for dp, dns, fns in os.walk(top):
        dns[:] = [d for d in dns if d not in ('.git', 'build', 'third_party', '_deps')]
        for fn in fns:
            if fn.endswith(exts):
                yield os.path.join(dp, fn)

# ── A 段：CMake PUBLIC/INTERFACE 段内 src 传播面 ─────────────
def include_dir_blocks(txt):
    """yield (start_line, body) for each balanced target_include_directories(...)"""
    key = 'target_include_directories('
    idx = 0
    while True:
        i = txt.find(key, idx)
        if i < 0:
            break
        line_no = txt.count('\n', 0, i) + 1
        depth, k = 0, i + len(key) - 1          # 位于 '('
        while k < len(txt):
            if txt[k] == '(':
                depth += 1
            elif txt[k] == ')':
                depth -= 1
                if depth == 0:
                    break
            k += 1
        yield line_no, txt[i + len(key):k]
        idx = k + 1

prop_hits = []      # (file, block_line, token)
for p in walk_src(root, ('CMakeLists.txt',)):
    txt = open(p, encoding='utf-8', errors='replace').read()
    for line_no, body in include_dir_blocks(txt):
        seg = None
        for tok in body.replace('\\\n', ' ').replace('\n', ' ').split():
            if tok in ('PUBLIC', 'PRIVATE', 'INTERFACE'):
                seg = tok
                continue
            if seg in ('PUBLIC', 'INTERFACE') and '${CMAKE_CURRENT_SOURCE_DIR}/src' in tok:
                prop_hits.append((rel(p), line_no, tok))

# ── B 段：daemons/ 内 __attribute__((unused)) 计数 ───────────
ux_re = re.compile(r'__attribute__\s*\(\(\s*(__)?unused(__)?\s*\)\)')
ux_count = 0
ux_files = defaultdict(int)
for p in walk_src(os.path.join(root, 'daemons'), ('.c', '.h')):
    txt = open(p, encoding='utf-8', errors='replace').read()
    n = len(ux_re.findall(txt))
    if n:
        ux_count += n
        ux_files[rel(p)] = n

# ── 基线读写 ─────────────────────────────────────────────────
new_a = {f"A|{f}:{ln}:{tok}" for f, ln, tok in prop_hits}
new_b = f"B|{ux_count}"

old_a, old_b = set(), None
if os.path.exists(baseline):
    for l in open(baseline):
        l = l.strip()
        if not l or l.startswith('#'):
            continue
        if l.startswith('A|'):
            old_a.add(l)
        elif l.startswith('B|'):
            old_b = int(l[2:])

print(f"A) PUBLIC/INTERFACE src propagation hits: {len(prop_hits)}")
print(f"B) __attribute__((unused)) in daemons/:   {ux_count} across {len(ux_files)} files")

violations = 0
if update:
    with open(baseline, 'w') as f:
        for k in sorted(new_a):
            f.write(k + '\n')
        f.write(new_b + '\n')
    print(f"baseline rewritten: {baseline} ({len(new_a)} A-entries, B={ux_count})")
else:
    for k in sorted(new_a & old_a):
        print(f"  [A-BASELINE] {k}")
    for k in sorted(new_a - old_a):
        print(f"  [A-NEW] {k}")
        violations += 1
    shrunk_a = old_a - new_a
    for k in sorted(shrunk_a):
        print(f"  [A-SHRUNK] {k}")
    if shrunk_a:
        print(f"A-entries resolved: {len(shrunk_a)} (run --update-baseline to lock)")
    if old_b is None:
        print(f"  [B-NEW] no baseline count (run --update-baseline)")
        violations += 1
    elif ux_count > old_b:
        print(f"  [B-GROW] {old_b} -> {ux_count} (+{ux_count - old_b}): unused must never grow")
        for f, n in sorted(ux_files.items()):
            print(f"      {f}: {n}")
        violations += 1
    elif ux_count < old_b:
        print(f"  [B-SHRUNK] {old_b} -> {ux_count} (-{old_b - ux_count}): run --update-baseline to lock")
    else:
        print(f"  [B-BASELINE] count unchanged at {ux_count}")

sys.exit(1 if violations else 0)
PYEOF
rc=$?

section "V16.13 propagation & dead-signal gate"
if [ "$rc" -eq 0 ]; then
    log_ok "V16.13 propagation & dead-signal gate PASSED"
    exit 0
else
    log_err "V16.13 propagation & dead-signal gate FAILED"
    exit 1
fi
