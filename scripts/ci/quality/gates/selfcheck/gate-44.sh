#!/bin/bash
# Gate 44 selfcheck 元门禁（0.1.20 方案 §9.3 / §9 Gate 44）
#
# 职责：审计门禁体系自身的 fail-closed 属性——门禁审计门禁，
#   审计器自身不能红等于不存在（T4 突变自证闭环）。
#
# 用例：
#   T1 静态审计：编排器 gate_* 函数体内 "not found/skipped" 类
#      无法判定消息必须映射 check_gate 1（红）；WARN 映射或缺判定即违例
#   T2 缺脚本活体反证：剥离 main 后函数级挂载，删除委托脚本，
#      断言对应 gate 函数返回 1 且 GATE_FAIL 计数入账
#   T3 缺基线不静默反证：隔离树中删除棘轮基线，断言门禁红且
#      基线不被静默重建（删除基线不得成为绕过门禁的退路）
#   T4 突变红自证：构造退化突变体（判定翻 WARN / 判定移除），
#      断言 T1 审计器必须检出——审计器失明等于元门禁失效
#   T5 selfcheck 清单完整性：gate-31/32/33/34/35/36/37/38/39/40/41/42/
#      43/44/45 与 layer-check（Gate 24 E 段）必须在册
#
# 用法: selfcheck/gate-44.sh
# 退出码: 0 = 全部断言符合预期；1 = 元审计失败
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH="${GATES_DIR}/quality-gate.sh"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect_rc() {
    local name="$1" want="$2" rc="$3"
    if [ "$rc" -eq "$want" ]; then
        log_ok "${name}: exit ${rc}（期望 ${want}）"
    else
        log_err "${name}: exit ${rc}，期望 ${want}"
        exit 1
    fi
}

# A 类 fail-closed 不变量审计器（T1 主判据 / T4 突变靶）：
# gate_* 函数体内 "not found/skipped" 类无法判定消息，其后的
# check_gate 判定必须是 1（红）；映射 WARN 或缺失判定均判违例。
audit_orch() {
    python3 - "$1" <<'PYAUDIT'
import re, sys
path = sys.argv[1]
lines = open(path, encoding='utf-8').read().splitlines()
viol = []
cur_fn = None
for i, line in enumerate(lines):
    m = re.match(r'^(gate_\w+)\s*\(\)\s*\{', line)
    if m:
        cur_fn = m.group(1)
    elif re.match(r'^}\s*$', line):
        cur_fn = None
    if cur_fn and ('not found' in line or 'skipped' in line):
        hit = None
        for w in lines[i+1:i+7]:
            g = re.search(r'check_gate\s+"[A-Za-z0-9_-]+"\s+(\d)', w)
            if g:
                hit = g.group(1)
                break
        if hit is None:
            viol.append("%s:%d: [%s] cannot-judge branch has no check_gate verdict" % (path, i + 1, cur_fn))
        elif hit != '1':
            viol.append("%s:%d: [%s] cannot-judge branch maps to WARN(%s)" % (path, i + 1, cur_fn, hit))
if viol:
    print("\n".join(viol))
    sys.exit(1)
print("audit clean: %s" % path)
sys.exit(0)
PYAUDIT
}

# ── T1: 静态审计（真实编排器必须 CLEAN）─────────────────────
section "T1: static audit of orchestrator fail-closed invariant"
rc=0
audit_orch "$ORCH" || rc=$?
expect_rc "T1 orchestrator audit clean" 0 "$rc"

# ── T2: 缺脚本活体反证（函数级挂载）─────────────────────────
section "T2: missing gate script must map red (live probe)"
T2_GATES="$TMP/t2/gates"
mkdir -p "$T2_GATES"
cp "$ORCH" "$T2_GATES/"
cp "${GATES_DIR}/stub-scan-check.sh" "$T2_GATES/"
cp "${GATES_DIR}/file-length-check.sh" "$T2_GATES/"
# 函数级技法：sed '$d' 剥离尾行 main 调用后 source（三端可移植）。
# source 会重放编排器的 set -euo pipefail，必须立即解除，否则 gate
# 函数 return 1 触发 -e 直接退出；source 下 $0 指向本脚本，须手动
# 复位 SCRIPT_DIR 到隔离副本。
source <(sed '$d' "$T2_GATES/quality-gate.sh")
set +e +o pipefail
SCRIPT_DIR="$T2_GATES"

rm "$T2_GATES/stub-scan-check.sh"
rc=0
gate_stub_scan >/dev/null 2>&1 || rc=$?
expect_rc "T2a stub-scan missing red" 1 "$rc"
expect_rc "T2b StubScan verdict counted" 1 "$GATE_FAIL"

