#!/usr/bin/env bash
# shellcheck shell=bash
# Copyright (c) 2026 SPHARX Ltd. All Rights Reserved.
# AgentRT 统一日志和错误处理模块
# 遵循 AgentRT 架构设计原则：反馈闭环、工程美学

###############################################################################
# 颜色定义
###############################################################################
declare -r COLOR_RED='\033[0;31m'
declare -r COLOR_GREEN='\033[0;32m'
declare -r COLOR_YELLOW='\033[1;33m'
declare -r COLOR_BLUE='\033[0;34m'
declare -r COLOR_CYAN='\033[0;36m'
declare -r COLOR_MAGENTA='\033[0;35m'
declare -r COLOR_NC='\033[0m'

###############################################################################
# 日志级别定义
###############################################################################
declare -r LOG_LEVEL_DEBUG=0
declare -r LOG_LEVEL_INFO=1
declare -r LOG_LEVEL_WARN=2
declare -r LOG_LEVEL_ERROR=3
declare -r LOG_LEVEL_FATAL=4

declare -r LOG_LEVEL_NAMES=("DEBUG" "INFO" "WARN" "ERROR" "FATAL")
declare -r LOG_LEVEL_COLORS=("$COLOR_CYAN" "$COLOR_BLUE" "$COLOR_YELLOW" "$COLOR_RED" "$COLOR_MAGENTA")

###############################################################################
# 全局变量
###############################################################################
_AGENTRT_LOG_LEVEL="${AGENTRT_LOG_LEVEL:-$LOG_LEVEL_INFO}"
_AGENTRT_LOG_PREFIX="${AGENTRT_LOG_PREFIX:-[AgentRT]}"
_AGENTRT_LOG_TIMESTAMP="${AGENTRT_LOG_TIMESTAMP:-1}"
_AGENTRT_LOG_FILE="${AGENTRT_LOG_FILE:-}"
_AGENTRT_SCRIPT_ERRORS=0
_AGENTRT_SCRIPT_WARNINGS=0
_AGENTRT_SCRIPT_NAME="${0##*/}"
_AGENTRT_SCRIPT_PID=$$
_AGENTRT_TRACE_ID="${AGENTRT_TRACE_ID:-$(date +%s)-$$}"

###############################################################################
# 内部函数：获取时间戳
###############################################################################
_agentrt_timestamp() {
    if [[ "$_AGENTRT_LOG_TIMESTAMP" == "1" ]]; then
        date '+%Y-%m-%d %H:%M:%S'
    fi
}

###############################################################################
# 内部函数：写入日志
###############################################################################
_agentrt_log_write() {
    local level=$1
    local message="$2"
    local timestamp=$(_agentrt_timestamp)
    local level_name="${LOG_LEVEL_NAMES[$level]}"
    local level_color="${LOG_LEVEL_COLORS[$level]}"
    local formatted_msg

    if [[ -n "$timestamp" ]]; then
        formatted_msg="${timestamp} ${_AGENTRT_LOG_PREFIX} ${level_name} ${message}"
    else
        formatted_msg="${_AGENTRT_LOG_PREFIX} ${level_name} ${message}"
    fi

    echo -e "${level_color}${formatted_msg}${COLOR_NC}"

    if [[ -n "$_AGENTRT_LOG_FILE" ]]; then
        echo "$formatted_msg" >> "$_AGENTRT_LOG_FILE"
    fi
}

###############################################################################
# 公共API：日志函数
###############################################################################
airy_log_debug() {
    if [[ $_AGENTRT_LOG_LEVEL -le $LOG_LEVEL_DEBUG ]]; then
        _agentrt_log_write $LOG_LEVEL_DEBUG "$1"
    fi
}

airy_log_info() {
    if [[ $_AGENTRT_LOG_LEVEL -le $LOG_LEVEL_INFO ]]; then
        _agentrt_log_write $LOG_LEVEL_INFO "$1"
    fi
}

airy_log_warn() {
    ((_AGENTRT_SCRIPT_WARNINGS++))
    if [[ $_AGENTRT_LOG_LEVEL -le $LOG_LEVEL_WARN ]]; then
        _agentrt_log_write $LOG_LEVEL_WARN "$1"
    fi
}

airy_log_error() {
    ((_AGENTRT_SCRIPT_ERRORS++))
    if [[ $_AGENTRT_LOG_LEVEL -le $LOG_LEVEL_ERROR ]]; then
        _agentrt_log_write $LOG_LEVEL_ERROR "$1"
    fi
}

airy_log_fatal() {
    ((_AGENTRT_SCRIPT_ERRORS++))
    _agentrt_log_write $LOG_LEVEL_FATAL "$1"
    airy_exit 1
}

