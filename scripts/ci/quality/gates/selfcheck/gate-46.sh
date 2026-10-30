#!/bin/bash
# Gate 46 selfcheck 反向用例（0.1.20 方案 §9.3 门禁自证规则）
#
# 规则：每个门禁必须配一个反向用例脚本，注入已知违规样本，
#   断言该门禁退出码符合预期——门禁不能红等于不存在。
#
# 口径说明：本脚本注入的是「四模块守卫」本身（fixture 内的最小守卫），
#   不是被测的守卫判据。守卫判据单点在 ecosystem 各模块仓库内，Gate 46
#   只拥有执法逻辑（是否真实执行、是否 fail-closed），故以受控守卫驱动。
#
# 用例：
#   V1 agents 守卫判红            → 红
#   V2 markets 守卫判红           → 红
#   V3 prompts 守卫判红           → 红
#   V4 skills 守卫判红            → 红
#   V5 守卫文件缺席（不得 skip）  → 红（fail-closed）
#   C1 四守卫全绿                 → 绿
#
# 用法: selfcheck/gate-46.sh
# 退出码: 0 = 全部用例符合预期；1 = selfcheck 失败
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="${GATES_DIR}/g46-ecosystem-contract.sh"

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

# 直跑型守卫（unittest/script）：退出码即判定
mk_direct() {
    mkdir -p "$(dirname "$1")"
    printf 'import sys\nsys.exit(%s)\n' "$2" > "$1"
}

# pytest 型守卫：断言结果即判定
mk_pytest() {
    mkdir -p "$(dirname "$1")"
    if [ "$2" -eq 0 ]; then
        printf 'def test_ok():\n    assert True\n' > "$1"
    else
        printf 'def test_bad():\n    assert False\n' > "$1"
    fi
}

# fixture: $1=目录 $2..$5 = agents/markets/prompts/skills 期望（0 绿 / 1 红 / x 缺席）
fixture() {
    local d="$TMP/$1"
    mkdir -p "$d"
    [ "$2" = x ] || mk_direct "$d/agents/tests/test_vocab_consistency.py" "$2"
    [ "$3" = x ] || mk_pytest "$d/markets/tests/test_contract_consistency.py" "$3"
    [ "$4" = x ] || mk_direct "$d/prompts/scripts/validate_registry.py" "$4"
    [ "$5" = x ] || mk_pytest "$d/skills/tests/test_skills.py" "$5"
}

run_gate() {
    local rc=0
    G46_ECO_ROOT="$TMP/$1" bash "$CHECK" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# ── V1~V4: 任一模块守卫判红即红 ─────────────────────────────
section "V1: agents guard red must be red"
fixture v1 1 0 0 0
expect_rc "V1 agents red" 1 "$(run_gate v1)"

section "V2: markets guard red must be red"
fixture v2 0 1 0 0
expect_rc "V2 markets red" 1 "$(run_gate v2)"

section "V3: prompts guard red must be red"
fixture v3 0 0 1 0
expect_rc "V3 prompts red" 1 "$(run_gate v3)"

section "V4: skills guard red must be red"
fixture v4 0 0 0 1
expect_rc "V4 skills red" 1 "$(run_gate v4)"

# ── V5: 守卫缺席不得 skip（fail-closed）────────────────────
section "V5: absent guard must be red, never skipped"
fixture v5 0 x 0 0
expect_rc "V5 guard absent" 1 "$(run_gate v5)"

# ── C1: 四守卫全绿 → 绿 ────────────────────────────────────
section "C1: four green guards must stay green"
fixture c1 0 0 0 0
expect_rc "C1 all green" 0 "$(run_gate c1)"

section "Gate 46 selfcheck verdict"
log_ok "6/6 用例符合预期（五红一绿）"
exit 0
