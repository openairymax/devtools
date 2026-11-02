#!/usr/bin/env bash
# ============================================================================
# bootstrap-cross-toolchain.sh <i686|armv7l|riscv64> —— 免 root 交叉工具链引导
#
# 六架构兼容决策（2026-08-30）：x86（x86_64/i686）、ARM（aarch64/armv7l）、
# RISC-V（riscv64/riscv32）32/64 位全兼容。本脚本为 i686 / armv7l（armhf）/
# riscv64 从 Ubuntu 仓下载交叉工具链与目标依赖库并解压到构建台（源码区外），
# 布局与 riscv64-toolchain 完全一致：
#
#   <TC>/
#     dl/                 工具链 deb（gcc/g++/binutils/libc6-*-cross，apt 递归解析）
#     dl-libs/            目标架构依赖库 deb（ports.ubuntu.com，-dev 与运行时）
#     root/               工具链二进制 + 目标 libc（cross 布局 /usr/<triple>）
#     sysroot/            第三方依赖库（multiarch 布局 usr/lib/<multiarch>）
#     toolchain-<arch>.cmake
#
# 套件自适应（0.1.20）：SUITE 取构建容器的 VERSION_CODENAME（focal/noble…），
# 可用 AIRY_SUITE 覆盖。交叉腿必须在与出包运行基线一致的发行版内 bootstrap
# ——20.04（glibc 2.31）容器里若取 noble sysroot（2.39），产物在 20.04/22.04
# 上直接 "GLIBC_2.34 not found"。依赖清单按套件分支（t64 改名仅 noble 起）。
#
# riscv64 的 cJSON/OpenSSL/libcurl/libwebsockets 不取 apt 预编译包：focal 的
# cJSON 1.7.10 缺 cJSON_GetNumberValue，且 apt libcurl 链 libssl1.1 会与
# agentrt 直链的 libssl.so.3 形成双 OpenSSL ABI（0.1.6e 根因）。四者由
# lib-builddeps.sh 交叉模式编进 sysroot，与此处 libc 同源。
#
# 用法:
#   bash bootstrap-cross-toolchain.sh i686
#   bash bootstrap-cross-toolchain.sh armv7l
#   bash bootstrap-cross-toolchain.sh riscv64
#
# 产物消费方：tools/scripts/ci/release/build.sh build_cross i686|armv7l|riscv64
#   （CMakeLists: airy_depgraph 门禁无关；此处指 agentrt 顶层 CMake 交叉配置）
# ============================================================================
set -euo pipefail

ARCH="${1:-}"
case "$ARCH" in
    i686)
        TC="i686-toolchain"; TRIPLE="i686-linux-gnu"; CMAKE_ARCH="i686"
        MULTIARCH="i386-linux-gnu"; PORT_ARCH="i386"; TUI_TARGET="i686-unknown-linux-gnu"
        TOOL_PKGS="gcc-i686-linux-gnu g++-i686-linux-gnu"
        # i386 属主归档（archive.ubuntu.com）；armhf 属 ports（armhf 为 port 架构）
        ARCH_BASE="http://archive.ubuntu.com/ubuntu"
        ;;
    armv7l)
        TC="armhf-toolchain"; TRIPLE="arm-linux-gnueabihf"; CMAKE_ARCH="armhf"
        MULTIARCH="arm-linux-gnueabihf"; PORT_ARCH="armhf"; TUI_TARGET="armv7-unknown-linux-gnueabihf"
        TOOL_PKGS="gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf"
        ARCH_BASE="https://ports.ubuntu.com/ubuntu-ports"
        ;;
    riscv64)
        TC="riscv64-toolchain"; TRIPLE="riscv64-linux-gnu"; CMAKE_ARCH="riscv64"
        MULTIARCH="riscv64-linux-gnu"; PORT_ARCH="riscv64"; TUI_TARGET="riscv64gc-unknown-linux-gnu"
        TOOL_PKGS="gcc-riscv64-linux-gnu g++-riscv64-linux-gnu"
        ARCH_BASE="https://ports.ubuntu.com/ubuntu-ports"
        ;;
    *)
        echo "用法: $0 <i686|armv7l|riscv64>"; exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UMBRELLA="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# 构建台根默认 = 伞仓同级 works-engineering（随源码仓库迁移自适应，不硬编码 $HOME）
