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
dump_cmake_err() { # <阶段名> <日志>
    log_err "cmake $1 失败，错误摘要（$2）："
    grep -nE "error:|fatal error|CMake Error|Error [0-9]" "$2" | tail -40 || true
    echo "---- 末 40 行 ----"
    tail -40 "$2" || true
}

gate_compile() {
    section "Gate 1: Compilation Check"
    # 构建产物一律树外化：严禁在伞仓源码区落任何编译产物（工程铁律 a）。
    # 可用 QUALITY_GATE_BUILD_DIR 覆盖；默认落到系统临时区而非 ${PROJECT_ROOT}。
    local build_dir="${QUALITY_GATE_BUILD_DIR:-${TMPDIR:-/tmp}/agentrt-quality-gate-build}"

    if [ ! -f "${AGENTRT_SRC}/CMakeLists.txt" ]; then
        log_err "CMakeLists.txt not found: compilation gate cannot judge (fail-closed)"
        check_gate "Compile" 1
        return 1
    fi

    # 产品件根锚点由装配方显式持有（SSoT）：agentrt 的产品探测以
    # CMAKE_CURRENT_SOURCE_DIR 做候选路径算术，在 CI 的 agentrt 符号链接
    # 布局下 ".." 按物理目标解析，三个候选全部落空（cupolas 静默不装配，
    # 进而 safety_guard.h 不可解析）。此处一次性把布局事实解析成显式 -D
    # 锚点，不在 workflow 内复制环境变量形成双副本。
    local _prod_root=""
    if [ -d "${PROJECT_ROOT}/agent-workload/products" ]; then
        _prod_root="${PROJECT_ROOT}/agent-workload/products"
    elif [ -d "${PROJECT_ROOT}/products" ]; then
        _prod_root="${PROJECT_ROOT}/products"
    fi

    local _anchor=""
    local -a _prod_args=()
    if [ -n "${_prod_root}" ]; then
        for _anchor in \
            "CUPOLAS_SRC_DIR:cupolas" \
            "LANG_GW_SRC_DIR:lang_gateway" \
            "COG_SRC_DIR:cognition" \
            "GATEWAY_BIZ_SRC_DIR:gateway_biz"; do
            local _var="${_anchor%%:*}"
            local _dir="${_anchor#*:}"
            if [ -f "${_prod_root}/${_dir}/CMakeLists.txt" ]; then
                _prod_args+=("-D${_var}=${_prod_root}/${_dir}")
            else
                log_err "product CMakeLists.txt not found: ${_prod_root}/${_dir} (fail-closed)"
                check_gate "Compile" 1
                return 1
            fi
        done
        log_info "Products anchors: ${_prod_root} (${#_prod_args[@]} 件)"
    else
        log_err "Products root not found: compilation gate cannot judge product daemons (fail-closed)"
        check_gate "Compile" 1
        return 1
    fi

    log_info "Out-of-source build dir: ${build_dir}"
    mkdir -p "$build_dir"
    cd "$build_dir"

    local _cfg_log="${build_dir}/configure.log"
    local _bld_log="${build_dir}/build.log"
    if cmake -B . -S "${AGENTRT_SRC}" -DCMAKE_BUILD_TYPE=Debug \
        ${_prod_args[@]+"${_prod_args[@]}"} >"${_cfg_log}" 2>&1; then
        tail -5 "${_cfg_log}"
        if cmake --build . >"${_bld_log}" 2>&1; then
            tail -5 "${_bld_log}"
            check_gate "Compile" 0
        else
            dump_cmake_err "build" "${_bld_log}"
            check_gate "Compile" 1
        fi
    else
        dump_cmake_err "configure" "${_cfg_log}"
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
        log_err "BAN scan script not found: ${ban_script}"
        check_gate "BAN-Rules" 1
        return 1
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
        log_err "Security scan skipped (SKIP_SECURITY=1): skip is not a verdict (fail-closed)"
        check_gate "Security" 1
        return 1
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
        log_err "Security scan script not found: ${sec_script}"
        check_gate "Security" 1
        return 1
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
        log_err "Contract version check not found"
        check_gate "Contract" 1
        return 1
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
        log_err "Cross-repo verification script not found"
        check_gate "CrossRepo" 1
        return 1
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
        log_err "Complexity check script not found: ${complexity_script}"
        check_gate "Complexity" 1
        return 1
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
        log_err "SSoT validation script not found: ${ssot_script}"
        check_gate "SSoT-Validate" 1
        return 1
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
        log_err "Header duplication script not found: ${hdr_script}"
        check_gate "HeaderDup" 1
        return 1
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
        log_err "ABI frozen check script not found: ${abi_script}"
        check_gate "ABI-Frozen" 1
        return 1
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
        log_err "corekern runtime check script not found: ${ckrt_script}"
        check_gate "CorekernRuntime" 1
        return 1
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
        log_err "function-name check script not found: ${fn_script}"
        check_gate "NameLength" 1
        return 1
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
        log_err "loc-ceiling check script not found: ${loc_script}"
        check_gate "LocCeiling" 1
        return 1
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
        log_err "propagation check script not found: ${prop_script}"
        check_gate "Propagation" 1
        return 1
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
        log_err "header-shadow check script not found: ${shadow_script}"
        check_gate "HeaderShadow" 1
        return 1
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
        log_err "adapter-registry check script not found: ${ad_script}"
        check_gate "AdapterRegistry" 1
        return 1
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
        log_err "sample-form check script not found: ${sf_script}"
        check_gate "SampleForm" 1
        return 1
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
        log_err "version-consistency check script not found: ${vc_script}"
        check_gate "VersionConsistency" 1
        return 1
    fi
}

