#!/bin/bash
# G16 全队列户形态计数门禁（0.1.19 五件套机械执法）
#
# 权威依据：
#   0.1.19-架构改进方案.md §6.3 G16：全部 C daemon × 5 件齐全
#     （.manifest + main.c≤150 + svc.c + modules/ + 唯一私有头），
#     scripts 户仅登记 .manifest（CI 脚本集、无 C 生产码）；
#     G17：每户 manifest slots 字段完整（能力格词表由 daemon_gen 校验）。
#   0.1.19-L1-SSoT收敛台账.md §44：mem_d 唯一私有头落点豁免为
#     src/core/mem_daemon_ctx.h（历史嵌套形态，src 根不再放私有头）。
#
# 断言（resident 全队列，cupolas_d 等外户由 codegen-check 覆盖）：
#   A1  C daemon 户数 == FORM_DAEMON_COUNT（thresholds.conf SSoT）
#   A2  每户五件套齐：.manifest / src/main.c≤FORM_MAIN_MAX / src/svc.c /
#       modules/sources.cmake / 唯一私有头（src 根恰 1 个 *.h，
#       或命中豁免表且豁免文件在位）
#   A3  每户 src 顶层 .c == {main.c, svc.c} 二件（纯形态防回潮）
#   A4  每户 manifest 含非空 slots 数组（G17 全队列执法）
#   A5  scripts 户 .manifest 在位且为登记型（无 rpc/tcp 端口坐标）
#
# 用法: form-count-check.sh
# 退出码: 0 = 通过；1 = 存在违例；2 = 环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
DAEMONS="${PROJECT_ROOT}/agent-workload/agentrt/daemons"
THRESHOLDS="${SCRIPT_DIR}/../thresholds.conf"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

VIOLATIONS=0

[ -d "$DAEMONS" ] || { echo "daemons 树缺失: $DAEMONS"; exit 2; }
[ -f "$THRESHOLDS" ] || { echo "thresholds.conf 缺失: $THRESHOLDS"; exit 2; }
FORM_DAEMON_COUNT="$(sed -nE 's/^FORM_DAEMON_COUNT=([0-9]+).*/\1/p' "$THRESHOLDS" | head -n1)"
FORM_MAIN_MAX="$(sed -nE 's/^FORM_MAIN_MAX=([0-9]+).*/\1/p' "$THRESHOLDS" | head -n1)"
[ -n "$FORM_DAEMON_COUNT" ] && [ -n "$FORM_MAIN_MAX" ] \
    || { echo "thresholds.conf 缺 FORM_DAEMON_COUNT / FORM_MAIN_MAX"; exit 2; }

# 登记型户：非 C daemon，不入库纳计数（与 daemon_gen.py 豁免集一致）
REG_ONLY="common scripts"
# 唯一私有头豁免表（台账 §44）：户名 -> src/ 相对落点
exempt_priv() {
    case "$1" in
        mem_d) echo "core/mem_daemon_ctx.h" ;;
        *) echo "" ;;
    esac
}

