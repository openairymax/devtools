#!/bin/bash
# Gate 31 验证器隔离门禁（0.1.20 方案 §9.1 Gate 31 / §3.7l 第三表第 5 项）
#
# 权威依据：
#   0.1.20-架构改进完善和自演化方案.md §9.1 Gate 31：验证器隔离 | C /
#     确定性链 | 目标的 nm -u 中不出现任何 S2/LLM 符号；植入一处调用必红 |
#     fail-closed | 0.08 | B8。
#
# 被测物口径：§9.1 原文的 "t1-p 目标" 是 0.1.16 期的命名，现行构建无该
#   目标。等价且更严格的做法是把确定性链收窄到单一翻译单元
#   grad_verifier.c：它必须能独立成对象（零 LLM 依赖即可链接），其未定
#   义符号表即该链的真实外部契约。构建一律出树（mktemp -d），严禁在源码
#   区落任何产物（工程铁律）。
#
# 断言（五臂）：
#   A1 源码面隔离：grad_verifier.c 的 include 行不含 LLM/S2 词根
#   A2 契约面隔离：grad_verifier.h 及其一阶 include 闭包同样干净
#      （契约若引 LLM 头，隔离只在实现层成立，等于假隔离）。边界类型
#      头 *_types.h 豁免：它是机制与策略共用的词汇表（llm_service_types.h
#      是 atoms <-> llm_d 的唯一 SSoT），不构成对生成面实现的依赖；
#      实现面依赖由 B1 的对象符号表作为最终裁决。
#   B1 对象面隔离：单 TU 出树编译后 nm -u 无任何 S2/LLM 符号
#   B2 正向在位：六个公开入口必须定义（防空壳通过——零符号也满足 B1）
#   B3 唯一实现面：六个入口的定义行只允许出现在 grad_verifier.c
#      （双实现意味着隔离面被绕过，判据不再成立）
#
# 用法: g31-verifier-isolation.sh
# 环境变量（selfcheck 注入用）：G31_ROOT / G31_CC / G31_NM
# 退出码: 0 = 通过；1 = 存在违例（含编译失败）；2 = 环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
ROOT="${G31_ROOT:-$PROJECT_ROOT}"
CC="${G31_CC:-cc}"
NM="${G31_NM:-nm}"

SRC="${ROOT}/agent-workload/products/cognition/src/grad/grad_verifier.c"
HDR="${ROOT}/agent-workload/products/cognition/src/grad/grad_verifier.h"

# 编译面：与 agentrt/CMakeLists.txt 全局 include 面同源（0.1.20 实测通过）
INC_DIRS=(
    agent-workload/products/cognition/src/grad
    agent-workload/products/cognition/src
    agent-workload/products/cognition/src/gccp
    agent-workload/products/cognition/include
    agent-workload/agentrt/atoms/corekern/include
    agent-workload/agentrt/atoms/coreloopthree/include
    agent-workload/agentrt/commons
    agent-workload/agentrt/commons/utils/include
    agent-workload/agentrt/commons/utils/compat
    agent-workload/agentrt/commons/utils/memory
    agent-workload/agentrt/commons/utils/string
    agent-workload/agentrt/commons/utils/logging
    agent-workload/agentrt/commons/utils/error
    agent-workload/agentrt/commons/platform/include
    agent-workload/agentrt/commons/utils/ipc
    agent-workload/agentrt/commons/utils/sd
    agent-workload/agentrt/commons/utils/types
    agent-workload/agentrt/commons/utils/sync
    agent-workload/agentrt/commons/include
    agent-workload/agentrt/protocols/include
)

# 禁用词根：LLM 生成面与 S2 规划面（含其仲裁器）
BAD_WORD='llm|s2_plan|s1_arb'
BAD_SYM='grad_llm_|airy_llm_|llm_svc_|gccp_llm_|s2_plan|s1_arb'
# 边界类型头豁免：跨进程契约的词汇表，不是生成面实现
TYPE_HDR='_types\.h$'

