#!/usr/bin/env bash
# shellcheck shell=bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# AgentRT 取数机制模块
# 职责：镜像序列取件 + 断点续传 + 尺寸核对 + sha256 fail-closed。
# 机制与策略分离：本模块只提供"取一件并验证"的机制，不感知任何组件的 pin 数据；
# pin 解析、镜像序列编排属于策略层（见 bin/airy-local）。
# 校验语义（0.1.19 教训）：下载完成判据必须核对真实 size，不许模糊判断；
# 尺寸吻合但 sha256 不符即毒件，立即终止且不自动重试。
# 库模块不设置 shell 选项，严格模式由 common.sh 统一负责

###############################################################################
# 幂等保护
###############################################################################
if [[ -n "${_AGENTRT_FETCH_LIB_LOADED:-}" ]]; then
    return 0
fi
_AGENTRT_FETCH_LIB_LOADED=1

###############################################################################
# 公共API：取文件 sha256（sha256sum / shasum 双回退）
###############################################################################
fetch_sha256_of() {
    local file="$1"
    if command -v sha256sum &> /dev/null; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum &> /dev/null; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        airy_log_error "No sha256 tool available (need sha256sum or shasum)"
        return 1
    fi
}

###############################################################################
# 公共API：取文件字节尺寸（GNU stat / BSD stat 双回退）
###############################################################################
fetch_file_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null
}

###############################################################################
# 公共API：校验一个已落盘文件
# 用法：fetch_verify <file> <expect_size> <expect_sha256>
# 返回：0 校验通过；1 尺寸不符（截断/超发）；2 尺寸吻合但哈希不符（毒件）
###############################################################################
fetch_verify() {
    local file="$1" expect_size="$2" expect_sha="$3"
    local real_size real_sha

    real_size=$(fetch_file_size "$file") || {
        airy_log_error "Cannot stat file: $file"
        return 1
    }
    if [[ "$real_size" != "$expect_size" ]]; then
        airy_log_error "Size mismatch: $file (got $real_size, want $expect_size)"
        return 1
    fi

    real_sha=$(fetch_sha256_of "$file") || return 2
    if [[ "$real_sha" != "$expect_sha" ]]; then
        airy_log_error "SHA256 mismatch: $file — poisoned artifact, refusing"
        return 2
    fi
    return 0
}

###############################################################################
# 公共API：从单一来源取件到暂存文件
# 用法：fetch_source_get <url_or_path> <part_file>
# 本地路径（以 / 开头）直接拷贝；URL 用 curl 断点续传（-C -）。
# 续传失败（服务器不支持 Range 等）时清除残留后整件重取一次。
###############################################################################
fetch_source_get() {
    local src="$1" dest="$2"

    if [[ "$src" == /* ]]; then
        [[ -f "$src" ]] || return 1
        cp -f "$src" "$dest"
        return 0
    fi

    local curl_opts=(-fSL --retry 2 --retry-delay 1 --connect-timeout 15
                     --speed-limit 1024 --speed-time 30)
    if [[ -n "${AGENTRT_HTTP_PROXY:-}" ]]; then
        curl_opts+=(--proxy "$AGENTRT_HTTP_PROXY")
    fi
    if [[ -n "${AGENTRT_HTTPS_PROXY:-}" ]]; then
        curl_opts+=(--proxy "$AGENTRT_HTTPS_PROXY")
    fi

    if [[ -f "$dest" ]]; then
        if curl "${curl_opts[@]}" -C - -o "$dest" "$src"; then
            return 0
        fi
        rm -f "$dest"
    fi
    curl "${curl_opts[@]}" -o "$dest" "$src"
}

###############################################################################
# 公共API：镜像序列取件并验证
# 用法：fetch_file_verified <dest> <expect_size> <expect_sha256> <source>...
# source 为本地路径（以 / 开头，离线 bundle）或 URL，依序尝试；
# 首个通过尺寸+sha256 双校验者落位 dest。
# 返回：0 成功；1 全部来源失败（含截断）；2 毒件（fail-closed，立即终止不重试）
###############################################################################
fetch_file_verified() {
    local dest="$1" expect_size="$2" expect_sha="$3"
    shift 3

    airy_mkdir "$(dirname "$dest")"
    local part="${dest}.part"
    local src rc

    for src in "$@"; do
        airy_log_info "Fetching: $src"
        if fetch_source_get "$src" "$part"; then
            rc=0
            fetch_verify "$part" "$expect_size" "$expect_sha" || rc=$?
            case $rc in
                0)
                    mv -f "$part" "$dest"
                    return 0
                    ;;
                2)
                    rm -f "$part"
                    airy_log_error "Poisoned artifact from: $src — fail-closed, no retry"
                    return 2
                    ;;
                *)
                    rm -f "$part"
                    airy_log_warn "Incomplete artifact from: $src, trying next source"
                    ;;
            esac
        else
            rm -f "$part"
            airy_log_warn "Source unreachable: $src"
        fi
    done

    airy_log_error "All sources exhausted for: $(basename "$dest")"
    return 1
}

###############################################################################
# 导出公共API
###############################################################################
export -f fetch_sha256_of fetch_file_size fetch_verify fetch_source_get
export -f fetch_file_verified
