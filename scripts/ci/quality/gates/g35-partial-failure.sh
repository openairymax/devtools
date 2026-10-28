#!/bin/bash
# Gate 35 部分失败语义门禁（0.1.20 方案 §9.1 Gate 35 / C8）
#
# 权威依据：
#   0.1.20-架构改进完善和自演化方案.md §9.1 Gate 35：至少 5 种部分失败
#     组合，返回码与日志必须指明"哪一步"失败；fail-closed。
#
# 为何要独立一位 stage：终态（C7）只回答"计划是否放行"，不回答"哪一步
# 没走通"。同一返回码可来自不同阶段——LLM 出口缺席与生成降级同为
# AIRY_ESERVICE，无进展即停与迭代耗尽同为 AIRY_ETIMEDOUT。调用方据此
# 无法决定"重试"还是"改参"，运维也指认不了坏点。故 stage 与 status
# 正交，作为失败归因的唯一申报位。
#
# 断言（封闭世界，新增阶段未分类即红）：
#   A1 阶段域完备：grad_stage_e 恰 8 值 0..7 且 stats 有 stage 申报位
#   A2 生产者可达：7 个非 NONE 阶段在 grad_run/grad_coordinator 均有赋值；
#      未收敛且无更早归因时出口兜底申报 loop（否则"哪一步"留空）
#   B1 用例完备：≥5 种失败组合、≥4 个不同阶段各有构造用例
#   B2 三元组齐备：每个断言 status 的用例必须同时断言返回码与 stage
#      （只断言 status 则"哪一步失败"无人取证）
#   B3 用例在位：每个组合用例经 RUN_TEST 注册且文件在构建目标内
#   D1 归因可观测：机制面事件携带 stats.stage，决策链 trace 落盘 stage
#   D2 运行臂：已构建树中 cognition_grad_tests 必须真实通过
#
# 静态臂守"判据没有被写弱"，运行臂守"判据此刻成立"；两者缺一不可。
#
# 构建树位于源码区外（工程铁律 4.1.1）：由 AIRYRT_BUILD_ROOT 或
# QUALITY_GATE_BUILD_DIR 指定；两者皆空视为环境错误。
# 用法: [AIRYRT_BUILD_ROOT=<build>] g35-partial-failure.sh
# 环境变量（selfcheck 注入用）：G35_ROOT
# 退出码: 0 = 通过；1 = 违例；2 = 环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# G35_ROOT 供 selfcheck 在快照树上施注单一突变；生产路径恒为脚本自身锚点。
PROJECT_ROOT="${G35_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
AW="${PROJECT_ROOT}/agent-workload"
HDR="${AW}/agentrt/atoms/coreloopthree/include/grad.h"
RUN="${AW}/products/cognition/src/grad/grad_run.c"
COORD="${AW}/products/cognition/src/grad/grad_coordinator.c"
CASES="${AW}/products/cognition/tests/unit/test_grad_run.c"
RUNNER="${AW}/products/cognition/tests/unit/test_grad.c"
BUILD="${AW}/products/cognition/CMakeLists.txt"
EVENT="${AW}/agentrt/atoms/coreloopthree/src/cognition/think/engine_process_grad.c"
BUILD_ROOT="${AIRYRT_BUILD_ROOT:-${QUALITY_GATE_BUILD_DIR:-}}"

CASE_NAME="cognition_grad_tests"

# 7 个非 NONE 阶段（NONE 表示全链通过，不属失败归因，不参与可达性）。
STAGES="GRAD_STAGE_INPUT GRAD_STAGE_LLM GRAD_STAGE_CHANNEL GRAD_STAGE_GEN
GRAD_STAGE_VERIFY GRAD_STAGE_ARBITER GRAD_STAGE_LOOP"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

violations=0
fail() {
    log_err "$*"
    violations=$((violations + 1))
}

section "0.1.20 G35 partial-failure semantics gate"
for f in "$HDR" "$RUN" "$COORD" "$CASES" "$RUNNER" "$BUILD" "$EVENT"; do
    [ -f "$f" ] || { log_err "受审文件缺失: ${f}"; exit 2; }
done
[ -n "$BUILD_ROOT" ] || {
    log_err "build tree not specified: set AIRYRT_BUILD_ROOT or QUALITY_GATE_BUILD_DIR"
    exit 2
}
[ -d "$BUILD_ROOT" ] || { log_err "build tree not found: ${BUILD_ROOT}"; exit 2; }