# B2/B3 的被审入口（确定性链唯一对外承诺）
ENTRIES="airy_grad_verify_plan airy_grad_verify_plan_g airy_grad_verify_scope
airy_grad_verify_scope_g airy_grad_report_to_json airy_grad_error_str"
ENTRIES="$(printf '%s\n' $ENTRIES | paste -sd' ' -)"

# B3 扫描面：机制件与策略件的实现目录（声明在头文件，不计入）
SCAN_DIRS=(
    "${ROOT}/agent-workload/products/cognition/src"
    "${ROOT}/agent-workload/agentrt/atoms/coreloopthree/src"
)

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

# ── 环境前置（缺件即环境错误，不得静默跳过）──────────────────
for f in "$SRC" "$HDR"; do
    [ -f "$f" ] || { echo "受审文件缺失: $f"; exit 2; }
done
for t in "$CC" "$NM"; do
    command -v "$t" >/dev/null 2>&1 || { echo "工具链缺失: $t"; exit 2; }
done
for d in "${INC_DIRS[@]}"; do
    [ -d "${ROOT}/${d}" ] || { echo "include 根缺失: ${ROOT}/${d}"; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VIOLATIONS=0
fail() { log_err "$1"; VIOLATIONS=$((VIOLATIONS + 1)); }

# include 行抽取（只管引号包含；系统头与 C 标准库不在隔离判据内）
included_quoted() {
    grep -hoE '^[[:space:]]*#[[:space:]]*include[[:space:]]*"[^"]+"' "$1" 2>/dev/null \
        | grep -oE '"[^"]+"' | tr -d '"' | sort -u || true
}

# 在一阶 include 闭包中定位头文件（相对 include 根）
resolve_header() {
    local name="$1" d
    for d in "${INC_DIRS[@]}"; do
        [ -f "${ROOT}/${d}/${name}" ] && { printf '%s\n' "${ROOT}/${d}/${name}"; return 0; }
    done
    return 1
}

# ── A1: 源码面隔离 ──────────────────────────────────────────
section "A1: implementation source isolation"
A1_ALL="$(included_quoted "$SRC")"
A1_BAD="$(printf '%s\n' "${A1_ALL:-}" | grep -iE "${BAD_WORD}" || true)"
if [ -n "$A1_BAD" ]; then
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        fail "A1 实现面引入 LLM/S2 头: ${h}"
    done <<< "$A1_BAD"
else
    log_ok "A1 实现面 $(printf '%s\n' "${A1_ALL:-}" | grep -c . || true) 个头，零 LLM/S2 词根"
fi

# ── A2: 契约面隔离（一阶闭包）────────────────────────────────
section "A2: contract header isolation (first-order closure)"
A2_N=0
A2_HEADERS="${HDR}"
while IFS= read -r h; do
    [ -z "$h" ] && continue
    p="$(resolve_header "$h" || true)"
    if [ -z "$p" ]; then
        fail "A2 契约闭包不可解析: ${h}（无法判断即红）"
        continue
    fi
    A2_HEADERS="${A2_HEADERS}"$'\n'"${p}"
done <<< "$(included_quoted "$HDR")"

while IFS= read -r p; do
    [ -z "$p" ] && continue
    A2_N=$((A2_N + 1))
    bad="$(included_quoted "$p" | grep -iE "${BAD_WORD}" | grep -vE "${TYPE_HDR}" || true)"
    if [ -n "$bad" ]; then
        while IFS= read -r h; do
            [ -z "$h" ] && continue
            fail "A2 契约面引入 LLM/S2 头: $(basename "$p") -> ${h}"
        done <<< "$bad"
    fi
done <<< "$A2_HEADERS"
[ "$A2_N" -gt 1 ] || fail "A2 契约闭包仅 ${A2_N} 件，解析口径异常"
log_ok "A2 契约闭包 ${A2_N} 件受审"

# ── 出树单 TU 编译（确定性链的对象面取证）────────────────────
section "B0: out-of-tree object build (deterministic chain TU)"
OBJ="${TMP}/grad_verifier.o"
LOG="${TMP}/cc.log"
INCS=()
for d in "${INC_DIRS[@]}"; do INCS+=("-I${ROOT}/${d}"); done
CC_RC=0
"$CC" -std=c11 -D_GNU_SOURCE -O2 -Wall -Wextra "${INCS[@]}" \
    -c "$SRC" -o "$OBJ" >"$LOG" 2>&1 || CC_RC=$?
if [ "$CC_RC" -ne 0 ]; then
    tail -20 "$LOG"
    fail "B0 单 TU 出树编译失败（rc=${CC_RC}），隔离面不可判"
else
    log_ok "B0 单 TU 编译产出 $(basename "$OBJ")"
fi

# ── B1: 对象面隔离 ──────────────────────────────────────────
section "B1: object-level symbol isolation"
if [ "$CC_RC" -ne 0 ]; then
    fail "B1 无对象可验（编译失败）"
else
    UNDEF="$("$NM" -u "$OBJ" | awk '{print $NF}' | sort -u)"
    if [ -z "$UNDEF" ]; then
        fail "B1 未定义符号表为空，取证口径异常"
    fi
    B1_BAD="$(printf '%s\n' "$UNDEF" | grep -E "${BAD_SYM}" || true)"
    if [ -n "$B1_BAD" ]; then
        while IFS= read -r s; do
            [ -z "$s" ] && continue
            fail "B1 确定性链引入 S2/LLM 符号: ${s}"
        done <<< "$B1_BAD"
    else
        log_ok "B1 nm -u $(printf '%s\n' "$UNDEF" | grep -c .) 个外部符号，零 S2/LLM"
    fi
fi

# ── B2: 正向在位（防空壳）───────────────────────────────────
section "B2: public entries defined (no empty shell)"
if [ "$CC_RC" -ne 0 ]; then
    fail "B2 无对象可验（编译失败）"
else
    DEFINED="$("$NM" --defined-only "$OBJ" | awk 'NF>=3 && $2 ~ /^[TtDdBbRr]$/ {print $3}')"
    for e in $ENTRIES; do
        printf '%s\n' "$DEFINED" | grep -qx "$e" \
            || fail "B2 公开入口未定义（空壳实现）: ${e}"
    done
    log_ok "B2 六入口定义在位（定义面 $(printf '%s\n' "$DEFINED" | grep -c .) 个符号）"
fi

# ── B3: 唯一实现面 ──────────────────────────────────────────
section "B3: single implementation site"
for e in $ENTRIES; do
    def_re="^[A-Za-z_][A-Za-z0-9_ *]*[ *]${e}[[:space:]]*\("
    SITES="$(grep -rlE "$def_re" "${SCAN_DIRS[@]}" --include='*.c' 2>/dev/null || true)"
    n="$(printf '%s\n' "${SITES:-}" | grep -c . || true)"
    if [ "$n" -eq 0 ]; then
        fail "B3 入口无定义行（扫描口径异常）: ${e}"
    elif [ "$n" -gt 1 ]; then
        fail "B3 入口存在多实现（隔离面被绕过）: ${e} -> $(printf '%s' "$SITES" | paste -sd, -)"
    fi
done
log_ok "B3 六入口定义唯一（$(printf '%s\n' "${SCAN_DIRS[@]}" | wc -l | tr -d ' ') 个实现目录受审）"

# ── 裁决 ────────────────────────────────────────────────────
section "Verdict"
if [ "$VIOLATIONS" -gt 0 ]; then
    log_err "Gate 31 验证器隔离违例 ${VIOLATIONS} 处"
    exit 1
fi
log_ok "Gate 31 验证器隔离通过（确定性链零 LLM 依赖）"
exit 0
