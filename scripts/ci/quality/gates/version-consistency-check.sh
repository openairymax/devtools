#!/usr/bin/env bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# version-consistency-check.sh — AgentRT 版本一致性门禁（fail-closed）
#
# 背景：AgentRT 版本唯一权威（SSoT）为 agentrt/VERSION 文件，经顶层
# CMakeLists.txt 读取并以 add_compile_definitions 注入 AIRYRT_VERSION。
# 源码内任何"硬编码发布号副本"都会随发版漂移，且漂移只有在门禁缺口下才
# 暴露（历史事故：airyrt_version.h 手写 0.1.10 与 VERSION=0.1.18 并存）。
# 本门禁以结构断言消灭该缺口——源码内不再允许出现发布号字面量副本。
#
# 判定项：
#   1. VERSION 存在、单行、形如 X.Y.Z（允许字母/数字后缀，如 0.1.6a）
#   2. C 侧 SSoT 头 commons/include/airyrt_version.h 的 AIRYRT_VERSION
#      必须为漂移免疫 marker "0.0.0-dev"（不携带真实发布号）
#   3. 全树 C/H 源码中 7 个 AgentRT 发布号宏不得 #define 为 X.Y.Z 字面量
#   4. 全树 CMake 不得 set(<*VERSION*> "X.Y.Z")
#   5. 全树 workflow 的 `default:` / `VERSION:` 不得含 vX.Y.Z 字面量
#
# 范围界定（按设计排除，非遗漏）：
#   - scripts/install.sh、scripts/install.ps1、scripts/verify_release_gates.sh
#     内的版本缺省值是 `curl | sh` 主安装 UX 的"功能载荷路径 / 超前指针"，
#     其语义由 verify_release_gates.sh 的 H3 门禁覆盖（占位超前指针属 bump
#     窗口常态，不断言与 VERSION 相等），故不在本门禁断言范围内。
#   - 协议/适配器语义版本（如 MCP_CLIENT_PROTOCOL_VERSION、A2A_V03_VERSION、
#     第三方 NGHTTP2_VERSION）与本项目发布号无关，规则仅锁定下方 7 个宏，
#     避免全树泛禁 *VERSION* 造成大面积假阳性。
#
# 退出码: 0=通过 1=存在违例(fail-closed) 2=环境问题(告警)
#
# 用法: bash version-consistency-check.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 脚本位于 tools/scripts/ci/quality/gates/ — 需向上 5 级到达伞仓根
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
AGENTRT_SRC="${PROJECT_ROOT}/agent-workload/agentrt"

VERSION_FILE="${AGENTRT_SRC}/VERSION"
SSOT_HEADER="${AGENTRT_SRC}/commons/include/airyrt_version.h"
MARKER="0.0.0-dev"

# 7 个 AgentRT 自身发布号宏（精确集合，避免协议/适配器语义版本假阳性）
RELEASE_MACROS='AIRYRT_VERSION|AIRY_VERSION_STRING|AIRY_VERSION_MAJOR|AIRY_VERSION_MINOR|AIRY_VERSION_PATCH|GATEWAY_VERSION|AIRY_CLI_VERSION'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log_info() { echo -e "${BLUE}[VERSION]${NC}      $*"; }
log_ok()   { echo -e "${GREEN}[VERSION-OK]${NC}   $*"; }
log_warn() { echo -e "${YELLOW}[VERSION-WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[VERSION-ERR]${NC}  $*" >&2; }

case "${1:-}" in
    -h|--help)
        echo "Usage: $0"
        echo ""
        echo "AgentRT 版本一致性门禁：断言 VERSION 为唯一权威，源码内零发布号副本。"
        echo "退出码: 0=通过 1=违例 2=环境问题"
        exit 0
        ;;
esac

VIOLATIONS=0

if [ ! -d "$AGENTRT_SRC" ]; then
    log_warn "agentrt 源码树缺失：${AGENTRT_SRC}（环境问题，跳过）"
    exit 2
fi
if [ ! -f "$VERSION_FILE" ]; then
    log_warn "VERSION 文件缺失：${VERSION_FILE}（环境问题，跳过）"
    exit 2
fi

log_info "=== AgentRT Version Consistency Check ==="
log_info "agentrt 源码树: ${AGENTRT_SRC}"
echo ""

###############################################################################
# 1. VERSION 存在、单行、格式合法
###############################################################################
VERSION_RAW="$(tr -d '[:space:]' < "$VERSION_FILE")"
VERSION_LINES="$(grep -c '' "$VERSION_FILE" 2>/dev/null || true)"
if [ "${VERSION_LINES:-0}" -ne 1 ]; then
    log_err "VERSION 必须恰好一行，实际 ${VERSION_LINES:-0} 行"
    VIOLATIONS=$((VIOLATIONS + 1))
elif ! printf '%s' "$VERSION_RAW" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([A-Za-z0-9]+)?$'; then
    log_err "VERSION 格式非法：'${VERSION_RAW}'（期望 X.Y.Z，允许字母数字后缀）"
    VIOLATIONS=$((VIOLATIONS + 1))
