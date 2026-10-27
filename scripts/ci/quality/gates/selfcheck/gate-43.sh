#!/bin/bash
# Gate 43 selfcheck 反向用例（0.1.20 方案 §9.3 门禁自证规则）
#
# 规则：每个门禁必须配一个反向用例脚本，注入已知违规样本，
#   断言该门禁退出码为 1（能红）——门禁不能红等于不存在。
#
# 用例：
#   V1 未登记即红（主判据 G-W6-1）：树内新族不在登记表
#   V2 幽灵条目红：登记表含树内零实例的族
#   V3 非法归属值红：归属字段逃逸四值词表
#   C1 对照不误报：合规样本必须绿
#
# 用法: selfcheck/gate-43.sh
# 退出码: 0 = 全部用例符合预期；1 = selfcheck 失败
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="${GATES_DIR}/facade-attribution-check.sh"

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

# ── V1: 未登记即红 ──────────────────────────────────────────
section "V1: unregistered family must be red"
mkdir -p "$TMP/v1/src"
printf 'static const evil_new_ops_t g_x;\n' > "$TMP/v1/src/sample.c"
rc=0
FACADE_SCAN_ROOTS="$TMP/v1/src" \
FACADE_REGISTRY="${GATES_DIR}/facade-attribution.txt" \
    bash "$CHECK" >/dev/null 2>&1 || rc=$?
expect_rc "V1 unregistered" 1 "$rc"

# ── V2: 幽灵条目红 ──────────────────────────────────────────
section "V2: registry ghost entry must be red"
mkdir -p "$TMP/v2/src"
printf 'static const live_ops_t g_y;\n' > "$TMP/v2/src/sample.c"
printf 'live_ops_t|platform\nghost_ops_t|evolution\n' > "$TMP/v2/registry.txt"
rc=0
FACADE_SCAN_ROOTS="$TMP/v2/src" \
FACADE_REGISTRY="$TMP/v2/registry.txt" \
    bash "$CHECK" >/dev/null 2>&1 || rc=$?
expect_rc "V2 ghost entry" 1 "$rc"

# ── V3: 非法归属值红 ────────────────────────────────────────
section "V3: illegal facade value must be red"
mkdir -p "$TMP/v3/src"
printf 'static const fake_ops_t g_z;\n' > "$TMP/v3/src/sample.c"
printf 'fake_ops_t|ocean\n' > "$TMP/v3/registry.txt"
rc=0
FACADE_SCAN_ROOTS="$TMP/v3/src" \
FACADE_REGISTRY="$TMP/v3/registry.txt" \
    bash "$CHECK" >/dev/null 2>&1 || rc=$?
expect_rc "V3 illegal facade" 1 "$rc"

# ── C1: 对照不误报 ──────────────────────────────────────────
section "C1: compliant sample must stay green"
mkdir -p "$TMP/c1/src"
printf 'static const fake_ops_t g_w;\n' > "$TMP/c1/src/sample.c"
printf 'fake_ops_t|platform\n' > "$TMP/c1/registry.txt"
rc=0
FACADE_SCAN_ROOTS="$TMP/c1/src" \
FACADE_REGISTRY="$TMP/c1/registry.txt" \
    bash "$CHECK" >/dev/null 2>&1 || rc=$?
expect_rc "C1 compliant green" 0 "$rc"

section "Gate 43 selfcheck verdict"
log_ok "4/4 用例符合预期（三红一绿）"
exit 0
