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
# 注：tests/ 单独扫描（测试函数允许略高 CCN，但仍受 FAIL/BLOCK 约束）
SCAN_DIRS=(
    "${PROJECT_ROOT}/agentrt/atoms"
    "${PROJECT_ROOT}/agentrt/commons"
    "${PROJECT_ROOT}/agentrt/cupolas"
    "${PROJECT_ROOT}/agentrt/daemons"
    "${PROJECT_ROOT}/agentrt/gateway"
    "${PROJECT_ROOT}/agentrt/heapstore"
    "${PROJECT_ROOT}/agentrt/protocols"
    "${PROJECT_ROOT}/agentrt/sdk"
    "${PROJECT_ROOT}/agentrt/tests"
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
        # lizard 输出含两部分：主函数列表 + Warning 汇总（重复列出违规函数）
        # 用 awk 在 !!!! Warnings 标记处退出，只保留主列表的函数行（含 @）
        # CCN 阈值过滤由脚本自身处理，不依赖 lizard -C 参数
        lizard --sort cyclomatic_complexity "$dir" 2>/dev/null \
            | awk '/!!!! Warnings/{exit} /@/{print}' >> "$tmpfile" || true
    done

    # 解析 lizard 输出
    # lizard 输出格式（6 列）: NLOC CCN token PARAM length location
    # 其中 location = function@start-end@filepath
    while IFS= read -r line; do
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
# 增量检测模式（仅检查新增/修改函数的违规）
#
# 设计依据（CCN_LONG_TAIL_REMEDIATION.md §6.3）：
#   CI 门禁规则针对**新增**函数。已存在的 FAIL 级别函数（CCN 26~50）
#   已纳入长尾治理计划，CI 不阻塞其治理 PR。
#
#   实现：对比基础版本（CCN_BASE_REF）与当前版本的 lizard 输出，
#   只报告基础版本中**不存在**的违规函数（即真正新增的函数）。
#
# 子模块支持：
#   项目采用多层嵌套子模块结构（OpenAirymax → agentrt → atoms/...）。
#   增量检测遍历 SCAN_DIRS，对每个目录找到其 git 仓库根，
#   在该仓库内运行 git diff 获取变更文件，再转回绝对路径扫描。
#
# 环境变量：
#   CCN_BASE_REF  基础引用（默认 HEAD）
#                  - 本地开发：留空使用 HEAD（工作区与 HEAD 的差异）
#                  - CI 环境：设为 origin/main 或目标分支
# ============================================================================
scan_incremental() {
    local provided_files="${1:-}"
    local base_ref="${CCN_BASE_REF:-HEAD}"

    # 收集所有变更文件的绝对路径（支持嵌套子模块）
    local changed_abs=""
    if [ -n "$provided_files" ]; then
        # --files 模式：用户直接提供相对 PROJECT_ROOT 的路径
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            changed_abs="${changed_abs}${PROJECT_ROOT}/${f}"$'\n'
        done <<< "$provided_files"
    elif command -v git &>/dev/null; then
        for dir in "${SCAN_DIRS[@]}"; do
            [ ! -d "$dir" ] && continue
            local repo_root
            repo_root=$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)
            [ -z "$repo_root" ] && continue

            local repo_files=""
            if [ "$base_ref" = "HEAD" ]; then
                # 本地开发：工作区与 HEAD 的差异（含未提交变更）
                repo_files=$(cd "$repo_root" && git diff --name-only --diff-filter=ACMR HEAD 2>/dev/null | grep -E '\.(c|h|cpp|cc)$' || true)
                # 同时纳入未跟踪的新文件（git diff 不显示 untracked）
                repo_files="${repo_files}"$'\n'"$(cd "$repo_root" && git ls-files --others --exclude-standard 2>/dev/null | grep -E '\.(c|h|cpp|cc)$' || true)"
            else
                # CI 环境：与基础分支的三点差异（包含分叉后的所有提交）
                repo_files=$(cd "$repo_root" && git diff --name-only --diff-filter=ACMR "${base_ref}...HEAD" 2>/dev/null | grep -E '\.(c|h|cpp|cc)$' || true)
            fi

            # 将仓库内相对路径转为绝对路径
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                local abs="${repo_root}/${f}"
                [ ! -f "$abs" ] && continue
                changed_abs="${changed_abs}${abs}"$'\n'
            done <<< "$repo_files"
        done
        # 去重
        changed_abs=$(echo "$changed_abs" | sort -u | grep -v '^$' || true)
    fi

    if [ -z "$changed_abs" ]; then
        log_info "无变更的 C/C++ 文件，跳过增量检测"
        exit 0
    fi

    log_info "基础引用: ${base_ref}"
    log_info "增量检测变更文件:"
    echo "$changed_abs" | while IFS= read -r f; do
        [ -n "$f" ] && echo "  ${f#$PROJECT_ROOT/}"
    done

    local warn_count=0
    local fail_count=0
    local block_count=0

    while IFS= read -r abs_path; do
        [ -z "$abs_path" ] && continue
        [ ! -f "$abs_path" ] && continue

        # 确定该文件所属的 git 仓库（用于获取基础版本）
        local file_repo_root
        file_repo_root=$(cd "$(dirname "$abs_path")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)
        local rel_in_repo=""
        if [ -n "$file_repo_root" ]; then
            rel_in_repo="${abs_path#${file_repo_root}/}"
        fi

        # 获取基础版本中该文件已有的函数名集合（用于排除已存在函数）
        local base_funcs=""
        if [ -n "$file_repo_root" ] && [ -n "$rel_in_repo" ]; then
            local base_content
            base_content=$(cd "$file_repo_root" && git show "${base_ref}:${rel_in_repo}" 2>/dev/null || true)
            if [ -n "$base_content" ]; then
                # lizard 不支持 stdin 读取，必须写入临时文件
                local base_tmp
                base_tmp=$(mktemp /tmp/ccn_base_XXXX.c)
                echo "$base_content" > "$base_tmp"
                # 提取第 6 列（funcname@line-range@filepath），取 @ 前的函数名
                base_funcs=$(lizard "$base_tmp" 2>/dev/null \
                             | awk '/!!!! Warnings/{exit} /@/{print}' \
                             | awk '{print $6}' | cut -d'@' -f1 \
                             | sort -u || true)
                rm -f "$base_tmp"
            fi
        fi

        local violations
        # lizard 输出含两部分：主函数列表 + Warning 汇总（重复列出违规函数）
        # 用 awk 在 !!!! Warnings 标记处退出，只保留主列表的函数行（含 @）
        violations=$(lizard "$abs_path" 2>/dev/null | awk '/!!!! Warnings/{exit} /@/{print}' || true)

        if [ -n "$violations" ]; then
            while IFS= read -r line; do
                local ccn
                ccn=$(echo "$line" | awk '{print $2}')
                if [[ "$ccn" =~ ^[0-9]+$ ]] && [ "$ccn" -gt "$CCN_PASS" ]; then
                    local loc_str
                    loc_str=$(echo "$line" | awk '{print $6}')
                    local func_name
                    func_name=$(echo "$loc_str" | cut -d'@' -f1)

                    # 排除基础版本中已存在的函数（已在长尾治理计划中跟踪）
                    if [ -n "$base_funcs" ] && echo "$base_funcs" | grep -qFx "$func_name"; then
                        continue
                    fi

                    local line_range
                    line_range=$(echo "$loc_str" | cut -d'@' -f2)
                    local filepath
                    filepath=$(echo "$loc_str" | cut -d'@' -f3)

                    if [ "$ccn" -gt "$CCN_FAIL" ]; then
                        log_err "NEW BLOCK (CCN=${ccn}): ${func_name}() L${line_range} @ ${filepath}"
                        block_count=$((block_count + 1))
                    elif [ "$ccn" -gt "$CCN_WARN" ]; then
                        log_err "NEW FAIL (CCN=${ccn}): ${func_name}() L${line_range} @ ${filepath}"
                        fail_count=$((fail_count + 1))
                    else
                        log_warn "NEW WARN (CCN=${ccn}): ${func_name}() L${line_range} @ ${filepath}"
                        warn_count=$((warn_count + 1))
                    fi
                fi
            done <<< "$violations"
        fi
    done <<< "$changed_abs"

    echo ""
    section "Incremental Complexity Scan Summary"
    echo -e "  ${COLOR_YELLOW}New WARN (CCN ${CCN_PASS}-${CCN_WARN}):${COLOR_RESET}   ${warn_count}"
    echo -e "  ${COLOR_RED}New FAIL (CCN ${CCN_WARN}-${CCN_FAIL}):${COLOR_RESET}   ${fail_count}"
    echo -e "  ${COLOR_RED}New BLOCK (CCN > ${CCN_FAIL}):${COLOR_RESET}      ${block_count}"
    echo ""

    if [ "$block_count" -gt 0 ]; then
        echo -e "${COLOR_RED}❌ INCREMENTAL COMPLEXITY BLOCK: ${block_count} new function(s) with CCN > ${CCN_FAIL}${COLOR_RESET}"
        exit 1
    elif [ "$fail_count" -gt 0 ]; then
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
                echo "Usage: $0 [--incremental] [--files FILE_LIST] [CCN_BASE_REF=<ref>]"
                echo ""
                echo "Modes:"
                echo "  (default)      全量扫描所有源码（报告模式，展示整体 CCN 状态）"
                echo "  --incremental  增量扫描 git 变更文件，仅报告新增函数的违规"
                echo "  --files LIST   扫描指定文件列表"
                echo ""
                echo "Environment:"
                echo "  CCN_BASE_REF   增量模式的基础引用（默认 HEAD）"
                echo "                  本地开发: 留空，使用 HEAD（工作区与 HEAD 差异）"
                echo "                  CI 环境:  设为 origin/main 或目标分支"
                echo ""
                echo "Thresholds:"
                echo "  PASS  CCN ≤ ${CCN_PASS}"
                echo "  WARN  CCN ${CCN_PASS}-${CCN_WARN}"
                echo "  FAIL  CCN > ${CCN_WARN}"
                echo "  BLOCK CCN > ${CCN_FAIL}"
                echo ""
                echo "Exit Codes:"
                echo "  0  PASS  （无新增违规）"
                echo "  2  WARN  （仅新增 WARN 级别违规，允许合入）"
                echo "  1  FAIL  （新增 FAIL/BLOCK 级别违规，拒绝合入）"
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
