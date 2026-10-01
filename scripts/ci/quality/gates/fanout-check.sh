#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# fanout-check.sh — AgentRT 负载扇出门禁（G13：load ≤ 5 且 fan 不增）
#
# 背景（0.1.19 方案 §4.4 / §6.3 G13，台账 §44 / §62）：
#   五件套化"拆并三裁决"的判据是"拆后 load ≤ 5，并后 fan 不增"：
#   load = 件内部头的 src 面扇入（多少生产代码文件消费该头）；
#   fan  = 目标对项目内库的扇出（跨模块依赖数）。历史缺口：拆并以"感觉
#   合理"为准，缺 CI 机器判据——单户扇入悄然膨胀、或并户后扇出抬升都
#   不被阻断。本门禁把台账 §44 的 mem_d 复核口径（仅取 src 面）固化为
#   fail-closed 断言，使 G13 从"文字裁决"变为机器判据。
#
# 判定项：
#   A. 口径自洽：thresholds.conf 提供 FANIN_MAX（唯一权威源，禁内联）；
#      daemons 树与 link-whitelist.txt（链接/层界 SSoT）可达。
#   B. load（头文件 src 面扇入，G13 上半）：每个 daemon 内部头（include/
#      与 src/）的 src 面消费方文件数须 ≤ FANIN_MAX。存量超限头须已登记
#      基线且不得上升（棘轮，只降不升）；未登记的新超限 = fail-closed。
#   C. fan（目标扇出，G13 下半）：每个白名单目标对项目内库的去重扇出数
#      （自持服务库不计）不得超基线——"并户后 fan 不增"的 CI 判据。
#
# 范围界定（按设计排除，非遗漏）：
#   - tests/、third_party/、构建区：非生产码，不构成扇入断言对象（口径
#     教训见台账 §44：首轮混入 tests 面致 cache.h/ledger.h 误报 6/7）。
#   - 扇入作用域 = 头的所属模块：同名头按所属模块分域统计（跨户归并会虚增，
#     如各户 main.c 同引 daemon_main.h）；跨户消费经服务面，不计入件内 load。
#     属已知边界；入度仍按消费方文件去重，不虚增。
#
# 基线：fanout-baseline.txt，两段（load / fan），只降不升；缺失或非法
#   一律按零容忍判定，使"删除基线"无法成为绕过退路。清债后以
#   --update-baseline 下压。
#
# 退出码: 0=通过 1=硬违例或超基线(fail-closed) 2=高于水位(告警) 3=环境错误
# 用法: fanout-check.sh [--update-baseline]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="$PROJECT_ROOT/agent-workload/agentrt"
DAEMONS="$AGENTRT/daemons"
WL="$AGENTRT/link-whitelist.txt"
BASELINE="$SCRIPT_DIR/fanout-baseline.txt"
THRESHOLDS="$SCRIPT_DIR/../thresholds.conf"

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

HARD=0
note_hard() { HARD=$((HARD + 1)); }

if [ ! -d "$DAEMONS" ]; then
    log_err "daemons source tree not found: ${DAEMONS}"
    exit 3
fi
if [ ! -f "$WL" ]; then
    log_err "link whitelist SSoT not found: ${WL}"
    exit 3
fi

###############################################################################
# A. 口径自洽（阈值 SSoT）
###############################################################################
section "A. Threshold SSoT self-consistency"

if [ ! -f "$THRESHOLDS" ]; then
    log_err "A1. 阈值 SSoT 缺失：${THRESHOLDS}"
    exit 3
fi
FANIN_MAX="$(awk -F= '/^[[:space:]]*FANIN_MAX[[:space:]]*=/{
        v = $2; sub(/#.*/, "", v); gsub(/[[:space:]]/, "", v); print v; exit
    }' "$THRESHOLDS")"
if ! printf '%s' "$FANIN_MAX" | grep -qE '^[0-9]+$'; then
    log_err "A1. FANIN_MAX 未定义或非法：'${FANIN_MAX}'（须为 thresholds.conf 中的正整数字面量）"
    exit 3
fi
log_ok "A1. FANIN_MAX = ${FANIN_MAX}（取自 thresholds.conf；有效扇入口径仅取 src 面）"

