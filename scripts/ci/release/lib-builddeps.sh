#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
# ============================================================================
# AgentRT Linux 构建依赖自编译（SSoT 唯一来源）
#
# 0.1.6e 根治修复（社区用户 Ubuntu 24.04 启动失败根因）：
#   ubuntu:20.04 的 apt 预编译 libcurl/libwebsockets 链接系统 libssl.so.1.1，
#   而 llm_d/think_d/tool_d 直接链接自编译 OpenSSL 3.0.17（libssl.so.3）——
#   同一进程加载两套 OpenSSL ABI；宿主（如 Ubuntu 24.04，仅 libssl.so.3）
#   缺 libssl.so.1.1 时 libcurl.so.4 传递依赖即崩（"cannot open shared
#   object file"）。根治：自编译 libcurl 8.5.0 + libwebsockets 4.3.3，统一
#   链接 /usr/local 的 OpenSSL 3.0.17（libssl.so.3 单一链路）。
#
# 幂等：产物已存在于 /usr/local 即跳过（断点续传/重跑安全）。
# 离线缓存优先：/deps/curl-8.5.0.tar.gz、/deps/lws-4.3.3.tar.gz、
# /deps/openssl-3.0.17.tar.gz 存在则免网络下载。
#
# 调用方（容器内执行，root）：
#   build.sh build_qemu（CONTAINER_EOF 内）
#   .github/workflows/release.yml 各 Linux 构建 job
#
# 环境：DEBIAN_FRONTEND 已设置；apt 基础依赖已装（build-essential、
# libsqlite3-dev、libyaml-dev、zlib1g-dev、libzstd-dev、libevent-dev、
# libnghttp2-dev、cmake（3.29.6 源码）、python3、rust 工具链）。
# ============================================================================
set -euo pipefail

# ── cmake 3.29.6（20.04 自带 3.16 不满足最低要求）────────────────────
if ! cmake --version 2>/dev/null | grep -q "3\.29\.6"; then
    echo "[builddeps] 自编译 cmake 3.29.6 …"
    if [ -f /deps/cmake-v3.29.6.tar.gz ]; then
        tar -xzf /deps/cmake-v3.29.6.tar.gz -C /tmp
    else
        curl -fsSL --retry 3 -o /tmp/cmake.tar.gz \
            https://github.com/Kitware/CMake/releases/download/v3.29.6/cmake-3.29.6.tar.gz
        tar -xzf /tmp/cmake.tar.gz -C /tmp
    fi
    (cd /tmp/cmake-v3.29.6 && ./bootstrap --parallel="$(nproc)" --no-qt-gui --no-debugger \
        -- -DBUILD_TESTING=OFF -DBUILD_CursesDialog:BOOL=OFF \
        && make -j"$(nproc)" && make install)
fi

# ── cJSON 1.7.18（20.04 的 1.7.10 缺 cJSON_GetNumberValue）─────────────
if [ ! -f /usr/local/lib/libcjson.so ] && [ ! -f /usr/local/lib64/libcjson.so ]; then
    echo "[builddeps] 自编译 cJSON 1.7.18 …"
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

# ── OpenSSL 3.0.17 自编译（libssl.so.3 基线 + lib64 残留自愈）──────────
# 历史 bug：64 位主机默认 Configure 把 libdir 解析为 lib64，而 CMake
# FindOpenSSL/pkg-config 默认不搜 /usr/local/lib64 → 错解析到系统
# 1.1.1f（不导出 EVP_DigestSignUpdate@@OPENSSL_3.0.0）→ license_sign
# 链接失败。lib64 有残留即清理重装（幂等）。
if [ ! -f /usr/local/lib/libcrypto.a ] || [ -f /usr/local/lib64/libcrypto.a ] || \
   [ -f /usr/local/lib64/libssl.so ]; then
    echo "[builddeps] 自编译 OpenSSL 3.0.17 …"
    rm -rf /usr/local/lib64/libcrypto* /usr/local/lib64/libssl* \
        /usr/local/lib64/pkgconfig/libcrypto.pc /usr/local/lib64/pkgconfig/libssl.pc \
        /usr/local/include/openssl /usr/local/ssl
    if [ -f /deps/openssl-3.0.17.tar.gz ]; then
        cp -f /deps/openssl-3.0.17.tar.gz /tmp/openssl.tar.gz
    else
        curl -fsSL --retry 3 -o /tmp/openssl.tar.gz \
            https://github.com/openssl/openssl/releases/download/openssl-3.0.17/openssl-3.0.17.tar.gz
    fi
    tar -xzf /tmp/openssl.tar.gz -C /tmp
    OPENSSL_DIR="$(ls -d /tmp/openssl-* 2>/dev/null | head -1)"
    (cd "$OPENSSL_DIR" && ./config --prefix=/usr/local \
        --openssldir=/usr/local/ssl shared --libdir=lib \
        && make -j"$(nproc)" build_sw && make install_sw)
    ldconfig 2>/dev/null || true