###############################################################################
# 公共API：设置日志级别
###############################################################################
airy_log_set_level() {
    case "$1" in
        debug|DEBUG) _AGENTRT_LOG_LEVEL=$LOG_LEVEL_DEBUG ;;
        info|INFO)   _AGENTRT_LOG_LEVEL=$LOG_LEVEL_INFO ;;
        warn|WARN)  _AGENTRT_LOG_LEVEL=$LOG_LEVEL_WARN ;;
        error|ERROR) _AGENTRT_LOG_LEVEL=$LOG_LEVEL_ERROR ;;
        *)          airy_log_warn "Unknown log level: $1, using INFO"; _AGENTRT_LOG_LEVEL=$LOG_LEVEL_INFO ;;
    esac
}

###############################################################################
# 公共API：设置日志文件
###############################################################################
airy_log_set_file() {
    _AGENTRT_LOG_FILE="$1"
}

###############################################################################
# 公共API：打印消息（不带日志级别前缀）
###############################################################################
airy_echo() {
    echo -e "$1"
}

airy_echo_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_NC} $1"
}

airy_echo_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_NC} $1"
}

airy_echo_warning() {
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_NC} $1"
}

airy_echo_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_NC} $1"
}

###############################################################################
# 公共API：错误处理
###############################################################################
airy_die() {
    airy_log_fatal "$1"
    exit "${2:-1}"
}

airy_exit() {
    local exit_code=$1
    if [[ $exit_code -eq 0 ]]; then
        airy_log_info "Script $_AGENTRT_SCRIPT_NAME completed successfully"
    else
        airy_log_error "Script $_AGENTRT_SCRIPT_NAME failed with exit code $exit_code"
    fi
    exit $exit_code
}

###############################################################################
# 公共API：错误统计获取
###############################################################################
airy_get_error_count() {
    echo $_AGENTRT_SCRIPT_ERRORS
}

airy_get_warning_count() {
    echo $_AGENTRT_SCRIPT_WARNINGS
}

###############################################################################
# 公共API：断言函数
###############################################################################
airy_assert() {
    local condition="$1"
    local message="${2:-Assertion failed}"
    if ! eval "$condition"; then
        airy_log_fatal "$message (condition: $condition)"
    fi
}

airy_assert_not_empty() {
    local value="$1"
    local name="${2:-value}"
    if [[ -z "$value" ]]; then
        airy_log_fatal "Assert failed: $name must not be empty"
    fi
}

airy_assert_file_exists() {
    local file="$1"
    local name="${2:-file}"
    if [[ ! -f "$file" ]]; then
        airy_log_fatal "Assert failed: $name does not exist: $file"
    fi
}

airy_assert_dir_exists() {
    local dir="$1"
    local name="${2:-directory}"
    if [[ ! -d "$dir" ]]; then
        airy_log_fatal "Assert failed: $name does not exist: $dir"
    fi
}

airy_assert_command_exists() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        airy_log_fatal "Assert failed: required command not found: $cmd"
    fi
}

###############################################################################
# 公共API：追踪ID
###############################################################################
airy_get_trace_id() {
    echo "$_AGENTRT_TRACE_ID"
}

airy_set_trace_id() {
    _AGENTRT_TRACE_ID="$1"
}

###############################################################################
# 公共API：进度显示
###############################################################################
airy_progress_start() {
    local message="$1"
    echo -ne "${COLOR_BLUE}[......]${COLOR_NC} $message"
}

airy_progress_update() {
    local step="$1"
    echo -ne "\b\b\b\b\b\b"
    case "$step" in
        1) echo -ne "\b\b\b\b\b\b" ;;
        2) echo -ne "\b/     ]" ;;
        3) echo -ne "\b-     ]" ;;
        4) echo -ne "\b\\     ]" ;;
        5) echo -ne "\b|     ]" ;;
        *) echo -ne "\b*     ]" ;;
    esac
}

airy_progress_done() {
    local message="$1"
    local status="${2:-SUCCESS}"
    echo -ne "\b\b\b\b\b\b"
    case "$status" in
        SUCCESS) echo -e "\b\b\b\b\b\b${COLOR_GREEN}[DONE]${COLOR_NC} $message" ;;
        FAIL)    echo -e "\b\b\b\b\b\b${COLOR_RED}[FAIL]${COLOR_NC} $message" ;;
        SKIP)    echo -e "\b\b\b\b\b\b${COLOR_YELLOW}[SKIP]${COLOR_NC} $message" ;;
        *)       echo -e "\b\b\b\b\b\b${COLOR_BLUE}[$status]${COLOR_NC} $message" ;;
    esac
}

###############################################################################
# 导出公共API
###############################################################################
export -f airy_log_debug airy_log_info airy_log_warn airy_log_error airy_log_fatal
export -f airy_log_set_level airy_log_set_file
export -f airy_echo airy_echo_info airy_echo_success airy_echo_warning airy_echo_error
export -f airy_die airy_exit
export -f airy_get_error_count airy_get_warning_count
export -f airy_assert airy_assert_not_empty airy_assert_file_exists airy_assert_dir_exists airy_assert_command_exists
export -f airy_get_trace_id airy_set_trace_id
export -f airy_progress_start airy_progress_update airy_progress_done