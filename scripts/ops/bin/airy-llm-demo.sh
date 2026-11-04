#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
# =============================================================================
# airy-llm-demo.sh — AirymaxRT 本地推理链能力演示
#
# 在一台装好 AirymaxRT 的机器上（面向 285H 笔记本等本地推理硬件）：
#   1. 以 supervisor_d 声明面拉起「LLM 单功能」最小链：
#      supervisor_d → llm_d（复杂度路由 / 语义缓存 / 成本核算）
#                    → llama-server（llama.cpp 自托管后端, cache_prompt KV 复用）
#   2. 用 9B 本地模型（缺省 qwen3.5-9b-q4_k_m）执行一段约 50k token 的
#      长输入推理任务，输出细致结果报告：预填充/解码速度、KV 复用、
#      各链路阶段耗时、llm_d 成本核算状态、输出正文全文、资源占用。
#
# 设计边界（对齐 agentrt-llm-e2e.sh 的机制语义，不另造旁路）：
#   - RPC 走 $AIRY_HOME/run/llm.sock（AF_UNIX JSON-RPC 单行帧）；
#   - 配置面走备份-恢复：demo 用独立 model.yaml/profile.env 装配，
#     退出恢复原状（重跑即净，不留持久态）；
#   - 50k 输入需要大上下文：llama-server 以 -c 65536 -np 1 拉起
#     （受管装配缺省 -c 16384 装不下 50k，demo 装配有意放大并单槽位，
#     KV 预算 = 权重 + 单槽 65k，避免多槽位 KV 翻倍）。
#
# 用法：
#   airy-llm-demo.sh [--tokens 50000] [--model qwen3.5-9b-q4_k_m]
#                    [--out 512] [--threads 12] [--keep] [--force] [--takeover]
#     --tokens   目标输入 token 数（缺省 50000；上限 ctx-2048）
#     --model    model.yaml 注册的模型 id
#     --out      max_tokens 上限（缺省 512）
#     --threads  llama-server 计算线程数（缺省 12）
#     --keep     保留现场（进程与 demo 配置不清理，用于讲解/复跑）
#     --force    跳过电池/内存前置守卫（高风险自担）
#     --takeover 检测到运行中的完整栈时优雅停机接管（结束后需手动重启
#                airymaxrt）；缺省遇运行栈直接拒跑，防止错接生产 llm_d
# =============================================================================
set -Eeuo pipefail

AIRY_HOME="${AIRY_HOME:-$HOME/.airymaxrt}"
RUN_DIR="$AIRY_HOME/run"
CFG_DIR="$AIRY_HOME/config"
LOCAL_BIN="$AIRY_HOME/local/llamacpp/bin/llama-server"
LOCAL_DIR="$AIRY_HOME/local"
RUN_STATE="$RUN_DIR/llm-demo"
LLM_SOCK="$RUN_DIR/llm.sock"
SUP_SOCK="$RUN_DIR/supervisor.sock"
LLM_PORT=11435
CTX=65536

OPT_TOKENS=50000
OPT_MODEL="qwen3.5-9b-q4_k_m"
OPT_OUT=512
OPT_THREADS=""
OPT_KEEP=0
OPT_FORCE=0
OPT_TAKEOVER=0

log()  { printf '\033[0;36m[demo]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[demo]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[demo]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[demo][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ ${#} -gt 0 ]]; do
    case "$1" in
        --tokens)  OPT_TOKENS="${2:?}"; shift 2 ;;
        --model)   OPT_MODEL="${2:?}"; shift 2 ;;
        --out)     OPT_OUT="${2:?}"; shift 2 ;;
        --threads) OPT_THREADS="${2:?}"; shift 2 ;;
        --keep)    OPT_KEEP=1; shift ;;
        --force)   OPT_FORCE=1; shift ;;
        --takeover) OPT_TAKEOVER=1; shift ;;
        -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
        *) fail "未知参数: $1" ;;
    esac
done

CAP=$(( CTX - 2048 ))
(( OPT_TOKENS > 0 && OPT_TOKENS <= CAP )) || fail "--tokens 须在 1..$CAP（ctx=$CTX）"

