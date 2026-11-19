#!/usr/bin/env bash
# T8/P2-6 计量三档基线实测（0.1.21 L-3，判据标签 gate:lab）
#
# 计量基线 SSoT：docs-workload/140-application-development/
#   28-inference-metering-baseline.md —— 本脚本实现其 §1 档位定义、
#   §3 R1~R4/R6 判据与 §5 airy.t8.meter/1 记录，不复制阈值。
#
# 三档负载（§1，前缀缓存等效关闭：逐请求唯一前缀置于句首）：
#   a_single  单流；输入约 100~130 tok；输出 64 tok
#   b_dual    2 路并发（barrier 波次；model.yaml max_concurrent: 2）；
#             负载同 a_single
#   c_long    单流；输入 >=2048 tok；输出 64 tok
#
# 观测链（§4）：llm_d unix socket method=complete 逐请求回显
#   timings 五字段 + usage.prompt_tokens；档间以全新 AIRY_HOME 重启
#   llm_d，get_stats 只反映本档聚合（R4：meas_samples == 本档请求数）。
#
# 纪律注记：llm_d 的 cache_prompt 是能力位（providers/envelope.c 置位才
#   恒发 true，无法透传 false），故以逐请求唯一前缀达成「非缓存 prefill」
#   同等口径；样本 <100 时按 §3 只报原始值并注明 n。
#
# 用法:
#   t8-meter-baseline.sh [--bin DIR] [--llama PATH] [--model PATH.gguf]
#       [--runs N] [--port P] [--out DIR] [--keep]
# 退出码: 0 = R1~R4/R6 全绿且报告落盘；1 = 判据失败；2 = 环境缺失
set -uo pipefail

RUNS=12
PORT="${T8_PORT:-21450}"
OUT=""
KEEP=0
BIN="${T8_BIN:-}"
LLAMA="${T8_LLAMA:-}"
MODEL="${T8_MODEL:-}"

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
    case "$1" in
        --bin) BIN="$2"; shift 2 ;;
        --llama) LLAMA="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数 $1"; exit 2 ;;
    esac
done

SB="$(mktemp -d "${TMPDIR:-/tmp}/t8-meter.XXXXXX")" || exit 2
LLAMA_PID=""
LLM_PID=""
LLM_HOME=""
trap 'kill -TERM ${LLM_PID:-0} 2>/dev/null; kill -TERM ${LLAMA_PID:-0} 2>/dev/null; pkill -TERM -f "llm_d --manager $SB/" 2>/dev/null; [ "$KEEP" = 1 ] || rm -rf "$SB"' EXIT

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---- 环境探测（显式优先，出树与安装布局回退）----
if [ -n "$BIN" ] && [ -d "$BIN" ]; then BIN="$BIN/llm_d"; fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    for _c in /tmp/a6b/bin/llm_d "$HOME/.airymaxrt/current/bin/llm_d"; do
        [ -x "$_c" ] && BIN="$_c" && break
    done
fi
if [ -z "$LLAMA" ] || [ ! -x "$LLAMA" ]; then
    for _c in "$HOME/.airymaxrt/local/llamacpp/bin/llama-server" \
              /usr/local/bin/llama-server /usr/bin/llama-server; do
        [ -x "$_c" ] && LLAMA="$_c" && break
    done
