#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
# ============================================================================
# AgentRT 统一多架构构建台入口（源码区外构建，铁律 4.7）
#
# 三架构统一入口：
#   x86_64   原生构建（ccache + CMakeCache 持久增量）
#   arm64    qemu 用户态模拟（toolchain/apt 持久挂载 + 离线 deps 缓存）
#   riscv64  交叉编译优先（gcc-13 riscv64 cross + sysroot 依赖库，10-20×
#            快于 qemu；工具链缺失或 AIRY_CROSS=0 时回退 qemu 模拟）
#
# 目录约定（唯一构建台，均位于源码区外）：
#   ${AIRY_WORKSPACE:-$HOME/SpharxWorks/works-engineering}/airymaxrt-build/
#     native/               x86_64 原生 build（CMakeCache 持久 → 增量编译）
#     .ccache/              ccache 缓存（跨次构建复用）
#     tui-target/           cargo 统一 target（杜绝源码树内 target 落盘）
#     deps/                 cJSON/OpenSSL/cmake 离线 tarball（迁移自 developbuild）
#     tui-vendor/           cargo 离线 vendor
#     riscv64-toolchain/    riscv64 交叉工具链（gcc-13 + sysroot 依赖库 +
#                           toolchain-riscv64.cmake，从 ports.ubuntu.com deb 解压）
#     riscv64-cross/        riscv64 交叉 build（CMakeCache 持久 → 增量）
#     <arch>/ <arch>-toolchain/ <arch>-pkg/   qemu 容器构建/工具链/打包工作区
#   ${AIRY_DIST_OUT:-$UMBRELLA/developbuild/agentrt/dist}   统一产物台
#       （developbuild 为发布工作区：出包后由 publish-release.sh 上传 atomgit；
#         可用 AIRY_DIST_OUT 覆盖到其他目录）
#
# 用法：
#   build.sh <x86_64|arm64|riscv64> [--clean]
# 环境变量：
#   AIRY_WORKSPACE   构建台根（默认 $HOME/SpharxWorks/works-engineering）
#   AIRY_DIST_OUT    产物台（默认 $UMBRELLA/developbuild/agentrt/dist）
#   AIRY_VERSION     版本覆盖（默认读 agentrt/VERSION，SSoT）
#   AIRY_ARCH_IMAGE  arm64/riscv64 基础镜像
#   AIRY_BUILD_JOBS  并行编译数（默认 nproc）
#   AIRY_CROSS       0=riscv64 强制 qemu 模拟（默认 1 交叉编译）
#   SKIP_TUI=1       跳过 Rust TUI 构建（快速迭代）
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-package.sh"

UMBRELLA="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
AGENTRT_TREE="$UMBRELLA/agent-workload/agentrt"
TUI_SRC="$UMBRELLA/agent-workload/sdk/tui"

ARCH="${1:-}"
[ -n "$ARCH" ] || { echo "用法: $0 <x86_64|arm64|riscv64> [--clean]"; exit 1; }
CLEAN=0
[ "${2:-}" = "--clean" ] && CLEAN=1

case "$ARCH" in
    x86_64) PLATFORM="linux-x64" ;;
    i686)   PLATFORM="linux-x86" ;;
    arm64)  PLATFORM="linux-arm64" ;;
    armv7l) PLATFORM="linux-arm32" ;;
    riscv64) PLATFORM="linux-riscv64" ;;
    riscv32) PLATFORM="linux-riscv32" ;;
    *) echo "[FAIL] 仅支持 x86_64 / i686 / arm64 / armv7l / riscv64 / riscv32"; exit 1 ;;
esac

# ─── 构建台与产物台（构建台源码区外；产物台=发布工作区 developbuild） ───
AIRY_WORKSPACE="${AIRY_WORKSPACE:-${HOME}/SpharxWorks/works-engineering}"
BUILD_ROOT="${AIRY_WORKSPACE}/airymaxrt-build"
# 产物台默认 developbuild/agentrt/dist（发布工作区：build.sh 出包 →
# publish-release.sh 上传 atomgit 的单一落点）；AIRY_DIST_OUT 可覆盖。
DIST_DIR="${AIRY_DIST_OUT:-${UMBRELLA}/developbuild/agentrt/dist}"
JOBS="${AIRY_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"
SKIP_TUI="${SKIP_TUI:-0}"

pkg_setup_version "$AGENTRT_TREE"

log_info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
log_ok()   { echo -e "\033[0;32m[ OK ]\033[0m $*"; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }

mkdir -p "$BUILD_ROOT" "$DIST_DIR"
log_info "构建台: $BUILD_ROOT"
log_info "产物台: $DIST_DIR  版本: ${AIRY_VERSION}  (${PLATFORM})"

