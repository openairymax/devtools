#!/bin/bash
# Gate 42 selfcheck 反向用例（0.1.20 方案 §9.3 门禁自证规则）
#
# 规则：每个门禁必须配一个反向用例脚本，注入已知违规样本，
#   断言该门禁退出码符合预期——门禁不能红等于不存在。
#
# 口径说明：本脚本注入的是「报告生产者」，不是被测的计数逻辑。计数口径的唯一
#   权威实现在 loc-budget-check.sh 的 count_loc()，由 Gate 18 负责；Gate 42 只
#   拥有判定逻辑（表内自洽 + 账本对齐），故以受控报告驱动其判定面。
#
# 用例：
#   V1 实测 > pin（超账）                → 红（主判据）
#   V2 实测 < pin（账本滞后未落账）      → 红
#   V3 明细和 != 账合计（表内不自洽）    → 红
#   C1 三账全对齐                        → 绿
#   C2 减重后 --converge 落账仍对齐      → 绿
#
# 用法: selfcheck/gate-42.sh
# 退出码: 0 = 全部用例符合预期；1 = selfcheck 失败
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="${GATES_DIR}/g42-ledger-consistency.sh"

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

# fixture: $1=目录名 $2=报告正文 $3=基线正文
fixture() {
    local dir="$TMP/$1"
    mkdir -p "$dir"
    printf '%b\n' "$2" > "$dir/report.txt"
    printf '#!/bin/bash\ncat "%s/report.txt"\n' "$dir" > "$dir/lb.sh"
    printf '%b\n' "$3" > "$dir/baseline.txt"
}

run_gate() {
    local dir="$1" rc=0
    G42_LB="$TMP/$dir/lb.sh" G42_BASELINE="$TMP/$dir/baseline.txt" \
        bash "$CHECK" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

BASE_OK='core=100
facade=60
cupolas=40'
ROWS_OK='core.atoms=70
core.commons=30
facade.daemons=60'

# ── V1: 实测 > pin → 红 ─────────────────────────────────────
section "V1: measured above pin must be red"
fixture v1 "core=120
facade=60
cupolas=40
core.atoms=90
core.commons=30
facade.daemons=60" "$BASE_OK"
expect_rc "V1 over-ledger" 1 "$(run_gate v1)"

# ── V2: 实测 < pin（减重未落账）→ 红 ────────────────────────
section "V2: pin left behind by a reduction must be red"
fixture v2 "core=100
facade=60
cupolas=30
core.atoms=70
core.commons=30
facade.daemons=60" "$BASE_OK"
expect_rc "V2 lagging pin" 1 "$(run_gate v2)"

# ── V3: 明细和 != 合计 → 红 ─────────────────────────────────
section "V3: breakdown that does not add up must be red"
fixture v3 "core=100
facade=60
cupolas=40
core.atoms=70
core.commons=20
facade.daemons=60" "$BASE_OK"
expect_rc "V3 broken table" 1 "$(run_gate v3)"

# ── C1: 三账全对齐 → 绿 ─────────────────────────────────────
section "C1: aligned ledgers must stay green"
fixture c1 "core=100
facade=60
cupolas=40
$ROWS_OK" "$BASE_OK"
expect_rc "C1 aligned" 0 "$(run_gate c1)"

# ── C2: 减重并 --converge 落账 → 绿 ─────────────────────────
section "C2: reduction converged into the baseline must stay green"
fixture c2 "core=90
facade=60
cupolas=40
core.atoms=60
core.commons=30
facade.daemons=60" 'core=90
facade=60
cupolas=40'
expect_rc "C2 converged" 0 "$(run_gate c2)"

section "Gate 42 selfcheck verdict"
log_ok "5/5 用例符合预期（三红两绿）"
exit 0
