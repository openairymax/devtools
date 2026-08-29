#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
# ============================================================================
# 完全体二进制包组装共享函数库（SSoT）
#
# 供 build.sh / build-arch.sh / package-full-release.sh 共享调用，杜绝多脚本
# 各自手写 cp 清单导致的「漏包/多包」漂移（0.1.5 曾出现安装器快照分叉、
# 0.1.6 曾出现跨架构 .so 漏包）。包内内容白名单唯一定义于此。
#
# 依赖约定：
#   - set -euo pipefail 由调用方开启
#   - 包内顶层目录为 agentrt-<去v版本号>，与 install.sh install_binary 对齐
# ============================================================================

# 版本 SSoT：读取 agentrt/VERSION，输出 VERSION_NUM（去 v）与 AIRY_VERSION
pkg_setup_version() {
    local tree="$1"
    local num
    num="$(cat "$tree/VERSION" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$num" ] || { echo "[FAIL] 无法读取 $tree/VERSION"; return 1; }
    VERSION_NUM="$num"
    AIRY_VERSION="${AIRY_VERSION:-v${num}}"
    echo "[INFO] 版本 SSoT: ${AIRY_VERSION}（VERSION_NUM=${VERSION_NUM}）"
}

# 运行时 .so 自包含：遍历 bin/ 全部 ELF 收集依赖并集（各 daemon 依赖库不同，
# 仅以单一参考二进制收集会漏包）；系统核心库豁免。调用后可用
# pkg_verify_deps <out> 校验无未解析依赖。
pkg_runtime_libs() {
    local out="$1" b n p
    mkdir -p "$out/lib"
    for b in "$out"/bin/*; do
        [ -f "$b" ] || continue
        # 仅处理 ELF 二进制：脚本（bootstrap 等）ldd 返回非零，pipefail 下
        # 会误触发 set -e 中止（增量复用 out 目录时必现）
        file "$b" 2>/dev/null | grep -q 'ELF' || continue
        ldd "$b" 2>/dev/null | awk '{print $1, $3}' | while read -r n p; do
            case "$n" in
                linux-vdso*|ld-linux*|libc.so.*|libm.so.*|libgcc_s.so.*|libpthread.so.*|librt.so.*|libdl.so.*) continue ;;
            esac
            [ -n "$p" ] && [ -f "$p" ] && cp -f "$p" "$out/lib/" 2>/dev/null || true
        done
    done
}

# 校验包内所有 ELF 无未解析依赖（缺库则警告并返回非零）
pkg_verify_deps() {
    local out="$1" b missing=0
    for b in "$out"/bin/*; do
        [ -f "$b" ] || continue
        file "$b" 2>/dev/null | grep -q 'ELF' || continue
        if ldd "$b" 2>/dev/null | grep -q "not found"; then
            echo "warn: $(basename "$b") 存在未解析依赖:"
            ldd "$b" 2>/dev/null | grep "not found"
            missing=$((missing + 1))
        fi
    done
    [ "$missing" = "0" ] || { echo "warn: pkg_verify_deps: ${missing} 个二进制存在未解析依赖"; return 1; }
}

# Python 运行时依赖（agents + sdk-python 包体）
pkg_stage_python() {
    local out="$1" root="$2" p
    mkdir -p "$out/lib"
    for p in agent-workload/ecosystem/agents/airymax_agents \
             agent-workload/ecosystem/agents/airymax_agents_rs \
             agent-workload/ecosystem/agents/orchestration \
             agent-workload/sdk/sdk-python/agentrt; do
        [ -d "$root/$p" ] && cp -r "$root/$p" "$out/lib/" || true
    done
}

# 配置模板
pkg_stage_config() {
    local out="$1" root="$2"
    mkdir -p "$out/config"
    cp -f "$root/agent-workload/ecosystem/manager/configs/agentrt.yaml" "$out/config/" 2>/dev/null || true
    cp -f "$root/agent-workload/ecosystem/manager/model/model.yaml" "$out/config/" 2>/dev/null || true
    cp -f "$root/tools/scripts/ops/templates/secrets.env.example" "$out/config/" 2>/dev/null || true
    cp -f "$root/tools/scripts/ops/templates/permission_rules.yaml" "$out/config/" 2>/dev/null || true
}

# daemon 启动编排脚本（install.sh 部署依赖，缺失则 daemon 群无法拉起）
pkg_stage_bootstrap() {
    local out="$1" root="$2"
    cp -f "$root/tools/scripts/ops/bin/agentrt-bootstrap.sh" "$out/bin/" 2>/dev/null \
        || echo "warn: agentrt-bootstrap.sh 未找到"
}

# 数学计算后端（maths-toolkit：纯 Python + 安装器，无架构依赖）
pkg_stage_toolkit() {
    local out="$1" root="$2"
    mkdir -p "$out/modules"
    cp -rf "$root/agent-workload/ecosystem/markets/tools/maths-toolkit" "$out/modules/" 2>/dev/null || true
}

# 包内 manifest.json（checksum 权威在 latest/manifest.<channel>.json，包内
# 不内嵌校验值，防打包时刻快照漂移）
pkg_make_manifest() {
    local out="$1" version="$2" platform="$3"
    cat > "$out/manifest.json" <<EOF
{
  "name": "agentrt",
  "version": "${version}",
  "platform": "${platform}",
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
}

# 清理 Python 缓存（__pycache__/.pytest_cache 不入包）
pkg_clean_pyc() {
    local out="$1"
    find "$out" -type d \( -name "__pycache__" -o -name ".pytest_cache" \) \
        -exec rm -rf {} + 2>/dev/null || true
}

# 完整包组装（bin/lib/config/modules/manifest/架构标记一次到位）
pkg_assemble_full() {
    local out="$1" version="$2" platform="$3" root="$4"
    pkg_runtime_libs "$out"
    pkg_verify_deps "$out" || true
    pkg_stage_python "$out" "$root"
    pkg_stage_config "$out" "$root"
    pkg_stage_bootstrap "$out" "$root"
    pkg_stage_toolkit "$out" "$root"
    pkg_make_manifest "$out" "$version" "$platform"
    pkg_clean_pyc "$out"
    touch "$out/platform-${platform#linux-}"
}

# 打包：在 stage 目录内对 out 顶层目录打 tar.gz 至 dist，并生成 .sha256
pkg_tar_package() {
    local stage="$1" out_name="$2" dist="$3" tarball="$4"
    mkdir -p "$dist"
    ( cd "$stage" && tar -czf "$dist/$tarball" "$out_name" )
    ( cd "$dist" && sha256sum "$tarball" > "$tarball.sha256" )
}
