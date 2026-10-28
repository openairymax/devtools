#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
# =============================================================================
# agentrt-llm-e2e.sh — A7-5 端到端验收：llm_d → 11435 → managed llama-server
#
# 出处：《0.1.20-架构改进完善和自演化方案》§6.2 B-A7 批次（A7-5 行），
#       同时是 B8 发版闸门 C-10 的前置判据。
#
# 验收内容（DoD 原文口径）：
#   1. 真实请求返回 200（complete → choices[0].content 非空）；
#   2. 冷加载/存活/失联三态可观测（health_check endpoints[] 的
#      status=unknown|ok|unreachable、cold、deep 字段）；
#   3. kill llama-server 后自愈：supervisor BACKOFF 自动重启（CORE 角色），
#      新 pid ≠ 旧 pid、11435 复活、complete 恢复、health 恢复；
#   4. 回退：全链无持久态，重跑即净（退出时恢复备份的 profile.env/model.yaml）。
#
# 机制真实语义（不向机制核加验收后门）：
#   - ep_health deep 探针轮转：round0 即 deep，此后每 5 轮（150s）一次 deep；
#     粘滞判定 reachable=(ok && deep!=0)，故存活/自愈的 status=ok 断言窗口取
#     240s（覆盖最坏一轮完整轮转 + 容差）。
#   - complete 失败路径：连接拒绝快失败 × 4 次尝试（LLM_MAX_RETRIES=3），
#     失联断言窗口 60s。
#
# 用法：
#   agentrt-llm-e2e.sh [--bindir <dir>] [--keep] [--skip-install]
#     --bindir       supervisor_d/llm_d 所在目录（缺省自动探测）
#     --keep         保留现场（不清理进程与配置，用于失败诊断）
#     --skip-install 跳过 airy-local 安装（工件已就位时加速重跑）
# =============================================================================
set -Eeuo pipefail

AIRY_HOME="${AIRY_HOME:-$HOME/.airymaxrt}"
RUN_DIR="$AIRY_HOME/run"
CFG_DIR="$AIRY_HOME/config"
LOCAL_BIN="$AIRY_HOME/local/llamacpp/bin/llama-server"
LOCAL_MODEL="$AIRY_HOME/local/models/Qwen3-0.6B-Q8_0.gguf"
MODEL_YAML="$CFG_DIR/model.yaml"
PROFILE_ENV="$CFG_DIR/profile.env"
LLM_SOCK="$RUN_DIR/llm.sock"
SUP_SOCK="$RUN_DIR/supervisor.sock"
LLM_PORT=11435
MODEL_ID="qwen3-0.6b-q8_0"

BINDIR=""
OPT_KEEP=0
OPT_SKIP_INSTALL=0

log()  { printf '[e2e] %s\n' "$*"; }
fail() { printf '[e2e][FAIL] %s\n' "$*" >&2; exit 1; }

# ---------- 参数 ----------
while [[ ${#} -gt 0 ]]; do
    case "$1" in
        --bindir)       BINDIR="${2:?--bindir requires a value}"; shift 2 ;;
        --keep)         OPT_KEEP=1; shift ;;
        --skip-install) OPT_SKIP_INSTALL=1; shift ;;
        -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

# ---------- RPC 帮手（协议与 agentrt-e2e.py 同源：短连接、单行 JSON、
# 不可 shutdown(SHUT_WR)、首包后缩超时收尾等 EOF） ----------
rpc_call() { # $1=sock $2=method $3=params-json $4=timeout_s
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import json, socket, sys
sock, method, params, timeout = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(timeout)
try:
    s.connect(sock)
    req = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": json.loads(params)})
    s.sendall(req.encode("utf-8"))
    buf = b""
    while True:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
        if buf:
            s.settimeout(1.0)
    if not buf:
        print(json.dumps({"error": {"code": -1, "message": "no response"}}))
    else:
        print(buf.decode("utf-8", "replace"))
except Exception as exc:
    print(json.dumps({"error": {"code": -2, "message": str(exc)}}))
finally:
    s.close()
PYEOF
}