else
    echo "[builddeps] OpenSSL 已就位（跳过）"
fi

# ── libcurl 8.5.0 自编译（裁剪非必需依赖）──────────────────────────────
if [ ! -f /usr/local/lib/libcurl.so ]; then
    echo "[builddeps] 自编译 libcurl 8.5.0 …"
    if [ -f /deps/curl-8.5.0.tar.gz ]; then
        cp -f /deps/curl-8.5.0.tar.gz /tmp/curl.tar.gz
    else
        curl -fsSL --retry 3 -o /tmp/curl.tar.gz \
            https://github.com/curl/curl/releases/download/curl-8_5_0/curl-8.5.0.tar.gz
    fi
    tar -xzf /tmp/curl.tar.gz -C /tmp
    CURL_DIR="$(ls -d /tmp/curl-* 2>/dev/null | head -1)"
    (cd "$CURL_DIR" && ./configure --prefix=/usr/local \
        --with-openssl=/usr/local \
        --without-nghttp2 --without-nghttp3 --without-libpsl --without-libidn2 \
        --without-brotli --without-zstd --without-librtmp --without-libssh2 \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
        --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
        --disable-smtp --disable-gopher --disable-manual --disable-debug \
        --enable-http --enable-https --enable-ftp --enable-file --with-zlib \
        && make -j"$(nproc)" && make install)
    ldconfig 2>/dev/null || true
else
    echo "[builddeps] libcurl 已就位（跳过）"
fi

# ── libwebsockets 4.3.3 自编译（gateway_d websocket 组件，libssl.so.3）───
if [ ! -f /usr/local/lib/libwebsockets.so ]; then
    echo "[builddeps] 自编译 libwebsockets 4.3.3 …"
    if [ -f /deps/lws-4.3.3.tar.gz ]; then
        cp -f /deps/lws-4.3.3.tar.gz /tmp/lws.tar.gz
    else
        curl -fsSL --retry 3 -o /tmp/lws.tar.gz \
            https://github.com/warmcat/libwebsockets/archive/refs/tags/v4.3.3.tar.gz
    fi
    tar -xzf /tmp/lws.tar.gz -C /tmp
    LWS_DIR="$(ls -d /tmp/libwebsockets-* 2>/dev/null | head -1)"
    cmake -S "$LWS_DIR" -B /tmp/lws-build \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_PREFIX_PATH=/usr/local \
        -DOPENSSL_ROOT_DIR=/usr/local \
        -DLWS_WITH_SSL=ON -DLWS_WITH_SHARED=ON -DLWS_WITH_STATIC=OFF \
        -DLWS_WITHOUT_TESTAPPS=ON -DLWS_WITHOUT_TEST_SERVER=ON \
        -DLWS_WITHOUT_TEST_SERVER_EXTPOLL=ON -DLWS_WITHOUT_TEST_CLIENT=ON \
        -DLWS_WITH_HTTP2=OFF -DLWS_WITH_MINIMAL_EXAMPLES=OFF
    cmake --build /tmp/lws-build --parallel
    cmake --install /tmp/lws-build
    ldconfig 2>/dev/null || true
else
    echo "[builddeps] libwebsockets 已就位（跳过）"
fi

# 统一 pkg-config 解析到自编译库（后续 configure/cmake 依赖此环境）
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
echo "[builddeps] 完成：OpenSSL 3.0.17 + libcurl 8.5.0 + libwebsockets 4.3.3"
