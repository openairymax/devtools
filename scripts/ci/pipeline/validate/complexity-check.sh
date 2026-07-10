#!/bin/bash
# P0.19.6: 圈复杂度 CI 阈值检查脚本
# 使用 lizard v1.23.0 扫描源码圈复杂度
# 阈值: CCN ≤ 15 通过; 16~25 警告; > 25 拒绝; > 50 阻断性拒绝
# 增量检测: PR 中新增/修改函数 CCN > 15 即拒绝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 脚本位于 devtools/scripts/ci/pipeline/validate/ — 需向上 5 级到达项目根目录
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

# ============================================================================
# 配置
# ============================================================================
CCN_PASS=15        # CCN ≤ 15: 通过
CCN_WARN=25        # CCN 16~25: 警告
CCN_FAIL=50        # CCN > 50: 阻断性拒绝

# 颜色输出
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

log_info()  { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err()   { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }

# 检查 lizard 是否安装
if ! command -v lizard &>/dev/null; then
    log_err "lizard 未安装。请运行: pip install lizard"
    exit 2
fi

LIZARD_VERSION=$(lizard --version 2>&1)
log_info "lizard 版本: ${LIZARD_VERSION}"

# 扫描目标目录（排除构建产物和第三方代码）
SCAN_DIRS=(
    "${PROJECT_ROOT}/agentrt/atoms"
    "${PROJECT_ROOT}/agentrt/commons"
    "${PROJECT_ROOT}/agentrt/cupolas"
    "${PROJECT_ROOT}/agentrt/daemons"
    "${PROJECT_ROOT}/agentrt/sdk"
)

# ============================================================================
# 全量扫描模式
# ============================================================================
scan_full() {
    log_info "全量圈复杂度扫描..."
    log_info "阈值: PASS ≤ ${CCN_PASS}, WARN ${CCN_PASS}-${CCN_WARN}, FAIL ${CCN_WARN}-${CCN_FAIL}, BLOCK > ${CCN_FAIL}"

    local warn_count=0
    local fail_count=0
    local block_count=0
    local total_violations=0

    local tmpfile
    tmpfile=$(mktemp)

    for dir in "${SCAN_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            continue
        fi
        lizard -C "${CCN_PASS}" --sort cyclomatic_complexity "$dir" >> "$tmpfile" 2>/dev/null || true
    done

    # 解析 lizard 输出
    # lizard 输出格式（6 列）: NLOC CCN token PARAM length location
    # 其中 location = function@start-end@filepath
    while IFS= read -r line; do
        # 跳过表头和分隔线
        [[ "$line" =~ ^[=\-] ]] && continue
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*NLOC ]] && continue

        # 提取 CCN 值（第 2 列）
        local ccn
        ccn=$(echo "$line" | awk '{print $2}')

        if [[ "$ccn" =~ ^[0-9]+$ ]] && [ "$ccn" -gt "$CCN_PASS" ]; then
            # location 列（第 6 列）格式: function@start-end@filepath
            local loc_str
            loc_str=$(echo "$line" | awk '{print $6}')
            local func_name
            func_name=$(echo "$loc_str" | cut -d'@' -f1)
            local line_range
            line_range=$(echo "$loc_str" | cut -d'@' -f2)
            local filepath
            filepath=$(echo "$loc_str" | cut -d'@' -f3)

            if [ "$ccn" -gt "$CCN_FAIL" ]; then
                log_err "BLOCKING (CCN=${ccn}): ${func_name}() L${line_range} @ ${filepath}"
                block_count=$((block_count + 1))
            elif [ "$ccn" -gt "$CCN_WARN" ]; then
                log_err "FAIL (CCN=${ccn}): ${func_name}() L${line_range} @ ${filepath}"
                fail_count=$((fail_count + 1))
            else
                log_warn "WARN (CCN=${ccn}): ${func_name}() L${line_range} @ ${filepath}"
                warn_count=$((warn_count + 1))
            fi
            total_violations=$((total_violations + 1))
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"

    echo ""
    section "Complexity Scan Summary"
    echo -e "  ${COLOR_YELLOW}Warnings (CCN ${CCN_PASS}-${CCN_WARN}):${COLOR_RESET}  ${warn_count}"
    echo -e "  ${COLOR_RED}Failures (CCN ${CCN_WARN}-${CCN_FAIL}):${COLOR_RESET}  ${fail_count}"
    echo -e "  ${COLOR_RED}Blocking (CCN > ${CCN_FAIL}):${COLOR_RESET}       ${block_count}"
    echo -e "  Total violations:               ${total_violations}"
    echo ""

    if [ "$block_count" -gt 0 ]; then
        echo -e "${COLOR_RED}❌ COMPLEXITY BLOCK: ${block_count} function(s) with CCN > ${CCN_FAIL}${COLOR_RESET}"
        exit 1
    elif [ "$fail_count" -gt 0 ]; then
        echo -e "${COLOR_RED}❌ COMPLEXITY FAIL: ${fail_count} function(s) with CCN > ${CCN_WARN}${COLOR_RESET}"
        exit 1
    elif [ "$warn_count" -gt 0 ]; then
        echo -e "${COLOR_YELLOW}⚠️  COMPLEXITY WARN: ${warn_count} function(s) with CCN > ${CCN_PASS}${COLOR_RESET}"
        exit 2
    else
        echo -e "${COLOR_GREEN}✅ COMPLEXITY PASS: All functions within CCN ≤ ${CCN_PASS}${COLOR_RESET}"
        exit 0
    fi
}

