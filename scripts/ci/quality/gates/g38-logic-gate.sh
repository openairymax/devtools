#!/bin/bash
# 0.1.19 G38 逻辑完备性门禁（方案 §3.7.3；证伪修正 F7 / F8）
#
# 五张清单，逐项可验证：
#   G38-1 错误路径穷举 —— daemons/*/src/rpc/*.c 的 JSON-RPC 信封只经受控
#         helper 构造（禁止手搓 "jsonrpc"/"error" 字面量），并以
#         svc_test_rpc_err_class 证明 class/code 在边界保义；
#   G38-2 状态机穷举 —— svc_test_daemon_state（N7 形式化四态 + 迁移断言）；
#   G38-3 依赖闭环 —— svc_test_daemon_dep + tool_d_test_tool_avail，且契约表
#         requires_daemon 必须指向真实 daemon；
#   G38-4 缺陷—用例映射 —— v16-g38-defect-map.txt 逐条绑定证据，缺陷清零
#         不得无回归；
#   G38-5 时序一致性 —— daemon_dep 声明图无悬空、无自依赖、无环。
#
# 构建树位于源码区外（工程铁律 4.1.1）：由 AIRYRT_BUILD_ROOT 或
# QUALITY_GATE_BUILD_DIR 指定；两者皆空视为环境错误（门禁不猜测机器路径）。
# 用法: [AIRYRT_BUILD_ROOT=<build>] g38-logic-gate.sh
# 退出码: 0 = 通过；1 = 逻辑完备性违例；2 = 环境错误（树/构建树缺失）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
DAEMONS="${AGENTRT}/daemons"
LAUNCHER="${PROJECT_ROOT}/agent-workload/sdk/tui/scripts/airymaxrt"
DEFECT_MAP="${SCRIPT_DIR}/v16-g38-defect-map.txt"
BUILD_ROOT="${AIRYRT_BUILD_ROOT:-${QUALITY_GATE_BUILD_DIR:-}}"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

