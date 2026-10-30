#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# contract-version-check.sh — 跨团队合约版本变更检测
# P0.14.5: CI 中配置合约版本变更检测
#
# 功能：
#   1. 检测 contracts/ 下合约文件是否被修改
#   2. 提取合约版本号常量（CONTRACT_*_VERSION）
#   3. 与基线版本对比，检测版本是否被 bump
#   4. 合约内容变更但版本未 bump → CI 失败
#   5. 版本已 bump → 通知受影响团队
#
# 用法：
#   bash scripts/ci/pipeline/validate/contract-version-check.sh [--baseline-branch <branch>]
#   bash scripts/ci/pipeline/validate/contract-version-check.sh --baseline-snapshot <snapshot_file>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
CONTRACTS_DIR=""
GIT_ROOT=""
CONTRACTS_REL=""
BASELINE_BRANCH="main"
BASELINE_SNAPSHOT=""
CI_MODE=false

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[CONTRACT]${NC}   $*"; }
log_ok()    { echo -e "${GREEN}[CONTRACT-OK]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[CONTRACT-WARN]${NC} $*"; }
log_error() { echo -e "${RED}[CONTRACT-ERR]${NC}  $*" >&2; }

###############################################################################
# 参数解析
###############################################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-branch)
            BASELINE_BRANCH="$2"
            shift 2
            ;;
        --baseline-snapshot)
            BASELINE_SNAPSHOT="$2"
            shift 2
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --baseline-branch <branch>   Baseline branch for comparison (default: main)"
            echo "  --baseline-snapshot <file>   Use a saved snapshot file instead of git"
            echo "  --ci                          CI mode: stricter checks, exit 1 on violation"
            echo ""
            echo "Description:"
            echo "  Detects contract file changes and validates version bumps."
            echo "  If a contract file's content changed but the version constant"
            echo "  was not bumped, the check fails."
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

###############################################################################
# 合约 SSoT 宿主解析与版本声明解析（0.1.20 Q3）
#
# 历史实现把宿主硬编码为 <root>/contracts；该目录已不存在，实际合约头
# 随文档仓迁至 docs-closed/agent-workload-dev/06-contracts/。硬编码单路径
# 的直接后果是「目录不存在 → 无变更 → 通过」的空判据，门禁形同虚设。
# 解析器与版本声明解析统一放 lib/contract-sso.sh，与 Gate 5 共用同一份
# 事实源，避免两处判据各自漂移。
###############################################################################
# shellcheck source=lib/contract-sso.sh
source "${SCRIPT_DIR}/lib/contract-sso.sh"

resolve_rc=0
CONTRACTS_DIR=$(csso_root "$PROJECT_ROOT") || resolve_rc=$?
if [[ "$resolve_rc" -eq 1 ]]; then
    log_error "contract directories exist but hold no contract_*.h: empty judgement"
    exit 1
elif [[ "$resolve_rc" -eq 2 ]]; then
    log_info "contract SSoT dataset absent in this tree (NOT JUDGED)"
    exit 2
fi

if GIT_ROOT=$(git -C "$CONTRACTS_DIR" rev-parse --show-toplevel 2>/dev/null); then
    CONTRACTS_REL="${CONTRACTS_DIR#"$GIT_ROOT"}"
    CONTRACTS_REL="${CONTRACTS_REL#/}"
else
    GIT_ROOT=""
fi

###############################################################################
# 合约文件定义
###############################################################################
declare -A CONTRACT_TEAMS=(
    ["contract_A_B.h"]="team-A,team-B"
    ["contract_A_C.h"]="team-A,team-C"
    ["contract_B_C.h"]="team-B,team-C"
)

declare -A CONTRACT_VERSION_MACRO=(
    ["contract_A_B.h"]="CONTRACT_A_B_VERSION"
    ["contract_A_C.h"]="CONTRACT_A_C_VERSION"
    ["contract_B_C.h"]="CONTRACT_B_C_VERSION"
)