# ============================================================================
# Gate 18: 体积硬门禁（三本账数值棘轮，方案 §7.5 / §9 Gate 18）
# 三层分账（台账 §258 裁定，§1.2 丙口径终裁）：账一 机制核 =
# atoms+commons+heapstore+gateway+cmake/；账三 形态面 = daemons+protocols+tools；
# 账三 应用壳 = products/cupolas；账二 products 由产品侧独立预算，不入本门禁。
# 各账 *.c+*.h（排除 tests/ 与 third_party/，再扣空行与整行注释）计 SLOC 有效行；
# 三账各自与 baseline 数值 pin 比较，实测 > pin 即停线整改；target 为里程碑方向约束。
# pin 只降不升，上升由 Gate 41 审计；pin 滞后由 Gate 42 判红。
# 退出码: 0=通过 1=某账超 pin 2=树/基线缺失(告警)
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
        log_err "loc-budget check script not found: ${lb_script}"
        check_gate "LocBudget" 1
        return 1
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
        log_err "stub scan check script not found: ${sb_script}"
        check_gate "StubScan" 1
        return 1
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
        log_err "file-length check script not found: ${fl_script}"
        check_gate "FileLength" 1
        return 1
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
        log_err "clone check script not found: ${cl_script}"
        check_gate "Clone" 1
        return 1
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
        log_err "port coord check script not found: ${pc_script}"
        check_gate "PortCoord" 1
        return 1
    fi
}

# ============================================================================
# Gate 23: G18/G19 机制核策略载荷零容忍门禁（台账 §62 / 方案 §2.6、§6.3）
# 纲领「机制与策略极致分离」：机制核生产码剥离注释后不得出现厂商名 / 产品名，
# 厂商差异一律由生态层以 ops / .manifest 注入（策略数据化）。名表 SSoT 为
# policy-payload-names.txt；棘轮基线 policy-payload-baseline.txt，只降不升。
# 退出码: 0=通过 1=超基线(新增策略载荷，阻断) 2=高于水位(告警) 3=环境错误
# ============================================================================
gate_policy_payload() {
    section "Gate 23: Policy Payload Check (G18/G19, mechanism-core zero vendor names)"

    local pp_script="${SCRIPT_DIR}/policy-payload-check.sh"
    if [ -f "$pp_script" ]; then
        log_info "Running G18/G19 policy payload check..."
        local pp_out pp_rc=0
        pp_out=$(bash "$pp_script" 2>&1) || pp_rc=$?
        echo "$pp_out" | tail -25
        if [ "$pp_rc" -eq 0 ]; then
            check_gate "PolicyPayload" 0
        elif [ "$pp_rc" -eq 2 ]; then
            log_warn "policy payload check: violations within baseline (ratchet held)"
            check_gate "PolicyPayload" 2
        elif [ "$pp_rc" -eq 3 ]; then
            log_warn "policy payload check: environment error, manual review required"
            check_gate "PolicyPayload" 2
        else
            check_gate "PolicyPayload" 1
        fi
    else
        log_err "policy payload check script not found: ${pp_script}"
        check_gate "PolicyPayload" 1
        return 1
    fi
}

# ============================================================================
# Gate 24: G21/G23 层界单向 + 跨进程零符号引用门禁（方案 §6.3 / 架构文档 §7.1）
# 两条不变量：层界单向（不出现反向依赖，G21）；跨进程唯一通道 = IPC / syscall
# （零进程内符号引用，G23）。判据 = 链接图断言（白名单面）+ 相对 include 反
# 向边（代码面）；SSoT 输入为 agentrt/link-whitelist.txt（构建期 linkgate 同源）。
# E 段（0.1.20 P1-10）：corekern binder 为进程内总线，其 API 仅 corekern 自持，
# 且禁止以 ".rpc" 后缀派生通道名（跨进程按名寻址 SSoT = socket 路径）。
# 棘轮基线 layer-baseline.txt，只降不升。
# 退出码: 0=通过 1=硬违例或超基线(阻断) 2=高于水位(告警) 3=环境错误
# ============================================================================
gate_layer() {
    section "Gate 24: Layer Boundary Check (G21/G23 + in-process bus boundary)"

    local lb_script="${SCRIPT_DIR}/layer-check.sh"
    if [ -f "$lb_script" ]; then
        log_info "Running G21/G23 layer boundary check..."
        local lb_out lb_rc=0
        lb_out=$(bash "$lb_script" 2>&1) || lb_rc=$?
        echo "$lb_out" | tail -25
        if [ "$lb_rc" -eq 0 ]; then
            check_gate "LayerBoundary" 0
        elif [ "$lb_rc" -eq 2 ]; then
            log_warn "layer boundary check: violations within baseline (ratchet held)"
            check_gate "LayerBoundary" 2
        elif [ "$lb_rc" -eq 3 ]; then
            log_warn "layer boundary check: environment error, manual review required"
            check_gate "LayerBoundary" 2
        else
            check_gate "LayerBoundary" 1
        fi
    else
        log_err "layer boundary check script not found: ${lb_script}"
        check_gate "LayerBoundary" 1
        return 1
    fi
}