else
    log_ok "VERSION 合法：${VERSION_RAW}"
fi

###############################################################################
# 2. C 侧 SSoT 头必须为漂移免疫 marker
###############################################################################
if [ ! -f "$SSOT_HEADER" ]; then
    log_err "C 侧 SSoT 头缺失：${SSOT_HEADER}"
    VIOLATIONS=$((VIOLATIONS + 1))
elif grep -Eq "^[[:space:]]*#[[:space:]]*define[[:space:]]+AIRYRT_VERSION[[:space:]]+\"${MARKER}\"" "$SSOT_HEADER"; then
    log_ok "SSoT 头 AIRYRT_VERSION 为漂移免疫 marker \"${MARKER}\""
else
    log_err "SSoT 头 AIRYRT_VERSION 非 marker \"${MARKER}\"：源码内出现发布号副本"
    grep -nE "AIRYRT_VERSION" "$SSOT_HEADER" | sed 's/^/    /' || true
    VIOLATIONS=$((VIOLATIONS + 1))
fi

###############################################################################
# 3. 全树 C/H：7 个发布号宏不得 #define 为 X.Y.Z 字面量（marker 除外）
#    marker "0.0.0-dev" 因尾部为 '-'（非引号/空白）而不匹配，天然豁免。
###############################################################################
HARDCODE_PATTERN="^[[:space:]]*#[[:space:]]*define[[:space:]]+(${RELEASE_MACROS})[[:space:]]+\"?[0-9]+\.[0-9]+\.[0-9]+[\"[:space:]]"
HARDCODE_HITS="$(grep -rEn --include='*.c' --include='*.h' \
    --exclude-dir=.git "${HARDCODE_PATTERN}" "$AGENTRT_SRC" 2>/dev/null || true)"
if [ -n "$HARDCODE_HITS" ]; then
    log_err "C/H 源码内存在发布号硬编码副本（应为 marker 或构建期注入）："
    printf '%s\n' "$HARDCODE_HITS" | sed 's/^/    /'
    VIOLATIONS=$((VIOLATIONS + 1))
else
    log_ok "C/H 源码无发布号硬编码副本"
fi

###############################################################################
# 4. 全树 CMake：不得 set(<*VERSION*> "X.Y.Z")
###############################################################################
CMAKE_PATTERN="^[[:space:]]*set[[:space:]]*\([[:space:]]*[A-Za-z_]*VERSION[A-Za-z_]*[[:space:]]+\"?[0-9]+\.[0-9]+\.[0-9]+"
CMAKE_HITS="$(grep -rEn --include='CMakeLists.txt' --include='*.cmake' \
    --exclude-dir=.git "${CMAKE_PATTERN}" "$AGENTRT_SRC" 2>/dev/null || true)"
if [ -n "$CMAKE_HITS" ]; then
    log_err "CMake 内存在版本号硬编码（应从 VERSION 派生）："
    printf '%s\n' "$CMAKE_HITS" | sed 's/^/    /'
    VIOLATIONS=$((VIOLATIONS + 1))
else
    log_ok "CMake 无版本号硬编码"
fi

###############################################################################
# 5. 全树 workflow：default: / VERSION: 不得含 vX.Y.Z 字面量
###############################################################################
WF_DIR="${AGENTRT_SRC}/.github/workflows"
WF_HITS=""
if [ -d "$WF_DIR" ]; then
    # default: 值为 vX.Y.Z（产品发布号带 v 前缀；工具钉版如 1.23.0 不匹配）
    DFLT_HITS="$(grep -rEn --include='*.yml' --include='*.yaml' \
        "^[[:space:]]*default:[[:space:]]*['\"]?v[0-9]+\.[0-9]+\.[0-9]+" "$WF_DIR" 2>/dev/null || true)"
    # VERSION: 值为 vX.Y.Z 或 X.Y.Z（env 字面量）
    ENV_HITS="$(grep -rEn --include='*.yml' --include='*.yaml' \
        "^[[:space:]]*VERSION:[[:space:]]*['\"]?v?[0-9]+\.[0-9]+\.[0-9]+" "$WF_DIR" 2>/dev/null || true)"
    if [ -n "$DFLT_HITS" ]; then WF_HITS="$DFLT_HITS"; fi
    if [ -n "$ENV_HITS" ]; then WF_HITS="${WF_HITS}${WF_HITS:+$'\n'}${ENV_HITS}"; fi
fi
if [ -n "$WF_HITS" ]; then
    log_err "workflow 内存在版本号字面量（应经 VERSION 文件派生）："
    printf '%s\n' "$WF_HITS" | sed '/^$/d' | sed 's/^/    /'
    VIOLATIONS=$((VIOLATIONS + 1))
else
    log_ok "workflow 无版本号字面量"
fi

###############################################################################
# 结果汇总（fail-closed）
###############################################################################
echo ""
if [ "$VIOLATIONS" -gt 0 ]; then
    log_err "版本一致性门禁失败：${VIOLATIONS} 项违例（fail-closed）"
    exit 1
fi
log_ok "版本一致性门禁通过（SSoT=VERSION，源码内零发布号副本）"
exit 0