###############################################################################
# 版本号提取
#
# 合约头的权威声明形式是语义串（#define CONTRACT_A_B_VERSION "1.0.0"），
# 历史实现只认十六进制 0x00MMmmpp，对本仓现行合约全部取空值，一旦合约
# 真的变更就会拿 0x00000000 与 0x00000000 比对而误报「版本未 bump」。
# 解析统一由 lib/contract-sso.sh 的 csso_ver 完成（语义串/十六进制/数值
# 三元组三形式等价），本脚本不再自带第二份正则。
###############################################################################

###############################################################################
# 主检测逻辑
###############################################################################
VERSION_MISMATCH=0
CHANGED_CONTRACTS=()

log_info "=== AgentRT Contract Version Change Detection ==="
log_info "Contracts dir: ${CONTRACTS_DIR}"
log_info "Baseline ref:  ${BASELINE_BRANCH}"
echo ""

# 获取变更的合约文件
if [[ -n "${BASELINE_SNAPSHOT}" ]]; then
    # 使用快照文件比对
    log_info "Comparing against snapshot: ${BASELINE_SNAPSHOT}"
    if [[ ! -f "${BASELINE_SNAPSHOT}" ]]; then
        log_error "Snapshot file not found: ${BASELINE_SNAPSHOT}"
        exit 1
    fi
    CHANGED_FILES=$(diff <(sort "${BASELINE_SNAPSHOT}") \
        <(find "${CONTRACTS_DIR}" -name "contract_*.h" -type f | sort) 2>/dev/null || true)
else
    # 使用 git diff 比对（仓库根与相对路径均取自合约宿主，禁止假设 cwd）
    if [[ -z "$GIT_ROOT" ]]; then
        log_error "contracts host is not inside a git work tree: cannot judge drift (NOT JUDGED)"
        exit 2
    fi
    # 基线 ref 只解析一次：后续 diff 与基线内容读取共用，避免两处判定
    # 落在不同 ref 上（分支本地/远端并存时曾是隐患）。
    if git -C "$GIT_ROOT" rev-parse --verify "${BASELINE_BRANCH}" >/dev/null 2>&1; then
        BASE_REF="${BASELINE_BRANCH}"
    elif git -C "$GIT_ROOT" rev-parse --verify "origin/${BASELINE_BRANCH}" >/dev/null 2>&1; then
        BASE_REF="origin/${BASELINE_BRANCH}"
    else
        log_error "baseline ref '${BASELINE_BRANCH}' absent in ${GIT_ROOT}: cannot judge drift (NOT JUDGED)"
        exit 2
    fi
    CHANGED_FILES=$(git -C "$GIT_ROOT" diff --name-only "${BASE_REF}" HEAD -- \
        "${CONTRACTS_REL}" 2>/dev/null | grep -E 'contract_[A-Z]_[A-Z]\.h$' || true)
fi

if [[ -z "${CHANGED_FILES}" ]]; then
    log_ok "No contract files changed against baseline (judged: ${CONTRACTS_DIR})"
    exit 0
fi

echo ""
log_info "Changed contract files:"
echo "${CHANGED_FILES}" | while read -r f; do
    [[ -n "$f" ]] && echo "  - $f"
done
echo ""