# ============================================================================
# Gate 25: G13 负载扇出门禁（方案 §4.4 拆并三裁决 / 台账 §0.5 · §62）
# 两条不变量：拆后 load ≤ 5（件内部头 src 面扇入）；并后 fan 不增（目标对
# 项目内库的去重扇出）。判据 = 静态链接图 + 头引用分析；SSoT 输入为
# agentrt/link-whitelist.txt（与构建期 linkgate 同源）。阈值 FANIN_MAX 取自
# thresholds.conf，棘轮基线 fanout-baseline.txt 只降不升。
# 退出码: 0=通过 1=硬违例或超基线(阻断) 2=高于水位(告警) 3=环境错误
# ============================================================================
gate_fanout() {
    section "Gate 25: Fan-out Check (G13, load <= 5 + fan ratchet)"

    local fo_script="${SCRIPT_DIR}/fanout-check.sh"
    if [ -f "$fo_script" ]; then
        log_info "Running G13 load/fan-out check..."
        local fo_out fo_rc=0
        fo_out=$(bash "$fo_script" 2>&1) || fo_rc=$?
        echo "$fo_out" | tail -25
        if [ "$fo_rc" -eq 0 ]; then
            check_gate "FanOut" 0
        elif [ "$fo_rc" -eq 2 ]; then
            log_warn "fan-out check: violations within baseline (ratchet held)"
            check_gate "FanOut" 2
        elif [ "$fo_rc" -eq 3 ]; then
            log_warn "fan-out check: environment error, manual review required"
            check_gate "FanOut" 2
        else
            check_gate "FanOut" 1
        fi
    else
        log_err "fan-out check script not found: ${fo_script}"
        check_gate "FanOut" 1
        return 1
    fi
}

# ============================================================================
# Gate 26: G1 功能守恒（公开功能面符号快照双跑）
# 生产码 AIRY_API 公开函数符号集 S 与基线 S0 双向对比：丢失即 fail-closed，
# 新增须以 --update-baseline 显式记账。免构建、确定性、跨平台。
# 退出码: 0=通过 1=公开面变更(丢失/未记账新增) 2=环境错误(告警)
# ============================================================================
gate_symbol_conservation() {
    section "Gate 26: Symbol Conservation Check (G1, public surface)"

    local sc_script="${SCRIPT_DIR}/symbol-conservation-check.sh"
    if [ -f "$sc_script" ]; then
        log_info "Running G1 public-surface symbol conservation check..."
        local sc_out sc_rc=0
        sc_out=$(bash "$sc_script" 2>&1) || sc_rc=$?
        echo "$sc_out" | tail -40
        if [ "$sc_rc" -eq 0 ]; then
            check_gate "SymbolConservation" 0
        elif [ "$sc_rc" -eq 2 ]; then
            log_warn "symbol conservation check: environment error, manual review required"
            check_gate "SymbolConservation" 2
        else
            check_gate "SymbolConservation" 1
        fi
    else
        log_err "symbol conservation check script not found: ${sc_script}"
        check_gate "SymbolConservation" 1
        return 1
    fi
}

# ============================================================================
# Gate 27: 0.1.19 G38 逻辑完备性（五清单）
# 错误路径穷举 / 状态机穷举 / 依赖闭环 / 缺陷—用例映射 / 时序一致性。
# 需要已构建的测试树（QUALITY_GATE_BUILD_DIR）；未提供时告警而非误判通过。
# 退出码: 0=通过 1=逻辑完备性违例 2=环境错误(告警)
# ============================================================================
gate_logic_g38() {
    section "Gate 27: G38 Logic Completeness (0.1.19)"

    # fail-closed（0.1.20 方案 §9.2 / P1-6）：缺脚本与缺构建树均为"无法判断"，
    # 一律映射为红，不得映射为跳过——SKIP 参与全绿加总即假绿（Gate 27 假绿的根因）。
    local g38_script="${SCRIPT_DIR}/g38-logic-gate.sh"
    if [ ! -f "$g38_script" ]; then
        log_err "g38 logic gate script not found: ${g38_script}"
        check_gate "LogicCompleteness" 1
        return 1
    fi

    if [ -z "${QUALITY_GATE_BUILD_DIR:-}" ]; then
        log_err "QUALITY_GATE_BUILD_DIR not set: G38 needs a built test tree"
        check_gate "LogicCompleteness" 1
        return 1
    fi

    log_info "Running G38 five-checklist gate..."
    local g38_out g38_rc=0
    g38_out=$(bash "$g38_script" 2>&1) || g38_rc=$?
    echo "$g38_out" | tail -30
    if [ "$g38_rc" -eq 0 ]; then
        check_gate "LogicCompleteness" 0
    elif [ "$g38_rc" -eq 2 ]; then
        log_warn "g38 logic gate: environment error, manual review required"
        check_gate "LogicCompleteness" 2
    else
        check_gate "LogicCompleteness" 1
    fi
}

# ============================================================================
# Gate 28: 0.1.19 G30 体验门禁（TUI 建设方案 §10.3）
# TUI golden / §6 69 条 / budget 有界 / 主题三级 / 纯投影 / 六域锚点 /
# 命令面带 / 三 venue 共用 command 层 / 单文件行数基线 / 十二机制 golden。
# 退出码: 0=通过 1=判据违例 2=环境告警
# ============================================================================
gate_g30_experience() {
    section "Gate 28: G30 Experience Gate (0.1.19)"

    local g30_script="${SCRIPT_DIR}/g30-experience-gate.sh"
    if [ ! -f "$g30_script" ]; then
        log_err "g30 experience gate script not found: ${g30_script}"
        check_gate "ExperienceG30" 1
        return 1
    fi

    log_info "Running G30 experience gate..."
    local g30_out g30_rc=0
    g30_out=$(bash "$g30_script" 2>&1) || g30_rc=$?
    echo "$g30_out"
    if [ "$g30_rc" -eq 0 ]; then
        check_gate "ExperienceG30" 0
    elif [ "$g30_rc" -eq 2 ]; then
        check_gate "ExperienceG30" 2
    else
        check_gate "ExperienceG30" 1
    fi
}

