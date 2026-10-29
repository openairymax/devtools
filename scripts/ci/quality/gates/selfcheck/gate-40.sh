#!/bin/bash
# Gate 40 kill switch 跨进程通道 + V8 采纳→回滚全链 lab 验收
# （0.1.20 方案 §5.7 V8 / §9.1 Gate 40；Q4 (a)：gate:lab 定性）
#
# 与 selfcheck 反向用例不同，本门禁需要真实集成环境（gate:lab）：
#   真实 cupolas_d 进程 + 真实 unix socket JSON-RPC + 真实文件哨兵，
#   零 mock、零桩。B3 出口前须留一次人工跑通记录与日志路径。
#
# T1（V8 全链 + Gate 40 跨进程哨兵）：
#   load → activate（can_gate 分流建灰度会话）→ 日志确认 entered shadow →
#   本脚本进程直接落盘 <AIRY_HOME>/run/local/evolve/policy/kill（不经
#   CLI、不共进程——验证通道三语义中的跨进程可见性）→ 日志确认 kill
#   switch hit → 全链耗时 ≤ CANARY_RB_MAX_SECS(300s)，即 V8 判据
#   rb_secs>300 → -5 拒绝的反面实证：真实链路必须能在窗口内完成。
#
# T2（env 通道 fail-closed）：
#   AIRY_CUPOLAS_CANARY_KILL=1 起服务 → load 照常入暂存（两段式不受
#   影响）→ activate 必须被 can_gate 拒绝（JSON-RPC error）→
#   policy_status 确认拒绝路径 staged 完整保留（可重试，无部分副作用）。
#
# 用法: selfcheck/gate-40.sh <build-dir>   （build-dir 含 bin/cupolas_d，
#        或 export AIRY_BUILD_DIR=...）
# 依赖: python3（JSON-RPC 裸流帧客户端）
# 退出码: 0 = T1/T2 全部符合预期；1 = 门禁失败或基建异常
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

BUILD_DIR="${1:-${AIRY_BUILD_DIR:-}}"
if [ -z "$BUILD_DIR" ]; then
    log_err "usage: gate-40.sh <build-dir> (or export AIRY_BUILD_DIR=...)"
    exit 1
fi
CUPOLAS_D="$BUILD_DIR/bin/cupolas_d"
[ -x "$CUPOLAS_D" ] || {
    log_err "cupolas_d not found or not executable: ${CUPOLAS_D}"
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    log_err "python3 required for JSON-RPC bare-stream client"
    exit 1
}

# 全链预算取自契约常量 CANARY_RB_MAX_SECS（门禁侧从 canary.h 读取后经
# G40_RB_SECS 传入，此处 300 仅作独立运行的兜底）。段内等待不得引入独立
# 魔数：CI 慢机上曾因 60s 死线先于契约判据触发，把「链路比契约慢」误报
# 成「四通道语义不成立」（run 40884260525 实证）。
RB_SECS="${G40_RB_SECS:-300}"
DEADLINE_MS=0

