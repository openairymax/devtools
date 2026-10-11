#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# layer-check.sh — AgentRT 层界单向 + 跨进程零符号引用门禁（G21 / G23）
#
# 背景（0.1.19 方案 §6.3 / 架构文档 §7.1，台账 §62）：
#   架构文档 §7.1 运行视图两条不变量：跨进程唯一通道 = IPC / syscall（零进程
#   内符号引用，G23）；层界单向（不出现反向依赖，G21）。方案 §6.3 将二者归为
#   「链接图断言」——构建区生成 include/符号依赖图，反向边 = 0。历史缺口：层
#   界只以文字写在 README，缺乏 CI fail-closed 机器判据，任一模块悄然反向
#   依赖上层（或在进程内直引他户服务符号）都不被阻断。本门禁把层界 SSoT
#   （agentrt/link-whitelist.txt，构建期 airy_linkgate/airy_depgraph 的同一
#   权威源）搬进 CI，使「层界在而不生效」（方案 §6.5 R-7）不再复发。
#
# 判定项：
#   A. 白名单自洽：link-whitelist.txt 可解析、目标唯一、语法合法；值侧出现的
#      项目库（前缀 airy_/libairy_/coreloopthree/cognition/svc_/daemon_）必须
#      解析到真实 CMake 目标，否则即「未登记项目库」，fail-closed。目标宇宙 =
#      agentrt 树 ∪ 顶层装配块挂载的外户源根（products/ 下 cupolas /
#      lang_gateway / cognition），使外户目标（如 airy_cupolas_service）合法
#      解析（§296 修复：曾仅扫 agentrt，误判外户目标未登记而 fail-closed）。
#   B. 层界单向（G21，白名单面）：认知引擎只对 think_d 暴露服务面——gateway 系
#      目标禁链 coreloopthree/cognition；内核机制只被 daemon 服务面访问——
#      客户端目标（airy_cli / gateway 系）禁链 airy_atoms。
#   C. 跨进程零符号引用（G23）：daemon 目标的允许集不得含其它 daemon 的服务库
#      或任意 daemon_* 库（跨界调用必须走总线）；例外仅在白名单登记后才豁免。
#   D. 层界单向（G21，代码面）：源码相对 include 不得反向跨层（由下向上）。
#      层序（自底向上）= commons < atoms < heapstore < gateway <
#      protocols < daemons；反向边 = 0。（cupolas 已按方案 §1.3 迁出
#      agentrt 树至 products，不再参与层序。）
#
# 范围界定（按设计排除，非遗漏）：
#   - tests/ 、third_party/ 、构建区：非生产码，不构成层界断言对象。
#   - 非相对 include（如 `#include "airy_rt.h"` 经 include 目录解析）：无路径
#     知识，静态不可判，不属本段（其链接面约束由 B/C 与构建期 linkgate 覆盖）。
#   - tools/ 等非分层目录不参与 D（rank 0，客户端而非层）。
#
# 基线：layer-baseline.txt，首行数值为当前允许的反向 include 数（棘轮水位）；
#   A/B/C 硬违例不计入水位（零容忍，直接 fail-closed）；清债后以
#   --update-baseline 下压，只降不升。缺失或非法一律按水位 0 判定，使「删除
#   基线」无法成为绕过退路。
#
# 退出码: 0=通过 1=硬违例或超基线(fail-closed) 2=高于水位(告警) 3=环境错误
# 用法: layer-check.sh [--update-baseline]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="$PROJECT_ROOT/agent-workload/agentrt"
WL="$AGENTRT/link-whitelist.txt"
BASELINE="$SCRIPT_DIR/layer-baseline.txt"

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
D_VIOL=0
note_hard() { HARD=$((HARD + 1)); }

if [ ! -d "$AGENTRT" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 3
fi
if [ ! -f "$WL" ]; then
    log_err "link whitelist SSoT not found: ${WL}"
    exit 3
fi

###############################################################################
# A. 白名单自洽（SSoT 解析 + 未登记项目库）
###############################################################################
section "A. Link whitelist self-consistency (SSoT)"

WL_PARSE="$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
        line = $0
        pos = index(line, ":")
        if (pos == 0) { print "SYNERR\t" NR "\t" line; next }
        t = substr(line, 1, pos - 1); gsub(/[[:space:]]/, "", t)
        if (t !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
            print "SYNERR\t" NR "\t" line; next
        }
        libs = substr(line, pos + 1)
        gsub(/^[[:space:]]+/, "", libs); gsub(/[[:space:]]+$/, "", libs)
        print t "\t" libs
    }
