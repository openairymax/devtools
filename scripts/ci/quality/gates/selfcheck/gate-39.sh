#!/bin/bash
# Gate 39 爆炸半径 selfcheck 反向用例（0.1.20 方案 §9.1 Gate 39 / §9.3）
#
# 规则：每个门禁必须配一个反向用例脚本，注入已知违规样本，
#   断言该门禁退出码为 1（能红）——门禁不能红等于不存在。
#
# Gate 39 判据：第 4 文件、201 行、新增 151 行、修改后 201 行
#   四者全被拒；且 canary_admit(0, 200) == 0（纯修改补丁合法，
#   与 §10.2 B6 型缺陷相反的断言）。
#
# 用例（同一真实用例套件，三种被测实现）：
#   C1 对照不误报：真实实现必须绿
#   V1 B6 语义复辟红：admit(0, mod>0) 改回 -1 必须被用例捕获
#   V2 超限判据拆除红：上限比较改恒假（放行超限）必须被捕获
#
# 用法: selfcheck/gate-39.sh
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

expect_nonzero() {
    local name="$1" rc="$2"
    if [ "$rc" -ne 0 ]; then
        log_ok "${name}: exit ${rc}（非零即红，符合预期）"
    else
        log_err "${name}: exit 0，期望非零（用例丧失判别力）"
        exit 1
    fi
}

# 树外编译并运行用例套件：$1=被测源根 $2=产物名。
# 用例永远取真实套件；突变只发生在实现侧（§9.3 判别力自检本意）。
build_run() {
    gcc -std=gnu11 -Wall -Wextra -O2 \
        -I"$1/include" \
        -o "$TMP/$2" \
        "$CANARY_SRC/tests/unit/test_canary.c" \
        "$1"/src/*.c >/dev/null 2>&1
    "$TMP/$2" >/dev/null 2>&1
}

# 复制被测源并对 canary_admit 施注突变；$3=sed 脚本。
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

# ── V1: B6 语义复辟红 ───────────────────────────────────────
# 历史缺陷：把纯修改补丁（new_fn=0, mod_fn>0）判为 -1 拒绝，
# 反向用例写反、缺陷固化成契约。复辟此语义必须被真实用例打红。
section "V1: B6 regression (pure modification rejected) must be red"
mutate "$TMP/v1" "V1" 's/if (new_fn == 0 \&\& mod_fn == 0)/if (new_fn == 0 \&\& mod_fn > 0)/'
rc=0
build_run "$TMP/v1" v1 || rc=$?
expect_nonzero "V1 B6 regression red" "$rc"

# ── V2: 超限判据拆除红 ──────────────────────────────────────
# 恒真放行突变：上限比较改为 if (0)，151/201 边界全部失守。
# 门禁不能对"上限悄悄消失"无感（§9.1 Gate 41 同族风险）。
section "V2: removed ceiling check (always-true bypass) must be red"
mutate "$TMP/v2" "V2" 's/if (new_fn > CANARY_FN_NEW_MAX || mod_fn > CANARY_FN_MOD_MAX)/if (0)/'
rc=0
build_run "$TMP/v2" v2 || rc=$?
expect_nonzero "V2 ceiling bypass red" "$rc"

section "Gate 39 selfcheck verdict"
log_ok "3/3 用例符合预期（两红一绿）"
exit 0
