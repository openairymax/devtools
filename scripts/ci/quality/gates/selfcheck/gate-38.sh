#!/bin/bash
# Gate 38 金丝雀六门禁可触发 selfcheck 反向用例（0.1.20 方案 §9.1 Gate 38 / §9.1.2 / §9.3）
#
# 规则：六道门禁 K1-K6 六次独立注入必须分别返回 -2/-3/-4/-5/-6/-7；
#   任一恒真即红——门禁恒真等于给自演化发无限额度通行证（§4.3.2 P1-2）。
#
# 前置：S1 已落（canary ed7919d，canary_gates 无观测样本返回
#   CANARY_K_UNKNOWN(-8)，宿主不滚不推进）。S1 未落则本门禁无法激活，
#   不得先写一个恒绿的空壳（§9.1 Gate 38 激活条件）。
#
# 用例（同一真实用例套件，八种被测实现，一绿七红）：
#   C1 对照不误报：真实实现必须绿
#   V1-V6 K1-K6 判据逐条拆除红：任一门禁恒真放行必须被用例捕获
#   V7 F4 型降级红：K_UNKNOWN 改放行（-8 填成 0，S1 变成新常量）必须被捕获
#
# 饱和检测（§9.1.2）：突变经 cmp -s 守卫——sed 未命中即 selfcheck
#   自身失效转红，保证被测路径确实进入（handler_n > 0 的同构判据）。
#
# 用法: selfcheck/gate-38.sh
# 退出码: 0 = 全部用例符合预期；1 = selfcheck 失败
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AHUB="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
CANARY_SRC="${CANARY_SRC_ROOT:-${AHUB}/agent-workload/products/canary}"

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

# 突变红必须钉死为 exit 1（真实用例断言失败），编译/执行类基建
# 失败（126/127）一律视为 selfcheck 自身异常——红要红得有正确原因。
expect_nonzero() {
    local name="$1" rc="$2"
    if [ "$rc" -eq 1 ]; then
        log_ok "${name}: exit 1（断言红，符合预期）"
    else
        log_err "${name}: exit ${rc}，期望 1（基建失败非断言红）"
        exit 1
    fi
}

# 树外编译并运行用例套件：$1=被测源根 $2=产物名（加 .bin 后缀，
# 避免与突变目录同名冲突）。用例永远取真实套件；突变只发生在
# 实现侧（§9.3 判别力自检本意）。
build_run() {
    gcc -std=gnu11 -Wall -Wextra -O2 \
        -I"$1/include" \
        -o "$TMP/$2.bin" \
        "$CANARY_SRC/tests/unit/test_canary.c" \
        "$1"/src/*.c >/dev/null 2>&1
    "$TMP/$2.bin" >/dev/null 2>&1
}

# 复制被测源并对 canary_gates 施注突变；$3=sed 脚本。
# sed 未命中视为 selfcheck 自身异常（fail-closed，§9.2 规则 3）。
mutate() {
    local dst="$1" name="$2" expr="$3"
    mkdir -p "$dst"
    cp -r "$CANARY_SRC/include" "$CANARY_SRC/src" "$dst/"
    sed -i "$expr" "$dst/src/canary_core.c"
    if cmp -s "$CANARY_SRC/src/canary_core.c" "$dst/src/canary_core.c"; then
        log_err "${name}: mutation no-op（实现漂移，selfcheck 判据失效）"
        exit 1
    fi
}

[ -d "$CANARY_SRC/src" ] || {
    log_err "canary source root not found: ${CANARY_SRC}"
    exit 1
}

# ── C1: 对照不误报 ──────────────────────────────────────────
section "C1: real implementation must stay green"
rc=0
build_run "$CANARY_SRC" c1 || rc=$?
expect_rc "C1 real green" 0 "$rc"

# ── V1-V6: K1-K6 判据逐条拆除红 ─────────────────────────────
# 恒真放行突变：单条判据改 if (0)，对应错误码失守。
# 任一突变下真实用例套件不红 = 该门禁恒真（P1-2 复辟）。
mutate "$TMP/v1" "V1" 's/if (g->ok_pm < CANARY_OK_FLOOR)/if (0)/'
rc=0
build_run "$TMP/v1" v1 || rc=$?
expect_nonzero "V1 K1 ok_pm floor bypass red" "$rc"

mutate "$TMP/v2" "V2" 's/if (g->perf_ppm < CANARY_PERF_FLOOR)/if (0)/'
rc=0
build_run "$TMP/v2" v2 || rc=$?
expect_nonzero "V2 K2 perf floor bypass red" "$rc"

mutate "$TMP/v3" "V3" 's/if (g->crashes != 0u)/if (0)/'
rc=0
build_run "$TMP/v3" v3 || rc=$?
expect_nonzero "V3 K3 crash gate bypass red" "$rc"

mutate "$TMP/v4" "V4" 's/if (g->rb_secs > CANARY_RB_MAX_SECS)/if (0)/'
rc=0
build_run "$TMP/v4" v4 || rc=$?
expect_nonzero "V4 K4 rollback budget bypass red" "$rc"

mutate "$TMP/v5" "V5" 's/if ((g->flags \& CANARY_G_EXPLAIN) == 0u)/if (0)/'
rc=0
build_run "$TMP/v5" v5 || rc=$?
expect_nonzero "V5 K5 explain flag bypass red" "$rc"

mutate "$TMP/v6" "V6" 's/if ((g->flags \& CANARY_G_BOUNDARY) == 0u)/if (0)/'
rc=0
build_run "$TMP/v6" v6 || rc=$?
expect_nonzero "V6 K6 boundary flag bypass red" "$rc"

# ── V7: F4 型降级红 ────────────────────────────────────────
# 历史风险（§11 F4）：S1 变成新常量——无观测样本(-8) 改放行，
# "未知即通过"。降级必须被 K_UNKNOWN 用例打红。
section "V7: K_UNKNOWN downgraded to pass (F4) must be red"
mutate "$TMP/v7" "V7" 's/return CANARY_K_UNKNOWN;/return 0;/'
rc=0
build_run "$TMP/v7" v7 || rc=$?
expect_nonzero "V7 K_UNKNOWN pass-through red" "$rc"

section "Gate 38 selfcheck verdict"
log_ok "8/8 用例符合预期（七红一绿）"
exit 0
