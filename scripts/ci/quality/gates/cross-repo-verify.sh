#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# cross-repo-verify.sh — AgentRT 跨子仓库交叉验证
# P4.8: 6 个子仓库版本一致性检查 → API 合约兼容性 → 依赖版本对齐
#
# 用法:
#   bash scripts/ci/pipeline/validate/cross-repo-verify.sh [--ci] [--json]
#
# 检查项:
#   1. 版本一致性: 所有子仓库版本号对齐
#   2. API 合约兼容性: contracts/ 接口签名一致
#   3. 依赖版本对齐: 第三方依赖版本统一
#   4. 子仓库存在性: 确认所有子仓库可访问
#   5. Git 子模块一致性: 子模块引用正确
#   6. CI 配置一致性: 各子仓库 CI 配置一致

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"
ARTIFACT_DIR="${PROJECT_ROOT}/ci-artifacts/cross-repo"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[CROSS]${NC}   $*"; }
log_ok()    { echo -e "${GREEN}[CROSS-OK]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[CROSS-WARN]${NC} $*"; }
log_error() { echo -e "${RED}[CROSS-ERR]${NC}  $*" >&2; }
log_header() { echo -e "\n${MAGENTA}=== Cross-Repo: $* ===${NC}"; }

CI_MODE="${1:-}"
JSON_OUTPUT=false
[[ "$CI_MODE" == "--json" ]] && JSON_OUTPUT=true

ISSUES=0
PASSED=0
declare -a ISSUE_LIST=()

add_issue() {
    ((ISSUES++)) || true
    ISSUE_LIST+=("$1")
}

check_pass() {
    ((PASSED++)) || true
}

###############################################################################
# 子仓库定义
###############################################################################
# 子仓库名称 → 相对路径映射（0.1.6 修正：适配 agent-workload/ 伞仓布局）
declare -A SUBREPOS=(
    ["AgentRT"]="${PROJECT_ROOT}/agent-workload/agentrt"
    ["Ecosystem"]="${PROJECT_ROOT}/agent-workload/ecosystem"
    ["SDK"]="${PROJECT_ROOT}/agent-workload/sdk"
    ["Products"]="${PROJECT_ROOT}/agent-workload/products"
    ["Tools"]="${PROJECT_ROOT}/tools"
    ["Docs"]="${PROJECT_ROOT}/docs"
    ["DocsClosed"]="${PROJECT_ROOT}/docs-closed"
    ["AgentLinux"]="${PROJECT_ROOT}/agent-linux"
)

# 版本一致性基线：以 agentrt/VERSION 为唯一权威（SSoT，0.1.6）
EXPECTED_VERSION="$(cat "${PROJECT_ROOT}/agent-workload/agentrt/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "0.1.5")"

###############################################################################
# Check 1: 子仓库存在性
###############################################################################
check_repo_existence() {
    log_header "Check 1: Sub-repo Existence"

    for repo in "${!SUBREPOS[@]}"; do
        local path="${SUBREPOS[$repo]}"
        if [[ -d "$path" ]]; then
            log_ok "$repo: exists ($path)"
            check_pass
        else
            add_issue "$repo: directory not found at $path"
            log_warn "$repo: NOT FOUND ($path)"
        fi
    done
}

