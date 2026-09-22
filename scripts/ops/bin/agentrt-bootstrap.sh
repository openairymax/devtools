#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# agentrt-bootstrap.sh — AgentRT 一键启动脚本
# Copyright (C) 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
#
# 0.1.18: supervisor 声明调谐编排——先写 launch 声明（profile.env）并注入
#         子进程继承环境，专用路径拉起 supervisor_d；CORE 5 daemon 由
#         supervisor 调谐自动拉起、死亡指数退避复活，AUX 9 daemon 按需
#         激活（activate），maths_d 保持直启域。同层并行、跨层等待健康
#         检查通过的 DAG 语义不变。
#
# 用法:
#   bash agentrt-bootstrap.sh [选项]         启动全部 daemon
#   bash agentrt-bootstrap.sh stop           停止全部 daemon
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

# 0.1.6b 缺陷修复（社区"很多库找不到 / daemon 群全部起不来"根因）：
# 包内 lib/ 自带全部第三方 .so（curl/gnutls/ssh/rtmp/ldap…），但
# DT_RUNPATH 非传递性——daemon 的直接依赖可经 $ORIGIN/../lib 找到，
# 而 libcurl 等库的传递依赖只能走系统路径；宿主缺这些库时 daemon
# 启动即失败。经 LD_LIBRARY_PATH 注入包内 lib/（传递生效，覆盖全部
# daemon 与其子进程）；优先 source 安装期生成的 agentrt-env.sh
# （同源唯一，含 LD_LIBRARY_PATH/AIRY_* 全量运行环境）。
if [ -f "${AIRY_HOME}/bin/agentrt-env.sh" ]; then
    # shellcheck disable=SC1090
    . "${AIRY_HOME}/bin/agentrt-env.sh"
fi
# 注意：LD_LIBRARY_PATH 幂等兜底不在此处——此处 AIRY_HOME 尚未经
# --home/-H 覆盖（最终值在下方路径体系解析后确定），注入会指向旧
# 安装 lib（实测复现 sched_d 缺 libssl.so.1.1）。兜底统一在
# AIRY_HOME 定稿后执行（见下方"运行库路径兜底（0.1.6c）"）。

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

