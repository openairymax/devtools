#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# agentrt-bootstrap.sh — AgentRT 一键启动脚本
# Copyright (C) 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
#
# P1.23.3: 按 DAG 层级顺序启动所有 daemon，等待每个 daemon
#          健康检查通过后再启动下一层。
#
# 用法:
#   bash agentrt-bootstrap.sh [选项]
#
# 选项:
#   -c <config>    指定 agentrt.yaml 配置文件
#   -b <bindir>    指定 daemon 二进制目录 (默认: /usr/local/bin)
#   -r <runtimedir> 指定运行时目录 (默认: /tmp/agentrt)
#   -t <timeout>   全局健康检查超时秒数 (默认: 120)
#   -w / --watchdog  全部拉起后进入 watchdog 自愈巡检循环（默认每 10s，
#                     死亡 daemon 按启动顺序自动重启，60s 内单 daemon 最多 3 次）
#   --watchdog-interval <sec>  watchdog 巡检间隔秒数 (默认: 10)
#   -s             静默模式（减少输出）
#   -n             dry-run（只打印启动计划，不实际启动）
#   -h             显示帮助
#
# 验收: bash agentrt-bootstrap.sh → 所有 daemon 按序启动 → agentrt status 全部在线
#       bash agentrt-bootstrap.sh --watchdog → 启动后进程死亡可被自动拉起
# =============================================================================

set -euo pipefail

# ==================== 颜色/输出 ====================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SILENT=0
DRY_RUN=0

log_info()  { ((SILENT)) || echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { ((SILENT)) || echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { ((SILENT)) || echo -e "${CYAN}[STEP]${NC} $*"; }
log_debug() { ((SILENT)) || echo -e "${BLUE}[DEBUG]${NC} $*"; }

# ==================== 默认值 ====================
# 路径默认值全部对齐 AIRY_HOME 路径体系（2.3.2.5）：AGENTRT_BINDIR/
# AGENTRT_RUNTIME_DIR 以 $AIRY_HOME 子目录为准（下方 AIRY_HOME 解析后
# 强制覆盖），此处不再保留 /tmp/agentrt、/usr/local/bin 旧路径——旧默认值
# 虽会被覆盖，但残留会误导诊断（用户看到"默认 /tmp/agentrt"以为数据在
# /tmp）。AGENTRT_CONFIG 兼容旧显式传参；无值时用 $AIRY_HOME/config。

AGENTRT_BINDIR="${AGENTRT_BINDIR:-}"
AGENTRT_RUNTIME_DIR="${AGENTRT_RUNTIME_DIR:-}"
AGENTRT_CONFIG="${AGENTRT_CONFIG:-}"
GLOBAL_TIMEOUT_SEC=120
HEALTH_CHECK_INTERVAL_SEC=1

# Watchdog 自愈模式参数（--watchdog）
WATCHDOG=0
WATCHDOG_INTERVAL_SEC=10
WATCHDOG_RESTART_LIMIT=3            # 60s 窗口内单 daemon 最大重启次数（防崩溃循环）
WATCHDOG_RESTART_WINDOW_SEC=60

# 优雅停止窗口（秒）：daemon 收到 SIGTERM 后允许的清理时间，
# 与 daemon 生命周期约定（50-engineering-standards）的 10s 一致。
GRACEFUL_STOP_SEC="${GRACEFUL_STOP_SEC:-10}"

# 工具 OS 沙箱模式（--sandbox off|workspace|strict，默认 workspace）
SANDBOX_MODE="workspace"

# ==================== 仓库根推导 ====================

# 脚本位于 <repo>/tools/scripts/ops/bin/，仓库根为上 4 级。
# 不做硬编码本地绝对路径（硬约束），支持环境变量显式覆盖。
# 生产部署时脚本被复制到 $AIRY_HOME/bin/，上溯 4 级无法回到仓库根，
# 此时回退到 $AIRY_HOME 标准布局（config/model.yaml 与 lib/ 由 build.sh 固化）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRYMAXHUB_ROOT="$(cd "${SCRIPT_DIR}/../../../.." 2>/dev/null && pwd || true)"
# 提前解析 AIRY_HOME（--home/-H 预扫描之后会再次赋值，此处仅用于依赖推导）
if [ -z "${AIRY_HOME:-}" ]; then
    for _CAND in "${SCRIPT_DIR}/../config/install.env" "$HOME/.airymaxrt/config/install.env"; do
        if [ -f "$_CAND" ] && _HOME="$(sed -n 's/^AIRY_HOME=//p' "$_CAND" 2>/dev/null | head -1)"; then
            [ -n "$_HOME" ] && AIRY_HOME="$_HOME"
            break
        fi
    done
    AIRY_HOME="${AIRY_HOME:-$HOME/.airymaxrt}"
fi
AIRY_HOME="$(echo "$AIRY_HOME" | sed 's#/$##')"

# LLM 模型配置（SSoT）：llm_d 的唯一模型来源。
# 不传 --manager 时 llm_d 模型注册表为空（历史 P1-1：total_endpoints=0 →
# COMPLETE-FAIL INVALID_MODEL），必须显式指定。
# 优先级：显式 env > 仓库生态模型配置 > 已安装 $AIRY_HOME/config/model.yaml。
if [ -z "${AGENTRT_MODEL_CONFIG:-}" ]; then
    if [ -n "${AIRYMAXHUB_ROOT}" ] && [ -f "${AIRYMAXHUB_ROOT}/ecosystem/manager/model/model.yaml" ]; then
        AGENTRT_MODEL_CONFIG="${AIRYMAXHUB_ROOT}/ecosystem/manager/model/model.yaml"
    elif [ -f "${AIRY_HOME}/config/model.yaml" ]; then
        AGENTRT_MODEL_CONFIG="${AIRY_HOME}/config/model.yaml"
    fi
fi

# ==================== Agent Python SDK 依赖（airymax_agents / openlab / agentrt） ====================
#
# agent_d 的 Python runner 子进程以 `python3 -m airymax_agents.runner` 启动，
# 依赖三个 SDK 包可导入（service_child.c 采用标准包安装解析——pip install -e
# 或 wheel，不再注入 PYTHONPATH）。bootstrap 在启动 agent_d 前做一次性导入
# 检查并显式告知，避免 spawn 阶段 ModuleNotFoundError 静默回退。
# 本地源码构建（AIRYMAXHUB_ROOT 存在）时自动 editable 安装三包（幂等，
# --user 避免污染系统 Python）；生产 lib 布局依赖 $AIRY_HOME/lib 下已安装
# 的 SDK（由发行包安装器负责），检查失败仅告警不阻断 bootstrap。
AGENT_SDK_OK=1
if ! python3 -c "import airymax_agents, openlab, agentrt" >/dev/null 2>&1; then
    AGENT_SDK_OK=0
    if [ -n "${AIRYMAXHUB_ROOT}" ] && [ -d "${AIRYMAXHUB_ROOT}/ecosystem/agents" ]; then
        log_info "Agent SDK packages not importable — editable-installing from source tree"
        if python3 -m pip install --user -e "${AIRYMAXHUB_ROOT}/sdk/sdk-python" >/dev/null 2>&1 \
           && python3 -m pip install --user -e "${AIRYMAXHUB_ROOT}/ecosystem/openlab" >/dev/null 2>&1 \
           && python3 -m pip install --user -e "${AIRYMAXHUB_ROOT}/ecosystem/agents" >/dev/null 2>&1; then
            AGENT_SDK_OK=1
            log_info "Agent SDK editable install OK"
        else
            log_warn "Agent SDK auto-install failed — agents will not execute"
        fi
    else
        log_warn "Agent SDK packages not importable and no source tree — agents will not execute"
    fi
fi
export AGENT_SDK_OK

# ==================== 安装目录参数（--home/-H） ====================
#
# 用户自选安装目录（与 get-agentrt.sh --prefix 对应）。必须在 AIRY_HOME
# 默认值解析之前生效，故先做一轮预扫描：提取 --home/--home=/-H 的值并
# 消费掉（getopts 不支持长选项，若不消费会报 "Unknown option: --"；
# 短选项 -H 同样在此处理，getopts 阶段已不可见）。
# 优先级: --home/-H > $AIRY_HOME 环境变量 > ~/.airymaxrt

SCAN_ARGS=("$@")
FILTERED_ARGS=()
CUSTOM_AIRY_HOME=""
i=0
while [[ $i -lt ${#SCAN_ARGS[@]} ]]; do
    case "${SCAN_ARGS[$i]}" in
        --home|-H)
            CUSTOM_AIRY_HOME="${SCAN_ARGS[$((i + 1))]:-}"
            i=$((i + 2)) ;;
        --home=*)
            CUSTOM_AIRY_HOME="${SCAN_ARGS[$i]#*=}"
            i=$((i + 1)) ;;
        --watchdog)
            WATCHDOG=1
            i=$((i + 1)) ;;
        --sandbox)
            SANDBOX_MODE="${SCAN_ARGS[$((i + 1))]:-workspace}"
            i=$((i + 2)) ;;
        --sandbox=*)
            SANDBOX_MODE="${SCAN_ARGS[$i]#*=}"
            i=$((i + 1)) ;;
        --watchdog-interval)
            WATCHDOG_INTERVAL_SEC="${SCAN_ARGS[$((i + 1))]:-10}"
            i=$((i + 2)) ;;
        --watchdog-interval=*)
            WATCHDOG_INTERVAL_SEC="${SCAN_ARGS[$i]#*=}"
            i=$((i + 1)) ;;
        *)
            FILTERED_ARGS+=("${SCAN_ARGS[$i]}")
            i=$((i + 1)) ;;
    esac