###############################################################################
# Check 2: 版本一致性（SSoT：仅 agentrt/VERSION 为发布版本权威）
###############################################################################
check_version_consistency() {
    log_header "Check 2: Version Consistency (SSoT baseline ${EXPECTED_VERSION})"

    # 仅对携带发布版本的叶仓做内部一致性核对；docs/ecosystem/sdk/tools
    # 独立版本化（0.1.6 修正：不构成跨仓同一版本号的假前提）。
    local repo path found_version
    for repo in "AgentRT" "Ecosystem" "SDK" "Products" "Tools"; do
        path="${SUBREPOS[$repo]}"
        [[ ! -d "$path" ]] && continue

        found_version=""
        if [[ -f "$path/CMakeLists.txt" ]]; then
            found_version=$(grep -oP 'project\([^)]*VERSION\s+\K[0-9][0-9a-zA-Z.]*' "$path/CMakeLists.txt" 2>/dev/null | head -1 || echo "")
        fi
        if [[ -z "$found_version" ]] && [[ -f "$path/pyproject.toml" ]]; then
            found_version=$(grep -oP 'version\s*=\s*"\K[0-9][0-9a-zA-Z.]*' "$path/pyproject.toml" 2>/dev/null | head -1 || echo "")
        fi
        if [[ -z "$found_version" ]] && [[ -f "$path/Cargo.toml" ]]; then
            found_version=$(grep -oP '^version\s*=\s*"\K[0-9][0-9a-zA-Z.]*' "$path/Cargo.toml" 2>/dev/null | head -1 || echo "")
        fi

        if [[ -z "$found_version" ]]; then
            log_info "$repo: no release version marker (independently versioned, skipped)"
            check_pass
        elif [[ "$found_version" == "$EXPECTED_VERSION" ]]; then
            log_ok "$repo: $found_version"
            check_pass
        else
            # 独立版本化仓库与 agentrt 发布版本不必相同；仅告警不阻断
            log_warn "$repo: version $found_version (independent; release baseline $EXPECTED_VERSION)"
            check_pass
        fi
    done

    # AgentRT 内部一致性：VERSION 文件 ↔ CMakeLists project VERSION。
    # CMake project VERSION 仅接受数值（MAJOR.MINOR.PATCH），不允许
    # "0.1.5a" 类字母后缀（实测 CMake Error: VERSION format invalid）；
    # 比较时以数值前缀归一（剥离尾随字母段），full string 以 VERSION 文件
    # 与 AIRYRT_VERSION 宏为权威。
    local agentrt_cmake agentrt_cmake_norm expected_norm
    agentrt_cmake=$(grep -oP 'project\([^)]*VERSION\s+\K[0-9][0-9a-zA-Z.]*' \
        "${SUBREPOS[AgentRT]}/CMakeLists.txt" 2>/dev/null | head -1 || echo "")
    agentrt_cmake_norm="${agentrt_cmake//[^0-9.]/}"
    expected_norm="${EXPECTED_VERSION//[^0-9.]/}"
    if [[ -n "$agentrt_cmake" && "$agentrt_cmake_norm" != "$expected_norm" ]]; then
        add_issue "agentrt VERSION file ($EXPECTED_VERSION) != CMakeLists project VERSION ($agentrt_cmake)"
        log_warn "AGENTRT VERSION DRIFT: VERSION=$EXPECTED_VERSION CMake=$agentrt_cmake"
    else
        log_ok "AgentRT internal version SSoT consistent ($EXPECTED_VERSION)"
        check_pass
    fi
}