# ── A1: 户数口径 ──────────────────────────────────────────────
section "A1: resident C daemon count"
DAEMON_LIST=()
for d in "$DAEMONS"/*/; do
    name="$(basename "$d")"
    skip=0
    for r in $REG_ONLY; do [ "$name" = "$r" ] && skip=1 && break; done
    [ "$skip" -eq 1 ] && continue
    [ -f "${d}src/main.c" ] || continue
    DAEMON_LIST+=("$name")
done
if [ "${#DAEMON_LIST[@]}" -eq "$FORM_DAEMON_COUNT" ]; then
    log_ok "A1. resident C daemon = ${#DAEMON_LIST[@]}（== SSoT 期望 ${FORM_DAEMON_COUNT}）"
else
    log_err "A1. resident C daemon = ${#DAEMON_LIST[@]}，期望 ${FORM_DAEMON_COUNT}（户数漂移须同步 thresholds.conf 与方案 G16）"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# ── A2/A3/A4: 逐户五件套 + 纯形态 + slots ─────────────────────
section "A2/A3/A4: per-daemon five-piece / landing / slots"
for name in "${DAEMON_LIST[@]}"; do
    dir="$DAEMONS/$name"
    bad=0

    if [ ! -f "$dir/.manifest" ]; then
        log_err "A2. ${name}: 缺 .manifest"; bad=$((bad + 1))
    else
        if ! grep -qE '"slots"[[:space:]]*:[[:space:]]*\[[[:space:]]*"' "$dir/.manifest"; then
            log_err "A4. ${name}: manifest slots 缺失或为空数组（G17）"; bad=$((bad + 1))
        fi
    fi

    if [ -f "$dir/src/main.c" ]; then
        lines="$(wc -l < "$dir/src/main.c")"
        if [ "$lines" -gt "$FORM_MAIN_MAX" ]; then
            log_err "A2. ${name}: main.c ${lines} 行 > ${FORM_MAIN_MAX}"; bad=$((bad + 1))
        fi
    else
        log_err "A2. ${name}: 缺 src/main.c"; bad=$((bad + 1))
    fi

    [ -f "$dir/src/svc.c" ] || { log_err "A2. ${name}: 缺 src/svc.c"; bad=$((bad + 1)); }
    [ -f "$dir/modules/sources.cmake" ] \
        || { log_err "A2. ${name}: 缺 modules/sources.cmake"; bad=$((bad + 1)); }

    top_h="$(find "$dir/src" -maxdepth 1 -name '*.h' | wc -l)"
    priv="$(exempt_priv "$name")"
    if [ -n "$priv" ]; then
        if [ "$top_h" -eq 0 ] && [ -f "$dir/src/$priv" ]; then
            :
        else
            log_err "A2. ${name}: 豁免私有头形态破坏（src 根头 ${top_h} 个，豁免应 0 且 src/${priv} 在位）"; bad=$((bad + 1))
        fi
    elif [ "$top_h" -ne 1 ]; then
        log_err "A2. ${name}: src 根私有头 ${top_h} 个（唯一私有头要求恰 1）"; bad=$((bad + 1))
    fi

    top_c="$(find "$dir/src" -maxdepth 1 -name '*.c' | wc -l)"
    if [ "$top_c" -ne 2 ] || [ ! -f "$dir/src/main.c" ] || [ ! -f "$dir/src/svc.c" ]; then
        log_err "A3. ${name}: src 顶层 .c 面 ${top_c} 个 != {main.c, svc.c}（装配回潮）"; bad=$((bad + 1))
    fi

    if [ "$bad" -eq 0 ]; then
        log_ok "A2/A3/A4. ${name}: 五件套齐全，slots 在位，顶层纯形态"
    else
        VIOLATIONS=$((VIOLATIONS + bad))
    fi
done

# ── A5: scripts 户登记 ────────────────────────────────────────
section "A5: scripts registration manifest"
SMF="$DAEMONS/scripts/.manifest"
if [ ! -f "$SMF" ]; then
    log_err "A5. 缺 daemons/scripts/.manifest（G16：scripts 户仅登记 .manifest）"
    VIOLATIONS=$((VIOLATIONS + 1))
elif ! grep -qE '"daemon"[[:space:]]*:[[:space:]]*"scripts"' "$SMF"; then
    log_err "A5. scripts/.manifest daemon 字段非 scripts"
    VIOLATIONS=$((VIOLATIONS + 1))
elif grep -qE '"tcp"' "$SMF"; then
    log_err "A5. scripts/.manifest 含 rpc.tcp 端口坐标（登记型户禁止）"
    VIOLATIONS=$((VIOLATIONS + 1))
else
    log_ok "A5. scripts 户登记在位（无 C 生产码、无端口坐标）"
fi

section "Form count gate summary"
if [ "$VIOLATIONS" -eq 0 ]; then
    log_ok "G16/G17 全队列形态计数：${#DAEMON_LIST[@]} 个 C daemon 五件套 + scripts 户登记 = $(( ${#DAEMON_LIST[@]} + 1 )) 户全绿"
    exit 0
fi
log_err "G16/G17 全队列形态计数：违例 ${VIOLATIONS} 项"
exit 1
