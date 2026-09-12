#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# corekern-runtime-check.sh — WS-8 8.4.2 "corekern 运行时达标" 门禁
#
# 堵 0.1.15 架构改进方案 §7.3 结构性口径漏洞：运行时达标不接受
# "库在构建内/头文件在位"，只接受运行时调用链证据——逐个真实拉起
# 生产进程（15 daemon + airy_cli），从其启动输出取证：
#   a) 进程内调用证据  "corekern core initialized"
#      （main.c 中 airy_init()==AIRY_SUCCESS 分支在本进程真实走到）
#   b) corekern 链路证据  "core_init: [OK] AgentRT core initialized successfully"
#      （airy_init() 内部 mem/oom/task/ipc/eventloop 子系统初始化链，
#      daemon 必配；airy_cli 因 CLI 日志级别钉在 ERROR 不打印链路行，
#      仅要求 a)
#   c) 一票否决  "corekern init failed ... running degraded (badge=0)"
#      （airy_init() 失败 = 降级运行 = 运行时不达标）
#
# 退出码: 0=全部达标  1=任一未达标(阻断)  2=环境错误(构建产物缺失,告警)
#
# 用法:
#   corekern-runtime-check.sh [--build-dir DIR] [--timeout SEC]
# 环境变量:
#   COREKERN_GATE_BUILD_DIR  构建树根（默认复用 quality-gate Gate 1 的
#                            树外构建目录；亦可直接传 works-engineering 树）
#   COREKERN_GATE_TIMEOUT    单进程取证等待秒数（默认 8）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

BUILD_DIR="${COREKERN_GATE_BUILD_DIR:-${TMPDIR:-/tmp}/agentrt-quality-gate-build}"
WAIT_SEC="${COREKERN_GATE_TIMEOUT:-8}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[CKRT]${NC}       $*"; }
log_ok()    { echo -e "${GREEN}[CKRT-OK]${NC}   $*"; }
log_warn()  { echo -e "${YELLOW}[CKRT-WARN]${NC} $*"; }
log_error() { echo -e "${RED}[CKRT-ERR]${NC}  $*" >&2; }

# 生产进程清单：15 daemon（<build>/bin/）+ airy_cli（<build>/tools/airy_cli/）
DAEMON_LIST=(a2a_d agent_d channel_d cupolas_d gateway_d hook_d llm_d
             market_d maths_d mem_d monit_d notify_d sched_d think_d tool_d)

EVIDENCE_CALL='corekern core initialized'
EVIDENCE_CHAIN='AgentRT core initialized successfully'
EVIDENCE_DEGRADED='corekern init failed'

# probe <name> <binary> [extra-args...]
# 拉起进程 → 轮询扫描启动输出（0.2s 步长，至多 WAIT_SEC，见证即收）→
# TERM→宽限→KILL 收尾。守护进程常驻不退出，取证靠输出扫描而非退出码。
probe() {
    local name="$1" bin="$2"
    shift 2
    local outfile
    outfile="$(mktemp "${TMPDIR:-/tmp}/corekern-gate-${name}.XXXXXX")"

    "$bin" "$@" >"$outfile" 2>&1 </dev/null &
    local pid=$!
    local verdict="no-evidence"
    local max_steps
    max_steps=$(awk -v t="$WAIT_SEC" 'BEGIN { print int(t / 0.2) }')
    local i

    for ((i = 0; i < max_steps; i++)); do
        if grep -q "$EVIDENCE_DEGRADED" "$outfile" 2>/dev/null; then
            verdict="degraded"
            break
        fi
        if grep -q "$EVIDENCE_CALL" "$outfile" 2>/dev/null; then
            verdict="ok"
            break
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done

    kill -TERM "$pid" 2>/dev/null
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    # 终扫描：兜住「证据落盘晚于循环退出」的竞态；降级一票否决优先
    if [ "$verdict" != "degraded" ]; then
        if grep -q "$EVIDENCE_DEGRADED" "$outfile" 2>/dev/null; then
            verdict="degraded"
        elif grep -q "$EVIDENCE_CALL" "$outfile" 2>/dev/null; then
            verdict="ok"
        fi
    fi
    # daemon 双证据判定：调用证据 + corekern 内部子系统链证据
    if [ "$verdict" = "ok" ] && [ "$name" != "airy_cli" ]; then
        grep -q "$EVIDENCE_CHAIN" "$outfile" 2>/dev/null || verdict="missing-chain"
    fi

    case "$verdict" in
        ok)
            log_ok "$name: runtime call-chain confirmed"
            ;;
        *)
            log_error "$name: runtime evidence FAILED ($verdict)"
            grep -E "ERROR|FATAL|failed|degraded" "$outfile" 2>/dev/null \
                | head -3 | sed 's/^/    /' >&2
            ;;
    esac
    rm -f "$outfile"

    [ "$verdict" = "ok" ]
}

usage() {
    cat <<'EOF'
Usage: corekern-runtime-check.sh [--build-dir DIR] [--timeout SEC]

Probes every production process (15 daemons + airy_cli) of a build tree
and requires runtime corekern call-chain evidence from its startup output.
Exit codes: 0 = all certified, 1 = any failure (blocking), 2 = environment
(build artifacts missing; warning-level).
EOF
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --build-dir)
                BUILD_DIR="$2"
                shift 2
                ;;
            --timeout)
                WAIT_SEC="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "unknown option: $1"
                exit 2
                ;;
        esac
    done

    local bin_dir="${BUILD_DIR}/bin"
    local cli_bin="${BUILD_DIR}/tools/airy_cli/airy_cli"

    echo "corekern runtime gate (WS-8 8.4.2) — $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "build dir: ${BUILD_DIR}"
    log_info "per-process evidence wait: ${WAIT_SEC}s"

    if [ ! -d "$bin_dir" ]; then
        log_warn "build tree has no bin/ (${bin_dir}) — build first (environment error)"
        exit 2
    fi

    local pass=0 fail=0
    local d bin verdict
    local -a failed_list=()

    for d in "${DAEMON_LIST[@]}"; do
        bin="${bin_dir}/${d}"
        if [ ! -x "$bin" ]; then
            log_error "$d: binary not found at ${bin}"
            fail=$((fail + 1))
            failed_list+=("$d (missing)")
            continue
        fi
        if probe "$d" "$bin"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            failed_list+=("$d")
        fi
    done

    if [ ! -x "$cli_bin" ]; then
        log_error "airy_cli: binary not found at ${cli_bin}"
        fail=$((fail + 1))
        failed_list+=("airy_cli (missing)")
    elif probe "airy_cli" "$cli_bin" -p ""; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failed_list+=("airy_cli")
    fi

    echo ""
    echo "  corekern runtime gate: ${pass} passed, ${fail} failed (of $((pass + fail)))"
    if [ "$fail" -gt 0 ]; then
        echo "  failed: ${failed_list[*]}"
        exit 1
    fi
    exit 0
}

main "$@"