TMP="$(mktemp -d)"
PIDS=()
cleanup() {
    for p in "${PIDS[@]:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null && wait "$p" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

# JSON-RPC 裸 JSON 文本流客户端（与 airy_daemon_read_request 的
# recv + JSON 配平探测同构）：响应能被 json.loads 即帧完。
cat > "$TMP/rpc.py" <<'EOF'
import json, socket, sys

path, method, params = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
req = {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(path)
s.sendall(json.dumps(req).encode())
buf = b""
while True:
    try:
        chunk = s.recv(4096)
    except socket.timeout:
        break
    if not chunk:
        break
    buf += chunk
    try:
        print(json.dumps(json.loads(buf.decode())))
        sys.exit(0)
    except (json.JSONDecodeError, UnicodeDecodeError):
        continue
print(json.dumps({"incomplete": buf.decode(errors="replace")}))
sys.exit(2)
EOF

has_field() { # $1=resp-file $2=json-key
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in d else 1)' "$1" "$2"
}
expect_ok() { # $1=name $2=resp-file
    if has_field "$2" result; then
        log_ok "$1"
    else
        log_err "$1: expected result, got $(cat "$2")"
        exit 1
    fi
}
expect_err() { # $1=name $2=resp-file
    if has_field "$2" error; then
        log_ok "$1"
    else
        log_err "$1: expected error (fail-closed), got $(cat "$2")"
        exit 1
    fi
}
wait_log() { # $1=pattern $2=logfile；截止 = 全链预算（见 DEADLINE_MS）
    while [ "$(date +%s%3N)" -lt "$DEADLINE_MS" ]; do
        if grep -q "$1" "$2" 2>/dev/null; then return 0; fi
        sleep 0.2
    done
    log_err "timeout waiting for log: $1 (budget ${RB_SECS}s)"
    return 1
}
start_daemon() { # $1=sandbox $2=logfile  (+env: KILL_ENV="VAR=val" 经 env 命令注入)
    mkdir -p "$1/run"
    # 展开产生的 VAR=val 单词不会被 shell 识别为赋值前缀（POSIX 语义，
    # 会被误当命令名），须经 env 命令注入
    AIRY_HOME="$1" env ${KILL_ENV:+$KILL_ENV} "$CUPOLAS_D" >"$2" 2>&1 &
    PIDS+=($!)
    local deadline=$(( $(date +%s) + 10 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ -S "$1/run/cupolas.sock" ] && return 0
        kill -0 "${PIDS[-1]}" 2>/dev/null || break
        sleep 0.1
    done
    log_err "daemon socket timeout: $1/run/cupolas.sock (log: $2)"
    tail -20 "$2" || true
    return 1
}
stop_daemons() {
    for p in "${PIDS[@]:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null && wait "$p" 2>/dev/null
    done
    PIDS=()
}

MIN_POLICY='{"rules":[{"id":"r1","effect":"allow","subject":"*","action":"*","resource":"*"}]}'

# params JSON 一律由 json.dumps 生成：策略文档含嵌套引号，
# bash 字符串拼接会被切断（argv 边界错位）
load_params() {
    python3 -c 'import json,sys; print(json.dumps({"json": sys.argv[1]}))' "$MIN_POLICY"
}

# RPC 失败必须自解释：rpc.py 在收不到完整帧时 exit 2，若直接裸调用，
# set -e 会静默以 2 终止，CI 只能看到「语义不成立」（run 40884260525 /
# 本机 run4 各中一次）。此处统一回显响应原文与宿主日志尾部。
rpc_call() { # $1=resp-file $2=sock $3=method $4=params $5=daemon-log
    if ! python3 "$TMP/rpc.py" "$2" "$3" "$4" >"$1"; then
        log_err "rpc ${3} 无完整响应帧: $(cat "$1")"
        tail -20 "$5" || true
        return 1
    fi
}

# ── T1: V8 全链 + Gate 40 跨进程哨兵 ────────────────────────
section "T1: adopt -> shadow -> cross-process kill sentinel -> rollback"
SB1="$TMP/t1"; LOG1="$SB1-daemon.log"
start_daemon "$SB1" "$LOG1"
SOCK1="$SB1/run/cupolas.sock"

rpc_call "$TMP/r1.json" "$SOCK1" policy_load "$(load_params)" "$LOG1" || exit 1
expect_ok "T1 policy_load staged" "$TMP/r1.json"

T0=$(date +%s%3N)
DEADLINE_MS=$(( T0 + RB_SECS * 1000 ))
rpc_call "$TMP/r2.json" "$SOCK1" policy_activate '{"description": "gate-40 v8 lab"}' "$LOG1" || exit 1
expect_ok "T1 policy_activate (canary gate divert)" "$TMP/r2.json"

wait_log "canary session entered shadow" "$LOG1" || exit 1
log_ok "T1 shadow session established"

mkdir -p "$SB1/run/local/evolve/policy"
: > "$SB1/run/local/evolve/policy/kill"

wait_log "canary kill switch hit, rolling back" "$LOG1" || exit 1
log_ok "T1 kill sentinel observed cross-process"

T1=$(date +%s%3N)
ELAPSED=$((T1 - T0))
if [ "$ELAPSED" -le $(( RB_SECS * 1000 )) ]; then
    log_ok "T1 V8 full chain: ${ELAPSED}ms <= $(( RB_SECS * 1000 ))ms (CANARY_RB_MAX_SECS=${RB_SECS}s)"
else
    log_err "T1 V8 full chain: ${ELAPSED}ms > $(( RB_SECS * 1000 ))ms (CANARY_RB_MAX_SECS=${RB_SECS}s)"
    exit 1
fi
stop_daemons

# ── T2: env 通道 fail-closed ────────────────────────────────
section "T2: env kill channel fail-closed (activate rejected, staged kept)"
SB2="$TMP/t2"; LOG2="$SB2-daemon.log"
KILL_ENV="AIRY_CUPOLAS_CANARY_KILL=1" start_daemon "$SB2" "$LOG2"
SOCK2="$SB2/run/cupolas.sock"

rpc_call "$TMP/r3.json" "$SOCK2" policy_load "$(load_params)" "$LOG2" || exit 1
expect_ok "T2 policy_load unaffected (two-phase staging)" "$TMP/r3.json"

rpc_call "$TMP/r4.json" "$SOCK2" policy_activate '{"description": "gate-40 t2"}' "$LOG2" || exit 1
expect_err "T2 activate rejected under kill switch" "$TMP/r4.json"

rpc_call "$TMP/r5.json" "$SOCK2" policy_status '{}' "$LOG2" || exit 1
if has_field "$TMP/r5.json" result && \
   python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["result"]["staged"] else 1)' "$TMP/r5.json"; then
    log_ok "T2 staged preserved after rejection (retryable, no partial effect)"
else
    log_err "T2 staged lost after rejection: $(cat "$TMP/r5.json")"
    exit 1
fi
stop_daemons

section "Gate 40 lab verdict"
log_ok "V8 full chain within 300s window + kill switch fail-closed"
exit 0