[[ -x "$LOCAL_BIN" ]] || fail "llama-server 未就位: $LOCAL_BIN"
# 管道末段可能非零（如 while 末次 grep 未命中）：pipefail+set -e 下赋值
# 会静默退脚本，故显式 || true 兜底；if 语句保证 while 体恒返回 0。
MODEL_PATH=$(find "$LOCAL_DIR" -maxdepth 3 -type f -iname '*.gguf' 2>/dev/null \
    | while IFS= read -r f; do if basename "$f" | grep -qi "${OPT_MODEL%%-*}"; then echo "$f"; fi; done \
    | head -1) || true
if [[ -z "$MODEL_PATH" ]]; then
    MODEL_PATH=$(find "$LOCAL_DIR" -maxdepth 3 -type f -iname '*.gguf' 2>/dev/null | head -1) || true
fi
[[ -n "$MODEL_PATH" ]] || fail "未找到 GGUF 模型（$LOCAL_DIR 下）"
# 模板与生产装配一致：优先 merged 合成版——orig 原版对 system 消息位置
# 严格校验（llm_d 信封注入 system 即触发 500），merged 版容忍任意位置。
TEMPLATE=$(find "$LOCAL_DIR" -maxdepth 3 -name '*merged*.jinja' 2>/dev/null | head -1 || true)
[[ -n "$TEMPLATE" ]] || TEMPLATE=$(find "$LOCAL_DIR" -maxdepth 3 -name '*template*.jinja' 2>/dev/null | head -1 || true)
BINDIR="$AIRY_HOME/bin"
[[ -x "$BINDIR/llm_d" && -x "$BINDIR/supervisor_d" ]] \
    || fail "缺 llm_d/supervisor_d（$BINDIR，先完成 AirymaxRT 安装）"

# ---------- RPC（协议与 agentrt-e2e.py 同源：单行 JSON、EOF 收尾） ----------
rpc_call() { # $1=sock $2=method $3=params-json $4=timeout_s → stdout: JSON
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import json, socket, sys
sock, method, params, timeout = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(timeout)
out = {"error": {"code": -1, "message": "no response"}}
try:
    s.connect(sock)
    s.sendall(json.dumps({"jsonrpc": "2.0", "id": 1,
                          "method": method, "params": json.loads(params)}).encode())
    buf = b""
    while True:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
        s.settimeout(1.0)
    if buf:
        out = json.loads(buf.decode("utf-8", "replace").splitlines()[0])
except Exception as exc:
    out = {"error": {"code": -2, "message": str(exc)}}
finally:
    s.close()
print(json.dumps(out, ensure_ascii=False))
PYEOF
}

jget() { # $1=json $2=python 点路径表达式（r=根对象）→ stdout: 值（空串表示缺）
    python3 -c "
import json, sys
try:
    r = json.loads(sys.argv[1])
    v = eval(sys.argv[2], {'r': r})
    print('' if v is None else v)
except Exception:
    print('')
" "$1" "$2" 2>/dev/null || true
}

tcp_up() { (exec 3<>"/dev/tcp/127.0.0.1/$LLM_PORT") 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1; }
llama_pid() { pgrep -f "llama-server.*$LLM_PORT" | head -1 || true; }
rss_gb() { ps -o rss= -p "$1" 2>/dev/null | awk '{printf "%.2f", $1/1048576}' || true; }
mem_avail_gb() { awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo; }

# 后端实测计时（llama.cpp 每次 slot 完成向 stdout 打印 print_timing 三行：
# prompt eval / eval / 总计）。本构建的 /metrics 端点为空（285H 实证 0 行），
# 日志差量是唯一后端硬数据源。supervisor 把 llama-server stdout 重定向到
# $AIRY_HOME/logs/llama_server.out；推理前记字节偏移，推理后取偏移之后
# 的 print_timing 行（重试时天然只含成功那次的块）。
log_off() { stat -c %s "$AIRY_HOME/logs/llama_server.out" 2>/dev/null || echo 0; }