# ============================================================================
# Gate 29: 0.1.19 G37 性能预算门禁（方案 §3.6.4 / §3.6.6）
# 三档 TTFT 预算 + 本地 GPU SYCL decode >= 35 tok/s；证据只读、禁止估算。
# 退出码: 0=通过 1=性能预算违例 2=环境错误(告警，--strict 视为失败)
# ============================================================================
gate_perf_g37() {
    section "Gate 29: G37 Performance Budget (0.1.19)"

    local g37_script="${SCRIPT_DIR}/g37-perf-budget-gate.sh"
    if [ ! -f "$g37_script" ]; then
        log_err "g37 performance gate script not found: ${g37_script}"
        check_gate "PerfBudgetG37" 1
        return 1
    fi

    log_info "Running G37 performance-budget gate..."
    local g37_out g37_rc=0
    g37_out=$(bash "$g37_script" 2>&1) || g37_rc=$?
    echo "$g37_out"
    if [ "$g37_rc" -eq 0 ]; then
        check_gate "PerfBudgetG37" 0
    elif [ "$g37_rc" -eq 2 ]; then
        log_warn "g37 performance gate: evidence unavailable, manual review required"
        check_gate "PerfBudgetG37" 2
    else
        check_gate "PerfBudgetG37" 1
    fi
}

# ============================================================================
# Gate 30: 0.1.19 G16/G17 全队列户形态计数（方案 §6.3 五件套机械执法）
# resident C daemon 五件套逐户断言 + scripts 户登记断言；户数与入口行数
# 预算取 thresholds.conf SSoT（FORM_DAEMON_COUNT / FORM_MAIN_MAX）。
# 退出码: 0=通过 1=形态违例 2=环境错误(告警，--strict 视为失败)
# ============================================================================
gate_form_count() {
    section "Gate 30: Fleet Form Count G16/G17 (0.1.19)"

    local fc_script="${SCRIPT_DIR}/form-count-check.sh"
    if [ ! -f "$fc_script" ]; then
        log_err "form-count gate script not found: ${fc_script}"
        check_gate "FleetFormCount" 1
        return 1
    fi

    log_info "Running fleet form-count gate..."
    local fc_out fc_rc=0
    fc_out=$(bash "$fc_script" 2>&1) || fc_rc=$?
    echo "$fc_out" | tail -25
    if [ "$fc_rc" -eq 0 ]; then
        check_gate "FleetFormCount" 0
    elif [ "$fc_rc" -eq 2 ]; then
        log_warn "form-count gate: environment error, manual review required"
        check_gate "FleetFormCount" 2
    else
        check_gate "FleetFormCount" 1
    fi
}

# ============================================================================
# Gate 43: 形态面归属（0.1.20 G-W6-1 演化面归属登记机械执法）
# 新增 *_ops_t 必须登记所属形态面；未登记即红。判据与登记表 SSoT：
# facade-attribution.txt；双向闭合检查见 facade-attribution-check.sh。
# fail-closed（§9.2）：缺脚本与门禁自身异常一律映射为红，不得映射为跳过。
# 退出码: 0=通过 1=归属违例/缺脚本/环境错误（一律红）
# ============================================================================
gate_facade_attribution() {
    section "Gate 43: Facade Attribution (0.1.20)"

    local fa_script="${SCRIPT_DIR}/facade-attribution-check.sh"
    if [ ! -f "$fa_script" ]; then
        log_err "facade-attribution gate script not found: ${fa_script}"
        check_gate "FacadeAttribution" 1
        return 1
    fi

    log_info "Running facade-attribution gate..."
    local fa_out fa_rc=0
    fa_out=$(bash "$fa_script" 2>&1) || fa_rc=$?
    echo "$fa_out" | tail -20
    if [ "$fa_rc" -eq 0 ]; then
        check_gate "FacadeAttribution" 0
    else
        # 环境错误（rc=2）与归属违例（rc=1）同罪：无法判断时按失败处理
        log_err "facade-attribution gate failed (rc=${fa_rc})"
        check_gate "FacadeAttribution" 1
        return 1
    fi
}

# ============================================================================
# Gate 41: 棘轮漂移审计（0.1.20 §4.2 A4 / §9 Gate 41）
# 审计 v16-loc-budget-baseline.txt 的 pin 历史：只降不升，
# 上升 commit 必须带 RATCHET-JUSTIFY: 行，锚点前豁免。
# fail-closed（§9.2）：缺脚本与审计自身异常一律映射为红。
# 退出码: 0=通过 1=棘轮漂移违例/缺脚本/环境错误（一律红）
# ============================================================================
gate_ratchet() {
    section "Gate 41: Ratchet Drift Audit (0.1.20)"

    local ra_script="${SCRIPT_DIR}/g41-ratchet-audit.sh"
    if [ ! -f "$ra_script" ]; then
        log_err "ratchet audit script not found: ${ra_script}"
        check_gate "RatchetDrift" 1
        return 1
    fi

    log_info "Running ratchet drift audit..."
    local ra_out ra_rc=0
    ra_out=$(bash "$ra_script" 2>&1) || ra_rc=$?
    echo "$ra_out" | tail -20
    if [ "$ra_rc" -eq 0 ]; then
        check_gate "RatchetDrift" 0
    else
        # 环境错误（rc=2）与漂移违例（rc=1）同罪：无法判断时按失败处理
        log_err "ratchet audit gate failed (rc=${ra_rc})"
        check_gate "RatchetDrift" 1
        return 1
    fi
}