' "$WL" || true)"

SYNERR="$(printf '%s\n' "$WL_PARSE" | grep '^SYNERR' || true)"
if [ -n "$SYNERR" ]; then
    while IFS=$'\t' read -r _ ln body; do
        log_err "A2. 白名单语法非法（第 ${ln} 行）：${body}"
        note_hard
    done <<< "$SYNERR"
else
    log_ok "A2. 白名单语法合法（<目标>: <允许库...>）"
fi

WL_GOOD="$(printf '%s\n' "$WL_PARSE" | grep -v '^SYNERR' || true)"
TARGETS="$(printf '%s\n' "$WL_GOOD" | cut -f1 | grep -v '^$' | sort || true)"
TARGET_N="$(printf '%s\n' "$TARGETS" | grep -c . || true)"

if [ "$TARGET_N" -eq 0 ]; then
    log_err "A1. 白名单未解析到任何目标"
    exit 3
fi
log_ok "A1. 白名单目标数 = ${TARGET_N}"

DUP_T="$(printf '%s\n' "$TARGETS" | uniq -d || true)"
if [ -n "$DUP_T" ]; then
    log_err "A3. 白名单目标重复：$(printf '%s' "$DUP_T" | tr '\n' ' ')"
    note_hard
else
    log_ok "A3. 白名单目标唯一"
fi

# A4 目标宇宙 = agentrt 树 ∪ 顶层装配块挂载的外户源根。0.1.19 方案 §1.3
# 将 cupolas 等产品壳迁出核心树至 products/；agentrt/CMakeLists.txt 顶层
# 装配块以三态探测 add_subdirectory 挂载 cupolas / lang_gateway / cognition
# （§255 起 cupolas_d 亦于顶层挂载），其 CMake 目标（airy_cupolas_service /
# cupolas_d 等）合法出现在白名单值侧。源根缺席（standalone 平铺布局）即
# 跳过，等价该外户未挂载。
CMAKE_SCAN_ROOTS=("$AGENTRT")
for _ext in cupolas lang_gateway cognition; do
    _ext_dir="$PROJECT_ROOT/agent-workload/products/$_ext"
    if [ -d "$_ext_dir" ]; then
        CMAKE_SCAN_ROOTS+=("$_ext_dir")
    fi
done
EXT_ROOT_N=$(( ${#CMAKE_SCAN_ROOTS[@]} - 1 ))

CMAKE_TARGETS="$(grep -rhE '^[[:space:]]*add_(library|executable)[[:space:]]*\(' \
    --include=CMakeLists.txt "${CMAKE_SCAN_ROOTS[@]}" 2>/dev/null \
    | sed -E 's/^[[:space:]]*add_(library|executable)[[:space:]]*\([[:space:]]*//' \
    | awk '{print $1}' | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | sort -u || true)"
CMAKE_N="$(printf '%s\n' "$CMAKE_TARGETS" | grep -c . || true)"

UNREG=0
while IFS=$'\t' read -r t libs; do
    [ -n "$t" ] || continue
    for lib in $libs; do
        case "$lib" in
            airy_*|libairy_*|coreloopthree|cognition|svc_*|daemon_*) ;;
            *) continue ;;
        esac
        if printf '%s\n' "$TARGETS" | grep -qx "$lib"; then continue; fi
        if printf '%s\n' "$CMAKE_TARGETS" | grep -qx "$lib"; then continue; fi
        log_err "A4. 未登记项目库：'${lib}'（目标 ${t}）——既非白名单目标亦非 CMake 目标"
        UNREG=$((UNREG + 1))
        note_hard
    done
done <<< "$WL_GOOD"
if [ "$UNREG" -eq 0 ]; then
    log_ok "A4. 值侧项目库全部解析到已知目标（CMake 目标 ${CMAKE_N} 个；外户源根 ${EXT_ROOT_N} 个）"
fi

allowed_set() {  # $1=target -> 该目标允许链接的项目库（空格分隔）
    printf '%s\n' "$WL_GOOD" | awk -F'\t' -v t="$1" '$1 == t { print $2; found = 1 } END { }'
}

###############################################################################
# B. 层界单向（G21，白名单面）
###############################################################################
section "B. Layer boundary one-way (G21, whitelist face)"

B_HITS=0
check_forbid() {  # $1=target $2=forbidden-lib $3=reason
    local t="$1" lib="$2" why="$3"
    local libs; libs="$(allowed_set "$t")"
    case " $libs " in
        *" $lib "*)
            log_err "B. 目标 ${t} 违规链接 ${lib} —— ${why}"
            B_HITS=$((B_HITS + 1)); note_hard ;;
    esac
}