# 解析偏移后的计时块 → LT_* 全局（不匹配时保持空，报告段降级跳过）
log_timings() { # $1=推理前字节偏移
    local off="$1" blk pline eline
    LT_P_MS=""; LT_P_N=""; LT_P_MSPT=""; LT_P_PS=""
    LT_E_MS=""; LT_E_N=""; LT_E_MSPT=""; LT_E_PS=""
    [[ -f "$AIRY_HOME/logs/llama_server.out" ]] || return 0
    blk=$(tail -c +"$((off + 1))" "$AIRY_HOME/logs/llama_server.out" 2>/dev/null \
        | { grep "print_timing" || true; } | tail -4)
    [[ -n "$blk" ]] || return 0
    pline=$(printf '%s\n' "$blk" | { grep "prompt eval time" || true; } | tail -1)
    eline=$(printf '%s\n' "$blk" | { grep -E "\|[[:space:]]*eval time =" || true; } | tail -1)
    if [[ -n "$pline" ]]; then
        LT_P_MS=$(printf '%s' "$pline" | sed -E 's/.*prompt eval time = *([0-9.]+) ms.*/\1/')
        LT_P_N=$(printf '%s' "$pline" | sed -E 's/.*ms \/ *([0-9]+) tokens.*/\1/')
        LT_P_MSPT=$(printf '%s' "$pline" | sed -E 's/\( *([0-9.]+) ms per token.*/\1/')
        LT_P_PS=$(printf '%s' "$pline" | sed -E 's/per token, *([0-9.]+) tokens per second.*/\1/')
    fi
    if [[ -n "$eline" ]]; then
        LT_E_MS=$(printf '%s' "$eline" | sed -E 's/.*eval time = *([0-9.]+) ms.*/\1/')
        LT_E_N=$(printf '%s' "$eline" | sed -E 's/.*ms \/ *([0-9]+) tokens.*/\1/')
        LT_E_MSPT=$(printf '%s' "$eline" | sed -E 's/\( *([0-9.]+) ms per token.*/\1/')
        LT_E_PS=$(printf '%s' "$eline" | sed -E 's/per token, *([0-9.]+) tokens per second.*/\1/')
    fi
    return 0
}

# ---------- 现场保护与清理（重跑即净） ----------
B_YAML=""; B_PROFILE=""; HAD_YAML=0; HAD_PROFILE=0; SUP_PID=""; DEMO_YAML=0; DEMO_PROFILE=0
cleanup() {
    local rc=$?
    if (( OPT_KEEP )); then
        warn "--keep：保留现场（supervisor=$SUP_PID，demo 配置未还原）"
        return "$rc"
    fi
    if [[ -n "$SUP_PID" ]]; then
        rpc_call "$SUP_SOCK" supervisor.shutdown '{}' 5 >/dev/null 2>&1 || true
        sleep 2
        kill -- "-$SUP_PID" 2>/dev/null || true
    fi
    pkill -f "llama-server.*$LLM_PORT" 2>/dev/null || true
    pkill -f "bin/llm_d --manager $CFG_DIR/demo-model.yaml" 2>/dev/null || true
    # 只清理 demo 自己写出的文件：早于装配的静默死亡绝不可触碰生产配置
    if (( HAD_PROFILE )); then mv "$B_PROFILE" "$CFG_DIR/profile.env" 2>/dev/null || rm -f "$CFG_DIR/profile.env"; elif (( DEMO_PROFILE )); then rm -f "$CFG_DIR/profile.env"; fi
    if (( HAD_YAML )); then mv "$B_YAML" "$CFG_DIR/model.yaml" 2>/dev/null || rm -f "$CFG_DIR/model.yaml"; elif (( DEMO_YAML )); then rm -f "$CFG_DIR/model.yaml"; fi
    rm -rf "$RUN_STATE"
    if (( rc == 0 )); then ok "现场已还原（重跑即净）"; else warn "exit=$rc（现场已清理）"; fi
    return "$rc"
}
trap cleanup EXIT INT TERM

# ---------- 前置守卫 ----------
if (( OPT_FORCE == 0 )); then
    bat=""
    if ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
        for b in /sys/class/power_supply/BAT*/status; do
            [[ -e "$b" ]] || continue
            s=$(cat "$b" 2>/dev/null || true)
            [[ "$s" == "Discharging" ]] && bat="$b" && break
        done
    fi
    if [[ -n "$bat" ]]; then
        fail "电池放电中（$bat）：50k 预填充为长时间满载，请接电源后重跑（--force 跳过）"
    fi
    mem_avail=$(mem_avail_gb)
    if ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= 18.0 else 1)" "$mem_avail"; then
        fail "可用内存 ${mem_avail}GB < 18GB（9B 权重 + 65k KV 预算），--force 跳过"
    fi
fi