done
set -- "${FILTERED_ARGS[@]}"

# ==================== AIRY_HOME 路径体系 ====================
#
# 统一安装根目录：$AIRY_HOME 或 ~/.airymaxrt（与 platform.h airy_home_dir()
# 一致）。全部运行时产物收敛其下，非 root 部署、容器化、卸载均干净。
if [[ -n "${CUSTOM_AIRY_HOME}" ]]; then
    export AIRY_HOME="${CUSTOM_AIRY_HOME}"
else
    export AIRY_HOME="${AIRY_HOME:-$HOME/.airymaxrt}"
fi
mkdir -p "$AIRY_HOME"/bin "$AIRY_HOME"/lib "$AIRY_HOME"/run \
         "$AIRY_HOME"/config "$AIRY_HOME"/data \
         "$AIRY_HOME"/data/agentrt/logs "$AIRY_HOME"/data/agentrt/tmp \
         "$AIRY_HOME"/data/agentrt/cache "$AIRY_HOME"/data/agentrt/workspaces 2>/dev/null

# 子目录导出（与 daemon airy_paths_init() 的 setenv 一致）
# 运行时数据全量统一于 $AIRY_HOME/data/agentrt（2026-08-25）：
# 日志/缓存/临时/持久化工作区均收敛其下，顶层仅保留分发物与易失 run/。
export AIRY_RUNTIME_DIR="${AIRY_RUNTIME_DIR:-$AIRY_HOME/run}"
export AIRY_LOG_DIR="${AIRY_LOG_DIR:-$AIRY_HOME/data/agentrt/logs}"
export AIRY_CONFIG_DIR="${AIRY_CONFIG_DIR:-$AIRY_HOME/config}"
export AIRY_BIN_DIR="${AIRY_BIN_DIR:-$AIRY_HOME/bin}"
export AIRY_LIB_DIR="${AIRY_LIB_DIR:-$AIRY_HOME/lib}"
export AIRY_DATA_DIR="${AIRY_DATA_DIR:-$AIRY_HOME/data}"
export AIRY_CACHE_DIR="${AIRY_CACHE_DIR:-$AIRY_HOME/data/agentrt/cache}"
export AIRY_TMP_DIR="${AIRY_TMP_DIR:-$AIRY_HOME/data/agentrt/tmp}"
export AIRY_WORKSPACE_DIR="${AIRY_WORKSPACE_DIR:-$AIRY_HOME/data/agentrt/workspaces}"

