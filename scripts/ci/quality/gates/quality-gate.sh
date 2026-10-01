#!/bin/bash
# AgentRT Quality Gate - CI/CD 质量门禁
# 集成: 编译检查 · BAN规则扫描 · 安全扫描 · 测试 · 合约验证
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 脚本位于 tools/scripts/ci/quality/gates/ — 需向上 5 级到达伞仓根
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
# 伞仓 agent-workload/ 布局：agentrt 源码树（门禁编译/扫描目标）
AGENTRT_SRC="${PROJECT_ROOT}/agent-workload/agentrt"
SCRIPTS_ROOT="${PROJECT_ROOT}/tools/scripts"

# 质量阈值唯一权威源（SSoT）：复杂度/重复率等策略数据统一由此读取
if [ -f "${SCRIPT_DIR}/../thresholds.conf" ]; then
    # shellcheck source=../thresholds.conf
    source "${SCRIPT_DIR}/../thresholds.conf"
fi

# ============================================================================
# 颜色输出
# ============================================================================
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

GATE_PASS=0
GATE_FAIL=0
GATE_WARN=0
GATE_SKIP=0

log_info()  { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err()   { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
section()   { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

check_gate() {
    local name="$1"
    local result="$2"
    case "$result" in
        0) GATE_PASS=$((GATE_PASS+1)); log_ok "GATE: $name - PASSED" ;;
        2) GATE_WARN=$((GATE_WARN+1)); log_warn "GATE: $name - WARNING" ;;
        *) GATE_FAIL=$((GATE_FAIL+1)); log_err "GATE: $name - FAILED" ;;
    esac
}

print_header() {
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   AgentRT Quality Gate                           ║"
    echo "║   $(date '+%Y-%m-%d %H:%M:%S')                       ║"
    echo "╚══════════════════════════════════════════════════╝"
}

# ============================================================================
# Gate 1: 编译检查 (0e0w)
# ============================================================================
gate_compile() {
    section "Gate 1: Compilation Check"
    # 构建产物一律树外化：严禁在伞仓源码区落任何编译产物（工程铁律 a）。
    # 可用 QUALITY_GATE_BUILD_DIR 覆盖；默认落到系统临时区而非 ${PROJECT_ROOT}。
    local build_dir="${QUALITY_GATE_BUILD_DIR:-${TMPDIR:-/tmp}/agentrt-quality-gate-build}"

    if [ ! -f "${AGENTRT_SRC}/CMakeLists.txt" ]; then
        log_warn "CMakeLists.txt not found, skipping compilation check"
        check_gate "Compile" 2
        return
    fi

    log_info "Out-of-source build dir: ${build_dir}"
    mkdir -p "$build_dir"
    cd "$build_dir"

    if cmake -B . -S "${AGENTRT_SRC}" -DCMAKE_BUILD_TYPE=Debug 2>&1 | tail -5; then
        if cmake --build . 2>&1 | tail -5; then
            check_gate "Compile" 0
        else
            check_gate "Compile" 1
        fi
    else
        check_gate "Compile" 1
    fi
}

# ============================================================================
# Gate 2: BAN 规则扫描 (PATH-BAN + BAN-191/193)
# ============================================================================
gate_ban() {
    section "Gate 2: BAN Rule Scan"

    local ban_script="${SCRIPT_DIR}/../../verify/security/forbidden_functions.sh"
    if [ -x "$ban_script" ]; then
        log_info "Running BAN rule scan..."
        if bash "$ban_script" 2>&1 | tail -10; then
            check_gate "BAN-Rules" 0
        else
            check_gate "BAN-Rules" 1
        fi
    else
        log_warn "BAN scan script not found: ${ban_script}"
        check_gate "BAN-Rules" 2
    fi

    # BAN-191: 禁止 head -z 管道（POSIX 兼容性）
    # 自排除本脚本：其注释/日志必然含该模式的字面文本，否则永远自命中。
    log_info "BAN-191: Scanning for 'head -z' usage..."
    local head_z_found
    head_z_found=$(find "${SCRIPTS_ROOT}" -name "*.sh" ! -name "quality-gate.sh" \
        -exec grep -lP "head\s+-z" {} \; 2>/dev/null || true)
    if [ -n "$head_z_found" ]; then
        log_err "BAN-191: 'head -z' found in:"
        echo "$head_z_found" | while IFS= read -r f; do log_err "  $f"; done
        check_gate "BAN-191" 1
    else
        log_ok "BAN-191: No 'head -z' usage found"
        check_gate "BAN-191" 0
    fi

    # BAN-193: 危险函数扫描必须使用 \b 词边界
    log_info "BAN-193: Scanning for unguarded dangerous function patterns..."
    local dangerous_patterns
    dangerous_patterns=$(find "${SCRIPTS_ROOT}" -name "*.sh" -exec grep -lP 'grep\s+(?!.*\\\\b).*"(strcpy|strcat|sprintf|gets|scanf)"' {} \; 2>/dev/null || true)
    if [ -n "$dangerous_patterns" ]; then
        log_err "BAN-193: Unguarded dangerous function grep found in:"
        echo "$dangerous_patterns" | while IFS= read -r f; do log_err "  $f"; done
        check_gate "BAN-193" 1
    else
        log_ok "BAN-193: No unguarded dangerous function patterns found"
        check_gate "BAN-193" 0
    fi
}

