#!/bin/bash
# Gate 42 账本三表一致（0.1.20 方案 §9 Gate 42 / §4.2 A5）
#
# 判据（方案 §9 Gate 42 原文）：三表加总 == baseline 记录值，差异必须为 0。
#   ① 表内自洽：每本账的模块明细之和 == 该账合计；
#   ② 账本对齐：每本账实测合计 == baseline pin，任一方向差异非零即红。
#
# 与 Gate 18 的分工：Gate 18 判「不得超过」（实测 < pin 只告警，容忍 pin 滞后），
#   Gate 42 判「不许滞后」——pin 与代码必须逐数对齐。减重后必须 --converge 同步
#   落账，否则账本记录不再是代码的真实体量，§7.5 三本账就退化为装饰。
#
# 口径不在本脚本实现：一律复用 loc-budget-check.sh --report（唯一权威实现），
#   避免门禁之间复制 count_loc() 造成双口径。
#
# 环境变量（selfcheck 注入用）：
#   G42_LB        报告生产者（默认同目录 loc-budget-check.sh）
#   G42_BASELINE  基线文件（默认同目录 v16-loc-budget-baseline.txt）
#
# 用法: g42-ledger-consistency.sh
# 退出码: 0=三账全对齐 1=差异非零（违例） 2=环境错误（无法判断）
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LB="${G42_LB:-${SCRIPT_DIR}/loc-budget-check.sh}"
BASELINE="${G42_BASELINE:-${SCRIPT_DIR}/v16-loc-budget-baseline.txt}"
LEDGERS=(core facade cupolas)
SPLIT=(core facade)      # 多模块账：必须在报告里给出模块明细，供表内自洽校验
                         # 账三 cupolas 为单树账，明细即合计，不另列行

[ -f "$LB" ] || { echo "g42: report producer not found: ${LB}" >&2; exit 2; }
[ -f "$BASELINE" ] || { echo "g42: baseline not found: ${BASELINE}" >&2; exit 2; }

REPORT="$(bash "$LB" --report 2>/dev/null)" || {
    echo "g42: report producer failed: ${LB}" >&2
    exit 2
}

declare -A got=() rows=()
while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    case "$v" in
        ''|*[!0-9]*) echo "g42: malformed report line: ${k}=${v}" >&2; exit 2 ;;
    esac
    case "$k" in
        *.*) base="${k%%.*}"; rows["$base"]=$(( ${rows["$base"]:-0} + v )) ;;
        *)   got["$k"]="$v" ;;
    esac
done <<< "$REPORT"

pin_of() {
    sed -n "s/^$1=//p" "$BASELINE" | head -n1
}

declare -A pin=()
for l in "${LEDGERS[@]}"; do
    [ -n "${got[$l]:-}" ] || { echo "g42: report missing ledger ${l}" >&2; exit 2; }
    v="$(pin_of "$l")"
    case "$v" in
        ''|*[!0-9]*) echo "g42: baseline key '${l}' missing or non-numeric: '${v}'" >&2; exit 2 ;;
    esac
    pin["$l"]="$v"
done

for l in "${SPLIT[@]}"; do
    [ -n "${rows[$l]:-}" ] || { echo "g42: report missing rows for ${l}" >&2; exit 2; }
done

rc=0
for l in "${LEDGERS[@]}"; do
    if [ -n "${rows[$l]:-}" ]; then
        d=$(( got[$l] - rows[$l] ))
        if [ "$d" -ne 0 ]; then
            echo "g42: FAIL ${l} 表内不自洽：明细和=${rows[$l]} 合计=${got[$l]} 差=${d}"
            rc=1
        fi
    fi
    d=$(( got[$l] - pin[$l] ))
    if [ "$d" -gt 0 ]; then
        echo "g42: FAIL ${l} 超账：实测=${got[$l]} pin=${pin[$l]} 差=+${d}（须配减）"
        rc=1
    elif [ "$d" -lt 0 ]; then
        echo "g42: FAIL ${l} 账本滞后：实测=${got[$l]} pin=${pin[$l]} 差=${d}（须 --converge 落账）"
        rc=1
    fi
done

if [ "$rc" -ne 0 ]; then
    echo "g42: ledger mismatch, 差异必须为 0（§9 Gate 42）"
    exit 1
fi
echo "g42: core=${got[core]}/${pin[core]} facade=${got[facade]}/${pin[facade]} cupolas=${got[cupolas]}/${pin[cupolas]} — 三表对齐，差异 0"
exit 0