# ============================================================================
# Gate 42: 账本三表一致（0.1.20 §9 Gate 42 / §4.2 A5）
# 判据：三表加总 == baseline 记录值，差异必须为 0。
#   Gate 18 判「不得超过」（允许 pin 滞后），Gate 42 判「不许滞后」：pin 与代码
#   必须逐数对齐，减重后须 --converge 落账，否则账本不再是代码的真实体量。
# fail-closed（§9.2）：缺脚本与审计自身异常一律映射为红。
# 退出码: 0=通过 1=差异非零/缺脚本/环境错误（一律红）
# ============================================================================
gate_ledger() {
    section "Gate 42: Ledger Consistency (0.1.20)"

    local lg_script="${SCRIPT_DIR}/g42-ledger-consistency.sh"
    if [ ! -f "$lg_script" ]; then
        log_err "ledger consistency script not found: ${lg_script}"
        check_gate "LedgerConsistency" 1
        return 1
    fi

    log_info "Running ledger consistency audit..."
    local lg_out lg_rc=0
    lg_out=$(bash "$lg_script" 2>&1) || lg_rc=$?
    echo "$lg_out" | tail -20
    if [ "$lg_rc" -eq 0 ]; then
        check_gate "LedgerConsistency" 0
    else
        # 环境错误（rc=2）与差异违例（rc=1）同罪：无法判断时按失败处理
        log_err "ledger consistency gate failed (rc=${lg_rc})"
        check_gate "LedgerConsistency" 1
        return 1
    fi
}

# ============================================================================
# Gate 44: 元门禁审计（0.1.20 §9 Gate 44，门禁审计门禁）
# selfcheck/gate-44.sh 静态审计全部 gate_* 函数的 fail-closed 不变量：
# R1=无法判定消息后无 check_gate 红映射；R2=窗口内无任何判定（静默降级）。
# 缺 selfcheck 脚本 = 审计器失明 = 元门禁失效，一律红。
# 退出码: 0=通过 1=审计违例/缺脚本/环境错误（一律红）
# ============================================================================
gate_meta_failclosed() {
    section "Gate 44: Meta Fail-Closed Audit (0.1.20)"

    local mf_script="${SCRIPT_DIR}/selfcheck/gate-44.sh"
    if [ ! -f "$mf_script" ]; then
        log_err "meta fail-closed selfcheck not found: ${mf_script}"
        check_gate "MetaFailClosed" 1
        return 1
    fi

    log_info "Running meta fail-closed audit..."
    local mf_out mf_rc=0
    mf_out=$(bash "$mf_script" 2>&1) || mf_rc=$?
    echo "$mf_out" | tail -20
    if [ "$mf_rc" -eq 0 ]; then
        check_gate "MetaFailClosed" 0
    else
        # 环境错误与审计违例同罪：无法判断时按失败处理
        log_err "meta fail-closed audit failed (rc=${mf_rc})"
        check_gate "MetaFailClosed" 1
        return 1
    fi
}

# ============================================================================
# Gate 45: 文档-代码一致性（0.1.20 §9.1.1，本文档自指门禁）
# doc-consistency-check.sh 审计活跃 SSoT 文档的 file:line 引用可复现性
# （±3 行窗口，EV-2）+ 证据文件非空（§8.7）+ 四级指针归拢（Q13）。
# fail-closed：缺脚本/清单缺席/受辖文档缺席一律红。
# 退出码: 0=通过 1=违例/环境错误（一律红）
# ============================================================================
gate_doc_consistency() {
    section "Gate 45: Doc-Code Consistency (0.1.20)"

    local dc_script="${SCRIPT_DIR}/doc-consistency-check.sh"
    if [ ! -f "$dc_script" ]; then
        log_err "doc-consistency gate script not found: ${dc_script}"
        check_gate "DocConsistency" 1
        return 1
    fi

    log_info "Running doc-code consistency audit..."
    local dc_out dc_rc=0
    dc_out=$(bash "$dc_script" 2>&1) || dc_rc=$?
    echo "$dc_out" | tail -20
    if [ "$dc_rc" -eq 0 ]; then
        check_gate "DocConsistency" 0
    else
        # 环境错误（rc=2）与违例（rc=1）同罪：无法判断时按失败处理
        log_err "doc-consistency audit failed (rc=${dc_rc})"
        check_gate "DocConsistency" 1
        return 1
    fi
}

# ============================================================================
# Gate 36: 三终态完备（0.1.20 §9.1 Gate 36 / §3.7l，C7 收口）
# 成功 / 失败 / 未知三态各有构造用例；未知态不得并入成功；用例须注册
# 且入构建目标；机制面事件须携带 stats.status。封闭世界：新增终态未分类
# 即红。fail-closed：缺件/异常一律红，不出 WARN。
# 退出码: 0=通过 1=违例/环境错误（一律红）
# ============================================================================
gate_terminal36() {
    section "Gate 36: Terminal-State Completeness (0.1.20)"

    local t36_script="${SCRIPT_DIR}/g36-terminal-gate.sh"
    if [ ! -f "$t36_script" ]; then
        log_err "terminal-state gate script not found: ${t36_script}"
        check_gate "Terminal36" 1
        return 1
    fi

    log_info "Running terminal-state completeness audit..."
    local t36_out t36_rc=0
    t36_out=$(bash "$t36_script" 2>&1) || t36_rc=$?
    echo "$t36_out" | tail -12
    if [ "$t36_rc" -eq 0 ]; then
        check_gate "Terminal36" 0
    else
        log_err "terminal-state audit failed (rc=${t36_rc})"
        check_gate "Terminal36" 1
        return 1
    fi
}