# ==================== Agent Python SDK 依赖（airymax_agents / orchestration / agentrt） ====================
#
# agent_d 的 Python runner 子进程以 `python3 -m airymax_agents.runner` 启动，
# 依赖三个 SDK 包可导入（service_child.c 采用标准包安装解析——pip install -e
# 或 wheel，不再注入 PYTHONPATH）。bootstrap 在启动 agent_d 前做一次性导入
# 检查并显式告知，避免 spawn 阶段 ModuleNotFoundError 静默回退。
# 本地源码构建（AIRYMAXHUB_ROOT 存在）时自动 editable 安装三包（幂等，
# --user 避免污染系统 Python）；生产 lib 布局依赖 $AIRY_HOME/lib 下已安装
# 的 SDK（由发行包安装器负责，检查时注入 PYTHONPATH），检查失败仅告警不阻断。
AGENT_SDK_OK=1
AIRY_SDK_CHECK="import airymax_agents, orchestration, agentrt"
if [ -d "${AIRY_HOME}/lib" ]; then
    if ! PYTHONPATH="${AIRY_HOME}/lib" python3 -c "${AIRY_SDK_CHECK}" >/dev/null 2>&1; then
        AGENT_SDK_OK=0
        if [ -n "${AIRYMAXHUB_ROOT}" ] && [ -d "${AIRYMAXHUB_ROOT}/ecosystem/agents" ]; then
            log_info "Agent SDK packages not importable — editable-installing from source tree"
            if python3 -m pip install --user -e "${AIRYMAXHUB_ROOT}/sdk/sdk-python" >/dev/null 2>&1 \
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
else
    if ! python3 -c "${AIRY_SDK_CHECK}" >/dev/null 2>&1; then
        AGENT_SDK_OK=0
        if [ -n "${AIRYMAXHUB_ROOT}" ] && [ -d "${AIRYMAXHUB_ROOT}/ecosystem/agents" ]; then
            log_info "Agent SDK packages not importable — editable-installing from source tree"
            if python3 -m pip install --user -e "${AIRYMAXHUB_ROOT}/sdk/sdk-python" >/dev/null 2>&1 \
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
STOP_REQUESTED=0
i=0
while [[ $i -lt ${#SCAN_ARGS[@]} ]]; do
    case "${SCAN_ARGS[$i]}" in
        stop)
            # stop 子命令预扫描（消费掉，避免被 main 的 $1 检查遗漏）：
            # getopts 不消费位置参数，main 里 `${1:-}` 只看到 $1——当 stop
            # 排在选项之后（如 `-s stop` / `--home /x stop`）时 $1 是选项，
            # 原实现会误走启动路径实际重启 daemon 群。此处从全部参数中
            # 提取 stop 标记，与参数顺序无关。
            STOP_REQUESTED=1
            i=$((i + 1)) ;;
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
# 0.1.6c 系统性修复：AIRY_HOME 为权威运行根，全部 AIRY_* 子目录一律从
# 最终 AIRY_HOME 强制派生。父环境残留的旧 AIRY_* 值（历史安装 export /
# 终端残留）会使 --home/-H 新目录失效——daemon 从旧目录启动、健康检查
# 探测错 socket（实测复现：AIRY_BIN_DIR 残留时 --home 被忽略）。显式
# -b/-r 覆盖仍有效（main 中经 AGENTRT_BINDIR/RUNTIME_DIR 重新同步）。
export AIRY_RUNTIME_DIR="$AIRY_HOME/run"
export AIRY_LOG_DIR="$AIRY_HOME/data/agentrt/logs"
export AIRY_CONFIG_DIR="$AIRY_HOME/config"
export AIRY_BIN_DIR="$AIRY_HOME/bin"
export AIRY_LIB_DIR="$AIRY_HOME/lib"
export AIRY_DATA_DIR="$AIRY_HOME/data"
export AIRY_CACHE_DIR="$AIRY_HOME/data/agentrt/cache"
export AIRY_TMP_DIR="$AIRY_HOME/data/agentrt/tmp"
export AIRY_WORKSPACE_DIR="$AIRY_HOME/data/agentrt/workspaces"

# ── 运行库路径兜底（0.1.6c 系统性修复，AIRY_HOME 已定稿）───────────────
# 老用户（0.1.5a 及更早安装）的 env.sh 无 LD_LIBRARY_PATH 注入行（airymaxrt
# update 热替换不重新生成 env.sh），仅 source 不会注入；此处确保最终
# $AIRY_HOME/lib 始终在 LD_LIBRARY_PATH 首位（幂等，已含则跳过），与完整
# 启动器 airymaxrt 兜底同源。必须在此处（而非 env.sh 之后）——--home/-H
# 覆盖前的注入会指向旧安装 lib（实测复现 sched_d 缺 libssl.so.1.1）。
case ":${LD_LIBRARY_PATH:-}:" in
    *":${AIRY_HOME}/lib:"*) ;;
    *) export LD_LIBRARY_PATH="${AIRY_HOME}/lib:${LD_LIBRARY_PATH:-}" ;;
esac

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
# 5 层启动 DAG（本文件为 daemon 启动编排的单一真相源；0.1.9 M4 整编
# 18→15：observe_d/info_d→monit_d、plugin_d→tool_d）。
# 同层内可并行启动，跨层必须等待前层健康检查通过。
# 扩展：agent_d（执行体）、mem_d（记忆）、a2a_d（多智能体）并入 Layer 1~2。
#

# Layer 0: 基础设施（无依赖；0.1.9 M4：observe_d / info_d 并入 monit_d）
DAEMON_LAYER_0=("monit_d" "notify_d" "cupolas_d")

# Layer 1: 核心服务
DAEMON_LAYER_1=("sched_d" "channel_d" "mem_d")

# Layer 2: Agent 服务（think_d：双思考 GCCP+GRAD，gateway 经 think.sock 调用；
#           maths_d：数学外挂计算，gateway/CLI 经 maths.sock 调用。
#           0.1.9 M4：plugin_d 并入 tool_d，插件 dlopen 执行域随迁）
DAEMON_LAYER_2=("llm_d" "think_d" "tool_d" "hook_d" "agent_d" "a2a_d" "maths_d")

# Layer 3: 业务服务
DAEMON_LAYER_3=("market_d")

# Layer 4: 网关
DAEMON_LAYER_4=("gateway_d")

