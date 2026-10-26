#!/bin/bash
# 0.1.19 G2 体积硬门禁 + 里程碑阶梯（方案 §0.2 阶梯执法 / §0.5 G2）
#
# 口径（台账 §258「三层重新分账」裁定，2026-10-16；2026-10-16 SLOC 重锚）：按项目
#   术语把 agentrt/ 分三层分别计量，取代旧「七模块合一账」口径——按「原子件 ·
#   能力格 · 形态面」归位：
#     · 机制核（硬门禁账，目标 < 80,000 有效行）= 原子件层 atoms + 能力格层 commons +
#       堆存层 heapstore + 网关层 gateway + 组织码 cmake/。
#       （gateway 属机制核：agentrt 的 ingress/execute 形态面在机制侧的承载，
#        非可选壳层；§1.2 丙口径终裁「机制核含 gateway」。）
#     · 形态面子账（棘轮只降不升）= daemons + protocols + tools。
#     · 应用壳子账（棘轮只降不升）= products/cupolas（§1.3 迁出机制核的壳层本体）。
#   三层互不抵扣：子账缩水不减机制核，机制核减重亦不计入子账。
#   ⚠ 本口径为「分账口径裁定」，非减重——不得以口径变更冒充减重（守恒律·三账分立）。
# 计数口径：SLOC「有效行」= 各账 *.c + *.h，排除 tests/ 与 third_party/（vendored
#   第三方，非项目自研码，§229 裁定比照 tests/ 排除）后，再扣除空行与整行注释
#   （`^[[:space:]]*$` 与 `^[[:space:]]*(//|/*|*)`）。项目自有术语见
#   《0.1.19-机制核减重可行性细分方案》§1.1「有效代码」列：机制核现值 = 85,535
#   有效行（对应物理行 133,880）。
#   ⚠ PLOC（物理行 wc -l）→ SLOC（有效行）为口径裁定，非减重（守恒律·口径不可腾挪）。
# 阶梯（方案 §6.2 甲段；2026-10-16 SLOC 重锚；旧 PLOC 阶梯 K0=133,881… 作废）：
#   K0 = 现值锚（SLOC 85,535）/ K1 ≤83,500 / K2 ≤82,000 / K3 ≤80,500 /
#   K4 = < 80,000 终局硬门禁（取 79,999 作计数断言）。
#   中间梯级 provisional，随每波实测重排，未实测前不得虚挂。
#   映射 §6.2 甲端锚点：K0=M0、K1=M2★、K2=M5★、K3=M7★、K4=M10。
# 判据：实测机制核 ≤ 当前 pin 梯级上限即 PASS；超出即 FAIL——未达梯级值即停线整改，
#   不得带入下一梯级。子账棘轮只降不升，任一子账超出其 pin 亦 FAIL。
#   实测已达下一梯级时以 --advance 推进 pin（子账 pin 同步收敛为实测值）。
# 基线：v16-loc-budget-baseline.txt —— 每行 <键>=<值>；current=<K#>; facade=<N>; cupolas=<N>。
#   facade pin 裁定（2026-10-21）：由 60,990 恢复为方案 §1.2 丙 声明的形态面基线
#   61,426。该增量仅承担 CCN 长尾批次（main/tui_read_key/cli_* 等 8 项）拆分产生的
#   结构性开销（上下文结构体 + static 阶段函数样板，预计 +250~350 行），每批次完成
#   后在收敛台账公示实测值；M10 终局再统一棘轮收敛为实测值，不得长期停留于基线。
#   facade pin 裁定（2026-10-26，0.1.20 B1-c）：61,426 -> 实测 61,502（+76）。增量系
#   方案 D0 测量面（llm_rtr_meas EWMA 回填 + router/measurement stats 导出，G47/G60/G62
#   判据）落点全在 daemons 口径，属方案 §10 账一施工量，批次配减（§10.2）合入后回吐。
#   facade pin 裁定（2026-10-26，0.1.20 B1-d）：61,502 -> 实测 61,576（+74）。增量系
#   方案 P2-2 残余收口（prov_diag 线程诊断槽 + adapter/sse/rate_limit 写点 + llm_d
#   三处 RPC 错误面上游 detail 透传 + tools 集成测试源列表同步），复用 ErrorModel v1
#   语义未另建错误体，属方案 §10 账一施工量，批次配减（§10.2）合入后回吐。
# 用法: loc-budget-check.sh [--advance]
# 退出码: 0 = 通过；1 = 机制核超限 / 子账增长；2 = 环境错误（树/基线缺失）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
CUPOLAS_DIR="${PROJECT_ROOT}/agent-workload/products/cupolas"
BASELINE="$SCRIPT_DIR/v16-loc-budget-baseline.txt"

