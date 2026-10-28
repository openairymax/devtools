#!/bin/bash
# Gate 41 selfcheck 反向用例（0.1.20 方案 §9.3 门禁自证规则）
#
# 规则：每个门禁必须配一个反向用例脚本，注入已知违规样本，
#   断言该门禁退出码符合预期——门禁不能红等于不存在。
#
# 用例：
#   V1 锚点后上升无 RATCHET-JUSTIFY → 红（主判据）
#   C1 上升但同 commit 带 RATCHET-JUSTIFY → 绿
#   C2 pin 下降 → 绿
#   C3 锚点之前的漂移豁免 → 绿
#
# 用法: selfcheck/gate-41.sh
# 退出码: 0 = 全部用例符合预期；1 = selfcheck 失败
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="${GATES_DIR}/g41-ratchet-audit.sh"

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

new_repo() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email selfcheck@g41.local
    git -C "$dir" config user.name g41-selfcheck
    printf 'current=K1\nfacade=100\ncupolas=50\n' > "$dir/v16-loc-budget-baseline.txt"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "c1: seed baseline"
    git -C "$dir" rev-parse HEAD
}

run_gate() {
    local repo="$1" anchor="$2"
    local rc=0
    RATCHET_REPO="$repo" \
    RATCHET_BASELINE="$repo/v16-loc-budget-baseline.txt" \
    RATCHET_ANCHOR="$anchor" \
        bash "$CHECK" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# ── V1: 锚点后上升无 justify → 红 ───────────────────────────
section "V1: pin rise without RATCHET-JUSTIFY must be red"
R1="$(new_repo "$TMP/v1")"
printf 'current=K1\nfacade=120\ncupolas=50\n' > "$TMP/v1/v16-loc-budget-baseline.txt"
git -C "$TMP/v1" add -A && git -C "$TMP/v1" commit -qm "c2: raise facade"
rc="$(run_gate "$TMP/v1" "$R1")"
expect_rc "V1 unjustified rise" 1 "$rc"

# ── C1: 上升但带 justify → 绿 ───────────────────────────────
section "C1: justified rise must stay green"
C1="$(new_repo "$TMP/c1")"
printf 'current=K1\nfacade=120\ncupolas=50\n' > "$TMP/c1/v16-loc-budget-baseline.txt"
git -C "$TMP/c1" add -A
git -C "$TMP/c1" commit -qm "c2: raise facade for the transport batch

RATCHET-JUSTIFY: ${C1:0:12} +20 lands the D8 transport landing"
rc="$(run_gate "$TMP/c1" "$C1")"
expect_rc "C1 justified rise" 0 "$rc"

# ── C2: pin 下降 → 绿 ───────────────────────────────────────
section "C2: pin decrease must stay green"
C2="$(new_repo "$TMP/c2")"
printf 'current=K1\nfacade=80\ncupolas=50\n' > "$TMP/c2/v16-loc-budget-baseline.txt"
git -C "$TMP/c2" add -A && git -C "$TMP/c2" commit -qm "c2: shrink facade"
rc="$(run_gate "$TMP/c2" "$C2")"
expect_rc "C2 decrease" 0 "$rc"

# ── C3: 锚点之前的漂移豁免 → 绿 ──────────────────────────────
section "C3: drift before the anchor must be exempt"
C3="$(new_repo "$TMP/c3")"
printf 'current=K1\nfacade=140\ncupolas=50\n' > "$TMP/c3/v16-loc-budget-baseline.txt"
git -C "$TMP/c3" add -A && git -C "$TMP/c3" commit -qm "c2: legacy untracked rise"
LEGACY="$(git -C "$TMP/c3" rev-parse HEAD)"
printf 'current=K1\nfacade=140\ncupolas=50\n# c3 audit touch\n' > "$TMP/c3/v16-loc-budget-baseline.txt"
git -C "$TMP/c3" add -A && git -C "$TMP/c3" commit -qm "c3: post-anchor touch without rise"
rc="$(run_gate "$TMP/c3" "$LEGACY")"
expect_rc "C3 pre-anchor exemption" 0 "$rc"

section "Gate 41 selfcheck verdict"
log_ok "4/4 用例符合预期（一红三绿）"
exit 0
