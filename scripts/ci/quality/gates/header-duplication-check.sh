#!/bin/bash
# AgentRT Header Duplication Gate — IRON-6 re-export 规则固化（0.1.9 M0 §1.3bis L4）
#
# 背景：commons/ 与 daemons/common/ 曾出现同名头双写、字节级拷贝、
# include guard 冲突（L2 静默跳过缺陷类）。本门禁在 CI 侧根除再生路径：
#   R1  同名头 re-export：daemons/common/include 与 commons 同名头必须为
#       纯转发或「转发 + 别名宏/helper」，禁止 typedef/extern/函数原型双写
#   R2  guard 全局唯一：commons+daemons 域内任意两头不得共用同一 guard
#   R3  同名 .c 禁止：daemons/common/src 与 commons 不得出现同名实现文件
#   R4  字节级拷贝禁止：域内任意两头内容不得完全相同
# 零基线 fail-closed：现状即全量通过，任何新增违例直接失败。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 脚本位于 tools/scripts/ci/quality/gates/ — 需向上 5 级到达伞仓根
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"

DAEMONS_INC="${AGENTRT}/daemons/common/include"
DAEMONS_SRC="${AGENTRT}/daemons/common/src"
COMMONS_DIR="${AGENTRT}/commons"
DAEMONS_DIR="${AGENTRT}/daemons"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