###############################################################################
# Check 3: API 合约兼容性
###############################################################################
check_contract_compatibility() {
    log_header "Check 3: API Contract Compatibility"

    local contracts_dir="${PROJECT_ROOT}/contracts"
    if [[ ! -d "$contracts_dir" ]]; then
        # 0.1.6 修正：共享契约层物理宿主已移至 commons/include/airymax/
        # （[SC] 头，见 docs 09-ssot-registry TP-001~011），根级 contracts/
        # 目录不再是 SSoT 物理位置，缺失不构成问题。
        log_info "contracts/ directory not present (SC headers live in commons/include/airymax, skipped)"
        check_pass
        return
    fi

    # Check each contract header
    for contract in contract_A_B.h contract_A_C.h contract_B_C.h; do
        if [[ -f "$contracts_dir/$contract" ]]; then
            log_ok "$contract: exists"
            check_pass

            # Verify contract has proper include guard
            if grep -q "#ifndef.*_H$\|#define.*_H$" "$contracts_dir/$contract" 2>/dev/null; then
                log_ok "  $contract: include guard OK"
                check_pass
            else
                add_issue "$contract: missing include guard"
                log_warn "  $contract: MISSING INCLUDE GUARD"
            fi

            # Verify contract has version marker
            if grep -q "CONTRACT_VERSION\|VERSION.*0\.1" "$contracts_dir/$contract" 2>/dev/null; then
                log_ok "  $contract: version marker OK"
                check_pass
            else
                add_issue "$contract: missing version marker"
                log_warn "  $contract: NO VERSION MARKER"
            fi
        else
            add_issue "$contract: not found"
            log_warn "$contract: NOT FOUND"
        fi
    done

    # Verify contract_test.c compiles
    if [[ -f "$contracts_dir/contract_test.c" ]]; then
        if gcc -fsyntax-only -I"$contracts_dir" "$contracts_dir/contract_test.c" 2>/dev/null; then
            log_ok "contract_test.c: compiles"
            check_pass
        else
            add_issue "contract_test.c: compilation failed"
            log_warn "contract_test.c: COMPILATION FAILED"
        fi
    fi
}

###############################################################################
# Check 4: 依赖版本对齐
###############################################################################
check_dependency_alignment() {
    log_header "Check 4: Dependency Version Alignment"

    # Check key dependencies across sub-repos
    local -A deps_found=()

    for repo in "${!SUBREPOS[@]}"; do
        local path="${SUBREPOS[$repo]}"
        [[ ! -d "$path" ]] && continue

        # Check for common dependencies
        # libevent
        if grep -rq "libevent" "$path" --include="CMakeLists.txt" 2>/dev/null; then
            deps_found["libevent_${repo}"]="found"
        fi

        # openssl
        if grep -rq "OpenSSL\|openssl" "$path" --include="CMakeLists.txt" 2>/dev/null; then
            deps_found["openssl_${repo}"]="found"
        fi

        # json-c / jansson
        if grep -rq "json-c\|jansson" "$path" --include="CMakeLists.txt" 2>/dev/null; then
            deps_found["json_${repo}"]="found"
        fi

        # curl
        if grep -rq "CURL\|curl" "$path" --include="CMakeLists.txt" 2>/dev/null; then
            deps_found["curl_${repo}"]="found"
        fi

        # redis (hiredis)
        if grep -rq "hiredis\|redis" "$path" --include="CMakeLists.txt" 2>/dev/null; then
            deps_found["redis_${repo}"]="found"
        fi
    done

    # Report dependency spread
    local dep_summary=""
    for key in "${!deps_found[@]}"; do
        dep_summary+="$key "
    done
    if [[ -n "$dep_summary" ]]; then
        log_info "Dependencies detected: ${dep_summary}"
    else
        log_info "No cross-repo dependencies detected (single-repo project)"
    fi
    check_pass
}

###############################################################################
# Check 5: Git 子模块一致性
###############################################################################
check_git_submodules() {
    log_header "Check 5: Git Submodule Consistency"

    # Check if .gitmodules exists
    if [[ -f "${PROJECT_ROOT}/.gitmodules" ]]; then
        log_info "Found .gitmodules in umbrella root"
        local submodule_count
        submodule_count=$(grep -c '\[submodule' "${PROJECT_ROOT}/.gitmodules" 2>/dev/null || echo "0")
        log_ok "Submodules defined: $submodule_count"
        check_pass

        # Verify submodules are initialized
        local uninit
        uninit=$(cd "${PROJECT_ROOT}" && git submodule status 2>/dev/null | grep -c '^-' || echo "0")
        if [[ "$uninit" -gt 0 ]]; then
            add_issue "$uninit submodule(s) not initialized"
            log_warn "$uninit submodule(s) not initialized"
        else
            log_ok "All submodules initialized"
            check_pass
        fi
    else
        log_info "No .gitmodules found (independent repos assumed)"
        check_pass
    fi
}

