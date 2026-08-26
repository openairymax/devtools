# Shell 公共库（lib）

`tools/scripts/ops/lib/`

## 概述

`lib/` 目录存放 AgentRT 运维脚本共享的 Shell 公共库，遵循接口最小化原则（E-5），按职责拆分为四个模块：`common.sh`（工具函数入口）、`log.sh`（日志与错误处理）、`error.sh`（错误码体系）、`platform.sh`（平台检测）。所有 `airy_*` 函数均通过 `export -f` 导出，供各运维脚本统一 `source` 后复用，保证日志格式、错误码与平台判断全项目一致。

> **版本**: v0.1.5

## 目录结构

```
lib/
├── README.md       # 本文档
├── common.sh       # 通用工具函数入口：source 后自动加载 log/error/platform，提供字符串/文件/进程/网络/数组/版本比较/配置/交互/下载等 airy_* 工具
├── log.sh          # 统一日志与错误处理：DEBUG/INFO/WARN/ERROR/FATAL 五级日志、断言、追踪 ID、进度显示
├── error.sh        # 统一错误码体系：成功 0，通用 1000-1999，构建 2000-2999，安装 3000-3999，Docker 4000-4999，配置 5000-5999，测试 6000-6999，环境 7000-7999
└── platform.sh     # 平台检测：linux/macos/windows/wsl/unknown，架构 x86_64/arm64/aarch64
```

## 核心组件说明

### common.sh — 通用工具函数入口

脚本采用 `set -euo pipefail` 严格模式；`source` 时通过 `airy_load_libs` 自动加载 `log.sh`、`error.sh`、`platform.sh`（缺失任一模块即报错返回）。按类别提供的工具：

- 字符串：`airy_to_lower` / `airy_to_upper` / `airy_trim` / `airy_contains` / `airy_random_string`
- 文件：`airy_mkdir` / `airy_safe_rm` / `airy_backup_file` / `airy_file_size` / `airy_is_executable`
- 进程：`airy_is_process_running` / `airy_wait_for_process` / `airy_kill_process`
- 网络：`airy_is_port_available` / `airy_wait_for_url`
- 数组：`airy_in_array` / `airy_array_length`
- 版本比较：`airy_version_compare` / `airy_version_check`
- 配置读写：`airy_config_get` / `airy_config_set`（`key=value` 文件）
- 交互：`airy_confirm` / `airy_select`
- 下载：`airy_download`（支持 `AGENTRT_HTTP_PROXY` / `AGENTRT_HTTPS_PROXY` 代理）

### log.sh — 统一日志与错误处理

- 日志级别：`airy_log_debug` / `airy_log_info` / `airy_log_warn` / `airy_log_error` / `airy_log_fatal`（FATAL 记数后以退出码 1 终止）
- 级别控制：`airy_log_set_level`（debug/info/warn/error，默认 INFO）、`airy_log_set_file`（追加写入日志文件）
- 输出：`airy_echo_*` 系列不带级别前缀的彩色消息
- 错误处理：`airy_die` / `airy_exit` / `airy_get_error_count` / `airy_get_warning_count`
- 断言：`airy_assert` / `airy_assert_not_empty` / `airy_assert_file_exists` / `airy_assert_dir_exists` / `airy_assert_command_exists`
- 其他：`airy_get_trace_id` / `airy_set_trace_id`（追踪 ID，默认 `日期时间-$$`）、`airy_progress_start` / `airy_progress_update` / `airy_progress_done`（进度显示）

### error.sh — 统一错误码体系

定义 `AGENTRT_*` 错误码常量（`declare -r`）与 `AGENTRT_ERROR_MESSAGES` 描述映射（`declare -A`）。错误码按模块分段分配，保证全局唯一：成功 `AGENTRT_SUCCESS=0`；通用错误 1000-1999（如 `AGENTRT_ERR_INVALID_PARAM=1001`、`AGENTRT_ERR_TIMEOUT=1003`）；构建 2000-2999；安装 3000-3999；Docker 4000-4999；配置 5000-5999；测试 6000-6999；脚本执行环境 7000-7999（如 `AGENTRT_ERR_ENV_PLATFORM=7001`）。

### platform.sh — 平台检测

检测顺序 WSL → macOS → Linux → Windows（MINGW/CYGWIN）→ unknown，架构 x86_64 / arm64 / aarch64。检测结果缓存于全局变量，重复调用零开销。公共 API：`airy_platform_detect`、`airy_arch_detect`、`airy_platform_is_linux` / `airy_platform_is_macos` 等条件判断，另提供 `airy_linux_distro_detect`、`airy_package_manager_detect`、`airy_system_info`、`airy_cpu_count`、`airy_total_memory` 等环境探测函数。

## 使用方式

```bash
# 在 Shell 脚本中引用公共库（自动加载 log/error/platform）
source tools/scripts/ops/lib/common.sh

# 日志
airy_log_info "服务启动成功"
airy_log_warn "内存使用率较高"
airy_log_error "连接超时"

# 平台检测
if airy_platform_is_linux; then
    echo "Linux 平台"
fi
platform=$(airy_platform_detect)
arch=$(airy_arch_detect)
distro=$(airy_linux_distro_detect)
nproc=$(airy_cpu_count)

# 工具函数
airy_to_lower "HELLO"          # → hello
airy_config_get app.conf debug "false"
if airy_confirm "是否继续？" ; then ... fi
```

## 依赖

| 模块 | 依赖 | 说明 |
|------|------|------|
| `common.sh` | Bash 4.0+（关联数组/`export -f`） | 自动加载 log/error/platform；`airy_wait_for_url`/`airy_download` 依赖 curl |
| `log.sh` | Bash 4.0+ | 纯 Bash 实现，无外部依赖 |
| `error.sh` | Bash 4.0+ | 纯 Bash 实现，无外部依赖 |
| `platform.sh` | Bash 4.0+、`uname` | 纯 Bash 实现，无外部依赖 |

---

© 2025-2026 SPHARX Ltd. All Rights Reserved.
