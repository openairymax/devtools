#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
# ============================================================================
# 本地多架构二进制包构建（ARM64 / RISC-V，qemu 用户态模拟）
#
# 与 .github/workflows/release.yml 的 build-riscv64 job 对齐：在对应架构的
# ubuntu:20.04 容器内完成「依赖 → cJSON/OpenSSL 源码 → cmake 构建 → 打包」，
# 产物 agentrt-<v版本>-linux-<arch>.tar.gz 输出到源码区外的 dist 目录。
#
# 用法：
#   build-arch.sh arm64    # → linux-aarch64 包
#   build-arch.sh riscv64  # → linux-riscv64 包
# 环境变量：
#   AIRY_ARCH_IMAGE  基础镜像（默认 docker.1panel.live/library/ubuntu:20.04）
#   AIRY_VERSION     版本（默认读 agentrt/VERSION，SSoT）
#   AIRY_DIST_OUT    产物目录（默认 $HOME/.airymaxrt/dist）
# ============================================================================

set -euo pipefail

ARCH="${1:-}"
[ -n "$ARCH" ] || { echo "用法: $0 <arm64|riscv64>"; exit 1; }

case "$ARCH" in
    arm64)   PLATFORM="linux-aarch64" ;;
    riscv64) PLATFORM="linux-riscv64" ;;
    *) echo "[FAIL] 仅支持 arm64 / riscv64"; exit 1 ;;
esac

UMBRELLA="$(cd "$(dirname "$0")/../../../.." && pwd)"
VERSION_NUM="$(cat "$UMBRELLA/agent-workload/agentrt/VERSION" 2>/dev/null | tr -d '[:space:]')"
AIRY_VERSION="${AIRY_VERSION:-v${VERSION_NUM}}"
DIST_DIR="${AIRY_DIST_OUT:-${HOME}/.airymaxrt/dist}"
IMAGE="${AIRY_ARCH_IMAGE:-docker.1panel.live/library/ubuntu:20.04}"
WORK="${DIST_DIR}/.arch-build-${PLATFORM}"
PKG="agentrt-${AIRY_VERSION}-${PLATFORM}"

log_info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
log_ok()   { echo -e "\033[0;32m[ OK ]\033[0m $*"; }

mkdir -p "$WORK/build" "$WORK/pkg"
[ -n "$VERSION_NUM" ] || { echo "[FAIL] 无法读取 agentrt/VERSION"; exit 1; }

# TUI 离线 vendor 依赖（容器内 cargo 构建 agentrt-tui 用；与 build.sh
# setup_bundled_vendor 同源，避免容器内 crates.io 网络不可达导致 TUI 降级）。
# 2026-08-28 布局收敛：离线缓存统一在 developbuild 打包工作区的
# .build-cache/（deps + tui-vendor 单一落点，git 忽略），容器只读挂载，
# 不做 tgz 解包。不再引用已废弃的 developbuild/agentrt/tools/ 路径。
CACHE_BASE="${UMBRELLA}/developbuild/agentrt/.build-cache"
TUI_VENDOR_DIR="${CACHE_BASE}/tui-vendor"
DEPS_DIR="${CACHE_BASE}/deps"
TUI_CFG_DIR="${DIST_DIR}/tui-cfg"
if [ -d "$TUI_VENDOR_DIR" ]; then
    mkdir -p "$TUI_CFG_DIR"
    cat > "$TUI_CFG_DIR/config.toml" <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "/tui-vendor"
EOF
fi

log_info "构建 ${PLATFORM} 包（${AIRY_VERSION}）…"
log_info "源码树: $UMBRELLA（只读挂载） 产物: ${DIST_DIR}/"

# 容器内构建（源码只读挂载；构建/打包目录写挂载）。
# 与 CI riscv64 job 相同步骤：依赖 → cJSON/OpenSSL 源码 → cmake → TUI(降级) → 打包。
docker run --rm --platform "linux/${ARCH}" \
    -v "$UMBRELLA":/src:ro \
    -v "$WORK/build":/build \
    -v "$WORK/pkg":/pkg \
    -v "$WORK/toolchain":/usr/local \
    $([ -d "$DEPS_DIR" ] && echo "-v $DEPS_DIR:/deps:ro") \
    $([ -d "$TUI_VENDOR_DIR" ] && echo "-v $TUI_VENDOR_DIR:/tui-vendor:ro -v $TUI_CFG_DIR:/src/agent-workload/sdk/tui/.cargo:ro") \
    "$IMAGE" bash -euxo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential make perl curl git ca-certificates python3 python3-pip python3-venv \
  libsqlite3-dev libyaml-dev libcurl4-openssl-dev libssl-dev zlib1g-dev libzstd-dev \
  libmicrohttpd-dev libwebsockets-dev libevent-dev libnghttp2-dev