# ============================================================================
# Gate 3: 安全扫描 (P3.21 - 10 项检查)
# ============================================================================
gate_security() {
    section "Gate 3: Security Scan (10 Items)"

    if [ "${SKIP_SECURITY:-0}" = "1" ]; then
        log_warn "Security scan skipped (SKIP_SECURITY=1)"
        check_gate "Security" 2
        return
    fi

    local sec_script="${SCRIPT_DIR}/../../verify/security/security-scan.sh"
    if [ -x "$sec_script" ]; then
        log_info "Running security scan..."
        if bash "$sec_script" "$@" 2>&1 | tail -20; then
            check_gate "Security" 0
        else
            local sec_exit=$?
            if [ $sec_exit -eq 1 ]; then
                log_err "Security scan failed (HIGH+ vulnerabilities or secrets found)"
                check_gate "Security" 1
            else
                check_gate "Security" 2
            fi
        fi
    else
        log_warn "Security scan script not found: ${sec_script}"
        check_gate "Security" 2
    fi
}

# ============================================================================
# Gate 4: 合约版本检查
# ============================================================================
gate_contract() {
    section "Gate 4: Contract Version Check"

    local contract_script="${SCRIPT_DIR}/contract-version-check.sh"
    if [ -x "$contract_script" ]; then
        log_info "Checking contract versions..."
        if bash "$contract_script" 2>&1 | tail -5; then
            check_gate "Contract" 0
        else
            check_gate "Contract" 1
        fi
    else
        log_warn "Contract version check not found"
        check_gate "Contract" 2
    fi
}

# ============================================================================
# Gate 5: 跨子仓库验证 (P4.8)
# ============================================================================
gate_cross_repo() {
    section "Gate 5: Cross-Repository Verification"

    local cross_repo_script="${SCRIPT_DIR}/cross-repo-verify.sh"
    if [ -x "$cross_repo_script" ]; then
        log_info "Running cross-repo verification..."
        if bash "$cross_repo_script" 2>&1 | tail -10; then
            check_gate "CrossRepo" 0
        else
            check_gate "CrossRepo" 1
        fi
    else
        log_warn "Cross-repo verification script not found"
        check_gate "CrossRepo" 2
    fi
}

# ============================================================================
# Gate 6: 圈复杂度检查 (P0.19.6)
# ============================================================================
gate_complexity() {
    section "Gate 6: Complexity Check (lizard, thresholds from thresholds.conf)"

    local complexity_script="${SCRIPT_DIR}/complexity-check.sh"
    if [ -x "$complexity_script" ]; then
        # CI 门禁使用增量模式：仅检查 PR 中新增/修改函数的违规
        # 已有 FAIL 函数在 CCN_LONG_TAIL_REMEDIATION.md 长尾治理计划中跟踪，不阻塞
        # 全量扫描由开发者手动运行: ./complexity-check.sh
        log_info "Running incremental complexity check (CCN_BASE_REF=${CCN_BASE_REF:-HEAD})..."
        if bash "$complexity_script" --incremental 2>&1 | tail -50; then
            check_gate "Complexity" 0
        else
            local cx_exit=$?
            if [ $cx_exit -eq 2 ]; then
                log_warn "Complexity check: new WARN-level functions found (CCN ${CCN_FN_PASS:-15}-${CCN_FN_WARN:-25})"
                check_gate "Complexity" 2
            else
                log_err "Complexity check: new FAIL/BLOCK-level functions found (CCN > ${CCN_FN_WARN:-25})"
                check_gate "Complexity" 1
            fi
        fi
    else
        log_warn "Complexity check script not found: ${complexity_script}"
        check_gate "Complexity" 2
    fi
}