# ── 函数级扫描：把每个 test_ 函数体内的断言按函数归属 ─────────
# 用法: pair_scan <ERE>；输出 "函数名 命中片段"，供函数级三元组判定。
pair_scan() {
    awk -v pat="$1" '
        /^(static )?void test_[a-z0-9_]+\(/ {
            fn = $0; sub(/^.*void /, "", fn); sub(/\(.*/, "", fn); next
        }
        fn != "" {
            rest = $0
            while (match(rest, pat)) {
                m = substr(rest, RSTART, RLENGTH)
                sub(/^.* [=!]= /, "", m)
                print fn, m
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
        /^}/ { fn = "" }
    ' "$CASES"
}

# ── A1: 阶段域完备（枚举 == 分类表，封闭世界）───────────────
section "A1: stage domain (enum == classification)"
ENUM_BLOCK="$(awk '/^typedef enum \{/ { inblk = 1 }
    inblk { print }
    inblk && /^\} grad_stage_e;/ { exit }' "$HDR")"
ENUM_SET="$(printf '%s\n' "$ENUM_BLOCK" \
    | grep -oE 'GRAD_STAGE_[A-Z_]+ *= *[0-9]+' | tr -d ' ' | paste -sd' ' - || true)"
EXPECT="GRAD_STAGE_NONE=0 GRAD_STAGE_INPUT=1 GRAD_STAGE_LLM=2 \
GRAD_STAGE_CHANNEL=3 GRAD_STAGE_GEN=4 GRAD_STAGE_VERIFY=5 \
GRAD_STAGE_ARBITER=6 GRAD_STAGE_LOOP=7"
EXPECT="$(printf '%s\n' $EXPECT | paste -sd' ' -)"
if [ "$ENUM_SET" = "$EXPECT" ]; then
    log_ok "A1 阶段域 8 值 0..7，与分类表全等"
else
    fail "A1 阶段域与分类表不等价：实际 [${ENUM_SET}]"
fi
grep -qE 'uint8_t[[:space:]]+stage;' "$HDR" \
    || fail "A1 stats 未提供 stage 申报位（归因无落地字段）"

# ── A2: 生产者可达（7 个非 NONE 阶段均有赋值 + 出口兜底）────
section "A2: producer reachability"
PROD_SET="$(grep -hoE 'stats\.stage *= *GRAD_STAGE_[A-Z_]+' "$RUN" "$COORD" \
    | grep -oE 'GRAD_STAGE_[A-Z_]+' | sort -u || true)"
if [ -z "$PROD_SET" ]; then
    fail "A2 生产者无阶段赋值，扫描口径异常"
fi
for s in $STAGES; do
    printf '%s\n' "$PROD_SET" | grep -qx "$s" \
        || fail "A2 失败阶段零赋值（不可达）: ${s}"
done
log_ok "A2 生产者可达阶段 $(printf '%s\n' "$PROD_SET" | wc -l | tr -d ' ') 值"
# 出口兜底：未收敛且此前无更早归因 → loop。缺此则"哪一步"留空。
grep -qF 'if (!coord->stats.converged && coord->stats.stage == GRAD_STAGE_NONE)' "$COORD" \
    || fail "A2 出口缺未收敛兜底（未收敛却无阶段归因）"
grep -A1 -F 'if (!coord->stats.converged && coord->stats.stage == GRAD_STAGE_NONE)' "$COORD" \
    | grep -qF 'coord->stats.stage = GRAD_STAGE_LOOP;' \
    || fail "A2 兜底未申报 loop（未收敛归因缺失）"

# ── 用例取证：status / stage / 返回码三路函数级配对 ─────────
STATUS_PAIRS="$(pair_scan 'stats[.]status == GRAD_STATUS_[A-Z_]+' | sort -u)"
STAGE_PAIRS="$(pair_scan 'stats[.]stage == GRAD_STAGE_[A-Z_]+' | sort -u)"
ERR_FNS="$(pair_scan 'err [=!]= AIRY_[A-Z_]+' | awk 'NF { print $1 }' | sort -u)"
if [ -z "$STATUS_PAIRS" ] || [ -z "$STAGE_PAIRS" ]; then
    fail "B1 归因断言零命中，用例文件口径异常"
fi
ST_FNS="$(printf '%s\n' "$STATUS_PAIRS" | awk 'NF { print $1 }' | sort -u)"
SG_FNS="$(printf '%s\n' "$STAGE_PAIRS" | awk 'NF { print $1 }' | sort -u)"
COMBO_FNS="$(comm -12 <(printf '%s\n' "$ST_FNS") <(printf '%s\n' "$SG_FNS"))"
COMBO_N="$(printf '%s\n' "$COMBO_FNS" | grep -c . || true)"
DISTINCT="$(printf '%s\n' "$STAGE_PAIRS" | awk 'NF { print $2 }' | sort -u)"
DISTINCT_N="$(printf '%s\n' "$DISTINCT" | grep -c . || true)"

# ── B1: 组合与阶段覆盖（≥5 组合、≥4 个不同阶段）─────────────
section "B1: failure combinations and stage coverage"
[ "$COMBO_N" -ge 5 ] \
    || fail "B1 失败组合 ${COMBO_N} 种（§9.1 要求 ≥5）"
[ "$DISTINCT_N" -ge 4 ] \
    || fail "B1 覆盖阶段 ${DISTINCT_N} 个（要求 ≥4，缩水即漏检某一步）"
log_ok "B1 组合 ${COMBO_N} 种 / 阶段 ${DISTINCT_N} 个"

# ── B2: 三元组齐备（status 用例必须同时断言返回码与 stage）──
section "B2: return code + status + stage per case"
while IFS= read -r fn; do
    [ -z "$fn" ] && continue
    printf '%s\n' "$ERR_FNS" | grep -qx "$fn" \
        || fail "B2 用例 ${fn} 未断言返回码（无法分辨失败强度）"
    printf '%s\n' "$SG_FNS" | grep -qx "$fn" \
        || fail "B2 用例 ${fn} 未断言 stage（未指明哪一步失败）"
done <<< "$ST_FNS"

# ── B3: 用例在位（注册 + 构建目标）──────────────────────────
section "B3: cases registered and built"
grep -q 'tests/unit/test_grad_run.c' "$BUILD" \
    || fail "B3 用例文件未列入构建目标（永不编译）"
while IFS= read -r fn; do
    [ -z "$fn" ] && continue
    grep -qE "RUN_TEST\(${fn}\)" "$RUNNER" \
        || fail "B3 组合用例未注册（永不运行）: ${fn}"
done <<< "$COMBO_FNS"
grep -qE "add_test\(NAME ${CASE_NAME} COMMAND test_grad_strategy\)" "$BUILD" \
    || fail "B3 构建目标未登记 ctest 用例 ${CASE_NAME}"

# ── D1: 归因可观测（事件 + trace 双路）─────────────────────
section "D1: stage observable in event and trace"
grep -q 'grad_out.stats.stage' "$EVENT" \
    || fail "D1 机制面事件未携带 stats.stage，失败阶段不可观测"
grep -qF 'stage\":%u' "$RUN" \
    || fail "D1 决策链 trace 未落盘 stage（事后无法归因）"
grep -qF '(unsigned)out_outcome->stats.stage' "$RUN" \
    || fail "D1 trace 未绑定 stats.stage（键在而值不实）"

# ── D2: 运行臂（已构建树中用例必须真实通过）────────────────
section "D2: runtime arm"
if ctest --test-dir "$BUILD_ROOT" -N -R "^${CASE_NAME}$" 2>/dev/null | grep -q "Test #"; then
    run_log="$(mktemp "${TMPDIR:-/tmp}/g35-run.XXXXXX")"
    rc=0
    ctest --test-dir "$BUILD_ROOT" -R "^${CASE_NAME}$" --output-on-failure \
        >"$run_log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        log_ok "D2 ${CASE_NAME} 通过（组合与归因由被测程序自证）"
    else
        fail "D2 ${CASE_NAME} 失败（rc=${rc}）"
        tail -12 "$run_log" | sed 's/^/        /'
    fi
    rm -f "$run_log"
else
    fail "D2 构建树未登记 ${CASE_NAME}（无运行臂则归因结论不可验证）"
fi

# ── 裁决 ───────────────────────────────────────────────────
section "Verdict"
if [ "$violations" -gt 0 ]; then
    log_err "0.1.20 G35 partial-failure semantics gate FAILED (${violations} violation(s))"
    exit 1
fi
log_ok "0.1.20 G35 partial-failure semantics gate PASSED"
exit 0