# ============================================================================
# Gate 37: 计费热路径两臂门禁（0.1.20 §3.7l / §9.1.2，B3 收口）
# 七条臂：单同步点 / 窗口 SSoT / 请求路径形态 / 测量臂在位 / 收尾隔离 /
# 两臂证据 / p99 增量。证据只读：bench 实测 fsync 次数不得由门禁估算。
# fail-closed（§9.2）：缺脚本/缺构建树/证据不可解析一律红，不出 WARN。
# 退出码: 0=通过 1=违例/环境错误（一律红）
# ============================================================================
gate_cost37() {
    section "Gate 37: Cost Hot-Path Two-Arm (0.1.20)"

    local c37_script="${SCRIPT_DIR}/g37-cost-hotpath-gate.sh"
    if [ ! -f "$c37_script" ]; then
        log_err "cost hot-path gate script not found: ${c37_script}"
        check_gate "CostHotpath37" 1
        return 1
    fi

    log_info "Running cost hot-path two-arm audit..."
    local c37_out c37_rc=0
    c37_out=$(bash "$c37_script" 2>&1) || c37_rc=$?
    echo "$c37_out" | tail -20
    if [ "$c37_rc" -eq 0 ]; then
        check_gate "CostHotpath37" 0
    else
        log_err "cost hot-path audit failed (rc=${c37_rc})"
        check_gate "CostHotpath37" 1
        return 1
    fi
}

# ============================================================================
# Gate 31: 验证器隔离（0.1.20 §9.1 Gate 31 / §3.7l 第三表第 5 项）
# 五臂：实现面/契约面 include 词根干净、确定性链单 TU 出树对象的 nm -u
# 零 S2/LLM 符号、六入口定义在位（防空壳）、入口定义唯一（防双实现）。
# 运行一侧的判据：单 TU 可独立成对象，即该链的外部契约真实为「零生成面
# 依赖」。构建一律出树（mktemp），源码区零产物。
# fail-closed：缺脚本/缺工具链/缺受审件/编译失败一律红，不出 WARN。
# 退出码: 0=通过 1=违例/环境错误（一律红）
# ============================================================================
gate_verifier31() {
    section "Gate 31: Verifier Isolation (0.1.20)"

    local g31_script="${SCRIPT_DIR}/g31-verifier-isolation.sh"
    if [ ! -f "$g31_script" ]; then
        log_err "verifier isolation gate script not found: ${g31_script}"
        check_gate "Isolation31" 1
        return 1
    fi

    log_info "Running verifier isolation audit..."
    local g31_out g31_rc=0
    g31_out=$(bash "$g31_script" 2>&1) || g31_rc=$?
    echo "$g31_out" | tail -14
    if [ "$g31_rc" -eq 0 ]; then
        check_gate "Isolation31" 0
    else
        log_err "verifier isolation audit failed (rc=${g31_rc})"
        check_gate "Isolation31" 1
        return 1
    fi
}

# ============================================================================
# Gate 33: 裁决往返（0.1.20 §9.1 Gate 33，C 面）
# 静态四臂（写出侧在场 / 规范形定序 / 空值省键 / 出参契约）+ 用例两臂
# （100 次迭代与字节比对写在源码里 / 已注册进构建）+ 运行臂（构建树中
# cognition_grad_tests 真实通过）。静态臂守判据未被写弱，运行臂守判据
# 此刻成立。fail-closed：缺脚本/缺构建树/缺受审文件一律红。
# 退出码: 0=通过 1=违例/环境错误（一律红）
# ============================================================================
gate_roundtrip33() {
    section "Gate 33: Verdict Roundtrip (0.1.20)"

    local g33_script="${SCRIPT_DIR}/g33-verdict-roundtrip.sh"
    if [ ! -f "$g33_script" ]; then
        log_err "verdict roundtrip gate script not found: ${g33_script}"
        check_gate "Verdict33" 1
        return 1
    fi

    log_info "Running verdict roundtrip audit..."
    local g33_out g33_rc=0
    g33_out=$(bash "$g33_script" 2>&1) || g33_rc=$?
    echo "$g33_out" | tail -14
    if [ "$g33_rc" -eq 0 ]; then
        check_gate "Verdict33" 0
    else
        log_err "verdict roundtrip audit failed (rc=${g33_rc})"
        check_gate "Verdict33" 1
        return 1
    fi
}

# ============================================================================
# Gate 32: 违规优先级（0.1.20 §9.1 Gate 32，C 面）
# 两层取证：单一真相（grad_err_rank 唯一定义、被流水线唯一消费、无内联梯）
# + 梯序定死（E-02 > E-05 > E-01 > E-03 > E-04）+ 用例两臂（10 组两两组合与
# 边界写在源码里 / 已注册进构建）+ 运行臂（cognition_grad_tests 真实通过）。
# 判「表」而非「流水线」：E-02 命中即早退，冲突位图在真实流水线不可发生。
# 退出码: 0=通过 1=违例/环境错误（一律红）
# ============================================================================
gate_priority32() {
    section "Gate 32: Violation Priority (0.1.20)"

    local g32_script="${SCRIPT_DIR}/g32-priority-order.sh"
    if [ ! -f "$g32_script" ]; then
        log_err "violation priority gate script not found: ${g32_script}"
        check_gate "Rank32" 1
        return 1
    fi

    log_info "Running violation priority audit..."
    local g32_out g32_rc=0
    g32_out=$(bash "$g32_script" 2>&1) || g32_rc=$?
    echo "$g32_out" | tail -14
    if [ "$g32_rc" -eq 0 ]; then
        check_gate "Rank32" 0
    else
        log_err "violation priority audit failed (rc=${g32_rc})"
        check_gate "Rank32" 1
        return 1
    fi
}