# ============================================================================
# Gate 7: SSoT 技术点权威源校验 (0.1.6 P2-3)
# ============================================================================
gate_ssot() {
    section "Gate 7: SSoT Authority Validation"

    local ssot_script="${SCRIPT_DIR}/../../verify/validate-ssot.py"
    if [ -x "$ssot_script" ] || [ -f "$ssot_script" ]; then
        log_info "Running SSoT authority validation..."
        # 不截断输出：validate-ssot.py 的失败清单走 stderr、[OK] 明细走
        # stdout，管道下二者刷新次序不定，tail 会吃掉失败原因（run #60
        # 即因此只余 [OK] 行、真因不可见）。全量透出以保证可诊断。
        if python3 "$ssot_script" "${PROJECT_ROOT}" 2>&1; then
            check_gate "SSoT-Validate" 0
        else
            check_gate "SSoT-Validate" 1
        fi
    else
        log_warn "SSoT validation script not found: ${ssot_script}"
        check_gate "SSoT-Validate" 2
    fi
}

# ============================================================================
# Gate 8: 头文件重复度检查 (0.1.9 M0 §1.3bis L4, IRON-6 re-export)
# ============================================================================
gate_header_duplication() {
    section "Gate 8: Header Duplication Check (IRON-6 re-export)"

    local hdr_script="${SCRIPT_DIR}/header-duplication-check.sh"
    if [ -x "$hdr_script" ] || [ -f "$hdr_script" ]; then
        log_info "Running header duplication check..."
        if bash "$hdr_script" 2>&1 | tail -20; then
            check_gate "HeaderDup" 0
        else
            check_gate "HeaderDup" 1
        fi
    else
        log_warn "Header duplication script not found: ${hdr_script}"
        check_gate "HeaderDup" 2
    fi
}

# ============================================================================
# Gate 9: coreloopthree ABI 冻结检查 (0.1.9 M3 §4.2-3)
# 退出码: 0=通过 1=违规(阻断) 2=环境错误(告警)
# ============================================================================
gate_abi_frozen() {
    section "Gate 9: ABI Frozen Check (coreloopthree)"

    local abi_script="${SCRIPT_DIR}/abi-frozen-check.sh"
    if [ -x "$abi_script" ] || [ -f "$abi_script" ]; then
        log_info "Running ABI frozen check..."
        if bash "$abi_script" 2>&1 | tail -20; then
            check_gate "ABI-Frozen" 0
        else
            local abi_exit=$?
            if [ $abi_exit -eq 2 ]; then
                log_warn "ABI frozen check: environment error, manual review required"
                check_gate "ABI-Frozen" 2
            else
                check_gate "ABI-Frozen" 1
            fi
        fi
    else
        log_warn "ABI frozen check script not found: ${abi_script}"
        check_gate "ABI-Frozen" 2
    fi
}

# ============================================================================
# Gate 10: corekern 运行时达标检查 (WS-8 8.4.2)
# 从"库在构建内"升级为"运行时调用链证据"：真实拉起 15 daemon + airy_cli，
# 从启动输出取证调用链证据；降级运行（badge=0）一票否决。
# 退出码: 0=通过 1=未达标(阻断) 2=环境错误(告警)
# ============================================================================
gate_corekern_runtime() {
    section "Gate 10: corekern Runtime Check (WS-8 8.4.2)"

    local ckrt_script="${SCRIPT_DIR}/corekern-runtime-check.sh"
    if [ -f "$ckrt_script" ]; then
        # 复用 Gate 1 的树外构建目录（构建产物一律树外化，工程铁律 a）
        local ckrt_build_dir="${QUALITY_GATE_BUILD_DIR:-${TMPDIR:-/tmp}/agentrt-quality-gate-build}"
        log_info "Probing production processes for runtime evidence (build: ${ckrt_build_dir})..."
        local ckrt_out
        if ckrt_out=$(bash "$ckrt_script" --build-dir "$ckrt_build_dir" 2>&1); then
            echo "$ckrt_out" | tail -8
            check_gate "CorekernRuntime" 0
        else
            local ckrt_exit=$?
            echo "$ckrt_out" | tail -15
            if [ $ckrt_exit -eq 2 ]; then
                log_warn "corekern runtime check: build artifacts missing, manual review required"
                check_gate "CorekernRuntime" 2
            else
                check_gate "CorekernRuntime" 1
            fi
        fi
    else
        log_warn "corekern runtime check script not found: ${ckrt_script}"
        check_gate "CorekernRuntime" 2
    fi
}