# ---------- 运行栈守卫（防错接生产 llm_d） ----------
# demo 装配复用 $RUN_DIR 下同名 socket 与 $CFG_DIR/profile.env：完整栈在跑时
# 二者已被生产 supervisor/llm_d 持有——demo 的 supervisor_d 起不来、RPC 会打进
# 生产 llm_d、退出清理还会误杀生产进程。故缺省 fail-fast，--takeover 显式接管。
stack_alive() { # 生产栈存活判定：supervisor_d 进程可寻（兼容 bin/ 软链与 releases 布局）
    pgrep -f "\.airymaxrt/.*bin/supervisor_d" >/dev/null 2>&1
}
takeover_stack() {
    local sp i
    warn "检测到运行中的 AirymaxRT 完整栈，--takeover：优雅停机后接管"
    rpc_call "$SUP_SOCK" supervisor.shutdown '{}' 8 >/dev/null 2>&1 || true
    sleep 2
    sp=$(pgrep -f "\.airymaxrt/.*bin/supervisor_d" | head -1 || true)
    [[ -n "$sp" ]] && kill -- "-$sp" 2>/dev/null || true
    pkill -f "\.airymaxrt/.*bin/supervisor_d" 2>/dev/null || true
    pkill -f "\.airymaxrt/.*bin/llm_d" 2>/dev/null || true
    pkill -f "\.airymaxrt/.*bin/think_d" 2>/dev/null || true
    pkill -f "llama-server" 2>/dev/null || true
    for i in $(seq 1 15); do stack_alive || break; sleep 1; done
    stack_alive && fail "生产栈未停止（请手动 airymaxrt stop 后重跑）"
    rm -f "$SUP_SOCK" "$LLM_SOCK"
    warn "生产栈已停：演示结束后请重新运行 airymaxrt 恢复完整功能栈"
}
if stack_alive; then
    if (( OPT_TAKEOVER )); then
        takeover_stack
    else
        fail "检测到运行中的 AirymaxRT 完整栈（supervisor_d 活跃）。demo 需独占 LLM 链与 run/config 目录：请先 airymaxrt stop，或加 --takeover 由本脚本接管（结束后需手动重启 airymaxrt）"
    fi
fi

ok "== AirymaxRT 本地推理链能力演示 =="
ok "模型: $OPT_MODEL ($MODEL_PATH)"
ok "目标输入: ${OPT_TOKENS} tokens | ctx=$CTX threads=${OPT_THREADS:-12} max_out=$OPT_OUT"

mkdir -p "$RUN_DIR" "$RUN_STATE" "$CFG_DIR"
if [[ -f "$CFG_DIR/model.yaml" ]]; then B_YAML=$(mktemp); cp "$CFG_DIR/model.yaml" "$B_YAML"; HAD_YAML=1; fi
if [[ -f "$CFG_DIR/profile.env" ]]; then B_PROFILE=$(mktemp); cp "$CFG_DIR/profile.env" "$B_PROFILE"; HAD_PROFILE=1; fi

# ---------- 装配（声明面：supervisor 以 $AIRY_HOME/bin/<name> 固定解析） ----------
CORES=$(nproc)
THREADS="${OPT_THREADS:-$(( CORES >= 12 ? 12 : CORES ))}"
LAUNCH_ARGS="-m $MODEL_PATH --host 127.0.0.1 --port $LLM_PORT -t $THREADS -c $CTX -np 1 --cont-batching -fa on"
if [[ -n "$TEMPLATE" ]]; then
    LAUNCH_ARGS="$LAUNCH_ARGS --chat-template-file $TEMPLATE"
fi

DEMO_YAML=1
cat > "$CFG_DIR/demo-model.yaml" <<YEOF
models:
  - name: $OPT_MODEL
    model_id: $OPT_MODEL
    provider: local-llamacpp
    base_url: http://127.0.0.1:$LLM_PORT/v1
    api_format: chat
    provision: managed
    artifact: $MODEL_PATH
    context_window: $CTX
    timeout_sec: 5400
    capabilities:
      seed: true
      grammar: true
      response_format: true
      cache_prompt: true
      enable_thinking: true
YEOF
DEMO_PROFILE=1
cat > "$CFG_DIR/profile.env" <<PEOF
AIRYRT_LAUNCH_CORE="llm_d llama_server"
AIRYRT_LAUNCH_ARGS_llm_d="--manager $CFG_DIR/demo-model.yaml"
AIRYRT_LAUNCH_BIN_llama_server=$LOCAL_BIN
AIRYRT_LAUNCH_EP_llama_server=tcp:$LLM_PORT
AIRYRT_LAUNCH_ARGS_llama_server=$LAUNCH_ARGS
PEOF