# 默认值对齐 AIRY_HOME（原 /tmp/agentrt、/usr/local/bin 已废弃）。
# 直接以 AIRY_* 权威子目录为准（空默认值 + 覆盖，等价于旧"强制覆盖"）。
# AIRY_HOME 为权威路径，自定义经 -b/-r 参数或 AIRY_HOME。
AGENTRT_BINDIR="${AIRY_BIN_DIR}"
AGENTRT_RUNTIME_DIR="${AIRY_RUNTIME_DIR}"

# ==================== 凭据加载（secrets.env） ====================
# 开发者设置 LLM key 的唯一位置：$AIRY_HOME/config/secrets.env
# 模板：tools/scripts/ops/templates/secrets.env.example
AIRY_SECRETS_FILE="${AIRY_SECRETS_FILE:-$AIRY_CONFIG_DIR/secrets.env}"
if [ -f "$AIRY_SECRETS_FILE" ]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1090
    . "$AIRY_SECRETS_FILE"
    set +a
    log_info "Loaded LLM secrets from $AIRY_SECRETS_FILE"
else
    log_warn "No secrets file at $AIRY_SECRETS_FILE — LLM providers will be unavailable."
    log_warn "Setup: cp <repo>/tools/scripts/ops/templates/secrets.env.example $AIRY_SECRETS_FILE"
fi

# ==================== Agent 工具 ACL（执行任务所需） ====================
#
# 工具执行采用 fail-closed ACL：无 ACL 条目的 agent/tool 一律拒绝。
# 权威源为 $AIRY_CONFIG_DIR/permission_rules.yaml（daemon_security 启动时
# 加载，按标准角色最小权限授予；install.sh/build.sh 部署模板）。
# AIRY_AGENT_ACL 默认不设，保持 rules 文件唯一权威；高级部署可显式
# 覆盖收紧：AIRY_AGENT_ACL="coding_v1=fs_read,fs_glob" ...
export AIRY_AGENT_ACL="${AIRY_AGENT_ACL:-}"

# ==================== 工具 OS 沙箱模式（shell_run） ====================
#
# shell_run 经 os_sandbox（Landlock + seccomp + rlimit）隔离。模式：
#   workspace: 全局只读 + workspace 可写（安全默认）
#   strict:    仅系统基础路径 + workspace 可读执行，默认禁网（Landlock 不可用时 fail-closed）
#   off:       无 OS 级隔离（仅超时/输出截断），用于无沙箱能力内核或本地全放行调试
# 默认 workspace（安全）。--sandbox <off|workspace|strict> 参数可显式覆盖；
# 环境变量 AIRY_TOOL_SANDBOX_MODE 仍为最高优先（与 daemon os_sandbox_cfg_from_env 一致）。
# 注意：web_search/web_fetch 走 curl 子进程（sandbox=NULL），不受本模式影响。
case "$SANDBOX_MODE" in
    off|workspace|strict) ;;
    *) SANDBOX_MODE="workspace" ;;
esac
AIRY_TOOL_SANDBOX_MODE="${AIRY_TOOL_SANDBOX_MODE:-$SANDBOX_MODE}"
export AIRY_TOOL_SANDBOX_MODE

# ==================== Sanitizer 部署兼容（ASAN_OPTIONS） ====================
#
# 生产构建启用 AddressSanitizer（0.1.1 质量基线）。部分部署环境存在系统级
# preload 库（如容器/沙箱注入的 LD_PRELOAD 拦截器），会先于 libasan 被加载，
# 触发 "ASan runtime does not come first in initial library list" 启动失败。
# verify_asan_link_order=0 仅跳过链接顺序校验（ASan 仍完整生效），纯兼容性
# 开关：无 preload 环境不受影响。可用环境变量显式覆盖。
if [ -z "${ASAN_OPTIONS:-}" ]; then
    export ASAN_OPTIONS="verify_asan_link_order=0"
fi

# ==================== DAG 定义 ====================
#
# 与 daemon_startup.h 保持一致，5 层启动 DAG。
# 同层内可并行启动，跨层必须等待前层健康检查通过。
# 扩展：agent_d（执行体）、mem_d（记忆）、a2a_d（多智能体）并入 Layer 1~2。
#

# Layer 0: 基础设施（无依赖）
DAEMON_LAYER_0=("monit_d" "observe_d" "info_d" "notify_d" "cupolas_d")

# Layer 1: 核心服务
DAEMON_LAYER_1=("sched_d" "channel_d" "mem_d")

# Layer 2: Agent 服务（think_d：双思考 GCCP+GRAD，gateway 经 think.sock 调用；
#           maths_d：数学外挂计算，gateway/CLI 经 maths.sock 调用）
DAEMON_LAYER_2=("llm_d" "think_d" "tool_d" "hook_d" "plugin_d" "agent_d" "a2a_d" "maths_d")

# Layer 3: 业务服务
DAEMON_LAYER_3=("market_d")

# Layer 4: 网关
DAEMON_LAYER_4=("gateway_d")

ALL_LAYERS=("DAEMON_LAYER_0" "DAEMON_LAYER_1" "DAEMON_LAYER_2" "DAEMON_LAYER_3" "DAEMON_LAYER_4")

# daemon 健康检查超时 (秒)
declare -A DAEMON_HEALTH_TIMEOUT=(
    [monit_d]=15    [observe_d]=15   [info_d]=15     [notify_d]=15    [cupolas_d]=20
    [sched_d]=20    [channel_d]=20   [mem_d]=20
    [llm_d]=30      [think_d]=30     [tool_d]=30     [hook_d]=20     [plugin_d]=30
    [agent_d]=30    [a2a_d]=20
    [maths_d]=20
    [market_d]=30
    [gateway_d]=30
)

# daemon 默认端口 (0 = Unix Socket)
# 注意: tool_d 仅监听 Unix Socket，历史遗留的 8082 TCP 端口映射会导致
# 健康检查 nc -z 8082 挂起（连接被 DROP 而非 REFUSE）后才回退 socket
# 检查，使 tool_d 每次启动延迟 30s+。已移除，仅保留真实 TCP 端口。
declare -A DAEMON_PORT=(
    [gateway_d]=8080
)