# ============================================================================
# Gate 11: 函数名长度检查 (M3 0.1.9 §4.2 x-cutting-a)
# 生产函数名 ≤ 20 字节；基线台账 fail-closed（基线外新增名即阻断）。
# 退出码: 0=通过 1=新增超长名(阻断) 2=基线缺失(告警)
# ============================================================================
gate_name_length() {
    section "Gate 11: Function Name Length (<= 20 bytes)"

    local fn_script="${SCRIPT_DIR}/function-name-check.sh"
    if [ -f "$fn_script" ]; then
        log_info "Running function-name length check..."
        local fn_out fn_rc=0
        fn_out=$(bash "$fn_script" 2>&1) || fn_rc=$?
        echo "$fn_out" | tail -12
        if [ "$fn_rc" -eq 0 ]; then
            check_gate "NameLength" 0
        elif [ "$fn_rc" -eq 2 ]; then
            log_warn "function-name check: environment error, manual review required"
            check_gate "NameLength" 2
        else
            check_gate "NameLength" 1
        fi
    else
        log_warn "function-name check script not found: ${fn_script}"
        check_gate "NameLength" 2
    fi
}

# ============================================================================
# Gate 12: daemons LOC 上限检查 (V16.1, ceiling < 9000)
# 口径 src/ + include/（排除 tests/）；超标仅允许带任务号的豁免，且只减不增。
# 退出码: 0=通过 1=存在违例 2=daemons 树缺失(告警)
# ============================================================================
gate_loc_ceiling() {
    section "Gate 12: LOC Ceiling Check (V16.1, < 9000)"

    local loc_script="${SCRIPT_DIR}/loc-ceiling-check.sh"
    if [ -f "$loc_script" ]; then
        log_info "Running V16.1 LOC ceiling check..."
        local loc_out loc_rc=0
        loc_out=$(bash "$loc_script" 2>&1) || loc_rc=$?
        echo "$loc_out" | tail -20
        if [ "$loc_rc" -eq 0 ]; then
            check_gate "LocCeiling" 0
        elif [ "$loc_rc" -eq 2 ]; then
            log_warn "loc-ceiling check: environment error, manual review required"
            check_gate "LocCeiling" 2
        else
            check_gate "LocCeiling" 1
        fi
    else
        log_warn "loc-ceiling check script not found: ${loc_script}"
        check_gate "LocCeiling" 2
    fi
}

# ============================================================================
# Gate 13: 传播面与死信号检查 (V16.13)
# PUBLIC/INTERFACE 段内 src 传播面 + daemons/ __attribute__((unused)) 计数，
# 均走基线台账只减不增。
# 退出码: 0=通过 1=存在违例 2=agentrt 树缺失(告警)
# ============================================================================
gate_propagation() {
    section "Gate 13: Propagation & Dead-Signal Check (V16.13)"

    local prop_script="${SCRIPT_DIR}/propagation-dead-signal-check.sh"
    if [ -f "$prop_script" ]; then
        log_info "Running V16.13 propagation & dead-signal check..."
        local prop_out prop_rc=0
        prop_out=$(bash "$prop_script" 2>&1) || prop_rc=$?
        echo "$prop_out" | tail -20
        if [ "$prop_rc" -eq 0 ]; then
            check_gate "Propagation" 0
        elif [ "$prop_rc" -eq 2 ]; then
            log_warn "propagation check: environment error, manual review required"
            check_gate "Propagation" 2
        else
            check_gate "Propagation" 1
        fi
    else
        log_warn "propagation check script not found: ${prop_script}"
        check_gate "Propagation" 2
    fi
}

# ============================================================================
# Gate 14: 同名头遮蔽检查 (V16.12)
# 同 include 搜索路径内 basename 重复且内容互异 → SHADED（存量台账只减不增）。
# 退出码: 0=通过 1=存在违例 2=agentrt 树缺失(告警)
# ============================================================================
gate_header_shadow() {
    section "Gate 14: Header Shadow Check (V16.12)"

    local shadow_script="${SCRIPT_DIR}/header-shadow-check.sh"
    if [ -f "$shadow_script" ]; then
        log_info "Running V16.12 header-shadow check..."
        local shadow_out shadow_rc=0
        shadow_out=$(bash "$shadow_script" 2>&1) || shadow_rc=$?
        echo "$shadow_out" | tail -20
        if [ "$shadow_rc" -eq 0 ]; then
            check_gate "HeaderShadow" 0
        elif [ "$shadow_rc" -eq 2 ]; then
            log_warn "header-shadow check: environment error, manual review required"
            check_gate "HeaderShadow" 2
        else
            check_gate "HeaderShadow" 1
        fi
    else
        log_warn "header-shadow check script not found: ${shadow_script}"
        check_gate "HeaderShadow" 2
    fi
}