for t in gateway airy_gateway_service gateway_d; do
    check_forbid "$t" airy_coreloopthree "认知引擎只对 think_d 暴露服务面"
    check_forbid "$t" airy_cognition "认知引擎只对 think_d 暴露服务面"
done
for t in airy_cli gateway airy_gateway_service gateway_d; do
    check_forbid "$t" airy_atoms "内核机制只被 daemon 服务面访问（客户端禁链微核心聚合）"
done
if [ "$B_HITS" -eq 0 ]; then
    log_ok "B. gateway 系零 coreloopthree/cognition；客户端零 airy_atoms"
fi

###############################################################################
# C. 跨进程零符号引用（G23）
###############################################################################
section "C. Cross-process zero in-process symbol reference (G23)"

# daemon 服务库全集：直接取自 CMake 目标（命名规范 <name>_service），
# 避免手工枚举与真实目标漂移；own_svc 按 daemon 命名规范 <name>_d ->
# airy_<name>_service 派生，新增 daemon 无需改本脚本（SSoT）。
DAEMON_SVC="$(printf '%s\n' "$CMAKE_TARGETS" | grep -E '^airy_[a-z0-9_]*_service$' | sort -u || true)"

own_svc() {  # $1=daemon 目标 -> 其自身服务库（自持，允许）
    printf 'airy_%s_service' "${1%_d}"
}

is_exempt() {  # $1=target $2=lib -> 0=登记例外（分隔符 | 需转义，否则被 case 当作择一）
    case "$1|$2" in
        tool_d\|airy_llm_service) return 0 ;;
        sched_d\|airy_llm_service) return 0 ;;
        sched_d\|airy_tool_service) return 0 ;;
        think_d\|airy_llm_service) return 0 ;;
        think_d\|airy_tool_service) return 0 ;;
        *) return 1 ;;
    esac
}

C_HITS=0
while IFS=$'\t' read -r t libs; do
    [ -n "$t" ] || continue
    case "$t" in *_d) ;; *) continue ;; esac
    self="$(own_svc "$t")"
    for lib in $libs; do
        [ "$lib" = "$self" ] && continue
        hit=0
        case "$lib" in daemon_*) hit=1 ;; esac
        for svc in $DAEMON_SVC; do
            [ "$lib" = "$svc" ] && hit=1
        done
        [ "$hit" -eq 1 ] || continue
        is_exempt "$t" "$lib" && continue
        log_err "C. daemon ${t} 进程内引用他户符号 ${lib}（跨界调用必须走总线，未登记例外）"
        C_HITS=$((C_HITS + 1)); note_hard
    done
done <<< "$WL_GOOD"
if [ "$C_HITS" -eq 0 ]; then
    log_ok "C. daemon 允许集零跨户服务符号（BUS-only，例外已登记）"
fi

###############################################################################
# D. 层界单向（G21，代码面）：相对 include 反向边
###############################################################################
section "D. Layer boundary one-way (G21, include face)"

layer_rank() {
    case "$1" in
        commons) echo 1 ;;
        atoms) echo 2 ;;
        heapstore) echo 3 ;;
        gateway) echo 4 ;;
        protocols) echo 5 ;;
        daemons) echo 6 ;;
        *) echo 0 ;;
    esac
}

