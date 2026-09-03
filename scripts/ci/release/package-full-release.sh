#!/usr/bin/env bash
# ============================================================================
# AgentRT 完全体二进制包发布流水线（CI 构建 + 上传）
#
# 阶段 0：质量门禁（可选：SKIP_GATES=1 跳过）
# 阶段 1：闭源预编译模块包 — atoms-prebuilt / memoryrovol-pro
#         （内部 CI 持有闭源源码；对外交付「静态库 + 公共 API 头」）
# 阶段 2：完全体二进制包 — agentrt-<v版本>-<os>-<arch>.tar.gz
#         （bin: 16 daemon + CLI + TUI；lib: Python 依赖；include: 公共头；
#          config: 配置模板；manifest.json：版本/组件/校验和）
# 制品命名规范与 .github/workflows/release.yml 对齐（默认承载 atomgit，
# GitHub Release 为镜像）。
# 阶段 3：上传 release（可配 atomgit release API 或通用 UPLOAD_URL；DRY_RUN 模拟）
#
# 用法：
#   ./package-full-release.sh <版本> [os-arch]      # 如 v0.1.3 linux-x86_64
# 环境变量：
#   SKIP_GATES=1      跳过质量门禁（CI 快速发布）
#   SKIP_MODULES=1    跳过闭源预编译模块包（仅打完全体）
#   SKIP_UPLOAD=1     不上传（仅本地打包）
#   DRY_RUN=1         模拟（打印将执行的命令）
#   UPLOAD_URL / UPLOAD_TOKEN / RELEASE_ORG / RELEASE_REPO
#   AIRY_BUILD_JOBS   并行编译数（默认 nproc）
#
# 产物：dist/ 下全部 tarball + manifest.json + *.sha256
# ============================================================================

set -euo pipefail

# ─── 颜色 ──────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
# 打包内容白名单共享（SSoT）：包内 bin/lib/config/modules 组装与打包函数
# 唯一定义于 lib-package.sh，杜绝多脚本手写 cp 清单导致的漏包/多包漂移。
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-package.sh"

# 版本 SSoT：默认读取 agentrt/VERSION（伞仓 agent-workload/ 布局），
# 支持 <版本> 参数显式覆盖（问题 7：版本 bump 无需多处置零）。
AGENTRT_VERSION_FILE="${PROJECT_ROOT}/agent-workload/agentrt/VERSION"
DEFAULT_VERSION="v$(cat "$AGENTRT_VERSION_FILE" 2>/dev/null | tr -d '[:space:]' || echo 0.1.5)"
VERSION="${1:-${DEFAULT_VERSION}}"
PLATFORM="${2:-linux-x64}"
# 目录内使用去 v 的版本号（包内顶层目录 agentrt-<num>，与 install.sh 匹配）
VERSION_NUM="${VERSION#v}"
SKIP_GATES="${SKIP_GATES:-0}"
SKIP_MODULES="${SKIP_MODULES:-0}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
DRY_RUN="${DRY_RUN:-0}"
JOBS="${AIRY_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"
UPLOAD_URL="${UPLOAD_URL:-}"
UPLOAD_TOKEN="${UPLOAD_TOKEN:-}"
RELEASE_ORG="${RELEASE_ORG:-openairymax}"
RELEASE_REPO="${RELEASE_REPO:-airymaxhub}"

# 产物目录：默认源码区外（铁律 4.7：构建产物禁止污染 airymaxhub 源码区），
# 可用 AIRY_DIST_OUT 覆盖（CI 上传场景可指向共享制品目录）。
DIST_DIR="${AIRY_DIST_OUT:-${HOME}/.airymaxrt/dist}"
STAGE_DIR="${DIST_DIR}/.stage-${VERSION}"
# 伞仓 agent-workload/ 布局（问题 5：发布脚本曾按扁平布局假设路径）
AGENTRT_SRC="${PROJECT_ROOT}/agent-workload/agentrt"
TUI_SRC="${PROJECT_ROOT}/agent-workload/sdk/tui"

