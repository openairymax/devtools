#!/bin/bash
# Gate B-6 不做项与回退正面守卫（0.1.21 §17.2 B-6）
#
# 七条不做项各配一条负面守卫，两类判据：
#   ① 代码面：禁词在 GPU 服务与加速器探测面零命中（不做即不写，写了即越界）；
#   ② 命令面：七种越界选项必须被 CLI 拒绝（回退语义 fail-closed，不得静默接受）；
#   ③ 回退面：无加速器主机上 backend 必须落到 cpu（降级文案分支不可被删）。
# 任何一条命中即 FAIL，不以「以后再做」放行。
#
# 用法: b6-scope-guard.sh [--source DIR] [--cli PATH]
# 退出码: 0 = PASS；1 = FAIL；2 = 环境错误；3 = SKIP（回退面未达，带原因）
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
SRC="${B6_SRC:-$ROOT/agent-workload/agentrt}"
CLI="${B6_CLI:-${QUALITY_GATE_BUILD_DIR:+$QUALITY_GATE_BUILD_DIR/tools/airy_cli/airy_cli}}"
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SRC="${2:-}"; shift 2 ;;
        --cli) CLI="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "b6: 未知参数 $1" >&2; exit 2 ;;
    esac
done

PASS=0; SKIP=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
skip() { SKIP=$((SKIP+1)); echo "  [SKIP] $1：$2"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1：$2"; }

if [ ! -d "$SRC" ]; then
    echo "b6: 源码面不存在: $SRC（用 --source 指定 agentrt 根）" >&2
    exit 2
fi
if [ ! -x "$CLI" ]; then
    echo "b6: CLI 不存在: ${CLI:-<未指定>}（用 --cli 指定 airy_cli）" >&2
    exit 2
fi

# 七条不做项：名称 / 判据文案 / 代码面禁词（ERE）/ 命令面越界选项
ITEMS=(
    "跨进程 binder:Android binder 驱动面:/dev/binder|android/binder|libbinder:--binder"
    "跨族 MTP:多 token 预测跨模型族:\\bMTP\\b|multi_token|multi-token:--mtp"
    "iGPU 换内核:内核模块装卸面:modprobe|insmod|rmmod|dkms:--igpu-swap"
    "分布式推理:多机集合通信面:nccl|torch\\.distributed|mpirun|ray\\.init:--distributed"
    "多卡张量并行:单任务跨卡切分:tensor_parallel|tensor-parallel|tp_size:--tensor-parallel"
    "自研量化:自研量化算子:dequant|quantize_kernel|ggml_quantize:--quant-self"
    "显存复用池:自建显存池:cudaMalloc|cudaMemPool|vram_pool:--gpu-pool"
)

# 代码面扫描域：GPU 服务、加速器探测、网关协议面与内核 IPC 面。
DEAD_SCAN=(
    "$SRC/daemons/providers"
    "$SRC/commons/platform"
    "$SRC/atoms/corekern/src/ipc"
    "$SRC/gateway/src"
)

scan_item() { # <pattern> → 输出 file:line；无命中返回 1
    local pat="$1" d hit=1
    for d in "${DEAD_SCAN[@]}"; do
        [ -d "$d" ] || continue
        if grep -REn --include=*.c --include=*.h --include=*.rs "$pat" "$d" 2>/dev/null; then
            hit=0
        fi
    done
    return "$hit"
}

echo "[组1] 不做项代码面守卫（七项，命中即越界）"
for row in "${ITEMS[@]}"; do
    name="${row%%:*}"; rest="${row#*:}"
    why="${rest%%:*}"; rest="${rest#*:}"
    pat="${rest%%:*}"

    if out="$(scan_item "$pat")"; then
        fail "$name" "代码面出现实现痕迹（应不做）：
$out"
    else
        pass "$name（$why 零命中）"
    fi
done

echo "[组2] 不做项命令面守卫（越界选项必须拒绝：非零退出且提示未知）"
CLI_OUT="$(mktemp)"
for row in "${ITEMS[@]}"; do
    name="${row%%:*}"; rest="${row#*:}"; rest="${rest#*:}"
    flag="${rest##*:}"
    rc=0
    "$CLI" gpu "$flag" >"$CLI_OUT" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$name" "$flag 被静默接受（越界选项必须 fail-closed）"
    elif grep -q '不认识参数' "$CLI_OUT"; then
        pass "$name（$flag 被拒 rc=$rc）"
    else
        fail "$name" "$flag 拒绝但未说明未知参数（rc=$rc）：
$(head -2 "$CLI_OUT")"
    fi
done
rm -f "$CLI_OUT"

echo "[组3] 回退面守卫（无加速器主机必须落到 cpu）"
rc=0
GPU_JSON="$("$CLI" gpu --json 2>/dev/null)" || rc=$?
case "$GPU_JSON" in
    *'"verdict":"r3"'*)
        case "$GPU_JSON" in
            *'"backend":"cuda"'*|*'"backend":"rocm"'*|*'"backend":"vulkan"'*|\
            *'"backend":"metal"'*|*'"backend":"sycl"'*)
                # 无加速器却声称加速后端，等于把「未检出」粉饰成「已绑定」
                fail "回退到 CPU" "verdict=r3 但 backend 声称加速后端：$GPU_JSON" ;;
            *)
                pass "回退到 CPU（verdict=r3，backend 未声称加速后端）" ;;
        esac ;;
    "")
        fail "回退到 CPU" "gpu --json 无输出（rc=$rc）" ;;
    *)
        # 有加速器的主机：回退演练需 GPU 机与运行态，本档不判，具名 SKIP
        skip "回退到 CPU" "本机含加速器，需 gate:runtime 档实机演练（${GPU_JSON:0:120}）" ;;
esac

# 回退语义的代码锚点：降级文案分支不得被删，否则「落 CPU」只是运行态巧合。
if grep -q 'degraded:local_cpu' "$SRC/daemons/providers/src/core/prov_degrade.c" 2>/dev/null; then
    pass "降级文案分支在档（prov_degrade.c: degraded:local_cpu）"
else
    fail "降级文案分支" "prov_degrade.c 缺 degraded:local_cpu，回退语义无代码锚点"
fi

echo "[汇总] PASS=$PASS SKIP=$SKIP FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
[ "$SKIP" -gt 0 ] && exit 3
exit 0