# ============================================================================
# 增量检测模式（仅检查变更文件）
# ============================================================================
scan_incremental() {
    local changed_files="${1:-}"

    if [ -z "$changed_files" ]; then
        # 尝试从 git 获取变更文件
        if command -v git &>/dev/null; then
            changed_files=$(cd "$PROJECT_ROOT" && git diff --name-only --diff-filter=ACMR HEAD 2>/dev/null | grep -E '\.(c|h|cpp|cc)$' || true)
        fi
    fi

    if [ -z "$changed_files" ]; then
        log_info "无变更的 C/C++ 文件，跳过增量检测"
        exit 0
    fi

    log_info "增量检测变更文件:"
    echo "$changed_files" | while IFS= read -r f; do
        echo "  $f"
    done

    local warn_count=0
    local fail_count=0

    while IFS= read -r file; do
        [ -z "$file" ] && continue
        local full_path="${PROJECT_ROOT}/${file}"
        [ ! -f "$full_path" ] && continue

        local violations
        violations=$(lizard -C "$CCN_PASS" "$full_path" 2>/dev/null | tail -n +5 || true)

        if [ -n "$violations" ]; then
            while IFS= read -r line; do
                [[ "$line" =~ ^[=\-] ]] && continue
                [[ -z "$line" ]] && continue
                [[ "$line" =~ ^[[:space:]]*NLOC ]] && continue

                local ccn
                ccn=$(echo "$line" | awk '{print $2}')
                if [[ "$ccn" =~ ^[0-9]+$ ]] && [ "$ccn" -gt "$CCN_PASS" ]; then
                    local loc_str
                    loc_str=$(echo "$line" | awk '{print $6}')
                    local func_name
                    func_name=$(echo "$loc_str" | cut -d'@' -f1)
                    local line_range
                    line_range=$(echo "$loc_str" | cut -d'@' -f2)
                    local filepath
                    filepath=$(echo "$loc_str" | cut -d'@' -f3)

                    if [ "$ccn" -gt "$CCN_WARN" ]; then
                        log_err "NEW FAIL (CCN=${ccn}): ${func_name}() L${line_range} @ ${filepath}"
                        fail_count=$((fail_count + 1))
                    else
                        log_warn "NEW WARN (CCN=${ccn}): ${func_name}() L${line_range} @ ${filepath}"
                        warn_count=$((warn_count + 1))
                    fi
                fi
            done <<< "$violations"
        fi
    done <<< "$changed_files"

    if [ "$fail_count" -gt 0 ]; then
        echo -e "${COLOR_RED}❌ INCREMENTAL COMPLEXITY FAIL: ${fail_count} new function(s) with CCN > ${CCN_WARN}${COLOR_RESET}"
        exit 1
    elif [ "$warn_count" -gt 0 ]; then
        echo -e "${COLOR_YELLOW}⚠️  INCREMENTAL COMPLEXITY WARN: ${warn_count} new function(s) with CCN > ${CCN_PASS}${COLOR_RESET}"
        exit 2
    else
        echo -e "${COLOR_GREEN}✅ INCREMENTAL COMPLEXITY PASS${COLOR_RESET}"
        exit 0
    fi
}

section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

# ============================================================================
# 主函数
# ============================================================================
main() {
    local mode="full"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --incremental)
                mode="incremental"
                shift
                ;;
            --files)
                mode="incremental"
                shift
                scan_incremental "$1"
                exit $?
                ;;
            --help|-h)
                echo "Usage: $0 [--incremental] [--files FILE_LIST]"
                echo ""
                echo "Modes:"
                echo "  (default)     全量扫描所有源码"
                echo "  --incremental  仅扫描 git 变更文件"
                echo "  --files LIST   扫描指定文件列表"
                echo ""
                echo "Thresholds:"
                echo "  PASS  CCN ≤ ${CCN_PASS}"
                echo "  WARN  CCN ${CCN_PASS}-${CCN_WARN}"
                echo "  FAIL  CCN > ${CCN_WARN}"
                echo "  BLOCK CCN > ${CCN_FAIL}"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    section "Complexity Check (lizard v1.23.0)"

    if [ "$mode" = "incremental" ]; then
        scan_incremental
    else
        scan_full
    fi
}

main "$@"