# ============================================================================
# Gate 15: llm_d 适配注册检查 (V16.11)
# A1 注册表存在 / A2 adapters/*.c 零直接 I/O / A3 表驱动完整性。
# 退出码: 0=通过 1=存在违例 2=adapters 目录缺失(告警)
# ============================================================================
gate_adapter_registry() {
    section "Gate 15: Adapter Registry Check (V16.11)"

    local ad_script="${SCRIPT_DIR}/adapter-registry-check.sh"
    if [ -f "$ad_script" ]; then
        log_info "Running V16.11 adapter-registry check..."
        local ad_out ad_rc=0
        ad_out=$(bash "$ad_script" 2>&1) || ad_rc=$?
        echo "$ad_out" | tail -20
        if [ "$ad_rc" -eq 0 ]; then
            check_gate "AdapterRegistry" 0
        elif [ "$ad_rc" -eq 2 ]; then
            log_warn "adapter-registry check: environment error, manual review required"
            check_gate "AdapterRegistry" 2
        else
            check_gate "AdapterRegistry" 1
        fi
    else
        log_warn "adapter-registry check script not found: ${ad_script}"
        check_gate "AdapterRegistry" 2
    fi
}

# ============================================================================
# Gate 16: llm_d 样本形态检查 (V16.10)
# 7 域成形 / src 顶层零裸文件 / include 仅 2 头 / 拆片入度 ≤5 /
# 内层域反向边 = 0 / 装配域反向边入基线只减不增。
# 退出码: 0=通过 1=存在违例 2=llm_d 树缺失(告警)
# ============================================================================
gate_sample_form() {
    section "Gate 16: Sample Form Check (V16.10)"

    local sf_script="${SCRIPT_DIR}/sample-form-check.sh"
    if [ -f "$sf_script" ]; then
        log_info "Running V16.10 sample-form check..."
        local sf_out sf_rc=0
        sf_out=$(bash "$sf_script" 2>&1) || sf_rc=$?
        echo "$sf_out" | tail -20
        if [ "$sf_rc" -eq 0 ]; then
            check_gate "SampleForm" 0
        elif [ "$sf_rc" -eq 2 ]; then
            log_warn "sample-form check: environment error, manual review required"
            check_gate "SampleForm" 2
        else
            check_gate "SampleForm" 1
        fi
    else
        log_warn "sample-form check script not found: ${sf_script}"
        check_gate "SampleForm" 2
    fi
}

# ============================================================================
# Gate 17: 版本一致性检查 (DT-12 SSoT, 0 硬编码)
# VERSION 为唯一权威；C 侧 SSoT 头为漂移免疫 marker；源码/CMake/workflow
# 内零发布号副本。
# 退出码: 0=通过 1=存在违例 2=agentrt 树缺失(告警)
# ============================================================================
gate_version_consistency() {
    section "Gate 17: Version Consistency Check (SSoT, zero-hardcode)"

    local vc_script="${SCRIPT_DIR}/version-consistency-check.sh"
    if [ -f "$vc_script" ]; then
        log_info "Running version-consistency check..."
        local vc_out vc_rc=0
        vc_out=$(bash "$vc_script" 2>&1) || vc_rc=$?
        echo "$vc_out" | tail -20
        if [ "$vc_rc" -eq 0 ]; then
            check_gate "VersionConsistency" 0
        elif [ "$vc_rc" -eq 2 ]; then
            log_warn "version-consistency check: environment error, manual review required"
            check_gate "VersionConsistency" 2
        else
            check_gate "VersionConsistency" 1
        fi
    else
        log_warn "version-consistency check script not found: ${vc_script}"
        check_gate "VersionConsistency" 2
    fi
}

# ============================================================================
# Gate 18: 体积硬门禁 + 里程碑阶梯 (G2 ★, 方案 §0.2)
# agentrt 八模块 *.c+*.h（排除 tests/）+ cmake/ 计数；实测须 ≤ 当前 pin
# 里程碑上限，超出即停线整改。--advance 在达标时推进 pin。
# 退出码: 0=通过 1=超出当前上限 2=树/基线缺失(告警)
# ============================================================================
gate_loc_budget() {
    section "Gate 18: LOC Budget Check (G2, milestone ladder)"

    local lb_script="${SCRIPT_DIR}/loc-budget-check.sh"
    if [ -f "$lb_script" ]; then
        log_info "Running G2 LOC budget check..."
        local lb_out lb_rc=0
        lb_out=$(bash "$lb_script" 2>&1) || lb_rc=$?
        echo "$lb_out" | tail -20
        if [ "$lb_rc" -eq 0 ]; then
            check_gate "LocBudget" 0
        elif [ "$lb_rc" -eq 2 ]; then
            log_warn "loc-budget check: environment error, manual review required"
            check_gate "LocBudget" 2
        else
            check_gate "LocBudget" 1
        fi
    else
        log_warn "loc-budget check script not found: ${lb_script}"
        check_gate "LocBudget" 2
    fi
}

