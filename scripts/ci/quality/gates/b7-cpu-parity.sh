#!/bin/bash
# Gate B-7 非 GPU 路径不减配（0.1.21 §17.2 B-7）
#
# 两段判据：
#   ① GPU 关闭（能力位未声明）时，0.1.20 的 CPU 自托管用例逐条复跑仍绿；
#   ② 九平台产物构建不受 GPU 新能力影响——不得引入 CUDA/ROCm 硬依赖；
#      非本机平台由 release.yml 对应构建腿承担，此处显式 SKIP 并带原因。
#
# 用法: b7-cpu-parity.sh [--build-dir DIR]
# 退出码: 0 = PASS；1 = FAIL；2 = 环境错误；3 = SKIP（未达，带原因）
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
BUILD="${B7_BUILD_DIR:-${QUALITY_GATE_BUILD_DIR:-}}"
while [ $# -gt 0 ]; do
    case "$1" in
        --build-dir) BUILD="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "b7: 未知参数 $1" >&2; exit 2 ;;
    esac
done

PASS=0; SKIP=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
skip() { SKIP=$((SKIP+1)); echo "  [SKIP] $1：$2"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1：$2"; }

# ── ① CPU 自托管用例（能力位全缺省 → 按旧名字选路）───────────────────────
CPU_RE='llm_d_test_(config_decl|provider_caps|service_reload|chain|route|router_integration)$'
if [ -z "$BUILD" ] || [ ! -d "$BUILD" ]; then
    skip "CPU 自托管用例复跑" "未提供 --build-dir（需已构建的测试树）"
elif ! command -v ctest >/dev/null 2>&1; then
    skip "CPU 自托管用例复跑" "本机无 ctest"
else
    # 先落变量再判定：grep -q 提前关闭管道会让写端收 SIGPIPE，在 pipefail
    # 下整条管道被判失败（曾误报 BUILD_TESTS=OFF）。此处用模式匹配，不走管道。
    REG="$(ctest --test-dir "$BUILD" -N 2>/dev/null || true)"
    case "$REG" in
        *llm_d_test_config_decl*) ;;
        *) REG="" ;;
    esac
    if [ -z "$REG" ]; then
        skip "CPU 自托管用例复跑" "$BUILD 内未构建 llm_d 测试（BUILD_TESTS=OFF？）"
    elif ctest --test-dir "$BUILD" -R "$CPU_RE" --output-on-failure >/tmp/b7-cpu-parity.log 2>&1; then
        pass "CPU 自托管用例复跑（$(grep -c 'Passed' /tmp/b7-cpu-parity.log) 项通过）"
    else
        fail "CPU 自托管用例复跑" "见 /tmp/b7-cpu-parity.log"
    fi
fi

# ── ② 九平台：先证「无 GPU 硬依赖」，再按工具链可得性判定 ────────────────
DEPS=0
for f in "$ROOT"/agent-workload/agentrt/CMakeLists.txt \
         "$ROOT"/agent-workload/agentrt/commons/CMakeLists.txt \
         "$ROOT"/agent-workload/agentrt/tools/airy_cli/CMakeLists.txt; do
    [ -r "$f" ] || continue
    if grep -Eq 'find_package\((CUDA|HIP|hip|ROCM)|link_libraries\([^)]*(cuda|nvidia|rocm)' "$f"; then
        DEPS=1
    fi
done
if [ "$DEPS" -eq 0 ]; then
    pass "九平台构建：无 CUDA/ROCm 硬依赖（GPU 为可选探测，不改变产物形态）"
else
    fail "九平台构建" "CMake 引入 GPU 硬依赖，会削减无卡平台产物"
fi

NINE="linux-x86-64 linux-x86-32 linux-arm-64 linux-arm-32 linux-riscv-64 macos-arm-64 macos-x86-64 windows-x86-64 windows-x86-32"
HOST_ARCH="$(uname -m)"; HOST_OS="$(uname -s)"
case "$HOST_OS/$HOST_ARCH" in
    Linux/x86_64) NATIVE=linux-x86-64 ;;
    Linux/i686|Linux/i386) NATIVE=linux-x86-32 ;;
    Linux/aarch64|Linux/arm64) NATIVE=linux-arm-64 ;;
    Linux/armv7l) NATIVE=linux-arm-32 ;;
    Linux/riscv64) NATIVE=linux-riscv-64 ;;
    Darwin/arm64) NATIVE=macos-arm-64 ;;
    Darwin/x86_64) NATIVE=macos-x86-64 ;;
    *) NATIVE="" ;;
esac
for p in $NINE; do
    if [ "$p" = "$NATIVE" ]; then
        pass "九平台构建 $p（本机原生，依赖面已判）"
    else
        skip "九平台构建 $p" "本机 ${HOST_OS}/${HOST_ARCH} 无该平台构建腿，由 release.yml 对应腿承担"
    fi
done

echo
echo "b7: PASS=$PASS  SKIP=$SKIP  FAIL=$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
[ "$PASS" -gt 0 ] && exit 0 || exit 3