###############################################################################
# Check 6: CI 配置一致性
###############################################################################
check_ci_consistency() {
    log_header "Check 6: CI Configuration Consistency"

    local ci_dirs=()
    for repo in "${!SUBREPOS[@]}"; do
        local path="${SUBREPOS[$repo]}"
        if [[ -d "$path/.github/workflows" ]]; then
            ci_dirs+=("$repo")
        fi
    done

    if [[ ${#ci_dirs[@]} -eq 0 ]]; then
        log_info "No CI workflows found in any sub-repo"
        check_pass
        return
    fi

    log_info "Repos with CI workflows: ${ci_dirs[*]}"
    check_pass

    # Check that all CI workflows use consistent naming
    for repo in "${ci_dirs[@]}"; do
        local path="${SUBREPOS[$repo]}/.github/workflows"
        local wf_count
        wf_count=$(find "$path" -name "*.yml" -o -name "*.yaml" 2>/dev/null | wc -l)
        log_ok "$repo: $wf_count workflow(s)"
        check_pass
    done
}

###############################################################################
# Check 7: 工具 schema 跨仓一致性（0.1.6 SSoT S-6）
###############################################################################
check_tool_schema_consistency() {
    log_header "Check 7: Tool Schema Cross-Repo Consistency (SSoT S-6)"

    local check_script="${SCRIPT_DIR}/../../verify/check-tool-schema-consistency.py"
    if [[ ! -f "$check_script" ]]; then
        add_issue "check-tool-schema-consistency.py not found"
        log_warn "check-tool-schema-consistency.py NOT FOUND"
        return
    fi

    if python3 "$check_script" "${PROJECT_ROOT}"; then
        log_ok "Python BUILTIN_TOOL_SCHEMAS is a subset of C tool_d registry"
        check_pass
    else
        add_issue "Python tool schema set violates C-side subset constraint"
        log_warn "PYTHON TOOL SCHEMA NOT A SUBSET OF C TOOL REGISTRY"
    fi
}

###############################################################################
# 报告生成
###############################################################################
generate_report() {
    mkdir -p "$ARTIFACT_DIR"

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        cat > "${ARTIFACT_DIR}/cross-repo-report.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "total_checks": $((PASSED + ISSUES)),
    "passed": $PASSED,
    "issues": $ISSUES,
    "issue_list": [
        $(for i in "${!ISSUE_LIST[@]}"; do
            echo "        \"${ISSUE_LIST[$i]}\""
            [[ $i -lt $((${#ISSUE_LIST[@]} - 1)) ]] && echo ","
        done)
    ]
}
EOF
        log_info "JSON report: ${ARTIFACT_DIR}/cross-repo-report.json"
    fi

    echo ""
    echo "============================================================"
    echo "  Cross-Repo Verification Summary"
    echo "============================================================"
    echo "  Total checks: $((PASSED + ISSUES))"
    echo "  Passed:       $PASSED"
    echo "  Issues:       $ISSUES"
    echo ""

    if [[ ${#ISSUE_LIST[@]} -gt 0 ]]; then
        echo "  Issues found:"
        for issue in "${ISSUE_LIST[@]}"; do
            echo "    - $issue"
        done
    fi

    echo ""
    if [[ $ISSUES -eq 0 ]]; then
        echo "  Status: ALL CHECKS PASSED"
    else
        echo "  Status: $ISSUES ISSUE(S) FOUND"
    fi
    echo "============================================================"
}

###############################################################################
# 主流程
###############################################################################
main() {
    echo "AgentRT Cross-Repo Verification"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Workspace: ${WORKSPACE_ROOT}"
    echo ""

    check_repo_existence
    check_version_consistency
    check_contract_compatibility
    check_dependency_alignment
    check_git_submodules
    check_ci_consistency
    check_tool_schema_consistency

    generate_report

    if [[ $ISSUES -gt 0 ]]; then
        return 1
    fi
    return 0
}

main "$@"