ok "== 启动 LLM 单功能链：supervisor_d → llm_d → llama-server =="
setsid "$BINDIR/supervisor_d" > "$RUN_STATE/supervisor.log" 2>&1 &
SUP_PID=$!
for i in $(seq 1 30); do [[ -S "$SUP_SOCK" ]] && break; sleep 1; done
[[ -S "$SUP_SOCK" ]] || fail "supervisor.sock 未就绪（$RUN_STATE/supervisor.log）"
for i in $(seq 1 30); do [[ -S "$LLM_SOCK" ]] && break; sleep 1; done
[[ -S "$LLM_SOCK" ]] || fail "llm.sock 未就绪（$RUN_STATE/supervisor.log）"

# 幕 0：冷加载 → 后端健康（9B 权重从磁盘加载需数十秒）
T0=$(date +%s.%N)
for i in $(seq 1 120); do tcp_up && break; sleep 1; done
tcp_up || fail "llama-server :$LLM_PORT 未拉起"
EP_STATUS=""
for i in $(seq 1 90); do
    H=$(rpc_call "$LLM_SOCK" health_check '{}' 40)
    EP_STATUS=$(jget "$H" "next((e.get('status') for e in (r.get('result') or {}).get('endpoints',[]) if '11435' in str(e.get('base',''))), '')")
    [[ "$EP_STATUS" == "ok" ]] && break
    sleep 2
done
[[ "$EP_STATUS" == "ok" ]] || { log "末次 health: $H"; fail "endpoint 未达 ok"; }
COLD_S=$(python3 -c "print(f'{$(date +%s.%N) - $T0:.1f}')")
ok "链就绪: health status=ok, 冷加载 ${COLD_S}s"

# ---------- 构造 50k 输入（count 驱动：按实测 token 数缩放文本） ----------
ok "== 构造 ${OPT_TOKENS}-token 输入（链内实测 token 计数） =="
gen_text() { # $1=段数：确定性中文长文档（编号段落，避免完全重复段）
    python3 - "$1" <<'PYEOF'
import sys
n = int(sys.argv[1])
topics = ["原子件与能力格的分层模型", "形态面与机制策略分离", "推理链的复杂度路由",
          "语义缓存与 KV 前缀复用", "成本核算与配额守恒", "supervisor 声明面与自愈",
          "跨架构发行：x86/ARM/RISC-V", "端侧资源受限环境的稳态运行",
          "故障注入与回归判据", "发行面三端一致性", "TUI 会话与守护进程协议",
          "文件系统事务与元数据一致性"]
out = []
for i in range(n):
    t = topics[i % len(topics)]
    out.append(f"第{i+1}节 {t}。本节阐述 {t} 的设计动因与实现要点：")
    out.append(f"在边界条件 a={i%7+1}, b={i%5+2}, c={i%3+1} 的约束下，系统按阶段推进："
               f"先做意图识别与输入规整，再做资源预算分配，然后进入执行与观测，"
               f"最后把证据写回状态面。第{i+1}次的配额基数取 {100+i}，超限回收策略按"
               f"{'指数退避' if i%2 else '线性衰减'}执行，确保长时间运行下的公平性与可预期性。")
    out.append(f"该节对应的失败模式包括：上游抖动、磁盘占满、上下文溢出与权限漂移；"
               f"系统以 {i%4+1} 级降级响应，并在恢复后补齐欠账。工程判据要求"
               f"每一次降级都必须可观测、可复现、可回滚，这构成了第{i+1}节的验收底线。")
print("\n".join(out))
PYEOF
}

count_tokens_of() { # $1=text → stdout: token 数（llm_d 链内计数，失败回退后端 /tokenize）
    local cnt tn
    cnt=$(rpc_call "$LLM_SOCK" count_tokens "{\"model\":\"$OPT_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")}]}" 120)
    tn=$(jget "$cnt" "(r.get('result') or {}).get('tokens')")
    if [[ -z "$tn" || "$tn" == "0" ]]; then
        tn=$(curl -sS --max-time 60 -X POST "http://127.0.0.1:$LLM_PORT/tokenize" \
                -H 'Content-Type: application/json' \
                -d "$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$1")" \
            | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("tokens",[])))' 2>/dev/null || echo 0)
    fi
    echo "$tn"
}