# daemon 二进制名称映射 (daemon_name -> binary_name)
# CMake 构建产出使用 agentrt-<name>-d 命名，channel_d/gateway_d 例外
declare -A DAEMON_BIN_NAME=(
    [monit_d]="monit_d"
    [observe_d]="observe_d"
    [info_d]="info_d"
    [notify_d]="notify_d"
    [cupolas_d]="cupolas_d"
    [sched_d]="sched_d"
    [channel_d]="channel_d"
    [mem_d]="mem_d"
    [llm_d]="llm_d"
    [think_d]="think_d"
    [tool_d]="tool_d"
    [hook_d]="hook_d"
    [plugin_d]="plugin_d"
    [agent_d]="agent_d"
    [a2a_d]="a2a_d"
    [maths_d]="maths_d"
    [market_d]="market_d"
    [gateway_d]="gateway_d"
)

# ==================== 运行时状态 ====================

declare -A DAEMON_PIDS=()       # daemon_name -> PID
FAILED_DAEMONS=()               # 启动失败的 daemon 列表
declare -A WD_RESTART_TIMES=()  # watchdog: daemon_name -> "ts,ts,..."（60s 滑动窗口）

# ==================== 工具函数 ====================

print_usage() {
    cat <<'EOF'
AgentRT Bootstrap Script — 一键按序启动所有 daemon

Usage: bash agentrt-bootstrap.sh [options]

Options:
  -H <dir>         指定安装目录 AIRY_HOME（用户自选，同 --home）
  -c <config>      指定 agentrt.yaml 配置文件
  -b <bindir>      指定 daemon 二进制目录 (默认: $AIRY_HOME/bin)
  -r <runtimedir>  指定运行时目录 (默认: $AIRY_HOME/run)
  -t <timeout>     全局健康检查超时秒数 (默认: 120)
  -w               启用 watchdog 自愈模式（同 --watchdog）
  --sandbox <mode> 工具 shell_run OS 沙箱模式: off|workspace|strict（默认 workspace）
  --watchdog       全部拉起后进入 watchdog 巡检循环（默认每 10s 检查一次，
                   死亡 daemon 按启动顺序自动重启，60s 内单 daemon 最多 3 次；
                   重启记录写入 $AIRY_HOME/logs/watchdog.log）
  --watchdog-interval <sec>  watchdog 巡检间隔秒数（默认: 10）
  -s               静默模式（减少输出）
  -n               dry-run（只打印启动计划，不实际启动）
  -h               显示帮助

Startup DAG:
  Layer 0: monit_d, observe_d, info_d, notify_d
  Layer 1: sched_d, channel_d, mem_d
  Layer 2: llm_d, think_d, tool_d, hook_d, plugin_d, agent_d, a2a_d, maths_d
  Layer 3: market_d
  Layer 4: gateway_d

Examples:
  bash agentrt-bootstrap.sh
  bash agentrt-bootstrap.sh --home /srv/airymaxrt
  bash agentrt-bootstrap.sh --home /srv/airymaxrt --watchdog
  bash agentrt-bootstrap.sh --watchdog --watchdog-interval 15
  bash agentrt-bootstrap.sh -b ./build/bin -r /var/run/agentrt
  bash agentrt-bootstrap.sh -n  # dry-run
EOF
}

parse_args() {
    while getopts ":H:c:b:r:t:swnh" opt; do
        case "$opt" in
            H) : ;;  # 已在顶部预扫描处理（AIRY_HOME 需先于默认值解析生效）
            c) AGENTRT_CONFIG="$OPTARG" ;;
            b) AGENTRT_BINDIR="$OPTARG" ;;
            r) AGENTRT_RUNTIME_DIR="$OPTARG" ;;
            t) GLOBAL_TIMEOUT_SEC="$OPTARG" ;;
            s) SILENT=1 ;;
            w) WATCHDOG=1 ;;
            n) DRY_RUN=1 ;;
            h) print_usage; exit 0 ;;
            *) log_error "Unknown option: -$OPTARG"; print_usage; exit 1 ;;
        esac
    done
}

# ==================== 健康检查 ====================

# 读取 daemon 真实 PID：PID 文件优先（start_daemon 经 sh -c 包装落盘，
# $$ 即 exec 后 daemon 的真实 PID），无文件或文件 stale 时回退记录值。
# setsid 在调用方为进程组组长时会 fork 使 $! 记录的 PID 漂移（历史根因：
# 健康检查 kill -0 误判 FAILED + SIGTERM 发给死 PID 导致 daemon 群残留），
# 因此所有进程维度的操作（停止/状态）一律经本函数取真实 PID。
get_daemon_pid() {
    local name="$1"
    local pid_file="${AGENTRT_RUNTIME_DIR}/${name%_d}.pid"
    if [[ -f "$pid_file" ]]; then
        local _p
        _p="$(cat "$pid_file" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "$_p" ]] && kill -0 "$_p" 2>/dev/null; then
            echo "$_p"
            return 0
        fi
        # stale PID 文件（进程已退出），删除避免污染后续判断
        rm -f "$pid_file"
    fi
    echo "${DAEMON_PIDS[$name]:-}"
    return 0
}

# 检查 Unix socket 是否有活跃监听：ss 输出整体读入后字符串匹配。
# 不用 `ss | grep -q`——grep -q 匹配后提前退出使 ss 收到 SIGPIPE，
# set -euo pipefail 下管道退出码 141 会误判失败（历史根因：socket
# 在 ss 输出中排序靠前时，启动健康检查偶发误判 UNHEALTHY、单实例锁
# 误删活跃 socket）。ss 不可用时返回 1，由调用方回退 -S 判断。
sock_is_listening() {
    local sock_path="$1"
    command -v ss >/dev/null 2>&1 || return 1
    local ss_out
    ss_out="$(ss -xln 2>/dev/null || true)"
    case "$ss_out" in
        *"${sock_path} "*) return 0 ;;
    esac
    return 1
}

check_daemon_health_unix() {
    local name="$1"
    # daemon socket 名称不带 _d 后缀 (monit_d → monit.sock)
    local short_name="${name%_d}"
    local sock_path="${AGENTRT_RUNTIME_DIR}/${short_name}.sock"

    # socket 文件不存在 → 未 bind，不健康
    [[ -S "$sock_path" ]] || return 1

    # ss 可用时确认实际监听（防 stale socket 文件残留误判为健康）；
    # ss 不可用（受限环境）时信任 socket 文件存在（bind 成功的直接证据）。
    if command -v ss >/dev/null 2>&1; then
        sock_is_listening "$sock_path"
        return $?
    fi
    return 0
}

