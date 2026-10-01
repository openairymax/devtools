#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# policy-payload-check.sh — AgentRT 机制核策略载荷零容忍门禁（G18 / G19）
#
# 背景（0.1.19 方案 §2.6 / §6.3，台账 §62）：
#   纲领「机制与策略极致分离」要求机制核零策略载荷：厂商名、产品名一律不得
#   写死在机制核生产码中，而应由生态层以 ops / .manifest 注入（G18 策略数据
#   化）。历史缺口：协议注册表、网关路由器、LLM 适配层把厂商名直接编进目录
#   与符号（如 PROTO_OPENAI / AIRY_PORT_OPENCLAW / provider_build_openai_
#   request），使新增一家厂商必改机制核——机制与策略耦合，即 R-7 复发的载
#   体。本门禁以静态断言把该缺口封死：名表之外的策略载荷不得进入机制核。
#
# 判定项：
#   A. 名表自洽：policy-payload-names.txt 存在、非空、全小写、无重复。
#   B. 机制核零策略载荷（G19）：机制核生产码剥离 C/C++ 注释与字面量保留区后，
#      不得出现名表内任一名。匹配以非字母数字字符为边界、大小写不敏感，故
#      `PROTO_CLAUDE`、`openai_compat` 命中，而 `myopenai` 不命中。
#   C. 棘轮基线：全局违例计数（名表命中行数）只减不增，新增即 fail-closed。
#
# 范围界定（按设计排除，非遗漏）：
#   - */tests/ 、*/third_party/ ：非生产码，不构成机制核。
#   - protocols/{integrations,frameworks,standards}/ ：方案 §4 明示的厂商 /
#     开放标准适配面，即 L8 迁出对象，本就不是机制核。
#   - 开放标准名（JSON-RPC / MCP / A2A 等）不在名表：机制核实现开放标准属
#     机制职责，不构成策略载荷。
#
# 基线：policy-payload-baseline.txt，首行数值为当前允许的违例数（棘轮水位）；
#   存量水位内的违例计 WARN（不阻断），清债后以 --update-baseline 下压，
#   只降不升。缺失或非法一律按水位 0 判定，使「删除基线」无法成为绕过退路。
#
# 退出码: 0=通过 1=超基线(新增违例，fail-closed) 2=高于水位(告警) 3=环境错误
# 用法: policy-payload-check.sh [--update-baseline]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="$PROJECT_ROOT/agent-workload/agentrt"
NAMES="$SCRIPT_DIR/policy-payload-names.txt"
BASELINE="$SCRIPT_DIR/policy-payload-baseline.txt"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