# ============================================================================
# Gate 19: G6 禁桩检查
# 生产码零未竟标记（TODO/FIXME/XXX/HACK/STUB、#if 0），零容忍无基线放宽。
# 退出码: 0=通过 1=存在桩标记 2=环境错误(告警)
# ============================================================================
gate_stub_scan() {
    section "Gate 19: Stub Scan Check (G6, zero-tolerance)"

    local sb_script="${SCRIPT_DIR}/stub-scan-check.sh"
    if [ -f "$sb_script" ]; then
        log_info "Running G6 stub scan check..."
        local sb_out sb_rc=0
        sb_out=$(bash "$sb_script" 2>&1) || sb_rc=$?
        echo "$sb_out" | tail -20
        if [ "$sb_rc" -eq 0 ]; then
            check_gate "StubScan" 0
        elif [ "$sb_rc" -eq 2 ]; then
            log_warn "stub scan check: environment error, manual review required"
            check_gate "StubScan" 2
        else
            check_gate "StubScan" 1
        fi
    else
        log_warn "stub scan check script not found: ${sb_script}"
        check_gate "StubScan" 2
    fi
}

# ============================================================================
# Gate 20: G24 文件行数硬门禁（≤ 800 行/文件，基线棘轮）
# 生产码单文件超限须入基线；基线外新增超限文件即 fail-closed。
# 退出码: 0=通过 1=存在基线外超限文件 2=环境错误(告警)
# ============================================================================
gate_file_length() {
    section "Gate 20: File Length Check (G24, <= 800 lines/file)"

    local fl_script="${SCRIPT_DIR}/file-length-check.sh"
    if [ -f "$fl_script" ]; then
        log_info "Running G24 file-length check..."
        local fl_out fl_rc=0
        fl_out=$(bash "$fl_script" 2>&1) || fl_rc=$?
        echo "$fl_out" | tail -20
        if [ "$fl_rc" -eq 0 ]; then
            check_gate "FileLength" 0
        elif [ "$fl_rc" -eq 2 ]; then
            log_warn "file-length check: environment error, manual review required"
            check_gate "FileLength" 2
        else
            check_gate "FileLength" 1
        fi
    else
        log_warn "file-length check script not found: ${fl_script}"
        check_gate "FileLength" 2
    fi
}

# ============================================================================
# Gate 21: G26 重复率门禁（方案 §6.3：3% ~ 5%，归一化行窗口口径）
# 自建克隆检测器（无外部依赖，三端可移植）；阈值取自 thresholds.conf。
# 退出码: 0=通过 1=超基线(新增重复，阻断) 2=高于目标(告警) 3=环境错误
# ============================================================================
gate_clone() {
    section "Gate 21: Clone/Duplication Check (G26, target <3%, ceiling 5%)"

    local cl_script="${SCRIPT_DIR}/clone-check.sh"
    if [ -f "$cl_script" ]; then
        log_info "Running G26 clone/duplication check..."
        local cl_out cl_rc=0
        cl_out=$(bash "$cl_script" 2>&1) || cl_rc=$?
        echo "$cl_out" | tail -20
        if [ "$cl_rc" -eq 0 ]; then
            check_gate "Clone" 0
        elif [ "$cl_rc" -eq 2 ]; then
            log_warn "clone check: rate above target but within baseline"
            check_gate "Clone" 2
        elif [ "$cl_rc" -eq 3 ]; then
            log_warn "clone check: environment error, manual review required"
            check_gate "Clone" 2
        else
            check_gate "Clone" 1
        fi
    else
        log_warn "clone check script not found: ${cl_script}"
        check_gate "Clone" 2
    fi
}