# cmake 安装：riscv64 无预编译 wheel，pip PEP 517 源码构建在 qemu/网络下
# 不稳定（tuna 下载大 sdist 偶发 RemoteDisconnected 断连、cmake 4.x 自带
# cmcurl 在 gcc9 + OpenSSL 1.1.1 下 openssl.c 编译失败，2026-08-29 实测两次；
# GitHub 在容器/内网亦不可达）。改为离线源码构建：
#   cmake 3.29.6：优先 /deps/cmake-v3.29.6.tar.gz（本地构建工作区缓存，
#   源自主仓 gitee.com/mirrors/cmake v3.29.6，bootstrap+make 与 20.04 工具链
#   兼容）；无缓存时回退 cmake.org 官方 tarball（海外直连，慢但可达）。
#   幂等：/usr/local 持久化挂载，已装则跳过（断点续传，qemu 下省时）。
if ! cmake --version 2>/dev/null | grep -q "3\.29\.6"; then
  if [ -f /deps/cmake-v3.29.6.tar.gz ]; then
      tar -xzf /deps/cmake-v3.29.6.tar.gz -C /tmp
  else
      curl -fsSL --retry 3 -o /tmp/cmake.tar.gz \
        https://cmake.org/files/v3.29/cmake-3.29.6.tar.gz
      tar -xzf /tmp/cmake.tar.gz -C /tmp
  fi
  (cd /tmp/cmake-v3.29.6 && ./bootstrap --parallel="$(nproc)" --no-qt-gui --no-debugger \
    -- -DBUILD_TESTING=OFF -DBUILD_CursesDialog:BOOL=OFF \
    && make -j"$(nproc)" && make install)
fi

# cJSON 1.7.18（20.04 的 1.7.10 缺 cJSON_GetNumberValue；优先 /deps 离线包，
# 网络受限环境无需访问 GitHub）
if [ ! -f /usr/local/lib/libcjson.so ] && [ ! -f /usr/local/lib64/libcjson.so ]; then
  if [ -f /deps/cJSON-1.7.18.tar.gz ]; then
      cp -f /deps/cJSON-1.7.18.tar.gz /tmp/cjson.tar.gz
  else
      curl -fsSL -o /tmp/cjson.tar.gz \
        https://github.com/DaveGamble/cJSON/archive/refs/tags/v1.7.18.tar.gz
  fi
  tar -xzf /tmp/cjson.tar.gz -C /tmp
  CJSON_DIR="$(ls -d /tmp/cJSON-* 2>/dev/null | head -1)"
  cmake -S "$CJSON_DIR" -B /tmp/cjson-build \
    -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DENABLE_CJSON_TEST=OFF -DBUILD_SHARED_LIBS=ON
  cmake --build /tmp/cjson-build --parallel
  cmake --install /tmp/cjson-build
fi

# OpenSSL 3.0.17（20.04 libssl 1.1.1 头触发 poison 编译失败；优先 /deps 离线包）
if [ ! -f /usr/local/lib/libcrypto.a ] && [ ! -f /usr/local/lib64/libcrypto.a ]; then
  if [ -f /deps/openssl-3.0.17.tar.gz ]; then
      cp -f /deps/openssl-3.0.17.tar.gz /tmp/openssl.tar.gz
  else
      curl -fsSL -o /tmp/openssl.tar.gz \
        https://github.com/openssl/openssl/releases/download/openssl-3.0.17/openssl-3.0.17.tar.gz
  fi
  tar -xzf /tmp/openssl.tar.gz -C /tmp
  OPENSSL_DIR="$(ls -d /tmp/openssl-* 2>/dev/null | head -1)"
  (cd "$OPENSSL_DIR" && ./config --prefix=/usr/local \
    --openssldir=/usr/local/ssl shared && make -j"$(nproc)" build_sw && make install_sw)
fi

# cmake 构建（Release，无测试；安装到 /pkg）。/build 持久化挂载，CMakeCache
# 存在时增量构建（断点续传），全新时完整配置。
if [ ! -f /build/CMakeCache.txt ]; then
  cmake -S /src/agent-workload/agentrt -B /build \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DENABLE_SANITIZERS=OFF \
    -DAIRY_BUILD_ALL=ON -DCMAKE_INSTALL_PREFIX=/pkg/out
fi
cmake --build /build -j"$(nproc)"
cmake --install /build