# 逐文件检查
for contract_file in contract_A_B.h contract_A_C.h contract_B_C.h; do
    filepath="${CONTRACTS_DIR}/${contract_file}"

    if [[ ! -f "$filepath" ]]; then
        log_error "Contract file missing from resolved SSoT: ${contract_file} (fail-closed)"
        exit 1
    fi

    # 检查此文件是否在变更列表中
    if ! echo "${CHANGED_FILES}" | grep -q "${contract_file}"; then
        log_ok "${contract_file}: not changed"
        continue
    fi

    CHANGED_CONTRACTS+=("${contract_file}")

    macro="${CONTRACT_VERSION_MACRO[${contract_file}]}"
    current_ver=$(csso_ver "${macro}" < "$filepath") || {
        log_error "${contract_file}: no canonical version declaration for ${macro} (fail-closed)"
        exit 1
    }

    # 获取基线版本（与变更检测共用 BASE_REF）
    baseline_ver=""
    if [[ -n "${BASELINE_SNAPSHOT}" ]]; then
        baseline_ver=$(grep "^${contract_file}:" "${BASELINE_SNAPSHOT}" 2>/dev/null | \
            head -1 | cut -d: -f2 || true)
    else
        baseline_content=$(git -C "$GIT_ROOT" show \
            "${BASE_REF}:${CONTRACTS_REL}/${contract_file}" 2>/dev/null || true)
        if [[ -n "${baseline_content}" ]]; then
            baseline_ver=$(printf '%s\n' "${baseline_content}" | csso_ver "${macro}" || true)
        fi
    fi
    [[ -n "${baseline_ver}" ]] || baseline_ver="unknown"

    # 检查版本是否被 bump
    if [[ "${current_ver}" == "${baseline_ver}" ]]; then
        # 版本未变更 —— 如果文件内容确实变了（不只是版本号），则报错
        log_error "${contract_file}: VERSION NOT BUMPED!"
        log_error "  Current:  ${current_ver}"
        log_error "  Baseline: ${baseline_ver}"
        log_error "  Teams affected: ${CONTRACT_TEAMS[${contract_file}]}"
        log_error "  ACTION: Bump ${macro} before modifying this contract."
        log_error "  Example: #define ${macro} \"1.0.1\"  /* or _MAJOR/_MINOR/_PATCH */"
        echo ""
        ((VERSION_MISMATCH++)) || true
    else
        # 版本已变更
        log_ok "${contract_file}: VERSION BUMPED"
        log_info "  ${baseline_ver} → ${current_ver}"
        log_info "  Notify teams: ${CONTRACT_TEAMS[${contract_file}]}"
        echo ""

        # CI 模式下输出 GitHub Actions 通知
        if [[ "${CI_MODE}" == "true" ]] && [[ -n "${GITHUB_ACTIONS:-}" ]]; then
            echo "::warning title=Contract Version Changed::${contract_file} version bumped: ${baseline_ver} → ${current_ver}. Affected teams: ${CONTRACT_TEAMS[${contract_file}]}"
        fi
    fi
done

###############################################################################
# 生成合约版本快照（供后续 CI 使用）
###############################################################################
# 快照默认落系统临时目录：不得在源码区或工作区落生成物（铁律 4.7）
SNAPSHOT_FILE="${CI_ARTIFACT_DIR:-${TMPDIR:-/tmp}/agentrt-ci-artifacts}/contract-versions.txt"
mkdir -p "$(dirname "${SNAPSHOT_FILE}")"

echo "# AgentRT Contract Versions Snapshot" > "${SNAPSHOT_FILE}"
echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "${SNAPSHOT_FILE}"

for contract_file in contract_A_B.h contract_A_C.h contract_B_C.h; do
    filepath="${CONTRACTS_DIR}/${contract_file}"
    if [[ -f "$filepath" ]]; then
        macro="${CONTRACT_VERSION_MACRO[${contract_file}]}"
        ver=$(csso_ver "${macro}" < "$filepath") || {
            log_error "${contract_file}: cannot snapshot version (no ${macro} declaration)"
            exit 1
        }
        echo "${contract_file}:${ver}" >> "${SNAPSHOT_FILE}"
    fi
done

log_info "Contract version snapshot saved to: ${SNAPSHOT_FILE}"

###############################################################################
# 报告小结
###############################################################################
echo ""
echo "=== Contract Version Check Summary ==="
echo "Contracts changed:  ${#CHANGED_CONTRACTS[@]}"
echo "Version mismatches: ${VERSION_MISMATCH}"

if [[ "${#CHANGED_CONTRACTS[@]}" -gt 0 ]]; then
    echo ""
    echo "Changed contracts:"
    for c in "${CHANGED_CONTRACTS[@]}"; do
        echo "  - ${c} (teams: ${CONTRACT_TEAMS[${c}]})"
    done
fi

echo ""

if [[ "${VERSION_MISMATCH}" -gt 0 ]]; then
    log_error "${VERSION_MISMATCH} contract(s) changed without version bump!"
    log_error "Policy: Any change to a contract file MUST bump its version constant."

    if [[ "${CI_MODE}" == "true" ]]; then
        log_error "CI MODE: Failing the build."
        exit 1
    else
        log_warn "Local mode: reporting only (use --ci to fail on violation)."
        exit 0
    fi
else
    log_ok "All changed contracts have valid version bumps."
    exit 0
fi