# ============================================================================
# Gate 34: 非法计划 schema 拒绝（0.1.20 §9.1 Gate 34，C1 面）
# 12 类拒绝原因码逐类取证：每码在实现中有定位写入、定位后立即拒绝（不得静默
# 修复）、非对象节点单独定位；用例逐行断言 field+reason 双定位并注册进构建。
# 退出码: 0=通过 1=违例/环境错误（一律红）
# ============================================================================
gate_plan34() {
    section "Gate 34: Plan Schema Rejection (0.1.20)"

    local g34_script="${SCRIPT_DIR}/g34-plan-schema-reject.sh"
    if [ ! -f "$g34_script" ]; then
        log_err "plan schema rejection gate script not found: ${g34_script}"
        check_gate "Schema34" 1
        return 1
    fi

    log_info "Running plan schema rejection audit..."
    local g34_out g34_rc=0
    g34_out=$(bash "$g34_script" 2>&1) || g34_rc=$?
    echo "$g34_out" | tail -14
    if [ "$g34_rc" -eq 0 ]; then
        check_gate "Schema34" 0
    else
        log_err "plan schema rejection audit failed (rc=${g34_rc})"
        check_gate "Schema34" 1
        return 1
    fi
}

# ============================================================================
# Gate 35: 部分失败语义（0.1.20 §9.1 Gate 35，C8 面）
# 七臂：阶段域完备（8 值封闭世界）/ 生产者可达（7 个非 NONE 阶段均有赋值 +
# 出口未收敛兜底申报 loop）/ 组合与阶段覆盖（≥5 组合、≥4 阶段）/ 三元组齐备
# （返回码 + status + stage 同例断言）/ 用例在位 / 归因可观测（事件 + trace
# 双路）/ 运行臂。静态臂守判据未被写弱，运行臂守判据此刻成立。
# fail-closed：缺脚本/缺构建树/缺受审文件一律红。
# 退出码: 0=通过 1=违例/环境错误（一律红）
# ============================================================================
gate_partial35() {
    section "Gate 35: Partial-Failure Semantics (0.1.20)"

    local g35_script="${SCRIPT_DIR}/g35-partial-failure.sh"
    if [ ! -f "$g35_script" ]; then
        log_err "partial-failure gate script not found: ${g35_script}"
        check_gate "Partial35" 1
        return 1
    fi

    log_info "Running partial-failure semantics audit..."
    local g35_out g35_rc=0
    g35_out=$(bash "$g35_script" 2>&1) || g35_rc=$?
    echo "$g35_out" | tail -16
    if [ "$g35_rc" -eq 0 ]; then
        check_gate "Partial35" 0
    else
        log_err "partial-failure semantics audit failed (rc=${g35_rc})"
        check_gate "Partial35" 1
        return 1
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
    local skip_form_count=false
    local skip_version_consistency=false
    local skip_loc_budget=false
    local skip_stub_scan=false
    local skip_file_length=false
    local skip_clone=false
    local skip_port_coord=false
    local skip_policy_payload=false
    local skip_layer=false
    local skip_fanout=false
    local skip_symbol=false
    local skip_logic_g38=false
    local skip_g30=false
    local skip_g37=false
    local skip_facade=false
    local skip_ratchet=false
    local skip_g42=false
    local skip_meta44=false
    local skip_doc45=false
    local skip_t36=false
    local skip_hotpath=false
    local skip_g33=false
    local skip_g32=false
    local skip_g34=false
    local skip_g35=false
    local skip_g31=false
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
                ;;
            --skip-form-count)
                skip_form_count=true
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
            --skip-policy-payload)
                skip_policy_payload=true
                shift
                ;;
            --skip-layer)
                skip_layer=true
                shift
                ;;
            --skip-fanout)
                skip_fanout=true
                shift
                ;;
            --skip-symbol)
                skip_symbol=true
                shift
                ;;
            --skip-logic-g38)
                skip_logic_g38=true
                shift
                ;;
            --skip-g30)
                skip_g30=true
                shift
                ;;
            --skip-g37)
                skip_g37=true
                shift
                ;;
            --skip-facade)
                skip_facade=true
                shift
                ;;
            --skip-ratchet)
                skip_ratchet=true
                shift
                ;;
            --skip-g42)
                skip_g42=true
                shift
                ;;
            --skip-meta44)
                skip_meta44=true
                shift
                ;;
            --skip-doc45)
                skip_doc45=true
                shift
                ;;
            --skip-t36)
                skip_t36=true
                shift
                ;;
            --skip-hotpath)
                skip_hotpath=true
                shift
                ;;
            --skip-g33)
                skip_g33=true
                shift
                ;;
            --skip-g32)
                skip_g32=true
                shift
                ;;
            --skip-g34)
                skip_g34=true
                shift
                ;;
            --skip-g35)
                skip_g35=true
                shift
                ;;
            --skip-g31)
                skip_g31=true
                shift
                ;;
            --strict)
                strict_mode=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--security-scan] [--skip-security] [--skip-cross-repo] [--skip-complexity] [--skip-corekern-runtime] [--skip-name-length] [--skip-loc-ceiling] [--skip-propagation] [--skip-header-shadow] [--skip-adapter-registry] [--skip-sample-form] [--skip-version-consistency] [--skip-loc-budget] [--skip-stub-scan] [--skip-file-length] [--skip-clone] [--skip-port-coord] [--skip-policy-payload] [--skip-layer] [--skip-fanout] [--skip-symbol] [--skip-logic-g38] [--skip-g30] [--skip-g37] [--skip-facade] [--skip-ratchet] [--skip-g42] [--skip-meta44] [--skip-doc45] [--skip-t36] [--skip-hotpath] [--skip-g33] [--skip-g32] [--skip-g34] [--skip-g35] [--skip-g31] [--strict]"
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
                echo "  23. Policy Payload Check (G18/G19, mechanism-core zero vendor names)"
                echo "  24. Layer Boundary Check (G21/G23, one-way + zero cross-process symbol)"
                echo "  25. Fan-out Check (G13, header load <= 5 + target fan ratchet)"
                echo "  26. Symbol Conservation Check (G1, AIRY_API public surface)"
                echo "  27. G38 Logic Completeness (0.1.19, five checklists)"
                echo "  28. G30 Experience Gate (0.1.19, TUI + CLI surface)"
                echo "  29. G37 Performance Budget (0.1.19, three-tier TTFT + SYCL throughput)"
                echo "  30. Ratchet Drift Audit (0.1.20, Gate 41 pin history)"
                echo "  31. Facade Attribution (0.1.20, Gate 43 ops family registry)"
                echo "  32. Meta Fail-Closed Audit (0.1.20, Gate 44 gate-the-gates)"
                echo "  33. Doc-Code Consistency (0.1.20, Gate 45 self-referential audit)"
                echo "  34. Terminal-State Completeness (0.1.20, Gate 36 success/fail/unknown)"
                echo "  35. Cost Hot-Path Two-Arm (0.1.20, Gate 37 single-request fsync + p99)"
                echo "  36. Verdict Roundtrip (0.1.20, Gate 33 100x byte-identical)"
                echo "  37. Violation Priority (0.1.20, Gate 32 E-02 > E-05 > E-01 > E-03 > E-04)"
                echo "  38. Plan Schema Rejection (0.1.20, Gate 34 12 reason classes)"
                echo "  39. Partial-Failure Semantics (0.1.20, Gate 35 five combos + stage)"
                echo "  40. Verifier Isolation (0.1.20, Gate 31 deterministic chain zero LLM symbols)"
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
                echo "  --skip-form-count     Skip fleet form-count check (G16/G17)"
                echo "  --skip-version-consistency  Skip version consistency check (SSoT)"
                echo "  --skip-loc-budget     Skip G2 LOC budget (milestone ladder) check"
                echo "  --skip-stub-scan      Skip G6 stub scan (zero-tolerance) check"
                echo "  --skip-file-length    Skip G24 file-length (<= 800 lines/file) check"
                echo "  --skip-clone          Skip G26 clone/duplication (target <3%) check"
                echo "  --skip-port-coord     Skip G5 port coordinate uniqueness (band 2026-2100) check"
                echo "  --skip-policy-payload  Skip G18/G19 policy payload (mechanism-core zero vendor names) check"
                echo "  --skip-layer          Skip G21/G23 layer boundary (one-way + zero cross-process symbol) check"
                echo "  --skip-fanout         Skip G13 fan-out (header load <= 5 + target fan ratchet) check"
                echo "  --skip-symbol         Skip G1 public-surface symbol conservation check"
                echo "  --skip-logic-g38      Skip G38 logic-completeness (0.1.19, five checklists) check"
                echo "  --skip-g30            Skip G30 experience gate (0.1.19, TUI + CLI surface) check"
                echo "  --skip-g37            Skip G37 performance budget (0.1.19, three-tier TTFT) check"
                echo "  --skip-facade         Skip Gate 43 facade-attribution (0.1.20, ops family registry) check"
                echo "  --skip-ratchet        Skip Gate 41 ratchet drift audit (0.1.20, pin history) check"
                echo "  --skip-g42            Skip Gate 42 ledger consistency (0.1.20, three-ledger parity) check"
                echo "  --skip-meta44         Skip Gate 44 meta fail-closed (0.1.20, gate-the-gates) check"
                echo "  --skip-doc45          Skip Gate 45 doc-code consistency (0.1.20, file:line audit) check"
                echo "  --skip-t36            Skip Gate 36 terminal-state completeness (0.1.20, success/fail/unknown) check"
                echo "  --skip-hotpath        Skip Gate 37 cost hot-path two-arm (0.1.20, single-request fsync + p99) check"
                echo "  --skip-g33            Skip Gate 33 verdict roundtrip (0.1.20, 100x byte-identical) check"
                echo "  --skip-g32            Skip Gate 32 violation priority (0.1.20, E-02 > E-05 > E-01 > E-03 > E-04) check"
                echo "  --skip-g34            Skip Gate 34 plan schema rejection (0.1.20, 12 reason classes) check"
                echo "  --skip-g35            Skip Gate 35 partial-failure semantics (0.1.20, five combos + stage) check"
                echo "  --skip-g31            Skip Gate 31 verifier isolation (0.1.20, deterministic chain zero LLM symbols) check"
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
        $skip_form_count || gate_form_count
        $skip_version_consistency || gate_version_consistency
        $skip_loc_budget || gate_loc_budget
        $skip_stub_scan || gate_stub_scan
        $skip_file_length || gate_file_length
        $skip_clone || gate_clone
        $skip_port_coord || gate_port_coord
        $skip_policy_payload || gate_policy_payload
        $skip_layer || gate_layer
        $skip_fanout || gate_fanout
        $skip_symbol || gate_symbol_conservation
        $skip_logic_g38 || gate_logic_g38
        $skip_g30 || gate_g30_experience
        $skip_g37 || gate_perf_g37
        $skip_facade || gate_facade_attribution
        $skip_ratchet || gate_ratchet
        $skip_g42 || gate_ledger
        $skip_meta44 || gate_meta_failclosed
        $skip_doc45 || gate_doc_consistency
        $skip_t36 || gate_terminal36
        $skip_hotpath || gate_cost37
        $skip_g33 || gate_roundtrip33
        $skip_g32 || gate_priority32
        $skip_g34 || gate_plan34
        $skip_g35 || gate_partial35
        $skip_g31 || gate_verifier31
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