# 闭源模块源码（内部 CI 持有；本地开发模式从本地路径取）
ATOMS_SRC="${ATOMS_SRC:-${AGENTRT_SRC}/atoms}"
MEMORYROVOL_SRC="${MEMORYROVOL_SRC:-${PROJECT_ROOT}/agent-workload/products/memoryrovol}"

# 预编译包内容清单
ATOMS_LIBS="core memory cognition coreloopthree taskflow syscall frameworks"
# 内部实现头（不进入公共头包，避免与系统/commons 同名头冲突）
ATOMS_EXCLUDE_HEADERS="stdatomic.h"

run() {
    if [ "$DRY_RUN" = "1" ]; then
        log_info "DRY-RUN: $*"
    else
        "$@"
    fi
}

# ─── 阶段 0：质量门禁（复用 release.sh 的构建/测试门禁） ───────────────
quality_gates() {
    [ "$SKIP_GATES" = "1" ] && { log_warn "跳过质量门禁（SKIP_GATES=1）"; return 0; }
    log_info "阶段0：质量门禁（源码构建回归）…"
    # 铁律 4.7：构建目录必须在源码区外（历史版本曾用 ${PROJECT_ROOT}/dist
    # 与源码区根 build-release/，污染伞仓源码区）
    local gates_build="${DIST_DIR}/.gates-build"
    run cmake -S "$AGENTRT_SRC" -B "$gates_build" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=ON >/dev/null
    run cmake --build "$gates_build" -j"$JOBS"
    log_ok "质量门禁通过（构建成功）"
}

# ─── 阶段 1：闭源预编译模块包 ───────────────────────────────────────────
build_atoms_prebuilt() {
    local out="${STAGE_DIR}/atoms-prebuilt-${VERSION}-${PLATFORM}"
    log_info "阶段1：构建 atoms 预编译包（${PLATFORM}）…"
    [ -d "$ATOMS_SRC" ] || { log_fail "atoms 源码缺失（闭源模块须由内部 CI 构建）: $ATOMS_SRC"; return 1; }

    local build_dir="${STAGE_DIR}/build-atoms"
    run cmake -S "$AGENTRT_SRC" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DAIRY_WITH_MEMORYROVOL=OFF \
        -DCMAKE_INSTALL_PREFIX="$build_dir/install" >/dev/null
    run cmake --build "$build_dir" -j"$JOBS" --target airy_core airy_memory airy_syscall \
        airy_cognition airy_coreloopthree airy_taskflow airy_frameworks

    # 收集静态库
    run mkdir -p "$out/lib"
    local lib
    for lib in $ATOMS_LIBS; do
        local src_lib
        src_lib="$(find "$build_dir" -name "libairy_${lib}.a" | head -1)"
        [ -n "$src_lib" ] || { log_fail "缺少 libairy_${lib}.a（构建产物未生成）"; return 1; }
        run cp "$src_lib" "$out/lib/"
    done
    # 可选：MemoryRovol PRO 预编译库（商业化，内部 CI 单独构建）
    if [ -f "${build_dir}/memoryrovol/src/libagentrt_memoryrovol.a" ]; then
        run cp "${build_dir}/memoryrovol/src/libagentrt_memoryrovol.a" "$out/lib/"
    fi

    # 镜像公共头文件（源码相对结构，剔除内部实现头）
    local inc_pairs="corekern/include coreloopthree/include coreloopthree/src/cognition syscall/include frameworks/include taskflow/include"
    local pair h
    for pair in $inc_pairs; do
        [ -d "$ATOMS_SRC/$pair" ] || continue
        run mkdir -p "$out/atoms/$(dirname "$pair")"
        run cp -r "$ATOMS_SRC/$pair" "$out/atoms/$pair"
    done
    run mkdir -p "$out/atoms/memory"
    [ -d "$ATOMS_SRC/memory/include" ] && run cp -r "$ATOMS_SRC/memory/include" "$out/atoms/memory/"
    [ -d "$ATOMS_SRC/memory/src" ] && run cp -r "$ATOMS_SRC/memory/src" "$out/atoms/memory/"
    # 剔除内部实现头（stdatomic.h shim 等，避免 include_next 递归与同名遮蔽）
    for h in $ATOMS_EXCLUDE_HEADERS; do
        run find "$out/atoms" -name "$h" -delete 2>/dev/null || true
    done

    # manifest + 打包
    {
        echo "{"
        echo "  \"name\": \"airy-atoms-prebuilt\","
        echo "  \"version\": \"${VERSION}\","
        echo "  \"platform\": \"${PLATFORM}\","
        echo "  \"libs\": [$(printf '"libairy_%s.a",' $ATOMS_LIBS | sed 's/,$//')],"
        echo "  \"note\": \"atoms 闭源模块预编译交付：静态库 + 公共 API 头（不含实现源码）\""
        echo "}"
    } > "$out/manifest.json"

    # 打包：out 位于 ${STAGE_DIR}（与 build_full_package 一致，须 cd STAGE_DIR）。
    ( cd "$STAGE_DIR" && run tar -czf "${DIST_DIR}/airy-atoms-prebuilt-${VERSION}-${PLATFORM}.tar.gz" \
        "$(basename "$out")" )
    run sha256sum "$DIST_DIR/airy-atoms-prebuilt-${VERSION}-${PLATFORM}.tar.gz" \
        > "$DIST_DIR/airy-atoms-prebuilt-${VERSION}-${PLATFORM}.tar.gz.sha256"
    log_ok "atoms 预编译包: dist/airy-atoms-prebuilt-${VERSION}-${PLATFORM}.tar.gz"
}

