#!/bin/bash
# Gate 40 kill switch 四通道门禁（0.1.20 方案 §5.7 V8 / §9.1 Gate 40）
#
# 权威依据：
#   0.1.20 方案 §5.7 V8：kill switch 四通道（env / 全局文件 / 实例哨兵 /
#     CLI 持久化），任一路命中即停止一切自演化写入。
#   同方案 §9.1 Gate 40：四通道须各自独立可判，且跨进程/跨实例可见；
#     全链回滚窗口 ≤ CANARY_RB_MAX_SECS。
#   同方案 §9.1 Gate 40 定性为 gate:lab——真实 cupolas_d + 真实 socket，
#     零 mock；环境缺失按 exit 2 上报（check_gate 记 WARNING，不静默绿）。
#
# 断言：
#   A1 四通道实现独立：ks_probe 内 env / 全局文件 / 实例哨兵逐条在位，
#      CLI 通道独立持久化（不经 ks_probe，重启后仍生效）
#   A2 契约常量：CANARY_KS_TTL_MS ≤ 1000（轮询上限 1s）、
#      CANARY_RB_MAX_SECS == 300（5min 回滚预算）
#   B1 用例完备：四通道各有断言，且文件/哨兵/CLI 三条均验跨实例可见
#   C1 lab 全链：selfcheck/gate-40.sh 在真实 cupolas_d 上跑通 T1/T2
#
# 用法: g40-killswitch-gate.sh [build-dir]
# 环境变量：G40_ROOT、G40_SKIP_LAB（置 1 等同 lab 环境缺失，仍记 WARNING）
# 退出码: 0 = 通过；1 = 存在违例；2 = 环境错误（lab 前置缺失）
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
ROOT="${G40_ROOT:-$PROJECT_ROOT}"

CANARY="${ROOT}/agent-workload/products/canary"
HDR="${CANARY}/include/canary.h"
INT="${CANARY}/src/canary_internal.h"
CORE="${CANARY}/src/canary_core.c"
CASES="${CANARY}/tests/unit/test_canary.c"
LAB="${SCRIPT_DIR}/selfcheck/gate-40.sh"
BUILD_DIR="${1:-${AIRY_BUILD_DIR:-${QUALITY_GATE_BUILD_DIR:-}}}"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

for f in "$HDR" "$INT" "$CORE" "$CASES"; do
    [ -f "$f" ] || { echo "受审文件缺失: $f"; exit 2; }
done

VIOLATIONS=0
fail() { log_err "$1"; VIOLATIONS=$((VIOLATIONS + 1)); }

# ── A1: 四通道独立实现 ──────────────────────────────────────
section "A1: four channels implemented independently"
PROBE="$(awk '/^static int ks_probe\(/ { f = 1 } f { print } f && /^}/ { exit }' "$CORE")"
[ -n "$PROBE" ] || fail "A1 未定位 ks_probe 函数体，扫描口径异常"
for anchor in 'g_ks_env[0] && getenv(g_ks_env)' 'g_ks_file[0] && ks_probe_file(g_ks_file)' 'ks_probe_file(c->sentry)'; do
    printf '%s\n' "$PROBE" | grep -qF "$anchor" \
        || fail "A1 通道探测缺失: ${anchor}"
done

CLI="$(awk '/^int canary_ks_cli\(/ { f = 1 } f { print } f && /^}/ { exit }' "$CORE")"
printf '%s\n' "$CLI" | grep -qF 'fopen(c->sentry' \
    || fail "A1 CLI 通道未持久化哨兵文件（重启后失效）"
printf '%s\n' "$CLI" | grep -qF 'atomic_store(&c->ks_on, 1)' \
    || fail "A1 CLI 通道未立即熔断（须先置位再落盘）"

