#!/bin/bash
# 0.1.19 G24 文件行数硬门禁（方案 §0.5 G24：≤ 800 行/文件）
#
# 口径（台账 §0.1；§254a；§254c）：agentrt/ 七模块（atoms commons daemons
#   gateway heapstore protocols tools）+ products/cupolas 产品壳下 *.c + *.h，
#   排除 tests/ 与 third_party/。cupolas 按 §1.3 迁出机制核，§254c 起作为
#   独立根纳入本门禁扫描域（同一 ≤800 上限）。
#   前二者非本仓可维护代码：tests/ 为用例，third_party/ 为上游客供，均不适用
#   本仓可读性上限（G24 的立意是"单文件在生产码中可被一次通读"）。
# 判据：单文件行数 ≤ 800 即 PASS。超限文件须入基线（既有债务），基线外新增
#   超限文件即 FAIL——fail-closed 阻断新债，既有债务随 L4/L5 拆分收敛。
# 基线：g24-file-length-baseline.txt，存量条目相对 agentrt/，产品壳条目相对
#   agent-workload/（products/cupolas/…），双口径并存；
#   收敛后以 --update-baseline 重生成（消失即视为拆分成效）。
# 用法: file-length-check.sh [--update-baseline]
# 退出码: 0 = 通过；1 = 存在基线外超限文件；2 = 环境错误（树/基线缺失）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
AW_ROOT="${PROJECT_ROOT}/agent-workload"
CUPOLAS_DIR="${AW_ROOT}/products/cupolas"
BASELINE="$SCRIPT_DIR/g24-file-length-baseline.txt"

MAX_LINES=800
MODULES=(atoms commons daemons gateway heapstore protocols tools)

UPDATE_BASELINE=0
if [ "${1:-}" = "--update-baseline" ]; then
    UPDATE_BASELINE=1
fi

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

if [ ! -d "$AGENTRT" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 2
fi

if [ ! -d "$CUPOLAS_DIR" ]; then
    log_err "cupolas source tree not found: ${CUPOLAS_DIR}"
    exit 2
fi

# 输出 "相对路径 行数"，仅含超限文件
scan_over_limit() {
    local m d
    for m in "${MODULES[@]}"; do
        d="$AGENTRT/$m"
        if [ ! -d "$d" ]; then
            log_err "module tree missing: ${d}"
            exit 2
        fi
        find "$d" -type f \( -name '*.c' -o -name '*.h' \) \
            | { grep -v '/tests/' || true; } \
            | { grep -v '/third_party/' || true; } \
            | tr '\n' '\0' | xargs -0 -r wc -l 2>/dev/null \
            | awk -v max="$MAX_LINES" -v root="$AGENTRT/" '
                $2 == "total" { next }
                {
                    n = $1; p = $2;
                    if (n > max) { sub("^" root, "", p); printf "%s %d\n", p, n }
                }' || true
    done
    find "$CUPOLAS_DIR" -type f \( -name '*.c' -o -name '*.h' \) \
        | { grep -v '/tests/' || true; } \
        | { grep -v '/third_party/' || true; } \
        | tr '\n' '\0' | xargs -0 -r wc -l 2>/dev/null \
        | awk -v max="$MAX_LINES" -v root="$AW_ROOT/" '
            $2 == "total" { next }
            {
                n = $1; p = $2;
                if (n > max) { sub("^" root, "", p); printf "%s %d\n", p, n }
            }' || true
}

TMP_CUR="$(mktemp)"
trap 'rm -f "$TMP_CUR"' EXIT
scan_over_limit | sort > "$TMP_CUR"

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    awk '{ print $1 }' "$TMP_CUR" | sort -u > "$BASELINE"
    log_info "基线已更新：$(wc -l < "$BASELINE") 个超限文件（g24-file-length-baseline.txt）"
    exit 0
fi

section "0.1.19 G24 file-length gate (ceiling: ${MAX_LINES} lines/file, tests/ + third_party/ excluded)"

if [ ! -f "$BASELINE" ]; then
    log_err "baseline not found: ${BASELINE} (run --update-baseline to seed)"
    exit 2
fi

new_count=0
known_count=0
TMP_NEW="$(mktemp)"
trap 'rm -f "$TMP_CUR" "$TMP_NEW"' EXIT

while read -r path lines; do
    [ -n "$path" ] || continue
    if grep -qxF "$path" "$BASELINE"; then
        known_count=$((known_count + 1))
        log_warn "baseline debt (${lines} lines): ${path}"
    else
        new_count=$((new_count + 1))
        echo "  ${path} (${lines} lines)" >> "$TMP_NEW"
    fi
done < "$TMP_CUR"

# 基线中已不再超限的路径 = 本批次拆分成效
TMP_CURP="$(mktemp)"
trap 'rm -f "$TMP_CUR" "$TMP_NEW" "$TMP_CURP"' EXIT
awk '{ print $1 }' "$TMP_CUR" | sort -u > "$TMP_CURP"
shrunk=0
while IFS= read -r base_path; do
    [ -n "$base_path" ] || continue
    if ! grep -qxF "$base_path" "$TMP_CURP"; then
        shrunk=$((shrunk + 1))
    fi
done < "$BASELINE"

section "0.1.19 G24 file-length gate"

if [ "$new_count" -gt 0 ]; then
    log_err "新增超限文件 ${new_count} 个（基线外，须拆分或更新台账）："
    cat "$TMP_NEW"
    log_err "0.1.19 G24 file-length gate FAILED"
    exit 1
fi

log_ok "无新增超限文件（现存台账债务 ${known_count} 项）"
if [ "$shrunk" -gt 0 ]; then
    log_warn "台账较基线已收敛 ${shrunk} 项（拆分批次后请运行 --update-baseline）"
fi
log_ok "0.1.19 G24 file-length gate PASSED"
exit 0