check_daemon_health_tcp() {
    local name="$1"
    local port="${DAEMON_PORT[$name]:-0}"

    if [[ "$port" -eq 0 ]]; then
        # 无 TCP 端口，回退到 Unix Socket 检查
        check_daemon_health_unix "$name"
        return $?
    fi

    # TCP 端口检查。nc 必须带 -w 超时：本机防火墙对未监听端口可能 DROP
    # 而非 REFUSE（历史根因：无超时 nc 在 8080 空闲时挂起 30s+，bootstrap
    # 卡在 Layer 4 gateway 健康检查，导致 gateway 启动极慢或失败，系统
    # 表现为"启动不稳定"）。
    if command -v nc &>/dev/null; then
        nc -z -w 2 127.0.0.1 "$port" 2>/dev/null && return 0
    elif command -v curl &>/dev/null; then
        curl -sf --max-time 2 "http://127.0.0.1:${port}/health" &>/dev/null && return 0
    elif command -v ss &>/dev/null; then
        ss -tln 2>/dev/null | grep -q ":${port} " && return 0
    fi

    # TCP 检查失败，回退到 Unix Socket 检查
    check_daemon_health_unix "$name"
    return $?
}

check_daemon_health() {
    local name="$1"

    # socket 可达为权威判据（daemon bind 成功的直接证据）。
    # 不再以 kill -0 记录 PID 为前置失败条件——setsid fork 时 $!
    # 记录的中间 PID 会立即失效，曾导致健康检查误判 FAILED（根因）。
    check_daemon_health_tcp "$name"
    return $?
}

wait_for_daemon() {
    local name="$1"
    local timeout="${DAEMON_HEALTH_TIMEOUT[$name]:-30}"
    local elapsed=0

    log_debug "Waiting for $name (timeout=${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        if check_daemon_health "$name"; then
            # 健康确认后从 PID 文件回填真实 PID（setsid fork 时 $! 漂移，
            # 后续 stop/status 一律以真实 PID 为准）
            local real_pid
            real_pid="$(get_daemon_pid "$name")"
            [[ -n "$real_pid" ]] && DAEMON_PIDS[$name]="$real_pid"
            log_info "$name is healthy (${elapsed}s)"
            return 0
        fi
        sleep "$HEALTH_CHECK_INTERVAL_SEC"
        ((elapsed += HEALTH_CHECK_INTERVAL_SEC))
    done

    log_error "$name health check FAILED after ${timeout}s"
    return 1
}

# ==================== 启动/停止 ====================