fi
if [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; then
    # 探测纪律（两遍扫描，不依赖 collation）：en_US.UTF-8 下小写
    # qwen2.5-7b 分片首件排在 Qwen3-0.6B 之前（285H 实测踩坑），单遍 glob
    # 会把分片误选为首选。第一遍只取单文件，第二遍才取完整分片对。
    for _p in 1 2; do
        for _c in "$HOME"/.airymaxrt/local/models/*.gguf; do
            [ -f "$_c" ] || continue
            case "$_c" in
            *-00001-of-00002.gguf)
                # 分片首件：第二遍才取，且伴生分片必须齐备
                [ "$_p" = 2 ] \
                    && [ -f "${_c/-00001-of-00002/-00002-of-00002}" ] \
                    && MODEL="$_c" ;;
            *-of-[0-9][0-9][0-9][0-9][0-9].gguf)
                : ;; # 其余分片件（-00002-… 等）永不为候选
            *) [ "$_p" = 1 ] && MODEL="$_c" ;;
            esac
            [ -n "$MODEL" ] && break
        done
        [ -n "$MODEL" ] && break
    done
    [ -n "$MODEL" ] || MODEL=/tmp/g37-models/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf
fi
missing=0
for _f in "$BIN" "$LLAMA" "$MODEL"; do
    [ -e "$_f" ] || { echo "环境缺失: $_f"; missing=1; }
done
[ "$missing" = 0 ] || exit 2
command -v curl >/dev/null || { echo "环境缺失: curl"; exit 2; }
MODEL_ID="$(basename "$MODEL" .gguf)"
MODEL_ID="${MODEL_ID%%-00001-of-00002}"

if [ -z "$OUT" ]; then
    OUT="$(cd "$(dirname "$0")" && pwd)/evidence"
fi
mkdir -p "$OUT"

# ---- 夹具：llama-server（CPU）+ 每档全新 llm_d ----
wait_http() { # <url> <秒>
    local i=0
    while [ "$i" -lt "$2" ]; do
        curl -sf --max-time 2 "$1" >/dev/null 2>&1 && return 0
        sleep 0.5; i=$((i + 1))
    done
    return 1
}

start_backends() {
    # LD_LIBRARY_PATH 隔离：容器环境被注入旧 libstdc++ 时无损；正常机器空操作
    env -u LD_LIBRARY_PATH "$LLAMA" -m "$MODEL" --host 127.0.0.1 --port "$PORT" \
        -t "$(nproc)" -c 8192 --parallel 2 \
        >"$SB/llama.log" 2>&1 &
    LLAMA_PID=$!
    wait_http "http://127.0.0.1:$PORT/health" 240 || {
        echo "llama-server 未就绪（见 $SB/llama.log）"; exit 2; }
    say "llama-server 就绪 model=$MODEL_ID port=$PORT"
}

start_llm() { # <name> [max_concurrent] → 全新 AIRY_HOME
    local h="$SB/home-$1"
    local mc="${2:-}"
    mkdir -p "$h/config" "$h/logs"
    {
        printf 'models:\n'
        printf '  - name: t8-%s\n' "$1"
        printf '    mode: api\n'
        printf '    base_url: http://127.0.0.1:%s/v1\n' "$PORT"
        printf '    model_id: %s\n' "$MODEL_ID"
        printf '    provision: external\n'
        if [ -n "$mc" ]; then
            # B 档并发闸容量走配置面声明（llm_d svc_gate_limit：cfg>0 时
            # 兜底 /props 探测失败——285H 实测该失败路径会把多槽端点压成
            # 单流，B 档零加速）
            printf '    max_concurrent: %s\n' "$mc"
        fi
    } >"$h/config/model.yaml"
    AIRY_HOME="$h" "$BIN" --manager "$h/config/model.yaml" \
        >"$h/logs/llm.log" 2>&1 &
    LLM_PID=$!
    LLM_HOME="$h"
    local i=0
    while [ "$i" -lt 100 ]; do
        [ -S "$h/run/llm.sock" ] && break
        kill -0 "$LLM_PID" 2>/dev/null || {
            echo "llm_d($1) 启动失败（见 $h/logs/llm.log）"; exit 2; }
        sleep 0.2; i=$((i + 1))
    done
    [ -S "$h/run/llm.sock" ] || { echo "llm_d($1) socket 未就绪"; exit 2; }
    # 守护化后直连子进程即退：改记守护进程 PID，内存计量与停机都指真实进程
    LLM_PID="$(pgrep -f "llm_d --manager $h/config/model.yaml" | head -1)"
    LLM_HOME="$h" # 经全局变量交付，socket 路径取 $LLM_HOME/run/llm.sock；
                  # 调用方禁用命令替换捕获——子 shell 丢失赋值曾致 stop_llm
                  # 长期为 no-op，守护进程跨档并存
}

stop_llm() { # llm_d 守护化（双 fork 后 PPID=1）：$! 直连子进程即退，
             # 须按 manager 路径清理守护进程，否则跨档实例并存互扰
    if [ -n "$LLM_HOME" ]; then
        local pat="llm_d --manager $LLM_HOME/config/model.yaml" i=0
        pkill -TERM -f "$pat" 2>/dev/null
        while [ "$i" -lt 100 ]; do
            pgrep -f "$pat" >/dev/null 2>&1 || break
            sleep 0.2; i=$((i + 1))
        done
        pgrep -f "$pat" >/dev/null 2>&1 \
            && pkill -KILL -f "$pat" 2>/dev/null
    fi
    [ -n "$LLM_PID" ] && kill -TERM "$LLM_PID" 2>/dev/null
    wait "${LLM_PID:-0}" 2>/dev/null
    LLM_PID=""; LLM_HOME=""
}

rpc() { # <sock> <method> <params-json> [秒] → stdout（单行 JSON）
    SOCK="$1" METHOD="$2" PARAMS="$3" TMO="${4:-120}" python3 - <<'PY'
import json, os, socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(float(os.environ["TMO"]))
try:
    s.connect(os.environ["SOCK"])
except OSError as e:
    print(json.dumps({"transport_error": str(e)})); sys.exit(0)
s.sendall(json.dumps({"jsonrpc": "2.0", "id": 1,
                      "method": os.environ["METHOD"],
                      "params": json.loads(os.environ["PARAMS"] or "{}")}).encode())
buf = b""
end = time.time() + float(os.environ["TMO"])
while time.time() < end:
    try:
        c = s.recv(65536)
    except socket.timeout:
        break
    if not c:
        break
    buf += c
    try:
        json.loads(buf); break
    except ValueError:
        continue
sys.stdout.write(buf.decode("utf-8", "replace") + "\n")
PY
}

rss_kb() {
    local t=0 r
    for r in "$1" "$2"; do
        t=$((t + $(ps -o rss= -p "$r" 2>/dev/null || echo 0)))
    done
    echo "$t"
}

uniq_tag() { printf '%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM"; }

# ---- 负载构造（唯一前缀置于句首：kv 复用无从命中；/no_think 关闭 Qwen3
#      思考链——否则 reasoning_content 分流后 content 为空，端点空响应）----
# AB 负载 ~120 tok（§1 上限 256 内）：足以稀释 llama-server 逐请求固有的
# BOS 段复用（kv_cache_tokens≤3）到 R3 阈值（≤0.05）之下。
AB_BASE="You are a concise assistant working inside an automated metering benchmark. Read the unique tag embedded in this message, then reply with exactly one short declarative sentence that describes what the tag contains. Do not ask questions back. Do not apologize. Do not repeat the tag itself. Do not explain your reasoning. Keep the answer under twenty words. Answer in plain English text. Start the reply immediately with the sentence itself and stop right after the final period. Any extra preamble, markdown, or trailing commentary is considered a failed response for the purposes of this benchmark run."
mk_c_prompt() { python3 -c "
base = ('The quick brown fox jumps over the lazy dog while the calm river '
        'flows beneath the old stone bridge in the quiet valley at dawn. ')
words = base.split()
out = []
while sum(len(w) + 1 for w in out) < 2300 * 5:
    out.extend(words)
print(' '.join(out))"; }

run_one() { # <sock> <model> <prompt-file> → 单行响应追加到 stdout
    local p; p="$(cat "$3")"
    rpc "$1" complete "{\"model\":\"$2\",\"messages\":[{\"role\":\"user\",\
\"content\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$p")}\
],\"max_tokens\":64}" 180
}

tier_a() { # <sock> <jsonl>
    local i
    for i in $(seq 1 "$RUNS"); do
        printf '/no_think\n[%s] %s' "$(uniq_tag)" "$AB_BASE" >"$SB/pa.txt"
        run_one "$1" "t8-a" "$SB/pa.txt" >>"$2"
    done
}

tier_b() { # <sock> → RUNS/2 个波次，每波两路 barrier 同发同收；
           # 逐波把两路响应与波墙钟并记 b-waves.jsonl（R6 聚合口径的
           # 波次边界依据，避免无 barrier 时请求交叠致配对歧义）
    local w t0 t1 p1 p2
    : >"$SB/b-waves.jsonl"
    # 预热夹具：直连后端双路并发一发，加热 llama-server 双槽与批调度
    # （gate-diag 实证：先 seat-check 预热再测即 ~103 tps；首波冷启动
    # 会把 R6 波 1 拉到 ~33 tps）。直连不经 llm_d → 不污染 get_stats/R4
    python3 -c 'import json,sys;print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":sys.argv[2]}],"max_tokens":64}))' \
        "$MODEL_ID" "/no_think
[warmup] $AB_BASE" >"$SB/warm-req.json"
    local wpid=""
    for w in 1 2; do
        curl -sf --max-time 90 -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            -d @"$SB/warm-req.json" >"$SB/warm-$w.json" &
        wpid="$wpid $!"
    done
    wait $wpid
    for w in $(seq 1 $((RUNS / 2))); do
        printf '/no_think\n[%s] %s' "$(uniq_tag)" "$AB_BASE" >"$SB/pb1.txt"
        printf '/no_think\n[%s] %s' "$(uniq_tag)" "$AB_BASE" >"$SB/pb2.txt"
        t0=$(date +%s%3N)
        # 裸 wait 会连 llama-server 一起等（脚本常驻后台任务）→ 永久卡死；
        # 只等本波两路 PID
        run_one "$1" "t8-b1" "$SB/pb1.txt" >"$SB/w1.json" &
        p1=$!
        run_one "$1" "t8-b2" "$SB/pb2.txt" >"$SB/w2.json" &
        p2=$!
        wait "$p1" "$p2"
        t1=$(date +%s%3N)
        # $(cat) 剥掉 rpc 尾部换行：信封必须拼成单行 JSONL 才能逐行解析
        printf '{"wave":%s,"wall_ms":%s,"r1":%s,"r2":%s}\n' "$w" \
            "$((t1 - t0))" "$(cat "$SB/w1.json")" "$(cat "$SB/w2.json")" \
            >>"$SB/b-waves.jsonl"
    done
}

tier_c() { # <sock> <jsonl>
    local i
    mk_c_prompt >"$SB/pc-base.txt"
    for i in $(seq 1 "$RUNS"); do
        { printf '/no_think\n[%s] ' "$(uniq_tag)"; cat "$SB/pc-base.txt"; } \
            >"$SB/pc.txt"
        run_one "$1" "t8-c" "$SB/pc.txt" >>"$2"
    done
}

# ---- 三档采集 ----
start_backends
WALL_B=0

say "== A 单流 =="
start_llm a
T0=$(date +%s%N)
tier_a "$LLM_HOME/run/llm.sock" "$SB/a.jsonl"
T1=$(date +%s%N)
MEM_A="$(rss_kb "$LLAMA_PID" "$LLM_PID")"
rpc "$LLM_HOME/run/llm.sock" get_stats '{}' 30 >"$SB/stats-a.json"
say "A 完成 mem=${MEM_A}KB $(( (T1 - T0) / 1000000000 ))s"
stop_llm

say "== B 2 路 =="
start_llm b 2
T0=$(date +%s%N)
tier_b "$LLM_HOME/run/llm.sock"
T1=$(date +%s%N)
WALL_B=$(( (T1 - T0) / 1000000 ))
MEM_B="$(rss_kb "$LLAMA_PID" "$LLM_PID")"
rpc "$LLM_HOME/run/llm.sock" get_stats '{}' 30 >"$SB/stats-b.json"
say "B 完成 mem=${MEM_B}KB wall=${WALL_B}ms"
stop_llm

say "== C 长 prompt =="
start_llm c
tier_c "$LLM_HOME/run/llm.sock" "$SB/c.jsonl"
MEM_C="$(rss_kb "$LLAMA_PID" "$LLM_PID")"
rpc "$LLM_HOME/run/llm.sock" get_stats '{}' 30 >"$SB/stats-c.json"
say "C 完成 mem=${MEM_C}KB"
stop_llm

# ---- 判据与记录（python 只读 SB 落盘数据）----
say "== R1~R4/R6 判定 =="
BIN_VER="$(timeout 5 "$BIN" --version </dev/null 2>/dev/null | head -1)"
[ -n "$BIN_VER" ] || BIN_VER="$BIN"
SB="$SB" OUT="$OUT" RUNS="$RUNS" WALL_B="$WALL_B" BIN_VER="$BIN_VER" \
LLAMA="$LLAMA" \
MEM_A="$MEM_A" MEM_B="$MEM_B" MEM_C="$MEM_C" \
MODEL_ID="$MODEL_ID" python3 - <<'PY'
import hashlib, json, os, platform, statistics, sys
from datetime import datetime, timezone

sb, out, runs = os.environ["SB"], os.environ["OUT"], int(os.environ["RUNS"])
wall_b = float(os.environ["WALL_B"])

def rows(*files):
    got = []
    for f in files:
        p = os.path.join(sb, f)
        if not os.path.isfile(p):
            continue
        for line in open(p, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            res = r.get("result") or {}
            if isinstance(res, dict) and res.get("timings"):
                got.append(res)
    return got

def stats(f):
    p = os.path.join(sb, f)
    if not os.path.isfile(p):
        return {}
    try:
        r = json.load(open(p, encoding="utf-8", errors="replace"))
    except ValueError:
        return {}
    return (r.get("result") or {}).get("measurement") or {}

def tier_metrics(res, n_expected):
    if not res:
        return {"n": 0, "evidence": "C", "error": "no timings rows"}
    tps, pms, r2dev, pratio = [], [], 0.0, 0.0
    for r in res:
        t, u = r["timings"], r.get("usage") or {}
        pt, dms = t.get("prefill_tokens", 0), t.get("decode_ms", 0)
        dn, dt = t.get("decode_tokens", 0), t.get("prefill_ms", 0)
        # 端点口径：prefill_tokens 为实际重算量（不含 kv 命中），总量自洽
        # 判据按 prefill_tokens+kv_cache_tokens 对齐 usage.prompt_tokens
        pt_total = pt + t.get("kv_cache_tokens", 0)
        if u.get("prompt_tokens"):
            r2dev = max(r2dev, abs(pt_total - u["prompt_tokens"])
                        / u["prompt_tokens"])
        if pt:
            pratio = max(pratio, t.get("kv_cache_tokens", 0) / pt)
        if dms:
            tps.append(dn / (dms / 1000.0))
        if dt:
            pms.append(dt)
    rep = len(res) / max(n_expected, 1)
    return {"n": len(res), "report_ratio": round(rep, 4),
            "r2_dev_max": round(r2dev, 4), "prefix_ratio_max": round(pratio, 4),
            "decode_tps_raw": [round(x, 2) for x in tps],
            "prefill_ms_raw": [round(x, 1) for x in pms]}

def wave_data():
    """b-waves.jsonl → (展平 result 行列表, 波次列表)"""
    p = os.path.join(sb, "b-waves.jsonl")
    flat, waves = [], []
    if not os.path.isfile(p):
        return flat, waves
    for line in open(p, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            wv = json.loads(line)
        except ValueError:
            continue
        pair = []
        for k in ("r1", "r2"):
            env = wv.get(k) or {}
            res = env.get("result") if isinstance(env, dict) else None
            if isinstance(res, dict) and res.get("timings"):
                pair.append(res)
                flat.append(res)
        if len(pair) == 2:
            waves.append(dict(wv, pair=pair))
    return flat, waves

a = tier_metrics(rows("a.jsonl"), runs)
brows, bwaves = wave_data()
b = tier_metrics(brows, runs)
c = tier_metrics(rows("c.jsonl"), runs)

r1 = (a.get("report_ratio", 0) >= 0.95
      and b.get("report_ratio", 0) >= 0.95
      and c.get("report_ratio", 0) >= 0.95)
r2 = (a.get("r2_dev_max", 1) <= 0.02 and b.get("r2_dev_max", 1) <= 0.02
      and c.get("r2_dev_max", 1) <= 0.02)
r3 = (a.get("prefix_ratio_max", 1) <= 0.05
      and b.get("prefix_ratio_max", 1) <= 0.05
      and c.get("prefix_ratio_max", 1) <= 0.05)
mb = stats("stats-b.json")
b_n = b.get("n", 0)
r4 = b_n > 0 and mb.get("meas_samples", -1) == b_n
tps_a = a.get("decode_tps_raw") or []
# B 档墙钟聚合吞吐（含 prefill 相位），仅作记录不参与 R6 判定——
# 285H 实测与 A 档 decode_tps 直接比属相位错配（wall 内大头是 prefill）。
agg_b = (sum(r.get("timings", {}).get("decode_tokens", 0)
             for r in brows) / (wall_b / 1000.0)
         if wall_b > 0 else 0.0)
# R6 波次口径（decode 相位聚合）：barrier 同发且闸容量=2 时两路 decode
# 同窗、无排队掺入，(dt1+dt2)/max(dms1,dms2) 与 A 档 decode_tps 同相位
# 可比；逐波取最小值判 >= mean(tps_a)。285H 直连探针实证该口径下
# 2 路聚合（~94 tps）≥ 单流（~70 tps）。
wave_tps = []
for wv in bwaves:
    dms = [r["timings"].get("decode_ms", 0) for r in wv["pair"]]
    dts = [r["timings"].get("decode_tokens", 0) for r in wv["pair"]]
    m = max(dms)
    if m > 0:
        wave_tps.append(round(sum(dts) / (m / 1000.0), 2))
r6 = bool(tps_a) and bool(wave_tps) and min(wave_tps) >= statistics.mean(tps_a)
for t in (a, b, c):
    t["evidence"] = "A" if t.get("report_ratio", 0) >= 0.95 else "B"
verdict = {"r1_report_ratio": r1, "r2_metering_scale": r2,
           "r3_prefix_discernible": r3, "r4_aggregate_plus": r4,
           "r6_concurrency_floor": r6, "agg_b_tps": round(agg_b, 2),
           "r6_wave_tps_raw": wave_tps}
ok = all([r1, r2, r3, r4, r6])

machine = hashlib.sha256("|".join([
    platform.processor() or "unknown",
    str(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") // (1 << 30)),
    "cpu", platform.platform()]).encode()).hexdigest()[:16]
record = {
    "schema": "airy.t8.meter/1",
    "measured_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "machine": machine, "backend": "cpu", "model": os.environ["MODEL_ID"],
    "llm_d_bin": os.environ["BIN_VER"], "llama_bin": os.environ["LLAMA"],
    "sample_note": "n<100 只报原始值（基线 SSoT §3）",
    "tiers": {"a_single": dict(a, mem_kb=int(os.environ["MEM_A"])),
              "b_dual": dict(b, mem_kb=int(os.environ["MEM_B"]),
                             meas_samples=mb.get("meas_samples"),
                             agg_tps=round(agg_b, 2),
                             wave_wall_ms_raw=[wv.get("wall_ms")
                                               for wv in bwaves],
                             wave_tps_raw=wave_tps),
              "c_long": dict(c, mem_kb=int(os.environ["MEM_C"]))},
    "verdict": verdict, "evidence": "A" if r1 else "B"}
with open(os.path.join(out, "t8-meter-baseline.json"), "w",
          encoding="utf-8") as f:
    json.dump(record, f, ensure_ascii=False, indent=2)

def rng(xs):
    return "%s~%s" % (min(xs), max(xs)) if xs else "无"
mem = {k: os.environ[v] for k, v in
       (("A", "MEM_A"), ("B", "MEM_B"), ("C", "MEM_C"))}
lines = [
    "# T8/P2-6 计量三档基线实测报告（gate:lab）", "",
    "- 基线 SSoT：docs-workload/140-application-development/"
    "28-inference-metering-baseline.md（§1 档位 / §3 判据 / §5 记录）",
    "- 机器指纹：`%s`；后端 cpu；模型 `%s`" % (machine, os.environ["MODEL_ID"]),
    "- 缓存口径：llm_d cache_prompt 为能力位、无法透传 false，"
    "以逐请求唯一前缀达成非缓存 prefill（R3 实证 prefix_ratio）", "",
    "| 档位 | 负载 | 延迟 | 内存 | 结论 |",
    "|---|---|---|---|---|",
]
# 四列表（负载列写实测 usage 区间；延迟列写 prefill_ms / decode_tps 原始值
# 区间；内存列取实测 RSS，禁推演值）
pts_a = [r.get("usage", {}).get("prompt_tokens", 0) for r in rows("a.jsonl")]
pts_b = [r.get("usage", {}).get("prompt_tokens", 0) for r in brows]
pts_c = [r.get("usage", {}).get("prompt_tokens", 0) for r in rows("c.jsonl")]
for name, t, pts, mk in (("A 单流", a, pts_a, mem["A"]),
                         ("B 2 路", b, pts_b, mem["B"]),
                         ("C 长 prompt", c, pts_c, mem["C"])):
    lines.append(
        "| %s | 输入 %s tok；输出 64 tok；n=%d | prefill_ms %s；"
        "decode_tps %s（原始值） | %s KB | R1 %s / R2 %s / R3 %s |"
        % (name, rng(pts), t.get("n", 0),
           rng(t.get("prefill_ms_raw") or []),
           rng(t.get("decode_tps_raw") or []),
           mk,
           "绿" if t.get("report_ratio", 0) >= 0.95 else "红",
           "绿" if t.get("r2_dev_max", 1) <= 0.02 else "红",
           "绿" if t.get("prefix_ratio_max", 1) <= 0.05 else "红"))
lines += [
    "", "内存列 = llama-server 与 llm_d 常驻 RSS 合计（KB，档末采样）。",
    "", "## R1~R4/R6 判定", "",
    "| 判据 | 阈值 | 实测 | 判定 |", "|---|---|---|---|",
    "| R1 上报率 | >=0.95 | A=%s B=%s C=%s | %s |"
        % (a.get("report_ratio"), b.get("report_ratio"),
           c.get("report_ratio"), "绿" if r1 else "红"),
    "| R2 口径自洽 | 偏差<=2%% | 最大 %.2f%% | %s |"
        % (max(a.get("r2_dev_max", 0), b.get("r2_dev_max", 0),
               c.get("r2_dev_max", 0)) * 100, "绿" if r2 else "红"),
    "| R3 缓存可辨 | prefix_ratio<=0.05 | 最大 %s | %s |"
        % (max(a.get("prefix_ratio_max", 0), b.get("prefix_ratio_max", 0),
               c.get("prefix_ratio_max", 0)), "绿" if r3 else "红"),
    "| R4 聚合一致 | meas_samples==n_B | %s vs %d | %s |"
        % (mb.get("meas_samples"), b_n, "绿" if r4 else "红"),
    "| R6 并发下限 | min(波次聚合 decode_tps) >= mean(a) | %s vs %s | %s |"
        % (rng(wave_tps) if wave_tps else "无",
           round(statistics.mean(tps_a), 2) if tps_a else "?",
           "绿" if r6 else "红"),
    "", "R5 回归容差：本机无前次基线记录，判据不适用（SSoT §5 纪律 1）。",
    "", "记录：`t8-meter-baseline.json`（airy.t8.meter/1）。",
]
with open(os.path.join(out, "t8-meter-report.md"), "w",
          encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print(json.dumps(verdict, ensure_ascii=False))
sys.exit(0 if ok else 1)
PY
RC=$?
say "判定 rc=$RC（报告与记录已写入 $OUT）"
exit "$RC"
