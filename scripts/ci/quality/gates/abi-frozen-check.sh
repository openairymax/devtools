#!/bin/bash
# M3 (0.1.9 §4.2-3): coreloopthree ABI 冻结门禁
# 规则 1（阻断）：coreloopthree/src/ 下内部子域头禁止被 coreloopthree 之外
#   include（engine_internal、grad/*、foundation/*、orchestrator_internal 等
#   均为认知引擎内部实现细节，外部只能消费 include/ 公共接口面）。
# 规则 2（信息性）：coreloopthree/include/ 公共头被外部 include 的白名单
#   快照——新增头若被外部 include 且不在白名单则警告（防隐式依赖扩张）。
#
# 用法: abi-frozen-check.sh [--info]
#   --info  规则 2 从警告升级为阻断
# 退出码: 0 = 通过；1 = 违规；2 = 环境错误
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 脚本位于 tools/scripts/ci/quality/gates/ — 向上 6 级到达伞仓根目录
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
CL3_DIR="${PROJECT_ROOT}/agent-workload/agentrt/atoms/coreloopthree"
INFO_STRICT=0
[ "${1:-}" = "--info" ] && INFO_STRICT=1

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

log_info()  { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err()   { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }

[ -d "$CL3_DIR" ] || { log_err "coreloopthree 目录不存在: $CL3_DIR"; exit 2; }

# ---------------------------------------------------------------------------
# 收集 coreloopthree 内部头 basename 与公共头 basename
# ---------------------------------------------------------------------------
mapfile -t CL3_INTERNAL_HEADERS < <(find "$CL3_DIR/src" -name "*.h" -printf "%f\n" | sort -u)
mapfile -t CL3_PUBLIC_HEADERS < <(find "$CL3_DIR/include" -name "*.h" -printf "%f\n" | sort -u)

# 排除"同名不同头"的假阳性：这些 basename 在项目其他位置存在独立头文件，
# 外部 include 它们不代表引用 coreloopthree 内部实现。
mapfile -t DUP_NAMES < <(for h in "${CL3_INTERNAL_HEADERS[@]}"; do
    cnt=$(find "$PROJECT_ROOT/agent-workload/agentrt" -path "*coreloopthree*" -prune -o \
          -name "$h" -print 2>/dev/null | wc -l)
    if [ "$cnt" -gt 0 ]; then echo "$h"; fi
done)

# ---------------------------------------------------------------------------
# 外部消费白名单（0.1.9 调研实证：coreloopthree/include 被外部消费的 24 头）
# ---------------------------------------------------------------------------
PUBLIC_ALLOWLIST=(
    airy_hook.h hook_service.h hook_registry.h hook_builtin_handlers.h
    hook_executor.h hook_interceptor.h hook_timeout.h
    cognition.h orchestrator.h llm_svc_adapter.h lang_gateway.h airy_orch_ops.h
    loop.h roadmap_sched.h gccp.h work_hall.h hall_store.h governance.h
    plan_to_dag.h execution_review.h multi_agent_collaboration.h
    airy_artifact_validator.h memory.h agent_registry.h
    # 机制本体公共面（0.1.9 M3 实证外部消费）：
    semantic_unit.h checkpoint_adapter.h memoryrovol_bridge.h tool_svc_adapter.h
)

# ---------------------------------------------------------------------------
# 外部扫描目录（coreloopthree 之外的所有源码区）
# ---------------------------------------------------------------------------
scan_dirs=(
    "${PROJECT_ROOT}/agent-workload/agentrt/atoms"
    "${PROJECT_ROOT}/agent-workload/agentrt/commons"
    "${PROJECT_ROOT}/agent-workload/agentrt/cupolas"
    "${PROJECT_ROOT}/agent-workload/agentrt/daemons"
    "${PROJECT_ROOT}/agent-workload/agentrt/gateway"
    "${PROJECT_ROOT}/agent-workload/agentrt/heapstore"
    "${PROJECT_ROOT}/agent-workload/agentrt/protocols"
    "${PROJECT_ROOT}/agent-workload/agentrt/sdk"
    "${PROJECT_ROOT}/agent-workload/agentrt/tools"
    "${PROJECT_ROOT}/tools/tests"
)
# 去重
mapfile -t scan_dirs < <(printf "%s\n" "${scan_dirs[@]}" | awk '!seen[$0]++' | sed '/^$/d')

exit_code=0

# ---------------------------------------------------------------------------
# 规则 1：内部子域头禁止外部 include
# ---------------------------------------------------------------------------
log_info "规则 1：coreloopthree 内部子域头外部 include 检查"
for h in "${CL3_INTERNAL_HEADERS[@]}"; do
    # 同名头存在于外部 → 假阳性风险，跳过
    if printf '%s\n' "${DUP_NAMES[@]}" | grep -qx "$h"; then
        continue
    fi
    # 在任何外部扫描目录的 .c/.h 中搜索 include
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        log_err "内部头 $h 被外部引用: $f"
        exit_code=1
    done < <(grep -rln "#include[[:space:]]*[\"<]$h[\">]" \
                 --include="*.c" --include="*.h" --include="*.cpp" --include="*.hpp" \
                 --exclude-dir=coreloopthree \
                 "${scan_dirs[@]}" 2>/dev/null || true)
done

if [ "$exit_code" -eq 0 ]; then
    log_ok "内部子域头外部 include 零违规"
fi

# ---------------------------------------------------------------------------
# 规则 2：公共头外部 include 白名单（默认信息性，--info 升级阻断）
# ---------------------------------------------------------------------------
log_info "规则 2：coreloopthree 公共头外部 include 白名单"
for h in "${CL3_PUBLIC_HEADERS[@]}"; do
    if printf '%s\n' "${PUBLIC_ALLOWLIST[@]}" | grep -qx "$h"; then
        continue
    fi
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        msg="公共头 $h 不在 ABI 白名单却被外部引用: $f"
        if [ "$INFO_STRICT" -eq 1 ]; then
            log_err "$msg"
            exit_code=1
        else
            log_warn "$msg"
        fi
    done < <(grep -rln "#include[[:space:]]*[\"<]$h[\">]" \
                 --include="*.c" --include="*.h" --include="*.cpp" --include="*.hpp" \
                 --exclude-dir=coreloopthree \
                 "${scan_dirs[@]}" 2>/dev/null || true)
done

if [ "$exit_code" -eq 0 ]; then
    log_ok "ABI 冻结门禁通过"
else
    log_err "ABI 冻结门禁失败（存在违规）"
fi
exit "$exit_code"