# Rust TUI（agentrt-tui，失败降级不阻断）
# 容器内 GitHub 不可达：rustup 走国内镜像 rsproxy；crates-io 依赖由
# /tui-vendor 离线 vendor 提供（.cargo/config.toml 已挂载到源码树）。
# riscv64 链接陷阱（2026-08-29 实测）：GNU ld 2.34（20.04）无法合并
# RISC-V attributes（"failed to merge target specific data"），libc 等
# crate 的 build script 链接即失败。系统无 lld 包（riscv64 20.04 仓库
# 无 lld）。修复（两轮实测后定案）：
#   1) -C linker=rust-lld 直链 → 丢系统库路径（unable to find -lc 等）
#   2) -fuse-ld=<绝对路径> → gcc9 不支持（GCC 10+ 特性）
#   最终：把工具链自带 rust-lld 复制为 /usr/local/bin/ld.lld，gcc driver
#   保留库路径查找，-fuse-ld=lld 仅换链接器（gcc8+ 官方支持）。
# 降级保护用 if ! 结构，杜绝 set -e 下误中断整体构建。
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTUP_DIST_SERVER="https://rsproxy.cn" RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"
command -v cargo >/dev/null 2>&1 || \
  curl --proto =https --tlsv1.2 -sSf https://rsproxy.cn/rustup/rustup-init.sh | sh -s -- -y --profile minimal
RUST_LLD="$(find "$HOME/.rustup" -name rust-lld -path '*riscv64*' 2>/dev/null | head -1)"
if [ -n "$RUST_LLD" ]; then
  cp -f "$RUST_LLD" /usr/local/bin/ld.lld
  chmod +x /usr/local/bin/ld.lld
fi
export CARGO_TARGET_DIR=/tmp/tui-target
if ! (cd /src/agent-workload/sdk/tui && RUSTFLAGS="-C link-arg=-fuse-ld=lld" cargo build --release); then
  echo "warn: ${ARCH} TUI 构建失败（降级为 C CLI 包装）"
else
  cp -f /tmp/tui-target/release/agentrt-tui /pkg/out/bin/ 2>/dev/null || true
fi

# Python 运行时依赖
mkdir -p /pkg/out/lib
for p in agent-workload/ecosystem/agents/airymax_agents \
         agent-workload/ecosystem/agents/airymax_agents_rs \
         agent-workload/ecosystem/agents/orchestration \
         agent-workload/sdk/sdk-python/agentrt; do
  [ -d "/src/$p" ] && cp -r "/src/$p" /pkg/out/lib/ || true
done

# config 模板 + bootstrap
mkdir -p /pkg/out/config
cp -f /src/agent-workload/ecosystem/manager/configs/agentrt.yaml /pkg/out/config/ 2>/dev/null || true
cp -f /src/agent-workload/ecosystem/manager/model/model.yaml /pkg/out/config/ 2>/dev/null || true
cp -f /src/tools/scripts/ops/templates/secrets.env.example /pkg/out/config/ 2>/dev/null || true
cp -f /src/tools/scripts/ops/templates/permission_rules.yaml /pkg/out/config/ 2>/dev/null || true
cp -f /src/tools/scripts/ops/bin/agentrt-bootstrap.sh /pkg/out/bin/ 2>/dev/null || true
# 数学计算后端（maths-toolkit：纯 Python + 安装器，无架构依赖，随包分发）
mkdir -p /pkg/out/modules
cp -rf /src/agent-workload/ecosystem/markets/tools/maths-toolkit /pkg/out/modules/ 2>/dev/null || true
' || { echo "[FAIL] 容器内构建失败"; exit 1; }

# 整理顶层目录 agentrt-<num> 并打包（与 install.sh 二进制模式匹配）
PKG_DIR="$WORK/pkg/agentrt-${VERSION_NUM}"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"
cp -rf "$WORK/pkg/out/." "$PKG_DIR/"
# 架构标记（install.sh install_binary 交叉校验）
touch "$PKG_DIR/platform-${PLATFORM#linux-}"
# 包内 manifest（与 package-full-release.sh 同格式，SSoT：checksum 权威在
# latest/manifest.stable.json，包内不内嵌校验值，防打包时刻快照漂移）
cat > "$PKG_DIR/manifest.json" <<EOF
{
  "name": "agentrt",
  "version": "${AIRY_VERSION}",
  "platform": "${PLATFORM}",
  "components": {
    "daemons": "18 (15 基础 + think_d/cupolas_d/maths_d)",
    "cli": "airy_cli",
    "tui": "agentrt-tui (rust)",
    "atoms": "prebuilt (closed source)",
    "memoryrovol": "prebuilt (commercial, optional)"
  },
  "checksum_source": "latest/manifest.stable.json"
}
EOF

# 清理 Python 缓存（pyc 无害但污染制品：__pycache__/.pytest_cache 不入包）
find "$PKG_DIR" -type d \( -name "__pycache__" -o -name ".pytest_cache" \) \
    -exec rm -rf {} + 2>/dev/null || true

( cd "$WORK/pkg" && tar -czf "$DIST_DIR/agentrt-${AIRY_VERSION}-${PLATFORM}.tar.gz" \
    "agentrt-${VERSION_NUM}" )
( cd "$DIST_DIR" && sha256sum "agentrt-${AIRY_VERSION}-${PLATFORM}.tar.gz" \
    > "agentrt-${AIRY_VERSION}-${PLATFORM}.tar.gz.sha256" )
log_ok "产物: $DIST_DIR/agentrt-${AIRY_VERSION}-${PLATFORM}.tar.gz"