ALL_LAYERS=("DAEMON_LAYER_0" "DAEMON_LAYER_1" "DAEMON_LAYER_2" "DAEMON_LAYER_3" "DAEMON_LAYER_4")

# daemon 健康检查超时 (秒)
declare -A DAEMON_HEALTH_TIMEOUT=(
    [monit_d]=15    [notify_d]=15    [cupolas_d]=20
    [sched_d]=20    [channel_d]=20   [mem_d]=20
    [llm_d]=30      [think_d]=30     [tool_d]=30     [hook_d]=20
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
    [notify_d]="notify_d"
    [cupolas_d]="cupolas_d"
    [sched_d]="sched_d"
    [channel_d]="channel_d"
    [mem_d]="mem_d"
    [llm_d]="llm_d"
    [think_d]="think_d"
    [tool_d]="tool_d"
    [hook_d]="hook_d"
    [agent_d]="agent_d"
    [a2a_d]="a2a_d"
    [maths_d]="maths_d"
    [market_d]="market_d"
    [gateway_d]="gateway_d"
)

# ==================== Supervisor 编排（0.1.18） ====================
#
# supervisor_d 声明调谐：bootstrap 写 launch 声明（$AIRY_HOME/config/
# profile.env）并前置注入子进程继承环境后，经专用路径拉起 supervisor_d
# （严禁复用 start_daemon：其 sh 包装写 <runtime>/supervisor.pid，与
# supervisor 自身 pidfile 防重直接冲突，supervisor 会判定已有实例退出）。
# CORE 由 supervisor 调谐自动拉起（死亡指数退避复活），AUX 经控制口按需
# 激活，maths_d 保持直启域。supervisor_d 二进制缺失时整体回退直启模式
# （五层 DAG 语义不变，模块化拔插）。

SUP_BIN_NAME="supervisor_d"
SUP_READY_TIMEOUT_SEC=20    # supervisor 控制口就绪截止
SUP_STOP_GRACE_SEC=15       # shutdown_all（并行 TERM + KILL 兜底）总截止

# CORE 名单 = supervisor 缺省表（decl.c sup_decl_defaults），顺序一致
SUP_CORE_DAEMONS=("gateway_d" "llm_d" "think_d" "agent_d" "tool_d")

# AUX 名单按 DAG 层序排列（激活时逐层进行，保留跨层依赖语义）
SUP_AUX_DAEMONS=("monit_d" "notify_d" "cupolas_d" "sched_d" "channel_d"
                 "mem_d" "hook_d" "a2a_d" "market_d")

# 直启域：不在 supervisor 声明表内，保持 start_daemon 原路
SUP_DIRECT_DAEMONS=("maths_d")

sup_enabled() {
    [[ -x "${AGENTRT_BINDIR}/${SUP_BIN_NAME}" ]]
}

sup_sock_path() {
    echo "${AGENTRT_RUNTIME_DIR}/supervisor.sock"
}

# daemon 在 supervisor 声明表中的角色：core / aux；直启域输出空并返回 1
sup_role_of() {
    local name="$1" d
    for d in "${SUP_CORE_DAEMONS[@]}"; do
        [[ "$d" == "$name" ]] && { echo "core"; return 0; }
    done
    for d in "${SUP_AUX_DAEMONS[@]}"; do
        [[ "$d" == "$name" ]] && { echo "aux"; return 0; }
    done
    return 1
}

# ==================== 运行时状态 ====================

declare -A DAEMON_PIDS=()       # daemon_name -> PID
FAILED_DAEMONS=()               # 启动失败的 daemon 列表
declare -A ACTIVATE_FAILED=()   # supervisor 模式：激活失败的 AUX（等待阶段跳过）
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
  Layer 0: monit_d, notify_d, cupolas_d
  Layer 1: sched_d, channel_d, mem_d
  Layer 2: llm_d, think_d, tool_d, hook_d, agent_d, a2a_d, maths_d
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

# Unix socket 就绪统一原语：socket 文件存在是 bind 成功的直接证据；
# ss 可用时进一步确认真实监听（防 stale socket 残留误判）。ss 缺失
# （受限环境）时信任 socket 文件。所有就绪判定必须经此原语，严禁裸调
# sock_is_listening——0.1.18 clean-room e2e 根因：ubuntu:20.04 洁净
# 容器无 ss（iproute2 缺席），sup_start 裸调 sock_is_listening 恒返 1，
# 就绪轮询全程假阴性 20s 超时 abort（supervisor_d 实际已 bind）。
# 权衡：stale socket + 进程已死时误判运行中，可接受（误判路径均有日志）。
sock_is_ready() {
    local sock_path="$1"
    [[ -S "$sock_path" ]] || return 1
    command -v ss >/dev/null 2>&1 || return 0
    sock_is_listening "$sock_path"
}