BUILD_ROOT="${AIRY_WORKSPACE:-$(dirname "$UMBRELLA")/works-engineering}/airymaxrt-build"
TC_DIR="$BUILD_ROOT/$TC"
mkdir -p "$TC_DIR/dl" "$TC_DIR/dl-libs"
# 套件随构建容器自适应（focal=20.04 基线 / noble=24.04），AIRY_SUITE 可覆盖
if [ -n "${AIRY_SUITE:-}" ]; then
    SUITE="$AIRY_SUITE"
elif [ -r /etc/os-release ]; then
    SUITE="$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")"
else
    SUITE="noble"
fi

log() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
ok()  { echo -e "\033[0;32m[ OK ]\033[0m $*"; }

# ─── 1) 工具链 deb：apt-get download（不写系统缓存）+ 递归解析依赖 ───
cd "$TC_DIR/dl"
queue=($TOOL_PKGS)
declare -A seen=()
i=0
while [ $i -lt ${#queue[@]} ]; do
    p="${queue[$i]}"; i=$((i+1))
    [ -n "${seen[$p]:-}" ] && continue
    seen["$p"]=1
    # 仅吸收与本架构相关的依赖（triple / *-cross / binutils / cpp / gcc-N）
    # 宿主已装的同名包同样入队：root/ 必须自洽完整。crt1.o 与目标 libc
    # 随 libc6-dev-<triple>-cross 落盘，若因宿主预装而跳过，root/ 就缺这些
    # 文件，交叉配置阶段即失败（riscv64 腿 apt 预装 gcc-riscv64-linux-gnu
    # 时曾因此只有编译器、无 crt/libc）。重复下载仅多几 MB，换确定性。
    while read -r d; do
        [ -z "$d" ] && continue
        case "$d" in
            *"$TRIPLE"*|*-cross*|binutils-*|cpp-*|gcc-*|g\+\+-*)
                [ -n "${seen[$d]:-}" ] && continue
                queue+=("$d")
                ;;
        esac
    done < <(apt-cache depends "$p" 2>/dev/null | grep -oP '(?<=Depends: )[^ ]+' | sed 's/[:<>=].*//')
done
log "工具链包（${#seen[@]}）: $(printf '%s ' "${!seen[@]}" | head -c 200)..."
apt-get download "${!seen[@]}" >/dev/null 2>&1 || { echo "[FAIL] 工具链下载失败（检查 apt 源含 universe）"; exit 1; }
ok "工具链 deb 就位: $(ls *.deb 2>/dev/null | wc -l) 个"

# 解压到 root/：cross deb 布局 usr/<triple> 与 usr/bin/<triple>-*
for f in *.deb; do
    dpkg-deb -x "$f" "$TC_DIR/root/"
done
[ -x "$TC_DIR/root/usr/bin/$TRIPLE-gcc" ] || { echo "[FAIL] 工具链解压后缺 $TRIPLE-gcc"; exit 1; }
ok "工具链解压: $TC_DIR/root/usr/bin/$TRIPLE-gcc"

# ─── 2) 目标依赖库 sysroot deb：ports.ubuntu.com ───
# 依赖集与 riscv64-toolchain/dl-libs 同口径（agentrt 链接的第三方库）。
# 套件间差异只有 t64 改名（noble 起 libcurl4t64/libssl3t64/libffi8/libunistring5
# 等）与 focal 的旧 soname（libssl1.1/libldap-2.4-2/libffi7）。四依赖
# （cJSON/OpenSSL/libcurl/libwebsockets）一律不进清单：由 lib-builddeps.sh
# 交叉自编译，避免 focal 旧符号缺失与双 OpenSSL ABI。
if [ "$SUITE" = "noble" ]; then
LIBS="libcjson-dev libcjson1 libcap-dev libcap2 libcurl4-openssl-dev libcurl4t64 \
libevent-dev libevent-core-2.1-7t64 libevent-extra-2.1-7t64 libevent-openssl-2.1-7t64 libevent-pthreads-2.1-7t64 \
libmicrohttpd-dev libmicrohttpd12t64 libnghttp2-dev libnghttp2-14 libsqlite3-dev libsqlite3-0 \
libssl-dev libssl3t64 libwebsockets-dev libwebsockets19t64 zlib1g-dev zlib1g \
libkrb5-dev libkrb5-3 libgssapi-krb5-2 libk5crypto3 libkrb5support0 libcom-err2 libkeyutils1 \
libssh2-1-dev libssh2-1t64 libldap2-dev libldap2 libsasl2-2 \
libpsl-dev libpsl5t64 libidn2-dev libidn2-0 libbrotli-dev libbrotli1 \
libgcrypt20-dev libgcrypt20 libgpg-error0 libkeyutils-dev libcom-err-dev \
libsasl2-dev libsasl2-modules-db librtmp1 \
libgmp10 libgnutls30t64 libhogweed6t64 libnettle8t64 libssh-4 libunistring5 libzstd1 \
libp11-kit0 libtasn1-6 libffi8"
else
    # focal（20.04，riscv64 交叉腿基线）：pkg-config 型依赖 + 运行时 soname
    LIBS="libcap-dev libcap2 \
libevent-dev libevent-2.1-7 libevent-core-2.1-7 libevent-extra-2.1-7 \
libevent-openssl-2.1-7 libevent-pthreads-2.1-7 \
libmicrohttpd-dev libmicrohttpd12 libnghttp2-dev libnghttp2-14 \
libsqlite3-dev libsqlite3-0 zlib1g-dev zlib1g \
libkrb5-dev libkrb5-3 libgssapi-krb5-2 libk5crypto3 libkrb5support0 libcom-err2 libkeyutils1 \
libssh2-1-dev libssh2-1 libldap2-dev libldap-2.4-2 libsasl2-2 \
libpsl-dev libpsl5 libidn2-dev libidn2-0 libbrotli-dev libbrotli1 \
libgcrypt20-dev libgcrypt20 libgpg-error0 libkeyutils-dev comerr-dev \
libsasl2-dev libsasl2-modules-db librtmp1 \
libgmp10 libgnutls30 libhogweed5 libnettle7 libssh-4 libunistring2 libzstd1 \
libp11-kit0 libtasn1-6 libffi7 \
libyaml-dev libyaml-0-2 libuv1-dev libuv1 libjansson-dev libjansson4 \
libuuid1 libtirpc3 libbsd0 libmd4c0 libdouble-conversion3 libpcre2-8-0"
fi

cd "$TC_DIR/dl-libs"
IDX="/tmp/pkgs-${ARCH}-${SUITE}.txt"
: > "$IDX"
# 拉取 main + universe 的 Package 索引（xz 解压；两次拼一个文件）
for comp in main universe; do
    url="${ARCH_BASE}/dists/${SUITE}/${comp}/binary-${PORT_ARCH}/Packages.xz"
    curl -fsSL "$url" | xz -dc >> "$IDX" 2>/dev/null || echo "[WARN] $comp 索引拉取失败: $url"
done
awk '/^Package:/{p=$2} /^Filename:/{if (p != "") {f[p]=$2; p=""}} END{for (k in f) print k ":" f[k]}' \
    "$IDX" > "/tmp/pkgs-map-${ARCH}-${SUITE}.txt"
declare -A FILENAME
while read -r line; do
    [ -z "$line" ] && continue
    p="${line%%:*}"; f="${line#*:}"
    FILENAME["$p"]="$f"
done < "/tmp/pkgs-map-${ARCH}-${SUITE}.txt"

# 并行下载（xargs -P 8）：先落清单再并发拉取，已存在文件跳过（幂等断点续跑）。
# 顺序下载在慢网络下每包串行等待，61 包可能拖到小时级；并发显著提速。
: > "/tmp/dl-list-${ARCH}.txt"
for p in $LIBS; do
    f="${FILENAME[$p]:-}"
    [ -z "$f" ] && { echo "[MISS] $p"; continue; }
    base="$(basename "$f")"
    [ -f "$base" ] && continue
    printf '%s|%s|%s\n' "$p" "$base" "${ARCH_BASE}/$f" >> "/tmp/dl-list-${ARCH}.txt"
done
[ -s "/tmp/dl-list-${ARCH}.txt" ] && {
    xargs -P 8 -I{} bash -c '
        p="${1%%|*}"; rest="${1#*|}"; base="${rest%%|*}"; url="${rest#*|}"
        curl -fsSL --connect-timeout 20 --max-time 600 -o "$base" "$url" \
            && echo "[GET] $base" || echo "[FAIL] $p"
    ' _ {} < "/tmp/dl-list-${ARCH}.txt"
}
ok "依赖库 deb 就位: $(ls *.deb 2>/dev/null | wc -l) 个"

# 解压到 sysroot/（multiarch 布局 usr/lib/<multiarch> 与 usr/include）
for f in *.deb; do
    dpkg-deb -x "$f" "$TC_DIR/sysroot/"
done
[ -d "$TC_DIR/sysroot/usr/lib/$MULTIARCH" ] || { echo "[FAIL] sysroot 缺 $MULTIARCH 库目录"; exit 1; }
ok "sysroot 就位: $TC_DIR/sysroot/usr/lib/$MULTIARCH"

# ─── 3) 生成 toolchain cmake（仿 riscv64-toolchain/toolchain-riscv64.cmake）───
# armhf 默认 CPU 架构无 FPU（armv5te），须显式 -march=armv7-a（覆盖树莓派 2/3）
EXTRA_MARCH=""
[ "$ARCH" = "armv7l" ] && EXTRA_MARCH="-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard"
cat > "$TC_DIR/toolchain-${CMAKE_ARCH}.cmake" <<EOF
# ${CMAKE_ARCH} (${TRIPLE}) 交叉编译工具链 — 32 位 ${ARCH} 部署
# 由 bootstrap-cross-toolchain.sh 生成；布局同 riscv64-toolchain：
# root/ = 工具链 + libc；sysroot/ = 第三方依赖库（multiarch）。

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${ARCH})

