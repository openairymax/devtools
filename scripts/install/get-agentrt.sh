#!/usr/bin/env bash
# =============================================================================
# get-agentrt.sh — AgentRT 生产安装脚本（AIRY_HOME 模型）
# Copyright (C) 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
#
# 类比 kubeadm 之于 K8s 节点：在一台宿主机上完成 agentrt 节点运行时安装。
# 安装目标为 $AIRY_HOME（默认 ~/.airymaxrt），完全脱离源码树运行：
#
#   bin/     15 个 daemon 二进制（cmake --install）
#   lib/     Python 依赖（airymax_agents / openlab / markets / agentrt）
#   config/  secrets.env（LLM key 唯一落点）
#   run/     运行时 socket 与 agent 子进程日志
#   logs/    审计日志 daemon_audit.log
#   data/ tmp/ cache/  持久化与临时数据
#
# 用法:
#   bash get-agentrt.sh [--prefix <安装目录>] [--source <源码目录>]
#
#   --prefix / --home <dir>         安装目录（用户自选，AIRY_HOME）。
#                                    优先级: --prefix > $AIRY_HOME > ~/.airymaxrt
#   --source / --airymaxhub <dir>   指定源码树（agentrt 仓库根，含
#                                    agentrt/ ecosystem/ sdk/ devtools/）
#   --help                          显示帮助
#
# 安装完成后固化安装位置到 $AIRY_HOME/config/install.env，并生成
# $AIRY_HOME/bin/agentrt-env.sh（source 后获得完整运行环境，免手动 export）。
# 未指定源码目录时尝试从脚本位置反推仓库根，失败则提示手动 clone。
# =============================================================================

set -euo pipefail

# ==================== 输出 ====================

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ==================== 参数解析 ====================

SOURCE_DIR=""
INSTALL_PREFIX=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source|--airymaxhub)
            SOURCE_DIR="$2"; shift 2 ;;
        --prefix|--home)
            INSTALL_PREFIX="$2"; shift 2 ;;
        --help|-h)
            echo "用法: bash get-agentrt.sh [--prefix <安装目录>] [--source <agentrt 仓库根>]"; exit 0 ;;
        *)
            fail "未知参数: $1（--help 查看用法）" ;;
    esac
done