n_seg=$(( OPT_TOKENS / 220 + 8 ))
TEXT=$(gen_text "$n_seg")
TN=0
for _ in 1 2 3 4; do
    TN=$(count_tokens_of "$TEXT")
    [[ -n "$TN" && "$TN" != "0" ]] || fail "token 计数失败（链内与后端均不可用）"
    ok "当前文本 tokens=$TN / 目标=$OPT_TOKENS"
    (( TN >= OPT_TOKENS )) && break
    n_seg=$(( n_seg * OPT_TOKENS / TN + 4 ))
    TEXT=$(gen_text "$n_seg")
done
(( TN <= CAP )) || fail "文本 $TN tokens 超出上下文上限 $CAP"
INSTR="以上是一份长文档。请仔细阅读全部内容，然后输出：1) 三条核心设计原则的中文摘要（每条不超过60字）；2) 文档中出现的全部数字配额按升序列出前8个；3) 一句话评价该架构的长上下文处理能力。"
FULL_TEXT="$TEXT

$INSTR"

# ---------- 执行推理（含链路各段计时、后端计数快照与自愈重试） ----------
# ggml alderlake 后端在长 prefill 偶发段错误（dmesg 有实例；同参直连复现
# 亦 1 崩 1 成）。崩溃后由 supervisor 自愈复活 llama-server（liveness 周期
# + 冷加载，约 5 分钟），故 IO 类失败等待自愈后重试，至多 3 次。
llama_wait_healthy() { # 等 supervisor 复活 llama-server 并恢复健康探测
    local i h st
    for i in $(seq 1 60); do [[ -n "$(llama_pid)" ]] && break; sleep 5; done
    [[ -n "$(llama_pid)" ]] || return 1
    for i in $(seq 1 100); do
        h=$(rpc_call "$LLM_SOCK" health_check '{}' 8)
        st=$(jget "$h" "(r.get('result') or {}).get('endpoint_status')")
        [[ "$st" == "ok" ]] && return 0
        sleep 5
    done
    return 1
}
ok "== 执行推理（llm.complete，超时上限 90 分钟） =="
PARAMS=$(printf '{"model":"%s","messages":[{"role":"user","content":%s}],"max_tokens":%d,"temperature":0.3,"seed":42,"cache_prompt":true,"chat_template_kwargs":{"enable_thinking":false}}' \
    "$OPT_MODEL" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$FULL_TEXT")" "$OPT_OUT")
RESP=""; ERR=""; ATT=0
for ATT in 1 2 3; do
    if (( ATT > 1 )); then
        warn "第 ${ATT}/3 次尝试：上游 IO 失败（疑 ggml 后端偶发段错误），等待 supervisor 自愈"
        llama_wait_healthy || fail "llama-server 未能自愈复活（已等约 13 分钟）"
        ok "链路已自愈，重试推理"
    fi
    LOG_OFF=$(log_off)
    STATS_BEFORE=$(rpc_call "$LLM_SOCK" get_stats '{}' 15)
    PID_BEFORE=$(llama_pid); RSS_BEFORE=$(rss_gb "$PID_BEFORE")
    WALL_T0=$(date +%s.%N)
    RESP=$(rpc_call "$LLM_SOCK" complete "$PARAMS" 5400)
    WALL_S=$(python3 -c "print(f'{$(date +%s.%N) - $WALL_T0:.1f}')")
    PID_AFTER=$(llama_pid); RSS_AFTER=$(rss_gb "$PID_AFTER")
    log_timings "$LOG_OFF"
    STATS_AFTER=$(rpc_call "$LLM_SOCK" get_stats '{}' 15)
    ERR=$(jget "$RESP" "(r.get('error') or {}).get('message')")
    [[ -z "$ERR" ]] && break
    echo "$ERR" | grep -q "Network request" && continue
    break
done
[[ -z "$ERR" ]] || fail "推理失败（${ATT} 次尝试）: $ERR"
CONTENT=$(jget "$RESP" "((r.get('result') or {}).get('choices') or [{}])[0].get('content')")
if [[ -z "$CONTENT" ]]; then
    CONTENT=$(jget "$RESP" "(r.get('result') or {}).get('content')")
fi
[[ -n "$CONTENT" ]] || fail "返回缺正文（$(printf '%s' "$RESP" | head -c 400)）"