get_filename_component(AIRY_TC_BASE "\${CMAKE_CURRENT_LIST_DIR}" REALPATH)
set(AIRY_TC_ROOT \${AIRY_TC_BASE}/root)
set(AIRY_SYSROOT \${AIRY_TC_BASE}/sysroot)
set(AIRY_TC_BIN \${AIRY_TC_ROOT}/usr/bin)

set(CMAKE_SYSROOT \${AIRY_TC_ROOT})

set(CMAKE_C_COMPILER \${AIRY_TC_BIN}/${TRIPLE}-gcc)
set(CMAKE_CXX_COMPILER \${AIRY_TC_BIN}/${TRIPLE}-g++)
set(CMAKE_ASM_COMPILER \${AIRY_TC_BIN}/${TRIPLE}-gcc)

# 交叉包的 libc 开发文件（librt.so 等）落在 root/usr/<triple>/lib，不在
# multiarch 目录下；FIND_ROOT_PATH_MODE_LIBRARY ONLY 会把它排除在
# find_library 之外，导致 glibc<2.34 上的 shm_open/shm_unlink 链接失败。
set(CMAKE_FIND_ROOT_PATH \${AIRY_TC_ROOT};\${AIRY_TC_ROOT}/usr/${TRIPLE};\${AIRY_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# 第三方 CMake config（cJSON/libwebsockets）内嵌绝对安装前缀 /usr，
# 交叉 sysroot 下 imported target 引用宿主路径而失效（i686/armhf 实测）。
# 禁用其 find_package，由 CMakeLists 的 pkg-config / find_library 回退接管
# （回退路径经 CMAKE_FIND_ROOT_PATH 自动 sysroot 化，与 riscv64 同法）。
set(CMAKE_DISABLE_FIND_PACKAGE_cJSON TRUE)
set(CMAKE_DISABLE_FIND_PACKAGE_libwebsockets TRUE)

set(CMAKE_C_FLAGS_INIT "${EXTRA_MARCH} -I\${AIRY_TC_ROOT}/usr/${TRIPLE}/include -I\${AIRY_SYSROOT}/usr/include -I\${AIRY_SYSROOT}/usr/include/${MULTIARCH}")
set(CMAKE_CXX_FLAGS_INIT "${EXTRA_MARCH} -I\${AIRY_TC_ROOT}/usr/${TRIPLE}/include -I\${AIRY_SYSROOT}/usr/include -I\${AIRY_SYSROOT}/usr/include/${MULTIARCH}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-L\${AIRY_SYSROOT}/usr/lib/${MULTIARCH} -Wl,--allow-shlib-undefined")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-L\${AIRY_SYSROOT}/usr/lib/${MULTIARCH} -Wl,--allow-shlib-undefined")

set(ENV{PKG_CONFIG_LIBDIR} \${AIRY_SYSROOT}/usr/lib/${MULTIARCH}/pkgconfig:\${AIRY_SYSROOT}/usr/share/pkgconfig)
EOF
ok "toolchain-${CMAKE_ARCH}.cmake 生成完毕"
log "工具链就绪: $TC_DIR  （build.sh ${ARCH} 将自动使用）"
