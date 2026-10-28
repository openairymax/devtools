#!/bin/bash
# Gate 18 体积门禁（三本账数值棘轮）—— 方案 §0.5 G2 / §7.5 三本账 / §9 Gate 41-42
#
# 三账分立（台账 §258 裁定，§1.2 丙口径终裁；三层互不抵扣，不得以口径变更冒充减重）：
#   · 账一 机制核 = atoms + commons + heapstore + gateway + cmake/；
#   · 账三 形态面 = daemons + protocols + tools；
#   · 账三 应用壳 = products/cupolas。
#   账二（products）由产品侧独立预算，不入本门禁。
#
# 计数口径（唯一权威实现，Gate 42 必须复用 --report 而非复制本函数）：
#   SLOC「有效行」= 各账 *.c + *.h，排除 /tests/ 与 /third_party/（vendored 与
#   测试非自研码），再扣除空行与整行注释（^[[:space:]]*$ 与 ^[[:space:]]*(//|/*|*)）。
#
# 判据（2026-10-28 裁定，取代旧 K0-K4 梯级名判据）：
#   三账各自与 baseline 的数值 pin 比较，实测 > pin 即红。pin 只降不升，
#   上升须同 commit 携 RATCHET-JUSTIFY（Gate 41 审计，core 亦在其列）。
#   旧判据把账一绑在梯级名 current=K4 上，梯级自带 500-2000 行松量，且因
#   Gate 41 只解析 KEY=NUM，账一的棘轮完全逃逸审计——账本因此长期与代码脱节。
#   数值 pin 使「文件里的数就是代码的体量」，松量与逃逸同时消失。
#   target 为里程碑目标（<80,000 有效行），只降不升，差额以 WARN 公示，不阻断——
#   阻断由数值 pin 承担，target 承担方向约束（见方案 §7.5 收敛表）。
#
# 基线：v16-loc-budget-baseline.txt，每行 <键>=<值>：core/facade/cupolas/target。
#
# 用法: loc-budget-check.sh [--report|--converge]
#   --report    输出机器可读实测值：三账合计（core=/facade=/cupolas=）与逐模块
#               明细（core.<模块>= / facade.<模块>=），供 Gate 42 复用
#   --converge  把各账 pin 收敛为实测值（只降不升），里程碑 target 不动
# 退出码: 0 = 通过；1 = 某账超 pin；2 = 环境错误（树/基线缺失）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
CUPOLAS_DIR="${PROJECT_ROOT}/agent-workload/products/cupolas"
BASELINE="$SCRIPT_DIR/v16-loc-budget-baseline.txt"

CORE_MODULES=(atoms commons heapstore gateway)     # 账一：原子件 + 能力格 + 堆存 + 网关
FACADE_MODULES=(daemons protocols tools)           # 账三：形态面

MODE=check
case "${1:-}" in
    --report)   MODE=report ;;
    --converge) MODE=converge ;;
    "")         ;;
    *)          echo "loc-budget-check.sh: unknown option: $1" >&2; exit 2 ;;
esac

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

# 单账计数（SLOC 有效行）：dir 下 *.c + *.h，排除 /tests/ 与 /third_party/，
#   再扣除空行与整行注释（与《机制核减重可行性细分方案》§1.1「有效代码」列同口径）
count_loc() {
    find "$1" -type f \( -name '*.c' -o -name '*.h' \) \
        | { grep -v -e '/tests/' -e '/third_party/' || true; } \
        | tr '\n' '\0' | xargs -0 -r cat \
        | { grep -vE '^[[:space:]]*$' || true; } \
        | { grep -vE '^[[:space:]]*(//|/\*|\*)' || true; } \
        | wc -l
}

pin_of() {
    sed -n "s/^$1=//p" "$BASELINE" | head -n1
}

[ -d "$AGENTRT" ] || { log_err "agentrt source tree not found: ${AGENTRT}"; exit 2; }
[ -d "$CUPOLAS_DIR" ] || { log_err "cupolas source tree not found: ${CUPOLAS_DIR}"; exit 2; }
[ -f "$BASELINE" ] || {
    log_err "baseline not found: ${BASELINE} (keys: core=<N>; facade=<N>; cupolas=<N>; target=<N>)"
    exit 2
}

pin_core="$(pin_of core)"
pin_facade="$(pin_of facade)"
pin_cupolas="$(pin_of cupolas)"
target="$(pin_of target)"