log_info() { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"; }
log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

VIOLATIONS=0

if [ ! -d "${AGENTRT}" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 2
fi

commons_headers() {
    find "${COMMONS_DIR}" -name '*.h' -not -path '*third_party*' | sort
}

# ============================================================================
# R1: daemons/common/include 与 commons 同名头必须为 re-export（禁双写声明）
# ============================================================================
check_reexport() {
    section "R1: Same-name headers must be re-export shims (IRON-6)"

    local tmp_c tmp_d tmp_dup
    tmp_c=$(mktemp) tmp_d=$(mktemp) tmp_dup=$(mktemp)
    commons_headers | sed 's|.*/||' | sort -u > "${tmp_c}"
    ls "${DAEMONS_INC}"/*.h 2>/dev/null | sed 's|.*/||' | sort > "${tmp_d}"
    comm -12 "${tmp_c}" "${tmp_d}" > "${tmp_dup}"
    rm -f "${tmp_c}" "${tmp_d}"

    local n=0 bad=0 name dh
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        n=$((n+1))
        dh="${DAEMONS_INC}/${name}"

        # 必须含至少一个 #include（转发存在性）
        if ! grep -qE '^[[:space:]]*#include' "${dh}"; then
            log_err "R1: ${name} 无任何 #include，非 re-export 形态"
            bad=$((bad+1)); continue
        fi

        # 双写声明检测：非 '#' 起始的列零 typedef / extern（排除 extern "C"）
        # / 函数原型（以 ';' 结尾且不含 '{'，参数表内无分号与花括号）
        local dup_hits
        dup_hits=$(grep -nE '^[a-zA-Z_].*\btypedef\b|^[a-zA-Z_].*\bextern\b|^[a-zA-Z_][a-zA-Z0-9_ ,*]*\([^;{}]*\)[[:space:]]*;[[:space:]]*$' "${dh}" | grep -v 'extern "C"' || true)
        if [ -n "${dup_hits}" ]; then
            log_err "R1: ${name} 存在双写声明（应仅保留转发/别名宏/helper）:"
            echo "${dup_hits}" | head -5 | while IFS= read -r l; do log_err "      ${l}"; done
            bad=$((bad+1))
        fi
    done < "${tmp_dup}"
    rm -f "${tmp_dup}"

    if [ "${bad}" -eq 0 ]; then
        log_ok "R1: ${n} 个同名头均为合法 re-export/别名宏形态"
    else
        VIOLATIONS=$((VIOLATIONS+bad))
    fi
}

# ============================================================================
# R2: include guard 域内全局唯一（commons + daemons，防 L2 静默跳过复发）
# ============================================================================
check_guard_uniqueness() {
    section "R2: Include guards must be unique (commons + daemons)"

    local tmp_guards
    tmp_guards=$(mktemp)
    find "${COMMONS_DIR}" "${DAEMONS_DIR}" -name '*.h' -not -path '*third_party*' | sort | \
        while IFS= read -r f; do
            g=$(grep -m1 '^#ifndef' "${f}" 2>/dev/null | awk '{print $2}')
            [ -n "${g}" ] && echo "${g}|${f#${PROJECT_ROOT}/}"
        done > "${tmp_guards}"

    local dups bad=0
    dups=$(cut -d'|' -f1 "${tmp_guards}" | sort | uniq -d)
    if [ -n "${dups}" ]; then
        while IFS= read -r g; do
            log_err "R2: guard ${g} 被多个头共用:"
            grep "^${g}|" "${tmp_guards}" | while IFS='|' read -r _ f; do log_err "      ${f}"; done
            bad=$((bad+1))
        done <<< "${dups}"
        VIOLATIONS=$((VIOLATIONS+bad))
    else
        log_ok "R2: $(wc -l < "${tmp_guards}") 个头文件 guard 全局唯一"
    fi
    rm -f "${tmp_guards}"
}

# ============================================================================
# R3: daemons/common/src 与 commons 禁止同名 .c
# ============================================================================
check_no_dup_c() {
    section "R3: No same-name .c between daemons/common/src and commons"

    local tmp_c tmp_d hits
    tmp_c=$(mktemp) tmp_d=$(mktemp)
    find "${COMMONS_DIR}" -name '*.c' | sed 's|.*/||' | sort -u > "${tmp_c}"
    find "${DAEMONS_SRC}" -name '*.c' | sed 's|.*/||' | sort -u > "${tmp_d}"
    hits=$(comm -12 "${tmp_c}" "${tmp_d}" || true)
    rm -f "${tmp_c}" "${tmp_d}"

    if [ -n "${hits}" ]; then
        log_err "R3: 发现同名实现文件（死拷贝风险，见 L1 circuit_breaker.c 案）:"
        echo "${hits}" | while IFS= read -r n; do log_err "      ${n}"; done
        VIOLATIONS=$((VIOLATIONS+1))
    else
        log_ok "R3: 无同名 .c 文件"
    fi
}

# ============================================================================
# R4: 域内禁止字节级相同的头文件拷贝
# ============================================================================
check_no_identical_headers() {
    section "R4: No byte-identical duplicate headers (commons + daemons)"

    local tmp_hash dups bad=0
    tmp_hash=$(mktemp)
    find "${COMMONS_DIR}" "${DAEMONS_DIR}" -name '*.h' -not -path '*third_party*' -exec sha256sum {} \; | \
        sed "s|${PROJECT_ROOT}/||" | sort > "${tmp_hash}"
    dups=$(awk '{print $1}' "${tmp_hash}" | sort | uniq -d)
    if [ -n "${dups}" ]; then
        while IFS= read -r h; do
            log_err "R4: 字节级重复头拷贝:"
            grep "^${h}" "${tmp_hash}" | awk '{$1=""; print "     " $0}' | while IFS= read -r l; do log_err "${l}"; done
            bad=$((bad+1))
        done <<< "${dups}"
        VIOLATIONS=$((VIOLATIONS+bad))
    else
        log_ok "R4: $(wc -l < "${tmp_hash}") 个头文件无字节级重复"
    fi
    rm -f "${tmp_hash}"
}

main() {
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   AgentRT Header Duplication Gate (IRON-6)       ║"
    echo "║   $(date '+%Y-%m-%d %H:%M:%S')                       ║"
    echo "╚══════════════════════════════════════════════════╝"

    check_reexport
    check_guard_uniqueness
    check_no_dup_c
    check_no_identical_headers

    echo ""
    if [ "${VIOLATIONS}" -eq 0 ]; then
        log_ok "HEADER-DUPLICATION GATE PASSED (0 violations)"
        exit 0
    else
        log_err "HEADER-DUPLICATION GATE FAILED (${VIOLATIONS} violation group(s))"
        exit 1
    fi
}

main "$@"