# 未指定时从脚本位置反推仓库根：<root>/devtools/scripts/install/get-agentrt.sh
if [[ -z "${SOURCE_DIR}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CANDIDATE="$(cd "${SCRIPT_DIR}/../../../.." 2>/dev/null && pwd || true)"
    if [[ -n "${CANDIDATE}" && -f "${CANDIDATE}/agentrt/CMakeLists.txt" ]]; then
        SOURCE_DIR="${CANDIDATE}"
    fi
fi

if [[ -z "${SOURCE_DIR}" ]]; then
    fail "无法定位源码目录。请显式指定: bash get-agentrt.sh --source /path/to/agentrt"
fi
if [[ ! -f "${SOURCE_DIR}/agentrt/CMakeLists.txt" ]]; then
    fail "源码目录无效（缺 agentrt/CMakeLists.txt）: ${SOURCE_DIR}"
fi

AGENTRT_SRC="$(cd "${SOURCE_DIR}" && pwd)"

# ==================== 目标目录（AIRY_HOME 体系） ====================
#
# 安装目录由用户自选，优先级: --prefix/--home > $AIRY_HOME 环境变量 > ~/.airymaxrt。
# --prefix 显式归一为绝对路径，避免后续子目录拼接受相对路径影响。

if [[ -n "${INSTALL_PREFIX}" ]]; then
    AIRY_HOME="$(cd "${INSTALL_PREFIX}" 2>/dev/null && pwd || echo "${INSTALL_PREFIX}")"
    export AIRY_HOME
else
    export AIRY_HOME="${AIRY_HOME:-$HOME/.airymaxrt}"
fi
AIRY_BIN_DIR="${AIRY_HOME}/bin"
AIRY_LIB_DIR="${AIRY_HOME}/lib"
AIRY_RUN_DIR="${AIRY_HOME}/run"
AIRY_LOG_DIR="${AIRY_HOME}/logs"
AIRY_CFG_DIR="${AIRY_HOME}/config"
AIRY_DATA_DIR="${AIRY_HOME}/data"
AIRY_TMP_DIR="${AIRY_HOME}/tmp"
AIRY_CACHE_DIR="${AIRY_HOME}/cache"
AIRY_SECRETS_FILE="${AIRY_CFG_DIR}/secrets.env"

# ==================== 依赖检测 ====================

info "Step 1/6: 检测依赖..."
for dep in cmake gcc make python3; do
    command -v "${dep}" >/dev/null 2>&1 || fail "缺失依赖: ${dep}"
done
ok "依赖齐全 (cmake/gcc/make/python3)"

# ==================== 创建目录结构 ====================

info "Step 2/6: 创建 AIRY_HOME 目录结构..."
mkdir -p "${AIRY_BIN_DIR}" "${AIRY_LIB_DIR}" "${AIRY_RUN_DIR}" "${AIRY_LOG_DIR}" \
         "${AIRY_CFG_DIR}" "${AIRY_DATA_DIR}" "${AIRY_TMP_DIR}" "${AIRY_CACHE_DIR}"
# 密钥目录收紧权限
chmod 700 "${AIRY_CFG_DIR}" 2>/dev/null || true
ok "目录就绪: ${AIRY_HOME}"

# ==================== 构建（out-of-source，BAN-33） ====================

info "Step 3/6: 构建 C 核心（out-of-source）..."
# 构建临时目录放系统临时区，与 AIRY_HOME/tmp（运行时临时）解耦，可随时清理
BUILD_DIR="${TMPDIR:-/tmp}/agentrt-install-build"
rm -rf "${BUILD_DIR}"
cmake -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -S "${AGENTRT_SRC}/agentrt" >/dev/null
cmake --build "${BUILD_DIR}" -j"$(nproc 2>/dev/null || echo 4)" >/dev/null 2>&1 \
    || { warn "全量构建失败，重试（首次 LTO 串行较慢）..."; cmake --build "${BUILD_DIR}" -j2 >/dev/null; }
ok "C 核心构建完成"

# ==================== 安装 daemon 二进制 ====================

info "Step 4/6: 安装 daemon 到 ${AIRY_BIN_DIR}..."
cmake --install "${BUILD_DIR}" --prefix "${AIRY_HOME}" >/dev/null
# 校验 15 个 daemon 全部就位
EXPECTED_DAEMONS=(monit_d observe_d info_d notify_d sched_d channel_d mem_d
                  llm_d tool_d hook_d plugin_d agent_d a2a_d market_d gateway_d)
MISSING=()
for d in "${EXPECTED_DAEMONS[@]}"; do
    [[ -x "${AIRY_BIN_DIR}/${d}" ]] || MISSING+=("${d}")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    fail "daemon 安装不完整，缺失: ${MISSING[*]}"
fi
ok "15 个 daemon 已安装"

# ==================== Python 依赖 → lib/ ====================

info "Step 5/6: 安装 Python 依赖到 ${AIRY_LIB_DIR}..."
install_python_deps() {
    local src_root="$1"; shift
    local pkg
    for pkg in "$@"; do
        [[ -d "${src_root}/${pkg}" ]] || { warn "源码包缺失，跳过: ${src_root}/${pkg}"; continue; }
        # 不带尾部斜杠：复制目录本身 → ${AIRY_LIB_DIR}/${pkg}/
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --exclude 'tests' --exclude '__pycache__' --exclude '.git' \
                  --exclude 'examples' "${src_root}/${pkg}" "${AIRY_LIB_DIR}/"
        else
            cp -r "${src_root}/${pkg}" "${AIRY_LIB_DIR}/"
        fi
    done
}

install_python_deps "${AGENTRT_SRC}/ecosystem/agents" airymax_agents airymax_agents_rs
install_python_deps "${AGENTRT_SRC}/ecosystem/openlab" openlab markets contrib app
install_python_deps "${AGENTRT_SRC}/sdk/sdk-python" agentrt

# 校验可导入
if ! PYTHONPATH="${AIRY_LIB_DIR}" python3 -c "import agentrt, airymax_agents, openlab, markets" 2>/dev/null; then
    warn "lib/ 导入校验失败（检查源码包结构）"
else
    ok "Python 依赖可导入 (agentrt/airymax_agents/openlab/markets)"
fi

# ==================== secrets.env 模板 ====================

info "Step 6/6: 配置 LLM 凭据模板..."
if [[ ! -f "${AIRY_SECRETS_FILE}" ]]; then
    TEMPLATE="${AGENTRT_SRC}/devtools/scripts/ops/templates/secrets.env.example"
    if [[ -f "${TEMPLATE}" ]]; then
        cp "${TEMPLATE}" "${AIRY_SECRETS_FILE}"
        chmod 600 "${AIRY_SECRETS_FILE}"
        warn "已生成 ${AIRY_SECRETS_FILE}，请填写 LLM API key"
    fi
else
    ok "secrets.env 已存在，跳过"
fi

# ==================== 固化安装位置 ====================

# 用户自选目录在后续启动时必须可复现，否则 C 侧 airy_paths_init() 会回落
# 到默认 $HOME/.airymaxrt。install.env 记录本次安装位置；agentrt-env.sh
# 提供 source 即用的运行环境（AIRY_HOME + 子目录 + PATH）。

{
    echo "# AgentRT 安装信息（由 get-agentrt.sh 生成，勿手改）"
    echo "AIRY_HOME=${AIRY_HOME}"
    echo "AIRY_VERSION=0.1.1"
    echo "INSTALLED_AT=$(date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
} > "${AIRY_CFG_DIR}/install.env"
chmod 600 "${AIRY_CFG_DIR}/install.env"

cat > "${AIRY_BIN_DIR}/agentrt-env.sh" <<EOF
#!/usr/bin/env bash
# AgentRT 运行环境（由 get-agentrt.sh 生成，source 使用）
# 用法: source \${AIRY_HOME:-${AIRY_HOME}}/bin/agentrt-env.sh
export AIRY_HOME="${AIRY_HOME}"
export AIRY_RUNTIME_DIR="\${AIRY_RUNTIME_DIR:-\$AIRY_HOME/run}"
export AIRY_LOG_DIR="\${AIRY_LOG_DIR:-\$AIRY_HOME/logs}"
export AIRY_CONFIG_DIR="\${AIRY_CONFIG_DIR:-\$AIRY_HOME/config}"
export AIRY_BIN_DIR="\${AIRY_BIN_DIR:-\$AIRY_HOME/bin}"
export AIRY_LIB_DIR="\${AIRY_LIB_DIR:-\$AIRY_HOME/lib}"
export PATH="\${AIRY_HOME}/bin:\$PATH"
EOF
chmod 600 "${AIRY_BIN_DIR}/agentrt-env.sh"
ok "安装位置已固化: install.env + agentrt-env.sh"

# ==================== 验证 ====================

echo ""
echo "============================================================"
echo "  AgentRT v0.1.1 生产安装完成（AIRY_HOME=${AIRY_HOME}）"
echo "============================================================"
echo "  二进制:   ${AIRY_BIN_DIR}"
echo "  Python:   ${AIRY_LIB_DIR}"
echo "  凭据:     ${AIRY_SECRETS_FILE}"
echo "  运行时:   ${AIRY_RUN_DIR} / ${AIRY_LOG_DIR}"
echo "  安装固化: ${AIRY_CFG_DIR}/install.env"
echo ""
echo "启动: source ${AIRY_BIN_DIR}/agentrt-env.sh"
echo "  （或设置 PATH 后直接执行: ${AIRY_BIN_DIR}/agent_d）"
echo "  agentrt-bootstrap.sh 位于源码树 devtools/scripts/ops/bin/"
echo "============================================================"