for kv in "core:${pin_core}" "facade:${pin_facade}" "cupolas:${pin_cupolas}" "target:${target}"; do
    k="${kv%%:*}"; v="${kv#*:}"
    case "$v" in
        ''|*[!0-9]*) log_err "baseline key '${k}' missing or non-numeric: '${v}'"; exit 2 ;;
    esac
done

for m in "${CORE_MODULES[@]}" "${FACADE_MODULES[@]}"; do
    [ -d "$AGENTRT/$m" ] || { log_err "module tree missing: ${AGENTRT}/${m}"; exit 2; }
done

core=0
for m in "${CORE_MODULES[@]}"; do
    core=$((core + $(count_loc "$AGENTRT/$m")))
done
core=$((core + $(count_loc "$AGENTRT/cmake")))

facade=0
for m in "${FACADE_MODULES[@]}"; do
    facade=$((facade + $(count_loc "$AGENTRT/$m")))
done

cupolas=$(count_loc "$CUPOLAS_DIR")

if [ "$MODE" = "report" ]; then
    printf 'core=%s\nfacade=%s\ncupolas=%s\n' "$core" "$facade" "$cupolas"
    for m in "${CORE_MODULES[@]}" cmake; do
        printf 'core.%s=%s\n' "$m" "$(count_loc "$AGENTRT/$m")"
    done
    for m in "${FACADE_MODULES[@]}"; do
        printf 'facade.%s=%s\n' "$m" "$(count_loc "$AGENTRT/$m")"
    done
    exit 0
fi

if [ "$MODE" = "converge" ]; then
    new_core="$pin_core";   [ "$core" -lt "$new_core" ] && new_core="$core"
    new_facade="$pin_facade"; [ "$facade" -lt "$new_facade" ] && new_facade="$facade"
    new_cupolas="$pin_cupolas"; [ "$cupolas" -lt "$new_cupolas" ] && new_cupolas="$cupolas"
    tmp="$(mktemp)"
    while IFS= read -r line; do
        case "$line" in
            core=*)    printf 'core=%s\n' "$new_core" ;;
            facade=*)  printf 'facade=%s\n' "$new_facade" ;;
            cupolas=*) printf 'cupolas=%s\n' "$new_cupolas" ;;
            *)         printf '%s\n' "$line" ;;
        esac
    done < "$BASELINE" > "$tmp"
    mv "$tmp" "$BASELINE"
    printf 'core=%s\nfacade=%s\ncupolas=%s\n' "$new_core" "$new_facade" "$new_cupolas"
    exit 0
fi

section "Gate 18 LOC budget (三本账数值棘轮；机制核=atoms+commons+heapstore+gateway+cmake)"

for m in "${CORE_MODULES[@]}"; do
    printf '  %-10s %8d\n' "$m" "$(count_loc "$AGENTRT/$m")"
done
printf '  %-10s %8d\n' "cmake" "$(count_loc "$AGENTRT/cmake")"
for m in "${FACADE_MODULES[@]}"; do
    printf '  %-10s %8d\n' "$m" "$(count_loc "$AGENTRT/$m")"
done
echo "  ----------------------"
printf '  %-10s %8d  (账一 机制核；pin=%s)\n' "core" "$core" "$pin_core"
printf '  %-10s %8d  (账三 形态面；pin=%s)\n' "facade" "$facade" "$pin_facade"
printf '  %-10s %8d  (账三 应用壳；pin=%s)\n' "cupolas" "$cupolas" "$pin_cupolas"

section "Gate 18 verdict"

rc=0
over() {
    local name="$1" got="$2" pin="$3"
    if [ "$got" -gt "$pin" ]; then
        log_err "${name}: 实测=${got} > pin=${pin}（超 $((got - pin)) 行）"
        rc=1
    elif [ "$got" -lt "$pin" ]; then
        log_warn "${name}: 实测=${got} < pin=${pin}（pin 滞后 $((pin - got)) 行）— 合入后须 --converge"
    else
        log_ok "${name}: 实测=${got} == pin=${pin}"
    fi
}
over "账一 core" "$core" "$pin_core"
over "账三 facade" "$facade" "$pin_facade"
over "账三 cupolas" "$cupolas" "$pin_cupolas"

if [ "$core" -gt "$target" ]; then
    log_warn "里程碑 target=${target} 差额 $((core - target)) 行（见方案 §7.5 收敛表；不阻断，方向约束）"
else
    log_ok "里程碑 target=${target} 已达成（余量 $((target - core)) 行）"
fi

[ "$rc" -eq 0 ] || { log_err "三账棘轮：任一账超 pin 即停线整改，不得带入下一批次"; exit 1; }
log_ok "Gate 18 PASSED"
exit 0