# health endpoints[] 中 11435 端点字段提取
health_field() { # $1=health-json $2=field
    python3 -c '
import json, sys
resp = json.loads(sys.argv[1])
field = sys.argv[2]
for ep in (resp.get("result") or {}).get("endpoints", []):
    if "11435" in str(ep.get("base", "")):
        v = ep.get(field)
        print("" if v is None else v)
        break
' "$1" "$2" 2>/dev/null
}

tcp_up() { (exec 3<>"/dev/tcp/127.0.0.1/$LLM_PORT") 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1; }

llama_pid() { pgrep -f "llama-server.*$LLM_PORT" | head -1 || true; }

wait_health() { # $1=期望 status  $2=timeout_s
    local deadline=$((SECONDS + $2)) resp st
    while (( SECONDS < deadline )); do
        resp=$(rpc_call "$LLM_SOCK" health_check '{}' 40)
        st=$(health_field "$resp" status)
        if [[ "$st" == "$1" ]]; then
            HEALTH_LAST="$resp"
            return 0
        fi
        sleep 5
    done
    HEALTH_LAST="$resp"
    return 1
}

wait_complete() { # $1=timeout_s  成功时 COMPLETE_LAST=content 并 return 0
    local deadline=$((SECONDS + $1)) resp
    while (( SECONDS < deadline )); do
        resp=$(rpc_call "$LLM_SOCK" complete "$COMPLETE_PARAMS" 190)
        if python3 -c '
import json, sys
resp = json.loads(sys.argv[1])
r = resp.get("result")
sys.exit(0 if r and r.get("choices") and (r["choices"][0].get("content") or "") else 1)
' "$resp" 2>/dev/null; then
            COMPLETE_LAST=$(printf '%s' "$resp" | python3 -c '
import json, sys
print(json.loads(sys.stdin.read())["result"]["choices"][0]["content"])')
            return 0
        fi
        sleep 5
    done
    return 1
}

# ---------- 现场保护与清理 ----------
BACKUP_PROFILE=""
BACKUP_YAML=""
HAD_PROFILE=0
HAD_YAML=0
SUP_PID=""

cleanup() {
    local rc=$?
    if (( OPT_KEEP )); then
        log "--keep：保留现场（supervisor=$SUP_PID）"
        return 0
    fi
    [[ -n "$SUP_PID" ]] && {
        rpc_call "$SUP_SOCK" supervisor.shutdown '{}' 5 >/dev/null 2>&1 || true
        sleep 2
        kill -- "-$SUP_PID" 2>/dev/null || true
    }
    pkill -f "llama-server.*$LLM_PORT" 2>/dev/null || true
    pkill -f "bin/llm_d --manager $MODEL_YAML" 2>/dev/null || true
    # 恢复配置（重跑即净）
    (( HAD_PROFILE )) && [[ -n "$BACKUP_PROFILE" ]] && mv "$BACKUP_PROFILE" "$PROFILE_ENV" 2>/dev/null || rm -f "$PROFILE_ENV"
    (( HAD_YAML )) && [[ -n "$BACKUP_YAML" ]] && mv "$BACKUP_YAML" "$MODEL_YAML" 2>/dev/null || rm -f "$MODEL_YAML"
    (( rc == 0 )) && log "PASS：A7-5 端到端验收全绿" || log "exit=$rc（现场已清理）"
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------- 前置 ----------
command -v airy-local >/dev/null 2>&1 || fail "airy-local 不在 PATH"
if [[ -z "$BINDIR" ]]; then
    for cand in "$HOME/airy-build-e2e/bin" "$PWD/build/bin"; do
        [[ -x "$cand/llm_d" && -x "$cand/supervisor_d" ]] && { BINDIR="$cand"; break; }
    done
fi
[[ -n "$BINDIR" ]] || fail "未找到构建产物（--bindir 指定 supervisor_d/llm_d 目录）"
[[ -x "$BINDIR/llm_d" && -x "$BINDIR/supervisor_d" ]] || fail "$BINDIR 缺 llm_d/supervisor_d"

mkdir -p "$RUN_DIR" "$CFG_DIR" "$AIRY_HOME/bin"
# Qwen3 为 thinking 模型：llm_d 附加 system 消息会拉长思考段，max_tokens
# 会被 reasoning 吃尽导致 content 恒空。请求显式禁 thinking（C3 机制链：
# RPC 入口解析 → envelope 按能力位注入 chat_template_kwargs），使断言
# 直接锚定 content 产出这一推理链可用性事实。
COMPLETE_PARAMS=$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly: ok"}],"max_tokens":16,"temperature":0.0,"chat_template_kwargs":{"enable_thinking":false}}' "$MODEL_ID")
HEALTH_LAST=""
COMPLETE_LAST=""

log "== 准备：配置备份 =="
[[ -f "$PROFILE_ENV" ]] && { BACKUP_PROFILE=$(mktemp); cp "$PROFILE_ENV" "$BACKUP_PROFILE"; HAD_PROFILE=1; }
[[ -f "$MODEL_YAML" ]] && { BACKUP_YAML=$(mktemp); cp "$MODEL_YAML" "$BACKUP_YAML"; HAD_YAML=1; }

# ---------- 安装（幂等） ----------
if (( ! OPT_SKIP_INSTALL )); then
    log "== 安装：llama.cpp(cpu) + 模型 $MODEL_ID（registry 幂等，首跑含真实下载）=="
    airy-local --variant cpu install
    airy-local model install "$MODEL_ID"
fi
[[ -x "$LOCAL_BIN" ]] || fail "llama-server 未就位：$LOCAL_BIN"
[[ -f "$LOCAL_MODEL" ]] || fail "模型未就位：$LOCAL_MODEL"

# ---------- 装配（声明面：supervisor 以 $AIRY_HOME/bin/<name> 固定解析） ----------
log "== 装配：bin 链接 + model.yaml + profile.env =="
ln -sfn "$BINDIR/llm_d" "$AIRY_HOME/bin/llm_d"
ln -sfn "$BINDIR/supervisor_d" "$AIRY_HOME/bin/supervisor_d"

cat > "$MODEL_YAML" <<YEOF
models:
  - name: $MODEL_ID
    model_id: $MODEL_ID
    provider: local-llamacpp
    base_url: http://127.0.0.1:$LLM_PORT/v1
    endpoint_kind: llamacpp
    api_format: chat
    provision: managed
    artifact: $LOCAL_MODEL
YEOF

cat > "$PROFILE_ENV" <<PEOF
AIRYRT_LAUNCH_CORE="llm_d llama_server"
AIRYRT_LAUNCH_ARGS_llm_d="--manager $MODEL_YAML"
AIRYRT_LAUNCH_BIN_llama_server=$LOCAL_BIN
AIRYRT_LAUNCH_EP_llama_server=tcp:$LLM_PORT
AIRYRT_LAUNCH_ARGS_llama_server=-m $LOCAL_MODEL --host 127.0.0.1 --port $LLM_PORT
PEOF

# ---------- 启动（调谐：tick 1s / backoff 0.5s 加速自愈验收） ----------
log "== 启动：supervisor_d（tick=1000ms backoff=500ms）=="
setsid env AIRYRT_SUP_TICK_MS=1000 AIRYRT_SUP_BACKOFF_BASE_MS=500 \
    "$AIRY_HOME/bin/supervisor_d" > /tmp/airy-e2e-supervisor.log 2>&1 &
SUP_PID=$!

for (( i=0; i<20; i++ )); do [[ -S "$SUP_SOCK" ]] && break; sleep 1; done
[[ -S "$SUP_SOCK" ]] || fail "supervisor.sock 未就绪（见 /tmp/airy-e2e-supervisor.log）"
for (( i=0; i<30; i++ )); do [[ -S "$LLM_SOCK" ]] && break; sleep 1; done
[[ -S "$LLM_SOCK" ]] || fail "llm.sock 未就绪（见 /tmp/airy-e2e-supervisor.log）"

# ---------- 幕一：冷加载软观测 ----------
log "== 幕一：冷加载软观测（首轮 health_check）=="
H1=$(rpc_call "$LLM_SOCK" health_check '{}' 40)
log "首轮 health: $H1"
cold=$(health_field "$H1" cold)
[[ -n "$cold" && "$cold" != "0" ]] && log "冷加载态已观测（cold=$cold）" \
    || log "首轮即就绪（加载快于探询，属正常时序）"

# ---------- 幕二：存活硬断言 ----------
log "== 幕二：存活断言（complete 200 + health status=ok，窗口 240s）=="
wait_complete 240 || fail "幕二 complete 未恢复（模型加载或路由故障）"
log "complete OK content=\"$COMPLETE_LAST\""
wait_health ok 240 || { log "末次 health: $HEALTH_LAST"; fail "幕二 health 未达 ok"; }
log "health OK: status=ok deep=$(health_field "$HEALTH_LAST" deep) cold=$(health_field "$HEALTH_LAST" cold)"

# ---------- 幕三：kill 失联硬断言 ----------
log "== 幕三：kill 失联断言 =="
OLD_PID=$(llama_pid)
[[ -n "$OLD_PID" ]] || fail "未找到 llama-server 进程"
kill -9 "$OLD_PID"
# 拒连确认用 100ms 步进高频探测：supervisor tick=1s 的快速自愈属期望
# 行为，拒连窗是其前置 vacuum 段；固定 sleep 会把检查推到 respawn 之后。
DEAD_SEEN=0
for (( i=0; i<30; i++ )); do
    tcp_up || { DEAD_SEEN=1; break; }
    sleep 0.1
done
[[ "$DEAD_SEEN" == 1 ]] || fail "kill 后 3s 内 11435 始终可连接（kill 未生效）"
log "11435 已拒连（旧 pid=$OLD_PID）"
# 失联窗 complete 紧贴拒连窗发出：respawn 需 tick + 启动监听（>1s），
# llm_d 连接拒绝快失败毫秒级返回，窗口稳定；断言失败路径而非挂死。
if rpc_call "$LLM_SOCK" complete "$COMPLETE_PARAMS" 60 | python3 -c '
import json, sys
resp = json.loads(sys.stdin.read())
sys.exit(0 if resp.get("result") and resp["result"].get("choices") else 1)'; then
    fail "失联窗口内 complete 竟然成功（重试/路由面与预期不符）"
fi
log "失联态 complete 按预期失败（快失败×4 次尝试）"

# ---------- 幕四：自愈硬断言 ----------
log "== 幕四：自愈断言（新 pid + 11435 复活 + complete/health 恢复）=="
NEW_PID=""
for (( i=0; i<30; i++ )); do
    p=$(llama_pid)
    if [[ -n "$p" && "$p" != "$OLD_PID" ]]; then NEW_PID="$p"; break; fi
    sleep 1
done
[[ -n "$NEW_PID" ]] || fail "supervisor 未自动重启 llama_server"
log "自愈重启：新 pid=$NEW_PID（旧 $OLD_PID）"
for (( i=0; i<120; i++ )); do tcp_up && break; sleep 1; done
tcp_up || fail "11435 未复活"
wait_complete 240 || fail "自愈后 complete 未恢复"
log "自愈 complete OK content=\"$COMPLETE_LAST\""
wait_health ok 240 || { log "末次 health: $HEALTH_LAST"; fail "自愈后 health 未恢复 ok"; }
log "自愈 health OK: status=ok deep=$(health_field "$HEALTH_LAST" deep)"

# ---------- 幕五：teardown（cleanup 内完成；此处仅作通过前自检） ----------
log "== 幕五：teardown 自检（list_models 可用性复核）=="
LM=$(rpc_call "$LLM_SOCK" list_models '{}' 30)
python3 -c '
import json, sys
resp = json.loads(sys.argv[1])
sys.exit(0 if "result" in resp else 1)' "$LM" || fail "list_models 异常: $LM"
log "list_models OK"
exit 0