# ─── 离线依赖缓存定位：优先构建台 deps/tui-vendor；回退 developbuild 旧缓存 ─
LEGACY_CACHE="$UMBRELLA/developbuild/agentrt/.build-cache"
DEPS_DIR="${BUILD_ROOT}/deps"
TUI_VENDOR_DIR="${BUILD_ROOT}/tui-vendor"
[ -d "$DEPS_DIR" ] || { [ -d "$LEGACY_CACHE/deps" ] && { cp -rn "$LEGACY_CACHE/deps" "$BUILD_ROOT/" 2>/dev/null || true; }; }
[ -d "$TUI_VENDOR_DIR" ] || { [ -d "$LEGACY_CACHE/tui-vendor" ] && { cp -rn "$LEGACY_CACHE/tui-vendor" "$BUILD_ROOT/" 2>/dev/null || true; }; }

# ─── 统一打包：组装 pkg/out → agentrt-<num> 顶层目录 → tar.gz ──────────
pkg_assemble() {
    pkg_assemble_full "$1" "$AIRY_VERSION" "$PLATFORM" "$UMBRELLA"
}

# ═══════════════════════════ x86_64：原生构建 ═══════════════════════════
build_native() {
    log_info "x86_64 原生构建（ccache + 增量）…"
    local build="$BUILD_ROOT/native"
    local stage="$BUILD_ROOT/stage-${VERSION_NUM}"
    local out="$stage/agentrt-${VERSION_NUM}"

    # ccache 持久化（跨次构建复用；缺失则跳过仅告警）
    if command -v ccache >/dev/null 2>&1; then
        export CCACHE_DIR="$BUILD_ROOT/.ccache"
        CCACHE_LAUNCHER="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
        log_ok "ccache 启用: $CCACHE_DIR"
    else
        CCACHE_LAUNCHER=""
        log_warn "ccache 未安装，建议 apt install ccache（跨次构建大幅加速）"
    fi

    # stage 打包目录每次全新组装（防跨架构污染：三架构共用
    # stage-<ver> 时 riscv64 交叉产物会覆盖 x86_64 bin/，0.1.6 实测）。
    # build/ 构建目录保留（CMakeCache 增量），CLEAN 时连 build 一起清。
    if [ "$CLEAN" = "1" ]; then rm -rf "$build" "$stage"; else rm -rf "$stage"; fi
    mkdir -p "$build" "$stage"

    # INSTALL_PREFIX 漂移检测：CMakeCache 固化的是上次版本的 stage
    # 路径（0.1.5a → stage-0.1.5a），版本 bump 后若不重新配置，
    # cmake --install 落错目录导致包内缺二进制/.so（0.1.6 实测）。
    if [ -f "$build/CMakeCache.txt" ]; then
        local cached_prefix
        cached_prefix="$(sed -n 's/^CMAKE_INSTALL_PREFIX:\([A-Za-z]*\)=//p' "$build/CMakeCache.txt" | head -1)"
        if [ -n "$cached_prefix" ] && [ "$cached_prefix" != "$out" ]; then
            log_warn "INSTALL_PREFIX 漂移（缓存 ${cached_prefix} → ${out}），重新 cmake 配置"
            cmake -S "$AGENTRT_TREE" -B "$build" \
                -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DENABLE_SANITIZERS=OFF \
                -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
                -DCMAKE_INSTALL_PREFIX="$out" \
                $CCACHE_LAUNCHER
        fi
    fi

    if [ ! -f "$build/CMakeCache.txt" ]; then
        cmake -S "$AGENTRT_TREE" -B "$build" \
            -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DENABLE_SANITIZERS=OFF \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            -DCMAKE_INSTALL_PREFIX="$out" \
            $CCACHE_LAUNCHER
    fi
    cmake --build "$build" -j"$JOBS"
    cmake --install "$build" >/dev/null || true
    # 未装 INSTALL 的二进制（CLI 等）直接从 build 目录收集
    [ -d "$out/bin" ] || mkdir -p "$out/bin"
    for d in "$build"/bin/*; do
        [ -f "$d" ] && cp -f "$d" "$out/bin/" 2>/dev/null || true
    done

    # Rust TUI（CARGO_TARGET_DIR 统一到构建台，杜绝源码树 target 落盘）
    if [ "$SKIP_TUI" != "1" ] && [ -d "$TUI_SRC" ] && { command -v cargo >/dev/null 2>&1 || [ -x "${HOME}/.cargo/bin/cargo" ]; }; then
        log_info "构建 agentrt-tui…"
        export PATH="${HOME}/.cargo/bin:$PATH"
        TUI_CFG_DIR="$BUILD_ROOT/tui-cfg"
        if [ -d "$TUI_VENDOR_DIR" ]; then
            mkdir -p "$TUI_CFG_DIR"
            cat > "$TUI_CFG_DIR/config.toml" <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$TUI_VENDOR_DIR"
EOF
        fi
        # CARGO_TARGET_DIR 必须 export：未 export 时 cargo 落盘源码树
        # sdk/tui/target（0.1.6 实测 376MB 污染 + TUI 未进包，cp 静默失败）
        export CARGO_TARGET_DIR="$BUILD_ROOT/tui-target"
        # cargo 无 -c 选项（0.1.6 实测 Usage 报错）；vendor 配置经
        # --config 注入（cargo 1.66+），不写源码树 .cargo/ 避免污染。
        if ( cd "$TUI_SRC" && cargo build --release ${TUI_CFG_DIR:+--config "$TUI_CFG_DIR/config.toml"} ); then
            if cp -f "$BUILD_ROOT/tui-target/release/agentrt-tui" "$out/bin/" 2>/dev/null; then
                log_ok "agentrt-tui 已就位（$(ls -la "$out/bin/agentrt-tui" | awk '{print $5}') 字节）"
            else
                echo "warn: agentrt-tui 复制失败（cargo 产物未找到）"
            fi
        else
            echo "warn: x86_64 TUI 构建失败（降级为 C CLI 包装）"
        fi
    fi

    pkg_assemble "$out"
    pkg_tar_package "$stage" "agentrt-${VERSION_NUM}" "$DIST_DIR" \
        "agentrt-${AIRY_VERSION}-${PLATFORM}.tar.gz"
    log_ok "产物: $DIST_DIR/agentrt-${AIRY_VERSION}-${PLATFORM}.tar.gz"
}

# ═══════════════ arm64 / riscv64：qemu 容器构建 ═════════════════════════
build_qemu() {
    local qemu_arch="$1" cname="${1}"
    local work="$BUILD_ROOT/${cname}"
    local pkg_dir="$work/pkg"
    local toolchain="$work/toolchain"
    local image="${AIRY_ARCH_IMAGE:-docker.1panel.live/library/ubuntu:20.04}"

    log_info "${ARCH} qemu 构建（toolchain/pkg 持久挂载）…"
    mkdir -p "$work" "$pkg_dir" "$toolchain"
    if [ "$CLEAN" = "1" ]; then
        rm -rf "$pkg_dir/out"
        rm -f "$work/build/CMakeCache.txt"
    fi

    TUI_CFG_DIR="$BUILD_ROOT/tui-cfg"
    if [ -d "$TUI_VENDOR_DIR" ]; then
        mkdir -p "$TUI_CFG_DIR"
        cat > "$TUI_CFG_DIR/config.toml" <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "/tui-vendor"
EOF
    fi

    (
    docker run -i --rm --platform "linux/${qemu_arch}" \
        -v "$UMBRELLA":/src:ro \
        -v "$work/build":/build \
        -v "$pkg_dir":/pkg \
        -v "$toolchain":/usr/local \
        $([ -d "$DEPS_DIR" ] && echo "-v $DEPS_DIR:/deps:ro") \
        $([ -d "$TUI_VENDOR_DIR" ] && echo "-v $TUI_VENDOR_DIR:/tui-vendor:ro -v $TUI_CFG_DIR:/src/agent-workload/sdk/tui/.cargo:ro") \
        -e SKIP_TUI="${SKIP_TUI:-0}" \
        -e ARCH="${qemu_arch}" \
        -e AIRY_APT_MIRROR="${AIRY_APT_MIRROR:-}" \
        "$image" bash -euxo pipefail -s <<'CONTAINER_EOF'
export DEBIAN_FRONTEND=noninteractive
# 0.1.6f 修复：容器 DNS 常返回 IPv6 AAAA，宿主无 IPv6 路由时 apt 走
# IPv6 连接挂起（2026-08-30 实测 apt-get update 卡死 >7 分钟）。强制
# apt 只用 IPv4，网络不可达时快速失败而非无限等待。
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
# 0.1.6f 提速：国内网络访问 archive.ubuntu.com 极慢（TCP 可连但吞吐
# 极低），支持 AIRY_APT_MIRROR 换镜像源（镜像根，脚本自动补 /ubuntu
# 路径；基础镜像无 ca-certificates，须用 http 协议：本地构建台设
# AIRY_APT_MIRROR=http://mirrors.aliyun.com；CI 海外 runner 不设、
# 保持官方源，两者互不影响）。
if [ -n "${AIRY_APT_MIRROR:-}" ]; then
  sed -i -e "s|http://archive.ubuntu.com/ubuntu|${AIRY_APT_MIRROR}/ubuntu|g" \
         -e "s|http://security.ubuntu.com/ubuntu|${AIRY_APT_MIRROR}/ubuntu|g" \
         /etc/apt/sources.list
fi
# 0.1.6b 系统性修复：apt 依赖在容器系统层，docker run 每次新建实例即丢失。
# 历史 bug：.agentrt-deps-installed 标志固化在持久 /usr/local 卷，导致新容器
# 实例跳过 apt 安装而 gcc 等已随旧实例销毁（2026-08-30 实测 cmake bootstrap
# 报 Cannot find appropriate C compiler）。改为每次实例都安装（1-2 分钟，
# apt 层缓存命中快）；cmake/openssl/cJSON 等源码级依赖仍由持久 /usr/local
# 缓存（断点续传），两套机制解耦，不再用标志文件把系统层安装与持久层
# 缓存错误绑定。
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential make perl curl git ca-certificates python3 python3-pip python3-venv \
  libsqlite3-dev libyaml-dev libcurl4-openssl-dev libssl-dev zlib1g-dev libzstd-dev \
  libmicrohttpd-dev libwebsockets-dev libevent-dev libnghttp2-dev
# 0.1.6e SSoT：cmake/cJSON/OpenSSL/libcurl/libwebsockets 自编译逻辑收敛到
# lib-builddeps.sh（单一权威，CI release.yml 各 Linux job 同源调用），
# 幂等（已就位即跳过），离线 deps 缓存优先。curl 8.5.0 + lws 4.3.3 统一
# 链接自编译 OpenSSL 3.0.17（libssl.so.3），根治宿主缺 libssl.so.1.1 崩溃。
bash /src/tools/scripts/ci/release/lib-builddeps.sh
# 配置漂移自愈：0.1.6b 起 configure 必须携带 -DOPENSSL_ROOT_DIR=/usr/local
# （FindOpenSSL 唯一解析到自编译 3.0.17）；0.1.6e 起同时携带
# -DCMAKE_PREFIX_PATH=/usr/local（FindCURL 优先命中自编译 libcurl，否则
# 命中 apt 的 /usr/lib/.../libcurl.so.4 → 链接 libssl.so.1.1 崩溃链）。
# 且配置前 export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig：libwebsockets
# 等走 pkg-config 的依赖必须命中自编译 4.3.3（libssl.so.3），否则 pkg-config
# 按默认目录顺序命中系统 libwebsockets.pc（4.1.0 → libssl.so.1.1）。
# 漂移检测同时覆盖 libwebsockets 解析：lws 走 find_package 的 config-mode
# （cache 变量 libwebsockets_DIR），非 pkg-config（无 pkgcfg_lib_* 条目）；
# cache 未命中自编译 /usr/local 即重配，否则 gateway 回退系统 apt 版
# （libssl.so.1.1 崩溃链）。
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
if [ ! -f /build/CMakeCache.txt ] || ! grep -q "OPENSSL_ROOT_DIR:.*=/usr/local" /build/CMakeCache.txt \
   || ! grep -q "CMAKE_PREFIX_PATH:.*=/usr/local" /build/CMakeCache.txt \
   || ! grep -q "libwebsockets_DIR:PATH=/usr/local/lib/cmake/libwebsockets" /build/CMakeCache.txt; then
  rm -f /build/CMakeCache.txt
  cmake -S /src/agent-workload/agentrt -B /build \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DENABLE_SANITIZERS=OFF \
    -DAIRY_BUILD_ALL=ON -DCMAKE_INSTALL_PREFIX=/pkg/out \
    -DOPENSSL_ROOT_DIR=/usr/local -DCMAKE_PREFIX_PATH=/usr/local
fi
cmake --build /build -j"$(nproc)"
cmake --install /build

# 0.1.6b 缺陷修复：运行时 .so 自包含收集（在容器内按目标 glibc 基线
# ldd 解析，宿主收集会带入构建主机更新的系统库破坏可移植性）。系统
# 核心库（libc/libm/libgcc_s/ld-linux 等）豁免，由目标系统提供。
# 注意：不依赖 file 命令（基础镜像未装，2026-08-30 实测收集全跳过）；
# ldd 对脚本/静态链接二进制输出 "not a dynamic executable"/"statically
# linked"，awk 解析无有效路径自然跳过，无需 file 预判。
# 0.1.6b 第二坑（2026-08-30 实测）：自编译 openssl/cJSON 装 /usr/local/lib
# 后未跑 ldconfig → 动态链接器不知道 /usr/local/lib → 收集时 ldd 对
# libcrypto.so.3 等报 not found → lib/ 漏收自编译库。ldconfig 注册
# /usr/local/lib（Ubuntu 默认 /etc/ld.so.conf.d/libc.conf 已含）后 ldd
# 才能解析全部依赖。
ldconfig 2>/dev/null || true
mkdir -p /pkg/out/lib
# 0.1.6e 根治修复（Ubuntu 24.04 社区崩溃根因）：收集前清空残留动态库，
# 并以 LD_LIBRARY_PATH 指向 /usr/local/lib，使 ldd 解析到自编译
# openssl 3.0.17 / curl 8.5.0（libssl.so.3 统一链路），而非系统 apt 库
# （libcurl 7.68 → libssl.so.1.1 → 宿主缺该库即崩）。此前 RUNPATH
# （$ORIGIN/../lib=/pkg/out/lib）优先命中上次收集残留的旧库，自编译
# libcurl 虽已链接却从未被收集。清空后再收集保证 ldd 无旧库可命中。
rm -f /pkg/out/lib/*.so.* 2>/dev/null || true
export LD_LIBRARY_PATH=/usr/local/lib
for b in /pkg/out/bin/*; do
  ldd "$b" 2>/dev/null | awk '{print $1, $3}' | while read -r n p; do
    case "$n" in
      linux-vdso*|ld-linux*|libc.so.*|libm.so.*|libgcc_s.so.*|libpthread.so.*|librt.so.*|libdl.so.*) continue ;;
    esac
    [ -n "$p" ] && [ -f "$p" ] && cp -f "$p" /pkg/out/lib/ 2>/dev/null || true
  done
done
touch /pkg/out/lib/.collected

# Rust TUI（agentrt-tui，失败降级不阻断；已装则跳过——qemu 下 cargo 全量
# 重编极慢）。riscv64 链接陷阱（2026-08-29 实测）：GNU ld 2.34 无法合并
# RISC-V attributes，需将 rust-lld 复制为 /usr/local/bin/ld.lld 并用
# -fuse-ld=lld 仅换链接器（gcc driver 保留库路径查找）。
if [ ! -f /pkg/out/bin/agentrt-tui ] && [ "${SKIP_TUI:-0}" != "1" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
  export RUSTUP_DIST_SERVER="https://rsproxy.cn" RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"
  command -v cargo >/dev/null 2>&1 || \
    curl --proto =https --tlsv1.2 -sSf https://rsproxy.cn/rustup/rustup-init.sh | sh -s -- -y --profile minimal
  # 0.1.6b：链接器按需。riscv64 必须换 lld（GNU ld 2.34 无法合并 RISC-V
  # attributes）；arm64/x86_64 GNU ld 正常，且容器内未必有 rust-lld
  # （2026-08-30 实测 arm64 容器无 riscv64 路径的 rust-lld → 无条件
  # -fuse-ld=lld 报 collect2: cannot find ld）。有 rust-lld 才切 lld。
  RUST_LD_ARG=""
  RUST_LLD="$(find "$HOME/.rustup" -name rust-lld 2>/dev/null | head -1)"
  if [ -n "$RUST_LLD" ]; then
    cp -f "$RUST_LLD" /usr/local/bin/ld.lld
    chmod +x /usr/local/bin/ld.lld
    RUST_LD_ARG="-C link-arg=-fuse-ld=lld"
  fi
  export CARGO_TARGET_DIR=/tmp/tui-target
  if ! (cd /src/agent-workload/sdk/tui && \
      RUSTFLAGS="-C link-arg=-Wl,-rpath,\$ORIGIN/../lib ${RUST_LD_ARG}" cargo build --release); then
    echo "warn: ${ARCH} TUI 构建失败（降级为 C CLI 包装）"
  else
    cp -f /tmp/tui-target/release/agentrt-tui /pkg/out/bin/ 2>/dev/null || true
  fi
fi
CONTAINER_EOF
    ) || { echo "[FAIL] 容器内构建失败"; exit 1; }

    # 整理顶层目录并打包（容器内 TUI/资源组装在宿主机完成，与 x86_64 同链）
    local stage="$BUILD_ROOT/stage-${VERSION_NUM}"
    local out="$stage/agentrt-${VERSION_NUM}"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -rf "$pkg_dir/out/." "$out/"
    pkg_assemble "$out"
    # 容器内收集标记不入包（lib/.collected 仅宿主跳过收集用）
    rm -f "$out/lib/.collected"
    pkg_tar_package "$stage" "agentrt-${VERSION_NUM}" "$DIST_DIR" \
        "agentrt-${AIRY_VERSION}-${PLATFORM}.tar.gz"
    log_ok "产物: $DIST_DIR/agentrt-${AIRY_VERSION}-${PLATFORM}.tar.gz"
}

# ═══════════ riscv64 / arm64：交叉编译（默认，10-20× 快于 qemu 模拟）═══════
# 两架构共用一套交叉构建逻辑，按 arch 区分工具链/sysroot/TUI target。
build_cross() {
    local arch="$1"
    local tc build toolchain_file readelf sysroot tui_target tui_linker tui_var
    case "$arch" in
        riscv64)
            tc="$BUILD_ROOT/riscv64-toolchain"
            build="$BUILD_ROOT/riscv64-cross"
            toolchain_file="$tc/toolchain-riscv64.cmake"
            readelf="$tc/root/usr/bin/riscv64-linux-gnu-readelf"
            sysroot="$tc/sysroot"
            tui_target="riscv64gc-unknown-linux-gnu"
            tui_linker="$tc/root/usr/bin/riscv64-linux-gnu-gcc"
            # binutils 运行库（libopcodes/libbfd-riscv64）在工具链 root 内，
            # 非标准 RUNPATH，必须显式 LD_LIBRARY_PATH；后续 lld 需要的
            # rustup libLLVM 同样经 LD_LIBRARY_PATH，两者合并（勿覆盖）。
            export LD_LIBRARY_PATH="$tc/root/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
            # RISC-V TUI 链接定案（2026-08-29 三轮回测）：
            #   GNU ld 2.34 无法合并 RISC-V attributes（failed to merge target
            #   specific data）→ 必须换 lld；rust-lld 直链又丢系统库路径
            #   （unable to find -lc）→ 以 gcc 为 driver，仅 `-fuse-ld=lld`
            #   换链接器，配合 `--sysroot` 让 lld 解析 cross multiarch libc。
            #   ld.lld 取自 rustup 工具链自带 rust-lld，复制到 GNU ld 同目录
            #   （riscv64-linux-gnu/bin/），collect2 按 -B 路径即可找到。
            #   gcc9 不支持 -fuse-ld=绝对路径（GCC10+ 特性），勿再尝试。
            if [ ! -x "$tc/root/usr/riscv64-linux-gnu/bin/ld.lld" ]; then
                local rust_lld
                rust_lld="$(find "$HOME/.rustup/toolchains" -name rust-lld -path '*/lib/rustlib/x86_64-unknown-linux-gnu/bin/*' 2>/dev/null | head -1)"
                [ -n "$rust_lld" ] && cp -f "$rust_lld" "$tc/root/usr/riscv64-linux-gnu/bin/ld.lld"
                chmod 755 "$tc/root/usr/riscv64-linux-gnu/bin/ld.lld" 2>/dev/null || true
            fi
            # lld 运行依赖 rustup 工具链的 libLLVM 共享库（追加，勿覆盖
            # 上面已合并的 binutils 路径）
            export RUSTFLAGS="-C link-arg=-fuse-ld=lld -C link-arg=-Wl,--sysroot=${tc}/root"
            export LD_LIBRARY_PATH="${HOME}/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib:${LD_LIBRARY_PATH:-}"
            ;;
        arm64)
            tc="$BUILD_ROOT/cross-sysroot/arm64-sysroot"
            build="$BUILD_ROOT/arm64-cross"
            toolchain_file="$tc/toolchain-aarch64.cmake"
            readelf="/usr/bin/aarch64-linux-gnu-readelf"
            sysroot="$tc"
            tui_target="aarch64-unknown-linux-gnu"
            tui_linker="aarch64-linux-gnu-gcc"
            ;;
        i686)
            # 32 位 x86（i686）：交叉工具链 + sysroot 从 Ubuntu noble deb 解压
            # （免 root），布局同 riscv64-toolchain（root/ 工具链 + sysroot/ 依赖库）。
            tc="$BUILD_ROOT/i686-toolchain"
            build="$BUILD_ROOT/i686-cross"
            toolchain_file="$tc/toolchain-i686.cmake"
            readelf="$tc/root/usr/bin/i686-linux-gnu-readelf"
            sysroot="$tc/sysroot"
            tui_target="i686-unknown-linux-gnu"
            tui_linker="$tc/root/usr/bin/i686-linux-gnu-gcc"
            # binutils 运行库（libbfd/libopcodes-i386）在工具链 root 内，
            # 非标准 RUNPATH，必须显式 LD_LIBRARY_PATH（同 riscv64 分支）。
            export LD_LIBRARY_PATH="$tc/root/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
            ;;
        armv7l)
            # 32 位 ARM（armhf）：交叉工具链 + sysroot 从 Ubuntu noble armhf deb
            # 解压（树莓派 32 位用户空间正解，2026-08-30 兼容决策）。
            tc="$BUILD_ROOT/armhf-toolchain"
            build="$BUILD_ROOT/armhf-cross"
            toolchain_file="$tc/toolchain-armhf.cmake"
            readelf="$tc/root/usr/bin/arm-linux-gnueabihf-readelf"
            sysroot="$tc/sysroot"
            tui_target="armv7-unknown-linux-gnueabihf"
            tui_linker="$tc/root/usr/bin/arm-linux-gnueabihf-gcc"
            # binutils 运行库（libbfd/libopcodes-armhf）在工具链 root 内，
            # 非标准 RUNPATH，必须显式 LD_LIBRARY_PATH（同 riscv64 分支）。
            export LD_LIBRARY_PATH="$tc/root/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
            ;;
        riscv32)
            # 32 位 RISC-V（ilp32d）：glibc 用户态生态极新（2.41+），Ubuntu
            # noble 无 riscv32 libc，预编译包暂不可行；检测正确后回退源码构建。
            # 预留工具链路径，未来 riscv32 musl/glibc 工具链可用时直接填充。
            tc="$BUILD_ROOT/riscv32-toolchain"
            build="$BUILD_ROOT/riscv32-cross"
            toolchain_file="$tc/toolchain-riscv32.cmake"
            readelf="$tc/root/usr/bin/riscv32-linux-gnu-readelf"
            sysroot="$tc/sysroot"
            tui_target="riscv32gc-unknown-linux-gnu"
            tui_linker="$tc/root/usr/bin/riscv32-linux-gnu-gcc"
            ;;
        *) log_err "build_cross: 不支持的架构 $arch"; return 1 ;;
    esac
    log_info "${arch} 交叉编译（${toolchain_file}）…"
    local stage="$BUILD_ROOT/stage-${VERSION_NUM}"
    local out="$stage/agentrt-${VERSION_NUM}"
    # stage 每次全新组装（与 build_native 同规则，防跨架构污染）
    if [ "$CLEAN" = "1" ]; then rm -rf "$build" "$stage"; else rm -rf "$stage"; fi
    mkdir -p "$build" "$stage"
    # INSTALL_PREFIX 漂移检测（同 build_native：版本 bump 后 CMakeCache
    # 固化旧 stage 路径，install 落错目录导致包内缺二进制/.so）
    # 同时处理"缓存残留但构建文件缺失"（上次配置失败后残留 CMakeCache
    # 而无 Makefile，直接 cmake --build 报 "No rule to make target"）。
    if [ -f "$build/CMakeCache.txt" ]; then
        local cached_prefix needs_reconf=0
        cached_prefix="$(sed -n 's/^CMAKE_INSTALL_PREFIX:\([A-Za-z]*\)=//p' "$build/CMakeCache.txt" | head -1)"
        [ -n "$cached_prefix" ] && [ "$cached_prefix" != "$out" ] && needs_reconf=1
        { [ ! -f "$build/Makefile" ] && [ ! -f "$build/build.ninja" ]; } && needs_reconf=1
        if [ "$needs_reconf" = "1" ]; then
            log_warn "CMake 缓存失效（prefix 漂移或构建文件缺失），重新配置"
            cmake -S "$AGENTRT_TREE" -B "$build" \
                -DCMAKE_TOOLCHAIN_FILE="$toolchain_file" \
                -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DENABLE_SANITIZERS=OFF \
                -DAIRY_BUILD_ALL=ON -DCMAKE_INSTALL_PREFIX="$out"
        fi
    fi
    if [ ! -f "$build/CMakeCache.txt" ]; then
        cmake -S "$AGENTRT_TREE" -B "$build" \
            -DCMAKE_TOOLCHAIN_FILE="$toolchain_file" \
            -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DENABLE_SANITIZERS=OFF \
            -DAIRY_BUILD_ALL=ON -DCMAKE_INSTALL_PREFIX="$out"
    fi
    cmake --build "$build" -j"$JOBS"
    cmake --install "$build" >/dev/null || true
    for d in "$build"/bin/*; do
        [ -f "$d" ] && cp -f "$d" "$out/bin/" 2>/dev/null || true
    done
    [ -d "$out/bin" ] || mkdir -p "$out/bin"
    # Rust TUI 交叉编译（rustup target；宿主无 cargo/工具链则降级）
    if [ "$SKIP_TUI" != "1" ] && [ -d "$TUI_SRC" ] && { command -v cargo >/dev/null 2>&1 || [ -x "${HOME}/.cargo/bin/cargo" ]; }; then
        export PATH="${HOME}/.cargo/bin:$PATH"
        rustup target list --installed 2>/dev/null | grep -q "$tui_target" || \
            rustup target add "$tui_target" 2>/dev/null || true
        export CARGO_TARGET_DIR="$BUILD_ROOT/${arch}-tui-target"
        # cargo 按 target 名大写（- → _）约定 linker 环境变量
        tui_var="CARGO_TARGET_$(printf '%s' "$tui_target" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_LINKER"
        export "$tui_var=$tui_linker"
        if ( cd "$TUI_SRC" && cargo build --release --target "$tui_target" 2>/dev/null ); then
            cp -f "$BUILD_ROOT/${arch}-tui-target/$tui_target/release/agentrt-tui" \
                "$out/bin/" 2>/dev/null || true
        else
            echo "warn: ${arch} TUI 交叉构建失败（降级为 C CLI 包装）"
        fi
    fi
    # 打包：交叉产物用 readelf 收集 NEEDED（宿主 ldd 无法分析异架构 ELF）
    pkg_assemble_full "$out" "$AIRY_VERSION" "$PLATFORM" "$UMBRELLA" \
        "$readelf" "$sysroot"
    pkg_tar_package "$stage" "agentrt-${VERSION_NUM}" "$DIST_DIR" \
        "agentrt-${AIRY_VERSION}-${PLATFORM}.tar.gz"
    log_ok "产物: $DIST_DIR/agentrt-${AIRY_VERSION}-${PLATFORM}.tar.gz"
}

case "$ARCH" in
    x86_64)
        # 0.1.6b：x86_64 默认走 ubuntu:20.04 容器构建（glibc 2.31 基线，
        # 保证旧发行版可运行；--platform linux/amd64 在 x86 主机原生执行，
        # 无 qemu 开销）。容器内同时完成 .so 收集（目标基线）。开发迭代
        # 可用 AIRY_NATIVE=1 切回宿主原生构建（仅本机可跑，不可发布）。
        if [ "${AIRY_NATIVE:-0}" = "1" ]; then
            build_native
        else
            build_qemu x86_64
        fi
        ;;
    arm64)
        if [ "${AIRY_CROSS:-1}" = "1" ] && [ -f "$BUILD_ROOT/cross-sysroot/arm64-sysroot/toolchain-aarch64.cmake" ] \
            && command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
            build_cross arm64
        else
            log_warn "arm64 交叉工具链缺失或 AIRY_CROSS=0，回退 qemu 模拟"
            build_qemu arm64
        fi
        ;;
    riscv64)
        if [ "${AIRY_CROSS:-1}" = "1" ] && [ -f "$BUILD_ROOT/riscv64-toolchain/toolchain-riscv64.cmake" ]; then
            build_cross riscv64
        else
            log_warn "交叉工具链缺失或 AIRY_CROSS=0，回退 qemu 模拟"
            build_qemu riscv64
        fi
        ;;
    i686)
        # 32 位 x86：交叉工具链（i686-toolchain）存在则交叉编译；缺失回退 qemu
        if [ "${AIRY_CROSS:-1}" = "1" ] && [ -f "$BUILD_ROOT/i686-toolchain/toolchain-i686.cmake" ]; then
            build_cross i686
        else
            log_warn "i686 交叉工具链缺失或 AIRY_CROSS=0，回退 qemu 模拟（需 qemu-i386 多架构容器）"
            build_qemu i686
        fi
        ;;
    armv7l)
        # 32 位 ARM（armhf，树莓派 32 位用户空间正解）：交叉工具链优先
        if [ "${AIRY_CROSS:-1}" = "1" ] && [ -f "$BUILD_ROOT/armhf-toolchain/toolchain-armhf.cmake" ]; then
            build_cross armv7l
        else
            log_warn "armhf 交叉工具链缺失或 AIRY_CROSS=0，回退 qemu 模拟（需 qemu-arm 多架构容器）"
            build_qemu armv7l
        fi
        ;;
    riscv32)
        # 32 位 RISC-V（ilp32d）：glibc 用户态生态极新（2.41+），Ubuntu noble
        # 无 riscv32 libc，预编译包暂不可行（build_cross case 已预留工具链
        # 路径）。检测正确后回退源码构建：AIRY_MODE=source bash install.sh。
        log_err "riscv32 预编译包暂不可用：glibc riscv32 用户态生态未就绪"
        log_err "请使用源码构建：AIRY_MODE=source bash install.sh"
        exit 1
        ;;
esac

log_ok "${PLATFORM} 构建完成"