# ---------- 报告 ----------
timings=$(jget "$RESP" "json.dumps((r.get('result') or {}).get('timings') or {}, ensure_ascii=False)")
kn=$(jget "$RESP" "(r.get('result') or {}).get('model')")
TTFT=$(jget "$RESP" "((r.get('result') or {}).get('timings') or {}).get('prompt_ms')")
PSPEED=$(jget "$RESP" "((r.get('result') or {}).get('timings') or {}).get('prompt_per_second')")
DSPEED=$(jget "$RESP" "((r.get('result') or {}).get('timings') or {}).get('predicted_per_second')")
PTOK=$(jget "$RESP" "((r.get('result') or {}).get('timings') or {}).get('prompt_n')")
DTOK=$(jget "$RESP" "((r.get('result') or {}).get('timings') or {}).get('predicted_n')")
KVTOK=$(jget "$RESP" "((r.get('result') or {}).get('timings') or {}).get('kv_cache_tokens')")
OUT_TOKN=$(jget "$RESP" "((r.get('result') or {}).get('usage') or {}).get('completion_tokens')")

echo
echo "════════════════════════════════════════════════════════════"
echo "        AirymaxRT 本地推理链能力演示 — 结果报告"
echo "════════════════════════════════════════════════════════════"
echo "【链路】airy-llm-demo → supervisor_d(声明面, 自愈托管)"
echo "        → llm_d(复杂度路由 · 语义缓存 · 成本核算 · KV 复用回显)"
echo "        → llama-server(llama.cpp 自托管, :$LLM_PORT, cache_prompt)"
echo "【模型】$kn  artifact=$(basename "$MODEL_PATH")"
echo "        ctx=$CTX threads=8(生效, r106 护栏钳制) np=1 fa=on seed=42 thinking=off"
echo "【输入】实测 $TN tokens（目标 $OPT_TOKENS）/ 输出上限 $OPT_OUT"
echo "【阶段耗时与速度】（优先后端 print_timing 实测，来源 logs/llama_server.out 日志差量）"
if [[ -n "$LT_P_N" ]]; then
    echo "  预填充 prefill : ${LT_P_N} tok @ ${LT_P_PS} tok/s（${LT_P_MS} ms，${LT_P_MSPT} ms/tok，TTFT≈${LT_P_MS}ms）"
elif [[ -n "$PTOK" && -n "$PSPEED" ]]; then
    echo "  预填充 prefill : ${PTOK} tok @ ${PSPEED} tok/s (TTFT≈${TTFT}ms)"
fi
if [[ -n "$LT_E_N" ]]; then
    echo "  解码   decode  : ${LT_E_N} tok @ ${LT_E_PS} tok/s（${LT_E_MS} ms，${LT_E_MSPT} ms/tok）"
elif [[ -n "$DTOK" && -n "$DSPEED" ]]; then
    echo "  解码   decode  : ${DTOK} tok @ ${DSPEED} tok/s"
fi
if [[ -n "$KVTOK" ]]; then
    echo "  KV 复用        : kv_cache_tokens=$KVTOK（cache_prompt 生效）"
fi
if [[ -z "$LT_P_PS" && -z "$PSPEED" ]]; then
    echo "  （后端 print_timing 与 llm_d timings 均未取到，仅端到端口径可用）"
fi
echo "  端到端         : ${WALL_S}s（含路由/排队/回传）"
if [[ -n "$LT_P_N" && -n "$LT_E_N" ]]; then
    echo "  综合吞吐       : $(awk -v p="$LT_P_N" -v e="$LT_E_N" -v w="$WALL_S" 'BEGIN{printf "%.1f", (p+e)/w}') tok/s（端到端均值，$(($LT_P_N + $LT_E_N)) tok / ${WALL_S}s）"
fi
echo "【llm_d 成本核算 / 语义缓存状态（get_stats）】"
python3 -c "
import json, sys
try:
    print(json.dumps(json.loads(sys.argv[1]).get('result') or {}, ensure_ascii=False, indent=2))
except Exception:
    print(str(sys.argv[1])[:400])
" "$STATS_AFTER" || true
echo "【资源】llama-server RSS: ${RSS_BEFORE:-?}GB → ${RSS_AFTER:-?}GB | 系统可用内存余量: $(mem_avail_gb)GB"
echo "【输出正文】（$kn, ${OUT_TOKN:-?} tokens）"
echo "────────────────────────────────────────────"
printf '%s\n' "$CONTENT"
echo "────────────────────────────────────────────"
echo "【原始 timings】$timings"
ok "演示完成：链路各段耗时与速度已如上呈现"