# ── A2: 契约常量 ────────────────────────────────────────────
section "A2: contract constants (TTL <= 1000ms, rollback <= 300s)"
TTL="$(grep -oE '^#define CANARY_KS_TTL_MS +[0-9]+' "$INT" | grep -oE '[0-9]+$' || true)"
if [ -z "$TTL" ]; then
    fail "A2 CANARY_KS_TTL_MS 未定义"
elif [ "$TTL" -gt 1000 ]; then
    fail "A2 CANARY_KS_TTL_MS=${TTL} 超出 1000ms 契约（kill 生效延迟不可接受）"
else
    log_ok "A2 TTL=${TTL}ms ≤ 1000ms"
fi
grep -qE '^#define CANARY_RB_MAX_SECS +300u' "$HDR" \
    || fail "A2 CANARY_RB_MAX_SECS 非 300s（回滚预算契约漂移）"

# ── B1: 四通道用例 + 跨实例可见 ─────────────────────────────
section "B1: per-channel cases with cross-instance visibility"
grep -qF 'canary_ks_env("CANARY_UT_KILL")' "$CASES" \
    || fail "B1 缺 env 通道用例"
grep -qF '/* 文件信号跨实例可见 */' "$CASES" \
    || fail "B1 缺全局文件通道跨实例用例"
grep -qF '/* 哨兵跨实例生效 */' "$CASES" \
    || fail "B1 缺实例哨兵通道跨实例用例"
grep -qF '/* 持久化跨实例（重启语义） */' "$CASES" \
    || fail "B1 缺 CLI 通道持久化跨实例用例"
grep -qF '/* TTL 过后解除 */' "$CASES" \
    || fail "B1 缺 TTL 解除用例（命中后永久熔断不可恢复）"

# ── C1: lab 全链（真实 cupolas_d）───────────────────────────
section "C1: lab chain on real cupolas_d (T1 adopt->shadow->kill, T2 env fail-closed)"
if [ "${G40_SKIP_LAB:-0}" = "1" ]; then
    log_err "C1 lab 被跳过（G40_SKIP_LAB=1）：按环境缺失上报，不计通过"
    exit 2
fi
if [ -z "$BUILD_DIR" ] || [ ! -x "${BUILD_DIR}/bin/cupolas_d" ]; then
    log_err "C1 lab 前置缺失：${BUILD_DIR:-<unset>}/bin/cupolas_d（先跑 Gate 1 建树）"
    exit 2
fi
if [ ! -x "$LAB" ]; then
    log_err "C1 lab 脚本缺失或不可执行: ${LAB}"
    exit 2
fi
# A2 已从 canary.h 读出回滚预算，C1 用它作 lab 的全链截止（单一契约源）；
# lab 输出落临时文件，失败时回显尾部——`>/dev/null` 全吞会使 CI 只剩一句
# 「语义不成立」，无法区分「链路超预算」与「语义真错」（run 40884260525 实证）。
RB_SECS="$(grep -oE '^#define CANARY_RB_MAX_SECS +[0-9]+' "$HDR" 2>/dev/null | grep -oE '[0-9]+$' || true)"
RB_SECS="${RB_SECS:-300}"
LAB_LOG="$(mktemp)"
rc=0
G40_RB_SECS="$RB_SECS" bash "$LAB" "$BUILD_DIR" >"$LAB_LOG" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    log_ok "C1 lab T1/T2 全部符合预期（budget ${RB_SECS}s）"
else
    fail "C1 lab 未通过（exit ${rc}）：四通道跨进程语义不成立"
    log_err "lab 输出尾部（诊断用，完整日志见上）:"
    tail -40 "$LAB_LOG" | sed 's/^/    /'
fi
rm -f "$LAB_LOG"

# ── 裁决 ────────────────────────────────────────────────────
section "Verdict"
if [ "$VIOLATIONS" -gt 0 ]; then
    log_err "Gate 40 kill switch 违例 ${VIOLATIONS} 处"
    exit 1
fi
log_ok "Gate 40 四通道独立可判且跨实例可见"
exit 0