check_daemon_health_unix() {
    local name="$1"
    # daemon socket 名称不带 _d 后缀 (monit_d → monit.sock)
    local short_name="${name%_d}"
    sock_is_ready "${AGENTRT_RUNTIME_DIR}/${short_name}.sock"
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
    local have_probe=0
    if command -v nc &>/dev/null; then
        have_probe=1
        nc -z -w 2 127.0.0.1 "$port" 2>/dev/null && return 0
    fi
    if command -v curl &>/dev/null; then
        have_probe=1
        curl -sf --max-time 2 "http://127.0.0.1:${port}/health" &>/dev/null && return 0
    fi
    if command -v ss &>/dev/null; then
        have_probe=1
        # 不用 grep -q：目标行靠前时 grep 提前退出使 ss 收 SIGPIPE，
        # pipefail 下误判未监听（同 sock_is_listening 注释的历史根因）。
        ss -tln 2>/dev/null | grep ":${port} " >/dev/null && return 0
    fi
    # 0.1.13 clean-room e2e：ubuntu:20.04 基容器无 nc/curl/ss（洁净前提 =
    # 无开发工具链）。TCP-only daemon（gateway_d 无 Unix socket）健康判定
    # 失去探针 → 恒误判 UNHEALTHY（rc3 e2e 实证：gateway 8080 已监听仍
    # FAILED after 30s）。bash 内建 /dev/tcp 作最后一档探针；仅当外部探针
    # 全缺时启用——外部探针存在但失败属真实未监听，语义不变。
    if [[ "$have_probe" -eq 0 ]] \
       && (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
        return 0
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

# ==================== daemon 环境前置 ====================

# daemon 环境前置（直启模式由 start_daemon 调用；supervisor 模式在拉起
# supervisor 前对监管域全量调用——supervisor spawn 的子进程继承 supervisor
# 环境，supervisor 启动后再 export 对子进程无效）。
prepare_daemon_env() {
    local name="$1"
    if [[ "$name" == "agent_d" ]]; then
        if [[ -z "${AIRY_AGENT_MODEL:-}" && -n "${AGENTRT_MODEL_CONFIG:-}" && -f "${AGENTRT_MODEL_CONFIG:-}" ]]; then
            local _def_model
            _def_model="$(sed -n 's/^[[:space:]]*model:[[:space:]]*"\{0,1\}\([^"#]*\)"\{0,1\}.*/\1/p' "$AGENTRT_MODEL_CONFIG" | head -1 | tr -d '[:space:]')"
            [[ -n "$_def_model" ]] && export AIRY_AGENT_MODEL="$_def_model"
        fi
        return 0
    fi
    if [[ "$name" == "llm_d" && -z "${DEEPSEEK_API_KEY:-}" && -f "$HOME/.bashrc" ]]; then
        local key_line
        # pipefail 下 grep 无匹配返回 1 会经管道传导为赋值失败（set -e 终止），
        # 空匹配属正常路径，|| true 吞掉非致命状态。
        key_line="$(grep -E '^[[:space:]]*export[[:space:]]+DEEPSEEK_API_KEY=' "$HOME/.bashrc" | head -1 || true)"
        if [[ -n "$key_line" ]]; then
            # shellcheck disable=SC2086
            eval "$key_line" 2>/dev/null || true
            if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
                log_info "llm_d: DEEPSEEK_API_KEY loaded from ~/.bashrc"
            fi
        fi
    fi
    # 显式 return 0：非 agent_d/llm_d 时若以失败的 [[ ]] 测试收尾，set -e
    # 会因函数隐式返回 1 终止脚本（供裸语句调用必须保证所有路径返回 0）。
    return 0
}

# ==================== Supervisor 编排（0.1.18） ====================

# profile.env 键值 upsert（awk 实现：BSD/GNU sed -i 不兼容，跨平台禁用）。
# 已有键整行替换为 key="val"，无键则追加。
upsert_profile_var() {
    local file="$1" key="$2" val="$3"
    if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
        local tmp="${file}.tmp.$$"
        awk -v k="$key" -v v="$val" '$0 ~ "^"k"=" { print k "=\"" v "\""; next } { print }' \
            "$file" > "$tmp" && mv "$tmp" "$file"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$file"
    fi
}

# supervisor 声明调谐：写 $AIRY_HOME/config/profile.env（sup_decl_load 声明
# 源）。CORE/AUX 名单两行 + 各 daemon ARGS 声明（未登记的声明被 decl.c
# fail-closed 拒绝，故只写有值的键）。llm_d 用 model.yaml 路径，其余用
# AGENTRT_CONFIG。
sup_write_decl() {
    local decl_dir="${AIRY_HOME}/config"
    local decl_file="${decl_dir}/profile.env"
    mkdir -p "$decl_dir"
    upsert_profile_var "$decl_file" "AIRYRT_LAUNCH_CORE" "${SUP_CORE_DAEMONS[*]}"
    upsert_profile_var "$decl_file" "AIRYRT_LAUNCH_AUX" "${SUP_AUX_DAEMONS[*]}"
    local d args_key args_val
    for d in "${SUP_CORE_DAEMONS[@]}" "${SUP_AUX_DAEMONS[@]}"; do
        args_key="AIRYRT_LAUNCH_ARGS_${d}"
        args_val=""
        if [[ "$d" == "llm_d" && -n "${AGENTRT_MODEL_CONFIG:-}" ]]; then
            args_val="--manager ${AGENTRT_MODEL_CONFIG}"
        elif [[ -n "$AGENTRT_CONFIG" ]]; then
            args_val="--manager ${AGENTRT_CONFIG}"
        fi
        [[ -n "$args_val" ]] && upsert_profile_var "$decl_file" "$args_key" "$args_val"
    done
    log_info "Launch declaration: ${decl_file}"
}

# supervisor 以 $AIRY_HOME/bin/<name> 固定解析子进程（decl.c add_proc），
# -b 自定义二进制目录时用符号链接归位，保证监管域可达。
sup_bin_link() {
    local home_bin="${AIRY_HOME}/bin"
    [[ "${AGENTRT_BINDIR}" == "${home_bin}" ]] && return 0
    mkdir -p "$home_bin"
    local d
    for d in "${SUP_CORE_DAEMONS[@]}" "${SUP_AUX_DAEMONS[@]}"; do
        [[ -x "${AGENTRT_BINDIR}/${d}" ]] && ln -sfn "${AGENTRT_BINDIR}/${d}" "${home_bin}/${d}"
    done
}

# 启动失败诊断：daemon 日志尾部经 stderr 输出（log_error 同通道，-s
# 静默模式仍可见）。0.1.18 e2e 教训：supervisor_d 崩溃讯息只在日志文件
# 里，CI 侧只见 20s 超时行，排障盲点。
sup_dump_log() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    log_error "----- tail -30 ${f} -----"
    tail -n 30 "$f" >&2 || true
}

# supervisor 专用启动（严禁复用 start_daemon：其 sh 包装写
# <runtime>/supervisor.pid，与 supervisor 自身 pidfile 防重直接冲突，
# supervisor 会判定已有实例运行而退出）。流程：sock 活跃 → 已运行跳过；
# pidfile 活跃 → 给控制口就绪窗口；否则 setsid 拉起后轮询 supervisor.sock。
sup_start() {
    local sup_bin="${AGENTRT_BINDIR}/${SUP_BIN_NAME}"
    local sock
    sock="$(sup_sock_path)"
    local sup_log="${AIRY_LOG_DIR}/${SUP_BIN_NAME}.log"
    if ((DRY_RUN)); then
        log_info "[DRY-RUN] Would start ${SUP_BIN_NAME} (declaration-driven)"
        return 0
    fi
    if sock_is_ready "$sock"; then
        log_warn "${SUP_BIN_NAME} already running (${sock}), skipping"
        return 0
    fi
    local pid_file="${AGENTRT_RUNTIME_DIR}/supervisor.pid"
    if [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid="$(tr -d '[:space:]' < "$pid_file")"
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            local w=0
            while (( w < SUP_READY_TIMEOUT_SEC )); do
                sock_is_ready "$sock" && {
                    log_warn "${SUP_BIN_NAME} (pid=$old_pid) ctrl now ready"
                    return 0
                }
                sleep 1
                w=$((w + 1))
            done
            log_error "${SUP_BIN_NAME} pid=$old_pid alive but ctrl not ready in ${SUP_READY_TIMEOUT_SEC}s (log=$sup_log)"
            sup_dump_log "$sup_log"
            return 1
        fi
    fi
    mkdir -p "$AGENTRT_RUNTIME_DIR" "$AIRY_LOG_DIR"
    log_step "Starting ${SUP_BIN_NAME} (declaration-driven orchestration)..."
    if command -v setsid >/dev/null 2>&1; then
        setsid "$sup_bin" >>"$sup_log" 2>&1 &
    else
        "$sup_bin" >>"$sup_log" 2>&1 &
    fi
    local elapsed=0
    while (( elapsed < SUP_READY_TIMEOUT_SEC )); do
        if sock_is_ready "$sock"; then
            log_info "${SUP_BIN_NAME} is ready (${elapsed}s, ctrl=${sock})"
            return 0
        fi
        sleep "$HEALTH_CHECK_INTERVAL_SEC"
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL_SEC))
    done
    log_error "${SUP_BIN_NAME} ctrl socket not ready after ${SUP_READY_TIMEOUT_SEC}s (log=$sup_log)"
    sup_dump_log "$sup_log"
    return 1
}

# AUX 激活（经 supervisor 控制口）。sup_activate 幂等：活进程直接返回 0，
# FAILED 状态由此复位 fail_count。
sup_activate_cli() {
    "${AGENTRT_BINDIR}/${SUP_BIN_NAME}" activate "$1" >/dev/null 2>&1
}

# supervisor 停止：控制口 stop 优先（shutdown_all 级联 TERM 全部监管域
# 子进程并自清 sock/pid），TERM 兜底，KILL 底线。
sup_stop() {
    ((DRY_RUN)) && return 0
    local pid_file="${AGENTRT_RUNTIME_DIR}/supervisor.pid"
    [[ -f "$pid_file" ]] || return 0
    local pid
    pid="$(tr -d '[:space:]' < "$pid_file")"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    log_step "Stopping ${SUP_BIN_NAME} (PID=$pid, cascading to managed daemons)..."
    "${AGENTRT_BINDIR}/${SUP_BIN_NAME}" stop >/dev/null 2>&1 \
        || kill -TERM "$pid" 2>/dev/null || true
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null && [[ $elapsed -lt $SUP_STOP_GRACE_SEC ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "${SUP_BIN_NAME} exceeded ${SUP_STOP_GRACE_SEC}s, force killing..."
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$(sup_sock_path)"
    fi
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
                # || true：ss 缺失（127）或竞态下端口已无监听（grep 空匹配）
                # 时管道非零，set -e 会误杀 bootstrap；空值走正常重启路径。
                stale_pid="$(ss -tlnp 2>/dev/null | grep ":${tcp_port}[[:space:]]" \
                    | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)"
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
            if sock_is_ready "$sock_path"; then
                log_warn "$name already running (socket ${sock_path}), skipping"
                return 0
            fi
            # ss 在场且确认无监听 → stale socket，删除避免 bind 失败
            # （ss 缺失时 sock_is_ready 已放行，不会到达此处）
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

    # daemon 环境前置（模型名/API key 注入，单一实现与 supervisor 模式共用）
    prepare_daemon_env "$name"

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

# 批量停止（并行 TERM → 统一宽限窗口 → KILL 兜底）。输入：daemon 名列表。
# 逐 daemon 顺序等待会放大总停止时间，故三阶段批量处理：
#   阶段一 逆序并行发 SIGTERM（不逐个等待）
#   阶段二 统一等待优雅停止窗口（全部并行清理，总耗时 ≈ 单个窗口）
#   阶段三 窗口超时仍未退出的进程强制清理
stop_daemons_parallel() {
    local -a names=("$@")
    local idx name pid

    for ((idx=${#names[@]}-1; idx>=0; idx--)); do
        name="${names[$idx]}"
        pid="$(get_daemon_pid "$name")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            log_debug "  TERM → $name (PID=$pid)"
        fi
    done

    local elapsed=0
    local any_alive=1
    while [[ $elapsed -lt $GRACEFUL_STOP_SEC ]]; do
        any_alive=0
        for name in "${names[@]}"; do
            pid="$(get_daemon_pid "$name")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                any_alive=1
            fi
        done
        [[ $any_alive -eq 0 ]] && break
        sleep 1
        # 注意：不能用 ((elapsed++))——set -e 下 elapsed=0 时其求值退出码为 1，
        # 会中断脚本（实测 systemd 记录 status=1，exit 0/130 分支均未到达）。
        elapsed=$((elapsed + 1))
    done

    for name in "${names[@]}"; do
        pid="$(get_daemon_pid "$name")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_warn "  $name exceeded graceful window, KILL (PID=$pid)"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
}

stop_all_daemons() {
    log_step "Stopping all daemons (parallel SIGTERM + graceful window)..."
    if ((DRY_RUN)); then
        return 0
    fi

    # supervisor 模式：监管域由 sup_stop 级联收摊（shutdown_all 并行 TERM
    # 全部子进程 + 宽限 + KILL 兜底，并自清 sock/pid），直启域残余并行补停。
    # 监管域无 pidfile（PID 由 supervisor 内存表掌握），直接 TERM 找不到
    # 目标——必须经控制口/级联路径停止。
    if sup_enabled; then
        sup_stop
        stop_daemons_parallel "${SUP_DIRECT_DAEMONS[@]}"
        return 0
    fi

    local -a all_names=()
    local layer_var
    for layer_var in "${ALL_LAYERS[@]}"; do
        local -n daemons="$layer_var"
        all_names+=("${daemons[@]}")
    done
    stop_daemons_parallel "${all_names[@]}"
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
                local tag="pre-existing"
                if sup_enabled && sup_role_of "$name" >/dev/null 2>&1; then
                    tag="managed by supervisor"
                fi
                log_info "$name: ONLINE ($tag)"
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
    # 不用 grep -q：comm 列表首行命中时 grep 提前退出使 ps 收 SIGPIPE，
    # pipefail 下误判已死（触发 watchdog 重复拉起）
    ps -eo comm= 2>/dev/null | grep -x "${bin_name}" >/dev/null && return 0
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

# 重启/激活后短等待健康确认（≤5s），避免阻塞整轮巡检；未通过由下轮兜底
wd_wait_health() {
    local name="$1"
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
        local pid_info
        pid_info="$(get_daemon_pid "$name")"
        [[ -n "$pid_info" ]] && pid_info=" (pid=$pid_info)"
        wd_log "OK    ${name} healthy again${pid_info}"
    fi
}

# 单轮巡检：按启动顺序检查全部 daemon，对死亡进程执行幂等重启。
# supervisor 监管域分流：CORE 死亡由 supervisor BACKOFF 自动复活
# （bootstrap 双拉起会与退避重启竞争，跳过）；AUX 死亡（STOPPED，supervisor
# 不自动复活）经控制口激活；直启域保持 start_daemon 原路。
wd_check_all() {
    ((DRY_RUN)) && return 0
    local layer_var name role

    for layer_var in "${ALL_LAYERS[@]}"; do
        local -n daemons="$layer_var"
        for name in "${daemons[@]}"; do
            if daemon_is_alive "$name"; then
                continue
            fi

            role=""
            if sup_enabled; then
                role="$(sup_role_of "$name" 2>/dev/null || true)"
            fi

            if [[ "$role" == "core" ]]; then
                continue
            fi

            if ! wd_restart_allowed "$name"; then
                wd_log "WARN  ${name} down but restart rate-limited (${WATCHDOG_RESTART_LIMIT}/${WATCHDOG_RESTART_WINDOW_SEC}s), skip this round"
                continue
            fi

            if [[ "$role" == "aux" ]]; then
                wd_log "RESTART ${name} detected down, activating via supervisor ctrl..."
                if sup_activate_cli "$name"; then
                    wd_wait_health "$name"
                else
                    wd_log "FAIL  ${name} activate failed"
                fi
            else
                wd_log "RESTART ${name} detected down, restarting..."
                if start_daemon "$name"; then
                    wd_wait_health "$name"
                else
                    wd_log "FAIL  ${name} restart failed"
                fi
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

    # 子命令支持：stop（停止全部 daemon）。历史问题：getopts 忽略位置参数，
    # 传 "stop" 会被当作启动执行（实际重启 daemon 群）。此处显式识别并走
    # 停止路径（并行 TERM → 等待 → KILL 兜底，与信号处理同语义）。
    # STOP_REQUESTED 由顶部预扫描从全部参数提取（与选项顺序无关）：
    # `-s stop` / `--home /x stop` 等组合同样正确进入停止路径。
    if (( STOP_REQUESTED )); then
        log_info "Stopping all daemons..."
        stop_all_daemons
        log_info "All daemons stopped"
        exit 0
    fi

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

    log_info "AgentRT Bootstrap v0.1.9"
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

    # supervisor 编排前置：声明调谐 → 监管域环境前置（supervisor spawn 的
    # 子进程继承 supervisor 环境，export 必须在拉起前完成）→ bin 归位 →
    # 拉起 supervisor。supervisor 内部 reconcile 立即拉起全部 CORE；AUX
    # 保持 STOPPED，由下方逐层循环按 DAG 层序经控制口激活（层间等待语义
    # 保留）。supervisor_d 二进制缺失时 sup_enabled 为假，整体回退直启
    # （模块化拔插，五层 DAG 语义不变）。
    if sup_enabled; then
        sup_write_decl
        local sd
        for sd in "${SUP_CORE_DAEMONS[@]}" "${SUP_AUX_DAEMONS[@]}"; do
            prepare_daemon_env "$sd"
        done
        sup_bin_link
        if ! sup_start; then
            log_error "supervisor_d failed to start, aborting..."
            stop_all_daemons
            exit 1
        fi
        log_info "Orchestration: supervisor_d manages CORE(${#SUP_CORE_DAEMONS[@]}) + AUX(${#SUP_AUX_DAEMONS[@]})"
    else
        log_info "Orchestration: direct-start (supervisor_d not present)"
    fi
    echo ""

    # 逐层启动
    local layer_num=0
    local total_started=0
    local total_failed=0

    for layer_var in "${ALL_LAYERS[@]}"; do
        local -n daemons="$layer_var"
        log_step "=== Layer $layer_num: ${daemons[*]} ==="

        # 同层启动（supervisor 模式分流：CORE 已由 reconcile 拉起、AUX 经
        # 控制口激活，均不再 start_daemon；直启域保持原路）
        for name in "${daemons[@]}"; do
            local role=""
            if sup_enabled; then
                role="$(sup_role_of "$name" 2>/dev/null || true)"
            fi
            if [[ "$role" == "core" ]]; then
                continue
            elif [[ "$role" == "aux" ]]; then
                if ((DRY_RUN)); then
                    log_info "[DRY-RUN] Would activate $name via supervisor ctrl"
                elif sup_activate_cli "$name"; then
                    log_info "$name activated via supervisor ctrl"
                else
                    log_error "$name activate failed via supervisor ctrl"
                    ACTIVATE_FAILED[$name]=1
                    total_failed=$((total_failed + 1))
                    continue
                fi
                total_started=$((total_started + 1))
            elif start_daemon "$name"; then
                total_started=$((total_started + 1))
            else
                total_failed=$((total_failed + 1))
            fi
        done

        # 等待同层所有 daemon 健康检查通过
        if ! ((DRY_RUN)); then
            for name in "${daemons[@]}"; do
                # 直启域以 DAEMON_PIDS 为准；监管域无 pidfile（PID 由
                # supervisor 内存表掌握），凡声明表成员均需健康确认
                # （激活失败的 AUX 除外，避免对未启动进程空等超时）。
                local need_wait=0
                if [[ -n "${DAEMON_PIDS[$name]:-}" ]]; then
                    need_wait=1
                elif [[ -z "${ACTIVATE_FAILED[$name]:-}" ]] \
                     && sup_enabled && sup_role_of "$name" >/dev/null 2>&1; then
                    need_wait=1
                fi
                if ((need_wait)); then
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

    # supervisor 模式下 CORE 由 reconcile 拉起（未进上方循环），计入总数
    # 以使收尾文案与系统实况一致。
    if sup_enabled; then
        total_started=$((total_started + ${#SUP_CORE_DAEMONS[@]}))
    fi
    log_info "Bootstrap complete — all ${total_started} daemons started successfully"

    # Watchdog 自愈模式：全部拉起后进入巡检循环（前台常驻）
    if ((WATCHDOG)); then
        watchdog_loop
    fi

    return 0
}

main "$@"