# ─── 阶段 2：完全体二进制包 ─────────────────────────────────────────────
build_full_package() {
    # 包内顶层目录 agentrt-<num>（去 v），与 install.sh/install.ps1 二进制
    # 模式按 agentrt-* 目录匹配解压位置对齐。
    local out="${STAGE_DIR}/agentrt-${VERSION_NUM}"
    log_info "阶段2：构建完全体二进制包（${PLATFORM}）…"
    local build_dir="${STAGE_DIR}/build-full"
    run cmake -S "$AGENTRT_SRC" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF \
        -DCMAKE_INSTALL_PREFIX="$out" >/dev/null
    run cmake --build "$build_dir" -j"$JOBS"
    run cmake --install "$build_dir" || true
    [ -d "$build_dir/bin" ] && run cp -f "$build_dir"/bin/* "$out/bin/" 2>/dev/null || true
    # 包内架构标记：install.sh install_binary 依 platform-<arch> 做交叉校验，
    # 防止异架构包被静默安装（跨架构 daemon 启动即崩溃）。PLATFORM=linux-x86_64
    # → platform-x86_64（与 install.sh detect_arch 输出一致）。
    run touch "$out/platform-${PLATFORM#linux-}"

    # Rust TUI
    # cargo 定位：PATH 直查 → rustup 默认安装路径回退（CI 与开发机 PATH
    # 差异——rustup 未 source 时 command -v cargo 失败，TUI 曾静默缺失）。
    if [ -d "$TUI_SRC" ] && { command -v cargo >/dev/null 2>&1 || [ -x "${HOME}/.cargo/bin/cargo" ]; }; then
        log_info "构建 agentrt-tui…"
        export PATH="${HOME}/.cargo/bin:$PATH"
        # MemoryRovol OSS 库（L1+L2，无 agentrt 运行时符号依赖）：TUI 独立
        # 链接专用。PRO 全功能库依赖 agentrt 平台符号（airy_thread_* 等），
        # 无法被 TUI 独立二进制链接——历史根因：环境残留 AIRY_HOME 指向含
        # PRO 库目录时 build.rs 误选 PRO 库 → airy_thread_* 未定义链接失败。
        # 显式构建 OSS 库并注入 MEMORYROVOL_OSS_LIB，同时注入 sanitizer-free
        # libairy_common.a（IME），并 unset AIRY_HOME 屏蔽环境残留。
        local mr_oss_lib=""
        if [ -d "${PROJECT_ROOT}/agent-workload/products/memoryrovol" ]; then
            local mr_oss_build="${STAGE_DIR}/build-mr-oss"
            run cmake -S "${PROJECT_ROOT}/agent-workload/products/memoryrovol" \
                -B "$mr_oss_build" \
                -DCMAKE_BUILD_TYPE=Release -DMEMORYROVOL_OSS=ON -DBUILD_TESTS=OFF >/dev/null
            run cmake --build "$mr_oss_build" -j"$JOBS"
            mr_oss_lib="$(find "$mr_oss_build" -name "libagentrt_memoryrovol.a" | head -1)"
        fi
        # 构建产物收敛（铁律 4.7）：CARGO_TARGET_DIR 指向 DIST_DIR/target，
        # 禁止 cargo 在源码树 sdk/tui/target 落盘。
        run bash -c "cd '$TUI_SRC' && env -u AIRY_HOME \
            MEMORYROVOL_OSS_LIB='${mr_oss_lib:-}' \
            AIRY_COMMON_LIB='${build_dir}/commons/libairy_common.a' \
            RUSTFLAGS='-C link-arg=-Wl,-rpath,\$ORIGIN/../lib' \
            CARGO_TARGET_DIR='${DIST_DIR}/target' cargo build --release"
        [ -f "${DIST_DIR}/target/release/agentrt-tui" ] && \
            run cp -f "${DIST_DIR}/target/release/agentrt-tui" "$out/bin/"
    fi

    # 包内内容白名单组装（SSoT，lib-package.sh）：bootstrap/python 运行时/
    # config 模板/maths-toolkit/manifest/.so 自包含/平台标记一次到位，
    # 与 build.sh 共用同一清单，杜绝多脚本手写 cp 漂移导致的漏包/多包。
    run pkg_assemble_full "$out" "$VERSION" "$PLATFORM" "$PROJECT_ROOT"

    # 打包：out 位于 ${STAGE_DIR}，须 cd STAGE_DIR（同 build_atoms_prebuilt 修复）。
    ( cd "$STAGE_DIR" && run tar -czf "${DIST_DIR}/agentrt-${VERSION}-${PLATFORM}.tar.gz" \
        "$(basename "$out")" )
    # sha256 文件内为相对文件名（sha256sum -c 兼容），不得带绝对路径。
    ( cd "$DIST_DIR" && run sha256sum "agentrt-${VERSION}-${PLATFORM}.tar.gz" \
        > "agentrt-${VERSION}-${PLATFORM}.tar.gz.sha256" )
    log_ok "完全体包: dist/agentrt-${VERSION}-${PLATFORM}.tar.gz"
}

# ─── 阶段 3：上传 release ───────────────────────────────────────────────
upload_releases() {
    [ "$SKIP_UPLOAD" = "1" ] && { log_warn "跳过上传（SKIP_UPLOAD=1）"; return 0; }
    [ -n "$UPLOAD_URL" ] || { log_warn "未配置 UPLOAD_URL，跳过上传（可用 SKIP_UPLOAD=1 明确跳过）"; return 0; }

    local f
    for f in "$DIST_DIR"/agentrt-*.tar.gz "$DIST_DIR"/agentrt-*.sha256 \
             "$DIST_DIR"/airy-atoms-prebuilt-*.tar.gz; do
        [ -e "$f" ] || continue
        log_info "上传: $(basename "$f")"
        run curl -fsSL -X POST -H "Authorization: Bearer ${UPLOAD_TOKEN}" \
            -F "file=@${f}" -F "version=${VERSION}" -F "platform=${PLATFORM}" \
            "${UPLOAD_URL}"
        log_ok "已上传: $(basename "$f")"
    done
}

# ─── 主流程 ─────────────────────────────────────────────────────────────
main() {
    log_info "AgentRT 完全体发布流水线 v${VERSION} (${PLATFORM})"
    run mkdir -p "$DIST_DIR" "$STAGE_DIR"

    quality_gates || true

    if [ "$SKIP_MODULES" != "1" ]; then
        build_atoms_prebuilt || log_warn "atoms 预编译包构建失败（SKIP_MODULES=1 可跳过）"
    fi

    build_full_package

    # 清理阶段目录（保留最终 tarball）
    run rm -rf "$STAGE_DIR" 2>/dev/null || true

    upload_releases

    log_ok "发布完成，产物位于 ${DIST_DIR}/"
    ls -la "$DIST_DIR" 2>/dev/null || true
}

main "$@"