log_ok()  { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

violations=0
case_log="$(mktemp "${TMPDIR:-/tmp}/g38-case.XXXXXX")"
trap 'rm -f "$case_log"' EXIT

declare -A CASE_SEEN=()

# 0.1.19 必须闭合的缺陷集合（§3.5 九条 + §3.6 D1~D5/D7/D8）。
# 映射文件可增列，但以下任何一条失去证据即判违例——缺陷清零不得失回归。
REQUIRED_DEFECTS=(
    '§3.5-1' '§3.5-2' '§3.5-3' '§3.5-4' '§3.5-5'
    '§3.5-6' '§3.5-7' '§3.5-8' '§3.5-9'
    '§3.6-D1' '§3.6-D2' '§3.6-D2p' '§3.6-D3' '§3.6-D4'
    '§3.6-D5' '§3.6-D7' '§3.6-D8'
)

fail() {
    log_err "$*"
    violations=$((violations + 1))
}

# 运行单个 ctest 用例；不存在即判违例，失败输出末 8 行。重复调用只跑一次。
run_case() {
    local name="$1"
    [ -n "${CASE_SEEN[$name]:-}" ] && return 0
    CASE_SEEN[$name]=1

    if ! ctest --test-dir "$BUILD_ROOT" -N -R "^${name}$" 2>/dev/null | grep -q "Test #"; then
        fail "case not registered in build tree: ${name}"
        return 0
    fi
    if ctest --test-dir "$BUILD_ROOT" -R "^${name}$" --output-on-failure \
        >"$case_log" 2>&1; then
        log_ok "case passed: ${name}"
    else
        fail "case failed: ${name}"
        tail -8 "$case_log" | sed 's/^/        /'
    fi
}

# 静态探针：启动器 profile.env 逐行解析（§3.5 缺陷1 防回退）。
probe_launcher_profile_parse() {
    [ -f "$LAUNCHER" ] || return 1
    grep -q '^profile_load()' "$LAUNCHER" || return 1
    grep -q 'while IFS= read -r' "$LAUNCHER" || return 1
    ! grep -qE '(^|[^[:alnum:]_])(\.|source)[[:space:]]+"\$PROFILE_ENV"' "$LAUNCHER"
}

# G38-1：RPC 边界信封构造纪律。
check_error_envelope() {
    local hits
    hits=$(find "$DAEMONS" -path '*/src/rpc/*.c' -type f \
        -exec grep -InE \
        'cJSON_Add[A-Za-z]+ToObject\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*,[[:space:]]*"jsonrpc"|cJSON_AddItemToObject\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*,[[:space:]]*"error"' \
        {} + 2>/dev/null || true)
    if [ -n "$hits" ]; then
        while IFS= read -r line; do fail "hand-built JSON-RPC envelope: ${line}"; done <<<"$hits"
    else
        log_ok "no hand-built JSON-RPC envelopes at daemon RPC boundary"
    fi
}

# G38-3：契约表 requires_daemon 必须指向真实 daemon（能力暴露 ⇒ 依赖存在）。
check_contract_deps() {
    local tab="${DAEMONS}/tool_d/src/rpc/service_builtin.c"
    [ -f "$tab" ] || { fail "contract table missing: ${tab}"; return 0; }
    local deps d
    deps=$(sed -n 's/^[[:space:]]*{"[a-z_]*",[[:space:]]*[A-Za-z0-9_]*,[[:space:]]*"\([a-z0-9_]*\)".*/\1/p' "$tab" \
        | sort -u)
    for d in $deps; do
        if [ -d "${DAEMONS}/${d}" ]; then
            log_ok "contract daemon resolved: ${d}"
        else
            fail "contract requires unknown daemon: ${d}"
        fi
    done
}

# G38-5：依赖声明图（悬空 / 自依赖 / 环）。
check_dep_graph() {
    local edges edge owner dep
    edges=$(find "$DAEMONS" -path '*/src/*' -name '*.c' -type f -exec awk '
        FNR == 1 { inblk = 0 }
        /daemon_dep_spec_t[ \t]+[A-Za-z_][A-Za-z0-9_]*\[[0-9]*\][ \t]*=/ {
            inblk = 1
            n = split(FILENAME, p, "/")
            owner = (n > 1) ? p[n - 2] : "?"
            if (p[n - 1] == "src") owner = p[n - 2]
            next
        }
        inblk && /^[ \t]*};/ { inblk = 0; next }
        inblk && match($0, /\{"[^"]+"/) {
            s = substr($0, RSTART + 2, RLENGTH - 3)
            dep = s
            sub(/".*/, "", dep)
            print owner, dep
        }
    ' {} + 2>/dev/null || true)

    while read -r owner dep; do
        [ -n "${owner:-}" ] && [ -n "${dep:-}" ] || continue
        [ -d "${DAEMONS}/${owner}" ] || fail "dependency owner not a daemon: ${owner}"
        [ -d "${DAEMONS}/${dep}" ] || fail "dangling dependency edge: ${owner} -> ${dep}"
        [ "$owner" = "$dep" ] && fail "self dependency: ${owner}"
    done <<<"$edges"

    if printf '%s\n' "$edges" | awk '
        NF == 2 { adj[$1] = adj[$1] " " $2; node[$1] = 1; node[$2] = 1 }
        function dfs(u,   i, k, a, v) {
            color[u] = 1
            k = split(adj[u], a, " ")
            for (i = 1; i <= k; i++) {
                v = a[i]
                if (v == "") continue
                if (color[v] == 1) { print "cycle: " u " -> " v; bad = 1 }
                else if (color[v] == 0) dfs(v)
            }
            color[u] = 2
        }
        END {
            for (n in node) if (color[n] == 0) dfs(n)
            if (bad) exit 1
        }
    '; then
        log_ok "dependency graph acyclic and closed"
    else
        fail "dependency graph violates acyclicity"
    fi
}

section "0.1.19 G38 logic-completeness gate (5 checklists)"
[ -d "$DAEMONS" ] || { log_err "daemon tree not found: ${DAEMONS}"; exit 2; }
[ -n "$BUILD_ROOT" ] || {
    log_err "build tree not specified: set AIRYRT_BUILD_ROOT or QUALITY_GATE_BUILD_DIR"
    exit 2
}
[ -d "$BUILD_ROOT" ] || { log_err "build tree not found: ${BUILD_ROOT}"; exit 2; }
[ -f "$DEFECT_MAP" ] || { log_err "defect map not found: ${DEFECT_MAP}"; exit 2; }

section "G38-1 error-path exhaustion"
check_error_envelope
run_case svc_test_rpc_err_class

section "G38-2 state-machine exhaustion"
run_case svc_test_daemon_state

section "G38-3 dependency closure"
check_contract_deps
run_case svc_test_daemon_dep
run_case tool_d_test_tool_avail

section "G38-4 defect-to-case mapping"
declare -A DEFECT_SEEN=()
while IFS='|' read -r defect evidence; do
    case "${defect:-}" in ''|'#'*) continue ;; esac
    DEFECT_SEEN[$defect]=1
    case "$evidence" in
        test:*)
            run_case "${evidence#test:}"
            ;;
        static:*)
            probe="${evidence#static:}"
            case "$probe" in
                launcher_profile_parse)
                    if probe_launcher_profile_parse; then
                        log_ok "probe passed: ${probe}"
                    else
                        fail "probe failed: ${probe}"
                    fi
                    ;;
                *)
                    fail "unknown static probe: ${probe}"
                    ;;
            esac
            ;;
        *)
            fail "malformed defect-map line: ${defect}|${evidence}"
            ;;
    esac
done <"$DEFECT_MAP"
[ "${#DEFECT_SEEN[@]}" -gt 0 ] || fail "defect map is empty"
for defect in "${REQUIRED_DEFECTS[@]}"; do
    [ -n "${DEFECT_SEEN[$defect]:-}" ] \
        || fail "defect lost its regression mapping: ${defect}"
done
log_ok "defect entries bound: ${#DEFECT_SEEN[@]}"

section "G38-5 temporal consistency"
check_dep_graph

section "0.1.19 G38 logic-completeness gate"
if [ "$violations" -eq 0 ]; then
    log_ok "all five checklists satisfied"
    log_ok "0.1.19 G38 logic-completeness gate PASSED"
    exit 0
else
    log_err "found ${violations} logic-completeness violation(s)"
    log_err "0.1.19 G38 logic-completeness gate FAILED"
    exit 1
fi