# ============================================================================
# Gate 22: G5 端口坐标唯一性 + 三面一致性门禁（台账 §四.2 / §五）
# 受辖带 2026-2100：机制面源码禁落带端口字面量（禁双轨）；部署/配置面落带
# 字面量必须登记于 SSoT（airy_defaults.h）；符号引用必须解析到登记表。
# 棘轮基线 port-coord-baseline.txt，只降不升。
# 退出码: 0=通过 1=超基线(新增违例，阻断) 2=高于水位(告警) 3=环境错误
# ============================================================================
gate_port_coord() {
    section "Gate 22: Port Coordinate Uniqueness Check (G5, band 2026-2100)"

    local pc_script="${SCRIPT_DIR}/port-coord-check.sh"
    if [ -f "$pc_script" ]; then
        log_info "Running G5 port coordinate check..."
        local pc_out pc_rc=0
        pc_out=$(bash "$pc_script" 2>&1) || pc_rc=$?
        echo "$pc_out" | tail -20
        if [ "$pc_rc" -eq 0 ]; then
            check_gate "PortCoord" 0
        elif [ "$pc_rc" -eq 2 ]; then
            log_warn "port coord check: violations within baseline (ratchet held)"
            check_gate "PortCoord" 2
        elif [ "$pc_rc" -eq 3 ]; then
            log_warn "port coord check: environment error, manual review required"
            check_gate "PortCoord" 2
        else
            check_gate "PortCoord" 1
        fi
    else
        log_warn "port coord check script not found: ${pc_script}"
        check_gate "PortCoord" 2
    fi
}

