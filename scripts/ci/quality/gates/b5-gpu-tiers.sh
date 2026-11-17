#!/bin/bash
# Gate B-5 验收分档 L0/L1/L2（0.1.21 §17.2 B-5）
#
# 铁律：无 GPU 的环境必须显式 SKIP 且带原因；SKIP 不计为 PASS，
#   汇总中 SKIP 与 PASS 分列。分档只按证据判，不按声明判。
#
# 用法: b5-gpu-tiers.sh [--tier L0|L1|L2] [--cli PATH] [--backend URL]
#                        [--l1-pid PID] [--l2-evidence FILE]
# 退出码: 0 = 请求档位 PASS；1 = FAIL；2 = 环境错误；3 = SKIP（未达，带原因）
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
TIER=L0
CLI="${AIRY_CLI:-}"
BACKEND="${B5_BACKEND:-}"
L1_PID=""
L2_EVID="${B5_L2_EVIDENCE:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --tier) TIER="${2:-}"; shift 2 ;;
        --cli) CLI="${2:-}"; shift 2 ;;
        --backend) BACKEND="${2:-}"; shift 2 ;;
        --l1-pid) L1_PID="${2:-}"; shift 2 ;;
        --l2-evidence) L2_EVID="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "b5: 未知参数 $1" >&2; exit 2 ;;
    esac
done

case "$TIER" in L0|L1|L2) ;; *) echo "b5: --tier 只接受 L0/L1/L2" >&2; exit 2 ;; esac

PASS=0; SKIP=0; FAIL=0
N_SKIP=""; N_PASS=""
pass() { PASS=$((PASS+1)); N_PASS="$N_PASS $1"; echo "  [PASS] $1"; }
skip() { SKIP=$((SKIP+1)); N_SKIP="$N_SKIP $1"; echo "  [SKIP] $1：$2"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1：$2"; }

[ -n "$CLI" ] || CLI="$(command -v airy_cli 2>/dev/null || true)"
[ -n "$CLI" ] || CLI="$ROOT/agent-workload/agentrt/latest/bin/airy_cli"
if [ ! -x "$CLI" ]; then
    echo "b5: 找不到可执行的 airy_cli（--cli / AIRY_CLI）" >&2
    exit 2
fi

GJ="$("$CLI" gpu --json 2>/dev/null || true)"
get() { printf '%s' "$GJ" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
num() { printf '%s' "$GJ" | sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p"; }
VERDICT="$(get verdict)"; DEVICES="$(num devices)"; REASON="$(get reason)"
DEVICES="${DEVICES:-0}"

# ── L0：抽象 + 探测 + 降级可用（B-1/B-3 判据）────────────────────────────
L0=PASS
case "$VERDICT" in r1|r2|r3) ;; *) L0=FAIL ;; esac
[ "$DEVICES" -ge 0 ] 2>/dev/null || L0=FAIL
if [ "$L0" = PASS ]; then
    pass "L0 抽象/探测/降级（verdict=$VERDICT devices=$DEVICES）"
else
    fail "L0 抽象/探测/降级" "gpu 快照不合法（verdict=$VERDICT）"
fi

# ── L1：GPU 后端可完成单次对话（B-2 判据）────────────────────────────────
L1=SKIP
L1_WHY=""
if [ "$DEVICES" -eq 0 ]; then
    L1_WHY="无加速器（devices=0），L1 未达"
elif [ "$VERDICT" = r3 ]; then
    L1_WHY="加速器在但后端不可用（${REASON:-无原因}）"
elif [ -z "$BACKEND" ]; then
    L1_WHY="未提供 --backend，无后端声明可核"
elif [ -z "$L1_PID" ]; then
    L1_WHY="未提供 --l1-pid，缺 per-PID 稳态显存占用证据"
else
    U="$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null |
         awk -F, -v p="$L1_PID" '{gsub(/ /,"",$1); gsub(/ MiB/,"",$2)} $1==p && $2+0>0 {print "hit"}')"
    if [ "$U" = hit ]; then
        pass "L1 后端 ${BACKEND} + 进程 ${L1_PID} 稳态显存占用 > 0"
        L1=PASS
    else
        L1_WHY="进程 ${L1_PID} 无显存占用（nvidia-smi 无记录）"
    fi
fi
[ "$L1" = PASS ] || skip "L1 GPU 单次对话" "$L1_WHY"

# ── L2：多 provider + 熔断 + 长跑稳定（B-2 + B-4 + C-7）──────────────────
L2=SKIP
if [ -n "$L2_EVID" ] && [ -r "$L2_EVID" ] &&
   grep -q 'B-4' "$L2_EVID" && grep -q 'C-7' "$L2_EVID"; then
    pass "L2 证据齐备（$L2_EVID 含 B-4/C-7 回执）"
    L2=PASS
else
    skip "L2 生产可用" "缺 B-4 熔断与 C-7 长压测回执（--l2-evidence）"
fi

echo
echo "b5: tier=$TIER  PASS=$PASS  SKIP=$SKIP  FAIL=$FAIL"
[ -n "$N_PASS" ] && echo "  PASS:${N_PASS}"
[ -n "$N_SKIP" ] && echo "  SKIP:${N_SKIP}"

[ "$FAIL" -gt 0 ] && exit 1
case "$TIER" in
    L0) [ "$L0" = PASS ] && exit 0 || exit 3 ;;
    L1) [ "$L1" = PASS ] && exit 0 || exit 3 ;;
    L2) [ "$L2" = PASS ] && exit 0 || exit 3 ;;
esac
