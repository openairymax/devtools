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
    x86_64) PLATFORM="linux-x86_64" ;;
    arm64)  PLATFORM="linux-aarch64" ;;
    riscv64) PLATFORM="linux-riscv64" ;;
    *) echo "[FAIL] 仅支持 x86_64 / arm64 / riscv64"; exit 1 ;;
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
        "$image" bash -euxo pipefail -s <<'CONTAINER_EOF'
export DEBIAN_FRONTEND=noninteractive
# 依赖仅首装一次：toolchain 持久挂载 /usr/local（.agentrt-deps-installed
# 标志文件判定），后续构建跳过 apt 与源码编译（断点续传，qemu 下省时）。
# 历史慢因根治：旧脚本每次 docker run 重建容器后都重新 apt-get update+install
# 全部依赖（几分钟）；固化到 toolchain 后仅首装一次。
if [ ! -f /usr/local/.agentrt-deps-installed ]; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    build-essential make perl curl git ca-certificates python3 python3-pip python3-venv \
    libsqlite3-dev libyaml-dev libcurl4-openssl-dev libssl-dev zlib1g-dev libzstd-dev \
    libmicrohttpd-dev libwebsockets-dev libevent-dev libnghttp2-dev
  touch /usr/local/.agentrt-deps-installed
fi
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
if [ ! -f /build/CMakeCache.txt ]; then
  cmake -S /src/agent-workload/agentrt -B /build \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DENABLE_SANITIZERS=OFF \
    -DAIRY_BUILD_ALL=ON -DCMAKE_INSTALL_PREFIX=/pkg/out
fi
cmake --build /build -j"$(nproc)"
cmake --install /build

# Rust TUI（agentrt-tui，失败降级不阻断；已装则跳过——qemu 下 cargo 全量
# 重编极慢）。riscv64 链接陷阱（2026-08-29 实测）：GNU ld 2.34 无法合并
# RISC-V attributes，需将 rust-lld 复制为 /usr/local/bin/ld.lld 并用
# -fuse-ld=lld 仅换链接器（gcc driver 保留库路径查找）。
if [ ! -f /pkg/out/bin/agentrt-tui ] && [ "${SKIP_TUI:-0}" != "1" ]; then
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
  if ! (cd /src/agent-workload/sdk/tui && RUSTFLAGS="-C link-arg=-fuse-ld=lld -C link-arg=-Wl,-rpath,\$ORIGIN/../lib" cargo build --release); then
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
    if [ -f "$build/CMakeCache.txt" ]; then
        local cached_prefix
        cached_prefix="$(sed -n 's/^CMAKE_INSTALL_PREFIX:\([A-Za-z]*\)=//p' "$build/CMakeCache.txt" | head -1)"
        if [ -n "$cached_prefix" ] && [ "$cached_prefix" != "$out" ]; then
            log_warn "INSTALL_PREFIX 漂移（缓存 ${cached_prefix} → ${out}），重新 cmake 配置"
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
    x86_64) build_native ;;
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
esac

log_ok "${PLATFORM} 构建完成"