start_daemon() {
    local name="$1"
    local bin_name="${DAEMON_BIN_NAME[$name]:-$name}"
    local bin_path="${AGENTRT_BINDIR}/${bin_name}"

    # 单实例锁：daemon 已运行则跳过启动（历史 P2-2：重复启动导致
    # EVENT-DRIVER STOP / accept 异常）。判定方式按监听类型分：
    #   - TCP daemon（gateway_d 监听 HTTP 8080）：检查端口已被监听。
    #     gateway 不建 Unix socket，仅按 socket 文件判断会让每次 bootstrap
    #     都重复启动一个 bind 失败的失效实例，残留多个半死 gateway_d。
    #   - 其余 daemon：检查 <runtime>/<name>.sock 存活监听。
    # dry-run 提前跳过，不产生副作用（不删除 stale socket）。
    local sock_path="${AGENTRT_RUNTIME_DIR}/${name%_d}.sock"
    if ! ((DRY_RUN)); then
        local tcp_port="${DAEMON_PORT[$name]:-0}"
        if [[ "$tcp_port" -gt 0 ]]; then
            if check_daemon_health_tcp "$name"; then
                # 端口被监听但 pidfile 无效（stale：旧实例正在退出/残留半死
                # 进程）时不可直接跳过——否则旧实例退出后该 daemon 永久缺失
                # （历史竞态：gateway_d 被跳过 → 8080 无监听 → 对话全断）。
                local _pid_ok
                _pid_ok="$(get_daemon_pid "$name")"
                if [[ -n "$_pid_ok" ]]; then
                    log_warn "$name already running (port $tcp_port, pid=$_pid_ok), skipping"
                    return 0
                fi
                log_warn "$name: port $tcp_port occupied but no valid pidfile (stale instance), reaping..."
                local stale_pid
                stale_pid="$(ss -tlnp 2>/dev/null | grep ":${tcp_port}[[:space:]]" \
                    | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
                if [[ -n "$stale_pid" ]] && kill -0 "$stale_pid" 2>/dev/null; then
                    kill "$stale_pid" 2>/dev/null || true
                    local _w=0
                    while check_daemon_health_tcp "$name" && [[ $_w -lt 10 ]]; do
                        sleep 1; ((_w++))
                    done
                fi
                rm -f "${AGENTRT_RUNTIME_DIR}/${name%_d}.pid"
            fi
        elif [[ -S "$sock_path" ]]; then
            if sock_is_listening "$sock_path"; then
                log_warn "$name already running (socket ${sock_path}), skipping"
                return 0
            fi
            # socket 文件残留但无监听 → 删除，避免 bind 失败
            rm -f "$sock_path"
            log_warn "$name: stale socket ${sock_path} removed"
        fi
    fi

    local cmd=("$bin_path")
    # daemon 统一使用 --manager（daemon_parse_args 只认 --manager/-h/--tcp）
    case "$name" in
        llm_d)
            # llm_d 的配置即模型清单 SSoT（model.yaml），必须显式传入。
            # 干净环境（二进制安装后尚未配置 model.yaml）时 AGENTRT_MODEL_CONFIG
            # 为空串——set -u 下必须用 :- 保护，否则 bootstrap 直接以
            # "unbound variable" 崩溃中断全部 daemon 启动（发行版阻塞）。
            # 空串时**省略** --manager 参数：llm_d 在 config_path==NULL 时回退到
            # $AIRY_CONFIG_DIR/model.yaml 自动发现（传空串会阻断该 fallback）。
            if [ -n "${AGENTRT_MODEL_CONFIG:-}" ]; then
                cmd+=("--manager" "$AGENTRT_MODEL_CONFIG")
            fi
            ;;
        *)
            if [[ -n "$AGENTRT_CONFIG" ]]; then
                cmd+=("--manager" "$AGENTRT_CONFIG")
            fi
            ;;
    esac

    log_step "Starting $name..."
    log_debug "  Command: ${cmd[*]}"

    if ((DRY_RUN)); then
        log_info "[DRY-RUN] Would start: ${cmd[*]}"
        DAEMON_PIDS[$name]=$$
        return 0
    fi

    if [[ ! -x "$bin_path" ]]; then
        log_error "Binary not found or not executable: $bin_path"
        FAILED_DAEMONS+=("$name")
        return 1
    fi

    # 确保 runtime 目录存在
    mkdir -p "$AGENTRT_RUNTIME_DIR"

    # agent_d：模型名贯通——openlab 子进程 SDK 默认模型硬编码 gpt-4o-mini
    # （DeepSeek provider 不认 → HTTP 400），注入 model.yaml 默认模型。
    # AIRY_AGENT_MODEL 在 openlab LLMAgent 中优先级最高（强制单模型），
    # 环境变量优先不覆盖。Agent SDK 包导入由脚本开头 AGENT_SDK_OK 检查保证，
    # agent_d 子进程经标准包解析（pip install -e / wheel）定位，无需 PYTHONPATH。
    if [[ "$name" == "agent_d" ]]; then
        if [[ -z "${AIRY_AGENT_MODEL:-}" && -n "$AGENTRT_MODEL_CONFIG" && -f "$AGENTRT_MODEL_CONFIG" ]]; then
            local _def_model
            _def_model="$(sed -n 's/^[[:space:]]*model:[[:space:]]*"\{0,1\}\([^"#]*\)"\{0,1\}.*/\1/p' "$AGENTRT_MODEL_CONFIG" | head -1 | tr -d '[:space:]')"
            [[ -n "$_def_model" ]] && export AIRY_AGENT_MODEL="$_def_model"
        fi
    fi

    # 补载 API key：llm_d 依赖 DEEPSEEK_API_KEY/OPENAI_API_KEY 等环境变量
    # （model.yaml 的 api_key_env 指定）。非交互 nohup 启动不 source ~/.bashrc
    # （bashrc 对非交互 shell 有提前 return 保护），此处直接从 ~/.bashrc 提取
    # export 行赋值，避免 401 invalid API key（历史 P1-3 邻近问题）。
    if [[ "$name" == "llm_d" && -z "${DEEPSEEK_API_KEY:-}" && -f "$HOME/.bashrc" ]]; then
        local key_line
        key_line="$(grep -E '^[[:space:]]*export[[:space:]]+DEEPSEEK_API_KEY=' "$HOME/.bashrc" | head -1)"
        if [[ -n "$key_line" ]]; then
            # shellcheck disable=SC2086
            eval "$key_line" 2>/dev/null || true
            if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
                log_info "llm_d: DEEPSEEK_API_KEY loaded from ~/.bashrc"
            fi
        fi
    fi

    # 启动 daemon（后台运行）
    #
    # stdout/stderr 一律重定向到 $AIRY_LOG_DIR/<name>.log，daemon 不再继承
    # 调用方的 stdout 管道。否则在 `bootstrap | tail` 这类管道调用场景下，
    # daemon 进程持有管道写端使其永不 EOF，调用方会无限挂起（历史问题：
    # 管道悬挂 5 分钟+）。日志文件亦为 daemon 单进程排他写入，不会交叉。
    #
    # setsid 脱离当前进程组（独立会话）：交互式 Ctrl-C / 沙箱回收只影响
    # bootstrap 自身，不会连带终止 daemon（历史问题：StopCommand 停掉
    # bootstrap 进程组时误杀了全部 daemon）。setsid 不可用时降级为普通后台。
    #
    # PID 捕获（根因修复）：setsid 在调用方为进程组组长时会先 fork 再 exec，
    # $! 记录的是 fork 前的中间 PID（立即退出）——此前导致健康检查 kill -0
    # 误判 FAILED、SIGTERM 发给死 PID 使 daemon 群残留。经 sh -c 包装将
    # $$（exec 后 daemon 的真实 PID）落盘到 $AIRY_RUNTIME_DIR/<name>.pid，
    # 健康检查回填与 stop/status 均以 PID 文件为准。
    local daemon_log="${AIRY_LOG_DIR}/${name}.log"
    local pid_file="${AGENTRT_RUNTIME_DIR}/${name%_d}.pid"
    rm -f "$pid_file"
    if command -v setsid >/dev/null 2>&1; then
        # sh 包装参数：$0=_, $1=pid_file，shift 后 $@ 即 daemon 完整命令行
        # （bin + 可选 --manager）。shift 2 会把无参数 daemon 的 bin 也移掉，
        # 导致 exec "$@" 为空、daemon 静默未启动（历史教训）。
        setsid /bin/sh -c 'echo $$ > "$1"; shift; exec "$@"' _ "$pid_file" "${cmd[@]}" >>"${daemon_log}" 2>&1 &
    else
        /bin/sh -c 'echo $$ > "$1"; shift; exec "$@"' _ "$pid_file" "${cmd[@]}" >>"${daemon_log}" 2>&1 &
    fi
    local pid=$!
    DAEMON_PIDS[$name]=$pid

    log_debug "  PID=$pid (log=$daemon_log, pidfile=$pid_file)"
    return 0
}

stop_daemon() {
    local name="$1"
    # 以 PID 文件中的真实 PID 为准（setsid fork 时记录 PID 会漂移）
    local pid
    pid="$(get_daemon_pid "$name")"

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    log_step "Stopping $name (PID=$pid)..."
    kill -TERM "$pid" 2>/dev/null || true

    # 优雅停止窗口：daemon 统一按 GRACEFUL_STOP_SEC（默认 10s，与
    # 50-engineering-standards daemon 生命周期约定一致）清理后退出，
    # 超时再 KILL 兜底。逐 daemon 顺序等待会放大总停止时间，批量场景
    # 由 stop_all_daemons 的并行信号 + 统一等待处理。
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null && [[ $elapsed -lt $GRACEFUL_STOP_SEC ]]; do
        sleep 1
        elapsed=$((elapsed + 1))  # 同 stop_all_daemons：set -e 下 ((elapsed++)) 会以退出码 1 中断脚本
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "$name did not stop within ${GRACEFUL_STOP_SEC}s, force killing..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "${AGENTRT_RUNTIME_DIR}/${name%_d}.pid"
    unset DAEMON_PIDS[$name]
}

stop_all_daemons() {
    log_step "Stopping all daemons (parallel SIGTERM + graceful window)..."
    if ((DRY_RUN)); then
        return 0
    fi

    # 阶段一：逆序向全部 daemon 并行发送 SIGTERM（不逐个等待）
    for ((layer=${#ALL_LAYERS[@]}-1; layer>=0; layer--)); do
        local layer_var="${ALL_LAYERS[$layer]}"
        local -n daemons="$layer_var"
        for ((i=${#daemons[@]}-1; i>=0; i--)); do
            local name="${daemons[$i]}"
            local pid
            pid="$(get_daemon_pid "$name")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null || true
                log_debug "  TERM → $name (PID=$pid)"
            fi
        done
    done

    # 阶段二：统一等待优雅停止窗口（全部并行清理，总耗时 ≈ 单个窗口）
    local elapsed=0
    local any_alive=1
    while [[ $elapsed -lt $GRACEFUL_STOP_SEC ]]; do
        any_alive=0
        for ((layer=${#ALL_LAYERS[@]}-1; layer>=0; layer--)); do
            local layer_var2="${ALL_LAYERS[$layer]}"
            local -n daemons2="$layer_var2"
            for name2 in "${daemons2[@]}"; do
                local pid2
                pid2="$(get_daemon_pid "$name2")"
                if [[ -n "$pid2" ]] && kill -0 "$pid2" 2>/dev/null; then
                    any_alive=1
                fi
            done
        done
        [[ $any_alive -eq 0 ]] && break
        sleep 1
        # 注意：不能用 ((elapsed++))——set -e 下 elapsed=0 时其求值退出码为 1，
        # 会中断脚本（实测 systemd 记录 status=1，exit 0/130 分支均未到达）。
        elapsed=$((elapsed + 1))
    done

    # 阶段三：窗口超时仍未退出的进程强制清理（KILL 兜底）
    for ((layer=${#ALL_LAYERS[@]}-1; layer>=0; layer--)); do
        local layer_var3="${ALL_LAYERS[$layer]}"
        local -n daemons3="$layer_var3"
        for name3 in "${daemons3[@]}"; do
            local pid3
            pid3="$(get_daemon_pid "$name3")"
            if [[ -n "$pid3" ]] && kill -0 "$pid3" 2>/dev/null; then
                log_warn "  $name3 exceeded graceful window, KILL (PID=$pid3)"
                kill -9 "$pid3" 2>/dev/null || true
            fi
        done
    done
}

# ==================== 状态查询 ====================

show_status() {
    echo ""
    echo "=============================="
    echo "  AgentRT Daemon Status"
    echo "=============================="

    local all_online=true
    for layer_var in "${ALL_LAYERS[@]}"; do
        local -n daemons="$layer_var"
        for name in "${daemons[@]}"; do
            local pid
            pid="$(get_daemon_pid "$name")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                if check_daemon_health "$name"; then
                    log_info "$name: ONLINE (PID=$pid)"
                else
                    log_warn "$name: RUNNING but UNHEALTHY (PID=$pid)"
                    all_online=false
                fi
            elif check_daemon_health "$name"; then
                # 外部已运行的健康 daemon（socket 存在，非本进程启动）：不误报 OFFLINE
                log_info "$name: ONLINE (pre-existing)"
            else
                log_error "$name: OFFLINE"
                all_online=false
            fi
        done
    done

    echo "=============================="
    if $all_online; then
        log_info "All daemons are ONLINE"
    else
        log_error "Some daemons are NOT online"
    fi
}

# ==================== Watchdog 自愈（--watchdog） ====================
#
# 进程级存活巡检：按 DAG 启动顺序检查每个 daemon 进程，发现死亡进程
# 即复用 start_daemon 重新拉起（幂等：存活进程不重复拉起）。带
# 60s/3 次重启频率限制，防止崩溃循环。重启记录写入 $AIRY_LOG_DIR/watchdog.log。
# 不依赖本进程 DAEMON_PIDS（支持独立进程调用 --watchdog）。

WATCHDOG_LOG="${AIRY_LOG_DIR:-$AIRY_HOME/logs}/watchdog.log"

wd_log() {
    echo "$(date '+%F %T') $*" >> "${WATCHDOG_LOG}" 2>/dev/null || true
}

# 进程存活检测（进程维度）
daemon_is_alive() {
    local name="$1"
    local bin_name="${DAEMON_BIN_NAME[$name]:-$name}"

    if command -v pgrep &>/dev/null; then
        # 精确进程名匹配（comm ≤ 15 字符，本仓库全部 daemon 名均满足）
        pgrep -x "${bin_name}" >/dev/null 2>&1 && return 0
        # 回退：全命令行匹配部署目录二进制路径
        pgrep -f "${AGENTRT_BINDIR}/${bin_name}" >/dev/null 2>&1 && return 0
        return 1
    fi
    ps -eo comm= 2>/dev/null | grep -qx "${bin_name}" && return 0
    return 1
}

# 重启频率限制：返回 0=允许重启，1=60s 窗口内已达 WATCHDOG_RESTART_LIMIT 次
wd_restart_allowed() {
    local name="$1"
    local now
    now="$(date +%s)"
    local list="${WD_RESTART_TIMES[$name]:-}"
    local new_list=""
    local count=0
    local t
    local IFS=','

    # shellcheck disable=SC2206
    local arr=(${list})
    for t in "${arr[@]}"; do
        if (( now - t < WATCHDOG_RESTART_WINDOW_SEC )); then
            new_list="${new_list}${t},"
            ((count++)) || true
        fi
    done
    WD_RESTART_TIMES[$name]="${new_list}"

    if (( count >= WATCHDOG_RESTART_LIMIT )); then
        return 1
    fi
    WD_RESTART_TIMES[$name]="${new_list}${now},"
    return 0
}

# 单轮巡检：按启动顺序检查全部 daemon，对死亡进程执行幂等重启
wd_check_all() {
    ((DRY_RUN)) && return 0
    local layer_var name

    for layer_var in "${ALL_LAYERS[@]}"; do
        local -n daemons="$layer_var"
        for name in "${daemons[@]}"; do
            if daemon_is_alive "$name"; then
                continue
            fi

            if ! wd_restart_allowed "$name"; then
                wd_log "WARN  ${name} down but restart rate-limited (${WATCHDOG_RESTART_LIMIT}/${WATCHDOG_RESTART_WINDOW_SEC}s), skip this round"
                continue
            fi

            wd_log "RESTART ${name} detected down, restarting..."
            if start_daemon "$name"; then
                # 短等待健康确认（≤5s），避免阻塞整轮巡检；未通过由下轮巡检兜底
                local waited=0
                while (( waited < 5 )); do
                    if check_daemon_health "$name"; then
                        break
                    fi
                    sleep 1
                    ((waited++)) || true
                done
                if (( waited >= 5 )) && ! check_daemon_health "$name"; then
                    wd_log "WARN  ${name} restarted but health not confirmed within 5s"
                else
                    wd_log "OK    ${name} restarted (pid=$(get_daemon_pid "$name"))"
                fi
            else
                wd_log "FAIL  ${name} restart failed"
            fi
        done
    done
}

watchdog_loop() {
    if ! [[ "${WATCHDOG_INTERVAL_SEC}" =~ ^[0-9]+$ ]] || (( WATCHDOG_INTERVAL_SEC < 1 )); then
        log_error "Invalid --watchdog-interval: ${WATCHDOG_INTERVAL_SEC}"
        exit 1
    fi

    log_info "Watchdog started (interval=${WATCHDOG_INTERVAL_SEC}s, limit=${WATCHDOG_RESTART_LIMIT}/${WATCHDOG_RESTART_WINDOW_SEC}s)"
    log_info "  Watchdog log: ${WATCHDOG_LOG}"
    wd_log "watchdog started (interval=${WATCHDOG_INTERVAL_SEC}s, limit=${WATCHDOG_RESTART_LIMIT}/${WATCHDOG_RESTART_WINDOW_SEC}s)"

    while true; do
        sleep "${WATCHDOG_INTERVAL_SEC}"
        wd_check_all
    done
}

# ==================== 信号处理 ====================

cleanup() {
    log_warn "Received shutdown signal, stopping all daemons..."
    stop_all_daemons
    # 由 systemd 托管时（INVOCATION_ID 由 systemd 注入），正常停止须以 0 退出，
    # 否则 Restart=on-failure 会把每次 stop 判为 failed 并自动拉起（实测 3 次
    # 'Failed with result exit-code' 均因此触发）。交互式 Ctrl-C 保留 130（128+SIGINT）
    # 惯例，供 shell 判断中断语义。
    if [[ -n "${INVOCATION_ID:-}" ]]; then
        exit 0
    fi
    exit 130
}

trap cleanup SIGINT SIGTERM

# ==================== 主流程 ====================

main() {
    parse_args "$@"

    # 显式 -b/-r 覆盖权威 AIRY_*（历史根因：parse_args 只改 AGENTRT_*
    # 健康检查路径而不同步 daemon 继承的 AIRY_BIN_DIR/AIRY_RUNTIME_DIR，
    # 导致 daemon 的 socket/日志落在 $AIRY_HOME（默认 ~/.airymaxrt）
    # 而健康检查查 -r 路径 → 启动误判 FAILED 并群停）。同步后两者一致。
    if [[ -n "$AGENTRT_BINDIR" ]]; then
        export AIRY_BIN_DIR="$AGENTRT_BINDIR"
    fi
    if [[ -n "$AGENTRT_RUNTIME_DIR" ]]; then
        export AIRY_RUNTIME_DIR="$AGENTRT_RUNTIME_DIR"
    fi

    log_info "AgentRT Bootstrap v0.1.4"
    log_info "  Bindir:    $AGENTRT_BINDIR"
    log_info "  Runtime:   $AGENTRT_RUNTIME_DIR"
    log_info "  Config:    ${AGENTRT_CONFIG:-<none>}"
    log_info "  Timeout:   ${GLOBAL_TIMEOUT_SEC}s"
    log_info "  Dry-run:   $DRY_RUN"
    echo ""

    # 前置检查
    if ! ((DRY_RUN)) && [[ ! -d "$AGENTRT_BINDIR" ]]; then
        log_error "Binary directory not found: $AGENTRT_BINDIR"
        exit 1
    fi

    # 逐层启动
    local layer_num=0
    local total_started=0
    local total_failed=0

    for layer_var in "${ALL_LAYERS[@]}"; do
        local -n daemons="$layer_var"
        log_step "=== Layer $layer_num: ${daemons[*]} ==="

        # 同层并行启动
        for name in "${daemons[@]}"; do
            if start_daemon "$name"; then
                total_started=$((total_started + 1))
            else
                total_failed=$((total_failed + 1))
            fi
        done

        # 等待同层所有 daemon 健康检查通过
        if ! ((DRY_RUN)); then
            for name in "${daemons[@]}"; do
                if [[ -n "${DAEMON_PIDS[$name]:-}" ]]; then
                    if ! wait_for_daemon "$name"; then
                        log_error "$name failed health check, aborting..."
                        FAILED_DAEMONS+=("$name")
                        stop_all_daemons
                        exit 1
                    fi
                fi
            done
        fi

        ((layer_num++)) || true
        echo ""
    done

    # 最终状态
    show_status

    if [[ ${#FAILED_DAEMONS[@]} -gt 0 ]]; then
        log_error "Failed daemons: ${FAILED_DAEMONS[*]}"
        exit 1
    fi

    log_info "Bootstrap complete — all ${total_started} daemons started successfully"

    # Watchdog 自愈模式：全部拉起后进入巡检循环（前台常驻）
    if ((WATCHDOG)); then
        watchdog_loop
    fi

    return 0
}

main "$@"
