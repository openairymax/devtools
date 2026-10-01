#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# port-coord-check.sh — AgentRT 端口坐标唯一性 + 三面一致性门禁（G5 禁双轨）
#
# 背景（0.1.19 台账 §四.2 / §五）：
#   端口坐标唯一权威（SSoT）为 agentrt/commons/include/airy_defaults.h 的
#   `AIRY_PORT_*` 宏族，受辖带 AIRY_PORT_BAND_MIN..AIRY_PORT_BAND_MAX
#   （2026-2100）。历史缺口：各 daemon 私有头 / Windows 端点表 / gateway
#   端口模型 / 外围适配器各自复刻端口字面量，形成"多轨坐标"——R7 并户与
#   D2 定夺反复被这些副本绊住（根因链见 §65①）。本门禁以结构断言消灭该
#   缺口：机制面源码一律以 SSoT 符号引用（禁双轨），受辖面内不得出现登记
#   表之外的落带端口字面量，三面端点表的符号引用必须全部解析到同一登记表。
#
# 判定项：
#   A. 登记表自洽：BAND_MIN/MAX 存在且有序；每个 AIRY_PORT_* 值落带内；
#      坐标值跨符号唯一（无两符号同值）。
#   B. 机制面源码（受辖 *.c / *.h / *.manifest）内禁止任何落带端口字面量
#      ——必须走 SSoT 符号（禁双轨）。
#   C. 部署/配置/探针面（受辖 *.yml / *.yaml / *.conf / *.sh / *.ps1 / *.py /
#      Dockerfile*）内落带端口字面量必须落在登记表值集合内；登记表之外者
#      FAIL（跨表坐标一致性）。
#   D. 符号解析：受辖面内引用的每个 AIRY_PORT_* 符号必须在 SSoT 登记表内
#      有定义（防拼写漂移导致坐标静默失配）。
#   E. codegen 主源：daemons/*/.manifest 的 rpc.tcp 必须为符号引用。
#
# 范围界定（按设计排除，非遗漏）：
#   - tests/ 、third_party/ ：台账 §四.3「测试纪律 ephemeral」将测试字面量
#     归存量整改面（白名单豁免，不阻塞本轮），非登记表管辖对象。
#   - 外部依赖端口（postgres 5432 / redis 6379 / ollama 11434 / jaeger
#     16686 等）：台账 §四.3 明示不归 AirymaxRT 管辖，不进段、不参与断言。
#   - 对外映射端口（用户侧 8080 / 8081 等策略面契约）：落带外，天然不触发。
#
# 基线：port-coord-baseline.txt，首行数值为当前允许的违例数（棘轮水位）；
#   清债后以 --update-baseline 下压，只降不升。
#
# 退出码: 0=通过 1=超基线(新增违例，fail-closed) 2=高于水位(告警) 3=环境错误
# 用法: port-coord-check.sh [--update-baseline]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="$PROJECT_ROOT/agent-workload/agentrt"
SSOT_HEADER="$AGENTRT/commons/include/airy_defaults.h"
BASELINE="$SCRIPT_DIR/port-coord-baseline.txt"

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
note_violation() { VIOLATIONS=$((VIOLATIONS + 1)); }