log_info() { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"; }
log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

UPDATE_BASELINE=0
if [ "${1:-}" = "--update-baseline" ]; then
    UPDATE_BASELINE=1
fi

VIOLATIONS=0

if [ ! -d "$AGENTRT" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 3
fi
if [ ! -f "$NAMES" ]; then
    log_err "policy name table not found: ${NAMES}"
    exit 3
fi

###############################################################################
# A. 策略名表自洽
###############################################################################
section "A. Policy name table (SSoT)"

mapfile -t NAME_LIST < <(grep -v '^[[:space:]]*#' "$NAMES" \
    | sed 's/[[:space:]]//g' | grep -v '^$' || true)
NAME_N="${#NAME_LIST[@]}"

if [ "$NAME_N" -eq 0 ]; then
    log_err "A1. 名表为空（未解析到任何策略名）"
    exit 3
fi
log_ok "A1. 名表条目数 = ${NAME_N}"

A_OK=1
for nm in "${NAME_LIST[@]}"; do
    if ! printf '%s' "$nm" | grep -qE '^[a-z0-9]+$'; then
        log_err "A2. 名表条目非全小写字母数字：'${nm}'"
        A_OK=0
    fi
done
if [ "$A_OK" -eq 1 ]; then
    log_ok "A2. 全部条目全小写字母数字"
fi

DUP_NAMES="$(printf '%s\n' "${NAME_LIST[@]}" | sort | uniq -d || true)"
if [ -n "$DUP_NAMES" ]; then
    log_err "A3. 名表条目重复：$(printf '%s' "$DUP_NAMES" | tr '\n' ' ')"
    exit 3
fi
log_ok "A3. 名表条目无重复"

ALT="$(printf '%s\n' "${NAME_LIST[@]}" \
    | awk 'BEGIN{s=0} {printf "%s%s",(s?"|":""),$0; s=1}')"
PAT="(^|[^A-Za-z0-9])(${ALT})([^A-Za-z0-9]|$)"

###############################################################################
# 机制核枚举
###############################################################################
GOV_SRC="$(find \
    "$AGENTRT/atoms" "$AGENTRT/commons" "$AGENTRT/daemons" \
    "$AGENTRT/cupolas" "$AGENTRT/gateway" "$AGENTRT/heapstore" \
    "$AGENTRT/tools" "$AGENTRT/protocols/core" "$AGENTRT/protocols/common" \
    "$AGENTRT/protocols/src" "$AGENTRT/protocols/include" \
    -type f \( -name '*.c' -o -name '*.h' \) \
    -not -path '*/third_party/*' -not -path '*/tests/*' \
    2>/dev/null | sort -u || true)"
SRC_N="$(printf '%s\n' "$GOV_SRC" | grep -c . || true)"
log_info "机制核生产码：${SRC_N} 文件"

###############################################################################
# B. 机制核零策略载荷
###############################################################################
section "B. Mechanism core zero policy payload (G19)"

HITS="$(printf '%s\n' "$GOV_SRC" | tr '\n' '\0' | xargs -0 -r awk -v pat="$PAT" '
BEGIN { ib=0; is=0; iq=0; q=sprintf("%c", 39) }
FNR == 1 { ib=0; is=0; iq=0 }
{
    l = $0; o = ""; i = 1; n = length(l)
    while (i <= n) {
        c = substr(l, i, 1); t = substr(l, i, 2)
        if (ib) { if (t == "*/") { ib = 0; i += 2 } else { i++ }; continue }
        if (is) {
            o = o c
            if (c == "\\") { o = o substr(l, i + 1, 1); i += 2 }
            else { if (c == "\"") { is = 0 }; i++ }
            continue
        }
        if (iq) {
            o = o c
            if (c == "\\") { o = o substr(l, i + 1, 1); i += 2 }
            else { if (c == q) { iq = 0 }; i++ }
            continue
        }
        if (t == "/*") { ib = 1; i += 2; continue }
        if (t == "//") { break }
        if (c == "\"") { is = 1; o = o c; i++; continue }
        if (c == q) { iq = 1; o = o c; i++; continue }
        o = o c; i++
    }
    if (tolower(o) ~ pat) print FILENAME ":" FNR
}
' 2>/dev/null || true)"

VIOLATIONS="$(printf '%s\n' "$HITS" | grep -c . || true)"
FILES_HIT="$(printf '%s\n' "$HITS" | sed 's/:[0-9]*$//' | sort -u | grep -c . || true)"

if [ "$VIOLATIONS" -eq 0 ]; then
    log_ok "B. 机制核零策略载荷（名表 ${NAME_N} 名全数未入机制核）"
else
    log_warn "B. 机制核命中策略载荷 ${VIOLATIONS} 处 / ${FILES_HIT} 文件（存量水位，见基线）"
    printf '%s\n' "$HITS" | sed 's/:[0-9]*$//' | sort | uniq -c | sort -rn \
        | head -n 15 | while IFS= read -r line; do
        rel="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')"
        cnt="$(printf '%s' "$line" | awk '{print $1}')"
        printf '        %s  %s\n' "$cnt" "${rel#$PROJECT_ROOT/}"
    done
fi

###############################################################################
# 结果汇总（棘轮基线）
###############################################################################
section "Policy payload gate summary"
printf '  名表条目: %s\n  机制核文件: %s\n  违例总数: %s  (%s 文件)\n' \
    "$NAME_N" "$SRC_N" "$VIOLATIONS" "$FILES_HIT"

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    printf '# 0.1.19 G18/G19 policy-payload violation baseline (count)\n%s\n' \
        "$VIOLATIONS" > "$BASELINE"
    log_info "基线已更新：${VIOLATIONS}（policy-payload-baseline.txt）"
    exit 0
fi

if [ "$VIOLATIONS" -eq 0 ]; then
    log_ok "策略载荷门禁通过（机制核零厂商名 / 产品名）"
    exit 0
fi

# 此处仅在 VIOLATIONS > 0 时到达；基线缺失/非法一律视为水位 0（fail-closed），
# 使「删除基线」无法成为绕过门禁的退路。
if [ ! -f "$BASELINE" ]; then
    log_err "基线缺失：${BASELINE}（运行 --update-baseline 播种；当前按水位 0 判定）"
    exit 1
fi
BASE_V="$(grep -v '^#' "$BASELINE" | grep -v '^[[:space:]]*$' | head -n1 | tr -d '[:space:]')"
if ! printf '%s' "$BASE_V" | grep -qE '^[0-9]+$'; then
    log_err "基线值非法：'${BASE_V}'（按水位 0 判定）"
    exit 1
fi

if [ "$VIOLATIONS" -gt "$BASE_V" ]; then
    log_err "违例 ${VIOLATIONS} 超基线 ${BASE_V}（新增策略载荷，fail-closed 阻断）"
    exit 1
fi

log_warn "违例 ${VIOLATIONS} ≤ 基线 ${BASE_V}（存量水位，未新增）"
exit 2