# ============================================================================
# 主函数
# ============================================================================
main() {
    local skip_security=false
    local security_only=false
    local skip_cross_repo=false
    local skip_complexity=false
    local skip_corekern_runtime=false
    local skip_name_length=false
    local skip_loc_ceiling=false
    local skip_propagation=false
    local skip_header_shadow=false
    local skip_adapter_registry=false
    local skip_sample_form=false
    local skip_version_consistency=false
    local skip_loc_budget=false
    local skip_stub_scan=false
    local skip_file_length=false
    local skip_clone=false
    local skip_port_coord=false
    local strict_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --security-scan)
                security_only=true
                shift
                ;;
            --skip-security)
                skip_security=true
                shift
                ;;
            --skip-cross-repo)
                skip_cross_repo=true
                shift
                ;;
            --skip-complexity)
                skip_complexity=true
                shift
                ;;
            --skip-corekern-runtime)
                skip_corekern_runtime=true
                shift
                ;;
            --skip-name-length)
                skip_name_length=true
                shift
                ;;
            --skip-loc-ceiling)
                skip_loc_ceiling=true
                shift
                ;;
            --skip-propagation)
                skip_propagation=true
                shift
                ;;
            --skip-header-shadow)
                skip_header_shadow=true
                shift
                ;;
            --skip-adapter-registry)
                skip_adapter_registry=true
                shift
                ;;
            --skip-sample-form)
                skip_sample_form=true
                shift
                ;;
            --skip-version-consistency)
                skip_version_consistency=true
                shift
                ;;
            --skip-loc-budget)
                skip_loc_budget=true
                shift
                ;;
            --skip-stub-scan)
                skip_stub_scan=true
                shift
                ;;
            --skip-file-length)
                skip_file_length=true
                shift
                ;;
            --skip-clone)
                skip_clone=true
                shift
                ;;
            --skip-port-coord)
                skip_port_coord=true
                shift
                ;;
            --strict)
                strict_mode=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--security-scan] [--skip-security] [--skip-cross-repo] [--skip-complexity] [--skip-corekern-runtime] [--skip-name-length] [--skip-loc-ceiling] [--skip-propagation] [--skip-header-shadow] [--skip-adapter-registry] [--skip-sample-form] [--skip-version-consistency] [--skip-loc-budget] [--skip-stub-scan] [--skip-file-length] [--skip-clone] [--skip-port-coord] [--strict]"
                echo ""
                echo "Quality Gates:"
                echo "  1. Compilation Check (0e0w)"
                echo "  2. BAN Rule Scan (256 rules + BAN-191/193)"
                echo "  3. Security Scan (10 items: CVE, SAST, Docker, Secrets, SBOM, ...)"
                echo "  4. Contract Version Check"
                echo "  5. Cross-Repository Verification"
                echo "  6. Complexity Check (lizard, CCN thresholds)"
                echo "  7. SSoT Authority Validation"
                echo "  8. Header Duplication Check (IRON-6 re-export)"
                echo "  9. ABI Frozen Check (coreloopthree)"
                echo "  10. corekern Runtime Check (WS-8 8.4.2)"
                echo "  11. Function Name Length Check (M3, <= 20 bytes)"
                echo "  12. LOC Ceiling Check (V16.1, daemons < 9000)"
                echo "  13. Propagation & Dead-Signal Check (V16.13)"
                echo "  14. Header Shadow Check (V16.12)"
                echo "  15. Adapter Registry Check (V16.11, llm_d)"
                echo "  16. Sample Form Check (V16.10, llm_d)"
                echo "  17. Version Consistency Check (DT-12 SSoT, zero-hardcode)"
                echo "  18. LOC Budget Check (G2, milestone ladder)"
                echo "  19. Stub Scan Check (G6, zero-tolerance)"
                echo "  20. File Length Check (G24, <= 800 lines/file)"
                echo "  21. Clone/Duplication Check (G26, target <3%, ceiling 5%)"
                echo "  22. Port Coordinate Uniqueness Check (G5, band 2026-2100)"
                echo ""
                echo "Options:"
                echo "  --security-scan      Run only security scan"
                echo "  --skip-security       Skip security scan"
                echo "  --skip-cross-repo     Skip cross-repo verification"
                echo "  --skip-complexity     Skip complexity check"
                echo "  --skip-corekern-runtime  Skip corekern runtime evidence check"
                echo "  --skip-name-length    Skip function name length check"
                echo "  --skip-loc-ceiling    Skip daemons LOC ceiling check"
                echo "  --skip-propagation    Skip propagation & dead-signal check"
                echo "  --skip-header-shadow  Skip header shadow check"
                echo "  --skip-adapter-registry  Skip llm_d adapter registry check"
                echo "  --skip-sample-form    Skip llm_d sample form check"
                echo "  --skip-version-consistency  Skip version consistency check (SSoT)"
                echo "  --skip-loc-budget     Skip G2 LOC budget (milestone ladder) check"
                echo "  --skip-stub-scan      Skip G6 stub scan (zero-tolerance) check"
                echo "  --skip-file-length    Skip G24 file-length (<= 800 lines/file) check"
                echo "  --skip-clone          Skip G26 clone/duplication (target <3%) check"
                echo "  --skip-port-coord     Skip G5 port coordinate uniqueness (band 2026-2100) check"
                echo "  --strict              Treat warnings as failures"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    print_header

    if $security_only; then
        gate_security
    else
        gate_compile
        gate_ban
        $skip_security || gate_security
        gate_contract
        $skip_cross_repo || gate_cross_repo
        $skip_complexity || gate_complexity
        gate_ssot
        gate_header_duplication
        gate_abi_frozen
        $skip_corekern_runtime || gate_corekern_runtime
        $skip_name_length || gate_name_length
        $skip_loc_ceiling || gate_loc_ceiling
        $skip_propagation || gate_propagation
        $skip_header_shadow || gate_header_shadow
        $skip_adapter_registry || gate_adapter_registry
        $skip_sample_form || gate_sample_form
        $skip_version_consistency || gate_version_consistency
        $skip_loc_budget || gate_loc_budget
        $skip_stub_scan || gate_stub_scan
        $skip_file_length || gate_file_length
        $skip_clone || gate_clone
        $skip_port_coord || gate_port_coord
    fi

    # 输出结果
    section "Quality Gate Results"
    echo ""
    echo -e "  ${COLOR_GREEN}Passed:${COLOR_RESET}   $GATE_PASS"
    echo -e "  ${COLOR_RED}Failed:${COLOR_RESET}   $GATE_FAIL"
    echo -e "  ${COLOR_YELLOW}Warnings:${COLOR_RESET} $GATE_WARN"
    echo -e "  ${COLOR_YELLOW}Skipped:${COLOR_RESET}  $GATE_SKIP"
    echo ""

    if [ "$GATE_FAIL" -eq 0 ]; then
        if $strict_mode && [ "$GATE_WARN" -gt 0 ]; then
            echo -e "${COLOR_RED}╔══════════════════════════════════════╗${COLOR_RESET}"
            echo -e "${COLOR_RED}║     QUALITY GATE FAILED (STRICT)     ║${COLOR_RESET}"
            echo -e "${COLOR_RED}║     ${GATE_WARN} WARNING(S) TREATED AS FAILURE  ║${COLOR_RESET}"
            echo -e "${COLOR_RED}╚══════════════════════════════════════╝${COLOR_RESET}"
            exit 1
        fi
        echo -e "${COLOR_GREEN}╔══════════════════════════════════════╗${COLOR_RESET}"
        echo -e "${COLOR_GREEN}║     ALL QUALITY GATES PASSED         ║${COLOR_RESET}"
        echo -e "${COLOR_GREEN}╚══════════════════════════════════════╝${COLOR_RESET}"
        exit 0
    else
        echo -e "${COLOR_RED}╔══════════════════════════════════════╗${COLOR_RESET}"
        echo -e "${COLOR_RED}║     QUALITY GATE FAILED              ║${COLOR_RESET}"
        echo -e "${COLOR_RED}║     ${GATE_FAIL} GATE(S) FAILED                   ║${COLOR_RESET}"
        echo -e "${COLOR_RED}╚══════════════════════════════════════╝${COLOR_RESET}"
        exit 1
    fi
}

main "$@"