if [ ! -d "$AGENTRT" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 3
fi
if [ ! -f "$SSOT_HEADER" ]; then
    log_err "port SSoT header not found: ${SSOT_HEADER}"
    exit 3
fi

###############################################################################
# A. 解析 SSoT 登记表
###############################################################################
section "A. Port SSoT registry"

BAND_MIN="$(sed -nE \
    's/^[[:space:]]*#[[:space:]]*define[[:space:]]+AIRY_PORT_BAND_MIN[[:space:]]+([0-9]+).*/\1/p' \
    "$SSOT_HEADER" | head -n1)"
BAND_MAX="$(sed -nE \
    's/^[[:space:]]*#[[:space:]]*define[[:space:]]+AIRY_PORT_BAND_MAX[[:space:]]+([0-9]+).*/\1/p' \
    "$SSOT_HEADER" | head -n1)"

if [ -z "$BAND_MIN" ] || [ -z "$BAND_MAX" ]; then
    log_err "A1. 受辖带边界缺失（AIRY_PORT_BAND_MIN/MAX 未在 SSoT 头定义）"
    note_violation
    BAND_MIN="${BAND_MIN:-0}"
    BAND_MAX="${BAND_MAX:-0}"
elif [ "$BAND_MIN" -gt "$BAND_MAX" ]; then
    log_err "A1. 受辖带边界倒置：MIN=${BAND_MIN} > MAX=${BAND_MAX}"
    note_violation
else
    log_ok "A1. 受辖带 = ${BAND_MIN}..${BAND_MAX}"
fi

in_band() {
    [ "$1" -ge "$BAND_MIN" ] 2>/dev/null && [ "$1" -le "$BAND_MAX" ] 2>/dev/null
}

REG_PAIRS="$(sed -nE \
    's/^[[:space:]]*#[[:space:]]*define[[:space:]]+(AIRY_PORT_[A-Z0-9_]+)[[:space:]]+([0-9]+)[[:space:]]*$/\1 \2/p' \
    "$SSOT_HEADER" | grep -vE '^AIRY_PORT_BAND_(MIN|MAX) ' || true)"

REG_SYMS="$(printf '%s\n' "$REG_PAIRS" | awk '{print $1}' | grep -v '^$' | sort || true)"
REG_VALS="$(printf '%s\n' "$REG_PAIRS" | awk '{print $2}' | grep -v '^$' | sort -n || true)"
REG_COUNT="$(printf '%s\n' "$REG_SYMS" | grep -c . || true)"

if [ "$REG_COUNT" -eq 0 ]; then
    log_err "A2. 登记表为空（未解析到任何 AIRY_PORT_* 坐标）"
    note_violation
else
    log_info "A2. 登记坐标数 = ${REG_COUNT}"
fi

OOB=""
while IFS= read -r v; do
    [ -n "$v" ] || continue
    if ! in_band "$v"; then
        OOB="${OOB}${OOB:+, }${v}"
    fi
done <<< "$REG_VALS"
if [ -n "$OOB" ]; then
    log_err "A2. 登记值越出受辖带（${BAND_MIN}-${BAND_MAX}）：${OOB}"
    note_violation
else
    log_ok "A2. 全部登记值落带内"
fi

DUP_VALS="$(printf '%s\n' "$REG_VALS" | grep -v '^$' | uniq -d || true)"
if [ -n "$DUP_VALS" ]; then
    log_err "A3. 坐标值跨符号重复（同值多符号）：$(printf '%s' "$DUP_VALS" | tr '\n' ' ')"
    note_violation
else
    log_ok "A3. 坐标值跨符号唯一"
fi

###############################################################################
# 受辖面枚举
###############################################################################
GOV_SRC="$(find "$AGENTRT" -type f \
    \( -name '*.c' -o -name '*.h' -o -name '*.manifest' \) \
    -not -path '*/.git/*' -not -path '*/third_party/*' -not -path '*/tests/*' \
    2>/dev/null | grep -v "/commons/include/airy_defaults.h$" || true)"

GOV_CFG="$(find "$AGENTRT" -type f \
    \( -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.sh' \
       -o -name '*.ps1' -o -name '*.py' -o -name 'Dockerfile*' \) \
    -not -path '*/.git/*' -not -path '*/third_party/*' -not -path '*/tests/*' \
    2>/dev/null || true)"

# 部署面 / 探针面（台账 §五 表内、落在 agentrt 之外的受辖落点）
EXT_PATHS=(
    "$PROJECT_ROOT/agent-workload/products/docker"
    "$PROJECT_ROOT/agent-workload/ecosystem/markets/client"
    "$PROJECT_ROOT/tools/scripts/ci/release/e2e-clean-room.sh"
    "$PROJECT_ROOT/tools/scripts/ci/pipeline/test/test-integration.sh"
    "$PROJECT_ROOT/tools/scripts/ci/pipeline/test/run-connection-tests.sh"
    "$PROJECT_ROOT/tools/scripts/ops/bin/quickstart.sh"
    "$PROJECT_ROOT/tools/scripts/ops/bin/agentrt-bootstrap.sh"
    "$PROJECT_ROOT/tools/deploy/kubernetes/helm/templates/configmap.yaml"
)
for p in "${EXT_PATHS[@]}"; do
    if [ -d "$p" ]; then
        more="$(find "$p" -type f \
            \( -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.sh' \
               -o -name '*.ps1' -o -name '*.py' -o -name 'Dockerfile*' \) \
            -not -path '*/.git/*' -not -path '*/tests/*' 2>/dev/null || true)"
        GOV_CFG="${GOV_CFG}${GOV_CFG:+$'\n'}${more}"
    elif [ -f "$p" ]; then
        GOV_CFG="${GOV_CFG}${GOV_CFG:+$'\n'}${p}"
    else
        log_warn "受辖外部落点缺失（跳过）：${p#$PROJECT_ROOT/}"
    fi
done

GOV_SRC="$(printf '%s\n' "$GOV_SRC" | grep -v '^$' | sort -u || true)"
GOV_CFG="$(printf '%s\n' "$GOV_CFG" | grep -v '^$' | sort -u || true)"

SRC_N="$(printf '%s\n' "$GOV_SRC" | grep -c . || true)"
CFG_N="$(printf '%s\n' "$GOV_CFG" | grep -c . || true)"
log_info "受辖面：机制源码 ${SRC_N} 文件 / 部署配置 ${CFG_N} 文件"

###############################################################################
# B. 机制面源码：禁止落带端口字面量
###############################################################################
section "B. Mechanism source (no in-band port literal)"

B_HITS=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#$PROJECT_ROOT/}"
    hits="$(grep -nE \
        '"[^"]*:[0-9]{4,6}|[^A-Za-z0-9_]port[[:space:]]*=[[:space:]]*[0-9]{4,6}|^[[:space:]]*#[[:space:]]*define[[:space:]]+[A-Za-z_]*PORT[A-Za-z_]*[[:space:]]+[0-9]{4,6}' \
        "$f" 2>/dev/null || true)"
    [ -n "$hits" ] || continue
    while IFS= read -r hit; do
        ln="${hit%%:*}"
        body="${hit#*:}"
        nums="$(printf '%s' "$body" | grep -oE '[0-9]{4,6}' || true)"
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            if in_band "$n"; then
                log_err "B. ${rel}:${ln} 落带端口字面量 (port=${n}) — 应引用 SSoT 符号"
                log_err "     ${body}"
                note_violation
                B_HITS=$((B_HITS + 1))
            fi
        done <<< "$nums"
    done <<< "$hits"
done <<< "$GOV_SRC"
if [ "$B_HITS" -eq 0 ]; then
    log_ok "B. 机制面源码零落带端口字面量（禁双轨达成）"
fi

###############################################################################
# C. 部署/配置/探针面：落带字面量必须落在登记表值内
###############################################################################
section "C. Deploy/config surface (in-band literal must be registered)"

is_registered() {
    printf '%s\n' "$REG_VALS" | grep -qx "$1"
}

C_HITS=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#$PROJECT_ROOT/}"
    hits="$(grep -nE \
        ':[0-9]{4,6}|[0-9]{4,6}:[0-9]{4,6}|[Pp][Oo][Rr][Tt][[:space:]]*[:=][[:space:]]*"?[0-9]{4,6}|EXPOSE[[:space:]]+[0-9]{4,6}|-p[[:space:]]+[0-9]{4,6}' \
        "$f" 2>/dev/null || true)"
    [ -n "$hits" ] || continue
    while IFS= read -r hit; do
        ln="${hit%%:*}"
        body="${hit#*:}"
        nums="$(printf '%s' "$body" | grep -oE '[0-9]{4,6}' || true)"
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            in_band "$n" || continue
            if ! is_registered "$n"; then
                log_err "C. ${rel}:${ln} 落带端口 ${n} 未登记于 SSoT 登记表"
                log_err "     ${body}"
                note_violation
                C_HITS=$((C_HITS + 1))
            fi
        done <<< "$nums"
    done <<< "$hits"
done <<< "$GOV_CFG"
if [ "$C_HITS" -eq 0 ]; then
    log_ok "C. 部署/配置面落带字面量均落在登记表内"
fi

###############################################################################
# D. 符号解析：引用的 AIRY_PORT_* 必须已登记
###############################################################################
section "D. Symbol resolution (three-face consistency)"

GOV_ALL="$(printf '%s\n%s\n' "$GOV_SRC" "$GOV_CFG" | grep -v '^$' || true)"
D_HITS=0
if [ -n "$GOV_ALL" ]; then
    REFS="$(printf '%s\n' "$GOV_ALL" | tr '\n' '\0' \
        | xargs -0 grep -hoE 'AIRY_PORT_[A-Z0-9_]+' 2>/dev/null | sort -u || true)"
    while IFS= read -r sym; do
        [ -n "$sym" ] || continue
        if ! printf '%s\n' "$REG_SYMS" | grep -qx "$sym"; then
            log_err "D. 引用了未登记符号：${sym}（SSoT 登记表无此坐标）"
            note_violation
            D_HITS=$((D_HITS + 1))
        fi
    done <<< "$REFS"
fi
if [ "$D_HITS" -eq 0 ]; then
    log_ok "D. 受辖面符号引用全部解析到 SSoT 登记表（三面一致）"
fi

###############################################################################
# E. codegen 主源：daemons/*/.manifest rpc.tcp 必须为符号引用
###############################################################################
section "E. codegen manifest rpc.tcp symbolic"

E_HITS=0
for mf in "$AGENTRT"/daemons/*/.manifest; do
    [ -f "$mf" ] || continue
    rel="${mf#$PROJECT_ROOT/}"
    tcp="$(sed -nE 's/.*"tcp"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$mf" | head -n1)"
    if [ -z "$tcp" ]; then
        log_err "E. ${rel} 未声明 rpc.tcp"
        note_violation
        E_HITS=$((E_HITS + 1))
    elif ! printf '%s' "$tcp" | grep -qE '^AIRY_PORT_[A-Z0-9_]+$'; then
        log_err "E. ${rel} rpc.tcp=\"${tcp}\" 非 SSoT 符号引用"
        note_violation
        E_HITS=$((E_HITS + 1))
    fi
done
if [ "$E_HITS" -eq 0 ]; then
    log_ok "E. 15 户 manifest rpc.tcp 均为 SSoT 符号"
fi

###############################################################################
# 结果汇总（棘轮基线）
###############################################################################
section "Port coordinate gate summary"
printf '  登记坐标: %s\n  机制源码: %s 文件\n  部署配置: %s 文件\n  违例总数: %s\n' \
    "$REG_COUNT" "$SRC_N" "$CFG_N" "$VIOLATIONS"

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    printf '# 0.1.19 G5 port-coordinate violation baseline (count)\n%s\n' \
        "$VIOLATIONS" > "$BASELINE"
    log_info "基线已更新：${VIOLATIONS}（port-coord-baseline.txt）"
    exit 0
fi

if [ "$VIOLATIONS" -eq 0 ]; then
    log_ok "端口坐标门禁通过（坐标唯一 + 三面一致 + 禁双轨）"
    exit 0
fi

# 此处仅在 VIOLATIONS > 0 时到达；基线缺失/非法一律视为水位 0（fail-closed），
# 使"删除基线"无法成为绕过门禁的退路。
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
    log_err "违例 ${VIOLATIONS} 超基线 ${BASE_V}（新增坐标违例，fail-closed 阻断）"
    exit 1
fi

log_warn "违例 ${VIOLATIONS} ≤ 基线 ${BASE_V}（存量水位，未新增）"
exit 2