CORE_MODULES=(atoms commons heapstore gateway)     # 机制核：原子件 + 能力格 + 堆存 + 网关
FACADE_MODULES=(daemons protocols tools)           # 形态面

# 阶梯（机制核 SLOC 有效行口径）：名 -> 上限（对接方案 §6.2 甲段 ★ 锚点；K4 < 80,000，取 79,999）
MILESTONES=(K0 K1 K2 K3 K4)
CEIL_K0=85535     # 现值锚（SLOC 有效行；§6.2 甲 M0 重锚）
CEIL_K1=83500     # §6.2 甲 M2 ★（SLOC 重锚，provisional）
CEIL_K2=82000     # §6.2 甲 M5 ★（SLOC 重锚，provisional）
CEIL_K3=80500     # §6.2 甲 M7 ★（SLOC 重锚，provisional）
CEIL_K4=79999     # §6.2 甲 M10 < 80,000 硬门禁（SLOC 有效行）

ADVANCE=0
if [ "${1:-}" = "--advance" ]; then
    ADVANCE=1
fi

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

ceil_of() {
    local var="CEIL_$1"
    echo "${!var}"
}

idx_of() {
    local i
    for i in "${!MILESTONES[@]}"; do
        if [ "${MILESTONES[$i]}" = "$1" ]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# 单账计数（SLOC 有效行）：dir 下 *.c + *.h，排除 tests/ 与 third_party/，
#   再扣除空行与整行注释（与《机制核减重可行性细分方案》§1.1「有效代码」列同口径）
count_loc() {
    find "$1" -type f \( -name '*.c' -o -name '*.h' \) \
        | { grep -v -e '/tests/' -e '/third_party/' || true; } \
        | tr '\n' '\0' | xargs -0 -r cat \
        | { grep -vE '^[[:space:]]*$' || true; } \
        | { grep -vE '^[[:space:]]*(//|/\*|\*)' || true; } \
        | wc -l
}

if [ ! -d "$AGENTRT" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 2
fi

if [ ! -f "$BASELINE" ]; then
    log_err "baseline not found: ${BASELINE} (expected keys: current=<K#>; facade=<N>; cupolas=<N>)"
    exit 2
fi

current="$(sed -n 's/^current=//p' "$BASELINE" | head -n1)"
if [ -z "$current" ]; then
    log_err "baseline missing 'current=' key: ${BASELINE}"
    exit 2
fi

facade_pin="$(sed -n 's/^facade=//p' "$BASELINE" | head -n1)"
if [ -z "$facade_pin" ]; then
    log_err "baseline missing 'facade=' key: ${BASELINE}"
    exit 2
fi

cupolas_pin="$(sed -n 's/^cupolas=//p' "$BASELINE" | head -n1)"
if [ -z "$cupolas_pin" ]; then
    log_err "baseline missing 'cupolas=' key: ${BASELINE}"
    exit 2
fi

if [ ! -d "$CUPOLAS_DIR" ]; then
    log_err "cupolas source tree not found: ${CUPOLAS_DIR}"
    exit 2
fi

cur_idx="$(idx_of "$current")" || {
    log_err "unknown milestone in baseline: current=${current}"
    exit 2
}

section "0.1.19 G2 LOC budget gate (pin=${current}, SLOC 有效行; 机制核=atoms+commons+heapstore+gateway+cmake; 形态面 & cupolas 独立子账)"

for m in "${CORE_MODULES[@]}"; do
    d="$AGENTRT/$m"
    if [ ! -d "$d" ]; then
        log_err "module tree missing: ${d}"
        exit 2
    fi
done
for m in "${FACADE_MODULES[@]}"; do
    d="$AGENTRT/$m"
    if [ ! -d "$d" ]; then
        log_err "module tree missing: ${d}"
        exit 2
    fi
done

core=0
for m in "${CORE_MODULES[@]}"; do
    n=$(count_loc "$AGENTRT/$m")
    core=$((core + n))
    printf '  %-10s %8d\n' "$m" "$n"
done
cmake_loc=0
if [ -d "$AGENTRT/cmake" ]; then
    cmake_loc=$(count_loc "$AGENTRT/cmake")
fi
core=$((core + cmake_loc))
printf '  %-10s %8d\n' "cmake" "$cmake_loc"

facade=0
for m in "${FACADE_MODULES[@]}"; do
    n=$(count_loc "$AGENTRT/$m")
    facade=$((facade + n))
    printf '  %-10s %8d\n' "$m" "$n"
done

cupolas_total=$(count_loc "$CUPOLAS_DIR")

echo "  ----------------------"
printf '  %-10s %8d  (机制核：原子件+能力格+堆存+网关+组织码；SLOC 有效行)\n' "core" "$core"
printf '  %-10s %8d  (形态面子账，不计入机制核)\n' "facade" "$facade"
printf '  %-10s %8d  (应用壳子账，不计入机制核)\n' "cupolas" "$cupolas_total"

ceiling="$(ceil_of "$current")"
next_idx=$((cur_idx + 1))

if [ "$ADVANCE" -eq 1 ]; then
    if [ "$next_idx" -ge "${#MILESTONES[@]}" ]; then
        log_err "--advance: ${current} is the terminal milestone"
        exit 2
    fi
    next="${MILESTONES[$next_idx]}"
    next_ceiling="$(ceil_of "$next")"
    if [ "$core" -gt "$next_ceiling" ]; then
        log_err "--advance refused: core=${core} exceeds ${next} ceiling=${next_ceiling}"
        exit 1
    fi
    facade_new_pin="$facade_pin"
    if [ "$facade" -lt "$facade_new_pin" ]; then
        facade_new_pin="$facade"
    fi
    cupolas_new_pin="$cupolas_pin"
    if [ "$cupolas_total" -lt "$cupolas_new_pin" ]; then
        cupolas_new_pin="$cupolas_total"
    fi
    printf 'current=%s\nfacade=%s\ncupolas=%s\n' "$next" "$facade_new_pin" "$cupolas_new_pin" > "$BASELINE"
    log_ok "milestone advanced: ${current} -> ${next} (core=${core} <= ${next_ceiling}), facade pin -> ${facade_new_pin}, cupolas pin -> ${cupolas_new_pin}"
    current="$next"
    ceiling="$next_ceiling"
    cur_idx="$next_idx"
    next_idx=$((next_idx + 1))
fi

section "0.1.19 G2 loc-budget gate"

if [ "$core" -gt "$ceiling" ]; then
    log_err "机制核 core=${core} exceeds pin ${current} ceiling=${ceiling} by $((core - ceiling))"
    log_err "阶梯执法：未达梯级值即停线整改，不得带入下一梯级"
    exit 1
fi
log_ok "机制核 core=${core} <= ${current} ceiling=${ceiling} (slack=$((ceiling - core)))"

if [ "$facade" -gt "$facade_pin" ]; then
    log_err "形态面子账: total=${facade} exceeds pin=${facade_pin} by $((facade - facade_pin))"
    log_err "子账棘轮只降不升：形态面缩水不抵扣机制核，但同样禁止增长"
    exit 1
fi
log_ok "形态面 facade=${facade} <= pin=${facade_pin} (子账 slack=$((facade_pin - facade)))"

if [ "$cupolas_total" -gt "$cupolas_pin" ]; then
    log_err "应用壳子账: total=${cupolas_total} exceeds pin=${cupolas_pin} by $((cupolas_total - cupolas_pin))"
    log_err "子账棘轮只降不升：cupolas 缩水不抵扣机制核，但同样禁止增长"
    exit 1
fi
log_ok "cupolas=${cupolas_total} <= pin=${cupolas_pin} (子账 slack=$((cupolas_pin - cupolas_total)))"

if [ "$next_idx" -lt "${#MILESTONES[@]}" ]; then
    next="${MILESTONES[$next_idx]}"
    next_ceiling="$(ceil_of "$next")"
    if [ "$core" -le "$next_ceiling" ]; then
        log_warn "next milestone ${next} (<=${next_ceiling}) already met — run --advance"
    else
        log_warn "gap to ${next} ceiling=${next_ceiling}: $((core - next_ceiling))"
    fi
fi

log_ok "0.1.19 G2 loc-budget gate PASSED"
exit 0