rm "$T2_GATES/file-length-check.sh"
rc=0
gate_file_length >/dev/null 2>&1 || rc=$?
expect_rc "T2c file-length missing red" 1 "$rc"
expect_rc "T2d FileLength verdict counted" 2 "$GATE_FAIL"

# ── T3: 缺基线不静默反证（隔离树）───────────────────────────
section "T3: missing ratchet baseline must be red, never recreated"
T3="$TMP/t3"
T3_GATES="$T3/a/b/c/d/e/gates"
mkdir -p "$T3_GATES" \
    "$T3/a/agent-workload/agentrt/commons/include" \
    "$T3/a/agent-workload/agentrt/daemons/demo"
cp "${GATES_DIR}/port-coord-check.sh" "$T3_GATES/"
# 副本经 SCRIPT_DIR 五级上溯解析 PROJECT_ROOT，树须落在 a/ 之下
printf '#pragma once\n#define AIRY_PORT_BAND_MIN 2026\n#define AIRY_PORT_BAND_MAX 2100\n#define AIRY_PORT_GATEWAY 2080\n' \
    > "$T3/a/agent-workload/agentrt/commons/include/airy_defaults.h"
printf 'static int port = 2099;\n' > "$T3/a/agent-workload/agentrt/daemons/demo/demo.c"
printf '1\n' > "$T3_GATES/port-coord-baseline.txt"
rc=0
bash "$T3_GATES/port-coord-check.sh" >/dev/null 2>&1 || rc=$?
expect_rc "T3a harness control at-watermark" 2 "$rc"
rm "$T3_GATES/port-coord-baseline.txt"
rc=0
bash "$T3_GATES/port-coord-check.sh" >/dev/null 2>&1 || rc=$?
expect_rc "T3b missing baseline red" 1 "$rc"
if [ -f "$T3_GATES/port-coord-baseline.txt" ]; then
    log_err "T3c: baseline silently recreated (must stay absent)"
    exit 1
fi
log_ok "T3c: baseline not silently recreated"

# ── T4: 突变红自证（审计器必须能红）─────────────────────────
section "T4: degraded mutations must be flagged (auditor self-proof)"
T4D="$TMP/t4"
mkdir -p "$T4D"
python3 - "$ORCH" "$T4D/m1.sh" <<'PYMUT'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines(keepends=True)
mutated = 0
for i, line in enumerate(lines):
    if 'stub scan check script not found' in line:
        for j in range(i + 1, min(i + 7, len(lines))):
            if 'check_gate "StubScan" 1' in lines[j]:
                lines[j] = lines[j].replace('check_gate "StubScan" 1', 'check_gate "StubScan" 2')
                mutated += 1
                break
        break
assert mutated == 1, "mutation target not found"
open(sys.argv[2], 'w', encoding='utf-8').write(''.join(lines))
PYMUT
rc=0
audit_orch "$T4D/m1.sh" >/dev/null 2>&1 || rc=$?
expect_rc "T4a WARN-mapping mutation flagged" 1 "$rc"

python3 - "$ORCH" "$T4D/m2.sh" <<'PYMUT'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines(keepends=True)
mutated = 0
for i, line in enumerate(lines):
    if 'stub scan check script not found' in line:
        for j in range(i + 1, min(i + 7, len(lines))):
            if 'check_gate "StubScan" 1' in lines[j]:
                lines[j] = ''
                mutated += 1
                break
        break
assert mutated == 1, "mutation target not found"
open(sys.argv[2], 'w', encoding='utf-8').write(''.join(lines))
PYMUT
rc=0
audit_orch "$T4D/m2.sh" >/dev/null 2>&1 || rc=$?
expect_rc "T4b verdict-removal mutation flagged" 1 "$rc"

# ── T5: selfcheck 清单完整性 ────────────────────────────────
section "T5: selfcheck checklist completeness"
for s in gate-31.sh gate-32.sh gate-33.sh gate-34.sh gate-35.sh gate-36.sh gate-37.sh gate-38.sh gate-39.sh gate-40.sh gate-41.sh gate-42.sh gate-43.sh gate-44.sh gate-45.sh layer-check.sh; do
    if [ -f "${GATES_DIR}/selfcheck/$s" ]; then
        log_ok "T5: selfcheck/$s present"
    else
        log_err "T5: selfcheck/$s missing"
        exit 1
    fi
done

section "Gate 44 selfcheck verdict"
log_ok "16 项断言全部符合预期（A 类假绿面全数可检出，审计器自证可红）"
exit 0