norm_path() {  # $1=绝对路径（可含 .. / .）-> 规整化
    awk -v p="$1" 'BEGIN {
        n = split(p, a, "/"); out = "";
        for (i = 1; i <= n; i++) {
            c = a[i];
            if (c == "" || c == ".") continue;
            if (c == "..") { sub(/\/[^\/]*$/, "", out); continue }
            out = out "/" c;
        }
        if (out == "") out = "/";
        print out;
    }'
}

CAND="$(grep -rnE '#[[:space:]]*include[[:space:]]*"[^"]*\.\./[^"]*"' \
    --include='*.c' --include='*.h' "$AGENTRT" 2>/dev/null \
    | grep -vE '/(tests|third_party|\.git|build)/' || true)"

while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"; rest="${line#*:}"
    ln="${rest%%:*}"; body="${rest#*:}"
    inc="$(printf '%s' "$body" | sed -nE 's/.*#include[[:space:]]*"([^"]*)".*/\1/p')"
    [ -n "$inc" ] || continue
    src_rel="${file#$AGENTRT/}"
    src_layer="${src_rel%%/*}"
    src_rank="$(layer_rank "$src_layer")"
    [ "$src_rank" -gt 0 ] || continue
    dir="${file%/*}"
    abs="$(norm_path "${dir}/${inc}")"
    case "$abs" in "$AGENTRT"/*) ;; *) continue ;; esac
    dst_rel="${abs#$AGENTRT/}"
    dst_layer="${dst_rel%%/*}"
    dst_rank="$(layer_rank "$dst_layer")"
    [ "$dst_rank" -gt 0 ] || continue
    if [ "$src_rank" -lt "$dst_rank" ]; then
        log_err "D. ${src_rel}:${ln} 反向跨层 include → ${dst_layer}（${src_layer} < ${dst_layer}）"
        log_err "     ${inc}"
        D_VIOL=$((D_VIOL + 1))
    fi
done <<< "$CAND"
if [ "$D_VIOL" -eq 0 ]; then
    log_ok "D. 相对 include 零反向跨层边"
fi

###############################################################################
# 结果汇总（A/B/C 零容忍；D 棘轮基线）
###############################################################################
TOTAL=$((HARD + D_VIOL))
section "Layer boundary gate summary"
printf '  白名单目标: %s\n  CMake 目标: %s\n  A/B/C 硬违例: %s\n  D 反向边: %s\n  违例总数: %s\n' \
    "$TARGET_N" "$CMAKE_N" "$HARD" "$D_VIOL" "$TOTAL"

if [ "$HARD" -gt 0 ]; then
    log_err "层界硬违例 ${HARD} 处（G21/G23 零容忍，fail-closed 阻断）"
    exit 1
fi

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    printf '# 0.1.19 G21 reverse-include violation baseline (count)\n%s\n' \
        "$D_VIOL" > "$BASELINE"
    log_info "基线已更新：${D_VIOL}（layer-baseline.txt）"
    exit 0
fi

if [ "$D_VIOL" -eq 0 ]; then
    log_ok "层界门禁通过（层界单向 + 跨进程零符号引用）"
    exit 0
fi

# 此处仅在 D_VIOL > 0 时到达；基线缺失/非法一律视为水位 0（fail-closed），
# 使「删除基线」无法成为绕过门禁的退路。
if [ ! -f "$BASELINE" ]; then
    log_err "基线缺失：${BASELINE}（运行 --update-baseline 播种；当前按水位 0 判定）"
    exit 1
fi
BASE_V="$(grep -v '^#' "$BASELINE" | grep -v '^[[:space:]]*$' | head -n1 | tr -d '[:space:]' || true)"
if ! printf '%s' "$BASE_V" | grep -qE '^[0-9]+$'; then
    log_err "基线值非法：'${BASE_V}'（按水位 0 判定）"
    exit 1
fi

if [ "$D_VIOL" -gt "$BASE_V" ]; then
    log_err "反向边 ${D_VIOL} 超基线 ${BASE_V}（新增层界反向依赖，fail-closed 阻断）"
    exit 1
fi

log_warn "反向边 ${D_VIOL} ≤ 基线 ${BASE_V}（存量水位，未新增）"
exit 2