###############################################################################
# B. load：头文件 src 面扇入（G13 上半）
###############################################################################
section "B. Header load (src-face fan-in, G13)"

HDRS="$(find "$DAEMONS" -type f -name '*.h' 2>/dev/null \
    | grep -vE '/(tests|third_party|build|\.git)/' | sort || true)"
HDR_N="$(printf '%s\n' "$HDRS" | grep -c . || true)"
if [ "$HDR_N" -eq 0 ]; then
    log_err "B. 未枚举到任何内部头（路径或过滤有误）"
    exit 3
fi

CAND="$(grep -rnE '#[[:space:]]*include[[:space:]]*"[^"]+"' \
    --include='*.c' --include='*.h' "$DAEMONS" 2>/dev/null \
    | grep -vE '/(tests|third_party|build|\.git)/' || true)"

# 单趟 awk：以消费方文件去重计裸名入度，作用域 = 头的所属模块（沿台账
# §44 mem_d 口径：扇入只在件内衡量，跨户消费经服务面不计）；自引不计。
LOAD_OVER="$(awk -v max="$FANIN_MAX" -v root="$DAEMONS/" '
    function owner(p,  r) { r = substr(p, length(root) + 1); sub(/\/.*/, "", r); return r }
    NR==FNR {
        hdr[$0] = 1
        k = split($0, s, "/"); hb[$0] = s[k]; ow[$0] = owner($0)
        next
    }
    {
        i = index($0, ":")
        if (i == 0) { next }
        file = substr($0, 1, i - 1); body = substr($0, i + 1)
        if (!match(body, /"[^"]+"/)) { next }
        p = substr(body, RSTART + 1, RLENGTH - 2)
        n = split(p, a, "/"); base = a[n]
        if (base == "") { next }
        mo = owner(file)
        if ((file in hdr) && (hb[file] == base) && (ow[file] == mo)) { next }
        key = mo SUBSEP base SUBSEP file
        if (key in seen) { next }
        seen[key] = 1; cnt[mo SUBSEP base]++
    }
    END {
        for (h in hdr) {
            base = hb[h]; c = cnt[ow[h] SUBSEP base] + 0
            if (c > max) {
                rel = substr(h, length(root) + 1)
                printf "%s\t%d\n", rel, c
            }
        }
    }
' <(printf '%s\n' "$HDRS") <(printf '%s\n' "$CAND") | sort -t$'\t' -k2,2nr -k1,1)"

LOAD_OVER_N="$(printf '%s\n' "$LOAD_OVER" | grep -c . || true)"
log_info "B. 内部头 ${HDR_N} 个；src 面扇入 > ${FANIN_MAX} 者 ${LOAD_OVER_N} 个"

###############################################################################
# C. fan：目标扇出（G13 下半）
###############################################################################
section "C. Target fan-out (G13)"

WL_GOOD="$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
        pos = index($0, ":")
        if (pos == 0) { next }
        t = substr($0, 1, pos - 1); gsub(/[[:space:]]/, "", t)
        if (t !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { next }
        libs = substr($0, pos + 1)
        gsub(/^[[:space:]]+/, "", libs); gsub(/[[:space:]]+$/, "", libs)
        print t "\t" libs
    }
' "$WL" || true)"

FAN_TBL="$(printf '%s\n' "$WL_GOOD" | awk -F'\t' '
    {
        t = $1
        self = (t ~ /_d$/) ? "airy_" substr(t, 1, length(t) - 2) "_service" : ""
        n = split($2, a, " ")
        delete seen; c = 0
        for (i = 1; i <= n; i++) {
            lib = a[i]
            if (lib == "" || lib == self) { continue }
            if (lib in seen) { continue }
            seen[lib] = 1; c++
        }
        printf "%s\t%d\n", t, c
    }
' | sort)"

FAN_N="$(printf '%s\n' "$FAN_TBL" | grep -c . || true)"
log_info "C. 白名单目标 ${FAN_N} 个（fan = 去重项目内库扇出，自持服务库不计）"

###############################################################################
# 结果汇总（B/C 棘轮基线；基线缺失/非法一律零容忍）
###############################################################################
section "Fan-out gate summary"

BL_LOAD="$(awk '$1 == "load" { print $2 "\t" $3 }' "$BASELINE" 2>/dev/null || true)"
BL_FAN="$(awk  '$1 == "fan"  { print $2 "\t" $3 }' "$BASELINE" 2>/dev/null || true)"
read_field() {  # $1=两列表 $2=键 -> 值
    printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2; exit }'
}

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    {
        printf '# 0.1.19 G13 load/fan baseline (ratchet; only decrease)\n'
        printf '# section load: <daemon-relative header path> <src-face fan-in>\n'
        printf '# section fan : <whitelist target> <distinct project libs, self-held excluded>\n'
        printf '%s\n' "$LOAD_OVER" | grep . | sed 's/^/load /'
        printf '%s\n' "$FAN_TBL"   | grep . | sed 's/^/fan /'
    } > "$BASELINE"
    log_info "基线已更新：load 超限 ${LOAD_OVER_N} 项 / fan ${FAN_N} 项（fanout-baseline.txt）"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    log_err "基线缺失：${BASELINE}（运行 --update-baseline 播种）"
    exit 1
fi

# ── B 判定：未登记超限 = hard；水位上升 = hard；水位内 = warn ──────────────
B_NEW=0; B_RISE=0; B_SAFE=0
while IFS=$'\t' read -r rel c; do
    [ -n "$rel" ] || continue
    bv="$(read_field "$BL_LOAD" "$rel")"
    if [ -z "$bv" ]; then
        log_err "B. 新增超限头：${rel} load=${c} > ${FANIN_MAX}（新造件须达标，fail-closed）"
        B_NEW=$((B_NEW + 1)); note_hard
    elif [ "$c" -gt "$bv" ]; then
        log_err "B. 扇入上升：${rel} load=${c} > 基线 ${bv}（棘轮只降不升，fail-closed）"
        B_RISE=$((B_RISE + 1)); note_hard
    else
        [ "$c" -lt "$bv" ] && log_info "B. 扇入下降（可下压基线）：${rel} ${bv} → ${c}"
        B_SAFE=$((B_SAFE + 1))
    fi
done <<< "$LOAD_OVER"
if [ "$LOAD_OVER_N" -eq 0 ]; then
    log_ok "B. 全部内部头 src 面扇入 ≤ ${FANIN_MAX}（G13 load 达标）"
elif [ "$B_NEW" -eq 0 ] && [ "$B_RISE" -eq 0 ]; then
    log_warn "B. 存量超限 ${B_SAFE} 项，均在基线水位内（未新增、未上升）"
fi

# ── C 判定：fan 超基线 = hard；缺失基线项按 0 处理 ────────────────────────
C_RISE=0; C_SAFE=0
while IFS=$'\t' read -r t c; do
    [ -n "$t" ] || continue
    bv="$(read_field "$BL_FAN" "$t")"
    [ -n "$bv" ] || bv=0
    if [ "$c" -gt "$bv" ]; then
        log_err "C. 扇出上升：${t} fan=${c} > 基线 ${bv}（并户不得抬升扇出，fail-closed）"
        C_RISE=$((C_RISE + 1)); note_hard
    else
        C_SAFE=$((C_SAFE + 1))
    fi
done <<< "$FAN_TBL"
if [ "$C_RISE" -eq 0 ]; then
    log_ok "C. 全部目标 fan 未超基线（G13 fan 达标，${C_SAFE} 项）"
fi

printf '  内部头: %s\n  扇入超限: %s\n  B 新增/上升: %s/%s\n  目标: %s\n  C 上升: %s\n  硬违例: %s\n' \
    "$HDR_N" "$LOAD_OVER_N" "$B_NEW" "$B_RISE" "$FAN_N" "$C_RISE" "$HARD"

if [ "$HARD" -gt 0 ]; then
    log_err "负载扇出硬违例 ${HARD} 处（G13 fail-closed 阻断）"
    exit 1
fi

if [ "$LOAD_OVER_N" -eq 0 ]; then
    log_ok "负载扇出门禁通过（load ≤ ${FANIN_MAX} 且 fan 不增）"
    exit 0
fi

log_warn "存量超限 ${LOAD_OVER_N} 项（${B_SAFE} 项水位内）≤ 基线，未新增/未上升"
exit 2
